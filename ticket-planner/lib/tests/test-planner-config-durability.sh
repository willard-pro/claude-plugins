#!/usr/bin/env bash
# test-planner-config-durability.sh — Proves invocation config survives the process
# boundary the dispatch loop puts between every pair of phases.
#
# This is the suite that #144 needed and did not have. The stop-condition tests set
# PLANNER_UNTIL and read it back in the same shell, so they passed 25/25 while
# --dry-run did nothing at all in production: an Agent tool call sits between the
# shell that parses arguments and the shell that checks the stop condition, and an
# `export` does not cross it.
#
# Every assertion below therefore writes in one `bash -c` and reads in another. A
# helper that reintroduces an environment read will fail here and nowhere else.
#
# Run: bash ticket-planner/lib/tests/test-planner-config-durability.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT
export REPOS_ROOT="$TMPDIR"

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

# Run a snippet in a *fresh process* with the libraries sourced and nothing else
# inherited — the closest faithful model of one dispatch-loop iteration.
in_new_process() {
  env -i \
    HOME="$HOME" PATH="$PATH" REPOS_ROOT="$REPOS_ROOT" LIB_DIR="$LIB_DIR" \
    bash -c '
      source "${LIB_DIR}/planner-state.sh"
      source "${LIB_DIR}/planner-router.sh"
      source "${LIB_DIR}/planner-phase-prompts.sh"
      '"$1"'
    '
}

echo "=== planner config durability (cross-process) tests ==="

# ── Test 1: the stop point survives the boundary ───────────────────────────────
#
# The exact repro from #144: export in one call, read in the next.

echo "--- Test 1: the stop point crosses the boundary ---"

in_new_process 'planner_state_init INIT-DURABLE "an idea" >/dev/null
                planner_stop_after_set INIT-DURABLE Consensus'

got=$(in_new_process 'planner_stop_phase INIT-DURABLE')
if [ "$got" = "Consensus" ]; then
  pass "a stop point written in one process is read in the next"
else
  fail "stop point crosses the boundary" "got '${got}'"
fi

# The counter-example: the old mechanism, to show the boundary is real and that
# this suite would have caught the regression.
got=$(
  env -i HOME="$HOME" PATH="$PATH" REPOS_ROOT="$REPOS_ROOT" LIB_DIR="$LIB_DIR" \
    bash -c 'export PLANNER_UNTIL=Consensus' 2>/dev/null
  in_new_process 'echo "${PLANNER_UNTIL:-<UNSET>}"'
)
if [ "$got" = "<UNSET>" ]; then
  pass "an exported variable does NOT cross the boundary (the #144 mechanism)"
else
  fail "the boundary is real" "PLANNER_UNTIL read back as '${got}'"
fi

# ── Test 2: creation is refused across the boundary ────────────────────────────

echo "--- Test 2: the create gate holds across the boundary ---"

if in_new_process 'planner_create_gate_check INIT-DURABLE EpicGen' 2>/dev/null; then
  fail "EpicGen is refused in a fresh process" "allowed"
else
  pass "EpicGen is refused in a process that never saw the flags"
fi

if in_new_process 'planner_should_stop_after INIT-DURABLE Consensus'; then
  pass "the loop stops after Consensus in a fresh process"
else
  fail "stop decision crosses the boundary" "did not stop"
fi

# ── Test 3: authorization survives a crash between --create and EpicGen ────────
#
# The issue's own verification step: authorize, lose the process, resume with no
# flag at all, and creation must still be authorized — because it is on disk.

echo "--- Test 3: authorization survives a crash ---"

in_new_process 'planner_authorize_create INIT-DURABLE
                planner_stop_after_set INIT-DURABLE ""'

if in_new_process 'planner_create_authorized INIT-DURABLE'; then
  pass "authorization written in one process is visible in another"
else
  fail "authorization crosses the boundary" "not authorized"
fi

if in_new_process 'planner_create_gate_check INIT-DURABLE EpicGen' 2>/dev/null; then
  pass "a resume with no flags still proceeds once authorized"
else
  fail "authorized resume proceeds" "refused"
fi

got=$(in_new_process 'planner_stop_phase INIT-DURABLE')
if [ -z "$got" ]; then
  pass "--create lifts the stop point across the boundary"
else
  fail "--create lifts the stop point" "got '${got}'"
fi

# ── Test 4: project and milestone reach the prompt generator ───────────────────
#
# EpicGen's prompt is built six phases and at least six process boundaries after
# --project was parsed. The value has to come off disk or it is not there at all.

echo "--- Test 4: project/milestone reach prompt generation ---"

in_new_process 'planner_state_init INIT-PROJ "an idea" >/dev/null
                planner_authorize_create INIT-PROJ
                planner_config_set INIT-PROJ linear-team "LED"
                planner_config_set INIT-PROJ linear-project "Ledgerly M1"
                planner_config_set INIT-PROJ linear-milestone "Vertical Slice 1"
                planner_config_set INIT-PROJ branch-override "shared"'

prompt=$(in_new_process 'planner_prompt_epicgen INIT-PROJ "an idea" /tmp/state')

if echo "$prompt" | grep -qF 'PROJECT_REF="Ledgerly M1"'; then
  pass "the project ref is interpolated into the EpicGen prompt as a literal"
else
  fail "project ref reaches EpicGen" "$(echo "$prompt" | grep -m1 'PROJECT_REF=' || echo 'absent')"
fi

if echo "$prompt" | grep -qF 'MILESTONE_REF="Vertical Slice 1"'; then
  pass "the milestone ref is interpolated into the EpicGen prompt as a literal"
else
  fail "milestone ref reaches EpicGen" "$(echo "$prompt" | grep -m1 'MILESTONE_REF=' || echo 'absent')"
fi

if echo "$prompt" | grep -qF 'BRANCH_OVERRIDE="shared"'; then
  pass "the branch override is interpolated into the EpicGen prompt as a literal"
else
  fail "branch override reaches EpicGen" "$(echo "$prompt" | grep -m1 'BRANCH_OVERRIDE=' || echo 'absent')"
fi

if echo "$prompt" | grep -qF 'TEAM_REF="LED"'; then
  pass "the team ref is interpolated into the EpicGen prompt as a literal"
else
  fail "team ref reaches EpicGen" "$(echo "$prompt" | grep -m1 'TEAM_REF=' || echo 'absent')"
fi

# The project gate is the reason an unset --project is no longer silent (#256).
# It has to be wired into the prompt, and wired in *before* the create call —
# after it, the epic is already filed with no project and the gate is theatre.
if echo "$prompt" | grep -qF 'planner_project_gate_check "INIT-PROJ" "$TEAM_ID"'; then
  pass "EpicGen calls the project gate"
else
  fail "EpicGen calls the project gate" "no planner_project_gate_check call in the prompt"
fi

if echo "$prompt" | grep -qF 'source "${CLAUDE_PLUGIN_ROOT}/lib/planner-project-gate.sh"'; then
  pass "EpicGen sources the gate it calls"
else
  fail "EpicGen sources the gate" "no source line for planner-project-gate.sh"
fi

gate_line=$(echo "$prompt" | grep -n 'planner_project_gate_check' | head -1 | cut -d: -f1)
create_line=$(echo "$prompt" | grep -n 'EPIC_RESPONSE=$(planner_linear_create_issue' | head -1 | cut -d: -f1)
if [ -n "$gate_line" ] && [ -n "$create_line" ] && [ "$gate_line" -lt "$create_line" ]; then
  pass "the gate runs before the epic is created"
else
  fail "gate precedes creation" "gate at line '${gate_line}', create at line '${create_line}'"
fi

# ── Test 5: TicketGen prefers the ids EpicGen resolved ─────────────────────────

echo "--- Test 5: TicketGen files against the resolved ids ---"

tg=$(in_new_process 'planner_prompt_ticketgen INIT-PROJ "an idea" /tmp/state')
if echo "$tg" | grep -qF '"Ledgerly M1"'; then
  pass "TicketGen falls back to the raw ref before EpicGen has resolved one"
else
  fail "TicketGen falls back to the raw ref" "no project ref in the prompt"
fi

in_new_process 'planner_config_set INIT-PROJ linear-project-id "11111111-2222-3333-4444-555555555555"
                planner_config_set INIT-PROJ linear-milestone-id "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
                planner_config_set INIT-PROJ linear-team-id "99999999-8888-7777-6666-555555555555"'

tg=$(in_new_process 'planner_prompt_ticketgen INIT-PROJ "an idea" /tmp/state')
if echo "$tg" | grep -qF '"11111111-2222-3333-4444-555555555555"' &&
  ! echo "$tg" | grep -qF '"Ledgerly M1"'; then
  pass "TicketGen prefers the resolved project id EpicGen persisted"
else
  fail "TicketGen prefers the resolved project id" "still using the raw ref"
fi

# The team is the one value where a second, independent lookup would be actively
# harmful: children on a different team from their parent epic is unrecoverable
# without deleting and recreating them.
if echo "$tg" | grep -qF 'TEAM_ID="99999999-8888-7777-6666-555555555555"'; then
  pass "TicketGen files children against the team id EpicGen resolved"
else
  fail "TicketGen reuses the resolved team id" "$(echo "$tg" | grep -m1 'TEAM_ID=' || echo 'absent')"
fi

# ── Test 6: no library reads the flag variables at use time ────────────────────
#
# A structural guard. If someone reintroduces `${LINEAR_PROJECT:-}` into a phase
# prompt or the router, the value silently reverts to empty in production and only
# this check notices.

echo "--- Test 6: no mid-run environment reads ---"

leaks=""
for var in PLANNER_UNTIL PLANNER_REVIEW_HOLD PLANNER_CONSENSUS_HOLD \
  PLANNER_SHARED_BRANCH PLANNER_NO_SHARED_BRANCH LINEAR_PROJECT LINEAR_PROJECT_MILESTONE; do
  hits=$(grep -ln "\${${var}[:-]" "${LIB_DIR}/planner-router.sh" "${LIB_DIR}/planner-phase-prompts.sh" 2>/dev/null || true)
  [ -n "$hits" ] && leaks="${leaks}${var} in ${hits}; "
done

if [ -z "$leaks" ]; then
  pass "the router and phase prompts read none of the flag variables"
else
  fail "no mid-run environment reads" "$leaks"
fi

# SKILL.md may *read* the env vars once during argument parsing — that shell does
# see them. What it must never do again is `export` one and expect a later phase to
# find it, which is the line-for-line mistake #144 was.
skill_md="${LIB_DIR}/../skills/ticket-planner/SKILL.md"
exports=$(grep -nE '^\s*export (PLANNER_UNTIL|PLANNER_SHARED_BRANCH|PLANNER_NO_SHARED_BRANCH|LINEAR_PROJECT|LINEAR_PROJECT_MILESTONE)' "$skill_md" 2>/dev/null || true)
if [ -z "$exports" ]; then
  pass "SKILL.md exports no flag variable across the dispatch loop"
else
  fail "SKILL.md does not export flag variables" "$exports"
fi

# And it must persist the authorization before it can dispatch a write phase.
if grep -q 'planner_authorize_create' "$skill_md" && grep -q 'planner_create_gate_check' "$skill_md"; then
  pass "SKILL.md persists authorization and checks the gate"
else
  fail "SKILL.md wires the create gate" "missing planner_authorize_create or planner_create_gate_check"
fi

echo ""
echo "=== planner config durability: ${PASS} passed, ${FAIL} failed ==="
[ "$FAIL" -eq 0 ]
