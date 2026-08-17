#!/usr/bin/env bash
# ticket-flow: deterministic Linear state/label executor.
# -u (nounset) intentionally omitted: Claude Code shell snapshots inject
# ZSH_VERSION references that trigger false-positive "unbound variable"
# errors in this bash version when nounset is active.
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${CLAUDE_SKILLS_LIB:-$HOME/.claude/skills/lib}"
source "$LIB_DIR/heartbeat.sh"
source "$LIB_DIR/linear-api.sh"

SM="$SCRIPT_DIR/state-machine.json"

usage() {
  echo "Usage: $0 <TICKET-ID> <TRIGGER> [--generation N] [--state-dir DIR] [--data key=value ...] [--dry-run]" >&2
  echo "" >&2
  echo "  --generation N   Caller's generation token (required when fence is active)" >&2
  echo "  --state-dir DIR   Fleet state directory for fence marker lookup" >&2
  echo "" >&2
  echo "Valid triggers (from state-machine.json):" >&2
  jq -r '.triggers | keys[]' "$SM" 2>/dev/null | sed 's/^/  /' >&2
  exit 1
}

TICKET_ID="${1:-}"
TRIGGER="${2:-}"
shift 2 2>/dev/null || true

[ -z "$TICKET_ID" ] && usage
[ -z "$TRIGGER" ] && usage
[[ "$TICKET_ID" =~ ^[A-Z]+-[0-9]+$ ]] || {
  echo "Invalid TICKET_ID: $TICKET_ID" >&2
  exit 1
}

# ── Concurrent-execution lock (flock FD 9) ──────────────────────────────────
# Lock path is anchored to a fixed directory so fleet-intervene.sh's mutex
# check sees the same lock regardless of the caller's CWD. Resolve via env
# var first, then fall back to the plugin directory.
FLOW_LOCK_DIR="${TICKET_FLOW_LOCK_DIR:-$SCRIPT_DIR/locks}"
mkdir -p "$FLOW_LOCK_DIR"
exec 9>"${FLOW_LOCK_DIR}/.ticket-flow-${TICKET_ID}.lock"
if ! flock -n -E 42 9; then
  echo "ticket already in flight: $TICKET_ID" >&2
  exit 42
fi

# ── Parse optional flags ────────────────────────────────────────────────────

DRY_RUN=false
CALLER_GENERATION=""
FLEET_STATE_DIR="${FLEET_STATE_DIR:-}"
declare -A DATA=()
while [ $# -gt 0 ]; do
  case "$1" in
  --dry-run) DRY_RUN=true ;;
  --generation)
    CALLER_GENERATION="$2"
    shift
    ;;
  --state-dir)
    FLEET_STATE_DIR="$2"
    shift
    ;;
  --data)
    key="${2%%=*}"
    val="${2#*=}"
    DATA["$key"]="$val"
    shift
    ;;
  esac
  shift
done

# ── Pipeline log helper ─────────────────────────────────────────────────────

_log() {
  [ -n "${LOG_FILE:-}" ] || return 0
  # $1 is the pipe-delimited suffix: "PHASE|STEP|STATUS|MSG"
  IFS='|' read -r _ph _st _status _msg <<<"$1"
  _plog "$LOG_FILE" "$_ph" "$_st" "$_status" "$_msg"
}

_emit_schema_header() {
  [ -n "${LOG_FILE:-}" ] || return 0
  if [ ! -s "$LOG_FILE" ]; then
    _log "META|schema|info|1"
  fi
}

# ── Validate state-machine.json ─────────────────────────────────────────────

if ! jq '.' "$SM" >/dev/null 2>&1; then
  echo "state-machine.json is not valid JSON: $SM" >&2
  exit 1
fi

# ── Dispatch trigger via JSON ────────────────────────────────────────────────

def=$(jq --arg t "$TRIGGER" '.triggers[$t] // empty' "$SM")
if [ -z "$def" ]; then
  echo "Unknown trigger: $TRIGGER" >&2
  echo "Valid triggers:" >&2
  jq -r '.triggers | keys[]' "$SM" | sed 's/^/  /' >&2
  exit 3
fi

# Emit trigger-def to pipeline log
_emit_schema_header
_log "META|trigger-def|info|${TRIGGER}:$(echo "$def" | jq -c '.')"
hb_gate "trigger-dispatch" "fired" "trigger ${TRIGGER} dispatched" '{"trigger":"'"$TRIGGER"'"}'

# ── Derive state machine variables from trigger def ─────────────────────────

NEW_STATE_NAME=$(echo "$def" | jq -r '.to // empty')
SET_ASSIGNEE_ME=$(echo "$def" | jq -r '.set_assignee == "me"')

# Build label arrays — substitute {complexity} and {outcome} placeholders
ADD_LABEL_NAMES=()
while IFS= read -r label; do
  [ -z "$label" ] && continue
  label=$(echo "$label" | sed \
    -e "s/{complexity}/${DATA[complexity]:-simple}/g" \
    -e "s/{outcome}/${DATA[outcome]:-Smooth}/g")
  ADD_LABEL_NAMES+=("$label")
done < <(echo "$def" | jq -r '.adds[]? // empty')

REMOVE_LABEL_NAMES=()
while IFS= read -r label; do
  [ -z "$label" ] && continue
  REMOVE_LABEL_NAMES+=("$label")
done < <(echo "$def" | jq -r '.removes[]? // empty')

# ── Fetch current ticket state ──────────────────────────────────────────────

ISSUE_JSON=$(get_issue "$TICKET_ID")
TEAM_ID=$(echo "$ISSUE_JSON" | jq -r '.team.id // empty')
CURRENT_STATE_NAME=$(echo "$ISSUE_JSON" | jq -r '.state.name // empty')

# ── Warn-only from-precondition check (D-2) ─────────────────────────────────
# flow.sh has executed triggers unguarded since inception. This check logs
# ILLEGAL_TRANSITION when the ticket's current state does not match the
# trigger's declared "from" field, but does NOT block the mutation. Ship
# warn-only first, gather telemetry, then decide whether to hard-enforce.
# If "from" is null or absent, the check is skipped entirely.
# "from" can be a single string or an array of acceptable states.
EXPECTED_FROM=$(echo "$def" | jq -r '.from // empty')
if [ -n "$EXPECTED_FROM" ] && [ "$EXPECTED_FROM" != "null" ]; then
  _from_match=false
  # Check if "from" is an array — if so, any element matching current state is valid
  if echo "$def" | jq -e '.from | type == "array"' >/dev/null 2>&1; then
    if echo "$def" | jq -e --arg state "$CURRENT_STATE_NAME" '.from | index($state) != null' >/dev/null 2>&1; then
      _from_match=true
    fi
  else
    # Single string value
    if [ "$CURRENT_STATE_NAME" = "$EXPECTED_FROM" ]; then
      _from_match=true
    fi
  fi
  if ! $_from_match; then
    _log "META|flow-warn|info|ILLEGAL_TRANSITION — ${TICKET_ID} attempted ${TRIGGER} from ${CURRENT_STATE_NAME}, expected from ${EXPECTED_FROM}"
    hb_gate "flow-warn" "warn" "ILLEGAL_TRANSITION" "{\"ticket\":\"${TICKET_ID}\",\"trigger\":\"${TRIGGER}\",\"actual\":\"${CURRENT_STATE_NAME}\",\"expected_from\":\"${EXPECTED_FROM}\"}"
  fi
fi

CURRENT_LABEL_NAMES=$(echo "$ISSUE_JSON" | jq -r '[.labels.nodes[].name] | join(",")')
ISSUE_TYPE=$(echo "$ISSUE_JSON" | jq -r '.issueType.name // empty')
PROJECT_NAME=$(echo "$ISSUE_JSON" | jq -r '.project.name // empty')

# ── Planner label preconditions ──────────────────────────────────────────────
# state:execution is an Epic-only label. Reject if added to a non-Epic issue.
# Read precondition rules from state-machine.json planner_labels section.
for label_name in "${ADD_LABEL_NAMES[@]}"; do
  _precondition=$(jq -r --arg l "$label_name" '.planner_labels[$l].precondition // empty' "$SM" 2>/dev/null)
  if [ "$_precondition" = "issue_type_must_be_epic" ] && [ "$ISSUE_TYPE" != "Epic" ]; then
    echo "flow.sh: precondition failed — 'state:execution' label can only be applied to Epic issues (current type: ${ISSUE_TYPE:-unknown})" >&2
    _log "META|precondition|fail|state:execution requires Epic, got ${ISSUE_TYPE:-unknown}"
    hb_gate "precondition" "fail" "state:execution non-Epic rejected" "{\"ticket\":\"$TICKET_ID\",\"type\":\"${ISSUE_TYPE:-unknown}\"}"
    exit 8
  fi
done

TEAM_JSON=$(get_team "$TEAM_ID")

# ── Generation fence guard ────────────────────────────────────────────────────
# Gate behind FLEET_FENCE_ENFORCE (default: true).
# If a fence marker exists for this ticket, refuse mutations from superseded
# generations. Missing generation token on a fenced ticket → fail-closed.
FENCE_ENFORCE="${FLEET_FENCE_ENFORCE:-true}"
if [ "$FENCE_ENFORCE" = "true" ]; then
  # Discover and source fleet-config.sh (renamed from config.sh to avoid the
  # SessionStart lib-sync collision) for _fleet_fence_file constructor.
  # Look relative to this script (monorepo), then installed plugin paths.
  # The old config.sh name is kept as a fallback for installed pre-rename
  # fleet-controller versions.
  _flow_config_sh=""
  for _cand in \
    "$SCRIPT_DIR/../../../fleet-controller/lib/fleet-config.sh" \
    "$HOME/.claude/skills/fleet-controller/lib/fleet-config.sh" \
    "$HOME/.claude/plugins/fleet-controller/lib/fleet-config.sh" \
    "$SCRIPT_DIR/../../../fleet-controller/lib/config.sh" \
    "$HOME/.claude/skills/fleet-controller/lib/config.sh" \
    "$HOME/.claude/plugins/fleet-controller/lib/config.sh"; do
    [ -f "$_cand" ] && {
      _flow_config_sh="$_cand"
      break
    }
  done
  if [ -n "$_flow_config_sh" ]; then
    source "$_flow_config_sh"
    _fence_file=$(_fleet_fence_file "$TICKET_ID" "${FLEET_STATE_DIR:-./logs}")
  else
    # Fallback: match config.sh resolution logic — FLEET_STATE_DIR takes
    # precedence, workspace-derived path second, /tmp last (backward compat).
    if [ -n "${FLEET_STATE_DIR:-}" ]; then
      _fence_file="${FLEET_STATE_DIR}/${TICKET_ID}-fence"
    else
      _fence_file="/tmp/${TICKET_ID}-fence"
    fi
  fi

  if [ -f "$_fence_file" ]; then
    _fenced_gen=$(jq -r '.fenced_generation // 0' "$_fence_file" 2>/dev/null || echo "0")

    # Missing generation token on a fenced ticket → refuse
    if [ -z "$CALLER_GENERATION" ]; then
      echo "flow.sh: fence guard — missing generation token for fenced ticket ${TICKET_ID} (fenced at generation ${_fenced_gen})" >&2
      _log "META|fence-guard|fail|missing generation token for fenced ticket ${TICKET_ID}"
      hb_gate "fence-guard" "fail" "missing generation token" "{\"ticket\":\"${TICKET_ID}\",\"fenced_gen\":${_fenced_gen}}"
      exit 9
    fi

    # caller_gen <= fenced_gen → superseded, refuse
    if [ "$CALLER_GENERATION" -le "$_fenced_gen" ] 2>/dev/null; then
      echo "flow.sh: fence guard — generation ${CALLER_GENERATION} is superseded by fenced generation ${_fenced_gen} for ${TICKET_ID}" >&2
      _log "META|fence-guard|fail|generation ${CALLER_GENERATION} <= fenced ${_fenced_gen}"
      hb_gate "fence-guard" "fail" "superseded generation" "{\"ticket\":\"${TICKET_ID}\",\"caller_gen\":${CALLER_GENERATION},\"fenced_gen\":${_fenced_gen}}"
      exit 10
    fi

    # caller_gen > fenced_gen → current generation, allowed
    _log "META|fence-guard|info|generation ${CALLER_GENERATION} > fenced ${_fenced_gen}, allowed"
  fi
  # No fence marker → unrestricted (backward compatible)
fi

# Helper: look up state ID by name
resolve_state_id() {
  local name="$1"
  local sid
  sid=$(echo "$TEAM_JSON" | jq -r --arg n "$name" '.states[] | select(.name == $n) | .id')
  [ -n "$sid" ] || {
    echo "State '$name' not found in team" >&2
    exit 3
  }
  echo "$sid"
}

# Helper: look up label ID by name (returns empty string if not found)
resolve_label_id() {
  local name="$1"
  echo "$TEAM_JSON" | jq -r --arg n "$name" '.labels[] | select(.name | ascii_downcase == ($n | ascii_downcase)) | .id // empty'
}

# ── Compute new label IDs from current + adds - removes ────────────────────

compute_label_ids() {
  local filter="."
  for name in "${ADD_LABEL_NAMES[@]}"; do
    local lid
    lid=$(resolve_label_id "$name")
    [ -n "$lid" ] && filter="$filter + [\"$lid\"]"
  done
  for name in "${REMOVE_LABEL_NAMES[@]}"; do
    local lid
    lid=$(echo "$ISSUE_JSON" | jq -r --arg n "$name" '.labels.nodes[] | select(.name | ascii_downcase == ($n | ascii_downcase)) | .id // empty')
    [ -n "$lid" ] && filter="$filter - [\"$lid\"]"
  done
  echo "$ISSUE_JSON" | jq -c "[.labels.nodes[].id] | $filter | unique"
}

NEW_LABEL_IDS=$(compute_label_ids)

# ── Resolve state ID ────────────────────────────────────────────────────────

NEW_STATE_ID=""
if [ -n "$NEW_STATE_NAME" ]; then
  NEW_STATE_ID=$(resolve_state_id "$NEW_STATE_NAME")
fi

# ── Idempotency check ───────────────────────────────────────────────────────

CURRENT_STATE_ID=$(echo "$ISSUE_JSON" | jq -r '.state.id // empty')
CURRENT_LABEL_IDS_SORTED=$(echo "$ISSUE_JSON" | jq -c '[.labels.nodes[].id] | sort')
NEW_LABEL_IDS_SORTED=$(echo "$NEW_LABEL_IDS" | jq -c 'sort')

STATE_CHANGED=false
[ -n "$NEW_STATE_ID" ] && [ "$NEW_STATE_ID" != "$CURRENT_STATE_ID" ] && STATE_CHANGED=true

LABELS_CHANGED=false
[ "$NEW_LABEL_IDS_SORTED" != "$CURRENT_LABEL_IDS_SORTED" ] && LABELS_CHANGED=true

# ── Dry-run output ──────────────────────────────────────────────────────────

if $DRY_RUN; then
  NEW_LABEL_NAMES=""
  if [ "$NEW_LABEL_IDS" != "[]" ]; then
    NEW_LABEL_NAMES=$(echo "$TEAM_JSON" | jq -r \
      --argjson ids "$NEW_LABEL_IDS" \
      '[.labels[] | select(.id as $lid | $ids | index($lid)) | .name] | join(",")')
  fi

  FINAL_STATE="${NEW_STATE_NAME:-$CURRENT_STATE_NAME}"
  jq -n \
    --arg trigger "$TRIGGER" \
    --arg current_state "$CURRENT_STATE_NAME" \
    --arg current_labels "$CURRENT_LABEL_NAMES" \
    --arg new_state "$FINAL_STATE" \
    --arg new_labels "${NEW_LABEL_NAMES:-}" \
    --argjson state_changed "$STATE_CHANGED" \
    --argjson labels_changed "$LABELS_CHANGED" \
    --argjson set_assignee "$SET_ASSIGNEE_ME" \
    '{
      trigger: $trigger,
      dry_run: true,
      current: {state: $current_state, labels: $current_labels},
      computed: {state: $new_state, labels: $new_labels},
      state_changed: $state_changed,
      labels_changed: $labels_changed,
      set_assignee_me: $set_assignee
    }'
  exit 0
fi

# ── Execute mutation ────────────────────────────────────────────────────────

IDEMPOTENT=false
if ! $STATE_CHANGED && ! $LABELS_CHANGED && [ "$SET_ASSIGNEE_ME" = "false" ]; then
  IDEMPOTENT=true
  hb_gate "idempotent-skip" "ok" "no mutation needed, desired state matches current" '{"trigger":"'"$TRIGGER"'"}'
  exit 0
fi

LABEL_IDS_ARG=""
$LABELS_CHANGED && LABEL_IDS_ARG="$NEW_LABEL_IDS"

ASSIGNEE_ARG=""
if [ "$SET_ASSIGNEE_ME" = "true" ]; then
  ASSIGNEE_ARG=$(get_me 2>/dev/null | jq -r '.id // empty')
fi

# Capture stderr alongside stdout so we can diagnose the root cause
# when update_issue returns non-JSON output (stderr contamination, curl
# failure, GraphQL error response, network timeout, etc.).
_update_stderr=$(mktemp)
RESULT=$(update_issue "$TICKET_ID" "${NEW_STATE_ID:-}" "$LABEL_IDS_ARG" "${ASSIGNEE_ARG:-}" 2>"$_update_stderr")
_update_rc=$?

if ! echo "$RESULT" | jq empty 2>/dev/null; then
  _stderr_head=$(head -5 "$_update_stderr" 2>/dev/null || echo "(empty)")
  rm -f "$_update_stderr"
  echo "flow.sh: invalid JSON from update_issue for ticket $TICKET_ID" >&2
  echo "flow.sh: update_issue exit code: ${_update_rc}" >&2
  echo "flow.sh: update_issue stderr (first 5 lines): ${_stderr_head}" >&2
  hb_retry "flow-sh" "fail" "update_issue returned non-JSON" "{\"ticket\":\"$TICKET_ID\",\"rc\":$_update_rc}"
  exit 5
fi
rm -f "$_update_stderr"
SUCCESS=$(echo "$RESULT" | jq -r '.success // false')

if [ "$SUCCESS" != "true" ]; then
  echo "Update failed: $RESULT" >&2
  exit 2
fi

# ── Post-trigger state assertion ────────────────────────────────────────────
# Skip when idempotency path was taken (no mutation occurred)

if ! $IDEMPOTENT; then
  # Bounded retry with backoff for read-after-write consistency.
  # Linear's API is eventually consistent — a mutation may not be
  # visible in the immediate next read. Retry once (2 total reads)
  # with a short delay before declaring STATE_ASSERTION_FAILED.
  _assert_attempt=0
  _assert_max=2
  while true; do
    LIVE_JSON=$(get_issue "$TICKET_ID")
    LIVE_STATE=$(echo "$LIVE_JSON" | jq -r '.state.name // empty')
    LIVE_LABELS=$(echo "$LIVE_JSON" | jq -r '[.labels.nodes[].name]')

    assert_failed=false
    assert_details=""

    # Assert state
    if [ -n "$NEW_STATE_NAME" ] && [ "$LIVE_STATE" != "$NEW_STATE_NAME" ]; then
      assert_failed=true
      assert_details="state: expected=$NEW_STATE_NAME actual=$LIVE_STATE"
    fi

    # Assert added labels are present
    for name in "${ADD_LABEL_NAMES[@]}"; do
      if ! echo "$LIVE_LABELS" | jq -e --arg n "$name" \
        '.[] | select(ascii_downcase == ($n | ascii_downcase))' >/dev/null 2>&1; then
        assert_failed=true
        assert_details="${assert_details:+$assert_details; }missing_label=$name"
      fi
    done

    # Assert removed labels are absent
    for name in "${REMOVE_LABEL_NAMES[@]}"; do
      if echo "$LIVE_LABELS" | jq -e --arg n "$name" \
        '.[] | select(ascii_downcase == ($n | ascii_downcase))' >/dev/null 2>&1; then
        assert_failed=true
        assert_details="${assert_details:+$assert_details; }unexpected_label=$name"
      fi
    done

    # post_assert removed: latent RCE vector via eval on trigger-defined shell code.
    # No trigger in state-machine.json currently uses post_assert.
    # If future assertion support is needed, implement a safe DSL (e.g. predicate
    # functions like assert_label_present) rather than eval.

    if $assert_failed; then
      _assert_attempt=$((_assert_attempt + 1))
      if [ "$_assert_attempt" -lt "$_assert_max" ]; then
        _log "META|assert|warn|retry ${_assert_attempt}/${_assert_max}: read-after-write lag — ${assert_details}"
        sleep 0.5
        continue
      fi
      local_details="trigger=${TRIGGER} expected_state=${NEW_STATE_NAME:-none} actual_state=${LIVE_STATE} ${assert_details}"
      echo "STATE_ASSERTION_FAILED: $local_details" >&2
      _log "META|assert|fail|${local_details}"
      hb_gate "assertion" "fail" "post-trigger assertion failed" "{\"trigger\":\"$TRIGGER\",\"detail\":\"${assert_details:0:60}\"}"
      exit 7
    else
      hb_gate "assertion" "ok" "post-trigger assertion passed" "{\"trigger\":\"$TRIGGER\"}"
      break
    fi
  done
fi

echo "$RESULT" | jq -c '.'
