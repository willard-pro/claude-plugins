#!/usr/bin/env bash
# test-template-select.sh — unit tests for lib/template-select.sh
# Usage: bash test-template-select.sh [test_name_filter]
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$LIB_DIR/template-select.sh"

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

_run_output() {
  local name="$1"
  local expected="$2"
  shift 2
  local actual
  actual=$("$@" 2>/dev/null) || true
  if [ "$actual" = "$expected" ]; then
    echo "PASS: $name"
    ((PASS++)) || true
  else
    echo "FAIL: $name (expected '$expected', got '$actual')"
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

# ── Tests ─────────────────────────────────────────────────────────────────────

# 1. Known type resolution
_run_output "bug → templates/bug.md" "templates/bug.md" resolve_template bug
_run_output "feature → templates/feature.md" "templates/feature.md" resolve_template feature
_run_output "improvement → templates/improvement.md" "templates/improvement.md" resolve_template improvement
_run_output "security → templates/security.md" "templates/security.md" resolve_template security
_run_output "chore → templates/chore.md" "templates/chore.md" resolve_template chore

# 2. Alias resolution
_run_output "refactor → improvement (alias)" "templates/improvement.md" resolve_template refactor

# 3. Unknown/empty type → exit 3
_run_exit_code "unknown type (epic) → exit 3" 3 resolve_template epic
_run_exit_code "empty type → exit 3" 3 resolve_template ""

# 4. Case sensitivity: lowercase expected
_run_output "BUG (uppercase) → no match, exit 3" "" resolve_template BUG 2>/dev/null || _run_exit_code "BUG → exit 3" 3 resolve_template BUG

# 5. Determinism: repeated calls return identical result
_run() {
  local r1 r2
  r1=$(resolve_template "bug")
  r2=$(resolve_template "bug")
  [ "$r1" = "$r2" ]
}
_run "deterministic: bug returns same path twice"

# 6. All known types resolve (smoke test)
for t in bug feature improvement security chore refactor; do
  if resolve_template "$t" >/dev/null 2>&1; then
    echo "PASS: known type '$t' resolves"
    ((PASS++)) || true
  else
    echo "FAIL: known type '$t' should resolve"
    ((FAIL++)) || true
  fi
done

# ── Summary ───────────────────────────────────────────────────────────────────

echo "---"
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
