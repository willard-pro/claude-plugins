---
name: ticket-appraise-exec
description: Artifact executor for a Linear ticket that has already been investigated by /ticket-appraise. Reads the complexity score from notes.md, creates either simple-fix.md or an openspec change, assigns the ticket in Linear, posts the appraisal comment, and moves to Approve state. Run after /ticket-appraise has fully populated notes.md.
---

# Ticket Appraise — Executor

You have been given a ticket ID as the argument (e.g. `WIL-42`). The investigation phase (`/ticket-appraise`) must already be complete — notes.md must contain a `## Complexity` section and a populated `## Initial Investigation` section. Execute the steps below in order.

## Guard — Verify working directory

If the arguments contain `--from-auto`, skip this guard — `ticket-auto` already verified the working directory.

Run `basename "$(pwd)"`. If the result is NOT `tickets`, abort immediately and tell the user to `cd` to the tickets workspace and re-run.

---

## Linear access strategy

When `$LINEAR_API_KEY` is set in the environment, use bash calls to `~/.claude/skills/lib/linear-api.sh` for **all** Linear operations. When `$LINEAR_API_KEY` is unset, fall back to MCP tools (`mcp__linear-server__*`).

**Function mapping:**

| Operation | linear-api.sh bash call | MCP fallback |
|-----------|------------------------|--------------|
| Post comment | `bash -c "source ~/.claude/skills/lib/linear-api.sh; save_comment '<id>' '<body>'"` | `mcp__linear-server__save_comment(issueId: "<id>", body: "<body>")` |
| List issues | `bash -c "source ~/.claude/skills/lib/linear-api.sh; list_issues '<team_key>' '<state>'"` | (MCP equivalent if available) |

Always check `$LINEAR_API_KEY` before each operation and use the appropriate method.

---

## Step 0 — Clear context: Run `/clear`.

---

## Step 0.5 — Detect project context

Read `CLAUDE.md` and extract: `{REPOS_ROOT}` (parent path of all service dirs), `{ISSUE_PREFIX}` (issue ID prefix, e.g. `CRE`), `{BE_SERVICES}` (dirs with `Layer = BE`), `{BE_TEST_CMD}` (backend test command from Build & Test section).

---

## Logging (--from-auto)

If `$LOG_FILE` is set (passed by the `ticket-auto` orchestrator): read `~/.claude/skills/pipeline-log-format.md`. After each major step below, write progress entries to `$LOG_FILE` using the format defined there. Phase is `EXEC`.

## Heartbeat (--from-auto)

If `$HB_LOG_FILE` is set (passed by the orchestrator): call `source ~/.claude/skills/lib/heartbeat.sh` then write heartbeat entries at these points:
- **Complexity read**: after extracting complexity from notes.md, write `hb_decision "complexity-read" "info" "complexity: {simple|complex}" '{"score":"{COMPLEXITY}"}'`
- **Artifact created**: after writing simple-fix.md or openspec change, write `hb_decision "artifact-created" "fired" "created {simple-fix|openspec}" '{"type":"{simple-fix|openspec}"}'`
- **Coherence gate**: after complexity-coherence check, write `hb_gate "coherence-check" "ok|fail" "complexity-artifact match|mismatch" '{"declared":"{COMPLEXITY}","artifact":"{simple-fix|openspec}"}'`
- **Regression verdict**: after the regression guard, write `hb_decision "regression-verdict" "fired" "{CONFLICT|ADJACENT|SUPERSEDES|clear}" '{"verdict":"{CONFLICT|ADJACENT|SUPERSEDES|clear}"}'`
- **Linear fallback**: if LINEAR_API_KEY is unset and MCP fallback is used for posting the comment, write `hb_fallback "linear-api" "fired" "using MCP Linear tools" '{"reason":"LINEAR_API_KEY unset"}'`
- **Re-appraisal skip**: if re-appraisal detected no changes and steps 5-6 are skipped, write `hb_decision "re-appraisal-skip" "info" "no changes detected, skipping Linear post"`

---

## Step dispatch (--from-step)

If `--from-step {step-name}` is in the arguments, this is a crash-recovery resume. Skip all steps up to and including the named step. Do not re-run skipped steps. Proceed directly to the first step after the named step.

| `--from-step` value | Skip to | Restore from |
|---------------------|---------|--------------|
| `load-workspace` | Step 3 (create artifact) | notes.md `## Complexity` for COMPLEXITY; context.md for ticket metadata |
| `create-artifact` | Step 3.5 (regression guard) | simple-fix.md or openspec change already exists |
| `regression-guard` | Step 4 (re-appraisal check) | `## ⚠️ Regression Risk` in notes.md if present |
| `post-linear` | End — skill already complete | — |

If `--from-step` is not provided, proceed normally from Step 1.

---

## Step 1 — Load ticket workspace

Find the local directory:
```bash
find . -type d -name "{TICKET-ID}*"
```

[ -n "$LOG_FILE" ] && echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|EXEC|load-workspace|start|Loading ticket workspace" >> "$LOG_FILE"

If not found → tell the user to run `/ticket-appraise {TICKET-ID}` first. Stop here.

Read both files:
- `context.md` — ticket scope, labels, affected areas
- `notes.md` — investigation findings, complexity score, open questions

**Verify notes.md is ready:** It must contain a `## Complexity` heading with `**Score:**` set. If missing, the planner has not completed — stop and tell the user to finish `/ticket-appraise {TICKET-ID}` first.

Extract from notes.md:
- `{COMPLEXITY}` — `simple` or `complex`
- `{AFFECTED_REPOS}` — repos mentioned in Initial Investigation
- `{OPEN_QUESTIONS}` — anything listed under Open Questions
- `{INVESTIGATION_BULLETS}` — 2-4 key bullets from Initial Investigation
- `{BLAST_RADIUS}` — if `## Blast Radius` section exists, extract the table rows (target, risk, d=1/d=2 callers, affected flows); otherwise `none`

[ -n "$LOG_FILE" ] && echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|EXEC|load-workspace|done|Loaded {COMPLEXITY}" >> "$LOG_FILE"

---

## Step 1.5 — Create task tracker

Create a TaskCreate for every remaining step (Steps 2 through 6). Each task subject = the step heading. After each step is fully done, mark it completed with TaskUpdate. At session end, write a trace file:

```bash
cat > {ticket-dir}/appraise-exec-session.md << 'TRACE'
# appraise-exec session — {ISSUE-ID}
**Date:** {today}
**Complexity:** {simple|complex}
**Artifact:** {simple-fix.md | openspec: <name>}

## Step trace
- [x] Step 2: State already set by appraise (Todo + claimed + assignee)
- [x] Step 3: Create change artifacts — {type}
- [x] Step 3.5: Regression guard — {clear | ADJACENT | CONFLICT | skipped (no prior art)}
- [x] Step 4: Re-appraisal check — {skipped | no marker → continued}
- [x] Step 5: Post Linear comment — {done | skipped (no changes)}
- [x] Step 6: Set state → Approve — {done | skipped (no changes)}
- [x] Step 7: Report — done
TRACE
```

---

## Step 2 — State already set

Ticket was already moved to `Todo` with `claimed` label and `assignee: "me"` by `ticket-appraise`. No action needed — proceed to Step 3.

---

## Step 3 — Create change artifacts

[ -n "$LOG_FILE" ] && echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|EXEC|create-artifact|start|Creating artifact" >> "$LOG_FILE"

Branch on `{COMPLEXITY}` extracted from notes.md:

---

### Step 3-Simple (complexity = simple)

Create `simple-fix.md` in the ticket directory. Do not run `opsx:propose`.

```markdown
# Simple Fix — {ISSUE-ID}

## Summary
{one sentence: what the ticket asks for}

## Affected files
{For each file that needs to change:}
- `{repo-relative-path}:{line or range}` — {what needs to change and why}

## How to implement
{Concrete step-by-step instructions derived from the investigation. Be specific enough
that an implementer can follow without re-reading the ticket. Include method names,
field names, enum values, config keys, etc. where known.}

## Constraints and gotchas
{Anything that could go wrong: ordering dependencies, side effects, things NOT to change.
Omit this section if there are none.}

{If BLAST_RADIUS is not "none":}
## Blast Radius (from GitNexus)
{Insert the blast radius table from notes.md verbatim.}

{If any target has d=1 callers listed:}
**⚠️  High-risk targets:** {list targets with HIGH/CRITICAL risk or 3+ d=1 callers}. These break if the change is wrong — verify each one is intentionally modified or confirmed unaffected.```

---

### Step 3-Complex (complexity = complex)

Run the `/opsx:propose` skill to create the change artifacts for this ticket.

**Derive the change name:** `{ticket-id-lowercase}-{title-slug}` (e.g. `wil-42-upload-page-scroll`).

Pass the following to the propose skill as context:

- The ticket ID, title, and description
- The affected repos and files from the investigation in notes.md
- Whether any **backend (BE) repos** are involved — use `{BE_SERVICES}` resolved in Step 0.5
- {If BLAST_RADIUS is not "none":} The blast radius table from notes.md — affected communities, execution flows, and high-risk targets

**Unit test requirement (BE only):** After `tasks.md` is generated, check whether it contains a task for writing or updating unit tests. If the ticket touches any BE repo and no such task exists, add one explicitly:

```markdown
### Write unit tests for <service> changes
- Identify the service classes / methods modified in this ticket
- Write or update unit tests covering the new/changed logic
- Run `{BE_TEST_CMD}` in the affected repo and confirm all tests pass
```

Insert this task after the main implementation tasks and before any commit/push tasks.

[ -n "$LOG_FILE" ] && echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|EXEC|create-artifact|done|{simple-fix|openspec}" >> "$LOG_FILE"

---

## Step 3.4 — Complexity-coherence gate

After writing the artifact, verify that the declared complexity matches what was produced.

Read complexity from notes.md using the shared helper:
```bash
COMPLEXITY=$(bash -c "source ~/.claude/skills/lib/notes-parse.sh; get_complexity '{TICKET_DIR}'")
```

Check artifact presence:
```bash
# simple-fix path
SIMPLE_FIX=$(find {TICKET_DIR} -name "simple-fix.md" -print -quit 2>/dev/null)
# openspec path
CHANGE_DIR=$(ls -d openspec/changes/*/ 2>/dev/null | grep -i "{ticket-id-lowercase}" | head -1)
OPENSPEC_TASKS="${CHANGE_DIR}tasks.md"
```

Assert coherence:
- If `COMPLEXITY` is empty → gate fires: `COMPLEXITY_ARTIFACT_MISMATCH — notes.md missing **Score:** under ## Complexity`
- If `COMPLEXITY` = `simple` AND `SIMPLE_FIX` is absent → gate fires: `COMPLEXITY_ARTIFACT_MISMATCH — declared simple but no simple-fix.md found`
- If `COMPLEXITY` = `complex` AND (`CHANGE_DIR` is empty OR `OPENSPEC_TASKS` does not exist) → gate fires: `COMPLEXITY_ARTIFACT_MISMATCH — declared complex but no openspec tasks.md found`
- If `COMPLEXITY` = `simple` AND `SIMPLE_FIX` absent but openspec dir exists → gate fires: `COMPLEXITY_ARTIFACT_MISMATCH — declared simple but found openspec artifact (not simple-fix.md)`

On any mismatch:
```bash
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|META|gate-stop|fail|COMPLEXITY_ARTIFACT_MISMATCH — declared={COMPLEXITY} artifact={artifact-found}" >> "$LOG_FILE"
```
Stop with non-zero exit so `ticket-auto` halts the pipeline.

On match proceed silently to Step 3.5.

---

## Step 3.5 — Regression Guard

[ -n "$LOG_FILE" ] && echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|EXEC|regression-guard|start|Checking plan against prior art" >> "$LOG_FILE"

Read the `## Prior Art` section of notes.md. If it says "No relevant prior art found." and there are no `[local-ticket]` entries → skip this step entirely, proceed to Step 4.

Otherwise:

**A. Extract affected files from the plan:**
- If `{COMPLEXITY}` = simple: read `simple-fix.md` → collect every file path listed under `## Affected files`
- If `{COMPLEXITY}` = complex: read `openspec/changes/{change-name}/tasks.md` → collect every file path mentioned in implementation tasks

**B. Cross-reference:** For each file path in the plan, check whether any Prior Art hit mentions the same file path, class name, or component name. A match is when the same token appears in both the plan's affected-file list and the prior art hit's **Key finding** or **Incorporate** lines.

**C. For each overlapping file, perform conflict reasoning:**

Read the prior ticket's artifact: check for `simple-fix.md` in the matched ticket directory first, then fall back to the `## Initial Investigation` section of its notes.md. Read the relevant section of the current plan for that same file. Then explicitly reason:

> "The prior fix did X to this file. The current plan does Y. Does Y undo, overwrite, or conflict with X?"

Assign a verdict:
- `CONFLICT` — the current plan would undo or overwrite the prior fix
- `ADJACENT` — same file, different lines/method/section, no direct conflict
- `SUPERSEDES` — current plan intentionally replaces the prior fix (document why)

**D. Write to notes.md** if any overlap exists (regardless of verdict):

```markdown
## ⚠️ Regression Risk

| Plan file | Prior art | Verdict | Detail |
|-----------|-----------|---------|--------|
| `{file}` | {TICKET-ID} [local-ticket\|mem] | CONFLICT\|ADJACENT\|SUPERSEDES | {one sentence} |

**Status:** UNACKNOWLEDGED
→ Edit this file and change Status to `ACKNOWLEDGED` before running `/ticket-implement {TICKET-ID}`.
```

**E. Print to user:**

If any CONFLICT verdict:
```
⚠️  REGRESSION RISK — CONFLICT DETECTED
The implementation plan for {TICKET-ID} conflicts with a prior fix.
See ## Regression Risk in notes.md. Change Status to ACKNOWLEDGED after reviewing before running /ticket-implement.
```

If ADJACENT or SUPERSEDES only (no CONFLICT):
```
ℹ️  Regression check: overlapping files found, no direct conflict (see ## Regression Risk in notes.md).
Acknowledge in notes.md before implementing.
```

If no overlap: write nothing — proceed silently.

[ -n "$LOG_FILE" ] && echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|EXEC|regression-guard|done|{CONFLICT|ADJACENT|SUPERSEDES|clear}" >> "$LOG_FILE"

---

## Step 4 — Check for re-appraisal skip

Read notes.md and look for a `## Re-appraisal` section. If it contains `**Changes detected:** no`, skip Steps 5 and 6 — no new comment or state change needed. Proceed directly to Step 7 (Report).

If no `## Re-appraisal` section exists (first run), or `**Changes detected:** yes`, continue to Step 5.

---

## Step 5 — Post a Linear comment

[ -n "$LOG_FILE" ] && echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|EXEC|post-linear|start|Posting appraisal comment" >> "$LOG_FILE"

Post a comment via the Linear access strategy (bash `save_comment` when `LINEAR_API_KEY` is set, MCP `save_comment` fallback otherwise) summarising the appraisal:

```
**Ticket appraised** — local workspace created.

**Initial investigation:**
{2-4 bullets from Initial Investigation in notes.md}

**Open questions:**
{From notes.md Open Questions — or "None"}

**Next step:**
{First concrete action from notes.md Next Steps}
```

[ -n "$LOG_FILE" ] && echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|EXEC|post-linear|done|Comment posted" >> "$LOG_FILE"

---

## Step 6 — Set Linear state → Approve

Delegate to the flow executor:

```
/ticket-flow {TICKET-ID} appraise-complete
```

This sets state → `Approve`, keeping all existing labels.

---

## Step 7 — Report to the user

[ -n "$LOG_FILE" ] && echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|EXEC|handoff|start|Writing final report" >> "$LOG_FILE"

```
## {TICKET-ID} appraisal complete

**Local directory:** `{relative path from tickets root}`

**Complexity:** {simple | complex}

**Artifacts created:**
- {simple-fix.md | openspec change: <change-name>}

**Open questions:**
{bullets or "None"}

**Next step:** {first action}

Linear updated — assigned to you, status → Approve + `claimed` (awaiting approval).

> **Full state lifecycle:**
> Todo + `claimed` (appraise) → Approve + `claimed` (end of exec) → Ready + `approved` (human approves) → Review (after PR) → Done

Run `/ticket-implement {TICKET-ID}` once the `approved` label is added in Linear.
```

[ -n "$LOG_FILE" ] && echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|EXEC|handoff|done|Reported to user" >> "$LOG_FILE"
