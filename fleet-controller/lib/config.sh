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
# Seconds to wait for the spawn queue flock per attempt.
FLEET_QUEUE_LOCK_TIMEOUT="${FLEET_QUEUE_LOCK_TIMEOUT:-5}"

# Maximum retry attempts for contended queue appends. After exhausting retries,
# the entry is dead-lettered rather than silently dropped.
FLEET_QUEUE_MAX_RETRIES="${FLEET_QUEUE_MAX_RETRIES:-3}"

# Base backoff seconds between queue append retries. Doubles on each attempt.
FLEET_QUEUE_RETRY_BACKOFF_SECS="${FLEET_QUEUE_RETRY_BACKOFF_SECS:-2}"

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

# ── State path constructors ─────────────────────────────────────────────────────
# Every consumer that reads or writes fleet state (stop-files, queue, registry,
# fence markers) MUST derive paths through these functions. Independent path
# derivation duplicates the resolution rule — that is how the same bug recurs.
#
# All constructors accept an optional workspace argument forwarded to
# _fleet_state_dir. The caller's responsibility is to pass a consistent workspace;
# the resolver's responsibility is to derive a consistent directory from it.

# Stop-file paths — written by fleet-intervene.sh (kill), watched by spawn-helper.sh (worker).
# Usage: _fleet_stop_file <tid> <type> [workspace]
#   type: pinger | watchdog
_fleet_stop_file() {
  local tid="$1" type="$2" workspace="${3:-./logs}"
  echo "$(_fleet_state_dir "$workspace")/ticket-auto-${tid}-${type}-stop"
}

# Spawn queue path — written by fleet-dispatch.sh, consumed by fleet-monitor.sh.
# Usage: _fleet_queue_file [workspace]
_fleet_queue_file() {
  local workspace="${1:-./logs}"
  local instance_id="${FLEET_INSTANCE_ID:-default}"
  echo "$(_fleet_state_dir "$workspace")/fleet-${instance_id}-spawn-queue.jsonl"
}

# Queue lock file path — serializes queue read+write across dispatch and monitor.
# Usage: _fleet_queue_lock [workspace]
_fleet_queue_lock() {
  local workspace="${1:-./logs}"
  echo "$(_fleet_queue_file "$workspace").lock"
}

# Run registry path — written at spawn (monitor/daemon), read at kill/restart.
# Usage: _fleet_run_file <tid> [workspace]
_fleet_run_file() {
  local tid="$1" workspace="${2:-./logs}"
  echo "$(_fleet_state_dir "$workspace")/${tid}-run.json"
}

# Fence marker path — written at kill, read by flow.sh pre-mutation guard.
# Usage: _fleet_fence_file <tid> [workspace]
_fleet_fence_file() {
  local tid="$1" workspace="${2:-./logs}"
  echo "$(_fleet_state_dir "$workspace")/${tid}-fence"
}
