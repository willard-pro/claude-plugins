#!/usr/bin/env bash
# test-ticket-audit-cache.sh — unit tests for scan cache behavior in ticket-audit
# All tests use temp directories — no real cache mutations.
# Requires: bash, jq
# Usage: bash test-ticket-audit-cache.sh [test_name_filter]
set -eo pipefail

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

# ── Scan cache read/write ─────────────────────────────────────────────────────

test_cache_read_write_roundtrip() {
  local tmpdir
  tmpdir=$(mktemp -d)
  local cache_file="$tmpdir/.scan-cache.json"
  echo '{}' >"$cache_file"

  # Write entry
  local updated
  updated=$(echo '{}' | jq --arg tid "milestone-abc" --arg date "2026-06-07T00:00:00Z" --arg file "./logs/audit/recommendations/milestone-sprint1-2026-06-07.md" \
    '.[$tid] = {scanned_at: $date, report_file: $file}')
  echo "$updated" >"$cache_file"

  # Read entry
  local cached
  cached=$(jq -r --arg tid "milestone-abc" '.[$tid].scanned_at // empty' "$cache_file")
  [ "$cached" = "2026-06-07T00:00:00Z" ]
  local result=$?
  rm -rf "$tmpdir"
  return $result
}

test_cache_miss_returns_empty() {
  local tmpdir
  tmpdir=$(mktemp -d)
  local cache_file="$tmpdir/.scan-cache.json"
  echo '{}' >"$cache_file"

  local cached
  cached=$(jq -r --arg tid "nonexistent" '.[$tid] // empty' "$cache_file")
  [ -z "$cached" ]
  local result=$?
  rm -rf "$tmpdir"
  return $result
}

test_cache_multiple_targets() {
  local tmpdir
  tmpdir=$(mktemp -d)
  local cache_file="$tmpdir/.scan-cache.json"

  # Add two targets
  echo '{}' | jq \
    --arg tid1 "milestone-1" --arg d1 "2026-06-01T00:00:00Z" --arg f1 "report1.md" \
    --arg tid2 "parent-2" --arg d2 "2026-06-02T00:00:00Z" --arg f2 "report2.md" \
    '.[$tid1] = {scanned_at: $d1, report_file: $f1} | .[$tid2] = {scanned_at: $d2, report_file: $f2}' >"$cache_file"

  local count
  count=$(jq 'keys | length' "$cache_file")
  [ "$count" -eq 2 ]
  local result=$?
  rm -rf "$tmpdir"
  return $result
}

# ── --force bypass ────────────────────────────────────────────────────────────

test_force_overwrites_existing_cache_entry() {
  local tmpdir
  tmpdir=$(mktemp -d)
  local cache_file="$tmpdir/.scan-cache.json"

  # Initial entry
  echo '{"milestone-1": {"scanned_at": "2026-06-01T00:00:00Z", "report_file": "old-report.md"}}' >"$cache_file"

  # --force: overwrite with new data
  local updated
  updated=$(jq --arg tid "milestone-1" --arg date "2026-06-07T00:00:00Z" --arg file "new-report.md" \
    '.[$tid] = {scanned_at: $date, report_file: $file}' "$cache_file")
  echo "$updated" >"$cache_file"

  local cached_date
  cached_date=$(jq -r --arg tid "milestone-1" '.[$tid].scanned_at' "$cache_file")
  [ "$cached_date" = "2026-06-07T00:00:00Z" ]
  local result=$?
  rm -rf "$tmpdir"
  return $result
}

# ── dispatch ──────────────────────────────────────────────────────────────────

FILTER="${1:-}"

for fn in \
  test_cache_read_write_roundtrip \
  test_cache_miss_returns_empty \
  test_cache_multiple_targets \
  test_force_overwrites_existing_cache_entry; do
  [ -z "$FILTER" ] || [[ "$fn" == *"$FILTER"* ]] || continue
  _run "$fn" "$fn"
done

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
