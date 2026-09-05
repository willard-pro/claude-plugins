#!/usr/bin/env bash
# Once-per-ticket preamble — everything ticket-auto Steps 0.1–0.6 establish
# before the first phase agent runs, as one deterministic entrypoint.
#
# Why this exists (design.md D17, task 4.10). fleetd dispatches *individual
# phases*. Every phase skill assumes an operating environment it never builds
# itself: an env file to source, a pipeline log with a schema line, a resolved
# branch decision, a validated Linear team. On the manual path the router's
# prose establishes all of it; on the automated path nothing did.
#
# It is bash and not Python for the reason D13 gave for the terminal marker:
# a second implementation is a second authority. The env-file grammar
# (spawn_write_env), the branch precedence chain (branch-resolve.sh), the
# gate-stop codes and the log line format already exist here. fleetd calls
# this; it does not restate it.
#
# Three decisions are embedded and are not mechanics:
#
#   * **Branch context is resolved once and thereafter rehydrated, never
#     re-resolved.** `META|branch-context` is the record. Re-running
#     resolve_branch_context on a restart re-reads the parent epic from
#     Linear, and an epic whose directive changed mid-ticket would silently
#     move the pipeline's target branch between two phases of one ticket —
#     half the work on one branch, half on another, with nothing in the log
#     saying so. A recorded decision is the decision.
#
#   * **Everything here is idempotent, because a fleetd restart mid-ticket
#     re-enters it.** The preamble is not "run at the start"; it is "run
#     before each dispatch, cheap and unchanging after the first". Every
#     write is either guarded by a grep for its own prior output or
#     regenerates a file byte-identically.
#
#   * **Preflight failure is fatal, prescan failure is not.** A rejected
#     Linear key means every flow.sh call in the ticket will fail one at a
#     time, deep inside phases; failing here costs one exit code instead.
#     Prescan is an optimisation and is deliberately not part of this file.
#
# -u (nounset) intentionally omitted, matching spawn-helper.sh: Claude Code
# shell snapshots inject ZSH_VERSION references that trip it.
set -eo pipefail

_TP_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# heartbeat.sh provides _plog, _iso_now, hb_* and cl_init. Guarded so a test
# harness can pre-load mocks.
if ! declare -f _plog >/dev/null 2>&1; then
  [ -f "$_TP_LIB_DIR/heartbeat.sh" ] && source "$_TP_LIB_DIR/heartbeat.sh"
fi

# ── Exit codes ────────────────────────────────────────────────────────────────
# Distinct per failure so fleetd routes on the code rather than on stderr text.
#
# 1 is deliberately left as the generic "called wrong" code that bash hands out
# for free, and it is deliberately NOT the gate-stop. Overloading 1 would make a
# caller's typo indistinguishable from a malformed branch directive — and the
# gate-stop is the one outcome here that writes a durable verdict onto a real
# ticket. The code that does that has to mean only that.
TP_USAGE=1 # bad arguments — a bug in the caller, not the ticket
TP_OK=0
TP_BRANCH_DIRECTIVE_INVALID=2 # gate-stop already written to the pipeline log
TP_BRANCH_RESOLVE_FAILED=3    # API error or malformed result — not a gate-stop
TP_LINEAR_CONFIG_INVALID=4    # team states/labels do not match the state machine
TP_LINEAR_AUTH_FAILED=5       # key unset or rejected
TP_ENV_WRITE_FAILED=6         # the env file could not be written — never spawn

# The project-context fields spawn_write_env carries and every phase reads.
# Order is the order they are emitted in; it has no other meaning.
_TP_CONTEXT_FIELDS="REPOS_ROOT ISSUE_PREFIX BE_SERVICES WIKI_ROOT BE_TEST_CMD BE_TEST_RUNNER FE_TEST_CMD LOCAL_URL UAT_URL SLACK_CHANNEL"

# ── Project context ───────────────────────────────────────────────────────────

# Read one project-context field. Precedence: process env → CLAUDE.md.
#
# Env first because fleetd's own configuration is the more specific statement:
# an operator who exported REPOS_ROOT for the daemon meant it for the tickets
# the daemon runs. The CLAUDE.md grammar (`KEY = value`, `KEY: value`, either
# side optionally backticked) is env-check.sh's find_in_claude_md, kept
# identical so /ticket-env-check and the preamble cannot disagree about what a
# project declares.
_tp_context_field() {
  local varname="$1" project_dir="${2:-$PWD}"

  local from_env="${!varname:-}"
  if [ -n "$from_env" ]; then
    printf '%s' "$from_env"
    return 0
  fi

  local claude_md="$project_dir/CLAUDE.md"
  [ -f "$claude_md" ] || return 0

  grep -oP '^`?'"$varname"'`?\s*[=:]\s*`?\K[^`]+' "$claude_md" 2>/dev/null |
    head -1 | sed 's/[[:space:]]*$//' || true
}

# Emit `KEY=value` lines for every project-context field.
# Usage: ticket_preamble_project_context [PROJECT_DIR]
ticket_preamble_project_context() {
  local project_dir="${1:-$PWD}" field value
  for field in $_TP_CONTEXT_FIELDS; do
    value="$(_tp_context_field "$field" "$project_dir")"
    printf '%s=%s\n' "$field" "$value"
  done
}

# ── Preflight ─────────────────────────────────────────────────────────────────

# Locate state-machine.json: monorepo layout first, then the installed skill,
# then the plugin cache. Same cascade validate-linear-config.sh is found by.
_tp_state_machine() {
  local cand
  for cand in \
    "$_TP_LIB_DIR/../skills/ticket-flow/state-machine.json" \
    "$HOME/.claude/skills/ticket-flow/state-machine.json"; do
    [ -f "$cand" ] && {
      printf '%s' "$cand"
      return 0
    }
  done
  find "$HOME/.claude/plugins/cache" -name state-machine.json \
    -path '*/ticket-flow/*' 2>/dev/null | sort | tail -1
}

_tp_validate_script() {
  local cand
  for cand in \
    "$_TP_LIB_DIR/../skills/ticket-flow/validate-linear-config.sh" \
    "$HOME/.claude/skills/ticket-flow/validate-linear-config.sh"; do
    [ -f "$cand" ] && {
      printf '%s' "$cand"
      return 0
    }
  done
  find "$HOME/.claude/plugins/cache" -name validate-linear-config.sh \
    -path '*/ticket-flow/*' 2>/dev/null | sort | tail -1
}

# Validate the Linear team config and the API key.
#
# The config check is sentinel-cached on the state machine's hash: it is a
# dozen API calls that can only change when state-machine.json does. The key
# check is not cached — a revoked token is exactly the kind of thing that
# changes between two runs, and it is one call.
#
# Usage: ticket_preamble_preflight
# Prints the resolved team id on stdout when it resolved one.
ticket_preamble_preflight() {
  local sentinel_dir="${TICKET_FLOW_STATE_DIR:-$HOME/.claude/state/ticket-flow}"
  local sm sm_hash team_id sentinel teams team_count me

  sm="$(_tp_state_machine)"
  [ -n "$sm" ] || {
    echo "preamble: state-machine.json not found" >&2
    return $TP_LINEAR_CONFIG_INVALID
  }
  sm_hash="$(sha256sum "$sm" | cut -d' ' -f1)"

  team_id="${LINEAR_TEAM_ID:-}"
  if [ -z "$team_id" ]; then
    teams="$(bash -c "source '$_TP_LIB_DIR/linear-api.sh'; linear_graphql '{\"query\":\"query{teams{nodes{id name}}}\"}'" 2>/dev/null || true)"
    team_count="$(echo "$teams" | jq '.data.teams.nodes | length' 2>/dev/null || true)"
    if ! [[ "$team_count" =~ ^[0-9]+$ ]]; then
      echo "preamble: Linear teams query failed — check LINEAR_API_KEY and connectivity" >&2
      return $TP_LINEAR_AUTH_FAILED
    fi
    if [ "$team_count" -ne 1 ]; then
      echo "preamble: $team_count Linear teams visible — set LINEAR_TEAM_ID" >&2
      return $TP_LINEAR_CONFIG_INVALID
    fi
    team_id="$(echo "$teams" | jq -r '.data.teams.nodes[0].id')"
  fi

  sentinel="$sentinel_dir/validated-${team_id}"
  if [ -f "$sentinel" ] && grep -q "^sm_hash=${sm_hash}$" "$sentinel" 2>/dev/null; then
    hb_gate "preflight" "ok" "sentinel valid, skipping config check" 2>/dev/null || true
  else
    local validate_sh
    validate_sh="$(_tp_validate_script)"
    [ -n "$validate_sh" ] || {
      echo "preamble: validate-linear-config.sh not found" >&2
      return $TP_LINEAR_CONFIG_INVALID
    }
    if ! bash "$validate_sh" "$team_id" >&2; then
      hb_gate "preflight" "fail" "Linear config validation failed" "{\"team_id\":\"$team_id\"}" 2>/dev/null || true
      return $TP_LINEAR_CONFIG_INVALID
    fi
    hb_gate "preflight" "ok" "Linear config validated" "{\"team_id\":\"$team_id\"}" 2>/dev/null || true
  fi

  if ! me="$(bash -c "source '$_TP_LIB_DIR/linear-api.sh'; get_me" 2>&1)"; then
    echo "preamble: Linear API key unset or rejected" >&2
    hb_gate "preflight" "fail" "Linear API key rejected" '{"exit_code":"4"}' 2>/dev/null || true
    return $TP_LINEAR_AUTH_FAILED
  fi
  hb_source "linear-auth" "ok" \
    "authenticated as $(echo "$me" | jq -r '.name // "unknown"' 2>/dev/null || echo unknown)" \
    2>/dev/null || true

  printf '%s' "$team_id"
}

# ── Branch context ────────────────────────────────────────────────────────────

# Read a field out of the recorded `META|branch-context` line.
#
# The grammar is append-only by construction — `base=…;integration=…;source=…;
# ticket=…;uat-policy=…;merge-policy=…`, each field added at the end — so a log
# written before a field existed still parses and simply yields empty for it.
# That is why this reads by key and never by position.
_tp_branch_field() {
  local log_file="$1" key="$2" line
  [ -f "$log_file" ] || return 0
  line="$(grep '^[^|]*|META|branch-context|info|' "$log_file" 2>/dev/null | tail -1 || true)"
  [ -n "$line" ] || return 0
  echo "${line#*|META|branch-context|info|}" | tr ';' '\n' |
    sed -n "s/^${key}=//p" | head -1
}

# ── The preamble itself ───────────────────────────────────────────────────────

# Usage:
#   ticket_preamble_run TICKET_ID=CRE-123 \
#     [AUTONOMY=auto] [FROM_PLANNED=true] [BRANCH_FLAG=epic/x] \
#     [PROJECT_DIR=/path] [LOGS_DIR=/path/logs] [SKIP_PREFLIGHT=true]
#
# Emits a TICKET_PREAMBLE_RESULT block on stdout. Every value fleetd needs for
# build_phase_spawn is in it, so the caller parses one block rather than
# re-deriving paths that this file already decided.
ticket_preamble_run() {
  local TICKET_ID="" AUTONOMY="" FROM_PLANNED="" BRANCH_FLAG=""
  local PROJECT_DIR="$PWD" LOGS_DIR="" SKIP_PREFLIGHT=""

  local arg
  for arg in "$@"; do
    case "$arg" in
    TICKET_ID=*) TICKET_ID="${arg#TICKET_ID=}" ;;
    AUTONOMY=*) AUTONOMY="${arg#AUTONOMY=}" ;;
    FROM_PLANNED=*) FROM_PLANNED="${arg#FROM_PLANNED=}" ;;
    BRANCH_FLAG=*) BRANCH_FLAG="${arg#BRANCH_FLAG=}" ;;
    PROJECT_DIR=*) PROJECT_DIR="${arg#PROJECT_DIR=}" ;;
    LOGS_DIR=*) LOGS_DIR="${arg#LOGS_DIR=}" ;;
    SKIP_PREFLIGHT=*) SKIP_PREFLIGHT="${arg#SKIP_PREFLIGHT=}" ;;
    *)
      echo "ticket_preamble_run: unknown parameter '$arg'" >&2
      return $TP_USAGE
      ;;
    esac
  done

  [ -n "$TICKET_ID" ] || {
    echo "ticket_preamble_run: TICKET_ID is required" >&2
    return $TP_USAGE
  }

  # Same three-tier precedence as SKILL.md Step 0.1 — caller → env → manual.
  # An unrecognised TICKET_AUTONOMY falls back rather than failing, because
  # `manual` is the safe reading of an ambiguous autonomy setting.
  if [ -z "$AUTONOMY" ]; then
    case "${TICKET_AUTONOMY:-}" in
    manual | auto | semi-auto) AUTONOMY="$TICKET_AUTONOMY" ;;
    *) AUTONOMY="manual" ;;
    esac
  fi
  case "$AUTONOMY" in
  manual | auto | semi-auto) ;;
  *)
    echo "ticket_preamble_run: unrecognised AUTONOMY '$AUTONOMY', using manual" >&2
    AUTONOMY="manual"
    ;;
  esac
  [ -n "$FROM_PLANNED" ] || FROM_PLANNED="false"

  LOGS_DIR="${LOGS_DIR:-$PROJECT_DIR/logs}"
  mkdir -p "$LOGS_DIR"
  local LOG_FILE="$LOGS_DIR/${TICKET_ID}-pipeline.log"
  local HB_LOG_FILE="$LOGS_DIR/${TICKET_ID}-heartbeat.log"
  local CLAUDE_LOG_FILE="$LOGS_DIR/${TICKET_ID}-claude.log"
  export HB_LOG_FILE CLAUDE_LOG_FILE

  # 0.1 — heartbeat first, so a preflight failure below leaves a trace.
  hb_init 2>/dev/null || true
  cl_init 2>/dev/null || true
  if ! grep -q '|heartbeat|pipeline-start|' "$HB_LOG_FILE" 2>/dev/null; then
    hb_heartbeat "pipeline-start" \
      "pipeline starting — autonomy=${AUTONOMY}, from-planned=${FROM_PLANNED}, ticket=${TICKET_ID}" \
      2>/dev/null || true
  fi
  if ! grep -q '|decision|autonomy-resolution|' "$HB_LOG_FILE" 2>/dev/null; then
    hb_decision "autonomy-resolution" "fired" "autonomy set to ${AUTONOMY}" \
      "{\"mode\":\"${AUTONOMY}\"}" 2>/dev/null || true
  fi

  # 0.4 — preflight.
  if [ "$SKIP_PREFLIGHT" != "true" ]; then
    local _pf_rc=0
    ticket_preamble_preflight >/dev/null || _pf_rc=$?
    [ "$_pf_rc" -eq 0 ] || return "$_pf_rc"
  fi

  # 0.6 (moved ahead of 0.5) — the log must exist and carry its schema line
  # before branch resolution, because a BRANCH_DIRECTIVE_INVALID gate-stop is
  # written *into* it. SKILL.md orders these the other way round and gets away
  # with it only because `>>` creates the file; a log whose first line is a
  # gate-stop reads to detect-resume.sh as a v0 log needing grace.
  touch "$LOG_FILE"
  if ! grep -q '^[^|]*|META|schema|info|' "$LOG_FILE" 2>/dev/null; then
    _plog "$LOG_FILE" "META" "schema" "info" "1"
  fi

  # 0.55 — run identity. No --new here: the router's own Step 0.6 is what
  # opens a new run once per process; this call site is the fleetd re-entry
  # path, invoked once per phase, so it must only rehydrate the open run
  # (run_identity_stamp's own guard makes every call but the first a no-op).
  source "$_TP_LIB_DIR/run-identity.sh"
  run_identity_stamp "$TICKET_ID" "$LOG_FILE" || true
  if [ "$SKIP_PREFLIGHT" != "true" ]; then
    run_identity_ticket_meta "$TICKET_ID" "$LOG_FILE" || true
  fi

  # 0.5a — branch context: rehydrate a recorded decision, resolve only once.
  local BASE_BRANCH INTEGRATION_BRANCH TICKET_BRANCH BRANCH_SOURCE
  local UAT_POLICY MERGE_POLICY BRANCH_ORIGIN
  BASE_BRANCH="$(_tp_branch_field "$LOG_FILE" base)"
  INTEGRATION_BRANCH="$(_tp_branch_field "$LOG_FILE" integration)"
  TICKET_BRANCH="$(_tp_branch_field "$LOG_FILE" ticket)"
  BRANCH_SOURCE="$(_tp_branch_field "$LOG_FILE" source)"
  UAT_POLICY="$(_tp_branch_field "$LOG_FILE" uat-policy)"
  MERGE_POLICY="$(_tp_branch_field "$LOG_FILE" merge-policy)"

  if [ -n "$BASE_BRANCH" ] || [ -n "$TICKET_BRANCH" ]; then
    BRANCH_ORIGIN="rehydrated"
  else
    BRANCH_ORIGIN="resolved"
    source "$_TP_LIB_DIR/branch-resolve.sh"

    local _br_out _br_rc=0
    if [ -n "$BRANCH_FLAG" ]; then
      _br_out="$(resolve_branch_context "$TICKET_ID" --branch "$BRANCH_FLAG" 2>&1)" || _br_rc=$?
    else
      _br_out="$(resolve_branch_context "$TICKET_ID" 2>&1)" || _br_rc=$?
    fi

    if [ "$_br_rc" -ne 0 ]; then
      if echo "$_br_out" | grep -q 'BRANCH_DIRECTIVE_INVALID'; then
        _plog "$LOG_FILE" "META" "gate-stop" "fail" "BRANCH_DIRECTIVE_INVALID"
        hb_gate "branch-context" "fail" "BRANCH_DIRECTIVE_INVALID" \
          "{\"ticket\":\"$TICKET_ID\"}" 2>/dev/null || true
        return $TP_BRANCH_DIRECTIVE_INVALID
      fi
      echo "$_br_out" >&2
      return $TP_BRANCH_RESOLVE_FAILED
    fi

    local _f
    for _f in TICKET_BRANCH BASE_BRANCH INTEGRATION_BRANCH BRANCH_SOURCE UAT_POLICY MERGE_POLICY; do
      printf -v "$_f" '%s' \
        "$(echo "$_br_out" | sed -n "s/^[[:space:]]*${_f}:[[:space:]]*//p" | head -1)"
    done

    # 0.5b — record the decision. This line is what every later re-entry reads
    # instead of asking Linear again.
    _plog "$LOG_FILE" "META" "branch-context" "info" \
      "base=${BASE_BRANCH};integration=${INTEGRATION_BRANCH};source=${BRANCH_SOURCE};ticket=${TICKET_BRANCH};uat-policy=${UAT_POLICY};merge-policy=${MERGE_POLICY}"
    hb_gate "branch-context" "ok" "branch decision recorded" \
      "{\"base\":\"${BASE_BRANCH}\",\"ticket\":\"${TICKET_BRANCH}\",\"source\":\"${BRANCH_SOURCE}\"}" \
      2>/dev/null || true
  fi

  # 0.5c — project context + env file. Rewritten on every entry, including
  # rehydrated ones: spawn_write_env is deterministic in its inputs, so a
  # re-run either produces the same file or repairs one a tmp sweep removed.
  local _ctx_line _k _v
  local -A _ctx=()
  while IFS= read -r _ctx_line; do
    _k="${_ctx_line%%=*}"
    _v="${_ctx_line#*=}"
    _ctx["$_k"]="$_v"
  done < <(ticket_preamble_project_context "$PROJECT_DIR")

  # A phase that starts without this file runs with no REPOS_ROOT and no
  # LINEAR_API_KEY and says nothing about it — the skill preamble sources it
  # with `|| true`. So the write is checked, and a failure returns a code that
  # means "do not spawn" rather than letting `set -e` collapse it into 1.
  source "$_TP_LIB_DIR/spawn-helper.sh"
  spawn_write_env \
    TICKET_ID="$TICKET_ID" \
    REPOS_ROOT="${_ctx[REPOS_ROOT]}" \
    ISSUE_PREFIX="${_ctx[ISSUE_PREFIX]}" \
    BE_SERVICES="${_ctx[BE_SERVICES]}" \
    WIKI_ROOT="${_ctx[WIKI_ROOT]}" \
    BE_TEST_CMD="${_ctx[BE_TEST_CMD]}" \
    BE_TEST_RUNNER="${_ctx[BE_TEST_RUNNER]}" \
    FE_TEST_CMD="${_ctx[FE_TEST_CMD]}" \
    LOCAL_URL="${_ctx[LOCAL_URL]}" \
    UAT_URL="${_ctx[UAT_URL]}" \
    SLACK_CHANNEL="${_ctx[SLACK_CHANNEL]}" \
    FROM_PLANNED="$FROM_PLANNED" \
    BASE_BRANCH="$BASE_BRANCH" \
    INTEGRATION_BRANCH="$INTEGRATION_BRANCH" \
    TICKET_BRANCH="$TICKET_BRANCH" \
    UAT_POLICY="$UAT_POLICY" \
    AUTONOMY="$AUTONOMY" \
    MERGE_POLICY="$MERGE_POLICY" >/dev/null || return $TP_ENV_WRITE_FAILED
  [ -s "/tmp/ticket-auto-${TICKET_ID}-env.sh" ] || return $TP_ENV_WRITE_FAILED

  # 0.6 tail — autonomy and provenance. A mode that differs from the recorded
  # one is logged as a change rather than overwritten: gate decisions already
  # taken under the old mode stay explicable.
  local _recorded
  _recorded="$(grep '^[^|]*|META|autonomy|info|' "$LOG_FILE" 2>/dev/null | tail -1 | cut -d'|' -f5- || true)"
  if [ -z "$_recorded" ]; then
    _plog "$LOG_FILE" "META" "autonomy" "info" "$AUTONOMY"
  elif [ "$_recorded" != "$AUTONOMY" ]; then
    _plog "$LOG_FILE" "META" "mode-change" "warn" "$AUTONOMY (was $_recorded)"
  fi
  if ! grep -q '^[^|]*|META|from-planned|' "$LOG_FILE" 2>/dev/null; then
    _plog "$LOG_FILE" "META" "from-planned" "info" "$FROM_PLANNED"
  fi

  cat <<EOF
TICKET_PREAMBLE_RESULT:
  TICKET_ID: $TICKET_ID
  ENV_FILE: /tmp/ticket-auto-${TICKET_ID}-env.sh
  LOG_FILE: $LOG_FILE
  HB_LOG_FILE: $HB_LOG_FILE
  CLAUDE_LOG_FILE: $CLAUDE_LOG_FILE
  AUTONOMY: $AUTONOMY
  FROM_PLANNED: $FROM_PLANNED
  BASE_BRANCH: $BASE_BRANCH
  INTEGRATION_BRANCH: $INTEGRATION_BRANCH
  TICKET_BRANCH: $TICKET_BRANCH
  BRANCH_SOURCE: $BRANCH_SOURCE
  BRANCH_ORIGIN: $BRANCH_ORIGIN
  UAT_POLICY: $UAT_POLICY
  MERGE_POLICY: $MERGE_POLICY
  REPOS_ROOT: ${_ctx[REPOS_ROOT]}
EOF
}

# Direct invocation: `bash ticket-preamble.sh TICKET_ID=CRE-123 …`.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  ticket_preamble_run "$@"
fi
