#!/usr/bin/env bash
# test-fleet-feedback.sh — unit tests for fleet-feedback.sh
# Tests feedback aggregation with mock pipeline logs.
# Usage: bash test-fleet-feedback.sh [test_name_filter]
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

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

# ── Mock helpers ─────────────────────────────────────────────────────────────────

_setup_workspace() {
  mktemp -d
}

_plog() {
  local dir="$1" tid="$2" phase="$3" step="$4" status="$5" msg="$6"
  local iso="${7:-2026-07-07T10:00:00Z}"
  mkdir -p "$dir"
  echo "${iso}|${phase}|${step}|${status}|${msg}" >>"${dir}/${tid}-pipeline.log"
}

source "$LIB_DIR/fleet-feedback.sh"

# ── Tests ───────────────────────────────────────────────────────────────────────

test_feedback_no_logs() {
  local ws
  ws=$(_setup_workspace)

  local output
  output=$(fleet_aggregate_feedback "$ws" 2>&1 || true)
  # A fresh workspace with no pipeline logs → should report "no feedback"
  echo "$output" | grep -q "does not exist\|no pipeline logs\|no feedback" && return 0 || { echo "output: $output"; return 1; }
}

test_feedback_no_entries() {
  local ws
  ws=$(_setup_workspace)
  _plog "$ws" "CRE-101" "IMPLEMENT" "implement" "done" "implemented fix"
  _plog "$ws" "CRE-101" "META" "outcome" "info" "completed: success"

  local output
  output=$(fleet_aggregate_feedback "$ws" 2>&1 || true)
  echo "$output" | grep -q "no feedback to aggregate" && return 0 || { echo "output: $output"; return 1; }
}

test_feedback_malformed_json_skipped() {
  local ws
  ws=$(_setup_workspace)
  _plog "$ws" "CRE-101" "META" "planner-feedback" "info" "not-valid-json-at-all"

  local output
  output=$(fleet_aggregate_feedback "$ws" 2>&1 || true)
  # With no initiative labels, it should skip or report no feedback
  echo "$output" | grep -q "no feedback\|skipping" && return 0 || { echo "output: $output"; return 1; }
}

test_feedback_dry_run_flag_accepted() {
  local ws
  ws=$(_setup_workspace)
  # Test that --dry-run flag is accepted as argument
  local output
  output=$(FLEET_DRY_RUN=true REPOS_ROOT="$ws" fleet_aggregate_feedback "$ws" --dry-run 2>&1 || true)
  # Should still say "no feedback" (no entries) but not crash
  echo "$output" | grep -q "no feedback" && return 0 || { echo "output: $output"; return 1; }
}

test_feedback_empty_workspace() {
  local ws
  ws=$(_setup_workspace)

  local output
  output=$(fleet_aggregate_feedback "$ws" 2>&1 || true)
  # Workspace exists but has no pipeline logs
  echo "$output" | grep -q "no pipeline logs\|no feedback\|does not exist" && return 0 || { echo "output: $output"; return 1; }
}

test_drift_none_label() {
  local result
  result=$(_drift_label "0.0" 2>/dev/null)
  [ "$result" = "none" ] || { echo "expected 'none', got '$result'"; return 1; }
}

test_drift_minor_label() {
  local result
  result=$(_drift_label "-0.15" 2>/dev/null)
  [ "$result" = "minor" ] || { echo "expected 'minor', got '$result'"; return 1; }
}

test_drift_major_label() {
  local result
  result=$(_drift_label "-0.25" 2>/dev/null)
  [ "$result" = "major" ] || { echo "expected 'major', got '$result'"; return 1; }
}

test_parse_feedback_payload_valid() {
  local line="2026-07-07T10:00:00Z|META|planner-feedback|info|{\"decision_drift\":\"none\"}"
  local payload
  payload=$(_parse_feedback_payload "$line" 2>/dev/null || echo "FAIL")
  [ "$payload" != "FAIL" ] || { echo "failed to parse valid payload"; return 1; }
  echo "$payload" | jq -e '.decision_drift == "none"' >/dev/null 2>&1 || { echo "wrong decision_drift"; return 1; }
}

test_parse_feedback_payload_invalid() {
  local line="2026-07-07T10:00:00Z|META|planner-feedback|info|{broken"
  if _parse_feedback_payload "$line" 2>/dev/null; then
    echo "expected failure for invalid JSON"; return 1
  fi
  return 0
}

# ── Run all tests ────────────────────────────────────────────────────────────────

# Skip integration tests that need linear-api (just test internal helpers + dry paths)
_run "feedback_no_logs" test_feedback_no_logs
_run "feedback_no_entries" test_feedback_no_entries
_run "feedback_malformed_json_skipped" test_feedback_malformed_json_skipped
_run "feedback_dry_run_flag_accepted" test_feedback_dry_run_flag_accepted
_run "feedback_empty_workspace" test_feedback_empty_workspace
_run "drift_none" test_drift_none_label
_run "drift_minor" test_drift_minor_label
_run "drift_major" test_drift_major_label
_run "parse_feedback_payload_valid" test_parse_feedback_payload_valid
_run "parse_feedback_payload_invalid" test_parse_feedback_payload_invalid

echo ""
echo "=== Results ==="
echo "PASS: $PASS | FAIL: $FAIL"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
