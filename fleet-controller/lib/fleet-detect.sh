#!/usr/bin/env bash
# Fleet detection engine — parses pipeline and heartbeat logs to detect
# anomalies across all active pipelines. Each detector returns a severity code:
#   0 = ok (OBSERVE, log only)
#   1 = WARN (alert, no destructive action)
#   2 = KILL (stop background processes)
#   3 = KILL+RESTART (kill + respawn fresh pipeline)
#   4 = KILL severity but degraded to WARN (e.g., gate-stop non-retryable)
#
# NOTE: Does NOT set -euo pipefail — this is a sourceable library.
# Callers are responsible for shell flags.

# Source config for threshold defaults (but allow override via env)
_CONFIG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$_CONFIG_DIR/fleet-config.sh" ]; then
  source "$_CONFIG_DIR/fleet-config.sh"
fi

# Read-only access to the fleet state store. Every engine below prefers store
# rows to re-parsing the pipeline log, and falls back to the file when there is
# no store — which is the normal state on a host running the pipeline manually.
if [ -f "$_CONFIG_DIR/fleet-store.sh" ]; then
  source "$_CONFIG_DIR/fleet-store.sh"
fi

# ── Helpers ──────────────────────────────────────────────────────────────────────

# ── Pipeline-log input source ────────────────────────────────────────────────────
# The one seam through which every pipeline-log-driven engine reads. When the
# fleet state store is available the lines come from `log_events`, parsed once at
# ingest; otherwise they come from the file, exactly as before.
#
# Deliberately a single seam rather than a store-backed variant of each engine:
# two code paths per detector would double the surface that has to be kept in
# agreement, and the parity requirement — same findings, same severities — is
# only cheap to assert when the filtering logic is literally the same code.

# Emits `lineno:line`, the shape `grep -n` produces.
# Usage: _pipeline_rows <tid> [workspace]
_pipeline_rows() {
  local tid="$1"
  local workspace="${2:-${FLEET_PIPELINE_LOG_DIR:-./logs}}"

  if declare -f fleet_store_pipeline_rows >/dev/null 2>&1 &&
    declare -f fleet_store_ready >/dev/null 2>&1 &&
    fleet_store_ready "$workspace"; then
    local rows
    rows=$(fleet_store_pipeline_rows "$tid" "$workspace" 2>/dev/null || true)
    if [ -n "$rows" ]; then
      printf '%s\n' "$rows"
      return 0
    fi
  fi

  local log_file="${workspace}/${tid}-pipeline.log"
  [ -f "$log_file" ] || return 1
  command grep -n '' "$log_file" 2>/dev/null || true
}

# Emits the lines without their numbers.
# Usage: _pipeline_lines <tid> [workspace]
_pipeline_lines() {
  _pipeline_rows "$1" "${2:-}" | command sed 's/^[0-9]*://'
}

# True when this ticket has any pipeline history at all — the store-aware
# replacement for `[ -f "$log_file" ]`.
# Usage: _pipeline_has_history <tid> [workspace]
_pipeline_has_history() {
  local tid="$1"
  local workspace="${2:-${FLEET_PIPELINE_LOG_DIR:-./logs}}"
  [ -f "${workspace}/${tid}-pipeline.log" ] && return 0
  local first
  first=$(_pipeline_rows "$tid" "$workspace" | head -1)
  [ -n "$first" ]
}

# Age in seconds of the ticket's last pipeline entry; 999999 when there is none,
# matching _last_entry_age_secs.
# Usage: _pipeline_last_age_secs <tid> [workspace]
_pipeline_last_age_secs() {
  local tid="$1"
  local workspace="${2:-${FLEET_PIPELINE_LOG_DIR:-./logs}}"
  local last_iso
  last_iso=$(_pipeline_lines "$tid" "$workspace" | tail -1 | awk -F'|' '{print $1}')
  if [ -z "$last_iso" ]; then
    echo "999999"
    return
  fi
  local last_epoch now_epoch
  last_epoch=$(date -d "$last_iso" +%s 2>/dev/null || echo "0")
  now_epoch=$(date -u +%s)
  echo $((now_epoch - last_epoch))
}

# Get the age of the last log entry in seconds. Returns 999999 if no entries.
# Arg: log_file
_last_entry_age_secs() {
  local file="$1"
  if [ ! -f "$file" ] || [ ! -s "$file" ]; then
    echo "999999"
    return
  fi
  local last_iso
  last_iso=$(tail -1 "$file" | awk -F'|' '{print $1}')
  local last_epoch now_epoch
  last_epoch=$(date -d "$last_iso" +%s 2>/dev/null || echo "0")
  now_epoch=$(date -u +%s)
  echo $((now_epoch - last_epoch))
}

# Count occurrences of a pattern in a file. Returns 0 if file missing.
# Arg: file, grep_pattern
_count_in_file() {
  local file="$1"
  local pattern="$2"
  if [ ! -f "$file" ]; then
    echo "0"
    return
  fi
  command grep -c "$pattern" "$file" 2>/dev/null || true
}

# Extract a field from the last line of a file using awk -F'|'.
# Use awk (not cut -f5) to avoid truncation of pipe-containing message fields.
# Arg: file, field_index (must be 1-4; fields 5+ contain embedded pipes)
_last_field() {
  local file="$1"
  local idx="$2"
  if [ ! -f "$file" ] || [ ! -s "$file" ]; then
    echo ""
    return
  fi
  # Safety assertion: fields 5+ may contain pipe characters.
  # Use _last_msg to join fields 5 through NF instead.
  if [ "$idx" -ge 5 ]; then
    echo "_last_field: idx=${idx} would truncate pipe-containing fields; use _last_msg for field 5+" >&2
    return 1
  fi
  tail -1 "$file" | awk -F'|' -v n="$idx" '{print $n}'
}

# Extract message field (field 5+) from the last line of a file.
# Unlike cut -f5 (which silently truncates at the first pipe in the message),
# this joins fields 5 through NF with pipe delimiters, preserving full message
# content even when the MSG field contains pipe characters.
# Arg: file
_last_msg() {
  local file="$1"
  if [ ! -f "$file" ] || [ ! -s "$file" ]; then
    echo ""
    return
  fi
  tail -1 "$file" | awk -F'|' '{for(i=5;i<=NF;i++) printf "%s%s", $i, (i<NF?"|":"")}'
}

# Emits the log's last line, skipping any trailing run of `META|worker-exit`
# entries. fleetd's reap path appends `META|worker-exit|...` after a
# worker's own generation exits (fleet-controller/CLAUDE.md "Worker exit
# records") — an annotation of the exit, not a new pipeline state — so a
# genuinely completed pipeline's log ends with worker-exit as its literal
# last line once fleetd has reaped it. Any classifier that took the raw
# last line here would misclassify an already-terminal pipeline as
# incomplete on the very next call (e.g. a stale queue-consume check would
# stop skipping re-spawn of a finished ticket). Arg: file
_last_effective_line() {
  local file="$1"
  if [ ! -f "$file" ] || [ ! -s "$file" ]; then
    echo ""
    return
  fi
  tac "$file" | awk -F'|' '$3 != "worker-exit" {print; exit}'
}

# ── Outcome classification ──────────────────────────────────────────────────
# Pipeline-finalize.sh's tail-check guarantee means only the log's LAST line
# needs inspecting — a stale "held:"/"stopped:" outcome earlier in a
# crash-resumed log must never override a later, real resolution. "Last
# line" skips any trailing `META|worker-exit` entries for the same reason
# _last_effective_line does — fleetd appends one of those after reap, and it
# is an annotation of the exit, not a new pipeline state.

# Emits the pipeline's effective last line (trailing worker-exit entries
# skipped), or nothing when there is no history at all.
# Usage: _pipeline_last_effective_line <tid> [workspace]
_pipeline_last_effective_line() {
  local tid="$1"
  local workspace="${2:-${FLEET_PIPELINE_LOG_DIR:-./logs}}"
  _pipeline_lines "$tid" "$workspace" | tac | awk -F'|' '$3 != "worker-exit" {print; exit}'
}

# Emits the pipeline's last outcome message, or nothing when the effective
# last line is not an outcome entry (including "no history at all").
# Usage: _pipeline_last_outcome_msg <tid> [workspace]
_pipeline_last_outcome_msg() {
  local tid="$1"
  local workspace="${2:-${FLEET_PIPELINE_LOG_DIR:-./logs}}"
  local last
  last=$(_pipeline_last_effective_line "$tid" "$workspace")
  [ -z "$last" ] && return
  local step
  step=$(echo "$last" | awk -F'|' '{print $3}')
  [ "$step" = "outcome" ] || return
  echo "$last" | awk -F'|' '{for(i=5;i<=NF;i++) printf "%s%s", $i, (i<NF?"|":"")}'
}

# True only for a genuinely finished pipeline — completed, stopped
# (gate-stop/exhausted/exit/fleet-kill), or dead-lettered. False for a held
# ticket, which is waiting on a human, not the pipeline, and must stay
# visible to the sweep. A raw `META|outcome|` grep treated "held: gate" the
# same as "completed: STEP_6" and exempted every held ticket from all 11
# detectors — one sat unanswered for 160h with no alert.
# Usage: _pipeline_genuinely_terminal <tid> [workspace]
_pipeline_genuinely_terminal() {
  local tid="$1"
  local workspace="${2:-${FLEET_PIPELINE_LOG_DIR:-./logs}}"
  local last_step
  last_step=$(_pipeline_last_effective_line "$tid" "$workspace" | awk -F'|' '{print $3}')
  [ "$last_step" = "dead-letter" ] && return 0
  local msg
  msg=$(_pipeline_last_outcome_msg "$tid" "$workspace")
  [ -z "$msg" ] && return 1
  case "$msg" in
  "held: "*) return 1 ;;
  *) return 0 ;;
  esac
}

# True when the ticket's last outcome is a hold — waiting on a human, not
# terminal, but not "active" in the ordinary sense either: the router has
# already exited cleanly, so the 10 process-liveness detectors (stalls,
# zombies, loops, ...) would false-positive against it within minutes (no
# heartbeat, no open bracket — that IS what a clean hold looks like). Only
# detect_abandoned's held-aware branch should run for these.
# Usage: _pipeline_is_held <tid> [workspace]
_pipeline_is_held() {
  local tid="$1"
  local workspace="${2:-${FLEET_PIPELINE_LOG_DIR:-./logs}}"
  local msg
  msg=$(_pipeline_last_outcome_msg "$tid" "$workspace")
  case "$msg" in
  "held: "*) return 0 ;;
  *) return 1 ;;
  esac
}

# ── Detection functions ─────────────────────────────────────────────────────────
# Each takes (tid, workspace_dir) and prints severity to stdout.
# workspace_dir is optional — defaults to FLEET_PIPELINE_LOG_DIR, then ./logs.

# 1. Phase failure detection
detect_phase_failures() {
  local tid="$1"
  local workspace="${2:-${FLEET_PIPELINE_LOG_DIR:-./logs}}"

  if ! _pipeline_has_history "$tid" "$workspace"; then
    echo "0"
    return
  fi

  local severity=0
  local lines
  lines=$(_pipeline_lines "$tid" "$workspace")

  # Check for gate-stop codes first (separate classification)
  local gate_stop
  gate_stop=$(printf '%s\n' "$lines" | command grep '|META|gate-stop|fail|' 2>/dev/null | tail -1 || true)

  if [ -n "$gate_stop" ]; then
    local code
    code=$(echo "$gate_stop" | awk -F'|' '{print $5}')
    case "$code" in
    PR_REVIEW_VERDICT_UNPARSEABLE)
      echo "3" # agent flaked, retryable
      return
      ;;
    *)
      echo "1" # human must resolve
      return
      ;;
    esac
  fi

  # Check for general phase failures (non-MAINTENANCE, non-META)
  local phase_failures
  phase_failures=$(printf '%s\n' "$lines" | command grep -v '|MAINTENANCE|' | command grep -v '|META|' | command grep -c '|fail|' 2>/dev/null || true)

  if [ "$phase_failures" -gt 0 ]; then
    # First occurrence → WARN
    severity=1
  fi

  echo "$severity"
}

# ── Spawn-bracket state ──────────────────────────────────────────────────────────
# A bracket is "open" when the last |waiting| line in the pipeline log has no
# done/fail/skip terminal after it — i.e. the router has launched an agent and
# has not yet recorded its return. Scoped to lines *after* the waiting entry so
# a terminal from an earlier cycle of the same phase/step cannot mask it (the
# same position-scoping detect_zombies uses).
# Returns 0 (true) when a bracket is open.
# Prints `lineno|iso|phase|step` for the currently open spawn bracket and
# returns 0; returns 1 when no bracket is open. _spawn_bracket_open is the
# boolean form. Both callers need the same scan, and the runaway-call counter
# additionally needs the bracket's start timestamp to scope its count — one
# function so the two can never disagree about which bracket is open.
_spawn_bracket_info() {
  local tid="$1"
  local workspace="${2:-${FLEET_PIPELINE_LOG_DIR:-./logs}}"
  local rows
  rows=$(_pipeline_rows "$tid" "$workspace") || return 1
  [ -n "$rows" ] || return 1

  local last_waiting
  last_waiting=$(printf '%s\n' "$rows" | command grep '|waiting|' | tail -1 || true)
  [ -z "$last_waiting" ] && return 1

  local lineno="${last_waiting%%:*}"
  local line="${last_waiting#*:}"
  local iso phase step
  iso=$(echo "$line" | awk -F'|' '{print $1}')
  phase=$(echo "$line" | awk -F'|' '{print $2}')
  step=$(echo "$line" | awk -F'|' '{print $3}')

  # Scoped to rows *after* the waiting entry by line number rather than by
  # `tail -n +N`: with the store the row set can be a suffix of the file (old
  # projection rows pruned), and only the recorded line number is stable.
  local has_terminal
  has_terminal=$(printf '%s\n' "$rows" | awk -F: -v n="$lineno" '$1 > n' | command sed 's/^[0-9]*://' | command grep -E -c "\|${phase}\|${step}\|(done|fail|skip)\|" 2>/dev/null || true)
  has_terminal="${has_terminal:-0}"

  [ "$has_terminal" -eq 0 ] || return 1
  echo "${lineno}|${iso}|${phase}|${step}"
}

_spawn_bracket_open() {
  _spawn_bracket_info "$@" >/dev/null
}

# ── fleetd ownership ─────────────────────────────────────────────────────────────
# True when a fleetd run-registry entry exists for this ticket. run_all_detectors
# globs every *-pipeline.log in the workspace with no ownership gate, so a human
# running /ticket-auto by hand is measured by the same engines that drive
# fleet-intervene.sh's kills. The agent-activity signals are the ones most likely
# to fire on a human (reading output, thinking, exploring), so they are capped at
# WARN for tickets fleetd does not own. This is the file-based interim of the
# store-backed ownership scoping the fleet-state-store capability specifies.
# Returns 0 (true) when fleetd owns the ticket.
_fleet_owns_ticket() {
  local tid="$1"
  local workspace="${2:-${FLEET_PIPELINE_LOG_DIR:-./logs}}"
  local run_file=""

  # The store is the durable form of this question: it records ownership at
  # dispatch rather than inferring it from a file's existence.
  if declare -f fleet_store_ready >/dev/null 2>&1 && fleet_store_ready "$workspace"; then
    fleet_store_is_owned "$tid" "$workspace"
    return $?
  fi

  if declare -f _fleet_run_file >/dev/null 2>&1; then
    run_file=$(_fleet_run_file "$tid" "$workspace" 2>/dev/null || true)
  elif [ -n "${FLEET_STATE_DIR:-}" ]; then
    run_file="${FLEET_STATE_DIR}/${tid}-run.json"
  else
    run_file="${workspace}/${tid}-run.json"
  fi

  [ -n "$run_file" ] && [ -f "$run_file" ]
}

# ── Agent-activity liveness ──────────────────────────────────────────────────────
# Second, independent input to detect_stalls. The orchestrator watchdog's `alive`
# line proves the *router* is running; it says nothing about the agent the router
# is blocked on. The activity log (hooks/agent-activity.sh, one line per tool
# call) is the agent's own pulse — a fresh watchdog with a cold activity log is
# exactly the hung-agent case the heartbeat dimension cannot see.
#
# Only meaningful while a spawn bracket is open: between brackets the router is
# doing its own deterministic work and no agent is expected to be calling tools.
# Prints a severity (0-2).
_detect_activity_stall() {
  local tid="$1"
  local workspace="${2:-${FLEET_PIPELINE_LOG_DIR:-./logs}}"
  local act_log="${workspace}/${tid}-activity.log"

  # No activity log at all — the hook never resolved this ticket (an older
  # pipeline run, or a phase that made no tool calls yet). Contribute nothing
  # rather than guessing; the heartbeat dimension still applies.
  if [ ! -f "$act_log" ] || [ ! -s "$act_log" ]; then
    echo "0"
    return
  fi

  if ! _spawn_bracket_open "$tid" "$workspace"; then
    echo "0"
    return
  fi

  local warn_secs="${FLEET_ACTIVITY_WARN_SECS:-240}"
  local stale_secs="${FLEET_ACTIVITY_STALE_SECS:-900}"
  local age
  age=$(_last_entry_age_secs "$act_log")

  local severity=0
  if [ "$age" -ge "$stale_secs" ]; then
    severity=2
  elif [ "$age" -ge "$warn_secs" ]; then
    severity=1
  fi

  # Cap at WARN for work fleetd does not own — see _fleet_owns_ticket.
  if [ "$severity" -ge 2 ] && ! _fleet_owns_ticket "$tid" "$workspace"; then
    severity=1
  fi

  echo "$severity"
}

# ── Runaway tool-call rate ───────────────────────────────────────────────────────
# The mirror image of the activity-stall signal. A stalled agent stops calling
# tools; a runaway agent never stops — a retry loop, a search that keeps widening,
# an agent re-reading the same file. Both look identical to the orchestrator
# heartbeat, which only proves the router is alive.
#
# Counted per spawn bracket, not per log: the activity log spans the whole run, so
# a raw line count would flag any long ticket. The bracket's own `|waiting|`
# timestamp scopes the count to the current phase. Activity timestamps are
# fixed-width ISO-8601 UTC, so a lexicographic compare is a correct chronological
# compare and no date parsing is needed per line.
#
# Note the ceiling: hooks/agent-activity.sh ring-caps the activity log at
# FLEET_ACTIVITY_LOG_MAX_LINES (500). The count therefore saturates there, which
# is why the default threshold (300) sits below the cap — above it the signal
# would be unreachable.
#
# Prints a severity (0-1). WARN only, by design: a high call count is evidence of
# a possible problem, never proof of one, and severity >=2 drives real kills.
detect_runaway_calls() {
  local tid="$1"
  local workspace="${2:-${FLEET_PIPELINE_LOG_DIR:-./logs}}"
  local act_log="${workspace}/${tid}-activity.log"

  if [ ! -f "$act_log" ] || [ ! -s "$act_log" ]; then
    echo "0"
    return
  fi

  local info
  info=$(_spawn_bracket_info "$tid" "$workspace") || {
    echo "0"
    return
  }

  local start_iso
  start_iso=$(echo "$info" | awk -F'|' '{print $2}')
  if [ -z "$start_iso" ]; then
    echo "0"
    return
  fi

  local threshold="${FLEET_RUNAWAY_CALL_THRESHOLD:-300}"
  local count
  count=$(awk -F'|' -v s="$start_iso" '$1 >= s' "$act_log" 2>/dev/null | wc -l)
  count="${count:-0}"

  local severity=0
  [ "$count" -gt "$threshold" ] && severity=1

  # Ownership gate (task 9.5). Redundant while the ceiling is WARN, and kept
  # deliberately: if this signal is ever escalated to a kill severity, the gate
  # is already in place rather than being remembered at that moment. A human
  # exploring by hand trips a call-count threshold as naturally as an agent does.
  if [ "$severity" -ge 2 ] && ! _fleet_owns_ticket "$tid" "$workspace"; then
    severity=1
  fi

  echo "$severity"
}

# 2. Stall detection via stale heartbeats and stale agent activity
detect_stalls() {
  local tid="$1"
  local workspace="${2:-${FLEET_PIPELINE_LOG_DIR:-./logs}}"
  local hb_file="${workspace}/${tid}-heartbeat.log"

  # Activity dimension is independent of the heartbeat dimension: it is
  # computed even when there is no heartbeat log or no heartbeat entry, and the
  # final severity is the max of the two.
  local act_sev
  act_sev=$(_detect_activity_stall "$tid" "$workspace")

  if [ ! -f "$hb_file" ]; then
    echo "$act_sev"
    return
  fi

  # Find last orchestrator-waiting or watchdog|alive entry
  local last_hb
  last_hb=$(command grep -E '\|orchestrator-waiting\||\|watchdog\|alive\|' "$hb_file" 2>/dev/null | tail -1 || true)

  if [ -z "$last_hb" ]; then
    echo "$act_sev"
    return
  fi

  local last_iso
  last_iso=$(echo "$last_hb" | awk -F'|' '{print $1}')
  local last_epoch now_epoch
  last_epoch=$(date -d "$last_iso" +%s 2>/dev/null || echo "0")
  now_epoch=$(date -u +%s)
  local age=$((now_epoch - last_epoch))

  # Get pinger iteration count from last pinger entry
  local pinger_iter
  pinger_iter=$(command grep '|orchestrator-waiting|.*pinger ' "$hb_file" 2>/dev/null | tail -1 | awk -F'|' '{print $5}' | command grep -oP '\d+(?=/)' || echo "0")
  pinger_iter="${pinger_iter:-0}"

  # Default warn threshold is 600s, not 300s: background subagents are
  # waited for up to 10 minutes at exit (CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS),
  # so 300s false-positived on a worker that was legitimately still exiting
  # (worker-reap-recovery task 5.1). kill_secs/restart_secs must stay
  # strictly greater than warn_secs (task 5.3) — 900/1800 already hold.
  local severity=0
  local warn_secs="${FLEET_STALL_WARN_SECS:-600}"
  local kill_secs="${FLEET_STALL_KILL_SECS:-900}"
  local restart_secs="${FLEET_STALL_RESTART_SECS:-1800}"

  if [ "$age" -ge "$restart_secs" ]; then
    severity=3
  elif [ "$age" -ge "$kill_secs" ]; then
    severity=2
  elif [ "$age" -ge "$warn_secs" ]; then
    severity=1
  fi

  # Pinger exhaustion escalates one level
  if [ "$severity" -ge 1 ] && [ "${pinger_iter:-0}" -ge 80 ]; then
    severity=$((severity + 1))
    [ "$severity" -gt 3 ] && severity=3
  fi

  # A hung agent under a healthy router shows up here and nowhere else.
  [ "$act_sev" -gt "$severity" ] && severity="$act_sev"

  echo "$severity"
}

# 3. Zombie step detection — unresolved |waiting| entries
detect_zombies() {
  local tid="$1"
  local workspace="${2:-${FLEET_PIPELINE_LOG_DIR:-./logs}}"

  if ! _pipeline_has_history "$tid" "$workspace"; then
    echo "0"
    return
  fi

  local rows
  rows=$(_pipeline_rows "$tid" "$workspace" || true)

  # Find all |waiting| lines, with line numbers so the terminal search below
  # can be scoped to lines *after* each waiting entry.
  local lines
  lines=$(printf '%s\n' "$rows" | command grep '|waiting|' 2>/dev/null || true)

  if [ -z "$lines" ]; then
    echo "0"
    return
  fi

  local severity=0
  local now_epoch
  now_epoch=$(date -u +%s)
  local zombie_threshold="${FLEET_ZOMBIE_SECS:-900}"

  while IFS= read -r raw; do
    [ -z "$raw" ] && continue
    local lineno="${raw%%:*}"
    local line="${raw#*:}"
    local iso
    iso=$(echo "$line" | awk -F'|' '{print $1}')
    local phase
    phase=$(echo "$line" | awk -F'|' '{print $2}')
    local step
    step=$(echo "$line" | awk -F'|' '{print $3}')

    local line_epoch
    line_epoch=$(date -d "$iso" +%s 2>/dev/null || echo "0")
    local age=$((now_epoch - line_epoch))

    # Check if this waiting entry has a matching done/fail/skip *after* its
    # own line — a terminal line from an earlier cycle must not mask a
    # currently-stalled waiting entry for the same phase/step.
    local has_terminal
    has_terminal=$(printf '%s\n' "$rows" | awk -F: -v n="$lineno" '$1 > n' | command sed 's/^[0-9]*://' | command grep -E -c "\|${phase}\|${step}\|(done|fail|skip)\|" 2>/dev/null || true)
    has_terminal="${has_terminal:-0}"

    if [ "$has_terminal" -eq 0 ] && [ "$age" -ge "$zombie_threshold" ]; then
      severity=2 # KILL
      break
    elif [ "$has_terminal" -eq 0 ] && [ "$age" -ge "$((zombie_threshold / 2))" ]; then
      severity=1 # WARN
    fi
  done <<<"$lines"

  echo "$severity"
}

# 4. Loop detection via excessive retries
detect_loops() {
  local tid="$1"
  local workspace="${2:-${FLEET_PIPELINE_LOG_DIR:-./logs}}"
  local hb_file="${workspace}/${tid}-heartbeat.log"

  if [ ! -f "$hb_file" ]; then
    echo "0"
    return
  fi

  local severity=0

  # Check for terminal exhaustion gates first (these are KILL+RESTART)
  local exhaustion
  exhaustion=$(command grep -E '\|gate\|(verify-exhausted|iteration-exhausted|reverify-exhausted|combined-cap)\|' "$hb_file" 2>/dev/null | tail -1 || true)
  if [ -n "$exhaustion" ]; then
    echo "3"
    return
  fi

  # Count loop-back events by type
  local verify_loops
  verify_loops=$(command grep -c "decision|loop-back|fired|verify fail" "$hb_file" 2>/dev/null || true)
  local pr_loops
  pr_loops=$(command grep -c "decision|loop-back|fired|PR review" "$hb_file" 2>/dev/null || true)

  local max_verify="${MAX_VERIFY_ATTEMPTS:-3}"
  local max_pr="${MAX_PR_ITERATIONS:-3}"

  # Rogue loop: orchestrator exceeded its own caps without emitting exhaustion gate
  if [ "$verify_loops" -gt "$max_verify" ] || [ "$pr_loops" -gt "$max_pr" ]; then
    severity=3
  fi

  echo "$severity"
}

# 5. Abandonment detection — pipeline log exists but no genuine resolution
detect_abandoned() {
  local tid="$1"
  local workspace="${2:-${FLEET_PIPELINE_LOG_DIR:-./logs}}"

  if ! _pipeline_has_history "$tid" "$workspace"; then
    echo "0"
    return
  fi

  # Genuinely finished (completed/stopped/dead-lettered) — nothing left to
  # watch.
  if _pipeline_genuinely_terminal "$tid" "$workspace"; then
    echo "0"
    return
  fi

  local age
  age=$(_pipeline_last_age_secs "$tid" "$workspace")
  local warn_secs=$((${FLEET_ABANDON_WARN_HOURS:-1} * 3600))

  # A held ticket is waiting on a human, not abandoned by the pipeline — but
  # it can still go stale if nobody ever answers. Capped at WARN: unlike a
  # genuinely dead pipeline there is no process to kill, and restarting
  # would only spawn a duplicate worker while the same open question sits
  # unanswered.
  if _pipeline_is_held "$tid" "$workspace"; then
    if [ "$age" -ge "$warn_secs" ]; then
      echo "1"
    else
      echo "0"
    fi
    return
  fi

  local kill_secs=$((${FLEET_ABANDON_KILL_HOURS:-4} * 3600))

  if [ "$age" -ge "$kill_secs" ]; then
    echo "3"
  elif [ "$age" -ge "$warn_secs" ]; then
    echo "1"
  else
    echo "0"
  fi
}

# 5b. Human-hold visibility (human-hold-protocol) — a ticket parked waiting
# on a person. Log-only, one code path (the file's own rule against a
# detector that behaves differently depending on its caller): whether the
# invalid-record branch or the age branch fires depends entirely on what the
# log itself carries, not on who called this function or whether the ticket
# is currently classified held.
#
# Severity is capped at 1 — NEVER 2/3/4, for any hold age. In this codebase
# severity 2 is already an intervention (KILL: touch stop files, finalize the
# pipeline log). Applied to a held ticket that has no process to kill — the
# router exited cleanly when the agent asked — finalizing would write a
# terminal outcome *over* the `held:` outcome that is the hold's own audit
# record and the exact line both terminal classifiers key on, making the
# waiting ticket look finished to the very machinery that was just taught to
# recognise it. See human-hold-protocol design.md D6. Escalation for a
# long-unanswered hold lives in `fleet_notify_hold` instead, not here.
detect_human_hold() {
  local tid="$1"
  local workspace="${2:-${FLEET_PIPELINE_LOG_DIR:-./logs}}"

  if ! _pipeline_has_history "$tid" "$workspace"; then
    echo "0"
    return
  fi

  # An invalid (unparseable) human-hold request is visible regardless of
  # whether the ticket is currently held — a swallowed ask is the exact
  # defect this channel exists to fix, and a human resolves it directly. The
  # `parse_status` marker comes straight from the canonical JSON
  # `human-hold-parse.sh` already wrote; no re-parsing of agent prose here.
  local latest_hold_line
  latest_hold_line=$(_pipeline_lines "$tid" "$workspace" |
    command grep '|META|human-hold|waiting|' | tail -1)
  if [ -n "$latest_hold_line" ]; then
    case "$latest_hold_line" in
    *'"parse_status":"invalid"'*)
      echo "1"
      return
      ;;
    esac
  fi

  # Otherwise, a human hold is a log fact exactly like a gate hold: the
  # `held: human` outcome pipeline-finalize.sh writes for an unreleased
  # valid request.
  if ! _pipeline_is_held "$tid" "$workspace"; then
    echo "0"
    return
  fi

  local msg
  msg=$(_pipeline_last_outcome_msg "$tid" "$workspace")
  if [ "$msg" != "held: human" ]; then
    # Held for a different kind (e.g. `held: gate`) — not this detector's
    # concern; detect_abandoned's held-aware branch already covers it.
    echo "0"
    return
  fi

  local age warn_secs
  age=$(_pipeline_last_age_secs "$tid" "$workspace")
  warn_secs=$((${FLEET_HOLD_WARN_HOURS:-2} * 3600))

  if [ "$age" -ge "$warn_secs" ]; then
    echo "1"
  else
    echo "0"
  fi
}

# Observer findings (agent-observer Inc 4). WARN-only, by design — never
# escalates beyond severity 1, whatever a finding's own `sev=` says: the
# observer is non-authoritative under any configuration, and letting one of
# its findings drive a KILL/RESTART would make an advisory sidecar able to
# act on a ticket, exactly what design.md's Goals rule out. Scoped to the
# current open spawn bracket only — same `_spawn_bracket_info` convention
# `detect_runaway_calls` uses — so a finding from an earlier, already-closed
# phase is not repeatedly re-flagged on every later cycle.
detect_observer_findings() {
  local tid="$1"
  local workspace="${2:-${FLEET_PIPELINE_LOG_DIR:-./logs}}"

  if ! _pipeline_has_history "$tid" "$workspace"; then
    echo "0"
    return
  fi

  local info
  info=$(_spawn_bracket_info "$tid" "$workspace") || {
    echo "0"
    return
  }

  local start_iso
  start_iso=$(echo "$info" | awk -F'|' '{print $2}')
  if [ -z "$start_iso" ]; then
    echo "0"
    return
  fi

  local high_count
  high_count=$(_pipeline_lines "$tid" "$workspace" |
    awk -F'|' -v s="$start_iso" '$1 >= s' |
    command grep -c '|META|observer-finding|.*sev=HIGH' 2>/dev/null || true)
  high_count="${high_count:-0}"

  if [ "$high_count" -gt 0 ]; then
    echo "1"
  else
    echo "0"
  fi
}

# 6. Flow failure detection — scan heartbeat log for retry|flow-sh|fail entries
detect_flow_failures() {
  local tid="$1"
  local workspace="${2:-${FLEET_PIPELINE_LOG_DIR:-./logs}}"
  local hb_file="${workspace}/${tid}-heartbeat.log"

  if [ ! -f "$hb_file" ]; then
    echo "0"
    return
  fi

  local failures
  failures=$(command grep -c 'retry|flow-sh|fail' "$hb_file" 2>/dev/null || true)
  failures="${failures:-0}"

  if [ "$failures" -ge 2 ]; then
    echo "2" # KILL
  elif [ "$failures" -ge 1 ]; then
    echo "1" # WARN
  else
    echo "0"
  fi
}

# 7. Auto-mode block detection — scans pipeline log for check-approval|fail
#    entries and agent output logs for denial patterns.
#    Severity: 0 = none, 1 = WARN (1 block), 2 = KILL (2+ blocks).
detect_auto_mode_blocks() {
  local tid="$1"
  local workspace="${2:-${FLEET_PIPELINE_LOG_DIR:-./logs}}"

  if ! _pipeline_has_history "$tid" "$workspace"; then
    echo "0"
    return
  fi

  local block_count=0

  # Source 1: check-approval|fail entries in pipeline log
  local pipeline_blocks
  pipeline_blocks=$(_pipeline_lines "$tid" "$workspace" | command grep -c '|check-approval|fail|' 2>/dev/null || true)
  pipeline_blocks=$((pipeline_blocks + 0))
  block_count=$((block_count + pipeline_blocks))

  # Source 2: agent output logs for auto-mode denial patterns
  for agent_log in "${workspace}/${tid}"-*-agent.log; do
    [ -f "$agent_log" ] || continue
    local agent_blocks
    agent_blocks=$(command grep -c "Permission for this action was denied" "$agent_log" 2>/dev/null || true)
    agent_blocks=$((agent_blocks + 0))
    block_count=$((block_count + agent_blocks))
  done

  if [ "$block_count" -ge 2 ]; then
    echo "2"
  elif [ "$block_count" -ge 1 ]; then
    echo "1"
  else
    echo "0"
  fi
}

# 8. Tool error detection — scans {tid}-tool-errors.log for agent tool-call failures.
#    Deduplicates by TOOL_NAME+ERROR_TYPE within FLEET_TOOL_ERROR_WINDOW seconds.
#    Severity scales with distinct error count.
detect_tool_errors() {
  local tid="$1"
  local workspace="${2:-${FLEET_PIPELINE_LOG_DIR:-./logs}}"
  local err_file="${workspace}/${tid}-tool-errors.log"

  if [ ! -f "$err_file" ] || [ ! -s "$err_file" ]; then
    echo "0"
    return
  fi

  local unique_errors=0
  local prev_key="" prev_epoch=0
  local window="${FLEET_TOOL_ERROR_WINDOW:-300}"

  while IFS='|' read -r iso tool type phase msg; do
    [ -z "$iso" ] && continue
    # Skip corrupt lines: empty tool/type or unparseable date
    [ -z "$tool" ] || [ -z "$type" ] && continue
    local key="${tool}|${type}"
    local epoch
    epoch=$(date -d "$iso" +%s 2>/dev/null || echo "0")
    [ "$epoch" = "0" ] && continue

    if [ "$key" != "$prev_key" ] || [ $((epoch - prev_epoch)) -ge "$window" ]; then
      unique_errors=$((unique_errors + 1))
    fi
    prev_key="$key"
    prev_epoch="$epoch"
  done <"$err_file"

  if [ "$unique_errors" -ge 3 ]; then
    echo "2" # KILL — persistent failure pattern
  elif [ "$unique_errors" -ge 1 ]; then
    echo "1" # WARN — transient errors seen
  else
    echo "0"
  fi
}

# 9. Planner feedback detection — scan pipeline logs for META|planner-feedback
#    entries and check whether corresponding feedback files exist.
#    Severity: 0 = OBSERVE (none), 1 = WARN (uncollected feedback found).
detect_planner_feedback() {
  local tid="$1"
  local workspace="${2:-${FLEET_PIPELINE_LOG_DIR:-./logs}}"

  if ! _pipeline_has_history "$tid" "$workspace"; then
    echo "0"
    return
  fi

  # Find META|planner-feedback entries
  local fb_entries
  fb_entries=$(_pipeline_lines "$tid" "$workspace" | command grep '|META|planner-feedback|' 2>/dev/null || true)
  [ -z "$fb_entries" ] && echo "0" && return

  # For each feedback entry, check if this ticket's feedback has already
  # been collected. Feedback files at REPOS_ROOT/.ticket-auto/initiatives/*/feedback/*.json
  # carry a "source_tid" field — grep for this ticket's ID across all feedback files.
  local repos_root="${REPOS_ROOT:-}"
  local uncollected=0

  while IFS= read -r line; do
    [ -z "$line" ] && continue
    local fb_payload
    fb_payload=$(echo "$line" | awk -F'|' '{for(i=5;i<=NF;i++) printf "%s%s", $i, (i<NF?"|":"")}')
    [ -z "$fb_payload" ] && continue

    # Check whether this ticket's feedback has been collected.
    # Look for \"source_tid\":\"<tid>\" in any feedback JSON under the initiatives tree.
    local fb_found=0
    if [ -n "$repos_root" ] && [ -d "$repos_root/.ticket-auto/initiatives" ]; then
      if grep -rql "\"source_tid\":\"${tid}\"" "$repos_root/.ticket-auto/initiatives"/*/feedback/ 2>/dev/null; then
        fb_found=1
      fi
    fi

    [ "$fb_found" -eq 0 ] && uncollected=$((uncollected + 1))
  done <<<"$fb_entries"

  if [ "$uncollected" -gt 0 ]; then
    echo "1"
  else
    echo "0"
  fi
}

# 10. Blocked-by resolution detection — find tickets with blocked-by:{ID}
#     labels where the blocking ticket has reached Done state.
#     Fleet-wide detector: uses linear-api.sh to query ticket labels.
#     Severity: 0 = OBSERVE, 1 = WARN (unblocked tickets found).
detect_blocked_by() {
  local tid="$1"
  local workspace="${2:-${FLEET_PIPELINE_LOG_DIR:-./logs}}"
  local log_file="${workspace}/${tid}-pipeline.log"

  # This is primarily a fleet-wide detector — per-ticket invocation
  # checks whether THIS ticket has a blocked-by label and whether its
  # blocker is Done. The fleet-wide scan aggregates all.
  #
  # We need linear-api.sh for this check. If unavailable, return OBSERVE.
  if ! declare -f get_issue >/dev/null 2>&1; then
    local _la_paths=("$HOME/.claude/skills/lib/linear-api.sh" "${_CONFIG_DIR}/../linear-api.sh")
    for _lp in "${_la_paths[@]}"; do
      [ -f "$_lp" ] && source "$_lp" && break
    done
  fi

  # If linear-api.sh is still unavailable, return OBSERVE
  if ! declare -f get_issue >/dev/null 2>&1; then
    echo "0"
    return
  fi

  # Per-ticket: check if this ticket has blocked-by labels in its pipeline log
  # or check Linear for the ticket's labels
  if [ ! -f "$log_file" ]; then
    echo "0"
    return
  fi

  # Check if the ticket's pipeline log references blocked-by labels
  # We use the Linear API to get current label state
  local issue_json
  if ! issue_json=$(get_issue "$tid" 2>/dev/null); then
    echo "0"
    return
  fi

  # Extract labels from the issue JSON and check for blocked-by patterns
  local blocked_by_ids
  blocked_by_ids=$(echo "$issue_json" | jq -r '.labels.nodes[]?.name // empty' 2>/dev/null | grep -oP 'blocked-by:\K[A-Z]+-\d+' || true)

  if [ -z "$blocked_by_ids" ]; then
    echo "0"
    return
  fi

  # Check each blocker's state
  local unblocked_count=0
  while IFS= read -r blocker_id; do
    [ -z "$blocker_id" ] && continue
    local blocker_json
    if blocker_json=$(get_issue "$blocker_id" 2>/dev/null); then
      local blocker_state
      blocker_state=$(echo "$blocker_json" | jq -r '.state.name // empty' 2>/dev/null)
      [ "$blocker_state" = "Done" ] && unblocked_count=$((unblocked_count + 1))
    fi
  done <<<"$blocked_by_ids"

  if [ "$unblocked_count" -gt 0 ]; then
    echo "1"
  else
    echo "0"
  fi
}

# 11. Initiative dispatch detection — find epics with state:execution
#     label that have undispatched planned child tickets in Backlog.
#     Fleet-wide detector: uses linear-api.sh to query epics and children.
#     Severity: 0 = OBSERVE, 1 = WARN (undispatched tickets found).
detect_initiative_dispatch() {
  local tid="$1"
  local workspace="${2:-${FLEET_PIPELINE_LOG_DIR:-./logs}}"

  # This is a fleet-wide detector. Per-ticket invocation is a no-op —
  # the fleet-wide scan in fleet_detect_all runs it once separately.
  # However, for compatibility with the per-ticket loop, return 0.
  echo "0"
}

# Fleet-wide initiative dispatch scan. Runs once per fleet_detect_all call.
# Usage: _fleet_scan_initiative_dispatch [workspace]
# The workspace is threaded through to fleet_dispatch_initiative so the spawn
# queue resolves to the same durable path the daemon consumes
# ({state_dir}/fleet-{instance}-spawn-queue.jsonl) instead of a ./logs-relative
# path under the caller's CWD — auto-dispatched entries were otherwise written
# somewhere fleetd never reads.
_fleet_scan_initiative_dispatch() {
  local workspace="${1:-${FLEET_PIPELINE_LOG_DIR:-./logs}}"
  if ! declare -f get_issue >/dev/null 2>&1; then
    local _la_paths=("$HOME/.claude/skills/lib/linear-api.sh" "${_CONFIG_DIR}/../linear-api.sh")
    for _lp in "${_la_paths[@]}"; do
      [ -f "$_lp" ] && source "$_lp" && break
    done
  fi

  if ! declare -f get_issue >/dev/null 2>&1; then
    echo '{"severity":0,"findings":""}'
    return
  fi

  # Query Linear for epics with state:execution label.
  # Use GraphQL bulk query for efficiency (single round-trip vs N+1 get_issue calls).
  # Retry pattern matches linear-api.sh: 3 attempts with exponential backoff.
  # NOTE: no epic Linear-state filter — the state:execution label is the gate.
  # This matches fleet_dispatch_initiative's population exactly; a state filter
  # here made epics invisible to detection while still dispatchable.
  local query='{"query":"{issues(filter:{labels:{name:{eq:\\"state:execution\\"}}}){nodes{id identifier title children{nodes{id identifier state{name} labels{nodes{name}}}}}}}"}'

  local epics_json attempt=1 max_attempts=3 delay=1
  while [ "$attempt" -le "$max_attempts" ]; do
    epics_json=$(echo "$query" | curl -s -X POST "${LINEAR_API_URL:-https://api.linear.app/graphql}" \
      -H "Content-Type: application/json" \
      -H "Authorization: ${LINEAR_API_KEY}" \
      -d @- 2>/dev/null) && break
    attempt=$((attempt + 1))
    [ "$attempt" -le "$max_attempts" ] && sleep "$delay" && delay=$((delay * 2))
  done

  if [ -z "$epics_json" ]; then
    echo '{"severity":0,"findings":""}'
    return
  fi

  local undispatched=0
  local initiative_ids=""

  # Extract epics and check children
  local epic_count
  epic_count=$(echo "$epics_json" | jq -r '.data.issues.nodes | length // 0' 2>/dev/null)
  [ "${epic_count:-0}" -eq 0 ] && echo '{"severity":0,"findings":""}' && return

  for i in $(seq 0 $((epic_count - 1))); do
    local epic_id epic_identifier
    epic_id=$(echo "$epics_json" | jq -r ".data.issues.nodes[$i].identifier // empty" 2>/dev/null)
    [ -z "$epic_id" ] && continue

    # Check child tickets
    local child_count
    child_count=$(echo "$epics_json" | jq -r ".data.issues.nodes[$i].children.nodes | length // 0" 2>/dev/null)
    [ "${child_count:-0}" -eq 0 ] && continue

    local epic_undispatched=0
    for j in $(seq 0 $((child_count - 1))); do
      local child_state child_labels child_id
      child_state=$(echo "$epics_json" | jq -r ".data.issues.nodes[$i].children.nodes[$j].state.name // empty" 2>/dev/null)
      child_labels=$(echo "$epics_json" | jq -r ".data.issues.nodes[$i].children.nodes[$j].labels.nodes[].name // empty" 2>/dev/null)
      child_id=$(echo "$epics_json" | jq -r ".data.issues.nodes[$i].children.nodes[$j].identifier // empty" 2>/dev/null)

      # Check for planned label + Backlog state
      if [ "$child_state" = "Backlog" ] && echo "$child_labels" | grep -q "planned" 2>/dev/null; then
        epic_undispatched=$((epic_undispatched + 1))
      fi
    done

    if [ "$epic_undispatched" -gt 0 ]; then
      undispatched=$((undispatched + epic_undispatched))
      local stop_note=""
      if [ -f "$(_fleet_epic_stop_file "$workspace" "$epic_id")" ]; then
        stop_note=" (stopped: stop-${epic_id}.json present)"
      fi
      initiative_ids="${initiative_ids} ${epic_id}(${epic_undispatched})${stop_note}"
    fi
  done

  local findings
  findings=$(echo "$initiative_ids" | sed 's/^ //')

  if [ "$undispatched" -gt 0 ]; then
    echo "{\"severity\":1,\"findings\":\"${undispatched} undispatched: ${findings}\"}"

    # Auto-dispatch: when FLEET_AUTO_DISPATCH=true, call fleet_dispatch_initiative
    # for each initiative with undispatched planned children.
    # The human approval gate still stops every ticket — this automates dispatch,
    # not approval.
    if [ "${FLEET_AUTO_DISPATCH}" = "true" ]; then
      # Source fleet-dispatch.sh if not already available
      if ! declare -f fleet_dispatch_initiative >/dev/null 2>&1; then
        local _dispatch_lib="${_CONFIG_DIR}/fleet-dispatch.sh"
        [ -f "$_dispatch_lib" ] && source "$_dispatch_lib"
      fi

      if declare -f fleet_dispatch_initiative >/dev/null 2>&1; then
        for epic_id in $initiative_ids; do
          # Strip the count suffix: "INIT-42(3)" → "INIT-42"
          local clean_id="${epic_id%(*}"
          if [ "${FLEET_DRY_RUN:-false}" = "true" ]; then
            echo "[FLEET_AUTO_DISPATCH] would dispatch initiative: ${clean_id}" >&2
          else
            fleet_dispatch_initiative "$clean_id" "${workspace:-}" 2>&1 | while IFS= read -r dispatch_msg; do
              echo "[FLEET_AUTO_DISPATCH] ${clean_id}: ${dispatch_msg}" >&2
            done
          fi
        done
      else
        echo "[FLEET_AUTO_DISPATCH] WARNING: fleet_dispatch_initiative not available — cannot auto-dispatch" >&2
      fi
    fi
  else
    echo '{"severity":0,"findings":""}'
  fi
}

# ── D-12: Epic branch readiness ────────────────────────────────────────────────────
# Per-ticket stub — fleet-wide scan in fleet_detect_all runs it once separately.
detect_epic_branch_ready() {
  echo "0"
}

# _fleet_advance_epic_state <EPIC_ID> [children_json]
# Fires epic-integration-open once for the epic, moving it to Review.
#
# Called only when at least one integration PR has been observed open. Readiness
# is re-confirmed first: the readiness that admitted this epic was computed from
# a snapshot taken before a repo loop that may run for a long time, during which
# a child must be assumed capable of regressing out of Done.
#
# All output is redirected. This runs inside the detector, whose stdout is
# captured by command substitution to build its JSON result.
_fleet_advance_epic_state() {
  local epic_id="$1"
  local children_json="${2:-}"

  # 1. Re-confirm readiness against fresh data (no cached children here — the
  #    whole point is to catch a child that regressed during the loop).
  if declare -f epic_branch_children_done >/dev/null 2>&1; then
    if ! epic_branch_children_done "$epic_id" >/dev/null 2>&1; then
      return 0
    fi
  fi

  # 2. Locate the flow executor — monorepo checkout first, then the installed
  #    plugin layout.
  local _flow_sh=""
  local _cand
  for _cand in \
    "${_CONFIG_DIR}/../../ticket-auto-pipeline/skills/ticket-flow/flow.sh" \
    "$HOME/.claude/skills/ticket-flow/flow.sh"; do
    if [ -f "$_cand" ]; then
      _flow_sh="$_cand"
      break
    fi
  done
  [ -n "$_flow_sh" ] || return 0

  # 3. Fire once. Exit 42 is flow.sh's in-flight lock: an operator or another
  #    process is mid-mutation on this same epic. That is contention, not
  #    failure — treat it as benign and let the next cycle settle it.
  local _rc=0
  bash "$_flow_sh" "$epic_id" epic-integration-open >/dev/null 2>&1 || _rc=$?
  case "$_rc" in
  0 | 42) return 0 ;;
  *) return 0 ;;
  esac
}

# Fleet-wide epic branch readiness scan. Runs once per fleet_detect_all call.
# Checks state:execution epics with Branch Directives: are all children Done?
# Usage: _fleet_scan_epic_branch_ready <workspace>
_fleet_scan_epic_branch_ready() {
  local workspace="${1:-${FLEET_PIPELINE_LOG_DIR:-./logs}}"

  # Ensure linear-api.sh and epic-branch deps are available
  if ! declare -f get_issue >/dev/null 2>&1; then
    local _la_paths=("$HOME/.claude/skills/lib/linear-api.sh" "${_CONFIG_DIR}/../linear-api.sh")
    for _lp in "${_la_paths[@]}"; do
      [ -f "$_lp" ] && source "$_lp" && break
    done
  fi

  if ! declare -f get_issue >/dev/null 2>&1; then
    echo '{"severity":0,"findings":""}'
    return
  fi

  # Source epic branch deps if available. Two candidate locations — the
  # monorepo checkout (../../) and the installed plugin layout where the
  # ticket-auto-pipeline SessionStart hook syncs libs to ~/.claude/skills/lib.
  # Without the second, D-12 silently never fires in installed deployments.
  local _tap_lib
  for _tap_lib in "${_CONFIG_DIR}/../../ticket-auto-pipeline/lib" "$HOME/.claude/skills/lib"; do
    if ! declare -f _parse_directive >/dev/null 2>&1; then
      [ -f "$_tap_lib/planned-ticket-check.sh" ] && source "$_tap_lib/planned-ticket-check.sh"
      [ -f "$_tap_lib/branch-directive-check.sh" ] && source "$_tap_lib/branch-directive-check.sh"
    fi
    if ! declare -f epic_branch_children_done >/dev/null 2>&1; then
      [ -f "$_tap_lib/epic-branch.sh" ] && source "$_tap_lib/epic-branch.sh"
    fi
    if declare -f epic_branch_children_done >/dev/null 2>&1; then
      break
    fi
  done
  # Fail loud, not silently: an un-sourceable helper must not degrade to
  # "never ready" (which reads as healthy-but-idle).
  if ! declare -f epic_branch_children_done >/dev/null 2>&1; then
    echo '{"severity":0,"findings":"epic-branch.sh not sourceable"}' >&2
    return
  fi
  # Repo enumeration must match dispatch's — source the shared helper.
  if ! declare -f _fleet_repos_under_root >/dev/null 2>&1; then
    local _dispatch_lib="${_CONFIG_DIR}/fleet-dispatch.sh"
    [ -f "$_dispatch_lib" ] && source "$_dispatch_lib"
  fi

  # Query epics with state:execution label — include description and children.
  # No epic Linear-state filter: the label is the gate, matching the dispatch
  # population (see the same note on the D-11 query).
  # The epic's own state{name} is added to the query the detector already
  # issues, so the idempotency short-circuit below costs no extra request.
  local query='{"query":"{issues(filter:{labels:{name:{eq:\\\"state:execution\\\"}}}){nodes{id identifier title description state{name} children{nodes{id identifier state{name} labels{nodes{name}}}}}}}"}'

  local epics_json attempt=1 max_attempts=3 delay=1
  while [ "$attempt" -le "$max_attempts" ]; do
    epics_json=$(echo "$query" | curl -s -X POST "${LINEAR_API_URL:-https://api.linear.app/graphql}" \
      -H "Content-Type: application/json" \
      -H "Authorization: ${LINEAR_API_KEY}" \
      -d @- 2>/dev/null) && break
    attempt=$((attempt + 1))
    [ "$attempt" -le "$max_attempts" ] && sleep "$delay" && delay=$((delay * 2))
  done

  if [ -z "$epics_json" ]; then
    echo '{"severity":0,"findings":""}'
    return
  fi

  local ready_count=0
  local ready_ids=""

  local epic_count
  epic_count=$(echo "$epics_json" | jq -r '.data.issues.nodes | length // 0' 2>/dev/null)
  [ "${epic_count:-0}" -eq 0 ] && echo '{"severity":0,"findings":""}' && return

  for i in $(seq 0 $((epic_count - 1))); do
    local epic_id epic_description epic_state
    epic_id=$(echo "$epics_json" | jq -r ".data.issues.nodes[$i].identifier // empty" 2>/dev/null)
    epic_description=$(echo "$epics_json" | jq -r ".data.issues.nodes[$i].description // \"\"" 2>/dev/null)
    epic_state=$(echo "$epics_json" | jq -r ".data.issues.nodes[$i].state.name // \"\"" 2>/dev/null)
    [ -z "$epic_id" ] && continue

    # Idempotency short-circuit — BEFORE any per-repository work.
    #
    # Two jobs in one guard. It stops the detector dragging an epic that an
    # operator (or a previous cycle) already advanced back to an earlier state,
    # which on a short cycle would otherwise repeat indefinitely. And because
    # the state:execution label that admits an epic to this population is never
    # removed, it is also what stops a finished epic being rescanned — including
    # its whole repo loop — on every cycle forever.
    case "$epic_state" in
    Review | UAT | Done)
      continue
      ;;
    esac

    # Check for Branch Directive — skip epics without one
    if ! echo "$epic_description" | grep -q "Branch Directive" 2>/dev/null; then
      continue
    fi

    # Validate directive
    if ! declare -f check_branch_directive_description >/dev/null 2>&1; then
      # Without the validator, check the description for a directive block
      if ! echo "$epic_description" | command grep -q '^\*\*Branch:\*\*' 2>/dev/null; then
        continue
      fi
    fi

    # Readiness is delegated to the single canonical children-done helper —
    # no independent inline evaluation (duplicated checks have drifted before).
    # The helper consumes JSONL (one child object per line), matching the
    # jq -c '.children[] // empty' stream its own fetch path produces.
    local children_nodes
    children_nodes=$(echo "$epics_json" | jq -c ".data.issues.nodes[$i].children.nodes[] // empty" 2>/dev/null)

    if epic_branch_children_done "$epic_id" "$children_nodes"; then
      ready_count=$((ready_count + 1))
      ready_ids="${ready_ids} ${epic_id}"

      # Actuation: once ready, open the integration PR in every repository the
      # epic branch was created in (same repo set dispatch iterated — the
      # shared helper, not a re-guess). epic_branch_open_pr is idempotent
      # (existing-PR check) and never merges; it is only called when
      # FLEET_EPIC_AUTO_PR is enabled, matching the detector's opt-in convention.
      if [ "${FLEET_EPIC_AUTO_PR:-false}" = "true" ] && declare -f epic_branch_open_pr >/dev/null 2>&1; then
        local _ebr_repo
        local _ebr_pr_open=false
        while IFS= read -r _ebr_repo; do
          [ -z "$_ebr_repo" ] && continue
          # stdout MUST be redirected as well as stderr: this function's
          # stdout is captured by command substitution to build the detector's
          # JSON result, so any prose the PR helper prints would corrupt it.
          #
          # children_nodes and epic_description are passed in: both were fetched
          # once for this scan, and re-fetching them per repository multiplies
          # Linear requests by the repo count on every cycle.
          epic_branch_open_pr "$epic_id" "$_ebr_repo" "$children_nodes" "$epic_description" >/dev/null 2>&1 || true
          # Loop completion proves nothing — the helper returns success when it
          # is disabled, when no directive exists, when the repo has no epic
          # commits, and when it actually opened something. Only the observed
          # per-repo state distinguishes them.
          if [ "${EPIC_BRANCH_PR_STATE:-none}" = "open" ]; then
            _ebr_pr_open=true
          fi
        done < <(_fleet_repos_under_root)

        # Advance the epic's own acceptance state — once per epic, not once per
        # repository, and only on an observed open PR.
        if $_ebr_pr_open; then
          _fleet_advance_epic_state "$epic_id" "$children_nodes"
        fi
      fi
    fi
  done

  local findings
  findings=$(echo "$ready_ids" | sed 's/^ //')

  if [ "$ready_count" -gt 0 ]; then
    echo "{\"severity\":1,\"findings\":\"${ready_count} epic(s) ready for integration PR: ${findings}\"}"
  else
    echo '{"severity":0,"findings":""}'
  fi
}

# Fleet-wide blocked-by scan. Runs once per fleet_detect_all call.
# Checks all active tickets for resolved blocked-by dependencies.
# Usage: _fleet_scan_blocked_by <workspace>
_fleet_scan_blocked_by() {
  local workspace="${1:-${FLEET_PIPELINE_LOG_DIR:-./logs}}"

  if ! declare -f get_issue >/dev/null 2>&1; then
    local _la_paths=("$HOME/.claude/skills/lib/linear-api.sh" "${_CONFIG_DIR}/../linear-api.sh")
    for _lp in "${_la_paths[@]}"; do
      [ -f "$_lp" ] && source "$_lp" && break
    done
  fi

  if ! declare -f get_issue >/dev/null 2>&1; then
    echo '{"severity":0,"findings":""}'
    return
  fi

  # Scan all active pipeline logs and check each ticket's blocked-by status
  local unblocked_tids=""
  local unblocked_count=0

  for log_file in "$workspace"/*-pipeline.log; do
    [ -f "$log_file" ] || continue
    local tid
    tid=$(basename "$log_file" | sed 's/-pipeline.log$//')
    [ -z "$tid" ] && continue

    # Skip genuinely finished pipelines. A held ticket is not terminal — it
    # is waiting on a human — so it still has its blocked-by status checked;
    # this detector never auto-acts (WARN-only, fleet-wide finding), so
    # there is no kill/restart risk in scanning it.
    _pipeline_genuinely_terminal "$tid" "$workspace" && continue

    local sev
    sev=$(detect_blocked_by "$tid" "$workspace")
    if [ "$sev" -ge 1 ]; then
      unblocked_tids="${unblocked_tids} ${tid}"
      unblocked_count=$((unblocked_count + 1))
    fi
  done

  if [ "$unblocked_count" -gt 0 ]; then
    local findings
    findings="$(echo "$unblocked_tids" | sed 's/^ //')"
    echo "{\"severity\":1,\"findings\":\"${unblocked_count} unblocked: ${findings}\"}"
  else
    echo '{"severity":0,"findings":""}'
  fi
}

# ── Diagnostic context extraction ────────────────────────────────────────────────
# Reads: last 3 fail entries + last 5 RETRO hints from Claude log,
#        last 20 lines from agent output log if it exists.
# Usage: extract_diagnostics <tid> <phase> <workspace>
extract_diagnostics() {
  local tid="$1"
  local phase="${2:-}"
  local workspace="${3:-${FLEET_PIPELINE_LOG_DIR:-./logs}}"
  local claude_log="${workspace}/${tid}-claude.log"
  local agent_log=""

  # Agent output log — try to find matching phase
  if [ -n "$phase" ]; then
    agent_log="${workspace}/${tid}-${phase}-agent.log"
  fi

  echo "--- diagnostics for ${tid} ---"

  # Last 3 fail entries from Claude log
  if [ -f "$claude_log" ]; then
    echo "  last_fail_entries:"
    command grep '|fail|' "$claude_log" 2>/dev/null | tail -3 | while IFS= read -r l; do
      echo "    - $l"
    done || echo "    (none)"
  fi

  # Last 5 RETRO hints
  if [ -f "$claude_log" ]; then
    echo "  retro_hints:"
    command grep '|RETRO|hint|' "$claude_log" 2>/dev/null | tail -5 | while IFS= read -r l; do
      echo "    - $l"
    done || echo "    (none)"
  fi

  # Last 20 lines of agent output log
  if [ -n "$agent_log" ] && [ -f "$agent_log" ]; then
    echo "  agent_output (${tid}-${phase}-agent.log):"
    tail -20 "$agent_log" 2>/dev/null | while IFS= read -r l; do
      echo "    | $l"
    done
  fi

  echo "--- end diagnostics ---"
}

# ── Workspace guard ──────────────────────────────────────────────────────────────
# A misconfigured fleet and an idle fleet look identical from the aggregator's
# point of view: both produce zero pipeline rows. The difference is whether the
# directory is there at all. FLEET_PIPELINE_LOG_DIR defaults to the *relative*
# path ./logs, so a fleetd started from the wrong working directory silently
# monitors nothing and reports a clean bill of health forever — the worst
# possible failure mode for a health monitor.
#
# Emits {"severity":N,"findings":"..."} — WARN (1) when the directory cannot be
# read, silent (0) when it exists and is simply idle.
_fleet_workspace_guard() {
  local workspace="${1:-${FLEET_PIPELINE_LOG_DIR:-./logs}}"
  local configured="${FLEET_PIPELINE_LOG_DIR:-}"
  local origin
  if [ -n "$configured" ]; then
    origin="FLEET_PIPELINE_LOG_DIR=${configured}"
  else
    origin="FLEET_PIPELINE_LOG_DIR unset — default ./logs resolved against $(pwd)"
  fi

  if [ ! -e "$workspace" ]; then
    echo "{\"severity\":1,\"findings\":\"pipeline log directory does not exist: ${workspace} (${origin}). The fleet is monitoring nothing.\"}"
    return
  fi

  if [ ! -d "$workspace" ]; then
    echo "{\"severity\":1,\"findings\":\"pipeline log path is not a directory: ${workspace} (${origin}).\"}"
    return
  fi

  if [ ! -r "$workspace" ] || [ ! -x "$workspace" ]; then
    echo "{\"severity\":1,\"findings\":\"pipeline log directory is not readable: ${workspace} (${origin}).\"}"
    return
  fi

  # Exists and is readable. Zero logs here is a genuinely idle fleet, which is a
  # normal state and stays silent — warning on it would train operators to
  # ignore this detector.
  echo '{"severity":0,"findings":""}'
}

# ── Aggregator ───────────────────────────────────────────────────────────────────
# Enumerates active pipeline logs and runs every registered detector: 8
# legacy per-ticket detectors + planner_feedback + blocked_by +
# initiative_dispatch + epic_branch_ready + runaway_calls + human_hold +
# workspace_config. Detectors 9-10 run per-ticket; 10-13 have fleet-wide
# scans collected into the fleet_wide array; human_hold runs only inside the
# held-ticket branch (see fleet-controller/CLAUDE.md's detector table for the
# current count — this comment deliberately does not restate it).
# Outputs JSON results array.
# Usage: fleet_detect_all <workspace>
fleet_detect_all() {
  local workspace="${1:-${FLEET_PIPELINE_LOG_DIR:-./logs}}"

  # The guard runs before the directory check, not after it: a missing workspace
  # is exactly the case it exists to report, and the old early return discarded
  # that fact silently.
  local ws_json ws_sev ws_findings
  ws_json=$(_fleet_workspace_guard "$workspace")
  ws_sev=$(echo "$ws_json" | jq -r '.severity // 0')
  ws_findings=$(echo "$ws_json" | jq -r '.findings // ""')

  if [ ! -d "$workspace" ]; then
    local ws_entry
    ws_entry=$(jq -nc \
      --arg name "detect_workspace_config" \
      --argjson severity "$ws_sev" \
      --arg findings "$ws_findings" \
      --arg type "fleet-wide" \
      '{name: $name, severity: $severity, findings: $findings, type: $type}')
    jq -nc \
      --argjson fleet_wide "[$ws_entry]" \
      --argjson warn "$ws_sev" \
      '{pipelines: [], fleet_wide: $fleet_wide, summary: {total: 0, healthy: 0, warn: $warn, kill: 0, restart: 0}}'
    return
  fi

  local results="["
  local first=true
  local total=0 healthy=0 warn=0 kill=0 restart=0

  # Find all unique ticket IDs from pipeline logs (exclude completed ones)
  for log_file in "$workspace"/*-pipeline.log; do
    [ -f "$log_file" ] || continue

    local tid
    tid=$(basename "$log_file" | sed 's/-pipeline.log$//')
    [ -z "$tid" ] && continue

    # Skip logs older than FLEET_MAX_LOG_AGE_HOURS when configured
    if [ -n "${FLEET_MAX_LOG_AGE_HOURS:-}" ]; then
      local log_mtime now_epoch max_age_secs
      log_mtime=$(stat -c %Y "$log_file" 2>/dev/null || echo "0")
      now_epoch=$(date -u +%s)
      max_age_secs=$((FLEET_MAX_LOG_AGE_HOURS * 3600))
      if [ "$((now_epoch - log_mtime))" -ge "$max_age_secs" ]; then
        continue
      fi
    fi

    # Skip pipelines that are genuinely finished (completed, stopped, or
    # dead-lettered) — nothing left to watch. A held ticket is NOT
    # genuinely terminal (it is waiting on a human, not the pipeline), so
    # it stays in the sweep below rather than being exempted from every
    # detector — a raw `META|outcome|` grep here previously treated
    # "held: gate" the same as "completed:" and exempted every held ticket
    # from all 11 detectors; one sat unanswered for 160h with no alert.
    if _pipeline_genuinely_terminal "$tid" "$workspace"; then
      continue
    fi

    total=$((total + 1))

    # Run all per-ticket detectors, collect max severity
    local s1 s2 s3 s4 s5 s6 s7 s8 s9 s10 s11 s12 s13 max_sev anomaly_types
    if _pipeline_is_held "$tid" "$workspace"; then
      # The router has already exited cleanly for a held ticket — no live
      # process, no open bracket, no heartbeat. The other detectors
      # assume an actively running pipeline and would false-positive
      # (stalls/zombies/loops in particular) within minutes of a clean
      # hold. Only detect_abandoned's held-aware branch and
      # detect_human_hold (both WARN-capped, no kill/restart) are
      # meaningful here.
      s1=0
      s2=0
      s3=0
      s4=0
      s5=$(detect_abandoned "$tid" "$workspace")
      s6=0
      s7=0
      s8=0
      s9=0
      s10=0
      s11=0
      s12=$(detect_human_hold "$tid" "$workspace")
      # A held ticket has no live process and no open spawn bracket — the
      # router exited cleanly when the agent asked — so there is nothing
      # for the current-bracket scope to find here, same reasoning as
      # s1-s4/s6-s11 above.
      s13=0
    else
      s1=$(detect_phase_failures "$tid" "$workspace")
      s2=$(detect_stalls "$tid" "$workspace")
      s3=$(detect_zombies "$tid" "$workspace")
      s4=$(detect_loops "$tid" "$workspace")
      s5=$(detect_abandoned "$tid" "$workspace")
      s6=$(detect_flow_failures "$tid" "$workspace")
      s7=$(detect_auto_mode_blocks "$tid" "$workspace")
      s8=$(detect_tool_errors "$tid" "$workspace")
      s9=$(detect_planner_feedback "$tid" "$workspace")
      s10=$(detect_epic_branch_ready "$tid" "$workspace")
      s11=$(detect_runaway_calls "$tid" "$workspace")
      s12=0
      s13=$(detect_observer_findings "$tid" "$workspace")
    fi

    max_sev=0
    anomaly_types=""

    for s in "$s1" "$s2" "$s3" "$s4" "$s5" "$s6" "$s7" "$s8" "$s9" "$s10" "$s11" "$s12" "$s13"; do
      [ "$s" -gt "$max_sev" ] && max_sev="$s"
    done

    # Collect anomaly type labels
    [ "$s1" -ge 1 ] && anomaly_types="${anomaly_types} phase-failure(S${s1})"
    [ "$s2" -ge 1 ] && anomaly_types="${anomaly_types} stall(S${s2})"
    [ "$s3" -ge 1 ] && anomaly_types="${anomaly_types} zombie(S${s3})"
    [ "$s4" -ge 1 ] && anomaly_types="${anomaly_types} loop(S${s4})"
    [ "$s5" -ge 1 ] && anomaly_types="${anomaly_types} abandoned(S${s5})"
    [ "$s6" -ge 1 ] && anomaly_types="${anomaly_types} flow-failure(S${s6})"
    [ "$s7" -ge 1 ] && anomaly_types="${anomaly_types} auto-block(S${s7})"
    [ "$s8" -ge 1 ] && anomaly_types="${anomaly_types} tool-errors(S${s8})"
    [ "$s9" -ge 1 ] && anomaly_types="${anomaly_types} planner-feedback(S${s9})"
    [ "$s10" -ge 1 ] && anomaly_types="${anomaly_types} epic-branch-ready(S${s10})"
    [ "$s11" -ge 1 ] && anomaly_types="${anomaly_types} runaway-calls(S${s11})"
    [ "$s12" -ge 1 ] && anomaly_types="${anomaly_types} human-hold(S${s12})"
    [ "$s13" -ge 1 ] && anomaly_types="${anomaly_types} observer-findings(S${s13})"
    anomaly_types=$(echo "$anomaly_types" | sed 's/^ //')

    # Cap severity at 2 (KILL) when auto-restart is disabled
    if [ "$max_sev" -eq 3 ] && [ "${FLEET_AUTO_RESTART:-false}" != "true" ]; then
      max_sev=2
      anomaly_types="${anomaly_types} restart degraded to kill (auto-restart disabled)"
    fi

    # Get current phase from last pipeline log line
    local phase
    phase=$(_last_field "$log_file" 2)

    # Get last heartbeat age
    local hb_file="${workspace}/${tid}-heartbeat.log"
    local hb_age
    hb_age=$(_last_entry_age_secs "$hb_file")

    # Build JSON entry
    [ "$first" = "false" ] && results="$results,"
    first=false

    local entry
    entry=$(jq -nc \
      --arg tid "$tid" \
      --arg phase "${phase:-unknown}" \
      --argjson severity "$max_sev" \
      --arg anomalies "${anomaly_types:-none}" \
      --argjson hb_age "$hb_age" \
      --arg type "pipeline" \
      '{tid: $tid, phase: $phase, severity: $severity, anomalies: $anomalies, hb_age_secs: $hb_age, type: $type}')

    results="$results$entry"

    # Tally severities
    case "$max_sev" in
    0) healthy=$((healthy + 1)) ;;
    1) warn=$((warn + 1)) ;;
    2) kill=$((kill + 1)) ;;
    3) restart=$((restart + 1)) ;;
    esac
  done

  results="$results]"

  # ── Fleet-wide detectors (scan once, not per-ticket) ────────────────────────
  local fleet_wide="["
  local fw_first=true

  # D-10: Blocked-by resolution scan
  local bb_json
  bb_json=$(_fleet_scan_blocked_by "$workspace" 2>/dev/null || echo '{"severity":0,"findings":""}')
  [ "$fw_first" = "false" ] && fleet_wide="$fleet_wide,"
  fw_first=false
  fleet_wide="${fleet_wide}$(jq -nc \
    --arg name "detect_blocked_by" \
    --argjson severity "$(echo "$bb_json" | jq -r '.severity // 0')" \
    --arg findings "$(echo "$bb_json" | jq -r '.findings // ""')" \
    --arg type "fleet-wide" \
    '{name: $name, severity: $severity, findings: $findings, type: $type}')"

  local bb_sev
  bb_sev=$(echo "$bb_json" | jq -r '.severity // 0')
  [ "$bb_sev" -ge 1 ] && warn=$((warn + 1))

  # D-11: Initiative dispatch scan
  local id_json
  id_json=$(_fleet_scan_initiative_dispatch "$workspace" 2>/dev/null || echo '{"severity":0,"findings":""}')
  [ "$fw_first" = "false" ] && fleet_wide="$fleet_wide,"
  fw_first=false
  fleet_wide="${fleet_wide}$(jq -nc \
    --arg name "detect_initiative_dispatch" \
    --argjson severity "$(echo "$id_json" | jq -r '.severity // 0')" \
    --arg findings "$(echo "$id_json" | jq -r '.findings // ""')" \
    --arg type "fleet-wide" \
    '{name: $name, severity: $severity, findings: $findings, type: $type}')"

  local id_sev
  id_sev=$(echo "$id_json" | jq -r '.severity // 0')
  [ "$id_sev" -ge 1 ] && warn=$((warn + 1))

  # D-12: Epic branch readiness scan
  local ebr_json
  ebr_json=$(_fleet_scan_epic_branch_ready "$workspace" 2>/dev/null || echo '{"severity":0,"findings":""}')
  [ "$fw_first" = "false" ] && fleet_wide="$fleet_wide,"
  fw_first=false
  fleet_wide="${fleet_wide}$(jq -nc \
    --arg name "detect_epic_branch_ready" \
    --argjson severity "$(echo "$ebr_json" | jq -r '.severity // 0')" \
    --arg findings "$(echo "$ebr_json" | jq -r '.findings // ""')" \
    --arg type "fleet-wide" \
    '{name: $name, severity: $severity, findings: $findings, type: $type}')"

  local ebr_sev
  ebr_sev=$(echo "$ebr_json" | jq -r '.severity // 0')
  [ "$ebr_sev" -ge 1 ] && warn=$((warn + 1))

  # D-13: Workspace configuration guard (computed above, before the directory
  # check, so the same verdict is reported on both paths).
  [ "$fw_first" = "false" ] && fleet_wide="$fleet_wide,"
  fw_first=false
  fleet_wide="${fleet_wide}$(jq -nc \
    --arg name "detect_workspace_config" \
    --argjson severity "$ws_sev" \
    --arg findings "$ws_findings" \
    --arg type "fleet-wide" \
    '{name: $name, severity: $severity, findings: $findings, type: $type}')"

  [ "$ws_sev" -ge 1 ] && warn=$((warn + 1))

  fleet_wide="$fleet_wide]"

  # ── Summary ─────────────────────────────────────────────────────────────────
  local summary
  summary=$(jq -nc \
    --argjson total "$total" \
    --argjson healthy "$healthy" \
    --argjson warn "$warn" \
    --argjson kill "$kill" \
    --argjson restart "$restart" \
    '{total: $total, healthy: $healthy, warn: $warn, kill: $kill, restart: $restart}')

  jq -nc \
    --argjson pipelines "$results" \
    --argjson fleet_wide "$fleet_wide" \
    --argjson summary "$summary" \
    '{pipelines: $pipelines, fleet_wide: $fleet_wide, summary: $summary}'
}
