#!/usr/bin/env bash
# Fleet monitor script — deterministic detection + intervention loop.
#
# Sourceable: when sourced, defines fleet_monitor_cycle and fleet_monitor_loop
#   functions without executing them.
# Executable: when run directly (bash lib/fleet-monitor.sh <workspace>),
#   invokes fleet_monitor_loop with the first argument as workspace path.
#
# Dual spawn modes:
#   - Interactive: CLAUDE_CODE_SESSION_ID set → emits ACTION:spawn-restart to stdout
#   - Cron: CLAUDE_CODE_SESSION_ID absent → writes to spawn queue JSONL
#
# NOTE: Does NOT set -euo pipefail — this is a sourceable library.
# Callers are responsible for shell flags.

_MONITOR_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source dependencies with declare-guard pattern
if [ -f "$_MONITOR_DIR/config.sh" ]; then
  source "$_MONITOR_DIR/config.sh"
fi

# Bridge: heartbeat.sh uses HB_LOG_FILE; fleet controller uses FLEET_HB_LOG_FILE.
[ -z "${HB_LOG_FILE:-}" ] && HB_LOG_FILE="${FLEET_HB_LOG_FILE:-}"

# Source heartbeat for _plog (and _source_if_missing) — must be first
if ! declare -f _plog >/dev/null 2>&1; then
  [ -f "$_MONITOR_DIR/heartbeat.sh" ] && source "$_MONITOR_DIR/heartbeat.sh"
fi

_source_if_missing fleet_detect_all "$_MONITOR_DIR/fleet-detect.sh"
_source_if_missing fleet_kill_pipeline "$_MONITOR_DIR/fleet-intervene.sh"
_source_if_missing fleet_render_dashboard_from_data "$_MONITOR_DIR/fleet-dashboard.sh"

# ── Fleet controller log writer ───────────────────────────────────────────────────
# Write a timestamped entry to the fleet controller's own log file.
# Usage: fl_write <level> <component> <msg>
fl_write() {
  local level="$1"
  local component="$2"
  local msg="$3"
  local log_file="${FLEET_LOG_FILE:-./logs/fleet-controller.log}"
  if [ "${FLEET_LOG_FILE:-}" = "/dev/null" ]; then
    return 0
  fi
  _ensure_dir_for "$log_file"
  echo "$(_iso_now)|${level}|${component}|${msg}" >>"$log_file"
}

# ── Spawn helpers ────────────────────────────────────────────────────────────────

# Write a restart entry to the cron spawn queue JSONL file.
# No-op in interactive mode (CLAUDE_CODE_SESSION_ID is set).
# Args: tid reason restarts
_spawn_queue_write() {
  local tid="$1"
  local reason="$2"
  local restarts="${3:-0}"
  local instance_id="${FLEET_INSTANCE_ID:-default}"
  local queue_file="/tmp/fleet-${instance_id}-spawn-queue.jsonl"
  local entry
  entry=$(jq -nc \
    --arg tid "$tid" \
    --arg reason "$reason" \
    --arg timestamp "$(_iso_now)" \
    --argjson restarts "$restarts" \
    '{tid: $tid, reason: $reason, timestamp: $timestamp, restarts: $restarts}')

  echo "$entry" >>"$queue_file"
}

# Emit a restart spawn action. In interactive mode (CLAUDE_CODE_SESSION_ID is set),
# emits ACTION:spawn-restart to stdout. In cron mode, writes to spawn queue JSONL.
# Args: tid reason [restarts]
_spawn_restart() {
  local tid="$1"
  local reason="$2"
  local restarts="${3:-0}"

  if [ -n "${CLAUDE_CODE_SESSION_ID:-}" ]; then
    # Interactive mode — Claude Code parses these ACTION: lines
    echo "ACTION:spawn-restart tid=${tid}"
  else
    # Cron mode — write to spawn queue for external consumer
    _spawn_queue_write "$tid" "$reason" "$restarts"
  fi
}

# ── fleet_monitor_cycle ──────────────────────────────────────────────────────────
# Run one complete detection + intervention cycle.
# Returns JSON detection results to stdout.
# Usage: fleet_monitor_cycle <workspace>
fleet_monitor_cycle() {
  local workspace="${1:-${FLEET_PIPELINE_LOG_DIR:-./logs}}"

  fl_write "INFO" "monitor" "Starting monitor cycle"

  # Run detection ONCE per cycle
  local data
  if ! data=$(fleet_detect_all "$workspace" 2>/dev/null); then
    fl_write "ERROR" "monitor" "fleet_detect_all failed"
    echo '{"pipelines":[],"summary":{"total":0,"healthy":0,"warn":0,"kill":0,"restart":0}}'
    return 1
  fi

  # Render dashboard + report from the same detection data
  fleet_render_dashboard_from_data "$data" "$workspace" 2>/dev/null || true
  fleet_write_report_from_data "$data" "$workspace" 2>/dev/null || true

  # Execute interventions for KILL and KILL+RESTART severities
  local pipelines_json
  pipelines_json=$(echo "$data" | jq -c '.pipelines')

  echo "$pipelines_json" | jq -c '.[]' 2>/dev/null | while read -r pipeline; do
    local tid sev
    tid=$(echo "$pipeline" | jq -r '.tid')
    sev=$(echo "$pipeline" | jq -r '.severity')

    if [ "$sev" -ge 2 ]; then
      # Emit anomaly-detected heartbeat for WARN+ level pipelines
      local anomalies
      anomalies=$(echo "$pipeline" | jq -r '.anomalies')
      hb_fleet_action "anomaly-detected" "fired" "Pipeline anomaly detected" \
        "{\"tid\":\"$tid\",\"severity\":$sev,\"anomalies\":\"$anomalies\"}"

      if [ "$sev" -eq 3 ]; then
        # KILL+RESTART
        if fleet_restart_pipeline "$tid" "auto-restart" "$workspace" 2>/dev/null; then
          # Scan for fresh restart-intent markers
          if grep -q "META|fleet-restart-marker|info|restart-intent" "${workspace}/${tid}-pipeline.log" 2>/dev/null; then
            fl_write "INFO" "monitor" "Spawning restart for ${tid}"
            _spawn_restart "$tid" "auto-restart" 0
          fi
        fi
      else
        # KILL only (severity 2)
        fleet_kill_pipeline "$tid" "auto-kill" "$workspace" 2>/dev/null || true
      fi
    fi
  done

  fl_write "INFO" "monitor" "Monitor cycle complete"

  # Return the detection data for fleet-summary gating in the loop
  echo "$data"
}

# ── fleet_monitor_loop ───────────────────────────────────────────────────────────
# Continuous detection + intervention loop with fleet-summary state-transition
# gating. Exits cleanly when the namespaced stop file exists.
# Usage: fleet_monitor_loop <workspace>
fleet_monitor_loop() {
  local workspace="${1:-${FLEET_PIPELINE_LOG_DIR:-./logs}}"
  local instance_id="${FLEET_INSTANCE_ID:-default}"
  local stop_file="/tmp/fleet-${instance_id}-controller-stop"
  local poll_interval="${FLEET_POLL_INTERVAL:-30}"
  local summary_interval="${FLEET_SUMMARY_INTERVAL_CYCLES:-10}"

  fl_write "INFO" "monitor" "Starting monitor loop (instance=${instance_id}, interval=${poll_interval}s, stop_file=${stop_file})"
  hb_fleet_scan "cycle-start" "ok" "Monitor loop started" "{\"instance\":\"$instance_id\"}"

  # Initialize fleet summary state-transition gating
  local prev_summary=""
  local cycles_since_summary=0

  while true; do
    # Check namespaced stop file before each cycle
    if [ -f "$stop_file" ]; then
      fl_write "INFO" "monitor" "Stop file detected, exiting monitor loop"
      hb_fleet_scan "cycle-end" "ok" "Monitor loop stopped (stop file)" \
        "{\"instance\":\"$instance_id\"}"
      break
    fi

    # Run one cycle
    local cycle_data
    cycle_data=$(fleet_monitor_cycle "$workspace" 2>/dev/null || true)

    # Extract current summary for state-transition gating
    local current_summary
    current_summary=$(echo "$cycle_data" | jq -c '.summary' 2>/dev/null || echo "{}")

    cycles_since_summary=$((cycles_since_summary + 1))

    # Emit fleet-summary on state change OR forced interval
    local should_emit=false
    if [ -n "$current_summary" ] && [ "$current_summary" != "$prev_summary" ]; then
      should_emit=true
    fi
    if [ "$cycles_since_summary" -ge "$summary_interval" ]; then
      should_emit=true
    fi

    if [ "$should_emit" = "true" ]; then
      local total healthy warn kill restart
      total=$(echo "$current_summary" | jq -r '.total // 0')
      healthy=$(echo "$current_summary" | jq -r '.healthy // 0')
      warn=$(echo "$current_summary" | jq -r '.warn // 0')
      kill=$(echo "$current_summary" | jq -r '.kill // 0')
      restart=$(echo "$current_summary" | jq -r '.restart // 0')

      hb_fleet_scan "fleet-summary" "info" "Fleet health summary" \
        "{\"total\":$total,\"healthy\":$healthy,\"warn\":$warn,\"kill\":$kill,\"restart\":$restart,\"cycles_since_last\":$cycles_since_summary}"

      prev_summary="$current_summary"
      cycles_since_summary=0
    fi

    sleep "$poll_interval"
  done
}

# ── Sourceable/executable guard ──────────────────────────────────────────────────
# When executed directly (not sourced), run the monitor loop.
# ${BASH_SOURCE[0]} == "$0" means this script is the entry point.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  WORKSPACE="${1:-${FLEET_PIPELINE_LOG_DIR:-./logs}}"
  fleet_monitor_loop "$WORKSPACE"
fi
