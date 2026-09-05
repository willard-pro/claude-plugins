#!/usr/bin/env bash
# test-prescan-check.sh — unit tests for lib/prescan-check.sh
# Usage: bash test-prescan-check.sh [test_name_filter]
set -eo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$TEST_DIR/.." && pwd)"
PRESCAN_CHECK="$LIB_DIR/prescan-check.sh"

PASS=0
FAIL=0

_run() {
  local name="$1"
  shift
  # Toggle -e off to capture test function return values correctly.
  # Test functions may legitimately return non-zero for assertion failures.
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

_ws=""             # workspace dir
_repo=""           # mock git repo
_root=""           # mock REPOS_ROOT
_origin=""         # mock bare "origin" repo (branch-aware tests only)
_default_branch="" # branch left checked out locally (branch-aware tests only)

_setup() {
  _ws=$(mktemp -d)
  _root="$_ws/repos-root"
  _repo="$_ws/test-repo"
  mkdir -p "$_root" "$_repo"
  cd "$_repo"
  git init -q
  git config user.email "test@test.com"
  git config user.name "Test"
  echo "// test source" >"$_repo/main.ts"
  git add main.ts
  git commit -q -m "initial commit"
  cd / # go somewhere safe, not into a temp dir we'll delete
}

_teardown() {
  rm -rf "$_ws" 2>/dev/null || true
}

# ── Helpers ────────────────────────────────────────────────────────────────────

# Run prescan-check and source its output into env vars
_run_check() {
  local repo="$1" force="${2:-false}" branch="${3:-}"
  local args=("$repo" "--repos-root" "$_root")
  [ "$force" = "true" ] && args+=("--force")
  [ -n "$branch" ] && args+=("--branch" "$branch")

  local _tmp_out="$_ws/prescan-out.env"
  # prescan-check.sh returns non-zero for stale/missing — expected.
  # Save/restore errexit so we don't re-enable it on the caller.
  local _saved_opts="$-"
  set +e
  "$PRESCAN_CHECK" "${args[@]}" >"$_tmp_out" 2>/dev/null
  case "$_saved_opts" in *e*) set -e ;; esac
  source "$_tmp_out"
}

# Make a commit on the repo (creates source change by touching main.ts)
_make_commit() {
  cd "$_repo"
  echo "// change $(date +%s%N)" >>"$_repo/main.ts"
  git add main.ts
  git commit -q -m "change"
  cd /
}

# Write a meta.json marker
_write_marker() {
  local slug="$1" sha="$2" schema="${3:-1}" full_dive_sha="${4:-}" full_dive_ts="${5:-}"
  local meta_dir="$_root/.ticket-auto/$slug"
  mkdir -p "$meta_dir"
  local fd_sha="${full_dive_sha:-$sha}"
  local fd_ts="${full_dive_ts:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
  cat >"$meta_dir/meta.json" <<JSONEOF
{
  "schema_version": "$schema",
  "last_scanned_sha": "$sha",
  "last_scanned_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "last_full_dive_sha": "$fd_sha",
  "last_full_dive_ts": "$fd_ts"
}
JSONEOF
}

# Write non-empty doc files for integrity check (all 4 required + services/)
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

# ── Tests ──────────────────────────────────────────────────────────────────────

test_no_marker_is_missing() {
  _setup
  _run_check "$_repo"
  [ "$PRESCAN_STATUS" = "missing" ] && [ "$PRESCAN_REASON" = "no_marker" ]
  local rc=$?
  _teardown
  return $rc
}

test_marker_at_head_is_fresh() {
  _setup
  local slug="test-repo" head
  head=$(git -C "$_repo" rev-parse HEAD)
  _write_marker "$slug" "$head"
  _write_docs "$slug"
  _run_check "$_repo"
  [ "$PRESCAN_STATUS" = "fresh" ] && [ "$PRESCAN_REASON" = "head_unchanged" ]
  local rc=$?
  _teardown
  return $rc
}

test_older_sha_with_source_change_is_stale() {
  _setup
  local slug="test-repo" orig_head new_head
  orig_head=$(git -C "$_repo" rev-parse HEAD)
  # Set last_full_dive_sha to a more recent SHA so decay doesn't override stale.
  # We'll use a marker where full_dive matches current HEAD but scanned_sha is older.
  # First save orig_head, then make a commit, then write marker.
  _make_commit
  new_head=$(git -C "$_repo" rev-parse HEAD)
  # Marker: last scanned was at orig_head, but full dive was at new_head (recent)
  # so churn since full dive is 0% → no decay trigger.
  _write_marker "$slug" "$orig_head" "1" "$new_head" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  _write_docs "$slug"
  _run_check "$_repo"
  [ "$PRESCAN_STATUS" = "stale" ] && [ "$PRESCAN_REASON" = "source_changed" ]
  local rc=$?
  _teardown
  return $rc
}

test_force_flag_is_stale_regardless() {
  _setup
  local slug="test-repo" head
  head=$(git -C "$_repo" rev-parse HEAD)
  _write_marker "$slug" "$head"
  _write_docs "$slug"
  _run_check "$_repo" "true"
  [ "$PRESCAN_STATUS" = "stale" ] && [ "$PRESCAN_REASON" = "forced" ]
  local rc=$?
  _teardown
  return $rc
}

test_schema_version_mismatch_is_missing() {
  _setup
  local slug="test-repo" head
  head=$(git -C "$_repo" rev-parse HEAD)
  _write_marker "$slug" "$head" "99"
  _write_docs "$slug"
  _run_check "$_repo"
  [ "$PRESCAN_STATUS" = "missing" ] && [ "$PRESCAN_REASON" = "schema_version_mismatch" ]
  local rc=$?
  _teardown
  return $rc
}

test_non_ancestor_sha_is_missing() {
  _setup
  local slug="test-repo"
  local bogus_sha="deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
  _write_marker "$slug" "$bogus_sha"
  _write_docs "$slug"
  _run_check "$_repo"
  [ "$PRESCAN_STATUS" = "missing" ] && [ "$PRESCAN_REASON" = "non_ancestor_sha" ]
  local rc=$?
  _teardown
  return $rc
}

test_integrity_fail_missing_doc_is_stale() {
  _setup
  local slug="test-repo" head
  head=$(git -C "$_repo" rev-parse HEAD)
  _write_marker "$slug" "$head"
  # Write all docs except overview.md to trigger integrity:overview.md
  local docs_dir="$_root/.ticket-auto/$slug/docs"
  mkdir -p "$docs_dir/services"
  echo "# Processes" >"$docs_dir/processes.md"
  echo "# INDEX" >"$docs_dir/INDEX.md"
  echo "# Security" >"$docs_dir/security-surfaces.md"
  echo "# Svc" >"$docs_dir/services/test-service.md"
  _run_check "$_repo"
  [ "$PRESCAN_STATUS" = "stale" ] && echo "$PRESCAN_REASON" | grep -q "integrity_fail"
  local rc=$?
  _teardown
  return $rc
}

test_integrity_fail_empty_doc_is_stale() {
  _setup
  local slug="test-repo" head
  head=$(git -C "$_repo" rev-parse HEAD)
  _write_marker "$slug" "$head"
  # Write empty overview.md, all others non-empty
  local docs_dir="$_root/.ticket-auto/$slug/docs"
  mkdir -p "$docs_dir/services"
  touch "$docs_dir/overview.md" # empty!
  echo "# Processes" >"$docs_dir/processes.md"
  echo "# INDEX" >"$docs_dir/INDEX.md"
  echo "# Security" >"$docs_dir/security-surfaces.md"
  echo "# Svc" >"$docs_dir/services/test-service.md"
  _run_check "$_repo"
  [ "$PRESCAN_STATUS" = "stale" ] && echo "$PRESCAN_REASON" | grep -q "integrity_fail:overview.md"
  local rc=$?
  _teardown
  return $rc
}

test_dirty_working_tree() {
  _setup
  local slug="test-repo" head
  head=$(git -C "$_repo" rev-parse HEAD)
  _write_marker "$slug" "$head"
  _write_docs "$slug"
  echo "// dirty change" >>"$_repo/main.ts"
  _run_check "$_repo"
  [ "$DIRTY" = "true" ]
  local rc=$?
  _teardown
  return $rc
}

test_no_source_changes_after_head_move_is_fresh() {
  _setup
  local slug="test-repo" orig_head
  orig_head=$(git -C "$_repo" rev-parse HEAD)
  _write_marker "$slug" "$orig_head"
  _write_docs "$slug"
  # Make a change to a file NOT in source globs — add a CI config file
  cd "$_repo"
  mkdir -p .github/workflows
  echo "name: CI" >.github/workflows/ci.yml
  git add .github/workflows/ci.yml
  git commit -q -m "add CI config"
  cd /
  _run_check "$_repo"
  # .yml is NOT in default globs (no package.json), and "*.yml" isn't in
  # DEFAULT_SOURCE_GLOBS. Actually checking — .github/workflows/ci.yml won't
  # match *.ts, *.js, etc. So this should be fresh.
  # NOTE: DEFAULT_SOURCE_GLOBS includes *.yml? No. Let's check: *.ts *.js *.py
  # *.java *.go *.rs *.rb *.php *.html *.css *.scss *.vue *.tsx *.jsx
  # .yml is NOT in the list. But the source glob is derived from markers.
  # Since only main.ts exists (no package.json), default globs apply.
  # .github/workflows/ci.yml won't match *.ts etc.
  # Actually wait — git diff uses glob patterns. *.yml won't match a .yml file
  # in a subdirectory because git treats the glob differently...
  # For git diff -- '*.yml', it actually does match files in subdirs.
  # But '*.yml' isn't in the default globs anyway.
  # So this should work: the .yml change won't trigger source_changed.
  [ "$PRESCAN_STATUS" = "fresh" ] && [ "$PRESCAN_REASON" = "no_source_changes" ]
  local rc=$?
  _teardown
  return $rc
}

test_decay_churn_over_threshold() {
  _setup
  local slug="test-repo" orig_head
  orig_head=$(git -C "$_repo" rev-parse HEAD)
  _write_marker "$slug" "$orig_head" "1" "$orig_head" "2026-01-01T00:00:00Z"
  _write_docs "$slug"
  _make_commit
  # Set churn threshold to 0% so any source change triggers decay
  PRESCAN_DECAY_CHURN_PCT=0 _run_check "$_repo"
  [ "$PRESCAN_STATUS" = "decayed" ] && [ "$PRESCAN_REASON" = "decay_churn" ]
  local rc=$?
  _teardown
  return $rc
}

test_decay_age_over_30d() {
  _setup
  local slug="test-repo" head
  head=$(git -C "$_repo" rev-parse HEAD)
  # Set full dive timestamp to 60 days ago (hardcoded — works on any date implementation)
  _write_marker "$slug" "$head" "1" "$head" "2026-04-15T00:00:00Z"
  _write_docs "$slug"
  _run_check "$_repo"
  [ "$PRESCAN_STATUS" = "decayed" ] && [ "$PRESCAN_REASON" = "decay_age" ]
  local rc=$?
  _teardown
  return $rc
}

test_exit_code_fresh_is_0() {
  _setup
  local slug="test-repo" head actual _saved
  head=$(git -C "$_repo" rev-parse HEAD)
  _write_marker "$slug" "$head"
  _write_docs "$slug"
  _saved="$-"
  set +e
  "$PRESCAN_CHECK" "$_repo" --repos-root "$_root" >/dev/null 2>/dev/null
  actual=$?
  case "$_saved" in *e*) set -e ;; esac
  [ $actual -eq 0 ]
  local rc=$?
  _teardown
  return $rc
}

test_exit_code_stale_is_1() {
  _setup
  local actual _saved
  _saved="$-"
  set +e
  "$PRESCAN_CHECK" "$_repo" --repos-root "$_root" --force >/dev/null 2>/dev/null
  actual=$?
  case "$_saved" in *e*) set -e ;; esac
  [ $actual -eq 1 ]
  local rc=$?
  _teardown
  return $rc
}

test_exit_code_missing_is_2() {
  _setup
  local actual _saved
  _saved="$-"
  set +e
  "$PRESCAN_CHECK" "$_repo" --repos-root "$_root" >/dev/null 2>/dev/null
  actual=$?
  case "$_saved" in *e*) set -e ;; esac
  [ $actual -eq 2 ]
  local rc=$?
  _teardown
  return $rc
}

test_no_sha_in_marker_is_missing() {
  _setup
  local slug="test-repo"
  local meta_dir="$_root/.ticket-auto/$slug"
  mkdir -p "$meta_dir"
  cat >"$meta_dir/meta.json" <<'JSONEOF'
{
  "schema_version": "1",
  "last_scanned_at": "2026-01-01T00:00:00Z"
}
JSONEOF
  _write_docs "$slug"
  _run_check "$_repo"
  [ "$PRESCAN_STATUS" = "missing" ] && [ "$PRESCAN_REASON" = "no_sha_in_marker" ]
  local rc=$?
  _teardown
  return $rc
}

# ── New tests: uncovered paths ─────────────────────────────────────────────────

test_decay_incremental_count() {
  _setup
  local slug="test-repo" head
  head=$(git -C "$_repo" rev-parse HEAD)
  _write_marker "$slug" "$head" "1" "$head" "2026-07-01T00:00:00Z"
  _write_docs "$slug"
  # Simulate 10 prior incremental scans by writing incremental_count into meta.json
  jq '.incremental_scan_count = 10' \
    "$_root/.ticket-auto/$slug/meta.json" >"$_root/.ticket-auto/$slug/meta.json.tmp" &&
    mv "$_root/.ticket-auto/$slug/meta.json.tmp" "$_root/.ticket-auto/$slug/meta.json"
  _run_check "$_repo"
  [ "$PRESCAN_STATUS" = "decayed" ] && [ "$PRESCAN_REASON" = "decay_incremental_count" ]
  local rc=$?
  _teardown
  return $rc
}

test_incremental_count_not_yet_decayed() {
  _setup
  local slug="test-repo" head
  head=$(git -C "$_repo" rev-parse HEAD)
  _write_marker "$slug" "$head" "1" "$head" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  _write_docs "$slug"
  # Only 3 incremental scans — below threshold of 10
  jq '.incremental_scan_count = 3' \
    "$_root/.ticket-auto/$slug/meta.json" >"$_root/.ticket-auto/$slug/meta.json.tmp" &&
    mv "$_root/.ticket-auto/$slug/meta.json.tmp" "$_root/.ticket-auto/$slug/meta.json"
  _run_check "$_repo"
  [ "$PRESCAN_STATUS" = "fresh" ]
  local rc=$?
  _teardown
  return $rc
}

test_head_unchanged_decay_age() {
  _setup
  local slug="test-repo" head
  head=$(git -C "$_repo" rev-parse HEAD)
  # HEAD == last_scanned_sha, but full_dive was 60 days ago
  _write_marker "$slug" "$head" "1" "$head" "2026-04-15T00:00:00Z"
  _write_docs "$slug"
  _run_check "$_repo"
  [ "$PRESCAN_STATUS" = "decayed" ] && [ "$PRESCAN_REASON" = "decay_age" ]
  local rc=$?
  _teardown
  return $rc
}

test_integrity_services_empty() {
  _setup
  local slug="test-repo" head
  head=$(git -C "$_repo" rev-parse HEAD)
  _write_marker "$slug" "$head"
  # Create docs but NO services/ dir
  local docs_dir="$_root/.ticket-auto/$slug/docs"
  mkdir -p "$docs_dir"
  echo "# Overview" >"$docs_dir/overview.md"
  echo "# Processes" >"$docs_dir/processes.md"
  echo "# INDEX" >"$docs_dir/INDEX.md"
  echo "# Security" >"$docs_dir/security-surfaces.md"
  # services/ dir intentionally not created
  _run_check "$_repo"
  [ "$PRESCAN_STATUS" = "stale" ] && echo "$PRESCAN_REASON" | grep -q "services/"
  local rc=$?
  _teardown
  return $rc
}

test_integrity_services_no_md_files() {
  _setup
  local slug="test-repo" head
  head=$(git -C "$_repo" rev-parse HEAD)
  _write_marker "$slug" "$head"
  local docs_dir="$_root/.ticket-auto/$slug/docs"
  mkdir -p "$docs_dir/services"
  echo "# Overview" >"$docs_dir/overview.md"
  echo "# Processes" >"$docs_dir/processes.md"
  echo "# INDEX" >"$docs_dir/INDEX.md"
  echo "# Security" >"$docs_dir/security-surfaces.md"
  # services/ exists but has NO .md files
  _run_check "$_repo"
  [ "$PRESCAN_STATUS" = "stale" ] && echo "$PRESCAN_REASON" | grep -q "services/"
  local rc=$?
  _teardown
  return $rc
}

# ── Branch-aware freshness tests (--branch flag) ──────────────────────────────
# Regression coverage for the false-"fresh" bug: repos in this project's
# local-dev convention run as ONE shared checkout, so literal HEAD is
# whichever branch happens to be checked out when the freshness gate runs —
# not necessarily the ticket's actual target branch (e.g. a long-lived epic
# branch that has diverged from develop/main). Each test builds a bare
# "origin" repo, then diverges a target branch away from whatever's left
# checked out locally.

# Builds a bare "origin" repo and pushes the current (checked-out) branch to
# it, so --branch can later `git fetch origin <name>` against something real.
_setup_with_origin() {
  _setup
  _origin="$_ws/origin.git"
  git init -q --bare "$_origin"
  cd "$_repo"
  _default_branch=$(git symbolic-ref --short HEAD)
  git remote add origin "$_origin"
  git push -q origin "refs/heads/$_default_branch:refs/heads/$_default_branch"
  cd /
}

# Creates a "target" branch on origin with one extra commit (touching the
# tracked source file) beyond whatever's currently checked out locally, then
# leaves the local checkout back on $_default_branch, UNCHANGED — i.e. the
# checked-out branch never advances; only the target branch (visible via
# origin/<name> after a fetch) does. Echoes the target branch's tip SHA.
_diverge_target_branch() {
  local branch_name="$1"
  cd "$_repo"
  git checkout -q -b "$branch_name" "$_default_branch"
  echo "// target branch change $(date +%s%N)" >>"$_repo/main.ts"
  git add main.ts
  git commit -q -m "target branch change"
  local sha
  sha=$(git rev-parse HEAD)
  git push -q origin "refs/heads/$branch_name:refs/heads/$branch_name"
  git checkout -q "$_default_branch"
  git branch -q -D "$branch_name"
  cd /
  echo "$sha"
}

test_branch_flag_absent_preserves_old_behavior() {
  _setup_with_origin
  local slug="test-repo" checked_out_head
  checked_out_head=$(git -C "$_repo" rev-parse HEAD)
  _diverge_target_branch "epic-branch" >/dev/null
  _write_marker "$slug" "$checked_out_head"
  _write_docs "$slug"
  # No --branch given: old behavior is preserved — diff against whatever's
  # checked out, which never moved. Must still report fresh (no regression).
  _run_check "$_repo"
  [ "$PRESCAN_STATUS" = "fresh" ] && [ "$PRESCAN_REASON" = "head_unchanged" ]
  local rc=$?
  _teardown
  return $rc
}

test_branch_flag_fresh_against_target_tip() {
  _setup_with_origin
  local slug="test-repo" target_sha
  target_sha=$(_diverge_target_branch "epic-branch")
  # Marker records the TARGET branch's tip, not the checked-out branch's HEAD
  # (which is still the original commit — behind the target branch).
  _write_marker "$slug" "$target_sha"
  _write_docs "$slug"
  _run_check "$_repo" "false" "epic-branch"
  [ "$PRESCAN_STATUS" = "fresh" ] && [ "$PRESCAN_REASON" = "head_unchanged" ]
  local rc=$?
  _teardown
  return $rc
}

test_branch_flag_catches_false_fresh_regression() {
  _setup_with_origin
  local slug="test-repo" checked_out_head
  checked_out_head=$(git -C "$_repo" rev-parse HEAD)
  # Target branch (epic-branch) gets a commit the freshness marker never saw.
  _diverge_target_branch "epic-branch" >/dev/null
  # Marker matches the checked-out HEAD, which never advanced — this is
  # exactly the false-fresh scenario from the bug report: last_scanned_sha
  # equals literal HEAD, but the ticket's real target branch has moved on.
  _write_marker "$slug" "$checked_out_head"
  _write_docs "$slug"

  # Baseline: without --branch, old (pre-fix) behavior is unaffected — fresh.
  _run_check "$_repo"
  if [ "$PRESCAN_STATUS" != "fresh" ]; then
    _teardown
    return 1
  fi

  # With --branch, the gate must NOT report fresh — the target branch has
  # diverged and the marker's SHA is stale relative to its actual tip.
  _run_check "$_repo" "false" "epic-branch"
  [ "$PRESCAN_STATUS" != "fresh" ]
  local rc=$?
  _teardown
  return $rc
}

# ── Runner ─────────────────────────────────────────────────────────────────────

echo "=== prescan-check.sh unit tests ==="
echo ""

# Run all tests
_run "no marker → missing" test_no_marker_is_missing
_run "marker at HEAD → fresh" test_marker_at_head_is_fresh
_run "older SHA with source change → stale" test_older_sha_with_source_change_is_stale
_run "--force → stale regardless" test_force_flag_is_stale_regardless
_run "schema_version mismatch → missing" test_schema_version_mismatch_is_missing
_run "non-ancestor SHA → missing" test_non_ancestor_sha_is_missing
_run "integrity fail (missing doc) → stale" test_integrity_fail_missing_doc_is_stale
_run "integrity fail (empty doc) → stale" test_integrity_fail_empty_doc_is_stale
_run "dirty working tree → DIRTY=true" test_dirty_working_tree
_run "no source changes after HEAD move → fresh" test_no_source_changes_after_head_move_is_fresh
_run "decay churn over threshold → decayed" test_decay_churn_over_threshold
_run "decay age over 30d → decayed" test_decay_age_over_30d
_run "fresh → exit 0" test_exit_code_fresh_is_0
_run "stale/forced → exit 1" test_exit_code_stale_is_1
_run "missing → exit 2" test_exit_code_missing_is_2
_run "no SHA in marker → missing" test_no_sha_in_marker_is_missing
_run "decay incremental count (10) → decayed" test_decay_incremental_count
_run "incremental count (3) below threshold → still fresh" test_incremental_count_not_yet_decayed
_run "HEAD unchanged + old full_dive → decay_age" test_head_unchanged_decay_age
_run "integrity fail (no services/ dir) → stale" test_integrity_services_empty
_run "integrity fail (services/ no .md files) → stale" test_integrity_services_no_md_files
_run "--branch absent → old behavior preserved (fresh vs checked-out)" test_branch_flag_absent_preserves_old_behavior
_run "--branch present → fresh evaluated against target branch tip" test_branch_flag_fresh_against_target_tip
_run "--branch present → catches false-fresh regression on diverged target" test_branch_flag_catches_false_fresh_regression

echo ""
echo "=== $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] || exit 1
