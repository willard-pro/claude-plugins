#!/usr/bin/env bash
# test-notes-parse.sh — unit tests for lib/notes-parse.sh
# get_complexity takes a ticket directory, reads $dir/notes.md.
# Correct fixture format: "## Complexity\n\n**Score:** simple"
# Usage: bash test-notes-parse.sh [test_name_filter]
# -u (nounset) intentionally omitted: Claude Code shell snapshots inject
# ZSH_VERSION references that trigger false-positive "unbound variable"
# errors in this bash version when nounset is active.
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

# ── tests ──────────────────────────────────────────────────────────────────────

test_extracts_simple() {
  local tmpdir
  tmpdir=$(mktemp -d)
  printf '## Complexity\n\n**Score:** simple\n' >"$tmpdir/notes.md"
  local result
  result=$(bash -c "source $LIB_DIR/notes-parse.sh; get_complexity '$tmpdir'" 2>/dev/null)
  rm -rf "$tmpdir"
  [ "$result" = "simple" ]
}

test_extracts_complex() {
  local tmpdir
  tmpdir=$(mktemp -d)
  printf '## Complexity\n\n**Score:** complex\n' >"$tmpdir/notes.md"
  local result
  result=$(bash -c "source $LIB_DIR/notes-parse.sh; get_complexity '$tmpdir'" 2>/dev/null)
  rm -rf "$tmpdir"
  [ "$result" = "complex" ]
}

test_missing_notes_file() {
  local tmpdir
  tmpdir=$(mktemp -d)
  # No notes.md created
  local exit_code=0
  bash -c "source $LIB_DIR/notes-parse.sh; get_complexity '$tmpdir'" 2>/dev/null || exit_code=$?
  rm -rf "$tmpdir"
  # Migration to error-handler.sh: E_ENV=12 for file-not-found
  [ "$exit_code" -eq 12 ]
}

test_missing_score_section() {
  local tmpdir
  tmpdir=$(mktemp -d)
  printf '## Complexity\n\nNo score line here.\n' >"$tmpdir/notes.md"
  local exit_code=0
  bash -c "source $LIB_DIR/notes-parse.sh; get_complexity '$tmpdir'" 2>/dev/null || exit_code=$?
  rm -rf "$tmpdir"
  [ "$exit_code" -eq 2 ]
}

test_windows_line_endings() {
  local tmpdir
  tmpdir=$(mktemp -d)
  printf '## Complexity\r\n\r\n**Score:** simple\r\n' >"$tmpdir/notes.md"
  local result
  result=$(bash -c "source $LIB_DIR/notes-parse.sh; get_complexity '$tmpdir'" 2>/dev/null)
  rm -rf "$tmpdir"
  [ "$result" = "simple" ]
}

test_critique_single_section_score() {
  local tmpdir
  tmpdir=$(mktemp -d)
  printf '## Readiness Critique\n\n**Status:** CLEAR\n**Score:** 90\n' >"$tmpdir/notes.md"
  local result
  result=$(bash -c "source $LIB_DIR/notes-parse.sh; get_critique_score '$tmpdir'" 2>/dev/null)
  rm -rf "$tmpdir"
  [ "$result" = "90" ]
}

test_critique_single_section_status() {
  local tmpdir
  tmpdir=$(mktemp -d)
  printf '## Readiness Critique\n\n**Status:** CLEAR\n**Score:** 90\n' >"$tmpdir/notes.md"
  local result
  result=$(bash -c "source $LIB_DIR/notes-parse.sh; get_critique_status '$tmpdir'" 2>/dev/null)
  rm -rf "$tmpdir"
  [ "$result" = "CLEAR" ]
}

# Reproduces #292: a re-run appends a second "## Readiness Critique (re-run
# <date>)" heading rather than replacing the first. Both headings contain
# "## Readiness Critique", so a naive sed range anchored on the first match
# would return the stale BLOCKED/20 values instead of the superseding
# re-run's CLEAR/80.
test_critique_rerun_score_takes_latest() {
  local tmpdir
  tmpdir=$(mktemp -d)
  printf '## Readiness Critique\n\n**Status:** BLOCKED\n**Score:** 20\n\n## Readiness Critique (re-run 2026-09-03)\n\n**Status:** CLEAR\n**Score:** 80\n' >"$tmpdir/notes.md"
  local result
  result=$(bash -c "source $LIB_DIR/notes-parse.sh; get_critique_score '$tmpdir'" 2>/dev/null)
  rm -rf "$tmpdir"
  [ "$result" = "80" ]
}

test_critique_rerun_status_takes_latest() {
  local tmpdir
  tmpdir=$(mktemp -d)
  printf '## Readiness Critique\n\n**Status:** BLOCKED\n**Score:** 20\n\n## Readiness Critique (re-run 2026-09-03)\n\n**Status:** CLEAR\n**Score:** 80\n' >"$tmpdir/notes.md"
  local result
  result=$(bash -c "source $LIB_DIR/notes-parse.sh; get_critique_status '$tmpdir'" 2>/dev/null)
  rm -rf "$tmpdir"
  [ "$result" = "CLEAR" ]
}

test_critique_rerun_stops_at_next_heading() {
  local tmpdir
  tmpdir=$(mktemp -d)
  printf '## Readiness Critique\n\n**Status:** BLOCKED\n**Score:** 20\n\n## Readiness Critique (re-run 2026-09-03)\n\n**Status:** CLEAR\n**Score:** 80\n\n## Some Later Section\n\n**Status:** IGNORED\n**Score:** 5\n' >"$tmpdir/notes.md"
  local result
  result=$(bash -c "source $LIB_DIR/notes-parse.sh; get_critique_score '$tmpdir'" 2>/dev/null)
  rm -rf "$tmpdir"
  [ "$result" = "80" ]
}

# ── dispatch ──────────────────────────────────────────────────────────────────

FILTER="${1:-}"

for fn in \
  test_extracts_simple \
  test_extracts_complex \
  test_missing_notes_file \
  test_missing_score_section \
  test_windows_line_endings \
  test_critique_single_section_score \
  test_critique_single_section_status \
  test_critique_rerun_score_takes_latest \
  test_critique_rerun_status_takes_latest \
  test_critique_rerun_stops_at_next_heading; do
  [ -z "$FILTER" ] || [[ "$fn" == *"$FILTER"* ]] || continue
  _run "$fn" "$fn"
done

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
