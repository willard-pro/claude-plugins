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
  export KNOWLEDGE_DIR="$TEST_DIR/knowledge"
  mkdir -p "$KNOWLEDGE_DIR"

  # Create a test item on disk
  cat >"$KNOWLEDGE_DIR/KC-0001--test-item.md" <<'EOF'
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
  cat >"$KNOWLEDGE_DIR/KC-0002--second-item.md" <<'EOF'
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

# ── Test: complete transitions to done (only from in_progress) ──────

setup

# Must claim first
"$KC_ITEM" claim KC-0001
"$KC_ITEM" complete KC-0001
STATUS=$(awk '/^status:/ {print $2}' "$KNOWLEDGE_DIR/KC-0001--test-item.md")
if [ "$STATUS" = "done" ]; then
  pass "complete (after claim) sets status to done"
else
  fail "complete (after claim) sets status to done (got: $STATUS)"
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

# ── Test: complete without claim is rejected ─────────────────────────

setup

if ! "$KC_ITEM" complete KC-0001 2>/dev/null; then
  pass "Complete without claim is rejected"
else
  fail "Complete without claim is rejected"
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
cat >"$TEST_DIR/bad-item.md" <<'EOF'
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
cat >"$TEST_DIR/good-item.md" <<'EOF'
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

# ── Test: release transitions in_progress to active ──────────────────

setup

"$KC_ITEM" claim KC-0001
"$KC_ITEM" release KC-0001
STATUS=$(awk '/^status:/ {print $2}' "$KNOWLEDGE_DIR/KC-0001--test-item.md")
if [ "$STATUS" = "active" ]; then
  pass "release sets status back to active"
else
  fail "release sets status back to active (got: $STATUS)"
fi

teardown

# ── Test: release without claim is rejected ──────────────────────────

setup

if ! "$KC_ITEM" release KC-0001 2>/dev/null; then
  pass "Release without claim is rejected"
else
  fail "Release without claim is rejected"
fi

teardown

# ── Test: released item appears in INDEX ─────────────────────────────

setup

"$KC_ITEM" claim KC-0001
"$KC_ITEM" release KC-0001
if grep -q "KC-0001" "$KNOWLEDGE_DIR/INDEX.md" && grep -q "active" "$KNOWLEDGE_DIR/INDEX.md"; then
  pass "Released item appears in INDEX as active"
else
  fail "Released item appears in INDEX as active"
fi

teardown

# ── Test: edit updates a field ───────────────────────────────────────

setup

"$KC_ITEM" edit KC-0001 priority p3
PRIORITY=$(awk '/^priority:/ {print $2}' "$KNOWLEDGE_DIR/KC-0001--test-item.md")
if [ "$PRIORITY" = "p3" ]; then
  pass "edit updates priority field"
else
  fail "edit updates priority field (got: $PRIORITY)"
fi

# Timestamp should be updated
UPDATED=$(awk '/^updated:/ {print $2}' "$KNOWLEDGE_DIR/KC-0001--test-item.md")
if [ "$UPDATED" != "2026-07-01T12:00:00Z" ]; then
  pass "edit updates timestamp"
else
  fail "edit updates timestamp"
fi

teardown

# ── Test: edit rejects structural fields ─────────────────────────────

setup

if ! "$KC_ITEM" edit KC-0001 status done 2>/dev/null; then
  pass "edit rejects status (use complete/release instead)"
else
  fail "edit rejects status"
fi

if ! "$KC_ITEM" edit KC-0001 id KC-9999 2>/dev/null; then
  pass "edit rejects id field"
else
  fail "edit rejects id field"
fi

teardown

# ── Test: edit rejects invalid enum values ───────────────────────────

setup

if ! "$KC_ITEM" edit KC-0001 priority urgent 2>/dev/null; then
  pass "edit rejects invalid priority value"
else
  fail "edit rejects invalid priority value"
fi

teardown

# ── Test: claim from done is rejected ────────────────────────────────

setup
# Manually set item to done
sed -i 's/^status: active/status: done/' "$KNOWLEDGE_DIR/KC-0001--test-item.md"
if ! "$KC_ITEM" claim KC-0001 2>/dev/null; then
  pass "Claim from done is rejected"
else
  fail "Claim from done is rejected"
fi
teardown

# ── Test: claim from dormant works ───────────────────────────────────

setup
sed -i 's/^status: active/status: dormant/' "$KNOWLEDGE_DIR/KC-0001--test-item.md"
if "$KC_ITEM" claim KC-0001; then
  pass "Claim from dormant succeeds"
else
  fail "Claim from dormant succeeds"
fi
teardown

# ── Test: claim from obsolete is rejected ────────────────────────────

setup
sed -i 's/^status: active/status: obsolete/' "$KNOWLEDGE_DIR/KC-0001--test-item.md"
if ! "$KC_ITEM" claim KC-0001 2>/dev/null; then
  pass "Claim from obsolete is rejected"
else
  fail "Claim from obsolete is rejected"
fi
teardown

# ── Test: complete from done is rejected ─────────────────────────────

setup
sed -i 's/^status: active/status: done/' "$KNOWLEDGE_DIR/KC-0001--test-item.md"
if ! "$KC_ITEM" complete KC-0001 2>/dev/null; then
  pass "Complete from done is rejected"
else
  fail "Complete from done is rejected"
fi
teardown

# ── Test: release from active is rejected (never claimed) ────────────

setup
if ! "$KC_ITEM" release KC-0001 2>/dev/null; then
  pass "Release from active is rejected"
else
  fail "Release from active is rejected"
fi
teardown

# ── Test: release from done is rejected ──────────────────────────────

setup
sed -i 's/^status: active/status: done/' "$KNOWLEDGE_DIR/KC-0001--test-item.md"
if ! "$KC_ITEM" release KC-0001 2>/dev/null; then
  pass "Release from done is rejected"
else
  fail "Release from done is rejected"
fi
teardown

# ── Test: add rejects file outside CWD/tmp (path traversal) ─────────

setup
cat >"$TEST_DIR/bad-path.md" <<'EOF'
---
id: KC-0099
type: idea
title: "Bad path"
status: active
priority: p2
project: test
created: 2026-07-06T18:00:00Z
updated: 2026-07-06T18:00:00Z
source: manual
tags: [test]
relates: []
---
# Bad path
EOF
# Try to add via a relative path that resolves outside CWD
if ! "$KC_ITEM" add "/etc/passwd" 2>/dev/null; then
  pass "add rejects /etc/passwd"
else
  fail "add rejects /etc/passwd"
fi
teardown

# ── Test: add rejects duplicate id ───────────────────────────────────

setup
# KC-0001 already exists from setup()
cat >"$TEST_DIR/dup-item.md" <<'EOF'
---
id: KC-0001
type: discovery
title: "Duplicate id"
status: active
priority: p2
project: test-repo
created: 2026-07-06T18:00:00Z
updated: 2026-07-06T18:00:00Z
source: manual
tags: [test]
relates: []
---
# Dup
EOF
if ! "$KC_ITEM" add "$TEST_DIR/dup-item.md" 2>/dev/null; then
  pass "add rejects duplicate id"
else
  fail "add rejects duplicate id"
fi
teardown

# ── Test: edit title field ───────────────────────────────────────────

setup
"$KC_ITEM" edit KC-0001 title "Updated title"
TITLE=$(awk '/^title:/ {sub(/^title: *"?/,""); sub(/"$/,""); print}' "$KNOWLEDGE_DIR/KC-0001--test-item.md")
if echo "$TITLE" | grep -q "Updated title"; then
  pass "edit updates title field"
else
  fail "edit updates title field (got: $TITLE)"
fi
teardown

# ── Test: edit tags field ────────────────────────────────────────────

setup
"$KC_ITEM" edit KC-0001 tags "[urgent, needs-review]"
if grep -q "urgent" "$KNOWLEDGE_DIR/KC-0001--test-item.md"; then
  pass "edit updates tags field"
else
  fail "edit updates tags field"
fi
teardown

# ── Test: edit relates field ─────────────────────────────────────────

setup
"$KC_ITEM" edit KC-0001 relates "[{rel: extends, id: KC-0002}]"
if grep -q "KC-0002" "$KNOWLEDGE_DIR/KC-0001--test-item.md"; then
  pass "edit updates relates field"
else
  fail "edit updates relates field"
fi
teardown

# ── Test: edit project field ─────────────────────────────────────────

setup
"$KC_ITEM" edit KC-0001 project "other-repo"
if grep -q "project: other-repo" "$KNOWLEDGE_DIR/KC-0001--test-item.md"; then
  pass "edit updates project field"
else
  fail "edit updates project field"
fi
teardown

# ── Test: edit rejects type/created/updated/source ───────────────────

setup
for field in type created updated source; do
  if ! "$KC_ITEM" edit KC-0001 "$field" "test-value" 2>/dev/null; then
    pass "edit rejects structural field: $field"
  else
    fail "edit rejects structural field: $field"
  fi
done
teardown

# ── Test: edit rejects unknown field ─────────────────────────────────

setup
if ! "$KC_ITEM" edit KC-0001 bogus_field "value" 2>/dev/null; then
  pass "edit rejects unknown field"
else
  fail "edit rejects unknown field"
fi
teardown

# ── Test: edit with value containing / (sed-safe) ────────────────────

setup
"$KC_ITEM" edit KC-0001 title "Fix foo/bar/baz parsing"
TITLE=$(awk '/^title:/ {sub(/^title: *"?/,""); sub(/"$/,""); print}' "$KNOWLEDGE_DIR/KC-0001--test-item.md")
if echo "$TITLE" | grep -q "foo/bar/baz"; then
  pass "edit handles / in value"
else
  fail "edit handles / in value (got: $TITLE)"
fi
teardown

# ── Test: edit with value containing & (sed-safe) ────────────────────

setup
"$KC_ITEM" edit KC-0001 title "Foo & Bar"
TITLE=$(awk '/^title:/ {sub(/^title: *"?/,""); sub(/"$/,""); print}' "$KNOWLEDGE_DIR/KC-0001--test-item.md")
if echo "$TITLE" | grep -q "Foo & Bar"; then
  pass "edit handles & in value"
else
  fail "edit handles & in value (got: $TITLE)"
fi
teardown

# ── Test: validate_id rejects path traversal ─────────────────────────

setup
# Test via claim with bad id format
for bad_id in "../../../etc/passwd" "KC-$(whoami)" "KC-0001;rm" "KC-ABCD" "KC-12345" ""; do
  if ! "$KC_ITEM" claim "$bad_id" 2>/dev/null; then
    pass "validate_id rejects: $bad_id"
  else
    fail "validate_id rejects: $bad_id"
  fi
done
teardown

# ── Test: status after claim/complete transitions ────────────────────

setup

OUTPUT=$("$KC_ITEM" status KC-0001)
if [ "$OUTPUT" = "active" ]; then
  pass "status: initial is active"
else
  fail "status: initial is active (got: $OUTPUT)"
fi

"$KC_ITEM" claim KC-0001 >/dev/null
OUTPUT=$("$KC_ITEM" status KC-0001)
if [ "$OUTPUT" = "in_progress" ]; then
  pass "status: after claim is in_progress"
else
  fail "status: after claim is in_progress (got: $OUTPUT)"
fi

"$KC_ITEM" complete KC-0001 >/dev/null
OUTPUT=$("$KC_ITEM" status KC-0001)
if [ "$OUTPUT" = "done" ]; then
  pass "status: after complete is done"
else
  fail "status: after complete is done (got: $OUTPUT)"
fi

teardown

# ── Test: status on nonexistent item ─────────────────────────────────

setup
if ! "$KC_ITEM" status KC-9999 2>/dev/null; then
  pass "status on nonexistent item fails"
else
  fail "status on nonexistent item fails"
fi
teardown

# ── Test: complete on nonexistent item fails ─────────────────────────

setup
if ! "$KC_ITEM" complete KC-9999 2>/dev/null; then
  pass "complete nonexistent item fails"
else
  fail "complete nonexistent item fails"
fi
teardown

# ── Test: release on nonexistent item fails ──────────────────────────

setup
if ! "$KC_ITEM" release KC-9999 2>/dev/null; then
  pass "release nonexistent item fails"
else
  fail "release nonexistent item fails"
fi
teardown

# ── Test: full lifecycle (active→claim→release→claim→complete) ──────

setup

# Start active
OUTPUT=$("$KC_ITEM" status KC-0001)
[ "$OUTPUT" = "active" ] || {
  fail "lifecycle: start active (got: $OUTPUT)"
  teardown
}

# Claim
"$KC_ITEM" claim KC-0001 >/dev/null
OUTPUT=$("$KC_ITEM" status KC-0001)
[ "$OUTPUT" = "in_progress" ] || {
  fail "lifecycle: after claim (got: $OUTPUT)"
  teardown
}

# Release back to active
"$KC_ITEM" release KC-0001 >/dev/null
OUTPUT=$("$KC_ITEM" status KC-0001)
[ "$OUTPUT" = "active" ] || {
  fail "lifecycle: after release (got: $OUTPUT)"
  teardown
}

# Claim again
"$KC_ITEM" claim KC-0001 >/dev/null
OUTPUT=$("$KC_ITEM" status KC-0001)
[ "$OUTPUT" = "in_progress" ] || {
  fail "lifecycle: after second claim (got: $OUTPUT)"
  teardown
}

# Complete
"$KC_ITEM" complete KC-0001 >/dev/null
OUTPUT=$("$KC_ITEM" status KC-0001)
[ "$OUTPUT" = "done" ] || {
  fail "lifecycle: after complete (got: $OUTPUT)"
  teardown
}

# Done item excluded from INDEX
if ! grep -q "KC-0001" "$KNOWLEDGE_DIR/INDEX.md" && [ -f "$KNOWLEDGE_DIR/KC-0001--test-item.md" ]; then
  pass "Full lifecycle: active→claim→release→claim→complete"
else
  fail "Full lifecycle: active→claim→release→claim→complete"
fi

teardown

# ── Summary ─────────────────────────────────────────────────────────

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
