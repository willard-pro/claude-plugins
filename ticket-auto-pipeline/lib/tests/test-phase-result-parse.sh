#!/usr/bin/env bash
# test-phase-result-parse.sh — unit tests for lib/phase-result-parse.sh
# Usage: bash test-phase-result-parse.sh [test_name_filter]
set -eo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$TEST_DIR/.." && pwd)"
PARSER="$LIB_DIR/phase-result-parse.sh"

PASS=0
FAIL=0

_run() {
  local name="$1"
  shift
  # Toggle -e off to capture test function return values correctly.
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
# SessionStart hooks don't run in CI, so heartbeat.sh / linear-api.sh helpers are
# absent there and present locally. Define no-ops only when the real ones are not
# already loaded, so the suite behaves identically in both environments.
declare -F hb_heartbeat >/dev/null 2>&1 || hb_heartbeat() { return 0; }
declare -F hb_gate >/dev/null 2>&1 || hb_gate() { return 0; }

# ── fixtures ──────────────────────────────────────────────────────────────────

_ws=""

_setup() {
  _ws=$(mktemp -d)
}

_teardown() {
  [ -n "$_ws" ] && rm -rf "$_ws"
  _ws=""
}

# _write_ret <filename> — body on stdin
_write_ret() {
  cat >"$_ws/$1"
}

# _parse <phase> <file> [extra args...] — runs the CLI, captures stdout/stderr/rc
_OUT=""
_ERR=""
_RC=0
_parse() {
  local phase="$1" file="$2"
  shift 2
  set +e
  _OUT=$(bash "$PARSER" --phase "$phase" --return-file "$_ws/$file" \
    --log-file "$_ws/pipeline.log" "$@" 2>"$_ws/stderr.txt")
  _RC=$?
  set -e
  _ERR=$(cat "$_ws/stderr.txt")
}

_json() { printf '%s' "$_OUT" | jq -r "$1" 2>/dev/null; }

_canonical_block() {
  cat <<'EOF'
=== PHASE_RESULT ===
SCHEMA_VERSION: 1
PHASE: VERIFY
VERIFIER: playwright_uat
VERDICT: PASS
CRITERIA_MET: 3
CRITERIA_TOTAL: 3
ATTEMPT: 1
EVIDENCE: exercised AC1-AC3 against UAT
UNADDRESSED:
=== END PHASE_RESULT ===
EOF
}

# ── 4.2 success cases ─────────────────────────────────────────────────────────

test_canonical_block() {
  _setup
  _canonical_block | _write_ret ret.txt
  _parse VERIFY ret.txt
  local ok=1
  [ "$_RC" -eq 0 ] &&
    [ "$(_json .parse_status)" = "ok" ] &&
    [ "$(_json .claimed_verdict)" = "PASS" ] &&
    [ "$(_json .verifier)" = "playwright_uat" ] &&
    [ "$(_json .criteria_met)" = "3" ] &&
    [ "$(_json .criteria_total)" = "3" ] &&
    [ "$(_json .attempt)" = "1" ] &&
    [ "$(_json .schema_version)" = "1" ] && ok=0
  _teardown
  return "$ok"
}

test_block_after_prose() {
  _setup
  {
    printf 'The agent explains at length what it did.\n\nWith paragraphs.\n\n'
    _canonical_block
  } | _write_ret ret.txt
  _parse VERIFY ret.txt
  local ok=1
  [ "$_RC" -eq 0 ] && [ "$(_json .claimed_verdict)" = "PASS" ] && ok=0
  _teardown
  return "$ok"
}

test_reordered_fields() {
  _setup
  _write_ret ret.txt <<'EOF'
=== PHASE_RESULT ===
VERDICT: BLOCK
EVIDENCE: found an unguarded null deref
PHASE: PR-REVIEW
VERIFIER: pr_review
SCHEMA_VERSION: 1
=== END PHASE_RESULT ===
EOF
  _parse PR-REVIEW ret.txt
  local ok=1
  [ "$_RC" -eq 0 ] && [ "$(_json .claimed_verdict)" = "BLOCK" ] &&
    [ "$(_json .phase)" = "PR-REVIEW" ] && ok=0
  _teardown
  return "$ok"
}

test_blank_lines_inside_block() {
  _setup
  _write_ret ret.txt <<'EOF'
=== PHASE_RESULT ===
SCHEMA_VERSION: 1

PHASE: IMPLEMENT

VERIFIER: implement_tests
VERDICT: PASS

=== END PHASE_RESULT ===
EOF
  _parse IMPLEMENT ret.txt
  local ok=1
  [ "$_RC" -eq 0 ] && [ "$(_json .claimed_verdict)" = "PASS" ] && ok=0
  _teardown
  return "$ok"
}

test_crlf_line_endings() {
  _setup
  _canonical_block | sed 's/$/\r/' | _write_ret ret.txt
  _parse VERIFY ret.txt
  local ok=1
  [ "$_RC" -eq 0 ] && [ "$(_json .claimed_verdict)" = "PASS" ] &&
    [ "$(_json .verifier)" = "playwright_uat" ] && ok=0
  _teardown
  return "$ok"
}

test_indented_markers_and_keys() {
  _setup
  _write_ret ret.txt <<'EOF'
   === PHASE_RESULT ===
    SCHEMA_VERSION: 1
    PHASE: VERIFY
      VERIFIER:   build_only
    VERDICT:  WARN
   === END PHASE_RESULT ===
EOF
  _parse VERIFY ret.txt
  local ok=1
  [ "$_RC" -eq 0 ] && [ "$(_json .claimed_verdict)" = "WARN" ] &&
    [ "$(_json .verifier)" = "build_only" ] && ok=0
  _teardown
  return "$ok"
}

test_unknown_field_is_recorded_not_fatal() {
  _setup
  _write_ret ret.txt <<'EOF'
=== PHASE_RESULT ===
SCHEMA_VERSION: 1
PHASE: VERIFY
VERIFIER: playwright_uat
VERDICT: PASS
REVIEWER_MODEL: claude-opus-5
FUTURE_FIELD_9: whatever
=== END PHASE_RESULT ===
EOF
  _parse VERIFY ret.txt
  local ok=1
  [ "$_RC" -eq 0 ] &&
    [ "$(_json .extra.REVIEWER_MODEL)" = "claude-opus-5" ] &&
    [ "$(_json .extra.FUTURE_FIELD_9)" = "whatever" ] && ok=0
  _teardown
  return "$ok"
}

test_last_block_wins_on_appended_attempts() {
  _setup
  {
    printf -- '--- Attempt 1 ---\n'
    cat <<'EOF'
=== PHASE_RESULT ===
SCHEMA_VERSION: 1
PHASE: VERIFY
VERIFIER: playwright_uat
VERDICT: FAIL
ATTEMPT: 1
=== END PHASE_RESULT ===
EOF
    printf -- '--- Attempt 2 ---\n'
    cat <<'EOF'
=== PHASE_RESULT ===
SCHEMA_VERSION: 1
PHASE: VERIFY
VERIFIER: playwright_uat
VERDICT: PASS
ATTEMPT: 2
=== END PHASE_RESULT ===
EOF
  } | _write_ret ret.txt
  _parse VERIFY ret.txt
  local ok=1
  [ "$_RC" -eq 0 ] && [ "$(_json .claimed_verdict)" = "PASS" ] &&
    [ "$(_json .attempt)" = "2" ] && ok=0
  _teardown
  return "$ok"
}

test_optional_fields_default() {
  _setup
  _write_ret ret.txt <<'EOF'
=== PHASE_RESULT ===
SCHEMA_VERSION: 1
PHASE: IMPLEMENT
VERIFIER: implement_tests
VERDICT: PASS
=== END PHASE_RESULT ===
EOF
  _parse IMPLEMENT ret.txt
  local ok=1
  [ "$_RC" -eq 0 ] &&
    [ "$(_json .criteria_met)" = "0" ] &&
    [ "$(_json .criteria_total)" = "0" ] &&
    [ "$(_json .attempt)" = "1" ] &&
    [ "$(_json .evidence)" = "" ] && ok=0
  _teardown
  return "$ok"
}

# ── 4.3 failure cases — each asserts UNKNOWN and no success object ────────────

# _assert_unknown <expected parse_status>
_assert_unknown() {
  local want="$1"
  [ "$_RC" -eq 1 ] || return 1
  [ "$(_json .claimed_verdict)" = "UNKNOWN" ] || return 1
  [ "$(_json .parse_status)" = "$want" ] || return 1
  # A rejected record is never partially populated — a half-read claim would
  # read as a real one.
  [ "$(_json .verifier)" = "" ] || return 1
  [ "$(_json .criteria_met)" = "0" ] || return 1
  [ -n "$(_json .parse_error)" ] || return 1
  # Diagnostics go to stderr, never stdout.
  [ -n "$_ERR" ] || return 1
  return 0
}

test_missing_closing_marker() {
  _setup
  _write_ret ret.txt <<'EOF'
=== PHASE_RESULT ===
SCHEMA_VERSION: 1
PHASE: VERIFY
VERIFIER: playwright_uat
VERDICT: PASS
EOF
  _parse VERIFY ret.txt
  local ok=1
  _assert_unknown invalid && ok=0
  _teardown
  return "$ok"
}

test_truncated_last_block_does_not_fall_back_to_earlier_one() {
  _setup
  {
    _canonical_block
    printf '=== PHASE_RESULT ===\nSCHEMA_VERSION: 1\nPHASE: VERIFY\n'
  } | _write_ret ret.txt
  _parse VERIFY ret.txt
  local ok=1
  # The earlier complete PASS block must NOT be reported as the current claim.
  _assert_unknown invalid && ok=0
  _teardown
  return "$ok"
}

test_malformed_line_without_colon() {
  _setup
  _write_ret ret.txt <<'EOF'
=== PHASE_RESULT ===
SCHEMA_VERSION: 1
PHASE: VERIFY
this line has no colon
VERIFIER: playwright_uat
VERDICT: PASS
=== END PHASE_RESULT ===
EOF
  _parse VERIFY ret.txt
  local ok=1
  _assert_unknown invalid && ok=0
  _teardown
  return "$ok"
}

test_lowercase_key_rejected() {
  _setup
  _write_ret ret.txt <<'EOF'
=== PHASE_RESULT ===
SCHEMA_VERSION: 1
phase: VERIFY
VERIFIER: playwright_uat
VERDICT: PASS
=== END PHASE_RESULT ===
EOF
  _parse VERIFY ret.txt
  local ok=1
  _assert_unknown invalid && ok=0
  _teardown
  return "$ok"
}

# Same as _parse, but runs the parser under an explicit locale. Kept separate so
# the ordinary tests keep exercising whatever locale the operator actually has.
_parse_in_locale() {
  local loc="$1" phase="$2" file="$3"
  shift 3
  set +e
  _OUT=$(env LC_ALL="$loc" LANG="$loc" bash "$PARSER" --phase "$phase" \
    --return-file "$_ws/$file" --log-file "$_ws/pipeline.log" "$@" 2>"$_ws/stderr.txt")
  _RC=$?
  set -e
  _ERR=$(cat "$_ws/stderr.txt")
}

# First available non-C UTF-8 locale, or empty. Under such a locale bash's
# `[A-Z]` also matches accented uppercase letters — the condition the key
# charset check has to be immune to. CI images commonly carry only C/C.UTF-8,
# where the defect cannot reproduce, which is precisely why it survived review.
_utf8_locale() {
  local l
  for l in $(locale -a 2>/dev/null); do
    case "$l" in
    C | POSIX | C.* | c.*) continue ;;
    *.utf8 | *.UTF-8 | *.utf-8 | *.UTF8)
      printf '%s' "$l"
      return 0
      ;;
    esac
  done
  return 1
}

test_non_ascii_key_rejected_in_every_locale() {
  _setup
  _write_ret ret.txt <<'EOF'
=== PHASE_RESULT ===
SCHEMA_VERSION: 1
PHASE: VERIFY
VERIFIER: playwright_uat
VERDICT: PASS
WÉIRD: value
=== END PHASE_RESULT ===
EOF
  local ok=0 loc utf8
  utf8=$(_utf8_locale || true)
  for loc in C C.UTF-8 ${utf8:+"$utf8"}; do
    _parse_in_locale "$loc" VERIFY ret.txt
    _assert_unknown invalid || {
      echo "  key charset check did not fire under LC_ALL=$loc" >&2
      ok=1
    }
  done
  _teardown
  return "$ok"
}

# A repeated key is ambiguity about the claim, not a transport quirk. Silent
# last-write-wins would let two individually well-formed lines coerce a FAIL
# into a logged PASS — the coercion the closed VERDICT enum exists to prevent.
test_duplicate_verdict_key_is_rejected() {
  _setup
  _write_ret ret.txt <<'EOF'
=== PHASE_RESULT ===
SCHEMA_VERSION: 1
PHASE: VERIFY
VERIFIER: playwright_uat
VERDICT: FAIL
EVIDENCE: 3 of 5 criteria failed
VERDICT: PASS
=== END PHASE_RESULT ===
EOF
  _parse VERIFY ret.txt
  local ok=1
  _assert_unknown invalid && [ "$(_json .parse_error)" = "duplicate field: VERDICT" ] && ok=0
  _teardown
  return "$ok"
}

# The guard must not be order-sensitive: PASS-then-FAIL is rejected too, so the
# rule is "ambiguous claim", not "downgrade protection".
test_duplicate_verdict_rejected_in_either_order() {
  _setup
  _write_ret ret.txt <<'EOF'
=== PHASE_RESULT ===
SCHEMA_VERSION: 1
PHASE: VERIFY
VERIFIER: playwright_uat
VERDICT: PASS
VERDICT: FAIL
=== END PHASE_RESULT ===
EOF
  _parse VERIFY ret.txt
  local ok=1
  _assert_unknown invalid && ok=0
  _teardown
  return "$ok"
}

# Unknown fields are tolerated once (a future emitter must not break a current
# parser) but a repeated unknown key is still an ambiguous record: `extra` is a
# flat object, so last-write-wins would silently drop one of the two values.
test_duplicate_unknown_key_is_rejected() {
  _setup
  _write_ret ret.txt <<'EOF'
=== PHASE_RESULT ===
SCHEMA_VERSION: 1
PHASE: IMPLEMENT
VERIFIER: implement_tests
VERDICT: PASS
FUTURE_FIELD: one
FUTURE_FIELD: two
=== END PHASE_RESULT ===
EOF
  _parse IMPLEMENT ret.txt
  local ok=1
  _assert_unknown invalid && ok=0
  _teardown
  return "$ok"
}

# Guard against over-correction: the duplicate rule is per-block, so the
# documented "several appended attempts, last one wins" behaviour must survive.
# Each attempt repeats every key — across blocks, not within one.
test_repeated_keys_across_appended_blocks_still_parse() {
  _setup
  {
    cat <<'EOF'
=== PHASE_RESULT ===
SCHEMA_VERSION: 1
PHASE: VERIFY
VERIFIER: playwright_uat
VERDICT: FAIL
ATTEMPT: 1
=== END PHASE_RESULT ===
EOF
    cat <<'EOF'
=== PHASE_RESULT ===
SCHEMA_VERSION: 1
PHASE: VERIFY
VERIFIER: playwright_uat
VERDICT: PASS
ATTEMPT: 2
=== END PHASE_RESULT ===
EOF
  } | _write_ret ret.txt
  _parse VERIFY ret.txt
  local ok=1
  [ "$_RC" -eq 0 ] && [ "$(_json .claimed_verdict)" = "PASS" ] &&
    [ "$(_json .attempt)" = "2" ] && ok=0
  _teardown
  return "$ok"
}

# ── envelope unwrapping ──────────────────────────────────────────────────────
# fleetd already spawns workers with `--output-format json` (supervisor.py:1375),
# which JSON-escapes every newline in the return. Without unwrapping, a perfectly
# valid emission parses as `absent` — the failure is silent and total.

_PR_BLOCK_TEXT='Verification complete.

=== PHASE_RESULT ===
SCHEMA_VERSION: 1
PHASE: VERIFY
VERIFIER: playwright_uat
VERDICT: PASS
CRITERIA_MET: 5
CRITERIA_TOTAL: 5
=== END PHASE_RESULT ==='

test_output_format_json_envelope_is_unwrapped() {
  _setup
  jq -n --arg r "$_PR_BLOCK_TEXT" \
    '{type:"result",subtype:"success",is_error:false,result:$r,session_id:"s1"}' \
    >"$_ws/ret.txt"
  _parse VERIFY ret.txt
  local ok=1
  [ "$_RC" -eq 0 ] && [ "$(_json .claimed_verdict)" = "PASS" ] &&
    [ "$(_json .criteria_met)" = "5" ] && ok=0
  _teardown
  return "$ok"
}

test_stream_json_envelope_is_unwrapped() {
  _setup
  {
    jq -nc '{type:"system",subtype:"init"}'
    jq -nc '{type:"assistant",message:{content:"working"}}'
    jq -nc --arg r "$_PR_BLOCK_TEXT" '{type:"result",result:$r}'
  } >"$_ws/ret.txt"
  _parse VERIFY ret.txt
  local ok=1
  [ "$_RC" -eq 0 ] && [ "$(_json .claimed_verdict)" = "PASS" ] && ok=0
  _teardown
  return "$ok"
}

# Plain stdout is still the common case and must not be routed through the
# envelope path — this is the regression guard on the unwrap itself.
test_plain_text_return_is_not_treated_as_envelope() {
  _setup
  printf '%s\n' "$_PR_BLOCK_TEXT" >"$_ws/ret.txt"
  _parse VERIFY ret.txt
  local ok=1
  [ "$_RC" -eq 0 ] && [ "$(_json .claimed_verdict)" = "PASS" ] && ok=0
  _teardown
  return "$ok"
}

# An envelope carrying a return that never emitted a block is still `absent` —
# unwrapping must not invent a claim, only reveal one that was already there.
test_json_envelope_without_block_is_absent() {
  _setup
  jq -n --arg r 'I finished but forgot to emit anything.' \
    '{type:"result",result:$r}' >"$_ws/ret.txt"
  _parse VERIFY ret.txt
  local ok=1
  _assert_unknown absent && ok=0
  _teardown
  return "$ok"
}

# A JSON object that is not a claude envelope (no string .result) must fall
# through to plain-text handling rather than silently yielding an empty body.
test_unrelated_json_file_falls_through_to_text() {
  _setup
  printf '{"some":"object","result":42}\n' >"$_ws/ret.txt"
  _parse VERIFY ret.txt
  local ok=1
  _assert_unknown absent && ok=0
  _teardown
  return "$ok"
}

# ── cross-file contract drift ────────────────────────────────────────────────
# The enums live in three places: the parser (what is accepted), the schema doc
# (the stated contract) and the skills (what agents are told to emit). Drift
# between any two is silent — an agent emits what the preamble says and the
# parser rejects it, degrading a real verdict to UNKNOWN with no error anywhere.

# Verifier ids the schema doc's VERIFIER enum table declares.
_doc_verifiers() {
  sed -n '/^### VERIFIER enum/,/^## /p' "$LIB_DIR/../docs/phase-result-schema.md" |
    sed -n 's/^| `\([a-z_][a-z0-9_]*\)` |.*/\1/p' | sort
}

# Verifier ids the parser actually accepts.
_parser_verifiers() {
  # shellcheck disable=SC1090
  (
    source "$PARSER" >/dev/null 2>&1
    printf '%s\n' $_PR_VERIFIERS
  ) | sort
}

test_verifier_enum_matches_schema_doc() {
  local doc parser
  doc=$(_doc_verifiers)
  parser=$(_parser_verifiers)
  if [ "$doc" != "$parser" ]; then
    echo "  VERIFIER enum drift between parser and docs/phase-result-schema.md:" >&2
    diff <(printf '%s\n' "$parser") <(printf '%s\n' "$doc") >&2 || true
    return 1
  fi
  # Guard the guard: an empty extraction on both sides would compare equal.
  [ "$(printf '%s\n' "$doc" | grep -c .)" -ge 10 ] || {
    echo "  extracted only $(printf '%s\n' "$doc" | grep -c .) ids — extraction broke" >&2
    return 1
  }
  return 0
}

# Every VERIFIER a loop-bearing skill is instructed to emit must be one the
# parser accepts, or that phase's verdict is silently unrecoverable.
test_skill_declared_verifiers_are_in_the_enum() {
  local skills_dir="$LIB_DIR/../skills" id ok=0 accepted
  accepted=$(_parser_verifiers)
  for id in implement_tests playwright_uat build_only live_backend pr_review; do
    printf '%s\n' "$accepted" | grep -qx "$id" || {
      echo "  skill-declared verifier '$id' is not in the parser enum" >&2
      ok=1
    }
    grep -rqF "$id" "$skills_dir/ticket-implement/SKILL.md" \
      "$skills_dir/ticket-verify/SKILL.md" \
      "$skills_dir/ticket-pr-review/SKILL.md" || {
      echo "  verifier '$id' no longer appears in any loop-bearing SKILL.md" >&2
      ok=1
    }
  done
  return "$ok"
}

# The block grammar must exist in exactly one place. A SKILL.md that restates it
# becomes a second source of truth that drifts from the parser unnoticed.
#
# Naming the marker in prose ("end your return with the `=== PHASE_RESULT ===`
# block described in § 6") is a *reference* and is fine — that is how the skills
# point at the preamble. What must not appear outside the preamble is the block
# itself, which is identifiable by the closing marker or by the field lines.
test_block_grammar_is_declared_only_in_the_preamble() {
  local root="$LIB_DIR/.." f ok=0
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    if grep -q '=== END PHASE_RESULT ===' "$f" ||
      grep -qE '^[[:space:]]*(SCHEMA_VERSION|VERDICT|CRITERIA_TOTAL):' "$f"; then
      echo "  block grammar restated outside the preamble: $f" >&2
      ok=1
    fi
  done <<<"$(grep -rl 'PHASE_RESULT' "$root/skills" 2>/dev/null || true)"
  # Guard the guard: the preamble must still be the one place that has it.
  grep -q '=== END PHASE_RESULT ===' "$LIB_DIR/skill-preamble-auto.md" || {
    echo "  preamble no longer carries the grammar" >&2
    ok=1
  }
  return "$ok"
}

test_dashed_key_rejected() {
  _setup
  _write_ret ret.txt <<'EOF'
=== PHASE_RESULT ===
SCHEMA_VERSION: 1
PHASE: VERIFY
SOME-KEY: x
VERIFIER: playwright_uat
VERDICT: PASS
=== END PHASE_RESULT ===
EOF
  _parse VERIFY ret.txt
  local ok=1
  _assert_unknown invalid && ok=0
  _teardown
  return "$ok"
}

test_missing_required_field() {
  _setup
  _write_ret ret.txt <<'EOF'
=== PHASE_RESULT ===
SCHEMA_VERSION: 1
PHASE: VERIFY
VERDICT: PASS
=== END PHASE_RESULT ===
EOF
  _parse VERIFY ret.txt
  local ok=1
  _assert_unknown invalid && ok=0
  _teardown
  return "$ok"
}

test_non_numeric_in_numeric_field() {
  _setup
  _write_ret ret.txt <<'EOF'
=== PHASE_RESULT ===
SCHEMA_VERSION: 1
PHASE: VERIFY
VERIFIER: playwright_uat
VERDICT: PASS
CRITERIA_MET: three
=== END PHASE_RESULT ===
EOF
  _parse VERIFY ret.txt
  local ok=1
  _assert_unknown invalid && ok=0
  _teardown
  return "$ok"
}

test_invalid_verdict_enum_is_not_coerced() {
  _setup
  _write_ret ret.txt <<'EOF'
=== PHASE_RESULT ===
SCHEMA_VERSION: 1
PHASE: VERIFY
VERIFIER: playwright_uat
VERDICT: SUCCESS
=== END PHASE_RESULT ===
EOF
  _parse VERIFY ret.txt
  local ok=1
  # SUCCESS must never be coerced to PASS.
  _assert_unknown invalid && ok=0
  _teardown
  return "$ok"
}

test_invalid_verifier_enum() {
  _setup
  _write_ret ret.txt <<'EOF'
=== PHASE_RESULT ===
SCHEMA_VERSION: 1
PHASE: VERIFY
VERIFIER: vibes_check
VERDICT: PASS
=== END PHASE_RESULT ===
EOF
  _parse VERIFY ret.txt
  local ok=1
  _assert_unknown invalid && ok=0
  _teardown
  return "$ok"
}

test_non_loop_bearing_phase_in_block_rejected() {
  _setup
  _write_ret ret.txt <<'EOF'
=== PHASE_RESULT ===
SCHEMA_VERSION: 1
PHASE: APPRAISE
VERIFIER: gate_check
VERDICT: PASS
=== END PHASE_RESULT ===
EOF
  _parse VERIFY ret.txt
  local ok=1
  _assert_unknown invalid && ok=0
  _teardown
  return "$ok"
}

test_block_phase_must_match_invoking_phase() {
  _setup
  _write_ret ret.txt <<'EOF'
=== PHASE_RESULT ===
SCHEMA_VERSION: 1
PHASE: IMPLEMENT
VERIFIER: implement_tests
VERDICT: PASS
=== END PHASE_RESULT ===
EOF
  _parse VERIFY ret.txt
  local ok=1
  _assert_unknown invalid && ok=0
  _teardown
  return "$ok"
}

test_unsupported_schema_version() {
  _setup
  _write_ret ret.txt <<'EOF'
=== PHASE_RESULT ===
SCHEMA_VERSION: 99
PHASE: VERIFY
VERIFIER: playwright_uat
VERDICT: PASS
=== END PHASE_RESULT ===
EOF
  _parse VERIFY ret.txt
  local ok=1
  _assert_unknown invalid && ok=0
  _teardown
  return "$ok"
}

test_empty_block() {
  _setup
  _write_ret ret.txt <<'EOF'
=== PHASE_RESULT ===
=== END PHASE_RESULT ===
EOF
  _parse VERIFY ret.txt
  local ok=1
  _assert_unknown invalid && ok=0
  _teardown
  return "$ok"
}

test_absent_block() {
  _setup
  _write_ret ret.txt <<'EOF'
The agent wrote prose and nothing else. No block here at all.
EOF
  _parse VERIFY ret.txt
  local ok=1
  _assert_unknown absent && ok=0
  _teardown
  return "$ok"
}

# ── parser-could-not-run cases (exit 2, nothing logged) ───────────────────────

test_missing_return_file_exits_2() {
  _setup
  set +e
  bash "$PARSER" --phase VERIFY --return-file "$_ws/nope.txt" \
    --log-file "$_ws/pipeline.log" >/dev/null 2>&1
  local rc=$?
  set -e
  local ok=1
  [ "$rc" -eq 2 ] && [ ! -s "$_ws/pipeline.log" ] && ok=0
  _teardown
  return "$ok"
}

test_bad_invoking_phase_exits_2() {
  _setup
  _canonical_block | _write_ret ret.txt
  set +e
  bash "$PARSER" --phase APPRAISE --return-file "$_ws/ret.txt" \
    --log-file "$_ws/pipeline.log" >/dev/null 2>&1
  local rc=$?
  set -e
  local ok=1
  [ "$rc" -eq 2 ] && [ ! -s "$_ws/pipeline.log" ] && ok=0
  _teardown
  return "$ok"
}

test_missing_required_args_exits_2() {
  _setup
  set +e
  bash "$PARSER" --phase VERIFY >/dev/null 2>&1
  local rc=$?
  set -e
  local ok=1
  [ "$rc" -eq 2 ] && ok=0
  _teardown
  return "$ok"
}

# ── 4.4 values-as-data ────────────────────────────────────────────────────────

test_values_with_shell_metacharacters_roundtrip() {
  _setup
  local payload='quote " dollar $HOME backtick `id` subst $(id) amp && semi ; back\slash'
  {
    printf '=== PHASE_RESULT ===\nSCHEMA_VERSION: 1\nPHASE: VERIFY\nVERIFIER: playwright_uat\nVERDICT: FAIL\n'
    printf 'EVIDENCE: %s\n' "$payload"
    printf '=== END PHASE_RESULT ===\n'
  } | _write_ret ret.txt
  _parse VERIFY ret.txt
  local got
  got=$(_json .evidence)
  local ok=1
  [ "$_RC" -eq 0 ] && [ "$got" = "$payload" ] && ok=0
  _teardown
  return "$ok"
}

test_command_substitution_is_not_executed() {
  _setup
  {
    printf '=== PHASE_RESULT ===\nSCHEMA_VERSION: 1\nPHASE: VERIFY\nVERIFIER: playwright_uat\nVERDICT: PASS\n'
    printf 'EVIDENCE: $(touch %s/PWNED) and `touch %s/PWNED2`\n' "$_ws" "$_ws"
    printf '=== END PHASE_RESULT ===\n'
  } | _write_ret ret.txt
  _parse VERIFY ret.txt
  local ok=1
  [ "$_RC" -eq 0 ] && [ ! -e "$_ws/PWNED" ] && [ ! -e "$_ws/PWNED2" ] && ok=0
  _teardown
  return "$ok"
}

test_value_with_interior_colons_and_paths() {
  _setup
  {
    printf '=== PHASE_RESULT ===\nSCHEMA_VERSION: 1\nPHASE: VERIFY\nVERIFIER: playwright_uat\nVERDICT: PASS\n'
    printf 'EVIDENCE: see /var/log/app.log:88: failed at 12:30:00\n'
    printf '=== END PHASE_RESULT ===\n'
  } | _write_ret ret.txt
  _parse VERIFY ret.txt
  local ok=1
  [ "$_RC" -eq 0 ] &&
    [ "$(_json .evidence)" = "see /var/log/app.log:88: failed at 12:30:00" ] && ok=0
  _teardown
  return "$ok"
}

test_unicode_value_roundtrips() {
  _setup
  {
    printf '=== PHASE_RESULT ===\nSCHEMA_VERSION: 1\nPHASE: VERIFY\nVERIFIER: playwright_uat\nVERDICT: WARN\n'
    printf 'EVIDENCE: verdict ⚠️ — naïve café 日本語 ✅\n'
    printf '=== END PHASE_RESULT ===\n'
  } | _write_ret ret.txt
  _parse VERIFY ret.txt
  local ok=1
  [ "$_RC" -eq 0 ] &&
    [ "$(_json .evidence)" = "verdict ⚠️ — naïve café 日本語 ✅" ] && ok=0
  _teardown
  return "$ok"
}

test_emitted_json_is_always_valid() {
  _setup
  {
    printf '=== PHASE_RESULT ===\nSCHEMA_VERSION: 1\nPHASE: VERIFY\nVERIFIER: playwright_uat\nVERDICT: FAIL\n'
    printf 'EVIDENCE: {"nested": "json"} [1,2] \\n \\t "unterminated\n'
    printf 'UNADDRESSED: trailing backslash \\\n'
    printf '=== END PHASE_RESULT ===\n'
  } | _write_ret ret.txt
  _parse VERIFY ret.txt
  local ok=1
  [ "$_RC" -eq 0 ] && printf '%s' "$_OUT" | jq -e . >/dev/null 2>&1 && ok=0
  _teardown
  return "$ok"
}

# ── 4.5 log channel ───────────────────────────────────────────────────────────

test_appends_meta_phase_result_to_log() {
  _setup
  _canonical_block | _write_ret ret.txt
  _parse VERIFY ret.txt
  local line
  line=$(grep -c '|META|phase-result|info|' "$_ws/pipeline.log" || true)
  local payload ok=1
  payload=$(tail -1 "$_ws/pipeline.log" | cut -d'|' -f5-)
  [ "$line" = "1" ] && printf '%s' "$payload" | jq -e '.claimed_verdict == "PASS"' >/dev/null 2>&1 && ok=0
  _teardown
  return "$ok"
}

test_unwritable_log_degrades_without_failing() {
  _setup
  _canonical_block | _write_ret ret.txt
  set +e
  local out rc
  out=$(bash "$PARSER" --phase VERIFY --return-file "$_ws/ret.txt" \
    --log-file /proc/definitely/not/writable.log 2>/dev/null)
  rc=$?
  set -e
  local ok=1
  # Still exits 0 and still emits the record on stdout.
  [ "$rc" -eq 0 ] && printf '%s' "$out" | jq -e '.claimed_verdict == "PASS"' >/dev/null 2>&1 && ok=0
  _teardown
  return "$ok"
}

test_no_log_file_still_emits_on_stdout() {
  _setup
  _canonical_block | _write_ret ret.txt
  set +e
  local out rc
  out=$(LOG_FILE="" bash "$PARSER" --phase VERIFY --return-file "$_ws/ret.txt" 2>/dev/null)
  rc=$?
  set -e
  local ok=1
  [ "$rc" -eq 0 ] && printf '%s' "$out" | jq -e '.parse_status == "ok"' >/dev/null 2>&1 && ok=0
  _teardown
  return "$ok"
}

test_claim_is_not_written_to_verifier_result_channel() {
  _setup
  _canonical_block | _write_ret ret.txt
  _parse VERIFY ret.txt
  local ok=1
  # The claim must stay out of the verifier-result array, or a claimed-PASS beside
  # a verified-FAIL would trip the flaky_tests / verdict_disagreement detectors.
  ! grep -q 'verifier-result' "$_ws/pipeline.log" && ok=0
  _teardown
  return "$ok"
}

# ── 4.6 per-phase attribution ─────────────────────────────────────────────────

test_multi_phase_log_is_attributable() {
  _setup
  cat >"$_ws/impl.txt" <<'EOF'
=== PHASE_RESULT ===
SCHEMA_VERSION: 1
PHASE: IMPLEMENT
VERIFIER: implement_tests
VERDICT: PASS
=== END PHASE_RESULT ===
EOF
  cat >"$_ws/ver.txt" <<'EOF'
=== PHASE_RESULT ===
SCHEMA_VERSION: 1
PHASE: VERIFY
VERIFIER: playwright_uat
VERDICT: FAIL
=== END PHASE_RESULT ===
EOF
  cat >"$_ws/pr.txt" <<'EOF'
=== PHASE_RESULT ===
SCHEMA_VERSION: 1
PHASE: PR-REVIEW
VERIFIER: pr_review
VERDICT: WARN
=== END PHASE_RESULT ===
EOF
  set +e
  bash "$PARSER" --phase IMPLEMENT --return-file "$_ws/impl.txt" --log-file "$_ws/pipeline.log" >/dev/null 2>&1
  bash "$PARSER" --phase VERIFY --return-file "$_ws/ver.txt" --log-file "$_ws/pipeline.log" >/dev/null 2>&1
  bash "$PARSER" --phase PR-REVIEW --return-file "$_ws/pr.txt" --log-file "$_ws/pipeline.log" >/dev/null 2>&1
  set -e

  # A consumer must be able to select any one of them with jq alone.
  local phases verdict ok=1
  phases=$(grep '|META|phase-result|info|' "$_ws/pipeline.log" | cut -d'|' -f5- |
    jq -r '.phase' | tr '\n' ' ')
  verdict=$(grep '|META|phase-result|info|' "$_ws/pipeline.log" | cut -d'|' -f5- |
    jq -r 'select(.phase == "PR-REVIEW") | .claimed_verdict')
  [ "$phases" = "IMPLEMENT VERIFY PR-REVIEW " ] && [ "$verdict" = "WARN" ] && ok=0
  _teardown
  return "$ok"
}

test_retried_phase_records_each_attempt() {
  _setup
  cat >"$_ws/a1.txt" <<'EOF'
=== PHASE_RESULT ===
SCHEMA_VERSION: 1
PHASE: VERIFY
VERIFIER: playwright_uat
VERDICT: FAIL
ATTEMPT: 1
=== END PHASE_RESULT ===
EOF
  cat >"$_ws/a2.txt" <<'EOF'
=== PHASE_RESULT ===
SCHEMA_VERSION: 1
PHASE: VERIFY
VERIFIER: playwright_uat
VERDICT: PASS
ATTEMPT: 2
=== END PHASE_RESULT ===
EOF
  set +e
  bash "$PARSER" --phase VERIFY --return-file "$_ws/a1.txt" --log-file "$_ws/pipeline.log" >/dev/null 2>&1
  bash "$PARSER" --phase VERIFY --return-file "$_ws/a2.txt" --log-file "$_ws/pipeline.log" >/dev/null 2>&1
  set -e
  local pairs ok=1
  pairs=$(grep '|META|phase-result|info|' "$_ws/pipeline.log" | cut -d'|' -f5- |
    jq -r '"\(.attempt):\(.claimed_verdict)"' | tr '\n' ' ')
  # A first-attempt failure stays distinguishable from a final pass.
  [ "$pairs" = "1:FAIL 2:PASS " ] && ok=0
  _teardown
  return "$ok"
}

test_rejected_record_still_carries_its_phase() {
  _setup
  _write_ret ret.txt <<'EOF'
prose only
EOF
  _parse PR-REVIEW ret.txt
  local ok=1
  [ "$(_json .phase)" = "PR-REVIEW" ] && [ "$(_json .claimed_verdict)" = "UNKNOWN" ] && ok=0
  _teardown
  return "$ok"
}

# ── sourceable-lib mode ───────────────────────────────────────────────────────

test_sourceable_as_a_lib() {
  _setup
  _canonical_block | _write_ret ret.txt
  set +e
  local out rc
  out=$(
    source "$PARSER"
    parse_phase_result --phase VERIFY --return-file "$_ws/ret.txt" --log-file "$_ws/pipeline.log"
  ) 2>/dev/null
  rc=$?
  set -e
  local ok=1
  [ "$rc" -eq 0 ] && printf '%s' "$out" | jq -e '.claimed_verdict == "PASS"' >/dev/null 2>&1 && ok=0
  _teardown
  return "$ok"
}

# ── runner ────────────────────────────────────────────────────────────────────

TESTS=(
  test_canonical_block
  test_block_after_prose
  test_reordered_fields
  test_blank_lines_inside_block
  test_crlf_line_endings
  test_indented_markers_and_keys
  test_unknown_field_is_recorded_not_fatal
  test_last_block_wins_on_appended_attempts
  test_optional_fields_default
  test_missing_closing_marker
  test_truncated_last_block_does_not_fall_back_to_earlier_one
  test_malformed_line_without_colon
  test_lowercase_key_rejected
  test_dashed_key_rejected
  test_non_ascii_key_rejected_in_every_locale
  test_duplicate_verdict_key_is_rejected
  test_duplicate_verdict_rejected_in_either_order
  test_duplicate_unknown_key_is_rejected
  test_repeated_keys_across_appended_blocks_still_parse
  test_output_format_json_envelope_is_unwrapped
  test_stream_json_envelope_is_unwrapped
  test_plain_text_return_is_not_treated_as_envelope
  test_json_envelope_without_block_is_absent
  test_unrelated_json_file_falls_through_to_text
  test_verifier_enum_matches_schema_doc
  test_skill_declared_verifiers_are_in_the_enum
  test_block_grammar_is_declared_only_in_the_preamble
  test_missing_required_field
  test_non_numeric_in_numeric_field
  test_invalid_verdict_enum_is_not_coerced
  test_invalid_verifier_enum
  test_non_loop_bearing_phase_in_block_rejected
  test_block_phase_must_match_invoking_phase
  test_unsupported_schema_version
  test_empty_block
  test_absent_block
  test_missing_return_file_exits_2
  test_bad_invoking_phase_exits_2
  test_missing_required_args_exits_2
  test_values_with_shell_metacharacters_roundtrip
  test_command_substitution_is_not_executed
  test_value_with_interior_colons_and_paths
  test_unicode_value_roundtrips
  test_emitted_json_is_always_valid
  test_appends_meta_phase_result_to_log
  test_unwritable_log_degrades_without_failing
  test_no_log_file_still_emits_on_stdout
  test_claim_is_not_written_to_verifier_result_channel
  test_multi_phase_log_is_attributable
  test_retried_phase_records_each_attempt
  test_rejected_record_still_carries_its_phase
  test_sourceable_as_a_lib
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
