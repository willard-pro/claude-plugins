#!/usr/bin/env bash
# test-retro-fallback-status.sh — regression test for skills/ticket-retro/retro.sh's
# heartbeat fallback aggregation (GitHub #206).
#
# retro.sh only counted category=fallback heartbeat events when status=fired,
# silently dropping the majority of real-world fallback statuses (ok, info)
# observed in the log corpus. This test asserts every fallback event is
# counted regardless of status.
#
# Usage: bash test-retro-fallback-status.sh [test_name_filter]
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
# sourcing heartbeat.sh itself — a pre-existing latent bug (unrelated to
# #206) that would otherwise crash every invocation under `set -e`.
_iso_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
export -f _iso_now

# Runs retro.sh against a constructed pipeline log + sibling heartbeat log
# and echoes its stdout JSON. $1 = ticket id, $2 = newline-delimited
# heartbeat lines, remaining args = pipeline log lines.
_retro_with_heartbeat() {
  local ticket_id="$1" hb_lines="$2"
  shift 2
  local tmpdir
  tmpdir=$(_mktemp_test_dir)
  local log_file="$tmpdir/${ticket_id}-pipeline.log"
  local hb_file="$tmpdir/${ticket_id}-heartbeat.log"
  local line
  for line in "$@"; do
    echo "$line" >>"$log_file"
  done
  printf '%s\n' "$hb_lines" >"$hb_file"
  CURSOR_FILE="$tmpdir/cursor.json" bash "$RETRO_SH" --window 1 --force "$log_file" 2>/dev/null
}

_fallback_count_for() {
  echo "$1" | jq -r --arg event "$2" '.heartbeat.fallback_frequency[$event] // 0'
}

# ── GitHub #206: non-fired fallback statuses must still be counted ────────

test_ok_status_fallback_is_counted() {
  local out
  out=$(_retro_with_heartbeat "CRE-19" \
    "2026-09-01T10:00:00Z|fallback|gitnexus-impact|ok|skipped stale detect_changes, trusted VERIFY phase build results" \
    "2026-09-01T10:00:00Z|META|schema|info|1")
  [ "$(_fallback_count_for "$out" "gitnexus-impact")" = "1" ]
}

test_info_status_fallback_is_counted() {
  local out
  out=$(_retro_with_heartbeat "CRE-20" \
    "2026-09-01T10:00:00Z|fallback|prescan-cache|info|used cached prescan doc" \
    "2026-09-01T10:00:00Z|META|schema|info|1")
  [ "$(_fallback_count_for "$out" "prescan-cache")" = "1" ]
}

test_mixed_status_fallback_events_all_counted() {
  local out
  out=$(_retro_with_heartbeat "CRE-21" \
    "2026-09-01T10:00:00Z|fallback|nav-hints|fired|no hint found
2026-09-01T10:00:01Z|fallback|nav-hints|ok|graceful fallback
2026-09-01T10:00:02Z|fallback|nav-hints|warn|degraded fallback" \
    "2026-09-01T10:00:00Z|META|schema|info|1")
  [ "$(_fallback_count_for "$out" "nav-hints")" = "3" ]
}

# ── dispatch ─────────────────────────────────────────────────────────────

FILTER="${1:-}"
for fn in \
  test_ok_status_fallback_is_counted \
  test_info_status_fallback_is_counted \
  test_mixed_status_fallback_events_all_counted; do
  [ -z "$FILTER" ] || [[ "$fn" == *"$FILTER"* ]] || continue
  _run "$fn" "$fn"
done

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
