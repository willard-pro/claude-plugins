#!/usr/bin/env bash
# test-planner-project-gate.sh — Tests for Epic Gen's Linear-project gate (#256).
#
# An unset --project used to be indistinguishable from a deliberate one: no
# derivation, no confirmation, no log entry. Four initiatives and 24 child tickets
# went to Linear with project: null before a human noticed. These tests pin the
# three outcomes — stop on a single plausible candidate, proceed loudly on zero or
# several, proceed silently on an explicit opt-out — and that the gate never picks
# a project by itself.
#
# No network: planner_linear_list_team_projects is stubbed after sourcing.
#
# Run: bash ticket-planner/lib/tests/test-planner-project-gate.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/.."

source "${LIB_DIR}/planner-state.sh"
source "${LIB_DIR}/planner-project-gate.sh"

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT
REPOS_ROOT="$TMPDIR"

TEAM_ID="c33944ff-9aee-408e-b98e-00dbaa98ae02"

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

# The stub stands in for the one function that would reach the network. Defined
# after the source above, so it replaces the real implementation.
PROJECTS_JSON='[{"id":"p1","name":"Ledgerly"},{"id":"p2","name":"Atlas"}]'
planner_linear_list_team_projects() { echo "$PROJECTS_JSON"; }

# Seed an initiative with the artifacts the gate matches project names against.
seed() {
  local id="$1" affected="$2"
  planner_state_init "$id" "a billing idea" >/dev/null
  cat >"$(planner_initiative_dir "$id")/artifacts/appraisal.md" <<APPRAISAL
# Appraisal

## Summary
Some work.

## Affected Services
- ${affected} — where the change lands

## Type
feature
APPRAISAL
}

log_of() { cat "$(planner_state_log "$1")"; }

echo "=== planner project gate tests ==="

# ── Test 1: exactly one plausible candidate stops the phase ────────────────────

echo "--- Test 1: single candidate ---"

seed "INIT-ONE" "ledgerly-api"

if planner_project_gate_check "INIT-ONE" "$TEAM_ID" 2>/dev/null; then
  fail "a single matching project stops Epic Gen" "the gate allowed the run"
else
  pass "a single matching project stops Epic Gen"
fi

if log_of INIT-ONE | grep -q '|EpicGen|project|fail|.*Ledgerly'; then
  pass "the stop is recorded in the state log, naming the candidate"
else
  fail "stop names the candidate in the log" "$(log_of INIT-ONE | grep '|EpicGen|' || echo 'no EpicGen entry')"
fi

err=$(planner_project_gate_check "INIT-ONE" "$TEAM_ID" 2>&1 || true)
if echo "$err" | grep -q -- "--project 'Ledgerly'" && echo "$err" | grep -q -- "--no-project"; then
  pass "the refusal names both the confirm and the opt-out command"
else
  fail "refusal names both commands" "$err"
fi

# The whole point: a candidate is offered, never applied. Nothing may write the
# project config on the operator's behalf.
if [ -z "$(planner_config_get INIT-ONE linear-project)" ]; then
  pass "the candidate is never auto-applied as configuration"
else
  fail "candidate is not auto-applied" "linear-project was set to '$(planner_config_get INIT-ONE linear-project)'"
fi

# ── Test 2: zero or several candidates proceed, but visibly ────────────────────

echo "--- Test 2: zero or several candidates ---"

seed "INIT-NONE" "billing-service"

if planner_project_gate_check "INIT-NONE" "$TEAM_ID" 2>/dev/null; then
  pass "no matching project proceeds with no project"
else
  fail "no match proceeds" "the gate stopped the run"
fi

if log_of INIT-NONE | grep -q '|EpicGen|project|skip|no project configured — 2 project(s) on team, 0 matched'; then
  pass "the omission is recorded as a skip entry naming the counts"
else
  fail "skip entry naming counts" "$(log_of INIT-NONE | grep '|EpicGen|' || echo 'no EpicGen entry')"
fi

if log_of INIT-NONE | grep -q 'pass --project or --no-project'; then
  pass "the skip entry says how to silence it"
else
  fail "skip entry names the flags" "$(log_of INIT-NONE | grep '|EpicGen|' || echo 'none')"
fi

seed "INIT-MANY" "ledgerly-api and atlas-gateway"

if planner_project_gate_check "INIT-MANY" "$TEAM_ID" 2>/dev/null; then
  pass "several matching projects proceed rather than guessing between them"
else
  fail "several matches proceed" "the gate stopped the run"
fi

if log_of INIT-MANY | grep -q '|EpicGen|project|skip|no project configured — 2 project(s) on team, 2 matched'; then
  pass "an ambiguous match is recorded with its candidate count"
else
  fail "ambiguous match recorded" "$(log_of INIT-MANY | grep '|EpicGen|' || echo 'no EpicGen entry')"
fi

# ── Test 3: the explicit opt-out is silent ─────────────────────────────────────

echo "--- Test 3: --no-project ---"

seed "INIT-OPTOUT" "ledgerly-api"
planner_config_set INIT-OPTOUT "no-project" "true"

if planner_project_gate_check "INIT-OPTOUT" "$TEAM_ID" 2>/dev/null; then
  pass "--no-project proceeds even with an exact-name candidate present"
else
  fail "--no-project proceeds" "the gate stopped the run"
fi

if ! log_of INIT-OPTOUT | grep -q '|EpicGen|project|'; then
  pass "--no-project writes no project entry at all — the decision is already made"
else
  fail "--no-project is silent" "$(log_of INIT-OPTOUT | grep '|EpicGen|')"
fi

# ── Test 4: a configured project bypasses the gate entirely ────────────────────

echo "--- Test 4: --project set ---"

seed "INIT-SET" "ledgerly-api"
planner_config_set INIT-SET "linear-project" "Atlas"

if planner_project_gate_check "INIT-SET" "$TEAM_ID" 2>/dev/null; then
  pass "a configured project passes the gate untouched"
else
  fail "configured project passes" "the gate stopped the run"
fi

if ! log_of INIT-SET | grep -q '|EpicGen|project|'; then
  pass "a configured project produces no gate entry"
else
  fail "configured project is silent" "$(log_of INIT-SET | grep '|EpicGen|')"
fi

# ── Test 5: the match text is the idea and Affected Services, not everything ───
#
# Matching whole artifacts would turn any passing mention of a project name — a
# prior-art reference, a risk note — into a stop.

echo "--- Test 5: match text scope ---"

seed "INIT-SCOPE" "billing-service"
cat >"$(planner_initiative_dir INIT-SCOPE)/artifacts/proposal.md" <<'PROPOSAL'
# Proposal

## Summary
Unrelated prose that mentions Ledgerly only as prior art.

- **Affected Services** — billing-service, invoicing
- **Strategy** — Balanced
PROPOSAL

text=$(planner_project_match_text INIT-SCOPE)
if echo "$text" | grep -q "billing-service" && ! echo "$text" | grep -q "prior art"; then
  pass "match text carries Affected Services and excludes unrelated prose"
else
  fail "match text scope" "$text"
fi

if planner_project_gate_check "INIT-SCOPE" "$TEAM_ID" 2>/dev/null; then
  pass "a project named only in unrelated prose does not stop the run"
else
  fail "unrelated mention does not stop" "the gate stopped the run"
fi

# ── Test 6: an unlistable project set never blocks creation ────────────────────
#
# The gate is a safety net, not a dependency. A failed listing degrades to the
# old behaviour — with a log entry, which is the part that was missing.

echo "--- Test 6: listing failure ---"

seed "INIT-APIFAIL" "ledgerly-api"
planner_linear_list_team_projects() { return 1; }

if planner_project_gate_check "INIT-APIFAIL" "$TEAM_ID" 2>/dev/null; then
  pass "a failed project listing proceeds rather than blocking the epic"
else
  fail "listing failure proceeds" "the gate stopped the run"
fi

if log_of INIT-APIFAIL | grep -q '|EpicGen|project|skip|.*could not be listed'; then
  pass "the failed listing is recorded"
else
  fail "failed listing recorded" "$(log_of INIT-APIFAIL | grep '|EpicGen|' || echo 'none')"
fi

planner_linear_list_team_projects() { echo "$PROJECTS_JSON"; }

echo ""
echo "=== planner project gate: ${PASS} passed, ${FAIL} failed ==="
[ "$FAIL" -eq 0 ]
