#!/usr/bin/env bash
# test-prescan-sweep.sh — unit tests for lib/prescan-sweep.sh
# Usage: bash test-prescan-sweep.sh [test_name_filter]
set -eo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$TEST_DIR/.." && pwd)"
PRESCAN_SWEEP="$LIB_DIR/prescan-sweep.sh"

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

_ws=""   # workspace dir
_root="" # mock REPOS_ROOT

_setup() {
  _ws=$(mktemp -d)
  _root="$_ws/repos-root"
  mkdir -p "$_root"
}

_teardown() {
  rm -rf "$_ws" 2>/dev/null || true
}

# Create a git repo with one commit under $_root/<name>
_make_repo() {
  local name="$1"
  local repo="$_root/$name"
  mkdir -p "$repo"
  cd "$repo"
  git init -q
  git config user.email "test@test.com"
  git config user.name "Test"
  echo "// test source" >"$repo/main.ts"
  git add main.ts
  git commit -q -m "initial commit"
  cd /
  echo "$repo"
}

_write_docs() {
  local slug="$1"
  local docs_dir="$_root/.ticket-auto/$slug/docs"
  mkdir -p "$docs_dir/services"
  echo "# Overview" >"$docs_dir/overview.md"
  echo "# Processes" >"$docs_dir/processes.md"
  echo "# INDEX" >"$docs_dir/INDEX.md"
  echo "# Security Surfaces" >"$docs_dir/security-surfaces.md"
  echo "# Test Service" >"$docs_dir/services/test-service.md"
}

_write_fresh_marker() {
  local repo="$1" slug="$2"
  local head
  head=$(git -C "$repo" rev-parse HEAD)
  local meta_dir="$_root/.ticket-auto/$slug"
  mkdir -p "$meta_dir"
  cat >"$meta_dir/meta.json" <<JSONEOF
{
  "schema_version": "1",
  "last_scanned_sha": "$head",
  "last_scanned_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "last_full_dive_sha": "$head",
  "last_full_dive_ts": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
JSONEOF
  _write_docs "$slug"
}

# ── Tests ──────────────────────────────────────────────────────────────────────

test_no_repos_is_clean_sweep() {
  _setup
  local out actual
  out=$("$PRESCAN_SWEEP" --repos-root "$_root" 2>/dev/null)
  actual=$?
  echo "$out" | grep -q "^TOTAL=0$"
  local rc=$?
  _teardown
  return $rc
}

test_all_fresh_repos_exit_0() {
  _setup
  local repo
  repo=$(_make_repo "repo-fresh")
  _write_fresh_marker "$repo" "repo-fresh"
  set +e
  "$PRESCAN_SWEEP" --repos-root "$_root" >/dev/null 2>/dev/null
  local actual=$?
  set -e
  [ $actual -eq 0 ]
  local rc=$?
  _teardown
  return $rc
}

test_missing_repo_exit_1() {
  _setup
  _make_repo "repo-missing" >/dev/null
  set +e
  "$PRESCAN_SWEEP" --repos-root "$_root" >/dev/null 2>/dev/null
  local actual=$?
  set -e
  [ $actual -eq 1 ]
  local rc=$?
  _teardown
  return $rc
}

test_mixed_status_counts() {
  _setup
  local fresh_repo missing_repo
  fresh_repo=$(_make_repo "repo-a")
  _write_fresh_marker "$fresh_repo" "repo-a"
  missing_repo=$(_make_repo "repo-b")
  local out
  set +e
  out=$("$PRESCAN_SWEEP" --repos-root "$_root" 2>/dev/null)
  set -e
  echo "$out" | grep -q "^TOTAL=2$" &&
    echo "$out" | grep -q "^FRESH=1$" &&
    echo "$out" | grep -q "^MISSING=1$"
  local rc=$?
  _teardown
  return $rc
}

test_needs_refresh_lists_non_fresh_repo() {
  _setup
  local missing_repo
  missing_repo=$(_make_repo "repo-needs-it")
  local out
  set +e
  out=$("$PRESCAN_SWEEP" --repos-root "$_root" 2>/dev/null)
  set -e
  echo "$out" | grep "^NEEDS_REFRESH=" | grep -q "repo-needs-it"
  local rc=$?
  _teardown
  return $rc
}

test_fresh_repo_not_in_needs_refresh() {
  _setup
  local fresh_repo
  fresh_repo=$(_make_repo "repo-all-good")
  _write_fresh_marker "$fresh_repo" "repo-all-good"
  local out
  set +e
  out=$("$PRESCAN_SWEEP" --repos-root "$_root" 2>/dev/null)
  set -e
  local needs_line
  needs_line=$(echo "$out" | grep "^NEEDS_REFRESH=")
  ! echo "$needs_line" | grep -q "repo-all-good"
  local rc=$?
  _teardown
  return $rc
}

test_json_format_valid() {
  _setup
  _make_repo "repo-json" >/dev/null
  local out
  set +e
  out=$("$PRESCAN_SWEEP" --repos-root "$_root" --format json 2>/dev/null)
  set -e
  echo "$out" | jq -e '.total == 1 and .missing == 1 and (.needs_refresh | length) == 1' >/dev/null
  local rc=$?
  _teardown
  return $rc
}

test_missing_repos_root_errors() {
  _setup
  set +e
  "$PRESCAN_SWEEP" --repos-root "$_ws/does-not-exist" >/dev/null 2>/dev/null
  local actual=$?
  set -e
  [ $actual -eq 2 ]
  local rc=$?
  _teardown
  return $rc
}

test_no_repos_root_flag_errors() {
  set +e
  REPOS_ROOT="" "$PRESCAN_SWEEP" >/dev/null 2>/dev/null
  local actual=$?
  set -e
  [ $actual -eq 2 ]
}

# ── Runner ─────────────────────────────────────────────────────────────────────

echo "=== prescan-sweep.sh unit tests ==="
echo ""

_run "no repos under REPOS_ROOT → clean sweep (TOTAL=0)" test_no_repos_is_clean_sweep
_run "all repos fresh → exit 0" test_all_fresh_repos_exit_0
_run "one missing repo → exit 1" test_missing_repo_exit_1
_run "mixed fresh/missing → correct counts" test_mixed_status_counts
_run "NEEDS_REFRESH lists non-fresh repo" test_needs_refresh_lists_non_fresh_repo
_run "NEEDS_REFRESH excludes fresh repo" test_fresh_repo_not_in_needs_refresh
_run "--format json emits valid JSON summary" test_json_format_valid
_run "nonexistent REPOS_ROOT → exit 2" test_missing_repos_root_errors
_run "no --repos-root and no env var → exit 2" test_no_repos_root_flag_errors

echo ""
echo "=== $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] || exit 1
