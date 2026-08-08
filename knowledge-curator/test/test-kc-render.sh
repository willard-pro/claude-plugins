#!/usr/bin/env bash
# Unit tests for kc-render.sh
#
# Usage: bash test/test-kc-render.sh
# Run from the knowledge-curator/ directory.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/../lib"
KC_RENDER="$LIB_DIR/kc-render.sh"

PASS=0
FAIL=0

pass() {
  echo "  ✓ $1"
  PASS=$((PASS + 1))
}
fail() {
  echo "  ✗ $1"
  FAIL=$((FAIL + 1))
}

setup() {
  TEST_DIR=$(mktemp -d)
  KNOWLEDGE_DIR="$TEST_DIR/knowledge"
  mkdir -p "$KNOWLEDGE_DIR"
}

teardown() {
  rm -rf "$TEST_DIR"
}

write_item() {
  # write_item <path> <id> <type> <title> <status> <priority> <updated> <why> <relates-yaml-or-empty>
  local path="$1" id="$2" type="$3" title="$4" status="$5" priority="$6" updated="$7" why="$8" relates="$9"
  {
    echo "---"
    echo "id: ${id}"
    echo "type: ${type}"
    echo "title: \"${title}\""
    echo "status: ${status}"
    echo "priority: ${priority}"
    echo "project: test-repo"
    echo "created: ${updated}"
    echo "updated: ${updated}"
    echo "source: manual"
    echo "why: \"${why}\""
    echo "tags: [test]"
    if [ -n "$relates" ]; then
      echo "relates:"
      echo "$relates"
    else
      echo "relates: []"
    fi
    echo "---"
    echo "# ${title}"
  } >"$path"
}

# ── Test: missing knowledge directory ────────────────────────────────

TEST_DIR=$(mktemp -d)
OUTPUT=$("$KC_RENDER" "$TEST_DIR/nonexistent")
EXIT=$?
if [ "$EXIT" -eq 0 ] && echo "$OUTPUT" | grep -q "No knowledge/ directory found"; then
  pass "Missing directory: friendly message, exit 0"
else
  fail "Missing directory: friendly message, exit 0 (got: $OUTPUT)"
fi
rm -rf "$TEST_DIR"

# ── Test: empty knowledge directory ──────────────────────────────────

setup
OUTPUT=$("$KC_RENDER" "$KNOWLEDGE_DIR")
if echo "$OUTPUT" | grep -q "No outstanding items"; then
  pass "Empty directory: 'No outstanding items' message"
else
  fail "Empty directory: 'No outstanding items' message (got: $OUTPUT)"
fi
teardown

# ── Test: single active item renders with NEXT box and why line ─────

setup
write_item "$KNOWLEDGE_DIR/KC-0001--solo.md" "KC-0001" "idea" "Solo item" "active" "p2" "2026-07-01T12:00:00Z" "the only thing on the stack" ""
OUTPUT=$("$KC_RENDER" "$KNOWLEDGE_DIR")
if echo "$OUTPUT" | grep -q "NEXT"; then
  pass "Single item: rendered in NEXT box"
else
  fail "Single item: rendered in NEXT box"
fi
if echo "$OUTPUT" | grep -q "the only thing on the stack"; then
  pass "Single item: why line shown"
else
  fail "Single item: why line shown"
fi
teardown

# ── Test: done/obsolete items excluded ───────────────────────────────

setup
write_item "$KNOWLEDGE_DIR/KC-0001--done.md" "KC-0001" "idea" "Done item" "done" "p1" "2026-07-01T12:00:00Z" "should not appear" ""
write_item "$KNOWLEDGE_DIR/KC-0002--obsolete.md" "KC-0002" "idea" "Obsolete item" "obsolete" "p1" "2026-07-01T12:00:00Z" "should not appear either" ""
write_item "$KNOWLEDGE_DIR/KC-0003--active.md" "KC-0003" "idea" "Active item" "active" "p2" "2026-07-01T12:00:00Z" "should appear" ""
OUTPUT=$("$KC_RENDER" "$KNOWLEDGE_DIR")
if ! echo "$OUTPUT" | grep -q "Done item" && ! echo "$OUTPUT" | grep -q "Obsolete item"; then
  pass "done/obsolete items excluded from render"
else
  fail "done/obsolete items excluded from render"
fi
if echo "$OUTPUT" | grep -q "Active item"; then
  pass "active item still appears"
else
  fail "active item still appears"
fi
teardown

# ── Test: unblocked p1 outranks p2 for NEXT ──────────────────────────

setup
write_item "$KNOWLEDGE_DIR/KC-0001--p1.md" "KC-0001" "idea" "P1 item" "active" "p1" "2026-07-20T12:00:00Z" "high priority, fresh" ""
write_item "$KNOWLEDGE_DIR/KC-0002--p2.md" "KC-0002" "idea" "P2 item" "active" "p2" "2026-06-01T12:00:00Z" "medium priority, older" ""
OUTPUT=$("$KC_RENDER" "$KNOWLEDGE_DIR")
NEXT_LINE=$(echo "$OUTPUT" | grep -A1 "NEXT" | tail -1)
if echo "$NEXT_LINE" | grep -q "KC-0001"; then
  pass "Unblocked p1 selected as NEXT over p2"
else
  fail "Unblocked p1 selected as NEXT over p2 (got: $NEXT_LINE)"
fi
teardown

# ── Test: blocked item flagged and relation type preserved ──────────

setup
write_item "$KNOWLEDGE_DIR/KC-0001--blocker.md" "KC-0001" "idea" "Blocker item" "active" "p1" "2026-07-01T12:00:00Z" "must land first" ""
write_item "$KNOWLEDGE_DIR/KC-0002--blocked.md" "KC-0002" "idea" "Blocked item" "active" "p1" "2026-07-01T12:00:00Z" "waiting on the blocker" "  - rel: depends
    id: KC-0001"
OUTPUT=$("$KC_RENDER" "$KNOWLEDGE_DIR")
if echo "$OUTPUT" | grep "KC-0002" | grep -q "▲"; then
  pass "Blocked item flagged with ▲"
else
  fail "Blocked item flagged with ▲"
fi
if echo "$OUTPUT" | grep -q "depends"; then
  pass "Relation type (depends) preserved in output, not just bare id"
else
  fail "Relation type (depends) preserved in output, not just bare id"
fi
teardown

# ── Test: blocked item is never selected as NEXT ─────────────────────

setup
write_item "$KNOWLEDGE_DIR/KC-0001--blocker.md" "KC-0001" "idea" "Blocker item" "active" "p3" "2026-07-01T12:00:00Z" "low priority but unblocked" ""
write_item "$KNOWLEDGE_DIR/KC-0002--blocked.md" "KC-0002" "idea" "Blocked item" "active" "p1" "2026-07-01T12:00:00Z" "high priority but blocked" "  - rel: depends
    id: KC-0001"
OUTPUT=$("$KC_RENDER" "$KNOWLEDGE_DIR")
if echo "$OUTPUT" | grep -A2 "NEXT" | grep -q "KC-0001"; then
  pass "Unblocked p3 selected as NEXT over blocked p1"
else
  fail "Unblocked p3 selected as NEXT over blocked p1"
fi
teardown

# ── Test: all items blocked (mutual depends cycle) ───────────────────

setup
write_item "$KNOWLEDGE_DIR/KC-0001--a.md" "KC-0001" "idea" "A" "active" "p2" "2026-07-01T12:00:00Z" "cycle member A" "  - rel: depends
    id: KC-0002"
write_item "$KNOWLEDGE_DIR/KC-0002--b.md" "KC-0002" "idea" "B" "active" "p2" "2026-07-01T12:00:00Z" "cycle member B" "  - rel: depends
    id: KC-0001"
OUTPUT=$("$KC_RENDER" "$KNOWLEDGE_DIR")
EXIT=$?
if [ "$EXIT" -eq 0 ] && echo "$OUTPUT" | grep -q "All outstanding items are blocked"; then
  pass "Mutual depends cycle: reports all-blocked, does not hang or crash"
else
  fail "Mutual depends cycle: reports all-blocked, does not hang or crash"
fi
teardown

# ── Test: dangling relation target does not crash ────────────────────

setup
write_item "$KNOWLEDGE_DIR/KC-0001--dangling.md" "KC-0001" "idea" "Dangling ref" "active" "p2" "2026-07-01T12:00:00Z" "points at a ghost" "  - rel: refines
    id: KC-9999"
OUTPUT=$("$KC_RENDER" "$KNOWLEDGE_DIR")
EXIT=$?
if [ "$EXIT" -eq 0 ] && echo "$OUTPUT" | grep -q "KC-9999"; then
  pass "Dangling relation target rendered without crashing"
else
  fail "Dangling relation target rendered without crashing"
fi
teardown

# ── Test: depends on a done item is not blocking ─────────────────────

setup
write_item "$KNOWLEDGE_DIR/KC-0001--finished.md" "KC-0001" "idea" "Finished dependency" "done" "p2" "2026-07-01T12:00:00Z" "already shipped" ""
write_item "$KNOWLEDGE_DIR/KC-0002--free.md" "KC-0002" "idea" "Free item" "active" "p2" "2026-07-01T12:00:00Z" "depends on something done" "  - rel: depends
    id: KC-0001"
OUTPUT=$("$KC_RENDER" "$KNOWLEDGE_DIR")
if echo "$OUTPUT" | grep "KC-0002" | grep -q "▲"; then
  fail "Item depending on a done item is not marked blocked"
else
  pass "Item depending on a done item is not marked blocked"
fi
if echo "$OUTPUT" | grep -q "\[done\]"; then
  pass "Relation to a done item shows [done] suffix"
else
  fail "Relation to a done item shows [done] suffix"
fi
teardown

# ── Test: stale p1 (>=14d) flagged with ⚠ ─────────────────────────────

setup
STALE_DATE=$(date -u -d '30 days ago' +%Y-%m-%dT%H:%M:%SZ)
write_item "$KNOWLEDGE_DIR/KC-0001--stale.md" "KC-0001" "idea" "Stale p1" "active" "p1" "$STALE_DATE" "untouched for a while" ""
OUTPUT=$("$KC_RENDER" "$KNOWLEDGE_DIR")
if echo "$OUTPUT" | grep "KC-0001" | grep -q "⚠"; then
  pass "Stale p1 (30d) flagged with ⚠"
else
  fail "Stale p1 (30d) flagged with ⚠"
fi
teardown

# ── Test: dormant status flagged with 💤 ──────────────────────────────

setup
write_item "$KNOWLEDGE_DIR/KC-0001--dormant.md" "KC-0001" "idea" "Dormant item" "dormant" "p2" "2026-07-01T12:00:00Z" "flagged dormant by sweep" ""
OUTPUT=$("$KC_RENDER" "$KNOWLEDGE_DIR")
if echo "$OUTPUT" | grep "KC-0001" | grep -q "💤"; then
  pass "Dormant status flagged with 💤"
else
  fail "Dormant status flagged with 💤"
fi
teardown

# ── Test: summary line reports correct counts ─────────────────────────

setup
write_item "$KNOWLEDGE_DIR/KC-0001--p1a.md" "KC-0001" "idea" "P1 A" "active" "p1" "2026-07-01T12:00:00Z" "one" ""
write_item "$KNOWLEDGE_DIR/KC-0002--p1b.md" "KC-0002" "idea" "P1 B" "in_progress" "p1" "2026-07-01T12:00:00Z" "two" ""
write_item "$KNOWLEDGE_DIR/KC-0003--p2.md" "KC-0003" "idea" "P2" "active" "p2" "2026-07-01T12:00:00Z" "three" ""
write_item "$KNOWLEDGE_DIR/KC-0004--done.md" "KC-0004" "idea" "Done" "done" "p1" "2026-07-01T12:00:00Z" "excluded" ""
OUTPUT=$("$KC_RENDER" "$KNOWLEDGE_DIR")
if echo "$OUTPUT" | head -1 | grep -q "3 items" && echo "$OUTPUT" | head -1 | grep -q "2 p1" && echo "$OUTPUT" | head -1 | grep -q "1 in_progress"; then
  pass "Summary line reports correct item/p1/in_progress counts"
else
  fail "Summary line reports correct item/p1/in_progress counts (got: $(echo "$OUTPUT" | head -1))"
fi
teardown

# ── Summary ─────────────────────────────────────────────────────────

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
