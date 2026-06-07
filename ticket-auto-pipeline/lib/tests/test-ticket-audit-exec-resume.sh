#!/usr/bin/env bash
# test-ticket-audit-exec-resume.sh — unit tests for write-ahead crash recovery.
# Tests [>] resume behavior, [x]/[!] transitions, archive blocking.
# Requires: bash, jq, ticket-audit-exec.sh (sourced)
# Usage: bash test-ticket-audit-exec-resume.sh [test_name_filter]
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

# ── Global test state (set by setup, read by tests) ───────────────────────────

_TEST_TMPDIR=""

# setup_test_file — creates temp dir + recommendation file with all item states.
# Sets _TEST_TMPDIR as global. Must NOT be called via $(...).
setup_test_file() {
  _TEST_TMPDIR=$(mktemp -d)
  mkdir -p "$_TEST_TMPDIR/recommendations" "$_TEST_TMPDIR/archive"
  # Override AUDIT_DIR for test scope (used by archive_checklist)
  export AUDIT_DIR="$_TEST_TMPDIR"

  local recfile="$_TEST_TMPDIR/recommendations/test-audit-$(date +%s).md"
  cat > "$recfile" <<'EOF'
# Audit Recommendations: test-audit (2026-06-07)
Source: test-milestone-abc
Generated: 2026-06-07T12:00:00Z
Phase: needs-info

## Audit Summary
Test audit.

## Goal Context
**Milestone:** Test Milestone
**Goal:** Test goal.

## Ticket Inventory
| ID | Title | State | Assignee | Last Updated |
|---|---|---|---|---|
| WIL-100 | Test ticket | Todo | — | 2026-06-01 |

## Needs Info (run 1 — delegate to ticket-critique)
- [ ] WIL-100 — needs-info: missing repro steps
- [>] WIL-101 — needs-info: scope unclear
- [x] WIL-102 — needs-info: already critiqued
- [!] WIL-103 — needs-info: ticket not found

## Structural (run 2 — post comments only)
- [ ] WIL-200 — merge candidate: duplicate of WIL-201
- [>] WIL-202 — split candidate: 6 ACs across 2 services
- [x] WIL-203 — duplicate: posted
- [!] WIL-204 — drift: comment failed
EOF

  echo "$recfile"
}

cleanup() {
  if [ -n "${_TEST_TMPDIR:-}" ] && [ -d "$_TEST_TMPDIR" ]; then
    rm -rf "$_TEST_TMPDIR"
  fi
}

# Source the lib
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_LIB="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$PLUGIN_LIB/ticket-audit-exec.sh"

# ── Resume tests ───────────────────────────────────────────────────────────────

test_resumed_item_is_parsed_as_pending() {
  setup_test_file
  local recfile
  recfile=$(ls -1t "$_TEST_TMPDIR/recommendations/"*.md | head -1)

  local checklist
  checklist=$(parse_checklist "$recfile")

  # WIL-101 has [>] — should be "resumed" state
  local state101
  state101=$(echo "$checklist" | jq -r '.needs_info_items[] | select(.ticket_id == "WIL-101") | .state')
  if [ "$state101" != "resumed" ]; then
    echo "expected resumed, got $state101"
    cleanup; return 1
  fi

  # WIL-101 should count toward pending
  local pending
  pending=$(echo "$checklist" | jq -r '.pending_needs_info')
  if [ "$pending" -lt 1 ]; then
    echo "expected >=1 pending, got $pending"
    cleanup; return 1
  fi

  cleanup; return 0
}

test_pending_item_parsed_correctly() {
  setup_test_file
  local recfile
  recfile=$(ls -1t "$_TEST_TMPDIR/recommendations/"*.md | head -1)

  local checklist
  checklist=$(parse_checklist "$recfile")

  local state100
  state100=$(echo "$checklist" | jq -r '.needs_info_items[] | select(.ticket_id == "WIL-100") | .state')
  if [ "$state100" != "pending" ]; then
    echo "expected pending, got $state100"
    cleanup; return 1
  fi

  cleanup; return 0
}

test_complete_item_is_skipped() {
  setup_test_file
  local recfile
  recfile=$(ls -1t "$_TEST_TMPDIR/recommendations/"*.md | head -1)

  local checklist
  checklist=$(parse_checklist "$recfile")

  local state102
  state102=$(echo "$checklist" | jq -r '.needs_info_items[] | select(.ticket_id == "WIL-102") | .state')
  if [ "$state102" != "complete" ]; then
    echo "expected complete, got $state102"
    cleanup; return 1
  fi

  # Complete + failed items should NOT count toward pending
  local pending
  pending=$(echo "$checklist" | jq -r '.pending_needs_info')
  # WIL-100 pending + WIL-101 resumed = 2; WIL-102 complete + WIL-103 failed don't count
  if [ "$pending" -ne 2 ]; then
    echo "expected 2 pending, got $pending"
    cleanup; return 1
  fi

  cleanup; return 0
}

test_failed_item_is_skipped() {
  setup_test_file
  local recfile
  recfile=$(ls -1t "$_TEST_TMPDIR/recommendations/"*.md | head -1)

  local checklist
  checklist=$(parse_checklist "$recfile")

  local state103
  state103=$(echo "$checklist" | jq -r '.needs_info_items[] | select(.ticket_id == "WIL-103") | .state')
  if [ "$state103" != "failed" ]; then
    echo "expected failed, got $state103"
    cleanup; return 1
  fi

  cleanup; return 0
}

# ── Write-ahead mark tests ─────────────────────────────────────────────────────

test_write_ahead_marks_pending_as_resumed() {
  setup_test_file
  local recfile
  recfile=$(ls -1t "$_TEST_TMPDIR/recommendations/"*.md | head -1)

  write_ahead_mark "$recfile" "WIL-100"

  if grep -q "\- \[>\] WIL-100 " "$recfile"; then
    cleanup; return 0
  else
    echo "WIL-100 not marked [>]"
    cleanup; return 1
  fi
}

test_write_ahead_is_idempotent_on_resumed() {
  setup_test_file
  local recfile
  recfile=$(ls -1t "$_TEST_TMPDIR/recommendations/"*.md | head -1)

  # Already [>] — write_ahead should leave it as [>]
  write_ahead_mark "$recfile" "WIL-101"

  if grep -q "\- \[>\] WIL-101 " "$recfile"; then
    cleanup; return 0
  else
    echo "WIL-101 should remain [>]"
    cleanup; return 1
  fi
}

test_mark_done_sets_complete() {
  setup_test_file
  local recfile
  recfile=$(ls -1t "$_TEST_TMPDIR/recommendations/"*.md | head -1)

  mark_item_done "$recfile" "WIL-100"

  if grep -q "\- \[x\] WIL-100 " "$recfile"; then
    cleanup; return 0
  else
    echo "WIL-100 not marked [x]"
    cleanup; return 1
  fi
}

test_mark_failed_sets_failed() {
  setup_test_file
  local recfile
  recfile=$(ls -1t "$_TEST_TMPDIR/recommendations/"*.md | head -1)

  mark_item_failed "$recfile" "WIL-100"

  if grep -q "\- \[!\] WIL-100 " "$recfile"; then
    cleanup; return 0
  else
    echo "WIL-100 not marked [!]"
    cleanup; return 1
  fi
}

# ── Archive tests ──────────────────────────────────────────────────────────────

test_failed_does_not_block_archive() {
  setup_test_file
  local recfile
  recfile=$(ls -1t "$_TEST_TMPDIR/recommendations/"*.md | head -1)

  # Mark all items as [x] or [!] (no [ ] or [>] remaining)
  sed -i 's/- \[ \] WIL-100/- [x] WIL-100/' "$recfile"
  sed -i 's/- \[>\] WIL-101/- [!] WIL-101/' "$recfile"
  sed -i 's/- \[ \] WIL-200/- [x] WIL-200/' "$recfile"
  sed -i 's/- \[>\] WIL-202/- [!] WIL-202/' "$recfile"

  # Advance phase to structural-done
  advance_phase "$recfile" "structural-done"

  # No pending items should remain
  if has_pending_items "$recfile"; then
    echo "should have no pending items"
    cleanup; return 1
  fi

  # Archive should succeed
  local archive_result
  archive_result=$(archive_checklist "$recfile")
  if echo "$archive_result" | grep -q "ARCHIVE_PATH="; then
    cleanup; return 0
  else
    echo "archive failed: $archive_result"
    cleanup; return 1
  fi
}

test_pending_items_block_archive() {
  setup_test_file
  local recfile
  recfile=$(ls -1t "$_TEST_TMPDIR/recommendations/"*.md | head -1)

  # WIL-100 and WIL-200 are still [ ] — should have pending items
  if has_pending_items "$recfile"; then
    cleanup; return 0
  else
    echo "should have pending items"
    cleanup; return 1
  fi
}

# ── Phase advance tests ────────────────────────────────────────────────────────

test_advance_phase_needs_info_to_done() {
  setup_test_file
  local recfile
  recfile=$(ls -1t "$_TEST_TMPDIR/recommendations/"*.md | head -1)

  advance_phase "$recfile" "needs-info-done"

  if grep -q '^Phase: needs-info-done' "$recfile"; then
    cleanup; return 0
  else
    echo "phase not advanced to needs-info-done"
    cleanup; return 1
  fi
}

test_advance_phase_to_structural_done() {
  setup_test_file
  local recfile
  recfile=$(ls -1t "$_TEST_TMPDIR/recommendations/"*.md | head -1)

  advance_phase "$recfile" "structural-done"

  if grep -q '^Phase: structural-done' "$recfile"; then
    cleanup; return 0
  else
    echo "phase not advanced to structural-done"
    cleanup; return 1
  fi
}

test_advance_phase_rejects_invalid_phase() {
  setup_test_file
  local recfile
  recfile=$(ls -1t "$_TEST_TMPDIR/recommendations/"*.md | head -1)

  if advance_phase "$recfile" "bogus-phase" 2>/dev/null; then
    echo "should have rejected bogus phase"
    cleanup; return 1
  fi

  cleanup; return 0
}

# ── dispatch ──────────────────────────────────────────────────────────────────

FILTER="${1:-}"

for fn in \
  test_resumed_item_is_parsed_as_pending \
  test_pending_item_parsed_correctly \
  test_complete_item_is_skipped \
  test_failed_item_is_skipped \
  test_write_ahead_marks_pending_as_resumed \
  test_write_ahead_is_idempotent_on_resumed \
  test_mark_done_sets_complete \
  test_mark_failed_sets_failed \
  test_failed_does_not_block_archive \
  test_pending_items_block_archive \
  test_advance_phase_needs_info_to_done \
  test_advance_phase_to_structural_done \
  test_advance_phase_rejects_invalid_phase; do
  [ -z "$FILTER" ] || [[ "$fn" == *"$FILTER"* ]] || continue
  _run "$fn" "$fn"
done

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
