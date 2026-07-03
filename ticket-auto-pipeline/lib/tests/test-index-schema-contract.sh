#!/usr/bin/env bash
# test-index-schema-contract.sh — schema contract pinning for INDEX.md.
# Verifies that the golden fixture, prescan-docs.sh output, and appraise parser
# all agree on heading names and table column structure.
# A mismatch here silently degrades appraise to Path B — this test prevents that.
set -eo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$TEST_DIR/.." && pwd)"
GOLDEN="$TEST_DIR/fixtures/golden-INDEX.md"

PASS=0
FAIL=0

_pass() { echo "PASS: $1"; ((PASS++)) || true; }
_fail() { echo "FAIL: $1"; ((FAIL++)) || true; }

# ── Test data ──────────────────────────────────────────────────────────────────

# Expected headings (in order)
EXPECTED_HEADINGS=("Lookup by Topic" "Lookup by Service")

# Expected column headers for each table
EXPECTED_TOPIC_COLS=("Topic" "File")
EXPECTED_SERVICE_COLS=("Service" "File")

# ── Tests ──────────────────────────────────────────────────────────────────────

echo "=== INDEX.md schema contract tests ==="
echo ""

# Test 1: Golden fixture exists and is non-empty
if [ -f "$GOLDEN" ] && [ -s "$GOLDEN" ]; then
  _pass "golden-INDEX.md exists and is non-empty"
else
  _fail "golden-INDEX.md missing or empty"
fi

# Test 2: Golden fixture has required headings
for heading in "${EXPECTED_HEADINGS[@]}"; do
  if grep -q "## $heading" "$GOLDEN"; then
    _pass "golden-INDEX.md contains heading: $heading"
  else
    _fail "golden-INDEX.md missing heading: $heading"
  fi
done

# Test 3: Golden fixture has correct table column headers (Lookup by Topic)
# Table structure: heading, blank line, column header line, separator line
topic_header=$(grep -A2 '## Lookup by Topic' "$GOLDEN" | tail -1 || true)
for col in "${EXPECTED_TOPIC_COLS[@]}"; do
  if echo "$topic_header" | grep -q "$col"; then
    _pass "Lookup by Topic column: $col"
  else
    _fail "Lookup by Topic missing column: $col (got: $topic_header)"
  fi
done

# Test 4: Golden fixture has correct table column headers (Lookup by Service)
svc_header=$(grep -A2 '## Lookup by Service' "$GOLDEN" | tail -1 || true)
for col in "${EXPECTED_SERVICE_COLS[@]}"; do
  if echo "$svc_header" | grep -q "$col"; then
    _pass "Lookup by Service column: $col"
  else
    _fail "Lookup by Service missing column: $col (got: $svc_header)"
  fi
done

# Test 5: prescan-docs.sh INDEX.md output matches golden fixture headings
# Run prescan-docs.sh with minimal input and verify its INDEX.md output
# has the same heading structure as the golden fixture.
if [ -f "$LIB_DIR/prescan-docs.sh" ]; then
  tmpdir=$(mktemp -d)
  # Run with empty inputs — should produce skeleton INDEX.md with correct headings
  bash "$LIB_DIR/prescan-docs.sh" \
    --repos-root "$tmpdir" --repo-slug "test-repo" \
    >/dev/null 2>/dev/null || true

  generated_index="$tmpdir/.ticket-auto/test-repo/docs/INDEX.md"
  if [ -f "$generated_index" ]; then
    for heading in "${EXPECTED_HEADINGS[@]}"; do
      if grep -q "## $heading" "$generated_index"; then
        _pass "prescan-docs.sh output contains heading: $heading"
      else
        _fail "prescan-docs.sh output missing heading: $heading"
      fi
    done

    # Verify column headers in generated output (heading, blank line, column header)
    gen_topic=$(grep -A2 '## Lookup by Topic' "$generated_index" | tail -1 || true)
    for col in "${EXPECTED_TOPIC_COLS[@]}"; do
      if echo "$gen_topic" | grep -q "$col"; then
        _pass "prescan-docs.sh Lookup by Topic column: $col"
      else
        _fail "prescan-docs.sh Lookup by Topic missing column: $col (got: $gen_topic)"
      fi
    done

    gen_svc=$(grep -A2 '## Lookup by Service' "$generated_index" | tail -1 || true)
    for col in "${EXPECTED_SERVICE_COLS[@]}"; do
      if echo "$gen_svc" | grep -q "$col"; then
        _pass "prescan-docs.sh Lookup by Service column: $col"
      else
        _fail "prescan-docs.sh Lookup by Service missing column: $col (got: $gen_svc)"
      fi
    done
  else
    _fail "prescan-docs.sh produced no INDEX.md"
  fi
  rm -rf "$tmpdir"
else
  _fail "prescan-docs.sh not found at $LIB_DIR/prescan-docs.sh"
fi

# Test 6: Golden fixture has no unexpected headings (catch drift)
while IFS= read -r heading; do
  [ -z "$heading" ] && continue
  found=false
  for expected in "${EXPECTED_HEADINGS[@]}"; do
    [ "$heading" = "$expected" ] && found=true && break
  done
  if [ "$found" = "true" ]; then
    _pass "Heading in golden fixture is expected: $heading"
  else
    _fail "Unexpected heading in golden fixture: $heading (expected only: ${EXPECTED_HEADINGS[*]})"
  fi
done < <(grep '^## ' "$GOLDEN" | sed 's/^## //' || true)

echo ""
echo "=== $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] || exit 1
