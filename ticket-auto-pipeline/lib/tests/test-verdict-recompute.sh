#!/usr/bin/env bash
# test-verdict-recompute.sh — unit tests for lib/verdict-recompute.sh
# Usage: bash test-verdict-recompute.sh [test_name_filter]
set -eo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$TEST_DIR/.." && pwd)"
SCRIPT="$LIB_DIR/verdict-recompute.sh"

PASS=0
FAIL=0

_run() {
  local name="$1"
  shift
  set +e
  "$@"
  local rc=$?
  set -e
  if [ $rc -eq 0 ]; then
    echo "PASS: $name"
    ((PASS++)) || true
  else
    echo "FAIL: $name  (exit $rc)"
    ((FAIL++)) || true
  fi
}

# ── declare-guard stubs ───────────────────────────────────────────────────────
# SessionStart hooks don't run in CI, so heartbeat.sh / verifier-result.sh
# helpers are absent there and present locally. Define no-ops only when the
# real ones are not already loaded, so the suite behaves identically in both
# environments.
declare -F hb_heartbeat >/dev/null 2>&1 || hb_heartbeat() { return 0; }
declare -F hb_gate >/dev/null 2>&1 || hb_gate() { return 0; }
declare -F write_verifier_result >/dev/null 2>&1 || write_verifier_result() { return 0; }

# ── fixtures ──────────────────────────────────────────────────────────────────

_ws=""

_setup() {
  _ws=$(mktemp -d)
  mkdir -p "$_ws/ticket"
}

_teardown() {
  [ -n "$_ws" ] && rm -rf "$_ws"
  _ws=""
}

_claim_block() {
  local verdict="${1:-PASS}" met="${2:-3}" total="${3:-3}" attempt="${4:-1}"
  cat <<EOF
=== PHASE_RESULT ===
SCHEMA_VERSION: 1
PHASE: VERIFY
VERIFIER: playwright_uat
VERDICT: ${verdict}
CRITERIA_MET: ${met}
CRITERIA_TOTAL: ${total}
ATTEMPT: ${attempt}
EVIDENCE: exercised AC1-3
UNADDRESSED:
=== END PHASE_RESULT ===
EOF
}

# _write_session <checked> <unchecked> — writes verify-session.md's Step trace
# section with the given counts of [x]/[ ] lines.
_write_session() {
  local checked="$1" unchecked="$2"
  {
    echo "# verify session — TEST-1"
    echo "**Verdict:** PASS"
    echo ""
    echo "## Step trace"
    local i
    for ((i = 0; i < checked; i++)); do echo "- [x] Step ${i}: done"; done
    for ((i = 0; i < unchecked; i++)); do echo "- [ ] Step ${i}: pending"; done
  } >"$_ws/ticket/verify-session.md"
}

# _write_bracket <iso> — writes the phase-start waiting line to pipeline.log
_write_bracket() {
  echo "${1}|VERIFY|verify|waiting|Agent launched" >"$_ws/pipeline.log"
}

# _recompute <return-file-content-fn> [extra args...] — runs the CLI
_OUT=""
_ERR=""
_RC=0
_recompute() {
  local extra_args=("$@")
  set +e
  _OUT=$(bash "$SCRIPT" --phase VERIFY --return-file "$_ws/ret.txt" \
    --ticket-dir "$_ws/ticket" "${extra_args[@]}" 2>"$_ws/stderr.txt")
  _RC=$?
  set -e
  _ERR=$(cat "$_ws/stderr.txt")
}

_json() { printf '%s' "$_OUT" | jq -r "$1" 2>/dev/null; }

# ── evidence-state scenarios (tasks.md 2.2) ────────────────────────────────────

test_missing_evidence_file() {
  _setup
  _claim_block PASS 3 3 >"$_ws/ret.txt"
  _recompute --log-file "$_ws/pipeline.log"
  local ok=1
  [ "$_RC" -eq 1 ] &&
    [ "$(_json .evidence_state)" = "missing" ] &&
    [ "$(_json .verified_met)" = "0" ] && ok=0
  _teardown
  return "$ok"
}

test_stale_evidence() {
  _setup
  _claim_block PASS 3 3 >"$_ws/ret.txt"
  _write_bracket "2099-01-01T00:00:00Z"
  _write_session 3 0
  # The evidence file's mtime is "now" (2026), which predates the phase-start
  # bracket dated far in the future — simulating a leftover file from an
  # earlier attempt without needing real sleeps.
  _recompute --log-file "$_ws/pipeline.log"
  local ok=1
  [ "$_RC" -eq 1 ] &&
    [ "$(_json .evidence_state)" = "stale" ] &&
    [ "$(_json .verified_met)" = "0" ] && ok=0
  _teardown
  return "$ok"
}

test_fresh_evidence_is_counted() {
  _setup
  _claim_block PASS 3 3 >"$_ws/ret.txt"
  _write_bracket "2020-01-01T00:00:00Z"
  _write_session 3 0
  _recompute --log-file "$_ws/pipeline.log"
  local ok=1
  [ "$_RC" -eq 0 ] &&
    [ "$(_json .evidence_state)" = "fresh" ] &&
    [ "$(_json .verified_met)" = "3" ] && ok=0
  _teardown
  return "$ok"
}

test_evidence_state_unverified_without_log_file() {
  _setup
  _claim_block PASS 3 3 >"$_ws/ret.txt"
  _write_session 3 0
  _recompute
  local ok=1
  [ "$_RC" -eq 0 ] &&
    [ "$(_json .evidence_state)" = "fresh-unverified-phase-start" ] &&
    [ "$(_json .verified_met)" = "3" ] && ok=0
  _teardown
  return "$ok"
}

# ── direction scenarios ────────────────────────────────────────────────────────

test_aligned_pass() {
  _setup
  _claim_block PASS 3 3 >"$_ws/ret.txt"
  _write_bracket "2020-01-01T00:00:00Z"
  _write_session 3 0
  _recompute --log-file "$_ws/pipeline.log"
  local ok=1
  [ "$_RC" -eq 0 ] &&
    [ "$(_json .direction)" = "aligned" ] &&
    [ "$(_json .verified_verdict)" = "PASS" ] &&
    [ "$(_json .delta)" = "0" ] && ok=0
  _teardown
  return "$ok"
}

test_aligned_fail() {
  _setup
  _claim_block FAIL 1 3 >"$_ws/ret.txt"
  _write_bracket "2020-01-01T00:00:00Z"
  _write_session 1 2
  _recompute --log-file "$_ws/pipeline.log"
  local ok=1
  [ "$_RC" -eq 0 ] &&
    [ "$(_json .direction)" = "aligned" ] &&
    [ "$(_json .verified_verdict)" = "FAIL" ] && ok=0
  _teardown
  return "$ok"
}

test_optimistic_claim() {
  _setup
  _claim_block PASS 3 3 >"$_ws/ret.txt"
  _write_bracket "2020-01-01T00:00:00Z"
  _write_session 2 1
  _recompute --log-file "$_ws/pipeline.log"
  local ok=1
  [ "$_RC" -eq 1 ] &&
    [ "$(_json .direction)" = "optimistic" ] &&
    [ "$(_json .claimed_verdict)" = "PASS" ] &&
    [ "$(_json .verified_verdict)" = "FAIL" ] &&
    [ "$(_json .delta)" = "1" ] && ok=0
  _teardown
  return "$ok"
}

test_pessimistic_claim() {
  _setup
  _claim_block FAIL 2 3 >"$_ws/ret.txt"
  _write_bracket "2020-01-01T00:00:00Z"
  _write_session 3 0
  _recompute --log-file "$_ws/pipeline.log"
  local ok=1
  [ "$_RC" -eq 1 ] &&
    [ "$(_json .direction)" = "pessimistic" ] &&
    [ "$(_json .claimed_verdict)" = "FAIL" ] &&
    [ "$(_json .verified_verdict)" = "PASS" ] && ok=0
  _teardown
  return "$ok"
}

test_unknown_claim_still_records() {
  _setup
  echo "no phase result block in this return" >"$_ws/ret.txt"
  _write_bracket "2020-01-01T00:00:00Z"
  _write_session 3 0
  _recompute --log-file "$_ws/pipeline.log"
  local ok=1
  [ "$_RC" -eq 1 ] &&
    [ "$(_json .claimed_verdict)" = "UNKNOWN" ] &&
    [ "$(_json .direction)" = "unknown" ] &&
    [ "$(_json .verified_verdict)" = "PASS" ] && ok=0
  _teardown
  return "$ok"
}

# ── log behaviour ──────────────────────────────────────────────────────────────

test_appends_meta_claim_delta_to_log() {
  _setup
  _claim_block PASS 3 3 >"$_ws/ret.txt"
  _write_bracket "2020-01-01T00:00:00Z"
  _write_session 3 0
  _recompute --log-file "$_ws/pipeline.log"
  local ok=1
  command grep -q '|META|claim-delta|info|{' "$_ws/pipeline.log" && ok=0
  _teardown
  return "$ok"
}

test_unwritable_log_degrades_without_failing() {
  _setup
  _claim_block PASS 3 3 >"$_ws/ret.txt"
  _write_session 3 0
  _recompute --log-file "$_ws/does-not-exist/pipeline.log"
  local ok=1
  # The phase-start lookup fails softly (no such log), and the append also
  # fails softly — the recomputation itself still succeeds and emits on stdout.
  [ "$_RC" -eq 0 ] && [ -n "$(_json .direction)" ] && ok=0
  _teardown
  return "$ok"
}

test_no_log_file_still_emits_on_stdout() {
  _setup
  _claim_block PASS 3 3 >"$_ws/ret.txt"
  _write_session 3 0
  _recompute
  local ok=1
  [ "$_RC" -eq 0 ] && [ -n "$(_json .direction)" ] && ok=0
  _teardown
  return "$ok"
}

# ── standalone invocation (tasks.md 2.3) ────────────────────────────────────────

test_standalone_invocation_no_router_env() {
  _setup
  _claim_block PASS 3 3 >"$_ws/ret.txt"
  _write_bracket "2020-01-01T00:00:00Z"
  _write_session 3 0
  # No LOG_FILE env var set, only explicit --log-file — this must work
  # identically to a router invocation that relies on the env var.
  (
    unset LOG_FILE
    _recompute --log-file "$_ws/pipeline.log"
  )
  local ok=1
  [ "$_RC" -eq 0 ] && [ "$(_json .direction)" = "aligned" ] && ok=0
  _teardown
  return "$ok"
}

test_sourceable_as_a_lib() {
  _setup
  _claim_block PASS 3 3 >"$_ws/ret.txt"
  _write_bracket "2020-01-01T00:00:00Z"
  _write_session 3 0
  local ok=1
  (
    source "$SCRIPT"
    out=$(verdict_recompute --phase VERIFY --return-file "$_ws/ret.txt" \
      --ticket-dir "$_ws/ticket" --log-file "$_ws/pipeline.log")
    [ "$(printf '%s' "$out" | jq -r .direction)" = "aligned" ]
  ) && ok=0
  _teardown
  return "$ok"
}

# ── errors ─────────────────────────────────────────────────────────────────────

test_missing_required_args_exits_2() {
  _setup
  set +e
  bash "$SCRIPT" --phase VERIFY 2>/dev/null
  local rc=$?
  set -e
  _teardown
  [ "$rc" -eq 2 ]
}

test_non_verify_phase_exits_2() {
  _setup
  _claim_block PASS 3 3 >"$_ws/ret.txt"
  set +e
  bash "$SCRIPT" --phase IMPLEMENT --return-file "$_ws/ret.txt" --ticket-dir "$_ws/ticket" 2>/dev/null
  local rc=$?
  set -e
  _teardown
  [ "$rc" -eq 2 ]
}

test_missing_ticket_dir_exits_2() {
  _setup
  _claim_block PASS 3 3 >"$_ws/ret.txt"
  set +e
  bash "$SCRIPT" --phase VERIFY --return-file "$_ws/ret.txt" --ticket-dir "$_ws/does-not-exist" 2>/dev/null
  local rc=$?
  set -e
  _teardown
  [ "$rc" -eq 2 ]
}

# ── main ─────────────────────────────────────────────────────────────────────

TESTS=(
  test_missing_evidence_file
  test_stale_evidence
  test_fresh_evidence_is_counted
  test_evidence_state_unverified_without_log_file
  test_aligned_pass
  test_aligned_fail
  test_optimistic_claim
  test_pessimistic_claim
  test_unknown_claim_still_records
  test_appends_meta_claim_delta_to_log
  test_unwritable_log_degrades_without_failing
  test_no_log_file_still_emits_on_stdout
  test_standalone_invocation_no_router_env
  test_sourceable_as_a_lib
  test_missing_required_args_exits_2
  test_non_verify_phase_exits_2
  test_missing_ticket_dir_exits_2
)

FILTER="${1:-}"
for t in "${TESTS[@]}"; do
  if [ -n "$FILTER" ] && [[ "$t" != *"$FILTER"* ]]; then
    continue
  fi
  _run "$t" "$t"
done

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
