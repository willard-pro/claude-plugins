#!/usr/bin/env bash
# ── test-grill-seal.sh ────────────────────────────────────────────────────────
# Test suite for grill-seal.sh — seal generation and verification.
# ───────────────────────────────────────────────────────────────────────────────

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$TEST_DIR/.." && pwd)"

# shellcheck source=../grill-seal.sh
source "$LIB_DIR/grill-seal.sh"

PASS=0
FAIL=0

pass() {
  PASS=$((PASS + 1))
  echo "  PASS $1"
}
fail() {
  FAIL=$((FAIL + 1))
  echo "  FAIL $1: $2"
}

# ── Helper: run a function and capture its output + exit code ─────────────────
# Usage: run_capturing <func_name> <args...>
# Sets global: CAPTURED_OUT, CAPTURED_EXIT
run_capturing() {
  local func="$1"
  shift
  # Capture output and exit code without || true
  set +e
  CAPTURED_OUT=$("$func" "$@" 2>&1)
  CAPTURED_EXIT=$?
  set -e
}

SCRATCH=$(mktemp -d)
trap 'rm -rf "$SCRATCH"' EXIT

# ── Helper: create a minimal test document ────────────────────────────────────
make_doc() {
  cat <<'MD'
# Validated Business Intent

**Subject:** Test Subject
**Profile:** product-idea
**Readiness:** 88/100
**Recommendation:** ready

## Objective

Build a real-time collaboration feature for the document editor.

## Users & Problem

Enterprise users who need to co-edit documents simultaneously.

## Success Criteria

Users can see each other's cursors in real time within 500ms.

## Scope

### In scope

Real-time cursor presence, document locking.

### Out of scope

Video chat, voice chat, offline sync.

## Acceptance Criteria

- Two users can open the same document simultaneously
- Cursor positions update within 500ms
- Document state is consistent across clients

## Constraints

Must work within existing WebSocket infrastructure.

## Dependencies

Depends on operational WebSocket service v2.

## Risks

Network latency may exceed 500ms threshold.

## Edge Cases

_None identified_

## Assumptions (require validation)

_None identified_

## Resolved Questions

_No questions were asked — the input scored ready on the first round._

## Open Gaps

_No open gaps — all dimensions are present._

## Category Scores

| Dimension | Weight | Status | Contribution |
|-----------|--------|--------|-------------|
| Objective | 14 | present | 14 |
MD
}

# ── Round-trip: generate → verify → VALID ─────────────────────────────────────
echo "=== Round-trip verification ==="

DOC="$SCRATCH/test-roundtrip.md"
make_doc >"$DOC"

run_capturing grill_seal_generate "$DOC" "product-idea" "88" "ready" "1" "2026-07-26T00:00:00Z"
if [ "$CAPTURED_EXIT" -eq 0 ]; then
  pass "seal generation succeeds"
else
  fail "seal generation succeeds" "exit code $CAPTURED_EXIT"
fi

# Verify
run_capturing grill_seal_verify "$DOC"
STATUS=$(echo "$CAPTURED_OUT" | grep "^GRILL_SEAL_STATUS=" | cut -d= -f2)

if [ "$CAPTURED_EXIT" -eq 0 ] && [ "$STATUS" = "VALID" ]; then
  pass "round-trip verify: VALID exit 0"
else
  fail "round-trip verify: VALID exit 0" "exit=$CAPTURED_EXIT, status=$STATUS"
fi

# Check metadata extraction
READY=$(echo "$CAPTURED_OUT" | grep "^GRILL_READINESS=" | cut -d= -f2)
REC=$(echo "$CAPTURED_OUT" | grep "^GRILL_RECOMMENDATION=" | cut -d= -f2)
PROF=$(echo "$CAPTURED_OUT" | grep "^GRILL_PROFILE=" | cut -d= -f2)

if [ "$READY" = "88" ] && [ "$REC" = "ready" ] && [ "$PROF" = "product-idea" ]; then
  pass "verify extracts metadata correctly"
else
  fail "verify extracts metadata" "readiness=$READY, rec=$REC, profile=$PROF"
fi

# ── Body edit → MISMATCH exit 4 ───────────────────────────────────────────────
echo "=== Tamper detection ==="

TAMPER_DOC="$SCRATCH/test-tamper.md"
make_doc >"$TAMPER_DOC"
grill_seal_generate "$TAMPER_DOC" "product-idea" "88" "ready" "1" "2026-07-26T00:00:00Z" >/dev/null 2>&1

# Edit one byte in the body
sed -i 's/real-time/offline/' "$TAMPER_DOC"

run_capturing grill_seal_verify "$TAMPER_DOC"
TAMPER_STATUS=$(echo "$CAPTURED_OUT" | grep "^GRILL_SEAL_STATUS=" | cut -d= -f2)

if [ "$CAPTURED_EXIT" -eq 4 ] && [ "$TAMPER_STATUS" = "MISMATCH" ]; then
  pass "body edit → MISMATCH exit 4"
else
  fail "body edit → MISMATCH exit 4" "exit=$CAPTURED_EXIT, status=$TAMPER_STATUS"
fi

# ── Editing seal metadata Readiness → MISMATCH exit 4 ────────────────────────
META_TAMPER_DOC="$SCRATCH/test-meta-tamper.md"
make_doc >"$META_TAMPER_DOC"
grill_seal_generate "$META_TAMPER_DOC" "product-idea" "22" "do-not-proceed" "1" "2026-07-26T00:00:00Z" >/dev/null 2>&1

# Change readiness from 22 to 95 inside the seal
sed -i 's/\*\*Readiness:\*\* 22/**Readiness:** 95/' "$META_TAMPER_DOC"

run_capturing grill_seal_verify "$META_TAMPER_DOC"
META_STATUS=$(echo "$CAPTURED_OUT" | grep "^GRILL_SEAL_STATUS=" | cut -d= -f2)

if [ "$CAPTURED_EXIT" -eq 4 ] && [ "$META_STATUS" = "MISMATCH" ]; then
  pass "seal metadata edit → MISMATCH exit 4"
else
  fail "seal metadata edit → MISMATCH exit 4" "exit=$CAPTURED_EXIT, status=$META_STATUS"
fi

# ── No seal → exit 3 ─────────────────────────────────────────────────────────
echo "=== No-seal and missing file ==="

NO_SEAL_DOC="$SCRATCH/test-noseal.md"
make_doc >"$NO_SEAL_DOC"

run_capturing grill_seal_verify "$NO_SEAL_DOC"
NO_SEAL_STATUS=$(echo "$CAPTURED_OUT" | grep "^GRILL_SEAL_STATUS=" | cut -d= -f2)

if [ "$CAPTURED_EXIT" -eq 3 ] && [ "$NO_SEAL_STATUS" = "NO_SEAL" ]; then
  pass "no seal → exit 3 NO_SEAL"
else
  fail "no seal → exit 3 NO_SEAL" "exit=$CAPTURED_EXIT, status=$NO_SEAL_STATUS"
fi

# ── Missing file → exit 2 ────────────────────────────────────────────────────
run_capturing grill_seal_verify "$SCRATCH/nonexistent.md"

if [ "$CAPTURED_EXIT" -eq 2 ]; then
  pass "missing file → exit 2"
else
  fail "missing file → exit 2" "exit=$CAPTURED_EXIT"
fi

# ── Double-generate refused ───────────────────────────────────────────────────
echo "=== Double-seal prevention ==="

DOUBLE_DOC="$SCRATCH/test-double.md"
make_doc >"$DOUBLE_DOC"
grill_seal_generate "$DOUBLE_DOC" "product-idea" "88" "ready" "1" "2026-07-26T00:00:00Z" >/dev/null 2>&1

run_capturing grill_seal_generate "$DOUBLE_DOC" "product-idea" "88" "ready" "1" "2026-07-26T00:00:00Z"
if [ "$CAPTURED_EXIT" -ne 0 ]; then
  pass "double-generate refused"
else
  fail "double-generate refused" "should have failed"
fi

# ── Trailing newline independence ────────────────────────────────────────────
echo "=== Trailing whitespace independence ==="

TRAIL_DOC="$SCRATCH/test-trailing.md"
make_doc >"$TRAIL_DOC"
grill_seal_generate "$TRAIL_DOC" "product-idea" "88" "ready" "1" "2026-07-26T00:00:00Z" >/dev/null 2>&1

# Verify original
run_capturing grill_seal_verify "$TRAIL_DOC"
orig_exit=$CAPTURED_EXIT

# Add trailing newlines and verify again
echo "" >>"$TRAIL_DOC"
echo "" >>"$TRAIL_DOC"

run_capturing grill_seal_verify "$TRAIL_DOC"
trail_exit=$CAPTURED_EXIT

if [ "$orig_exit" -eq 0 ] && [ "$trail_exit" -eq 0 ]; then
  pass "trailing newlines after hash don't break validation"
else
  fail "trailing newlines after hash" "orig=$orig_exit, with_trailing=$trail_exit"
fi

# ── Malformed hash value → exit 3 NO_SEAL ────────────────────────────────────
echo "=== Malformed hash ==="

MALFORM_DOC="$SCRATCH/test-malform.md"
make_doc >"$MALFORM_DOC"
grill_seal_generate "$MALFORM_DOC" "product-idea" "88" "ready" "1" "2026-07-26T00:00:00Z" >/dev/null 2>&1

# Corrupt the hash to be non-hex
sed -i 's/sha256:[a-f0-9]*/sha256:zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz/' "$MALFORM_DOC"

run_capturing grill_seal_verify "$MALFORM_DOC"
MALFORM_STATUS=$(echo "$CAPTURED_OUT" | grep "^GRILL_SEAL_STATUS=" | cut -d= -f2)

if [ "$CAPTURED_EXIT" -eq 3 ] && [ "$MALFORM_STATUS" = "NO_SEAL" ]; then
  pass "malformed hash → exit 3 NO_SEAL"
else
  fail "malformed hash → exit 3 NO_SEAL" "exit=$CAPTURED_EXIT, status=$MALFORM_STATUS"
fi

# ── Content-Hash is last non-empty line ──────────────────────────────────────
echo "=== Content-Hash position ==="

CH_DOC="$SCRATCH/test-ch-position.md"
make_doc >"$CH_DOC"
grill_seal_generate "$CH_DOC" "product-idea" "88" "ready" "1" "2026-07-26T00:00:00Z" >/dev/null 2>&1

# Get the last non-empty line
LAST_LINE=$(grep -v '^[[:space:]]*$' "$CH_DOC" | tail -1)
if echo "$LAST_LINE" | grep -q '^\*\*Content-Hash:\*\*'; then
  pass "Content-Hash is the last non-empty line"
else
  fail "Content-Hash is the last non-empty line" "last line: $LAST_LINE"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo "=== Results ==="
TOTAL=$((PASS + FAIL))
echo "$PASS/$TOTAL passed"
if [ "$FAIL" -gt 0 ]; then
  echo "$FAIL test(s) failed"
  exit 1
fi
echo "All tests passed"
