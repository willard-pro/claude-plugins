#!/usr/bin/env bash
# test-planner-crosscheck-bypass.sh — Tests for planner-crosscheck-bypass.sh (#174)
#
# Run: bash ticket-planner/lib/tests/test-planner-crosscheck-bypass.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/.."

source "${LIB_DIR}/planner-crosscheck-bypass.sh"

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

echo "=== planner-crosscheck-bypass tests ==="

# ═══════════════════════════════════════════════════════════════════════════
# planner_crosscheck_bypass_sweep
# ═══════════════════════════════════════════════════════════════════════════

echo "--- undisclosed second writer is BYPASS_PATH_UNADDRESSED ---"
SPECS1="${TMPDIR}/t1/specs"
REPOS1="${TMPDIR}/t1/repos"
mkdir -p "$SPECS1" "${REPOS1}/lib" "${REPOS1}/worker"

cat >"${SPECS1}/vs-5a.md" <<'EOF'
## Description

Canonical storage location is automatically derived from `classification` — see lib/r2.ts:1.
EOF

cat >"${REPOS1}/lib/r2.ts" <<'EOF'
export function buildStorageKey(classification) {
  return classification;
}
EOF

cat >"${REPOS1}/worker/main.py" <<'EOF'
def _build_classified_key(classification):
    return classification
EOF

out1=$(planner_crosscheck_bypass_sweep "$SPECS1" "$REPOS1")
rc1=$?
if [ "$rc1" -eq 1 ]; then
  pass "undisclosed writer: sweep returns 1"
else
  fail "undisclosed writer: sweep returns 1" "returned $rc1"
fi
case "$out1" in
*"BYPASS_PATH_UNADDRESSED"*"worker/main.py"*) pass "undisclosed writer: names worker/main.py" ;;
*) fail "undisclosed writer: names worker/main.py" "got: $out1" ;;
esac
case "$out1" in
*"lib/r2.ts"*"BYPASS_PATH_UNADDRESSED"*) fail "undisclosed writer: does not flag the cited file itself" "got: $out1" ;;
*) pass "undisclosed writer: does not flag the cited file itself" ;;
esac

echo "--- guarded resource whose only writer is the cited spec does not fire (AC3) ---"
SPECS2="${TMPDIR}/t2/specs"
REPOS2="${TMPDIR}/t2/repos"
mkdir -p "$SPECS2" "${REPOS2}/lib"

cat >"${SPECS2}/vs-b.md" <<'EOF'
## Description

Field `status` is never overwritten outside of lib/state.ts:1.
EOF

cat >"${REPOS2}/lib/state.ts" <<'EOF'
export function setStatus(status) {
  return status;
}
EOF

if planner_crosscheck_bypass_sweep "$SPECS2" "$REPOS2" >/tmp/bp-out-2.txt 2>&1; then
  pass "sole writer already cited: sweep returns 0"
else
  fail "sole writer already cited: sweep returns 0" "$(cat /tmp/bp-out-2.txt)"
fi

echo "--- spec with no guard phrase / no backtick term is a no-op ---"
SPECS3="${TMPDIR}/t3/specs"
REPOS3="${TMPDIR}/t3/repos"
mkdir -p "$SPECS3" "$REPOS3"

cat >"${SPECS3}/vs-c.md" <<'EOF'
## Description

A plain description with no guard language and no backtick identifiers.
EOF

if planner_crosscheck_bypass_sweep "$SPECS3" "$REPOS3" >/tmp/bp-out-3.txt 2>&1; then
  pass "no guard language: sweep returns 0"
else
  fail "no guard language: sweep returns 0" "$(cat /tmp/bp-out-3.txt)"
fi

# ═══════════════════════════════════════════════════════════════════════════
# planner_crosscheck_discovery_gap
# ═══════════════════════════════════════════════════════════════════════════

echo "--- undisclosed exploration gap is DISCOVERY_GAP_UNRESOLVED ---"
DISCOVERY1="${TMPDIR}/discovery1.md"
PROPOSAL1="${TMPDIR}/proposal1.md"
cat >"$DISCOVERY1" <<'EOF'
## Worker Exploration

This was a quick-scan and did not trace the full worker triage pipeline.
EOF
cat >"$PROPOSAL1" <<'EOF'
## Summary

Ships the classification epic.
EOF

out4=$(planner_crosscheck_discovery_gap "$DISCOVERY1" "$PROPOSAL1")
rc4=$?
if [ "$rc4" -eq 1 ]; then
  pass "undisclosed gap: returns 1"
else
  fail "undisclosed gap: returns 1" "returned $rc4"
fi
case "$out4" in
*"DISCOVERY_GAP_UNRESOLVED"*) pass "undisclosed gap: emits DISCOVERY_GAP_UNRESOLVED" ;;
*) fail "undisclosed gap: emits DISCOVERY_GAP_UNRESOLVED" "got: $out4" ;;
esac

echo "--- gap recorded in proposal Out of Scope does not fire ---"
DISCOVERY2="${TMPDIR}/discovery2.md"
PROPOSAL2="${TMPDIR}/proposal2.md"
cat >"$DISCOVERY2" <<'EOF'
## Worker Exploration

This was a quick-scan and did not trace the full worker triage pipeline.
EOF
cat >"$PROPOSAL2" <<'EOF'
## Summary

Ships the classification epic.

## Out of Scope

We did not trace the full worker triage pipeline; this quick-scan gap is
accepted for this iteration and revisited later.
EOF

if planner_crosscheck_discovery_gap "$DISCOVERY2" "$PROPOSAL2" >/tmp/bp-out-5.txt 2>&1; then
  pass "gap recorded in Out of Scope: returns 0"
else
  fail "gap recorded in Out of Scope: returns 0" "$(cat /tmp/bp-out-5.txt)"
fi

echo "--- discovery.md with no gap phrases is a no-op ---"
DISCOVERY3="${TMPDIR}/discovery3.md"
cat >"$DISCOVERY3" <<'EOF'
## Worker Exploration

Fully traced the triage pipeline end to end.
EOF

if planner_crosscheck_discovery_gap "$DISCOVERY3" "" >/tmp/bp-out-6.txt 2>&1; then
  pass "no gap phrases: returns 0"
else
  fail "no gap phrases: returns 0" "$(cat /tmp/bp-out-6.txt)"
fi

# ═══════════════════════════════════════════════════════════════════════════
# planner_crosscheck_bypass (public entry point)
# ═══════════════════════════════════════════════════════════════════════════

echo "--- public entry point wires both checks together ---"
REPOS4="${TMPDIR}/t4/repos"
INIT_ID="INIT-1700000002-9999"
ARTIFACTS="${REPOS4}/.ticket-auto/initiatives/${INIT_ID}/artifacts"
mkdir -p "${ARTIFACTS}/specs" "${REPOS4}/worker"

cat >"${ARTIFACTS}/specs/vs-5a.md" <<'EOF'
## Description

Canonical storage location is automatically derived from `classification` — see lib/r2.ts:1.
EOF
mkdir -p "${REPOS4}/lib"
cat >"${REPOS4}/lib/r2.ts" <<'EOF'
export function buildStorageKey(classification) {
  return classification;
}
EOF
cat >"${REPOS4}/worker/main.py" <<'EOF'
def _build_classified_key(classification):
    return classification
EOF
cat >"${ARTIFACTS}/discovery.md" <<'EOF'
## Worker Exploration

Fully traced the triage pipeline end to end.
EOF

export REPOS_ROOT="$REPOS4"
if planner_crosscheck_bypass "$INIT_ID" >/tmp/bp-out-7.txt 2>&1; then
  fail "entry point: returns 1 when bypass sweep finds a hit" "returned 0"
else
  pass "entry point: returns 1 when bypass sweep finds a hit"
fi
unset REPOS_ROOT

echo "--- public entry point reports missing artifacts dir ---"
export REPOS_ROOT="${TMPDIR}/t5/repos"
mkdir -p "$REPOS_ROOT"
if planner_crosscheck_bypass "INIT-DOES-NOT-EXIST" >/tmp/bp-out-8.txt 2>&1; then
  fail "entry point: missing artifacts dir returns 1" "returned 0"
else
  pass "entry point: missing artifacts dir returns 1"
fi
unset REPOS_ROOT

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
