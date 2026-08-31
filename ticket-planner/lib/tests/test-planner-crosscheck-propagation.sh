#!/usr/bin/env bash
# test-planner-crosscheck-propagation.sh — Tests for planner-crosscheck-propagation.sh
#
# Run: bash ticket-planner/lib/tests/test-planner-crosscheck-propagation.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/.."

source "${LIB_DIR}/planner-crosscheck-propagation.sh"

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

echo "=== planner-crosscheck-propagation tests ==="

# ═══════════════════════════════════════════════════════════════════════════
# planner_crosscheck_consensus_propagation
# ═══════════════════════════════════════════════════════════════════════════

echo "--- resolution correctly propagated to both siblings passes ---"
SPECS1="${TMPDIR}/specs1"
mkdir -p "$SPECS1"
cat >"${SPECS1}/vs-1.md" <<'EOF'
## Title
Parent terminal state on confirm path

## Description
Sets `status` to classified when the confirm path completes.
EOF
cat >"${SPECS1}/vs-2.md" <<'EOF'
## Title
Parent terminal state on split path

## Description
Also sets `status` to classified when the split path completes.
EOF
CONSENSUS1="${TMPDIR}/consensus1.md"
cat >"$CONSENSUS1" <<'EOF'
## Findings Addressed

1. Parent terminal state must be consistent across both split paths.
   Disposition: Accepted.
   Both split paths flip the parent document to `status`. Applies to vs-1 and vs-2.

2. Naming nit in error message.
   Disposition: Rejected.
   Not worth a ticket.
EOF

if planner_crosscheck_consensus_propagation "$CONSENSUS1" "$SPECS1" >/tmp/pp-out-1.txt 2>&1; then
  pass "resolution reaching both siblings passes"
else
  fail "resolution reaching both siblings passes" "$(cat /tmp/pp-out-1.txt)"
fi

echo "--- resolution reaching one sibling but not the other is RESOLUTION_NOT_PROPAGATED ---"
SPECS2="${TMPDIR}/specs2"
mkdir -p "$SPECS2"
cat >"${SPECS2}/vs-3.md" <<'EOF'
## Title
Confirm-split endpoint

## Description
Flips `status` to classified.
EOF
cat >"${SPECS2}/vs-4.md" <<'EOF'
## Title
Auto-split endpoint

## Description
Flips out of needs_review to ready — no mention of the field being set.
EOF
CONSENSUS2="${TMPDIR}/consensus2.md"
cat >"$CONSENSUS2" <<'EOF'
## Findings Addressed

1. Parent terminal state must be consistent across both split paths.
   Disposition: Accepted.
   Both split paths flip the parent document to `status`. Applies to vs-3 and vs-4.
EOF

OUT=$(planner_crosscheck_consensus_propagation "$CONSENSUS2" "$SPECS2" 2>&1)
RC=$?
if [ "$RC" -ne 0 ] && echo "$OUT" | grep -q "RESOLUTION_NOT_PROPAGATED" &&
  echo "$OUT" | grep -q "has-it=\[vs-3\]" && echo "$OUT" | grep -q "missing-it=\[vs-4\]"; then
  pass "asymmetric propagation reports RESOLUTION_NOT_PROPAGATED naming both sides"
else
  fail "asymmetric propagation reports RESOLUTION_NOT_PROPAGATED naming both sides" "$OUT"
fi

echo "--- resolution naming only one ticket never fires (false-positive guard) ---"
SPECS3="${TMPDIR}/specs3"
mkdir -p "$SPECS3"
cat >"${SPECS3}/vs-9.md" <<'EOF'
## Title
Single-ticket fix

## Description
Some unrelated content.
EOF
cat >"${SPECS3}/vs-10.md" <<'EOF'
## Title
Unrelated ticket

## Description
Nothing to do with the finding below.
EOF
CONSENSUS3="${TMPDIR}/consensus3.md"
cat >"$CONSENSUS3" <<'EOF'
## Findings Addressed

1. Single-ticket cleanup.
   Disposition: Accepted.
   Rename the `foo` variable in vs-9 for clarity.
EOF

if planner_crosscheck_consensus_propagation "$CONSENSUS3" "$SPECS3" >/tmp/pp-out-3.txt 2>&1; then
  pass "single-ticket resolution does not fire"
else
  fail "single-ticket resolution does not fire" "$(cat /tmp/pp-out-3.txt)"
fi

echo "--- rejected/deferred findings are excluded ---"
CONSENSUS4="${TMPDIR}/consensus4.md"
cat >"$CONSENSUS4" <<'EOF'
## Findings Addressed

1. Parent terminal state must be consistent across both split paths.
   Disposition: Deferred.
   Both split paths flip the parent document to `status`. Applies to vs-3 and vs-4.
EOF

if planner_crosscheck_consensus_propagation "$CONSENSUS4" "$SPECS2" >/tmp/pp-out-4.txt 2>&1; then
  pass "deferred finding is excluded from propagation check"
else
  fail "deferred finding is excluded from propagation check" "$(cat /tmp/pp-out-4.txt)"
fi

# ═══════════════════════════════════════════════════════════════════════════
# planner_crosscheck_forward_references
# ═══════════════════════════════════════════════════════════════════════════

echo "--- unfulfilled forward reference is FORWARD_REF_UNFULFILLED ---"
SPECS5="${TMPDIR}/specs5"
mkdir -p "$SPECS5"
cat >"${SPECS5}/vs-5b.md" <<'EOF'
## Title
Lock override page (part 1)

## Description
This ticket does not add lock/override display — that lands in `vs-5c` and is
additive to this same page.
EOF
cat >"${SPECS5}/vs-5c.md" <<'EOF'
## Title
Pagination controls

## Description
This ticket adds pagination controls only. No new UI elements.
EOF

OUT=$(planner_crosscheck_forward_references "$SPECS5" 2>&1)
RC=$?
if [ "$RC" -ne 0 ] && echo "$OUT" | grep -q "FORWARD_REF_UNFULFILLED" && echo "$OUT" | grep -q "vs-5c"; then
  pass "unfulfilled forward reference reports FORWARD_REF_UNFULFILLED"
else
  fail "unfulfilled forward reference reports FORWARD_REF_UNFULFILLED" "$OUT"
fi

echo "--- fulfilled forward reference passes ---"
SPECS6="${TMPDIR}/specs6"
mkdir -p "$SPECS6"
cat >"${SPECS6}/vs-6b.md" <<'EOF'
## Title
Lock override page (part 1)

## Description
This ticket does not add lock/override display — that lands in `vs-6c` and is
additive to this same page.
EOF
cat >"${SPECS6}/vs-6c.md" <<'EOF'
## Title
Lock override page (part 2)

## Description
Adds the lock override display controls to the same page as vs-6b.
EOF

if planner_crosscheck_forward_references "$SPECS6" >/tmp/pp-out-6.txt 2>&1; then
  pass "fulfilled forward reference passes"
else
  fail "fulfilled forward reference passes" "$(cat /tmp/pp-out-6.txt)"
fi

echo "--- no forward-reference phrase present is a clean no-op ---"
SPECS7="${TMPDIR}/specs7"
mkdir -p "$SPECS7"
cat >"${SPECS7}/vs-7a.md" <<'EOF'
## Title
Standalone ticket

## Description
Nothing here references any other ticket.
EOF
cat >"${SPECS7}/vs-7b.md" <<'EOF'
## Title
Another standalone ticket

## Description
Also nothing to see here.
EOF

if planner_crosscheck_forward_references "$SPECS7" >/tmp/pp-out-7.txt 2>&1; then
  pass "specs with no forward references are a clean no-op"
else
  fail "specs with no forward references are a clean no-op" "$(cat /tmp/pp-out-7.txt)"
fi

# ═══════════════════════════════════════════════════════════════════════════
# planner_crosscheck_carve_scope
# ═══════════════════════════════════════════════════════════════════════════

echo "--- ticket count mismatch is CARVE_SCOPE_LOST ---"
SPECS8="${TMPDIR}/specs8"
mkdir -p "$SPECS8"
cat >"${SPECS8}/a.md" <<'EOF'
## Title
A
EOF
cat >"${SPECS8}/b.md" <<'EOF'
## Title
B
EOF
LOG8="${TMPDIR}/state8.log"
cat >"$LOG8" <<'EOF'
1
2026-08-31T10:00:00Z|Specify|synthesize|start|Synthesizing proposal and writing specs for 4 tickets
2026-08-31T10:05:00Z|Specify|synthesize|done|Proposal written, 4 ticket specs in artifacts/specs/
EOF

OUT=$(planner_crosscheck_carve_scope "$LOG8" "$SPECS8" 2>&1)
RC=$?
if [ "$RC" -ne 0 ] && echo "$OUT" | grep -q "CARVE_SCOPE_LOST"; then
  pass "ticket count mismatch reports CARVE_SCOPE_LOST"
else
  fail "ticket count mismatch reports CARVE_SCOPE_LOST" "$OUT"
fi

echo "--- matching ticket count passes ---"
LOG9="${TMPDIR}/state9.log"
cat >"$LOG9" <<'EOF'
1
2026-08-31T10:00:00Z|Specify|synthesize|start|Synthesizing proposal and writing specs for 2 tickets
2026-08-31T10:05:00Z|Specify|synthesize|done|Proposal written, 2 ticket specs in artifacts/specs/
EOF

if planner_crosscheck_carve_scope "$LOG9" "$SPECS8" >/tmp/pp-out-9.txt 2>&1; then
  pass "matching ticket count passes"
else
  fail "matching ticket count passes" "$(cat /tmp/pp-out-9.txt)"
fi

echo "--- missing state log is a clean no-op (nothing to compare) ---"
if planner_crosscheck_carve_scope "${TMPDIR}/does-not-exist.log" "$SPECS8" >/tmp/pp-out-10.txt 2>&1; then
  pass "missing state log is a clean no-op"
else
  fail "missing state log is a clean no-op" "$(cat /tmp/pp-out-10.txt)"
fi

# ═══════════════════════════════════════════════════════════════════════════
# planner_crosscheck_propagation: full initiative sweep
# ═══════════════════════════════════════════════════════════════════════════

echo "--- planner_crosscheck_propagation sweeps all three checks ---"
export REPOS_ROOT="${TMPDIR}/repos"
INIT_ID="INIT-1234567890-0002"
ARTIFACTS_DIR="${REPOS_ROOT}/.ticket-auto/initiatives/${INIT_ID}/artifacts"
mkdir -p "${ARTIFACTS_DIR}/specs"

cp "${SPECS1}/vs-1.md" "${ARTIFACTS_DIR}/specs/vs-1.md"
cp "${SPECS1}/vs-2.md" "${ARTIFACTS_DIR}/specs/vs-2.md"
cp "$CONSENSUS1" "${ARTIFACTS_DIR}/consensus.md"
cat >"${REPOS_ROOT}/.ticket-auto/initiatives/${INIT_ID}/state.log" <<'EOF'
1
2026-08-31T10:00:00Z|Specify|synthesize|start|Synthesizing proposal and writing specs for 2 tickets
2026-08-31T10:05:00Z|Specify|synthesize|done|Proposal written, 2 ticket specs in artifacts/specs/
EOF

if planner_crosscheck_propagation "$INIT_ID" >/tmp/pp-out-11.txt 2>&1; then
  pass "clean initiative sweep passes all three checks"
else
  fail "clean initiative sweep passes all three checks" "$(cat /tmp/pp-out-11.txt)"
fi

echo "--- planner_crosscheck_propagation on missing artifacts dir fails cleanly ---"
if ! planner_crosscheck_propagation "INIT-does-not-exist" >/dev/null 2>&1; then
  pass "missing artifacts directory fails cleanly"
else
  fail "missing artifacts directory fails cleanly" "expected non-zero return"
fi

# ── summary ──────────────────────────────────────────────────────────────────

echo ""
echo "=== $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
