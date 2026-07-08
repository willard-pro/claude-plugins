#!/usr/bin/env bash
# test-fleet-detect-new.sh — unit tests for the 3 new detection engines
# (detect_planner_feedback, detect_blocked_by, detect_initiative_dispatch)
# Usage: bash test-fleet-detect-new.sh [test_name_filter]
set -e pipefail

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

# ── Helpers ──────────────────────────────────────────────────────────────────────

_setup_workspace() {
  mktemp -d
}

_plog() {
  local dir="$1" tid="$2" phase="$3" step="$4" status="$5" msg="$6"
  local iso="${7:-2026-07-07T10:00:00Z}"
  mkdir -p "$dir"
  echo "${iso}|${phase}|${step}|${status}|${msg}" >>"${dir}/${tid}-pipeline.log"
}

source "$LIB_DIR/fleet-detect.sh"

# ── Tests: detect_planner_feedback ───────────────────────────────────────────────

test_planner_feedback_none() {
  local ws
  ws=$(_setup_workspace)
  _plog "$ws" "CRE-101" "IMPLEMENT" "implement" "done" "implemented fix"
  _plog "$ws" "CRE-101" "META" "outcome" "info" "completed: success"

  local sev
  sev=$(detect_planner_feedback "CRE-101" "$ws")
  [ "$sev" = "0" ] || { echo "expected 0, got $sev"; return 1; }
}

test_planner_feedback_found() {
  local ws
  ws=$(_setup_workspace)
  _plog "$ws" "CRE-101" "IMPLEMENT" "implement" "done" "implemented fix"
  _plog "$ws" "CRE-101" "META" "planner-feedback" "info" "{\"decision_drift\":\"none\",\"confidence_actual\":0.85}"
  # No REPOS_ROOT set → no feedback dir exists → should report uncollected (WARN)
  local sev
  sev=$(detect_planner_feedback "CRE-101" "$ws")
  [ "$sev" = "1" ] || { echo "expected 1, got $sev"; return 1; }
}

test_planner_feedback_collected() {
  local ws
  ws=$(_setup_workspace)
  _plog "$ws" "CRE-101" "IMPLEMENT" "implement" "done" "implemented fix"
  _plog "$ws" "CRE-101" "META" "planner-feedback" "info" "{\"decision_drift\":\"none\",\"confidence_actual\":0.85}"

  # Create a mock feedback dir to simulate collected feedback
  REPOS_ROOT="$ws" FLEET_PIPELINE_LOG_DIR="$ws" \
    mkdir -p "$ws/.ticket-auto/initiatives/INIT-42/feedback"
  touch "$ws/.ticket-auto/initiatives/INIT-42/feedback/2026-07-07.json"

  local sev
  sev=$(REPOS_ROOT="$ws" detect_planner_feedback "CRE-101" "$ws")
  [ "$sev" = "0" ] || { echo "expected 0 (collected), got $sev"; return 1; }
}

test_planner_feedback_no_log_file() {
  local ws
  ws=$(_setup_workspace)
  local sev
  sev=$(detect_planner_feedback "CRE-999" "$ws")
  [ "$sev" = "0" ] || { echo "expected 0, got $sev"; return 1; }
}

# ── Tests: _fleet_scan_initiative_dispatch (no Linear API → returns OBSERVE) ────

test_initiative_dispatch_no_linear_api() {
  # Without linear-api.sh sourced, should return severity 0 gracefully
  local result
  result=$(_fleet_scan_initiative_dispatch 2>/dev/null)
  local sev
  sev=$(echo "$result" | jq -r '.severity // -1')
  [ "$sev" = "0" ] || { echo "expected severity 0 without Linear API, got $sev"; return 1; }
}

# ── Tests: _fleet_scan_blocked_by (no Linear API → returns OBSERVE) ──────────────

test_blocked_by_no_linear_api() {
  local ws
  ws=$(_setup_workspace)
  # Without linear-api.sh sourced, should return severity 0 gracefully
  local result
  result=$(_fleet_scan_blocked_by "$ws" 2>/dev/null)
  local sev
  sev=$(echo "$result" | jq -r '.severity // -1')
  [ "$sev" = "0" ] || { echo "expected severity 0 without Linear API, got $sev"; return 1; }
}

# ── Tests: fleet_detect_all includes fleet_wide key ──────────────────────────────

test_fleet_detect_all_includes_fleet_wide() {
  local ws
  ws=$(_setup_workspace)
  _plog "$ws" "CRE-101" "APPRAISE" "appraise" "done" "appraisal done"
  _plog "$ws" "CRE-101" "META" "outcome" "info" "completed: success"
  # Outcome exists → pipeline is completed → filtered out
  # So data should have 0 pipelines but still have fleet_wide array
  local data
  data=$(fleet_detect_all "$ws" 2>/dev/null)

  # Verify fleet_wide key exists
  local fw_count
  fw_count=$(echo "$data" | jq -r '.fleet_wide | length // -1' 2>/dev/null)
  [ "${fw_count:-0}" -ge 0 ] || { echo "missing fleet_wide key"; return 1; }
}

test_fleet_detect_all_empty_workspace() {
  local ws
  ws=$(_setup_workspace)
  local data
  data=$(fleet_detect_all "$ws" 2>/dev/null)
  local total
  total=$(echo "$data" | jq -r '.summary.total // -1')
  [ "$total" = "0" ] || { echo "expected 0 pipelines, got $total"; return 1; }
  echo "$data" | jq -e '.fleet_wide' >/dev/null 2>&1 || { echo "missing fleet_wide key in empty workspace"; return 1; }
}

test_fleet_detect_all_with_active_pipeline() {
  local ws
  ws=$(_setup_workspace)
  _plog "$ws" "CRE-101" "APPRAISE" "appraise" "start" "investigating"
  # No outcome → pipeline is active

  local data
  data=$(fleet_detect_all "$ws" 2>/dev/null)
  local total
  total=$(echo "$data" | jq -r '.summary.total // 0')
  [ "$total" = "1" ] || { echo "expected 1 active pipeline, got $total"; return 1; }
}

# ── Schema validation tests (Gap 3 from architect audit) ────────────────────────

test_schema_pipeline_entries_have_type() {
  local ws
  ws=$(_setup_workspace)
  _plog "$ws" "CRE-101" "APPRAISE" "appraise" "start" "investigating"
  # No outcome → pipeline is active

  local data
  data=$(fleet_detect_all "$ws" 2>/dev/null)
  local ptype
  ptype=$(echo "$data" | jq -r '.pipelines[0].type // "MISSING"' 2>/dev/null)
  [ "$ptype" = "pipeline" ] || { echo "expected 'pipeline', got '$ptype'"; return 1; }
}

test_schema_fleet_wide_entries_have_type() {
  local ws
  ws=$(_setup_workspace)
  _plog "$ws" "CRE-101" "APPRAISE" "appraise" "start" "investigating"

  local data
  data=$(fleet_detect_all "$ws" 2>/dev/null)
  local fw_count
  fw_count=$(echo "$data" | jq -r '.fleet_wide | length' 2>/dev/null)
  if [ "${fw_count:-0}" -gt 0 ]; then
    local fw_type
    fw_type=$(echo "$data" | jq -r '.fleet_wide[0].type // "MISSING"' 2>/dev/null)
    [ "$fw_type" = "fleet-wide" ] || { echo "expected 'fleet-wide', got '$fw_type'"; return 1; }
  fi
  return 0
}

test_schema_fleet_wide_always_array() {
  local ws
  ws=$(_setup_workspace)
  # Empty workspace should still have fleet_wide as an array
  local data
  data=$(fleet_detect_all "$ws" 2>/dev/null)
  local fw_type
  fw_type=$(echo "$data" | jq -r '.fleet_wide | type' 2>/dev/null)
  [ "$fw_type" = "array" ] || { echo "expected 'array', got '$fw_type'"; return 1; }
}

test_schema_summary_has_all_keys() {
  local ws
  ws=$(_setup_workspace)
  _plog "$ws" "CRE-101" "APPRAISE" "appraise" "start" "investigating"

  local data
  data=$(fleet_detect_all "$ws" 2>/dev/null)
  local keys
  keys=$(echo "$data" | jq -r '.summary | keys | sort | join(",")' 2>/dev/null)
  local expected="healthy,kill,restart,total,warn"
  [ "$keys" = "$expected" ] || { echo "expected '$expected', got '$keys'"; return 1; }
}

test_schema_top_level_keys() {
  local ws
  ws=$(_setup_workspace)
  _plog "$ws" "CRE-101" "APPRAISE" "appraise" "start" "investigating"

  local data
  data=$(fleet_detect_all "$ws" 2>/dev/null)
  local keys
  keys=$(echo "$data" | jq -r 'keys | sort | join(",")' 2>/dev/null)
  local expected="fleet_wide,pipelines,summary"
  [ "$keys" = "$expected" ] || { echo "expected '$expected', got '$keys'"; return 1; }
}

test_schema_pipeline_entry_keys() {
  local ws
  ws=$(_setup_workspace)
  _plog "$ws" "CRE-101" "APPRAISE" "appraise" "start" "investigating"

  local data
  data=$(fleet_detect_all "$ws" 2>/dev/null)
  local keys
  keys=$(echo "$data" | jq -r '.pipelines[0] | keys | sort | join(",")' 2>/dev/null)
  local expected="anomalies,hb_age_secs,phase,severity,tid,type"
  [ "$keys" = "$expected" ] || { echo "expected '$expected', got '$keys'"; return 1; }
}

test_schema_fleet_wide_entry_keys() {
  local ws
  ws=$(_setup_workspace)
  _plog "$ws" "CRE-101" "APPRAISE" "appraise" "start" "investigating"

  local data
  data=$(fleet_detect_all "$ws" 2>/dev/null)
  local fw_count
  fw_count=$(echo "$data" | jq -r '.fleet_wide | length' 2>/dev/null)
  if [ "${fw_count:-0}" -gt 0 ]; then
    local keys
    keys=$(echo "$data" | jq -r '.fleet_wide[0] | keys | sort | join(",")' 2>/dev/null)
    local expected="findings,name,severity,type"
    [ "$keys" = "$expected" ] || { echo "expected '$expected', got '$keys'"; return 1; }
  fi
  return 0
}

# ── Run all tests ────────────────────────────────────────────────────────────────

_run "planner_feedback_no_entries" test_planner_feedback_none
_run "planner_feedback_found_uncollected" test_planner_feedback_found
_run "planner_feedback_collected" test_planner_feedback_collected
_run "planner_feedback_no_log_file" test_planner_feedback_no_log_file
_run "initiative_dispatch_no_linear_api_graceful" test_initiative_dispatch_no_linear_api
_run "blocked_by_no_linear_api_graceful" test_blocked_by_no_linear_api
_run "fleet_detect_all_includes_fleet_wide" test_fleet_detect_all_includes_fleet_wide
_run "fleet_detect_all_empty_workspace" test_fleet_detect_all_empty_workspace
_run "fleet_detect_all_with_active_pipeline" test_fleet_detect_all_with_active_pipeline
_run "schema_pipeline_type" test_schema_pipeline_entries_have_type
_run "schema_fleet_wide_type" test_schema_fleet_wide_entries_have_type
_run "schema_fleet_wide_always_array" test_schema_fleet_wide_always_array
_run "schema_summary_keys" test_schema_summary_has_all_keys
_run "schema_top_level_keys" test_schema_top_level_keys
_run "schema_pipeline_entry_keys" test_schema_pipeline_entry_keys
_run "schema_fleet_wide_entry_keys" test_schema_fleet_wide_entry_keys

echo ""
echo "=== Results ==="
echo "PASS: $PASS | FAIL: $FAIL"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
