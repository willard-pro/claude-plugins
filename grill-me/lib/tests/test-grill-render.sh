#!/usr/bin/env bash
# ── test-grill-render.sh ──────────────────────────────────────────────────────
# Test suite for grill-render.sh — document rendering.
# ───────────────────────────────────────────────────────────────────────────────

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$TEST_DIR/.." && pwd)"

# shellcheck source=../grill-render.sh
source "$LIB_DIR/grill-render.sh"
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

SCRATCH=$(mktemp -d)
trap 'rm -rf "$SCRATCH"' EXIT

# ── Helper: create a minimal result.json ──────────────────────────────────────
make_result() {
  cat <<'JSON'
{
  "profile": "product-idea",
  "subject": "Test Subject",
  "round": 1,
  "readiness": 88,
  "recommendation": "ready",
  "critical_missing": "",
  "flags": "",
  "question_count": 0,
  "thresholds": {"ready": 80, "warn": 55},
  "max_questions": 7,
  "dimensions": [
    {"dimension":"objective","label":"Objective","weight":14,"status":"present","contribution":14},
    {"dimension":"users_problem","label":"Users & Problem","weight":14,"status":"present","contribution":14},
    {"dimension":"success_criteria","label":"Success Criteria","weight":14,"status":"present","contribution":14},
    {"dimension":"scope","label":"Scope","weight":12,"status":"present","contribution":12},
    {"dimension":"acceptance_criteria","label":"Acceptance Criteria","weight":12,"status":"present","contribution":12},
    {"dimension":"constraints","label":"Constraints","weight":8,"status":"present","contribution":8},
    {"dimension":"dependencies","label":"Dependencies","weight":8,"status":"present","contribution":8},
    {"dimension":"risks","label":"Risks","weight":8,"status":"present","contribution":8},
    {"dimension":"edge_cases","label":"Edge Cases","weight":6,"status":"missing","contribution":0},
    {"dimension":"assumptions","label":"Assumptions","weight":4,"status":"missing","contribution":0}
  ],
  "questions": [],
  "scored_at": "2026-07-26T00:00:00Z"
}
JSON
}

# ── Helper: create a minimal assessment.json ──────────────────────────────────
make_assessment() {
  cat <<'JSON'
{
  "profile": "product-idea",
  "subject": "Test Subject",
  "round": 1,
  "dimensions": [
    {"id":"objective","status":"present","evidence":"Build real-time collaboration","gap":""},
    {"id":"users_problem","status":"present","evidence":"Enterprise users need co-editing","gap":""},
    {"id":"success_criteria","status":"present","evidence":"500ms cursor update","gap":""},
    {"id":"scope","status":"present","evidence":"Real-time cursors, doc locking","gap":""},
    {"id":"acceptance_criteria","status":"present","evidence":"Two users open same doc simultaneously","gap":""},
    {"id":"constraints","status":"present","evidence":"Within existing WebSocket infra","gap":""},
    {"id":"dependencies","status":"present","evidence":"WebSocket service v2","gap":""},
    {"id":"risks","status":"present","evidence":"Network latency","gap":""},
    {"id":"edge_cases","status":"missing","evidence":"","gap":"No edge cases discussed"},
    {"id":"assumptions","status":"missing","evidence":"","gap":"Assumptions not stated"}
  ],
  "flags": {},
  "assumptions": [],
  "risks": [],
  "questions": []
}
JSON
}

echo "=== Section presence and order ==="

RESULT_FILE="$SCRATCH/result.json"
ASSESSMENT_FILE="$SCRATCH/assessment.json"
make_result >"$RESULT_FILE"
make_assessment >"$ASSESSMENT_FILE"

OUTPUT_FILE="$SCRATCH/output.md"
grill_render "$RESULT_FILE" "$ASSESSMENT_FILE" "$OUTPUT_FILE" 2>/dev/null

# Check all required sections present in order
SECTIONS=(
  "# Validated Business Intent"
  "## Objective"
  "## Users & Problem"
  "## Success Criteria"
  "## Scope"
  "### In scope"
  "### Out of scope"
  "## Acceptance Criteria"
  "## Constraints"
  "## Dependencies"
  "## Risks"
  "## Edge Cases"
  "## Assumptions (require validation)"
  "## Resolved Questions"
  "## Open Gaps"
  "## Category Scores"
)

prev_line=-1
all_in_order=true
for section in "${SECTIONS[@]}"; do
  line_num=$(grep -n "^${section}" "$OUTPUT_FILE" | head -1 | cut -d: -f1)
  if [ -z "$line_num" ]; then
    fail "section '${section}' exists" "not found"
    all_in_order=false
  elif [ "$line_num" -le "$prev_line" ]; then
    fail "section '${section}' order" "found at line $line_num, expected after $prev_line"
    all_in_order=false
  else
    prev_line="$line_num"
  fi
done
if $all_in_order; then
  pass "all sections present in fixed order"
fi

echo "=== Seal verification round-trip ==="

# Seal the rendered document
grill_seal_generate "$OUTPUT_FILE" "product-idea" "88" "ready" "1" "2026-07-26T00:00:00Z" 2>/dev/null

# Verify
set +e
grill_seal_verify "$OUTPUT_FILE" >/dev/null 2>&1
verify_exit=$?
set -e

if [ "$verify_exit" -eq 0 ]; then
  pass "rendered + sealed document passes seal verification"
else
  fail "rendered + sealed document passes seal verification" "exit $verify_exit"
fi

echo "=== Content-Hash is last non-empty line ==="
LAST_LINE=$(grep -v '^[[:space:]]*$' "$OUTPUT_FILE" | tail -1)
if echo "$LAST_LINE" | grep -q '^\*\*Content-Hash:\*\*'; then
  pass "Content-Hash is last non-empty line"
else
  fail "Content-Hash is last non-empty line" "last line: $LAST_LINE"
fi

echo "=== Out of scope is sourced from boundary, not gap ==="

# The scope dimension carries both a gap (assessment incompleteness) and a
# boundary (explicitly stated exclusions) with deliberately different text.
# "### Out of scope" must render the boundary text, never the gap text.
make_assessment_scope_boundary() {
  cat <<'JSON'
{
  "profile": "product-idea",
  "subject": "Test Subject",
  "round": 1,
  "dimensions": [
    {"id":"objective","status":"present","evidence":"Build real-time collaboration","gap":""},
    {"id":"users_problem","status":"present","evidence":"Enterprise users need co-editing","gap":""},
    {"id":"success_criteria","status":"present","evidence":"500ms cursor update","gap":""},
    {"id":"scope","status":"present","evidence":"Real-time cursors, doc locking","gap":"GAP_TEXT_SHOULD_NOT_APPEAR","boundary":"BOUNDARY_TEXT_SHOULD_APPEAR: mobile clients excluded"},
    {"id":"acceptance_criteria","status":"present","evidence":"Two users open same doc simultaneously","gap":""},
    {"id":"constraints","status":"present","evidence":"Within existing WebSocket infra","gap":""},
    {"id":"dependencies","status":"present","evidence":"WebSocket service v2","gap":""},
    {"id":"risks","status":"present","evidence":"Network latency","gap":""},
    {"id":"edge_cases","status":"missing","evidence":"","gap":"No edge cases discussed"},
    {"id":"assumptions","status":"missing","evidence":"","gap":"Assumptions not stated"}
  ],
  "flags": {},
  "assumptions": [],
  "risks": [],
  "questions": []
}
JSON
}

ASSESSMENT_BOUNDARY_FILE="$SCRATCH/assessment-boundary.json"
make_assessment_scope_boundary >"$ASSESSMENT_BOUNDARY_FILE"
OUTPUT_BOUNDARY_FILE="$SCRATCH/output-boundary.md"
grill_render "$RESULT_FILE" "$ASSESSMENT_BOUNDARY_FILE" "$OUTPUT_BOUNDARY_FILE" 2>/dev/null

if grep -q "BOUNDARY_TEXT_SHOULD_APPEAR" "$OUTPUT_BOUNDARY_FILE" && ! grep -q "GAP_TEXT_SHOULD_NOT_APPEAR" "$OUTPUT_BOUNDARY_FILE"; then
  pass "Out of scope renders boundary text, not gap text"
else
  fail "Out of scope renders boundary text, not gap text" "$(grep -A1 '### Out of scope' "$OUTPUT_BOUNDARY_FILE")"
fi

echo "=== Open Gaps rows are keyed by dimension id, not array position ==="

# Assessment dimensions deliberately reordered relative to result's
# profile-ordered array, and one profile dimension (constraints) omitted
# entirely — the scorer coerces omitted dimensions to "missing".
make_result_reordered() {
  cat <<'JSON'
{
  "profile": "product-idea",
  "subject": "Test Subject",
  "round": 1,
  "readiness": 60,
  "recommendation": "proceed-with-warnings",
  "critical_missing": "",
  "flags": "",
  "question_count": 0,
  "thresholds": {"ready": 80, "warn": 55},
  "max_questions": 7,
  "dimensions": [
    {"dimension":"objective","label":"Objective","weight":14,"status":"present","contribution":14},
    {"dimension":"scope","label":"Scope","weight":12,"status":"missing","contribution":0},
    {"dimension":"acceptance_criteria","label":"Acceptance Criteria","weight":12,"status":"partial","contribution":6},
    {"dimension":"constraints","label":"Constraints","weight":8,"status":"missing","contribution":0}
  ],
  "questions": [],
  "scored_at": "2026-07-26T00:00:00Z"
}
JSON
}

make_assessment_reordered() {
  # Order deliberately differs from result's dimensions array above, and
  # "constraints" is omitted entirely (coerced to missing by the scorer).
  cat <<'JSON'
{
  "profile": "product-idea",
  "subject": "Test Subject",
  "round": 1,
  "dimensions": [
    {"id":"acceptance_criteria","status":"partial","evidence":"","gap":"AC_GAP_FOR_ACCEPTANCE_CRITERIA"},
    {"id":"objective","status":"present","evidence":"Build real-time collaboration","gap":""},
    {"id":"scope","status":"missing","evidence":"","gap":"SCOPE_GAP_FOR_SCOPE"}
  ],
  "flags": {},
  "assumptions": [],
  "risks": [],
  "questions": []
}
JSON
}

RESULT_REORDERED_FILE="$SCRATCH/result-reordered.json"
ASSESSMENT_REORDERED_FILE="$SCRATCH/assessment-reordered.json"
make_result_reordered >"$RESULT_REORDERED_FILE"
make_assessment_reordered >"$ASSESSMENT_REORDERED_FILE"
OUTPUT_REORDERED_FILE="$SCRATCH/output-reordered.md"
grill_render "$RESULT_REORDERED_FILE" "$ASSESSMENT_REORDERED_FILE" "$OUTPUT_REORDERED_FILE" 2>/dev/null

GAPS_SECTION=$(sed -n '/^## Open Gaps$/,/^## Category Scores$/p' "$OUTPUT_REORDERED_FILE")

SCOPE_ROW_OK=false
AC_ROW_OK=false
CONSTRAINTS_ROW_OK=false
if echo "$GAPS_SECTION" | grep "^| scope " | grep -q "SCOPE_GAP_FOR_SCOPE"; then
  SCOPE_ROW_OK=true
fi
if echo "$GAPS_SECTION" | grep "^| acceptance_criteria " | grep -q "AC_GAP_FOR_ACCEPTANCE_CRITERIA"; then
  AC_ROW_OK=true
fi
if echo "$GAPS_SECTION" | grep "^| constraints " | grep -q "_Not specified_"; then
  CONSTRAINTS_ROW_OK=true
fi

if $SCOPE_ROW_OK && $AC_ROW_OK && $CONSTRAINTS_ROW_OK; then
  pass "Open Gaps rows keyed by id survive reordering and omission"
else
  fail "Open Gaps rows keyed by id" "scope_ok=$SCOPE_ROW_OK ac_ok=$AC_ROW_OK constraints_ok=$CONSTRAINTS_ROW_OK; section:\n${GAPS_SECTION}"
fi

echo "=== Resolved Questions renders answers from assessment.resolved ==="

# Regression test for the bug where _render_resolved_questions read the
# pending .questions array (always empty by the time rendering happens,
# since resolved questions are removed from it) instead of .resolved, and
# hardcoded the answer column to "_(pending)_".
make_assessment_with_resolved() {
  cat <<'JSON'
{
  "profile": "product-idea",
  "subject": "Test Subject",
  "round": 2,
  "dimensions": [
    {"id":"objective","status":"present","evidence":"Build real-time collaboration","gap":""},
    {"id":"users_problem","status":"present","evidence":"Enterprise users need co-editing","gap":""},
    {"id":"success_criteria","status":"present","evidence":"500ms cursor update","gap":""},
    {"id":"scope","status":"present","evidence":"Real-time cursors, doc locking","gap":""},
    {"id":"acceptance_criteria","status":"present","evidence":"Two users open same doc simultaneously","gap":""},
    {"id":"constraints","status":"present","evidence":"Within existing WebSocket infra","gap":""},
    {"id":"dependencies","status":"present","evidence":"WebSocket service v2","gap":""},
    {"id":"risks","status":"present","evidence":"Network latency","gap":""},
    {"id":"edge_cases","status":"present","evidence":"Answered in round 2","gap":""},
    {"id":"assumptions","status":"missing","evidence":"","gap":"Assumptions not stated"}
  ],
  "flags": {},
  "assumptions": [],
  "risks": [],
  "questions": [],
  "resolved": [
    {"question":"What happens on concurrent edit conflict?","dimension":"edge_cases","why":"Untested edge case","round":2,"answer":"ANSWER_TEXT_SHOULD_APPEAR"}
  ]
}
JSON
}

ASSESSMENT_RESOLVED_FILE="$SCRATCH/assessment-resolved.json"
make_assessment_with_resolved >"$ASSESSMENT_RESOLVED_FILE"
OUTPUT_RESOLVED_FILE="$SCRATCH/output-resolved.md"
grill_render "$RESULT_FILE" "$ASSESSMENT_RESOLVED_FILE" "$OUTPUT_RESOLVED_FILE" 2>/dev/null

RESOLVED_SECTION=$(sed -n '/^## Resolved Questions$/,/^## Open Gaps$/p' "$OUTPUT_RESOLVED_FILE")

if echo "$RESOLVED_SECTION" | grep -q "ANSWER_TEXT_SHOULD_APPEAR" && ! echo "$RESOLVED_SECTION" | grep -q "_(pending)_" && ! echo "$RESOLVED_SECTION" | grep -q "No questions were asked"; then
  pass "Resolved Questions renders real answer text from .resolved"
else
  fail "Resolved Questions renders real answer text from .resolved" "$RESOLVED_SECTION"
fi

echo "=== Resolved Questions shows 'no questions' only when .resolved is empty ==="

# .questions empty but .resolved also empty (never asked) — must still show
# the "no questions" message, not an empty table.
OUTPUT_NONE_FILE="$SCRATCH/output-none.md"
grill_render "$RESULT_FILE" "$ASSESSMENT_FILE" "$OUTPUT_NONE_FILE" 2>/dev/null
if grep -q "No questions were asked" "$OUTPUT_NONE_FILE"; then
  pass "empty .resolved still renders 'no questions' message"
else
  fail "empty .resolved still renders 'no questions' message" "$(grep -A2 '## Resolved Questions' "$OUTPUT_NONE_FILE")"
fi

echo "=== Results ==="
TOTAL=$((PASS + FAIL))
echo "$PASS/$TOTAL passed"
if [ "$FAIL" -gt 0 ]; then
  echo "$FAIL test(s) failed"
  exit 1
fi
echo "All tests passed"
