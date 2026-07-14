#!/usr/bin/env bash
# appraise-exec-planned.sh — adopt planner proposal for planned tickets.
# Sourceable bash library. Does NOT set -euo pipefail (caller controls error
# handling). Replaces a 22-line inline bash block previously embedded in
# ticket-appraise-exec SKILL.md Step 3-Complex.
#
# Exit codes:
#   0 — proposal adopted (caller skips /opsx:propose)
#   1 — no planner proposal exists (caller runs /opsx:propose)
#   2 — proposal exists but copy failed (caller should abort)
#
# Dependencies: planner-artifacts.sh (for has_planner_proposal, resolve_planner_dir)
#
# Usage:
#   source lib/appraise-exec-planned.sh
#   adopt_planner_proposal "CRE-123" "cre-123-fix-bug" "$LOG_FILE"
#   case $? in
#     0) echo "Proposal adopted — skip /opsx:propose" ;;
#     1) echo "No planner proposal — run /opsx:propose" ;;
#     2) echo "Copy failed — abort" ;;
#   esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source planner-artifacts.sh for has_planner_proposal / resolve_planner_dir
# — declare-guard so re-sourcing by a caller that already loaded it is harmless.
if ! declare -f has_planner_proposal >/dev/null 2>&1; then
  source "$SCRIPT_DIR/planner-artifacts.sh"
fi

# ── Public API ────────────────────────────────────────────────────────────────

# adopt_planner_proposal <ticket-id> <change-name> [log-file]
# Copies planner/proposal.md into openspec/changes/<change-name>/proposal.md.
# Returns 0 if adopted, 1 if no proposal exists (caller should run /opsx:propose),
# 2 if the copy operation fails.
adopt_planner_proposal() {
  local ticket_id="$1"
  local change_name="$2"
  local log_file="${3:-}"

  # Guard: required args
  if [ -z "$ticket_id" ] || [ -z "$change_name" ]; then
    echo "adopt_planner_proposal: missing required arguments (ticket-id and change-name)" >&2
    return 1
  fi

  # Check for planner proposal
  if ! has_planner_proposal "$ticket_id" 2>/dev/null; then
    return 1
  fi

  local planner_dir
  planner_dir=$(resolve_planner_dir "$ticket_id" 2>/dev/null) || {
    echo "adopt_planner_proposal: failed to resolve planner dir for $ticket_id" >&2
    return 2
  }

  # Validate change_name: lowercase alphanumeric + hyphens, no traversal.
  # Same pattern as planner-artifacts.sh path validation.
  if ! [[ "$change_name" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]]; then
    echo "adopt_planner_proposal: invalid change_name '$change_name'" >&2
    return 2
  fi

  local src="$planner_dir/proposal.md"
  local dest_dir="openspec/changes/$change_name"
  local dest="$dest_dir/proposal.md"

  # Verify source exists (has_planner_proposal already checked, but be defensive)
  if [ ! -f "$src" ]; then
    echo "adopt_planner_proposal: proposal not found at $src" >&2
    return 1
  fi

  mkdir -p "$dest_dir" || {
    echo "adopt_planner_proposal: failed to create $dest_dir" >&2
    return 2
  }

  # Defense-in-depth: verify destination stays within expected prefix
  local resolved_dest expected_prefix
  resolved_dest=$(realpath "$dest" 2>/dev/null) || true
  expected_prefix=$(realpath "openspec/changes/" 2>/dev/null) || true
  if [ -n "$expected_prefix" ] && [ -n "$resolved_dest" ]; then
    if [[ "$resolved_dest" != "$expected_prefix"/* ]]; then
      echo "adopt_planner_proposal: path traversal rejected — '$dest' resolves outside '$expected_prefix'" >&2
      return 2
    fi
    dest="$resolved_dest"
  fi

  cp "$src" "$dest" || {
    echo "adopt_planner_proposal: failed to copy $src → $dest" >&2
    return 2
  }

  # Log adoption (log_file must be under /tmp/ or a ticket workspace)
  if [ -n "$log_file" ]; then
    if ! [[ "$log_file" =~ ^(/tmp/|[./]?[A-Za-z0-9]) ]]; then
      echo "adopt_planner_proposal: log_file path rejected '$log_file'" >&2
      return 2
    fi
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|EXEC|create-artifact|done|openspec (planner proposal reused)" >> "$log_file"
  fi

  return 0
}

# ── Self-test mode ────────────────────────────────────────────────────────────

if [ "${1:-}" = "--self-test" ]; then
  echo "Running self-tests..."
  tmpdir=$(mktemp -d)
  trap 'rm -rf "$tmpdir"' EXIT

  # Set up fake planner plane
  PLANE_DIR="$tmpdir/.ticket-auto/initiatives/INIT-1/tickets/TEST-1/planner"
  mkdir -p "$PLANE_DIR"
  echo "# Test Proposal" > "$PLANE_DIR/proposal.md"

  # Override REPOS_ROOT for testing
  export REPOS_ROOT="$tmpdir"

  # Override planner-artifacts functions to use test plane
  has_planner_proposal() { true; }
  resolve_planner_dir() { echo "$PLANE_DIR"; }

  # Test 1: Successful adoption
  cd "$tmpdir"
  if adopt_planner_proposal "TEST-1" "test-1-fix" "/tmp/test-adopt.log"; then
    if [ -f "openspec/changes/test-1-fix/proposal.md" ]; then
      echo "✓ successful adoption"
    else
      echo "✗ adoption returned 0 but file missing"
    fi
  else
    echo "✗ adoption failed (exit $?)"
  fi

  # Test 2: No proposal → exit 1
  has_planner_proposal() { false; }
  if ! adopt_planner_proposal "TEST-2" "test-2-fix" 2>/dev/null; then
    rc=$?
    [ "$rc" = "1" ] && echo "✓ no proposal → exit 1" || echo "✗ no proposal → exit $rc (expected 1)"
  fi

  # Test 3: Missing args → exit 1
  if ! adopt_planner_proposal "" "name" 2>/dev/null; then
    rc=$?
    [ "$rc" = "1" ] && echo "✓ missing ticket-id → exit 1" || echo "✗ missing ticket-id → exit $rc"
  fi

  echo "Self-tests complete — run test-appraise-exec-planned.sh for full coverage."
  exit 0
fi
