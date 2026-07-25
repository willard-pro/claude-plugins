#!/usr/bin/env bash
# test-worktree.sh — unit tests for lib/worktree.sh
# Creates a real git repo fixture and tests worktree create/reuse/release/GC.
# Usage: bash test-worktree.sh [test_name_filter]
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# ── CI-safe declare guards ─────────────────────────────────────────────────
if ! declare -f _plog >/dev/null 2>&1; then
  _plog() { :; }
fi
if ! declare -f hb_gate >/dev/null 2>&1; then
  hb_gate() { :; }
fi

source "$LIB_DIR/config.sh"
source "$LIB_DIR/worktree.sh"

PASS=0
FAIL=0

_run() {
  local name="$1"
  shift
  if "$@" 2>/dev/null; then
    echo "PASS: $name"
    ((PASS++)) || true
  else
    echo "FAIL: $name"
    ((FAIL++)) || true
  fi
}

_run_exit_code() {
  local name="$1"
  local expected="$2"
  shift 2
  local actual=0
  "$@" 2>/dev/null || actual=$?
  if [ "$actual" -eq "$expected" ]; then
    echo "PASS: $name (exit $actual)"
    ((PASS++)) || true
  else
    echo "FAIL: $name (expected exit $expected, got $actual)"
    ((FAIL++)) || true
  fi
}

# ── Fixture ──────────────────────────────────────────────────────────────────

# Each test gets a fresh git repo with a base branch and one commit.
# Returns: FIXTURE_REPO path, FIXTURE_DIR temporary directory.
# Cleanup via trap on FIXTURE_DIR.
_setup_fixture() {
  FIXTURE_DIR=$(mktemp -d)
  export REPOS_ROOT="$FIXTURE_DIR/repos"

  # Create a fake repo under REPOS_ROOT
  FIXTURE_REPO="$REPOS_ROOT/my-service"
  mkdir -p "$FIXTURE_REPO"
  git -C "$FIXTURE_REPO" init -b main 2>/dev/null || git -C "$FIXTURE_REPO" init
  git -C "$FIXTURE_REPO" config user.email "test@test.com"
  git -C "$FIXTURE_REPO" config user.name "Test"
  echo "hello" >"$FIXTURE_REPO/README.md"
  git -C "$FIXTURE_REPO" add -A
  git -C "$FIXTURE_REPO" commit -m "initial" --no-gpg-sign
}

echo "=== Core tests ==="
echo ""

# ── 2.2: Create case ────────────────────────────────────────────────────────

test_create_worktree() {
  _setup_fixture
  local wt_path
  wt_path=$(ensure_worktree "CRE-123" "$FIXTURE_REPO" "feat/CRE-123-fix" "main" 2>&1) || return 1

  # Worktree exists at expected path
  [ -d "$wt_path" ] || {
    echo "  worktree not at $wt_path" >&2
    return 1
  }
  # Has the README
  [ -f "$wt_path/README.md" ] || {
    echo "  README missing in worktree" >&2
    return 1
  }
  # On the expected branch
  local actual_branch
  actual_branch=$(git -C "$wt_path" rev-parse --abbrev-ref HEAD)
  [ "$actual_branch" = "feat/CRE-123-fix" ] || {
    echo "  expected branch feat/CRE-123-fix, got $actual_branch" >&2
    return 1
  }
  return 0
}
_run "create worktree at expected path on expected branch" test_create_worktree

# ── 2.3: Idempotent re-create ───────────────────────────────────────────────

test_idempotent_reuse() {
  _setup_fixture
  local wt_path1 wt_path2
  wt_path1=$(ensure_worktree "CRE-123" "$FIXTURE_REPO" "feat/CRE-123-fix" "main" 2>&1) || return 1

  # Write a file in the worktree
  echo "modified" >"$wt_path1/newfile.txt"

  # Second call — should return same path, exit 0
  wt_path2=$(ensure_worktree "CRE-123" "$FIXTURE_REPO" "feat/CRE-123-fix" "main" 2>&1) || {
    echo "  second ensure_worktree failed" >&2
    return 1
  }

  [ "$wt_path1" = "$wt_path2" ] || {
    echo "  paths differ: $wt_path1 vs $wt_path2" >&2
    return 1
  }
  # Modified file still exists (no re-checkout wiped it)
  [ -f "$wt_path2/newfile.txt" ] || {
    echo "  modified file was wiped by re-checkout" >&2
    return 1
  }
  return 0
}
_run "idempotent reuse preserves working files" test_idempotent_reuse

# ── 2.4: Wrong-branch guard ─────────────────────────────────────────────────

test_wrong_branch_guard() {
  _setup_fixture
  ensure_worktree "CRE-123" "$FIXTURE_REPO" "feat/CRE-123-fix" "main" 2>/dev/null || return 1

  # Now ask for same ticket but different branch — should fail
  local actual=0
  ensure_worktree "CRE-123" "$FIXTURE_REPO" "feat/CRE-123-other" "main" 2>/dev/null || actual=$?

  [ "$actual" -ne 0 ] || {
    echo "  should have exited non-zero on wrong branch" >&2
    return 1
  }
  return 0
}
_run "wrong branch guard exits non-zero" test_wrong_branch_guard

# ── 2.5: worktree_path purity ───────────────────────────────────────────────

test_worktree_path_purity() {
  _setup_fixture
  local before_count
  before_count=$(git -C "$FIXTURE_REPO" worktree list 2>/dev/null | wc -l)

  # Call worktree_path — should create nothing
  local path
  path=$(worktree_path "CRE-999" "my-service") 2>&1

  # No worktree was created
  [ ! -d "$path" ] || {
    echo "  worktree_path created a directory!" >&2
    return 1
  }

  local after_count
  after_count=$(git -C "$FIXTURE_REPO" worktree list 2>/dev/null | wc -l)
  [ "$before_count" = "$after_count" ] || {
    echo "  worktree count changed" >&2
    return 1
  }
  return 0
}
_run "worktree_path creates nothing" test_worktree_path_purity

echo ""
echo "=== Release tests ==="
echo ""

# ── 2.6: Release removes worktree ───────────────────────────────────────────

test_release_removes_worktree() {
  _setup_fixture
  ensure_worktree "CRE-123" "$FIXTURE_REPO" "feat/CRE-123-fix" "main" 2>/dev/null || return 1

  local wt_path
  wt_path=$(worktree_path "CRE-123" "my-service")

  # Release it
  release_worktree "CRE-123" 2>/dev/null || return 1

  # Worktree dir should be gone
  [ ! -d "$wt_path" ] || {
    echo "  worktree dir still exists after release" >&2
    return 1
  }
  # Ticket dir should be gone too
  local ticket_dir
  ticket_dir=$(dirname "$wt_path")
  [ ! -d "$ticket_dir" ] || {
    echo "  ticket dir still exists" >&2
    return 1
  }
  return 0
}
_run "release removes worktree" test_release_removes_worktree

# ── 2.7: Repeat-release idempotent ──────────────────────────────────────────

test_repeat_release_idempotent() {
  _setup_fixture
  ensure_worktree "CRE-123" "$FIXTURE_REPO" "feat/CRE-123-fix" "main" 2>/dev/null || return 1
  release_worktree "CRE-123" 2>/dev/null || return 1

  # Second release should exit 0
  local actual=0
  release_worktree "CRE-123" 2>/dev/null || actual=$?

  [ "$actual" -eq 0 ] || {
    echo "  second release_worktree exited $actual" >&2
    return 1
  }
  return 0
}
_run "repeat release exits 0" test_repeat_release_idempotent

echo ""
echo "=== GC tests ==="
echo ""

# ── 2.8: GC removes terminal ticket worktrees ───────────────────────────────

test_gc_removes_terminal() {
  _setup_fixture
  ensure_worktree "CRE-T1" "$FIXTURE_REPO" "feat/CRE-T1-fix" "main" 2>/dev/null || return 1
  ensure_worktree "CRE-T2" "$FIXTURE_REPO" "feat/CRE-T2-feat" "main" 2>/dev/null || return 1

  # T1 is terminal, T2 is not
  export WORKTREE_GC_TICKETS="CRE-T1"
  worktree_gc 2>/dev/null

  local wt_t1
  wt_t1=$(worktree_path "CRE-T1" "my-service")
  local wt_t2
  wt_t2=$(worktree_path "CRE-T2" "my-service")

  [ ! -d "$wt_t1" ] || {
    echo "  terminal ticket T1 worktree still exists" >&2
    return 1
  }
  [ -d "$wt_t2" ] || {
    echo "  non-terminal ticket T2 worktree was incorrectly removed" >&2
    return 1
  }
  return 0
}
_run "GC removes terminal ticket worktrees only" test_gc_removes_terminal

echo ""
echo "=== Edge cases ==="
echo ""

# ── 2.9: Pre-existing branch works ──────────────────────────────────────────

test_preexisting_branch() {
  _setup_fixture
  # Create the branch in the main repo first
  git -C "$FIXTURE_REPO" checkout -b "feat/existing" 2>/dev/null
  git -C "$FIXTURE_REPO" checkout main 2>/dev/null

  local wt_path
  wt_path=$(ensure_worktree "CRE-456" "$FIXTURE_REPO" "feat/existing" "main" 2>&1) || return 1

  [ -d "$wt_path" ] || {
    echo "  worktree not created for pre-existing branch" >&2
    return 1
  }
  local actual_branch
  actual_branch=$(git -C "$wt_path" rev-parse --abbrev-ref HEAD)
  [ "$actual_branch" = "feat/existing" ] || {
    echo "  on wrong branch: $actual_branch" >&2
    return 1
  }
  return 0
}
_run "pre-existing branch worktree succeeds" test_preexisting_branch

# Release non-existent ticket
test_release_nonexistent() {
  _setup_fixture
  local actual=0
  release_worktree "DOES_NOT_EXIST" 2>/dev/null || actual=$?
  [ "$actual" -eq 0 ] || {
    echo "  release of non-existent ticket should exit 0" >&2
    return 1
  }
  return 0
}
_run "release non-existent ticket exits 0" test_release_nonexistent

# GC with no worktrees
test_gc_no_worktrees() {
  _setup_fixture
  local actual=0
  worktree_gc 2>/dev/null || actual=$?
  [ "$actual" -eq 0 ] || {
    echo "  GC with no worktrees should exit 0" >&2
    return 1
  }
  return 0
}
_run "GC with no worktrees exits 0" test_gc_no_worktrees

echo ""
echo "=== Results: $((PASS + FAIL)) tests, $PASS passed, $FAIL failed ==="

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
