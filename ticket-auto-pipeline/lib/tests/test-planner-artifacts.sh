#!/usr/bin/env bash
# test-planner-artifacts.sh — unit tests for lib/planner-artifacts.sh
# Usage: bash test-planner-artifacts.sh [test_name_filter]
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# ── CI-safe declare guards ───────────────────────────────────────────────────
if ! declare -f get_issue >/dev/null 2>&1; then
  get_issue() { echo '{"description":"","labels":{"nodes":[]}}'; }
fi
if ! declare -f _plog >/dev/null 2>&1; then _plog() { :; }; fi
if ! declare -f hb_gate >/dev/null 2>&1; then hb_gate() { :; }; fi

export REPOS_ROOT="${REPOS_ROOT:-/tmp/test-repos-root}"

source "$LIB_DIR/planner-artifacts.sh"

PASS=0
FAIL=0
_pass() {
  echo "PASS: $1"
  ((PASS++)) || true
}
_fail() {
  echo "FAIL: $1"
  ((FAIL++)) || true
}

# Exit-code-safe runner: captures $? via || rc=$? which suppresses errexit
_run_exit() {
  local name="$1" expected="$2" rc=0
  shift 2
  "$@" 2>/dev/null || rc=$?
  if [ "$rc" = "$expected" ]; then
    _pass "$name"
  else
    _fail "$name (expected exit $expected, got $rc)"
  fi
}

# ── Test data ─────────────────────────────────────────────────────────────────

PLANNER_DESC='## Planner Context
**Schema-Version:** 1
**Initiative:** INIT-42
**Epic:** EPIC-1
**Confidence:** 0.92
**Strategy:** Conservative
**Decision:** Refactor collector
**Affected Services:** collector
**Target Symbols:** DebtCollector.collect:src/collector.ts:42
**Pre-approved:** true
**Generated:** 2026-07-01T12:00:00Z
**Regenerate:** false'

NO_INITIATIVE_DESC='## Planner Context
**Schema-Version:** 1
**Confidence:** 0.50'

# ── Setup ─────────────────────────────────────────────────────────────────────

TEST_DIR="$REPOS_ROOT/.ticket-auto/initiatives/INIT-42/tickets/TEST-1/planner"
rm -rf "$REPOS_ROOT/.ticket-auto"
mkdir -p "$TEST_DIR"
touch "$TEST_DIR/body.md"

# ── Tests ─────────────────────────────────────────────────────────────────────

# 1. Present dir → exit 0, correct path
rc=0
actual=$(resolve_planner_dir "TEST-1" "$PLANNER_DESC" "true" 2>/dev/null) || rc=$?
if [ "$rc" = "0" ] && echo "$actual" | grep -q "INIT-42"; then
  _pass "resolve_planner_dir: present dir → exit 0"
else
  _fail "resolve_planner_dir: expected exit 0 with INIT-42 path, got rc=$rc path='$actual'"
fi

# 2. Missing dir → exit 1
PLANNER_DESC_99=$(echo "$PLANNER_DESC" | sed 's/INIT-42/INIT-99/')
rc=0
actual=$(resolve_planner_dir "TEST-2" "$PLANNER_DESC_99" "true" 2>/dev/null) || rc=$?
if [ "$rc" = "1" ]; then
  _pass "resolve_planner_dir: missing dir → exit 1"
else
  _fail "resolve_planner_dir: expected exit 1 for missing dir, got rc=$rc"
fi

# 3. No Initiative → exit 2
rc=0
actual=$(resolve_planner_dir "TEST-3" "$NO_INITIATIVE_DESC" "true" 2>/dev/null) || rc=$?
if [ "$rc" = "2" ]; then
  _pass "resolve_planner_dir: no Initiative → exit 2"
else
  _fail "resolve_planner_dir: expected exit 2 for no Initiative, got rc=$rc"
fi

# 4. Not planned → exit 1
rc=0
actual=$(resolve_planner_dir "TEST-4" "some desc" "false" 2>/dev/null) || rc=$?
if [ "$rc" = "1" ]; then
  _pass "resolve_planner_dir: not planned → exit 1"
else
  _fail "resolve_planner_dir: expected exit 1 for not planned, got rc=$rc"
fi

# 4a. Path traversal in Initiative field → exit 1 (rejected)
TRAVERSAL_DESC=$(echo "$PLANNER_DESC" | sed 's/INIT-42/..\/..\/..\/etc/')
rc=0
actual=$(resolve_planner_dir "TEST-TRAV" "$TRAVERSAL_DESC" "true" 2>/dev/null) || rc=$?
if [ "$rc" = "1" ]; then
  _pass "resolve_planner_dir: path traversal rejected → exit 1"
else
  _fail "resolve_planner_dir: expected exit 1 for path traversal, got rc=$rc"
fi

# 4b. Path traversal in ticket ID → exit 1 (rejected)
TRAVERSAL_DESC2="$PLANNER_DESC"
rc=0
actual=$(resolve_planner_dir "../../etc" "$TRAVERSAL_DESC2" "true" 2>/dev/null) || rc=$?
if [ "$rc" = "1" ]; then
  _pass "resolve_planner_dir: path traversal in ticket ID → exit 1"
else
  _fail "resolve_planner_dir: expected exit 1 for ticket ID traversal, got rc=$rc"
fi

# 5. has_planner_body true
if has_planner_body "TEST-1" "$PLANNER_DESC" "true" 2>/dev/null; then
  _pass "has_planner_body: true when body.md exists"
else
  _fail "has_planner_body: expected true when body.md exists"
fi

# 6. has_planner_body false
rm -f "$TEST_DIR/body.md"
rc=0
has_planner_body "TEST-1" "$PLANNER_DESC" "true" 2>/dev/null || rc=$?
if [ "$rc" != "0" ]; then
  _pass "has_planner_body: false when body.md missing"
else
  _fail "has_planner_body: expected false when body.md missing"
fi

# 7. has_planner_proposal true
touch "$TEST_DIR/proposal.md"
if has_planner_proposal "TEST-1" "$PLANNER_DESC" "true" 2>/dev/null; then
  _pass "has_planner_proposal: true when proposal.md exists"
else
  _fail "has_planner_proposal: expected true when proposal.md exists"
fi

# Cleanup
rm -rf "$REPOS_ROOT/.ticket-auto"

echo "---"
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
