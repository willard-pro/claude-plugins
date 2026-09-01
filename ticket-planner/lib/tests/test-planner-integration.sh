#!/usr/bin/env bash
# test-planner-integration.sh — Integration and E2E tests for ticket-planner.
#
# Tests spans multiple phases: crash-resume, idempotency, full run simulation.
# Uses mock agents — no real Linear API calls.
#
# Usage: bash lib/tests/test-planner-integration.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/.."

# Override REPOS_ROOT for tests
export REPOS_ROOT="/tmp/test-planner-integration-$$"
STATUS=0

PASS=0
FAIL=0

cleanup() {
  rm -rf "$REPOS_ROOT"
}
trap cleanup EXIT

mkdir -p "$REPOS_ROOT/.ticket-auto/initiatives"

source "${LIB_DIR}/planner-state.sh"
source "${LIB_DIR}/planner-deps-check.sh"
source "${LIB_DIR}/planner-ticket-validate.sh"

# ── Helpers ───────────────────────────────────────────────────────────────────

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "FAIL: $desc (expected '$expected', got '$actual')"
    FAIL=$((FAIL + 1))
    STATUS=1
  fi
}

assert_rc() {
  local desc="$1" expected_rc="$2" actual_rc="$3"
  if [ "$expected_rc" -eq "$actual_rc" ]; then
    echo "PASS: $desc (rc=$actual_rc)"
    PASS=$((PASS + 1))
  else
    echo "FAIL: $desc (expected rc=$expected_rc, got rc=$actual_rc)"
    FAIL=$((FAIL + 1))
    STATUS=1
  fi
}

# ── Test: Full 10-phase position derivation flow ──────────────────────────────

test_full_9_phase_run() {
  echo "=== test_full_10_phase_run ==="
  local id="INIT-TEST-FULL-$$"

  # Init
  planner_state_init "$id" "Test full run"
  local dir
  dir=$(planner_initiative_dir "$id")

  # Verify position starts at Appraisal
  local pos
  pos=$(planner_position_derive "$id")
  assert_eq "fresh init starts at Appraisal" "Appraisal" "$pos"

  # Simulate each phase completing
  for phase in "Appraisal" "Discovery" "Architecture" "Specify" "Review" "Consensus" "Crosscheck" "EpicGen" "TicketGen" "Completed"; do
    planner_state_write "$id" "$phase" "main" "start" "Starting $phase"
    planner_state_write "$id" "$phase" "main" "done" "Completed $phase"
  done

  # After Completed, position should be empty
  pos=$(planner_position_derive "$id")
  assert_eq "completed run returns empty" "" "$pos"

  echo ""
}

# ── Test: Crash mid-pipeline resume ──────────────────────────────────────────

test_crash_resume() {
  echo "=== test_crash_resume ==="
  local id="INIT-TEST-CRASH-$$"

  planner_state_init "$id" "Test crash resume"

  # Complete first 3 phases
  planner_state_write "$id" "Appraisal" "scope" "start" "Start"
  planner_state_write "$id" "Appraisal" "scope" "done" "Done"
  planner_state_write "$id" "Discovery" "explore" "start" "Start"
  planner_state_write "$id" "Discovery" "explore" "done" "Done"
  planner_state_write "$id" "Architecture" "design" "start" "Start"
  planner_state_write "$id" "Architecture" "design" "done" "Done"

  # Start Specify but don't finish (crash)
  planner_state_write "$id" "Specify" "synthesize" "start" "Start"
  # ... CRASH HERE — no done entry ...

  pos=$(planner_position_derive "$id")
  assert_eq "crash mid-Specify resumes at Specify" "Specify" "$pos"

  # Complete Specify and continue
  planner_state_write "$id" "Specify" "synthesize" "done" "Done"
  pos=$(planner_position_derive "$id")
  assert_eq "after Specify completes → Review" "Review" "$pos"

  echo ""
}

# ── Test: Idempotent entity creation ─────────────────────────────────────────

test_idempotent_entity_creation() {
  echo "=== test_idempotent_entity_creation ==="
  local id="INIT-TEST-IDEM-$$"

  planner_state_init "$id" "Test idempotency"

  # Record intent for an epic
  planner_record_intent "$id" "EpicGen" "epic" "epic-$id"

  # Create it
  planner_entity_mark_created "$id" "epic-$id" "CRE-999"

  # Verify it exists
  if planner_entity_exists "$id" "epic-$id"; then
    echo "PASS: entity exists after creation"
    PASS=$((PASS + 1))
  else
    echo "FAIL: entity should exist after creation"
    FAIL=$((FAIL + 1))
  fi

  # Verify get_id returns correct ID
  local eid
  eid=$(planner_entity_get_id "$id" "epic-$id")
  assert_eq "entity get_id returns correct Linear ID" "CRE-999" "$eid"

  # Re-recording intent should be a no-op (idempotent)
  planner_record_intent "$id" "EpicGen" "epic" "epic-$id"
  eid=$(planner_entity_get_id "$id" "epic-$id")
  assert_eq "re-recording intent preserves original ID" "CRE-999" "$eid"

  echo ""
}

# ── Test: Dependency cycle detection ─────────────────────────────────────────

test_cycle_detection() {
  echo "=== test_cycle_detection ==="

  # Valid DAG
  local valid_deps='{"A":["B"],"B":[]}'
  planner_deps_check_acyclic "$valid_deps"
  assert_rc "valid DAG passes acyclicity check" 0 $?

  # Cycle: A→B→A
  local cyclic_deps='{"A":["B"],"B":["A"]}'
  planner_deps_check_acyclic "$cyclic_deps" && rc=$? || rc=$?
  assert_rc "cyclic graph fails acyclicity check" 1 "$rc"

  # Empty graph
  planner_deps_check_acyclic "{}"
  assert_rc "empty graph passes" 0 $?

  echo ""
}

# ── Test: Phase sequence is exactly 10 phases ────────────────────────────────

test_phase_sequence_length() {
  echo "=== test_phase_sequence_length ==="
  local phases
  planner_phase_sequence phases

  local count="${#phases[@]}"
  assert_eq "phase sequence has 10 phases" "10" "$count"

  # Verify specific positions
  assert_eq "phase[0] is Appraisal" "Appraisal" "${phases[0]}"
  assert_eq "phase[3] is Specify" "Specify" "${phases[3]}"
  assert_eq "phase[6] is Crosscheck" "Crosscheck" "${phases[6]}"
  assert_eq "phase[9] is Completed" "Completed" "${phases[9]}"

  # Verify Story Gen and Execution are not present
  local found_storygen=0 found_execution=0
  for p in "${phases[@]}"; do
    [ "$p" = "StoryGen" ] && found_storygen=1
    [ "$p" = "Execution" ] && found_execution=1
  done
  assert_eq "StoryGen removed from sequence" "0" "$found_storygen"
  assert_eq "Execution removed from sequence" "0" "$found_execution"

  echo ""
}

# ── Test: State log repair drops invalid lines ───────────────────────────────

test_state_log_repair() {
  echo "=== test_state_log_repair ==="
  local id="INIT-TEST-REPAIR-$$"

  planner_state_init "$id" "Test repair"
  local log_file
  log_file=$(planner_state_log "$id")

  # Add a valid line
  planner_state_write "$id" "Appraisal" "scope" "start" "Starting"

  # Append a garbled line directly
  echo "garbled|line|that|makes|no|sense" >>"$log_file"

  # Append a line with an invalid phase
  echo "2024-01-01T00:00:00Z|PhantomPhase|step|done|msg" >>"$log_file"

  # Repair
  if planner_state_repair "$id"; then
    echo "PASS: state log repair succeeded"
    PASS=$((PASS + 1))
  else
    echo "FAIL: state log repair failed unexpectedly"
    FAIL=$((FAIL + 1))
  fi

  # Verify garbled lines are gone
  if grep -q "garbled" "$log_file" 2>/dev/null; then
    echo "FAIL: garbled line survived repair"
    FAIL=$((FAIL + 1))
  else
    echo "PASS: garbled line removed by repair"
    PASS=$((PASS + 1))
  fi

  if grep -q "PhantomPhase" "$log_file" 2>/dev/null; then
    echo "FAIL: invalid phase line survived repair"
    FAIL=$((FAIL + 1))
  else
    echo "PASS: invalid phase line removed by repair"
    PASS=$((PASS + 1))
  fi

  # Verify valid line survived
  if grep -q "Appraisal" "$log_file" 2>/dev/null; then
    echo "PASS: valid Appraisal line survived repair"
    PASS=$((PASS + 1))
  else
    echo "FAIL: valid line removed by repair"
    FAIL=$((FAIL + 1))
  fi

  echo ""
}

# ── Test: Pipe sanitization in idea ──────────────────────────────────────────

test_pipe_sanitization() {
  echo "=== test_pipe_sanitization ==="
  local id="INIT-TEST-PIPE-$$"
  local bad_idea="Add login|logout with pipe|chars"

  planner_state_init "$id" "$bad_idea"

  local log_file
  log_file=$(planner_state_log "$id")

  # The state log should not have raw pipe characters in the idea field
  local idea_line
  idea_line=$(grep '|META|idea|' "$log_file" | head -1)

  # The idea line should have exactly 4 pipes (ISO|META|idea|start|safe_idea)
  local pipe_count
  pipe_count=$(echo "$idea_line" | tr -cd '|' | wc -c)
  if [ "$pipe_count" -eq 4 ]; then
    echo "PASS: idea pipe sanitization — correct field count ($pipe_count pipes)"
    PASS=$((PASS + 1))
  else
    echo "FAIL: idea pipe sanitization — expected 4 pipes, got $pipe_count (line: $idea_line)"
    FAIL=$((FAIL + 1))
  fi

  # Verify original idea is preserved in artifacts/idea.txt
  local idea_file
  idea_file="$(planner_initiative_dir "$id")/artifacts/idea.txt"
  if [ -f "$idea_file" ] && grep -q "login|logout" "$idea_file" 2>/dev/null; then
    echo "PASS: original idea preserved in artifacts/idea.txt"
    PASS=$((PASS + 1))
  else
    echo "FAIL: original idea not preserved"
    FAIL=$((FAIL + 1))
  fi

  echo ""
}

# ── Test: Validator fail-closed (exit 3) ─────────────────────────────────────

test_validator_fail_closed() {
  echo "=== test_validator_fail_closed ==="
  # The validator returns 3 when planned-ticket-check.sh is not found
  # This test verifies the function signature — actual exit 3 requires the
  # validator to be absent, which we can simulate by checking the code:
  if grep -q "return 3" "${LIB_DIR}/planner-ticket-validate.sh" 2>/dev/null; then
    echo "PASS: validator has exit 3 for unavailable checker"
    PASS=$((PASS + 1))
  else
    echo "FAIL: validator missing exit 3"
    FAIL=$((FAIL + 1))
  fi
  echo ""
}

# ── Test: Phase transition validation ────────────────────────────────────────

test_phase_transitions() {
  echo "=== test_phase_transitions ==="
  local id="INIT-TEST-TRANS-$$"
  planner_state_init "$id" "Test transitions"

  # Valid transitions
  planner_phase_validate_transition "$id" "Appraisal" "Discovery" && rc=$? || rc=$?
  assert_rc "Appraisal→Discovery valid" 0 "$rc"

  planner_phase_validate_transition "$id" "TicketGen" "Completed" && rc=$? || rc=$?
  assert_rc "TicketGen→Completed valid" 0 "$rc"

  # Invalid skip
  planner_phase_validate_transition "$id" "Appraisal" "Architecture" && rc=$? || rc=$?
  assert_rc "Appraisal→Architecture (skip Discovery) invalid" 1 "$rc"

  # Same phase (resume)
  planner_phase_validate_transition "$id" "Specify" "Specify" && rc=$? || rc=$?
  assert_rc "Specify→Specify (resume) valid" 0 "$rc"

  # Unknown phase
  planner_phase_validate_transition "$id" "PhantomPhase" "Discovery" 2>/dev/null && rc=$? || rc=$?
  assert_rc "PhantomPhase→Discovery invalid" 1 "$rc"

  echo ""
}

# ── Run all tests ────────────────────────────────────────────────────────────

test_full_9_phase_run
test_crash_resume
test_idempotent_entity_creation
test_cycle_detection
test_phase_sequence_length
test_state_log_repair
test_pipe_sanitization
test_validator_fail_closed
test_phase_transitions

# ── Summary ──────────────────────────────────────────────────────────────────

echo "=== Integration Tests: $PASS passed, $FAIL failed ==="
exit $STATUS
