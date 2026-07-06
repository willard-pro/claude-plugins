#!/usr/bin/env bash
# Unit tests for kc-item.sh
#
# Usage: bash test/test-kc-item.sh
# Run from the knowledge-curator/ directory.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/../lib"
KC_ITEM="$LIB_DIR/kc-item.sh"
KC_INDEX="$LIB_DIR/kc-index.sh"

PASS=0
FAIL=0

pass() { echo "  ✓ $1"; PASS=$((PASS + 1)); }
fail() { echo "  ✗ $1"; FAIL=$((FAIL + 1)); }

setup() {
  TEST_DIR=$(mktemp -d)
  export KNOWLEDGE_DIR="$TEST_DIR/knowledge"
  mkdir -p "$KNOWLEDGE_DIR"

  # Create a test item on disk
  cat > "$KNOWLEDGE_DIR/KC-0001--test-item.md" << 'EOF'
---
id: KC-0001
type: idea
title: "Test item for claim/complete"
status: active
priority: p1
project: test-repo
created: 2026-07-01T12:00:00Z
updated: 2026-07-01T12:00:00Z
source: manual
tags: [test]
relates: []
---
# Test item

Content.
EOF

  # Create second item for concurrency test
  cat > "$KNOWLEDGE_DIR/KC-0002--second-item.md" << 'EOF'
---
id: KC-0002
type: discovery
title: "Second item"
status: active
priority: p2
project: test-repo
created: 2026-07-01T12:00:00Z
updated: 2026-07-01T12:00:00Z
source: manual
tags: [test]
relates: []
---
# Second item
EOF

  # Build initial index
  "$KC_INDEX" "$KNOWLEDGE_DIR"
}

teardown() {
  rm -rf "$TEST_DIR"
}

# ── Test: claim transitions status ──────────────────────────────────

setup

"$KC_ITEM" claim KC-0001
STATUS=$(awk '/^status:/ {print $2}' "$KNOWLEDGE_DIR/KC-0001--test-item.md")
if [ "$STATUS" = "in_progress" ]; then
  pass "claim sets status to in_progress"
else
  fail "claim sets status to in_progress (got: $STATUS)"
fi

# Verify updated timestamp changed
UPDATED=$(awk '/^updated:/ {print $2}' "$KNOWLEDGE_DIR/KC-0001--test-item.md")
if [ "$UPDATED" != "2026-07-01T12:00:00Z" ]; then
  pass "claim updates timestamp"
else
  fail "claim updates timestamp"
fi

teardown

# ── Test: double claim is rejected ──────────────────────────────────

setup

"$KC_ITEM" claim KC-0001
if ! "$KC_ITEM" claim KC-0001 2>/dev/null; then
  pass "Double claim is rejected"
else
  fail "Double claim is rejected"
fi

teardown

# ── Test: complete transitions to done ──────────────────────────────

setup

"$KC_ITEM" complete KC-0001
STATUS=$(awk '/^status:/ {print $2}' "$KNOWLEDGE_DIR/KC-0001--test-item.md")
if [ "$STATUS" = "done" ]; then
  pass "complete sets status to done"
else
  fail "complete sets status to done (got: $STATUS)"
fi

# Done items absent from INDEX
if ! grep -q "KC-0001" "$KNOWLEDGE_DIR/INDEX.md"; then
  pass "Done item excluded from INDEX.md"
else
  fail "Done item excluded from INDEX.md"
fi

# File still exists on disk
if [ -f "$KNOWLEDGE_DIR/KC-0001--test-item.md" ]; then
  pass "Done item file remains on disk"
else
  fail "Done item file remains on disk"
fi

teardown

# ── Test: claim nonexistent item fails ──────────────────────────────

setup

if ! "$KC_ITEM" claim KC-9999 2>/dev/null; then
  pass "Claim nonexistent item fails"
else
  fail "Claim nonexistent item fails"
fi

teardown

# ── Test: add validates schema ──────────────────────────────────────

setup

# Missing required field
cat > "$TEST_DIR/bad-item.md" << 'EOF'
---
id: KC-0003
type: idea
title: "Bad item"
---
EOF

if ! "$KC_ITEM" add "$TEST_DIR/bad-item.md" 2>/dev/null; then
  pass "add rejects item with missing fields"
else
  fail "add rejects item with missing fields"
fi

# Valid item
cat > "$TEST_DIR/good-item.md" << 'EOF'
---
id: KC-0003
type: discovery
title: "Good item"
status: active
priority: p2
project: test-repo
created: 2026-07-06T18:00:00Z
updated: 2026-07-06T18:00:00Z
source: manual
tags: [test]
relates: []
---
# Good item

Valid content.
EOF

if "$KC_ITEM" add "$TEST_DIR/good-item.md"; then
  pass "add accepts valid item"
else
  fail "add accepts valid item"
fi

if [ -f "$KNOWLEDGE_DIR/KC-0003--good-item.md" ]; then
  pass "add writes item to knowledge dir"
else
  fail "add writes item to knowledge dir"
fi

teardown

# ── Test: concurrent completes produce consistent index ─────────────

setup

# Launch two completes in parallel (simulate two agents finishing simultaneously)
"$KC_ITEM" claim KC-0001
"$KC_ITEM" claim KC-0002

# Both complete in background
"$KC_ITEM" complete KC-0001 &
PID1=$!
"$KC_ITEM" complete KC-0002 &
PID2=$!

wait $PID1 $PID2

# INDEX should be consistent — neither item should appear
if ! grep -q "KC-0001" "$KNOWLEDGE_DIR/INDEX.md" && ! grep -q "KC-0002" "$KNOWLEDGE_DIR/INDEX.md"; then
  pass "Concurrent completes produce consistent INDEX (both excluded)"
else
  fail "Concurrent completes produce consistent INDEX (both excluded)"
fi

teardown

# ── Test: in_progress items appear in INDEX ─────────────────────────

setup

"$KC_ITEM" claim KC-0001
if grep -q "in_progress" "$KNOWLEDGE_DIR/INDEX.md"; then
  pass "in_progress items appear in INDEX.md"
else
  fail "in_progress items appear in INDEX.md"
fi

teardown

# ── Test: status subcommand ─────────────────────────────────────────

setup

OUTPUT=$("$KC_ITEM" status KC-0001)
if [ "$OUTPUT" = "active" ]; then
  pass "status returns current status"
else
  fail "status returns current status (got: $OUTPUT)"
fi

teardown

# ── Summary ─────────────────────────────────────────────────────────

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
