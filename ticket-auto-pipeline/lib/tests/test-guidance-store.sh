#!/usr/bin/env bash
# test-guidance-store.sh — unit tests for lib/guidance-store.sh
# Usage: bash test-guidance-store.sh [test_name_filter]
set -eo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$TEST_DIR/.." && pwd)"
GS="$LIB_DIR/guidance-store.sh"
CP="$LIB_DIR/corrections-parse.sh"

source "$GS"
source "$CP"

PASS=0
FAIL=0
ASSERT_FAILURES=0

_run() {
  local name="$1"
  shift
  local failures_before=$ASSERT_FAILURES
  set +e
  "$@"
  local rc=$?
  set -e
  local new_failures=$((ASSERT_FAILURES - failures_before))
  if [ $rc -eq 0 ] && [ "$new_failures" -eq 0 ]; then
    echo "PASS: $name"
    ((PASS++)) || true
  else
    echo "FAIL: $name  (exit $rc, assertions failed: $new_failures)"
    ((FAIL++)) || true
  fi
}

_assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [[ "$expected" != "$actual" ]]; then
    echo "  ASSERT FAIL [$label]: expected '$expected', got '$actual'" >&2
    ASSERT_FAILURES=$((ASSERT_FAILURES + 1))
    return 1
  fi
  return 0
}

_assert_ge() {
  local label="$1" expected="$2" actual="$3"
  if [[ "$actual" -lt "$expected" ]]; then
    echo "  ASSERT FAIL [$label]: expected >= $expected, got $actual" >&2
    ASSERT_FAILURES=$((ASSERT_FAILURES + 1))
    return 1
  fi
  return 0
}

# ── Mock environment ──────────────────────────────────────────────────────────

_ws=""
_gs_dir=""
_notes=""

_setup() {
  _ws=$(mktemp -d)
  _gs_dir="$_ws/guidance"
  GUIDANCE_DIR="$_gs_dir"
  _notes="$_ws/notes.md"
  mkdir -p "$GUIDANCE_DIR"
}

_teardown() {
  rm -rf "$_ws" 2>/dev/null || true
}

# Helper: create a valid guidance entry JSON
_mk_entry() {
  local gid="${1:-abc123}"
  local component="${2:-lib/gate-check.sh}"
  local root_cause="${3:-lib-script}"
  local pattern="${4:-missing-null-check}"
  local status="${5:-proposed}"
  local source="${6:-phase-inspector}"
  local severity="${7:-warn}"
  local ts="${8:-2026-08-09T10:00:00Z}"

  cat <<EOF
{"guidance_id":"$gid","component":"$component","root_cause":"$root_cause","pattern":"$pattern","status":"$status","severity":"$severity","summary":"Test entry","detail":"Detailed description","evidence_tickets":[],"source":"$source","run_id":"wf_test","phase":"IMPLEMENT","transitions":[{"status":"proposed","at":"$ts","run_id":"wf_test"}],"created_at":"$ts","updated_at":"$ts"}
EOF
}

# ── _derive_filename tests ────────────────────────────────────────────────────

test_derive_multi_slash() {
  _setup
  local result
  result=$(_derive_filename "skills/ticket-implement/SKILL.md")
  _assert_eq "derive multi-slash" "skills-ticket-implement-SKILL.md.jsonl" "$result"
  _teardown
}

test_derive_single_segment() {
  _setup
  local result
  result=$(_derive_filename "gate-check.sh")
  _assert_eq "derive single-segment" "gate-check.sh.jsonl" "$result"
  _teardown
}

test_derive_lib_path() {
  _setup
  local result
  result=$(_derive_filename "lib/gate-check.sh")
  _assert_eq "derive lib path" "lib-gate-check.sh.jsonl" "$result"
  _teardown
}

# ── _compute_guidance_id tests ────────────────────────────────────────────────

test_guidance_id_stable() {
  _setup
  local id1 id2
  id1=$(_compute_guidance_id "lib/gate-check.sh" "lib-script" "missing-null-check")
  id2=$(_compute_guidance_id "lib/gate-check.sh" "lib-script" "missing-null-check")
  _assert_eq "guidance_id stable" "$id1" "$id2"
  # Should be 16 hex chars
  [[ "$id1" =~ ^[a-f0-9]{16}$ ]] || {
    echo "  guid not 16 hex chars: $id1" >&2
    return 1
  }
  _teardown
}

test_guidance_id_different() {
  _setup
  local id1 id2
  id1=$(_compute_guidance_id "lib/gate-check.sh" "lib-script" "missing-null-check")
  id2=$(_compute_guidance_id "lib/other.sh" "lib-script" "missing-null-check")
  [[ "$id1" != "$id2" ]] || {
    echo "  different inputs produced same guid" >&2
    return 1
  }
  _teardown
}

# ── guidance_upsert tests ─────────────────────────────────────────────────────

test_upsert_append_new() {
  _setup
  local entry
  entry=$(_mk_entry "guid-001" "lib/gate-check.sh" "lib-script" "null-check" "proposed")
  guidance_upsert "$entry"

  # File should exist
  local f="$GUIDANCE_DIR/lib-gate-check.sh.jsonl"
  [[ -f "$f" ]] || {
    echo "  file not created: $f" >&2
    return 1
  }

  local count
  count=$(wc -l <"$f")
  _assert_eq "line count" "1" "$count"

  local stored_id
  stored_id=$(head -1 "$f" | jq -r '.guidance_id')
  _assert_eq "stored guid" "guid-001" "$stored_id"
  _teardown
}

test_upsert_idempotent_update() {
  _setup
  local entry1 entry2
  entry1=$(_mk_entry "guid-001" "lib/gate-check.sh" "lib-script" "null-check" "proposed" "phase-inspector" "warn")
  entry2=$(_mk_entry "guid-001" "lib/gate-check.sh" "lib-script" "null-check" "proposed" "phase-inspector" "warn")

  guidance_upsert "$entry1"
  guidance_upsert "$entry2"

  local f="$GUIDANCE_DIR/lib-gate-check.sh.jsonl"
  local count
  count=$(wc -l <"$f")
  _assert_eq "still one line after idempotent upsert" "1" "$count"
  _teardown
}

test_upsert_merges_evidence_tickets() {
  _setup
  local entry1 entry2
  entry1=$(_mk_entry "guid-001" "lib/gate-check.sh" "lib-script" "null-check" "proposed" "phase-inspector" "warn")
  # Second entry has an evidence ticket
  entry2=$(echo "$(_mk_entry "guid-001" "lib/gate-check.sh" "lib-script" "null-check" "proposed")" | jq -c '.evidence_tickets = ["CRE-100"]')

  guidance_upsert "$entry1"
  guidance_upsert "$entry2"

  local f="$GUIDANCE_DIR/lib-gate-check.sh.jsonl"
  local count
  count=$(wc -l <"$f")
  _assert_eq "still one line" "1" "$count"

  local tickets
  tickets=$(head -1 "$f" | jq -r '.evidence_tickets | join(",")')
  _assert_eq "evidence_tickets merged" "CRE-100" "$tickets"
  _teardown
}

test_upsert_different_components_separate_files() {
  _setup
  local entry1 entry2
  entry1=$(_mk_entry "guid-001" "lib/gate-check.sh" "lib-script" "null-check" "proposed")
  entry2=$(_mk_entry "guid-002" "skills/ticket-implement/SKILL.md" "skill-file" "missing-step" "proposed")

  guidance_upsert "$entry1"
  guidance_upsert "$entry2"

  [[ -f "$GUIDANCE_DIR/lib-gate-check.sh.jsonl" ]] || {
    echo "  missing gate-check file" >&2
    return 1
  }
  [[ -f "$GUIDANCE_DIR/skills-ticket-implement-SKILL.md.jsonl" ]] || {
    echo "  missing skill file" >&2
    return 1
  }

  local c1 c2
  c1=$(wc -l <"$GUIDANCE_DIR/lib-gate-check.sh.jsonl")
  c2=$(wc -l <"$GUIDANCE_DIR/skills-ticket-implement-SKILL.md.jsonl")
  _assert_eq "file1 lines" "1" "$c1"
  _assert_eq "file2 lines" "1" "$c2"
  _teardown
}

test_upsert_creates_dir_on_first_write() {
  _setup
  rmdir "$_gs_dir" # Remove pre-created dir
  GUIDANCE_DIR="$_gs_dir"

  local entry
  entry=$(_mk_entry "guid-001" "lib/test.sh")
  guidance_upsert "$entry"

  [[ -d "$GUIDANCE_DIR" ]] || {
    echo "  directory not created" >&2
    return 1
  }
  [[ -f "$GUIDANCE_DIR/lib-test.sh.jsonl" ]] || {
    echo "  file not created" >&2
    return 1
  }
  _teardown
}

test_upsert_fail_soft_bad_json() {
  _setup
  # Missing guidance_id and component → should exit 0, not crash
  guidance_upsert '{"not_a_real_entry": true}'
  # Should not have created any files
  local file_count
  file_count=$(ls "$GUIDANCE_DIR"/*.jsonl 2>/dev/null | wc -l) || file_count=0
  _assert_eq "no files created" "0" "$file_count"
  _teardown
}

# ── guidance_query tests ──────────────────────────────────────────────────────

test_query_all() {
  _setup
  guidance_upsert "$(_mk_entry "g1" "lib/a.sh" "lib-script" "p1")"
  guidance_upsert "$(_mk_entry "g2" "lib/b.sh" "skill-file" "p2")"

  local count
  count=$(guidance_query | wc -l)
  _assert_eq "query all count" "2" "$count"
  _teardown
}

test_query_by_component() {
  _setup
  guidance_upsert "$(_mk_entry "g1" "lib/a.sh" "lib-script" "p1")"
  guidance_upsert "$(_mk_entry "g2" "lib/b.sh" "skill-file" "p2")"

  local result
  result=$(guidance_query --component "lib/a.sh")
  local count
  count=$(echo "$result" | wc -l)
  _assert_eq "query by component count" "1" "$count"

  local gid
  gid=$(echo "$result" | jq -r '.guidance_id')
  _assert_eq "query by component guid" "g1" "$gid"
  _teardown
}

test_query_by_root_cause() {
  _setup
  guidance_upsert "$(_mk_entry "g1" "lib/a.sh" "lib-script" "p1")"
  guidance_upsert "$(_mk_entry "g2" "lib/b.sh" "skill-file" "p2")"
  guidance_upsert "$(_mk_entry "g3" "lib/c.sh" "skill-file" "p3")"

  local count
  count=$(guidance_query --root-cause "skill-file" | wc -l)
  _assert_eq "query by root cause" "2" "$count"
  _teardown
}

test_query_by_status() {
  _setup
  guidance_upsert "$(_mk_entry "g1" "lib/a.sh" "lib-script" "p1" "proposed")"
  guidance_upsert "$(_mk_entry "g2" "lib/b.sh" "skill-file" "p2" "confirmed")"

  local count
  count=$(guidance_query --status "confirmed" | wc -l)
  _assert_eq "query by status" "1" "$count"
  _teardown
}

test_query_combined_filters() {
  _setup
  guidance_upsert "$(_mk_entry "g1" "lib/a.sh" "lib-script" "p1" "confirmed")"
  guidance_upsert "$(_mk_entry "g2" "lib/a.sh" "skill-file" "p2" "proposed")"
  guidance_upsert "$(_mk_entry "g3" "lib/b.sh" "lib-script" "p3" "confirmed")"

  local result
  result=$(guidance_query --component "lib/a.sh" --status "confirmed")
  local count
  count=$(echo "$result" | wc -l)
  _assert_eq "combined filter count" "1" "$count"

  local gid
  gid=$(echo "$result" | jq -r '.guidance_id')
  _assert_eq "combined filter guid" "g1" "$gid"
  _teardown
}

test_query_empty_store() {
  _setup
  local result
  result=$(guidance_query 2>/dev/null) || true
  _assert_eq "empty store output" "" "$result"
  _teardown
}

test_query_no_match() {
  _setup
  guidance_upsert "$(_mk_entry "g1" "lib/a.sh" "lib-script" "p1" "proposed")"

  local result
  result=$(guidance_query --status "confirmed" 2>/dev/null) || true
  _assert_eq "no match output" "" "$result"
  _teardown
}

test_query_limit() {
  _setup
  guidance_upsert "$(_mk_entry "g1" "lib/a.sh" "lib-script" "p1")"
  guidance_upsert "$(_mk_entry "g2" "lib/b.sh" "lib-script" "p2")"
  guidance_upsert "$(_mk_entry "g3" "lib/c.sh" "lib-script" "p3")"

  local count
  count=$(guidance_query --limit 2 | wc -l)
  _assert_eq "limit 2" "2" "$count"
  _teardown
}

test_query_since() {
  _setup
  local old_entry new_entry
  old_entry=$(_mk_entry "g1" "lib/a.sh" "lib-script" "p1" "proposed" "phase-inspector" "warn" "2026-01-01T00:00:00Z")
  new_entry=$(_mk_entry "g2" "lib/b.sh" "skill-file" "p2" "proposed" "phase-inspector" "warn" "2026-08-09T10:00:00Z")

  guidance_upsert "$old_entry"
  guidance_upsert "$new_entry"

  local count
  count=$(guidance_query --since "2026-08-01T00:00:00Z" | wc -l)
  _assert_eq "since filter count" "1" "$count"

  local gid
  gid=$(echo "$(guidance_query --since '2026-08-01T00:00:00Z')" | jq -r '.guidance_id')
  _assert_eq "since filter guid" "g2" "$gid"
  _teardown
}

test_query_corrupted_line_skipped() {
  _setup
  guidance_upsert "$(_mk_entry "g1" "lib/a.sh" "lib-script" "p1")"
  # Append garbage line
  echo "not valid json at all" >>"$GUIDANCE_DIR/lib-a.sh.jsonl"
  guidance_upsert "$(_mk_entry "g2" "lib/a.sh" "lib-script" "p2")"

  local result
  result=$(guidance_query 2>/dev/null) || true
  local count
  count=$(echo "$result" | wc -l)
  _assert_eq "valid entries returned" "2" "$count"
  _teardown
}

# ── guidance_confirm tests ────────────────────────────────────────────────────

test_confirm_happy_path() {
  _setup
  guidance_upsert "$(_mk_entry "guid-001" "lib/gate.sh" "lib-script" "bug" "proposed")"

  guidance_confirm "guid-001" "CRE-200"
  local rc=$?
  _assert_eq "confirm exit 0" "0" "$rc"

  # Verify status updated
  local status
  status=$(guidance_query --component "lib/gate.sh" | jq -r '.status')
  _assert_eq "status confirmed" "confirmed" "$status"

  # Verify evidence_tickets
  local tickets
  tickets=$(guidance_query --component "lib/gate.sh" | jq -r '.evidence_tickets | join(",")')
  _assert_eq "evidence_ticket present" "CRE-200" "$tickets"

  # Verify transitions
  local trans_count
  trans_count=$(guidance_query --component "lib/gate.sh" | jq -r '.transitions | length')
  _assert_eq "two transitions" "2" "$trans_count"
  _teardown
}

test_confirm_already_confirmed_rejected() {
  _setup
  guidance_upsert "$(_mk_entry "guid-001" "lib/gate.sh" "lib-script" "bug" "confirmed")"

  set +e
  guidance_confirm "guid-001" "CRE-201"
  local rc=$?
  set -e
  _assert_eq "confirm rejected exit 2" "2" "$rc"
  _teardown
}

test_confirm_not_found() {
  _setup
  set +e
  guidance_confirm "nonexistent" "CRE-200"
  local rc=$?
  set -e
  _assert_eq "confirm not found exit 1" "1" "$rc"
  _teardown
}

test_confirm_deprecated_rejected() {
  _setup
  guidance_upsert "$(_mk_entry "guid-001" "lib/gate.sh" "lib-script" "bug" "deprecated")"

  set +e
  guidance_confirm "guid-001" "CRE-201"
  local rc=$?
  set -e
  _assert_eq "confirm deprecated rejected exit 2" "2" "$rc"
  _teardown
}

# ── guidance_deprecate tests ──────────────────────────────────────────────────

test_deprecate_happy_path() {
  _setup
  guidance_upsert "$(_mk_entry "guid-001" "lib/gate.sh" "lib-script" "bug" "confirmed")"

  guidance_deprecate "guid-001" "fixed in commit abc123"
  local rc=$?
  _assert_eq "deprecate exit 0" "0" "$rc"

  local status reason
  status=$(guidance_query --component "lib/gate.sh" | jq -r '.status')
  reason=$(guidance_query --component "lib/gate.sh" | jq -r '.deprecation_reason')
  _assert_eq "status deprecated" "deprecated" "$status"
  _assert_eq "deprecation reason" "fixed in commit abc123" "$reason"
  _teardown
}

test_deprecate_proposed_direct() {
  _setup
  guidance_upsert "$(_mk_entry "guid-001" "lib/gate.sh" "lib-script" "bug" "proposed")"

  guidance_deprecate "guid-001" "false positive"
  local rc=$?
  _assert_eq "proposed→deprecated exit 0" "0" "$rc"

  local status
  status=$(guidance_query --component "lib/gate.sh" | jq -r '.status')
  _assert_eq "status deprecated" "deprecated" "$status"
  _teardown
}

test_deprecate_already_deprecated_rejected() {
  _setup
  guidance_upsert "$(_mk_entry "guid-001" "lib/gate.sh" "lib-script" "bug" "deprecated")"

  set +e
  guidance_deprecate "guid-001" "another reason"
  local rc=$?
  set -e
  _assert_eq "deprecate rejected exit 2" "2" "$rc"
  _teardown
}

test_deprecate_not_found() {
  _setup
  set +e
  guidance_deprecate "nonexistent" "reason"
  local rc=$?
  set -e
  _assert_eq "deprecate not found exit 1" "1" "$rc"
  _teardown
}

# ── guidance_stats tests ──────────────────────────────────────────────────────

test_stats_healthy_store() {
  _setup
  guidance_upsert "$(_mk_entry "g1" "lib/a.sh" "lib-script" "p1" "proposed")"
  guidance_upsert "$(_mk_entry "g2" "lib/b.sh" "skill-file" "p2" "confirmed")"
  guidance_upsert "$(_mk_entry "g3" "lib/c.sh" "lib-script" "p3" "deprecated")"

  local stats
  stats=$(guidance_stats)
  local total
  total=$(echo "$stats" | jq -r '.total_entries')
  _assert_eq "total entries" "3" "$total"

  local proposed confirmed deprecated
  proposed=$(echo "$stats" | jq -r '.by_status.proposed // 0')
  confirmed=$(echo "$stats" | jq -r '.by_status.confirmed // 0')
  deprecated=$(echo "$stats" | jq -r '.by_status.deprecated // 0')
  _assert_eq "proposed count" "1" "$proposed"
  _assert_eq "confirmed count" "1" "$confirmed"
  _assert_eq "deprecated count" "1" "$deprecated"

  local lib_script skill_file
  lib_script=$(echo "$stats" | jq -r '.["by_root_cause"]["lib-script"] // 0')
  skill_file=$(echo "$stats" | jq -r '.["by_root_cause"]["skill-file"] // 0')
  _assert_eq "lib-script count" "2" "$lib_script"
  _assert_eq "skill-file count" "1" "$skill_file"
  _teardown
}

test_stats_empty_store() {
  _setup
  local stats
  stats=$(guidance_stats)
  local total
  total=$(echo "$stats" | jq -r '.total_entries')
  _assert_eq "total 0" "0" "$total"
  _teardown
}

# ── Lifecycle integration tests ───────────────────────────────────────────────

test_full_lifecycle() {
  _setup
  # Propose
  guidance_upsert "$(_mk_entry "lifecycle-1" "lib/test.sh" "lib-script" "test-pattern" "proposed")"
  local s1
  s1=$(guidance_query --component "lib/test.sh" | jq -r '.status')
  _assert_eq "initial proposed" "proposed" "$s1"

  # Confirm
  guidance_confirm "lifecycle-1" "CRE-300"
  local s2
  s2=$(guidance_query --component "lib/test.sh" | jq -r '.status')
  _assert_eq "after confirm" "confirmed" "$s2"

  # Deprecate
  guidance_deprecate "lifecycle-1" "fixed in PR #99"
  local s3
  s3=$(guidance_query --component "lib/test.sh" | jq -r '.status')
  _assert_eq "after deprecate" "deprecated" "$s3"

  # Transitions should have 3 entries
  local tcount
  tcount=$(guidance_query --component "lib/test.sh" | jq -r '.transitions | length')
  _assert_eq "three transitions" "3" "$tcount"
  _teardown
}

# ── Concurrent write safety ───────────────────────────────────────────────────

test_concurrent_writes() {
  _setup
  # Two background processes writing to same component simultaneously
  guidance_upsert "$(_mk_entry "concurrent-1" "lib/shared.sh" "lib-script" "p1")" &
  local pid1=$!
  guidance_upsert "$(_mk_entry "concurrent-2" "lib/shared.sh" "lib-script" "p2")" &
  local pid2=$!

  wait $pid1 $pid2 2>/dev/null || true

  local count
  count=$(wc -l <"$GUIDANCE_DIR/lib-shared.sh.jsonl" 2>/dev/null || echo 0)
  _assert_eq "both entries present" "2" "$count"
  _teardown
}

# ── CORRECTIONS integration ───────────────────────────────────────────────────

test_corrections_inspector_source() {
  _setup
  # Verify inspector is in the source enum
  append_correction "$_notes" "gate-check.sh lacks null validation" "inspector" "add null check before comparison"
  local rc=$?
  _assert_eq "append with inspector source" "0" "$rc"

  # Read back
  local env_file="$_ws/parsed.env"
  get_corrections "$_notes" >"$env_file" 2>/dev/null
  # shellcheck disable=SC1090
  source "$env_file"

  _assert_eq "correction count" "1" "${CORRECTION_COUNT:-0}"
  _assert_eq "correction source" "inspector" "${CORRECTION_0_SOURCE:-}"
  _teardown
}

test_guidance_to_corrections_roundtrip() {
  _setup
  # Upsert guidance for a lib-script defect
  guidance_upsert "$(_mk_entry "corr-test" "lib/gate-check.sh" "lib-script" "null-check" "proposed")"

  # Write corresponding CORRECTIONS block
  append_correction "$_notes" "gate-check.sh missing null check" "inspector" "validate COMPLEXITY before compare"

  # Verify guidance exists
  local gid
  gid=$(guidance_query --component "lib/gate-check.sh" | jq -r '.guidance_id')
  _assert_eq "guidance entry present" "corr-test" "$gid"

  # Verify corrections by source
  local env_file="$_ws/parsed.env"
  get_corrections_by_source "$_notes" "inspector" >"$env_file" 2>/dev/null
  # shellcheck disable=SC1090
  source "$env_file"
  _assert_eq "inspector corrections count" "1" "${CORRECTION_COUNT:-0}"
  _teardown
}

# ── Lazy GC tests ─────────────────────────────────────────────────────────────

test_lazy_gc_triggers() {
  _setup
  # Temporarily lower threshold for testing
  local orig_threshold="$GC_LINE_THRESHOLD"
  GC_LINE_THRESHOLD=3

  # Add 4 entries, 2 of them deprecated and very old
  guidance_upsert "$(_mk_entry "gc-1" "lib/gc-test.sh" "lib-script" "p1" "proposed" "phase-inspector" "warn" "2026-08-09T10:00:00Z")"
  guidance_upsert "$(_mk_entry "gc-2" "lib/gc-test.sh" "lib-script" "p2" "confirmed" "phase-inspector" "warn" "2026-08-09T10:00:00Z")"
  guidance_upsert "$(_mk_entry "gc-3" "lib/gc-test.sh" "lib-script" "p3" "deprecated" "phase-inspector" "warn" "2025-01-01T00:00:00Z")"
  guidance_upsert "$(_mk_entry "gc-4" "lib/gc-test.sh" "lib-script" "p4" "deprecated" "phase-inspector" "warn" "2025-01-01T00:00:00Z")"

  # The 4th upsert should have triggered GC (now at 5 lines after append)
  # Actually we upserted 4 times, each one appends. After 4th, line_count would be 4.
  # Wait, the GC_THRESHOLD is now 3, so the 3rd upsert would have triggered GC already.
  # But GC only removes deprecated entries older than 90 days.
  # The deprecated entries (gc-3, gc-4) have dates in 2025, which is older than 90 days.
  # So after GC, we should have gc-1 and gc-2 remaining.

  local count
  count=$(wc -l <"$GUIDANCE_DIR/lib-gc-test.sh.jsonl" 2>/dev/null || echo 0)
  _assert_eq "active entries after GC" "2" "$count"

  GC_LINE_THRESHOLD="$orig_threshold"
  _teardown
}

test_lazy_gc_preserves_recent_deprecated() {
  _setup
  local orig_threshold="$GC_LINE_THRESHOLD"
  GC_LINE_THRESHOLD=3

  # Recent deprecated (today) should survive GC
  local today
  today=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date +%Y-%m-%dT%H:%M:%SZ)
  guidance_upsert "$(_mk_entry "gc-r1" "lib/gc-recent.sh" "lib-script" "p1" "proposed" "phase-inspector" "warn" "$today")"
  guidance_upsert "$(_mk_entry "gc-r2" "lib/gc-recent.sh" "lib-script" "p2" "deprecated" "phase-inspector" "warn" "$today")"
  guidance_upsert "$(_mk_entry "gc-r3" "lib/gc-recent.sh" "lib-script" "p3" "deprecated" "phase-inspector" "warn" "2025-01-01T00:00:00Z")"
  guidance_upsert "$(_mk_entry "gc-r4" "lib/gc-recent.sh" "lib-script" "p4" "proposed" "phase-inspector" "warn" "$today")"

  # After GC: old deprecated (gc-r3) removed, recent deprecated (gc-r2) kept
  local count
  count=$(wc -l <"$GUIDANCE_DIR/lib-gc-recent.sh.jsonl" 2>/dev/null || echo 0)
  _assert_eq "entries after GC with recent deprecated" "3" "$count"

  GC_LINE_THRESHOLD="$orig_threshold"
  _teardown
}

# ── Fail-soft tests ───────────────────────────────────────────────────────────

test_query_fail_soft_corrupted_file() {
  _setup
  # Create a file with only garbage
  echo "this is not json" >"$GUIDANCE_DIR/lib-bad.jsonl"
  echo "also not json" >>"$GUIDANCE_DIR/lib-bad.jsonl"

  local rc=0
  set +e
  guidance_query 2>/dev/null
  rc=$?
  set -e
  _assert_eq "query exits 0 on corrupted store" "0" "$rc"
  _teardown
}

test_upsert_fail_soft_lock_timeout() {
  _setup
  # Hold a lock, then try to upsert — should timeout and exit 0
  local lockfile="$GUIDANCE_DIR/lib-locked.sh.jsonl.lock"
  exec 10>"$lockfile"
  flock -x 10 2>/dev/null || true

  local entry
  entry=$(_mk_entry "lock-test" "lib/locked.sh" "lib-script" "p1")
  local rc=0
  set +e
  guidance_upsert "$entry"
  rc=$?
  set -e
  _assert_eq "upsert exits 0 on lock timeout" "0" "$rc"

  exec 10>&-
  _teardown
}

# ── Entry integrity tests ─────────────────────────────────────────────────────

test_transitions_preserved_on_upsert() {
  _setup
  guidance_upsert "$(_mk_entry "trans-1" "lib/trans.sh" "lib-script" "p1" "proposed")"
  guidance_confirm "trans-1" "CRE-500"

  # Upsert again — transitions should be preserved
  guidance_upsert "$(_mk_entry "trans-1" "lib/trans.sh" "lib-script" "p1" "confirmed")"

  local tcount
  tcount=$(guidance_query --component "lib/trans.sh" | jq -r '.transitions | length')
  _assert_eq "transitions preserved" "2" "$tcount"

  local status
  status=$(guidance_query --component "lib/trans.sh" | jq -r '.status')
  _assert_eq "status preserved" "confirmed" "$status"
  _teardown
}

# ── Regression: merge preserves confirmed status (F2 fix) ──────────────────────

test_upsert_preserves_confirmed_status() {
  _setup
  # Write proposed, confirm it, then re-detect — status must stay confirmed
  guidance_upsert "$(_mk_entry "reg-status" "lib/status.sh" "lib-script" "p1" "proposed")"
  guidance_confirm "reg-status" "CRE-700"

  # Re-detection with proposed status (simulates agent re-detecting same defect)
  guidance_upsert "$(_mk_entry "reg-status" "lib/status.sh" "lib-script" "p1" "proposed")"

  local status
  status=$(guidance_query --component "lib/status.sh" | jq -r '.status')
  _assert_eq "status stays confirmed after re-detection" "confirmed" "$status"
  _teardown
}

# ── Regression: merge accumulates evidence_tickets across runs (F2 fix) ───────

test_upsert_accumulates_evidence_across_runs() {
  _setup
  # Run 1: detect defect with ticket CRE-100
  local e1
  e1=$(echo "$(_mk_entry "reg-evidence" "lib/evidence.sh" "lib-script" "p1" "proposed")" | jq -c '.evidence_tickets = ["CRE-100"]')
  guidance_upsert "$e1"

  # Run 2: same defect detected with ticket CRE-200
  local e2
  e2=$(echo "$(_mk_entry "reg-evidence" "lib/evidence.sh" "lib-script" "p1" "proposed")" | jq -c '.evidence_tickets = ["CRE-200"]')
  guidance_upsert "$e2"

  local tickets
  tickets=$(guidance_query --component "lib/evidence.sh" | jq -r '.evidence_tickets | sort | join(",")')
  _assert_eq "both tickets accumulated" "CRE-100,CRE-200" "$tickets"

  local count
  count=$(guidance_query --component "lib/evidence.sh" | jq -r '.evidence_tickets | length')
  _assert_eq "exactly 2 evidence tickets" "2" "$count"
  _teardown
}

# ── Regression: jq injection blocked in query (F4 fix) ────────────────────────

test_query_injection_attempt_does_not_bypass_filter() {
  _setup
  guidance_upsert "$(_mk_entry "inj-1" "lib/inject.sh" "lib-script" "p1" "proposed")"
  guidance_upsert "$(_mk_entry "inj-2" "lib/inject.sh" "lib-script" "p2" "confirmed")"

  # Attempt to inject: --status 'proposed" or true or "1"=="1'
  # With --arg, the value is treated literally, not as code.
  # "proposed\" or true or \"1\"==\"1" will match nothing (no entry has that exact status)
  local result
  result=$(guidance_query --status 'proposed" or true or "1" == "1' 2>/dev/null) || true
  local count
  count=$(echo "$result" | grep -c '.' 2>/dev/null) || count=0
  _assert_eq "injection returns no entries" "0" "$count"
  _teardown
}

# ── Regression: stderr not permanently redirected by upsert (F5 fix) ──────────

test_stderr_works_after_upsert() {
  _setup
  guidance_upsert "$(_mk_entry "stderr-test" "lib/stderr.sh" "lib-script" "p1")"

  # After upsert completes, fd 9 should be closed and stderr should work.
  # Write a message to a temp file via stderr to verify stderr is not /dev/null.
  local errfile="$_ws/stderr-capture.txt"
  echo "stderr-ok-$$" 2>"$errfile" >&2 || true

  local captured
  captured=$(cat "$errfile" 2>/dev/null || echo "MISSING")
  _assert_eq "stderr functional after upsert" "stderr-ok-$$" "$captured"
  _teardown
}

# ── Regression: bad JSON not written to store (F7 fix) ────────────────────────

test_upsert_refuses_malformed_json() {
  _setup
  # JSON that jq cannot parse — should NOT be written to the store
  guidance_upsert '{"guidance_id":"bad-json","component":"lib/bad.sh","root_cause":"lib-script","pattern":"p1" INVALID'

  local file_count
  file_count=$(ls "$GUIDANCE_DIR"/*.jsonl 2>/dev/null | wc -l) || file_count=0
  _assert_eq "no files created from malformed JSON" "0" "$file_count"
  _teardown
}

# ── Run ───────────────────────────────────────────────────────────────────────

_run_tests() {
  local filter="${1:-}"

  # _derive_filename
  _run "derive multi-slash path" test_derive_multi_slash
  _run "derive single-segment path" test_derive_single_segment
  _run "derive lib path" test_derive_lib_path

  # _compute_guidance_id
  _run "guidance_id stable" test_guidance_id_stable
  _run "guidance_id different for different inputs" test_guidance_id_different

  # guidance_upsert
  _run "upsert appends new entry" test_upsert_append_new
  _run "upsert idempotent — same guid updates in place" test_upsert_idempotent_update
  _run "upsert merges evidence_tickets" test_upsert_merges_evidence_tickets
  _run "upsert different components → separate files" test_upsert_different_components_separate_files
  _run "upsert creates directory on first write" test_upsert_creates_dir_on_first_write
  _run "upsert fail-soft on bad JSON" test_upsert_fail_soft_bad_json

  # guidance_query
  _run "query all entries" test_query_all
  _run "query by component" test_query_by_component
  _run "query by root cause" test_query_by_root_cause
  _run "query by status" test_query_by_status
  _run "query combined filters" test_query_combined_filters
  _run "query empty store" test_query_empty_store
  _run "query no match" test_query_no_match
  _run "query limit" test_query_limit
  _run "query since" test_query_since
  _run "query skips corrupted line" test_query_corrupted_line_skipped

  # guidance_confirm
  _run "confirm happy path" test_confirm_happy_path
  _run "confirm already-confirmed rejected (exit 2)" test_confirm_already_confirmed_rejected
  _run "confirm not found (exit 1)" test_confirm_not_found
  _run "confirm deprecated rejected (exit 2)" test_confirm_deprecated_rejected

  # guidance_deprecate
  _run "deprecate happy path" test_deprecate_happy_path
  _run "deprecate proposed→deprecated direct" test_deprecate_proposed_direct
  _run "deprecate already-deprecated rejected (exit 2)" test_deprecate_already_deprecated_rejected
  _run "deprecate not found (exit 1)" test_deprecate_not_found

  # guidance_stats
  _run "stats healthy store" test_stats_healthy_store
  _run "stats empty store" test_stats_empty_store

  # Lifecycle
  _run "full lifecycle: proposed→confirmed→deprecated" test_full_lifecycle
  _run "transitions preserved on upsert" test_transitions_preserved_on_upsert

  # Concurrent writes
  _run "concurrent writes to same component" test_concurrent_writes

  # CORRECTIONS integration
  _run "append_correction with inspector source" test_corrections_inspector_source
  _run "guidance to corrections roundtrip" test_guidance_to_corrections_roundtrip

  # Lazy GC
  _run "lazy GC removes old deprecated entries" test_lazy_gc_triggers
  _run "lazy GC preserves recent deprecated entries" test_lazy_gc_preserves_recent_deprecated

  # Fail-soft
  _run "query fail-soft on corrupted file" test_query_fail_soft_corrupted_file
  _run "upsert fail-soft on lock timeout" test_upsert_fail_soft_lock_timeout

  # Regression: P0/P1 fixes from 5-agent review
  _run "upsert preserves confirmed status after re-detection" test_upsert_preserves_confirmed_status
  _run "upsert accumulates evidence tickets across runs" test_upsert_accumulates_evidence_across_runs
  _run "query injection attempt does not bypass filter" test_query_injection_attempt_does_not_bypass_filter
  _run "stderr works after upsert (no permanent redirect)" test_stderr_works_after_upsert
  _run "upsert refuses malformed JSON" test_upsert_refuses_malformed_json

  echo ""
  echo "─── Results ───"
  echo "PASS: $PASS"
  echo "FAIL: $FAIL"
  if [[ "$FAIL" -gt 0 ]]; then
    echo "SOME TESTS FAILED"
    return 1
  fi
  echo "ALL TESTS PASSED"
  return 0
}

_run_tests "$@"
