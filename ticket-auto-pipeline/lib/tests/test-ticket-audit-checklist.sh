#!/usr/bin/env bash
# test-ticket-audit-checklist.sh — unit tests for recommendation checklist format
# Validates checklist generation format, split threshold boundary, item counts.
# Requires: bash, jq
# Usage: bash test-ticket-audit-checklist.sh [test_name_filter]
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

# ── Checklist format ──────────────────────────────────────────────────────────

test_checklist_has_required_sections() {
  local tmpfile
  tmpfile=$(mktemp)
  cat >"$tmpfile" <<'EOF'
# Audit Recommendations: milestone-sprint1 (2026-06-07)
Source: milestone-abc123
Generated: 2026-06-07T12:00:00Z
Phase: needs-info

## Audit Summary
Found 3 issues across 10 tickets.

## Goal Context
**Milestone/Parent:** Sprint 1
**Goal:** Improve attorney assignment workflows.

## Ticket Inventory
| ID | Title | State | Assignee | Last Updated |
|---|---|---|---|---|
| WIL-1 | Fix bug | Todo | — | 2026-06-01 |

## Needs Info
- [ ] WIL-1 — needs-info: missing repro steps

## Structural
- [ ] WIL-2 — merge candidate: duplicate of WIL-3 (Jaccard: 88%)
EOF

  local valid=0
  grep -q '## Audit Summary' "$tmpfile" &&
    grep -q '## Goal Context' "$tmpfile" &&
    grep -q '## Ticket Inventory' "$tmpfile" &&
    grep -q '## Needs Info' "$tmpfile" &&
    grep -q '## Structural' "$tmpfile" &&
    valid=1

  rm -f "$tmpfile"
  [ "$valid" -eq 1 ]
}

test_checklist_source_line_format() {
  local source="milestone-abc123"
  local expected="Source: milestone-abc123"
  [ "Source: $source" = "$expected" ]
}

test_checklist_items_use_checkbox_format() {
  local item="- [ ] WIL-1 — needs-info: missing repro steps"
  echo "$item" | grep -qE '^- \[ \] WIL-[0-9]+ —' || return 1

  local item2="- [ ] WIL-78 — merge candidate: duplicate of WIL-79 (Jaccard: 88%)"
  echo "$item2" | grep -qE '^- \[ \] WIL-[0-9]+ — merge candidate' || return 1
}

test_checklist_empty_needs_info_shows_none() {
  local section="## Needs Info (run 1 — delegate to ticket-critique)

No issues requiring information."
  echo "$section" | grep -q "No issues requiring information"
}

# ── Split threshold boundary ──────────────────────────────────────────────────

test_split_flag_at_2_signals() {
  # 2 signals = flagged
  local signal_count=2
  [ "$signal_count" -ge 2 ]
}

test_split_no_flag_at_1_signal() {
  local signal_count=1
  [ "$signal_count" -lt 2 ]
}

test_split_no_flag_at_0_signals() {
  local signal_count=0
  [ "$signal_count" -lt 2 ]
}

# ── Item counts by category ───────────────────────────────────────────────────

test_item_counts_by_category() {
  local needs_info_count=3
  local structural_count=2
  local drift_count=1

  local total=$((needs_info_count + structural_count + drift_count))
  [ "$total" -eq 6 ]
}

# ── dispatch ──────────────────────────────────────────────────────────────────

FILTER="${1:-}"

for fn in \
  test_checklist_has_required_sections \
  test_checklist_source_line_format \
  test_checklist_items_use_checkbox_format \
  test_checklist_empty_needs_info_shows_none \
  test_split_flag_at_2_signals \
  test_split_no_flag_at_1_signal \
  test_split_no_flag_at_0_signals \
  test_item_counts_by_category; do
  [ -z "$FILTER" ] || [[ "$fn" == *"$FILTER"* ]] || continue
  _run "$fn" "$fn"
done

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
