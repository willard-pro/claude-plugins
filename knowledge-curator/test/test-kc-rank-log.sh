#!/usr/bin/env bash
# Unit tests for kc-rank-log.sh (ranking telemetry)
#
# Usage: bash test/test-kc-rank-log.sh
# Run from the knowledge-curator/ directory.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/../lib"
KC_RENDER="$LIB_DIR/kc-render.sh"
KC_ITEM="$LIB_DIR/kc-item.sh"
KC_RANK_LOG_SH="$LIB_DIR/kc-rank-log.sh"

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
  KDIR="$TEST_DIR/knowledge"
  mkdir -p "$KDIR"
}

teardown() {
  rm -rf "$TEST_DIR"
}

write_item() {
  # write_item <path> <id> <title> <status> <priority> <updated> <relates-yaml-or-empty>
  local path="$1" id="$2" title="$3" status="$4" priority="$5" updated="$6" relates="$7"
  {
    echo "---"
    echo "id: ${id}"
    echo "type: idea"
    echo "title: \"${title}\""
    echo "status: ${status}"
    echo "priority: ${priority}"
    echo "project: test-repo"
    echo "created: ${updated}"
    echo "updated: ${updated}"
    echo "source: manual"
    echo "why: \"because ${id}\""
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

NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
OLD=$(date -u -d '40 days ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-40d +%Y-%m-%dT%H:%M:%SZ)

# ── Test: render appends a well-formed line ──────────────────────────

setup
write_item "$KDIR/KC-0001--alpha.md" KC-0001 "Alpha" active p2 "$NOW" ""
"$KC_RENDER" "$KDIR" >/dev/null

LOG="$KDIR/.kc-rank-log"
if [ -f "$LOG" ]; then
  pass "Render: creates .kc-rank-log"
else
  fail "Render: creates .kc-rank-log"
fi

LINE=$(head -1 "$LOG")
if [ "$(echo "$LINE" | awk -F'|' '{print NF}')" = "5" ]; then
  pass "Render: log line has exactly 5 pipe-delimited fields"
else
  fail "Render: log line has exactly 5 fields (got: $LINE)"
fi

if echo "$LINE" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\|render\|KC-0001\|KC-0001\|total=1 blocked=0$'; then
  pass "Render: line matches ISO|render|next|ranked|detail schema"
else
  fail "Render: line matches schema (got: $LINE)"
fi
teardown

# ── Test: ranked list is display order, blocked marked with ! ─────────

setup
write_item "$KDIR/KC-0001--alpha.md" KC-0001 "Alpha" active p2 "$NOW" ""
write_item "$KDIR/KC-0002--beta.md" KC-0002 "Beta" active p2 "$NOW" "  - rel: depends
    id: KC-0001"
write_item "$KDIR/KC-0003--gamma.md" KC-0003 "Gamma" active p3 "$OLD" ""
"$KC_RENDER" "$KDIR" >/dev/null

RANKED=$(awk -F'|' '$2=="render" {print $4}' "$KDIR/.kc-rank-log" | tail -1)
if [ "$RANKED" = "KC-0001,KC-0003,!KC-0002" ]; then
  pass "Render: ranked list is display order with blocked item marked (!)"
else
  fail "Render: ranked list display order (got: $RANKED)"
fi

DETAIL=$(awk -F'|' '$2=="render" {print $5}' "$KDIR/.kc-rank-log" | tail -1)
if [ "$DETAIL" = "total=3 blocked=1" ]; then
  pass "Render: detail records total and blocked counts"
else
  fail "Render: detail counts (got: $DETAIL)"
fi
teardown

# ── Test: empty store logs nothing (no ranking to validate) ──────────

setup
"$KC_RENDER" "$KDIR" >/dev/null
if [ ! -f "$KDIR/.kc-rank-log" ]; then
  pass "Empty store: no render logged (nothing was ranked)"
else
  fail "Empty store: no render logged (log exists)"
fi
teardown

# ── Test: missing directory never creates a log or errors ────────────

TEST_DIR=$(mktemp -d)
if "$KC_RENDER" "$TEST_DIR/nonexistent" >/dev/null 2>&1; then
  pass "Missing directory: exits 0 (fail-open)"
else
  fail "Missing directory: exits 0"
fi
if [ ! -e "$TEST_DIR/nonexistent" ]; then
  pass "Missing directory: does not create the directory to log into"
else
  fail "Missing directory: created something unexpectedly"
fi
rm -rf "$TEST_DIR"

# ── Test: KC_RANK_LOG=0 disables logging ─────────────────────────────

setup
write_item "$KDIR/KC-0001--alpha.md" KC-0001 "Alpha" active p2 "$NOW" ""
KC_RANK_LOG=0 "$KC_RENDER" "$KDIR" >/dev/null
if [ ! -f "$KDIR/.kc-rank-log" ]; then
  pass "KC_RANK_LOG=0: no log written (opt-out honoured)"
else
  fail "KC_RANK_LOG=0: log written despite opt-out"
fi
teardown

# ── Test: claim / complete / release are logged ──────────────────────

setup
write_item "$KDIR/KC-0001--alpha.md" KC-0001 "Alpha" active p2 "$NOW" ""
KNOWLEDGE_DIR="$KDIR" "$KC_ITEM" claim KC-0001 >/dev/null
if awk -F'|' '$2=="claim" && $3=="KC-0001"' "$KDIR/.kc-rank-log" | grep -q .; then
  pass "Claim: logged as claim event"
else
  fail "Claim: logged as claim event"
fi

KNOWLEDGE_DIR="$KDIR" "$KC_ITEM" complete KC-0001 >/dev/null
if awk -F'|' '$2=="complete" && $3=="KC-0001"' "$KDIR/.kc-rank-log" | grep -q .; then
  pass "Complete: logged as complete event"
else
  fail "Complete: logged as complete event"
fi

write_item "$KDIR/KC-0002--beta.md" KC-0002 "Beta" in_progress p2 "$NOW" ""
KNOWLEDGE_DIR="$KDIR" "$KC_ITEM" release KC-0002 >/dev/null
if awk -F'|' '$2=="release" && $3=="KC-0002"' "$KDIR/.kc-rank-log" | grep -q .; then
  pass "Release: logged as release event"
else
  fail "Release: logged as release event"
fi
teardown

# ── Test: a rejected claim is NOT logged ─────────────────────────────
# Telemetry must reflect real work, not attempted work — a double-claim
# would otherwise inflate the agreement numbers.

setup
write_item "$KDIR/KC-0001--alpha.md" KC-0001 "Alpha" in_progress p2 "$NOW" ""
KNOWLEDGE_DIR="$KDIR" "$KC_ITEM" claim KC-0001 >/dev/null 2>&1 || true
if [ ! -f "$KDIR/.kc-rank-log" ] || ! grep -q "|claim|" "$KDIR/.kc-rank-log"; then
  pass "Rejected claim: not logged (already in_progress)"
else
  fail "Rejected claim: logged despite failing"
fi
teardown

# ── Test: stats with no log ──────────────────────────────────────────

setup
OUT=$("$KC_RENDER" --stats "$KDIR")
if echo "$OUT" | grep -q "No ranking telemetry yet"; then
  pass "Stats: friendly message when no telemetry exists"
else
  fail "Stats: friendly message when no telemetry exists (got: $OUT)"
fi
teardown

# ── Test: stats classifies a NEXT-box claim as a hit ─────────────────

setup
write_item "$KDIR/KC-0001--alpha.md" KC-0001 "Alpha" active p1 "$NOW" ""
write_item "$KDIR/KC-0002--beta.md" KC-0002 "Beta" active p3 "$NOW" ""
"$KC_RENDER" "$KDIR" >/dev/null
KNOWLEDGE_DIR="$KDIR" "$KC_ITEM" claim KC-0001 >/dev/null
OUT=$("$KC_RENDER" --stats "$KDIR")
if echo "$OUT" | grep -qE "NEXT box claimed +1"; then
  pass "Stats: claiming the NEXT item counts as a hit"
else
  fail "Stats: NEXT hit (got: $OUT)"
fi
if echo "$OUT" | grep -qE "1 renders · 1 claims"; then
  pass "Stats: render and claim totals reported"
else
  fail "Stats: totals (got: $OUT)"
fi
teardown

# ── Test: stats classifies a top-3 claim ─────────────────────────────

setup
write_item "$KDIR/KC-0001--alpha.md" KC-0001 "Alpha" active p1 "$NOW" ""
write_item "$KDIR/KC-0002--beta.md" KC-0002 "Beta" active p2 "$NOW" ""
"$KC_RENDER" "$KDIR" >/dev/null
KNOWLEDGE_DIR="$KDIR" "$KC_ITEM" claim KC-0002 >/dev/null
OUT=$("$KC_RENDER" --stats "$KDIR")
if echo "$OUT" | grep -qE "claimed from top 3 +1"; then
  pass "Stats: claiming position 2 counts as top-3, not a hit"
else
  fail "Stats: top-3 classification (got: $OUT)"
fi
teardown

# ── Test: stats classifies a deep claim and reports average position ──

setup
for n in 1 2 3 4 5; do
  write_item "$KDIR/KC-000${n}--item${n}.md" "KC-000${n}" "Item ${n}" active p2 "$NOW" ""
done
# Make KC-0005 rank last by giving it the lowest priority.
write_item "$KDIR/KC-0005--item5.md" KC-0005 "Item 5" active p3 "$NOW" ""
"$KC_RENDER" "$KDIR" >/dev/null
KNOWLEDGE_DIR="$KDIR" "$KC_ITEM" claim KC-0005 >/dev/null
OUT=$("$KC_RENDER" --stats "$KDIR")
if echo "$OUT" | grep -qE "claimed further down +1"; then
  pass "Stats: claiming position 4+ counts as further down"
else
  fail "Stats: deep claim classification (got: $OUT)"
fi
if echo "$OUT" | grep -q "avg position 5.0"; then
  pass "Stats: reports average position for deep claims"
else
  fail "Stats: avg position (got: $OUT)"
fi
teardown

# ── Test: stats counts blocked-item claims ───────────────────────────
# This is the tuning signal for the blocked penalty: if the human keeps
# claiming demoted items, the -60 is too harsh.

setup
write_item "$KDIR/KC-0001--alpha.md" KC-0001 "Alpha" active p2 "$NOW" ""
write_item "$KDIR/KC-0002--beta.md" KC-0002 "Beta" active p2 "$NOW" "  - rel: depends
    id: KC-0001"
"$KC_RENDER" "$KDIR" >/dev/null
KNOWLEDGE_DIR="$KDIR" "$KC_ITEM" claim KC-0002 >/dev/null
OUT=$("$KC_RENDER" --stats "$KDIR")
if echo "$OUT" | grep -qE "claims of blocked items +1"; then
  pass "Stats: counts claims of items demoted as blocked"
else
  fail "Stats: blocked claim count (got: $OUT)"
fi
teardown

# ── Test: claim with no preceding render is 'cold' ───────────────────

setup
write_item "$KDIR/KC-0001--alpha.md" KC-0001 "Alpha" active p2 "$NOW" ""
KNOWLEDGE_DIR="$KDIR" "$KC_ITEM" claim KC-0001 >/dev/null
OUT=$("$KC_RENDER" --stats "$KDIR")
if echo "$OUT" | grep -qE "claimed without a render +1"; then
  pass "Stats: claim with no preceding render counted separately"
else
  fail "Stats: cold claim classification (got: $OUT)"
fi
teardown

# ── Test: item not on screen at render time ──────────────────────────

setup
write_item "$KDIR/KC-0001--alpha.md" KC-0001 "Alpha" active p2 "$NOW" ""
"$KC_RENDER" "$KDIR" >/dev/null
write_item "$KDIR/KC-0009--late.md" KC-0009 "Late arrival" active p2 "$NOW" ""
KNOWLEDGE_DIR="$KDIR" "$KC_ITEM" claim KC-0009 >/dev/null
OUT=$("$KC_RENDER" --stats "$KDIR")
if echo "$OUT" | grep -qE "not on screen +1"; then
  pass "Stats: item absent from the last render counted as not on screen"
else
  fail "Stats: not-on-screen classification (got: $OUT)"
fi
teardown

# ── Test: renders with no claims reports gracefully ──────────────────

setup
write_item "$KDIR/KC-0001--alpha.md" KC-0001 "Alpha" active p2 "$NOW" ""
"$KC_RENDER" "$KDIR" >/dev/null
OUT=$("$KC_RENDER" --stats "$KDIR")
if echo "$OUT" | grep -q "No claims logged yet"; then
  pass "Stats: renders without claims reports nothing to compare"
else
  fail "Stats: no-claims message (got: $OUT)"
fi
teardown

# ── Test: field delimiters in input cannot break the schema ──────────

setup
# shellcheck source=/dev/null
. "$KC_RANK_LOG_SH"
kc_rank_log "$KDIR" claim "KC-0001|injected|fields" "-" "-"
LINE=$(tail -1 "$KDIR/.kc-rank-log")
if [ "$(echo "$LINE" | awk -F'|' '{print NF}')" = "5" ]; then
  pass "Sanitization: pipes in a value cannot add fields"
else
  fail "Sanitization: pipes in a value (got: $LINE)"
fi
teardown

# ── Test: log is trimmed once it exceeds the cap ─────────────────────

setup
LOG="$KDIR/.kc-rank-log"
# Trim only fires once the log drifts 200 lines past the cap, so the rewrite
# is amortised rather than paid on every append — seed past that threshold.
for i in $(seq 1 250); do
  echo "2026-01-01T00:00:00Z|claim|KC-0001|-|seed=${i}" >>"$LOG"
done
# shellcheck source=/dev/null
. "$KC_RANK_LOG_SH"
KC_RANK_LOG_MAX=10 kc_rank_log "$KDIR" claim KC-0002
LINES=$(wc -l <"$LOG")
if [ "$LINES" -le 11 ]; then
  pass "Trim: log capped at KC_RANK_LOG_MAX (got ${LINES} lines)"
else
  fail "Trim: log capped (got ${LINES} lines)"
fi
if tail -1 "$LOG" | grep -q "KC-0002"; then
  pass "Trim: newest event survives the trim"
else
  fail "Trim: newest event survives the trim"
fi
teardown

# ── Test: telemetry failure never breaks a mutation ──────────────────
# The log is dropped into a read-only directory; claim must still succeed.

setup
write_item "$KDIR/KC-0001--alpha.md" KC-0001 "Alpha" active p2 "$NOW" ""
"$KC_RENDER" "$KDIR" >/dev/null
chmod a-w "$KDIR/.kc-rank-log"
if KNOWLEDGE_DIR="$KDIR" "$KC_ITEM" claim KC-0001 >/dev/null 2>&1; then
  pass "Fail-open: unwritable log does not break claim"
else
  fail "Fail-open: unwritable log broke claim"
fi
chmod u+w "$KDIR/.kc-rank-log" 2>/dev/null || true
teardown

# ── Results ──────────────────────────────────────────────────────────

echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ] || exit 1
