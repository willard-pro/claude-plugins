#!/usr/bin/env bash
# audit-drift-check.sh — Deterministic delta detection for ticket-audit re-runs.
# Compares current Linear response against snapshot inventory to find changed/new tickets.
# No LLM. Pure bash.
#
# Input (two JSON files):
#   $1: path to snapshot JSON (from ## Ticket Inventory section of previous report)
#   $2: path to current Linear response JSON (from get_milestone_issues or get_parent_with_children)
#
# Output (sourceable):
#   CHANGED_IDS="id1 id2 ..."   — tickets with newer updatedAt than snapshot
#   NEW_IDS="id3 id4 ..."       — tickets not in snapshot at all
#
# Usage:
#   source audit-drift-check.sh snapshot.json current.json
#   echo "Changed: $CHANGED_IDS"
#   echo "New: $NEW_IDS"

set -eo pipefail

audit_drift_check() {
  local snapshot_file="$1"
  local current_file="$2"

  if [ ! -f "$snapshot_file" ] || [ ! -f "$current_file" ]; then
    echo "audit-drift-check: missing input file(s)" >&2
    exit 1
  fi

  CHANGED_IDS=""
  NEW_IDS=""

  # For each ticket in current, check if newer or new
  local current_ids
  current_ids=$(jq -r '.[].id' "$current_file" 2>/dev/null || echo "")

  for cid in $current_ids; do
    # Get current updatedAt
    local curr_updated
    curr_updated=$(jq -r --arg id "$cid" '.[] | select(.id == $id) | .updatedAt' "$current_file" 2>/dev/null || echo "")

    # Check if this ID exists in snapshot
    local snap_updated
    snap_updated=$(jq -r --arg id "$cid" '.[] | select(.id == $id) | .updatedAt' "$snapshot_file" 2>/dev/null || echo "")

    if [ -z "$snap_updated" ]; then
      # Not in snapshot → new ticket
      NEW_IDS="$NEW_IDS $cid"
    elif [ -n "$curr_updated" ] && [ "$curr_updated" != "$snap_updated" ]; then
      # Compare ISO timestamps lexicographically (works for ISO 8601)
      if [[ "$curr_updated" > "$snap_updated" ]]; then
        CHANGED_IDS="$CHANGED_IDS $cid"
      fi
    fi
  done

  # Trim leading/trailing whitespace
  CHANGED_IDS=$(echo "$CHANGED_IDS" | xargs)
  NEW_IDS=$(echo "$NEW_IDS" | xargs)

  echo "CHANGED_IDS=\"$CHANGED_IDS\""
  echo "NEW_IDS=\"$NEW_IDS\""
}

# Allow sourcing or direct execution
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  audit_drift_check "$@"
fi
