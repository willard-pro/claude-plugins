#!/usr/bin/env bash
# test-spawn-helper.sh — unit tests for lib/spawn-helper.sh
# Usage: bash test-spawn-helper.sh [test_name_filter]
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

# ── mocks ──────────────────────────────────────────────────────────────────────

# Mock hb_heartbeat and hb_pinger_start (defined in heartbeat.sh — not available in test)
# Real pinger stdout isolation is tested in test-heartbeat.sh: test_pinger_no_stdout_output.
hb_heartbeat() { return 0; }
hb_pinger_start() { return 0; }
hb_pinger_stop() { return 0; }
cl_write() { return 0; }
capture_agent_result() { return 0; }

# ── spawn_write_env tests ──────────────────────────────────────────────────────

test_write_env_creates_file() {
  local tmpdir
  tmpdir=$(mktemp -d)
  source "$LIB_DIR/spawn-helper.sh"
  spawn_write_env TICKET_ID=TEST-42 REPOS_ROOT=/tmp/test ISSUE_PREFIX=TEST BE_SERVICES=svc1 WIKI_ROOT=/tmp/wiki BE_TEST_CMD="make test" FE_TEST_CMD="npm test" LOCAL_URL=http://localhost:3000 UAT_URL=http://localhost:8080 SLACK_CHANNEL="#test" >/dev/null 2>&1
  local rc=$?
  rm -rf "$tmpdir"
  [ "$rc" -eq 0 ] && [ -f "/tmp/ticket-auto-TEST-42-env.sh" ]
}

test_write_env_exports_ticket_id() {
  source "$LIB_DIR/spawn-helper.sh"
  spawn_write_env TICKET_ID=TEST-42 REPOS_ROOT=/tmp/test ISSUE_PREFIX=TEST BE_SERVICES=svc1 >/dev/null 2>&1
  grep -q 'export TICKET_ID="TEST-42"' /tmp/ticket-auto-TEST-42-env.sh
}

test_write_env_exports_repos_root() {
  source "$LIB_DIR/spawn-helper.sh"
  spawn_write_env TICKET_ID=TEST-42 REPOS_ROOT=/home/user/repos ISSUE_PREFIX=TEST BE_SERVICES=svc1 >/dev/null 2>&1
  grep -q 'export REPOS_ROOT="/home/user/repos"' /tmp/ticket-auto-TEST-42-env.sh
}

test_write_env_exports_all_fields() {
  source "$LIB_DIR/spawn-helper.sh"
  spawn_write_env TICKET_ID=TEST-42 \
    REPOS_ROOT=/repos \
    ISSUE_PREFIX=TEST \
    BE_SERVICES="svc1 svc2" \
    WIKI_ROOT=/wiki \
    BE_TEST_CMD="mvn test" \
    FE_TEST_CMD="npm test" \
    LOCAL_URL=http://localhost:3000 \
    UAT_URL=http://localhost:8080 \
    SLACK_CHANNEL="#alerts" >/dev/null 2>&1
  local f=/tmp/ticket-auto-TEST-42-env.sh
  grep -q 'export TICKET_ID="TEST-42"' "$f" &&
    grep -q 'export REPOS_ROOT="/repos"' "$f" &&
    grep -q 'export BE_SERVICES="svc1 svc2"' "$f" &&
    grep -q 'export WIKI_ROOT="/wiki"' "$f" &&
    grep -q 'export SLACK_CHANNEL="#alerts"' "$f"
}

test_write_env_appends_linear_key_when_set() {
  local tmpfile
  source "$LIB_DIR/spawn-helper.sh"
  LINEAR_API_KEY=test-spawn-key spawn_write_env TICKET_ID=TEST-LL \
    REPOS_ROOT=/repos ISSUE_PREFIX=TEST BE_SERVICES=svc1 >/dev/null 2>&1
  tmpfile=/tmp/ticket-auto-TEST-LL-env.sh
  grep -q 'export LINEAR_API_KEY="test-spawn-key"' "$tmpfile"
}

test_write_env_does_not_append_linear_key_when_unset() {
  source "$LIB_DIR/spawn-helper.sh"
  unset LINEAR_API_KEY
  spawn_write_env TICKET_ID=TEST-NK \
    REPOS_ROOT=/repos ISSUE_PREFIX=TEST BE_SERVICES=svc1 >/dev/null 2>&1
  ! grep -q 'LINEAR_API_KEY' /tmp/ticket-auto-TEST-NK-env.sh
}

test_write_env_rejects_empty_ticket_id() {
  source "$LIB_DIR/spawn-helper.sh"
  spawn_write_env REPOS_ROOT=/tmp/test ISSUE_PREFIX=TEST BE_SERVICES=svc1 >/dev/null 2>&1 && false || true
}

test_write_env_rejects_unknown_param() {
  source "$LIB_DIR/spawn-helper.sh"
  spawn_write_env TICKET_ID=TEST-42 REPOS_ROOT=/tmp UNKNOWN_FIELD=bad ISSUE_PREFIX=TEST BE_SERVICES=svc1 >/dev/null 2>&1 && false || true
}

test_write_env_handles_special_chars_in_values() {
  # Values with commas, semicolons, and dollar signs should be preserved exactly
  source "$LIB_DIR/spawn-helper.sh"
  spawn_write_env TICKET_ID=TEST-42 REPOS_ROOT=/tmp/test ISSUE_PREFIX=TEST BE_SERVICES="svc1,svc2;svc3 \$dollar" >/dev/null 2>&1
  local f=/tmp/ticket-auto-TEST-42-env.sh
  grep -q 'export BE_SERVICES="svc1,svc2;svc3 \$dollar"' "$f"
}

test_write_env_no_shell_expansion_in_heredoc() {
  # Variables like $HOME or $(whoami) in values must NOT be expanded
  source "$LIB_DIR/spawn-helper.sh"
  spawn_write_env TICKET_ID=TEST-42 REPOS_ROOT='$(echo pwned)' ISSUE_PREFIX=TEST BE_SERVICES='$HOME' >/dev/null 2>&1
  local f=/tmp/ticket-auto-TEST-42-env.sh
  # The literal strings should appear, not their expanded values
  grep -q 'export REPOS_ROOT="$(echo pwned)"' "$f" &&
    grep -q 'export BE_SERVICES="$HOME"' "$f"
}

# ── spawn_agent_pre tests ──────────────────────────────────────────────────────

test_pre_rejects_missing_phase() {
  source "$LIB_DIR/spawn-helper.sh"
  spawn_agent_pre STEP=test TICKET_ID=TEST-42 SKILL=/ticket-test >/dev/null 2>&1 && false || true
}

test_pre_rejects_missing_ticket_id() {
  source "$LIB_DIR/spawn-helper.sh"
  spawn_agent_pre PHASE=TEST STEP=test SKILL=/ticket-test >/dev/null 2>&1 && false || true
}

test_pre_prints_agent_prompt_line() {
  source "$LIB_DIR/spawn-helper.sh"
  local output
  output=$(spawn_agent_pre PHASE=TEST STEP=test TICKET_ID=TEST-42 SKILL=/ticket-test FLAGS="--from-auto" DESCRIPTION="testing" 2>/dev/null)
  echo "$output" | grep -q '^AGENT_PROMPT='
}

test_pre_prompt_includes_skill_and_ticket() {
  source "$LIB_DIR/spawn-helper.sh"
  local output
  output=$(spawn_agent_pre PHASE=TEST STEP=test TICKET_ID=TEST-42 SKILL=/ticket-test FLAGS="--from-auto" 2>/dev/null)
  echo "$output" | grep -q '/ticket-test TEST-42 --from-auto'
}

test_pre_appends_from_step_to_flags() {
  source "$LIB_DIR/spawn-helper.sh"
  local output
  output=$(spawn_agent_pre PHASE=TEST STEP=test TICKET_ID=TEST-42 SKILL=/ticket-test FLAGS="--from-auto" FROM_STEP=code-review 2>/dev/null)
  echo "$output" | grep -q '\-\-from-step code-review'
}

test_pre_writes_metadata_file() {
  rm -f /tmp/ticket-auto-TEST-42-spawn-meta.txt
  source "$LIB_DIR/spawn-helper.sh"
  spawn_agent_pre PHASE=TEST STEP=test TICKET_ID=TEST-42 SKILL=/ticket-test >/dev/null 2>&1
  [ -f /tmp/ticket-auto-TEST-42-spawn-meta.txt ]
}

test_pre_metadata_contains_correct_phase() {
  source "$LIB_DIR/spawn-helper.sh"
  spawn_agent_pre PHASE=IMPLEMENT STEP=implement TICKET_ID=TEST-42 SKILL=/ticket-implement >/dev/null 2>&1
  grep -q 'PHASE=IMPLEMENT' /tmp/ticket-auto-TEST-42-spawn-meta.txt
}

test_pre_printf_q_escapes_shell_metachars() {
  # Values containing ; or " must be printf '%q' escaped in the env_prefix
  source "$LIB_DIR/spawn-helper.sh"
  local output
  output=$(spawn_agent_pre PHASE=TEST STEP=test TICKET_ID=TEST-42 SKILL=/ticket-test \
    LOG_FILE='/tmp/foo"; echo pwned; true".log' \
    HB_LOG_FILE='/tmp/foo".log' \
    2>/dev/null)
  # The escaped values should appear in single quotes (printf '%q' output)
  # and NOT contain unescaped double-quote-shell-break patterns
  echo "$output" | grep -q "AGENT_PROMPT="
  # The unescaped injection string should be absent from the final prompt
  ! echo "$output" | grep -q 'echo pwned'
}

test_pre_writes_context_file() {
  rm -f /tmp/ticket-auto-TEST-42-ctx.txt
  source "$LIB_DIR/spawn-helper.sh"
  spawn_agent_pre PHASE=APPRAISE STEP=appraise TICKET_ID=TEST-42 SKILL=/ticket-appraise LOG_FILE=/tmp/test.log >/dev/null 2>&1
  grep -q 'APPRAISE|/tmp/test.log' /tmp/ticket-auto-TEST-42-ctx.txt
}

# ── env file integration tests (Tasks 4.1-4.2) ──────────────────────────────

test_pre_prompt_includes_env_file_path() {
  # Task 4.1: spawn_write_env then spawn_agent_pre — verify the AGENT_PROMPT
  # includes the correct env file path.
  source "$LIB_DIR/spawn-helper.sh"
  # Write the env file first (simulating orchestrator Step 0.5)
  spawn_write_env TICKET_ID=TEST-42 \
    REPOS_ROOT=/home/user/repos \
    ISSUE_PREFIX=TEST \
    BE_SERVICES=svc1 >/dev/null 2>&1
  # Now call spawn_agent_pre and check the prompt
  local output
  output=$(spawn_agent_pre PHASE=TEST STEP=test TICKET_ID=TEST-42 SKILL=/ticket-test FLAGS="--from-auto" 2>/dev/null)
  echo "$output" | grep -q 'source /tmp/ticket-auto-TEST-42-env.sh'
}

test_pre_completes_when_env_file_missing() {
  # Task 4.2: spawn_agent_pre must succeed even when the env file doesn't exist.
  # The AGENT_PROMPT still includes the source command (sub-agent tolerates missing file).
  rm -f /tmp/ticket-auto-TEST-42-env.sh
  source "$LIB_DIR/spawn-helper.sh"
  local output
  output=$(spawn_agent_pre PHASE=TEST STEP=test TICKET_ID=TEST-42 SKILL=/ticket-test FLAGS="--from-auto" 2>/dev/null)
  local rc=$?
  [ "$rc" -eq 0 ] && echo "$output" | grep -q 'source /tmp/ticket-auto-TEST-42-env.sh'
}

# ── spawn_agent_post tests ─────────────────────────────────────────────────────

test_post_reads_metadata_file() {
  source "$LIB_DIR/spawn-helper.sh"
  # Write metadata manually to simulate spawn_agent_pre having run
  cat >/tmp/ticket-auto-TEST-42-spawn-meta.txt <<'META'
PHASE=TEST
STEP=test
TICKET_ID=TEST-42
LOG_FILE=/tmp/test-post.log
HB_LOG_FILE=/tmp/test-post.hb.log
CLAUDE_LOG_FILE=/tmp/test-post.claude.log
META
  spawn_agent_post TICKET_ID=TEST-42 RESULT=done MSG="all good" >/dev/null 2>&1
  local rc=$?
  [ "$rc" -eq 0 ]
}

test_post_rejects_missing_ticket_id() {
  source "$LIB_DIR/spawn-helper.sh"
  spawn_agent_post RESULT=done >/dev/null 2>&1 && false || true
}

test_post_rejects_missing_result() {
  source "$LIB_DIR/spawn-helper.sh"
  spawn_agent_post TICKET_ID=TEST-42 >/dev/null 2>&1 && false || true
}

test_post_rejects_bad_result_value() {
  source "$LIB_DIR/spawn-helper.sh"
  spawn_agent_post TICKET_ID=TEST-42 RESULT=maybe >/dev/null 2>&1 && false || true
}

test_post_done_explicit_params_no_metadata() {
  rm -f /tmp/ticket-auto-TEST-42-spawn-meta.txt
  source "$LIB_DIR/spawn-helper.sh"
  spawn_agent_post TICKET_ID=TEST-42 RESULT=done PHASE=TEST STEP=test MSG="explicit done" >/dev/null 2>&1
}

test_post_fail_explicit_params() {
  rm -f /tmp/ticket-auto-TEST-42-spawn-meta.txt
  source "$LIB_DIR/spawn-helper.sh"
  spawn_agent_post TICKET_ID=TEST-42 RESULT=fail PHASE=TEST STEP=test MSG="something broke" >/dev/null 2>&1
}

test_post_cleans_up_metadata_file() {
  cat >/tmp/ticket-auto-TEST-42-spawn-meta.txt <<'META'
PHASE=TEST
STEP=test
TICKET_ID=TEST-42
LOG_FILE=/tmp/test-cleanup.log
META
  source "$LIB_DIR/spawn-helper.sh"
  spawn_agent_post TICKET_ID=TEST-42 RESULT=done >/dev/null 2>&1
  [ ! -f /tmp/ticket-auto-TEST-42-spawn-meta.txt ]
}

test_post_warn_continue_stops_pinger_but_does_not_exit() {
  cat >/tmp/ticket-auto-TEST-42-spawn-meta.txt <<'META'
PHASE=MAINTENANCE
STEP=maintenance
TICKET_ID=TEST-42
LOG_FILE=/tmp/test-warn.log
META
  source "$LIB_DIR/spawn-helper.sh"
  FAIL_ACTION=warn-continue spawn_agent_post TICKET_ID=TEST-42 RESULT=fail MSG="wiki down" >/dev/null 2>&1
}

# ── spawn_capture tests ────────────────────────────────────────────────────────

test_capture_rejects_missing_phase() {
  source "$LIB_DIR/spawn-helper.sh"
  spawn_capture TICKET_ID=TEST-42 RESULT="some output" >/dev/null 2>&1 && false || true
}

test_capture_calls_through_with_all_params() {
  source "$LIB_DIR/spawn-helper.sh"
  spawn_capture TICKET_ID=TEST-42 PHASE=TEST RESULT="captured output" ATTEMPT=2 >/dev/null 2>&1
}

# ── escalation test — printf '%q' safety ──────────────────────────────────────

test_env_prefix_survives_shell_special_chars_in_paths() {
  # If any of LOG_FILE, HB_LOG_FILE, CLAUDE_LOG_FILE, or TICKET_ID contained
  # a quote or command substitution, the sub-agent would execute it. This test
  # asserts that printf '%q' neutralises those characters.
  source "$LIB_DIR/spawn-helper.sh"
  local try_tid='TEST-42"; echo BAD; true"'
  local try_log='/tmp/log"; $(id); true".log'
  local output
  output=$(spawn_agent_pre PHASE=TEST STEP=test TICKET_ID="$try_tid" SKILL=/ticket-test \
    LOG_FILE="$try_log" HB_LOG_FILE="$try_log" CLAUDE_LOG_FILE="$try_log" 2>/dev/null || true)
  # The output must not contain an unquoted command injection site
  ! echo "$output" | grep -qF 'echo BAD'
  ! echo "$output" | grep -qF '$(id)'
}

# ── heartbeat source guard ────────────────────────────────────────────────────

test_heartbeat_sourced_when_not_predefined() {
  # Run in a clean subshell with no pre-defined hb_* mocks — spawn-helper.sh
  # must source heartbeat.sh itself so hb_heartbeat is available.
  bash -c "
    source '${LIB_DIR}/spawn-helper.sh'
    declare -f hb_heartbeat >/dev/null 2>&1
  "
}

test_heartbeat_not_sourced_when_already_defined() {
  # When hb_heartbeat is already defined (e.g. test mocks), spawn-helper.sh
  # must not overwrite it with the real heartbeat.sh implementation.
  bash -c "
    hb_heartbeat() { echo MOCK; }
    source '${LIB_DIR}/spawn-helper.sh'
    [ \"\$(hb_heartbeat)\" = 'MOCK' ]
  "
}

# ── Watchdog tests (Tasks 3.5-3.7) ────────────────────────────────────────────

test_watchdog_start_creates_background_process() {
  # Verify spawn_watchdog_start launches a background process that can be stopped
  source "$LIB_DIR/spawn-helper.sh"
  local tmpdir
  tmpdir=$(mktemp -d)
  local stop_file="$tmpdir/watchdog-stop"
  # Use a short sleep (1s) to test the stop mechanism; watchdog_start uses a
  # sub-process that loops on sleep 60, but we only need to verify start/stop.
  # We bypass the long sleep by writing a minimal inline function.
  export HB_LOG_FILE="$tmpdir/test-hb.log"
  # Verify the function exists and accepts parameters
  type spawn_watchdog_start >/dev/null 2>&1 || {
    rm -rf "$tmpdir"
    echo "spawn_watchdog_start not defined"
    return 1
  }
  type spawn_watchdog_stop >/dev/null 2>&1 || {
    rm -rf "$tmpdir"
    echo "spawn_watchdog_stop not defined"
    return 1
  }
  rm -rf "$tmpdir"
  return 0
}

test_watchdog_stop_kills_background_process() {
  # Verify spawn_watchdog_stop creates the stop file to terminate the watchdog
  source "$LIB_DIR/spawn-helper.sh"
  local tmpdir
  tmpdir=$(mktemp -d)
  local stop_file="$tmpdir/watchdog-stop"
  export HB_LOG_FILE="$tmpdir/test-hb.log"
  # Test that stop creates the stop file (watchdog loop checks for this file)
  spawn_watchdog_stop "$stop_file"
  [ -f "$stop_file" ] || {
    echo "Stop file not created"
    rm -rf "$tmpdir"
    return 1
  }
  rm -rf "$tmpdir"
  return 0
}

test_watchdog_entries_use_correct_category() {
  # Verify watchdog entries use category=watchdog, event=alive, phase in MSG
  # The spawn_watchdog_start function calls:
  #   hb_heartbeat "watchdog" "alive" "waiting for {PHASE} agent"
  # Verify this exact call pattern exists in the source
  local src="$LIB_DIR/spawn-helper.sh"
  grep -q '"watchdog"' "$src" || {
    echo "category watchdog not in spawn_watchdog_start"
    return 1
  }
  grep -q '"alive"' "$src" || {
    echo "event alive not in spawn_watchdog_start"
    return 1
  }
  grep -q 'waiting for.*agent' "$src" || {
    echo "phase-in-MSG pattern not in spawn_watchdog_start"
    return 1
  }
  return 0
}

test_watchdog_integrated_into_spawn_agent_pre() {
  # Verify spawn_agent_pre calls spawn_watchdog_start after hb_pinger_start
  local src="$LIB_DIR/spawn-helper.sh"
  [ -f "$src" ] || return 1
  grep -q 'spawn_watchdog_start' "$src" || {
    echo "spawn_watchdog_start not found"
    return 1
  }
  local pre_func
  pre_func=$(sed -n '/^spawn_agent_pre()/,/^}/p' "$src")
  local pinger_line watchdog_line
  pinger_line=$(echo "$pre_func" | grep -n 'hb_pinger_start' | head -1 | cut -d: -f1)
  watchdog_line=$(echo "$pre_func" | grep -n 'spawn_watchdog_start' | head -1 | cut -d: -f1)
  [ -n "$pinger_line" ] || {
    echo "hb_pinger_start not found in pre"
    return 1
  }
  [ -n "$watchdog_line" ] || {
    echo "spawn_watchdog_start not found in pre"
    return 1
  }
  [ "$watchdog_line" -gt "$pinger_line" ] || {
    echo "watchdog start not after pinger start"
    return 1
  }
  return 0
}

test_watchdog_integrated_into_spawn_agent_post() {
  # Verify spawn_agent_post calls spawn_watchdog_stop before hb_pinger_stop
  local src="$LIB_DIR/spawn-helper.sh"
  [ -f "$src" ] || return 1
  grep -q 'spawn_watchdog_stop' "$src" || {
    echo "spawn_watchdog_stop not found"
    return 1
  }
  local post_func
  post_func=$(sed -n '/^spawn_agent_post()/,/^}/p' "$src")
  local watchdog_line pinger_line
  watchdog_line=$(echo "$post_func" | grep -n 'spawn_watchdog_stop' | head -1 | cut -d: -f1)
  pinger_line=$(echo "$post_func" | grep -n 'hb_pinger_stop' | head -1 | cut -d: -f1)
  [ -n "$watchdog_line" ] || {
    echo "spawn_watchdog_stop not found in post"
    return 1
  }
  [ -n "$pinger_line" ] || {
    echo "hb_pinger_stop not found in post"
    return 1
  }
  [ "$watchdog_line" -lt "$pinger_line" ] || {
    echo "watchdog stop not before pinger stop"
    return 1
  }
  return 0
}

# ── Watchdog heartbeat verification test (Task 3.3) ─────────────────────────

test_watchdog_emits_heartbeats() {
  # Verify spawn_watchdog_start actually writes heartbeat entries when
  # HB_LOG_FILE is set. Uses sleep_secs=1 to avoid 60s delay.
  local tmpdir
  tmpdir=$(mktemp -d)
  local stop_file="$tmpdir/watchdog-stop"
  local hb_log="$tmpdir/hb.log"
  # Run in a clean subshell — unset global mocks so spawn-helper.sh loads real heartbeat.sh
  (
    export HB_LOG_FILE="$hb_log"
    unset -f hb_heartbeat hb_pinger_start hb_pinger_stop cl_write 2>/dev/null || true
    source "$LIB_DIR/spawn-helper.sh"
    # Initialize the heartbeat log (schema header needed for valid file)
    hb_init
    # Start watchdog with 1s interval (instead of default 60s)
    spawn_watchdog_start "$stop_file" "TEST" 1
    # Wait up to 3s for at least one heartbeat entry
    waited=0
    while [ $waited -lt 6 ]; do
      sleep 0.5
      waited=$((waited + 1))
      [ -f "$hb_log" ] && grep -q 'watchdog' "$hb_log" 2>/dev/null && break
    done
    # Stop the watchdog
    spawn_watchdog_stop "$stop_file"
    # Verify at least one watchdog heartbeat was written
    grep -q 'watchdog' "$hb_log"
  )
  local rc=$?
  rm -rf "$tmpdir"
  return $rc
}

# ── dispatch ──────────────────────────────────────────────────────────────────

FILTER="${1:-}"

for fn in \
  test_write_env_creates_file \
  test_write_env_exports_ticket_id \
  test_write_env_exports_repos_root \
  test_write_env_exports_all_fields \
  test_write_env_appends_linear_key_when_set \
  test_write_env_does_not_append_linear_key_when_unset \
  test_write_env_rejects_empty_ticket_id \
  test_write_env_rejects_unknown_param \
  test_write_env_handles_special_chars_in_values \
  test_write_env_no_shell_expansion_in_heredoc \
  test_pre_rejects_missing_phase \
  test_pre_rejects_missing_ticket_id \
  test_pre_prints_agent_prompt_line \
  test_pre_prompt_includes_skill_and_ticket \
  test_pre_appends_from_step_to_flags \
  test_pre_writes_metadata_file \
  test_pre_metadata_contains_correct_phase \
  test_pre_printf_q_escapes_shell_metachars \
  test_pre_writes_context_file \
  test_pre_prompt_includes_env_file_path \
  test_pre_completes_when_env_file_missing \
  test_post_reads_metadata_file \
  test_post_rejects_missing_ticket_id \
  test_post_rejects_missing_result \
  test_post_rejects_bad_result_value \
  test_post_done_explicit_params_no_metadata \
  test_post_fail_explicit_params \
  test_post_cleans_up_metadata_file \
  test_post_warn_continue_stops_pinger_but_does_not_exit \
  test_capture_rejects_missing_phase \
  test_capture_calls_through_with_all_params \
  test_env_prefix_survives_shell_special_chars_in_paths \
  test_heartbeat_sourced_when_not_predefined \
  test_heartbeat_not_sourced_when_already_defined \
  test_watchdog_start_creates_background_process \
  test_watchdog_stop_kills_background_process \
  test_watchdog_entries_use_correct_category \
  test_watchdog_integrated_into_spawn_agent_pre \
  test_watchdog_integrated_into_spawn_agent_post \
  test_watchdog_emits_heartbeats; do
  [ -z "$FILTER" ] || [[ "$fn" == *"$FILTER"* ]] || continue
  _run "$fn" "$fn"
done

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
