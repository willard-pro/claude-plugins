#!/usr/bin/env bash
# test-worker-hooks.sh — unit tests for hooks/stop-capture.sh and
# hooks/stop-failure.sh (worker-reap-recovery task 6.6)
# Usage: bash test-worker-hooks.sh [test_name_filter]
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOKS_DIR="$(cd "$SCRIPT_DIR/../../hooks" && pwd)"
FLEET_SCHEMA_SQL="$SCRIPT_DIR/../../../fleet-controller/fleetd/schema.sql"

_TEST_TMPDIRS=()
_mktemp_test_dir() {
  local d
  d=$(mktemp -d)
  _TEST_TMPDIRS+=("$d")
  echo "$d"
}
_cleanup_test_tmpdirs() {
  local d
  for d in "${_TEST_TMPDIRS[@]}"; do
    rm -rf "$d" 2>/dev/null || true
  done
}
trap _cleanup_test_tmpdirs EXIT

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

_write_run_file() {
  # _write_run_file <state_dir> <tid> <session_id> <generation> [filename]
  # filename defaults to "<tid>-run.json"; pass an explicit filename when tid
  # itself isn't filesystem-safe (path-traversal test).
  local state_dir="$1" tid="$2" session_id="$3" generation="$4"
  local filename="${5:-$tid-run.json}"
  cat >"$state_dir/$filename" <<EOF
{"tid": "$tid", "session_id": "$session_id", "generation": $generation}
EOF
}

_store_insert_worker() {
  # _store_insert_worker <state_dir> <tid> <session_id> <generation>
  local state_dir="$1" tid="$2" session_id="$3" generation="$4"
  command -v sqlite3 >/dev/null 2>&1 || return 1
  sqlite3 -batch "$state_dir/fleet-state.db" <"$FLEET_SCHEMA_SQL" >/dev/null 2>&1 || true
  sqlite3 -batch "$state_dir/fleet-state.db" "
INSERT INTO tickets (tid) VALUES ('$tid');
INSERT INTO workers (tid, phase, pid, generation, session_id, status)
  VALUES ('$tid', 'implement', 1, $generation, '$session_id', 'running');
" >/dev/null 2>&1
}

FILTER="${1:-}"

# ── stop-capture.sh ────────────────────────────────────────────────────────

test_capture_writes_last_assistant_message() {
  local state_dir
  state_dir=$(_mktemp_test_dir)
  _write_run_file "$state_dir" "TST-1" "sess-abc" 1
  echo '{"session_id":"sess-abc","last_assistant_message":"need input to proceed"}' |
    FLEET_STATE_DIR="$state_dir" "$HOOKS_DIR/stop-capture.sh" >/dev/null 2>&1
  grep -q "need input to proceed" "$state_dir/TST-1-gen1-hook.json"
}

test_capture_noop_when_session_not_found() {
  local state_dir
  state_dir=$(_mktemp_test_dir)
  _write_run_file "$state_dir" "TST-1" "sess-abc" 1
  echo '{"session_id":"sess-does-not-match","last_assistant_message":"hello"}' |
    FLEET_STATE_DIR="$state_dir" "$HOOKS_DIR/stop-capture.sh" >/dev/null 2>&1
  ! ls "$state_dir"/*-hook.json >/dev/null 2>&1
}

test_capture_noop_when_message_empty() {
  local state_dir
  state_dir=$(_mktemp_test_dir)
  _write_run_file "$state_dir" "TST-1" "sess-abc" 1
  echo '{"session_id":"sess-abc","last_assistant_message":""}' |
    FLEET_STATE_DIR="$state_dir" "$HOOKS_DIR/stop-capture.sh" >/dev/null 2>&1
  ! ls "$state_dir"/*-hook.json >/dev/null 2>&1
}

test_capture_noop_when_state_dir_unset() {
  local out rc
  out=$(echo '{"session_id":"sess-abc","last_assistant_message":"hi"}' |
    FLEET_STATE_DIR="" "$HOOKS_DIR/stop-capture.sh" 2>&1)
  rc=$?
  [ "$rc" -eq 0 ]
}

test_capture_rejects_path_traversal_tid() {
  local state_dir parent
  state_dir=$(_mktemp_test_dir)
  parent="$(dirname "$state_dir")"
  _write_run_file "$state_dir" '../evil' "sess-abc" 1 "evil-run.json"
  echo '{"session_id":"sess-abc","last_assistant_message":"hi"}' |
    FLEET_STATE_DIR="$state_dir" "$HOOKS_DIR/stop-capture.sh" >/dev/null 2>&1
  [ ! -e "$parent/evil-gen1-hook.json" ] && ! ls "$state_dir"/*-hook.json >/dev/null 2>&1
}

test_capture_preserves_existing_hook_file_keys() {
  local state_dir
  state_dir=$(_mktemp_test_dir)
  _write_run_file "$state_dir" "TST-1" "sess-abc" 1
  echo '{"some_other_field": "keep-me"}' >"$state_dir/TST-1-gen1-hook.json"
  echo '{"session_id":"sess-abc","last_assistant_message":"final answer"}' |
    FLEET_STATE_DIR="$state_dir" "$HOOKS_DIR/stop-capture.sh" >/dev/null 2>&1
  grep -q "keep-me" "$state_dir/TST-1-gen1-hook.json" &&
    grep -q "final answer" "$state_dir/TST-1-gen1-hook.json"
}

test_capture_resolves_via_store_when_no_run_file() {
  command -v sqlite3 >/dev/null 2>&1 || return 0
  local state_dir
  state_dir=$(_mktemp_test_dir)
  _store_insert_worker "$state_dir" "TST-3" "sess-store" 2
  echo '{"session_id":"sess-store","last_assistant_message":"resolved via store"}' |
    FLEET_STATE_DIR="$state_dir" "$HOOKS_DIR/stop-capture.sh" >/dev/null 2>&1
  grep -q "resolved via store" "$state_dir/TST-3-gen2-hook.json"
}

test_capture_falls_back_to_file_when_store_has_no_match() {
  command -v sqlite3 >/dev/null 2>&1 || return 0
  local state_dir
  state_dir=$(_mktemp_test_dir)
  _store_insert_worker "$state_dir" "TST-OTHER" "sess-unrelated" 1
  _write_run_file "$state_dir" "TST-4" "sess-file-only" 1
  echo '{"session_id":"sess-file-only","last_assistant_message":"from file registry"}' |
    FLEET_STATE_DIR="$state_dir" "$HOOKS_DIR/stop-capture.sh" >/dev/null 2>&1
  grep -q "from file registry" "$state_dir/TST-4-gen1-hook.json"
}

# ── stop-failure.sh ────────────────────────────────────────────────────────

test_failure_appends_worker_api_error_line() {
  local state_dir
  state_dir=$(_mktemp_test_dir)
  _write_run_file "$state_dir" "TST-2" "sess-xyz" 1
  : >"$state_dir/TST-2-pipeline.log"
  echo '{"session_id":"sess-xyz"}' |
    FLEET_STATE_DIR="$state_dir" "$HOOKS_DIR/stop-failure.sh" >/dev/null 2>&1
  grep -q "META|worker-api-error|warn" "$state_dir/TST-2-pipeline.log"
}

test_failure_noop_when_pipeline_log_missing() {
  local state_dir
  state_dir=$(_mktemp_test_dir)
  _write_run_file "$state_dir" "TST-2" "sess-xyz" 1
  echo '{"session_id":"sess-xyz"}' |
    FLEET_STATE_DIR="$state_dir" "$HOOKS_DIR/stop-failure.sh" >/dev/null 2>&1
  [ ! -e "$state_dir/TST-2-pipeline.log" ]
}

test_failure_noop_when_session_not_found() {
  local state_dir
  state_dir=$(_mktemp_test_dir)
  _write_run_file "$state_dir" "TST-2" "sess-xyz" 1
  : >"$state_dir/TST-2-pipeline.log"
  echo '{"session_id":"sess-unmatched"}' |
    FLEET_STATE_DIR="$state_dir" "$HOOKS_DIR/stop-failure.sh" >/dev/null 2>&1
  ! grep -q "worker-api-error" "$state_dir/TST-2-pipeline.log"
}

test_failure_resolves_via_store_when_no_run_file() {
  command -v sqlite3 >/dev/null 2>&1 || return 0
  local state_dir
  state_dir=$(_mktemp_test_dir)
  _store_insert_worker "$state_dir" "TST-5" "sess-store-fail" 1
  : >"$state_dir/TST-5-pipeline.log"
  echo '{"session_id":"sess-store-fail"}' |
    FLEET_STATE_DIR="$state_dir" "$HOOKS_DIR/stop-failure.sh" >/dev/null 2>&1
  grep -q "META|worker-api-error|warn" "$state_dir/TST-5-pipeline.log"
}

# ── dispatch ─────────────────────────────────────────────────────────────

for fn in \
  test_capture_writes_last_assistant_message \
  test_capture_noop_when_session_not_found \
  test_capture_noop_when_message_empty \
  test_capture_noop_when_state_dir_unset \
  test_capture_rejects_path_traversal_tid \
  test_capture_preserves_existing_hook_file_keys \
  test_capture_resolves_via_store_when_no_run_file \
  test_capture_falls_back_to_file_when_store_has_no_match \
  test_failure_appends_worker_api_error_line \
  test_failure_noop_when_pipeline_log_missing \
  test_failure_noop_when_session_not_found \
  test_failure_resolves_via_store_when_no_run_file; do
  [ -z "$FILTER" ] || [[ "$fn" == *"$FILTER"* ]] || continue
  _run "$fn" "$fn"
done

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
