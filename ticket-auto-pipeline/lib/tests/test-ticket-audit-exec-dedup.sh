#!/usr/bin/env bash
# test-ticket-audit-exec-dedup.sh — unit tests for dedup guard integration.
# Tests: guard exit 0 → skip, guard exit 1 → proceed, double-invocation after crash.
# Mocks audit-comment-guard.sh behavior via a test double.
# Requires: bash, jq, ticket-audit-exec.sh (sourced)
# Usage: bash test-ticket-audit-exec-dedup.sh [test_name_filter]
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
_TEST_GUARD_RESPONSE=""
_TEST_GUARD_LOG=""

# ── Setup helpers ──────────────────────────────────────────────────────────────

# setup_mock_env — creates temp dir, mock guard, sources lib.
# Sets _TEST_TMPDIR, _TEST_GUARD_RESPONSE, _TEST_GUARD_LOG as globals.
# Must NOT be called via $(...) — sets globals, not stdout.
setup_mock_env() {
  _TEST_TMPDIR=$(mktemp -d)
  mkdir -p "$_TEST_TMPDIR/recommendations" "$_TEST_TMPDIR/archive" "$_TEST_TMPDIR/lib"
  export AUDIT_DIR="$_TEST_TMPDIR"

  # Create a mock audit-comment-guard.sh that we control
  cat >"$_TEST_TMPDIR/lib/audit-comment-guard.sh" <<'MOCK'
#!/usr/bin/env bash
resp_file="${_TEST_GUARD_RESPONSE:-/tmp/guard-response}"
if [ -f "$resp_file" ]; then
  resp=$(cat "$resp_file")
  case "$resp" in
    found*) exit 0 ;;
    error*) exit 2 ;;
    *) exit 1 ;;
  esac
fi
exit 1
MOCK
  chmod +x "$_TEST_TMPDIR/lib/audit-comment-guard.sh"
  _TEST_GUARD_LOG="$_TEST_TMPDIR/guard.log"
  _TEST_GUARD_RESPONSE="$_TEST_TMPDIR/guard-response"
  export _TEST_GUARD_RESPONSE _TEST_GUARD_LOG
}

# setup_test_recfile <tmpdir>
# Creates a test recommendation file in tmpdir/recommendations/.
# Echoes the file path (safe for $(...) capture).
setup_test_recfile() {
  local tmpdir="$1"
  local recfile="$tmpdir/recommendations/test-dedup-$(date +%s).md"
  cat >"$recfile" <<'EOF'
# Audit Recommendations: dedup-test
Source: dedup-test-source
Generated: 2026-06-07T12:00:00Z
Phase: needs-info

## Audit Summary
Dedup test.

## Goal Context
**Milestone:** Test

## Ticket Inventory
| ID | Title | State |
|---|---|---|
| WIL-1 | Test | Todo |

## Needs Info
- [ ] WIL-1 — needs-info: missing repro steps
- [ ] WIL-2 — needs-info: scope unclear

## Structural
- [ ] WIL-10 — merge candidate: duplicate of WIL-11
- [ ] WIL-12 — split candidate: too large
EOF
  echo "$recfile"
}

# cleanup — removes temp dir if set
cleanup() {
  if [ -n "${_TEST_TMPDIR:-}" ] && [ -d "$_TEST_TMPDIR" ]; then
    rm -rf "$_TEST_TMPDIR"
  fi
}

# Source the real lib (functions don't depend on AUDIT_DIR for mark/done/failed)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_LIB="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$PLUGIN_LIB/ticket-audit-exec.sh"

# ── Dedup guard: existing comment found (exit 0) ──────────────────────────────

test_guard_exit_0_item_marked_done() {
  setup_mock_env
  local recfile
  recfile=$(setup_test_recfile "$_TEST_TMPDIR")

  # Set guard to return "found" (exit 0)
  echo "found" >"$_TEST_GUARD_RESPONSE"

  # Simulate: guard exits 0 → should mark item [x], skip delegation
  GUARD_SOURCE="dedup-test-source:WIL-1:needs-info"
  if bash "$_TEST_TMPDIR/lib/audit-comment-guard.sh" "WIL-1" "$GUARD_SOURCE"; then
    mark_item_done "$recfile" "WIL-1"
  fi

  # Verify WIL-1 is now [x]
  if grep -q "\- \[x\] WIL-1 " "$recfile"; then
    cleanup
    return 0
  else
    echo "WIL-1 should be [x] after dedup match"
    cleanup
    return 1
  fi
}

test_guard_exit_0_skips_delegation() {
  setup_mock_env
  local recfile
  recfile=$(setup_test_recfile "$_TEST_TMPDIR")

  # Set guard to "found" (exit 0) for WIL-2
  echo "found" >"$_TEST_GUARD_RESPONSE"

  GUARD_SOURCE="dedup-test-source:WIL-2:needs-info"
  if bash "$_TEST_TMPDIR/lib/audit-comment-guard.sh" "WIL-2" "$GUARD_SOURCE"; then
    mark_item_done "$recfile" "WIL-2"
    # In real flow, delegation would be skipped here
  fi

  # WIL-2 should be [x], WIL-1 should still be [ ]
  if grep -q "\- \[x\] WIL-2 " "$recfile" && grep -q "\- \[ \] WIL-1 " "$recfile"; then
    cleanup
    return 0
  else
    echo "WIL-2 should be [x], WIL-1 should still be [ ]"
    cleanup
    return 1
  fi
}

# ── Dedup guard: no existing comment (exit 1) ──────────────────────────────────

test_guard_exit_1_proceeds() {
  setup_mock_env
  local recfile
  recfile=$(setup_test_recfile "$_TEST_TMPDIR")

  # No response file → guard exits 1
  rm -f "$_TEST_GUARD_RESPONSE"

  GUARD_SOURCE="dedup-test-source:WIL-1:needs-info"
  if ! bash "$_TEST_TMPDIR/lib/audit-comment-guard.sh" "WIL-1" "$GUARD_SOURCE"; then
    # Guard didn't find existing → proceed with delegation
    write_ahead_mark "$recfile" "WIL-1"
    # (in real flow, ticket-critique would be called here)
    # Simulate success:
    mark_item_done "$recfile" "WIL-1"
  fi

  # WIL-1 should be [x]
  if grep -q "\- \[x\] WIL-1 " "$recfile"; then
    cleanup
    return 0
  else
    echo "WIL-1 should be [x] after processing"
    cleanup
    return 1
  fi
}

# ── Double invocation after crash (resume dedup) ──────────────────────────────

test_crash_resume_deduplicates() {
  setup_mock_env
  local recfile
  recfile=$(setup_test_recfile "$_TEST_TMPDIR")

  # Simulate first invocation: guard says not found → post comment → crash before marking [x]
  rm -f "$_TEST_GUARD_RESPONSE"
  GUARD_SOURCE="dedup-test-source:WIL-10:structural"
  if ! bash "$_TEST_TMPDIR/lib/audit-comment-guard.sh" "WIL-10" "$GUARD_SOURCE"; then
    write_ahead_mark "$recfile" "WIL-10"
    # Comment posted successfully (simulated)
    # CRASH happens here — before mark_item_done
  fi

  # Verify WIL-10 is [>] (crashed in-progress)
  if ! grep -q "\- \[>\] WIL-10 " "$recfile"; then
    echo "WIL-10 should be [>] after crash"
    cleanup
    return 1
  fi

  # Second invocation: guard now finds the comment posted before crash
  echo "found" >"$_TEST_GUARD_RESPONSE"

  # parse_checklist sees [>] as resumed (treated as pending)
  local checklist
  checklist=$(parse_checklist "$recfile")
  local state10
  state10=$(echo "$checklist" | jq -r '.structural_items[] | select(.ticket_id == "WIL-10") | .state')
  if [ "$state10" != "resumed" ]; then
    echo "WIL-10 should be resumed, got $state10"
    cleanup
    return 1
  fi

  # Re-process: guard matches → mark [x], no second comment
  if bash "$_TEST_TMPDIR/lib/audit-comment-guard.sh" "WIL-10" "$GUARD_SOURCE"; then
    mark_item_done "$recfile" "WIL-10"
  fi

  # WIL-10 should now be [x]
  if grep -q "\- \[x\] WIL-10 " "$recfile"; then
    cleanup
    return 0
  else
    echo "WIL-10 should be [x] after dedup"
    cleanup
    return 1
  fi
}

test_double_invocation_no_double_comment() {
  setup_mock_env
  local recfile
  recfile=$(setup_test_recfile "$_TEST_TMPDIR")

  # First run: no existing comment → post → mark [x]
  rm -f "$_TEST_GUARD_RESPONSE"
  GUARD_SOURCE="dedup-test-source:WIL-12:structural"
  if ! bash "$_TEST_TMPDIR/lib/audit-comment-guard.sh" "WIL-12" "$GUARD_SOURCE"; then
    write_ahead_mark "$recfile" "WIL-12"
    # Comment posted
    mark_item_done "$recfile" "WIL-12"
  fi

  # Second run: re-parse — WIL-12 is now [x] (complete), should be skipped
  local checklist
  checklist=$(parse_checklist "$recfile")
  local state12
  state12=$(echo "$checklist" | jq -r '.structural_items[] | select(.ticket_id == "WIL-12") | .state')
  if [ "$state12" != "complete" ]; then
    echo "WIL-12 should be complete, got $state12"
    cleanup
    return 1
  fi

  # Verify only one WIL-12 line exists (not double-marked)
  local count
  count=$(grep -c "WIL-12" "$recfile" || true)
  if [ "$count" -ne 1 ]; then
    echo "WIL-12 should appear exactly once, got $count"
    cleanup
    return 1
  fi

  cleanup
  return 0
}

# ── Multi-ticket extraction tests ──────────────────────────────────────────────

test_multi_ticket_extraction_merge_candidate() {
  setup_mock_env
  local recfile
  recfile=$(setup_test_recfile "$_TEST_TMPDIR")

  # Parse the test file — WIL-10 is "merge candidate: duplicate of WIL-11"
  local checklist
  checklist=$(parse_checklist "$recfile")
  local all_tids10
  all_tids10=$(echo "$checklist" | jq -r '.structural_items[] | select(.ticket_id == "WIL-10") | .all_ticket_ids')

  # Should include BOTH WIL-10 and WIL-11
  if echo "$all_tids10" | grep -q "WIL-10" && echo "$all_tids10" | grep -q "WIL-11"; then
    cleanup
    return 0
  else
    echo "expected all_ticket_ids to contain WIL-10 and WIL-11, got: $all_tids10"
    cleanup
    return 1
  fi
}

test_detail_clean_strips_finding_type_prefix() {
  setup_mock_env
  local recfile
  recfile=$(setup_test_recfile "$_TEST_TMPDIR")

  local checklist
  checklist=$(parse_checklist "$recfile")

  # WIL-1 detail: "needs-info: missing repro steps" → detail_clean: "missing repro steps"
  local detail_clean_1
  detail_clean_1=$(echo "$checklist" | jq -r '.needs_info_items[] | select(.ticket_id == "WIL-1") | .detail_clean')
  if [ "$detail_clean_1" = "missing repro steps" ]; then
    cleanup
    return 0
  else
    echo "expected 'missing repro steps', got '$detail_clean_1'"
    cleanup
    return 1
  fi
}

test_comment_body_no_redundancy() {
  setup_mock_env
  local recfile
  recfile=$(setup_test_recfile "$_TEST_TMPDIR")

  local checklist
  checklist=$(parse_checklist "$recfile")

  # WIL-10: "merge candidate: duplicate of WIL-11 (Jaccard: 88%)"
  local detail
  detail=$(echo "$checklist" | jq -r '.structural_items[] | select(.ticket_id == "WIL-10") | .detail')
  local detail_clean
  detail_clean=$(echo "$checklist" | jq -r '.structural_items[] | select(.ticket_id == "WIL-10") | .detail_clean')

  # detail_clean should NOT contain the finding type prefix from detail
  if echo "$detail" | grep -q "^merge candidate: " && echo "$detail_clean" | grep -qv "^merge candidate: "; then
    cleanup
    return 0
  else
    echo "detail_clean should strip 'merge candidate: ' prefix"
    cleanup
    return 1
  fi
}

test_single_ticket_has_only_itself_in_all_tids() {
  setup_mock_env
  local recfile
  recfile=$(setup_test_recfile "$_TEST_TMPDIR")

  local checklist
  checklist=$(parse_checklist "$recfile")

  # WIL-1 is a simple needs-info item, not a merge/duplicate
  local all_tids1
  all_tids1=$(echo "$checklist" | jq -r '.needs_info_items[] | select(.ticket_id == "WIL-1") | .all_ticket_ids')

  # Should be exactly "WIL-1" (or contain only WIL-1)
  if [ "$all_tids1" = "WIL-1" ]; then
    cleanup
    return 0
  else
    echo "expected 'WIL-1', got '$all_tids1'"
    cleanup
    return 1
  fi
}

# ── dispatch ──────────────────────────────────────────────────────────────────

FILTER="${1:-}"

for fn in \
  test_guard_exit_0_item_marked_done \
  test_guard_exit_0_skips_delegation \
  test_guard_exit_1_proceeds \
  test_crash_resume_deduplicates \
  test_double_invocation_no_double_comment \
  test_multi_ticket_extraction_merge_candidate \
  test_detail_clean_strips_finding_type_prefix \
  test_comment_body_no_redundancy \
  test_single_ticket_has_only_itself_in_all_tids; do
  [ -z "$FILTER" ] || [[ "$fn" == *"$FILTER"* ]] || continue
  _run "$fn" "$fn"
done

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
