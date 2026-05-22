#!/usr/bin/env bash
# test-capture-transcript.sh — unit tests for lib/capture-transcript.sh
# capture_agent_result writes to ./logs/ relative to CWD — tests cd to tmpdir.
# Usage: bash test-capture-transcript.sh [test_name_filter]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

PASS=0
FAIL=0

_run() {
  local name="$1"; shift
  if "$@" 2>/dev/null; then
    echo "PASS: $name"; ((PASS++)) || true
  else
    echo "FAIL: $name"; ((FAIL++)) || true
  fi
}

# ── tests ──────────────────────────────────────────────────────────────────────

test_capture_single_attempt_overwrites() {
  local tmpdir; tmpdir=$(mktemp -d)
  (
    cd "$tmpdir"
    source "$LIB_DIR/capture-transcript.sh"
    capture_agent_result "WIL-1" "appraise" "first content"
    capture_agent_result "WIL-1" "appraise" "second content"
  )
  local content; content=$(cat "$tmpdir/logs/WIL-1-appraise-agent.log")
  rm -rf "$tmpdir"
  [ "$content" = "second content" ]
}

test_capture_multi_attempt_appends_with_separator() {
  local tmpdir; tmpdir=$(mktemp -d)
  (
    cd "$tmpdir"
    source "$LIB_DIR/capture-transcript.sh"
    capture_agent_result "WIL-1" "verify" "first try" "1"
    capture_agent_result "WIL-1" "verify" "second try" "2"
  )
  local content; content=$(cat "$tmpdir/logs/WIL-1-verify-agent.log")
  rm -rf "$tmpdir"
  echo "$content" | grep -q -e "--- Attempt 2 ---" && echo "$content" | grep -q "second try"
}

test_capture_noop_empty_ticket_id() {
  local tmpdir; tmpdir=$(mktemp -d)
  (
    cd "$tmpdir"
    source "$LIB_DIR/capture-transcript.sh"
    capture_agent_result "" "appraise" "some content"
  )
  local files_created=false
  [ -d "$tmpdir/logs" ] && ls "$tmpdir/logs/" | grep -q . && files_created=true || true
  rm -rf "$tmpdir"
  ! $files_created
}

test_capture_noop_empty_phase() {
  local tmpdir; tmpdir=$(mktemp -d)
  (
    cd "$tmpdir"
    source "$LIB_DIR/capture-transcript.sh"
    capture_agent_result "WIL-1" "" "some content"
  )
  local files_created=false
  [ -d "$tmpdir/logs" ] && ls "$tmpdir/logs/" | grep -q . && files_created=true || true
  rm -rf "$tmpdir"
  ! $files_created
}

# ── dispatch ──────────────────────────────────────────────────────────────────

FILTER="${1:-}"

for fn in \
  test_capture_single_attempt_overwrites \
  test_capture_multi_attempt_appends_with_separator \
  test_capture_noop_empty_ticket_id \
  test_capture_noop_empty_phase; do
  [ -z "$FILTER" ] || [[ "$fn" == *"$FILTER"* ]] || continue
  _run "$fn" "$fn"
done

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
