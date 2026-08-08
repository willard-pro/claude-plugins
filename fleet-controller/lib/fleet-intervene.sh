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
# Source registry/fence helpers if available
if [ -f "$_INTERVENE_DIR/fleet-registry.sh" ]; then
  source "$_INTERVENE_DIR/fleet-registry.sh"
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
  grep -c '|META|fleet-restart|' "$file" 2>/dev/null || echo "0"
}

# ── fleet_stop_background ────────────────────────────────────────────────────────
# Touch both stop files to signal background pinger/watchdog to shut down.
# Idempotent — touching files that already exist succeeds.
# Usage: fleet_stop_background <tid> [workspace]
fleet_stop_background() {
  local tid="$1"
  local workspace="${2:-${FLEET_PIPELINE_LOG_DIR:-./logs}}"
  local pinger_stop watchdog_stop
  pinger_stop=$(_fleet_stop_file "$tid" "pinger" "$workspace")
  watchdog_stop=$(_fleet_stop_file "$tid" "watchdog" "$workspace")

  touch "$pinger_stop" 2>/dev/null || true
  touch "$watchdog_stop" 2>/dev/null || true
}

# ── fleet_postmortem ────────────────────────────────────────────────────────────
# Run pipeline post-mortem analysis after fleet-kill (RLVR Phase 3).
# Fail-soft: failures are logged but never block the kill path.
# Gated behind FLEET_POSTMORTEM_ON_KILL (default false).
# F05: passes LOG_FILE and HB_FILE so postmortem finds the correct logs
# regardless of fleetd's cwd.
# Usage: _fleet_postmortem <tid> <log_file> <hb_file>
_fleet_postmortem() {
  local tid="$1"
  local log_file="$2"
  local hb_file="$3"

  if [ "${FLEET_POSTMORTEM_ON_KILL:-false}" != "true" ]; then
    return 0
  fi

  local _pm_script
  _pm_script="$HOME/.claude/skills/lib/pipeline-postmortem.sh"
  if [ ! -f "$_pm_script" ]; then
    _pm_script=$(find "$HOME/.claude/plugins/cache" -name pipeline-postmortem.sh -path "*/ticket-auto-pipeline/*" 2>/dev/null | sort | tail -1)
  fi

  if [ -n "$_pm_script" ] && [ -f "$_pm_script" ]; then
    LOG_FILE="${log_file}" HB_FILE="${hb_file}" \
      timeout 60 bash "$_pm_script" "$tid" --exit-code 1 2>&1 || true
  fi
}

# ── fleet_kill_pipeline ──────────────────────────────────────────────────────────
# Kill a pipeline with verified escalation:
#   stop-files → grace → kill -0 → SIGTERM → grace → kill -0 → SIGKILL → re-verify
# META|outcome is written ONLY after PID is confirmed gone.
# Writes a generation fence marker to prevent superseded zombie mutations.
# Usage: fleet_kill_pipeline <tid> [reason] [workspace]
fleet_kill_pipeline() {
  local tid="$1"
  local reason="${2:-fleet-kill}"
  local workspace="${3:-${FLEET_PIPELINE_LOG_DIR:-./logs}}"
  local state_dir
  state_dir=$(_fleet_state_dir "$workspace")
  local log_file="${workspace}/${tid}-pipeline.log"
  local hb_file="${workspace}/${tid}-heartbeat.log"
  local kill_grace="${FLEET_KILL_GRACE_SECS:-10}"
  local kill_verify="${FLEET_KILL_VERIFY:-true}"

  # Pre-kill existence check — prevent creating log directories for nonexistent tickets
  if [ ! -f "$log_file" ]; then
    echo "fleet_kill_pipeline: no pipeline log for ${tid}" >&2
    return 1
  fi

  if [ "${FLEET_DRY_RUN:-false}" = "true" ]; then
    echo "[DRY-RUN] would KILL ticket ${tid}: ${reason}"
    local dry_registry_pid
    dry_registry_pid=$(registry_pid "$tid" "$state_dir" 2>/dev/null)
    if [ -n "$dry_registry_pid" ] && [ "$dry_registry_pid" != "0" ]; then
      echo "[DRY-RUN]   would escalate: stop-files → grace ${kill_grace}s → SIGTERM → grace → SIGKILL for PID ${dry_registry_pid}"
    else
      echo "[DRY-RUN]   stop-files only (no registry PID)"
    fi
    return 0
  fi

  # Check flow.sh mutex
  if _flow_mutex_held "$tid"; then
    echo "fleet_kill_pipeline: deferred — flow.sh mutex held for ${tid}"
    return 2
  fi

  # Write intervention log entry
  _log_pipeline "$log_file" "META" "fleet-intervention" "warn" "KILL; reason=${reason}"

  # Touch stop files (workspace-relative state dir)
  fleet_stop_background "$tid" "$state_dir"

  # ── Verified escalation ────────────────────────────────────────────────────────
  # If kill-verify is disabled, fall back to stop-file-only (pre-escalation compat).
  if [ "$kill_verify" != "true" ]; then
    _log_pipeline "$log_file" "META" "outcome" "info" "stopped: fleet-kill (stop-files only); ${reason}"
    export HB_LOG_FILE="${hb_file}"
    hb_decision "fleet-kill" "fired" "reason=${reason}"
    _fleet_postmortem "$tid" "$log_file" "$hb_file"
    echo "fleet_kill_pipeline: killed ${tid} (stop-files only) — ${reason}"
    return 0
  fi

  # ── Registry-aware escalation ──────────────────────────────────────────────────
  local registry_pid registry_gen
  registry_pid=$(registry_pid "$tid" "$state_dir" 2>/dev/null)
  registry_gen=$(registry_generation "$tid" "$state_dir" 2>/dev/null || echo "0")

  if [ -z "$registry_pid" ] || [ "$registry_pid" = "0" ]; then
    # No registry PID — fall back to stop-file-only (backward compatible)
    _log_pipeline "$log_file" "META" "outcome" "info" "stopped: fleet-kill (no registry PID); ${reason}"
    export HB_LOG_FILE="${hb_file}"
    hb_decision "fleet-kill" "fired" "reason=${reason}"
    _fleet_postmortem "$tid" "$log_file" "$hb_file"
    echo "fleet_kill_pipeline: killed ${tid} (no registry PID, stop-files only) — ${reason}"
    return 0
  fi

  # Wait for cooperative shutdown (stop-files signal the pinger/watchdog)
  sleep "$kill_grace"

  # Check if process exited cooperatively
  if ! kill -0 "$registry_pid" 2>/dev/null; then
    # PID already gone — cooperative shutdown succeeded
    _log_pipeline "$log_file" "META" "outcome" "info" "stopped: fleet-kill (cooperative); ${reason}"
    export HB_LOG_FILE="${hb_file}"
    hb_decision "fleet-kill" "fired" "reason=${reason}"

    # Write fence marker for the killed generation
    if [ "$registry_gen" -gt 0 ] 2>/dev/null; then
      fence_write "$tid" "$registry_gen" "$state_dir"
    fi

    _fleet_postmortem "$tid" "$log_file" "$hb_file"
    echo "fleet_kill_pipeline: killed ${tid} (cooperative exit) — ${reason}"
    return 0
  fi

  # ── PID-reuse guard ────────────────────────────────────────────────────────────
  # Before signalling, corroborate the PID is still our worker (not a reused PID).
  # Check: process start time newer than registry started_at, OR cmdline contains tid.
  local registry_started_at
  registry_started_at=$(registry_read "$tid" "$state_dir" 2>/dev/null | jq -r '.started_at // empty')
  local pid_verified=true
  if [ -n "$registry_started_at" ] && command -v ps >/dev/null 2>&1; then
    # Check if the PID's process start time is plausibly ours
    local pid_start
    pid_start=$(ps -o lstart= -p "$registry_pid" 2>/dev/null | head -1 || true)
    if [ -n "$pid_start" ]; then
      # If the process started before our registry entry, it's not ours
      local pid_start_epoch registry_start_epoch
      pid_start_epoch=$(date -d "$pid_start" +%s 2>/dev/null || echo "0")
      registry_start_epoch=$(date -d "$registry_started_at" +%s 2>/dev/null || echo "0")
      if [ "$pid_start_epoch" != "0" ] && [ "$registry_start_epoch" != "0" ] &&
        [ "$pid_start_epoch" -lt "$((registry_start_epoch - 5))" ] 2>/dev/null; then
        pid_verified=false
      fi
    fi
  fi

  if ! $pid_verified; then
    # PID reuse suspected — downgrade to kill-unverified, do NOT signal
    _log_pipeline "$log_file" "META" "kill-unverified" "warn" "PID ${registry_pid} ownership unverified for ${tid}; no signal sent"
    export HB_LOG_FILE="${hb_file}"
    hb_decision "kill-unverified" "warn" "PID reuse suspected for ${tid}"
    echo "fleet_kill_pipeline: kill-unverified — PID ${registry_pid} ownership unconfirmed for ${tid}"
    return 0
  fi

  # ── SIGTERM escalation ─────────────────────────────────────────────────────────
  kill -TERM "$registry_pid" 2>/dev/null || true
  sleep "$kill_grace"

  if ! kill -0 "$registry_pid" 2>/dev/null; then
    # SIGTERM succeeded
    _log_pipeline "$log_file" "META" "outcome" "info" "stopped: fleet-kill (SIGTERM); ${reason}"
    export HB_LOG_FILE="${hb_file}"
    hb_decision "fleet-kill" "fired" "reason=${reason}"

    if [ "$registry_gen" -gt 0 ] 2>/dev/null; then
      fence_write "$tid" "$registry_gen" "$state_dir"
    fi

    _fleet_postmortem "$tid" "$log_file" "$hb_file"
    echo "fleet_kill_pipeline: killed ${tid} (SIGTERM) — ${reason}"
    return 0
  fi

  # ── SIGKILL escalation ─────────────────────────────────────────────────────────
  kill -KILL "$registry_pid" 2>/dev/null || true
  sleep 1 # Brief wait for kernel to reap

  if ! kill -0 "$registry_pid" 2>/dev/null; then
    # SIGKILL succeeded — PID confirmed gone, finalize
    _log_pipeline "$log_file" "META" "outcome" "info" "stopped: fleet-kill (SIGKILL); ${reason}"
    export HB_LOG_FILE="${hb_file}"
    hb_decision "fleet-kill" "fired" "reason=${reason}"

    if [ "$registry_gen" -gt 0 ] 2>/dev/null; then
      fence_write "$tid" "$registry_gen" "$state_dir"
    fi

    _fleet_postmortem "$tid" "$log_file" "$hb_file"
    echo "fleet_kill_pipeline: killed ${tid} (SIGKILL) — ${reason}"
    return 0
  fi

  # ── kill-unverified fallthrough ────────────────────────────────────────────────
  # PID still alive after SIGKILL — something is very wrong.
  # Emit kill-unverified WARN, do NOT finalize as stopped.
  _log_pipeline "$log_file" "META" "kill-unverified" "warn" "PID ${registry_pid} survived SIGKILL for ${tid}; NOT finalized"
  export HB_LOG_FILE="${hb_file}"
  hb_decision "kill-unverified" "warn" "PID ${registry_pid} survived SIGKILL for ${tid}"

  echo "fleet_kill_pipeline: kill-unverified — PID ${registry_pid} survived escalation for ${tid}" >&2
  return 3
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
