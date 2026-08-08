#!/usr/bin/env bash
# Shared agent spawn helpers. Source this file from the ticket-auto orchestrator.
# These functions handle the repeatable boilerplate around agent spawns —
# logging, heartbeat pinger, phase context file, and result capture.
# -u (nounset) intentionally omitted: Claude Code shell snapshots inject
# ZSH_VERSION references that trigger false-positive "unbound variable"
# errors in this bash version when nounset is active.
set -eo pipefail

# Source heartbeat library (provides _plog, _iso_now, hb_* and cl_write)
# unless already loaded (e.g. test mocks)
if ! declare -f _plog >/dev/null 2>&1; then
  _HB_LIB="$(dirname "${BASH_SOURCE[0]}")/heartbeat.sh"
  [ -f "$_HB_LIB" ] && source "$_HB_LIB"
fi

# ── State-directory resolution ──────────────────────────────────────────────────
# Resolve stop-file and progress-file paths consistently with
# fleet-controller/lib/config.sh so the worker watches the same directory the
# fleet controller writes to. Without this, the worker watches /tmp while
# fleet-intervene.sh writes to the workspace — cooperative kill never reaches
# the worker.
#
# Discovery order:
#   1. FLEET_STATE_DIR env var — explicit override, always wins
#   2. config.sh constructors — when fleet-controller is co-installed
#   3. /tmp — backward compatible with non-fleet-controller environments
#
# Usage: _worker_stop_file <type>
#   type: pinger | watchdog

# Discover and source config.sh for _fleet_stop_file constructor.
# Look relative to this script (monorepo), then installed plugin paths.
_worker_config_sh=""
for _w_cand in \
  "$(dirname "${BASH_SOURCE[0]}")/../../fleet-controller/lib/config.sh" \
  "$HOME/.claude/skills/fleet-controller/lib/config.sh" \
  "$HOME/.claude/plugins/fleet-controller/lib/config.sh"; do
  [ -f "$_w_cand" ] && {
    source "$_w_cand"
    _worker_config_sh="$_w_cand"
    break
  }
done

_worker_state_dir() {
  # Delegate to config.sh resolver when available — ensures the worker and
  # fleet controller agree on the state directory regardless of whether
  # FLEET_STATE_DIR is set. The resolver handles both explicit and default
  # cases, so FLEET_STATE_DIR unset resolves to the workspace, matching
  # what fleet-intervene.sh writes to.
  if [ -n "$_worker_config_sh" ] && declare -f _fleet_state_dir >/dev/null 2>&1; then
    _fleet_state_dir "${FLEET_PIPELINE_LOG_DIR:-./logs}"
  elif [ -n "${FLEET_STATE_DIR:-}" ]; then
    echo "$FLEET_STATE_DIR"
  else
    echo "/tmp"
  fi
}
_worker_stop_file() {
  local type="$1"
  # Always use the canonical constructor when config.sh is available — the
  # constructor handles FLEET_STATE_DIR set and unset cases identically to
  # fleet-intervene.sh. The prior guard required FLEET_STATE_DIR to be set,
  # which meant the worker watched /tmp while the fleet controller wrote to
  # the workspace under the default config — cooperative kill never reached
  # the worker.
  if [ -n "$_worker_config_sh" ] && declare -f _fleet_stop_file >/dev/null 2>&1; then
    _fleet_stop_file "$TICKET_ID" "$type" "${FLEET_PIPELINE_LOG_DIR:-./logs}"
  else
    echo "$(_worker_state_dir)/ticket-auto-${TICKET_ID}-${type}-stop"
  fi
}
_worker_progress_file() {
  local tid="${1:-${TICKET_ID:-}}"
  echo "$(_worker_state_dir)/ticket-auto-${tid}-progress.txt"
}

# ── Diagnostic ERR trap ────────────────────────────────────────────────────────────
# Logs crash location before exiting. Opt-in via SPAWN_DIAGNOSTICS=true to avoid
# log noise in normal operation. When a pipeline crashes at an agent-spawn boundary,
# enable this to capture the exact line and command that triggered the exit.
_spawn_err_trap() {
  local _rc=$?
  echo "SPAWN_CRASH: rc=${_rc} func=${FUNCNAME[1]:-toplevel} line=${BASH_LINENO[0]:-?} cmd=${BASH_COMMAND:-?}" >&2
  # Write crash marker to pipeline log when LOG_FILE is available
  if [ -n "${LOG_FILE:-}" ]; then
    _plog "$LOG_FILE" "META" "spawn-crash" "fail" "rc=${_rc} func=${FUNCNAME[1]:-toplevel} line=${BASH_LINENO[0]:-?}"
  fi
  exit "$_rc"
}
if [ "${SPAWN_DIAGNOSTICS:-false}" = "true" ]; then
  trap '_spawn_err_trap' ERR
fi

# ── spawn_write_env ──────────────────────────────────────────────────────────────
# Write extracted CLAUDE.md fields to /tmp/ticket-auto-{TICKET_ID}-env.sh using
# single-quote heredoc that prevents shell interpretation. Sub-agents source this
# file to get project context without reading CLAUDE.md independently.
#
# Usage: spawn_write_env TICKET_ID=<id> \
#          REPOS_ROOT=<path> ISSUE_PREFIX=<prefix> BE_SERVICES=<services> \
#          [WIKI_ROOT=<path>] [BE_TEST_CMD=<cmd>] [BE_TEST_RUNNER=<cmd>] [FE_TEST_CMD=<cmd>] \
#          [LOCAL_URL=<url>] [UAT_URL=<url>] [SLACK_CHANNEL=<channel>]
#          [BASE_BRANCH=<branch>] [INTEGRATION_BRANCH=<branch>] [TICKET_BRANCH=<branch>]
#          [WORKTREE_ROOT=<path>]
#
# Uses single-quote heredoc — no shell expansion, no injection risk.
spawn_write_env() {
  local TICKET_ID=""
  local REPOS_ROOT=""
  local ISSUE_PREFIX=""
  local BE_SERVICES=""
  local WIKI_ROOT=""
  local BE_TEST_CMD=""
  local BE_TEST_RUNNER=""
  local FE_TEST_CMD=""
  local LOCAL_URL=""
  local UAT_URL=""
  local SLACK_CHANNEL=""
  local BASE_BRANCH=""
  local INTEGRATION_BRANCH=""
  local TICKET_BRANCH=""
  local WORKTREE_ROOT=""

  # Parse named parameters
  for arg in "$@"; do
    case "$arg" in
    TICKET_ID=*) TICKET_ID="${arg#TICKET_ID=}" ;;
    REPOS_ROOT=*) REPOS_ROOT="${arg#REPOS_ROOT=}" ;;
    ISSUE_PREFIX=*) ISSUE_PREFIX="${arg#ISSUE_PREFIX=}" ;;
    BE_SERVICES=*) BE_SERVICES="${arg#BE_SERVICES=}" ;;
    WIKI_ROOT=*) WIKI_ROOT="${arg#WIKI_ROOT=}" ;;
    BE_TEST_CMD=*) BE_TEST_CMD="${arg#BE_TEST_CMD=}" ;;
    BE_TEST_RUNNER=*) BE_TEST_RUNNER="${arg#BE_TEST_RUNNER=}" ;;
    FE_TEST_CMD=*) FE_TEST_CMD="${arg#FE_TEST_CMD=}" ;;
    LOCAL_URL=*) LOCAL_URL="${arg#LOCAL_URL=}" ;;
    UAT_URL=*) UAT_URL="${arg#UAT_URL=}" ;;
    SLACK_CHANNEL=*) SLACK_CHANNEL="${arg#SLACK_CHANNEL=}" ;;
    BASE_BRANCH=*) BASE_BRANCH="${arg#BASE_BRANCH=}" ;;
    INTEGRATION_BRANCH=*) INTEGRATION_BRANCH="${arg#INTEGRATION_BRANCH=}" ;;
    TICKET_BRANCH=*) TICKET_BRANCH="${arg#TICKET_BRANCH=}" ;;
    WORKTREE_ROOT=*) WORKTREE_ROOT="${arg#WORKTREE_ROOT=}" ;;
    *)
      echo "spawn_write_env: unknown parameter '$arg'" >&2
      return 1
      ;;
    esac
  done

  if [ -z "$TICKET_ID" ]; then
    echo "spawn_write_env: TICKET_ID is required" >&2
    return 1
  fi

  local env_file="/tmp/ticket-auto-${TICKET_ID}-env.sh"

  # Single-quote heredoc — NO shell expansion, NO injection.
  # Even BE_TEST_CMD="mvn test -Dfoo=\"bar\"" is preserved exactly.
  cat >"$env_file" <<'ENVEOF'
#!/usr/bin/env bash
# Auto-generated by spawn-helper.sh — do not edit by hand.
# Sourced by --from-auto sub-agents to get project context without reading CLAUDE.md.
# Regenerated fresh each pipeline run by the orchestrator's Step 0.5.
export TICKET_ID="TICKET_ID_PLACEHOLDER"
export REPOS_ROOT="REPOS_ROOT_PLACEHOLDER"
export ISSUE_PREFIX="ISSUE_PREFIX_PLACEHOLDER"
export BE_SERVICES="BE_SERVICES_PLACEHOLDER"
export WIKI_ROOT="WIKI_ROOT_PLACEHOLDER"
export BE_TEST_CMD="BE_TEST_CMD_PLACEHOLDER"
export BE_TEST_RUNNER="BE_TEST_RUNNER_PLACEHOLDER"
export FE_TEST_CMD="FE_TEST_CMD_PLACEHOLDER"
export LOCAL_URL="LOCAL_URL_PLACEHOLDER"
export UAT_URL="UAT_URL_PLACEHOLDER"
export SLACK_CHANNEL="SLACK_CHANNEL_PLACEHOLDER"
export BASE_BRANCH="BASE_BRANCH_PLACEHOLDER"
export INTEGRATION_BRANCH="INTEGRATION_BRANCH_PLACEHOLDER"
export TICKET_BRANCH="TICKET_BRANCH_PLACEHOLDER"
export WORKTREE_ROOT="WORKTREE_ROOT_PLACEHOLDER"
ENVEOF

  # Sed-replace placeholders with actual values (escaped for sed)
  # Values may contain / & \ but sed delimiter is |, so only | needs escaping
  _sed_escape() { echo "$1" | sed 's/|/\\|/g'; }

  sed -i \
    -e "s|TICKET_ID_PLACEHOLDER|$(_sed_escape "$TICKET_ID")|" \
    -e "s|REPOS_ROOT_PLACEHOLDER|$(_sed_escape "$REPOS_ROOT")|" \
    -e "s|ISSUE_PREFIX_PLACEHOLDER|$(_sed_escape "$ISSUE_PREFIX")|" \
    -e "s|BE_SERVICES_PLACEHOLDER|$(_sed_escape "$BE_SERVICES")|" \
    -e "s|WIKI_ROOT_PLACEHOLDER|$(_sed_escape "$WIKI_ROOT")|" \
    -e "s|BE_TEST_CMD_PLACEHOLDER|$(_sed_escape "$BE_TEST_CMD")|" \
    -e "s|BE_TEST_RUNNER_PLACEHOLDER|$(_sed_escape "$BE_TEST_RUNNER")|" \
    -e "s|FE_TEST_CMD_PLACEHOLDER|$(_sed_escape "$FE_TEST_CMD")|" \
    -e "s|LOCAL_URL_PLACEHOLDER|$(_sed_escape "$LOCAL_URL")|" \
    -e "s|UAT_URL_PLACEHOLDER|$(_sed_escape "$UAT_URL")|" \
    -e "s|SLACK_CHANNEL_PLACEHOLDER|$(_sed_escape "$SLACK_CHANNEL")|" \
    -e "s|BASE_BRANCH_PLACEHOLDER|$(_sed_escape "$BASE_BRANCH")|" \
    -e "s|INTEGRATION_BRANCH_PLACEHOLDER|$(_sed_escape "$INTEGRATION_BRANCH")|" \
    -e "s|TICKET_BRANCH_PLACEHOLDER|$(_sed_escape "$TICKET_BRANCH")|" \
    -e "s|WORKTREE_ROOT_PLACEHOLDER|$(_sed_escape "$WORKTREE_ROOT")|" \
    "$env_file"

  # Auto-append LINEAR_API_KEY to env file when available
  if [ -n "${LINEAR_API_KEY:-}" ]; then
    echo "export LINEAR_API_KEY=\"${LINEAR_API_KEY}\"" >>"$env_file"
  fi

  # Restrict permissions — env file may contain credentials
  chmod 600 "$env_file"

  echo "spawn_write_env: wrote $env_file"

  return 0
}

# ── spawn_agent_pre ──────────────────────────────────────────────────────────────
# Pre-spawn boilerplate: writes the waiting log entry, starts the heartbeat pinger,
# and writes the phase context file. The orchestrator reads the printed "AGENT_PROMPT"
# line and spawns the agent with that prompt.
#
# Usage: spawn_agent_pre PHASE=<phase> STEP=<step> LOG_FILE=<path> \
#          HB_LOG_FILE=<path> CLAUDE_LOG_FILE=<path> TICKET_ID=<id> \
#          SKILL=<skill> [FLAGS=<flags>] [INSTRUCTIONS=<instructions>] \
#          [DESCRIPTION=<desc>] [FROM_STEP=<step>] [ATTEMPT=<int>]
#
# Prints to stdout:
#   AGENT_PROMPT=<the full agent spawn prompt>
# The orchestrator reads this and passes it to the Agent tool.
spawn_agent_pre() {
  local PHASE=""
  local STEP=""
  local LOG_FILE=""
  local HB_LOG_FILE=""
  local CLAUDE_LOG_FILE=""
  local TICKET_ID=""
  local SKILL=""
  local FLAGS="--from-auto"
  local INSTRUCTIONS="Follow the skill exactly. Report only the final handoff output."
  local DESCRIPTION=""
  local FROM_STEP=""
  # F10: Router-supplied attempt number for RL episode integrity.
  # The router owns counters (VERIFY_ATTEMPTS, ITERATION, etc.) and
  # injects the current attempt via this param. Agents read it from
  # spawn-meta instead of guessing.
  local ATTEMPT=""

  for arg in "$@"; do
    case "$arg" in
    PHASE=*) PHASE="${arg#PHASE=}" ;;
    STEP=*) STEP="${arg#STEP=}" ;;
    LOG_FILE=*) LOG_FILE="${arg#LOG_FILE=}" ;;
    HB_LOG_FILE=*) HB_LOG_FILE="${arg#HB_LOG_FILE=}" ;;
    CLAUDE_LOG_FILE=*) CLAUDE_LOG_FILE="${arg#CLAUDE_LOG_FILE=}" ;;
    TICKET_ID=*) TICKET_ID="${arg#TICKET_ID=}" ;;
    SKILL=*) SKILL="${arg#SKILL=}" ;;
    FLAGS=*) FLAGS="${arg#FLAGS=}" ;;
    INSTRUCTIONS=*) INSTRUCTIONS="${arg#INSTRUCTIONS=}" ;;
    DESCRIPTION=*) DESCRIPTION="${arg#DESCRIPTION=}" ;;
    FROM_STEP=*) FROM_STEP="${arg#FROM_STEP=}" ;;
    ATTEMPT=*) ATTEMPT="${arg#ATTEMPT=}" ;;
    *)
      echo "spawn_agent_pre: unknown parameter '$arg'" >&2
      return 1
      ;;
    esac
  done

  # Validate required params
  local missing=""
  [ -z "$PHASE" ] && missing="$missing PHASE"
  [ -z "$STEP" ] && missing="$missing STEP"
  [ -z "$TICKET_ID" ] && missing="$missing TICKET_ID"
  [ -z "$SKILL" ] && missing="$missing SKILL"
  if [ -n "$missing" ]; then
    echo "spawn_agent_pre: missing required parameters:$missing" >&2
    return 1
  fi

  # If FROM_STEP is set, append to FLAGS
  if [ -n "$FROM_STEP" ]; then
    FLAGS="$FLAGS --from-step $FROM_STEP"
  fi

  # F10 race-window guard: clear stale stop files from prior phases, then
  # check for external kill signals from the fleet controller.
  # spawn_agent_post() creates pinger and watchdog stop files during normal
  # cleanup (hb_pinger_stop, spawn_watchdog_stop). On the next phase, those
  # stale files would cause a false abort. Remove them first so only files
  # created AFTER this point (genuine fleet kills) trigger the guard.
  local _pinger_stop _watchdog_stop
  _pinger_stop=$(_worker_stop_file "pinger")
  _watchdog_stop=$(_worker_stop_file "watchdog")
  rm -f "$_pinger_stop" "$_watchdog_stop"
  # Yield to widen the race-window guard enough for fleet controller signals
  # to land. The fleet controller polls every 30s — 1ms is invisible to
  # pipeline throughput but makes the window testable.
  sleep 0.01 2>/dev/null || true
  if [ -f "$_pinger_stop" ]; then
    echo "spawn_agent_pre: spawn aborted — external kill detected for ${TICKET_ID}" >&2
    return 1
  fi

  local phase_lower phase_upper
  phase_lower=$(echo "$STEP" | tr '[:upper:]' '[:lower:]')
  # Normalize phase to uppercase for detect-resume.sh compatibility
  phase_upper=$(echo "$PHASE" | tr '[:lower:]' '[:upper:]')

  # 1. Write waiting log entry (idempotent: tail-check — allows retries after fail)
  if [ -n "$LOG_FILE" ]; then
    local last_line
    last_line=$(tail -1 "$LOG_FILE" 2>/dev/null || true)
    if echo "$last_line" | grep -q "|${PHASE}|${phase_lower}|waiting|"; then
      : # already written, skip (back-to-back duplicate)
    else
      local desc="${DESCRIPTION:-agent for ${TICKET_ID}}"
      _plog "$LOG_FILE" "$phase_upper" "$phase_lower" "waiting" "Agent launched — ${desc}"
    fi
  fi

  # 2. Start heartbeat pinger and watchdog
  local PINGER_PID=""
  local WATCHDOG_PID=""
  if [ -n "${HB_LOG_FILE:-}" ]; then
    local pinger_stop watchdog_stop
    pinger_stop=$(_worker_stop_file "pinger")
    watchdog_stop=$(_worker_stop_file "watchdog")
    export HB_LOG_FILE="$HB_LOG_FILE"
    hb_heartbeat "orchestrator-waiting" "agent ${phase_lower} launched"
    hb_pinger_start "$pinger_stop"
    PINGER_PID=$!
    spawn_watchdog_start "$watchdog_stop" "$PHASE" 60 "$TICKET_ID"
    WATCHDOG_PID=$!
  fi

  # 3. Write phase context file
  if [ -n "$LOG_FILE" ]; then
    echo "${PHASE}|${LOG_FILE}" >"/tmp/ticket-auto-${TICKET_ID}-ctx.txt"

    # 3b. Create empty agent progress file — agents write single-line status
    # updates here. The watchdog reads it each cycle for agent-progress heartbeats.
    : >"$(_worker_progress_file)"
  fi

  # 4. Write cl_write handoff
  if [ -n "${CLAUDE_LOG_FILE:-}" ]; then
    local from_info="${FROM_STEP:-fresh}"
    cl_write "$PHASE" "handoff" "info" "ticket=${TICKET_ID} from_step=${from_info}"
  fi

  # 5. Print the agent spawn prompt for the orchestrator to forward
  # Build the env-sourcing prefix. printf '%q' escapes shell metacharacters
  # in path values, preventing command injection if a path contains ";", $(), etc.
  local _q
  _q() { printf '%q' "$1"; }
  local env_prefix="export LOG_FILE=$(_q "${LOG_FILE}"); export HB_LOG_FILE=$(_q "${HB_LOG_FILE}"); export CLAUDE_LOG_FILE=$(_q "${CLAUDE_LOG_FILE}"); export HUSKY=0; source ~/.claude/skills/lib/heartbeat.sh; source /tmp/ticket-auto-$(_q "${TICKET_ID}")-env.sh"

  echo "AGENT_PROMPT=Run ${SKILL} ${TICKET_ID} ${FLAGS}. Before starting, run: ${env_prefix}. ${INSTRUCTIONS}"

  # 6. Store spawn metadata for spawn_agent_post
  local meta_file="/tmp/ticket-auto-${TICKET_ID}-spawn-meta.txt"
  cat >"$meta_file" <<EOF
PHASE=$PHASE
STEP=$STEP
TICKET_ID=$TICKET_ID
LOG_FILE=$LOG_FILE
HB_LOG_FILE=$HB_LOG_FILE
CLAUDE_LOG_FILE=$CLAUDE_LOG_FILE
PINGER_PID=$PINGER_PID
WATCHDOG_PID=$WATCHDOG_PID
EOF

  # F10: Append ATTEMPT to spawn-meta when router supplies it.
  # The router owns per-phase attempt counters (VERIFY_ATTEMPTS, ITERATION, etc.)
  # and injects the current attempt so agents don't guess.
  if [ -n "$ATTEMPT" ]; then
    echo "ATTEMPT=${ATTEMPT}" >>"$meta_file" || true
  fi

  # 6a. Append MODEL to spawn-meta file (Phase 0 RLVR — model identity recording)
  local model="${ANTHROPIC_MODEL:-unknown}"
  # F6: guard against unwritable /tmp or full disk — must not abort router spawn
  echo "MODEL=${model}" >>"$meta_file" || true

  # 6b. Write META|model|info to pipeline log (wrapped for set -e safety)
  local model_json
  model_json=$(printf '{"phase":"%s","model":"%s"}' "$PHASE" "$model")
  # F7: validate JSON with jq before appending — unescaped newlines or quotes
  # in ANTHROPIC_MODEL would inject forged log lines or produce malformed JSON
  if echo "$model_json" | jq -e . >/dev/null 2>&1; then
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|META|model|info|${model_json}" >>"$LOG_FILE" || true
  else
    # Fallback: escape the model value via jq -Rs, then embed in valid JSON
    local safe_model
    safe_model=$(printf '%s' "$model" | jq -Rs 'rtrimstr("\n")' 2>/dev/null || echo "\"unknown\"")
    model_json=$(printf '{"phase":"%s","model":%s}' "$PHASE" "$safe_model")
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|META|model|info|${model_json}" >>"$LOG_FILE" || true
  fi

  return 0
}

# ── spawn_agent_post ─────────────────────────────────────────────────────────────
# Post-spawn boilerplate: stops the heartbeat pinger and writes the done or fail
# log entry. Call this after the agent returns.
#
# Usage: spawn_agent_post TICKET_ID=<id> RESULT=<done|fail> [MSG=<message>] \
#          [VERDICT=<PASS|FAIL|OK|WARN|BLOCK>] \
#          [NEXT_PHASE=<phase>] [PHASE=<phase>] [STEP=<step>] \
#          [LOOP_BEARING=true]
#
# Or, after calling spawn_agent_pre, the metadata file is auto-read:
# Usage: spawn_agent_post TICKET_ID=<id> RESULT=<done|fail> [MSG=<message>] \
#          [NEXT_PHASE=<phase>]
#
# VERDICT is optional for non-loop phases. When set, it is prepended to MSG as
# a canonical token ("${VERDICT} — ${MSG}") so downstream consumers
# (detect-resume.sh) can grep the token instead of coupling to router free-text
# prose or emoji bytes.
#
# LOOP_BEARING=true marks this phase as participating in a router-managed retry
# loop (VERIFY, PR-REVIEW iterate/reconcile). When set, either VERDICT= must be
# supplied OR MSG= must contain "cycle#" — failing loudly if neither is present.
# This prevents the silent loop-counter freeze that occurs when the router LLM
# omits the free-text token.
spawn_agent_post() {
  local TICKET_ID=""
  local RESULT=""
  local MSG=""
  local VERDICT=""
  local NEXT_PHASE=""
  local LOOP_BEARING="false"
  local PHASE=""
  local STEP=""
  local LOG_FILE=""
  local HB_LOG_FILE=""
  local CLAUDE_LOG_FILE=""

  for arg in "$@"; do
    case "$arg" in
    TICKET_ID=*) TICKET_ID="${arg#TICKET_ID=}" ;;
    RESULT=*) RESULT="${arg#RESULT=}" ;;
    MSG=*) MSG="${arg#MSG=}" ;;
    VERDICT=*) VERDICT="${arg#VERDICT=}" ;;
    NEXT_PHASE=*) NEXT_PHASE="${arg#NEXT_PHASE=}" ;;
    PHASE=*) PHASE="${arg#PHASE=}" ;;
    STEP=*) STEP="${arg#STEP=}" ;;
    LOG_FILE=*) LOG_FILE="${arg#LOG_FILE=}" ;;
    HB_LOG_FILE=*) HB_LOG_FILE="${arg#HB_LOG_FILE=}" ;;
    CLAUDE_LOG_FILE=*) CLAUDE_LOG_FILE="${arg#CLAUDE_LOG_FILE=}" ;;
    LOOP_BEARING=*) LOOP_BEARING="${arg#LOOP_BEARING=}" ;;
    *)
      echo "spawn_agent_post: unknown parameter '$arg'" >&2
      return 1
      ;;
    esac
  done

  # Hard-require VERDICT= or cycle#N in MSG for loop-bearing phases.
  # The router's retry counters (VERIFY_ATTEMPTS, ITERATION, etc.) depend
  # on these tokens to advance. If the router LLM omits the token, the
  # counter silently freezes — defeating the 3-attempt safety cap.
  if [ "$LOOP_BEARING" = "true" ]; then
    if [ -z "$VERDICT" ] && ! echo "$MSG" | grep -q 'cycle#'; then
      echo "spawn_agent_post: LOOP_BEARING=true requires VERDICT=<token> or MSG containing 'cycle#'" >&2
      echo "  Phase: ${PHASE:-unknown}, Step: ${STEP:-unknown}" >&2
      echo "  This prevents silent loop-counter freeze from an omitted verdict token." >&2
      return 1
    fi
  fi

  case "$VERDICT" in
  "" | PASS | FAIL | OK | WARN | BLOCK) ;;
  *)
    echo "spawn_agent_post: VERDICT must be one of PASS|FAIL|OK|WARN|BLOCK, got '$VERDICT'" >&2
    return 1
    ;;
  esac

  # If metadata file exists and explicit params not given, read from it
  local meta_file="/tmp/ticket-auto-${TICKET_ID}-spawn-meta.txt"
  local PINGER_PID=""
  local WATCHDOG_PID=""
  if [ -f "$meta_file" ] && [ -z "$PHASE" ]; then
    while IFS='=' read -r key val; do
      case "$key" in
      PHASE) [ -z "$PHASE" ] && PHASE="$val" ;;
      STEP) [ -z "$STEP" ] && STEP="$val" ;;
      LOG_FILE) [ -z "$LOG_FILE" ] && LOG_FILE="$val" ;;
      HB_LOG_FILE) [ -z "$HB_LOG_FILE" ] && HB_LOG_FILE="$val" ;;
      CLAUDE_LOG_FILE) [ -z "$CLAUDE_LOG_FILE" ] && CLAUDE_LOG_FILE="$val" ;;
      PINGER_PID) [ -z "$PINGER_PID" ] && PINGER_PID="$val" ;;
      WATCHDOG_PID) [ -z "$WATCHDOG_PID" ] && WATCHDOG_PID="$val" ;;
      esac
    done <"$meta_file"
  fi

  if [ -z "$TICKET_ID" ] || [ -z "$RESULT" ]; then
    echo "spawn_agent_post: TICKET_ID and RESULT are required" >&2
    return 1
  fi

  local phase_lower="" phase_upper=""
  [ -n "${STEP:-}" ] && phase_lower=$(echo "${STEP:-}" | tr '[:upper:]' '[:lower:]')
  # Normalize phase to uppercase for detect-resume.sh compatibility
  [ -n "${PHASE:-}" ] && phase_upper=$(echo "${PHASE:-}" | tr '[:lower:]' '[:upper:]')
  phase_upper="${phase_upper:-UNKNOWN}"

  # Stop watchdog and heartbeat pinger
  if [ -n "${HB_LOG_FILE:-}" ]; then
    local watchdog_stop pinger_stop
    watchdog_stop=$(_worker_stop_file "watchdog")
    pinger_stop=$(_worker_stop_file "pinger")
    spawn_watchdog_stop "$watchdog_stop"
    hb_pinger_stop "$pinger_stop"

    # Truncate agent progress file — agent has returned
    : >"$(_worker_progress_file)"

    # Reap background processes — wait for captured PIDs to prevent zombie accumulation.
    # Handles stale PIDs (process already exited): wait on dead PID returns immediately
    # with exit 127, which is acceptable (non-fatal, logged to stderr only in debug).
    if [ -n "$PINGER_PID" ] || [ -n "$WATCHDOG_PID" ]; then
      local _pid _waited=0
      for _pid in "$PINGER_PID" "$WATCHDOG_PID"; do
        [ -z "$_pid" ] && continue
        # Guard: skip wait if process no longer exists, preventing
        # "[1]+ Exit 127" noise from waiting on dead PIDs.
        kill -0 "$_pid" 2>/dev/null || continue
        wait "$_pid" 2>/dev/null &
        local _wait_pid=$!
        # 5-second timeout per PID
        local _timeout=50
        while [ "$_timeout" -gt 0 ] && kill -0 "$_wait_pid" 2>/dev/null; do
          sleep 0.1
          _timeout=$((_timeout - 1))
        done
        kill -0 "$_wait_pid" 2>/dev/null && kill "$_wait_pid" 2>/dev/null || true
        _waited=1
      done
      # Suppress shell's "Terminated" messages for killed wait jobs
      [ "$_waited" -eq 1 ] && wait 2>/dev/null || true
    else
      # Fallback: no PID capture available — wait for any child with 5-second total timeout
      local _waited=0
      while [ "$_waited" -lt 50 ]; do
        wait -n 2>/dev/null && break || break
        _waited=$((_waited + 1))
        sleep 0.1
      done
    fi
  fi

  case "$RESULT" in
  done)
    local done_msg="${MSG:-agent done}"
    [ -n "$VERDICT" ] && done_msg="${VERDICT} — ${done_msg}"
    if [ -n "${LOG_FILE:-}" ]; then
      # Tail-scoped (not whole-file): a whole-file grep would suppress every
      # done line after the first for loop phases (pr-review iterate, verify
      # retry), where the same PHASE|STEP recurs across brackets. Matches the
      # pre-guard's tail-check semantics (see spawn_agent_pre above).
      local last_line
      last_line=$(tail -1 "${LOG_FILE}" 2>/dev/null || true)
      if echo "$last_line" | grep -q "|$phase_upper|${phase_lower:-unknown}|done|"; then
        : # already written, skip (back-to-back duplicate)
      else
        _plog "$LOG_FILE" "$phase_upper" "${phase_lower:-unknown}" "done" "${done_msg}"
      fi
    fi
    if [ -n "${HB_LOG_FILE:-}" ]; then
      hb_heartbeat "agent-returned" "${phase_lower:-agent} done — ${done_msg}"
      if [ -n "$NEXT_PHASE" ]; then
        hb_heartbeat "phase-transition" "${PHASE:-} → ${NEXT_PHASE}"
      fi
    fi
    if [ -n "${CLAUDE_LOG_FILE:-}" ]; then
      cl_write "$phase_upper" "${phase_lower:-unknown}" "done" "${done_msg}"
    fi
    ;;

  fail)
    local fail_msg="${MSG:-Agent failed}"
    [ -n "$VERDICT" ] && fail_msg="${VERDICT} — ${fail_msg}"
    local fail_action="${FAIL_ACTION:-stop}"
    local suffix=""
    [ "$fail_action" = "warn-continue" ] && suffix=" — continuing"

    if [ -n "${LOG_FILE:-}" ]; then
      local last_line
      last_line=$(tail -1 "${LOG_FILE}" 2>/dev/null || true)
      if echo "$last_line" | grep -q "|$phase_upper|${phase_lower:-unknown}|fail|"; then
        : # already written, skip (back-to-back duplicate)
      else
        _plog "$LOG_FILE" "$phase_upper" "${phase_lower:-unknown}" "fail" "${fail_msg}${suffix}"
      fi
    fi
    if [ -n "${HB_LOG_FILE:-}" ]; then
      hb_heartbeat "agent-returned" "${phase_lower:-agent} failed${suffix}"
    fi
    if [ -n "${CLAUDE_LOG_FILE:-}" ]; then
      local last_hb="unknown"
      [ -n "${HB_LOG_FILE:-}" ] && [ -f "$HB_LOG_FILE" ] && last_hb=$(tail -1 "$HB_LOG_FILE" 2>/dev/null | cut -d'|' -f2-4 || echo "unknown")
      cl_write "$phase_upper" "context" "fail" "${phase_lower:-agent} agent failed (${fail_action}) — last_hb: ${last_hb}"
      if [ "$fail_action" = "stop" ]; then
        cl_write RETRO hint info "sub-agent spawn failure in $phase_upper phase — check agent isolation, tool availability, and CLAUDE_LOG_FILE export for diagnostics"
      fi
    fi
    ;;

  *)
    echo "spawn_agent_post: RESULT must be 'done' or 'fail', got '$RESULT'" >&2
    return 1
    ;;
  esac

  # Meta file persists until next spawn_agent_pre overwrites it.
  # This allows duplicate spawn_agent_post calls to read PHASE/STEP
  # for idempotency guard tail-checks.

  return 0
}

# ── spawn_capture ────────────────────────────────────────────────────────────────
# Wrapper around capture_agent_result that reads metadata if available.
# Usage: spawn_capture TICKET_ID=<id> PHASE=<phase> RESULT="<agent output>"
spawn_capture() {
  # Source capture-transcript.sh if capture_agent_result is not already loaded.
  # spawn-helper.sh is sourced from multiple contexts; capture-transcript.sh may
  # not be in the calling chain. The guard prevents 22 exit-127 errors per run.
  if ! command -v capture_agent_result >/dev/null 2>&1; then
    source "${CLAUDE_SKILLS_LIB:-$HOME/.claude/skills/lib}/capture-transcript.sh" 2>/dev/null || true
  fi

  local TICKET_ID=""
  local PHASE=""
  local RESULT=""
  local ATTEMPT=""

  for arg in "$@"; do
    case "$arg" in
    TICKET_ID=*) TICKET_ID="${arg#TICKET_ID=}" ;;
    PHASE=*) PHASE="${arg#PHASE=}" ;;
    RESULT=*) RESULT="${arg#RESULT=}" ;;
    ATTEMPT=*) ATTEMPT="${arg#ATTEMPT=}" ;;
    *)
      echo "spawn_capture: unknown parameter '$arg'" >&2
      return 1
      ;;
    esac
  done

  if [ -z "$TICKET_ID" ] || [ -z "$PHASE" ]; then
    echo "spawn_capture: TICKET_ID and PHASE are required" >&2
    return 1
  fi

  if [ -n "${ATTEMPT:-}" ]; then
    capture_agent_result "$TICKET_ID" "$PHASE" "${RESULT:-}" "$ATTEMPT"
  else
    capture_agent_result "$TICKET_ID" "$PHASE" "${RESULT:-}"
  fi
}

# ── spawn_watchdog_start ─────────────────────────────────────────────────────────
# Backgrounds a watchdog heartbeat loop that emits hb_heartbeat entries every 60s
# while the orchestrator waits for a sub-agent. Uses a stop-file to signal shutdown.
#
# Usage: spawn_watchdog_start <stop_file> <phase_label> [sleep_secs=60] [ticket_id]
spawn_watchdog_start() {
  [ -z "${HB_LOG_FILE:-}" ] && return 0

  local stop_file="$1"
  local phase_label="${2:-unknown}"
  local sleep_secs="${3:-60}"
  local ticket_id="${4:-}"

  rm -f "$stop_file"

  (
    set +e
    while true; do
      sleep "$sleep_secs"
      [ -f "$stop_file" ] && break
      hb_heartbeat "watchdog" "alive" "waiting for ${phase_label} agent" || true
      # Read agent progress file — if non-empty, emit as agent-progress heartbeat
      if [ -n "$ticket_id" ]; then
        local prog_file
        prog_file=$(_worker_progress_file "$ticket_id")
        if [ -f "$prog_file" ] && [ -s "$prog_file" ]; then
          local prog_content
          prog_content=$(head -1 "$prog_file" 2>/dev/null || true)
          [ -n "$prog_content" ] && hb_heartbeat "agent-progress" "${prog_content}" || true
        fi
      fi
    done
  ) >/dev/null 2>&1 &
  disown
}

# ── spawn_watchdog_stop ──────────────────────────────────────────────────────────
# Stops the watchdog background process by creating its stop file.
# Args: stop_file
spawn_watchdog_stop() {
  [ -z "${HB_LOG_FILE:-}" ] && return 0
  touch "$1"
}
