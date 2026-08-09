#!/usr/bin/env bash
# test-inspect-verifiers.sh — unit tests for lib/inspect-verifiers.sh
# Usage: bash test-inspect-verifiers.sh
set -eo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$TEST_DIR/.." && pwd)"
IV="$LIB_DIR/inspect-verifiers.sh"

source "$IV"

PASS=0
FAIL=0

_run() {
  local name="$1"
  shift
  set +e
  "$@"
  local rc=$?
  set -e
  if [ $rc -eq 0 ]; then
    echo "PASS: $name"
    ((PASS++)) || true
  else
    echo "FAIL: $name  (exit $rc)"
    ((FAIL++)) || true
  fi
}

# ── Tests ──────────────────────────────────────────────────────────────────────

test_clean_verifiers_pass() {
  local result
  result=$(inspect_verifiers '[
    {"verifier":"unit_tests","verdict":"PASS","score":1.0,"criteria_met":5,"criteria_total":5,"attempt":1,"phase":"IMPLEMENT"},
    {"verifier":"gate_check","verdict":"PASS","score":1.0,"criteria_met":1,"criteria_total":1,"attempt":1,"phase":"IMPLEMENT"}
  ]' "false" "IMPLEMENT")
  local verdict signals
  verdict=$(echo "$result" | jq -r '.verdict')
  signals=$(echo "$result" | jq -r '.signals')
  [ "$verdict" = "PASS" ] && [ "$signals" = "0" ]
}

test_flaky_tests_detected() {
  local result
  result=$(inspect_verifiers '[
    {"verifier":"unit_tests","verdict":"PASS","score":1.0,"criteria_met":5,"criteria_total":5,"attempt":1,"phase":"IMPLEMENT"},
    {"verifier":"playwright_uat","verdict":"FAIL","score":0.4,"criteria_met":2,"criteria_total":5,"attempt":1,"phase":"VERIFY"}
  ]' "false" "IMPLEMENT")
  local verdict patterns
  verdict=$(echo "$result" | jq -r '.verdict')
  patterns=$(echo "$result" | jq -r '.patterns | [.[].pattern] | join(",")')
  [ "$verdict" = "WARN" ] && echo "$patterns" | grep -q "flaky_tests"
}

test_incomplete_implementation_detected() {
  local result
  result=$(inspect_verifiers '[
    {"verifier":"unit_tests","verdict":"PASS","score":1.0,"criteria_met":5,"criteria_total":5,"attempt":1,"phase":"IMPLEMENT"}
  ]' "true" "IMPLEMENT")
  local verdict patterns
  verdict=$(echo "$result" | jq -r '.verdict')
  patterns=$(echo "$result" | jq -r '.patterns | [.[].pattern] | join(",")')
  [ "$verdict" = "WARN" ] && echo "$patterns" | grep -q "incomplete_implementation"
}

test_trivial_pass_detected() {
  local result
  result=$(inspect_verifiers '[
    {"verifier":"playwright_uat","verdict":"PASS","score":1.0,"criteria_met":1,"criteria_total":1,"attempt":1,"phase":"VERIFY"}
  ]' "false" "VERIFY")
  local patterns
  patterns=$(echo "$result" | jq -r '.patterns | [.[].pattern] | join(",")')
  echo "$patterns" | grep -q "trivial_pass"
}

test_trivial_pass_excludes_gates() {
  local result
  result=$(inspect_verifiers '[
    {"verifier":"gate_check","verdict":"PASS","score":1.0,"criteria_met":1,"criteria_total":1,"attempt":1,"phase":"GATE"},
    {"verifier":"return_completeness","verdict":"PASS","score":1.0,"criteria_met":1,"criteria_total":1,"attempt":1,"phase":"IMPLEMENT"}
  ]' "false" "IMPLEMENT")
  local verdict
  verdict=$(echo "$result" | jq -r '.verdict')
  [ "$verdict" = "PASS" ]
}

test_empty_input_returns_warn() {
  local result verdict
  result=$(inspect_verifiers "[]" "false" "IMPLEMENT")
  verdict=$(echo "$result" | jq -r '.verdict')
  [ "$verdict" = "WARN" ]
}

test_unparseable_json_returns_warn() {
  local result verdict
  result=$(inspect_verifiers "not json" "false" "IMPLEMENT")
  verdict=$(echo "$result" | jq -r '.verdict')
  [ "$verdict" = "WARN" ]
}

test_missing_requirement_detected() {
  local result
  result=$(inspect_verifiers '[
    {"verifier":"pr_review","verdict":"PASS","score":1.0,"criteria_met":3,"criteria_total":3,"attempt":1,"phase":"PR-REVIEW"},
    {"verifier":"critique","verdict":"WARN","score":0.7,"criteria_met":2,"criteria_total":3,"attempt":1,"phase":"APPRAISE"}
  ]' "false" "PR-REVIEW")
  local patterns
  patterns=$(echo "$result" | jq -r '.patterns | [.[].pattern] | join(",")')
  echo "$patterns" | grep -q "missing_requirement"
}

test_validate_corrects_mismatched_verdict() {
  local agent_json inspect_json result
  agent_json='{"verdict":"PASS","signals":0,"detail":"All good","verifiers_consulted":["unit_tests"],"patterns":[]}'
  inspect_json='{"verdict":"WARN","signals":2,"detail":"2 patterns detected","patterns":[{"pattern":"flaky_tests","severity":"warn","evidence":"x"}]}'
  result=$(validate_phase_inspector "$agent_json" "$inspect_json" "IMPLEMENT")
  local verdict overridden
  verdict=$(echo "$result" | jq -r '.verdict')
  overridden=$(echo "$result" | jq -r '.agent_overridden // false')
  [ "$verdict" = "WARN" ] && [ "$overridden" = "true" ]
}

test_validate_preserves_matching_verdict() {
  local agent_json inspect_json result
  agent_json='{"verdict":"PASS","signals":0,"detail":"All clean","verifiers_consulted":["unit_tests"],"patterns":[]}'
  inspect_json='{"verdict":"PASS","signals":0,"detail":"All verifiers clean","patterns":[]}'
  result=$(validate_phase_inspector "$agent_json" "$inspect_json" "IMPLEMENT")
  local verdict validated
  verdict=$(echo "$result" | jq -r '.verdict')
  validated=$(echo "$result" | jq -r '.bash_validated // false')
  [ "$verdict" = "PASS" ] && [ "$validated" = "true" ]
}

# ── Run ─────────────────────────────────────────────────────────────────────────

echo "=== test-inspect-verifiers.sh ==="
echo ""

_run "clean verifiers produce PASS" test_clean_verifiers_pass
_run "flaky_tests pattern detected" test_flaky_tests_detected
_run "incomplete_implementation detected" test_incomplete_implementation_detected
_run "trivial_pass detected for single-criterion" test_trivial_pass_detected
_run "trivial_pass excludes gate verifiers" test_trivial_pass_excludes_gates
_run "empty input returns WARN" test_empty_input_returns_warn
_run "unparseable JSON returns WARN" test_unparseable_json_returns_warn
_run "missing_requirement detected" test_missing_requirement_detected
_run "validate corrects mismatched verdict" test_validate_corrects_mismatched_verdict
_run "validate preserves matching verdict" test_validate_preserves_matching_verdict

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] || exit 1
