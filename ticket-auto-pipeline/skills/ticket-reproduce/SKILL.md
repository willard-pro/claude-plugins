---
name: ticket-reproduce
description: Derives a concrete browser reproduction plan from a Linear ticket, writes it to reproduce.md in the ticket directory, then navigates UAT step-by-step using playwright-cli to confirm the bug. Use when the user says "/ticket-reproduce <ID>", "reproduce ticket <ID>", or "verify bug <ID>".
---

# Ticket Reproduce

You have been given a ticket ID as the argument (e.g. `CRE-45`). Execute the full sequence below in order.

## Guard — Verify working directory

Run `basename "$(pwd)"`. If the result is NOT `tickets`, abort immediately and tell the user to `cd` to the tickets workspace and re-run.

---

## Credentials

Read `/home/mortal/.claude/skills/ticket-reproduce/credentials.md` to look up the password for the user and environment before any login attempt. The credentials file is the source of truth — never assume a default password.

---

## Step 1 — Set up local workspace

Run `/ticket-setup {TICKET-ID}` and wait for it to complete.

- If ticket-setup reports **workspace created** → use the directory path and ticket data it outputs; continue to Step 2.
- If ticket-setup reports **workspace already exists** → read `context.md` from the existing directory; continue to Step 2.

---

## Step 1.5 — Create task tracker

Create a TaskCreate for every remaining step (Steps 2 through 8). Each task subject = the step heading. After each step is fully done, mark it completed with TaskUpdate. At session end, write a trace file:

```bash
cat > {ticket-dir}/reproduce-session.md << 'TRACE'
# reproduce session — {ISSUE-ID}
**Date:** {today}
**Result:** {REPRODUCED|NOT REPRODUCED|BLOCKED}

## Step trace
- [x] Step 2: Load app knowledge — done
- [x] Step 3: Derive plan — {N} steps
- [x] Step 3b: Sufficiency check — {pass|gaps found}
- [x] Step 4: Write reproduce.md — done
- [x] Step 5: Present plan — confirmed
- [x] Step 6: Execute in browser — {N} steps navigated
- [x] Step 7: Record result — {outcome}
- [x] Step 8: Report — done
TRACE
```

---

## Step 2 — Load app knowledge and credentials

Read in parallel:
1. `/home/mortal/.claude/skills/app-knowledge/SKILL.md` — navigation patterns, role-based UI rules, state mappings, known quirks
2. `{TICKETS_ROOT}/nav-hints.md` — click-by-click navigation paths for feature areas (never use `page.goto()` for in-app nav)
3. `/home/mortal/.claude/skills/ticket-reproduce/credentials.md` — environment-specific passwords

From the ticket-setup output (or context.md), extract:
- **User** to log in as (look for a "User:" or "Log in as" field in the description)
- **Steps to Reproduce** — numbered list of user actions
- **Bug observation** — what is wrong / what to look for at the assertion point

---

## Step 3 — Derive the reproduction plan

Using the steps from context.md and the navigation knowledge from app-knowledge, enrich each step into a concrete navigation action.

For each original step, produce:
- **Action**: what to do in the browser (navigate to URL, click element by label, fill field, select option)
- **Path/selector hint**: known URL path or UI element label from app-knowledge
- **Prerequisite** (if any): what state the system must be in first

Apply these navigation rules:
- **Never use `page.goto()` for in-app navigation** — Angular loses session state on full reload. Always click through the UI.
- Use `{TICKETS_ROOT}/nav-hints.md` for known area → click-path mappings. If the feature area isn't listed, derive navigation from app-knowledge patterns.
- Action icons per handover row (left to right, confirmed CRE-45): Book (Documents), Comments, Receipt (Payments), Toolbox dropdown (Correspondents, Fees, Defendant, Reference)
- Attorney users: do NOT use Book/Documents icon (1st icon, returns `/accessdenied` from detail view); use the correct icon for the feature
- Nav bar org name confirms successful login
- If nav bar doesn't show Handovers/Administration after login, the intermittent nav bug struck — navigate to root URL (`/`) to restore, then log in again

For the **assertion step** (the final "observe" step), be explicit about:
- What value is currently shown (the bug)
- What value should be shown (the expected)
- Where exactly to look in the UI (page, section, field name)

If any step is ambiguous or requires a specific handover record that may not exist, note it as a **prerequisite gap**.

---

## Step 3b — Sufficiency check

Before writing the plan, assess whether the ticket provides enough detail to actually execute the reproduction without guessing.

**Required information checklist:**
- [ ] Which specific record to use (e.g. which handover, which case, which debtor) — OR explicit instruction to create a new one
- [ ] Which user to log in as
- [ ] Clear assertion: what to observe and where (page/section/field)
- [ ] Any prerequisite state the record must be in (e.g. handover state = LEGAL)

**Examples of missing info that block reproduction:**
- "Navigate to Handovers" without specifying which handover (reference number, debtor name, etc.)
- "Record a payment" without specifying whether to use an existing payment or create a new one
- "Observe the progress entry" without specifying which entry (newest, specific date, etc.)
- No user specified

**If any required information is missing:**

1. List every gap clearly.
2. Post a comment on the Linear ticket via `mcp__linear-server__save_comment`:

```
**Reproduction blocked — additional information required**

To reproduce this issue I need the following details:

- {gap 1: e.g. "Which handover should I use? Please provide the reference number or debtor name."}
- {gap 2: e.g. "Should I record a new payment or look at an existing one? If existing, which one?"}
- {gap 3: etc.}

Once these details are provided I can proceed with the reproduction.
```

3. Report to the user:
```
## CRE-XX — Reproduction blocked

Insufficient detail to reproduce. Comment posted on Linear requesting:
- {gap 1}
- {gap 2}

Waiting for reporter to respond before proceeding.
```

4. **Stop. Do not proceed to Step 4.**

**If all required information is present:** proceed to Step 4.

---

## Step 4 — Write reproduce.md

Write the plan to `{ticket-dir}/reproduce.md`:

```markdown
# Reproduction Plan — {TICKET-ID}

**Environment:** UAT — https://uat.credit-network.biz
**User:** {email}
**Password:** {password from credentials.md for this env}
**Generated:** {today's date}

---

## Prerequisites

- {List any required system state — e.g. "A handover in LEGAL state must exist and be assigned to the attorney's organisation"}

---

## Steps

| # | Action | Detail | Assert |
|---|--------|--------|--------|
| 1 | Log in | Navigate to https://uat.credit-network.biz, fill username = {email}, password = admin, click Sign In | Nav bar shows org name confirming authenticated session |
| 2 | ... | ... | — |
| N | Observe bug | Navigate to {page}, find {field} | **BUG:** Shows "{actual value}" — Expected: "{expected value}" |

---

## Expected vs Actual

| Field | Expected | Actual (bug) |
|-------|----------|--------------|
| {field name} | {correct value} | {wrong value shown} |

---

## Result

<!-- Filled in after navigation -->
**Status:** PENDING
**Reproduced:** —
**Notes:** —
**Screenshot:** —
```

---

## Step 5 — Present plan and confirm

Show the user the reproduction plan in a concise summary:

```
## Reproduction Plan — {TICKET-ID}

**User:** {email} / admin
**Environment:** UAT

**Steps:**
1. {step}
2. {step}
...

**Assertion:** At step N, {field} should show "{expected}" but bug shows "{actual}".

**Prerequisite gaps:** {any gaps found, or "None"}

---
Ready to navigate UAT and execute these steps?
```

**Wait for user confirmation before proceeding.**

---

## Step 6 — Execute in browser via playwright-cli

Open a browser and navigate UAT step by step.

### Login
```bash
playwright-cli open https://uat.credit-network.biz
playwright-cli snapshot
# Fill login form
playwright-cli fill [username field ref] "{email}"
playwright-cli fill [password field ref] "{password from credentials.md}"
playwright-cli click [sign in button ref]
playwright-cli snapshot
```

Confirm login success: nav bar must show the org name. If login fails or nav bar is incomplete (missing Handovers / Administration), note it and attempt a second navigation to trigger the enriched JWT flow:
```bash
playwright-cli goto https://uat.credit-network.biz/handover
playwright-cli snapshot
```

### Execute each step

For each step in the plan:
1. Perform the action using playwright-cli commands
2. Take a snapshot after each significant action
3. Note what is visible — if a step fails (element not found, access denied, missing data), record the blocker and continue where possible

### Assertion step

At the assertion point:
```bash
playwright-cli snapshot
playwright-cli screenshot --filename={ticket-id}-assertion.png
```

Read the snapshot carefully. Compare the actual value shown against the expected value from the plan.

---

## Step 7 — Record result

Update `reproduce.md` — fill in the Result section:
- `Status`: REPRODUCED or NOT REPRODUCED or BLOCKED
- `Reproduced`: yes / no / blocked
- `Notes`: what was observed at the assertion point (exact text seen)
- `Screenshot`: path to screenshot file (relative to ticket dir)

Also append to `{ticket-dir}/notes.md`:

```markdown
### {today's date} — Reproduction run
- **Result:** REPRODUCED / NOT REPRODUCED / BLOCKED
- **Observed:** "{exact value seen at assertion point}"
- **Expected:** "{correct value}"
- **Screenshot:** attachments/{ticket-id}-assertion.png
```

Move the screenshot to `{ticket-dir}/attachments/` if captured.

---

## Step 8 — Report to user

```
## {TICKET-ID} — Reproduction Result

**Status:** REPRODUCED ✓ / NOT REPRODUCED / BLOCKED

**Assertion:**
- Field: {field name}
- Expected: "{expected}"
- Observed: "{actual}"

**Screenshot:** {path or "not captured"}

{If BLOCKED: explain what prevented reproduction and what prerequisite is missing}

{If NOT REPRODUCED: note whether the bug may be fixed already or environment-specific}
```
