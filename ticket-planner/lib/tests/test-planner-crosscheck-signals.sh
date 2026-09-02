#!/usr/bin/env bash
# test-planner-crosscheck-signals.sh — Tests for planner-crosscheck-signals.sh (#220)
#
# Run: bash ticket-planner/lib/tests/test-planner-crosscheck-signals.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/.."

source "${LIB_DIR}/planner-crosscheck-signals.sh"

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

export REPOS_ROOT="${TMPDIR}/repos"
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

# Usage: write_spec <specs_dir> <name> <signals_json>
write_spec() {
  local dir="$1" name="$2" signals="$3"
  cat >"${dir}/${name}.md" <<EOF
# ${name}

## Description

Spec fixture for planner-crosscheck-signals tests.

## Signals

\`\`\`json
${signals}
\`\`\`
EOF
}

echo "=== planner-crosscheck-signals tests ==="

# ── Byte-identical Signals across 2+ specs ──────────────────────────────────

echo "--- byte-identical Signals blocks ---"
INIT_A="init-a"
SPECS_A="${REPOS_ROOT}/.ticket-auto/initiatives/${INIT_A}/artifacts/specs"
mkdir -p "$SPECS_A"

SIGNALS_SHARED='{"services_identified": 2, "symbols_resolved": 5, "prior_art_found": true, "complexity": "moderate", "exploration_depth": "standard"}'
write_spec "$SPECS_A" "vs-a1" "$SIGNALS_SHARED"
write_spec "$SPECS_A" "vs-a2" "$SIGNALS_SHARED"
write_spec "$SPECS_A" "vs-a3" "$SIGNALS_SHARED"

out=$(planner_crosscheck_signals "$INIT_A")
rc=$?
if [ "$rc" -eq 1 ]; then
  pass "byte-identical: returns 1"
else
  fail "byte-identical: returns 1" "returned $rc"
fi
case "$out" in
*"SIGNALS_UNIFORM"*"byte-identical"*"vs-a1.md"*"vs-a2.md"*"vs-a3.md"*) pass "byte-identical: names all 3 specs" ;;
*) fail "byte-identical: names all 3 specs" "got: $out" ;;
esac

# ── Distinct Signals — clean ─────────────────────────────────────────────────

echo "--- distinct Signals — clean ---"
INIT_B="init-b"
SPECS_B="${REPOS_ROOT}/.ticket-auto/initiatives/${INIT_B}/artifacts/specs"
mkdir -p "$SPECS_B"

write_spec "$SPECS_B" "vs-b1" '{"services_identified": 1, "symbols_resolved": 3, "prior_art_found": false, "complexity": "simple", "exploration_depth": "quick-scan"}'
write_spec "$SPECS_B" "vs-b2" '{"services_identified": 4, "symbols_resolved": 9, "prior_art_found": true, "complexity": "complex", "exploration_depth": "deep"}'

out=$(planner_crosscheck_signals "$INIT_B")
rc=$?
if [ "$rc" -eq 0 ]; then
  pass "distinct signals: returns 0"
else
  fail "distinct signals: returns 0" "returned $rc, out: $out"
fi

# ── Near-identical on the 3 called-out fields, differing complexity/depth ──

echo "--- near-identical (3-field match, differing complexity/exploration_depth) ---"
INIT_C="init-c"
SPECS_C="${REPOS_ROOT}/.ticket-auto/initiatives/${INIT_C}/artifacts/specs"
mkdir -p "$SPECS_C"

write_spec "$SPECS_C" "vs-c1" '{"services_identified": 2, "symbols_resolved": 5, "prior_art_found": true, "complexity": "simple", "exploration_depth": "quick-scan"}'
write_spec "$SPECS_C" "vs-c2" '{"services_identified": 2, "symbols_resolved": 5, "prior_art_found": true, "complexity": "complex", "exploration_depth": "deep"}'

out=$(planner_crosscheck_signals "$INIT_C")
rc=$?
if [ "$rc" -eq 1 ]; then
  pass "near-identical: returns 1"
else
  fail "near-identical: returns 1" "returned $rc"
fi
case "$out" in
*"SIGNALS_UNIFORM"*"near-identical"*"vs-c1.md"*"vs-c2.md"*) pass "near-identical: names both specs" ;;
*) fail "near-identical: names both specs" "got: $out" ;;
esac

# ── Trivial all-zero/false combination is excluded from near-identical ─────

echo "--- trivial all-zero/false combination does not fire ---"
INIT_D="init-d"
SPECS_D="${REPOS_ROOT}/.ticket-auto/initiatives/${INIT_D}/artifacts/specs"
mkdir -p "$SPECS_D"

write_spec "$SPECS_D" "vs-d1" '{"services_identified": 0, "symbols_resolved": 0, "prior_art_found": false, "complexity": "simple", "exploration_depth": "quick-scan"}'
write_spec "$SPECS_D" "vs-d2" '{"services_identified": 0, "symbols_resolved": 0, "prior_art_found": false, "complexity": "moderate", "exploration_depth": "standard"}'

out=$(planner_crosscheck_signals "$INIT_D")
rc=$?
if [ "$rc" -eq 0 ]; then
  pass "trivial all-zero/false: returns 0"
else
  fail "trivial all-zero/false: returns 0" "returned $rc, out: $out"
fi

# ── A single spec file can never trigger a finding ──────────────────────────

echo "--- single spec — clean ---"
INIT_E="init-e"
SPECS_E="${REPOS_ROOT}/.ticket-auto/initiatives/${INIT_E}/artifacts/specs"
mkdir -p "$SPECS_E"

write_spec "$SPECS_E" "vs-e1" "$SIGNALS_SHARED"

out=$(planner_crosscheck_signals "$INIT_E")
rc=$?
if [ "$rc" -eq 0 ]; then
  pass "single spec: returns 0"
else
  fail "single spec: returns 0" "returned $rc, out: $out"
fi

# ── Byte-identical pair does not ALSO fire as near-identical duplicate ─────

echo "--- byte-identical pair not double-reported as near-identical ---"
INIT_F="init-f"
SPECS_F="${REPOS_ROOT}/.ticket-auto/initiatives/${INIT_F}/artifacts/specs"
mkdir -p "$SPECS_F"

write_spec "$SPECS_F" "vs-f1" "$SIGNALS_SHARED"
write_spec "$SPECS_F" "vs-f2" "$SIGNALS_SHARED"

out=$(planner_crosscheck_signals "$INIT_F")
findings=$(echo "$out" | grep -c "SIGNALS_UNIFORM")
if [ "$findings" -eq 1 ]; then
  pass "byte-identical pair: exactly one finding line"
else
  fail "byte-identical pair: exactly one finding line" "got $findings lines: $out"
fi

# ── Missing specs directory is not a finding ────────────────────────────────

echo "--- missing specs directory — clean ---"
INIT_G="init-g-missing"

out=$(planner_crosscheck_signals "$INIT_G")
rc=$?
if [ "$rc" -eq 0 ]; then
  pass "missing specs dir: returns 0"
else
  fail "missing specs dir: returns 0" "returned $rc, out: $out"
fi

# ── No Signals block at all is not a finding (structural — spec-validate's job) ──

echo "--- spec with no Signals block does not participate ---"
INIT_H="init-h"
SPECS_H="${REPOS_ROOT}/.ticket-auto/initiatives/${INIT_H}/artifacts/specs"
mkdir -p "$SPECS_H"

cat >"${SPECS_H}/vs-h1.md" <<'EOF'
# vs-h1

## Description

No Signals section at all.
EOF
write_spec "$SPECS_H" "vs-h2" "$SIGNALS_SHARED"

out=$(planner_crosscheck_signals "$INIT_H")
rc=$?
if [ "$rc" -eq 0 ]; then
  pass "no Signals block: returns 0 (only 1 spec has a parseable block)"
else
  fail "no Signals block: returns 0 (only 1 spec has a parseable block)" "returned $rc, out: $out"
fi

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
