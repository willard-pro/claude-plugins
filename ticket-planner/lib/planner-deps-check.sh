#!/usr/bin/env bash
# planner-deps-check.sh — Dependency acyclicity validation for planned tickets.
#
# Validates that a set of blocked-by dependencies forms a DAG before any tickets
# are created. A cycle would produce tickets that can never dispatch — a deadlock
# the pipeline cannot diagnose.
#
# Usage:
#   planner_deps_check_acyclic <deps_json>
#     deps_json: JSON object mapping ticket-id → [list of blocked-by IDs]
#     Returns: 0 if acyclic, 1 if cyclic (reports cycle to stderr).
#
#   planner_deps_topological_sort <deps_json>
#     Returns topological order as JSON array. Empty array if cyclic.
#
# Sourceable library — no set -euo pipefail.

# ── Cycle detection (DFS-based) ────────────────────────────────────────────────

# Check whether a dependency graph is acyclic.
# Input: JSON object {"TICKET-1": ["TICKET-2"], "TICKET-2": []}
# Output: exit 0 if acyclic, exit 1 if cyclic (writes cycle path to stderr).
planner_deps_check_acyclic() {
  local deps_json="$1"

  if [ -z "$deps_json" ] || [ "$deps_json" = "{}" ]; then
    return 0 # Empty graph is trivially acyclic
  fi

  # Use tsort (standard Unix utility) for topological sort.
  # tsort reads pairs (A B) meaning A → B (A depends on B, so B must come first).
  # We write pairs as "blocker ticket" (ticket depends on blocker, so blocker first).
  local pairs
  pairs=$(echo "$deps_json" | jq -r '
    to_entries[] |
    .key as $ticket |
    .value[]? |
    "\(. ) \($ticket)"
  ' 2>/dev/null)

  if [ -z "$pairs" ]; then
    return 0 # No edges — trivially acyclic
  fi

  # Run tsort with timeout to prevent unbounded hang on malformed graphs.
  # POSIX specifies no upper bound on tsort runtime.
  local tsort_timeout="${PLANNER_TSORT_TIMEOUT:-30}"
  if echo "$pairs" | timeout "$tsort_timeout" tsort >/dev/null 2>&1; then
    return 0
  else
    local tsort_rc=$?
    if [ "$tsort_rc" -eq 124 ]; then
      echo "planner-deps-check: tsort timed out after ${tsort_timeout}s — dependency graph may be malformed" >&2
    else
      echo "planner-deps-check: cycle detected in dependency graph" >&2
    fi
    # Try to identify the cycle for diagnostics
    local cycle_info
    cycle_info=$(echo "$pairs" | timeout "$tsort_timeout" tsort 2>&1 || true)
    echo "planner-deps-check: tsort output: $cycle_info" >&2
    return 1
  fi
}

# ── Topological sort ───────────────────────────────────────────────────────────

# Return topological order as a JSON array. Empty array if cyclic.
# Usage: planner_deps_topological_sort <deps_json>
planner_deps_topological_sort() {
  local deps_json="$1"

  if [ -z "$deps_json" ] || [ "$deps_json" = "{}" ]; then
    echo "[]"
    return 0
  fi

  local pairs
  pairs=$(echo "$deps_json" | jq -r '
    to_entries[] |
    .key as $ticket |
    .value[]? |
    "\(. ) \($ticket)"
  ' 2>/dev/null)

  if [ -z "$pairs" ]; then
    echo "[]"
    return 0
  fi

  local sorted
  if sorted=$(echo "$pairs" | tsort 2>/dev/null); then
    echo "$sorted" | jq -R -s 'split("\n") | map(select(length > 0))' 2>/dev/null
    return 0
  else
    echo "[]"
    return 1
  fi
}

# ── Dependency helpers ─────────────────────────────────────────────────────────

# Extract blocked-by dependencies from a set of planned tickets.
# Input: JSON array of ticket objects with "id" and "blocked_by" fields.
# Output: JSON object mapping ticket-id → [blocked-by IDs].
# Usage: planner_deps_from_tickets <tickets_json>
planner_deps_from_tickets() {
  local tickets_json="$1"
  echo "$tickets_json" | jq '[
    .[] | select(.blocked_by != null and (.blocked_by | length) > 0) |
    {key: .id, value: .blocked_by}
  ] | from_entries' 2>/dev/null || echo "{}"
}

# Validate that all blocked-by targets exist in the ticket set.
# A ticket depending on a non-existent ticket is an error — it can never dispatch.
# Usage: planner_deps_validate_targets <deps_json> <ticket_ids_json>
# Returns: 0 if all targets exist, 1 with missing IDs on stderr.
planner_deps_validate_targets() {
  local deps_json="$1" ticket_ids_json="$2"

  local missing
  missing=$(echo "$deps_json" | jq -r --argjson ids "$ticket_ids_json" '
    to_entries[] | .value[]? |
    select(. as $dep | $ids | index($dep) | not)
  ' 2>/dev/null | sort -u)

  if [ -n "$missing" ]; then
    echo "planner-deps-check: blocked-by targets not in ticket set:" >&2
    echo "$missing" | while read -r id; do
      echo "  - $id" >&2
    done
    return 1
  fi
  return 0
}
