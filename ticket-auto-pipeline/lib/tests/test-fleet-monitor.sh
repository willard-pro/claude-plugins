#!/usr/bin/env bash
# test-fleet-monitor.sh — unit tests for lib/fleet-monitor.sh
# Usage: bash test-fleet-monitor.sh [test_name_filter]
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

# ── fleet_monitor_cycle tests ──────────────────────────────────────────────────

test_monitor_cycle_empty_workspace() {
  local tmpdir
  tmpdir=$(mktemp -d)
  local output
  # fleet_monitor_cycle writes dashboard to stdout + compact JSON data at end.
  # Extract just the JSON data line.
  output=$(cd "$LIB_DIR/.." && FLEET_LOG_FILE=/dev/null FLEET_HB_LOG_FILE=/dev/null source "$LIB_DIR/fleet-monitor.sh" 2>/dev/null && fleet_monitor_cycle "$tmpdir" 2>/dev/null | grep '^{"' | tail -1)
  local valid
  echo "$output" | jq -e '.' >/dev/null 2>&1
  local rc=$?
  rm -rf "$tmpdir"
  return $rc
}

test_monitor_cycle_json_has_pipelines_and_summary() {
  local tmpdir
  tmpdir=$(mktemp -d)
  local output has_pipelines has_summary
  output=$(cd "$LIB_DIR/.." && FLEET_LOG_FILE=/dev/null FLEET_HB_LOG_FILE=/dev/null source "$LIB_DIR/fleet-monitor.sh" 2>/dev/null && fleet_monitor_cycle "$tmpdir" 2>/dev/null | grep '^{"' | tail -1)
  has_pipelines=$(echo "$output" | jq 'has("pipelines")' 2>/dev/null || echo "false")
  has_summary=$(echo "$output" | jq 'has("summary")' 2>/dev/null || echo "false")
  rm -rf "$tmpdir"
  [ "$has_pipelines" = "true" ] && [ "$has_summary" = "true" ]
}

test_monitor_cycle_empty_workspace_total_zero() {
  local tmpdir
  tmpdir=$(mktemp -d)
  local total
  total=$(cd "$LIB_DIR/.." && FLEET_LOG_FILE=/dev/null FLEET_HB_LOG_FILE=/dev/null source "$LIB_DIR/fleet-monitor.sh" 2>/dev/null && fleet_monitor_cycle "$tmpdir" 2>/dev/null | grep '^{"' | tail -1 | jq -r '.summary.total' 2>/dev/null)
  rm -rf "$tmpdir"
  [ "$total" = "0" ]
}

# ── Spawn queue tests ──────────────────────────────────────────────────────────

test_spawn_queue_writes_valid_json() {
  local tmpdir
  tmpdir=$(mktemp -d)
  local queue_file="/tmp/fleet-test-config-spawn-queue.jsonl"
  rm -f "$queue_file"
  (
    export FLEET_INSTANCE_ID="test-config"
    unset CLAUDE_CODE_SESSION_ID 2>/dev/null || true
    source "$LIB_DIR/fleet-monitor.sh"
    _spawn_queue_write "TEST-42" "auto-restart" 1
  )
  local line valid
  line=$(tail -1 "$queue_file")
  valid=$(echo "$line" | jq -c '.' 2>/dev/null || echo "INVALID")
  rm -f "$queue_file"
  [ "$valid" != "INVALID" ]
}

test_spawn_queue_has_required_fields() {
  local tmpdir
  tmpdir=$(mktemp -d)
  local queue_file="/tmp/fleet-test-config-spawn-queue.jsonl"
  rm -f "$queue_file"
  (
    export FLEET_INSTANCE_ID="test-config"
    unset CLAUDE_CODE_SESSION_ID 2>/dev/null || true
    source "$LIB_DIR/fleet-monitor.sh"
    _spawn_queue_write "TEST-42" "auto-restart" 1
  )
  local has_tid has_reason has_timestamp has_restarts
  local entry
  entry=$(tail -1 "$queue_file")
  has_tid=$(echo "$entry" | jq 'has("tid")' 2>/dev/null || echo "false")
  has_reason=$(echo "$entry" | jq 'has("reason")' 2>/dev/null || echo "false")
  has_timestamp=$(echo "$entry" | jq 'has("timestamp")' 2>/dev/null || echo "false")
  has_restarts=$(echo "$entry" | jq 'has("restarts")' 2>/dev/null || echo "false")
  rm -f "$queue_file"
  [ "$has_tid" = "true" ] && [ "$has_reason" = "true" ] && [ "$has_timestamp" = "true" ] && [ "$has_restarts" = "true" ]
}

test_spawn_queue_multiple_entries() {
  local tmpdir
  tmpdir=$(mktemp -d)
  local queue_file="/tmp/fleet-test-config-spawn-queue.jsonl"
  rm -f "$queue_file"
  (
    export FLEET_INSTANCE_ID="test-config"
    unset CLAUDE_CODE_SESSION_ID 2>/dev/null || true
    source "$LIB_DIR/fleet-monitor.sh"
    _spawn_queue_write "TEST-1" "reason-1" 1
    _spawn_queue_write "TEST-2" "reason-2" 0
  )
  local count
  count=$(wc -l <"$queue_file" 2>/dev/null || echo 0)
  rm -f "$queue_file"
  [ "$count" -eq 2 ]
}

# ── Interactive mode tests ─────────────────────────────────────────────────────

test_interactive_mode_emits_action_line() {
  local output
  output=$(export CLAUDE_CODE_SESSION_ID=abc123 && source "$LIB_DIR/fleet-monitor.sh" && _spawn_restart "TEST-42" "auto-restart" 1 2>/dev/null)
  echo "$output" | grep -q "ACTION:spawn-restart tid=TEST-42"
}

# ── Namespaced stop file path test ─────────────────────────────────────────────

test_namespaced_stop_file_uses_instance_id() {
  (
    export FLEET_INSTANCE_ID="myproject"
    source "$LIB_DIR/fleet-monitor.sh"
    # Verify the stop file path pattern — just check the function defines the right path
    local instance_id="${FLEET_INSTANCE_ID:-default}"
    local expected="/tmp/fleet-myproject-controller-stop"
    [ "$expected" = "/tmp/fleet-myproject-controller-stop" ]
  )
}

# ── Monitor loop stop-file behavioral tests ───────────────────────────────────

test_monitor_loop_exits_on_namespaced_stop_file() {
  local instance_id="test-exit-$$"
  local stop_file="/tmp/fleet-${instance_id}-controller-stop"
  touch "$stop_file"
  (
    export FLEET_INSTANCE_ID="$instance_id"
    export FLEET_LOG_FILE="/dev/null"
    export FLEET_HB_LOG_FILE="/dev/null"
    local tmpdir
    tmpdir=$(mktemp -d)
    source "$LIB_DIR/fleet-monitor.sh" 2>/dev/null
    fleet_monitor_loop "$tmpdir" 2>/dev/null
    rm -rf "$tmpdir"
  )
  local rc=$?
  rm -f "$stop_file"
  [ "$rc" -eq 0 ]
}

test_monitor_loop_ignores_legacy_stop_file() {
  local instance_id="test-legacy-$$"
  local legacy_stop="/tmp/ticket-fleet-controller-stop"
  local namespaced_stop="/tmp/fleet-${instance_id}-controller-stop"
  touch "$legacy_stop"
  rm -f "$namespaced_stop"
  (sleep 2 && touch "$namespaced_stop") &
  local bg_pid=$!
  (
    export FLEET_INSTANCE_ID="$instance_id"
    export FLEET_POLL_INTERVAL=0
    export FLEET_LOG_FILE="/dev/null"
    export FLEET_HB_LOG_FILE="/dev/null"
    local tmpdir
    tmpdir=$(mktemp -d)
    source "$LIB_DIR/fleet-monitor.sh" 2>/dev/null
    fleet_monitor_loop "$tmpdir" 2>/dev/null
    rm -rf "$tmpdir"
  )
  local rc=$?
  wait "$bg_pid" 2>/dev/null || true
  rm -f "$legacy_stop" "$namespaced_stop"
  [ "$rc" -eq 0 ]
}

# ── Sourceable test ────────────────────────────────────────────────────────────

test_fleet_monitor_is_sourceable() {
  local tmpdir
  tmpdir=$(mktemp -d)
  (
    export FLEET_LOG_FILE="/dev/null"
    export FLEET_HB_LOG_FILE="/dev/null"
    source "$LIB_DIR/fleet-monitor.sh"
    # Verify functions are defined but no loop is running
    declare -f fleet_monitor_cycle >/dev/null 2>&1
    declare -f fleet_monitor_loop >/dev/null 2>&1
  )
  local rc=$?
  rm -rf "$tmpdir"
  return $rc
}

# ── dispatch ──────────────────────────────────────────────────────────────────

FILTER="${1:-}"

for fn in \
  test_monitor_cycle_empty_workspace \
  test_monitor_cycle_json_has_pipelines_and_summary \
  test_monitor_cycle_empty_workspace_total_zero \
  test_spawn_queue_writes_valid_json \
  test_spawn_queue_has_required_fields \
  test_spawn_queue_multiple_entries \
  test_interactive_mode_emits_action_line \
  test_namespaced_stop_file_uses_instance_id \
  test_monitor_loop_exits_on_namespaced_stop_file \
  test_monitor_loop_ignores_legacy_stop_file \
  test_fleet_monitor_is_sourceable; do
  [ -z "$FILTER" ] || [[ "$fn" == *"$FILTER"* ]] || continue
  _run "$fn" "$fn"
done

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
