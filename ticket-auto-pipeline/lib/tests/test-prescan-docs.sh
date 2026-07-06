#!/usr/bin/env bash
# test-prescan-docs.sh — unit tests for prescan-docs.sh _write_index title resolution
# Usage: bash test-prescan-docs.sh [test_name_filter]
set -eo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$TEST_DIR/.." && pwd)"
PSCAN_DOCS="$LIB_DIR/prescan-docs.sh"
# prescan-docs.sh needs CLAUDE_SKILLS_LIB to find heartbeat.sh
export CLAUDE_SKILLS_LIB="$LIB_DIR"
# Source the script to get _write_index and _write_if_changed functions
source "$PSCAN_DOCS"

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
_repo=""

_setup() {
  _ws=$(mktemp -d)
  _repo="$_ws/repo"
  mkdir -p "$_repo"
  # Initialize git repo (prescan-check.sh needs it for SHA)
  git -C "$_repo" init -q
  git -C "$_repo" config user.email "test@test.com"
  git -C "$_repo" config user.name "Test"
  # Create a dummy committed file so there's a HEAD SHA
  echo "// test source" >"$_repo/main.ts"
  git -C "$_repo" add main.ts
  git -C "$_repo" commit -q -m "init"
}

_teardown() {
  rm -rf "$_ws" 2>/dev/null || true
}

# Create meta.json at REPOS_ROOT/.ticket-auto/<repo-slug>/meta.json
_write_meta() {
  local repo_slug="$1" doc_titles_json="$2"
  local meta_dir="$_ws/repos-root/.ticket-auto/$repo_slug"
  mkdir -p "$meta_dir"
  printf '{"schema_version":"1","last_scanned_sha":"abc123","last_scanned_at":"2026-01-01T00:00:00Z"%s}\n' \
    "${doc_titles_json:+",\"doc_titles\":$doc_titles_json"}" >"$meta_dir/meta.json"
}

# Create a service doc at REPOS_ROOT/.ticket-auto/<repo-slug>/docs/services/<name>.md
_write_service_doc() {
  local repo_slug="$1" name="$2" first_line="$3"
  local docs_dir="$_ws/repos-root/.ticket-auto/$repo_slug/docs/services"
  mkdir -p "$docs_dir"
  printf '%s\n\nService content for %s.\n' "$first_line" "$name" >"$docs_dir/$name.md"
}

# Run _write_index directly against our mock docs_dir
_run_index() {
  local repo_slug="$1"
  local docs_dir="$_ws/repos-root/.ticket-auto/$repo_slug/docs"
  mkdir -p "$docs_dir"
  _write_index "$docs_dir"
}

# ── Tests ──────────────────────────────────────────────────────────────────────

test_meta_title_used_in_index() {
  _setup
  local slug="test-repo"
  _write_meta "$slug" '{"services/custom-svc.md":"Custom Title from Meta"}'
  _write_service_doc "$slug" "custom-svc" "# Different Heading Title"
  _run_index "$slug"
  # INDEX.md should use meta.json title, not the heading
  grep -q '| Custom Title from Meta | services/custom-svc.md |' "$_ws/repos-root/.ticket-auto/$slug/docs/INDEX.md"
  local rc=$?
  _teardown
  return $rc
}

test_fallback_to_heading_when_no_meta_entry() {
  _setup
  local slug="test-repo"
  _write_meta "$slug" "{}"
  _write_service_doc "$slug" "fallback-svc" "# Fallback Heading"
  _run_index "$slug"
  # INDEX.md should use heading scrape (no meta.json entry for this doc)
  grep -q '| Fallback Heading | services/fallback-svc.md |' "$_ws/repos-root/.ticket-auto/$slug/docs/INDEX.md"
  local rc1=$?
  # meta.json should now have doc_titles written back
  jq -e '.doc_titles["services/fallback-svc.md"] == "Fallback Heading"' \
    "$_ws/repos-root/.ticket-auto/$slug/meta.json" >/dev/null 2>&1
  local rc2=$?
  _teardown
  [ $rc1 -eq 0 ] && [ $rc2 -eq 0 ]
  return $?
}

test_fallback_to_basename_when_heading_missing() {
  _setup
  local slug="test-repo"
  _write_meta "$slug" "{}"
  # Service doc with no # Heading at all
  local docs_dir="$_ws/repos-root/.ticket-auto/$slug/docs/services"
  mkdir -p "$docs_dir"
  printf 'Just some plain text, no heading.\n' >"$docs_dir/minimal.md"
  _run_index "$slug"
  # INDEX.md should use the basename "minimal"
  grep -q '| minimal | services/minimal.md |' "$_ws/repos-root/.ticket-auto/$slug/docs/INDEX.md"
  local rc=$?
  _teardown
  return $rc
}

test_no_meta_json_graceful() {
  _setup
  local slug="test-repo"
  # Don't create meta.json at all — _run_index creates a minimal one
  # but we want to test the case where meta.json doesn't have doc_titles
  _write_service_doc "$slug" "no-meta-svc" "# Scraped Title"
  _run_index "$slug"
  grep -q '| Scraped Title | services/no-meta-svc.md |' "$_ws/repos-root/.ticket-auto/$slug/docs/INDEX.md"
  local rc=$?
  _teardown
  return $rc
}

test_index_schema_unchanged() {
  _setup
  local slug="test-repo"
  _write_meta "$slug" '{"services/custom-svc.md":"Cached Title"}'
  _write_service_doc "$slug" "custom-svc" "# Different Heading"
  _run_index "$slug"
  local idx="$_ws/repos-root/.ticket-auto/$slug/docs/INDEX.md"
  # Required headings must be present
  grep -q '## Lookup by Topic' "$idx" || {
    _teardown
    return 1
  }
  grep -q '## Lookup by Service' "$idx" || {
    _teardown
    return 1
  }
  grep -q '| Topic | File |' "$idx" || {
    _teardown
    return 1
  }
  grep -q '| Service | File |' "$idx" || {
    _teardown
    return 1
  }
  _teardown
  return 0
}

test_mixed_meta_coverage() {
  _setup
  local slug="test-repo"
  # Three docs: two with meta titles, one without
  _write_meta "$slug" '{"services/alpha.md":"Alpha From Meta","services/beta.md":"Beta From Meta"}'
  _write_service_doc "$slug" "alpha" "# Wrong Alpha Heading"
  _write_service_doc "$slug" "beta" "# Wrong Beta Heading"
  _write_service_doc "$slug" "gamma" "# Gamma From Heading"
  _run_index "$slug"
  local idx="$_ws/repos-root/.ticket-auto/$slug/docs/INDEX.md"
  # alpha uses meta title
  grep -q '| Alpha From Meta | services/alpha.md |' "$idx" || {
    _teardown
    return 1
  }
  # beta uses meta title
  grep -q '| Beta From Meta | services/beta.md |' "$idx" || {
    _teardown
    return 1
  }
  # gamma uses heading (no meta entry)
  grep -q '| Gamma From Heading | services/gamma.md |' "$idx" || {
    _teardown
    return 1
  }
  # meta.json should now have all three
  jq -e '.doc_titles["services/alpha.md"] == "Alpha From Meta"' \
    "$_ws/repos-root/.ticket-auto/$slug/meta.json" >/dev/null 2>&1 || {
    _teardown
    return 1
  }
  jq -e '.doc_titles["services/gamma.md"] == "Gamma From Heading"' \
    "$_ws/repos-root/.ticket-auto/$slug/meta.json" >/dev/null 2>&1 || {
    _teardown
    return 1
  }
  _teardown
  return 0
}

# ── Runner ─────────────────────────────────────────────────────────────────────

echo "=== prescan-docs.sh _write_index title tests ==="
echo ""

_run "meta.json title used in INDEX.md" test_meta_title_used_in_index
_run "fallback to heading when no meta entry" test_fallback_to_heading_when_no_meta_entry
_run "fallback to basename when heading missing" test_fallback_to_basename_when_heading_missing
_run "no meta.json — graceful fallback" test_no_meta_json_graceful
_run "INDEX.md schema unchanged" test_index_schema_unchanged
_run "mixed meta coverage" test_mixed_meta_coverage

echo ""
echo "=== $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] || exit 1
