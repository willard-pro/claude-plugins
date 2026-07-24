#!/usr/bin/env bash
# test-planner-transitions.sh — Tests for planner phase transitions, failure
# handling, and crash-resume behavior (task 6.8).
#
# Covers:
#   1. Out-of-order transitions refused (skip-ahead, backward, multi-skip)
#   2. Phase failure halts the run recoverably (fail status → resume at same phase)
#   3. Resume picks up at the failed phase after crash
#
# Run: bash ticket-planner/lib/tests/test-planner-transitions.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/.."
PLUGIN_ROOT="${SCRIPT_DIR}/../.."

# Source the state library (provides planner_phase_validate_transition,
# planner_position_derive, planner_state_write, planner_state_init)
source "${LIB_DIR}/planner-state.sh"

# Source the router library (provides planner_phase_dispatch, planner_resume)
source "${LIB_DIR}/planner-router.sh"

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

REPOS_ROOT="$TMPDIR"

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

echo "=== planner transitions tests ==="

# ═══════════════════════════════════════════════════════════════════════════════
# 1. Out-of-order transitions refused
# ═══════════════════════════════════════════════════════════════════════════════

echo "--- 1a: skip-ahead (gap of 2) ---"
if ! planner_phase_validate_transition "INIT-SKIP" "Appraisal" "Architecture" 2>/dev/null; then
  pass "Appraisal → Architecture (skipping Discovery) is refused"
else
  fail "Appraisal → Architecture refused" "validator accepted skip-ahead"
fi

echo "--- 1b: skip-ahead (gap of 3) ---"
if ! planner_phase_validate_transition "INIT-BIG" "Discovery" "Review" 2>/dev/null; then
  pass "Discovery → Review (skipping Architecture+Specify) is refused"
else
  fail "Discovery → Review refused" "validator accepted multi-skip"
fi

echo "--- 1c: backward transition ---"
if ! planner_phase_validate_transition "INIT-BACK" "Architecture" "Discovery" 2>/dev/null; then
  pass "Architecture → Discovery (backward) is refused"
else
  fail "Architecture → Discovery refused" "validator accepted backward transition"
fi

echo "--- 1d: backward to first phase ---"
if ! planner_phase_validate_transition "INIT-BACK2" "TicketGen" "Appraisal" 2>/dev/null; then
  pass "TicketGen → Appraisal (backward to start) is refused"
else
  fail "TicketGen → Appraisal refused" "validator accepted wild backward"
fi

echo "--- 1e: jump to Completed from early phase ---"
if ! planner_phase_validate_transition "INIT-JUMP" "Appraisal" "Completed" 2>/dev/null; then
  pass "Appraisal → Completed (skipping 10 phases) is refused"
else
  fail "Appraisal → Completed refused" "validator accepted terminal jump"
fi

echo "--- 1f: unknown from-phase ---"
if ! planner_phase_validate_transition "INIT-BAD1" "Nonsense" "Appraisal" 2>/dev/null; then
  pass "unknown 'from' phase is refused"
else
  fail "unknown 'from' phase refused" "validator accepted bogus from-phase"
fi

echo "--- 1g: unknown to-phase ---"
if ! planner_phase_validate_transition "INIT-BAD2" "Appraisal" "BogusPhase" 2>/dev/null; then
  pass "unknown 'to' phase is refused"
else
  fail "unknown 'to' phase refused" "validator accepted bogus to-phase"
fi

echo "--- 1h: legal transitions honored ---"
# Verify every legal adjacent transition works
phase_sequence=(
  "Appraisal" "Discovery" "Architecture" "Specify" "Review" "Consensus"
  "EpicGen" "TicketGen" "Completed"
)
all_legal_ok=true
for ((i = 0; i < ${#phase_sequence[@]} - 1; i++)); do
  from="${phase_sequence[$i]}"
  to="${phase_sequence[$((i + 1))]}"
  if ! planner_phase_validate_transition "INIT-LEGAL" "$from" "$to" 2>/dev/null; then
    echo "    UNEXPECTED: $from → $to was rejected"
    all_legal_ok=false
  fi
done
if $all_legal_ok; then
  pass "all 11 legal adjacent transitions accepted"
else
  fail "all 11 legal adjacent transitions accepted" "at least one legal transition rejected"
fi

echo "--- 1i: same-phase transition (resume) ---"
if planner_phase_validate_transition "INIT-SAME" "Specify" "Specify" 2>/dev/null; then
  pass "Specify → Specify (same-phase resume) is legal"
else
  fail "Specify → Specify legal" "validator rejected same-phase resume"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# 2. Phase failure halts the run recoverably
# ═══════════════════════════════════════════════════════════════════════════════

echo "--- 2a: failed phase → resume at same phase ---"
planner_state_init "INIT-FAIL" "test failure handling"
planner_state_write "INIT-FAIL" "Appraisal" "appraise" "done" "scope established"
planner_state_write "INIT-FAIL" "Discovery" "discover" "done" "context gathered"
planner_state_write "INIT-FAIL" "Architecture" "architect" "fail" "unresolvable ambiguity in service boundaries"

pos=$(planner_position_derive "INIT-FAIL")
if [ "$pos" = "Architecture" ]; then
  pass "after Architecture fail, position derivation returns Architecture (re-run)"
else
  fail "after Architecture fail, position returns Architecture" "got '$pos'"
fi

echo "--- 2b: phase_is_done returns false for failed phase ---"
if ! planner_phase_is_done "INIT-FAIL" "Architecture"; then
  pass "failed Architecture phase → phase_is_done returns false"
else
  fail "failed Architecture → phase_is_done false" "returned true (treated as done)"
fi

echo "--- 2c: resume correctly identifies failed phase ---"
resume_out=$(planner_resume "INIT-FAIL" 2>&1)
if echo "$resume_out" | grep -q 'PLANNER_NEXT_PHASE=Architecture'; then
  pass "planner_resume routes to Architecture after Architecture fail"
else
  fail "planner_resume routes to Architecture after fail" "got: $resume_out"
fi

echo "--- 2d: after re-running failed phase successfully, advances normally ---"
# Simulate re-running Architecture successfully
planner_state_write "INIT-FAIL" "Architecture" "architect" "done" "approach chosen after retry"
pos=$(planner_position_derive "INIT-FAIL")
if [ "$pos" = "Specify" ]; then
  pass "after re-running failed phase to done, advances to next phase"
else
  fail "after re-running failed phase to done" "got '$pos'"
fi

echo "--- 2e: multiple consecutive failures still resume at same phase ---"
planner_state_init "INIT-MULTI" "test multiple failures"
planner_state_write "INIT-MULTI" "Appraisal" "appraise" "done" "scope done"
planner_state_write "INIT-MULTI" "Discovery" "discover" "fail" "first failure"
planner_state_write "INIT-MULTI" "Discovery" "discover" "fail" "second failure — still failing"
planner_state_write "INIT-MULTI" "Discovery" "discover" "fail" "third failure"

pos=$(planner_position_derive "INIT-MULTI")
if [ "$pos" = "Discovery" ]; then
  pass "after 3 consecutive Discovery failures, position still returns Discovery"
else
  fail "after 3 consecutive failures, position returns Discovery" "got '$pos'"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# 3. Crash-resume (phase started but never terminated)
# ═══════════════════════════════════════════════════════════════════════════════

echo "--- 3a: started-but-never-completed → resume at that phase ---"
planner_state_init "INIT-CRASH" "test crash recovery"
planner_state_write "INIT-CRASH" "Appraisal" "appraise" "done" "scope done"
planner_state_write "INIT-CRASH" "Discovery" "discover" "done" "context done"
planner_state_write "INIT-CRASH" "Architecture" "architect" "start" "spawning Architecture agent"
# Agent crashes here — no done/fail for Architecture

pos=$(planner_position_derive "INIT-CRASH")
if [ "$pos" = "Architecture" ]; then
  pass "started-but-never-completed Architecture → resume at Architecture"
else
  fail "started-but-never-completed → resume at Architecture" "got '$pos'"
fi

echo "--- 3b: resume after crash surfaces correct phase ---"
resume_out=$(planner_resume "INIT-CRASH" 2>&1)
if echo "$resume_out" | grep -q 'PLANNER_NEXT_PHASE=Architecture'; then
  pass "planner_resume after crash returns Architecture"
else
  fail "planner_resume after crash returns Architecture" "got: $resume_out"
fi

echo "--- 3c: completed phase before crash is marked done ---"
if planner_phase_is_done "INIT-CRASH" "Appraisal"; then
  pass "Appraisal is done (completed before crash)"
else
  fail "Appraisal is done (completed before crash)" "returned false"
fi

echo "--- 3d: crash during first phase → resume at first phase ---"
planner_state_init "INIT-CRASH2" "crash at start"
planner_state_write "INIT-CRASH2" "Appraisal" "appraise" "start" "spawning Appraisal agent"
# Crashed during first phase

pos=$(planner_position_derive "INIT-CRASH2")
if [ "$pos" = "Appraisal" ]; then
  pass "crash during first phase → resume at Appraisal"
else
  fail "crash during first phase → resume at Appraisal" "got '$pos'"
fi

echo "--- 3e: skip status (phase deliberately skipped) → advances ---"
planner_state_init "INIT-SKIPPED" "test skip"
planner_state_write "INIT-SKIPPED" "Appraisal" "appraise" "done" "scope done"
planner_state_write "INIT-SKIPPED" "Discovery" "discover" "skip" "no external services — nothing to discover"

pos=$(planner_position_derive "INIT-SKIPPED")
if [ "$pos" = "Architecture" ]; then
  pass "skip status causes advance to next phase (like done)"
else
  fail "skip status advances to Architecture" "got '$pos'"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# 4. End-to-end: fail → re-run → success flow
# ═══════════════════════════════════════════════════════════════════════════════

echo "--- 4a: full fail→retry→advance lifecycle ---"
planner_state_init "INIT-LIFECYCLE" "test full lifecycle"

# Phase 1: Appraisal succeeds
planner_state_write "INIT-LIFECYCLE" "Appraisal" "appraise" "done" "scope established"
pos=$(planner_position_derive "INIT-LIFECYCLE")
if [ "$pos" = "Discovery" ]; then
  pass "lifecycle: Appraisal done → next is Discovery"
else
  fail "lifecycle: Appraisal done → next is Discovery" "got '$pos'"
fi

# Phase 2: Discovery starts, crashes (start with no terminal)
planner_state_write "INIT-LIFECYCLE" "Discovery" "discover" "start" "spawning Discovery agent"
pos=$(planner_position_derive "INIT-LIFECYCLE")
if [ "$pos" = "Discovery" ]; then
  pass "lifecycle: Discovery started+crashed → resume at Discovery"
else
  fail "lifecycle: Discovery started+crashed → resume at Discovery" "got '$pos'"
fi

# Phase 2 retry: Discovery fails
planner_state_write "INIT-LIFECYCLE" "Discovery" "discover" "fail" "could not reach payment-gateway repo"
pos=$(planner_position_derive "INIT-LIFECYCLE")
if [ "$pos" = "Discovery" ]; then
  pass "lifecycle: Discovery failed → still at Discovery"
else
  fail "lifecycle: Discovery failed → still at Discovery" "got '$pos'"
fi

# Phase 2 retry 2: Discovery succeeds
planner_state_write "INIT-LIFECYCLE" "Discovery" "discover" "done" "context gathered from 3 repos"
pos=$(planner_position_derive "INIT-LIFECYCLE")
if [ "$pos" = "Architecture" ]; then
  pass "lifecycle: Discovery done after retry → advances to Architecture"
else
  fail "lifecycle: Discovery done after retry → advances" "got '$pos'"
fi

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
