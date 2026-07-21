#!/usr/bin/env bash
# Don't use set -e — the feedback writer sources functions that grep logs
# where no-match exit codes are expected.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="/home/mortal/workspace/workbench/willard.pro/git/claude-plugins/ticket-auto-pipeline/lib"

source "${LIB_DIR}/planned-feedback-write.sh"

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

PASS=0
FAIL=0

pass() { echo "  PASS $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL $1: $2"; FAIL=$((FAIL + 1)); }

echo "=== planned-feedback-write.sh tests ==="

# --- Test 1: no-op when FROM_PLANNED is false ---
echo "--- Test 1: no-op for unplanned tickets ---"
FROM_PLANNED=false
log="${TMPDIR}/test1-pipeline.log"
touch "$log"
planned_feedback_write "TEST-1" "$log" || true
if ! grep -q 'planner-feedback' "$log" 2>/dev/null; then
  pass "no feedback emitted for unplanned ticket"
else
  fail "no feedback emitted" "unexpected feedback entry found"
fi

# --- Test 2: emits feedback when FROM_PLANNED is true ---
echo "--- Test 2: emits feedback for planned tickets ---"
FROM_PLANNED=true
log="${TMPDIR}/test2-pipeline.log"
echo "2026-07-21T00:00:00Z|META|outcome-label|info|Smooth" > "$log"
planned_feedback_write "TEST-2" "$log" || true
if grep -q '|META|planner-feedback|info|' "$log" 2>/dev/null; then
  pass "feedback entry emitted for planned ticket"
else
  fail "feedback entry emitted" "no planner-feedback entry found"
fi

# --- Test 3: payload is valid JSON ---
echo "--- Test 3: payload is valid JSON ---"
payload=$(grep '|META|planner-feedback|info|' "$log" | head -1 | awk -F'|' '{for(i=5;i<=NF;i++) printf "%s%s", $i, (i<NF?"|":"")}')
if echo "$payload" | jq -e . >/dev/null 2>&1; then
  pass "feedback payload is valid JSON"
else
  fail "feedback payload is valid JSON" "jq parse failed"
fi

# --- Test 4: payload has required fields ---
echo "--- Test 4: payload has required fields ---"
for field in confidence_predicted confidence_actual outcome corrections_count files_changed services_touched decision_drift; do
  if echo "$payload" | jq -e ".${field} != null" >/dev/null 2>&1; then
    pass "  field '${field}' present"
  else
    fail "  field '${field}' present" "missing or null"
  fi
done

# --- Test 5: confidence_actual computation ---
echo "--- Test 5: confidence computation ---"
actual=$(_compute_actual_confidence "Smooth" 0)
if [ "$actual" = "0.90" ]; then
  pass "Smooth + 0 corrections → 0.90"
else
  fail "Smooth + 0 corrections → 0.90" "got $actual"
fi

actual=$(_compute_actual_confidence "Rough" 2)
if [ "$actual" = "0.55" ]; then
  pass "Rough + 2 corrections → 0.55"
else
  fail "Rough + 2 corrections → 0.55" "got $actual"
fi

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -gt 0 ] && exit 1 || exit 0
