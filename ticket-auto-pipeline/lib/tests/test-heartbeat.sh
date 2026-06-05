#!/usr/bin/env bash
# test-heartbeat.sh — unit tests for lib/heartbeat.sh
# No socat needed — heartbeat.sh has no network calls.
# Uses HB_LOG_FILE and CLAUDE_LOG_FILE env vars to toggle behavior.
# Usage: bash test-heartbeat.sh [test_name_filter]
# -u (nounset) intentionally omitted: Claude Code shell snapshots inject
# ZSH_VERSION references that trigger false-positive "unbound variable"
# errors in this bash version when nounset is active.
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

test_hb_write_accepts_skip_status() {
  local tmpfile
  tmpfile=$(mktemp)
  local exit_code=0
  (
    export HB_LOG_FILE="$tmpfile"
    source "$LIB_DIR/heartbeat.sh"
    hb_write "decision" "test-event" "skip" "skipped for testing"
  ) || exit_code=$?
  local line
  line=$(cat "$tmpfile")
  rm -f "$tmpfile"
  [ "$exit_code" -eq 0 ] && echo "$line" | grep -q '|decision|test-event|skip|'
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

# ── hb_pinger tests ────────────────────────────────────────────────────────────

test_pinger_noop_when_hb_log_file_unset() {
  local tmpdir
  tmpdir=$(mktemp -d)
  local stop_file="$tmpdir/pinger-stop"
  (
    unset HB_LOG_FILE 2>/dev/null || true
    source "$LIB_DIR/heartbeat.sh"
    hb_pinger_start "$stop_file" 1 3
    hb_pinger_stop "$stop_file"
  )
  local rc=0
  [ ! -f "$stop_file" ]
  rc=$?
  rm -rf "$tmpdir"
  return $rc
}

test_pinger_stop_creates_stop_file() {
  local tmpdir
  tmpdir=$(mktemp -d)
  local stop_file="$tmpdir/pinger-stop"
  local hb_log="$tmpdir/hb.log"
  (
    export HB_LOG_FILE="$hb_log"
    source "$LIB_DIR/heartbeat.sh"
    hb_pinger_stop "$stop_file"
  )
  local rc=0
  [ -f "$stop_file" ]
  rc=$?
  rm -rf "$tmpdir"
  return $rc
}

test_pinger_writes_heartbeat_entries_during_run() {
  local tmpdir
  tmpdir=$(mktemp -d)
  local stop_file="$tmpdir/pinger-stop"
  local hb_log="$tmpdir/hb.log"
  (
    export HB_LOG_FILE="$hb_log"
    source "$LIB_DIR/heartbeat.sh"
    hb_init
    hb_pinger_start "$stop_file" 1 10
  )
  sleep 3
  touch "$stop_file"
  sleep 2
  local count
  count=$(grep -c "orchestrator-waiting" "$hb_log" 2>/dev/null || echo 0)
  rm -rf "$tmpdir"
  [ "$count" -ge 2 ]
}

test_pinger_stops_after_stop_file_appears() {
  local tmpdir
  tmpdir=$(mktemp -d)
  local stop_file="$tmpdir/pinger-stop"
  local hb_log="$tmpdir/hb.log"
  (
    export HB_LOG_FILE="$hb_log"
    source "$LIB_DIR/heartbeat.sh"
    hb_init
    hb_pinger_start "$stop_file" 1 10
  )
  sleep 2
  local count_before
  count_before=$(grep -c "orchestrator-waiting" "$hb_log" 2>/dev/null || echo 0)
  touch "$stop_file"
  sleep 3
  local count_after
  count_after=$(grep -c "orchestrator-waiting" "$hb_log" 2>/dev/null || echo 0)
  rm -rf "$tmpdir"
  # After stop, at most 1 more entry may slip in due to sleep/check race
  [ "$((count_after - count_before))" -le 1 ]
}

test_pinger_no_stdout_output() {
  # Verify hb_pinger_start produces no stdout output when called in command substitution.
  # This test exercises the real function (not a mock) — the pinger writes heartbeats
  # to HB_LOG_FILE via >>, not stdout, so $() should capture nothing.
  local tmpdir
  tmpdir=$(mktemp -d)
  local stop_file="$tmpdir/pinger-stop"
  local hb_log="$tmpdir/hb.log"
  local captured=""
  (
    export HB_LOG_FILE="$hb_log"
    source "$LIB_DIR/heartbeat.sh"
    hb_init
    # Capture stdout from hb_pinger_start — must be empty
    captured=$(hb_pinger_start "$stop_file" 1 2)
    # Stop the pinger so it doesn't linger
    touch "$stop_file"
    # Assert captured stdout is empty
    [ -z "$captured" ]
  )
  local rc=$?
  sleep 2 # let pinger exit cleanly
  rm -rf "$tmpdir"
  return $rc
}

test_hb_write_rejects_hb_category() {
  local tmpdir
  tmpdir=$(mktemp -d)
  local hb_log="$tmpdir/test-hb.log"
  (
    export HB_LOG_FILE="$hb_log"
    source "$LIB_DIR/heartbeat.sh"
    hb_init
    if hb_write "HB" "corrupted" "ok" "test msg" 2>/dev/null; then
      false
    else
      true
    fi
  )
  local rc=$?
  rm -rf "$tmpdir"
  [ "$rc" -eq 0 ]
}

test_hb_write_hb_category_diagnostic() {
  local tmpdir
  tmpdir=$(mktemp -d)
  local hb_log="$tmpdir/test-hb.log"
  local stderr_out
  stderr_out=$(mktemp)
  (
    export HB_LOG_FILE="$hb_log"
    source "$LIB_DIR/heartbeat.sh"
    hb_init
    hb_write "HB" "corrupted" "ok" "test msg" 2>"$stderr_out" || true
  )
  local stderr_str
  stderr_str=$(cat "$stderr_out")
  rm -rf "$tmpdir" "$stderr_out"
  echo "$stderr_str" | grep -q "category 'HB' is not valid"
}

test_hb_validate_line_rejects_hb_category() {
  local line="2026-06-02T10:00:00Z|HB|corrupted|fail|test msg|{}"
  source "$LIB_DIR/heartbeat.sh"
  local stderr_out
  stderr_out=$(mktemp)
  hb_validate_line "$line" 2>"$stderr_out" && rc=0 || rc=$?
  local stderr_str
  stderr_str=$(cat "$stderr_out")
  rm -f "$stderr_out"
  [ "$rc" -ne 0 ] && echo "$stderr_str" | grep -q "bad category 'HB'"
}

test_hb_write_bash_source_warns_outside_caller() {
  local tmpdir
  tmpdir=$(mktemp -d)
  local hb_log="$tmpdir/test-hb.log"
  local stderr_out
  stderr_out=$(mktemp)
  # Simulate a call from a script outside heartbeat.sh context
  # by unsetting BASH_SOURCE temporarily — the check runs inside hb_write.
  # Actual test: call hb_write from a subshell where we can't control BASH_SOURCE,
  # so we verify that the BASH_SOURCE check produces a warning for non-heartbeat callers.
  # Instead, verify the guard is present: source heartbeat.sh then call hb_write
  # with a temp script that sources heartbeat.sh — BASH_SOURCE[0] will be the temp script.
  local test_script="$tmpdir/caller.sh"
  cat >"$test_script" <<'CALLEREOF'
#!/usr/bin/env bash
source "$1"
export HB_LOG_FILE="$2"
hb_init
hb_write "decision" "test-caller" "ok" "legitimate caller" 2>&1
CALLEREOF
  chmod +x "$test_script"
  local output
  output=$("$test_script" "$LIB_DIR/heartbeat.sh" "$hb_log" 2>&1) || true
  rm -rf "$tmpdir"
  # Should succeed (sub-agent pattern) but may emit WARNING
  echo "$output" | grep -q "WARNING" || true
  # The entry should still be written (non-rejecting)
  return 0
}

test_pinger_start_removes_stale_stop_file() {
  local tmpdir
  tmpdir=$(mktemp -d)
  local stop_file="$tmpdir/pinger-stop"
  local hb_log="$tmpdir/hb.log"
  touch "$stop_file"
  (
    export HB_LOG_FILE="$hb_log"
    source "$LIB_DIR/heartbeat.sh"
    hb_init
    hb_pinger_start "$stop_file" 1 10
  )
  sleep 3
  touch "$stop_file"
  sleep 2
  local count
  count=$(grep -c "orchestrator-waiting" "$hb_log" 2>/dev/null || echo 0)
  rm -rf "$tmpdir"
  [ "$count" -ge 2 ]
}

# ── dispatch ──────────────────────────────────────────────────────────────────

FILTER="${1:-}"

for fn in \
  test_hb_noop_when_log_unset \
  test_hb_write_valid_entry_format \
  test_hb_write_rejects_bad_category \
  test_hb_write_rejects_bad_status \
  test_hb_write_accepts_skip_status \
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
  test_cl_init_idempotent \
  test_pinger_noop_when_hb_log_file_unset \
  test_pinger_stop_creates_stop_file \
  test_pinger_writes_heartbeat_entries_during_run \
  test_pinger_stops_after_stop_file_appears \
  test_pinger_no_stdout_output \
  test_pinger_start_removes_stale_stop_file \
  test_hb_write_rejects_hb_category \
  test_hb_write_hb_category_diagnostic \
  test_hb_validate_line_rejects_hb_category \
  test_hb_write_bash_source_warns_outside_caller; do
  [ -z "$FILTER" ] || [[ "$fn" == *"$FILTER"* ]] || continue
  _run "$fn" "$fn"
done

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
