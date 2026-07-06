#!/usr/bin/env bash
# test-corrections.sh — unit tests for lib/corrections-parse.sh
# Usage: bash test-corrections.sh [test_name_filter]
set -eo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$TEST_DIR/.." && pwd)"
CP="$LIB_DIR/corrections-parse.sh"

# Source the library for direct function testing
source "$CP"

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

# ── Mock environment ──────────────────────────────────────────────────────────

_ws=""
_notes=""

_setup() {
  _ws=$(mktemp -d)
  _notes="$_ws/notes.md"
}

_teardown() {
  rm -rf "$_ws" 2>/dev/null || true
}

# Parse notes.md via get_corrections and source the output into shell vars.
_parse() {
  local _tmp_out="$_ws/parsed.env"
  set +e
  get_corrections "$_notes" >"$_tmp_out" 2>/dev/null
  local rc=$?
  set -e
  # shellcheck disable=SC1090
  source "$_tmp_out"
  return $rc
}

# ── Tests ──────────────────────────────────────────────────────────────────────

test_append_write_roundtrip() {
  _setup
  append_correction "$_notes" "Service X was removed in v2" "prescan" "Service X still exists at /api/x, moved not removed"
  [ -f "$_notes" ] || {
    _teardown
    return 1
  }
  _parse
  [ "$CORRECTION_COUNT" -eq 1 ] &&
    [ "$CORRECTION_0_FACT" = "Service X was removed in v2" ] &&
    [ "$CORRECTION_0_SOURCE" = "prescan" ] &&
    [ "$CORRECTION_0_CORRECTED" = "Service X still exists at /api/x, moved not removed" ]
  local rc=$?
  _teardown
  return $rc
}

test_append_multiple() {
  _setup
  append_correction "$_notes" "Fact A" "appraise" "Correction A"
  append_correction "$_notes" "Fact B" "wiki" "Correction B"
  _parse
  [ "$CORRECTION_COUNT" -eq 2 ]
  local rc=$?
  _teardown
  return $rc
}

test_last_match_wins_dedup() {
  _setup
  append_correction "$_notes" "Config lives in application.properties" "exec" "Actually it is in config.yml"
  append_correction "$_notes" "Config lives in application.properties" "prescan" "Actually it is in config.yml (confirmed by second impl)"
  _parse
  # Count should be 1 (deduped), and the value should be the second write
  [ "$CORRECTION_COUNT" -eq 1 ] &&
    [ "$CORRECTION_0_SOURCE" = "prescan" ] &&
    echo "$CORRECTION_0_CORRECTED" | grep -q "confirmed by second impl"
  local rc=$?
  _teardown
  return $rc
}

test_last_match_wins_preserves_count() {
  _setup
  append_correction "$_notes" "Fact-A" "appraise" "Corr-A1"
  append_correction "$_notes" "Fact-B" "wiki" "Corr-B"
  append_correction "$_notes" "Fact-A" "prescan" "Corr-A2"
  _parse
  # count=2 (B + second A), Fact-A value is the second
  [ "$CORRECTION_COUNT" -eq 2 ]
  local rc1=$?
  # Find the entry with Fact-A and check its corrected value
  local found_a2=0
  for i in $(seq 0 $((CORRECTION_COUNT - 1))); do
    local fact_var="CORRECTION_${i}_FACT"
    local corr_var="CORRECTION_${i}_CORRECTED"
    if [ "${!fact_var}" = "Fact-A" ]; then
      [ "${!corr_var}" = "Corr-A2" ] && found_a2=1
    fi
  done
  [ "$found_a2" -eq 1 ]
  local rc2=$?
  _teardown
  [ $rc1 -eq 0 ] && [ $rc2 -eq 0 ]
  return $?
}

test_torn_block_ignored() {
  _setup
  # Write a notes.md that ends with an unclosed CORRECTIONS block
  cat >"$_notes" <<'EOF'
# Notes

<!-- CORRECTIONS -->
- fact: some fact
- source: prescan
- corrected: some correction
<!-- /CORRECTIONS -->

<!-- CORRECTIONS -->
- fact: torn fact
- source: wiki
EOF
  # Parse: the second (torn) block should be silently ignored.
  # Only the first intact block should be returned.
  _parse
  [ "$CORRECTION_COUNT" -eq 1 ] &&
    [ "$CORRECTION_0_FACT" = "some fact" ]
  local rc=$?
  _teardown
  return $rc
}

test_torn_block_preserves_prior() {
  _setup
  # Write an intact block, then a torn block
  cat >"$_notes" <<'EOF'
# Notes

<!-- CORRECTIONS -->
- fact: intact fact
- source: appraise
- corrected: intact correction
<!-- /CORRECTIONS -->

<!-- CORRECTIONS -->
- fact: torn fact
EOF
  _parse
  [ "$CORRECTION_COUNT" -eq 1 ] &&
    [ "$CORRECTION_0_FACT" = "intact fact" ]
  local rc=$?
  _teardown
  return $rc
}

test_no_corrections_block() {
  _setup
  cat >"$_notes" <<'EOF'
# Notes
Some content here but no corrections blocks at all.
EOF
  _parse
  [ "$CORRECTION_COUNT" -eq 0 ]
  local rc=$?
  _teardown
  return $rc
}

test_empty_notes_file() {
  _setup
  : >"$_notes"
  _parse
  [ "$CORRECTION_COUNT" -eq 0 ]
  local rc=$?
  _teardown
  return $rc
}

test_missing_notes_file() {
  _setup
  # _notes path doesn't exist
  local _tmp_out="$_ws/parsed.env"
  set +e
  get_corrections "/nonexistent/path/notes.md" >"$_tmp_out" 2>/dev/null
  local rc=$?
  set -e
  # Exit 1 for file not found
  [ "$rc" -eq 1 ]
  local rc2=$?
  _teardown
  return $rc2
}

test_get_by_source_filter() {
  _setup
  append_correction "$_notes" "Prescan fact" "prescan" "Prescan correction"
  append_correction "$_notes" "Wiki fact" "wiki" "Wiki correction"
  append_correction "$_notes" "Appraise fact" "appraise" "Appraise correction"

  local _tmp_out="$_ws/filtered.env"
  set +e
  get_corrections_by_source "$_notes" "prescan" >"$_tmp_out" 2>/dev/null
  local rc=$?
  set -e
  # shellcheck disable=SC1090
  source "$_tmp_out"
  [ "$rc" -eq 0 ] &&
    [ "$CORRECTION_COUNT" -eq 1 ] &&
    [ "$CORRECTION_0_FACT" = "Prescan fact" ] &&
    [ "$CORRECTION_0_CORRECTED" = "Prescan correction" ]
  local rc2=$?
  _teardown
  return $rc2
}

test_append_invalid_source() {
  _setup
  set +e
  append_correction "$_notes" "Fact" "bogus" "Correction"
  local rc=$?
  set -e
  # Exit 2 for invalid args
  [ "$rc" -eq 2 ]
  local rc2=$?
  _teardown
  return $rc2
}

# ── Runner ─────────────────────────────────────────────────────────────────────

echo "=== corrections-parse.sh unit tests ==="
echo ""

_run "append write roundtrip" test_append_write_roundtrip
_run "append multiple corrections" test_append_multiple
_run "last-match-wins dedup (same fact)" test_last_match_wins_dedup
_run "last-match-wins preserves count" test_last_match_wins_preserves_count
_run "torn block ignored" test_torn_block_ignored
_run "torn block preserves prior intact" test_torn_block_preserves_prior
_run "no corrections block in file" test_no_corrections_block
_run "empty notes file" test_empty_notes_file
_run "missing notes file" test_missing_notes_file
_run "get-by-source filter" test_get_by_source_filter
_run "append rejects invalid source" test_append_invalid_source

echo ""
echo "=== $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] || exit 1
