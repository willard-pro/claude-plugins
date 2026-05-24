#!/usr/bin/env bash
# ticket-flow: deterministic Linear state/label executor.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${CLAUDE_SKILLS_LIB:-$HOME/.claude/skills/lib}"
source "$LIB_DIR/heartbeat.sh"
source "$LIB_DIR/linear-api.sh"

SM="$SCRIPT_DIR/state-machine.json"

usage() {
  echo "Usage: $0 <TICKET-ID> <TRIGGER> [--data key=value ...] [--dry-run]" >&2
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

mkdir -p "./logs"
exec 9>"./logs/.ticket-flow-${TICKET_ID}.lock"
if ! flock -n -E 42 9; then
  echo "ticket already in flight: $TICKET_ID" >&2
  exit 42
fi

# ── Parse optional flags ────────────────────────────────────────────────────

DRY_RUN=false
declare -A DATA=()
while [ $# -gt 0 ]; do
  case "$1" in
  --dry-run) DRY_RUN=true ;;
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
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|$1" >>"$LOG_FILE"
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
    "s/{complexity}/${DATA[complexity]:-simple}/g" \
    "s/{outcome}/${DATA[outcome]:-Smooth}/g")
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
CURRENT_LABEL_NAMES=$(echo "$ISSUE_JSON" | jq -r '[.labels.nodes[].name] | join(",")')
PROJECT_NAME=$(echo "$ISSUE_JSON" | jq -r '.project.name // empty')

TEAM_JSON=$(get_team "$TEAM_ID")

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

RESULT=$(update_issue "$TICKET_ID" "${NEW_STATE_ID:-}" "$LABEL_IDS_ARG" "${ASSIGNEE_ARG:-}" 2>&1)
SUCCESS=$(echo "$RESULT" | jq -r '.success // false')

if [ "$SUCCESS" != "true" ]; then
  echo "Update failed: $RESULT" >&2
  exit 2
fi

# ── Post-trigger state assertion ────────────────────────────────────────────
# Skip when idempotency path was taken (no mutation occurred)

if ! $IDEMPOTENT; then
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
    local_details="trigger=${TRIGGER} expected_state=${NEW_STATE_NAME:-none} actual_state=${LIVE_STATE} ${assert_details}"
    echo "STATE_ASSERTION_FAILED: $local_details" >&2
    _log "META|assert|fail|${local_details}"
    hb_gate "assertion" "fail" "post-trigger assertion failed" "{\"trigger\":\"$TRIGGER\",\"detail\":\"${assert_details:0:60}\"}"
    exit 7
  else
    hb_gate "assertion" "ok" "post-trigger assertion passed" "{\"trigger\":\"$TRIGGER\"}"
  fi
fi

echo "$RESULT" | jq -c '.'
