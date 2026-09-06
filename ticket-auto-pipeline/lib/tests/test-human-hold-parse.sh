#!/usr/bin/env bash
# test-human-hold-parse.sh — unit tests for lib/human-hold-parse.sh
# Usage: bash test-human-hold-parse.sh [test_name_filter]
set -eo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$TEST_DIR/.." && pwd)"
PARSER="$LIB_DIR/human-hold-parse.sh"

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

_ws=""
_setup() { _ws=$(mktemp -d); }
_teardown() {
  [ -n "$_ws" ] && rm -rf "$_ws"
  _ws=""
}

_write_ret() { cat >"$_ws/$1"; }

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
=== HUMAN_HOLD ===
SCHEMA_VERSION: 1
PHASE: APPRAISE
REASON: SCOPE_UNDEFINED
BLOCKS: notes.md#Acceptance-Criteria AC-2
QUESTION_1: Should the export include archived records?
=== END HUMAN_HOLD ===
EOF
}

# ── success cases ────────────────────────────────────────────────────────────

test_canonical_block() {
  _setup
  _canonical_block | _write_ret ret.txt
  _parse APPRAISE ret.txt
  [ "$_RC" -eq 0 ] &&
    [ "$(_json .parse_status)" = "ok" ] &&
    [ "$(_json .phase)" = "APPRAISE" ] &&
    [ "$(_json .reason)" = "SCOPE_UNDEFINED" ] &&
    [ "$(_json '.questions | length')" = "1" ]
  local rc=$?
  _teardown
  return $rc
}

test_questions_retain_numbered_ids() {
  _setup
  cat <<'EOF' | _write_ret ret.txt
=== HUMAN_HOLD ===
SCHEMA_VERSION: 1
PHASE: EXEC
REASON: AC_CONFLICT
BLOCKS: notes.md#AC-1
QUESTION_2: second question
QUESTION_1: first question
QUESTION_3: third question
=== END HUMAN_HOLD ===
EOF
  _parse EXEC ret.txt
  [ "$_RC" -eq 0 ] &&
    [ "$(_json '.questions | length')" = "3" ] &&
    [ "$(_json '.questions[0].id')" = "1" ] &&
    [ "$(_json '.questions[0].text')" = "first question" ] &&
    [ "$(_json '.questions[2].id')" = "3" ]
  local rc=$?
  _teardown
  return $rc
}

test_supersedes_carried() {
  _setup
  cat <<'EOF' | _write_ret ret.txt
=== HUMAN_HOLD ===
SCHEMA_VERSION: 1
PHASE: APPRAISE
REASON: SCOPE_UNDEFINED
BLOCKS: notes.md#AC-2
SUPERSEDES: hold:CRE-9:g7:a1
QUESTION_1: which archive?
=== END HUMAN_HOLD ===
EOF
  _parse APPRAISE ret.txt
  [ "$_RC" -eq 0 ] && [ "$(_json .supersedes)" = "hold:CRE-9:g7:a1" ]
  local rc=$?
  _teardown
  return $rc
}

test_shell_metacharacters_are_data() {
  _setup
  cat <<'EOF' | _write_ret ret.txt
=== HUMAN_HOLD ===
SCHEMA_VERSION: 1
PHASE: APPRAISE
REASON: SCOPE_UNDEFINED
BLOCKS: notes.md#AC-2
QUESTION_1: expected "a $b" && got `c`; see $(pwd)/out.txt
=== END HUMAN_HOLD ===
EOF
  _parse APPRAISE ret.txt
  [ "$_RC" -eq 0 ] &&
    [ "$(_json '.questions[0].text')" = 'expected "a $b" && got `c`; see $(pwd)/out.txt' ]
  local rc=$?
  _teardown
  return $rc
}

# ── rejection cases ───────────────────────────────────────────────────────────

test_out_of_enum_reason_rejected() {
  _setup
  cat <<'EOF' | _write_ret ret.txt
=== HUMAN_HOLD ===
SCHEMA_VERSION: 1
PHASE: APPRAISE
REASON: NOT_A_REAL_REASON
BLOCKS: notes.md#AC-2
QUESTION_1: x?
=== END HUMAN_HOLD ===
EOF
  _parse APPRAISE ret.txt
  [ "$_RC" -eq 1 ] && [ "$(_json .parse_status)" = "invalid" ]
  local rc=$?
  _teardown
  return $rc
}

test_empty_blocks_rejected() {
  _setup
  cat <<'EOF' | _write_ret ret.txt
=== HUMAN_HOLD ===
SCHEMA_VERSION: 1
PHASE: APPRAISE
REASON: SCOPE_UNDEFINED
BLOCKS:
QUESTION_1: x?
=== END HUMAN_HOLD ===
EOF
  _parse APPRAISE ret.txt
  [ "$_RC" -eq 1 ] && [ "$(_json .parse_status)" = "invalid" ]
  local rc=$?
  _teardown
  return $rc
}

test_missing_blocks_rejected() {
  _setup
  cat <<'EOF' | _write_ret ret.txt
=== HUMAN_HOLD ===
SCHEMA_VERSION: 1
PHASE: APPRAISE
REASON: SCOPE_UNDEFINED
QUESTION_1: x?
=== END HUMAN_HOLD ===
EOF
  _parse APPRAISE ret.txt
  [ "$_RC" -eq 1 ] && [ "$(_json .parse_status)" = "invalid" ]
  local rc=$?
  _teardown
  return $rc
}

test_no_questions_rejected() {
  _setup
  cat <<'EOF' | _write_ret ret.txt
=== HUMAN_HOLD ===
SCHEMA_VERSION: 1
PHASE: APPRAISE
REASON: SCOPE_UNDEFINED
BLOCKS: notes.md#AC-2
=== END HUMAN_HOLD ===
EOF
  _parse APPRAISE ret.txt
  [ "$_RC" -eq 1 ] && [ "$(_json .parse_status)" = "invalid" ]
  local rc=$?
  _teardown
  return $rc
}

test_position_field_refused() {
  _setup
  cat <<'EOF' | _write_ret ret.txt
=== HUMAN_HOLD ===
SCHEMA_VERSION: 1
PHASE: APPRAISE
REASON: SCOPE_UNDEFINED
BLOCKS: notes.md#AC-2
POSITION: STEP_4
QUESTION_1: x?
=== END HUMAN_HOLD ===
EOF
  _parse APPRAISE ret.txt
  [ "$_RC" -eq 1 ] && [ "$(_json .parse_status)" = "invalid" ]
  local rc=$?
  _teardown
  return $rc
}

test_held_at_field_refused() {
  _setup
  cat <<'EOF' | _write_ret ret.txt
=== HUMAN_HOLD ===
SCHEMA_VERSION: 1
PHASE: APPRAISE
REASON: SCOPE_UNDEFINED
BLOCKS: notes.md#AC-2
HELD_AT: 2026-09-06T00:00:00Z
QUESTION_1: x?
=== END HUMAN_HOLD ===
EOF
  _parse APPRAISE ret.txt
  [ "$_RC" -eq 1 ] && [ "$(_json .parse_status)" = "invalid" ]
  local rc=$?
  _teardown
  return $rc
}

test_hold_id_field_refused() {
  _setup
  cat <<'EOF' | _write_ret ret.txt
=== HUMAN_HOLD ===
SCHEMA_VERSION: 1
PHASE: APPRAISE
REASON: SCOPE_UNDEFINED
BLOCKS: notes.md#AC-2
HOLD_ID: hold:CRE-9:g1:a1
QUESTION_1: x?
=== END HUMAN_HOLD ===
EOF
  _parse APPRAISE ret.txt
  [ "$_RC" -eq 1 ] && [ "$(_json .parse_status)" = "invalid" ]
  local rc=$?
  _teardown
  return $rc
}

test_severity_field_refused() {
  _setup
  cat <<'EOF' | _write_ret ret.txt
=== HUMAN_HOLD ===
SCHEMA_VERSION: 1
PHASE: APPRAISE
REASON: SCOPE_UNDEFINED
BLOCKS: notes.md#AC-2
SEVERITY: high
QUESTION_1: x?
=== END HUMAN_HOLD ===
EOF
  _parse APPRAISE ret.txt
  [ "$_RC" -eq 1 ] && [ "$(_json .parse_status)" = "invalid" ]
  local rc=$?
  _teardown
  return $rc
}

test_truncated_block_is_invalid_not_absent() {
  _setup
  cat <<'EOF' | _write_ret ret.txt
=== HUMAN_HOLD ===
SCHEMA_VERSION: 1
PHASE: APPRAISE
REASON: SCOPE_UNDEFINED
BLOCKS: notes.md#AC-2
QUESTION_1: x?
EOF
  _parse APPRAISE ret.txt
  [ "$_RC" -eq 1 ] && [ "$(_json .parse_status)" = "invalid" ]
  local rc=$?
  _teardown
  return $rc
}

test_no_block_is_absent_and_writes_nothing() {
  _setup
  printf 'Just ordinary prose, no block here.\n' | _write_ret ret.txt
  _parse APPRAISE ret.txt
  [ "$_RC" -eq 0 ] && [ "$(_json .parse_status)" = "absent" ] &&
    [ ! -s "$_ws/pipeline.log" ]
  local rc=$?
  _teardown
  return $rc
}

test_malformed_block_is_logged_not_dropped() {
  _setup
  cat <<'EOF' | _write_ret ret.txt
=== HUMAN_HOLD ===
SCHEMA_VERSION: 1
PHASE: APPRAISE
REASON: SCOPE_UNDEFINED
QUESTION_1: x?
EOF
  _parse APPRAISE ret.txt
  grep -q '|META|human-hold|waiting|' "$_ws/pipeline.log" 2>/dev/null &&
    grep -q '"parse_status":"invalid"' "$_ws/pipeline.log" 2>/dev/null
  local rc=$?
  _teardown
  return $rc
}

test_phase_mismatch_rejected() {
  _setup
  _canonical_block | _write_ret ret.txt
  _parse EXEC ret.txt
  [ "$_RC" -eq 1 ] && [ "$(_json .parse_status)" = "invalid" ]
  local rc=$?
  _teardown
  return $rc
}

# ── redaction ────────────────────────────────────────────────────────────────

test_secret_shaped_value_is_masked() {
  _setup
  cat <<'EOF' | _write_ret ret.txt
=== HUMAN_HOLD ===
SCHEMA_VERSION: 1
PHASE: EXEC
REASON: CREDENTIALS_MISSING
BLOCKS: notes.md#AC-3
QUESTION_1: use token: ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ012345
=== END HUMAN_HOLD ===
EOF
  _parse EXEC ret.txt
  [ "$_RC" -eq 0 ] &&
    [[ "$(_json '.questions[0].text')" == *'***REDACTED***'* ]] &&
    [[ "$(_json '.questions[0].text')" != *'ABCDEFGHIJKLMNOPQRSTUVWXYZ012345'* ]] &&
    ! grep -q 'ABCDEFGHIJKLMNOPQRSTUVWXYZ012345' "$_ws/pipeline.log"
  local rc=$?
  _teardown
  return $rc
}

test_redaction_applies_to_blocks_too() {
  _setup
  cat <<'EOF' | _write_ret ret.txt
=== HUMAN_HOLD ===
SCHEMA_VERSION: 1
PHASE: EXEC
REASON: CREDENTIALS_MISSING
BLOCKS: notes.md#token=abcSECRETvalue123
QUESTION_1: x?
=== END HUMAN_HOLD ===
EOF
  _parse EXEC ret.txt
  [ "$_RC" -eq 0 ] && [[ "$(_json .blocks)" == *'***REDACTED***'* ]]
  local rc=$?
  _teardown
  return $rc
}

# ── invalid → no hold eligibility (documentation-level assertion) ────────────

test_invalid_record_carries_no_hold_id_field() {
  _setup
  cat <<'EOF' | _write_ret ret.txt
=== HUMAN_HOLD ===
SCHEMA_VERSION: 1
PHASE: APPRAISE
REASON: NOPE
BLOCKS: notes.md#AC-2
QUESTION_1: x?
=== END HUMAN_HOLD ===
EOF
  _parse APPRAISE ret.txt
  # The record never carries a hold_id at all — minting is fleetd's job —
  # so an invalid record cannot be mistaken for a releasable one.
  [ "$_RC" -eq 1 ] && [ "$(_json 'has("hold_id")')" = "false" ]
  local rc=$?
  _teardown
  return $rc
}

# ── run ──────────────────────────────────────────────────────────────────────

_filter="${1:-}"
for fn in $(declare -F | awk '{print $3}' | grep '^test_'); do
  if [ -n "$_filter" ] && [[ "$fn" != *"$_filter"* ]]; then
    continue
  fi
  _run "$fn" "$fn"
done

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
