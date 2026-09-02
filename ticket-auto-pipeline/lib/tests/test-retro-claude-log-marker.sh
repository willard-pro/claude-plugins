#!/usr/bin/env bash
# test-retro-claude-log-marker.sh — regression test for
# skills/ticket-retro/retro.sh's scan_claude_log_failures (GitHub #207).
#
# The keyword list matched against a manually curated set of English-language
# failure phrases, missing the pipeline's own structured error marker
# (META|error|fail|). Structured errors with wording outside the keyword
# list (e.g. "ticket directory not found for X") were invisible to the
# Claude Log Failures section even though the pipeline itself already
# flagged them. This test asserts any META|error|fail| line is caught
# regardless of message wording.
#
# Usage: bash test-retro-claude-log-marker.sh [test_name_filter]
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
RETRO_SH="$(cd "$LIB_DIR/../skills/ticket-retro" && pwd)/retro.sh"

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

_TEST_TMPDIRS=()
_mktemp_test_dir() {
  local d
  d=$(mktemp -d)
  _TEST_TMPDIRS+=("$d")
  echo "$d"
}
_cleanup_test_tmpdirs() {
  local d
  for d in "${_TEST_TMPDIRS[@]}"; do
    rm -rf "$d" 2>/dev/null || true
  done
}
trap _cleanup_test_tmpdirs EXIT

# retro.sh has no BASH_SOURCE main-guard — sourcing it runs the full retro
# scan. Extract just scan_claude_log_failures() by pattern so this test
# isolates the helper without invoking the rest of the pipeline.
_source_scan_helper() {
  local fn_src
  fn_src="$(awk '/^scan_claude_log_failures\(\)/,/^}/' "$RETRO_SH")"
  eval "$fn_src"
}
_source_scan_helper

# ── GitHub #207: META|error|fail| structured marker must be caught ───────

test_meta_error_fail_marker_is_caught() {
  local tmpdir claude_log output
  tmpdir=$(_mktemp_test_dir)
  claude_log="$tmpdir/claude.log"
  output="$tmpdir/failures.txt"
  cat >"$claude_log" <<'EOF'
2026-08-30T07:13:40Z|META|error|fail|[12] ticket directory not found for CRE-22
EOF
  scan_claude_log_failures "$claude_log" "$output"
  grep -q "ticket directory not found for CRE-22" "$output"
}

test_meta_error_fail_marker_with_unmatched_wording() {
  local tmpdir claude_log output
  tmpdir=$(_mktemp_test_dir)
  claude_log="$tmpdir/claude.log"
  output="$tmpdir/failures.txt"
  cat >"$claude_log" <<'EOF'
2026-08-30T07:13:41Z|META|error|fail|[12] env-check: required configuration missing
EOF
  scan_claude_log_failures "$claude_log" "$output"
  grep -q "env-check: required configuration missing" "$output"
}

test_non_matching_lines_still_excluded() {
  local tmpdir claude_log output
  tmpdir=$(_mktemp_test_dir)
  claude_log="$tmpdir/claude.log"
  output="$tmpdir/failures.txt"
  cat >"$claude_log" <<'EOF'
2026-08-30T07:13:42Z|META|title|info|CRE-22: unrelated ticket title
EOF
  scan_claude_log_failures "$claude_log" "$output"
  [ ! -s "$output" ]
}

# ── dispatch ─────────────────────────────────────────────────────────────

FILTER="${1:-}"
for fn in \
  test_meta_error_fail_marker_is_caught \
  test_meta_error_fail_marker_with_unmatched_wording \
  test_non_matching_lines_still_excluded; do
  [ -z "$FILTER" ] || [[ "$fn" == *"$FILTER"* ]] || continue
  _run "$fn" "$fn"
done

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
