#!/usr/bin/env bash
# planner-artifacts.sh — resolve and check planner artifact plane directories.
# Sourceable bash library. Does NOT set -euo pipefail (caller controls error
# handling). Derives the shared filesystem path where planner-authored artifacts
# (body.md, exploration.md, proposal.md) live for a given ticket.
#
# Exit codes:
#   0 — directory present / file exists
#   1 — directory missing
#   2 — no Initiative field found in Planner Context block
#
# Dependencies: linear-api.sh (for get_issue), planned-ticket-check.sh (for
#               _extract_planner_context_block and _extract_field), jq

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/planned-ticket-check.sh"
#
# Usage:
#   source lib/planner-artifacts.sh
#   resolve_planner_dir "CRE-205"     # prints path, exit 0/1/2
#   has_planner_body "CRE-205"        # exit 0 if body.md present
#   has_planner_proposal "CRE-205"    # exit 0 if proposal.md present

# ── Public API ────────────────────────────────────────────────────────────────

# resolve_planner_dir <TID> [description] [has_planned_label]
# Prints the planner artifact directory path for the ticket.
# Fetches ticket via get_issue if description not provided inline.
# Exit 0 → directory exists (path printed), 1 → directory missing,
# 2 → no Initiative field found.
resolve_planner_dir() {
  local ticket_id="$1"
  local description="${2:-}"
  local has_planned_label="${3:-}"

  # Fetch if not provided inline (test mode bypass)
  if [ -z "$description" ]; then
    local issue_json
    issue_json=$(get_issue "$ticket_id" 2>/dev/null) || {
      echo "planner-artifacts: failed to fetch ticket $ticket_id" >&2
      return 1
    }
    description=$(echo "$issue_json" | jq -r '.description // ""')
    has_planned_label=$(echo "$issue_json" | jq -r \
      '[.labels.nodes[].name] | index("planned") != null')
  fi

  # Guard: must have planned label
  if [ "$has_planned_label" != "true" ]; then
    return 1
  fi

  # Extract the Planner Context block via shared helper
  local block
  block=$(_extract_planner_context_block "$description")

  if [ -z "$block" ]; then
    return 2
  fi

  # Extract Initiative field
  local initiative
  initiative=$(echo "$block" | _extract_field "Initiative")

  if [ -z "$initiative" ]; then
    return 2
  fi

  # Derive path: $REPOS_ROOT/.ticket-auto/initiatives/{INIT}/tickets/{TID}/planner/
  local repos_root="${REPOS_ROOT:-}"
  if [ -z "$repos_root" ]; then
    echo "planner-artifacts: REPOS_ROOT is not set" >&2
    return 1
  fi

  # Sanitize path components — reject traversal sequences and non-ID characters.
  # Initiative IDs are alphanumeric with hyphens (e.g. INIT-42).
  # Ticket IDs are uppercase alphanumeric with hyphens (e.g. CRE-205).
  if ! [[ "$initiative" =~ ^[A-Za-z0-9][-A-Za-z0-9]*$ ]]; then
    echo "planner-artifacts: invalid Initiative value '$initiative'" >&2
    return 1
  fi
  if ! [[ "$ticket_id" =~ ^[A-Za-z0-9][-A-Za-z0-9]*$ ]]; then
    echo "planner-artifacts: invalid ticket ID '$ticket_id'" >&2
    return 1
  fi

  local planner_dir="$repos_root/.ticket-auto/initiatives/$initiative/tickets/$ticket_id/planner"

  # Defense-in-depth: resolve and verify the path stays within the allowed prefix.
  # Even after character validation, ensure no symlink or filesystem trickery escapes.
  local resolved allowed_prefix
  resolved=$(realpath "$planner_dir" 2>/dev/null) || true
  allowed_prefix=$(realpath "$repos_root/.ticket-auto/initiatives/" 2>/dev/null) || true
  if [ -n "$allowed_prefix" ] && [ -n "$resolved" ]; then
    if [[ "$resolved" != "$allowed_prefix"/* ]]; then
      echo "planner-artifacts: path traversal rejected — '$planner_dir' resolves outside '$allowed_prefix'" >&2
      return 1
    fi
    planner_dir="$resolved"
  fi

  if [ -d "$planner_dir" ]; then
    echo "$planner_dir"
    return 0
  fi

  # Directory doesn't exist — print the path anyway for diagnostics, but exit 1
  echo "$planner_dir"
  return 1
}

# has_planner_body <TID> [description] [has_planned_label]
# Exit 0 if planner/body.md exists for the ticket, 1 otherwise.
has_planner_body() {
  local planner_dir
  planner_dir=$(resolve_planner_dir "$@" 2>/dev/null) || return 1

  [ -f "$planner_dir/body.md" ] && return 0
  return 1
}

# has_planner_proposal <TID> [description] [has_planned_label]
# Exit 0 if planner/proposal.md exists for the ticket, 1 otherwise.
has_planner_proposal() {
  local planner_dir
  planner_dir=$(resolve_planner_dir "$@" 2>/dev/null) || return 1

  [ -f "$planner_dir/proposal.md" ] && return 0
  return 1
}

# ── Self-test mode ────────────────────────────────────────────────────────────

if [ "${1:-}" = "--self-test" ]; then
  echo "Running self-tests..."

  # Block extraction
  desc='## Planner Context
**Initiative:** INIT-42
**Epic:** EPIC-1

## Next Section'
  block=$(_extract_planner_context_block "$desc")
  if echo "$block" | grep -q "INIT-42" 2>/dev/null; then
    echo "✓ block extraction includes Initiative"
  else
    echo "✗ block extraction missing Initiative"
  fi

  if ! echo "$block" | grep -q "Next Section"; then
    echo "✓ block extraction stops at next ## heading"
  else
    echo "✗ block extraction includes content past next ## heading"
  fi

  # resolve_planner_dir with no REPOS_ROOT → exit 1
  saved_root="${REPOS_ROOT:-}"
  unset REPOS_ROOT
  if ! resolve_planner_dir "TEST-1" "## Planner Context
**Initiative:** INIT-1" "true" 2>/dev/null; then
    echo "✓ missing REPOS_ROOT → exit 1"
  else
    echo "✗ missing REPOS_ROOT should exit 1"
  fi
  [ -n "$saved_root" ] && export REPOS_ROOT="$saved_root"

  echo "Self-tests complete — run test-planner-artifacts.sh for full coverage."
  exit 0
fi
