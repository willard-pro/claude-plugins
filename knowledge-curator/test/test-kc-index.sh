#!/usr/bin/env bash
# Unit tests for kc-index.sh
#
# Usage: bash test/test-kc-index.sh
# Run from the knowledge-curator/ directory.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/../lib"
KC_INDEX="$LIB_DIR/kc-index.sh"

PASS=0
FAIL=0

pass() { echo "  ✓ $1"; PASS=$((PASS + 1)); }
fail() { echo "  ✗ $1"; FAIL=$((FAIL + 1)); }

setup() {
  TEST_DIR=$(mktemp -d)
  mkdir -p "$TEST_DIR/knowledge"
}

teardown() {
  rm -rf "$TEST_DIR"
}

# ── Test: empty knowledge directory ─────────────────────────────────

setup
"$KC_INDEX" "$TEST_DIR/knowledge"
if [ -f "$TEST_DIR/knowledge/INDEX.md" ]; then
  pass "Empty directory produces INDEX.md"
else
  fail "Empty directory produces INDEX.md"
fi
if grep -q "_No active items._" "$TEST_DIR/knowledge/INDEX.md"; then
  pass "Empty INDEX.md shows 'No active items'"
else
  fail "Empty INDEX.md shows 'No active items'"
fi
teardown

# ── Test: INDEX reflects item files ─────────────────────────────────

setup

cat > "$TEST_DIR/knowledge/KC-0001--test-item.md" << 'EOF'
---
id: KC-0001
type: idea
title: "Test item one"
status: active
priority: p1
project: test-repo
created: 2026-07-01T12:00:00Z
updated: 2026-07-06T12:00:00Z
source: manual
tags: [test, idea]
relates: []
---
# Test item one

Content here.
EOF

cat > "$TEST_DIR/knowledge/KC-0002--another-item.md" << 'EOF'
---
id: KC-0002
type: decision
title: "Another item"
status: active
priority: p2
project: test-repo
created: 2026-07-02T12:00:00Z
updated: 2026-07-05T12:00:00Z
source: manual
tags: [test]
relates: []
---
# Another item
EOF

"$KC_INDEX" "$TEST_DIR/knowledge"

if grep -q "KC-0001" "$TEST_DIR/knowledge/INDEX.md" && grep -q "KC-0002" "$TEST_DIR/knowledge/INDEX.md"; then
  pass "INDEX.md includes both items"
else
  fail "INDEX.md includes both items"
fi

# p1 item should appear first
p1_line=$(grep -n "KC-0001" "$TEST_DIR/knowledge/INDEX.md" | head -1 | cut -d: -f1)
p2_line=$(grep -n "KC-0002" "$TEST_DIR/knowledge/INDEX.md" | head -1 | cut -d: -f1)
if [ "$p1_line" -lt "$p2_line" ]; then
  pass "p1 item sorted before p2 item"
else
  fail "p1 item sorted before p2 item"
fi

teardown

# ── Test: INDEX updates on status change ────────────────────────────

setup

cat > "$TEST_DIR/knowledge/KC-0003--status-test.md" << 'EOF'
---
id: KC-0003
type: lesson
title: "Status test"
status: active
priority: p2
project: test-repo
created: 2026-07-01T12:00:00Z
updated: 2026-07-01T12:00:00Z
source: manual
tags: [test]
relates: []
---
# Status test
EOF

"$KC_INDEX" "$TEST_DIR/knowledge"
if grep -q "KC-0003" "$TEST_DIR/knowledge/INDEX.md"; then
  pass "Active item appears in INDEX"
else
  fail "Active item appears in INDEX"
fi

# Change status to dormant
sed -i 's/^status: active/status: dormant/' "$TEST_DIR/knowledge/KC-0003--status-test.md"
sed -i 's/^updated:.*/updated: 2026-07-06T18:00:00Z/' "$TEST_DIR/knowledge/KC-0003--status-test.md"
"$KC_INDEX" "$TEST_DIR/knowledge"

if grep -q "KC-0003" "$TEST_DIR/knowledge/INDEX.md" && grep -q "dormant" "$TEST_DIR/knowledge/INDEX.md"; then
  pass "Dormant item still appears (not done/obsolete)"
else
  fail "Dormant item still appears (not done/obsolete)"
fi

# Change status to done — should be excluded
sed -i 's/^status: dormant/status: done/' "$TEST_DIR/knowledge/KC-0003--status-test.md"
"$KC_INDEX" "$TEST_DIR/knowledge"

if ! grep -q "KC-0003" "$TEST_DIR/knowledge/INDEX.md"; then
  pass "Done item excluded from INDEX"
else
  fail "Done item excluded from INDEX"
fi

teardown

# ── Test: nonexistent directory is fail-open ────────────────────────

setup
if "$KC_INDEX" "$TEST_DIR/nonexistent"; then
  pass "Nonexistent directory exits 0 (fail-open)"
else
  fail "Nonexistent directory exits 0 (fail-open)"
fi
teardown

# ── Summary ─────────────────────────────────────────────────────────

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
