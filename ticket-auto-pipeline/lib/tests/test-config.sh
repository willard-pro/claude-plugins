#!/usr/bin/env bash
# test-config.sh — unit tests for lib/config.sh
# Usage: bash test-config.sh [test_name_filter]
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

# ── FLEET_INSTANCE_ID tests ────────────────────────────────────────────────────

test_fleet_instance_id_from_env_var() {
  (
    export FLEET_INSTANCE_ID="my-custom-project"
    source "$LIB_DIR/config.sh"
    [ "$FLEET_INSTANCE_ID" = "my-custom-project" ]
  )
}

test_fleet_instance_id_from_git() {
  (
    unset FLEET_INSTANCE_ID
    cd "$LIB_DIR/.."
    source "$LIB_DIR/config.sh"
    # Should be something like "willard.pro-claude-plugins"
    echo "$FLEET_INSTANCE_ID" | grep -q '-'
  )
}

test_fleet_instance_id_stable_from_subdirectory() {
  local id_root id_lib
  id_root=$(cd "$LIB_DIR/.." && unset FLEET_INSTANCE_ID && source "$LIB_DIR/config.sh" && echo "$FLEET_INSTANCE_ID")
  id_lib=$(cd "$LIB_DIR" && unset FLEET_INSTANCE_ID && source "$LIB_DIR/config.sh" && echo "$FLEET_INSTANCE_ID")
  [ "$id_root" = "$id_lib" ]
}

test_fleet_instance_id_fallback_to_pwd_basename() {
  local tmpdir
  tmpdir=$(mktemp -d)
  (
    unset FLEET_INSTANCE_ID
    cd "$tmpdir"
    # Not a git repo, should fall back to basename
    source "$LIB_DIR/config.sh" 2>/dev/null || true
    echo "$FLEET_INSTANCE_ID" | grep -q "$(basename "$tmpdir")"
  )
  rm -rf "$tmpdir"
}

test_fleet_instance_id_no_slash() {
  (
    source "$LIB_DIR/config.sh"
    [[ ! "$FLEET_INSTANCE_ID" =~ / ]]
  )
}

# ── FLEET_DEBUG default test ──────────────────────────────────────────────────

test_fleet_debug_default_false() {
  (
    unset FLEET_DEBUG
    source "$LIB_DIR/config.sh"
    [ "$FLEET_DEBUG" = "false" ]
  )
}

# ── Log file path defaults ────────────────────────────────────────────────────

test_fleet_hb_log_file_default() {
  (
    unset FLEET_HB_LOG_FILE
    source "$LIB_DIR/config.sh"
    [ "$FLEET_HB_LOG_FILE" = "./logs/fleet-controller-heartbeat.log" ]
  )
}

test_fleet_log_file_default() {
  (
    unset FLEET_LOG_FILE
    source "$LIB_DIR/config.sh"
    [ "$FLEET_LOG_FILE" = "./logs/fleet-controller.log" ]
  )
}

test_fleet_summary_interval_default() {
  (
    unset FLEET_SUMMARY_INTERVAL_CYCLES
    source "$LIB_DIR/config.sh"
    [ "$FLEET_SUMMARY_INTERVAL_CYCLES" = "10" ]
  )
}

# ── dispatch ──────────────────────────────────────────────────────────────────

FILTER="${1:-}"

for fn in \
  test_fleet_instance_id_from_env_var \
  test_fleet_instance_id_from_git \
  test_fleet_instance_id_stable_from_subdirectory \
  test_fleet_instance_id_fallback_to_pwd_basename \
  test_fleet_instance_id_no_slash \
  test_fleet_debug_default_false \
  test_fleet_hb_log_file_default \
  test_fleet_log_file_default \
  test_fleet_summary_interval_default; do
  [ -z "$FILTER" ] || [[ "$fn" == *"$FILTER"* ]] || continue
  _run "$fn" "$fn"
done

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
