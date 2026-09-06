#!/usr/bin/env bash
# test-fleet-notify.sh — unit tests for fleet-notify.sh, the deterministic
# Slack notifier (worker-reap-recovery task 7.7). Uses a stub `curl` on PATH
# so no real network call is ever made.
# Usage: bash test-fleet-notify.sh [test_name_filter]
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

source "$LIB_DIR/fleet-notify.sh"

# ── stub curl ────────────────────────────────────────────────────────────────
# Installs a fake `curl` ahead of the real one on PATH. Reads FAKE_CURL_MODE
# ("success" | "fail") and, on success, writes the -d payload it received to
# FAKE_CURL_CAPTURE so tests can assert on the constructed body.
_install_stub_curl() {
  local bindir="$1"
  cat >"$bindir/curl" <<'STUB'
#!/usr/bin/env bash
payload=""
prev=""
for arg in "$@"; do
  if [ "$prev" = "-d" ]; then
    payload="$arg"
  fi
  prev="$arg"
done
if [ -n "${FAKE_CURL_CAPTURE:-}" ]; then
  printf '%s' "$payload" >"$FAKE_CURL_CAPTURE"
fi
if [ "${FAKE_CURL_MODE:-success}" = "fail" ]; then
  exit 7
fi
ts="${FAKE_CURL_TS:-1700000000.000100}"
printf '{"ok": true, "ts": "%s"}' "$ts"
STUB
  chmod +x "$bindir/curl"
}

_with_stub_path() {
  local bindir
  bindir=$(_mktemp_test_dir)
  _install_stub_curl "$bindir"
  echo "$bindir"
}

# ── fleet_slack_post ─────────────────────────────────────────────────────────

test_missing_config_degrades_to_log_only() {
  local state_dir out
  state_dir=$(_mktemp_test_dir)
  unset SLACK_BOT_TOKEN SLACK_CHANNEL
  out=$(fleet_slack_post "TST-1" "$state_dir" "hello" 2>&1)
  [[ "$out" == *"log-only"* ]] && [ ! -f "$state_dir/TST-1-slack-thread.json" ]
}

test_success_persists_thread_ts() {
  local state_dir bindir
  state_dir=$(_mktemp_test_dir)
  bindir=$(_with_stub_path)
  SLACK_BOT_TOKEN="xoxb-test" SLACK_CHANNEL="#alerts" FAKE_CURL_TS="1700000000.000100" \
    PATH="$bindir:$PATH" fleet_slack_post "TST-2" "$state_dir" "hello" >/dev/null 2>&1
  [ -f "$state_dir/TST-2-slack-thread.json" ] &&
    grep -q "1700000000.000100" "$state_dir/TST-2-slack-thread.json"
}

test_follow_up_reuses_stored_thread_ts() {
  local state_dir bindir capture
  state_dir=$(_mktemp_test_dir)
  bindir=$(_with_stub_path)
  capture="$state_dir/.capture"
  printf '{"ts": "1700000000.000100"}' >"$state_dir/TST-3-slack-thread.json"
  SLACK_BOT_TOKEN="xoxb-test" SLACK_CHANNEL="#alerts" FAKE_CURL_CAPTURE="$capture" \
    PATH="$bindir:$PATH" fleet_slack_post "TST-3" "$state_dir" "follow up" >/dev/null 2>&1
  grep -q "1700000000.000100" "$capture"
}

test_transport_failure_degrades_to_log_only_and_returns_zero() {
  local state_dir bindir out rc
  state_dir=$(_mktemp_test_dir)
  bindir=$(_with_stub_path)
  out=$(SLACK_BOT_TOKEN="xoxb-test" SLACK_CHANNEL="#alerts" FAKE_CURL_MODE="fail" \
    PATH="$bindir:$PATH" fleet_slack_post "TST-4" "$state_dir" "hello" 2>&1)
  rc=$?
  [ "$rc" -eq 0 ] && [[ "$out" == *"log-only"* ]] && [ ! -f "$state_dir/TST-4-slack-thread.json" ]
}

test_transport_failure_message_never_leaks_bare_token() {
  local state_dir bindir out
  state_dir=$(_mktemp_test_dir)
  bindir=$(_with_stub_path)
  out=$(SLACK_BOT_TOKEN="xoxb-supersecret9999" SLACK_CHANNEL="#alerts" FAKE_CURL_MODE="fail" \
    PATH="$bindir:$PATH" fleet_slack_post "TST-5" "$state_dir" "hello" 2>&1)
  [[ "$out" != *"xoxb-supersecret9999"* ]]
}

# ── fleet_notify_worker_event ────────────────────────────────────────────────

test_worker_event_includes_ticket_and_exit_fields() {
  local state_dir bindir capture
  state_dir=$(_mktemp_test_dir)
  bindir=$(_with_stub_path)
  capture="$state_dir/.capture"
  printf '2026-08-29T00:00:00Z|IMPLEMENT|code|start|working\n' >"$state_dir/TST-6-pipeline.log"
  printf '{"tid": "TST-6", "generation": 1, "pid": 123, "exit_code": 1, "exit_type": "exit", "killed_by_fleet": false, "terminal": false, "action": null, "last_assistant_message": null}' \
    >"$state_dir/TST-6-gen1-exit.json"
  SLACK_BOT_TOKEN="xoxb-test" SLACK_CHANNEL="#alerts" FAKE_CURL_CAPTURE="$capture" \
    PATH="$bindir:$PATH" fleet_notify_worker_event "TST-6" "$state_dir" "non-terminal-exit" >/dev/null 2>&1
  grep -q "TST-6" "$capture" && grep -q "IMPLEMENT" "$capture" && grep -q "exit" "$capture"
}

test_worker_event_includes_last_assistant_message_when_present() {
  local state_dir bindir capture
  state_dir=$(_mktemp_test_dir)
  bindir=$(_with_stub_path)
  capture="$state_dir/.capture"
  printf '{"tid": "TST-7", "generation": 1, "exit_code": 0, "exit_type": "SIGINT", "killed_by_fleet": false, "terminal": false, "last_assistant_message": "need clarification"}' \
    >"$state_dir/TST-7-gen1-exit.json"
  SLACK_BOT_TOKEN="xoxb-test" SLACK_CHANNEL="#alerts" FAKE_CURL_CAPTURE="$capture" \
    PATH="$bindir:$PATH" fleet_notify_worker_event "TST-7" "$state_dir" "non-terminal-exit" >/dev/null 2>&1
  grep -q "need clarification" "$capture"
}

test_worker_event_renders_elapsed_from_started_at_run_file() {
  # Regression for #199: the run file writes 'started_at' (supervisor.py),
  # so the reader must read that key, not the nonexistent 'timestamp'.
  local state_dir bindir capture
  state_dir=$(_mktemp_test_dir)
  bindir=$(_with_stub_path)
  capture="$state_dir/.capture"
  printf '{"tid": "TST-9", "pid": 123, "generation": 1, "started_at": "2000-01-01T00:00:00Z", "reason": "dispatch"}' \
    >"$state_dir/TST-9-run.json"
  SLACK_BOT_TOKEN="xoxb-test" SLACK_CHANNEL="#alerts" FAKE_CURL_CAPTURE="$capture" \
    PATH="$bindir:$PATH" fleet_notify_worker_event "TST-9" "$state_dir" "dead-letter" "orphaned-after-max-restarts" >/dev/null 2>&1
  ! grep -q "elapsed: unknown" "$capture" && grep -Eq 'elapsed: [0-9]+s' "$capture"
}

test_dead_letter_event_includes_reason() {
  local state_dir bindir capture
  state_dir=$(_mktemp_test_dir)
  bindir=$(_with_stub_path)
  capture="$state_dir/.capture"
  SLACK_BOT_TOKEN="xoxb-test" SLACK_CHANNEL="#alerts" FAKE_CURL_CAPTURE="$capture" \
    PATH="$bindir:$PATH" fleet_notify_worker_event "TST-8" "$state_dir" "dead-letter" "orphaned-after-max-restarts" >/dev/null 2>&1
  grep -q "orphaned-after-max-restarts" "$capture"
}

test_notify_call_site_is_scoped_to_dead_letter_branch() {
  # fleet-reconcile.sh must call fleet_notify_worker_event exactly once —
  # inside the dead-letter branch, never on the "done"/clean-completion
  # classification path.
  local reconcile="$LIB_DIR/fleet-reconcile.sh"
  local call_count
  call_count=$(grep -c 'fleet_notify_worker_event "\$tid"' "$reconcile")
  [ "$call_count" -eq 1 ] &&
    grep -B5 'fleet_notify_worker_event "\$tid"' "$reconcile" | grep -q "orphaned-after-max-restarts"
}

# ── fleet_notify_hold (human-hold-protocol) ─────────────────────────────────

_hold_payload() {
  printf '{"schema_version":1,"phase":"APPRAISE","reason":"SCOPE_UNDEFINED","blocks":"notes.md#AC-2","supersedes":"","questions":[{"id":1,"text":"which archive?"},{"id":2,"text":"csv or xlsx?"}],"parse_status":"ok","parse_error":""}'
}

_write_hold_log() {
  local state_dir="$1" tid="$2" held_at="${3:-2026-08-01T00:00:00Z}"
  printf '%s|META|human-hold|waiting|%s\n' "$held_at" "$(_hold_payload)" \
    >"$state_dir/${tid}-pipeline.log"
}

test_hold_created_sends_and_includes_questions() {
  local state_dir bindir capture
  state_dir=$(_mktemp_test_dir)
  bindir=$(_with_stub_path)
  capture="$state_dir/.capture"
  _write_hold_log "$state_dir" "TST-10"
  SLACK_BOT_TOKEN="xoxb-test" SLACK_CHANNEL="#alerts" FAKE_CURL_CAPTURE="$capture" \
    PATH="$bindir:$PATH" fleet_notify_hold "TST-10" "$state_dir" "created" >/dev/null 2>&1
  grep -q "TST-10" "$capture" && grep -q "which archive" "$capture" && grep -q "csv or xlsx" "$capture"
}

test_hold_created_writes_sent_sidecar() {
  local state_dir bindir
  state_dir=$(_mktemp_test_dir)
  bindir=$(_with_stub_path)
  _write_hold_log "$state_dir" "TST-11"
  SLACK_BOT_TOKEN="xoxb-test" SLACK_CHANNEL="#alerts" \
    PATH="$bindir:$PATH" fleet_notify_hold "TST-11" "$state_dir" "created" >/dev/null 2>&1
  grep -q '"notify_state": "sent"' "$state_dir/TST-11-hold-notify.json"
}

test_hold_created_twice_sends_once() {
  local state_dir bindir capture n
  state_dir=$(_mktemp_test_dir)
  bindir=$(_with_stub_path)
  capture="$state_dir/.capture"
  _write_hold_log "$state_dir" "TST-12"
  SLACK_BOT_TOKEN="xoxb-test" SLACK_CHANNEL="#alerts" FAKE_CURL_CAPTURE="$capture" \
    PATH="$bindir:$PATH" fleet_notify_hold "TST-12" "$state_dir" "created" >/dev/null 2>&1
  rm -f "$capture"
  SLACK_BOT_TOKEN="xoxb-test" SLACK_CHANNEL="#alerts" FAKE_CURL_CAPTURE="$capture" \
    PATH="$bindir:$PATH" fleet_notify_hold "TST-12" "$state_dir" "created" >/dev/null 2>&1
  [ ! -f "$capture" ]
}

test_hold_restart_does_not_resend() {
  # A fresh sourcing of this library (simulating a daemon restart) reads the
  # same sidecar off disk and must still send nothing for an already-sent hold.
  local state_dir bindir capture
  state_dir=$(_mktemp_test_dir)
  bindir=$(_with_stub_path)
  capture="$state_dir/.capture"
  _write_hold_log "$state_dir" "TST-13"
  SLACK_BOT_TOKEN="xoxb-test" SLACK_CHANNEL="#alerts" \
    PATH="$bindir:$PATH" fleet_notify_hold "TST-13" "$state_dir" "created" >/dev/null 2>&1
  (
    unset -f fleet_notify_hold fleet_slack_post fleet_notify_worker_event 2>/dev/null
    source "$LIB_DIR/fleet-notify.sh"
    SLACK_BOT_TOKEN="xoxb-test" SLACK_CHANNEL="#alerts" FAKE_CURL_CAPTURE="$capture" \
      PATH="$bindir:$PATH" fleet_notify_hold "TST-13" "$state_dir" "created" >/dev/null 2>&1
  )
  [ ! -f "$capture" ]
}

test_hold_transport_failure_marks_failed_and_completes() {
  local state_dir bindir
  state_dir=$(_mktemp_test_dir)
  bindir=$(_with_stub_path)
  _write_hold_log "$state_dir" "TST-14"
  local rc
  SLACK_BOT_TOKEN="xoxb-test" SLACK_CHANNEL="#alerts" FAKE_CURL_MODE="fail" \
    PATH="$bindir:$PATH" fleet_notify_hold "TST-14" "$state_dir" "created" >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 0 ] && grep -q '"notify_state": "failed"' "$state_dir/TST-14-hold-notify.json"
}

test_hold_failed_send_is_retried_on_a_later_pass() {
  local state_dir bindir capture
  state_dir=$(_mktemp_test_dir)
  bindir=$(_with_stub_path)
  capture="$state_dir/.capture"
  _write_hold_log "$state_dir" "TST-15"
  SLACK_BOT_TOKEN="xoxb-test" SLACK_CHANNEL="#alerts" FAKE_CURL_MODE="fail" \
    PATH="$bindir:$PATH" fleet_notify_hold "TST-15" "$state_dir" "created" >/dev/null 2>&1
  SLACK_BOT_TOKEN="xoxb-test" SLACK_CHANNEL="#alerts" FAKE_CURL_CAPTURE="$capture" \
    PATH="$bindir:$PATH" fleet_notify_hold "TST-15" "$state_dir" "created" >/dev/null 2>&1
  [ -f "$capture" ] && grep -q '"notify_state": "sent"' "$state_dir/TST-15-hold-notify.json"
}

test_hold_no_slack_config_degrades_to_log_line_and_succeeds() {
  local state_dir rc out
  state_dir=$(_mktemp_test_dir)
  unset SLACK_BOT_TOKEN SLACK_CHANNEL
  _write_hold_log "$state_dir" "TST-16"
  out=$(fleet_notify_hold "TST-16" "$state_dir" "created" 2>&1)
  rc=$?
  [ "$rc" -eq 0 ] && [[ "$out" == *"log-only"* ]]
}

test_hold_escalation_fires_once_at_threshold() {
  local state_dir bindir capture old_held_at
  state_dir=$(_mktemp_test_dir)
  bindir=$(_with_stub_path)
  capture="$state_dir/.capture"
  old_held_at=$(date -u -d '30 hours ago' +%Y-%m-%dT%H:%M:%SZ)
  _write_hold_log "$state_dir" "TST-17" "$old_held_at"
  SLACK_BOT_TOKEN="xoxb-test" SLACK_CHANNEL="#alerts" FAKE_CURL_CAPTURE="$capture" \
    PATH="$bindir:$PATH" fleet_notify_hold "TST-17" "$state_dir" "escalate" >/dev/null 2>&1
  [ -f "$capture" ] && grep -q '"escalated_at"' "$state_dir/TST-17-hold-notify.json" &&
    ! grep -q '"escalated_at": ""' "$state_dir/TST-17-hold-notify.json"
}

test_hold_escalation_does_not_repeat() {
  local state_dir bindir capture old_held_at
  state_dir=$(_mktemp_test_dir)
  bindir=$(_with_stub_path)
  capture="$state_dir/.capture"
  old_held_at=$(date -u -d '30 hours ago' +%Y-%m-%dT%H:%M:%SZ)
  _write_hold_log "$state_dir" "TST-18" "$old_held_at"
  SLACK_BOT_TOKEN="xoxb-test" SLACK_CHANNEL="#alerts" \
    PATH="$bindir:$PATH" fleet_notify_hold "TST-18" "$state_dir" "escalate" >/dev/null 2>&1
  SLACK_BOT_TOKEN="xoxb-test" SLACK_CHANNEL="#alerts" FAKE_CURL_CAPTURE="$capture" \
    PATH="$bindir:$PATH" fleet_notify_hold "TST-18" "$state_dir" "escalate" >/dev/null 2>&1
  [ ! -f "$capture" ]
}

test_hold_escalation_below_threshold_sends_nothing() {
  local state_dir bindir capture recent_held_at
  state_dir=$(_mktemp_test_dir)
  bindir=$(_with_stub_path)
  capture="$state_dir/.capture"
  recent_held_at=$(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%SZ)
  _write_hold_log "$state_dir" "TST-19" "$recent_held_at"
  SLACK_BOT_TOKEN="xoxb-test" SLACK_CHANNEL="#alerts" FAKE_CURL_CAPTURE="$capture" \
    PATH="$bindir:$PATH" fleet_notify_hold "TST-19" "$state_dir" "escalate" >/dev/null 2>&1
  [ ! -f "$capture" ]
}

test_hold_no_record_is_a_silent_no_op() {
  local state_dir rc
  state_dir=$(_mktemp_test_dir)
  rc=0
  fleet_notify_hold "TST-20" "$state_dir" "created" >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 0 ]
}

test_hold_invalid_record_is_a_silent_no_op() {
  local state_dir bindir capture
  state_dir=$(_mktemp_test_dir)
  bindir=$(_with_stub_path)
  capture="$state_dir/.capture"
  printf '2026-08-01T00:00:00Z|META|human-hold|waiting|{"schema_version":1,"phase":"APPRAISE","reason":"","blocks":"","supersedes":"","questions":[],"parse_status":"invalid","parse_error":"x"}\n' \
    >"$state_dir/TST-21-pipeline.log"
  SLACK_BOT_TOKEN="xoxb-test" SLACK_CHANNEL="#alerts" FAKE_CURL_CAPTURE="$capture" \
    PATH="$bindir:$PATH" fleet_notify_hold "TST-21" "$state_dir" "created" >/dev/null 2>&1
  [ ! -f "$capture" ]
}

# ── dispatch ─────────────────────────────────────────────────────────────

FILTER="${1:-}"
for fn in \
  test_missing_config_degrades_to_log_only \
  test_success_persists_thread_ts \
  test_follow_up_reuses_stored_thread_ts \
  test_transport_failure_degrades_to_log_only_and_returns_zero \
  test_transport_failure_message_never_leaks_bare_token \
  test_worker_event_includes_ticket_and_exit_fields \
  test_worker_event_includes_last_assistant_message_when_present \
  test_worker_event_renders_elapsed_from_started_at_run_file \
  test_dead_letter_event_includes_reason \
  test_notify_call_site_is_scoped_to_dead_letter_branch \
  test_hold_created_sends_and_includes_questions \
  test_hold_created_writes_sent_sidecar \
  test_hold_created_twice_sends_once \
  test_hold_restart_does_not_resend \
  test_hold_transport_failure_marks_failed_and_completes \
  test_hold_failed_send_is_retried_on_a_later_pass \
  test_hold_no_slack_config_degrades_to_log_line_and_succeeds \
  test_hold_escalation_fires_once_at_threshold \
  test_hold_escalation_does_not_repeat \
  test_hold_escalation_below_threshold_sends_nothing \
  test_hold_no_record_is_a_silent_no_op \
  test_hold_invalid_record_is_a_silent_no_op; do
  [ -z "$FILTER" ] || [[ "$fn" == *"$FILTER"* ]] || continue
  _run "$fn" "$fn"
done

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
