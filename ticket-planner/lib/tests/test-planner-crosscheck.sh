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

summary=$(planner_crosscheck_findings_summary "$INIT_ID")
if [ -z "$summary" ]; then
  pass "clean run: findings summary is empty"
else
  fail "clean run: findings summary is empty" "got: $summary"
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

summary2=$(planner_crosscheck_findings_summary "$INIT_ID2")
case "$summary2" in
*"blocking CITATION_UNRESOLVED"*) pass "dirty run: findings summary lists CITATION_UNRESOLVED as blocking" ;;
*) fail "dirty run: findings summary lists CITATION_UNRESOLVED as blocking" "got: $summary2" ;;
esac
case "$summary2" in
*"TOTAL: 1 blocking, 0 warn, 0 accepted"*) pass "dirty run: findings summary TOTAL line is correct" ;;
*) fail "dirty run: findings summary TOTAL line is correct" "got: $summary2" ;;
esac

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

# Findings summary is scoped to the latest attempt only — the earlier
# CITATION_UNRESOLVED finding must not still report as outstanding once the
# artifact was fixed and Crosscheck re-ran clean (#176 AC5).
summary2_after_fix=$(planner_crosscheck_findings_summary "$INIT_ID2")
if [ -z "$summary2_after_fix" ]; then
  pass "resume after fix: findings summary is empty (scoped to latest attempt)"
else
  fail "resume after fix: findings summary is empty (scoped to latest attempt)" "got: $summary2_after_fix"
fi

# ── --accept override (#222) ────────────────────────────────────────────────

echo "--- accept override ---"

INIT_ID3="INIT-1700000002-9012"
STATE_DIR3="${REPOS_ROOT}/.ticket-auto/initiatives/${INIT_ID3}"
mkdir -p "${STATE_DIR3}/artifacts/specs"

planner_state_init "$INIT_ID3" "test idea for accept override"
for p in Appraisal Discovery Architecture Specify Review Consensus; do
  planner_state_write "$INIT_ID3" "$p" "step" "done" "ok"
done

cat >"${STATE_DIR3}/artifacts/consensus.md" <<'EOF'
# Consensus
EOF

cat >"${STATE_DIR3}/artifacts/specs/vs-c.md" <<'EOF'
# vs-c

## Description

Cites a file that does not exist under REPOS_ROOT: lib/still-missing.ts:1.
EOF

log_file3=$(planner_state_log "$INIT_ID3")

# Unaccepted: the finding blocks, same as the dirty run above.
if planner_crosscheck_run "$INIT_ID3"; then
  fail "accept: unaccepted CITATION_UNRESOLVED still blocks" "returned 0"
else
  pass "accept: unaccepted CITATION_UNRESOLVED still blocks"
fi

# Operator accepts the code — this is what `resume <ID> --accept CODE:"reason"`
# persists in SKILL.md step 2b, before the dispatch loop reaches Crosscheck again.
planner_crosscheck_accept_set "$INIT_ID3" "CITATION_UNRESOLVED" "documented in consensus.md, not a real citation"

if grep -q '|META|crosscheck|accepted|CITATION_UNRESOLVED documented in consensus.md, not a real citation' "$log_file3"; then
  pass "accept: planner_crosscheck_accept_set writes META|crosscheck|accepted"
else
  fail "accept: planner_crosscheck_accept_set writes META|crosscheck|accepted" "$(grep 'crosscheck' "$log_file3")"
fi

# Re-run: the same finding recurs (artifact unchanged) but is now non-blocking.
if planner_crosscheck_run "$INIT_ID3"; then
  pass "accept: accepted CITATION_UNRESOLVED is non-blocking on the next run"
else
  fail "accept: accepted CITATION_UNRESOLVED is non-blocking on the next run" "returned nonzero"
fi

if [ "$(planner_position_derive "$INIT_ID3")" = "EpicGen" ]; then
  pass "accept: position derive advances past Crosscheck once accepted"
else
  fail "accept: position derive advances past Crosscheck once accepted" "got $(planner_position_derive "$INIT_ID3")"
fi

accept_summary=$(planner_crosscheck_findings_summary "$INIT_ID3")
case "$accept_summary" in
*"accepted CITATION_UNRESOLVED"*) pass "accept: findings summary lists CITATION_UNRESOLVED as accepted" ;;
*) fail "accept: findings summary lists CITATION_UNRESOLVED as accepted" "got: $accept_summary" ;;
esac
case "$accept_summary" in
*"TOTAL: 0 blocking, 0 warn, 1 accepted"*) pass "accept: findings summary TOTAL line counts the accepted finding" ;;
*) fail "accept: findings summary TOTAL line counts the accepted finding" "got: $accept_summary" ;;
esac

# ── Grouped findings report (#233) ──────────────────────────────────────────

echo "--- findings report ---"

# Clean initiative: the report is empty, same as the summary.
if [ -z "$(planner_crosscheck_findings_report "$INIT_ID")" ]; then
  pass "report: clean run produces no output"
else
  fail "report: clean run produces no output" "got: $(planner_crosscheck_findings_report "$INIT_ID")"
fi

# Fresh initiative with one hand-written finding of every message shape the
# check families emit — the report is pure presentation over the state log, so
# writing the log directly is the honest way to cover shapes the fixtures above
# cannot all produce.
INIT_ID4="INIT-1700000003-3456"
STATE_DIR4="${REPOS_ROOT}/.ticket-auto/initiatives/${INIT_ID4}"
mkdir -p "${STATE_DIR4}/artifacts/specs"

planner_state_init "$INIT_ID4" "test idea for findings report"
planner_state_write "$INIT_ID4" "Crosscheck" "check" "start" "running checks"

ART4="${STATE_DIR4}/artifacts"
planner_state_write "$INIT_ID4" "META" "crosscheck" "fail" \
  "CITATION_UNRESOLVED ${ART4}/specs/vs-1.md:12 → lib/nope.ts:42 (no file under REPOS_ROOT matches 'lib/nope.ts')"
planner_state_write "$INIT_ID4" "META" "crosscheck" "fail" \
  "CITATION_UNRESOLVED ${ART4}/specs/vs-1.md:31 → lib/gone.ts:9 (no file under REPOS_ROOT matches 'lib/gone.ts')"
planner_state_write "$INIT_ID4" "META" "crosscheck" "fail" \
  "PRECEDENT_NOT_FOUND ${ART4}/specs/vs-1.md:44 → identifier 'fooBar' has zero matches under REPOS_ROOT"
planner_state_write "$INIT_ID4" "META" "crosscheck" "fail" \
  "DANGLING_BLOCKED_BY vs-2.md references blocked-by:vs-9 which does not resolve to any sibling spec in this initiative"
planner_state_write "$INIT_ID4" "META" "crosscheck" "fail" \
  'CONTRACT_MISMATCH `Invoice` borrowed by INIT-x/vs-3.md from INIT-y/vs-7.md — field sets differ | INIT-x: "a" | INIT-y: "b"'
planner_state_write "$INIT_ID4" "META" "crosscheck" "fail" \
  "SIGNALS_UNIFORM 3 specs share byte-identical Signals JSON: vs-1.md vs-2.md vs-3.md — {}"
planner_state_write "$INIT_ID4" "META" "crosscheck" "warn" \
  "info DISCOVERY_GAP_UNRESOLVED ${ART4}/discovery.md:8 → \"unknown auth model\" not recorded in proposal.md Out of Scope"

report=$(planner_crosscheck_findings_report "$INIT_ID4")

case "$report" in
*"specs/vs-1.md"*) pass "report: spec path is shown relative to artifacts/" ;;
*) fail "report: spec path is shown relative to artifacts/" "got: $report" ;;
esac

case "$report" in
*"$ART4"*) fail "report: absolute artifact paths are not printed" "got: $report" ;;
*) pass "report: absolute artifact paths are not printed" ;;
esac

case "$report" in
*"CITATION_UNRESOLVED — 2 blocking"*) pass "report: same-file findings of one code are grouped with a count" ;;
*) fail "report: same-file findings of one code are grouped with a count" "got: $report" ;;
esac

case "$report" in
*"L12  lib/nope.ts:42"*) pass "report: offending token is quoted inline against its spec line" ;;
*) fail "report: offending token is quoted inline against its spec line" "got: $report" ;;
esac

case "$report" in
*"fix: path does not resolve under REPOS_ROOT"*) pass "report: canned fix hint is rendered per code" ;;
*) fail "report: canned fix hint is rendered per code" "got: $report" ;;
esac

# A file named mid-message (no leading `file:line` locus) still groups.
case "$report" in
*"vs-2.md"*"DANGLING_BLOCKED_BY"*) pass "report: mid-message .md filename groups the finding" ;;
*) fail "report: mid-message .md filename groups the finding" "got: $report" ;;
esac

# CONTRACT_MISMATCH messages contain " | " — the detail must survive whole.
case "$report" in
*'INIT-y: "b"'*) pass "report: pipes inside a finding message are not truncated" ;;
*) fail "report: pipes inside a finding message are not truncated" "got: $report" ;;
esac

case "$report" in
*"(cross-file)"*"SIGNALS_UNIFORM"*) pass "report: set-wide codes group under (cross-file)" ;;
*) fail "report: set-wide codes group under (cross-file)" "got: $report" ;;
esac

# A finding with a file but no line number must not render an empty "L".
if printf '%s\n' "$report" | grep -q '^    vs-2\.md references'; then
  pass "report: file-only finding renders without an L prefix"
else
  fail "report: file-only finding renders without an L prefix" "got: $report"
fi

case "$report" in
*"DISCOVERY_GAP_UNRESOLVED — 1 warn"*) pass "report: warn findings are labelled warn, not blocking" ;;
*) fail "report: warn findings are labelled warn, not blocking" "got: $report" ;;
esac

case "$report" in
*"TOTAL: 6 blocking, 1 warn, 0 accepted across 5 artifact group(s), 6 code(s)"*)
  pass "report: TOTAL line counts findings, groups and codes"
  ;;
*) fail "report: TOTAL line counts findings, groups and codes" "got: $report" ;;
esac

# Scoping: a second attempt supersedes the first, exactly like the summary.
planner_state_write "$INIT_ID4" "Crosscheck" "check" "fail" "6 blocking finding(s), 1 warn, 0 accepted"
planner_state_write "$INIT_ID4" "Crosscheck" "check" "start" "re-running after fixes"
planner_state_write "$INIT_ID4" "META" "crosscheck" "fail" \
  "CONTRACT_UNDEFINED ${ART4}/specs/vs-5.md \`Ledger\` declares new fields without canonical names: \"totals\""

report2=$(planner_crosscheck_findings_report "$INIT_ID4")
case "$report2" in
*"CITATION_UNRESOLVED"*) fail "report: scoped to the most recent attempt" "stale finding still listed: $report2" ;;
*"specs/vs-5.md"*) pass "report: scoped to the most recent attempt" ;;
*) fail "report: scoped to the most recent attempt" "got: $report2" ;;
esac

# An unknown code still renders — with the fallback hint, not a crash.
planner_state_write "$INIT_ID4" "META" "crosscheck" "fail" "SOME_NEW_CODE vs-6.md has a problem"
case "$(planner_crosscheck_findings_report "$INIT_ID4")" in
*"SOME_NEW_CODE"*"no canned hint for this code"*) pass "report: unknown code falls back to a generic hint" ;;
*) fail "report: unknown code falls back to a generic hint" "got: $(planner_crosscheck_findings_report "$INIT_ID4")" ;;
esac

# Long details are truncated rather than swamping the report.
PLANNER_CROSSCHECK_REPORT_WIDTH=40
long_report=$(planner_crosscheck_findings_report "$INIT_ID4")
unset PLANNER_CROSSCHECK_REPORT_WIDTH
case "$long_report" in
*"..."*) pass "report: PLANNER_CROSSCHECK_REPORT_WIDTH truncates long detail lines" ;;
*) fail "report: PLANNER_CROSSCHECK_REPORT_WIDTH truncates long detail lines" "got: $long_report" ;;
esac

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
