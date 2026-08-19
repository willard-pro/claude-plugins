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

# ── Helpers ──────────────────────────────────────────────────────────────────────

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

# ── Detection functions ─────────────────────────────────────────────────────────
# Each takes (tid, workspace_dir) and prints severity to stdout.
# workspace_dir is optional — defaults to FLEET_PIPELINE_LOG_DIR, then ./logs.

# 1. Phase failure detection
detect_phase_failures() {
  local tid="$1"
  local workspace="${2:-${FLEET_PIPELINE_LOG_DIR:-./logs}}"
  local log_file="${workspace}/${tid}-pipeline.log"

  if [ ! -f "$log_file" ]; then
    echo "0"
    return
  fi

  local severity=0

  # Check for gate-stop codes first (separate classification)
  local gate_stop
  gate_stop=$(command grep '|META|gate-stop|fail|' "$log_file" 2>/dev/null | tail -1 || true)

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
  phase_failures=$(command grep -v '|MAINTENANCE|' "$log_file" | command grep -v '|META|' | command grep -c '|fail|' 2>/dev/null || true)

  if [ "$phase_failures" -gt 0 ]; then
    # First occurrence → WARN
    severity=1
  fi

  echo "$severity"
}

# 2. Stall detection via stale heartbeats
detect_stalls() {
  local tid="$1"
  local workspace="${2:-${FLEET_PIPELINE_LOG_DIR:-./logs}}"
  local hb_file="${workspace}/${tid}-heartbeat.log"

  if [ ! -f "$hb_file" ]; then
    echo "0"
    return
  fi

  # Find last orchestrator-waiting or watchdog|alive entry
  local last_hb
  last_hb=$(command grep -E '\|orchestrator-waiting\||\|watchdog\|alive\|' "$hb_file" 2>/dev/null | tail -1 || true)

  if [ -z "$last_hb" ]; then
    echo "0"
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

  local severity=0
  local warn_secs="${FLEET_STALL_WARN_SECS:-300}"
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

  echo "$severity"
}

# 3. Zombie step detection — unresolved |waiting| entries
detect_zombies() {
  local tid="$1"
  local workspace="${2:-${FLEET_PIPELINE_LOG_DIR:-./logs}}"
  local log_file="${workspace}/${tid}-pipeline.log"

  if [ ! -f "$log_file" ]; then
    echo "0"
    return
  fi

  # Find all |waiting| lines
  local lines
  lines=$(command grep '|waiting|' "$log_file" 2>/dev/null || true)

  if [ -z "$lines" ]; then
    echo "0"
    return
  fi

  local severity=0
  local now_epoch
  now_epoch=$(date -u +%s)
  local zombie_threshold="${FLEET_ZOMBIE_SECS:-900}"

  while IFS= read -r line; do
    [ -z "$line" ] && continue
    local iso
    iso=$(echo "$line" | awk -F'|' '{print $1}')
    local phase
    phase=$(echo "$line" | awk -F'|' '{print $2}')
    local step
    step=$(echo "$line" | awk -F'|' '{print $3}')

    local line_epoch
    line_epoch=$(date -d "$iso" +%s 2>/dev/null || echo "0")
    local age=$((now_epoch - line_epoch))

    # Check if this waiting entry has a matching done/fail/skip
    local has_terminal
    has_terminal=$(command grep -E -c "\|${phase}\|${step}\|(done|fail|skip)\|" "$log_file" 2>/dev/null || true)

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

# 5. Abandonment detection — pipeline log exists but no outcome
detect_abandoned() {
  local tid="$1"
  local workspace="${2:-${FLEET_PIPELINE_LOG_DIR:-./logs}}"
  local log_file="${workspace}/${tid}-pipeline.log"

  if [ ! -f "$log_file" ]; then
    echo "0"
    return
  fi

  # Check if pipeline has an outcome (completed normally)
  if command grep -q '|META|outcome|' "$log_file" 2>/dev/null; then
    echo "0"
    return
  fi

  local age
  age=$(_last_entry_age_secs "$log_file")

  local warn_secs=$((${FLEET_ABANDON_WARN_HOURS:-1} * 3600))
  local kill_secs=$((${FLEET_ABANDON_KILL_HOURS:-4} * 3600))

  if [ "$age" -ge "$kill_secs" ]; then
    echo "3"
  elif [ "$age" -ge "$warn_secs" ]; then
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
  local log_file="${workspace}/${tid}-pipeline.log"

  if [ ! -f "$log_file" ]; then
    echo "0"
    return
  fi

  local block_count=0

  # Source 1: check-approval|fail entries in pipeline log
  local pipeline_blocks
  pipeline_blocks=$(command grep -c '|check-approval|fail|' "$log_file" 2>/dev/null || true)
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
  local log_file="${workspace}/${tid}-pipeline.log"

  if [ ! -f "$log_file" ]; then
    echo "0"
    return
  fi

  # Find META|planner-feedback entries
  local fb_entries
  fb_entries=$(command grep '|META|planner-feedback|' "$log_file" 2>/dev/null || true)
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
  local query='{"query":"{issues(filter:{labels:{name:{eq:\\\"state:execution\\\"}}}){nodes{id identifier title description children{nodes{id identifier state{name} labels{nodes{name}}}}}}}"}'

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
    local epic_id epic_description
    epic_id=$(echo "$epics_json" | jq -r ".data.issues.nodes[$i].identifier // empty" 2>/dev/null)
    epic_description=$(echo "$epics_json" | jq -r ".data.issues.nodes[$i].description // \"\"" 2>/dev/null)
    [ -z "$epic_id" ] && continue

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
        while IFS= read -r _ebr_repo; do
          [ -z "$_ebr_repo" ] && continue
          epic_branch_open_pr "$epic_id" "$_ebr_repo" 2>/dev/null || true
        done < <(_fleet_repos_under_root)
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

    # Skip completed pipelines
    command grep -q '|META|outcome|' "$log_file" 2>/dev/null && continue

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

# ── Aggregator ───────────────────────────────────────────────────────────────────
# Enumerates active pipeline logs, runs all 12 detectors: 8 legacy per-ticket
# detectors + planner_feedback + blocked_by + initiative_dispatch +
# epic_branch_ready. Detectors 9-10 run per-ticket; 10-12 have fleet-wide
# scans collected into the fleet_wide array.
# Outputs JSON results array.
# Usage: fleet_detect_all <workspace>
fleet_detect_all() {
  local workspace="${1:-${FLEET_PIPELINE_LOG_DIR:-./logs}}"

  if [ ! -d "$workspace" ]; then
    echo '{"pipelines":[],"fleet_wide":[],"summary":{"total":0,"healthy":0,"warn":0,"kill":0,"restart":0}}'
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

    # Skip pipelines that already have an outcome (completed)
    if command grep -q '|META|outcome|' "$log_file" 2>/dev/null; then
      continue
    fi

    total=$((total + 1))

    # Run all 10 per-ticket detectors (1-8 + planner_feedback + epic-branch), collect max severity
    local s1 s2 s3 s4 s5 s6 s7 s8 s9 s10 max_sev anomaly_types
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

    max_sev=0
    anomaly_types=""

    for s in "$s1" "$s2" "$s3" "$s4" "$s5" "$s6" "$s7" "$s8" "$s9" "$s10"; do
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
