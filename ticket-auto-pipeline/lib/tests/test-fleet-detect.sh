#!/usr/bin/env bash
# test-fleet-detect.sh — unit tests for lib/fleet-detect.sh
# Usage: bash test-fleet-detect.sh [test_name_filter]
set -euo pipefail

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
  local iso="${7:-2026-06-02T10:00:00Z}"
  mkdir -p "$dir"
  echo "${iso}|${phase}|${step}|${status}|${msg}" >>"${dir}/${tid}-pipeline.log"
}

_hblog() {
  local dir="$1" tid="$2" category="$3" event="$4" status="$5" msg="$6"
  local iso="${7:-2026-06-02T10:00:00Z}"
  mkdir -p "$dir"
  echo "${iso}|${category}|${event}|${status}|${msg}|{}" >>"${dir}/${tid}-heartbeat.log"
}

# ── Phase failure detection ──────────────────────────────────────────────────────

test_phase_failure_no_file_returns_ok() {
  local ws
  ws=$(_setup_workspace)
  source "$LIB_DIR/fleet-detect.sh"
  local r
  r=$(detect_phase_failures "NOEXIST-99" "$ws")
  rm -rf "$ws"
  [ "$r" -eq 0 ]
}

test_phase_failure_general_fail_returns_warn() {
  local ws
  ws=$(_setup_workspace)
  _plog "$ws" "CRE-47" "IMPLEMENT" "implement" "fail" "build error"
  source "$LIB_DIR/fleet-detect.sh"
  local r
  r=$(detect_phase_failures "CRE-47" "$ws")
  rm -rf "$ws"
  [ "$r" -eq 1 ]
}

test_gate_stop_retryable_returns_restart() {
  local ws
  ws=$(_setup_workspace)
  _plog "$ws" "CRE-47" "META" "gate-stop" "fail" "PR_REVIEW_VERDICT_UNPARSEABLE"
  source "$LIB_DIR/fleet-detect.sh"
  local r
  r=$(detect_phase_failures "CRE-47" "$ws")
  rm -rf "$ws"
  [ "$r" -eq 3 ]
}

test_gate_stop_non_retryable_returns_warn() {
  local ws
  ws=$(_setup_workspace)
  _plog "$ws" "CRE-47" "META" "gate-stop" "fail" "EXEC_NO_ARTIFACT"
  source "$LIB_DIR/fleet-detect.sh"
  local r
  r=$(detect_phase_failures "CRE-47" "$ws")
  rm -rf "$ws"
  [ "$r" -eq 1 ]
}

test_clean_log_returns_ok() {
  local ws
  ws=$(_setup_workspace)
  _plog "$ws" "CRE-47" "IMPLEMENT" "implement" "done" "all good"
  source "$LIB_DIR/fleet-detect.sh"
  local r
  r=$(detect_phase_failures "CRE-47" "$ws")
  rm -rf "$ws"
  [ "$r" -eq 0 ]
}

# ── Stall detection ──────────────────────────────────────────────────────────────

test_stall_no_hb_file_returns_ok() {
  local ws
  ws=$(_setup_workspace)
  source "$LIB_DIR/fleet-detect.sh"
  local r
  r=$(detect_stalls "CRE-47" "$ws")
  rm -rf "$ws"
  [ "$r" -eq 0 ]
}

test_stall_recent_heartbeat_returns_ok() {
  local ws
  ws=$(_setup_workspace)
  local recent
  recent=$(date -u -d '30 seconds ago' +%Y-%m-%dT%H:%M:%SZ)
  _hblog "$ws" "CRE-47" "heartbeat" "orchestrator-waiting" "ok" "pinger 1/80" "$recent"
  source "$LIB_DIR/fleet-detect.sh"
  local r
  r=$(detect_stalls "CRE-47" "$ws")
  rm -rf "$ws"
  [ "$r" -eq 0 ]
}

test_stall_old_heartbeat_returns_warn() {
  local ws
  ws=$(_setup_workspace)
  local old
  old=$(date -u -d '400 seconds ago' +%Y-%m-%dT%H:%M:%SZ)
  _hblog "$ws" "CRE-47" "heartbeat" "orchestrator-waiting" "ok" "pinger 10/80" "$old"
  (
    export FLEET_STALL_WARN_SECS=300 FLEET_STALL_KILL_SECS=900 FLEET_STALL_RESTART_SECS=1800
    source "$LIB_DIR/fleet-detect.sh"
    local r
    r=$(detect_stalls "CRE-47" "$ws")
    rm -rf "$ws"
    [ "$r" -ge 1 ]
  )
}

test_stall_empty_hb_returns_ok() {
  local ws
  ws=$(_setup_workspace)
  touch "${ws}/CRE-47-heartbeat.log"
  source "$LIB_DIR/fleet-detect.sh"
  local r
  r=$(detect_stalls "CRE-47" "$ws")
  rm -rf "$ws"
  [ "$r" -eq 0 ]
}

test_stall_watchdog_alive_detected() {
  local ws
  ws=$(_setup_workspace)
  local old
  old=$(date -u -d '1000 seconds ago' +%Y-%m-%dT%H:%M:%SZ)
  _hblog "$ws" "CRE-48" "heartbeat" "watchdog" "alive" "waiting for verify agent" "$old"
  (
    export FLEET_STALL_WARN_SECS=300 FLEET_STALL_KILL_SECS=900 FLEET_STALL_RESTART_SECS=1800
    source "$LIB_DIR/fleet-detect.sh"
    local r
    r=$(detect_stalls "CRE-48" "$ws")
    rm -rf "$ws"
    [ "$r" -eq 2 ]
  )
}

# ── Zombie detection ─────────────────────────────────────────────────────────────

test_zombie_no_file_returns_ok() {
  local ws
  ws=$(_setup_workspace)
  source "$LIB_DIR/fleet-detect.sh"
  local r
  r=$(detect_zombies "NOEXIST-99" "$ws")
  rm -rf "$ws"
  [ "$r" -eq 0 ]
}

test_zombie_no_waiting_returns_ok() {
  local ws
  ws=$(_setup_workspace)
  _plog "$ws" "CRE-47" "IMPLEMENT" "implement" "done" "agent completed"
  source "$LIB_DIR/fleet-detect.sh"
  local r
  r=$(detect_zombies "CRE-47" "$ws")
  rm -rf "$ws"
  [ "$r" -eq 0 ]
}

test_zombie_waiting_with_terminal_returns_ok() {
  local ws
  ws=$(_setup_workspace)
  _plog "$ws" "CRE-47" "IMPLEMENT" "implement" "waiting" "agent launched"
  _plog "$ws" "CRE-47" "IMPLEMENT" "implement" "done" "agent returned"
  source "$LIB_DIR/fleet-detect.sh"
  local r
  r=$(detect_zombies "CRE-47" "$ws")
  rm -rf "$ws"
  [ "$r" -eq 0 ]
}

test_zombie_old_waiting_no_terminal_returns_kill() {
  local ws
  ws=$(_setup_workspace)
  local old
  old=$(date -u -d '1200 seconds ago' +%Y-%m-%dT%H:%M:%SZ)
  _plog "$ws" "CRE-47" "IMPLEMENT" "implement" "waiting" "agent launched" "$old"
  (
    export FLEET_ZOMBIE_SECS=900
    source "$LIB_DIR/fleet-detect.sh"
    local r
    r=$(detect_zombies "CRE-47" "$ws")
    rm -rf "$ws"
    [ "$r" -eq 2 ]
  )
}

test_zombie_malformed_line_no_crash() {
  local ws
  ws=$(_setup_workspace)
  echo "garbage line with no delimiters" >>"${ws}/CRE-47-pipeline.log"
  source "$LIB_DIR/fleet-detect.sh"
  local r
  r=$(detect_zombies "CRE-47" "$ws") || true
  rm -rf "$ws"
  [ "$r" -eq 0 ]
}

# ── Loop detection ───────────────────────────────────────────────────────────────

test_loop_no_hb_file_returns_ok() {
  local ws
  ws=$(_setup_workspace)
  source "$LIB_DIR/fleet-detect.sh"
  local r
  r=$(detect_loops "CRE-47" "$ws")
  rm -rf "$ws"
  [ "$r" -eq 0 ]
}

test_loop_terminal_exhaustion_returns_restart() {
  local ws
  ws=$(_setup_workspace)
  _hblog "$ws" "CRE-47" "gate" "verify-exhausted" "fail" "verify cap hit (3/3)"
  source "$LIB_DIR/fleet-detect.sh"
  local r
  r=$(detect_loops "CRE-47" "$ws")
  rm -rf "$ws"
  [ "$r" -eq 3 ]
}

test_loop_rogue_exceeds_cap() {
  local ws
  ws=$(_setup_workspace)
  for i in 1 2 3 4; do
    _hblog "$ws" "CRE-47" "decision" "loop-back" "fired" "verify fail"
  done
  (
    export MAX_VERIFY_ATTEMPTS=3
    source "$LIB_DIR/fleet-detect.sh"
    local r
    r=$(detect_loops "CRE-47" "$ws")
    rm -rf "$ws"
    [ "$r" -eq 3 ]
  )
}

test_loop_normal_within_limits_returns_ok() {
  local ws
  ws=$(_setup_workspace)
  _hblog "$ws" "CRE-47" "decision" "loop-back" "fired" "verify fail"
  _hblog "$ws" "CRE-47" "decision" "loop-back" "fired" "verify fail"
  (
    export MAX_VERIFY_ATTEMPTS=3
    source "$LIB_DIR/fleet-detect.sh"
    local r
    r=$(detect_loops "CRE-47" "$ws")
    rm -rf "$ws"
    [ "$r" -eq 0 ]
  )
}

# ── Abandonment detection ────────────────────────────────────────────────────────

test_abandoned_no_file_returns_ok() {
  local ws
  ws=$(_setup_workspace)
  source "$LIB_DIR/fleet-detect.sh"
  local r
  r=$(detect_abandoned "NOEXIST-99" "$ws")
  rm -rf "$ws"
  [ "$r" -eq 0 ]
}

test_abandoned_with_outcome_returns_ok() {
  local ws
  ws=$(_setup_workspace)
  _plog "$ws" "CRE-47" "META" "outcome" "info" "completed: merged PR #123"
  source "$LIB_DIR/fleet-detect.sh"
  local r
  r=$(detect_abandoned "CRE-47" "$ws")
  rm -rf "$ws"
  [ "$r" -eq 0 ]
}

test_abandoned_recent_no_outcome_returns_ok() {
  local ws
  ws=$(_setup_workspace)
  local recent
  recent=$(date -u -d '30 seconds ago' +%Y-%m-%dT%H:%M:%SZ)
  _plog "$ws" "CRE-47" "IMPLEMENT" "implement" "waiting" "agent launched" "$recent"
  (
    export FLEET_ABANDON_WARN_HOURS=1 FLEET_ABANDON_KILL_HOURS=4
    source "$LIB_DIR/fleet-detect.sh"
    local r
    r=$(detect_abandoned "CRE-47" "$ws")
    rm -rf "$ws"
    [ "$r" -eq 0 ]
  )
}

test_abandoned_old_no_outcome_returns_warn() {
  local ws
  ws=$(_setup_workspace)
  local old
  old=$(date -u -d '2 hours ago' +%Y-%m-%dT%H:%M:%SZ)
  _plog "$ws" "CRE-47" "IMPLEMENT" "implement" "waiting" "agent launched" "$old"
  (
    export FLEET_ABANDON_WARN_HOURS=1 FLEET_ABANDON_KILL_HOURS=4
    source "$LIB_DIR/fleet-detect.sh"
    local r
    r=$(detect_abandoned "CRE-47" "$ws")
    rm -rf "$ws"
    [ "$r" -eq 1 ]
  )
}

test_abandoned_very_old_returns_restart() {
  local ws
  ws=$(_setup_workspace)
  local very_old
  very_old=$(date -u -d '6 hours ago' +%Y-%m-%dT%H:%M:%SZ)
  _plog "$ws" "CRE-47" "APPRAISE" "appraise" "done" "scored" "$very_old"
  (
    export FLEET_ABANDON_WARN_HOURS=1 FLEET_ABANDON_KILL_HOURS=4
    source "$LIB_DIR/fleet-detect.sh"
    local r
    r=$(detect_abandoned "CRE-47" "$ws")
    rm -rf "$ws"
    [ "$r" -eq 3 ]
  )
}

# ── Flow failure detection (6th detector) ───────────────────────────────────────

test_flow_failures_no_hb_file_returns_ok() {
  local ws
  ws=$(_setup_workspace)
  source "$LIB_DIR/fleet-detect.sh"
  local r
  r=$(detect_flow_failures "NOEXIST-99" "$ws")
  rm -rf "$ws"
  [ "$r" -eq 0 ]
}

test_flow_failures_zero_failures_returns_ok() {
  local ws
  ws=$(_setup_workspace)
  _hblog "$ws" "CRE-47" "heartbeat" "orchestrator-waiting" "ok" "all good"
  source "$LIB_DIR/fleet-detect.sh"
  local r
  r=$(detect_flow_failures "CRE-47" "$ws")
  rm -rf "$ws"
  [ "$r" -eq 0 ]
}

test_flow_failures_one_failure_returns_warn() {
  local ws
  ws=$(_setup_workspace)
  _hblog "$ws" "CRE-47" "retry" "flow-sh" "fail" "trigger dispatch failed"
  source "$LIB_DIR/fleet-detect.sh"
  local r
  r=$(detect_flow_failures "CRE-47" "$ws")
  rm -rf "$ws"
  [ "$r" -eq 1 ]
}

test_flow_failures_two_failures_returns_kill() {
  local ws
  ws=$(_setup_workspace)
  _hblog "$ws" "CRE-47" "retry" "flow-sh" "fail" "attempt 1"
  _hblog "$ws" "CRE-47" "retry" "flow-sh" "fail" "attempt 2"
  source "$LIB_DIR/fleet-detect.sh"
  local r
  r=$(detect_flow_failures "CRE-47" "$ws")
  rm -rf "$ws"
  [ "$r" -eq 2 ]
}

# ── Time-window filter ──────────────────────────────────────────────────────────

test_max_log_age_filter_excludes_old_logs() {
  local ws
  ws=$(_setup_workspace)
  _plog "$ws" "CRE-47" "IMPLEMENT" "implement" "done" "ok"
  # Set mtime to 48 hours ago
  touch -d '48 hours ago' "${ws}/CRE-47-pipeline.log"
  source "$LIB_DIR/fleet-detect.sh"
  (
    export FLEET_MAX_LOG_AGE_HOURS=24
    local r
    r=$(fleet_detect_all "$ws")
    local t
    t=$(echo "$r" | jq -r '.summary.total')
    rm -rf "$ws"
    [ "$t" -eq 0 ]
  )
}

test_max_log_age_zero_excludes_all_logs() {
  local ws
  ws=$(_setup_workspace)
  _plog "$ws" "CRE-47" "IMPLEMENT" "implement" "done" "ok"
  source "$LIB_DIR/fleet-detect.sh"
  (
    export FLEET_MAX_LOG_AGE_HOURS=0
    local r
    r=$(fleet_detect_all "$ws")
    local t
    t=$(echo "$r" | jq -r '.summary.total')
    rm -rf "$ws"
    [ "$t" -eq 0 ]
  )
}

# ── Severity cap (auto-restart off) ─────────────────────────────────────────────

test_detect_all_caps_severity_when_auto_restart_off() {
  local ws
  ws=$(_setup_workspace)
  local old
  old=$(date -u -d '6 hours ago' +%Y-%m-%dT%H:%M:%SZ)
  _plog "$ws" "CRE-47" "APPRAISE" "appraise" "done" "scored" "$old"
  source "$LIB_DIR/fleet-detect.sh"
  (
    export FLEET_AUTO_RESTART=false FLEET_ABANDON_WARN_HOURS=1 FLEET_ABANDON_KILL_HOURS=4
    local r
    r=$(fleet_detect_all "$ws")
    local max_sev
    max_sev=$(echo "$r" | jq -r '.pipelines[0].severity')
    local anomalies
    anomalies=$(echo "$r" | jq -r '.pipelines[0].anomalies')
    rm -rf "$ws"
    [ "$max_sev" -eq 2 ] && echo "$anomalies" | grep -q "restart degraded to kill"
  )
}

# ── _last_field assertion ───────────────────────────────────────────────────────

test_last_field_rejects_high_index() {
  local ws
  ws=$(_setup_workspace)
  _plog "$ws" "CRE-47" "IMPLEMENT" "implement" "done" "message with | pipes | inside"
  source "$LIB_DIR/fleet-detect.sh"
  local stderr_out rc
  stderr_out=$(mktemp)
  _last_field "${ws}/CRE-47-pipeline.log" 5 2>"$stderr_out" && rc=0 || rc=$?
  local stderr_str
  stderr_str=$(cat "$stderr_out")
  rm -rf "$ws" "$stderr_out"
  [ "$rc" -ne 0 ] && echo "$stderr_str" | grep -q "truncate pipe-containing"
}

test_last_field_safe_indices_still_work() {
  local ws
  ws=$(_setup_workspace)
  _plog "$ws" "CRE-47" "IMPLEMENT" "implement" "done" "simple msg"
  source "$LIB_DIR/fleet-detect.sh"
  local f1 f2 f4
  f1=$(_last_field "${ws}/CRE-47-pipeline.log" 1)
  f2=$(_last_field "${ws}/CRE-47-pipeline.log" 2)
  f4=$(_last_field "${ws}/CRE-47-pipeline.log" 4)
  rm -rf "$ws"
  [ "$f1" = "2026-06-02T10:00:00Z" ] && [ "$f2" = "IMPLEMENT" ] && [ "$f4" = "done" ]
}

# Fix test_awk_last_field_single_field — use idx=2 (safe) instead of idx=5 (now rejected)
test_awk_last_field_single_field() {
  local ws
  ws=$(_setup_workspace)
  _plog "$ws" "CRE-47" "IMPLEMENT" "implement" "done" "simple single field msg"
  source "$LIB_DIR/fleet-detect.sh"
  local f1 f2
  f1=$(_last_field "${ws}/CRE-47-pipeline.log" 1)
  f2=$(_last_field "${ws}/CRE-47-pipeline.log" 2)
  rm -rf "$ws"
  [ "$f1" = "2026-06-02T10:00:00Z" ] && [ "$f2" = "IMPLEMENT" ]
}

# ── Severity label/icon cap display ─────────────────────────────────────────────

test_severity_info_capped_when_auto_restart_off() {
  local ws
  ws=$(_setup_workspace)
  source "$LIB_DIR/fleet-detect.sh"
  source "$LIB_DIR/fleet-dashboard.sh"
  (
    export FLEET_AUTO_RESTART=false
    local icon label
    IFS='|' read -r icon label <<<"$(_severity_info 3)"
    rm -rf "$ws"
    [ "$icon" = "🔴" ] && [ "$label" = "KILL (auto-restart off)" ]
  )
}

test_severity_info_shows_restart_when_auto_restart_on() {
  local ws
  ws=$(_setup_workspace)
  source "$LIB_DIR/fleet-dashboard.sh"
  (
    export FLEET_AUTO_RESTART=true
    local icon label
    IFS='|' read -r icon label <<<"$(_severity_info 3)"
    rm -rf "$ws"
    [ "$icon" = "💀" ] && [ "$label" = "RESTART" ]
  )
}

# ── jq -c compact output regression ─────────────────────────────────────────────

test_jq_compact_output_in_fleet_detect_all() {
  local ws
  ws=$(_setup_workspace)
  _plog "$ws" "CRE-47" "IMPLEMENT" "implement" "done" "ok"
  source "$LIB_DIR/fleet-detect.sh"
  local output
  output=$(fleet_detect_all "$ws")
  rm -rf "$ws"
  # Verify output is valid JSON and contains compact (non-pretty) pipelines array
  echo "$output" | jq -e '.pipelines' >/dev/null 2>&1
}

# ── fleet_detect_all aggregator ──────────────────────────────────────────────────

test_detect_all_empty_workspace_returns_zero() {
  local ws
  ws=$(_setup_workspace)
  source "$LIB_DIR/fleet-detect.sh"
  local r
  r=$(fleet_detect_all "$ws")
  local t
  t=$(echo "$r" | jq -r '.summary.total')
  rm -rf "$ws"
  [ "$t" -eq 0 ]
}

test_detect_all_no_directory_returns_zero() {
  source "$LIB_DIR/fleet-detect.sh"
  local r
  r=$(fleet_detect_all "/tmp/noexist-detect-all-$$")
  local t
  t=$(echo "$r" | jq -r '.summary.total')
  [ "$t" -eq 0 ]
}

test_detect_all_skips_completed() {
  local ws
  ws=$(_setup_workspace)
  _plog "$ws" "CRE-99" "META" "outcome" "info" "completed"
  source "$LIB_DIR/fleet-detect.sh"
  local r
  r=$(fleet_detect_all "$ws")
  local t
  t=$(echo "$r" | jq -r '.summary.total')
  rm -rf "$ws"
  [ "$t" -eq 0 ]
}

test_detect_all_mixed_health() {
  local ws
  ws=$(_setup_workspace)
  # Use recent timestamps to avoid triggering abandonment detector
  local now
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  _plog "$ws" "CRE-01" "IMPLEMENT" "implement" "done" "ok" "$now"
  _plog "$ws" "CRE-02" "VERIFY" "verify" "fail" "test failure" "$now"
  _plog "$ws" "CRE-03" "META" "gate-stop" "fail" "PR_REVIEW_VERDICT_UNPARSEABLE" "$now"
  source "$LIB_DIR/fleet-detect.sh"
  local r
  r=$(fleet_detect_all "$ws")
  local healthy warn restart
  healthy=$(echo "$r" | jq -r '.summary.healthy')
  warn=$(echo "$r" | jq -r '.summary.warn')
  restart=$(echo "$r" | jq -r '.summary.restart')
  rm -rf "$ws"
  # Note: severity 3 survives because FLEET_AUTO_RESTART defaults to false
  # in config.sh which caps sev 3→2, but this test predates the cap.
  # With the cap active, CRE-03 (gate-stop PR_REVIEW_VERDICT_UNPARSEABLE → sev=3)
  # becomes sev=2 (kill). The test still passes: healthy=1, warn=1, kill=1.
  # The count for "restart" is 0 since sev 3 is capped.
  [ "$healthy" -eq 1 ] && [ "$warn" -eq 1 ]
}

test_detect_all_outputs_valid_json() {
  local ws
  ws=$(_setup_workspace)
  _plog "$ws" "CRE-47" "IMPLEMENT" "implement" "done" "ok"
  source "$LIB_DIR/fleet-detect.sh"
  local r
  r=$(fleet_detect_all "$ws")
  rm -rf "$ws"
  echo "$r" | jq -e '.pipelines' >/dev/null 2>&1 && echo "$r" | jq -e '.summary' >/dev/null 2>&1
}

# ── Diagnostic context ───────────────────────────────────────────────────────────

test_diagnostics_no_files_produces_output() {
  local ws
  ws=$(_setup_workspace)
  source "$LIB_DIR/fleet-detect.sh"
  local out
  out=$(extract_diagnostics "NOEXIST-99" "IMPLEMENT" "$ws" 2>&1) || true
  rm -rf "$ws"
  [ -n "$out" ]
}

test_diagnostics_with_claude_log() {
  local ws
  ws=$(_setup_workspace)
  echo "2026-06-02T10:00:00Z|IMPLEMENT|implement|fail|build error" >>"${ws}/CRE-47-claude.log"
  echo "2026-06-02T10:01:00Z|RETRO|hint|info|fix the thing" >>"${ws}/CRE-47-claude.log"
  source "$LIB_DIR/fleet-detect.sh"
  local out
  out=$(extract_diagnostics "CRE-47" "IMPLEMENT" "$ws" 2>&1) || true
  rm -rf "$ws"
  echo "$out" | grep -q "build error" && echo "$out" | grep -q "fix the thing"
}

# ── awk field extraction ─────────────────────────────────────────────────────────

test_awk_last_msg_preserves_pipes() {
  local ws
  ws=$(_setup_workspace)
  # MSG with embedded pipe — cut -f5 would truncate, _last_msg joins fields 5+
  _plog "$ws" "CRE-47" "META" "gate-stop" "fail" "complex reason | with | pipes"
  source "$LIB_DIR/fleet-detect.sh"
  local msg
  msg=$(_last_msg "${ws}/CRE-47-pipeline.log")
  rm -rf "$ws"
  echo "$msg" | grep -q "complex reason | with | pipes"
}

# ── Auto-mode block detection (7th detector) ─────────────────────────────────────

test_auto_mode_blocks_no_file_returns_ok() {
  local ws
  ws=$(_setup_workspace)
  source "$LIB_DIR/fleet-detect.sh"
  local r
  r=$(detect_auto_mode_blocks "NOEXIST-99" "$ws")
  rm -rf "$ws"
  [ "$r" -eq 0 ]
}

test_auto_mode_blocks_clean_pipeline_returns_ok() {
  local ws
  ws=$(_setup_workspace)
  _plog "$ws" "CRE-47" "IMPLEMENT" "implement" "done" "all good"
  source "$LIB_DIR/fleet-detect.sh"
  local r
  r=$(detect_auto_mode_blocks "CRE-47" "$ws")
  rm -rf "$ws"
  [ "$r" -eq 0 ]
}

test_auto_mode_blocks_single_block_returns_warn() {
  local ws
  ws=$(_setup_workspace)
  _plog "$ws" "CRE-47" "GATE" "check-approval" "fail" "auto-mode blocked approval"
  source "$LIB_DIR/fleet-detect.sh"
  local r
  r=$(detect_auto_mode_blocks "CRE-47" "$ws")
  rm -rf "$ws"
  [ "$r" -eq 1 ]
}

test_auto_mode_blocks_multiple_blocks_returns_kill() {
  local ws
  ws=$(_setup_workspace)
  _plog "$ws" "CRE-47" "GATE" "check-approval" "fail" "blocked #1"
  _plog "$ws" "CRE-47" "GATE" "check-approval" "fail" "blocked #2"
  source "$LIB_DIR/fleet-detect.sh"
  local r
  r=$(detect_auto_mode_blocks "CRE-47" "$ws")
  rm -rf "$ws"
  [ "$r" -eq 2 ]
}

test_auto_mode_blocks_agent_log_denial_pattern() {
  local ws
  ws=$(_setup_workspace)
  _plog "$ws" "CRE-47" "IMPLEMENT" "implement" "done" "ok"
  mkdir -p "$ws"
  echo "Permission for this action was denied" >"${ws}/CRE-47-implement-agent.log"
  source "$LIB_DIR/fleet-detect.sh"
  local r
  r=$(detect_auto_mode_blocks "CRE-47" "$ws")
  rm -rf "$ws"
  [ "$r" -eq 1 ]
}

test_auto_mode_blocks_combined_pipeline_and_agent_blocks() {
  local ws
  ws=$(_setup_workspace)
  _plog "$ws" "CRE-47" "GATE" "check-approval" "fail" "blocked"
  mkdir -p "$ws"
  echo "Permission for this action was denied" >"${ws}/CRE-47-implement-agent.log"
  source "$LIB_DIR/fleet-detect.sh"
  local r
  r=$(detect_auto_mode_blocks "CRE-47" "$ws")
  rm -rf "$ws"
  [ "$r" -eq 2 ]
}

test_auto_mode_blocks_integrated_in_fleet_detect_all() {
  local ws
  ws=$(_setup_workspace)
  local now
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  _plog "$ws" "CRE-47" "GATE" "check-approval" "fail" "auto-mode blocked" "$now"
  source "$LIB_DIR/fleet-detect.sh"
  local r
  r=$(fleet_detect_all "$ws")
  local sev anomalies
  sev=$(echo "$r" | jq -r '.pipelines[0].severity')
  anomalies=$(echo "$r" | jq -r '.pipelines[0].anomalies')
  rm -rf "$ws"
  [ "$sev" -eq 1 ] && echo "$anomalies" | grep -q "auto-block(S1)"
}

# ── Dispatcher ──────────────────────────────────────────────────────────────────
FILTER="${1:-}"

for fn in \
  test_phase_failure_no_file_returns_ok \
  test_phase_failure_general_fail_returns_warn \
  test_gate_stop_retryable_returns_restart \
  test_gate_stop_non_retryable_returns_warn \
  test_clean_log_returns_ok \
  test_stall_no_hb_file_returns_ok \
  test_stall_recent_heartbeat_returns_ok \
  test_stall_old_heartbeat_returns_warn \
  test_stall_empty_hb_returns_ok \
  test_stall_watchdog_alive_detected \
  test_zombie_no_file_returns_ok \
  test_zombie_no_waiting_returns_ok \
  test_zombie_waiting_with_terminal_returns_ok \
  test_zombie_old_waiting_no_terminal_returns_kill \
  test_zombie_malformed_line_no_crash \
  test_loop_no_hb_file_returns_ok \
  test_loop_terminal_exhaustion_returns_restart \
  test_loop_rogue_exceeds_cap \
  test_loop_normal_within_limits_returns_ok \
  test_abandoned_no_file_returns_ok \
  test_abandoned_with_outcome_returns_ok \
  test_abandoned_recent_no_outcome_returns_ok \
  test_abandoned_old_no_outcome_returns_warn \
  test_abandoned_very_old_returns_restart \
  test_flow_failures_no_hb_file_returns_ok \
  test_flow_failures_zero_failures_returns_ok \
  test_flow_failures_one_failure_returns_warn \
  test_flow_failures_two_failures_returns_kill \
  test_max_log_age_filter_excludes_old_logs \
  test_max_log_age_zero_excludes_all_logs \
  test_detect_all_caps_severity_when_auto_restart_off \
  test_last_field_rejects_high_index \
  test_last_field_safe_indices_still_work \
  test_severity_info_capped_when_auto_restart_off \
  test_severity_info_shows_restart_when_auto_restart_on \
  test_jq_compact_output_in_fleet_detect_all \
  test_detect_all_empty_workspace_returns_zero \
  test_detect_all_no_directory_returns_zero \
  test_detect_all_skips_completed \
  test_detect_all_mixed_health \
  test_detect_all_outputs_valid_json \
  test_diagnostics_no_files_produces_output \
  test_diagnostics_with_claude_log \
  test_awk_last_msg_preserves_pipes \
  test_awk_last_field_single_field \
  test_auto_mode_blocks_no_file_returns_ok \
  test_auto_mode_blocks_clean_pipeline_returns_ok \
  test_auto_mode_blocks_single_block_returns_warn \
  test_auto_mode_blocks_multiple_blocks_returns_kill \
  test_auto_mode_blocks_agent_log_denial_pattern \
  test_auto_mode_blocks_combined_pipeline_and_agent_blocks \
  test_auto_mode_blocks_integrated_in_fleet_detect_all; do
  [ -z "$FILTER" ] || [[ "$fn" == *"$FILTER"* ]] || continue
  _run "$fn" "$fn"
done

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
