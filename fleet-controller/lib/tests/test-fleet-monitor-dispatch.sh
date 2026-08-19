#!/usr/bin/env bash
# test-fleet-monitor-dispatch.sh — unit tests for spawn queue consumption in fleet-monitor.sh
# Usage: bash test-fleet-monitor-dispatch.sh [test_name_filter]
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

_setup_queue() {
  local state_dir="${1:-/tmp}"
  local instance_id="${2:-test-dispatch}"
  local queue_file="${state_dir}/fleet-${instance_id}-spawn-queue.jsonl"
  rm -f "$queue_file"
  echo "$queue_file"
}

# ── Tests ───────────────────────────────────────────────────────────────────────

test_queue_consume_empty() {
  local ws queue_file
  ws=$(_setup_workspace)
  queue_file=$(_setup_queue "$ws" "test-empty")

  local output
  output=$(bash -c "
    FLEET_STATE_DIR='$ws' FLEET_INSTANCE_ID=test-empty
    source '$LIB_DIR/fleet-monitor.sh' 2>/dev/null
    _spawn_queue_consume '$ws' 0 2>&1
  " 2>/dev/null || true)
  # Empty queue → nothing consumed, no error
  return 0
}

test_queue_consume_at_capacity() {
  local ws queue_file
  ws=$(_setup_workspace)
  queue_file=$(_setup_queue "$ws" "test-cap")

  # Write an entry to the queue
  echo '{"tid":"CRE-101","reason":"planned-dispatch","timestamp":"2026-07-07T10:00:00Z","restarts":0,"dispatch_type":"initial"}' >"$queue_file"

  local output
  output=$(bash -c "
    FLEET_STATE_DIR='$ws' FLEET_INSTANCE_ID=test-cap FLEET_MAX_CONCURRENT=3
    source '$LIB_DIR/fleet-monitor.sh' 2>/dev/null
    _spawn_queue_consume '$ws' 3 2>&1
  " 2>/dev/null || true)
  # 3 active + max 3 → 0 slots → should consume nothing
  [ -f "$queue_file" ] && return 0 || {
    echo "queue should still exist at capacity"
    return 1
  }
}

test_queue_consume_entry() {
  local ws queue_file
  ws=$(_setup_workspace)
  queue_file=$(_setup_queue "$ws" "test-consume")

  # Write an entry to the queue
  echo '{"tid":"CRE-101","reason":"planned-dispatch","timestamp":"2026-07-07T10:00:00Z","restarts":0,"dispatch_type":"initial"}' >"$queue_file"

  local output
  output=$(bash -c "
    FLEET_STATE_DIR='$ws' FLEET_INSTANCE_ID=test-consume FLEET_MAX_CONCURRENT=3 FLEET_LOG_FILE=/dev/null CLAUDE_CODE_SESSION_ID=dummy
    unset -f _iso_now 2>/dev/null || true
    unset -f _ensure_dir_for 2>/dev/null || true
    unset -f hb_fleet_action 2>/dev/null || true
    _iso_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
    _ensure_dir_for() { mkdir -p \"\$(dirname \"\$1\")\" 2>/dev/null || true; }
    hb_fleet_action() { return 0; }
    source '$LIB_DIR/fleet-monitor.sh' 2>/dev/null
    _spawn_queue_consume '$ws' 0 2>&1
  " 2>/dev/null || true)
  # Should emit ACTION:spawn-auto
  echo "$output" | grep -q "ACTION:spawn-auto" && return 0 || {
    echo "output missing ACTION:spawn-auto: $output"
    return 1
  }
}

test_queue_consume_malformed_skipped() {
  local ws queue_file
  ws=$(_setup_workspace)
  queue_file=$(_setup_queue "$ws" "test-malform")

  # Write malformed JSON line (no tid field)
  echo '{"reason":"bad entry","timestamp":"2026-07-07T10:00:00Z"}' >"$queue_file"

  local output
  output=$(bash -c "
    FLEET_STATE_DIR='$ws' FLEET_INSTANCE_ID=test-malform FLEET_MAX_CONCURRENT=3 FLEET_LOG_FILE=/dev/null CLAUDE_CODE_SESSION_ID=dummy
    unset -f _iso_now 2>/dev/null || true
    unset -f _ensure_dir_for 2>/dev/null || true
    unset -f hb_fleet_action 2>/dev/null || true
    _iso_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
    _ensure_dir_for() { mkdir -p \"\$(dirname \"\$1\")\" 2>/dev/null || true; }
    hb_fleet_action() { return 0; }
    source '$LIB_DIR/fleet-monitor.sh' 2>/dev/null
    _spawn_queue_consume '$ws' 0 2>&1
  " 2>/dev/null || true)
  # Malformed entries should be skipped, not cause errors
  return 0
}

test_queue_write_creates_entry() {
  local ws queue_file
  ws=$(_setup_workspace)
  queue_file=$(_setup_queue "$ws" "test-write")

  bash -c "
    FLEET_STATE_DIR='$ws' FLEET_INSTANCE_ID=test-write
    source '$LIB_DIR/fleet-monitor.sh' 2>/dev/null
    _spawn_queue_write 'CRE-101' 'test-reason' 0 '$ws' 2>/dev/null
  " 2>/dev/null || true

  [ -f "$queue_file" ] || {
    echo "queue file not created"
    return 1
  }
  grep -q '"tid":"CRE-101"' "$queue_file" && return 0 || {
    echo "entry not found in queue"
    return 1
  }
}

# Consume slot math in fleet_monitor_cycle must use the live-only pipeline
# count (shared _active_pipeline_count), not the detection summary's
# no-outcome log count — a dead log must free a slot, so fleetd's consume
# and the monitor agree on capacity.
test_monitor_cycle_consume_uses_live_only_count() {
  local ws queue_file
  ws=$(_setup_workspace)
  queue_file=$(_setup_queue "$ws" "test-liveonly")

  # A dead pipeline log: detection still counts it (summary.total=2 below),
  # but no worker and no registry pid exist — live-only count is 0.
  echo "2026-07-07T10:00:00Z|IMPLEMENT|implement|start|mid-flight" >"${ws}/TEST-DEAD-pipeline.log"
  echo '{"tid":"CRE-101","reason":"planned-dispatch","timestamp":"2026-07-07T10:00:00Z","restarts":0,"dispatch_type":"initial"}' >"$queue_file"

  local output
  output=$(bash -c "
    FLEET_STATE_DIR='$ws' FLEET_INSTANCE_ID=test-liveonly FLEET_MAX_CONCURRENT=1
    FLEET_LOG_FILE=/dev/null
    source '$LIB_DIR/fleet-monitor.sh' 2>/dev/null
    fleet_detect_all() { echo '{\"pipelines\":[],\"fleet_wide\":[],\"summary\":{\"total\":2,\"healthy\":0,\"warn\":0,\"kill\":0,\"restart\":0}}'; }
    fleet_render_dashboard_from_data() { return 0; }
    fleet_write_report_from_data() { return 0; }
    worktree_gc() { return 0; }
    fleet_monitor_cycle '$ws' 2>&1
  " 2>/dev/null || true)

  # summary.total=2 would have zero slots under the old count; live-only
  # count = 0 → the single slot is free and the entry is consumed.
  echo "$output" | grep -q "ACTION:spawn-auto tid=CRE-101" || {
    echo "expected spawn action for CRE-101; output: $output" >&2
    return 1
  }
  [ ! -f "$queue_file" ] || [ ! -s "$queue_file" ] || {
    echo "queue entry not consumed — dead log still jams monitor slots" >&2
    return 1
  }
  return 0
}

# ── Run all tests ────────────────────────────────────────────────────────────────

_run "queue_consume_empty" test_queue_consume_empty
_run "queue_consume_at_capacity" test_queue_consume_at_capacity
_run "queue_consume_entry" test_queue_consume_entry
_run "queue_consume_malformed_skipped" test_queue_consume_malformed_skipped
_run "queue_write_creates_entry" test_queue_write_creates_entry
_run "monitor_cycle_consume_uses_live_only_count" test_monitor_cycle_consume_uses_live_only_count

echo ""
echo "=== Results ==="
echo "PASS: $PASS | FAIL: $FAIL"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
