#!/usr/bin/env bash
# Fleet intervention library — executes kill/restart actions based on
# detection severity. All destructive actions are gated behind FLEET_DRY_RUN
# (when set, interventions are logged but not executed).
#
# NOTE: Does NOT set -euo pipefail — this is a sourceable library.
# Callers are responsible for shell flags.

# Source config for threshold defaults
_INTERVENE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$_INTERVENE_DIR/config.sh" ]; then
  source "$_INTERVENE_DIR/config.sh"
fi

# Source heartbeat library from canonical path (synced by ticket-auto-pipeline SessionStart hook)
if ! declare -f _plog >/dev/null 2>&1; then
  for _hp in "$_INTERVENE_DIR/heartbeat.sh" "$HOME/.claude/skills/lib/heartbeat.sh"; do
    [ -f "$_hp" ] && source "$_hp" && break
  done
fi

# ── Helpers ──────────────────────────────────────────────────────────────────────

# Write a timestamped entry to the pipeline log. Creates directory if needed.
# Args: log_file, phase, step, status, message
_log_pipeline() {
  _plog "$@" # file phase step status msg → delegates to shared log writer
}

# Check if a flock mutex is held by flow.sh for a given ticket ID.
# Returns 0 if mutex is held (should defer), 1 otherwise.
_flow_mutex_held() {
  local tid="$1"
  # Lock path matches flow.sh's anchored resolution: TICKET_FLOW_LOCK_DIR
  # env var first, then $HOME/.claude/skills/ticket-flow/locks as fallback.
  # Must resolve to the same directory flow.sh uses or the mutex check is blind.
  local lock_dir="${TICKET_FLOW_LOCK_DIR:-$HOME/.claude/skills/ticket-flow/locks}"
  local lockfile="${lock_dir}/.ticket-flow-${tid}.lock"
  # Try to acquire the same lock flow.sh holds. If we can't get it
  # (exit 42 = EWOULDBLOCK), flow.sh is mid-mutation.
  if [ -f "$lockfile" ]; then
    flock -n -E 42 "$lockfile" -c 'true' 2>/dev/null
    [ $? -eq 42 ] && return 0 # mutex held
  fi
  return 1 # mutex not held
}

# Count fleet-restart markers in pipeline log.
# Args: log_file
_count_restarts() {
  local file="$1"
  if [ ! -f "$file" ]; then
    echo "0"
    return
  fi
  grep -c 'fleet-restart' "$file" 2>/dev/null || echo "0"
}

# ── fleet_stop_background ────────────────────────────────────────────────────────
# Touch both stop files to signal background pinger/watchdog to shut down.
# Idempotent — touching files that already exist succeeds.
# Usage: fleet_stop_background <tid>
fleet_stop_background() {
  local tid="$1"
  local pinger_stop="/tmp/ticket-auto-${tid}-pinger-stop"
  local watchdog_stop="/tmp/ticket-auto-${tid}-watchdog-stop"

  touch "$pinger_stop" 2>/dev/null || true
  touch "$watchdog_stop" 2>/dev/null || true
}

# ── fleet_kill_pipeline ──────────────────────────────────────────────────────────
# Kill a pipeline: touch stop files, write intervention + outcome to pipeline log,
# write hb_decision audit entry.
# Usage: fleet_kill_pipeline <tid> [reason] [workspace]
fleet_kill_pipeline() {
  local tid="$1"
  local reason="${2:-fleet-kill}"
  local workspace="${3:-${FLEET_PIPELINE_LOG_DIR:-./logs}}"
  local log_file="${workspace}/${tid}-pipeline.log"
  local hb_file="${workspace}/${tid}-heartbeat.log"

  # Pre-kill existence check — prevent creating log directories for nonexistent tickets
  if [ ! -f "$log_file" ]; then
    echo "fleet_kill_pipeline: no pipeline log for ${tid}" >&2
    return 1
  fi

  if [ "${FLEET_DRY_RUN:-false}" = "true" ]; then
    echo "[DRY-RUN] would KILL ticket ${tid}: ${reason}"
    return 0
  fi

  # Check flow.sh mutex
  if _flow_mutex_held "$tid"; then
    echo "fleet_kill_pipeline: deferred — flow.sh mutex held for ${tid}"
    return 2
  fi

  # Touch stop files
  fleet_stop_background "$tid"

  # Write intervention log entry
  _log_pipeline "$log_file" "META" "fleet-intervention" "warn" "KILL; reason=${reason}"

  # Write outcome to finalize pipeline
  _log_pipeline "$log_file" "META" "outcome" "info" "stopped: fleet-kill; ${reason}"

  # Write heartbeat audit entry
  export HB_LOG_FILE="${hb_file}"
  hb_decision "fleet-kill" "fired" "reason=${reason}"

  echo "fleet_kill_pipeline: killed ${tid} — ${reason}"
  return 0
}

# ── fleet_can_restart ────────────────────────────────────────────────────────────
# Check restart eligibility. Returns 0 if eligible, 1 with reason otherwise.
# Checks: FLEET_AUTO_RESTART=true, restart count < FLEET_MAX_RESTARTS,
#         no flow.sh mutex held.
# Usage: fleet_can_restart <tid> [workspace]
fleet_can_restart() {
  local tid="$1"
  local workspace="${2:-${FLEET_PIPELINE_LOG_DIR:-./logs}}"
  local log_file="${workspace}/${tid}-pipeline.log"

  # Check auto-restart enabled
  if [ "${FLEET_AUTO_RESTART:-false}" != "true" ]; then
    echo "fleet_can_restart: auto-restart disabled (set FLEET_AUTO_RESTART=true to enable)"
    return 1
  fi

  # Check flow.sh mutex
  if _flow_mutex_held "$tid"; then
    echo "fleet_can_restart: deferred — flow.sh mutex held for ${tid}"
    return 1
  fi

  # Check restart count against cap
  local restarts max_restarts
  restarts=$(_count_restarts "$log_file")
  max_restarts="${FLEET_MAX_RESTARTS:-2}"

  if [ "$restarts" -ge "$max_restarts" ]; then
    echo "fleet_can_restart: restart cap reached (${restarts}/${max_restarts})"
    return 1
  fi

  return 0
}

# ── fleet_restart_pipeline ──────────────────────────────────────────────────────
# Restart a pipeline: kill + check eligibility + write restart marker + spawn hint.
# The actual spawn is done by the skill layer (Claude Code agent spawn), not here.
# Usage: fleet_restart_pipeline <tid> [reason] [workspace]
# Prints "RESTART_ELIGIBLE=<tid>" on success for the skill layer to act on.
fleet_restart_pipeline() {
  local tid="$1"
  local reason="${2:-fleet-restart}"
  local workspace="${3:-${FLEET_PIPELINE_LOG_DIR:-./logs}}"
  local log_file="${workspace}/${tid}-pipeline.log"
  local hb_file="${workspace}/${tid}-heartbeat.log"

  if [ "${FLEET_DRY_RUN:-false}" = "true" ]; then
    echo "[DRY-RUN] would RESTART ticket ${tid}: ${reason}"
    fleet_can_restart "$tid" "$workspace" || true
    return 0
  fi

  # Check eligibility
  local eligible
  if ! eligible=$(fleet_can_restart "$tid" "$workspace" 2>&1); then
    echo "fleet_restart_pipeline: not eligible — $eligible"
    return 1
  fi

  # Kill the existing pipeline first (finalizes the old pipeline)
  fleet_kill_pipeline "$tid" "restart: ${reason}" "$workspace"

  # Write restart marker to the OLD pipeline log (before restart count)
  _log_pipeline "$log_file" "META" "fleet-restart" "info" "restart ${reason}"

  # Write heartbeat audit entry
  export HB_LOG_FILE="${hb_file}"
  hb_decision "fleet-restart" "fired" "reason=${reason}"

  # Write restart marker so the skill layer can detect restart intent
  # from the pipeline log (replaces the old RESTART_ELIGIBLE stdout echo
  # that nobody captured — see decision 3 in design.md)
  _log_pipeline "$log_file" "META" "fleet-restart-marker" "info" "restart-intent ${reason}"

  return 0
}
