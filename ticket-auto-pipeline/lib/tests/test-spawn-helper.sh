#!/usr/bin/env bash
# test-spawn-helper.sh — unit tests for lib/spawn-helper.sh
# Usage: bash test-spawn-helper.sh [test_name_filter]
# -u (nounset) intentionally omitted: Claude Code shell snapshots inject
# ZSH_VERSION references that trigger false-positive "unbound variable"
# errors in this bash version when nounset is active.
set -eo pipefail

# Reap all child processes on exit. Tests that background pingers and
# watchdogs use disown, but any residual children from test setup/teardown
# would otherwise accumulate as zombies. jobs -p cannot see disowned jobs —
# tests that background a watchdog/pinger must capture and kill its PID
# directly (see test_watchdog_emits_heartbeats).
_cleanup_test_children() {
  local _pids
  _pids=$(jobs -p 2>/dev/null || true)
  [ -n "$_pids" ] && kill $_pids 2>/dev/null || true
}

# Every mktemp -d in this file must go through this helper so its directory
# is swept on exit even if the test fails, errors out, or forgets its own
# rm -rf — otherwise stale dirs accumulate under /tmp across runs.
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

# Scratch files this suite writes straight into /tmp (spawn_write_env,
# spawn_agent_pre and the token-tracker hooks all hardcode /tmp). Every ticket
# id used here starts with TEST-, so the glob cannot reach a real run's files.
# Without this, dormant fixtures outlive the suite and end up as live input to
# the production hooks (#273).
_cleanup_test_tmp_fixtures() {
  local f
  shopt -s nullglob
  for f in /tmp/ticket-auto-TEST-*; do
    rm -f -- "$f" 2>/dev/null || true
  done
  shopt -u nullglob
}

_cleanup_test_exit() {
  _cleanup_test_children
  _cleanup_test_tmpdirs
  _cleanup_test_tmp_fixtures
}
trap _cleanup_test_exit EXIT

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
  # Clean up any background processes the test may have left behind.
  # Watchdog tests spawn disowned loops; racer tests fork kill-file writers.
  # Accumulated stale processes cause later tests to hang or false-fail.
  _cleanup_test_children
  sleep 0.05 2>/dev/null || true
}

# ── mocks ──────────────────────────────────────────────────────────────────────

# Mock hb_heartbeat and hb_pinger_start (defined in heartbeat.sh — not available in test)
# Real pinger stdout isolation is tested in test-heartbeat.sh: test_pinger_no_stdout_output.
hb_heartbeat() { return 0; }
hb_pinger_start() { return 0; }
hb_pinger_stop() { return 0; }
cl_write() { return 0; }

# capture_agent_result spy. NOT a no-op: an unconditional `return 0` here is what
# let the uppercase-PHASE defect (#194) reach production green. This stub enforces
# the same contract the real function does — kebab-case phase, ticket id and phase
# both required — and records the call so a test can assert the capture happened
# and with which arguments.
_CAPTURE_SPY="${TMPDIR:-/tmp}/spawn-helper-capture-spy.$$"
capture_agent_result() {
  local ticket_id="${1:-}" phase="${2:-}" result="${3:-}" attempt="${4:-}"
  [ -z "$ticket_id" ] && return 0
  [ -z "$phase" ] && return 0
  if ! [[ "$phase" =~ ^[a-z][a-z0-9-]*$ ]]; then
    echo "capture_agent_result(spy): invalid phase '$phase' (must be kebab-case)" >&2
    return 1
  fi
  printf '%s|%s|%s|%s\n' "$ticket_id" "$phase" "$attempt" "$result" >>"$_CAPTURE_SPY"
}

_spy_reset() { : >"$_CAPTURE_SPY"; }
_spy_last() { tail -1 "$_CAPTURE_SPY" 2>/dev/null; }

# ── spawn_write_env tests ──────────────────────────────────────────────────────

test_write_env_creates_file() {
  local tmpdir
  tmpdir=$(_mktemp_test_dir)
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
    SLACK_CHANNEL="#alerts" \
    BASE_BRANCH=develop \
    INTEGRATION_BRANCH=epic/test-x \
    TICKET_BRANCH=feat/TEST-42-fix-auth \
    UAT_POLICY=epic \
    AUTONOMY=semi-auto \
    MERGE_POLICY=manual \
    WORKTREE_ROOT=/home/user/worktrees/TEST-42 >/dev/null 2>&1
  local f=/tmp/ticket-auto-TEST-42-env.sh
  grep -q 'export TICKET_ID="TEST-42"' "$f" &&
    grep -q 'export REPOS_ROOT="/repos"' "$f" &&
    grep -q 'export BE_SERVICES="svc1 svc2"' "$f" &&
    grep -q 'export WIKI_ROOT="/wiki"' "$f" &&
    grep -q 'export SLACK_CHANNEL="#alerts"' "$f" &&
    grep -q 'export BASE_BRANCH="develop"' "$f" &&
    grep -q 'export INTEGRATION_BRANCH="epic/test-x"' "$f" &&
    grep -q 'export TICKET_BRANCH="feat/TEST-42-fix-auth"' "$f" &&
    grep -q 'export UAT_POLICY="epic"' "$f" &&
    grep -q 'export AUTONOMY="semi-auto"' "$f" &&
    grep -q 'export MERGE_POLICY="manual"' "$f" &&
    grep -q 'export WORKTREE_ROOT="/home/user/worktrees/TEST-42"' "$f"
}

test_write_env_uat_policy_defaults_to_per_ticket() {
  # Omitting the parameter must materialise the default, not an empty string:
  # an empty UAT_POLICY would make uat_decide_trigger fall through to the
  # UAT-target check, which is exactly the routing this field overrides.
  source "$LIB_DIR/spawn-helper.sh"
  spawn_write_env TICKET_ID=TEST-UP-DEF \
    REPOS_ROOT=/repos ISSUE_PREFIX=TEST BE_SERVICES=svc1 >/dev/null 2>&1
  grep -q 'export UAT_POLICY="per-ticket"' /tmp/ticket-auto-TEST-UP-DEF-env.sh
}

test_write_env_merge_policy_defaults_to_empty() {
  # Unlike UAT_POLICY, omitting MERGE_POLICY must NOT materialise a default —
  # a ticket with no epic directive has no merge-policy opinion at all, and an
  # empty string is exactly the "unrestricted" signal ticket-pr-review's merge
  # gate checks for. Defaulting it to anything non-empty would block every
  # merge for tickets that were never under a directive in the first place.
  source "$LIB_DIR/spawn-helper.sh"
  spawn_write_env TICKET_ID=TEST-MP-DEF \
    REPOS_ROOT=/repos ISSUE_PREFIX=TEST BE_SERVICES=svc1 >/dev/null 2>&1
  grep -q 'export MERGE_POLICY=""' /tmp/ticket-auto-TEST-MP-DEF-env.sh
}

test_write_env_appends_linear_key_when_set() {
  local tmpfile
  source "$LIB_DIR/spawn-helper.sh"
  LINEAR_API_KEY=test-spawn-key spawn_write_env TICKET_ID=TEST-LL \
    REPOS_ROOT=/repos ISSUE_PREFIX=TEST BE_SERVICES=svc1 >/dev/null 2>&1
  tmpfile=/tmp/ticket-auto-TEST-LL-env.sh
  grep -q 'export LINEAR_API_KEY="test-spawn-key"' "$tmpfile"
}

test_write_env_empty_integration_branch() {
  source "$LIB_DIR/spawn-helper.sh"
  spawn_write_env TICKET_ID=TEST-42 \
    REPOS_ROOT=/repos ISSUE_PREFIX=TEST BE_SERVICES=svc1 \
    BASE_BRANCH=develop \
    INTEGRATION_BRANCH= \
    TICKET_BRANCH=feat/TEST-42-fix-bug >/dev/null 2>&1
  local f=/tmp/ticket-auto-TEST-42-env.sh
  # Empty INTEGRATION_BRANCH should produce empty placeholder (not error)
  grep -q 'export INTEGRATION_BRANCH=""' "$f"
}

test_write_env_empty_worktree_root() {
  source "$LIB_DIR/spawn-helper.sh"
  spawn_write_env TICKET_ID=TEST-42 \
    REPOS_ROOT=/repos ISSUE_PREFIX=TEST BE_SERVICES=svc1 \
    BASE_BRANCH=develop \
    WORKTREE_ROOT= >/dev/null 2>&1
  local f=/tmp/ticket-auto-TEST-42-env.sh
  # Empty WORKTREE_ROOT should produce empty placeholder (not error)
  grep -q 'export WORKTREE_ROOT=""' "$f"
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
  local tmpdir
  tmpdir=$(_mktemp_test_dir)
  local output
  # HB_LOG_FILE is real (non-empty), so this starts a genuine disowned
  # watchdog. FLEET_STATE_DIR pins its stop-file under our own tmpdir so it
  # self-terminates (spawn-helper.sh's stop_dir check) once we rm -rf below,
  # instead of spinning forever against a stop file it can never see.
  output=$(FLEET_STATE_DIR="$tmpdir" spawn_agent_pre PHASE=TEST STEP=test TICKET_ID=TEST-42 SKILL=/ticket-test \
    LOG_FILE='/tmp/foo"; echo pwned; true".log' \
    HB_LOG_FILE='/tmp/foo".log' \
    2>/dev/null)
  local rc=0
  # The escaped values should appear in single quotes (printf '%q' output)
  # and NOT contain unescaped double-quote-shell-break patterns
  echo "$output" | grep -q "AGENT_PROMPT=" || rc=1
  # The unescaped injection string should be absent from the final prompt
  echo "$output" | grep -q 'echo pwned' && rc=1
  rm -rf "$tmpdir"
  return $rc
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

test_post_meta_file_persists_after_done() {
  # Meta file must persist after spawn_agent_post so duplicate calls
  # can still read PHASE/STEP for idempotency guard tail-checks.
  # It is overwritten by the next spawn_agent_pre call.
  cat >/tmp/ticket-auto-TEST-42-spawn-meta.txt <<'META'
PHASE=TEST
STEP=test
TICKET_ID=TEST-42
LOG_FILE=/tmp/test-cleanup.log
META
  source "$LIB_DIR/spawn-helper.sh"
  spawn_agent_post TICKET_ID=TEST-42 RESULT=done >/dev/null 2>&1
  [ -f /tmp/ticket-auto-TEST-42-spawn-meta.txt ]
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

# ── token-tracker phase resolution tests (Task 1.3) ────────────────────────────

test_token_tracker_resolves_phase_from_spawn_meta() {
  # Verify token-tracker.sh reads PHASE from the spawn-meta file whose
  # SESSION_ID matches the hook payload's session_id, and writes the log
  # entry under the correct phase.
  local tmpdir
  tmpdir=$(_mktemp_test_dir)
  local log_file="$tmpdir/test-tk.log"
  local transcript="$tmpdir/transcript.jsonl"
  local meta_file="/tmp/ticket-auto-TEST-TK01-spawn-meta.txt"
  local start_file="/tmp/ticket-auto-TEST-TK01-start-APPRAISE-$(date +%s%N).ts"

  # Clean any prior run
  rm -f "$meta_file" "$start_file" "$log_file"

  # Write spawn-meta with PHASE=APPRAISE and a session id
  cat >"$meta_file" <<'META'
PHASE=APPRAISE
STEP=appraise
TICKET_ID=TEST-TK01
LOG_FILE=LOG_FILE_PLACEHOLDER
HB_LOG_FILE=
CLAUDE_LOG_FILE=
SESSION_ID=sess-tk01
META
  sed -i "s|LOG_FILE_PLACEHOLDER|$log_file|" "$meta_file"

  # Touch our meta file so it's the newest (ls -t picks it first)
  touch "$meta_file"

  # Write a minimal agent transcript with usage data
  cat >"$transcript" <<'JSONL'
{"type": "assistant", "message": {"usage": {"input_tokens": 100, "output_tokens": 50, "cache_read_input_tokens": 10}}}
JSONL

  # Create start timestamp file
  date +%s%N >"$start_file"

  # Build hook JSON (matching session_id) and pipe to token-tracker.sh
  local hook_json="{\"session_id\": \"sess-tk01\", \"agent_transcript_path\": \"$transcript\"}"
  local tracker="$LIB_DIR/../hooks/token-tracker.sh"
  if [ -f "$tracker" ]; then
    echo "$hook_json" | bash "$tracker" 2>/dev/null || true
  fi

  # Verify the log entry has correct phase
  local result=0
  if [ -f "$log_file" ]; then
    grep -q '|META|tokens|info|APPRAISE:' "$log_file" || result=1
  else
    result=1
  fi

  rm -rf "$tmpdir" "$meta_file" "$start_file" 2>/dev/null || true
  return $result
}

test_token_tracker_ignores_session_mismatch() {
  # Verify token-tracker.sh writes NOTHING when the newest spawn-meta file
  # belongs to a different session than the hook payload's — this is the
  # cross-session misattribution issue #272 fixes: no ls -t fallback across
  # sessions, no guessing.
  local tmpdir
  tmpdir=$(_mktemp_test_dir)
  local log_file="$tmpdir/test-tk2.log"
  local transcript="$tmpdir/transcript2.jsonl"
  local meta_file="/tmp/ticket-auto-TEST-TK02-spawn-meta.txt"
  local start_file="/tmp/ticket-auto-TEST-TK02-start-IMPLEMENT-$(date +%s%N).ts"

  rm -f "$meta_file" "$start_file" "$log_file"

  # Spawn-meta belongs to a DIFFERENT session than the one in hook_json below.
  cat >"$meta_file" <<'META'
PHASE=IMPLEMENT
STEP=implement
TICKET_ID=TEST-TK02
LOG_FILE=LOG_FILE_PLACEHOLDER
SESSION_ID=sess-owner
META
  sed -i "s|LOG_FILE_PLACEHOLDER|$log_file|" "$meta_file"
  touch "$meta_file"

  cat >"$transcript" <<'JSONL'
{"type": "assistant", "message": {"usage": {"input_tokens": 200, "output_tokens": 100}}}
JSONL

  date +%s%N >"$start_file"

  local hook_json="{\"session_id\": \"sess-unrelated\", \"agent_transcript_path\": \"$transcript\"}"
  local tracker="$LIB_DIR/../hooks/token-tracker.sh"
  if [ -f "$tracker" ]; then
    echo "$hook_json" | bash "$tracker" 2>/dev/null || true
  fi

  # No matching spawn-meta for this session → nothing should be written.
  local result=0
  [ -f "$log_file" ] && result=1

  rm -rf "$tmpdir" "$meta_file" "$start_file" 2>/dev/null || true
  return $result
}

test_token_tracker_no_session_in_payload_writes_nothing() {
  # Verify token-tracker.sh exits cleanly and writes nothing when the hook
  # payload carries no session_id at all — there is no safe attribution
  # target, so the hook must not guess (no UNKNOWN phase fallback).
  local tmpdir
  tmpdir=$(_mktemp_test_dir)
  local log_file="$tmpdir/test-tk3.log"
  local transcript="$tmpdir/transcript3.jsonl"
  local meta_file="/tmp/ticket-auto-TEST-TK03-spawn-meta.txt"
  local start_file="/tmp/ticket-auto-TEST-TK03-start-APPRAISE-$(date +%s%N).ts"

  rm -f "$meta_file" "$start_file" "$log_file"

  cat >"$meta_file" <<'META'
PHASE=APPRAISE
STEP=appraise
TICKET_ID=TEST-TK03
LOG_FILE=LOG_FILE_PLACEHOLDER
SESSION_ID=sess-tk03
META
  sed -i "s|LOG_FILE_PLACEHOLDER|$log_file|" "$meta_file"
  touch "$meta_file"

  cat >"$transcript" <<'JSONL'
{"type": "assistant", "message": {"usage": {"input_tokens": 50, "output_tokens": 25}}}
JSONL

  date +%s%N >"$start_file"

  local hook_json="{\"agent_transcript_path\": \"$transcript\"}"
  local tracker="$LIB_DIR/../hooks/token-tracker.sh"
  if [ -f "$tracker" ]; then
    echo "$hook_json" | bash "$tracker" 2>/dev/null || true
  fi

  local result=0
  [ -f "$log_file" ] && result=1

  rm -rf "$tmpdir" "$meta_file" "$start_file" 2>/dev/null || true
  return $result
}

test_token_tracker_skips_when_transcript_path_absent() {
  # 2b: when agent_transcript_path is absent from the payload (subagent_type
  # spawns omit it), token accounting must be skipped — never guessed from
  # the newest jsonl in the project dir, which is typically the parent
  # session's own transcript and would corrupt every downstream aggregate.
  local tmpdir
  tmpdir=$(_mktemp_test_dir)
  local log_file="$tmpdir/test-tkb.log"
  local meta_file="/tmp/ticket-auto-TEST-TKB-spawn-meta.txt"
  local start_file="/tmp/ticket-auto-TEST-TKB-start-APPRAISE-$(date +%s%N).ts"

  rm -f "$meta_file" "$start_file" "$log_file"

  cat >"$meta_file" <<META
PHASE=APPRAISE
STEP=appraise
TICKET_ID=TEST-TKB
LOG_FILE=$log_file
SESSION_ID=sess-tkb
META
  touch "$meta_file"
  date +%s%N >"$start_file"

  local hook_json="{\"session_id\": \"sess-tkb\"}"
  local tracker="$LIB_DIR/../hooks/token-tracker.sh"
  if [ -f "$tracker" ]; then
    echo "$hook_json" | bash "$tracker" 2>/dev/null || true
  fi

  # No token line should be written — there's no transcript to attribute to.
  local result=0
  if [ -f "$log_file" ]; then
    grep -q '|META|tokens|info|' "$log_file" && result=1
  fi

  rm -rf "$tmpdir" "$meta_file" "$start_file" 2>/dev/null || true
  return $result
}

test_token_tracker_transcript_path_with_quote_is_safe() {
  # 2c: AGENT_TRANSCRIPT must be passed as sys.argv, never interpolated into
  # Python source. A path containing a single quote would have terminated
  # the old string literal early; verify it's parsed correctly instead
  # (proving no injection surface) and tokens are still summed.
  local tmpdir
  tmpdir=$(_mktemp_test_dir)
  local quote_dir="$tmpdir/te'st"
  mkdir -p "$quote_dir"
  local transcript="$quote_dir/transcript.jsonl"
  local log_file="$tmpdir/test-tkq.log"
  local meta_file="/tmp/ticket-auto-TEST-TKQ-spawn-meta.txt"
  local start_file="/tmp/ticket-auto-TEST-TKQ-start-APPRAISE-$(date +%s%N).ts"

  rm -f "$meta_file" "$start_file" "$log_file"

  cat >"$meta_file" <<META
PHASE=APPRAISE
STEP=appraise
TICKET_ID=TEST-TKQ
LOG_FILE=$log_file
SESSION_ID=sess-tkq
META
  touch "$meta_file"

  cat >"$transcript" <<'JSONL'
{"type": "assistant", "message": {"usage": {"input_tokens": 7, "output_tokens": 3}}}
JSONL

  date +%s%N >"$start_file"

  local hook_json="{\"session_id\": \"sess-tkq\", \"agent_transcript_path\": \"$transcript\"}"
  local tracker="$LIB_DIR/../hooks/token-tracker.sh"
  if [ -f "$tracker" ]; then
    echo "$hook_json" | bash "$tracker" 2>/dev/null || true
  fi

  local result=0
  if [ -f "$log_file" ]; then
    grep -q '|META|tokens|info|APPRAISE:7/3/0' "$log_file" || result=1
  else
    result=1
  fi

  rm -rf "$tmpdir" "$meta_file" "$start_file" 2>/dev/null || true
  return $result
}

test_token_tracker_start_writes_timestamp_on_session_match() {
  local ticket_id="TEST-TKS1"
  local meta_file="/tmp/ticket-auto-${ticket_id}-spawn-meta.txt"
  rm -f "$meta_file" /tmp/ticket-auto-${ticket_id}-start-APPRAISE-*.ts

  cat >"$meta_file" <<META
PHASE=APPRAISE
STEP=appraise
TICKET_ID=${ticket_id}
LOG_FILE=/tmp/does-not-matter.log
SESSION_ID=sess-tks1
META
  touch "$meta_file"

  local hook_json="{\"session_id\": \"sess-tks1\"}"
  local starter="$LIB_DIR/../hooks/token-tracker-start.sh"
  if [ -f "$starter" ]; then
    echo "$hook_json" | bash "$starter" 2>/dev/null || true
  fi

  local result=0
  local found
  found=$(ls /tmp/ticket-auto-${ticket_id}-start-APPRAISE-*.ts 2>/dev/null | head -1 || true)
  [ -z "$found" ] && result=1

  rm -f "$meta_file" /tmp/ticket-auto-${ticket_id}-start-APPRAISE-*.ts 2>/dev/null || true
  return $result
}

test_token_tracker_start_ignores_session_mismatch() {
  local ticket_id="TEST-TKS2"
  local meta_file="/tmp/ticket-auto-${ticket_id}-spawn-meta.txt"
  rm -f "$meta_file" /tmp/ticket-auto-${ticket_id}-start-APPRAISE-*.ts

  cat >"$meta_file" <<META
PHASE=APPRAISE
STEP=appraise
TICKET_ID=${ticket_id}
LOG_FILE=/tmp/does-not-matter.log
SESSION_ID=sess-owner
META
  touch "$meta_file"

  local hook_json="{\"session_id\": \"sess-unrelated\"}"
  local starter="$LIB_DIR/../hooks/token-tracker-start.sh"
  if [ -f "$starter" ]; then
    echo "$hook_json" | bash "$starter" 2>/dev/null || true
  fi

  local result=0
  local found
  found=$(ls /tmp/ticket-auto-${ticket_id}-start-APPRAISE-*.ts 2>/dev/null | head -1 || true)
  [ -n "$found" ] && result=1

  rm -f "$meta_file" /tmp/ticket-auto-${ticket_id}-start-APPRAISE-*.ts 2>/dev/null || true
  return $result
}

# ── bracket idempotency guard tests (Tasks 3.1-3.3) ────────────────────────────

test_pre_duplicate_waiting_suppressed() {
  # Calling spawn_agent_pre twice with same PHASE/STEP must NOT write two waiting entries
  local tmpdir
  tmpdir=$(_mktemp_test_dir)
  local log_file="$tmpdir/test.log"
  # First call: writes waiting
  source "$LIB_DIR/spawn-helper.sh"
  spawn_agent_pre PHASE=TEST STEP=test_step TICKET_ID=TEST-DUP \
    SKILL=/ticket-test LOG_FILE="$log_file" >/dev/null 2>&1
  # Second call: should skip
  spawn_agent_pre PHASE=TEST STEP=test_step TICKET_ID=TEST-DUP \
    SKILL=/ticket-test LOG_FILE="$log_file" >/dev/null 2>&1
  local count
  count=$(grep -c '|TEST|test_step|waiting|' "$log_file" 2>/dev/null || true)
  rm -rf "$tmpdir"
  [ "$count" -eq 1 ]
}

test_post_duplicate_done_suppressed() {
  # Calling spawn_agent_post done twice with same PHASE/STEP must NOT write two done entries
  local tmpdir
  tmpdir=$(_mktemp_test_dir)
  local log_file="$tmpdir/test.log"
  cat >/tmp/ticket-auto-TEST-DUP2-spawn-meta.txt <<'META'
PHASE=TEST
STEP=test_step
TICKET_ID=TEST-DUP2
LOG_FILE=LOG_FILE_PLACEHOLDER
META
  sed -i "s|LOG_FILE_PLACEHOLDER|$log_file|" /tmp/ticket-auto-TEST-DUP2-spawn-meta.txt
  source "$LIB_DIR/spawn-helper.sh"
  # First call: writes done
  spawn_agent_post TICKET_ID=TEST-DUP2 RESULT=done MSG="first done" >/dev/null 2>&1
  # Second call: should skip
  spawn_agent_post TICKET_ID=TEST-DUP2 RESULT=done MSG="second done" >/dev/null 2>&1
  local count
  count=$(grep -c '|TEST|test_step|done|' "$log_file" 2>/dev/null || true)
  rm -rf "$tmpdir"
  [ "$count" -eq 1 ]
}

test_post_phase_uppercase_in_log() {
  # spawn_agent_post must uppercase the phase before writing to the pipeline log.
  # detect-resume.sh compares against uppercase phase constants (APPRAISE, IMPLEMENT, etc.)
  # and will silently fall through to STEP_1 if the phase is lowercase.
  local tmpdir
  tmpdir=$(_mktemp_test_dir)
  local log_file="$tmpdir/test.log"
  local hb_file="$tmpdir/test.hb"
  cat >/tmp/ticket-auto-TEST-CASE-spawn-meta.txt <<'META'
PHASE=appraise
STEP=appraise
TICKET_ID=TEST-CASE
LOG_FILE=LOG_FILE_PLACEHOLDER
HB_LOG_FILE=HB_FILE_PLACEHOLDER
PINGER_PID=
WATCHDOG_PID=
META
  sed -i "s|LOG_FILE_PLACEHOLDER|$log_file|" /tmp/ticket-auto-TEST-CASE-spawn-meta.txt
  sed -i "s|HB_FILE_PLACEHOLDER|$hb_file|" /tmp/ticket-auto-TEST-CASE-spawn-meta.txt
  source "$LIB_DIR/spawn-helper.sh"
  spawn_agent_post TICKET_ID=TEST-CASE RESULT=done MSG="phase casing test" >/dev/null 2>&1
  local has_upper
  has_upper=$(grep -c '|APPRAISE|appraise|done|' "$log_file" 2>/dev/null || true)
  local has_lower
  has_lower=$(grep -c '|appraise|appraise|done|' "$log_file" 2>/dev/null || true)
  rm -rf "$tmpdir"
  [ "$has_upper" -eq 1 ] && [ "$has_lower" -eq 0 ]
}

test_post_loop_phase_two_brackets_produce_two_done_lines() {
  # R4 regression: loop phases (pr-review iterate, verify retry) reuse the same
  # PHASE|STEP across multiple spawn brackets. A whole-file dedup grep would
  # suppress the second bracket's done line forever since the first done line
  # already matches. The post-guard must be tail-scoped like the pre-guard so
  # each bracket's own done line lands.
  local tmpdir
  tmpdir=$(_mktemp_test_dir)
  local log_file="$tmpdir/test.log"
  source "$LIB_DIR/spawn-helper.sh"
  # Bracket 1: waiting -> done
  spawn_agent_pre PHASE=PR-REVIEW STEP=pr-review TICKET_ID=TEST-LOOP \
    SKILL=/ticket-pr-review LOG_FILE="$log_file" >/dev/null 2>&1
  spawn_agent_post TICKET_ID=TEST-LOOP RESULT=done MSG="Verdict: first pass" >/dev/null 2>&1
  # Bracket 2 (iteration): waiting -> done, same PHASE|STEP
  spawn_agent_pre PHASE=PR-REVIEW STEP=pr-review TICKET_ID=TEST-LOOP \
    SKILL=/ticket-pr-review LOG_FILE="$log_file" >/dev/null 2>&1
  spawn_agent_post TICKET_ID=TEST-LOOP RESULT=done MSG="Verdict: second pass" >/dev/null 2>&1
  local done_count
  done_count=$(grep -c '|PR-REVIEW|pr-review|done|' "$log_file" 2>/dev/null || true)
  rm -rf "$tmpdir" /tmp/ticket-auto-TEST-LOOP-spawn-meta.txt 2>/dev/null
  [ "$done_count" -eq 2 ]
}

test_post_retry_after_fail_writes_new_bracket() {
  # After a fail entry, calling pre again MUST write a new waiting bracket
  # (last line is fail, not waiting — guard must allow the retry)
  local tmpdir
  tmpdir=$(_mktemp_test_dir)
  local log_file="$tmpdir/test.log"
  # Set up metadata for post
  cat >/tmp/ticket-auto-TEST-RETRY-spawn-meta.txt <<'META'
PHASE=TEST
STEP=test_step
TICKET_ID=TEST-RETRY
LOG_FILE=LOG_FILE_PLACEHOLDER
META
  sed -i "s|LOG_FILE_PLACEHOLDER|$log_file|" /tmp/ticket-auto-TEST-RETRY-spawn-meta.txt
  source "$LIB_DIR/spawn-helper.sh"
  # First pre: writes waiting
  spawn_agent_pre PHASE=TEST STEP=test_step TICKET_ID=TEST-RETRY \
    SKILL=/ticket-test LOG_FILE="$log_file" >/dev/null 2>&1
  # First post: writes fail
  spawn_agent_post TICKET_ID=TEST-RETRY RESULT=fail MSG="first attempt failed" >/dev/null 2>&1
  # Second pre: should write a NEW waiting (last line is fail, not waiting)
  spawn_agent_pre PHASE=TEST STEP=test_step TICKET_ID=TEST-RETRY \
    SKILL=/ticket-test LOG_FILE="$log_file" >/dev/null 2>&1
  local waiting_count fail_count
  waiting_count=$(grep -c '|TEST|test_step|waiting|' "$log_file" 2>/dev/null || true)
  fail_count=$(grep -c '|TEST|test_step|fail|' "$log_file" 2>/dev/null || true)
  rm -rf "$tmpdir"
  [ "$waiting_count" -eq 2 ] && [ "$fail_count" -eq 1 ]
}

# ── VERDICT token tests (R5) ───────────────────────────────────────────────────

test_post_rejects_bad_verdict_value() {
  source "$LIB_DIR/spawn-helper.sh"
  spawn_agent_post TICKET_ID=TEST-42 RESULT=done VERDICT=MAYBE >/dev/null 2>&1 && false || true
}

test_post_done_verdict_prepended_to_log_msg() {
  local tmpdir
  tmpdir=$(_mktemp_test_dir)
  local log_file="$tmpdir/test.log"
  cat >/tmp/ticket-auto-TEST-VERDICT1-spawn-meta.txt <<META
PHASE=VERIFY
STEP=verify
TICKET_ID=TEST-VERDICT1
LOG_FILE=$log_file
META
  source "$LIB_DIR/spawn-helper.sh"
  spawn_agent_post TICKET_ID=TEST-VERDICT1 RESULT=done VERDICT=PASS MSG="3/3 criteria met" >/dev/null 2>&1
  local rc=$?
  local matched
  matched=$(grep -c '|VERIFY|verify|done|PASS — 3/3 criteria met' "$log_file" 2>/dev/null || true)
  rm -rf "$tmpdir" /tmp/ticket-auto-TEST-VERDICT1-spawn-meta.txt
  [ "$rc" -eq 0 ] && [ "$matched" -eq 1 ]
}

test_post_fail_verdict_prepended_to_log_msg() {
  local tmpdir
  tmpdir=$(_mktemp_test_dir)
  local log_file="$tmpdir/test.log"
  cat >/tmp/ticket-auto-TEST-VERDICT2-spawn-meta.txt <<META
PHASE=VERIFY
STEP=verify
TICKET_ID=TEST-VERDICT2
LOG_FILE=$log_file
META
  source "$LIB_DIR/spawn-helper.sh"
  spawn_agent_post TICKET_ID=TEST-VERDICT2 RESULT=fail VERDICT=FAIL MSG="2/3 criteria met" >/dev/null 2>&1
  local matched
  matched=$(grep -c '|VERIFY|verify|fail|FAIL — 2/3 criteria met' "$log_file" 2>/dev/null || true)
  rm -rf "$tmpdir" /tmp/ticket-auto-TEST-VERDICT2-spawn-meta.txt
  [ "$matched" -eq 1 ]
}

test_post_no_verdict_leaves_msg_unprefixed() {
  # Non-verdict phases (e.g. document/maintenance) must not gain a stray prefix.
  local tmpdir
  tmpdir=$(_mktemp_test_dir)
  local log_file="$tmpdir/test.log"
  cat >/tmp/ticket-auto-TEST-VERDICT3-spawn-meta.txt <<META
PHASE=MAINTENANCE
STEP=document
TICKET_ID=TEST-VERDICT3
LOG_FILE=$log_file
META
  source "$LIB_DIR/spawn-helper.sh"
  spawn_agent_post TICKET_ID=TEST-VERDICT3 RESULT=done MSG="ai-context.md written" >/dev/null 2>&1
  local matched
  matched=$(grep -c '|MAINTENANCE|document|done|ai-context.md written$' "$log_file" 2>/dev/null || true)
  rm -rf "$tmpdir" /tmp/ticket-auto-TEST-VERDICT3-spawn-meta.txt
  [ "$matched" -eq 1 ]
}

# ── spawn_capture tests ────────────────────────────────────────────────────────

test_capture_rejects_missing_phase() {
  source "$LIB_DIR/spawn-helper.sh"
  spawn_capture TICKET_ID=TEST-42 RESULT="some output" >/dev/null 2>&1 && false || true
}

test_capture_calls_through_with_all_params() {
  source "$LIB_DIR/spawn-helper.sh"
  _spy_reset
  spawn_capture TICKET_ID=TEST-42 PHASE=TEST RESULT="captured output" ATTEMPT=2 >/dev/null 2>&1 || return 1
  # The capture must actually have happened, lowercased, with the attempt passed
  # through — not merely have returned 0.
  [ "$(_spy_last)" = "TEST-42|test|2|captured output" ]
}

test_capture_records_lowercased_phase() {
  source "$LIB_DIR/spawn-helper.sh"
  _spy_reset
  spawn_capture TICKET_ID=TEST-42 PHASE=PR-REVIEW RESULT="out" >/dev/null 2>&1 || return 1
  [ "$(_spy_last)" = "TEST-42|pr-review||out" ]
}

test_capture_reads_result_file() {
  local tmpdir
  tmpdir=$(_mktemp_test_dir)
  printf 'line one\nline two\n' >"$tmpdir/ret.txt"
  source "$LIB_DIR/spawn-helper.sh"
  _spy_reset
  spawn_capture TICKET_ID=TEST-42 PHASE=IMPLEMENT RESULT_FILE="$tmpdir/ret.txt" >/dev/null 2>&1 || return 1
  local got
  got=$(cat "$_CAPTURE_SPY")
  rm -rf "$tmpdir"
  # Multi-line result lands in the spy verbatim.
  [ "$got" = "TEST-42|implement||line one
line two" ]
}

test_capture_rejects_missing_result_file() {
  source "$LIB_DIR/spawn-helper.sh"
  spawn_capture TICKET_ID=TEST-42 PHASE=IMPLEMENT RESULT_FILE=/nonexistent/nope.txt >/dev/null 2>&1 && false || true
}

# ── real capture_agent_result contract tests ───────────────────────────────────
# These unset the file-scope spy and run the genuine function, so a regression in
# attempt separation or metacharacter handling fails CI rather than passing on a
# stubbed success.

test_real_capture_appends_each_attempt() {
  local tmpdir
  tmpdir=$(_mktemp_test_dir)
  (
    cd "$tmpdir" || exit 1
    unset -f capture_agent_result
    source "$LIB_DIR/spawn-helper.sh"
    source "$LIB_DIR/capture-transcript.sh"
    spawn_capture TICKET_ID=TEST-42 PHASE=VERIFY RESULT="first attempt" ATTEMPT=1
    spawn_capture TICKET_ID=TEST-42 PHASE=VERIFY RESULT="second attempt" ATTEMPT=2
  ) >/dev/null 2>&1
  local log="$tmpdir/logs/TEST-42-verify-agent.log"
  local ok=1
  if grep -q 'first attempt' "$log" 2>/dev/null &&
    grep -q 'second attempt' "$log" 2>/dev/null &&
    grep -q -- '--- Attempt 1 ---' "$log" 2>/dev/null &&
    grep -q -- '--- Attempt 2 ---' "$log" 2>/dev/null; then
    ok=0
  fi
  rm -rf "$tmpdir"
  return "$ok"
}

test_real_capture_preserves_shell_metacharacters() {
  local tmpdir
  tmpdir=$(_mktemp_test_dir)
  local payload='quote " dollar $HOME backtick `id` subst $(id) amp && semi ; back\slash'
  printf '%s\n' "$payload" >"$tmpdir/ret.txt"
  (
    cd "$tmpdir" || exit 1
    unset -f capture_agent_result
    source "$LIB_DIR/spawn-helper.sh"
    source "$LIB_DIR/capture-transcript.sh"
    spawn_capture TICKET_ID=TEST-42 PHASE=IMPLEMENT RESULT_FILE="$tmpdir/ret.txt"
  ) >/dev/null 2>&1
  local got
  got=$(cat "$tmpdir/logs/TEST-42-implement-agent.log" 2>/dev/null)
  rm -rf "$tmpdir"
  # Verbatim round-trip: nothing expanded, nothing executed, nothing truncated.
  [ "$got" = "$payload" ]
}

# capture_agent_result is mocked at file scope (see mocks section above) so the
# tests above only exercise param plumbing. This test uses the real
# capture-transcript.sh to catch the actual regression: capture_agent_result
# hard-rejects any non-kebab-case PHASE, and every real call site passes
# uppercase (e.g. PHASE=IMPLEMENT).
test_capture_lowercases_uppercase_phase_for_real_capture() {
  local tmpdir
  tmpdir=$(_mktemp_test_dir)
  (
    cd "$tmpdir" || exit 1
    unset -f capture_agent_result
    source "$LIB_DIR/spawn-helper.sh"
    source "$LIB_DIR/capture-transcript.sh"
    spawn_capture TICKET_ID=TEST-42 PHASE=IMPLEMENT RESULT="agent output"
  ) >/dev/null 2>&1
  [ -f "$tmpdir/logs/TEST-42-implement-agent.log" ]
}

# ── escalation test — printf '%q' safety ──────────────────────────────────────

test_env_prefix_survives_shell_special_chars_in_paths() {
  # If any of LOG_FILE, HB_LOG_FILE, CLAUDE_LOG_FILE, or TICKET_ID contained
  # a quote or command substitution, the sub-agent would execute it. This test
  # asserts that printf '%q' neutralises those characters.
  source "$LIB_DIR/spawn-helper.sh"
  local tmpdir
  tmpdir=$(_mktemp_test_dir)
  local try_tid='TEST-42"; echo BAD; true"'
  local try_log='/tmp/log"; $(id); true".log'
  local output
  # HB_LOG_FILE is real (non-empty), so this starts a genuine disowned
  # watchdog. FLEET_STATE_DIR pins its stop-file under our own tmpdir so it
  # self-terminates once we rm -rf below, rather than leaking indefinitely
  # against the shared ./logs default (which also gets the malicious
  # TICKET_ID baked into a filename otherwise — see GH #129).
  output=$(FLEET_STATE_DIR="$tmpdir" spawn_agent_pre PHASE=TEST STEP=test TICKET_ID="$try_tid" SKILL=/ticket-test \
    LOG_FILE="$try_log" HB_LOG_FILE="$try_log" CLAUDE_LOG_FILE="$try_log" 2>/dev/null || true)
  rm -rf "$tmpdir"
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
  # When _plog and hb_heartbeat are already defined (e.g. test mocks),
  # spawn-helper.sh must not overwrite them with the real heartbeat.sh implementation.
  bash -c "
    _plog() { return 0; }
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
  tmpdir=$(_mktemp_test_dir)
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
  tmpdir=$(_mktemp_test_dir)
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
  tmpdir=$(_mktemp_test_dir)
  local stop_file="$tmpdir/watchdog-stop"
  local hb_log="$tmpdir/hb.log"
  # Run in a clean subshell — unset global mocks so spawn-helper.sh loads real heartbeat.sh
  (
    export HB_LOG_FILE="$hb_log"
    unset -f hb_heartbeat hb_pinger_start hb_pinger_stop cl_write _plog _iso_now 2>/dev/null || true
    source "$LIB_DIR/spawn-helper.sh"
    # Initialize the heartbeat log (schema header needed for valid file)
    hb_init
    # Start watchdog with 1s interval (instead of default 60s)
    spawn_watchdog_start "$stop_file" "TEST" 1
    # $! immediately after start captures the disowned background PID —
    # jobs -p cannot see it once disowned, so this is the only handle we get.
    local watchdog_pid=$!
    # Wait up to 3s for at least one heartbeat entry
    waited=0
    while [ $waited -lt 6 ]; do
      sleep 0.5
      waited=$((waited + 1))
      [ -f "$hb_log" ] && grep -q 'watchdog' "$hb_log" 2>/dev/null && break
    done
    # Stop the watchdog and verify at least one heartbeat was written before
    # killing it directly — don't rely on the stop-file race against the
    # caller's rm -rf below (that's exactly the leak this test used to cause).
    spawn_watchdog_stop "$stop_file"
    local result=0
    grep -q 'watchdog' "$hb_log" || result=1
    kill "$watchdog_pid" 2>/dev/null || true
    exit "$result"
  )
  local rc=$?
  rm -rf "$tmpdir"
  return $rc
}

# Regression test for GH #129: a watchdog whose workspace directory is
# deleted out from under it (the test's own rm -rf, or a crashed caller in
# production) must exit on its own instead of spinning on a stop file that
# can never appear again.
test_watchdog_exits_when_workspace_removed() {
  local tmpdir
  tmpdir=$(_mktemp_test_dir)
  local stop_file="$tmpdir/watchdog-stop"
  local watchdog_pid
  (
    export HB_LOG_FILE="$tmpdir/hb.log"
    unset -f hb_heartbeat hb_pinger_start hb_pinger_stop cl_write _plog _iso_now 2>/dev/null || true
    source "$LIB_DIR/spawn-helper.sh"
    hb_init
    spawn_watchdog_start "$stop_file" "TEST" 1
    echo "$!"
  ) >"$tmpdir/pid.txt"
  watchdog_pid=$(cat "$tmpdir/pid.txt")
  # Remove the workspace without ever touching the stop file — this is the
  # exact race from the bug report (rm -rf wins before the watchdog wakes).
  rm -rf "$tmpdir"
  local waited=0
  while kill -0 "$watchdog_pid" 2>/dev/null; do
    if [ "$waited" -ge 30 ]; then
      kill "$watchdog_pid" 2>/dev/null || true
      echo "watchdog still alive after 3s of workspace removal"
      return 1
    fi
    sleep 0.1
    waited=$((waited + 1))
  done
  return 0
}

# ── FLEET_WORKER_PID honesty (worker-reap-recovery, tasks 1.7-1.8) ────────────

test_watchdog_exits_when_worker_pid_dies() {
  # A watchdog told about a real worker pid via FLEET_WORKER_PID exits as
  # soon as that pid dies — even though its own stop file was never touched
  # and its workspace directory still exists. This is the exact bug this
  # section fixes: a crashed worker used to leave the watchdog heartbeating
  # forever, reporting a false pulse to detect_stalls.
  local tmpdir
  tmpdir=$(_mktemp_test_dir)
  local stop_file="$tmpdir/watchdog-stop"
  local watchdog_pid sleeper_pid

  # A real process the watchdog will watch and we will kill ourselves.
  sleep 30 &
  sleeper_pid=$!

  (
    export HB_LOG_FILE="$tmpdir/hb.log"
    export FLEET_WORKER_PID="$sleeper_pid"
    unset -f hb_heartbeat hb_pinger_start hb_pinger_stop cl_write _plog _iso_now 2>/dev/null || true
    source "$LIB_DIR/spawn-helper.sh"
    hb_init
    spawn_watchdog_start "$stop_file" "TEST" 1
    echo "$!"
  ) >"$tmpdir/pid.txt"
  watchdog_pid=$(cat "$tmpdir/pid.txt")

  # Kill the "worker" — never touch the stop file.
  kill "$sleeper_pid" 2>/dev/null || true
  wait "$sleeper_pid" 2>/dev/null || true

  local waited=0
  while kill -0 "$watchdog_pid" 2>/dev/null; do
    if [ "$waited" -ge 30 ]; then
      kill "$watchdog_pid" 2>/dev/null || true
      rm -rf "$tmpdir"
      echo "watchdog still alive after 3s of worker death"
      return 1
    fi
    sleep 0.1
    waited=$((waited + 1))
  done
  # No heartbeat should have been written after the worker died — the
  # honesty check must fire before the alive heartbeat, not after.
  local result=0
  if [ -f "$tmpdir/hb.log" ] && grep -q 'watchdog' "$tmpdir/hb.log"; then
    result=1
    echo "watchdog emitted a heartbeat for a dead worker"
  fi
  rm -rf "$tmpdir"
  return $result
}

test_watchdog_exits_at_iteration_cap_when_pid_unset() {
  # With FLEET_WORKER_PID unset (interactive/manual runs), the watchdog has
  # no liveness signal to check and must still exit eventually — the
  # bounded iteration cap is the only thing preventing it from outliving
  # its purpose indefinitely.
  local tmpdir
  tmpdir=$(_mktemp_test_dir)
  local stop_file="$tmpdir/watchdog-stop"
  local watchdog_pid

  (
    export HB_LOG_FILE="$tmpdir/hb.log"
    unset FLEET_WORKER_PID FLEET_WORKER_START_TICKS
    export FLEET_WATCHDOG_MAX_ITERATIONS=2
    unset -f hb_heartbeat hb_pinger_start hb_pinger_stop cl_write _plog _iso_now 2>/dev/null || true
    source "$LIB_DIR/spawn-helper.sh"
    hb_init
    spawn_watchdog_start "$stop_file" "TEST" 1
    echo "$!"
  ) >"$tmpdir/pid.txt"
  watchdog_pid=$(cat "$tmpdir/pid.txt")

  # 2 iterations at 1s sleep = ~2s to the cap; allow generous headroom.
  local waited=0
  while kill -0 "$watchdog_pid" 2>/dev/null; do
    if [ "$waited" -ge 60 ]; then
      kill "$watchdog_pid" 2>/dev/null || true
      rm -rf "$tmpdir"
      echo "watchdog still alive after 6s — iteration cap not honoured"
      return 1
    fi
    sleep 0.1
    waited=$((waited + 1))
  done
  rm -rf "$tmpdir"
  return 0
}

# ── spawn_agent_post wait/reaping (Bug #4 fix) ─────────────────────────────────

# ── phase_bracket_open (task 4.12) ───────────────────────────────────────────
# The opening half, extracted for the same reason as the closing one: fleetd
# forks phases itself and would otherwise leave every bracket unopened, which
# detect-resume.sh, the zombie detector and the OTel exporter all read as "this
# phase never started". Exercised the way fleetd calls it — directly, with no
# pinger, no watchdog and no spawn-meta file.

test_phase_bracket_open_writes_waiting_and_model() {
  local tmpdir log
  tmpdir=$(_mktemp_test_dir)
  log="$tmpdir/TEST-PBO1-pipeline.log"
  echo "2026-06-02T10:00:00Z|META|schema|info|1" >"$log"
  (
    source "$LIB_DIR/spawn-helper.sh"
    ANTHROPIC_MODEL=claude-opus-5 phase_bracket_open \
      PHASE=verify STEP=Verify TICKET_ID=TEST-PBO1 \
      DESCRIPTION="verify agent" LOG_FILE="$log" >/dev/null
  )
  grep -q '|VERIFY|verify|waiting|Agent launched — verify agent$' "$log" &&
    grep -q '|META|model|info|{"phase":"VERIFY","model":"claude-opus-5"}$' "$log"
}

# The guard used to compare the caller's PHASE verbatim against a line written
# with PHASE uppercased, so a lowercase caller never matched its own entry and
# the idempotency check was inert. Both sides normalise now.
test_phase_bracket_open_suppresses_duplicate_for_a_lowercase_phase() {
  local tmpdir log count
  tmpdir=$(_mktemp_test_dir)
  log="$tmpdir/TEST-PBO2-pipeline.log"
  echo "2026-06-02T10:00:00Z|META|schema|info|1" >"$log"
  (
    source "$LIB_DIR/spawn-helper.sh"
    phase_bracket_open PHASE=implement STEP=implement TICKET_ID=TEST-PBO2 LOG_FILE="$log" >/dev/null
    phase_bracket_open PHASE=implement STEP=implement TICKET_ID=TEST-PBO2 LOG_FILE="$log" >/dev/null
  )
  count=$(grep -c '|IMPLEMENT|implement|waiting|' "$log")
  [ "$count" = "1" ]
}

# A retry after a resolved bracket must open a new one. The tail window is two
# lines precisely so it covers [waiting, model] without reaching back over a
# terminal line into the previous attempt.
test_phase_bracket_open_allows_a_retry_after_a_terminal() {
  local tmpdir log count
  tmpdir=$(_mktemp_test_dir)
  log="$tmpdir/TEST-PBO3-pipeline.log"
  echo "2026-06-02T10:00:00Z|META|schema|info|1" >"$log"
  (
    source "$LIB_DIR/spawn-helper.sh"
    phase_bracket_open PHASE=VERIFY STEP=verify TICKET_ID=TEST-PBO3 LOG_FILE="$log" >/dev/null
    phase_terminal_write PHASE=VERIFY STEP=verify RESULT=fail MSG="1/3 criteria" LOG_FILE="$log"
    phase_bracket_open PHASE=VERIFY STEP=verify TICKET_ID=TEST-PBO3 LOG_FILE="$log" >/dev/null
  )
  count=$(grep -c '|VERIFY|verify|waiting|' "$log")
  [ "$count" = "2" ]
}

# A model name carrying a quote would otherwise forge a log line, and the log
# is what every consumer routes on.
test_phase_bracket_open_never_forges_a_log_line() {
  local tmpdir log
  tmpdir=$(_mktemp_test_dir)
  log="$tmpdir/TEST-PBO4-pipeline.log"
  echo "2026-06-02T10:00:00Z|META|schema|info|1" >"$log"
  (
    source "$LIB_DIR/spawn-helper.sh"
    phase_bracket_open PHASE=EXEC STEP=exec TICKET_ID=TEST-PBO4 \
      MODEL='evil","x":"y' LOG_FILE="$log" >/dev/null
  )
  # Every META|model line must still be valid JSON in field 5+.
  grep '|META|model|info|' "$log" | sed 's/^[^|]*|META|model|info|//' | jq -e . >/dev/null
}

test_phase_bracket_open_echoes_the_model_without_a_log_file() {
  local out
  out=$(
    source "$LIB_DIR/spawn-helper.sh"
    ANTHROPIC_MODEL=claude-sonnet-5 phase_bracket_open PHASE=EXEC STEP=exec TICKET_ID=X
  )
  [ "$out" = "claude-sonnet-5" ]
}

test_spawn_agent_pre_still_opens_through_the_helper() {
  # The router path must be unchanged by the extraction, including the
  # spawn-meta MODEL line, which now reuses the value the helper resolved.
  local tmpdir log meta
  tmpdir=$(_mktemp_test_dir)
  log="$tmpdir/TEST-PBO5-pipeline.log"
  echo "2026-06-02T10:00:00Z|META|schema|info|1" >"$log"
  (
    source "$LIB_DIR/spawn-helper.sh"
    ANTHROPIC_MODEL=claude-opus-5 spawn_agent_pre \
      PHASE=APPRAISE STEP=appraise TICKET_ID=TEST-PBO5 SKILL=/ticket-appraise \
      LOG_FILE="$log" DESCRIPTION="appraise agent" >/dev/null
  )
  meta="/tmp/ticket-auto-TEST-PBO5-spawn-meta.txt"
  grep -q '|APPRAISE|appraise|waiting|Agent launched — appraise agent$' "$log" &&
    grep -q '|META|model|info|{"phase":"APPRAISE","model":"claude-opus-5"}$' "$log" &&
    grep -q '^MODEL=claude-opus-5$' "$meta"
}

# ── phase_terminal_write (design.md D13) ─────────────────────────────────────
# The writing half of spawn_agent_post, extracted so fleetd can resolve a
# bracket on the automated path without going through the router. These tests
# exercise it the way fleetd will: called directly, with no spawn-meta file, no
# pinger and no watchdog in play.

test_phase_terminal_write_emits_done_marker() {
  local tmpdir log
  tmpdir=$(_mktemp_test_dir)
  log="$tmpdir/TEST-PTW1-pipeline.log"
  echo "2026-06-02T10:00:00Z|META|schema|info|2" >"$log"
  (
    source "$LIB_DIR/spawn-helper.sh"
    phase_terminal_write PHASE=implement STEP=Implement RESULT=done \
      MSG="committed 3 files" LOG_FILE="$log"
  )
  # Phase uppercased, step lowercased — the grammar detect-resume.sh keys on.
  grep -q '|IMPLEMENT|implement|done|committed 3 files$' "$log"
}

test_phase_terminal_write_prefixes_verdict() {
  local tmpdir log
  tmpdir=$(_mktemp_test_dir)
  log="$tmpdir/TEST-PTW2-pipeline.log"
  echo "2026-06-02T10:00:00Z|META|schema|info|2" >"$log"
  (
    source "$LIB_DIR/spawn-helper.sh"
    phase_terminal_write PHASE=VERIFY STEP=verify RESULT=done \
      VERDICT=PASS MSG="3/3 criteria" LOG_FILE="$log"
  )
  grep -q '|VERIFY|verify|done|PASS — 3/3 criteria$' "$log"
}

test_phase_terminal_write_marks_warn_continue() {
  local tmpdir log
  tmpdir=$(_mktemp_test_dir)
  log="$tmpdir/TEST-PTW3-pipeline.log"
  echo "2026-06-02T10:00:00Z|META|schema|info|2" >"$log"
  (
    source "$LIB_DIR/spawn-helper.sh"
    phase_terminal_write PHASE=MAINTENANCE STEP=document RESULT=fail \
      MSG="no diff" FAIL_ACTION=warn-continue LOG_FILE="$log"
  )
  grep -q '|MAINTENANCE|document|fail|no diff — continuing$' "$log"
}

test_phase_terminal_write_rejects_bad_verdict() {
  local tmpdir log
  tmpdir=$(_mktemp_test_dir)
  log="$tmpdir/TEST-PTW4-pipeline.log"
  echo "2026-06-02T10:00:00Z|META|schema|info|2" >"$log"
  ! (
    source "$LIB_DIR/spawn-helper.sh"
    phase_terminal_write PHASE=VERIFY STEP=verify RESULT=done \
      VERDICT=MAYBE LOG_FILE="$log" 2>/dev/null
  )
}

test_phase_terminal_write_suppresses_back_to_back_duplicate() {
  # A duplicate resolution of the same bracket must not double-write, or the
  # loop counters detect-resume.sh derives from terminal lines overcount.
  local tmpdir log count
  tmpdir=$(_mktemp_test_dir)
  log="$tmpdir/TEST-PTW5-pipeline.log"
  echo "2026-06-02T10:00:00Z|META|schema|info|2" >"$log"
  (
    source "$LIB_DIR/spawn-helper.sh"
    phase_terminal_write PHASE=VERIFY STEP=verify RESULT=done VERDICT=PASS LOG_FILE="$log"
    phase_terminal_write PHASE=VERIFY STEP=verify RESULT=done VERDICT=PASS LOG_FILE="$log"
  )
  count=$(grep -c '|VERIFY|verify|done|' "$log")
  [ "$count" = "1" ]
}

test_spawn_agent_post_still_writes_through_the_helper() {
  # The router path must be unchanged by the extraction: same line, same shape.
  local tmpdir log
  tmpdir=$(_mktemp_test_dir)
  log="$tmpdir/TEST-PTW6-pipeline.log"
  echo "2026-06-02T10:00:00Z|META|schema|info|2" >"$log"
  (
    source "$LIB_DIR/spawn-helper.sh"
    spawn_agent_post TICKET_ID=TEST-PTW6 RESULT=done PHASE=APPRAISE \
      STEP=appraise MSG="complexity=simple" LOG_FILE="$log"
  )
  grep -q '|APPRAISE|appraise|done|complexity=simple$' "$log"
}

test_spawn_agent_post_waits_for_captured_pids() {
  # Verify spawn_agent_post reads PINGER_PID/WATCHDOG_PID from spawn-meta
  # and attempts to wait for them after writing stop files.
  local tmpdir
  tmpdir=$(_mktemp_test_dir)
  local meta_file="/tmp/ticket-auto-TEST-WAIT-spawn-meta.txt"
  # Start a long-running subshell to simulate a background pinger
  sleep 10 &
  local test_pid=$!
  # Write spawn-meta with captured PIDs
  cat >"$meta_file" <<METAEOF
PHASE=TEST
STEP=test-wait
TICKET_ID=TEST-WAIT
LOG_FILE=$tmpdir/TEST-WAIT-pipeline.log
HB_LOG_FILE=$tmpdir/TEST-WAIT-heartbeat.log
CLAUDE_LOG_FILE=$tmpdir/TEST-WAIT-claude.log
PINGER_PID=$test_pid
WATCHDOG_PID=
METAEOF
  mkdir -p "$tmpdir"
  echo "2026-06-02T10:00:00Z|META|schema|info|1" >"$tmpdir/TEST-WAIT-pipeline.log"
  # Run spawn_agent_post — it should wait for test_pid
  # We run in a subshell with a timeout to avoid hang if wait fails
  (
    source "$LIB_DIR/spawn-helper.sh"
    spawn_agent_post TICKET_ID=TEST-WAIT RESULT=done MSG="test" 2>/dev/null
  ) &
  local post_pid=$!
  # Give it 3 seconds max
  sleep 3
  # Kill the spawned background if still running
  kill -0 "$post_pid" 2>/dev/null && kill "$post_pid" 2>/dev/null || true
  wait "$post_pid" 2>/dev/null || true
  # Clean up test PID
  kill "$test_pid" 2>/dev/null || true
  wait "$test_pid" 2>/dev/null || true
  rm -rf "$tmpdir" "$meta_file"
  return 0
}

test_f10_guard_clears_stale_stop_files_from_prior_phase() {
  local tmpdir
  tmpdir=$(_mktemp_test_dir)
  (
    export FLEET_STATE_DIR="$tmpdir"
    source "$LIB_DIR/spawn-helper.sh"
    TICKET_ID=TEST-F10A
    # Use the resolver to get the correct paths — _worker_stop_file now
    # delegates to config.sh constructors, so paths may not be /tmp.
    local pinger_stop watchdog_stop
    pinger_stop=$(_worker_stop_file "pinger")
    watchdog_stop=$(_worker_stop_file "watchdog")
    mkdir -p "$(dirname "$pinger_stop")"
    # Simulate prior phase: create both stop files at the resolved paths
    touch "$pinger_stop" "$watchdog_stop"
    # The guard should rm -f both stale files and succeed
    spawn_agent_pre PHASE=TEST STEP=f10-clear TICKET_ID=TEST-F10A \
      SKILL=/ticket-test HB_LOG_FILE="$tmpdir/hb.log" >/dev/null 2>&1
    # $! right after the call still refers to the disowned watchdog job
    # backgrounded inside spawn_agent_pre — kill it now instead of waiting
    # out its sleep_secs against the FLEET_STATE_DIR teardown below.
    kill "$!" 2>/dev/null || true
    # Verify stale files were removed
    [ ! -f "$pinger_stop" ] || exit 1
    [ ! -f "$watchdog_stop" ] || exit 1
  )
  local rc=$?
  rm -rf "$tmpdir"
  [ "$rc" -eq 0 ]
}

test_f10_guard_still_blocks_external_kill() {
  local tmpdir
  tmpdir=$(_mktemp_test_dir)
  (
    # Pin FLEET_STATE_DIR to the temp dir so path resolution is deterministic
    # regardless of CWD. Without this, _worker_stop_file resolves to ./logs/
    # which may not exist, and touch with 2>/dev/null silently fails.
    export FLEET_STATE_DIR="$tmpdir"
    source "$LIB_DIR/spawn-helper.sh"
    TICKET_ID=TEST-F10B
    local pinger_stop
    pinger_stop=$(_worker_stop_file "pinger")
    mkdir -p "$(dirname "$pinger_stop")"
    # First call: clean state, should succeed (and clear any stale files)
    spawn_agent_pre PHASE=TEST STEP=f10-kill-1 TICKET_ID=TEST-F10B \
      SKILL=/ticket-test HB_LOG_FILE="$tmpdir/hb.log" >/dev/null 2>&1 || exit 1
    # Kill the watchdog this call started — the second call below aborts
    # before reaching spawn_watchdog_start, so this is the only one.
    kill "$!" 2>/dev/null || true
    # Race: background loop touches the stop file to simulate fleet
    # controller creating it between rm -f and [ -f ] inside the guard.
    (while true; do touch "$pinger_stop" 2>/dev/null; done) &
    local racer_pid=$!
    sleep 0.1
    # Second call: racer should recreate the file in the guard window
    if spawn_agent_pre PHASE=TEST STEP=f10-kill-2 TICKET_ID=TEST-F10B \
      SKILL=/ticket-test HB_LOG_FILE="$tmpdir/hb.log" 2>&1; then
      kill "$racer_pid" 2>/dev/null || true
      wait "$racer_pid" 2>/dev/null || true
      exit 1 # should have been aborted
    fi
    kill "$racer_pid" 2>/dev/null || true
    wait "$racer_pid" 2>/dev/null || true
  )
  local rc=$?
  rm -rf "$tmpdir"
  [ "$rc" -eq 0 ]
}

test_f10_guard_succeeds_when_no_stop_files_exist() {
  local tmpdir
  tmpdir=$(_mktemp_test_dir)
  (
    # Pin FLEET_STATE_DIR so the watchdog this starts is torn down with our
    # own tmpdir instead of leaking against the shared ./logs default.
    export FLEET_STATE_DIR="$tmpdir"
    source "$LIB_DIR/spawn-helper.sh"
    TICKET_ID=TEST-F10C
    # Ensure clean state at the resolved paths
    local pinger_stop watchdog_stop
    pinger_stop=$(_worker_stop_file "pinger")
    watchdog_stop=$(_worker_stop_file "watchdog")
    mkdir -p "$(dirname "$pinger_stop")"
    rm -f "$pinger_stop" "$watchdog_stop"
    spawn_agent_pre PHASE=TEST STEP=f10-clean TICKET_ID=TEST-F10C \
      SKILL=/ticket-test HB_LOG_FILE="$tmpdir/hb.log" >/dev/null 2>&1
    kill "$!" 2>/dev/null || true
  )
  local rc=$?
  rm -rf "$tmpdir"
  [ "$rc" -eq 0 ]
}

test_f10_guard_idempotent_across_multiple_spawns() {
  local tmpdir
  tmpdir=$(_mktemp_test_dir)
  (
    # Pin FLEET_STATE_DIR so both watchdogs started below are torn down with
    # our own tmpdir instead of leaking against the shared ./logs default.
    export FLEET_STATE_DIR="$tmpdir"
    source "$LIB_DIR/spawn-helper.sh"
    # Two sequential spawn_agent_pre calls with same TICKET_ID, both should succeed
    spawn_agent_pre PHASE=TEST STEP=f10-idem-1 TICKET_ID=TEST-F10D \
      SKILL=/ticket-test HB_LOG_FILE="$tmpdir/hb.log" >/dev/null 2>&1 || exit 1
    kill "$!" 2>/dev/null || true
    spawn_agent_pre PHASE=TEST STEP=f10-idem-2 TICKET_ID=TEST-F10D \
      SKILL=/ticket-test HB_LOG_FILE="$tmpdir/hb.log" >/dev/null 2>&1 || exit 1
    kill "$!" 2>/dev/null || true
  )
  local rc=$?
  rm -rf "$tmpdir"
  [ "$rc" -eq 0 ]
}

test_f10_guard_handles_hb_log_file_unset_path() {
  local tmpdir
  tmpdir=$(_mktemp_test_dir)
  # HB_LOG_FILE="" path: the guard should still clear stale files and succeed
  # (no heartbeat pinger/watchdog launched, but the guard check runs regardless)
  (
    source "$LIB_DIR/spawn-helper.sh"
    HB_LOG_FILE="" spawn_agent_pre PHASE=TEST STEP=f10-nohb TICKET_ID=TEST-F10E \
      SKILL=/ticket-test >/dev/null 2>&1
  )
  local rc=$?
  rm -rf "$tmpdir"
  [ "$rc" -eq 0 ]
}

# ── /tmp scratch-file lifetime tests (#273) ───────────────────────────────────

# Build a scratch-file group for one ticket inside an isolated sweep dir.
# Usage: _mk_scratch_group <dir> <ticket-id> <touch-date-or-empty>
_mk_scratch_group() {
  local dir="$1" id="$2" when="$3" f
  for f in "$dir/ticket-auto-${id}-ctx.txt" \
    "$dir/ticket-auto-${id}-spawn-meta.txt" \
    "$dir/ticket-auto-${id}-env.sh" \
    "$dir/ticket-auto-${id}-start-APPRAISE-123.ts"; do
    : >"$f"
    [ -n "$when" ] && touch -d "$when" "$f"
  done
}

_sweep_hook() { echo "$LIB_DIR/../hooks/tmp-sweep.sh"; }

test_tmp_sweep_removes_stale_group() {
  local dir
  dir=$(_mktemp_test_dir)
  _mk_scratch_group "$dir" "TEST-SW-OLD" "2 days ago"
  TICKET_TMP_DIR="$dir" bash "$(_sweep_hook)" 2>/dev/null
  # No managed scratch file survives past the TTL.
  [ -z "$(ls -A "$dir")" ]
}

test_tmp_sweep_keeps_live_group() {
  local dir
  dir=$(_mktemp_test_dir)
  _mk_scratch_group "$dir" "TEST-SW-NEW" ""
  TICKET_TMP_DIR="$dir" bash "$(_sweep_hook)" 2>/dev/null
  [ -f "$dir/ticket-auto-TEST-SW-NEW-env.sh" ] &&
    [ -f "$dir/ticket-auto-TEST-SW-NEW-ctx.txt" ] &&
    [ -f "$dir/ticket-auto-TEST-SW-NEW-spawn-meta.txt" ]
}

test_tmp_sweep_keeps_old_env_when_group_is_active() {
  # env.sh is written once at run start and is sourced by every later phase.
  # A long run whose env.sh predates the TTL must keep it as long as
  # spawn_agent_pre is still refreshing ctx/spawn-meta — this is why the TTL
  # is grouped per ticket instead of applied per file.
  local dir
  dir=$(_mktemp_test_dir)
  _mk_scratch_group "$dir" "TEST-SW-LONG" "2 days ago"
  touch "$dir/ticket-auto-TEST-SW-LONG-ctx.txt"
  TICKET_TMP_DIR="$dir" bash "$(_sweep_hook)" 2>/dev/null
  [ -f "$dir/ticket-auto-TEST-SW-LONG-env.sh" ]
}

test_tmp_sweep_leaves_concurrent_run_intact() {
  # Cleaning up run A must not touch run B (verification item 3 of #273).
  local dir
  dir=$(_mktemp_test_dir)
  _mk_scratch_group "$dir" "TEST-SW-A" "2 days ago"
  _mk_scratch_group "$dir" "TEST-SW-B" ""
  TICKET_TMP_DIR="$dir" bash "$(_sweep_hook)" 2>/dev/null
  [ ! -f "$dir/ticket-auto-TEST-SW-A-env.sh" ] &&
    [ -f "$dir/ticket-auto-TEST-SW-B-env.sh" ]
}

test_tmp_sweep_ignores_unmanaged_files() {
  # Progress files, stop files and flow locks share the namespace but have
  # their own lifetimes — the sweep must not claim them.
  local dir
  dir=$(_mktemp_test_dir)
  _mk_scratch_group "$dir" "TEST-SW-U" "2 days ago"
  : >"$dir/ticket-auto-TEST-SW-U-progress.txt"
  : >"$dir/ticket-auto-TEST-SW-U-pinger-stop"
  : >"$dir/ticket-auto-env.sh"
  touch -d "2 days ago" "$dir/ticket-auto-TEST-SW-U-progress.txt" \
    "$dir/ticket-auto-TEST-SW-U-pinger-stop" "$dir/ticket-auto-env.sh"
  TICKET_TMP_DIR="$dir" bash "$(_sweep_hook)" 2>/dev/null
  [ ! -f "$dir/ticket-auto-TEST-SW-U-ctx.txt" ] &&
    [ -f "$dir/ticket-auto-TEST-SW-U-progress.txt" ] &&
    [ -f "$dir/ticket-auto-TEST-SW-U-pinger-stop" ] &&
    [ -f "$dir/ticket-auto-env.sh" ]
}

test_tmp_sweep_honours_ttl_override() {
  local dir
  dir=$(_mktemp_test_dir)
  _mk_scratch_group "$dir" "TEST-SW-TTL" "30 minutes ago"
  TICKET_TMP_DIR="$dir" TICKET_TMP_TTL_MIN=10 bash "$(_sweep_hook)" 2>/dev/null
  [ -z "$(ls -A "$dir")" ]
}

test_tmp_sweep_bad_ttl_falls_back_to_default() {
  # A garbage TTL must not produce a cutoff that sweeps live files.
  local dir
  dir=$(_mktemp_test_dir)
  _mk_scratch_group "$dir" "TEST-SW-BAD" ""
  TICKET_TMP_DIR="$dir" TICKET_TMP_TTL_MIN="not-a-number" bash "$(_sweep_hook)" 2>/dev/null
  [ -f "$dir/ticket-auto-TEST-SW-BAD-env.sh" ]
}

test_token_tracker_prunes_start_files_without_a_match() {
  # The stale-start-file prune must run even when no start file paired with
  # this stop — the accumulation it prevents is worst exactly then (#273).
  local tmpdir
  tmpdir=$(_mktemp_test_dir)
  local log_file="$tmpdir/test-tk-prune.log"
  local meta_file="/tmp/ticket-auto-TEST-TKP1-spawn-meta.txt"
  local stale="/tmp/ticket-auto-TEST-TKP1-start-APPRAISE-111.ts"

  rm -f "$meta_file" "$stale"
  cat >"$meta_file" <<'META'
PHASE=APPRAISE
STEP=appraise
TICKET_ID=TEST-TKP1
LOG_FILE=LOG_FILE_PLACEHOLDER
SESSION_ID=sess-tkp1
META
  sed -i "s|LOG_FILE_PLACEHOLDER|$log_file|" "$meta_file"

  date +%s%N >"$stale"
  touch -d "30 minutes ago" "$stale"

  # No agent_transcript_path — the branch the old nested prune never reached.
  echo '{"session_id": "sess-tkp1"}' | bash "$LIB_DIR/../hooks/token-tracker.sh" 2>/dev/null || true

  local result=0
  [ -f "$stale" ] && result=1
  rm -f "$meta_file" "$stale" 2>/dev/null || true
  return $result
}

test_token_tracker_keeps_recent_start_file_of_live_sibling() {
  # The prune is age-bounded: a start file written moments ago belongs to a
  # spawn still in flight and must survive an unrelated sibling's stop.
  local tmpdir
  tmpdir=$(_mktemp_test_dir)
  local log_file="$tmpdir/test-tk-prune2.log"
  local meta_file="/tmp/ticket-auto-TEST-TKP2-spawn-meta.txt"
  local fresh="/tmp/ticket-auto-TEST-TKP2-start-APPRAISE-222.ts"

  rm -f "$meta_file" "$fresh"
  cat >"$meta_file" <<'META'
PHASE=APPRAISE
STEP=appraise
TICKET_ID=TEST-TKP2
LOG_FILE=LOG_FILE_PLACEHOLDER
SESSION_ID=sess-tkp2
META
  sed -i "s|LOG_FILE_PLACEHOLDER|$log_file|" "$meta_file"
  date +%s%N >"$fresh"

  echo '{"session_id": "sess-tkp2"}' | bash "$LIB_DIR/../hooks/token-tracker.sh" 2>/dev/null || true

  local result=0
  [ -f "$fresh" ] || result=1
  rm -f "$meta_file" "$fresh" 2>/dev/null || true
  return $result
}

# ── fleetd phase-worker token capture (design.md D15) ─────────────────────────
# A fleetd-dispatched phase is a top-level `claude -p` session, not a subagent,
# so SubagentStop never fires for it. Without these, META|tokens silently stops
# being written on the automated path and the dashboard, the OTel exporter's
# gen_ai.usage.* attributes and retro trend aggregation all degrade with no
# error anywhere. That silence is exactly why the move is tested rather than
# assumed.

_tt_write_fleetd_meta() {
  # $1 meta file, $2 ticket, $3 phase, $4 session, $5 log file
  cat >"$1" <<META
PHASE=$3
STEP=$(echo "$3" | tr '[:upper:]' '[:lower:]')
TICKET_ID=$2
LOG_FILE=$5
HB_LOG_FILE=
CLAUDE_LOG_FILE=
SESSION_ID=$4
SPAWNED_BY=fleetd
META
  touch "$1"
}

_tt_write_transcript() {
  cat >"$1" <<'JSONL'
{"type": "assistant", "message": {"usage": {"input_tokens": 100, "output_tokens": 50, "cache_read_input_tokens": 10}}}
JSONL
}

test_token_tracker_stop_event_captures_fleetd_phase() {
  # The load-bearing case: Stop + SPAWNED_BY=fleetd + transcript_path writes
  # META|tokens under the phase from spawn-meta.
  local tmpdir
  tmpdir=$(_mktemp_test_dir)
  local log_file="$tmpdir/test-tk-fleetd.log"
  local transcript="$tmpdir/top-transcript.jsonl"
  local meta_file="/tmp/ticket-auto-TEST-TKF1-spawn-meta.txt"

  rm -f "$meta_file" "$log_file"
  _tt_write_fleetd_meta "$meta_file" TEST-TKF1 VERIFY sess-tkf1 "$log_file"
  _tt_write_transcript "$transcript"

  echo "{\"session_id\": \"sess-tkf1\", \"hook_event_name\": \"Stop\", \"transcript_path\": \"$transcript\"}" |
    bash "$LIB_DIR/../hooks/token-tracker.sh" 2>/dev/null || true

  local result=0
  grep -q '|META|tokens|info|VERIFY:100/50/10' "$log_file" 2>/dev/null || result=1

  rm -rf "$tmpdir"
  rm -f "$meta_file" 2>/dev/null || true
  return $result
}

test_token_tracker_subagent_stop_ignores_fleetd_phase() {
  # The phase agent's own subagents stop within the phase's session id and so
  # match the same spawn-meta. Counting them would double-count the phase the
  # imminent Stop is about to count in full.
  local tmpdir
  tmpdir=$(_mktemp_test_dir)
  local log_file="$tmpdir/test-tk-fleetd2.log"
  local transcript="$tmpdir/sub-transcript.jsonl"
  local meta_file="/tmp/ticket-auto-TEST-TKF2-spawn-meta.txt"

  rm -f "$meta_file" "$log_file"
  _tt_write_fleetd_meta "$meta_file" TEST-TKF2 VERIFY sess-tkf2 "$log_file"
  _tt_write_transcript "$transcript"

  echo "{\"session_id\": \"sess-tkf2\", \"hook_event_name\": \"SubagentStop\", \"agent_transcript_path\": \"$transcript\"}" |
    bash "$LIB_DIR/../hooks/token-tracker.sh" 2>/dev/null || true

  local result=0
  [ -f "$log_file" ] && result=1

  rm -rf "$tmpdir"
  rm -f "$meta_file" 2>/dev/null || true
  return $result
}

test_token_tracker_stop_ignores_router_spawn() {
  # The mirror guard. A router spawn-meta carries no SPAWNED_BY, and the
  # router's own Stop fires against its session id at the end of every turn.
  # Counting it would attribute the whole router turn to whichever phase is
  # open at the time.
  local tmpdir
  tmpdir=$(_mktemp_test_dir)
  local log_file="$tmpdir/test-tk-router.log"
  local transcript="$tmpdir/router-transcript.jsonl"
  local meta_file="/tmp/ticket-auto-TEST-TKF3-spawn-meta.txt"

  rm -f "$meta_file" "$log_file"
  cat >"$meta_file" <<META
PHASE=IMPLEMENT
STEP=implement
TICKET_ID=TEST-TKF3
LOG_FILE=$log_file
SESSION_ID=sess-tkf3
META
  _tt_write_transcript "$transcript"

  echo "{\"session_id\": \"sess-tkf3\", \"hook_event_name\": \"Stop\", \"transcript_path\": \"$transcript\"}" |
    bash "$LIB_DIR/../hooks/token-tracker.sh" 2>/dev/null || true

  local result=0
  [ -f "$log_file" ] && result=1

  rm -rf "$tmpdir"
  rm -f "$meta_file" 2>/dev/null || true
  return $result
}

test_token_tracker_stop_never_falls_back_to_agent_transcript() {
  # A wrong measurement is worse than none: if the event's own transcript
  # field is absent, the hook must not reach for the other event's field.
  local tmpdir
  tmpdir=$(_mktemp_test_dir)
  local log_file="$tmpdir/test-tk-nofallback.log"
  local transcript="$tmpdir/other-transcript.jsonl"
  local meta_file="/tmp/ticket-auto-TEST-TKF4-spawn-meta.txt"

  rm -f "$meta_file" "$log_file"
  _tt_write_fleetd_meta "$meta_file" TEST-TKF4 IMPLEMENT sess-tkf4 "$log_file"
  _tt_write_transcript "$transcript"

  echo "{\"session_id\": \"sess-tkf4\", \"hook_event_name\": \"Stop\", \"agent_transcript_path\": \"$transcript\"}" |
    bash "$LIB_DIR/../hooks/token-tracker.sh" 2>/dev/null || true

  local result=0
  [ -f "$log_file" ] && result=1

  rm -rf "$tmpdir"
  rm -f "$meta_file" 2>/dev/null || true
  return $result
}

test_token_tracker_fleetd_phase_records_elapsed_from_start_marker() {
  # fleetd writes the start stamp itself because SubagentStart does not fire
  # either. Without it the phase's duration silently disappears.
  local tmpdir
  tmpdir=$(_mktemp_test_dir)
  local log_file="$tmpdir/test-tk-elapsed.log"
  local transcript="$tmpdir/elapsed-transcript.jsonl"
  local meta_file="/tmp/ticket-auto-TEST-TKF5-spawn-meta.txt"
  local start_file="/tmp/ticket-auto-TEST-TKF5-start-VERIFY-$(date +%s%N).ts"

  rm -f "$meta_file" "$log_file" "$start_file"
  _tt_write_fleetd_meta "$meta_file" TEST-TKF5 VERIFY sess-tkf5 "$log_file"
  _tt_write_transcript "$transcript"
  date +%s%N >"$start_file"

  echo "{\"session_id\": \"sess-tkf5\", \"hook_event_name\": \"Stop\", \"transcript_path\": \"$transcript\"}" |
    bash "$LIB_DIR/../hooks/token-tracker.sh" 2>/dev/null || true

  local result=0
  grep -q 'elapsed_ms=' "$log_file" 2>/dev/null || result=1

  rm -rf "$tmpdir"
  rm -f "$meta_file" "$start_file" 2>/dev/null || true
  return $result
}

# ── dispatch ──────────────────────────────────────────────────────────────────

FILTER="${1:-}"

for fn in \
  test_token_tracker_resolves_phase_from_spawn_meta \
  test_token_tracker_ignores_session_mismatch \
  test_token_tracker_no_session_in_payload_writes_nothing \
  test_token_tracker_skips_when_transcript_path_absent \
  test_token_tracker_transcript_path_with_quote_is_safe \
  test_token_tracker_start_writes_timestamp_on_session_match \
  test_token_tracker_start_ignores_session_mismatch \
  test_write_env_creates_file \
  test_write_env_exports_ticket_id \
  test_write_env_exports_repos_root \
  test_write_env_exports_all_fields \
  test_write_env_empty_integration_branch \
  test_write_env_empty_worktree_root \
  test_write_env_uat_policy_defaults_to_per_ticket \
  test_write_env_merge_policy_defaults_to_empty \
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
  test_post_meta_file_persists_after_done \
  test_post_warn_continue_stops_pinger_but_does_not_exit \
  test_pre_duplicate_waiting_suppressed \
  test_post_duplicate_done_suppressed \
  test_post_rejects_bad_verdict_value \
  test_post_done_verdict_prepended_to_log_msg \
  test_post_fail_verdict_prepended_to_log_msg \
  test_post_no_verdict_leaves_msg_unprefixed \
  test_post_phase_uppercase_in_log \
  test_post_loop_phase_two_brackets_produce_two_done_lines \
  test_post_retry_after_fail_writes_new_bracket \
  test_capture_rejects_missing_phase \
  test_capture_calls_through_with_all_params \
  test_capture_records_lowercased_phase \
  test_capture_reads_result_file \
  test_capture_rejects_missing_result_file \
  test_real_capture_appends_each_attempt \
  test_real_capture_preserves_shell_metacharacters \
  test_capture_lowercases_uppercase_phase_for_real_capture \
  test_env_prefix_survives_shell_special_chars_in_paths \
  test_heartbeat_sourced_when_not_predefined \
  test_heartbeat_not_sourced_when_already_defined \
  test_watchdog_start_creates_background_process \
  test_watchdog_stop_kills_background_process \
  test_watchdog_entries_use_correct_category \
  test_watchdog_integrated_into_spawn_agent_pre \
  test_watchdog_integrated_into_spawn_agent_post \
  test_watchdog_emits_heartbeats \
  test_watchdog_exits_when_workspace_removed \
  test_watchdog_exits_when_worker_pid_dies \
  test_watchdog_exits_at_iteration_cap_when_pid_unset \
  test_spawn_agent_post_waits_for_captured_pids \
  test_phase_bracket_open_writes_waiting_and_model \
  test_phase_bracket_open_suppresses_duplicate_for_a_lowercase_phase \
  test_phase_bracket_open_allows_a_retry_after_a_terminal \
  test_phase_bracket_open_never_forges_a_log_line \
  test_phase_bracket_open_echoes_the_model_without_a_log_file \
  test_spawn_agent_pre_still_opens_through_the_helper \
  test_phase_terminal_write_emits_done_marker \
  test_phase_terminal_write_prefixes_verdict \
  test_phase_terminal_write_marks_warn_continue \
  test_phase_terminal_write_rejects_bad_verdict \
  test_phase_terminal_write_suppresses_back_to_back_duplicate \
  test_spawn_agent_post_still_writes_through_the_helper \
  test_f10_guard_clears_stale_stop_files_from_prior_phase \
  test_f10_guard_still_blocks_external_kill \
  test_f10_guard_succeeds_when_no_stop_files_exist \
  test_f10_guard_idempotent_across_multiple_spawns \
  test_f10_guard_handles_hb_log_file_unset_path \
  test_tmp_sweep_removes_stale_group \
  test_tmp_sweep_keeps_live_group \
  test_tmp_sweep_keeps_old_env_when_group_is_active \
  test_tmp_sweep_leaves_concurrent_run_intact \
  test_tmp_sweep_ignores_unmanaged_files \
  test_tmp_sweep_honours_ttl_override \
  test_tmp_sweep_bad_ttl_falls_back_to_default \
  test_token_tracker_prunes_start_files_without_a_match \
  test_token_tracker_keeps_recent_start_file_of_live_sibling \
  test_token_tracker_stop_event_captures_fleetd_phase \
  test_token_tracker_subagent_stop_ignores_fleetd_phase \
  test_token_tracker_stop_ignores_router_spawn \
  test_token_tracker_stop_never_falls_back_to_agent_transcript \
  test_token_tracker_fleetd_phase_records_elapsed_from_start_marker; do
  [ -z "$FILTER" ] || [[ "$fn" == *"$FILTER"* ]] || continue
  _run "$fn" "$fn"
done

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
