#!/usr/bin/env bash
# test-planner-crosscheck-deps.sh — Tests for planner-crosscheck-deps.sh (#221)
#
# Run: bash ticket-planner/lib/tests/test-planner-crosscheck-deps.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/.."

source "${LIB_DIR}/planner-crosscheck-propagation.sh"
source "${LIB_DIR}/planner-crosscheck-deps.sh"

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

# Usage: write_spec <specs_dir> <name> <labels_line>
write_spec() {
  local dir="$1" name="$2" labels="$3"
  cat >"${dir}/${name}.md" <<EOF
# ${name}

## Description

Spec fixture for planner-crosscheck-deps tests.

## Labels

${labels}
EOF
}

echo "=== planner-crosscheck-deps tests ==="

# ── Full-slug reference resolves cleanly ────────────────────────────────────

echo "--- full-slug blocked-by resolves ---"
INIT_A="init-a"
SPECS_A="${REPOS_ROOT}/.ticket-auto/initiatives/${INIT_A}/artifacts/specs"
mkdir -p "$SPECS_A"

write_spec "$SPECS_A" "vs-1-schema" "blocked-by:vs-2-migration"
write_spec "$SPECS_A" "vs-2-migration" "type:backend"

out=$(planner_crosscheck_deps "$INIT_A")
rc=$?
if [ "$rc" -eq 0 ]; then
  pass "full-slug: returns 0"
else
  fail "full-slug: returns 0" "returned $rc, out: $out"
fi

# ── Unambiguous short-form prefix resolves cleanly ──────────────────────────

echo "--- unambiguous prefix blocked-by resolves ---"
INIT_B="init-b"
SPECS_B="${REPOS_ROOT}/.ticket-auto/initiatives/${INIT_B}/artifacts/specs"
mkdir -p "$SPECS_B"

write_spec "$SPECS_B" "exc-1" "type:backend"
write_spec "$SPECS_B" "exc-3-handler" "blocked-by:exc-1"
write_spec "$SPECS_B" "exc-4-consumer" "blocked-by:\`exc-3\`"

out=$(planner_crosscheck_deps "$INIT_B")
rc=$?
if [ "$rc" -eq 0 ]; then
  pass "unambiguous prefix (with backticks): returns 0"
else
  fail "unambiguous prefix (with backticks): returns 0" "returned $rc, out: $out"
fi

# ── Fully unresolved token — dangling ───────────────────────────────────────

echo "--- unresolved blocked-by token ---"
INIT_C="init-c"
SPECS_C="${REPOS_ROOT}/.ticket-auto/initiatives/${INIT_C}/artifacts/specs"
mkdir -p "$SPECS_C"

write_spec "$SPECS_C" "vs-1" "blocked-by:vs-9-nonexistent"

out=$(planner_crosscheck_deps "$INIT_C")
rc=$?
if [ "$rc" -eq 1 ]; then
  pass "unresolved token: returns 1"
else
  fail "unresolved token: returns 1" "returned $rc"
fi
case "$out" in
*"DANGLING_BLOCKED_BY"*"vs-1.md"*"vs-9-nonexistent"*"does not resolve"*) pass "unresolved token: names spec and ref" ;;
*) fail "unresolved token: names spec and ref" "got: $out" ;;
esac

# ── Ambiguous prefix — matches 2+ sibling specs ─────────────────────────────

echo "--- ambiguous prefix blocked-by token ---"
INIT_D="init-d"
SPECS_D="${REPOS_ROOT}/.ticket-auto/initiatives/${INIT_D}/artifacts/specs"
mkdir -p "$SPECS_D"

write_spec "$SPECS_D" "exc-2-alpha" "type:backend"
write_spec "$SPECS_D" "exc-2-beta" "type:backend"
write_spec "$SPECS_D" "exc-9-consumer" "blocked-by:exc-2"

out=$(planner_crosscheck_deps "$INIT_D")
rc=$?
if [ "$rc" -eq 1 ]; then
  pass "ambiguous prefix: returns 1"
else
  fail "ambiguous prefix: returns 1" "returned $rc"
fi
case "$out" in
*"DANGLING_BLOCKED_BY"*"exc-9-consumer.md"*"ambiguous prefix"*"exc-2-alpha"*"exc-2-beta"*) pass "ambiguous prefix: names both candidate specs" ;;
*) fail "ambiguous prefix: names both candidate specs" "got: $out" ;;
esac

# ── Mixed line: one good, one dangling — only the bad one is reported ──────

echo "--- mixed good and dangling references on same Labels line ---"
INIT_E="init-e"
SPECS_E="${REPOS_ROOT}/.ticket-auto/initiatives/${INIT_E}/artifacts/specs"
mkdir -p "$SPECS_E"

write_spec "$SPECS_E" "vs-1" "type:backend"
write_spec "$SPECS_E" "vs-2" "type:backend, blocked-by:vs-1, blocked-by:vs-404-missing"

out=$(planner_crosscheck_deps "$INIT_E")
rc=$?
findings=$(echo "$out" | grep -c "DANGLING_BLOCKED_BY")
if [ "$rc" -eq 1 ] && [ "$findings" -eq 1 ]; then
  pass "mixed references: exactly one finding, for the dangling ref only"
else
  fail "mixed references: exactly one finding, for the dangling ref only" "rc=$rc findings=$findings out: $out"
fi
case "$out" in
*"vs-404-missing"*) pass "mixed references: names the dangling ref" ;;
*) fail "mixed references: names the dangling ref" "got: $out" ;;
esac
case "$out" in
*"vs-1\""*) fail "mixed references: does not name the resolved ref" "got: $out" ;;
*) pass "mixed references: does not name the resolved ref" ;;
esac

# ── No Labels line at all is not a finding ──────────────────────────────────

echo "--- spec with no Labels line does not participate ---"
INIT_F="init-f"
SPECS_F="${REPOS_ROOT}/.ticket-auto/initiatives/${INIT_F}/artifacts/specs"
mkdir -p "$SPECS_F"

cat >"${SPECS_F}/vs-f1.md" <<'EOF'
# vs-f1

## Description

No Labels section at all.
EOF

out=$(planner_crosscheck_deps "$INIT_F")
rc=$?
if [ "$rc" -eq 0 ]; then
  pass "no Labels line: returns 0"
else
  fail "no Labels line: returns 0" "returned $rc, out: $out"
fi

# ── Labels line with no blocked-by token is not a finding ──────────────────

echo "--- Labels line with no blocked-by token ---"
INIT_G="init-g"
SPECS_G="${REPOS_ROOT}/.ticket-auto/initiatives/${INIT_G}/artifacts/specs"
mkdir -p "$SPECS_G"

write_spec "$SPECS_G" "vs-g1" "type:backend, priority:P1"

out=$(planner_crosscheck_deps "$INIT_G")
rc=$?
if [ "$rc" -eq 0 ]; then
  pass "no blocked-by token: returns 0"
else
  fail "no blocked-by token: returns 0" "returned $rc, out: $out"
fi

# ── Missing specs directory is not a finding ────────────────────────────────

echo "--- missing specs directory — clean ---"
INIT_H="init-h-missing"

out=$(planner_crosscheck_deps "$INIT_H")
rc=$?
if [ "$rc" -eq 0 ]; then
  pass "missing specs dir: returns 0"
else
  fail "missing specs dir: returns 0" "returned $rc, out: $out"
fi

# ── INDEX.md is excluded from both scanning and the known-slug set ─────────

echo "--- INDEX.md excluded ---"
INIT_I="init-i"
SPECS_I="${REPOS_ROOT}/.ticket-auto/initiatives/${INIT_I}/artifacts/specs"
mkdir -p "$SPECS_I"

write_spec "$SPECS_I" "INDEX" "blocked-by:vs-1"
write_spec "$SPECS_I" "vs-1" "blocked-by:INDEX"

out=$(planner_crosscheck_deps "$INIT_I")
rc=$?
if [ "$rc" -eq 1 ]; then
  pass "INDEX.md excluded: blocked-by:INDEX does not resolve"
else
  fail "INDEX.md excluded: blocked-by:INDEX does not resolve" "returned $rc, out: $out"
fi
case "$out" in
*"INDEX.md"*) fail "INDEX.md excluded: INDEX.md itself is never scanned" "got: $out" ;;
*) pass "INDEX.md excluded: INDEX.md itself is never scanned" ;;
esac

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
