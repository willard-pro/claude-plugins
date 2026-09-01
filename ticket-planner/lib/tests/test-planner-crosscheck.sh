#!/usr/bin/env bash
# test-planner-crosscheck.sh — Tests for planner-crosscheck.sh (issue #178
# wiring) and the phase-sequence / gate changes it depends on.
#
# Run: bash ticket-planner/lib/tests/test-planner-crosscheck.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/.."

source "${LIB_DIR}/planner-state.sh"
source "${LIB_DIR}/planner-router.sh"
source "${LIB_DIR}/planner-crosscheck.sh"

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

echo "=== planner-crosscheck tests ==="

# ── Phase sequence and gate wiring ──────────────────────────────────────────

echo "--- phase sequence ---"

seq=()
planner_phase_sequence seq
joined="${seq[*]}"
case "$joined" in
*"Consensus Crosscheck EpicGen"*) pass "Crosscheck sits between Consensus and EpicGen" ;;
*) fail "Crosscheck sits between Consensus and EpicGen" "sequence: $joined" ;;
esac

if [ "${#seq[@]}" -eq 10 ]; then
  pass "phase sequence has 10 phases"
else
  fail "phase sequence has 10 phases" "got ${#seq[@]}: $joined"
fi

if [ "$PLANNER_DRY_RUN_PHASE" = "Crosscheck" ]; then
  pass "PLANNER_DRY_RUN_PHASE is Crosscheck"
else
  fail "PLANNER_DRY_RUN_PHASE is Crosscheck" "got '$PLANNER_DRY_RUN_PHASE'"
fi

if [ "$PLANNER_CREATE_GATE_PHASE" = "Crosscheck" ]; then
  pass "PLANNER_CREATE_GATE_PHASE is Crosscheck"
else
  fail "PLANNER_CREATE_GATE_PHASE is Crosscheck" "got '$PLANNER_CREATE_GATE_PHASE'"
fi

# ── Fixture initiative ───────────────────────────────────────────────────────

INIT_ID="INIT-1700000000-1234"
STATE_DIR="${REPOS_ROOT}/.ticket-auto/initiatives/${INIT_ID}"
mkdir -p "${STATE_DIR}/artifacts/specs"

planner_state_init "$INIT_ID" "test idea for crosscheck wiring"
planner_state_write "$INIT_ID" "Appraisal" "scope" "done" "ok"
planner_state_write "$INIT_ID" "Discovery" "explore" "done" "ok"
planner_state_write "$INIT_ID" "Architecture" "decide" "done" "ok"
planner_state_write "$INIT_ID" "Specify" "synthesize" "start" "writing specs for 1 tickets"
planner_state_write "$INIT_ID" "Specify" "synthesize" "done" "ok"
planner_state_write "$INIT_ID" "Review" "critique" "done" "ok"
planner_state_write "$INIT_ID" "Consensus" "resolve" "done" "ok"

cat >"${STATE_DIR}/artifacts/consensus.md" <<'EOF'
# Consensus

Nothing to resolve here — single-ticket initiative.
EOF

cat >"${STATE_DIR}/artifacts/specs/vs-a.md" <<'EOF'
# vs-a

## Description

A clean spec with no citations and no precedent claims.

## Signals

```json
{"TargetSymbols": ""}
```
EOF

# ── Clean run ────────────────────────────────────────────────────────────────

echo "--- clean run ---"

if planner_crosscheck_run "$INIT_ID"; then
  pass "clean artifacts: planner_crosscheck_run returns 0"
else
  fail "clean artifacts: planner_crosscheck_run returns 0" "returned nonzero"
fi

log_file=$(planner_state_log "$INIT_ID")

if grep -q "|Crosscheck|check|start|" "$log_file"; then
  pass "clean run: Crosscheck|check|start written"
else
  fail "clean run: Crosscheck|check|start written" "missing from log"
fi

if grep -q "|Crosscheck|check|done|" "$log_file"; then
  pass "clean run: Crosscheck|check|done written"
else
  fail "clean run: Crosscheck|check|done written" "missing from log"
fi

if grep -q "|META|crosscheck|fail|" "$log_file"; then
  fail "clean run: no META|crosscheck|fail entries" "found one unexpectedly"
else
  pass "clean run: no META|crosscheck|fail entries"
fi

if [ -z "$(planner_position_derive "$INIT_ID")" ] || [ "$(planner_position_derive "$INIT_ID")" != "Crosscheck" ]; then
  pass "clean run: position derive advances past Crosscheck"
else
  fail "clean run: position derive advances past Crosscheck" "still at Crosscheck"
fi

# ── Dirty run (fresh initiative, bad citation) ──────────────────────────────

echo "--- dirty run ---"

INIT_ID2="INIT-1700000001-5678"
STATE_DIR2="${REPOS_ROOT}/.ticket-auto/initiatives/${INIT_ID2}"
mkdir -p "${STATE_DIR2}/artifacts/specs"

planner_state_init "$INIT_ID2" "test idea for dirty crosscheck"
for p in Appraisal Discovery Architecture Specify Review Consensus; do
  planner_state_write "$INIT_ID2" "$p" "step" "done" "ok"
done

cat >"${STATE_DIR2}/artifacts/consensus.md" <<'EOF'
# Consensus
EOF

cat >"${STATE_DIR2}/artifacts/specs/vs-b.md" <<'EOF'
# vs-b

## Description

Cites a file that does not exist under REPOS_ROOT: lib/nonexistent-helper.ts:42.
EOF

if planner_crosscheck_run "$INIT_ID2"; then
  fail "dirty artifacts: planner_crosscheck_run returns 1" "returned 0"
else
  pass "dirty artifacts: planner_crosscheck_run returns 1"
fi

log_file2=$(planner_state_log "$INIT_ID2")

if grep -q "|META|crosscheck|fail|CITATION_UNRESOLVED " "$log_file2"; then
  pass "dirty run: CITATION_UNRESOLVED emitted as META|crosscheck|fail"
else
  fail "dirty run: CITATION_UNRESOLVED emitted as META|crosscheck|fail" "$(grep 'crosscheck' "$log_file2")"
fi

if grep -q "|Crosscheck|check|fail|" "$log_file2"; then
  pass "dirty run: Crosscheck|check|fail written"
else
  fail "dirty run: Crosscheck|check|fail written" "missing"
fi

if [ "$(planner_position_derive "$INIT_ID2")" = "Crosscheck" ]; then
  pass "dirty run: position derive stays at Crosscheck for retry"
else
  fail "dirty run: position derive stays at Crosscheck for retry" "got $(planner_position_derive "$INIT_ID2")"
fi

# Fix the artifact and re-run — resume should succeed and advance.
cat >"${STATE_DIR2}/artifacts/specs/vs-b.md" <<'EOF'
# vs-b

## Description

Citation removed after the operator fixed the spec.
EOF

if planner_crosscheck_run "$INIT_ID2"; then
  pass "resume after fix: planner_crosscheck_run returns 0"
else
  fail "resume after fix: planner_crosscheck_run returns 0" "still nonzero"
fi

if grep -q "|Crosscheck|check|done|" "$log_file2"; then
  pass "resume after fix: Crosscheck|check|done written (fail→done retry allowed)"
else
  fail "resume after fix: Crosscheck|check|done written (fail→done retry allowed)" "missing"
fi

pos=$(planner_position_derive "$INIT_ID2")
if [ "$pos" = "EpicGen" ]; then
  pass "resume after fix: position derive advances to EpicGen"
else
  fail "resume after fix: position derive advances to EpicGen" "got '$pos'"
fi

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
