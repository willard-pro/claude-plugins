#!/usr/bin/env bash
# test-planner-crosscheck-contracts.sh — Tests for planner-crosscheck-contracts.sh (#175)
#
# Run: bash ticket-planner/lib/tests/test-planner-crosscheck-contracts.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/.."

source "${LIB_DIR}/planner-crosscheck-contracts.sh"

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

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

echo "=== planner-crosscheck-contracts tests ==="

# ═══════════════════════════════════════════════════════════════════════════
# planner_crosscheck_contract_undefined
# ═══════════════════════════════════════════════════════════════════════════

echo "--- structure gains fields with no canonical names is CONTRACT_UNDEFINED ---"
SPECS_U1="${TMPDIR}/u1/specs"
mkdir -p "$SPECS_U1"
cat >"${SPECS_U1}/vs6-a.md" <<'EOF'
## Description

`ClassificationResult` gains fields for tier reached / attempt count, exact
shape decided later.
EOF

out=$(planner_crosscheck_contract_undefined "$SPECS_U1")
rc=$?
if [ "$rc" -eq 1 ]; then
  pass "undefined fields: returns 1"
else
  fail "undefined fields: returns 1" "returned $rc"
fi
case "$out" in
*"CONTRACT_UNDEFINED"*"ClassificationResult"*) pass "undefined fields: names the structure" ;;
*) fail "undefined fields: names the structure" "got: $out" ;;
esac

echo "--- structure gains fields WITH canonical backtick names does not fire ---"
SPECS_U2="${TMPDIR}/u2/specs"
mkdir -p "$SPECS_U2"
cat >"${SPECS_U2}/vs6-a.md" <<'EOF'
## Description

`ClassificationResult` gains fields for `tier_reached` and `attempt_count`.
EOF

if planner_crosscheck_contract_undefined "$SPECS_U2" >/tmp/cu-out.txt 2>&1; then
  pass "named fields: returns 0"
else
  fail "named fields: returns 0" "$(cat /tmp/cu-out.txt)"
fi

# ═══════════════════════════════════════════════════════════════════════════
# planner_crosscheck_contract_mismatch
# ═══════════════════════════════════════════════════════════════════════════

echo "--- disjoint shape terms across initiatives is CONTRACT_MISMATCH ---"
REPOS_M1="${TMPDIR}/m1/repos"
INITS_M1="${REPOS_M1}/.ticket-auto/initiatives"
SELF_M1="${INITS_M1}/INIT-SELF/artifacts/specs"
SIB_M1="${INITS_M1}/INIT-SIB/artifacts/specs"
mkdir -p "$SELF_M1" "$SIB_M1"

cat >"${SELF_M1}/ebc-a.md" <<'EOF'
## Description

Reads `ValidationOutcome` with fields `valid` and `confidence`.
EOF

cat >"${SIB_M1}/vs6-a.md" <<'EOF'
## Description

`ValidationOutcome` is defined with fields `status` and `code`.
EOF

out=$(planner_crosscheck_contract_mismatch "INIT-SELF" "$SELF_M1" "$REPOS_M1")
rc=$?
if [ "$rc" -eq 1 ]; then
  pass "disjoint shape: returns 1"
else
  fail "disjoint shape: returns 1" "returned $rc"
fi
case "$out" in
*"CONTRACT_MISMATCH"*"ValidationOutcome"*"disjoint shape terms"*) pass "disjoint shape: reports disjoint shape terms" ;;
*) fail "disjoint shape: reports disjoint shape terms" "got: $out" ;;
esac
case "$out" in
*"ebc-a.md"*"vs6-a.md"*) pass "disjoint shape: quotes both files" ;;
*) fail "disjoint shape: quotes both files" "got: $out" ;;
esac

echo "--- overlapping shape terms across initiatives does not fire ---"
REPOS_M2="${TMPDIR}/m2/repos"
INITS_M2="${REPOS_M2}/.ticket-auto/initiatives"
SELF_M2="${INITS_M2}/INIT-SELF/artifacts/specs"
SIB_M2="${INITS_M2}/INIT-SIB/artifacts/specs"
mkdir -p "$SELF_M2" "$SIB_M2"

cat >"${SELF_M2}/ebc-a.md" <<'EOF'
## Description

Reads `ValidationOutcome` with fields `valid` and `confidence`.
EOF

cat >"${SIB_M2}/vs6-a.md" <<'EOF'
## Description

`ValidationOutcome` is defined with fields `valid` and `confidence`.
EOF

if planner_crosscheck_contract_mismatch "INIT-SELF" "$SELF_M2" "$REPOS_M2" >/tmp/cm-out.txt 2>&1; then
  pass "overlapping shape: returns 0"
else
  fail "overlapping shape: returns 0" "$(cat /tmp/cm-out.txt)"
fi

echo "--- per-field vs top-level descriptor conflict is CONTRACT_MISMATCH even with overlapping backticks ---"
REPOS_M3="${TMPDIR}/m3/repos"
INITS_M3="${REPOS_M3}/.ticket-auto/initiatives"
SELF_M3="${INITS_M3}/INIT-VS3/artifacts/specs"
SIB_M3="${INITS_M3}/INIT-VS6/artifacts/specs"
mkdir -p "$SELF_M3" "$SIB_M3"

cat >"${SELF_M3}/vs-3a.md" <<'EOF'
## Description

Restructures `_llm_classify()` to return per-field `confidence`, not one
document-level score.
EOF

cat >"${SIB_M3}/vs6-a.md" <<'EOF'
## Description

Every tier provider calling `_llm_classify()` returns JSON with a single
top-level `confidence` key.
EOF

out=$(planner_crosscheck_contract_mismatch "INIT-VS3" "$SELF_M3" "$REPOS_M3")
rc=$?
if [ "$rc" -eq 1 ]; then
  pass "descriptor conflict: returns 1"
else
  fail "descriptor conflict: returns 1" "returned $rc"
fi
case "$out" in
*"CONTRACT_MISMATCH"*"shape-descriptor conflict"*) pass "descriptor conflict: reports shape-descriptor conflict" ;;
*) fail "descriptor conflict: reports shape-descriptor conflict" "got: $out" ;;
esac

echo "--- no sibling initiatives is a fast no-op (AC3) ---"
REPOS_M4="${TMPDIR}/m4/repos"
INITS_M4="${REPOS_M4}/.ticket-auto/initiatives"
SELF_M4="${INITS_M4}/INIT-ONLY/artifacts/specs"
mkdir -p "$SELF_M4"
cat >"${SELF_M4}/vs-a.md" <<'EOF'
## Description

Mentions `SomeStructure` with no siblings around to compare against.
EOF

if planner_crosscheck_contract_mismatch "INIT-ONLY" "$SELF_M4" "$REPOS_M4" >/tmp/cm-noop.txt 2>&1; then
  pass "no siblings: returns 0"
else
  fail "no siblings: returns 0" "$(cat /tmp/cm-noop.txt)"
fi

# ═══════════════════════════════════════════════════════════════════════════
# planner_crosscheck_contract_consumers_unnotified
# ═══════════════════════════════════════════════════════════════════════════

echo "--- retiring a structure without notifying a sibling consumer is CONTRACT_CONSUMERS_UNNOTIFIED ---"
REPOS_C1="${TMPDIR}/c1/repos"
INITS_C1="${REPOS_C1}/.ticket-auto/initiatives"
SELF_C1="${INITS_C1}/INIT-EBC/artifacts/specs"
SIB_C1="${INITS_C1}/INIT-VS6/artifacts/specs"
mkdir -p "$SELF_C1" "$SIB_C1"

cat >"${SELF_C1}/ebc-c.md" <<'EOF'
## Description

This retires `ValidationOutcome`, replacing lib/legacy.py's own call site.
EOF

cat >"${SIB_C1}/vs6-b.md" <<'EOF'
## Description

Gates escalation on reading `ValidationOutcome`.valid.
EOF

cat >"${SIB_C1}/vs6-c.md" <<'EOF'
## Description

Gates DLQ routing on reading `ValidationOutcome`.confidence.
EOF

out=$(planner_crosscheck_contract_consumers_unnotified "INIT-EBC" "$SELF_C1" "$REPOS_C1")
rc=$?
if [ "$rc" -eq 1 ]; then
  pass "unnotified consumers: returns 1"
else
  fail "unnotified consumers: returns 1" "returned $rc"
fi
case "$out" in
*"CONTRACT_CONSUMERS_UNNOTIFIED"*"vs6-b"*) pass "unnotified consumers: names vs6-b" ;;
*) fail "unnotified consumers: names vs6-b" "got: $out" ;;
esac
case "$out" in
*"CONTRACT_CONSUMERS_UNNOTIFIED"*"vs6-c"*) pass "unnotified consumers: names vs6-c" ;;
*) fail "unnotified consumers: names vs6-c" "got: $out" ;;
esac

echo "--- consumer named by slug in the retiring paragraph is acknowledged and not flagged ---"
REPOS_C2="${TMPDIR}/c2/repos"
INITS_C2="${REPOS_C2}/.ticket-auto/initiatives"
SELF_C2="${INITS_C2}/INIT-EBC/artifacts/specs"
SIB_C2="${INITS_C2}/INIT-VS6/artifacts/specs"
mkdir -p "$SELF_C2" "$SIB_C2"

cat >"${SELF_C2}/ebc-c.md" <<'EOF'
## Description

This retires `ValidationOutcome`. vs6-b already migrated off it in the same
release.
EOF

cat >"${SIB_C2}/vs6-b.md" <<'EOF'
## Description

Gates escalation on reading `ValidationOutcome`.valid.
EOF

cat >"${SIB_C2}/vs6-c.md" <<'EOF'
## Description

Gates DLQ routing on reading `ValidationOutcome`.confidence.
EOF

out2=$(planner_crosscheck_contract_consumers_unnotified "INIT-EBC" "$SELF_C2" "$REPOS_C2")
case "$out2" in
*"vs6-b"*) fail "acknowledged consumer: vs6-b not flagged" "got: $out2" ;;
*) pass "acknowledged consumer: vs6-b not flagged" ;;
esac
case "$out2" in
*"vs6-c"*) pass "acknowledged consumer: vs6-c (still unacknowledged) is flagged" ;;
*) fail "acknowledged consumer: vs6-c (still unacknowledged) is flagged" "got: $out2" ;;
esac

echo "--- retirement with no other consumers anywhere is a no-op ---"
REPOS_C3="${TMPDIR}/c3/repos"
INITS_C3="${REPOS_C3}/.ticket-auto/initiatives"
SELF_C3="${INITS_C3}/INIT-EBC/artifacts/specs"
mkdir -p "$SELF_C3"
cat >"${SELF_C3}/ebc-c.md" <<'EOF'
## Description

This retires `SomeLocalHelper`, unused anywhere else.
EOF

if planner_crosscheck_contract_consumers_unnotified "INIT-EBC" "$SELF_C3" "$REPOS_C3" >/tmp/ccu-noop.txt 2>&1; then
  pass "no consumers: returns 0"
else
  fail "no consumers: returns 0" "$(cat /tmp/ccu-noop.txt)"
fi

# ═══════════════════════════════════════════════════════════════════════════
# planner_crosscheck_contracts (public entry point)
# ═══════════════════════════════════════════════════════════════════════════

echo "--- public entry point runs all three checks ---"
REPOS_E1="${TMPDIR}/e1/repos"
INITS_E1="${REPOS_E1}/.ticket-auto/initiatives"
SELF_E1="${INITS_E1}/INIT-EBC/artifacts/specs"
mkdir -p "$SELF_E1"
cat >"${SELF_E1}/ebc-a.md" <<'EOF'
## Description

`ClassificationResult` gains fields for tier reached / attempt count.
EOF

out=$(REPOS_ROOT="$REPOS_E1" planner_crosscheck_contracts "INIT-EBC")
rc=$?
if [ "$rc" -eq 1 ]; then
  pass "entry point: returns 1 (undefined-fields finding present)"
else
  fail "entry point: returns 1 (undefined-fields finding present)" "returned $rc"
fi
case "$out" in
*"CONTRACT_UNDEFINED"*) pass "entry point: surfaces CONTRACT_UNDEFINED" ;;
*) fail "entry point: surfaces CONTRACT_UNDEFINED" "got: $out" ;;
esac

echo "--- public entry point fails when artifacts directory is missing ---"
if REPOS_ROOT="${TMPDIR}/e2/repos" planner_crosscheck_contracts "INIT-MISSING" >/tmp/ce-out.txt 2>&1; then
  fail "entry point: missing artifacts dir returns 1" "returned 0"
else
  pass "entry point: missing artifacts dir returns 1"
fi

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
