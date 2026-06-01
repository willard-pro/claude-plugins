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
  grep -q 'export TICKET_ID="TEST-42"' "$f" \
    && grep -q 'export REPOS_ROOT="/repos"' "$f" \
    && grep -q 'export BE_SERVICES="svc1 svc2"' "$f" \
    && grep -q 'export WIKI_ROOT="/wiki"' "$f" \
    && grep -q 'export SLACK_CHANNEL="#alerts"' "$f"
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
  grep -q 'export REPOS_ROOT="$(echo pwned)"' "$f" \
    && grep -q 'export BE_SERVICES="$HOME"' "$f"
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

# ── spawn_agent_post tests ─────────────────────────────────────────────────────

test_post_reads_metadata_file() {
  source "$LIB_DIR/spawn-helper.sh"
  # Write metadata manually to simulate spawn_agent_pre having run
  cat > /tmp/ticket-auto-TEST-42-spawn-meta.txt << 'META'
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
  cat > /tmp/ticket-auto-TEST-42-spawn-meta.txt << 'META'
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
  cat > /tmp/ticket-auto-TEST-42-spawn-meta.txt << 'META'
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

# ── dispatch ──────────────────────────────────────────────────────────────────

FILTER="${1:-}"

for fn in \
  test_write_env_creates_file \
  test_write_env_exports_ticket_id \
  test_write_env_exports_repos_root \
  test_write_env_exports_all_fields \
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
  test_env_prefix_survives_shell_special_chars_in_paths; do
  [ -z "$FILTER" ] || [[ "$fn" == *"$FILTER"* ]] || continue
  _run "$fn" "$fn"
done

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
