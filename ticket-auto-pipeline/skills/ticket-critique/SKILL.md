---
name: ticket-critique
description: Validates a Linear ticket's requirements for completeness before implementation begins. Checks for multi-role credential gaps, untestable acceptance criteria, missing test data, and scope ambiguity. Posts a Linear comment and adds `needs-info` label if blockers are found. Called automatically by ticket-appraise Step 2.7.
---

# Ticket Critique

Given a ticket ID (e.g. `CRE-40`), validate that the ticket contains enough information to plan, implement, and verify it. This runs on the ticket text only — no codebase reads.

## Guard — Verify working directory

If the arguments contain `--from-appraise`, skip this guard — `ticket-appraise` already verified the working directory.

Run `basename "$(pwd)"`. If the result is NOT `tickets`, abort immediately and tell the user to `cd` to the tickets workspace and re-run.

---

## Input

Read from the local workspace (already created by ticket-setup):
- `context.md` — description, acceptance criteria, labels, comments
- `CLAUDE.md` — known environments (LOCAL_URL, UAT_URL), any documented test users

If `--from-appraise` is in the arguments, the workspace is guaranteed to exist.
Otherwise, find it:
```bash
find . -type d -name "{TICKET-ID}*"
```
If not found → tell the user to run `/ticket-appraise {TICKET-ID}` first. Stop here.

---

## Checklist

Run every check below. Classify each finding:
- **BLOCKER** — will definitively cause the pipeline to fail (must resolve before continuing)
- **WARNING** — may cause problems; record and continue

### Check 1 — Multi-role credential completeness

Scan the ticket description, acceptance criteria, and comments for role mentions. Look for patterns such as:
- "as an attorney", "as a debtor", "admin role", "attorney user", "debtor user"
- "X role", "Y role", "test as X", "log in as X", "with user X"
- "3 roles", "two users", "each user type", "different accounts"

Count distinct roles required for testing.

Scan for credentials provided in the ticket body and comments (username/email + password pairs). Also check CLAUDE.md for any documented test accounts.

**If distinct roles required > credential sets available → BLOCKER.**

Record:
```
- [BLOCKER] Multi-role gap: AC requires {N} roles ({list}), only {M} credential set(s) found.
  Missing credentials for: {list of roles without credentials}
```

### Check 2 — Acceptance criteria testability

For each acceptance criterion, check whether it describes an **observable outcome** — something that can be confirmed by looking at the UI or checking an API response.

Flag as WARNING if any criterion:
- Uses vague language: "should work correctly", "should be improved", "look better", "be fixed", "work as expected"
- Describes internal behavior only with no observable result
- Is written as a non-verifiable goal rather than a verifiable state

Record:
```
- [WARNING] Untestable AC: "{criterion text}" — no observable outcome described.
```

### Check 3 — Test data / pre-existing state assumptions

Scan AC and description for phrases that assume data already exists:
- "an existing handover", "a case in state X", "when there is already", "after creating"
- "the record created in CRE-XX", "use the handover from", "existing attorney"

For each assumption: check if the ticket describes how to set up that state, or references a ticket that provides the data.

**If pre-existing data is required AND no setup is described → WARNING** (may become a blocker depending on environment).

Record:
```
- [WARNING] Assumed test data: "{phrase}" — ticket does not describe how to reach this state.
```

### Check 4 — Scope identifiable

Check whether the ticket description is specific enough to identify at least one affected service or component from the CLAUDE.md codebase map.

- Read the codebase map table from CLAUDE.md
- Check if any service name, feature area, or layer keyword from the ticket title/description matches a row

**If no service or layer can be identified → WARNING.**

Record:
```
- [WARNING] Scope unclear: ticket description does not map to any known service or component.
```

### Check 5 — Bug tickets: reproduction steps

If the ticket has the `bug` label:
- Check whether numbered reproduction steps are present in the description
- Acceptable: "1. Go to X, 2. Click Y, 3. See error Z"

**If no repro steps → WARNING.**

Record:
```
- [WARNING] Bug without repro steps: no numbered steps to reproduce the issue.
```

---

## Write results to notes.md

Append a `## Readiness Critique` section:

```markdown
## Readiness Critique
**Date:** {today}
**Status:** {BLOCKED | WARNINGS | CLEAR}

### Findings
{For each finding, one bullet with [BLOCKER] or [WARNING] prefix}

### Missing information (blockers only)
{Bulleted list of what needs to be provided before this ticket can proceed}
```

If no findings: write `**Status:** CLEAR` with no findings list.

---

## Act on results

### If any BLOCKERs found

1. Post a Linear comment via `mcp__linear-server__save_comment`:

```
**Ticket blocked — missing information required for implementation.**

The following must be provided before this ticket can be appraised:

{bulleted list of BLOCKER items with plain-language description}

Please update the ticket description or add a comment with the missing details,
then re-run `/ticket-appraise {TICKET-ID}`.
```

2. Add `needs-info` label:

```
/ticket-flow {TICKET-ID} needs-info
```

3. Tell the user:

```
🚫 {TICKET-ID} — BLOCKED (missing information)

{list of BLOCKER items, one per line}

Linear updated — `needs-info` label added and comment posted.
Resolve the blockers in the Linear ticket, then re-run /ticket-appraise {TICKET-ID}.
```

4. **Stop.** Do not continue to codebase investigation.

---

### If WARNINGs only (no BLOCKERs)

Tell the user:

```
⚠️  {TICKET-ID} — {N} warning(s) noted (no blockers)

{list of WARNING items, one per line}

Continuing with appraisal. Warnings recorded in notes.md under ## Readiness Critique.
```

Continue — do not stop the pipeline.

---

### If CLEAR

Tell the user:

```
✓ {TICKET-ID} — readiness check passed. Continuing.
```

Continue silently.
