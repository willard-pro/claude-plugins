#!/usr/bin/env bash
# ── test-grill-profile.sh ─────────────────────────────────────────────────────
# Test suite for grill-profile.sh — profile loading and validation.
# ───────────────────────────────────────────────────────────────────────────────

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$TEST_DIR/.." && pwd)"
PROFILES_DIR="$(cd "$LIB_DIR/../profiles" && pwd)"

# shellcheck source=../grill-profile.sh
source "$LIB_DIR/grill-profile.sh"

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

assert_exit() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$actual" -eq "$expected" ]; then
    pass "$desc"
  else
    fail "$desc" "expected exit $expected, got $actual"
  fi
}

# ── Shipped profile passes its own validator ──────────────────────────────────
echo "=== Shipped profile validation ==="

PROFILE_JSON=$(grill_profile_load "$PROFILES_DIR/product-idea.json")
exit_code=$?
assert_exit "shipped profile loads" 0 $exit_code

if grill_profile_validate "$PROFILE_JSON"; then
  pass "shipped profile passes validator"
else
  fail "shipped profile passes validator" "expected exit 0, got $? — $(grill_profile_validate "$PROFILE_JSON" 2>&1 || true)"
fi

# ── Weight sums ───────────────────────────────────────────────────────────────
echo "=== Weight sum validation ==="

# Sum = 100 (valid)
VALID_100=$(
  cat <<'JSON'
{"id":"test","label":"Test","version":"1.0","max_questions":5,"thresholds":{"ready":80,"warn":55},"dimensions":[{"id":"a","label":"A","weight":60,"critical":true},{"id":"b","label":"B","weight":40,"critical":false}],"flags":{}}
JSON
)
if grill_profile_validate "$VALID_100"; then
  pass "weight sum 100 is valid"
else
  fail "weight sum 100 is valid" "unexpected rejection"
fi

# Sum = 99 (invalid)
SUM_99=$(
  cat <<'JSON'
{"id":"test","label":"Test","version":"1.0","max_questions":5,"thresholds":{"ready":80,"warn":55},"dimensions":[{"id":"a","label":"A","weight":59,"critical":true},{"id":"b","label":"B","weight":40,"critical":false}],"flags":{}}
JSON
)
if ! grill_profile_validate "$SUM_99" 2>/dev/null; then
  pass "weight sum 99 is rejected"
else
  fail "weight sum 99 is rejected" "should have failed"
fi

# Sum = 101 (invalid)
SUM_101=$(
  cat <<'JSON'
{"id":"test","label":"Test","version":"1.0","max_questions":5,"thresholds":{"ready":80,"warn":55},"dimensions":[{"id":"a","label":"A","weight":61,"critical":true},{"id":"b","label":"B","weight":40,"critical":false}],"flags":{}}
JSON
)
if ! grill_profile_validate "$SUM_101" 2>/dev/null; then
  pass "weight sum 101 is rejected"
else
  fail "weight sum 101 is rejected" "should have failed"
fi

# ── Duplicate ids ─────────────────────────────────────────────────────────────
echo "=== Duplicate id detection ==="

DUP_IDS=$(
  cat <<'JSON'
{"id":"test","label":"Test","version":"1.0","max_questions":5,"thresholds":{"ready":80,"warn":55},"dimensions":[{"id":"a","label":"A","weight":50,"critical":true},{"id":"a","label":"A Dup","weight":50,"critical":false}],"flags":{}}
JSON
)
if ! grill_profile_validate "$DUP_IDS" 2>/dev/null; then
  pass "duplicate dimension ids rejected"
else
  fail "duplicate dimension ids rejected" "should have failed"
fi

# ── Zero critical dimensions ──────────────────────────────────────────────────
echo "=== Critical dimension requirement ==="

NO_CRITICAL=$(
  cat <<'JSON'
{"id":"test","label":"Test","version":"1.0","max_questions":5,"thresholds":{"ready":80,"warn":55},"dimensions":[{"id":"a","label":"A","weight":50,"critical":false},{"id":"b","label":"B","weight":50,"critical":false}],"flags":{}}
JSON
)
if ! grill_profile_validate "$NO_CRITICAL" 2>/dev/null; then
  pass "zero critical dimensions rejected"
else
  fail "zero critical dimensions rejected" "should have failed"
fi

# ── Inverted thresholds ───────────────────────────────────────────────────────
echo "=== Threshold ordering ==="

INVERTED=$(
  cat <<'JSON'
{"id":"test","label":"Test","version":"1.0","max_questions":5,"thresholds":{"ready":50,"warn":80},"dimensions":[{"id":"a","label":"A","weight":100,"critical":true}],"flags":{}}
JSON
)
if ! grill_profile_validate "$INVERTED" 2>/dev/null; then
  pass "inverted thresholds (warn > ready) rejected"
else
  fail "inverted thresholds (warn > ready) rejected" "should have failed"
fi

WARN_EQ_READY=$(
  cat <<'JSON'
{"id":"test","label":"Test","version":"1.0","max_questions":5,"thresholds":{"ready":80,"warn":80},"dimensions":[{"id":"a","label":"A","weight":100,"critical":true}],"flags":{}}
JSON
)
if ! grill_profile_validate "$WARN_EQ_READY" 2>/dev/null; then
  pass "warn == ready rejected"
else
  fail "warn == ready rejected" "should have failed"
fi

# ── Missing required fields ───────────────────────────────────────────────────
echo "=== Missing required fields ==="

NO_ID=$(
  cat <<'JSON'
{"label":"Test","version":"1.0","max_questions":5,"thresholds":{"ready":80,"warn":55},"dimensions":[{"id":"a","label":"A","weight":100,"critical":true}],"flags":{}}
JSON
)
if ! grill_profile_validate "$NO_ID" 2>/dev/null; then
  pass "missing id rejected"
else
  fail "missing id rejected" "should have failed"
fi

NO_DIMS=$(
  cat <<'JSON'
{"id":"test","label":"Test","version":"1.0","max_questions":5,"thresholds":{"ready":80,"warn":55},"dimensions":[],"flags":{}}
JSON
)
if ! grill_profile_validate "$NO_DIMS" 2>/dev/null; then
  pass "empty dimensions rejected"
else
  fail "empty dimensions rejected" "should have failed"
fi

# ── Malformed profile halts — no fallback ─────────────────────────────────────
echo "=== File load errors ==="

if ! grill_profile_load "/nonexistent/path.json" 2>/dev/null; then
  pass "nonexistent profile exits non-zero"
else
  fail "nonexistent profile exits non-zero" "should have failed"
fi

# ── Non-integer weight rejected ───────────────────────────────────────────────
echo "=== Non-integer weight ==="

FRACTIONAL_WEIGHT=$(
  cat <<'JSON'
{"id":"test","label":"Test","version":"1.0","max_questions":5,"thresholds":{"ready":80,"warn":55},"dimensions":[{"id":"a","label":"A","weight":50.5,"critical":true},{"id":"b","label":"B","weight":49.5,"critical":false}],"flags":{}}
JSON
)
# jq would reject this during validation (weight 50 + 49 = 99 anyway, but the weight type check should catch it)
if ! grill_profile_validate "$FRACTIONAL_WEIGHT" 2>/dev/null; then
  pass "non-integer weight rejected"
else
  # This might pass weight sum but the floor check in validation should catch non-integer weights
  # Actually, 50.5 + 49.5 = 100.0 as floats. But the floor != value check should reject.
  fail "non-integer weight rejected" "should have failed — weights must be integers"
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
