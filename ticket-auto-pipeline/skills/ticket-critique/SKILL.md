---
name: ticket-critique
description: Validates a Linear ticket's requirements for completeness before implementation begins. Checks for multi-role credential gaps, untestable acceptance criteria, missing test data, and scope ambiguity. Posts a Linear comment and adds `needs-info` label if blockers are found. Called automatically by ticket-appraise Step 2.7. Supports --from-appraise (workspace guaranteed), --from-audit (fetches from Linear API, includes Source: marker).
---

# Ticket Critique

Given a ticket ID (e.g. `CRE-40`), validate that the ticket contains enough information to plan, implement, and verify it. This runs on the ticket text only — no codebase reads.

## Pipeline Preamble

Follow the pipeline preamble in `~/.claude/skills/lib/skill-preamble.md` with parameters: TICKET_ID=<from args>, PHASE=none, FROM_FLAG=--from-appraise, HAS_LINEAR_ACCESS=false, HAS_GUARD=true, HAS_PROJECT_CONTEXT=false, HAS_LOGGING=false, HAS_HEARTBEAT=false, HAS_STEP_DISPATCH=false, HAS_TASK_TRACKER=false

---

## Input

### If `--from-audit` is in the arguments

No workspace is guaranteed — fetch everything from the Linear API directly.

1. Source `lib/linear-api.sh` and `lib/config.sh`:
   ```bash
   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && cd ../../lib && pwd || echo "$HOME/.claude/skills/lib")"
   source "$SCRIPT_DIR/linear-api.sh"
   source "$SCRIPT_DIR/config.sh"
   ```

2. Fetch the ticket from Linear:
   ```bash
   ISSUE_JSON=$(get_issue "{TICKET_ID}")
   TITLE=$(echo "$ISSUE_JSON" | jq -r '.title')
   DESCRIPTION=$(echo "$ISSUE_JSON" | jq -r '.description // ""')
   LABELS=$(echo "$ISSUE_JSON" | jq -r '[.labels[]?.name] | join(", ")')
   STATE=$(echo "$ISSUE_JSON" | jq -r '.state.name')
   ```

3. Fetch comments for additional context:
   ```bash
   COMMENTS_JSON=$(get_comments "{TICKET_ID}")
   COMMENT_BODIES=$(echo "$COMMENTS_JSON" | jq -r '.[]?.body // ""' | head -5)
   ```

4. Build analysis context from API data (no workspace files needed):
   - **Title**: `$TITLE`
   - **Description**: `$DESCRIPTION`
   - **Labels**: `$LABELS`
   - **State**: `$STATE`
   - **Recent comments**: `$COMMENT_BODIES`
   - **Acceptance criteria**: extracted from description (look for numbered lists, "AC:", "Acceptance Criteria:" sections)

5. Read CLAUDE.md for known test users/environments (same as standard path):
   ```bash
   if [ -f "CLAUDE.md" ]; then
     cat CLAUDE.md | grep -A5 "test users\|UAT_URL\|LOCAL_URL" || true
   fi
   ```

Proceed to Checklist — same checks apply regardless of input source.

### If `--from-appraise` is in the arguments, the workspace is guaranteed to exist.
Otherwise (no recognized flag), find it:
```bash
find . -type d -name "{TICKET-ID}*"
```
If not found → tell the user to run `/ticket-appraise {TICKET-ID}` first. Stop here.

---

## Checklist

Run every check below. Classify each finding:
- **BLOCKER** — will definitively cause the pipeline to fail (must resolve before continuing)
- **WARNING** — may cause problems; record and continue

### Check 0 — Minimum Content Gate

Scan the ticket description for three structural prerequisites. This runs before all other checks — a ticket that fails Check 0 is structurally incomplete.

**0a. Acceptance criteria scan:**
Count distinct acceptance criteria in the description. Detect by:
- Numbered lines: `1.`, `2.`, `3.` at the start of lines
- Checkbox items: `- [ ]`, `- [x]`
- Explicit heading: `## Acceptance Criteria`, `### Acceptance Criteria`, `**Acceptance Criteria:**`

- **0 AC** → `[BLOCKER] No acceptance criteria: ticket has zero verifiable outcomes listed.`
- **1 AC** → `[WARNING] Thin acceptance criteria: only 1 verifiable outcome listed.`
- **2+ AC** → pass (no finding)

**0b. Test user / role scan:**
Scan the description for test user identification. Detect by:
- Email address patterns (e.g., `user@example.com`, `name@sdtlaw.co.za`)
- `**User:**` field with a value
- Role mentions: "as an attorney", "as an admin", "as a [role]", "log in as", "test as", "with user"
- Named test users from the test user catalog (`test-users.json` — project-local, not bundled; absent if not yet configured)

- **No test user email AND no role mention** → `[BLOCKER] No test user or role specified. Cannot determine who should verify this ticket.`
- **Test user email or role found** → pass (no finding)

**0c. Navigation target scan:**
Scan the description for navigation instructions. Detect by:
- URL path patterns: `/handover/`, `/admin/`, `/user-permission/`, `/organisation/`
- Navigation verbs: "Navigate to", "Go to", "Open"
- Menu path descriptions: "[Menu] → [Submenu]"

- **No URL path AND no navigation instruction** → `[WARNING] No navigation path specified. Verifier will need to discover the feature location from code.`
- **Navigation target found** → pass (no finding)

Record all Check 0 findings.

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

**If no repro steps → BLOCKER.** The verifier cannot reproduce the bug without steps — this is not a warning.

If the ticket is a feature (not a bug), skip this check entirely.

Record:
```
- [BLOCKER] Bug without repro steps: no numbered steps to reproduce the issue.
```

### Check 6 — Feature tickets: clarity analysis

If the ticket has the `feature` or `enhancement` label, OR has no `bug` label (default: feature), run these sub-checks. If the ticket is a bug, skip this check entirely.

**6a. Acceptance criteria specificity:**

For each acceptance criterion, check whether it describes a **measurable, observable outcome**. A criterion like "Dashboard shows metrics" fails — which metrics? From what source? For which time period?

Flag as BLOCKER if:
- Any AC uses placeholder language: "shows X", "displays data", "has metrics", "includes information", "provides overview"
- Quantitative claims lack units or thresholds: "faster", "better", "improved" without measurable baseline
- No concrete UI element is named: "shows something" vs. "shows case count by status as a pie chart in the dashboard header"

Record:
```
- [BLOCKER] Vague AC: "{criterion text}" — not a measurable outcome. Clarify: what exactly should the user see/do?
```

**6b. Scope boundary check:**

Determine whether the ticket defines what's **in scope** vs. **out of scope**. A feature ticket without boundaries is a BLOCKER — the implementer can't know where to stop.

- **Clear scope**: ticket lists specific deliverables AND states what's NOT included
- **Ambiguous scope**: ticket lists deliverables but no boundaries (WARNING)
- **No scope**: ticket describes a general area without specific deliverables (BLOCKER)

Record:
```
- [BLOCKER] Scope undefined: ticket describes "{area}" but does not list specific deliverables. What exactly should be built?
- [WARNING] Scope unbounded: deliverables listed but no boundaries defined. What is explicitly NOT in scope?
```

**6c. UI/UX specificity:**

If the feature has a UI component (most features do), check whether the ticket specifies:

- **Which page/component** is affected (e.g., "the handover list page", "the admin user-permission table")
- **What changes** visually (e.g., "add a new column 'Case Count' to the table", "replace the dropdown with radio buttons")
- **What the new behavior** is (e.g., "clicking the row opens a detail panel", "the button is disabled when no items are selected")

If none of these are specified for a UI-affecting feature → BLOCKER.

Record:
```
- [BLOCKER] UI unspecified: feature requires UI changes but no page/component/behavior specified.
- [WARNING] UI partially specified: {what's missing — page? visual change? behavior?}
```

**6d. Edge case awareness:**

Check whether the ticket addresses at least one of these edge case categories:
- **Empty state**: what happens when there's no data? (e.g., "show 'No handovers' message")
- **Error state**: what happens when an operation fails? (e.g., "show error toast on API failure")
- **Permission boundaries**: what happens when a user without the right role tries to access? (e.g., "hide the button for non-attorneys")
- **Loading state**: what does the user see while data loads?

If the ticket mentions NONE of these → WARNING. The implementer will have to guess.

Record:
```
- [WARNING] No edge cases addressed: ticket does not describe empty state, error state, permission boundaries, or loading behavior.
```

**Feature clarity BLOCKER count:** Count how many of 6a, 6b, 6c, 6d produced BLOCKER findings. Feature BLOCKERs contribute to the overall BLOCKER count for status determination.

Record all Check 6 findings.

---

## Content Quality Score

After all checks complete, compute a numeric content quality score from 0-100. Start at 100 and apply deductions:

| Gap | Deduction |
|-----|-----------|
| No acceptance criteria (0 AC) | -30 |
| Thin acceptance criteria (1-2 AC) | -10 |
| No test user or role mentioned | -20 |
| No navigation path | -15 |
| Bug ticket without reproduction steps | -25 |
| Feature ticket with vague/unmeasurable AC | -15 per vague AC (max -30) |
| Feature ticket with undefined scope | -20 |
| Feature ticket with unspecified UI | -15 |
| No test data/setup described (from Check 3) | -15 |
| Scope unidentifiable (from Check 4) | -15 |
| Untestable acceptance criteria | -10 per criterion (max -30) |
| No API contract references (when both FE and BE services mentioned) | -10 |

The score SHALL NOT go below 0. Example: a ticket with 0 AC (-30), no test user (-20), no nav path (-15), no scope (-15) = 100 - 80 = 20.

## Cumulative WARNING Escalation

After all checks complete, count all `[WARNING]` findings across all checks (0-5).

**If WARNING count >= 3 AND no individual `[BLOCKER]` findings exist:**
- The overall status escalates from WARNINGS to BLOCKED
- Record the reason: "Cumulative WARNING threshold: {N} warnings found. Individually minor gaps collectively make this ticket untestable."
- List the top contributing WARNINGs

**If WARNING count < 3 OR any `[BLOCKER]` finding exists:**
- No escalation — individual findings determine the status

A BLOCKER always takes precedence over cumulative escalation. If any BLOCKER exists, the ticket is BLOCKED regardless of WARNING count.

---

## Determine status

Combine individual BLOCKER findings, content quality score, and cumulative WARNING escalation:

1. **Any BLOCKER finding → BLOCKED** (individual BLOCKERs always override)
2. **Score < 40 → BLOCKED** (structurally incomplete)
3. **WARNING count >= 3 (no BLOCKERs) → BLOCKED** (cumulative escalation)
4. **Score 40-69 → WARNINGS** (gaps present but not fatal)
5. **Score >= 70 → CLEAR** (well-specified ticket)

A ticket can have WARNINGs and still be CLEAR if the score is >= 70 and WARNING count < 3.

## Write results to notes.md

Append a `## Readiness Critique` section:

```markdown
## Readiness Critique
**Date:** {today}
**Status:** {BLOCKED | WARNINGS | CLEAR}
**Score:** {0-100 integer}
**WARNING count:** {N}
**BLOCKER count:** {N}

### Deductions
{For each deduction applied, one bullet with gap name and points deducted}

### Findings
{For each finding, one bullet with [BLOCKER] or [WARNING] prefix}

### Missing information (blockers only)
{Bulleted list of what needs to be provided before this ticket can proceed}

### Cumulative escalation
{If cumulative WARNING escalation triggered: reason and contributing WARNINGs. Otherwise omit.}
```

If no findings: write `**Status:** CLEAR`, `**Score:** 100`, `**WARNING count:** 0`, `**BLOCKER count:** 0` with no findings list.

---

## Act on results

### If any BLOCKERs found

1. Post a Linear comment via the Linear MCP comment tool. The comment body depends on invocation source:

**If `--from-audit` (with optional `--source-marker <key>`):**
```
**Ticket flagged — audit found missing information.**

The audit identified this ticket as needing additional information:

{audit finding detail — extracted from args or the checklist item}

The following issues were confirmed by ticket-critique:

{bulleted list of BLOCKER items with plain-language description}

Please update the ticket description or add a comment with the missing details.
Source: {--source-marker value}
```

If `--source-marker` is not provided, derive it from the audit context: `ticket-audit:{TICKET-ID}:needs-info`.

**If `--from-appraise` (standard pipeline flow):**
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
_rc=$?
if [ "$_rc" -ne 0 ]; then
  hb_retry "flow-sh" "fail" "flow.sh needs-info failed (exit ${_rc})" \
    "{\"trigger\":\"needs-info\",\"exit_code\":\"${_rc}\",\"ticket\":\"{TICKET-ID}\"}"
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|META|flow-error|fail|exit ${_rc}: needs-info" >> {LOG_FILE}
fi
```

3. Tell the user:

```
🚫 {TICKET-ID} — BLOCKED (score: {N}/100, {M} BLOCKER(s), {K} WARNING(s))

{list of BLOCKER items, one per line}
{WARNING items, one per line}

Linear updated — `needs-info` label added and comment posted.
Resolve the blockers in the Linear ticket, then re-run /ticket-appraise {TICKET-ID}.
```

4. **Stop.** Do not continue to codebase investigation.

---

### If WARNINGs only (no BLOCKERs, score >= 40, <3 WARNINGs)

Tell the user:

```
⚠️  {TICKET-ID} — WARNINGS (score: {N}/100, {M} warning(s))

{list of WARNING items, one per line}

Continuing with appraisal. Warnings recorded in notes.md under ## Readiness Critique.
```

Continue — do not stop the pipeline.

---

### If CLEAR

Tell the user:

```
✓ {TICKET-ID} — CLEAR (score: {N}/100) — readiness check passed. Continuing.
```

Continue silently.
