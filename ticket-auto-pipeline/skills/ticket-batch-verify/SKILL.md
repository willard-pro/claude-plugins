---
name: ticket-batch-verify
description: Parallel UAT verification for multiple Linear tickets. Spawns one agent per ticket — each navigates UAT, confirms the fix against acceptance criteria, and reports PASS/FAIL. Use when the user says "/ticket-batch-verify <ID1>, <ID2>, ..." or "batch verify these: <list>". Also supports Linear queries: "/ticket-batch-verify --from project:<name> state:UAT".
---

# Ticket Batch Verify

You have been given one or more ticket IDs as the argument. Execute all tickets in parallel — each ticket gets its own agent that runs the full verify sequence on UAT. Report a summary when all are done.

**Credentials:** Each agent auto-derives the test user from its ticket description (ticket-verify Step 1b5). UAT password is always `admin`. No `--user`/`--password` flags needed. If a ticket lacks a user email in its description, the agent posts a comment asking for one and reports FAIL.

## Guard — Verify working directory

Run `basename "$(pwd)"`. If the result is NOT `tickets`, abort immediately and tell the user to `cd` to the tickets workspace and re-run.

---

## Step 0 — Clear context: Run `/clear`.

---

## Step 0.5 — Detect project context

Read `CLAUDE.md` and extract: `{UAT_URL}` (UAT environment URL), `{ISSUE_PREFIX}` (issue ID prefix, e.g. `CRE`). If no `UAT_URL`, abort — batch verify requires UAT.

---

## Step 0.6 — Create task tracker

Create a TaskCreate for every remaining step (Steps 1 through 4). Each task subject = the step heading. Mark each step completed as soon as it finishes. At session end, write a trace file:

```bash
cat > "$TICKETS_ROOT/batch-verify-{timestamp}.md" << 'TRACE'
# batch-verify session — {today}
**Tickets:** {N} submitted, {P} passed, {F} failed

## Results
{ticket ID} — PASS|FAIL — {key evidence or failure reason}
...
TRACE
```

---

## Step 1 — Resolve ticket IDs

**If `--from` flag is present** (e.g. `--from project:Handovers state:UAT`):

Call `mcp__linear-server__list_issues` with the qualifiers from the `--from` value. Parse `project:<name>` → team parameter, `state:<name>` → state parameter, `label:<name>` → label parameter. Collect up to 10 matching issue IDs.

Common query: `--from state:UAT` — all tickets awaiting UAT verification.

**If explicit IDs** (comma or space-separated, e.g. `CRE-45, CRE-46, CRE-47`):

Parse the argument string. Split on commas and/or whitespace. Each token is a ticket ID. Deduplicate. Cap at 10 tickets — if more, warn and take the first 10.

Report the resolved list before spawning agents:

```
## Batch verify — {N} tickets on UAT

{TICKET-ID} — {title from quick Linear fetch}
...
```

Quick-fetch all tickets in parallel (multiple `get_issue` calls in one message) to show titles and confirm they're in UAT state. Warn if any are not in `UAT` state but proceed anyway.

---

## Step 2 — Spawn parallel agents

**All agents must be sent in a single message — one Agent tool call per ticket.** Each agent runs independently with no awareness of the others.

Agent prompt template (fill `{TICKET-ID}` per agent):

```
Verify ticket {TICKET-ID} on UAT. Run:

/ticket-verify --env uat --from-auto {TICKET-ID}

Follow the ticket-verify skill exactly. --from-auto means:
- No user prompts — never ask questions
- Auto-derive the test user email from the ticket description (Step 1b5)
- UAT password is always "admin"
- If no user email in the ticket, post a comment asking for one and report FAIL
- If login fails, post a comment and report FAIL
- If a step requires input you don't have, report it in WHAT_FAILED

After the verify run completes, return ONLY:
1. Verdict: PASS or FAIL
2. Which user was used (email)
3. If PASS — what confirmed the fix (1-2 sentences)
4. If FAIL — what went wrong (step number, expected vs observed)
5. The ticket title (from Linear)
6. Path to the ticket workspace directory (if found)
```

**Do not use `run_in_background`** — send all Agent calls in a single response so they execute concurrently. The orchestrator waits for all results.

---

## Step 3 — Collect results

As each agent returns, record:

| Field | Source |
|---|---|
| Ticket ID | Agent was spawned with it |
| Title | Agent result |
| Verdict | Agent result — PASS or FAIL |
| Evidence/Reason | Agent result |
| Workspace | Agent result path |

If any agent fails (error, timeout, no result) — mark it as `FAILED` and continue collecting from the rest. Do not re-spawn failed agents.

### For each PASS:

Call `/ticket-flow {TICKET-ID} uat-pass` to move to Done:
```bash
/ticket-flow {TICKET-ID} uat-pass
_rc=$?
if [ "$_rc" -ne 0 ]; then
  hb_retry "flow-sh" "fail" "flow.sh uat-pass failed (exit ${_rc})" \
    "{\"trigger\":\"uat-pass\",\"exit_code\":\"${_rc}\",\"ticket\":\"{TICKET-ID}\"}"
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|META|flow-error|fail|exit ${_rc}: uat-pass" >> {LOG_FILE}
fi
```

### For each FAIL:

Post the agent's findings to Linear as a comment on the ticket. Use the agent's evidence as the body:

```
❌ ticket-verify FAIL — uat (batch)

**Tested as:** {--user}
**Date:** {today}

{agent's failure evidence}

**Next step:** Run `/ticket-verify --env uat {TICKET-ID}` interactively to diagnose.
```

Then call `/ticket-flow {TICKET-ID} uat-fail` to move back to Ready:
```bash
/ticket-flow {TICKET-ID} uat-fail
_rc=$?
if [ "$_rc" -ne 0 ]; then
  hb_retry "flow-sh" "fail" "flow.sh uat-fail failed (exit ${_rc})" \
    "{\"trigger\":\"uat-fail\",\"exit_code\":\"${_rc}\",\"ticket\":\"{TICKET-ID}\"}"
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|META|flow-error|fail|exit ${_rc}: uat-fail" >> {LOG_FILE}
fi
```

---

## Step 4 — Report

```
## Batch complete — {P}/{N} passed, {F}/{N} failed

| Ticket | Title | Verdict | Evidence |
|---|---|---|---|
| {ID} | {title} | ✅ PASS | {one-line evidence} |
| {ID} | {title} | ❌ FAIL | {one-line failure reason} |
| {ID} | FAILED | — | Agent error: {message} |
...

**Passed ({P}):** Already moved to Done via uat-pass.
**Failed ({F}):** Moved back to Ready via uat-fail. Failure details posted to Linear.
**Errors ({E}):** Agents that crashed — re-run individually.

**Trace:** batch-verify-{timestamp}.md
```

---

## Notes

- **Credentials are auto-derived** — each agent extracts the test user email from the ticket description. Password is `admin`. If a ticket lacks a user email, the agent posts a comment and fails gracefully.
- **Cap at 10 tickets** — beyond that, split into multiple batch runs.
- **Each agent gets its own browser tab** — Playwright agents operate independently.
- **UAT only** — batch verify doesn't support localhost. Local verification needs a running dev server and is inherently one-at-a-time.
- **State transitions are automatic** — PASS → Done, FAIL → Ready. No human review step per ticket.
