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
  test_dead_letter_event_includes_reason \
  test_notify_call_site_is_scoped_to_dead_letter_branch; do
  [ -z "$FILTER" ] || [[ "$fn" == *"$FILTER"* ]] || continue
  _run "$fn" "$fn"
done

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
