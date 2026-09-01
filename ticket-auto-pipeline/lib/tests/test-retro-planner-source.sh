#!/usr/bin/env bash
# test-retro-planner-source.sh — regression tests for skills/ticket-retro/retro.sh's
# ticket-planner log-source discovery (GitHub #177).
#
# retro.sh's directory-mode discovery was hardcoded to ticket-auto's
# ./logs/*-pipeline.log shape and could never see the planner's own
# ${REPOS_ROOT}/.ticket-auto/initiatives/{INIT_ID}/state.log logs. This runs
# retro.sh end-to-end (--window discovery, not the single-positional-log mode
# the other retro test suites use) against a synthetic REPOS_ROOT/logs tree
# and asserts both sources are discovered, counted separately, and deduped
# independently.
#
# Usage: bash test-retro-planner-source.sh [test_name_filter]
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
# heartbeat.sh itself; stub it so this test exercises source discovery in
# isolation from that unrelated latent bug.
_iso_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
export -f _iso_now

# Builds a workdir with a ticket-auto ./logs/{id}-pipeline.log and a planner
# ${REPOS_ROOT}/.ticket-auto/initiatives/{id}/state.log, runs retro.sh in
# directory-discovery (--window) mode from inside it, and echoes stdout JSON.
_retro_multi_source() {
  local extra_args=("$@")
  local tmpdir
  tmpdir=$(_mktemp_test_dir)

  mkdir -p "$tmpdir/logs"
  cat >"$tmpdir/logs/CRE-1-pipeline.log" <<'EOF'
2026-08-31T20:00:00Z|META|schema|info|1
2026-08-31T20:01:00Z|META|gate-stop|fail|EXEC_NO_ARTIFACT missing simple-fix.md
2026-08-31T20:01:01Z|META|outcome-label|info|Smooth
EOF

  mkdir -p "$tmpdir/reposroot/.ticket-auto/initiatives/INIT-1788079219-1490/artifacts"
  cat >"$tmpdir/reposroot/.ticket-auto/initiatives/INIT-1788079219-1490/state.log" <<'EOF'
2026-08-31T20:00:00Z|META|schema|info|1
2026-08-31T20:01:00Z|Crosscheck|check|start|running citation + propagation checks
2026-08-31T20:01:01Z|META|crosscheck|fail|CITATION_UNRESOLVED vs-a.md: lib/x.ts:42 not found
2026-08-31T20:01:02Z|Crosscheck|check|fail|1 blocking finding(s), 0 warn
EOF

  (
    cd "$tmpdir"
    CURSOR_FILE="$tmpdir/cursor.json" REPOS_ROOT="$tmpdir/reposroot" \
      bash "$RETRO_SH" --window 30 "${extra_args[@]}" 2>/dev/null
  )
}

# ── AC1: both sources discovered, counted separately ────────────────────────

test_both_sources_discovered() {
  local out
  out=$(_retro_multi_source --force)
  [ "$(echo "$out" | jq -r '.logs_by_source["ticket-auto"].scanned')" = "1" ] &&
    [ "$(echo "$out" | jq -r '.logs_by_source.planner.scanned')" = "1" ] &&
    [ "$(echo "$out" | jq -r '.logs_scanned')" = "2" ]
}

# ── AC2: planner Crosscheck findings land in failure_histogram by code ──────

test_planner_finding_in_histogram() {
  local out
  out=$(_retro_multi_source --force)
  [ "$(echo "$out" | jq -r '.failure_histogram.CITATION_UNRESOLVED')" = "1" ] &&
    [ "$(echo "$out" | jq -r '.crosscheck_blocking_total')" = "1" ]
}

# ── AC5-adjacent: planner finding never pollutes ticket-auto's own signal ──

test_ticket_auto_finding_also_present() {
  local out
  out=$(_retro_multi_source --force)
  [ "$(echo "$out" | jq -r '.failure_histogram.EXEC_NO_ARTIFACT')" = "1" ] &&
    [ "$(echo "$out" | jq -r '.gate_stop_total')" = "1" ]
}

# Out of scope (per #177): complexity-prediction accuracy has no planner
# equivalent — the planner initiative must not show up as a fake ticket in
# complexity_predictions.
test_planner_excluded_from_complexity_predictions() {
  local out
  out=$(_retro_multi_source --force)
  [ "$(echo "$out" | jq '.complexity_predictions | length')" = "1" ] &&
    [ "$(echo "$out" | jq -r '.complexity_predictions[0].ticket')" = "CRE-1" ]
}

# ── AC4: cursor dedupe works per source ──────────────────────────────────────

test_cursor_dedup_per_source() {
  local tmpdir
  tmpdir=$(_mktemp_test_dir)

  mkdir -p "$tmpdir/logs"
  cat >"$tmpdir/logs/CRE-2-pipeline.log" <<'EOF'
2026-08-31T20:00:00Z|META|schema|info|1
2026-08-31T20:01:00Z|META|gate-stop|fail|EXEC_NO_ARTIFACT missing simple-fix.md
EOF
  mkdir -p "$tmpdir/reposroot/.ticket-auto/initiatives/INIT-2/artifacts"
  cat >"$tmpdir/reposroot/.ticket-auto/initiatives/INIT-2/state.log" <<'EOF'
2026-08-31T20:00:00Z|META|schema|info|1
2026-08-31T20:01:01Z|META|crosscheck|fail|CITATION_UNRESOLVED vs-a.md: lib/x.ts:42 not found
EOF

  local cursor="$tmpdir/cursor.json"
  (
    cd "$tmpdir"
    CURSOR_FILE="$cursor" REPOS_ROOT="$tmpdir/reposroot" bash "$RETRO_SH" --window 30 --force >/dev/null 2>&1
  )
  local out
  out=$(cd "$tmpdir" && CURSOR_FILE="$cursor" REPOS_ROOT="$tmpdir/reposroot" bash "$RETRO_SH" --window 30 2>/dev/null)
  [ "$(echo "$out" | jq -r '.logs_by_source["ticket-auto"].skipped')" = "1" ] &&
    [ "$(echo "$out" | jq -r '.logs_by_source.planner.skipped')" = "1" ] &&
    [ "$(echo "$out" | jq -r '.logs_scanned')" = "0" ]
}

# ── AC3: ticket-auto behaviour is byte-identical when no planner logs exist ──

test_no_planner_dir_preserves_ticket_auto_only_behavior() {
  local tmpdir
  tmpdir=$(_mktemp_test_dir)
  mkdir -p "$tmpdir/logs"
  cat >"$tmpdir/logs/CRE-3-pipeline.log" <<'EOF'
2026-08-31T20:00:00Z|META|schema|info|1
2026-08-31T20:01:00Z|META|gate-stop|fail|EXEC_NO_ARTIFACT missing simple-fix.md
2026-08-31T20:01:01Z|META|outcome-label|info|Smooth
EOF
  local out
  out=$(cd "$tmpdir" && CURSOR_FILE="$tmpdir/cursor.json" REPOS_ROOT="$tmpdir/nonexistent-repos-root" \
    bash "$RETRO_SH" --window 30 --force 2>/dev/null)
  [ "$(echo "$out" | jq -r '.logs_scanned')" = "1" ] &&
    [ "$(echo "$out" | jq -r '.logs_by_source.planner.scanned')" = "0" ] &&
    [ "$(echo "$out" | jq -r '.failure_histogram.EXEC_NO_ARTIFACT')" = "1" ] &&
    [ "$(echo "$out" | jq -r '.complexity_predictions[0].ticket')" = "CRE-3" ]
}

# ── dispatch ─────────────────────────────────────────────────────────────

FILTER="${1:-}"
for fn in \
  test_both_sources_discovered \
  test_planner_finding_in_histogram \
  test_ticket_auto_finding_also_present \
  test_planner_excluded_from_complexity_predictions \
  test_cursor_dedup_per_source \
  test_no_planner_dir_preserves_ticket_auto_only_behavior; do
  [ -z "$FILTER" ] || [[ "$fn" == *"$FILTER"* ]] || continue
  _run "$fn" "$fn"
done

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
