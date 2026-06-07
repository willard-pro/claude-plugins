#!/usr/bin/env bash
# test-ticket-audit-exec-phase-gate.sh — unit tests for phase gating logic.
# Tests: blank phase → needs-info, phase gate blocks/permits, empty section fast-paths,
# structural-done → archive-only.
# Requires: bash, jq, ticket-audit-exec.sh (sourced)
# Usage: bash test-ticket-audit-exec-phase-gate.sh [test_name_filter]
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

# ── Global test state ──────────────────────────────────────────────────────────

_TEST_TMPDIR=""

# make_file <phase> <needs_info_content> <structural_content>
# Creates recommendation file with given Phase and section content.
# Sets _TEST_TMPDIR as global. Must NOT be called via $(...).
make_file() {
  local phase="$1"
  local ni_content="$2"
  local st_content="$3"

  _TEST_TMPDIR=$(mktemp -d)
  mkdir -p "$_TEST_TMPDIR/recommendations" "$_TEST_TMPDIR/archive"
  export AUDIT_DIR="$_TEST_TMPDIR"

  local recfile="$_TEST_TMPDIR/recommendations/test-phase-$(date +%s).md"
  cat >"$recfile" <<HEADER
# Audit Recommendations: test-phase
Source: test-phase-source
Generated: 2026-06-07T12:00:00Z
Phase: ${phase}

## Audit Summary
Test.

## Goal Context
**Milestone:** Test

## Ticket Inventory
| ID | Title | State |
|---|---|---|
| WIL-1 | Test | Todo |

## Needs Info
${ni_content:-No issues.}

## Structural
${st_content:-No issues.}
HEADER

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

# ── Phase parsing tests ────────────────────────────────────────────────────────

test_blank_phase_treated_as_needs_info() {
  make_file "" "" ""
  local recfile
  recfile=$(ls -1t "$_TEST_TMPDIR/recommendations/"*.md | head -1)

  local checklist
  checklist=$(parse_checklist "$recfile")
  local phase
  phase=$(echo "$checklist" | jq -r '.phase')

  if [ "$phase" = "needs-info" ]; then
    cleanup
    return 0
  else
    echo "expected needs-info, got $phase"
    cleanup
    return 1
  fi
}

test_unknown_phase_treated_as_needs_info() {
  _TEST_TMPDIR=$(mktemp -d)
  mkdir -p "$_TEST_TMPDIR/recommendations" "$_TEST_TMPDIR/archive"
  export AUDIT_DIR="$_TEST_TMPDIR"

  cat >"$_TEST_TMPDIR/recommendations/test-bad.md" <<'EOF'
# Audit
Source: test
Phase: bogus-value

## Needs Info
- [ ] WIL-1 — test
## Structural
EOF

  local checklist
  checklist=$(parse_checklist "$_TEST_TMPDIR/recommendations/test-bad.md")
  local phase
  phase=$(echo "$checklist" | jq -r '.phase')

  if [ "$phase" = "needs-info" ]; then
    cleanup
    return 0
  else
    echo "expected needs-info for bogus, got $phase"
    cleanup
    return 1
  fi
}

test_needs_info_phase_parsed_correctly() {
  make_file "needs-info" "- [ ] WIL-1 — needs-info: test" ""
  local recfile
  recfile=$(ls -1t "$_TEST_TMPDIR/recommendations/"*.md | head -1)

  local checklist
  checklist=$(parse_checklist "$recfile")
  local phase
  phase=$(echo "$checklist" | jq -r '.phase')

  if [ "$phase" = "needs-info" ]; then
    cleanup
    return 0
  else
    echo "expected needs-info, got $phase"
    cleanup
    return 1
  fi
}

test_needs_info_done_phase_parsed_correctly() {
  make_file "needs-info-done" "- [x] WIL-1 — test" "- [ ] WIL-2 — merge candidate"
  local recfile
  recfile=$(ls -1t "$_TEST_TMPDIR/recommendations/"*.md | head -1)

  local checklist
  checklist=$(parse_checklist "$recfile")
  local phase
  phase=$(echo "$checklist" | jq -r '.phase')

  if [ "$phase" = "needs-info-done" ]; then
    cleanup
    return 0
  else
    echo "expected needs-info-done, got $phase"
    cleanup
    return 1
  fi
}

test_structural_done_phase_parsed_correctly() {
  make_file "structural-done" "- [x] WIL-1 — test" "- [x] WIL-2 — done"
  local recfile
  recfile=$(ls -1t "$_TEST_TMPDIR/recommendations/"*.md | head -1)

  local checklist
  checklist=$(parse_checklist "$recfile")
  local phase
  phase=$(echo "$checklist" | jq -r '.phase')

  if [ "$phase" = "structural-done" ]; then
    cleanup
    return 0
  else
    echo "expected structural-done, got $phase"
    cleanup
    return 1
  fi
}

# ── Phase gate tests ───────────────────────────────────────────────────────────

test_needs_info_phase_blocks_structural() {
  make_file "needs-info" "- [ ] WIL-1 — needs-info: test" "- [ ] WIL-2 — merge candidate"
  local recfile
  recfile=$(ls -1t "$_TEST_TMPDIR/recommendations/"*.md | head -1)

  local checklist
  checklist=$(parse_checklist "$recfile")
  local phase pst
  phase=$(echo "$checklist" | jq -r '.phase')
  pst=$(echo "$checklist" | jq -r '.pending_structural')

  if [ "$phase" = "needs-info" ] && [ "$pst" -gt 0 ]; then
    cleanup
    return 0
  else
    echo "expected needs-info phase with >0 pending structural"
    cleanup
    return 1
  fi
}

test_needs_info_done_permits_structural() {
  make_file "needs-info-done" "- [x] WIL-1 — done" "- [ ] WIL-2 — merge candidate"
  local recfile
  recfile=$(ls -1t "$_TEST_TMPDIR/recommendations/"*.md | head -1)

  local checklist
  checklist=$(parse_checklist "$recfile")
  local phase pst
  phase=$(echo "$checklist" | jq -r '.phase')
  pst=$(echo "$checklist" | jq -r '.pending_structural')

  if [ "$phase" = "needs-info-done" ] && [ "$pst" -gt 0 ]; then
    cleanup
    return 0
  else
    echo "expected needs-info-done with >0 pending structural"
    cleanup
    return 1
  fi
}

test_structural_done_no_reprocessing() {
  make_file "structural-done" "- [x] WIL-1 — done" "- [x] WIL-2 — done"
  local recfile
  recfile=$(ls -1t "$_TEST_TMPDIR/recommendations/"*.md | head -1)

  local checklist
  checklist=$(parse_checklist "$recfile")
  local phase pst
  phase=$(echo "$checklist" | jq -r '.phase')
  pst=$(echo "$checklist" | jq -r '.pending_structural')

  if [ "$phase" = "structural-done" ] && [ "$pst" -eq 0 ]; then
    cleanup
    return 0
  else
    echo "expected structural-done with 0 pending"
    cleanup
    return 1
  fi
}

# ── Empty section fast-path tests ──────────────────────────────────────────────

test_empty_needs_info_fast_path() {
  make_file "needs-info" "" "- [ ] WIL-2 — merge candidate"
  local recfile
  recfile=$(ls -1t "$_TEST_TMPDIR/recommendations/"*.md | head -1)

  local checklist
  checklist=$(parse_checklist "$recfile")
  local pni pst
  pni=$(echo "$checklist" | jq -r '.pending_needs_info')
  pst=$(echo "$checklist" | jq -r '.pending_structural')

  if [ "$pni" -eq 0 ] && [ "$pst" -gt 0 ]; then
    cleanup
    return 0
  else
    echo "expected 0 pending needs-info, >0 structural"
    cleanup
    return 1
  fi
}

test_empty_structural_fast_path() {
  make_file "needs-info-done" "- [x] WIL-1 — done" ""
  local recfile
  recfile=$(ls -1t "$_TEST_TMPDIR/recommendations/"*.md | head -1)

  local checklist
  checklist=$(parse_checklist "$recfile")
  local pst
  pst=$(echo "$checklist" | jq -r '.pending_structural')

  if [ "$pst" -eq 0 ]; then
    cleanup
    return 0
  else
    echo "expected 0 pending structural, got $pst"
    cleanup
    return 1
  fi
}

test_both_sections_empty_proceeds_to_archive() {
  make_file "needs-info-done" "- [x] WIL-1 — done" "- [x] WIL-2 — done"
  local recfile
  recfile=$(ls -1t "$_TEST_TMPDIR/recommendations/"*.md | head -1)

  local checklist
  checklist=$(parse_checklist "$recfile")
  local pni pst
  pni=$(echo "$checklist" | jq -r '.pending_needs_info')
  pst=$(echo "$checklist" | jq -r '.pending_structural')

  if [ "$pni" -ne 0 ] || [ "$pst" -ne 0 ]; then
    echo "expected 0 pending in both sections"
    cleanup
    return 1
  fi

  # Should be able to archive
  advance_phase "$recfile" "structural-done"
  if has_pending_items "$recfile"; then
    echo "should have no pending items"
    cleanup
    return 1
  fi

  cleanup
  return 0
}

# ── dispatch ──────────────────────────────────────────────────────────────────

FILTER="${1:-}"

for fn in \
  test_blank_phase_treated_as_needs_info \
  test_unknown_phase_treated_as_needs_info \
  test_needs_info_phase_parsed_correctly \
  test_needs_info_done_phase_parsed_correctly \
  test_structural_done_phase_parsed_correctly \
  test_needs_info_phase_blocks_structural \
  test_needs_info_done_permits_structural \
  test_structural_done_no_reprocessing \
  test_empty_needs_info_fast_path \
  test_empty_structural_fast_path \
  test_both_sections_empty_proceeds_to_archive; do
  [ -z "$FILTER" ] || [[ "$fn" == *"$FILTER"* ]] || continue
  _run "$fn" "$fn"
done

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
