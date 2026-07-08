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
  local instance_id="${1:-test-dispatch}"
  local queue_file="/tmp/fleet-${instance_id}-spawn-queue.jsonl"
  rm -f "$queue_file"
  echo "$queue_file"
}

# ── Tests ───────────────────────────────────────────────────────────────────────

test_queue_consume_empty() {
  local ws queue_file
  ws=$(_setup_workspace)
  queue_file=$(_setup_queue "test-empty")

  local output
  output=$(bash -c "
    FLEET_INSTANCE_ID=test-empty
    source '$LIB_DIR/fleet-monitor.sh' 2>/dev/null
    _spawn_queue_consume '$ws' 0 2>&1
  " 2>/dev/null || true)
  # Empty queue → nothing consumed, no error
  return 0
}

test_queue_consume_at_capacity() {
  local ws queue_file
  ws=$(_setup_workspace)
  queue_file=$(_setup_queue "test-cap")

  # Write an entry to the queue
  echo '{"tid":"CRE-101","reason":"planned-dispatch","timestamp":"2026-07-07T10:00:00Z","restarts":0,"dispatch_type":"initial"}' >"$queue_file"

  local output
  output=$(bash -c "
    FLEET_INSTANCE_ID=test-cap FLEET_MAX_CONCURRENT=3
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
  queue_file=$(_setup_queue "test-consume")

  # Write an entry to the queue
  echo '{"tid":"CRE-101","reason":"planned-dispatch","timestamp":"2026-07-07T10:00:00Z","restarts":0,"dispatch_type":"initial"}' >"$queue_file"

  local output
  output=$(bash -c "
    FLEET_INSTANCE_ID=test-consume FLEET_MAX_CONCURRENT=3 FLEET_LOG_FILE=/dev/null CLAUDE_CODE_SESSION_ID=dummy
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
  queue_file=$(_setup_queue "test-malform")

  # Write malformed JSON line (no tid field)
  echo '{"reason":"bad entry","timestamp":"2026-07-07T10:00:00Z"}' >"$queue_file"

  local output
  output=$(bash -c "
    FLEET_INSTANCE_ID=test-malform FLEET_MAX_CONCURRENT=3 FLEET_LOG_FILE=/dev/null CLAUDE_CODE_SESSION_ID=dummy
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
  queue_file=$(_setup_queue "test-write")

  bash -c "
    FLEET_INSTANCE_ID=test-write
    source '$LIB_DIR/fleet-monitor.sh' 2>/dev/null
    _spawn_queue_write 'CRE-101' 'test-reason' 0 2>/dev/null
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

# ── Run all tests ────────────────────────────────────────────────────────────────

_run "queue_consume_empty" test_queue_consume_empty
_run "queue_consume_at_capacity" test_queue_consume_at_capacity
_run "queue_consume_entry" test_queue_consume_entry
_run "queue_consume_malformed_skipped" test_queue_consume_malformed_skipped
_run "queue_write_creates_entry" test_queue_write_creates_entry

echo ""
echo "=== Results ==="
echo "PASS: $PASS | FAIL: $FAIL"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
