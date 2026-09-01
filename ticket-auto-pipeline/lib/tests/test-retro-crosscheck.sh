#!/usr/bin/env bash
# test-retro-crosscheck.sh — regression tests for skills/ticket-retro/retro.sh's
# handling of ticket-planner Crosscheck findings (GitHub #176 AC2).
#
# #176 assumed retro.sh's existing fail-parser already histograms
# META|crosscheck|fail|<CODE> lines by CODE, the same way it does for
# META|gate-stop|fail|<CODE>. It doesn't — the generic fail branch buckets by
# $step ("crosscheck"), collapsing every distinct finding code into one
# bucket. This test runs retro.sh directly against a synthetic planner
# state.log (as AC2 asks) and asserts the fix histograms per-code, and that
# warn-level findings are counted separately from blocking ones (AC4).
#
# Usage: bash test-retro-crosscheck.sh [test_name_filter]
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

# See test-retro-outcome-parse.sh — retro.sh calls _iso_now without sourcing
# heartbeat.sh itself; stub it so this test exercises crosscheck parsing in
# isolation from that unrelated latent bug.
_iso_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
export -f _iso_now

# Runs retro.sh directly against a constructed planner state.log fixture and
# echoes its stdout JSON. $1 = initiative id (used as the log's stem, mirroring
# how retro.sh derives ticket_id from any -pipeline.log — the id itself is
# irrelevant to the code under test), remaining args = log lines.
_retro_with_log() {
  local initiative_id="$1"
  shift
  local tmpdir
  tmpdir=$(_mktemp_test_dir)
  local log_file="$tmpdir/${initiative_id}-pipeline.log"
  local line
  for line in "$@"; do
    echo "$line" >>"$log_file"
  done
  CURSOR_FILE="$tmpdir/cursor.json" bash "$RETRO_SH" --window 30 --force "$log_file" 2>/dev/null
}

# ── #176 AC1/AC2: blocking findings histogram by CODE, not by step ─────────

test_blocking_findings_histogram_by_code() {
  local out
  out=$(_retro_with_log "INIT-1" \
    "2026-08-31T20:00:00Z|META|schema|info|1" \
    "2026-08-31T20:01:00Z|Crosscheck|check|start|running citation + propagation checks" \
    "2026-08-31T20:01:01Z|META|crosscheck|fail|CITATION_UNRESOLVED vs-a.md: lib/x.ts:42 not found" \
    "2026-08-31T20:01:02Z|META|crosscheck|fail|CITATION_UNRESOLVED vs-b.md: lib/y.ts:10 not found" \
    "2026-08-31T20:01:03Z|META|crosscheck|fail|RESOLUTION_NOT_PROPAGATED vs-c.md: consensus item 2 unresolved" \
    "2026-08-31T20:01:04Z|Crosscheck|check|fail|3 blocking finding(s), 0 warn — see META|crosscheck entries")
  [ "$(echo "$out" | jq -r '.failure_histogram.CITATION_UNRESOLVED')" = "2" ] &&
    [ "$(echo "$out" | jq -r '.failure_histogram.RESOLUTION_NOT_PROPAGATED')" = "1" ] &&
    [ "$(echo "$out" | jq -r '.failure_histogram.crosscheck // "missing"')" = "missing" ]
}

test_crosscheck_blocking_total() {
  local out
  out=$(_retro_with_log "INIT-2" \
    "2026-08-31T20:00:00Z|META|schema|info|1" \
    "2026-08-31T20:01:01Z|META|crosscheck|fail|CITATION_UNRESOLVED vs-a.md: lib/x.ts:42 not found" \
    "2026-08-31T20:01:02Z|META|crosscheck|fail|CITATION_UNRESOLVED vs-b.md: lib/y.ts:10 not found")
  [ "$(echo "$out" | jq -r '.crosscheck_blocking_total')" = "2" ]
}

# ── #176 AC4: warn findings counted separately, never in the blocking histogram ─

test_warn_findings_counted_separately() {
  local out
  out=$(_retro_with_log "INIT-3" \
    "2026-08-31T20:00:00Z|META|schema|info|1" \
    "2026-08-31T20:01:01Z|META|crosscheck|fail|CITATION_UNRESOLVED vs-a.md: lib/x.ts:42 not found" \
    "2026-08-31T20:01:02Z|META|crosscheck|warn|info DISCOVERY_GAP_UNRESOLVED vs-b.md: quick-scan noted, unresolved")
  [ "$(echo "$out" | jq -r '.crosscheck_blocking_total')" = "1" ] &&
    [ "$(echo "$out" | jq -r '.crosscheck_warn_total')" = "1" ] &&
    [ "$(echo "$out" | jq -r '.failure_histogram.DISCOVERY_GAP_UNRESOLVED // "missing"')" = "missing" ]
}

test_clean_run_has_zero_totals() {
  local out
  out=$(_retro_with_log "INIT-4" \
    "2026-08-31T20:00:00Z|META|schema|info|1" \
    "2026-08-31T20:01:00Z|Crosscheck|check|start|running citation + propagation checks" \
    "2026-08-31T20:01:01Z|Crosscheck|check|done|clean (0 warn)")
  [ "$(echo "$out" | jq -r '.crosscheck_blocking_total')" = "0" ] &&
    [ "$(echo "$out" | jq -r '.crosscheck_warn_total')" = "0" ]
}

# ── dispatch ─────────────────────────────────────────────────────────────

FILTER="${1:-}"
for fn in \
  test_blocking_findings_histogram_by_code \
  test_crosscheck_blocking_total \
  test_warn_findings_counted_separately \
  test_clean_run_has_zero_totals; do
  [ -z "$FILTER" ] || [[ "$fn" == *"$FILTER"* ]] || continue
  _run "$fn" "$fn"
done

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
