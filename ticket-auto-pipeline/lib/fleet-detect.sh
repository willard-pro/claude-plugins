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
if [ -f "$_CONFIG_DIR/config.sh" ]; then
  source "$_CONFIG_DIR/config.sh"
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
    echo "2"   # KILL — persistent failure pattern
  elif [ "$unique_errors" -ge 1 ]; then
    echo "1"   # WARN — transient errors seen
  else
    echo "0"
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
# Enumerates active pipeline logs, runs all 7 detectors per pipeline,
# outputs JSON results array.
# Usage: fleet_detect_all <workspace>
fleet_detect_all() {
  local workspace="${1:-${FLEET_PIPELINE_LOG_DIR:-./logs}}"

  if [ ! -d "$workspace" ]; then
    echo '{"pipelines":[],"summary":{"total":0,"healthy":0,"warn":0,"kill":0,"restart":0}}'
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

    # Run all 8 detectors, collect max severity
    local s1 s2 s3 s4 s5 s6 s7 s8 max_sev anomaly_types
    s1=$(detect_phase_failures "$tid" "$workspace")
    s2=$(detect_stalls "$tid" "$workspace")
    s3=$(detect_zombies "$tid" "$workspace")
    s4=$(detect_loops "$tid" "$workspace")
    s5=$(detect_abandoned "$tid" "$workspace")
    s6=$(detect_flow_failures "$tid" "$workspace")
    s7=$(detect_auto_mode_blocks "$tid" "$workspace")
    s8=$(detect_tool_errors "$tid" "$workspace")

    max_sev=0
    anomaly_types=""

    for s in "$s1" "$s2" "$s3" "$s4" "$s5" "$s6" "$s7" "$s8"; do
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
      '{tid: $tid, phase: $phase, severity: $severity, anomalies: $anomalies, hb_age_secs: $hb_age}')

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
    --argjson summary "$summary" \
    '{pipelines: $pipelines, summary: $summary}'
}
