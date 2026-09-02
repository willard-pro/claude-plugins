#!/usr/bin/env bash
# test-planner-crosscheck-citations.sh — Tests for planner-crosscheck-citations.sh
#
# Run: bash ticket-planner/lib/tests/test-planner-crosscheck-citations.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/.."

source "${LIB_DIR}/planner-crosscheck-citations.sh"

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

REPOS_ROOT="${TMPDIR}/repos"
mkdir -p "$REPOS_ROOT"

PASS=0
FAIL=0
pass() {
  echo "  PASS $1"
  PASS=$((PASS + 1))
}
fail() {
  echo "  FAIL $1: $2"
  FAIL=$((FAIL + 1))
}

echo "=== planner-crosscheck-citations tests ==="

# ── Fixture repo ─────────────────────────────────────────────────────────────
# A tiny fake application repo under REPOS_ROOT, mirroring the shapes the
# audit found: a real symbol at a real line, an unrelated symbol elsewhere.

APP_DIR="${REPOS_ROOT}/ledgerly"
mkdir -p "${APP_DIR}/lib" "${APP_DIR}/worker"

cat >"${APP_DIR}/lib/document-badges.ts" <<'EOF'
// Badge helper functions — no interface here.
export function badgeColor(status: string): string {
  return status === "classified" ? "green" : "gray";
}
export function badgeLabel(status: string): string {
  return status;
}
EOF

cat >"${APP_DIR}/worker/main.py" <<'EOF'
def _helper_one():
    pass
# padding line 3
# padding line 4
# padding line 5
# padding line 6
# padding line 7
# padding line 8
# padding line 9
# padding line 10
# padding line 11
# padding line 12
# padding line 13
# padding line 14
# padding line 15
# padding line 16
# padding line 17
# padding line 18
# padding line 19
def _run_triage_inner(doc_id):
    # line 21
    update_document_pg(doc_id)
    return doc_id
EOF

# ── planner_crosscheck_citations_one: valid citation ────────────────────────

echo "--- valid citation resolves cleanly ---"
VALID_SPEC="${TMPDIR}/valid-spec.md"
cat >"$VALID_SPEC" <<'EOF'
## Title
Valid spec

## Description
The badge color helper lives at `lib/document-badges.ts:2`.

## Labels
planned
EOF

if planner_crosscheck_citations_one "$VALID_SPEC" "$REPOS_ROOT" >/tmp/cc-out-1.txt 2>&1; then
  pass "valid citation resolves with no findings"
else
  fail "valid citation resolves with no findings" "$(cat /tmp/cc-out-1.txt)"
fi

# ── missing file ─────────────────────────────────────────────────────────────

echo "--- missing file is CITATION_UNRESOLVED ---"
MISSING_SPEC="${TMPDIR}/missing-spec.md"
cat >"$MISSING_SPEC" <<'EOF'
## Title
Missing file spec

## Description
See the `Document` interface (`lib/document-badges-nonexistent.ts:14`).
EOF

OUT=$(planner_crosscheck_citations_one "$MISSING_SPEC" "$REPOS_ROOT" 2>&1)
if [ $? -ne 0 ] && echo "$OUT" | grep -q "CITATION_UNRESOLVED"; then
  pass "missing file reports CITATION_UNRESOLVED"
else
  fail "missing file reports CITATION_UNRESOLVED" "$OUT"
fi

# ── out-of-range line ────────────────────────────────────────────────────────

echo "--- out-of-range line is CITATION_LINE_OUT_OF_RANGE ---"
RANGE_SPEC="${TMPDIR}/range-spec.md"
cat >"$RANGE_SPEC" <<'EOF'
## Title
Out of range spec

## Description
The badge helper is at `lib/document-badges.ts:9999`.
EOF

OUT=$(planner_crosscheck_citations_one "$RANGE_SPEC" "$REPOS_ROOT" 2>&1)
if [ $? -ne 0 ] && echo "$OUT" | grep -q "CITATION_LINE_OUT_OF_RANGE"; then
  pass "out-of-range line reports CITATION_LINE_OUT_OF_RANGE"
else
  fail "out-of-range line reports CITATION_LINE_OUT_OF_RANGE" "$OUT"
fi

# ── symbol at wrong line (TargetSymbols) ─────────────────────────────────────

echo "--- symbol at wrong line is CITATION_SYMBOL_MISMATCH ---"
SYMBOL_SPEC="${TMPDIR}/symbol-spec.md"
cat >"$SYMBOL_SPEC" <<'EOF'
## Title
Symbol mismatch spec

## Description
Triage helper lives in the worker.

## Signals
```json
{
  "services_identified": 1,
  "symbols_resolved": 1,
  "prior_art_found": true,
  "complexity": "simple",
  "exploration_depth": "standard",
  "TargetSymbols": "_run_triage_inner:worker/main.py:1"
}
```
EOF

OUT=$(planner_crosscheck_citations_one "$SYMBOL_SPEC" "$REPOS_ROOT" 2>&1)
if [ $? -ne 0 ] && echo "$OUT" | grep -q "CITATION_SYMBOL_MISMATCH"; then
  pass "symbol at wrong line reports CITATION_SYMBOL_MISMATCH"
else
  fail "symbol at wrong line reports CITATION_SYMBOL_MISMATCH" "$OUT"
fi

echo "--- symbol at correct line (within proximity) passes ---"
SYMBOL_OK_SPEC="${TMPDIR}/symbol-ok-spec.md"
cat >"$SYMBOL_OK_SPEC" <<'EOF'
## Title
Symbol correct spec

## Signals
```json
{
  "services_identified": 1,
  "symbols_resolved": 1,
  "prior_art_found": true,
  "complexity": "simple",
  "exploration_depth": "standard",
  "TargetSymbols": "_run_triage_inner:worker/main.py:20"
}
```
EOF

if planner_crosscheck_citations_one "$SYMBOL_OK_SPEC" "$REPOS_ROOT" >/tmp/cc-out-2.txt 2>&1; then
  pass "symbol within proximity of cited line passes"
else
  fail "symbol within proximity of cited line passes" "$(cat /tmp/cc-out-2.txt)"
fi

# ── compound two-symbol citation with two distinct line numbers (#224) ──────

echo "--- compound X()/Y():path:line1,line2 pairs each symbol with its own line ---"
COMPOUND_OK_SPEC="${TMPDIR}/compound-ok-spec.md"
cat >"$COMPOUND_OK_SPEC" <<'EOF'
## Title
Compound citation spec

## Signals
```json
{
  "services_identified": 1,
  "symbols_resolved": 1,
  "prior_art_found": true,
  "complexity": "simple",
  "exploration_depth": "standard",
  "TargetSymbols": "_helper_one()/_run_triage_inner():worker/main.py:1,20"
}
```
EOF

if planner_crosscheck_citations_one "$COMPOUND_OK_SPEC" "$REPOS_ROOT" >/tmp/cc-out-compound-1.txt 2>&1; then
  pass "compound citation pairs each symbol with its own line and passes"
else
  fail "compound citation pairs each symbol with its own line and passes" "$(cat /tmp/cc-out-compound-1.txt)"
fi

echo "--- compound X()/Y():path:line1,line2 still catches a genuinely missing symbol ---"
COMPOUND_BAD_SPEC="${TMPDIR}/compound-bad-spec.md"
cat >"$COMPOUND_BAD_SPEC" <<'EOF'
## Title
Compound citation spec with a bad symbol

## Signals
```json
{
  "services_identified": 1,
  "symbols_resolved": 1,
  "prior_art_found": true,
  "complexity": "simple",
  "exploration_depth": "standard",
  "TargetSymbols": "_helper_one()/nonexistent_symbol():worker/main.py:1,20"
}
```
EOF

OUT=$(planner_crosscheck_citations_one "$COMPOUND_BAD_SPEC" "$REPOS_ROOT" 2>&1)
if [ $? -ne 0 ] && echo "$OUT" | grep -q "CITATION_SYMBOL_MISMATCH"; then
  pass "compound citation with a genuinely missing symbol still reports CITATION_SYMBOL_MISMATCH"
else
  fail "compound citation with a genuinely missing symbol still reports CITATION_SYMBOL_MISMATCH" "$OUT"
fi

# ── precedent with zero matches ──────────────────────────────────────────────

echo "--- precedent claim with zero matches is PRECEDENT_NOT_FOUND ---"
PRECEDENT_SPEC="${TMPDIR}/precedent-spec.md"
cat >"$PRECEDENT_SPEC" <<'EOF'
## Title
Precedent spec

## Description
This mirrors the existing `needsEdit` auto-expand rule already in the upload queue.
EOF

OUT=$(planner_crosscheck_citations_one "$PRECEDENT_SPEC" "$REPOS_ROOT" 2>&1)
if [ $? -ne 0 ] && echo "$OUT" | grep -q "PRECEDENT_NOT_FOUND"; then
  pass "precedent claim with zero matches reports PRECEDENT_NOT_FOUND"
else
  fail "precedent claim with zero matches reports PRECEDENT_NOT_FOUND" "$OUT"
fi

echo "--- precedent claim that does resolve passes (no false positive) ---"
cat >"${APP_DIR}/lib/upload-queue.ts" <<'EOF'
export function needsEdit(doc): boolean {
  return doc.status === "needs_review";
}
EOF

PRECEDENT_OK_SPEC="${TMPDIR}/precedent-ok-spec.md"
cat >"$PRECEDENT_OK_SPEC" <<'EOF'
## Title
Precedent OK spec

## Description
This mirrors the existing `needsEdit` auto-expand rule already in the upload queue.
EOF

if planner_crosscheck_citations_one "$PRECEDENT_OK_SPEC" "$REPOS_ROOT" >/tmp/cc-out-3.txt 2>&1; then
  pass "precedent claim that resolves in the repo passes"
else
  fail "precedent claim that resolves in the repo passes" "$(cat /tmp/cc-out-3.txt)"
fi
rm -f "${APP_DIR}/lib/upload-queue.ts"

# ── zero false positives on a clean, realistic spec ──────────────────────────

echo "--- realistic clean spec with multiple citations and no defects ---"
CLEAN_SPEC="${TMPDIR}/clean-spec.md"
cat >"$CLEAN_SPEC" <<'EOF'
## Title
Clean multi-citation spec

## Description
Badge color logic is at `lib/document-badges.ts:3`, and the badge label helper
is at `lib/document-badges.ts:5-7`. Triage entry point is `worker/main.py:20`.

## Labels
planned

## Signals
```json
{
  "services_identified": 2,
  "symbols_resolved": 2,
  "prior_art_found": true,
  "complexity": "simple",
  "exploration_depth": "standard",
  "TargetSymbols": "badgeColor:lib/document-badges.ts:2;_run_triage_inner:worker/main.py:20"
}
```
EOF

if planner_crosscheck_citations_one "$CLEAN_SPEC" "$REPOS_ROOT" >/tmp/cc-out-4.txt 2>&1; then
  pass "clean multi-citation spec has zero findings"
else
  fail "clean multi-citation spec has zero findings" "$(cat /tmp/cc-out-4.txt)"
fi

# ── planner_crosscheck_citations: full initiative sweep ─────────────────────

echo "--- planner_crosscheck_citations sweeps specs/ + proposal.md + consensus.md ---"
INIT_ID="INIT-1234567890-0001"
ARTIFACTS_DIR="${REPOS_ROOT}/.ticket-auto/initiatives/${INIT_ID}/artifacts"
mkdir -p "${ARTIFACTS_DIR}/specs"

cp "$CLEAN_SPEC" "${ARTIFACTS_DIR}/specs/vs-1.md"
cat >"${ARTIFACTS_DIR}/proposal.md" <<'EOF'
## Summary
Proposal referencing `lib/document-badges.ts:2`.
EOF
cat >"${ARTIFACTS_DIR}/consensus.md" <<'EOF'
## Resolutions
Confirmed at `worker/main.py:20`.
EOF
cat >"${ARTIFACTS_DIR}/specs/INDEX.md" <<'EOF'
# Index
Should be skipped even though it cites `nonexistent-file.ts:1`.
EOF

OUT=$(planner_crosscheck_citations "$INIT_ID" 2>&1)
RC=$?
if [ "$RC" -eq 0 ] && echo "$OUT" | grep -q "3 passed, 0 failed out of 3 files"; then
  pass "clean initiative sweep passes and skips INDEX.md"
else
  fail "clean initiative sweep passes and skips INDEX.md" "$OUT"
fi

echo "--- planner_crosscheck_citations fails when one spec has a defect ---"
cp "$MISSING_SPEC" "${ARTIFACTS_DIR}/specs/vs-2.md"
OUT=$(planner_crosscheck_citations "$INIT_ID" 2>&1)
RC=$?
if [ "$RC" -ne 0 ] && echo "$OUT" | grep -q "3 passed, 1 failed out of 4 files"; then
  pass "initiative sweep fails when one spec has a defect"
else
  fail "initiative sweep fails when one spec has a defect" "$OUT"
fi

echo "--- planner_crosscheck_citations on missing artifacts dir fails cleanly ---"
if ! planner_crosscheck_citations "INIT-does-not-exist" >/dev/null 2>&1; then
  pass "missing artifacts directory fails cleanly"
else
  fail "missing artifacts directory fails cleanly" "expected non-zero return"
fi

# ── summary ──────────────────────────────────────────────────────────────────

echo ""
echo "=== $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
