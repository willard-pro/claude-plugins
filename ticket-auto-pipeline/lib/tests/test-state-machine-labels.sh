#!/usr/bin/env bash
# test-state-machine-labels.sh — verify planner labels in state-machine.json
# Usage: bash test-state-machine-labels.sh
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SM="${SCRIPT_DIR}/../../skills/ticket-flow/state-machine.json"

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

echo "=== state-machine.json planner labels tests ==="
echo ""

# ── Test: state-machine.json exists and is valid JSON ──────────────────────

test_valid_json() {
  jq '.' "$SM" >/dev/null 2>&1
}

# ── Test: planner_labels section exists ─────────────────────────────────────

test_planner_labels_section() {
  jq -e '.planner_labels' "$SM" >/dev/null 2>&1
}

# ── Test: planned label defined ─────────────────────────────────────────────

test_planned_label() {
  local pattern
  pattern=$(jq -r '.planner_labels.planned.pattern' "$SM")
  [ "$pattern" = "planned" ]
}

# ── Test: planned label never removed ───────────────────────────────────────

test_planned_never_removed() {
  local removed_by
  removed_by=$(jq -r '.planner_labels.planned.removed_by | length' "$SM")
  [ "$removed_by" -eq 0 ]
}

# ── Test: INIT-* wildcard defined ───────────────────────────────────────────

test_init_wildcard() {
  local pattern
  pattern=$(jq -r '.planner_labels."INIT-*".pattern' "$SM")
  [ "$pattern" = "INIT-*" ]
}

# ── Test: pre-approved label defined ────────────────────────────────────────

test_pre_approved_label() {
  local pattern
  pattern=$(jq -r '.planner_labels."pre-approved".pattern' "$SM")
  [ "$pattern" = "pre-approved" ]
}

# ── Test: pre-approved removed by human-reject and re-claim ─────────────────

test_pre_approved_removers() {
  local removers
  removers=$(jq -r '.planner_labels."pre-approved".removed_by | join(",")' "$SM")
  echo "$removers" | grep -q "human-reject" && echo "$removers" | grep -q "re-claim"
}

# ── Test: pre-approved confidence threshold is 0.85 ─────────────────────────

test_pre_approved_confidence() {
  local threshold
  threshold=$(jq -r '.planner_labels."pre-approved".conditions.confidence_min' "$SM")
  [ "$threshold" = "0.85" ]
}

# ── Test: blocked-by:* wildcard defined ─────────────────────────────────────

test_blocked_by_wildcard() {
  local pattern
  pattern=$(jq -r '.planner_labels."blocked-by:*".pattern' "$SM")
  [ "$pattern" = "blocked-by:*" ]
}

# ── Test: blocked-by auto-remove-when set ───────────────────────────────────

test_blocked_by_auto_remove() {
  local auto
  auto=$(jq -r '.planner_labels."blocked-by:*".auto_remove_when' "$SM")
  [ "$auto" = "blocker_reaches_done" ]
}

# ── Test: state:execution label defined ─────────────────────────────────────

test_state_execution_label() {
  local pattern
  pattern=$(jq -r '.planner_labels."state:execution".pattern' "$SM")
  [ "$pattern" = "state:execution" ]
}

# ── Test: state:execution Epic-only precondition ────────────────────────────

test_state_execution_precondition() {
  local precond
  precond=$(jq -r '.planner_labels."state:execution".precondition' "$SM")
  [ "$precond" = "issue_type_must_be_epic" ]
}

# ── Test: well_known_labels unchanged ───────────────────────────────────────

test_well_known_labels_unchanged() {
  local labels
  labels=$(jq -r '.well_known_labels | join(",")' "$SM")
  echo "$labels" | grep -q "bug" && echo "$labels" | grep -q "feature" && echo "$labels" | grep -q "repro-failed"
}

# ── Test: existing triggers intact ──────────────────────────────────────────

test_triggers_intact() {
  local count
  count=$(jq -r '.triggers | keys | length' "$SM")
  [ "$count" -ge 15 ]
}

# ── Test: pre-approved label removed by human-reject trigger ────────────────

test_human_reject_removes_pre_approved() {
  local removes
  removes=$(jq -r '.triggers."human-reject".removes | join(",")' "$SM")
  echo "$removes" | grep -q "pre-approved"
}

# ── Test: pre-approved label removed by re-claim trigger ────────────────────

test_re_claim_removes_pre_approved() {
  local removes
  removes=$(jq -r '.triggers."re-claim".removes | join(",")' "$SM")
  echo "$removes" | grep -q "pre-approved"
}

# ── Test: state:execution precondition logic — Epic passes ──────────────────

test_precondition_epic_passes() {
  local precondition issue_type
  precondition=$(jq -r '.planner_labels."state:execution".precondition // empty' "$SM")
  [ "$precondition" = "issue_type_must_be_epic" ] || return 1
  issue_type="Epic"
  if [ "$precondition" = "issue_type_must_be_epic" ] && [ "$issue_type" != "Epic" ]; then
    # Should NOT reach here for Epic
    return 1
  fi
  return 0
}

# ── Test: state:execution precondition logic — Bug rejected ─────────────────

test_precondition_bug_rejected() {
  local precondition issue_type should_reject
  precondition=$(jq -r '.planner_labels."state:execution".precondition // empty' "$SM")
  [ "$precondition" = "issue_type_must_be_epic" ] || return 1
  issue_type="Bug"
  should_reject="false"
  if [ "$precondition" = "issue_type_must_be_epic" ] && [ "$issue_type" != "Epic" ]; then
    should_reject="true"
  fi
  [ "$should_reject" = "true" ]
}

# ── Test: state:execution precondition logic — Task rejected ────────────────

test_precondition_task_rejected() {
  local precondition issue_type should_reject
  precondition=$(jq -r '.planner_labels."state:execution".precondition // empty' "$SM")
  issue_type="Task"
  should_reject="false"
  if [ "$precondition" = "issue_type_must_be_epic" ] && [ "$issue_type" != "Epic" ]; then
    should_reject="true"
  fi
  [ "$should_reject" = "true" ]
}

# ── Run tests ──────────────────────────────────────────────────────────────

_run "valid JSON" test_valid_json
_run "planner_labels section exists" test_planner_labels_section
_run "planned label defined" test_planned_label
_run "planned label never removed" test_planned_never_removed
_run "INIT-* wildcard defined" test_init_wildcard
_run "pre-approved label defined" test_pre_approved_label
_run "pre-approved removed by human-reject and re-claim" test_pre_approved_removers
_run "pre-approved confidence threshold 0.85" test_pre_approved_confidence
_run "blocked-by:* wildcard defined" test_blocked_by_wildcard
_run "blocked-by auto_remove_when set" test_blocked_by_auto_remove
_run "state:execution label defined" test_state_execution_label
_run "state:execution Epic-only precondition" test_state_execution_precondition
_run "well_known_labels unchanged" test_well_known_labels_unchanged
_run "existing triggers intact" test_triggers_intact
_run "human-reject trigger removes pre-approved" test_human_reject_removes_pre_approved
_run "re-claim trigger removes pre-approved" test_re_claim_removes_pre_approved
_run "precondition logic: Epic passes" test_precondition_epic_passes
_run "precondition logic: Bug rejected" test_precondition_bug_rejected
_run "precondition logic: Task rejected" test_precondition_task_rejected

echo ""
echo "=== $((PASS + FAIL)) tests: $PASS pass, $FAIL fail ==="
[ "$FAIL" -eq 0 ] || exit 1
