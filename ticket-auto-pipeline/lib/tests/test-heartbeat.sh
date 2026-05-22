#!/usr/bin/env bash
# test-heartbeat.sh — unit tests for lib/heartbeat.sh
# No socat needed — heartbeat.sh has no network calls.
# Uses HB_LOG_FILE and CLAUDE_LOG_FILE env vars to toggle behavior.
# Usage: bash test-heartbeat.sh [test_name_filter]
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

# ── hb_write validation tests ─────────────────────────────────────────────────

test_hb_noop_when_log_unset() {
  # HB_LOG_FILE unset → no file created, returns 0
  local tmpfile="/tmp/hb-noop-test-$$"
  (
    unset HB_LOG_FILE 2>/dev/null || true
    source "$LIB_DIR/heartbeat.sh"
    hb_write "api" "test-event" "ok" "msg"
  )
  [ ! -f "$tmpfile" ]
}

test_hb_write_valid_entry_format() {
  local tmpfile
  tmpfile=$(mktemp)
  rm -f "$tmpfile"
  (
    export HB_LOG_FILE="$tmpfile"
    source "$LIB_DIR/heartbeat.sh"
    hb_write "api" "test-event" "ok" "test message"
  )
  local line
  line=$(cat "$tmpfile")
  local fields
  fields=$(echo "$line" | awk -F'|' '{print NF}')
  rm -f "$tmpfile"
  [ "$fields" -eq 6 ]
}

test_hb_write_rejects_bad_category() {
  local tmpfile
  tmpfile=$(mktemp)
  local exit_code=0
  (
    export HB_LOG_FILE="$tmpfile"
    source "$LIB_DIR/heartbeat.sh"
    hb_write "invalid" "my-event" "ok" "msg"
  ) 2>/dev/null || exit_code=$?
  local file_empty=true
  [ -s "$tmpfile" ] && file_empty=false
  rm -f "$tmpfile"
  [ "$exit_code" -ne 0 ] && $file_empty
}

test_hb_write_rejects_bad_status() {
  local tmpfile
  tmpfile=$(mktemp)
  local exit_code=0
  (
    export HB_LOG_FILE="$tmpfile"
    source "$LIB_DIR/heartbeat.sh"
    hb_write "api" "my-event" "bad-status" "msg"
  ) 2>/dev/null || exit_code=$?
  rm -f "$tmpfile"
  [ "$exit_code" -ne 0 ]
}

test_hb_write_rejects_camelCase_event() {
  local tmpfile
  tmpfile=$(mktemp)
  local exit_code=0
  (
    export HB_LOG_FILE="$tmpfile"
    source "$LIB_DIR/heartbeat.sh"
    hb_write "api" "myEvent" "ok" "msg"
  ) 2>/dev/null || exit_code=$?
  rm -f "$tmpfile"
  [ "$exit_code" -ne 0 ]
}

test_hb_write_rejects_pipe_in_msg() {
  local tmpfile
  tmpfile=$(mktemp)
  local exit_code=0
  (
    export HB_LOG_FILE="$tmpfile"
    source "$LIB_DIR/heartbeat.sh"
    hb_write "api" "my-event" "ok" "msg|with|pipes"
  ) 2>/dev/null || exit_code=$?
  rm -f "$tmpfile"
  [ "$exit_code" -ne 0 ]
}

test_hb_write_rejects_nested_json_detail() {
  local tmpfile
  tmpfile=$(mktemp)
  local exit_code=0
  (
    export HB_LOG_FILE="$tmpfile"
    source "$LIB_DIR/heartbeat.sh"
    hb_write "api" "my-event" "ok" "msg" '{"a":{"b":1}}'
  ) 2>/dev/null || exit_code=$?
  rm -f "$tmpfile"
  [ "$exit_code" -ne 0 ]
}

test_hb_write_rejects_invalid_json_detail() {
  local tmpfile
  tmpfile=$(mktemp)
  local exit_code=0
  (
    export HB_LOG_FILE="$tmpfile"
    source "$LIB_DIR/heartbeat.sh"
    hb_write "api" "my-event" "ok" "msg" "not json"
  ) 2>/dev/null || exit_code=$?
  rm -f "$tmpfile"
  [ "$exit_code" -ne 0 ]
}

test_hb_write_accepts_empty_detail() {
  local tmpfile
  tmpfile=$(mktemp)
  rm -f "$tmpfile"
  (
    export HB_LOG_FILE="$tmpfile"
    source "$LIB_DIR/heartbeat.sh"
    hb_write "api" "my-event" "ok" "msg"
  )
  local line
  line=$(cat "$tmpfile")
  rm -f "$tmpfile"
  # Last field should be {}
  [[ "$line" == *"|{}" ]]
}

# ── hb_init idempotency ───────────────────────────────────────────────────────

test_hb_init_idempotent() {
  local tmpfile
  tmpfile=$(mktemp)
  rm -f "$tmpfile"
  (
    export HB_LOG_FILE="$tmpfile"
    source "$LIB_DIR/heartbeat.sh"
    hb_init
    hb_init # second call should be a no-op
  )
  local schema_count
  schema_count=$(grep -c '|META|schema|' "$tmpfile" 2>/dev/null || echo 0)
  rm -f "$tmpfile"
  [ "$schema_count" -eq 1 ]
}

# ── hb_validate_line tests ────────────────────────────────────────────────────

test_hb_validate_line_valid() {
  local valid_line="2024-01-01T00:00:00Z|api|test-event|ok|test message|{}"
  (
    source "$LIB_DIR/heartbeat.sh"
    hb_validate_line "$valid_line"
  ) 2>/dev/null
}

test_hb_validate_line_bad_timestamp() {
  local bad_line="2024|api|test-event|ok|msg|{}"
  local exit_code=0
  (
    source "$LIB_DIR/heartbeat.sh"
    hb_validate_line "$bad_line"
  ) 2>/dev/null || exit_code=$?
  [ "$exit_code" -ne 0 ]
}

test_hb_validate_line_bad_field_count() {
  local bad_line="2024-01-01T00:00:00Z|api|event|ok" # 4 fields only
  local exit_code=0
  (
    source "$LIB_DIR/heartbeat.sh"
    hb_validate_line "$bad_line"
  ) 2>/dev/null || exit_code=$?
  [ "$exit_code" -ne 0 ]
}

# ── hb_validate_file tests ────────────────────────────────────────────────────

test_hb_validate_file_missing_schema_header() {
  local tmpfile
  tmpfile=$(mktemp)
  echo "2024-01-01T00:00:00Z|api|test-event|ok|msg|{}" >"$tmpfile"
  local exit_code=0
  (
    source "$LIB_DIR/heartbeat.sh"
    hb_validate_file "$tmpfile"
  ) 2>/dev/null || exit_code=$?
  rm -f "$tmpfile"
  [ "$exit_code" -ne 0 ]
}

test_hb_validate_file_empty() {
  local tmpfile
  tmpfile=$(mktemp)
  >"$tmpfile" # empty file
  local exit_code=0
  (
    source "$LIB_DIR/heartbeat.sh"
    hb_validate_file "$tmpfile"
  ) 2>/dev/null || exit_code=$?
  rm -f "$tmpfile"
  [ "$exit_code" -ne 0 ]
}

test_hb_validate_file_valid() {
  local tmpfile
  tmpfile=$(mktemp)
  {
    echo "2024-01-01T00:00:00Z|META|schema|info|1|{}"
    echo "2024-01-01T00:01:00Z|api|test-event|ok|msg one|{}"
    echo "2024-01-01T00:02:00Z|decision|my-decision|info|msg two|{}"
  } >"$tmpfile"
  local exit_code=0
  (
    source "$LIB_DIR/heartbeat.sh"
    hb_validate_file "$tmpfile"
  ) 2>/dev/null || exit_code=$?
  rm -f "$tmpfile"
  [ "$exit_code" -eq 0 ]
}

# ── cl_write / cl_init tests ──────────────────────────────────────────────────

test_cl_write_noop_when_unset() {
  local tmpfile="/tmp/cl-noop-test-$$"
  (
    unset CLAUDE_LOG_FILE 2>/dev/null || true
    source "$LIB_DIR/heartbeat.sh"
    cl_write RETRO hint info "test hint"
  )
  [ ! -f "$tmpfile" ]
}

test_cl_write_retro_hint_format() {
  local tmpfile
  tmpfile=$(mktemp)
  rm -f "$tmpfile"
  (
    export CLAUDE_LOG_FILE="$tmpfile"
    source "$LIB_DIR/heartbeat.sh"
    cl_write RETRO hint info "test hint message"
  )
  local line
  line=$(cat "$tmpfile")
  rm -f "$tmpfile"
  echo "$line" | grep -qE '^\S+\|RETRO\|hint\|info\|test hint message$'
}

test_cl_init_idempotent() {
  local tmpfile
  tmpfile=$(mktemp)
  rm -f "$tmpfile"
  (
    export CLAUDE_LOG_FILE="$tmpfile"
    source "$LIB_DIR/heartbeat.sh"
    cl_init
    cl_init # second call should be a no-op
  )
  local schema_count
  schema_count=$(grep -c '|META|schema|' "$tmpfile" 2>/dev/null || echo 0)
  rm -f "$tmpfile"
  [ "$schema_count" -eq 1 ]
}

# ── dispatch ──────────────────────────────────────────────────────────────────

FILTER="${1:-}"

for fn in \
  test_hb_noop_when_log_unset \
  test_hb_write_valid_entry_format \
  test_hb_write_rejects_bad_category \
  test_hb_write_rejects_bad_status \
  test_hb_write_rejects_camelCase_event \
  test_hb_write_rejects_pipe_in_msg \
  test_hb_write_rejects_nested_json_detail \
  test_hb_write_rejects_invalid_json_detail \
  test_hb_write_accepts_empty_detail \
  test_hb_init_idempotent \
  test_hb_validate_line_valid \
  test_hb_validate_line_bad_timestamp \
  test_hb_validate_line_bad_field_count \
  test_hb_validate_file_missing_schema_header \
  test_hb_validate_file_empty \
  test_hb_validate_file_valid \
  test_cl_write_noop_when_unset \
  test_cl_write_retro_hint_format \
  test_cl_init_idempotent; do
  [ -z "$FILTER" ] || [[ "$fn" == *"$FILTER"* ]] || continue
  _run "$fn" "$fn"
done

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
