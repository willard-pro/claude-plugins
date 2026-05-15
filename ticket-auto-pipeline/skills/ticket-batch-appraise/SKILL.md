---
name: ticket-batch-appraise
description: Parallel appraisal + artifact creation for multiple Linear tickets. Spawns one agent per ticket — each runs appraise then exec. Use when the user says "/ticket-batch-appraise <ID1>, <ID2>, ..." or "batch appraise these: <list>". Also supports Linear queries: "/ticket-batch-appraise --from project:<name> state:Backlog".
---

# Ticket Batch Appraise + Exec

You have been given one or more ticket IDs as the argument. Execute all tickets in parallel — each ticket gets its own agent that runs the full appraise → exec sequence. Report a summary when all are done.

## Guard — Verify working directory

Run `basename "$(pwd)"`. If the result is NOT `tickets`, abort immediately and tell the user to `cd` to the tickets workspace and re-run.

---

## Step 0 — Clear context: Run `/clear`.

---

## Step 0.5 — Detect project context

Read `CLAUDE.md` and extract: `{REPOS_ROOT}` (parent path of all service dirs), `{ISSUE_PREFIX}` (issue ID prefix, e.g. `CRE`).

---

## Step 0.6 — Create task tracker

Create a TaskCreate for every remaining step (Steps 1 through 4). Each task subject = the step heading. Mark each step completed as soon as it finishes. At session end, write a trace file:

```bash
cat > $TICKETS_ROOT/batch-appraise-{timestamp}.md << 'TRACE'
# batch-appraise session — {today}
**Tickets:** {N} submitted, {M} completed, {F} failed

## Results
{ticket ID} — {simple|complex} — {simple-fix|openspec} — {key finding}
...
TRACE
```

---

## Step 1 — Resolve ticket IDs

**If `--from` flag is present** (e.g. `--from project:Credit-Report state:Backlog`):

Call `mcp__linear-server__list_issues` with the qualifiers from the `--from` value. Parse `project:<name>` → team parameter, `state:<name>` → state parameter, `label:<name>` → label parameter. Collect up to 10 matching issue IDs.

**If explicit IDs** (comma or space-separated, e.g. `WIL-42, WIL-47, WIL-51`):

Parse the argument string. Split on commas and/or whitespace. Each token is a ticket ID. Deduplicate. Cap at 10 tickets — if more, warn and take the first 10.

Report the resolved list before spawning agents:

```
## Batch appraise — {N} tickets

{TICKET-ID} — {title from quick Linear fetch}
...
```

Quick-fetch all tickets in parallel (multiple `get_issue` calls in one message) to show titles. These are just display — the full investigation runs in the subagents.

---

## Step 2 — Spawn parallel agents

**All agents must be sent in a single message — one Agent tool call per ticket.** Each agent runs independently with no awareness of the others.

Agent prompt template (fill `{TICKET-ID}` per agent):

```
You are processing ticket {TICKET-ID} end-to-end. Do both phases in order:

### Phase 1: Appraise
Run /ticket-appraise {TICKET-ID}. Follow the skill exactly.

If you hit Resume mode (workspace already exists):
- If asked "continue or re-investigate?", choose "continue".
- If new comments are found, note them and continue. Do not prompt the user.

### Phase 2: Exec
After appraise completes, run /ticket-appraise-exec {TICKET-ID}. Follow the skill exactly.

### Result
When both phases are done, return ONLY:
- Complexity score (simple/complex)
- Axes that fired (or "none")
- Artifact type (simple-fix or openspec:<name>)
- 2-4 key findings from Initial Investigation
- Any open questions
- Path to the ticket workspace directory
```

**Do not use `run_in_background`** — send all Agent calls in a single response so they execute concurrently. The orchestrator waits for all results.

---

## Step 3 — Collect results

As each agent returns, record:

| Field | Source |
|---|---|
| Ticket ID | Agent was spawned with it |
| Complexity | Agent result |
| Axes fired | Agent result |
| Artifact | Agent result (simple-fix or openspec name) |
| Key findings | Agent result (2-4 bullets) |
| Open questions | Agent result |
| Workspace | Agent result path |

If any agent fails (error, timeout, no result) — mark it as `FAILED` and continue collecting from the rest. Do not re-spawn failed agents.

---

## Step 4 — Report

```
## Batch complete — {M}/{N} tickets appraised

| Ticket | Complexity | Artifact | Key finding |
|---|---|---|---|
| {ID} | {simple|complex} | {simple-fix\|openspec} | {one-line summary} |
| {ID} | FAILED | — | {error message} |
...

**Workspaces:**
{for each: path}

**Linear state:** All successful tickets → Approve + `claimed`, awaiting approval.

**Next steps:**
- Complex tickets: review the plan in notes.md, add `approved` label, then run `/ticket-implement <ID>`
- Simple tickets: add `approved` label and run `/ticket-implement <ID>`
- Or: run `/ticket-auto <ID>` on any ticket to take it all the way to merge

{Failed tickets: list IDs — re-run individually with `/ticket-appraise <ID>`}
```
