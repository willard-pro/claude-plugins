#!/usr/bin/env bash
# test-retro-outcome-parse.sh — regression tests for skills/ticket-retro/retro.sh's
# complexity-prediction "actual" outcome parser (GitHub #148).
# Invokes the real script end-to-end against constructed pipeline-log fixtures
# and asserts on the emitted complexity_predictions JSON.
# Usage: bash test-retro-outcome-parse.sh [test_name_filter]
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

# retro.sh calls _iso_now at its very end (cursor-file write) without
# sourcing heartbeat.sh itself — a separate, pre-existing bug (not part of
# #148) that would otherwise crash every invocation under `set -e`. Export a
# stub so this test exercises the outcome-parsing fix in isolation rather
# than tripping over that unrelated latent bug.
_iso_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
export -f _iso_now

# Runs retro.sh against a single constructed fixture log and echoes its
# stdout JSON. $1 = ticket id, remaining args = log lines.
_retro_with_log() {
  local ticket_id="$1"
  shift
  local tmpdir
  tmpdir=$(_mktemp_test_dir)
  local log_file="$tmpdir/${ticket_id}-pipeline.log"
  local line
  for line in "$@"; do
    echo "$line" >>"$log_file"
  done
  CURSOR_FILE="$tmpdir/cursor.json" bash "$RETRO_SH" --window 1 --force "$log_file" 2>/dev/null
}

_actual_for() {
  echo "$1" | jq -r '.complexity_predictions[0].actual'
}

_actual_source_for() {
  echo "$1" | jq -r '.complexity_predictions[0].actual_source'
}

# ── GitHub #148: outcome-label marker, not free-prose parsing ──────────────

test_hard_outcome_with_embedded_commas_and_colons() {
  local out
  out=$(_retro_with_log "CRE-9" \
    "2026-08-27T19:00:00Z|META|schema|info|1" \
    "2026-08-27T19:56:58Z|IMPLEMENT|implement|done|Implemented root parent POM (git/parent, bootstrapped as new repo — no prior GitHub repo existed) across 12 repos...; plugin pins preserved. Outcome: Hard (predicted simple) due to unplanned parent-repo bootstrap." \
    "2026-08-27T19:56:59Z|META|outcome-label|info|Hard")
  [ "$(_actual_for "$out")" = "Hard" ]
}

test_rough_outcome_no_colon_marker_in_prose() {
  # CRE-10's message has no "Outcome:" colon marker at all — the previously
  # proposed regex fix wouldn't have matched this shape either.
  local out
  out=$(_retro_with_log "CRE-10" \
    "2026-08-28T09:00:00Z|META|schema|info|1" \
    "2026-08-28T09:02:34Z|IMPLEMENT|implement|done|Implement complete — Rough outcome, pushed feature branch off epic branch" \
    "2026-08-28T09:02:35Z|META|outcome-label|info|Rough")
  [ "$(_actual_for "$out")" = "Rough" ]
}

test_smooth_outcome_with_comma_in_prose() {
  local out
  out=$(_retro_with_log "CRE-12" \
    "2026-08-28T22:43:00Z|META|schema|info|1" \
    "2026-08-28T22:43:59Z|IMPLEMENT|implement|done|Implement complete — Smooth, dryRun BUILD SUCCESS, committed+pushed" \
    "2026-08-28T22:44:00Z|META|outcome-label|info|Smooth")
  [ "$(_actual_for "$out")" = "Smooth" ]
}

test_missing_outcome_label_falls_back_to_missing() {
  # Older pre-outcome-label-check logs have no META|outcome-label|info| line
  # at all — actual_source must fall back to "missing", not throw or parse
  # the IMPLEMENT prose.
  local out
  out=$(_retro_with_log "CRE-OLD" \
    "2026-01-01T00:00:00Z|META|schema|info|1" \
    "2026-01-01T00:00:01Z|IMPLEMENT|implement|done|Implement complete — Smooth")
  [ "$(_actual_for "$out")" = "null" ] && [ "$(_actual_source_for "$out")" = "missing" ]
}

# ── dispatch ─────────────────────────────────────────────────────────────

FILTER="${1:-}"
for fn in \
  test_hard_outcome_with_embedded_commas_and_colons \
  test_rough_outcome_no_colon_marker_in_prose \
  test_smooth_outcome_with_comma_in_prose \
  test_missing_outcome_label_falls_back_to_missing; do
  [ -z "$FILTER" ] || [[ "$fn" == *"$FILTER"* ]] || continue
  _run "$fn" "$fn"
done

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
