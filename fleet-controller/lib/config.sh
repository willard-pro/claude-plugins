#!/usr/bin/env bash
# Fleet controller configuration — env-var defaults with `${VAR:-default}` pattern.
# Sourceable library — no set flags. Intended to be sourced by fleet-*.sh scripts.

# ── Durable state directory ─────────────────────────────────────────────────────
# All fleet-controller persistent state (spawn queue, stop files, run registry,
# fence markers) lives under this directory rather than /tmp so a host reboot
# does not silently drop queued dispatches or in-flight decisions.
# Default: {workspace} as resolved by each script's caller.
FLEET_STATE_DIR="${FLEET_STATE_DIR:-}"

# ── Kill escalation thresholds ──────────────────────────────────────────────────
# How long to wait for cooperative shutdown (after touching stop-files) before
# sending SIGTERM, and again after SIGTERM before sending SIGKILL.
FLEET_KILL_GRACE_SECS="${FLEET_KILL_GRACE_SECS:-10}"

# When true, fleet_kill_pipeline verifies PID termination before finalizing.
# Set to false to fall back to stop-file-only behaviour (pre-verified-escalation).
FLEET_KILL_VERIFY="${FLEET_KILL_VERIFY:-true}"

# ── Generation fencing ──────────────────────────────────────────────────────────
# When true, flow.sh refuses Linear mutations from a superseded (fenced) generation.
# Set to false for emergency rollback — unfenced tickets are always unrestricted.
FLEET_FENCE_ENFORCE="${FLEET_FENCE_ENFORCE:-true}"

# ── Spawn queue lock timeout ────────────────────────────────────────────────────
# Seconds to wait for the spawn queue flock before skipping the cycle.
FLEET_QUEUE_LOCK_TIMEOUT="${FLEET_QUEUE_LOCK_TIMEOUT:-5}"

# ── Instance namespace ──────────────────────────────────────────────────────────
# Namespace for spawn queue, stop files, run registry, and fence markers.
# Prevents collisions between multiple fleet controller instances on the same host.
FLEET_INSTANCE_ID="${FLEET_INSTANCE_ID:-default}"

# ── State directory resolver ────────────────────────────────────────────────────
# Resolves the durable-state directory from FLEET_STATE_DIR env var, falling back
# to the provided workspace path. Callers pass their workspace as $1.
# Usage: _fleet_state_dir <workspace>
_fleet_state_dir() {
  local workspace="${1:-./logs}"
  if [ -n "${FLEET_STATE_DIR:-}" ]; then
    echo "$FLEET_STATE_DIR"
  else
    echo "$workspace"
  fi
}
