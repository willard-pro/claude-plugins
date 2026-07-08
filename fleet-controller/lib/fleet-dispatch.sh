#!/usr/bin/env bash
# Fleet dispatch script — enqueues planned child tickets from initiative epics.
#
# Reads an initiative epic from Linear, validates state:execution label,
# finds child tickets with planned label in Backlog state, resolves
# blocked-by dependencies, and writes to the spawn queue JSONL for
# consumption by fleet-monitor.sh.
#
# NOTE: Does NOT set -euo pipefail — this is a sourceable library.
# Callers are responsible for shell flags.

_DISPATCH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source linear-api.sh from canonical path (synced by ticket-auto-pipeline SessionStart hook)
if ! declare -f get_issue >/dev/null 2>&1; then
  for _lp in "$HOME/.claude/skills/lib/linear-api.sh" "$_DISPATCH_DIR/../ticket-auto-pipeline/lib/linear-api.sh"; do
    [ -f "$_lp" ] && source "$_lp" && break
  done
fi

# ── Helpers ──────────────────────────────────────────────────────────────────────

# Check if a ticket is already in the spawn queue.
# Args: tid, queue_file
_queue_has_ticket() {
  local tid="$1"
  local queue_file="$2"
  [ ! -f "$queue_file" ] && return 1
  grep -q "\"tid\":\"${tid}\"" "$queue_file" 2>/dev/null
}

# Get current active pipeline count by counting non-completed pipeline logs.
# Args: workspace
_active_pipeline_count() {
  local workspace="${1:-${FLEET_PIPELINE_LOG_DIR:-./logs}}"
  local count=0
  if [ -d "$workspace" ]; then
    for log_file in "$workspace"/*-pipeline.log; do
      [ -f "$log_file" ] || continue
      command grep -q '|META|outcome|' "$log_file" 2>/dev/null && continue
      count=$((count + 1))
    done
  fi
  echo "$count"
}

# ── fleet_dispatch_initiative ────────────────────────────────────────────────────
# Main entry point: dispatch planned child tickets from an initiative epic.
# Usage: fleet_dispatch_initiative <initiative_id> [workspace]
fleet_dispatch_initiative() {
  local initiative_id="$1"
  local workspace="${2:-${FLEET_PIPELINE_LOG_DIR:-./logs}}"
  local instance_id="${FLEET_INSTANCE_ID:-default}"
  local queue_file="/tmp/fleet-${instance_id}-spawn-queue.jsonl"
  local max_concurrent="${FLEET_MAX_CONCURRENT:-3}"
  local dry_run="${FLEET_DRY_RUN:-false}"

  if [ -z "$initiative_id" ]; then
    echo "ERROR: initiative_id required" >&2
    echo "Usage: fleet_dispatch_initiative <INITIATIVE_ID> [workspace]" >&2
    return 1
  fi

  if ! declare -f get_issue >/dev/null 2>&1; then
    echo "ERROR: linear-api.sh not available — cannot query Linear" >&2
    return 1
  fi

  # Step 1: Validate initiative epic exists and has state:execution label
  echo "fleet_dispatch: validating initiative ${initiative_id}..."
  local epic_json
  if ! epic_json=$(get_issue "$initiative_id" 2>/dev/null); then
    echo "ERROR: initiative ${initiative_id} not found in Linear" >&2
    return 1
  fi

  local epic_labels
  epic_labels=$(echo "$epic_json" | jq -r '.data.issue.labels.nodes[]?.name // empty' 2>/dev/null)
  if ! echo "$epic_labels" | grep -q "state:execution"; then
    echo "initiative ${initiative_id} not in execution state (missing state:execution label)"
    return 0
  fi

  echo "fleet_dispatch: initiative ${initiative_id} validated (state:execution)"

  # Step 2: Find child tickets with planned label + Backlog state
  echo "fleet_dispatch: enumerating child tickets..."
  local children_json
  children_json=$(echo "$epic_json" | jq -c '.data.issue.children.nodes[] // empty' 2>/dev/null)
  if [ -z "$children_json" ]; then
    echo "no child tickets found for ${initiative_id}"
    return 0
  fi

  # Collect dispatchable tickets
  local dispatchable=""
  while IFS= read -r child; do
    [ -z "$child" ] && continue
    local child_id child_state child_labels
    child_id=$(echo "$child" | jq -r '.identifier // empty')
    child_state=$(echo "$child" | jq -r '.state.name // empty')
    child_labels=$(echo "$child" | jq -r '.labels.nodes[]?.name // empty' 2>/dev/null)

    # Must have planned label AND Backlog state
    if [ "$child_state" != "Backlog" ]; then
      continue
    fi
    if ! echo "$child_labels" | grep -q "planned"; then
      continue
    fi

    echo "  checking ${child_id} (planned, Backlog)..."

    # Step 3: Resolve blocked-by dependencies
    local blocked_labels
    blocked_labels=$(echo "$child_labels" | grep -oP 'blocked-by:\K[A-Z]+-\d+' || true)
    local is_blocked=false

    for blocker_id in $blocked_labels; do
      [ -z "$blocker_id" ] && continue
      local blocker_json blocker_state
      if blocker_json=$(get_issue "$blocker_id" 2>/dev/null); then
        blocker_state=$(echo "$blocker_json" | jq -r '.data.issue.state.name // empty' 2>/dev/null)
        if [ "$blocker_state" != "Done" ]; then
          echo "    blocked by ${blocker_id} (state: ${blocker_state}) — skipping"
          is_blocked=true
          break
        else
          echo "    blocked-by ${blocker_id} resolved (Done)"
        fi
      fi
    done

    [ "$is_blocked" = "true" ] && continue

    # Get priority for sorting
    local priority
    priority=$(echo "$child" | jq -r '.priority // 0' 2>/dev/null)
    [ -z "$priority" ] && priority=0

    dispatchable="${dispatchable}${priority}|${child_id}"$'\n'
  done <<<"$children_json"

  # Sort by priority (descending)
  local sorted
  sorted=$(echo "$dispatchable" | sort -t'|' -k1 -rn | grep -v '^$' || true)
  if [ -z "$sorted" ]; then
    echo "no dispatchable tickets for ${initiative_id}"
    return 0
  fi

  # Step 4: Enforce FLEET_MAX_CONCURRENT
  local active_count max_to_enqueue
  active_count=$(_active_pipeline_count "$workspace")
  max_to_enqueue=$((max_concurrent - active_count))
  [ "$max_to_enqueue" -le 0 ] && echo "fleet_dispatch: at capacity (${active_count}/${max_concurrent} active)" && return 0

  echo "fleet_dispatch: ${active_count}/${max_concurrent} active, can enqueue up to ${max_to_enqueue}"

  # Step 5: Write spawn queue
  local enqueued=0
  while IFS='|' read -r priority child_id; do
    [ -z "$child_id" ] && continue
    [ "$enqueued" -ge "$max_to_enqueue" ] && break

    # Idempotency: skip if already in queue
    if _queue_has_ticket "$child_id" "$queue_file"; then
      echo "  skip ${child_id} (already queued)"
      continue
    fi

    local entry
    entry=$(jq -nc \
      --arg tid "$child_id" \
      --arg reason "planned-dispatch from ${initiative_id}" \
      --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      --argjson restarts 0 \
      --arg dispatch_type "initial" \
      '{tid: $tid, reason: $reason, timestamp: $timestamp, restarts: $restarts, dispatch_type: $dispatch_type}')

    if [ "$dry_run" = "true" ]; then
      echo "[DRY-RUN] would enqueue: ${entry}"
    else
      echo "$entry" >>"$queue_file"
      echo "  enqueued ${child_id} (priority=${priority})"
    fi
    enqueued=$((enqueued + 1))
  done <<<"$sorted"

  if [ "$dry_run" = "true" ]; then
    echo "[DRY-RUN] would enqueue ${enqueued} ticket(s) for ${initiative_id}"
  else
    echo "fleet_dispatch: enqueued ${enqueued} ticket(s) for ${initiative_id} → ${queue_file}"
  fi

  return 0
}

# ── Sourceable/executable guard ──────────────────────────────────────────────────
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  INITIATIVE_ID="${1:-}"
  WORKSPACE="${2:-${FLEET_PIPELINE_LOG_DIR:-./logs}}"
  fleet_dispatch_initiative "$INITIATIVE_ID" "$WORKSPACE"
fi
