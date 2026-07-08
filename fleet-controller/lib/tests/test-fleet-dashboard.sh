#!/usr/bin/env bash
# test-fleet-dashboard.sh — unit tests for lib/fleet-dashboard.sh
# Usage: bash test-fleet-dashboard.sh [test_name_filter]
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

# ── mocks ──────────────────────────────────────────────────────────────────────

_iso_now() { echo "2026-06-05T12:00:00Z"; }
_plog() { return 0; }
_source_if_missing() { return 0; }
fleet_detect_all() { echo '{"summary":{"total":0,"healthy":0,"warn":0,"kill":0,"restart":0},"pipelines":[]}'; }
extract_diagnostics() { echo "diagnostics for $1"; }

# ── Source fleet-dashboard.sh ──────────────────────────────────────────────────

source "$LIB_DIR/fleet-dashboard.sh"

# ═══════════════════════════════════════════════════════════════════════════════
# _severity_info tests (4)
# ═══════════════════════════════════════════════════════════════════════════════

test_severity_0_ok() {
  local icon label
  IFS='|' read -r icon label <<<"$(_severity_info 0)"
  [ "$icon" = "🟢" ] && [ "$label" = "OK" ]
}

test_severity_1_warn() {
  local icon label
  IFS='|' read -r icon label <<<"$(_severity_info 1)"
  [ "$icon" = "🟡" ] && [ "$label" = "WARN" ]
}

test_severity_2_kill() {
  local icon label
  IFS='|' read -r icon label <<<"$(_severity_info 2)"
  [ "$icon" = "🔴" ] && [ "$label" = "KILL" ]
}

test_severity_3_restart() {
  # With FLEET_AUTO_RESTART=true, severity 3 shows RESTART.
  # Run in subshell so the export doesn't leak to other tests.
  (
    export FLEET_AUTO_RESTART=true
    icon="" label=""
    IFS='|' read -r icon label <<<"$(_severity_info 3)"
    [ "$icon" = "💀" ] && [ "$label" = "RESTART" ]
  )
}

test_severity_3_capped_to_kill_when_restart_off() {
  # Default: FLEET_AUTO_RESTART unset → defaults to false → capped to KILL
  local icon label
  IFS='|' read -r icon label <<<"$(_severity_info 3)"
  [ "$icon" = "🔴" ] && echo "$label" | grep -q "KILL"
}

# ═══════════════════════════════════════════════════════════════════════════════
# fleet_render_dashboard_from_data tests (6)
# ═══════════════════════════════════════════════════════════════════════════════

test_render_no_pipelines() {
  local data='{"summary":{"total":0,"healthy":0,"warn":0,"kill":0,"restart":0},"pipelines":[]}'
  local output
  output=$(fleet_render_dashboard_from_data "$data" "/tmp/test-ws")
  echo "$output" | grep -q "No active pipelines"
}

test_render_header_present() {
  local data='{"summary":{"total":1,"healthy":1,"warn":0,"kill":0,"restart":0},"pipelines":[{"tid":"WIL-1","phase":"IMPLEMENT","hb_age_secs":30,"severity":0,"anomalies":"none"}]}'
  local output
  output=$(fleet_render_dashboard_from_data "$data" "/tmp/test-ws")
  echo "$output" | grep -q "TICKET" && echo "$output" | grep -q "PHASE" && echo "$output" | grep -q "SEV"
}

test_render_shows_ticket_row() {
  local data='{"summary":{"total":1,"healthy":1,"warn":0,"kill":0,"restart":0},"pipelines":[{"tid":"WIL-1","phase":"IMPLEMENT","hb_age_secs":30,"severity":0,"anomalies":"none"}]}'
  local output
  output=$(fleet_render_dashboard_from_data "$data" "/tmp/test-ws")
  echo "$output" | grep -q "WIL-1" && echo "$output" | grep -q "IMPLEMENT"
}

test_render_shows_summary() {
  local data='{"summary":{"total":3,"healthy":1,"warn":1,"kill":1,"restart":0},"pipelines":[]}'
  local output
  output=$(fleet_render_dashboard_from_data "$data" "/tmp/test-ws")
  echo "$output" | grep -q "3 active" && echo "$output" | grep -q "1 healthy"
}

test_render_formats_stall_over_1h() {
  local data='{"summary":{"total":1,"healthy":0,"warn":1,"kill":0,"restart":0},"pipelines":[{"tid":"WIL-99","phase":"VERIFY","hb_age_secs":3723,"severity":1,"anomalies":"stall"}]}'
  local output
  output=$(fleet_render_dashboard_from_data "$data" "/tmp/test-ws")
  # 3723 seconds = 1h2m3s → should show "1h2m"
  echo "$output" | grep -q "1h2m"
}

test_render_formats_stall_under_1m() {
  local data='{"summary":{"total":1,"healthy":1,"warn":0,"kill":0,"restart":0},"pipelines":[{"tid":"WIL-1","phase":"APPRAISE","hb_age_secs":45,"severity":0,"anomalies":"none"}]}'
  local output
  output=$(fleet_render_dashboard_from_data "$data" "/tmp/test-ws")
  # 45 seconds → should show "45s"
  echo "$output" | grep -q "45s"
}

# ═══════════════════════════════════════════════════════════════════════════════
# fleet_write_report_from_data tests (3)
# ═══════════════════════════════════════════════════════════════════════════════

test_write_report_creates_file() {
  local tmpdir
  tmpdir=$(mktemp -d)
  local data='{"summary":{"total":0,"healthy":0,"warn":0,"kill":0,"restart":0},"pipelines":[]}'
  fleet_write_report_from_data "$data" "$tmpdir" 2>/dev/null
  local rc=$?
  local report_file="$tmpdir/reports/fleet-dashboard.md"
  [ "$rc" -eq 0 ] && [ -f "$report_file" ] && grep -q "No active pipelines" "$report_file"
  rm -rf "$tmpdir"
}

test_write_report_includes_alerts_section() {
  local tmpdir
  tmpdir=$(mktemp -d)
  local data='{"summary":{"total":1,"healthy":0,"warn":0,"kill":1,"restart":0},"pipelines":[{"tid":"WIL-5","phase":"VERIFY","hb_age_secs":900,"severity":2,"anomalies":"stall,zombie"}]}'
  fleet_write_report_from_data "$data" "$tmpdir" 2>/dev/null
  local report_file="$tmpdir/reports/fleet-dashboard.md"
  grep -q "## Alerts" "$report_file" && grep -q "WIL-5" "$report_file" && grep -q "stall,zombie" "$report_file"
  rm -rf "$tmpdir"
}

test_write_report_skips_alerts_when_all_healthy() {
  local tmpdir
  tmpdir=$(mktemp -d)
  local data='{"summary":{"total":1,"healthy":1,"warn":0,"kill":0,"restart":0},"pipelines":[{"tid":"WIL-1","phase":"IMPLEMENT","hb_age_secs":30,"severity":0,"anomalies":"none"}]}'
  fleet_write_report_from_data "$data" "$tmpdir" 2>/dev/null
  local report_file="$tmpdir/reports/fleet-dashboard.md"
  # Should NOT have alerts section when all healthy
  ! grep -q "## Alerts" "$report_file"
  rm -rf "$tmpdir"
}

# ═══════════════════════════════════════════════════════════════════════════════
# fleet_wide rendering tests (4) — Gap 1 from architect audit
# ═══════════════════════════════════════════════════════════════════════════════

test_render_fleet_wide_warn_detector() {
  local data
  data='{"summary":{"total":1,"healthy":1,"warn":0,"kill":0,"restart":0},"pipelines":[{"tid":"WIL-1","phase":"IMPLEMENT","hb_age_secs":30,"severity":0,"anomalies":"none","type":"pipeline"}],"fleet_wide":[{"name":"detect_blocked_by","severity":1,"findings":"2 unblocked: CRE-101 CRE-102","type":"fleet-wide"}]}'
  local output
  output=$(fleet_render_dashboard_from_data "$data" "/tmp/test-ws")
  # Should show fleet-wide section with detector name and findings
  echo "$output" | grep -q "Fleet-Wide Detectors" && \
    echo "$output" | grep -q "detect_blocked_by" && \
    echo "$output" | grep -q "CRE-101"
}

test_render_fleet_wide_clear_detector() {
  local data
  data='{"summary":{"total":1,"healthy":1,"warn":0,"kill":0,"restart":0},"pipelines":[{"tid":"WIL-1","phase":"IMPLEMENT","hb_age_secs":30,"severity":0,"anomalies":"none","type":"pipeline"}],"fleet_wide":[{"name":"detect_initiative_dispatch","severity":0,"findings":"","type":"fleet-wide"}]}'
  local output
  output=$(fleet_render_dashboard_from_data "$data" "/tmp/test-ws")
  echo "$output" | grep -q "detect_initiative_dispatch" && \
    echo "$output" | grep -q "clear"
}

test_write_report_includes_fleet_wide_section() {
  local tmpdir
  tmpdir=$(mktemp -d)
  local data
  data='{"summary":{"total":0,"healthy":0,"warn":0,"kill":0,"restart":0},"pipelines":[],"fleet_wide":[{"name":"detect_planner_feedback","severity":1,"findings":"3 uncollected","type":"fleet-wide"}]}'
  fleet_write_report_from_data "$data" "$tmpdir" 2>/dev/null
  local report_file="$tmpdir/reports/fleet-dashboard.md"
  grep -q "Fleet-Wide Detectors" "$report_file" && \
    grep -q "detect_planner_feedback" "$report_file" && \
    grep -q "3 uncollected" "$report_file"
  rm -rf "$tmpdir"
}

test_write_report_fleet_wide_table_has_detector_row() {
  local tmpdir
  tmpdir=$(mktemp -d)
  local data
  data='{"summary":{"total":0,"healthy":0,"warn":0,"kill":0,"restart":0},"pipelines":[],"fleet_wide":[{"name":"detect_blocked_by","severity":0,"findings":"clear","type":"fleet-wide"},{"name":"detect_initiative_dispatch","severity":1,"findings":"5 undispatched","type":"fleet-wide"}]}'
  fleet_write_report_from_data "$data" "$tmpdir" 2>/dev/null
  local report_file="$tmpdir/reports/fleet-dashboard.md"
  # Table header present
  grep -q "| Detector | Severity | Findings |" "$report_file" && \
    grep -q "detect_blocked_by" "$report_file" && \
    grep -q "detect_initiative_dispatch" "$report_file" && \
    grep -q "5 undispatched" "$report_file"
  rm -rf "$tmpdir"
}

# ═══════════════════════════════════════════════════════════════════════════════
# Runner
# ═══════════════════════════════════════════════════════════════════════════════

FILTER="${1:-}"
for fn in \
  test_severity_0_ok \
  test_severity_1_warn \
  test_severity_2_kill \
  test_severity_3_restart \
  test_severity_3_capped_to_kill_when_restart_off \
  test_render_no_pipelines \
  test_render_header_present \
  test_render_shows_ticket_row \
  test_render_shows_summary \
  test_render_formats_stall_over_1h \
  test_render_formats_stall_under_1m \
  test_write_report_creates_file \
  test_write_report_includes_alerts_section \
  test_write_report_skips_alerts_when_all_healthy \
  test_render_fleet_wide_warn_detector \
  test_render_fleet_wide_clear_detector \
  test_write_report_includes_fleet_wide_section \
  test_write_report_fleet_wide_table_has_detector_row; do
  [ -z "$FILTER" ] || [[ "$fn" == *"$FILTER"* ]] || continue
  _run "$fn" "$fn"
done

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
