#!/usr/bin/env bash
# worktree.sh — git worktree isolation for ticket-auto-pipeline.
# Sourceable bash library. Does NOT set -euo pipefail (caller controls error
# handling). Replaces the shared-clone checkout model with per-ticket worktrees
# so concurrent ticket runs don't collide.
#
# Path formula: $REPOS_ROOT/.ticket-auto/worktrees/{TICKET_ID}/{repo-slug}
#
# Dependencies: config.sh (for $REPOS_ROOT)
#
# Usage:
#   source lib/worktree.sh
#   path=$(worktree_path "CRE-123" "my-repo")
#   ensure_worktree "CRE-123" "/path/to/repo" "feat/CRE-123-fix" "develop"
#   release_worktree "CRE-123"
#   worktree_gc

# ── Public API ──────────────────────────────────────────────────────────────

# worktree_path <TICKET_ID> <repo_slug>
# Pure path computation — no side effects, no git calls.
# Returns $REPOS_ROOT/.ticket-auto/worktrees/{TICKET_ID}/{repo-slug}
worktree_path() {
  local ticket_id="$1"
  local repo_slug="$2"
  echo "${REPOS_ROOT:-.}/.ticket-auto/worktrees/${ticket_id}/${repo_slug}"
}

# ensure_worktree <TICKET_ID> <repo_path> <branch> <base>
# Ensures a git worktree exists at the computed path on the given branch.
# Creates it when absent; reuses when present on the expected branch.
# Exits non-zero when present on a different branch (identity guard).
# Prints the resolved worktree path on stdout.
ensure_worktree() {
  local ticket_id="$1"
  local repo_path="$2"
  local branch="$3"
  local base="$4"
  local repo_slug
  repo_slug=$(basename "$repo_path")
  local wt_path
  wt_path=$(worktree_path "$ticket_id" "$repo_slug")

  # Already exists — check identity
  if [ -d "$wt_path/.git" ] || [ -f "$wt_path/.git" ]; then
    local current_branch
    current_branch=$(git -C "$wt_path" rev-parse --abbrev-ref HEAD 2>/dev/null || true)

    if [ "$current_branch" = "$branch" ]; then
      # Idempotent: same branch, reuse
      echo "$wt_path"
      return 0
    fi

    # Identity guard: different branch — refuse to re-checkout
    echo "worktree: $wt_path exists on branch '$current_branch', expected '$branch' — refusing to re-checkout" >&2
    return 2
  fi

  # Doesn't exist — create it
  mkdir -p "$(dirname "$wt_path")"

  # Fetch origin to ensure the base ref is current
  git -C "$repo_path" fetch origin 2>/dev/null || true

  # Check if the branch already exists locally in the main repo
  if git -C "$repo_path" rev-parse --verify "$branch" >/dev/null 2>&1; then
    # Branch exists — create worktree on it
    git -C "$repo_path" worktree add "$wt_path" "$branch" >/dev/null 2>&1
  else
    # Branch doesn't exist yet — create it off the base
    git -C "$repo_path" worktree add -b "$branch" "$wt_path" "$base" >/dev/null 2>&1
  fi

  echo "$wt_path"
  return 0
}

# release_worktree <TICKET_ID>
# Removes all worktrees for a ticket. Idempotent — safe to call multiple times.
# Non-fatal: failures warn but don't exit non-zero (worktree removal is cleanup,
# not a correctness requirement).
release_worktree() {
  local ticket_id="$1"
  local wt_base="${REPOS_ROOT:-.}/.ticket-auto/worktrees/${ticket_id}"

  if [ ! -d "$wt_base" ]; then
    return 0
  fi

  for wt_dir in "$wt_base"/*/; do
    [ -d "$wt_dir" ] || continue
    # Check it's actually a git worktree
    if [ -f "$wt_dir/.git" ] || [ -d "$wt_dir/.git" ]; then
      local repo_path
      repo_path=$(git -C "$wt_dir" rev-parse --git-common-dir 2>/dev/null | sed 's|/.git/worktrees/.*||' || true)
      if [ -n "$repo_path" ] && [ -d "$repo_path" ]; then
        git -C "$repo_path" worktree remove "$wt_dir" --force 2>/dev/null || {
          echo "worktree: failed to remove $wt_dir — continuing" >&2
        }
      fi
    fi
  done

  # Clean up the ticket's worktree directory
  rm -rf "$wt_base" 2>/dev/null || true

  # Prune stale entries
  git worktree prune 2>/dev/null || true

  return 0
}

# worktree_gc
# Garbage-collect worktrees for tickets in terminal Linear states.
# Terminal states: Done, Cancelled. Reads terminal_tickets list from a temp file
# or env variable. Prunes stale administrative entries after removal.
worktree_gc() {
  local wt_root="${REPOS_ROOT:-.}/.ticket-auto/worktrees"

  if [ ! -d "$wt_root" ]; then
    return 0
  fi

  # Terminal tickets are passed as args or via WORKTREE_GC_TICKETS env
  local terminal_ids="${WORKTREE_GC_TICKETS:-}"

  for ticket_dir in "$wt_root"/*/; do
    [ -d "$ticket_dir" ] || continue
    local tid
    tid=$(basename "$ticket_dir")

    # Check if this ticket is terminal
    if [ -n "$terminal_ids" ] && echo "$terminal_ids" | grep -qw "$tid"; then
      release_worktree "$tid"
    fi
  done

  # Prune any stale git worktree entries
  git worktree prune 2>/dev/null || true

  return 0
}

# ── Self-test mode ──────────────────────────────────────────────────────────

if [ "${1:-}" = "--self-test" ]; then
  set --
  echo "Running self-tests..."

  # Path computation (no side effects)
  REPOS_ROOT=/tmp/test-repos
  path=$(worktree_path "CRE-123" "my-service")
  expected="/tmp/test-repos/.ticket-auto/worktrees/CRE-123/my-service"
  [ "$path" = "$expected" ] && echo "✓ worktree_path correct" || echo "✗ worktree_path: got '$path', expected '$expected'"

  # Path with empty REPOS_ROOT
  REPOS_ROOT=""
  path=$(worktree_path "CRE-456" "api")
  [[ "$path" == *"/.ticket-auto/worktrees/CRE-456/api" ]] && echo "✓ worktree_path with default REPOS_ROOT" || echo "✗ worktree_path default: '$path'"

  echo "Self-tests complete."
  exit 0
fi
