#!/usr/bin/env bash
# test-worker-hooks.sh — unit tests for hooks/stop-capture.sh and
# hooks/stop-failure.sh (worker-reap-recovery task 6.6)
# Usage: bash test-worker-hooks.sh [test_name_filter]
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOKS_DIR="$(cd "$SCRIPT_DIR/../../hooks" && pwd)"

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

# ── dispatch ─────────────────────────────────────────────────────────────

for fn in \
  test_capture_writes_last_assistant_message \
  test_capture_noop_when_session_not_found \
  test_capture_noop_when_message_empty \
  test_capture_noop_when_state_dir_unset \
  test_capture_rejects_path_traversal_tid \
  test_capture_preserves_existing_hook_file_keys \
  test_failure_appends_worker_api_error_line \
  test_failure_noop_when_pipeline_log_missing \
  test_failure_noop_when_session_not_found; do
  [ -z "$FILTER" ] || [[ "$fn" == *"$FILTER"* ]] || continue
  _run "$fn" "$fn"
done

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
