#!/usr/bin/env bash
# test-planner-replan.sh — Tests for planner re-planning: flag detection,
# feedback ingestion, drift computation, scope restriction (task 8.7).
#
# Covers:
#   1. Unflagged run reads no feedback
#   2. Regeneration does not modify an in-flight ticket
#   3. Systematic overconfidence lowers regenerated confidence
#   4. Absent vs unreadable feedback distinction
#   5. Flag detection across state log, proposal, and ticket specs
#
# Run: bash ticket-planner/lib/tests/test-planner-replan.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/.."
PLUGIN_ROOT="${SCRIPT_DIR}/../.."

# Source the state library (needed by replan for planner_state_write, planner_initiative_dir)
source "${LIB_DIR}/planner-state.sh"

# Source the replan library (the code under test)
source "${LIB_DIR}/planner-replan.sh"

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

REPOS_ROOT="$TMPDIR"

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

echo "=== planner re-planning tests ==="

# ═══════════════════════════════════════════════════════════════════════════════
# 1. Unflagged run reads no feedback
# ═══════════════════════════════════════════════════════════════════════════════

echo "--- 1a: no regenerate flag → flag detection returns false ---"
planner_state_init "INIT-NOFLAG" "test no regenerate"
if ! planner_replan_flag_is_set "INIT-NOFLAG"; then
  pass "initiative without Regenerate flag → flag_is_set returns false"
else
  fail "initiative without Regenerate flag" "flag_is_set returned true"
fi

echo "--- 1b: no feedback directory → status absent ---"
status=$(planner_feedback_status "INIT-NOFLAG")
if echo "$status" | jq -e '.status == "absent"' >/dev/null 2>&1; then
  pass "no feedback dir → status absent"
else
  fail "no feedback dir → status absent" "got $status"
fi

echo "--- 1c: no feedback → read_all returns empty ---"
all=$(planner_feedback_read_all "INIT-NOFLAG")
if [ "$all" = "[]" ]; then
  pass "no feedback → read_all returns empty array"
else
  fail "no feedback → read_all empty" "got $all"
fi

echo "--- 1d: no feedback → drift compute returns zeros ---"
drift=$(planner_drift_compute "[]")
if echo "$drift" | jq -e '.aggregate.avg_drift == 0 and .aggregate.drift_count == 0' >/dev/null 2>&1; then
  pass "empty feedback → drift compute returns zero aggregates"
else
  fail "empty feedback → drift compute zeros" "got $drift"
fi

echo "--- 1e: set flag → detection returns true ---"
planner_replan_flag_set "INIT-NOFLAG"
if planner_replan_flag_is_set "INIT-NOFLAG"; then
  pass "after flag set → flag_is_set returns true"
else
  fail "after flag set → flag_is_set returns true" "returned false"
fi

# ── Flag detection across sources ──────────────────────────────────────────────

echo "--- 1f: flag detected in state log ---"
# Already tested via 1a/1e — state log is primary source
planner_state_init "INIT-FLAG2" "test proposal flag"
# Write a proposal.md with Regenerate: true
init_dir="${TMPDIR}/.ticket-auto/initiatives/INIT-FLAG2"
mkdir -p "${init_dir}/artifacts"
echo "# Proposal" >"${init_dir}/artifacts/proposal.md"
echo "Regenerate: true" >>"${init_dir}/artifacts/proposal.md"

if planner_replan_flag_is_set "INIT-FLAG2"; then
  pass "Regenerate: true in proposal.md → flag detected"
else
  fail "Regenerate: true in proposal.md" "flag not detected"
fi

echo "--- 1g: flag detected in ticket specs ---"
planner_state_init "INIT-FLAG3" "test spec flag"
init_dir="${TMPDIR}/.ticket-auto/initiatives/INIT-FLAG3"
mkdir -p "${init_dir}/artifacts/specs"
echo '{"Regenerate": true, "ticket": "CRE-1"}' >"${init_dir}/artifacts/specs/ticket-1.json"

if planner_replan_flag_is_set "INIT-FLAG3"; then
  pass "Regenerate: true in spec file → flag detected"
else
  fail "Regenerate: true in spec file" "flag not detected"
fi

echo "--- 1h: flag absent in all sources → false ---"
planner_state_init "INIT-FLAG4" "test no flag anywhere"
init_dir="${TMPDIR}/.ticket-auto/initiatives/INIT-FLAG4"
mkdir -p "${init_dir}/artifacts/specs"
echo '{"Regenerate": false}' >"${init_dir}/artifacts/specs/ticket-1.json"

if ! planner_replan_flag_is_set "INIT-FLAG4"; then
  pass "Regenerate: false everywhere → flag not detected"
else
  fail "Regenerate: false everywhere" "flag incorrectly detected"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# 2. Regeneration does not modify in-flight tickets
# ═══════════════════════════════════════════════════════════════════════════════

echo "--- 2a: no intent files → eligible is empty ---"
planner_state_init "INIT-SCOPE" "test scope restriction"
eligible=$(planner_replan_eligible_tickets "INIT-SCOPE")
if [ "$eligible" = "[]" ]; then
  pass "no intent files → eligible tickets empty"
else
  fail "no intent files → eligible empty" "got $eligible"
fi

echo "--- 2b: undispatched backlog tickets are eligible ---"
init_dir="${TMPDIR}/.ticket-auto/initiatives/INIT-SCOPE"
mkdir -p "${init_dir}/.intents"
# Create an intent for a created-but-undispatched ticket
cat >"${init_dir}/.intents/ticket-CRE-10.json" <<'EOF'
{"entity_key":"ticket-CRE-10","entity_type":"ticket","phase":"TicketGen","status":"created","linear_id":"CRE-10"}
EOF

eligible=$(planner_replan_eligible_tickets "INIT-SCOPE")
if echo "$eligible" | jq -e 'length == 1' >/dev/null 2>&1; then
  pass "undispatched created ticket → eligible"
else
  fail "undispatched created ticket → eligible" "got $eligible"
fi

echo "--- 2c: dispatched ticket (in spawn queue) is excluded ---"
# Simulate a ticket in the spawn queue
spawn_dir="${TMPDIR}/.ticket-auto/spawn-queue"
mkdir -p "$spawn_dir"
echo '{"tid":"CRE-11","generation":1}' >"${spawn_dir}/queue.jsonl"

cat >"${init_dir}/.intents/ticket-CRE-11.json" <<'EOF'
{"entity_key":"ticket-CRE-11","entity_type":"ticket","phase":"TicketGen","status":"created","linear_id":"CRE-11"}
EOF

eligible=$(planner_replan_eligible_tickets "INIT-SCOPE")
# CRE-11 should be excluded (in spawn queue), only CRE-10 remains
if echo "$eligible" | jq -e 'length == 1' >/dev/null 2>&1; then
  if echo "$eligible" | jq -e '.[0] == "ticket-CRE-10"' >/dev/null 2>&1; then
    pass "dispatched ticket CRE-11 excluded → only CRE-10 eligible"
  else
    fail "dispatched ticket CRE-11 excluded" "unexpected: $eligible"
  fi
else
  fail "dispatched ticket excluded → 1 remaining" "got count=$(echo "$eligible" | jq length)"
fi

echo "--- 2d: in-progress ticket (has pipeline dir) is excluded ---"
# Simulate a ticket with an active pipeline directory
pipeline_dir="${TMPDIR}/.ticket-auto/pipelines/CRE-12--test-feature"
mkdir -p "$pipeline_dir"

cat >"${init_dir}/.intents/ticket-CRE-12.json" <<'EOF'
{"entity_key":"ticket-CRE-12","entity_type":"ticket","phase":"TicketGen","status":"created","linear_id":"CRE-12"}
EOF

eligible=$(planner_replan_eligible_tickets "INIT-SCOPE")
# CRE-11 (dispatched) and CRE-12 (pipeline) excluded, only CRE-10 remains
if echo "$eligible" | jq -e 'length == 1' >/dev/null 2>&1; then
  if echo "$eligible" | jq -e '.[0] == "ticket-CRE-10"' >/dev/null 2>&1; then
    pass "in-progress ticket CRE-12 excluded → only CRE-10 eligible"
  else
    fail "in-progress ticket CRE-12 excluded" "unexpected: $eligible"
  fi
else
  fail "in-progress ticket excluded → 1 remaining" "got count=$(echo "$eligible" | jq length)"
fi

echo "--- 2e: ticket with 'intent' status (not yet created) is excluded ---"
cat >"${init_dir}/.intents/ticket-CRE-13.json" <<'EOF'
{"entity_key":"ticket-CRE-13","entity_type":"ticket","phase":"TicketGen","status":"intent","linear_id":""}
EOF

eligible=$(planner_replan_eligible_tickets "INIT-SCOPE")
# CRE-13 still at "intent" status, no linear_id — should be excluded
if echo "$eligible" | jq -e 'length == 1' >/dev/null 2>&1; then
  pass "intent-only ticket CRE-13 excluded"
else
  fail "intent-only ticket CRE-13 excluded" "got $eligible"
fi

echo "--- 2f: all tickets in-flight → eligible is empty ---"
planner_state_init "INIT-ALL-FLIGHT" "all in flight"
init_dir="${TMPDIR}/.ticket-auto/initiatives/INIT-ALL-FLIGHT"
mkdir -p "${init_dir}/.intents"

# All tickets are either dispatched or in progress
for i in 20 21 22; do
  cat >"${init_dir}/.intents/ticket-CRE-${i}.json" <<EOF
{"entity_key":"ticket-CRE-${i}","entity_type":"ticket","phase":"TicketGen","status":"created","linear_id":"CRE-${i}"}
EOF
done
# CRE-20: in pipeline (in progress)
mkdir -p "${TMPDIR}/.ticket-auto/pipelines/CRE-20--feature-a"
# CRE-21: in spawn queue (dispatched)
echo '{"tid":"CRE-21","generation":1}' >>"${spawn_dir}/queue.jsonl"
# CRE-22: also in spawn queue
echo '{"tid":"CRE-22","generation":1}' >>"${spawn_dir}/queue.jsonl"

eligible=$(planner_replan_eligible_tickets "INIT-ALL-FLIGHT")
if [ "$eligible" = "[]" ]; then
  pass "all tickets in-flight → eligible is empty"
else
  fail "all tickets in-flight → eligible empty" "got $eligible"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# 3. Systematic overconfidence lowers regenerated confidence
# ═══════════════════════════════════════════════════════════════════════════════

echo "--- 3a: systematic overconfidence detected ---"
# Simulate feedback where planner consistently over-estimated by >0.15
feedback_json='[
  {"ticket_id":"CRE-1","confidence_predicted":0.90,"confidence_actual":0.40,"outcome":"rough","corrections_count":3,"decision_drift":"significant"},
  {"ticket_id":"CRE-2","confidence_predicted":0.85,"confidence_actual":0.35,"outcome":"rough","corrections_count":2,"decision_drift":"moderate"},
  {"ticket_id":"CRE-3","confidence_predicted":0.92,"confidence_actual":0.45,"outcome":"rough","corrections_count":4,"decision_drift":"significant"},
  {"ticket_id":"CRE-4","confidence_predicted":0.88,"confidence_actual":0.50,"outcome":"smooth","corrections_count":1,"decision_drift":"minor"}
]'

drift=$(planner_drift_compute "$feedback_json")

# Check systematic_overconfidence flag
if echo "$drift" | jq -e '.aggregate.systematic_overconfidence == true' >/dev/null 2>&1; then
  pass "consistent over-prediction → systematic_overconfidence = true"
else
  fail "consistent over-prediction → systematic_overconfidence" "got $(echo "$drift" | jq '.aggregate')"
fi

echo "--- 3b: drift values correct per ticket ---"
# CRE-1: 0.40 - 0.90 = -0.50
drift1=$(echo "$drift" | jq -r '.per_ticket[] | select(.ticket_id=="CRE-1") | .drift')
if [ "$drift1" = "-0.5" ] || [ "$drift1" = "-0.50" ]; then
  pass "CRE-1 drift = -0.50 (actual 0.40 - predicted 0.90)"
else
  fail "CRE-1 drift = -0.50" "got $drift1"
fi

echo "--- 3c: avg_drift reflects consistent overconfidence ---"
avg=$(echo "$drift" | jq -r '.aggregate.avg_drift')
# (-0.50 + -0.50 + -0.47 + -0.38) / 4 ≈ -0.4625
avg_abs=$(echo "$avg" | awk '{if($1<0) print -$1; else print $1}')
if echo "$avg_abs" | awk '{exit ($1 > 0.15 ? 0 : 1)}'; then
  pass "avg_drift magnitude > 0.15 ($avg) → systematic_overconfidence triggers"
else
  fail "avg_drift magnitude > 0.15" "got avg=$avg"
fi

echo "--- 3d: balanced outcomes → no systematic overconfidence ---"
balanced_json='[
  {"ticket_id":"CRE-10","confidence_predicted":0.70,"confidence_actual":0.65,"outcome":"smooth","corrections_count":0,"decision_drift":"none"},
  {"ticket_id":"CRE-11","confidence_predicted":0.60,"confidence_actual":0.70,"outcome":"smooth","corrections_count":0,"decision_drift":"none"},
  {"ticket_id":"CRE-12","confidence_predicted":0.80,"confidence_actual":0.75,"outcome":"smooth","corrections_count":1,"decision_drift":"minor"}
]'

drift=$(planner_drift_compute "$balanced_json")
if echo "$drift" | jq -e '.aggregate.systematic_overconfidence == false' >/dev/null 2>&1; then
  pass "balanced predictions → systematic_overconfidence = false"
else
  fail "balanced predictions → systematic_overconfidence false" "got $(echo "$drift" | jq '.aggregate')"
fi

echo "--- 3e: drift count matches input ---"
count=$(echo "$drift" | jq -r '.aggregate.drift_count')
if [ "$count" = "3" ]; then
  pass "drift_count = 3 matches input"
else
  fail "drift_count = 3" "got $count"
fi

echo "--- 3f: per-ticket drift direction is correct (negative = over-predicted) ---"
# Single ticket: predicted 0.9, actual 0.5 → drift = -0.4 (planner was too confident)
single='[{"ticket_id":"CRE-99","confidence_predicted":0.90,"confidence_actual":0.50,"outcome":"rough","corrections_count":2,"decision_drift":"significant"}]'
drift=$(planner_drift_compute "$single")
drift_val=$(echo "$drift" | jq -r '.per_ticket[0].drift')
if echo "$drift_val" | awk '{exit ($1 < 0 ? 0 : 1)}'; then
  pass "over-prediction → negative drift ($drift_val)"
else
  fail "over-prediction → negative drift" "got $drift_val"
fi

echo "--- 3g: null confidence values handled gracefully ---"
null_json='[
  {"ticket_id":"CRE-50","outcome":"rough"},
  {"ticket_id":"CRE-51","confidence_predicted":0.80,"confidence_actual":0.70,"outcome":"smooth"}
]'
drift=$(planner_drift_compute "$null_json")
# Only CRE-51 should be in per_ticket (has confidence_predicted)
per_ticket_count=$(echo "$drift" | jq '.per_ticket | length')
if [ "$per_ticket_count" = "1" ]; then
  pass "tickets without confidence_predicted filtered out (count=$per_ticket_count)"
else
  fail "tickets without confidence_predicted filtered" "got count=$per_ticket_count"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# 4. Absent vs unreadable feedback distinction
# ═══════════════════════════════════════════════════════════════════════════════

echo "--- 4a: empty feedback directory → status absent ---"
planner_state_init "INIT-ABSENT" "test absent feedback"
init_dir="${TMPDIR}/.ticket-auto/initiatives/INIT-ABSENT"
mkdir -p "${init_dir}/feedback"

status=$(planner_feedback_status "INIT-ABSENT")
if echo "$status" | jq -e '.status == "absent"' >/dev/null 2>&1; then
  pass "empty feedback dir → status absent"
else
  fail "empty feedback dir → status absent" "got $status"
fi

echo "--- 4b: valid feedback files → status present ---"
echo '{"ticket_id":"CRE-1","confidence_predicted":0.8,"confidence_actual":0.6}' \
  >"${init_dir}/feedback/2026-07-01.json"
echo '{"ticket_id":"CRE-2","confidence_predicted":0.7,"confidence_actual":0.65}' \
  >"${init_dir}/feedback/2026-07-05.json"

status=$(planner_feedback_status "INIT-ABSENT")
if echo "$status" | jq -e '.status == "present"' >/dev/null 2>&1; then
  count=$(echo "$status" | jq -r '.count')
  if [ "$count" = "2" ]; then
    pass "2 valid feedback files → status present, count=2"
  else
    fail "2 valid feedback files → count=2" "got count=$count"
  fi
else
  fail "valid feedback files → status present" "got $status"
fi

echo "--- 4c: unreadable feedback files distinguished ---"
# Add a corrupted file
echo 'not valid json {{{' >"${init_dir}/feedback/2026-07-10-corrupt.json"

status=$(planner_feedback_status "INIT-ABSENT")
if echo "$status" | jq -e '.status == "unreadable"' >/dev/null 2>&1; then
  unreadable_count=$(echo "$status" | jq '.unreadable | length')
  if [ "$unreadable_count" -ge 1 ]; then
    pass "corrupt file detected → status unreadable with unreadable count $unreadable_count"
  else
    fail "corrupt file detected → unreadable list populated" "got $status"
  fi
else
  fail "corrupt file → status unreadable" "got $status"
fi

echo "--- 4d: read_all skips corrupt files, returns only valid JSON ---"
all=$(planner_feedback_read_all "INIT-ABSENT" 2>/dev/null)
# Should only include the 2 valid files, skipping the corrupt one
# The merge wraps each valid file; the output must itself be parseable JSON
if echo "$all" | jq -e '. ' >/dev/null 2>&1; then
  obj_count=$(echo "$all" | jq 'flatten | length' 2>/dev/null)
  if [ "$obj_count" = "2" ]; then
    pass "read_all returns valid JSON with 2 entries (corrupt skipped)"
  else
    fail "read_all returns 2 valid entries" "got count=$obj_count, json=$all"
  fi
else
  fail "read_all returns valid JSON (corrupt skipped)" "unparseable output: $all"
fi

echo "--- 4e: non-existent directory → status absent (not error) ---"
status=$(planner_feedback_status "INIT-NEVEREXISTED")
if echo "$status" | jq -e '.status == "absent"' >/dev/null 2>&1; then
  pass "non-existent feedback dir → status absent"
else
  fail "non-existent feedback dir → status absent" "got $status"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# 5. Re-plan state log recording
# ═══════════════════════════════════════════════════════════════════════════════

echo "--- 5a: replan_record writes to state log ---"
planner_state_init "INIT-REPLOG" "test replan recording"
planner_replan_record "INIT-REPLOG" "manual" "3" "2" "1" "0" \
  '{"avg_drift":0.3,"systematic_overconfidence":true}'

log_content=$(planner_state_read "INIT-REPLOG")
if echo "$log_content" | grep -q '|META|replan-start|start|'; then
  pass "replan_record writes replan-start to state log"
else
  fail "replan_record writes replan-start" "not found in log"
fi

if echo "$log_content" | grep -q '|META|replan-drift|start|'; then
  pass "replan_record writes replan-drift to state log"
else
  fail "replan_record writes replan-drift" "not found in log"
fi

if echo "$log_content" | grep -q '|META|replan-result|start|'; then
  pass "replan_record writes replan-result to state log"
else
  fail "replan_record writes replan-result" "not found in log"
fi

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
