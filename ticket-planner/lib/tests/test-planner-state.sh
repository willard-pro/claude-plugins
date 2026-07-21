#!/usr/bin/env bash
# test-planner-state.sh — Tests for planner-state.sh position derivation and state log.
#
# Run: bash ticket-planner/lib/tests/test-planner-state.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/.."
PLUGIN_ROOT="${SCRIPT_DIR}/../.."

# Source the state library
source "${LIB_DIR}/planner-state.sh"

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

# Override REPOS_ROOT for testing
REPOS_ROOT="$TMPDIR"

PASS=0
FAIL=0

pass() { echo "  PASS $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL $1: $2"; FAIL=$((FAIL + 1)); }

echo "=== planner-state.sh tests ==="

# ── Test 1: position derivation from empty log ──────────────────────────────────

echo "--- Test 1: position derivation from empty log ---"

pos=$(planner_position_derive "INIT-NEW")
if [ "$pos" = "Appraisal" ]; then
  pass "empty log returns Appraisal (first phase)"
else
  fail "empty log returns Appraisal" "got '$pos'"
fi

# ── Test 2: position derivation after one completed phase ───────────────────────

echo "--- Test 2: position after one completed phase ---"

planner_state_init "INIT-1" "test idea"
planner_state_write "INIT-1" "Appraisal" "appraise" "done" "scope established"

pos=$(planner_position_derive "INIT-1")
if [ "$pos" = "Discovery" ]; then
  pass "after Appraisal done, next is Discovery"
else
  fail "after Appraisal done, next is Discovery" "got '$pos'"
fi

# ── Test 3: position derivation after multiple completed phases ─────────────────

echo "--- Test 3: position after multiple phases ---"

planner_state_write "INIT-1" "Discovery" "discover" "done" "context gathered"
planner_state_write "INIT-1" "Architecture" "architect" "done" "approach chosen"

pos=$(planner_position_derive "INIT-1")
if [ "$pos" = "Proposal" ]; then
  pass "after Architecture done, next is Proposal"
else
  fail "after Architecture done, next is Proposal" "got '$pos'"
fi

# ── Test 4: resume at crashed phase (start but no done/fail) ────────────────────

echo "--- Test 4: resume at crashed phase ---"

planner_state_write "INIT-1" "Proposal" "propose" "start" "spawning Proposal agent"
# No done/fail for Proposal — simulates crash

pos=$(planner_position_derive "INIT-1")
if [ "$pos" = "Proposal" ]; then
  pass "crashed Proposal phase resumes at Proposal"
else
  fail "crashed Proposal phase resumes at Proposal" "got '$pos'"
fi

# ── Test 5: terminal phase returns empty ────────────────────────────────────────

echo "--- Test 5: terminal phase returns empty ---"

planner_state_init "INIT-DONE" "completed idea"
for phase in "Appraisal" "Discovery" "Architecture" "Proposal" "Review" "Consensus" \
             "OpenSpec" "EpicGen" "StoryGen" "TicketGen" "Execution" "Completed"; do
  planner_state_write "INIT-DONE" "$phase" "$(echo "$phase" | tr '[:upper:]' '[:lower:]')" "done" "$phase complete"
done

pos=$(planner_position_derive "INIT-DONE")
if [ -z "$pos" ]; then
  pass "all phases complete returns empty (finished)"
else
  fail "all phases complete returns empty" "got '$pos'"
fi

# ── Test 6: phase_is_done detection ─────────────────────────────────────────────

echo "--- Test 6: phase_is_done ---"

if planner_phase_is_done "INIT-1" "Appraisal"; then
  pass "Appraisal is done in INIT-1"
else
  fail "Appraisal is done in INIT-1" "phase_is_done returned false"
fi

if ! planner_phase_is_done "INIT-1" "Review"; then
  pass "Review is not done in INIT-1"
else
  fail "Review is not done in INIT-1" "phase_is_done returned true"
fi

# ── Test 7: transition validation ───────────────────────────────────────────────

echo "--- Test 7: transition validation ---"

if planner_phase_validate_transition "INIT-T" "Appraisal" "Discovery"; then
  pass "Appraisal → Discovery is legal"
else
  fail "Appraisal → Discovery is legal" "validator rejected legal transition"
fi

if ! planner_phase_validate_transition "INIT-T" "Appraisal" "Architecture" 2>/dev/null; then
  pass "Appraisal → Architecture is illegal (skipping Discovery)"
else
  fail "Appraisal → Architecture is illegal" "validator accepted skipping transition"
fi

if planner_phase_validate_transition "INIT-T" "Appraisal" "Appraisal" 2>/dev/null; then
  pass "Appraisal → Appraisal is legal (resume same phase)"
else
  fail "Appraisal → Appraisal is legal" "validator rejected resume-same"
fi

# ── Test 8: partial trailing write ignored ──────────────────────────────────────

echo "--- Test 8: partial trailing write ignored ---"

planner_state_init "INIT-PARTIAL" "partial test"
planner_state_write "INIT-PARTIAL" "Appraisal" "appraise" "done" "done"
# Simulate a partial write by appending truncated data
echo "2026-07-21T00:00:00Z|Discovery|disc" >> "$REPOS_ROOT/.ticket-auto/initiatives/INIT-PARTIAL/state.log"

pos=$(planner_position_derive "INIT-PARTIAL")
if [ "$pos" = "Discovery" ]; then
  pass "partial trailing write is ignored (position still after last valid done)"
else
  fail "partial trailing write is ignored" "got '$pos'"
fi

# ── Test 9: unknown initiative reports error ────────────────────────────────────

echo "--- Test 9: unknown initiative ---"

if ! planner_resume "INIT-NONEXISTENT" 2>/dev/null; then
  pass "unknown initiative errors rather than silently created"
else
  fail "unknown initiative errors" "planner_resume with nonexistent ID succeeded"
fi

# ── Summary ─────────────────────────────────────────────────────────────────────

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
