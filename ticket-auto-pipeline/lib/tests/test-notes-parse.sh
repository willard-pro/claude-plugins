#!/usr/bin/env bash
# test-notes-parse.sh — unit tests for lib/notes-parse.sh
# get_complexity takes a ticket directory, reads $dir/notes.md.
# Correct fixture format: "## Complexity\n\n**Score:** simple"
# Usage: bash test-notes-parse.sh [test_name_filter]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

PASS=0
FAIL=0

_run() {
  local name="$1"; shift
  if "$@" 2>/dev/null; then
    echo "PASS: $name"; ((PASS++)) || true
  else
    echo "FAIL: $name"; ((FAIL++)) || true
  fi
}

# ── tests ──────────────────────────────────────────────────────────────────────

test_extracts_simple() {
  local tmpdir; tmpdir=$(mktemp -d)
  printf '## Complexity\n\n**Score:** simple\n' > "$tmpdir/notes.md"
  local result
  result=$(bash -c "source $LIB_DIR/notes-parse.sh; get_complexity '$tmpdir'" 2>/dev/null)
  rm -rf "$tmpdir"
  [ "$result" = "simple" ]
}

test_extracts_complex() {
  local tmpdir; tmpdir=$(mktemp -d)
  printf '## Complexity\n\n**Score:** complex\n' > "$tmpdir/notes.md"
  local result
  result=$(bash -c "source $LIB_DIR/notes-parse.sh; get_complexity '$tmpdir'" 2>/dev/null)
  rm -rf "$tmpdir"
  [ "$result" = "complex" ]
}

test_missing_notes_file() {
  local tmpdir; tmpdir=$(mktemp -d)
  # No notes.md created
  local exit_code=0
  bash -c "source $LIB_DIR/notes-parse.sh; get_complexity '$tmpdir'" 2>/dev/null || exit_code=$?
  rm -rf "$tmpdir"
  [ "$exit_code" -eq 1 ]
}

test_missing_score_section() {
  local tmpdir; tmpdir=$(mktemp -d)
  printf '## Complexity\n\nNo score line here.\n' > "$tmpdir/notes.md"
  local exit_code=0
  bash -c "source $LIB_DIR/notes-parse.sh; get_complexity '$tmpdir'" 2>/dev/null || exit_code=$?
  rm -rf "$tmpdir"
  [ "$exit_code" -eq 2 ]
}

test_windows_line_endings() {
  local tmpdir; tmpdir=$(mktemp -d)
  printf '## Complexity\r\n\r\n**Score:** simple\r\n' > "$tmpdir/notes.md"
  local result
  result=$(bash -c "source $LIB_DIR/notes-parse.sh; get_complexity '$tmpdir'" 2>/dev/null)
  rm -rf "$tmpdir"
  [ "$result" = "simple" ]
}

# ── dispatch ──────────────────────────────────────────────────────────────────

FILTER="${1:-}"

for fn in \
  test_extracts_simple \
  test_extracts_complex \
  test_missing_notes_file \
  test_missing_score_section \
  test_windows_line_endings; do
  [ -z "$FILTER" ] || [[ "$fn" == *"$FILTER"* ]] || continue
  _run "$fn" "$fn"
done

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
