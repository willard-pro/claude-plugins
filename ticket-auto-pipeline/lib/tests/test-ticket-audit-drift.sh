#!/usr/bin/env bash
# test-ticket-audit-drift.sh — unit tests for audit-drift-check.sh
# Tests changed ticket detection, new ticket detection, and no-change fast path.
# Requires: bash, jq
# Usage: bash test-ticket-audit-drift.sh [test_name_filter]
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Source the helper to get the audit_drift_check function
source "$LIB_DIR/audit-drift-check.sh"

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

# ── Drift detection ───────────────────────────────────────────────────────────

test_changed_ticket_triggers_drift() {
  local tmpdir
  tmpdir=$(mktemp -d)
  local snapshot="$tmpdir/snapshot.json"
  local current="$tmpdir/current.json"

  echo '[{"id":"i1","updatedAt":"2026-06-01T00:00:00Z"}]' > "$snapshot"
  echo '[{"id":"i1","updatedAt":"2026-06-07T00:00:00Z"}]' > "$current"

  local output
  output=$(audit_drift_check "$snapshot" "$current" 2>/dev/null)
  eval "$output"
  [ -n "${CHANGED_IDS:-}" ]
  local result=$?
  rm -rf "$tmpdir"
  return $result
}

test_new_ticket_triggers_drift() {
  local tmpdir
  tmpdir=$(mktemp -d)
  local snapshot="$tmpdir/snapshot.json"
  local current="$tmpdir/current.json"

  echo '[{"id":"i1","updatedAt":"2026-06-01T00:00:00Z"}]' > "$snapshot"
  echo '[{"id":"i1","updatedAt":"2026-06-01T00:00:00Z"},{"id":"i2","updatedAt":"2026-06-07T00:00:00Z"}]' > "$current"

  local output
  output=$(audit_drift_check "$snapshot" "$current" 2>/dev/null)
  eval "$output"
  [ -n "${NEW_IDS:-}" ]
  local result=$?
  rm -rf "$tmpdir"
  return $result
}

test_no_change_no_drift() {
  local tmpdir
  tmpdir=$(mktemp -d)
  local snapshot="$tmpdir/snapshot.json"
  local current="$tmpdir/current.json"

  echo '[{"id":"i1","updatedAt":"2026-06-01T00:00:00Z"}]' > "$snapshot"
  echo '[{"id":"i1","updatedAt":"2026-06-01T00:00:00Z"}]' > "$current"

  local output
  output=$(audit_drift_check "$snapshot" "$current" 2>/dev/null)
  eval "$output"
  [ -z "${CHANGED_IDS:-}" ] && [ -z "${NEW_IDS:-}" ]
  local result=$?
  rm -rf "$tmpdir"
  return $result
}

test_older_timestamp_not_changed() {
  local tmpdir
  tmpdir=$(mktemp -d)
  local snapshot="$tmpdir/snapshot.json"
  local current="$tmpdir/current.json"

  echo '[{"id":"i1","updatedAt":"2026-06-07T00:00:00Z"}]' > "$snapshot"
  echo '[{"id":"i1","updatedAt":"2026-06-01T00:00:00Z"}]' > "$current"

  local output
  output=$(audit_drift_check "$snapshot" "$current" 2>/dev/null)
  eval "$output"
  [ -z "${CHANGED_IDS:-}" ]
  local result=$?
  rm -rf "$tmpdir"
  return $result
}

# ── dispatch ──────────────────────────────────────────────────────────────────

FILTER="${1:-}"

for fn in \
  test_changed_ticket_triggers_drift \
  test_new_ticket_triggers_drift \
  test_no_change_no_drift \
  test_older_timestamp_not_changed; do
  [ -z "$FILTER" ] || [[ "$fn" == *"$FILTER"* ]] || continue
  _run "$fn" "$fn"
done

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
