#!/usr/bin/env bash
# test-planner-stop-conditions.sh — Tests for --until / --dry-run / hold vars and
# the retry budget.
#
# The three stop controls (issues #140, #141) collapse into one earliest-stop-phase
# decision, so these tests pin that they cannot diverge. PLANNER_MAX_PHASE_RETRIES
# is derived from `fail` entries in the state log, so it survives a crashed router.
#
# Run: bash ticket-planner/lib/tests/test-planner-stop-conditions.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/.."

source "${LIB_DIR}/planner-state.sh"
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

reset_env() {
  unset PLANNER_UNTIL PLANNER_REVIEW_HOLD PLANNER_CONSENSUS_HOLD PLANNER_MAX_PHASE_RETRIES
}

echo "=== planner stop-condition tests ==="

# ── Test 1: phase index against the canonical sequence ─────────────────────────
#
# Everything here compares indices into planner_phase_sequence — the single source
# of truth. A second hardcoded phase list must never appear.

echo "--- Test 1: planner_phase_index ---"

if [ "$(planner_phase_index Appraisal)" = "0" ] &&
  [ "$(planner_phase_index Consensus)" = "5" ] &&
  [ "$(planner_phase_index Completed)" = "8" ]; then
  pass "known phases map to their sequence position"
else
  pass_msg="Appraisal=$(planner_phase_index Appraisal) Consensus=$(planner_phase_index Consensus)"
  fail "known phases map to their sequence position" "$pass_msg"
fi

if [ "$(planner_phase_index Banana || true)" = "-1" ]; then
  pass "an unknown phase is -1"
else
  fail "an unknown phase is -1" "got '$(planner_phase_index Banana || true)'"
fi

# ── Test 2: no stop configured ─────────────────────────────────────────────────

echo "--- Test 2: default is run to completion ---"

reset_env
if [ -z "$(planner_stop_phase)" ]; then
  pass "no flags and no hold vars means no stop phase"
else
  fail "no stop phase by default" "got '$(planner_stop_phase)'"
fi

reset_env
if planner_should_stop_after Consensus; then
  fail "default does not stop at Consensus" "stopped"
else
  pass "default does not stop at Consensus"
fi

# ── Test 3: --until / PLANNER_UNTIL ────────────────────────────────────────────

echo "--- Test 3: --until ---"

reset_env
PLANNER_UNTIL="Specify"
if [ "$(planner_stop_phase)" = "Specify" ]; then
  pass "PLANNER_UNTIL sets the stop phase"
else
  fail "PLANNER_UNTIL sets the stop phase" "got '$(planner_stop_phase)'"
fi

if planner_should_stop_after Specify; then
  pass "stops after the named phase"
else
  fail "stops after the named phase" "did not stop"
fi

if planner_should_stop_after Discovery; then
  fail "does not stop before the named phase" "stopped at Discovery"
else
  pass "does not stop before the named phase"
fi

# ── Test 4: --dry-run stops on the Linear-write boundary ───────────────────────
#
# Consensus is the last artifact-only phase; EpicGen is the first Linear write.

echo "--- Test 4: dry-run boundary ---"

if [ "$PLANNER_DRY_RUN_PHASE" = "Consensus" ]; then
  pass "dry-run stops at Consensus — the last phase before any Linear write"
else
  fail "dry-run stops at Consensus" "got '$PLANNER_DRY_RUN_PHASE'"
fi

reset_env
PLANNER_UNTIL="$PLANNER_DRY_RUN_PHASE"
if planner_should_stop_after Consensus && ! planner_should_stop_after EpicGen; then
  pass "a dry run stops after Consensus and never reaches EpicGen"
else
  fail "dry run stops before EpicGen" "stop phase '$(planner_stop_phase)'"
fi

# ── Test 5: hold vars are the env-var form of the same mechanism ────────────────

echo "--- Test 5: hold variables ---"

reset_env
PLANNER_REVIEW_HOLD=true
if [ "$(planner_stop_phase)" = "Review" ]; then
  pass "PLANNER_REVIEW_HOLD stops after Review"
else
  fail "PLANNER_REVIEW_HOLD stops after Review" "got '$(planner_stop_phase)'"
fi

reset_env
PLANNER_CONSENSUS_HOLD=true
if [ "$(planner_stop_phase)" = "Consensus" ]; then
  pass "PLANNER_CONSENSUS_HOLD stops after Consensus"
else
  fail "PLANNER_CONSENSUS_HOLD stops after Consensus" "got '$(planner_stop_phase)'"
fi

reset_env
PLANNER_REVIEW_HOLD=false
PLANNER_CONSENSUS_HOLD=false
if [ -z "$(planner_stop_phase)" ]; then
  pass "hold vars set to false do not stop the run"
else
  fail "false hold vars do not stop" "got '$(planner_stop_phase)'"
fi

# ── Test 6: the earliest stop point wins ───────────────────────────────────────

echo "--- Test 6: earliest stop wins ---"

reset_env
PLANNER_REVIEW_HOLD=true
PLANNER_UNTIL="TicketGen"
if [ "$(planner_stop_phase)" = "Review" ]; then
  pass "a hold earlier than --until wins"
else
  fail "earliest stop wins" "got '$(planner_stop_phase)'"
fi

reset_env
PLANNER_CONSENSUS_HOLD=true
PLANNER_UNTIL="Discovery"
if [ "$(planner_stop_phase)" = "Discovery" ]; then
  pass "an --until earlier than a hold wins"
else
  fail "earliest stop wins" "got '$(planner_stop_phase)'"
fi

# ── Test 7: --until validation ─────────────────────────────────────────────────

echo "--- Test 7: --until validation ---"

reset_env
if err=$(planner_until_validate "Banana" 2>&1); then
  fail "an unknown phase is rejected" "accepted"
else
  if echo "$err" | grep -q "Appraisal" && echo "$err" | grep -q "Completed"; then
    pass "an unknown phase is rejected and lists the valid names"
  else
    fail "rejection lists valid names" "$err"
  fi
fi

if planner_until_validate "Consensus" 2>/dev/null; then
  pass "a valid phase is accepted with no initiative"
else
  fail "a valid phase is accepted" "rejected"
fi

planner_state_init "INIT-STOP" "an idea" >/dev/null
planner_state_write "INIT-STOP" "Appraisal" "scope" "done" "ok"
planner_state_write "INIT-STOP" "Discovery" "explore" "done" "ok"
planner_state_write "INIT-STOP" "Architecture" "decide" "done" "ok"

if planner_until_validate "Review" "INIT-STOP" 2>/dev/null; then
  pass "a phase ahead of the current position is accepted"
else
  fail "a phase ahead is accepted" "rejected"
fi

if err=$(planner_until_validate "Appraisal" "INIT-STOP" 2>&1); then
  fail "a phase already passed is rejected" "accepted"
else
  if echo "$err" | grep -q "Specify"; then
    pass "a phase already passed is rejected, naming the current position"
  else
    fail "rejection names the current position" "$err"
  fi
fi

# ── Test 8: retry budget derived from the state log ────────────────────────────

echo "--- Test 8: retry budget ---"

reset_env
planner_state_init "INIT-RETRY" "an idea" >/dev/null

if [ "$(planner_phase_fail_count "INIT-RETRY" "Specify")" = "0" ]; then
  pass "a phase with no failures has a fail count of 0"
else
  fail "fail count starts at 0" "got '$(planner_phase_fail_count "INIT-RETRY" "Specify")'"
fi

if planner_phase_retries_exhausted "INIT-RETRY" "Specify"; then
  fail "a fresh phase has retries left" "exhausted"
else
  pass "a fresh phase has retries left"
fi

# Default budget is 2 retries, so three recorded failures are needed to exhaust it.
planner_state_write "INIT-RETRY" "Specify" "attempt-1" "fail" "boom"
planner_state_write "INIT-RETRY" "Specify" "attempt-2" "fail" "boom"
if planner_phase_retries_exhausted "INIT-RETRY" "Specify"; then
  fail "two failures leave the budget intact at the default of 2" "exhausted"
else
  pass "two failures leave the budget intact at the default of 2"
fi

planner_state_write "INIT-RETRY" "Specify" "attempt-3" "fail" "boom"
if planner_phase_retries_exhausted "INIT-RETRY" "Specify"; then
  pass "a third failure exhausts the default budget"
else
  fail "a third failure exhausts the default budget" "not exhausted"
fi

PLANNER_MAX_PHASE_RETRIES=0
if planner_phase_retries_exhausted "INIT-RETRY" "Specify"; then
  pass "PLANNER_MAX_PHASE_RETRIES=0 exhausts after the first failure"
else
  fail "PLANNER_MAX_PHASE_RETRIES is honoured" "not exhausted"
fi

PLANNER_MAX_PHASE_RETRIES=10
if planner_phase_retries_exhausted "INIT-RETRY" "Specify"; then
  fail "a raised budget is honoured" "exhausted"
else
  pass "a raised PLANNER_MAX_PHASE_RETRIES keeps retrying"
fi

reset_env
if [ "$(planner_phase_fail_count "INIT-RETRY" "Review")" = "0" ]; then
  pass "fail counts are per-phase, not per-initiative"
else
  fail "fail counts are per-phase" "got '$(planner_phase_fail_count "INIT-RETRY" "Review")'"
fi

echo ""
echo "=== planner stop conditions: ${PASS} passed, ${FAIL} failed ==="
[ "$FAIL" -eq 0 ]
