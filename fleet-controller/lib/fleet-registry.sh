#!/usr/bin/env bash
# Fleet run-registry + generation-fence helper library.
# Sourceable — no set flags.
#
# Run registry: per-ticket JSON files recording which PID owns each ticket,
# at which generation. Written at spawn, read at kill/restart.
#
# Generation fence: per-ticket marker recording the killed generation.
# flow.sh consults this to reject mutations from superseded zombie workers.

_REGISTRY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Source config for the canonical state-directory resolver
if [ -f "$_REGISTRY_DIR/config.sh" ]; then
  source "$_REGISTRY_DIR/config.sh"
fi

# ── Run registry ────────────────────────────────────────────────────────────────

# Write a run registry entry for a spawned worker.
# Usage: registry_write <tid> <pid> <generation> <reason> <state_dir>
registry_write() {
  local tid="$1"
  local pid="$2"
  local generation="$3"
  local reason="$4"
  local state_dir="${5:-$(_fleet_state_dir ./logs)}"
  local registry_file
  registry_file=$(_fleet_run_file "$tid" "$state_dir")

  jq -nc \
    --arg tid "$tid" \
    --arg pid "$pid" \
    --argjson generation "$generation" \
    --arg started_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg reason "$reason" \
    '{tid: $tid, pid: $pid, generation: $generation, started_at: $started_at, reason: $reason}' \
    >"$registry_file"
}

# Read full run registry entry for a ticket.
# Usage: registry_read <tid> <state_dir>
# Returns JSON on stdout, empty string if no registry exists.
registry_read() {
  local tid="$1"
  local state_dir="${2:-$(_fleet_state_dir ./logs)}"
  local registry_file
  registry_file=$(_fleet_run_file "$tid" "$state_dir")

  if [ -f "$registry_file" ]; then
    cat "$registry_file"
  fi
}

# Read the PID from the run registry.
# Usage: registry_pid <tid> <state_dir>
# Returns PID string, empty if no registry.
registry_pid() {
  local tid="$1"
  local state_dir="${2:-$(_fleet_state_dir ./logs)}"
  local registry_file
  registry_file=$(_fleet_run_file "$tid" "$state_dir")

  if [ -f "$registry_file" ]; then
    jq -r '.pid // empty' "$registry_file" 2>/dev/null
  fi
}

# Read the generation from the run registry.
# Usage: registry_generation <tid> <state_dir>
# Returns generation integer, 0 if no registry.
registry_generation() {
  local tid="$1"
  local state_dir="${2:-$(_fleet_state_dir ./logs)}"
  local registry_file
  registry_file=$(_fleet_run_file "$tid" "$state_dir")

  if [ -f "$registry_file" ]; then
    jq -r '.generation // 0' "$registry_file" 2>/dev/null
  else
    echo "0"
  fi
}

# Check if a run registry exists for the given ticket.
# Usage: registry_exists <tid> <state_dir>
# Returns 0 if exists, 1 otherwise.
registry_exists() {
  local tid="$1"
  local state_dir="${2:-$(_fleet_state_dir ./logs)}"
  local registry_file
  registry_file=$(_fleet_run_file "$tid" "$state_dir")

  [ -f "$registry_file" ]
}

# Remove a run registry entry (worker is gone).
# Usage: registry_clear <tid> <state_dir>
registry_clear() {
  local tid="$1"
  local state_dir="${2:-$(_fleet_state_dir ./logs)}"
  local registry_file
  registry_file=$(_fleet_run_file "$tid" "$state_dir")

  rm -f "$registry_file"
}

# ── Generation fencing ──────────────────────────────────────────────────────────

# Write a fence marker for a killed generation.
# Usage: fence_write <tid> <fenced_generation> <state_dir>
fence_write() {
  local tid="$1"
  local fenced_generation="$2"
  local state_dir="${3:-$(_fleet_state_dir ./logs)}"
  local fence_file
  fence_file=$(_fleet_fence_file "$tid" "$state_dir")

  jq -nc \
    --arg tid "$tid" \
    --argjson fenced_generation "$fenced_generation" \
    --arg fenced_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{tid: $tid, fenced_generation: $fenced_generation, fenced_at: $fenced_at}' \
    >"$fence_file"
}

# Read the fence marker for a ticket.
# Usage: fence_read <tid> <state_dir>
# Returns JSON on stdout, empty if no fence.
fence_read() {
  local tid="$1"
  local state_dir="${2:-$(_fleet_state_dir ./logs)}"
  local fence_file
  fence_file=$(_fleet_fence_file "$tid" "$state_dir")

  if [ -f "$fence_file" ]; then
    cat "$fence_file"
  fi
}

# Check if a caller generation is superseded by the fence.
# Usage: fence_is_superseded <tid> <caller_generation> <state_dir>
# Returns 0 (true) if superseded, 1 (false) if allowed.
fence_is_superseded() {
  local tid="$1"
  local caller_generation="$2"
  local state_dir="${3:-$(_fleet_state_dir ./logs)}"
  local fence_file
  fence_file=$(_fleet_fence_file "$tid" "$state_dir")

  # No fence marker → unrestricted (backward compatible)
  if [ ! -f "$fence_file" ]; then
    return 1
  fi

  local fenced_gen
  fenced_gen=$(jq -r '.fenced_generation // 0' "$fence_file" 2>/dev/null)

  # caller_gen <= fenced_gen means the caller is superseded
  if [ "$caller_generation" -le "$fenced_gen" ] 2>/dev/null; then
    return 0
  fi

  return 1
}

# Clear a fence marker (new generation spawned — fence no longer blocks).
# Usage: fence_clear <tid> <state_dir>
fence_clear() {
  local tid="$1"
  local state_dir="${2:-$(_fleet_state_dir ./logs)}"
  local fence_file
  fence_file=$(_fleet_fence_file "$tid" "$state_dir")

  rm -f "$fence_file"
}
