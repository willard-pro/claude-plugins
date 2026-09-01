#!/usr/bin/env bash
# test-planner-stop-conditions.sh — Tests for the create gate, --until, and the
# retry budget.
#
# The create gate and --until collapse into one earliest-stop-phase decision, so
# these tests pin that they cannot diverge. Every one of them is resolved from the
# state log: after #144 nothing here may consult the environment, because the
# dispatch loop runs a fresh process per phase and an export does not survive it.
# Cross-process durability itself is proven in test-planner-config-durability.sh —
# same-process tests structurally cannot see the boundary that broke #141.
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
  # These are read only by argument parsing now; unsetting them here guards against
  # a regression that reintroduces a mid-loop environment read.
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
  [ "$(planner_phase_index Crosscheck)" = "6" ] &&
  [ "$(planner_phase_index Completed)" = "9" ]; then
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

# ── Test 2: the default is the create gate ─────────────────────────────────────
#
# The safe state is the default. An initiative nobody authorized stops on the last
# artifact-only phase, with no flag involved — there is nothing to forget to pass
# and nothing that can fail to propagate.

echo "--- Test 2: default stops at the create gate ---"

reset_env
planner_state_init "INIT-GATE" "an idea" >/dev/null

if [ "$(planner_stop_phase INIT-GATE)" = "Crosscheck" ]; then
  pass "an unauthorized initiative stops after Crosscheck by default"
else
  fail "default stop is Crosscheck" "got '$(planner_stop_phase INIT-GATE)'"
fi

if planner_should_stop_after INIT-GATE Crosscheck; then
  pass "the loop stops once Crosscheck completes"
else
  fail "the loop stops after Crosscheck" "did not stop"
fi

if planner_create_authorized INIT-GATE; then
  fail "a fresh initiative is unauthorized" "reported authorized"
else
  pass "a fresh initiative is not authorized to create"
fi

if err=$(planner_create_gate_check INIT-GATE EpicGen 2>&1); then
  fail "EpicGen is refused without authorization" "allowed"
else
  if echo "$err" | grep -q -- "--create"; then
    pass "EpicGen is refused, naming the --create command"
  else
    fail "refusal names --create" "$err"
  fi
fi

if planner_create_gate_check INIT-GATE Specify 2>/dev/null; then
  pass "artifact-only phases are never gated"
else
  fail "artifact-only phases are ungated" "Specify was refused"
fi

# ── Test 3: --create lifts the gate, durably ───────────────────────────────────

echo "--- Test 3: --create ---"

planner_authorize_create INIT-GATE "operator passed --create"

if planner_create_authorized INIT-GATE; then
  pass "--create authorizes the initiative"
else
  fail "--create authorizes" "still unauthorized"
fi

if [ -z "$(planner_stop_phase INIT-GATE)" ]; then
  pass "an authorized run has no stop phase"
else
  fail "authorized run runs to completion" "got '$(planner_stop_phase INIT-GATE)'"
fi

if planner_create_gate_check INIT-GATE EpicGen 2>/dev/null &&
  planner_create_gate_check INIT-GATE TicketGen 2>/dev/null; then
  pass "both Linear-write phases are allowed once authorized"
else
  fail "write phases allowed once authorized" "still refused"
fi

# The authorization is a log entry, not a variable — that is the whole point.
if grep -q '|META|create-authorized|done|' "$(planner_state_log INIT-GATE)"; then
  pass "authorization is persisted to the state log"
else
  fail "authorization is persisted" "no META entry written"
fi

# ── Test 4: --until narrows the run, and the earliest stop wins ────────────────

echo "--- Test 4: --until ---"

planner_state_init "INIT-UNTIL" "an idea" >/dev/null
planner_stop_after_set INIT-UNTIL "Specify"

if [ "$(planner_stop_phase INIT-UNTIL)" = "Specify" ]; then
  pass "--until sets the stop phase"
else
  fail "--until sets the stop phase" "got '$(planner_stop_phase INIT-UNTIL)'"
fi

if planner_should_stop_after INIT-UNTIL Specify && ! planner_should_stop_after INIT-UNTIL Discovery; then
  pass "stops after the named phase, not before it"
else
  fail "stops exactly at the named phase" "stop='$(planner_stop_phase INIT-UNTIL)'"
fi

# An --until past the gate cannot be used to sneak past it.
planner_stop_after_set INIT-UNTIL "TicketGen"
if [ "$(planner_stop_phase INIT-UNTIL)" = "Crosscheck" ]; then
  pass "--until past the gate still stops at the gate"
else
  fail "the earliest stop wins" "got '$(planner_stop_phase INIT-UNTIL)'"
fi

# …and an --until before the gate wins over it.
planner_stop_after_set INIT-UNTIL "Review"
if [ "$(planner_stop_phase INIT-UNTIL)" = "Review" ]; then
  pass "--until earlier than the gate wins"
else
  fail "the earliest stop wins" "got '$(planner_stop_phase INIT-UNTIL)'"
fi

# ── Test 5: --create clears a stop point an earlier invocation set ─────────────
#
# `plan --until Consensus` then `resume --create` must not keep stopping at
# Consensus. Config is last-write-wins, which requires that a re-written config
# entry is not suppressed as a duplicate `done`.

echo "--- Test 5: config is last-write-wins ---"

planner_state_init "INIT-OVERRIDE" "an idea" >/dev/null
planner_stop_after_set INIT-OVERRIDE "Consensus"
planner_authorize_create INIT-OVERRIDE
planner_stop_after_set INIT-OVERRIDE ""

if [ -z "$(planner_stop_phase INIT-OVERRIDE)" ]; then
  pass "--create clears the stop point plan recorded"
else
  fail "--create clears the earlier stop point" "got '$(planner_stop_phase INIT-OVERRIDE)'"
fi

if [ "$(grep -c '|META|stop-after|done|' "$(planner_state_log INIT-OVERRIDE)")" = "2" ]; then
  pass "a re-written config entry is appended, not suppressed as a duplicate"
else
  fail "config re-writes are appended" "$(grep -c '|META|stop-after|done|' "$(planner_state_log INIT-OVERRIDE)") entries"
fi

# ── Test 6: the dry-run boundary is still the phase before the first write ─────

echo "--- Test 6: write boundary ---"

if [ "$PLANNER_DRY_RUN_PHASE" = "Crosscheck" ] && [ "$PLANNER_CREATE_GATE_PHASE" = "Crosscheck" ]; then
  pass "the gate sits on the last artifact-only phase"
else
  fail "gate is at Crosscheck" "dry-run='$PLANNER_DRY_RUN_PHASE' gate='$PLANNER_CREATE_GATE_PHASE'"
fi

for phase in EpicGen TicketGen; do
  if planner_phase_writes_linear "$phase"; then
    pass "${phase} is classed as a Linear-write phase"
  else
    fail "${phase} writes Linear" "not classed as a write phase"
  fi
done

for phase in Appraisal Discovery Architecture Specify Review Consensus Crosscheck; do
  if planner_phase_writes_linear "$phase"; then
    fail "${phase} is artifact-only" "classed as a Linear-write phase"
  else
    pass "${phase} is artifact-only"
  fi
done

# ── Test 7: stop reason distinguishes the gate from an explicit --until ────────

echo "--- Test 7: stop reason ---"

planner_state_init "INIT-REASON" "an idea" >/dev/null
if planner_stop_reason INIT-REASON | grep -q "not authorized"; then
  pass "the default stop is reported as an authorization gate"
else
  fail "gate stop reason" "got '$(planner_stop_reason INIT-REASON)'"
fi

planner_stop_after_set INIT-REASON "Review"
if [ "$(planner_stop_reason INIT-REASON)" = "--until Review" ]; then
  pass "an explicit --until is reported as such"
else
  fail "--until stop reason" "got '$(planner_stop_reason INIT-REASON)'"
fi

planner_authorize_create INIT-REASON
planner_stop_after_set INIT-REASON ""
if [ -z "$(planner_stop_reason INIT-REASON)" ]; then
  pass "an unstopped run has no stop reason"
else
  fail "no stop reason when nothing stops" "got '$(planner_stop_reason INIT-REASON)'"
fi

# ── Test 7b: --until validation ────────────────────────────────────────────────

echo "--- Test 7b: --until validation ---"

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
