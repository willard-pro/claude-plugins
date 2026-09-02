#!/usr/bin/env bash
# test-planner-crosscheck-repo-ref.sh — Tests for planner-crosscheck-repo-ref.sh
# (issue #217: Crosscheck must resolve against the ref Discovery explored,
# not whatever branch the live REPOS_ROOT checkout happens to be on).
#
# Run: bash ticket-planner/lib/tests/test-planner-crosscheck-repo-ref.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/.."

source "${LIB_DIR}/planner-state.sh"
source "${LIB_DIR}/planner-crosscheck-repo-ref.sh"
source "${LIB_DIR}/planner-crosscheck-citations.sh"

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

export REPOS_ROOT="${TMPDIR}/repos"
mkdir -p "$REPOS_ROOT"

PASS=0
FAIL=0
pass() {
  echo "  PASS $1"
  PASS=$((PASS + 1))
}
fail() {
  echo "  FAIL $1: $2"
  FAIL=$((FAIL + 1))
}

echo "=== planner-crosscheck-repo-ref tests ==="

# ── Fixture: a git repo with two branches that genuinely differ ────────────
# Mirrors the VS-2 defect exactly: worker/metrics.py exists on develop only.

REPO_DIR="${REPOS_ROOT}/ledgerly"
mkdir -p "${REPO_DIR}/worker"
git -C "$REPOS_ROOT" init -q ledgerly
git -C "$REPO_DIR" config user.email "test@example.com"
git -C "$REPO_DIR" config user.name "Test"

echo "def handler(): pass" >"${REPO_DIR}/worker/main.py"
git -C "$REPO_DIR" add -A
git -C "$REPO_DIR" commit -q -m "main: baseline"
git -C "$REPO_DIR" branch -M main

git -C "$REPO_DIR" checkout -q -b develop
cat >"${REPO_DIR}/worker/metrics.py" <<'EOF'
def record_metric(name, value):
    pass
EOF
git -C "$REPO_DIR" add -A
git -C "$REPO_DIR" commit -q -m "develop: add metrics module"
DEVELOP_SHA=$(git -C "$REPO_DIR" rev-parse HEAD)

# Live checkout lands back on main — develop's file is now invisible to a
# plain filesystem resolve.
git -C "$REPO_DIR" checkout -q main

INIT_ID="INIT-217-test"
planner_state_init "$INIT_ID" "test idea" >/dev/null 2>&1

# ── planner_crosscheck_repo_refs: read-back ─────────────────────────────────

echo "--- planner_crosscheck_repo_refs ---"

OUT=$(planner_crosscheck_repo_refs "$INIT_ID")
if [ -z "$OUT" ]; then
  pass "no repo-ref entries yet returns nothing"
else
  fail "no repo-ref entries yet returns nothing" "$OUT"
fi

planner_state_write "$INIT_ID" "META" "discovery" "repo-ref" "ledgerly@develop@${DEVELOP_SHA}"

OUT=$(planner_crosscheck_repo_refs "$INIT_ID")
if [ "$OUT" = "ledgerly develop ${DEVELOP_SHA}" ]; then
  pass "reads back the recorded repo-ref"
else
  fail "reads back the recorded repo-ref" "$OUT"
fi

# Last-write-wins per repo.
OTHER_SHA="0000000000000000000000000000000000abcd"
planner_state_write "$INIT_ID" "META" "discovery" "repo-ref" "ledgerly@main@${OTHER_SHA}"
OUT=$(planner_crosscheck_repo_refs "$INIT_ID")
if [ "$OUT" = "ledgerly main ${OTHER_SHA}" ]; then
  pass "last-write-wins per repo"
else
  fail "last-write-wins per repo" "$OUT"
fi

# Restore the develop repo-ref for the rest of the tests.
planner_state_write "$INIT_ID" "META" "discovery" "repo-ref" "ledgerly@develop@${DEVELOP_SHA}"

# ── planner_crosscheck_repo_ref_ensure ──────────────────────────────────────

echo "--- planner_crosscheck_repo_ref_ensure ---"

LIVE_SHA=$(git -C "$REPO_DIR" rev-parse HEAD)
OUT=$(planner_crosscheck_repo_ref_ensure "$REPOS_ROOT" "ledgerly" "main" "$LIVE_SHA")
if [ -z "$OUT" ]; then
  pass "matching live checkout is a no-op (no worktree, no exclusion)"
else
  fail "matching live checkout is a no-op" "$OUT"
fi

OUT=$(planner_crosscheck_repo_ref_ensure "$REPOS_ROOT" "ledgerly" "develop" "$DEVELOP_SHA")
if [ "$OUT" = "ledgerly" ]; then
  pass "mismatched live checkout returns the live dir's basename to exclude"
else
  fail "mismatched live checkout returns the live dir's basename to exclude" "$OUT"
fi

WORKTREE_DIR=$(find "$REPOS_ROOT" -maxdepth 1 -type d -name 'ledgerly-crosscheck-develop-*' | head -1)
if [ -n "$WORKTREE_DIR" ] && [ -f "${WORKTREE_DIR}/worker/metrics.py" ]; then
  pass "worktree created alongside the live repo, containing develop's file"
else
  fail "worktree created alongside the live repo, containing develop's file" "dir='$WORKTREE_DIR'"
fi

if [ "$(git -C "$REPO_DIR" rev-parse --abbrev-ref HEAD)" = "main" ]; then
  pass "live checkout is untouched — still on main"
else
  fail "live checkout is untouched — still on main" "$(git -C "$REPO_DIR" rev-parse --abbrev-ref HEAD)"
fi

# Idempotent — a second call reuses the existing worktree rather than failing.
OUT2=$(planner_crosscheck_repo_ref_ensure "$REPOS_ROOT" "ledgerly" "develop" "$DEVELOP_SHA")
if [ "$OUT2" = "ledgerly" ]; then
  pass "second call is idempotent (reuses the existing worktree)"
else
  fail "second call is idempotent" "$OUT2"
fi

# Non-git directory — best-effort no-op, never fatal.
mkdir -p "${REPOS_ROOT}/not-a-repo"
OUT=$(planner_crosscheck_repo_ref_ensure "$REPOS_ROOT" "not-a-repo" "develop" "deadbeef")
if [ -z "$OUT" ]; then
  pass "non-git repo dir is a silent no-op"
else
  fail "non-git repo dir is a silent no-op" "$OUT"
fi

# ── End-to-end: planner_crosscheck_citations resolves against the pinned ref ─

echo "--- planner_crosscheck_citations resolves against Discovery's pinned ref ---"

ARTIFACTS_DIR="${REPOS_ROOT}/.ticket-auto/initiatives/${INIT_ID}/artifacts"
mkdir -p "$ARTIFACTS_DIR"
cat >"${ARTIFACTS_DIR}/proposal.md" <<'EOF'
## Title
Repo-ref test proposal

## Description
Metrics are recorded via `worker/metrics.py:1`.

## Labels
planned
EOF

if planner_crosscheck_citations "$INIT_ID" >/tmp/cc-repo-ref-out.txt 2>&1; then
  pass "citation against develop-only file resolves via the pinned-ref worktree"
else
  fail "citation against develop-only file resolves via the pinned-ref worktree" "$(cat /tmp/cc-repo-ref-out.txt)"
fi

if [ "$(git -C "$REPO_DIR" rev-parse --abbrev-ref HEAD)" = "main" ]; then
  pass "live checkout still untouched after a full Crosscheck citations run"
else
  fail "live checkout still untouched after a full Crosscheck citations run" "$(git -C "$REPO_DIR" rev-parse --abbrev-ref HEAD)"
fi

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
