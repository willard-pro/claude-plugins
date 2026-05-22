#!/usr/bin/env bash
# test-ticket-dir.sh — unit tests for lib/ticket-dir.sh
# Covers resolve_ticket_dir and the 3-tier resolve_plan_path fallback chain.
# Usage: bash test-ticket-dir.sh [test_name_filter]
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

# ── resolve_ticket_dir tests ──────────────────────────────────────────────────

test_resolves_single_match() {
  local tmpdir
  tmpdir=$(mktemp -d)
  mkdir -p "$tmpdir/WIL-42--fix-login"
  local result
  result=$(bash -c "source $LIB_DIR/ticket-dir.sh; resolve_ticket_dir WIL-42 '$tmpdir'" 2>/dev/null)
  rm -rf "$tmpdir"
  [[ "$result" == *"WIL-42--fix-login"* ]]
}

test_no_match_exits_1() {
  local tmpdir
  tmpdir=$(mktemp -d)
  local exit_code=0
  bash -c "source $LIB_DIR/ticket-dir.sh; resolve_ticket_dir WIL-99 '$tmpdir'" 2>/dev/null || exit_code=$?
  rm -rf "$tmpdir"
  [ "$exit_code" -eq 1 ]
}

test_multiple_matches_exits_2() {
  local tmpdir
  tmpdir=$(mktemp -d)
  mkdir -p "$tmpdir/WIL-42--fix-login"
  mkdir -p "$tmpdir/WIL-42--old-attempt"
  local exit_code=0
  bash -c "source $LIB_DIR/ticket-dir.sh; resolve_ticket_dir WIL-42 '$tmpdir'" 2>/dev/null || exit_code=$?
  rm -rf "$tmpdir"
  [ "$exit_code" -eq 2 ]
}

test_case_insensitive_match() {
  local tmpdir
  tmpdir=$(mktemp -d)
  mkdir -p "$tmpdir/wil-4--lowercase-dir"
  local result
  result=$(bash -c "source $LIB_DIR/ticket-dir.sh; resolve_ticket_dir WIL-4 '$tmpdir'" 2>/dev/null)
  rm -rf "$tmpdir"
  [[ "$result" == *"wil-4--lowercase-dir"* ]]
}

# ── resolve_plan_path tests ───────────────────────────────────────────────────

test_resolve_plan_from_log() {
  local tmpdir
  tmpdir=$(mktemp -d)
  local tasks_file="$tmpdir/tasks.md"
  touch "$tasks_file"
  local log_file="$tmpdir/pipeline.log"
  echo "2024-01-01T00:00:00Z|META|artifact|info|plan:$tasks_file" >"$log_file"

  local result
  result=$(bash -c "source $LIB_DIR/ticket-dir.sh; resolve_plan_path '$log_file' '$tmpdir'" 2>/dev/null)
  rm -rf "$tmpdir"
  [ "$result" = "$tasks_file" ]
}

test_resolve_plan_log_entry_stale() {
  local tmpdir
  tmpdir=$(mktemp -d)
  local stale_path="/tmp/nonexistent-tasks-stale-$$.md"
  local log_file="$tmpdir/pipeline.log"
  echo "2024-01-01T00:00:00Z|META|artifact|info|plan:$stale_path" >"$log_file"

  # Tier 2: simple-fix.md exists in ticket dir
  local fix_file="$tmpdir/simple-fix.md"
  touch "$fix_file"

  local result
  result=$(bash -c "source $LIB_DIR/ticket-dir.sh; resolve_plan_path '$log_file' '$tmpdir'" 2>/dev/null)
  rm -rf "$tmpdir"
  [ "$result" = "$fix_file" ]
}

test_resolve_plan_from_simple_fix() {
  local tmpdir
  tmpdir=$(mktemp -d)
  local log_file="$tmpdir/pipeline.log"
  touch "$log_file" # empty log — no artifact entry
  local fix_file="$tmpdir/simple-fix.md"
  touch "$fix_file"

  local result
  result=$(bash -c "source $LIB_DIR/ticket-dir.sh; resolve_plan_path '$log_file' '$tmpdir'" 2>/dev/null)
  rm -rf "$tmpdir"
  [ "$result" = "$fix_file" ]
}

test_resolve_plan_from_openspec() {
  local tmpdir
  tmpdir=$(mktemp -d)
  local log_file="$tmpdir/pipeline.log"
  touch "$log_file"
  mkdir -p "$tmpdir/openspec/changes/wil-4-my-feature"
  touch "$tmpdir/openspec/changes/wil-4-my-feature/tasks.md"

  local result
  result=$(cd "$tmpdir" && bash -c "source $LIB_DIR/ticket-dir.sh; resolve_plan_path '$log_file' '$tmpdir' 'wil-4'" 2>/dev/null)
  rm -rf "$tmpdir"
  [[ "$result" == *"wil-4-my-feature/tasks.md"* ]]
}

test_resolve_plan_all_fail() {
  local tmpdir
  tmpdir=$(mktemp -d)
  local log_file="$tmpdir/pipeline.log"
  touch "$log_file"
  # No simple-fix.md, no openspec dir, no log artifact entry

  local exit_code=0
  bash -c "source $LIB_DIR/ticket-dir.sh; resolve_plan_path '$log_file' '$tmpdir'" 2>/dev/null || exit_code=$?
  rm -rf "$tmpdir"
  [ "$exit_code" -ne 0 ]
}

# ── dispatch ──────────────────────────────────────────────────────────────────

FILTER="${1:-}"

for fn in \
  test_resolves_single_match \
  test_no_match_exits_1 \
  test_multiple_matches_exits_2 \
  test_case_insensitive_match \
  test_resolve_plan_from_log \
  test_resolve_plan_log_entry_stale \
  test_resolve_plan_from_simple_fix \
  test_resolve_plan_from_openspec \
  test_resolve_plan_all_fail; do
  [ -z "$FILTER" ] || [[ "$fn" == *"$FILTER"* ]] || continue
  _run "$fn" "$fn"
done

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
