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

cat >"$TEST_DIR/knowledge/KC-0001--test-item.md" <<'EOF'
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

cat >"$TEST_DIR/knowledge/KC-0002--another-item.md" <<'EOF'
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

cat >"$TEST_DIR/knowledge/KC-0003--status-test.md" <<'EOF'
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

# ── Test: orphaned .md files produce warnings ────────────────────────

setup

# Create a file that doesn't match the KC-NNNN pattern
cat >"$TEST_DIR/knowledge/orphaned-notes.md" <<'EOF'
---
id: bad-format
type: idea
title: "Orphan"
status: active
priority: p2
project: test
created: 2026-07-01T12:00:00Z
updated: 2026-07-01T12:00:00Z
source: manual
tags: [test]
relates: []
---
# Orphan
EOF

WARN_OUTPUT=$("$KC_INDEX" "$TEST_DIR/knowledge" 2>&1) || true
if echo "$WARN_OUTPUT" | grep -q "Orphaned file"; then
  pass "Orphaned non-KC-NNNN file triggers warning"
else
  fail "Orphaned non-KC-NNNN file triggers warning — got: $WARN_OUTPUT"
fi

# KC-NNNN file should NOT trigger warning
cat >"$TEST_DIR/knowledge/KC-0005--valid-item.md" <<'EOF'
---
id: KC-0005
type: idea
title: "Valid item"
status: active
priority: p2
project: test
created: 2026-07-01T12:00:00Z
updated: 2026-07-01T12:00:00Z
source: manual
tags: [test]
relates: []
---
# Valid item
EOF

WARN_OUTPUT2=$("$KC_INDEX" "$TEST_DIR/knowledge" 2>&1) || true
# KC-0005 should appear in INDEX.md (the file), not in stderr warnings
if grep -q "KC-0005" "$TEST_DIR/knowledge/INDEX.md" && ! echo "$WARN_OUTPUT2" | grep -q "KC-0005"; then
  pass "KC-NNNN file does not trigger orphaned warning"
else
  fail "KC-NNNN file does not trigger orphaned warning"
fi

teardown

# ── Test: item with missing required fields is skipped ───────────────

setup

cat >"$TEST_DIR/knowledge/KC-0006--corrupt.md" <<'EOF'
---
id: KC-0006
type: idea
title: ""
status:
priority:
project: test
created: 2026-07-01T12:00:00Z
updated: 2026-07-01T12:00:00Z
source: manual
tags: [test]
relates: []
---
# Corrupt item
EOF

WARN_OUTPUT3=$("$KC_INDEX" "$TEST_DIR/knowledge" 2>&1) || true
if echo "$WARN_OUTPUT3" | grep -q "Skipping item with missing required fields"; then
  pass "Item with empty required fields triggers skip warning"
else
  fail "Item with empty required fields triggers skip warning — got: $WARN_OUTPUT3"
fi

teardown

# ── Test: obsolete items excluded ────────────────────────────────────

setup

cat >"$TEST_DIR/knowledge/KC-0010--obsolete-item.md" <<'EOF'
---
id: KC-0010
type: idea
title: "Obsolete item"
status: obsolete
priority: p3
project: test
created: 2026-07-01T12:00:00Z
updated: 2026-07-01T12:00:00Z
source: manual
tags: [test]
relates: []
---
# Obsolete
EOF

"$KC_INDEX" "$TEST_DIR/knowledge"
if ! grep -q "KC-0010" "$TEST_DIR/knowledge/INDEX.md"; then
  pass "Obsolete item excluded from INDEX"
else
  fail "Obsolete item excluded from INDEX"
fi
teardown

# ── Test: item_count accurate with mixed statuses ────────────────────

setup

# Active item
cat >"$TEST_DIR/knowledge/KC-0011--active.md" <<'EOF'
---
id: KC-0011
type: idea
title: "Active"
status: active
priority: p1
project: test
created: 2026-07-01T12:00:00Z
updated: 2026-07-01T12:00:00Z
source: manual
tags: [test]
relates: []
---
# Active
EOF

# Done item (excluded from count)
cat >"$TEST_DIR/knowledge/KC-0012--done.md" <<'EOF'
---
id: KC-0012
type: discovery
title: "Done"
status: done
priority: p2
project: test
created: 2026-07-01T12:00:00Z
updated: 2026-07-01T12:00:00Z
source: manual
tags: [test]
relates: []
---
# Done
EOF

# Corrupt item (skipped)
cat >"$TEST_DIR/knowledge/KC-0013--bad.md" <<'EOF'
---
id: KC-0013
type:
title:
status:
priority:
project: test
created: 2026-07-01T12:00:00Z
updated: 2026-07-01T12:00:00Z
source: manual
tags: [test]
relates: []
---
# Bad
EOF

OUTPUT=$("$KC_INDEX" "$TEST_DIR/knowledge" 2>&1) || true
# Total counts ALL files matching KC-NNNN pattern (including done/obsolete/corrupt).
# Active items in the items table will be fewer.
# 3 files match: KC-0011 (active), KC-0012 (done), KC-0013 (corrupt)
TOTAL=$(grep "| [0-9]\+ | [0-9]\+ | [0-9]\+ |" "$TEST_DIR/knowledge/INDEX.md" | head -1 | awk -F'|' '{gsub(/ /,"",$2); print $2}')
if [ "$TOTAL" = "3" ]; then
  pass "item_count=3 (counts all KC-NNNN files, including done+corrupt)"
else
  fail "item_count=3 (counts all KC-NNNN files, including done+corrupt) — got: $TOTAL"
fi

# KC-0011 should appear, KC-0012 and KC-0013 should not
if grep -q "KC-0011" "$TEST_DIR/knowledge/INDEX.md" &&
  ! grep -q "KC-0012" "$TEST_DIR/knowledge/INDEX.md" &&
  ! grep -q "KC-0013" "$TEST_DIR/knowledge/INDEX.md"; then
  pass "Mixed statuses: only active item in INDEX"
else
  fail "Mixed statuses: only active item in INDEX"
fi
teardown

# ── Test: vanished item detection ────────────────────────────────────

setup

# Create an item and build index (this writes .kc-item-registry)
cat >"$TEST_DIR/knowledge/KC-0020--will-vanish.md" <<'EOF'
---
id: KC-0020
type: idea
title: "Will vanish"
status: active
priority: p2
project: test
created: 2026-07-01T12:00:00Z
updated: 2026-07-01T12:00:00Z
source: manual
tags: [test]
relates: []
---
# Will vanish
EOF

"$KC_INDEX" "$TEST_DIR/knowledge" >/dev/null 2>&1

# Registry should exist and contain KC-0020
if [ -f "$TEST_DIR/knowledge/.kc-item-registry" ] && grep -q "KC-0020" "$TEST_DIR/knowledge/.kc-item-registry"; then
  pass "Registry records item IDs after build"
else
  fail "Registry records item IDs after build"
fi

# Now delete the item file and rebuild
rm "$TEST_DIR/knowledge/KC-0020--will-vanish.md"
OUTPUT=$("$KC_INDEX" "$TEST_DIR/knowledge" 2>&1) || true
if echo "$OUTPUT" | grep -q "Previously tracked item vanished.*KC-0020"; then
  pass "Vanished item triggers warning"
else
  fail "Vanished item triggers warning — got: $OUTPUT"
fi
teardown

# ── Test: same-priority sort by updated timestamp (newer first) ─────

setup

# Both p2, KC-0031 updated later (newer) — should appear first
cat >"$TEST_DIR/knowledge/KC-0030--older.md" <<'EOF'
---
id: KC-0030
type: idea
title: "Older p2 item"
status: active
priority: p2
project: test
created: 2026-07-01T12:00:00Z
updated: 2026-06-01T12:00:00Z
source: manual
tags: [test]
relates: []
---
# Older
EOF

cat >"$TEST_DIR/knowledge/KC-0031--newer.md" <<'EOF'
---
id: KC-0031
type: idea
title: "Newer p2 item"
status: active
priority: p2
project: test
created: 2026-07-01T12:00:00Z
updated: 2026-07-15T12:00:00Z
source: manual
tags: [test]
relates: []
---
# Newer
EOF

"$KC_INDEX" "$TEST_DIR/knowledge"

newer_line=$(grep -n "KC-0031" "$TEST_DIR/knowledge/INDEX.md" | head -1 | cut -d: -f1)
older_line=$(grep -n "KC-0030" "$TEST_DIR/knowledge/INDEX.md" | head -1 | cut -d: -f1)
if [ "$newer_line" -lt "$older_line" ]; then
  pass "Same priority: newer item sorted first (updated desc)"
else
  fail "Same priority: newer item sorted first"
fi
teardown

# ── Test: multi-line relates extraction ──────────────────────────────

setup

cat >"$TEST_DIR/knowledge/KC-0040--with-relates.md" <<'EOF'
---
id: KC-0040
type: decision
title: "Item with relations"
status: active
priority: p2
project: test
created: 2026-07-01T12:00:00Z
updated: 2026-07-01T12:00:00Z
source: manual
tags: [architecture]
relates:
  - rel: refines
    id: KC-0030
  - rel: extends
    id: KC-0031
---
# With relations
EOF

"$KC_INDEX" "$TEST_DIR/knowledge"

if grep -q "KC-0030\|KC-0031" "$TEST_DIR/knowledge/INDEX.md"; then
  pass "Multi-line relates: relation IDs extracted into Relates column"
else
  fail "Multi-line relates: relation IDs extracted into Relates column"
fi
teardown

# ── Summary ─────────────────────────────────────────────────────────

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
