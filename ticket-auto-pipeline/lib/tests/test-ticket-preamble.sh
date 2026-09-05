#!/usr/bin/env bash
# test-ticket-preamble.sh — tests for lib/ticket-preamble.sh (task 4.10).
#
# The preamble's whole job is establishing an environment nothing else builds,
# so the assertions are about what exists afterwards — env file, schema line,
# branch-context line — and about the two properties fleetd actually depends
# on: re-entry is idempotent, and a recorded branch decision is never
# re-resolved.
#
# Linear is never called: preflight is skipped and branch resolution is
# stubbed, because the interesting behaviour here is the ordering and the
# guards, not the API clients those already have tests for.
# -u (nounset) intentionally omitted — see test-detect-resume.sh.
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PREAMBLE_SH="$LIB_DIR/ticket-preamble.sh"

PASS=0
FAIL=0

_run() {
  local name="$1"
  shift
  if "$@"; then
    echo "PASS: $name"
    ((PASS++)) || true
  else
    echo "FAIL: $name"
    ((FAIL++)) || true
  fi
}

_field() {
  local block="$1" field="$2"
  echo "$block" | grep "^  ${field}:" | sed -E "s/^  ${field}: *//"
}

# Run the preamble inside a throwaway project dir, with branch-resolve.sh
# stubbed by a shim on PATH-equivalent terms: the stub is a file the preamble
# sources by name, so it is installed into a copied lib dir.
#
# Echoes the TICKET_PREAMBLE_RESULT block; leaves the sandbox at $_SANDBOX for
# the caller to inspect, and it is the caller's to remove.
_preamble() {
  local ticket_id="$1"
  shift
  (cd "$_SANDBOX" && bash "$_SANDBOX/lib/ticket-preamble.sh" \
    TICKET_ID="$ticket_id" PROJECT_DIR="$_SANDBOX" SKIP_PREFLIGHT=true "$@")
}

# Build a sandbox: a copy of lib/ with branch-resolve.sh replaced by a stub
# that records every call, so "was it called again?" is an assertable fact.
_sandbox_new() {
  _SANDBOX="$(mktemp -d)"
  mkdir -p "$_SANDBOX/lib" "$_SANDBOX/logs"
  cp "$LIB_DIR"/*.sh "$_SANDBOX/lib/"

  cat >"$_SANDBOX/lib/branch-resolve.sh" <<'STUB'
#!/usr/bin/env bash
resolve_branch_context() {
  echo "$*" >>"${BRANCH_RESOLVE_CALLS:-/dev/null}"
  if [ -n "${BRANCH_RESOLVE_FAIL:-}" ]; then
    echo "$BRANCH_RESOLVE_FAIL" >&2
    return 1
  fi
  cat <<'BLOCK'
BRANCH_CONTEXT_RESULT:
  TICKET_BRANCH: feat/test-1
  BASE_BRANCH: develop
  INTEGRATION_BRANCH: epic/thing
  BRANCH_SOURCE: epic-directive
  UAT_POLICY: epic
  MERGE_POLICY: auto
BLOCK
}
STUB

  export BRANCH_RESOLVE_CALLS="$_SANDBOX/branch-calls.txt"
  : >"$BRANCH_RESOLVE_CALLS"
  unset BRANCH_RESOLVE_FAIL
}

_sandbox_rm() {
  [ -n "$_SANDBOX" ] && rm -rf "$_SANDBOX"
  rm -f /tmp/ticket-auto-TEST-PRE*-env.sh
  _SANDBOX=""
}

# ── The environment the preamble is responsible for ───────────────────────────

test_writes_env_file_log_and_branch_context() {
  _sandbox_new
  local out rc=0
  out=$(_preamble TEST-PRE-1 AUTONOMY=auto) || rc=$?
  local log="$_SANDBOX/logs/TEST-PRE-1-pipeline.log"

  [ "$rc" -eq 0 ] &&
    [ -f /tmp/ticket-auto-TEST-PRE-1-env.sh ] &&
    grep -q '^[^|]*|META|schema|info|1$' "$log" &&
    grep -q '|META|branch-context|info|base=develop;integration=epic/thing;source=epic-directive;ticket=feat/test-1;uat-policy=epic;merge-policy=auto$' "$log" &&
    grep -q '|META|autonomy|info|auto$' "$log" &&
    grep -q '|META|from-planned|info|false$' "$log" &&
    [ "$(_field "$out" BRANCH_ORIGIN)" = "resolved" ] &&
    [ "$(_field "$out" INTEGRATION_BRANCH)" = "epic/thing" ]
  local ok=$?
  _sandbox_rm
  return $ok
}

# The schema line must be the log's first line. If a gate-stop lands in an
# empty log first, detect-resume.sh reads the file as a v0 log and applies
# grace — silently, and with the gate-stop no longer first in the cascade.
test_schema_line_precedes_a_branch_gate_stop() {
  _sandbox_new
  export BRANCH_RESOLVE_FAIL="BRANCH_DIRECTIVE_INVALID: malformed"
  local rc=0
  _preamble TEST-PRE-2 >/dev/null 2>&1 || rc=$?
  unset BRANCH_RESOLVE_FAIL
  local log="$_SANDBOX/logs/TEST-PRE-2-pipeline.log"

  [ "$rc" -eq 2 ] &&
    head -1 "$log" | grep -q '|META|schema|info|1$' &&
    grep -q '|META|gate-stop|fail|BRANCH_DIRECTIVE_INVALID$' "$log"
  local ok=$?
  _sandbox_rm
  return $ok
}

# A branch resolution that fails for a non-directive reason is not a gate-stop:
# an API blip must not be recorded as a malformed directive, which is an
# operator-fix-it state a retry can never clear.
test_non_directive_branch_failure_is_not_a_gate_stop() {
  _sandbox_new
  export BRANCH_RESOLVE_FAIL="linear-api: 502 Bad Gateway"
  local rc=0
  _preamble TEST-PRE-3 >/dev/null 2>&1 || rc=$?
  unset BRANCH_RESOLVE_FAIL

  [ "$rc" -eq 3 ] &&
    ! grep -q 'gate-stop' "$_SANDBOX/logs/TEST-PRE-3-pipeline.log"
  local ok=$?
  _sandbox_rm
  return $ok
}

# ── Re-entry after a fleetd restart ───────────────────────────────────────────

test_reentry_rehydrates_and_does_not_re_resolve() {
  _sandbox_new
  _preamble TEST-PRE-4 >/dev/null
  local first_calls
  first_calls=$(wc -l <"$BRANCH_RESOLVE_CALLS")

  local out
  out=$(_preamble TEST-PRE-4)
  local second_calls
  second_calls=$(wc -l <"$BRANCH_RESOLVE_CALLS")

  [ "$first_calls" -eq 1 ] && [ "$second_calls" -eq 1 ] &&
    [ "$(_field "$out" BRANCH_ORIGIN)" = "rehydrated" ] &&
    [ "$(_field "$out" BASE_BRANCH)" = "develop" ] &&
    [ "$(_field "$out" MERGE_POLICY)" = "auto" ]
  local ok=$?
  _sandbox_rm
  return $ok
}

test_reentry_appends_no_duplicate_meta_lines() {
  _sandbox_new
  _preamble TEST-PRE-5 AUTONOMY=auto >/dev/null
  _preamble TEST-PRE-5 AUTONOMY=auto >/dev/null
  _preamble TEST-PRE-5 AUTONOMY=auto >/dev/null
  local log="$_SANDBOX/logs/TEST-PRE-5-pipeline.log"
  local hb="$_SANDBOX/logs/TEST-PRE-5-heartbeat.log"

  [ "$(grep -c '|META|schema|info|' "$log")" -eq 1 ] &&
    [ "$(grep -c '|META|branch-context|' "$log")" -eq 1 ] &&
    [ "$(grep -c '|META|autonomy|' "$log")" -eq 1 ] &&
    [ "$(grep -c '|META|from-planned|' "$log")" -eq 1 ] &&
    [ "$(grep -c '|heartbeat|pipeline-start|' "$hb")" -eq 1 ]
  local ok=$?
  _sandbox_rm
  return $ok
}

# An autonomy that differs from the recorded one is a logged change, never a
# silent overwrite: gate decisions already taken under the old mode have to
# stay explicable.
test_autonomy_change_is_logged_not_overwritten() {
  _sandbox_new
  _preamble TEST-PRE-6 AUTONOMY=manual >/dev/null
  _preamble TEST-PRE-6 AUTONOMY=auto >/dev/null
  local log="$_SANDBOX/logs/TEST-PRE-6-pipeline.log"

  grep -q '|META|autonomy|info|manual$' "$log" &&
    grep -q '|META|mode-change|warn|auto (was manual)$' "$log"
  local ok=$?
  _sandbox_rm
  return $ok
}

# The env file is rewritten on a rehydrated entry too — a tmp sweep can remove
# it between two phases of one ticket, and the next phase would source
# nothing (the preamble in skill-preamble-auto.md sources it with `|| true`,
# so its absence is silent).
test_reentry_repairs_a_swept_env_file() {
  _sandbox_new
  _preamble TEST-PRE-7 >/dev/null
  rm -f /tmp/ticket-auto-TEST-PRE-7-env.sh
  _preamble TEST-PRE-7 >/dev/null

  [ -f /tmp/ticket-auto-TEST-PRE-7-env.sh ] &&
    grep -q 'export BASE_BRANCH="develop"' /tmp/ticket-auto-TEST-PRE-7-env.sh &&
    grep -q 'export UAT_POLICY="epic"' /tmp/ticket-auto-TEST-PRE-7-env.sh
  local ok=$?
  _sandbox_rm
  return $ok
}

# ── Project context extraction ────────────────────────────────────────────────

test_context_reads_claude_md_and_env_wins() {
  local tmp
  tmp="$(mktemp -d)"
  cat >"$tmp/CLAUDE.md" <<'MD'
# Project

`REPOS_ROOT` = `/repos/from/md`
ISSUE_PREFIX: CRE
`BE_TEST_CMD` = `mvn -q test`
MD

  local out
  out=$(REPOS_ROOT=/repos/from/env bash -c \
    "source '$PREAMBLE_SH'; ticket_preamble_project_context '$tmp'")

  echo "$out" | grep -qx 'REPOS_ROOT=/repos/from/env' &&
    echo "$out" | grep -qx 'ISSUE_PREFIX=CRE' &&
    echo "$out" | grep -qx 'BE_TEST_CMD=mvn -q test' &&
    echo "$out" | grep -qx 'WIKI_ROOT='
  local ok=$?
  rm -rf "$tmp"
  return $ok
}

# Every field is emitted even when nothing declares it, so the caller reads a
# fixed field set rather than distinguishing "absent" from "empty".
test_context_emits_every_field_for_a_bare_project() {
  local tmp out
  tmp="$(mktemp -d)"
  out=$(env -u REPOS_ROOT -u ISSUE_PREFIX -u BE_SERVICES -u WIKI_ROOT \
    -u BE_TEST_CMD -u BE_TEST_RUNNER -u FE_TEST_CMD -u LOCAL_URL \
    -u UAT_URL -u SLACK_CHANNEL \
    bash -c "source '$PREAMBLE_SH'; ticket_preamble_project_context '$tmp'")
  [ "$(echo "$out" | wc -l)" -eq 10 ] && ! echo "$out" | grep -qv '=$'
  local ok=$?
  rm -rf "$tmp"
  return $ok
}

# ── Argument handling ─────────────────────────────────────────────────────────

# Both usage errors exit 1, and 1 is deliberately not the gate-stop code: a
# caller's typo must never be recorded on a ticket as a malformed directive.
test_missing_ticket_id_fails_with_the_usage_code() {
  local rc=0
  bash "$PREAMBLE_SH" SKIP_PREFLIGHT=true >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 1 ]
}

test_unknown_parameter_fails_with_the_usage_code() {
  local rc=0
  bash "$PREAMBLE_SH" TICKET_ID=X NONSENSE=1 >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 1 ]
}

test_unrecognised_autonomy_falls_back_to_manual() {
  _sandbox_new
  local out
  out=$(_preamble TEST-PRE-8 AUTONOMY=turbo 2>/dev/null)
  [ "$(_field "$out" AUTONOMY)" = "manual" ]
  local ok=$?
  _sandbox_rm
  return $ok
}

# ── Run identity (Branch A) ───────────────────────────────────────────────────

# fleetd re-enters the preamble once per phase; run_identity_stamp's own
# open-run guard is what keeps two calls within one run down to one line —
# the preamble does not call it any differently the second time.
test_two_preamble_calls_in_one_run_write_one_run_id_line() {
  _sandbox_new
  _preamble TEST-PRE-9 >/dev/null
  _preamble TEST-PRE-9 >/dev/null
  local log="$_SANDBOX/logs/TEST-PRE-9-pipeline.log"
  [ "$(grep -c '|META|run-id|info|' "$log")" -eq 1 ]
  local ok=$?
  _sandbox_rm
  return $ok
}

test_preamble_starts_a_new_run_after_an_outcome() {
  _sandbox_new
  _preamble TEST-PRE-10 >/dev/null
  local log="$_SANDBOX/logs/TEST-PRE-10-pipeline.log"
  echo '2026-01-01T00:00:00Z|META|outcome|info|{"status":"done"}' >>"$log"
  _preamble TEST-PRE-10 >/dev/null
  [ "$(grep -c '|META|run-id|info|' "$log")" -eq 2 ]
  local ok=$?
  _sandbox_rm
  return $ok
}

_run "writes env file, log and branch context" test_writes_env_file_log_and_branch_context
_run "schema line precedes a branch gate-stop" test_schema_line_precedes_a_branch_gate_stop
_run "non-directive branch failure is not a gate-stop" test_non_directive_branch_failure_is_not_a_gate_stop
_run "re-entry rehydrates and does not re-resolve" test_reentry_rehydrates_and_does_not_re_resolve
_run "re-entry appends no duplicate META lines" test_reentry_appends_no_duplicate_meta_lines
_run "autonomy change is logged not overwritten" test_autonomy_change_is_logged_not_overwritten
_run "re-entry repairs a swept env file" test_reentry_repairs_a_swept_env_file
_run "context reads CLAUDE.md and env wins" test_context_reads_claude_md_and_env_wins
_run "context emits every field for a bare project" test_context_emits_every_field_for_a_bare_project
_run "missing TICKET_ID fails with the usage code" test_missing_ticket_id_fails_with_the_usage_code
_run "unknown parameter fails with the usage code" test_unknown_parameter_fails_with_the_usage_code
_run "unrecognised autonomy falls back to manual" test_unrecognised_autonomy_falls_back_to_manual
_run "two preamble calls in one run write one run-id line" test_two_preamble_calls_in_one_run_write_one_run_id_line
_run "preamble starts a new run after an outcome" test_preamble_starts_a_new_run_after_an_outcome

echo ""
echo "ticket-preamble: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
