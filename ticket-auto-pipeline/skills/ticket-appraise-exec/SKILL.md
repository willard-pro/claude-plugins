---
name: ticket-appraise-exec
description: Artifact executor for a Linear ticket that has already been investigated by /ticket-appraise. Reads the complexity score from notes.md, creates either simple-fix.md or an openspec change, assigns the ticket in Linear, posts the appraisal comment, and moves to Approve state. Run after /ticket-appraise has fully populated notes.md.
---

# Ticket Appraise — Executor

You have been given a ticket ID as the argument (e.g. `WIL-42`). The investigation phase (`/ticket-appraise`) must already be complete — notes.md must contain a `## Complexity` section and a populated `## Initial Investigation` section. Execute the steps below in order.

## Pipeline Preamble

If `--from-auto` is present in the arguments, follow the auto-pipeline preamble in `~/.claude/skills/lib/skill-preamble-auto.md` with parameters: TICKET_ID=<from args>, PHASE=EXEC, HAS_LINEAR_ACCESS=true, LINEAR_OPS=save_comment,list_issues, HAS_LOGGING=true, HAS_HEARTBEAT=true. Before starting, source the project context: `source /tmp/ticket-auto-{TICKET_ID}-env.sh 2>/dev/null || true`. Otherwise, follow the full pipeline preamble in `~/.claude/skills/lib/skill-preamble.md` with parameters: TICKET_ID=<from args>, PHASE=EXEC, FROM_FLAG=none, HAS_LINEAR_ACCESS=true, LINEAR_OPS=save_comment,list_issues, HAS_GUARD=true, HAS_PROJECT_CONTEXT=true, PROJECT_CONTEXT_FIELDS=REPOS_ROOT,ISSUE_PREFIX,BE_SERVICES,BE_TEST_CMD, HAS_LOGGING=true, HAS_HEARTBEAT=true, HAS_STEP_DISPATCH=true, HAS_TASK_TRACKER=true

### Heartbeat points
- **Complexity read**: after extracting complexity from notes.md, write `hb_decision "complexity-read" "info" "complexity: {simple|complex}" '{"score":"{COMPLEXITY}"}'`
- **Artifact created**: after writing simple-fix.md or openspec change, write `hb_decision "artifact-created" "fired" "created {simple-fix|openspec}" '{"type":"{simple-fix|openspec}"}'`
- **Coherence gate**: after complexity-coherence check, write `hb_gate "coherence-check" "ok|fail" "complexity-artifact match|mismatch" '{"declared":"{COMPLEXITY}","artifact":"{simple-fix|openspec}"}'`
- **Regression verdict**: after the regression guard, write `hb_decision "regression-verdict" "fired" "{CONFLICT|ADJACENT|SUPERSEDES|clear}" '{"verdict":"{CONFLICT|ADJACENT|SUPERSEDES|clear}"}'`
- **Linear fallback**: if LINEAR_API_KEY is unset and MCP fallback is used for posting the comment, write `hb_fallback "linear-api" "fired" "using MCP Linear tools" '{"reason":"LINEAR_API_KEY unset"}'`
- **Adversarial review**: after adversarial agent completes, write `hb_decision "adversarial-review" "fired" "{PASS|WARNINGS|BLOCKED}" '{"verdict":"{PASS|WARNINGS|BLOCKED}","issues":"{N}"}'`
- **Verify plan derived**: after Step 3.7 completes, write `hb_gate "verify-plan-derived" "{ok|fail}" "{CLEAR|INSUFFICIENT_INFO}" '{"criteria":"{N}","verifiable":"{M}"}'`
- **Re-appraisal skip**: if re-appraisal detected no changes and steps 5-6 are skipped, write `hb_decision "re-appraisal-skip" "info" "no changes detected, skipping Linear post"`
- **Verification readiness**: after Step 3.8, write `hb_gate "verify-readiness" "{ok|fail}" "{CLEAR|WARNINGS|INCOMPLETE}" '{"missing":"{N}"}'`

### Step dispatch
| `--from-step` value | Skip to | Restore from |
|---------------------|---------|--------------|
| `load-workspace` | Step 3 (create artifact) | notes.md `## Complexity` for COMPLEXITY; context.md for ticket metadata |
| `create-artifact` | Step 3.5 (regression guard) | simple-fix.md or openspec change already exists |
| `regression-guard` | Step 4 (re-appraisal check) | `## ⚠️ Regression Risk` in notes.md if present |
| `verify-plan-derived` | Step 3.7 (derive verification plan) | `## Verification Plan` in notes.md if present |
| `post-linear` | End — skill already complete | — |

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
- [x] Step 3.6: Adversarial review — {PASS | WARNINGS | BLOCKED | skipped (simple)}
- [x] Step 3.7: Verify plan derivation — {CLEAR | INSUFFICIENT_INFO | skipped (simple)}
- [x] Step 3.8: Verification-readiness — {CLEAR | WARNINGS | INCOMPLETE}
- [x] Step 4: Re-appraisal check — {skipped | no marker → continued}
- [x] Step 5: Post Linear comment — {done | skipped (no changes)}
- [x] Step 6: Set state → Approve — {done | skipped (no changes)}
- [x] Step 7: Report — done
TRACE
```

---

## Step 2 — State already set

Ticket was already moved to `Todo` with `claimed` label and `assignee: "me"` by the router (or `ticket-appraise` when run standalone). No action needed — proceed to Step 3.

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

**After writing the artifact, immediately verify the file exists on disk before logging done:**
```bash
# simple path
[ ! -f "{TICKET_DIR}/simple-fix.md" ] && {
  [ -n "$LOG_FILE" ] && echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|META|gate-stop|fail|EXEC_NO_ARTIFACT — Write tool returned error or file missing after write" >> "$LOG_FILE"
  echo "ERROR: simple-fix.md was not written to disk. Check for hook blocks (PreToolUse errors) and retry." >&2
  exit 1
}
```

[ -n "$LOG_FILE" ] && echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|EXEC|create-artifact|done|{simple-fix|openspec}" >> "$LOG_FILE"
cl_write RETRO hint info "artifact path derived from TICKET_DIR={TICKET_DIR} — verify path resolution works when WORKSPACE_ROOT differs from default"

---

## Step 3.4 — Complexity-coherence gate

After writing the artifact, verify that the declared complexity matches what was produced.

Read complexity from notes.md using the shared helper:
```bash
COMPLEXITY=$(bash -c "source ~/.claude/skills/lib/notes-parse.sh; get_complexity '{TICKET_DIR}'")
```

Check artifact presence **by testing the file path directly** — do not rely on grep of notes.md:
```bash
# simple-fix path — must exist as a real file
if [ -f "{TICKET_DIR}/simple-fix.md" ]; then SIMPLE_FIX="{TICKET_DIR}/simple-fix.md"; else SIMPLE_FIX=""; fi
# openspec path
CHANGE_DIR=$(ls -d openspec/changes/*/ 2>/dev/null | grep -i "{ticket-id-lowercase}" | head -1)
OPENSPEC_TASKS="${CHANGE_DIR}tasks.md"
```

Assert coherence:
- If `COMPLEXITY` is empty → gate fires: `COMPLEXITY_ARTIFACT_MISMATCH — notes.md missing **Score:** under ## Complexity`
- If `COMPLEXITY` = `simple` AND `SIMPLE_FIX` is empty → gate fires: `COMPLEXITY_ARTIFACT_MISMATCH — declared simple but no simple-fix.md found`
- If `COMPLEXITY` = `complex` AND (`CHANGE_DIR` is empty OR `OPENSPEC_TASKS` does not exist) → gate fires: `COMPLEXITY_ARTIFACT_MISMATCH — declared complex but no openspec tasks.md found`
- If `COMPLEXITY` = `simple` AND `SIMPLE_FIX` empty but openspec dir exists → gate fires: `COMPLEXITY_ARTIFACT_MISMATCH — declared simple but found openspec artifact (not simple-fix.md)`

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

## Step 3.6 — Adversarial Review (complex tickets only)

**Only run this step if `{COMPLEXITY}` = complex.** If simple, skip to Step 4.

[ -n "$LOG_FILE" ] && echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|EXEC|adversarial-review|start|Spawning adversarial agent" >> "$LOG_FILE"

Spawn a `general-purpose` agent with an adversarial framing. Its sole job is to find what's wrong, missing, or under-specified in the implementation plan — not to confirm it's correct.

**Prompt the agent with:**

```
You are an adversarial reviewer. Your job is to find holes in an implementation plan for a ticket. Be skeptical. Assume nothing. If the plan is solid, say so — but dig hard first.

Ticket: {ISSUE-ID} — {title}
Description: {description}
Labels: {labels}

Read these files in the ticket workspace ({TICKET_DIR}):
1. `notes.md` — investigation findings, complexity, prior art, blast radius
2. The implementation artifact:
   - If `simple-fix.md` exists: read it (this shouldn't happen for complex tickets, but check)
   - Otherwise: read `openspec/changes/{change-name}/design.md`, `openspec/changes/{change-name}/tasks.md`, and any spec files under `openspec/changes/{change-name}/specs/`

Attack the plan from these angles. For each, report either "CLEAR" or what's wrong:

### 1. Edge cases
What inputs/states/conditions does the plan NOT handle? List specific scenarios the plan misses.

### 2. Data assumptions
Does the plan assume data exists where it might not? Are there null/empty/missing cases the plan doesn't address? Is a migration needed but not listed?

### 3. Error handling
What can fail that the plan doesn't account for? Network errors, timeouts, validation failures, concurrent writes?

### 4. Security
Any auth/authz gaps? Injection risks? Data exposure? Missing input validation?

### 5. Side effects
What else breaks if these changes land? Does the plan touch shared utilities, base classes, or Feign clients? Check the blast radius section in notes.md — are all high-risk targets addressed?

### 6. Test coverage
Does the plan include tests for the edge cases above? If it's a backend change and no unit test task exists, flag it.

### 7. Missing steps
What needs to happen that isn't in the plan? Config changes, env vars, DB migrations, cache invalidation, API version bumps?

Report your findings in this exact format:

## Adversarial Review

**Verdict:** PASS | WARNINGS | BLOCKED

### Edge cases
{findings or "CLEAR"}

### Data assumptions
{findings or "CLEAR"}

### Error handling
{findings or "CLEAR"}

### Security
{findings or "CLEAR"}

### Side effects
{findings or "CLEAR"}

### Test coverage
{findings or "CLEAR"}

### Missing steps
{findings or "CLEAR"}

**Summary:** {one sentence verdict with key finding count}

Use BLOCKED if any finding would cause incorrect behavior, data loss, or a security vulnerability if not addressed.
Use WARNINGS if findings are gaps worth noting but not correctness-critical.
Use PASS if the plan is solid across all angles.
```

**When the agent returns:**

Append its output verbatim to notes.md under the `## Adversarial Review` heading. Do not reinterpret or summarise.

**Gate on BLOCKED:**

If the agent's verdict is BLOCKED:

```bash
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|META|gate-stop|fail|ADVERSARIAL_BLOCKED — {ISSUE-ID} adversarial review found blocking issues" >> "$LOG_FILE"
```

Stop with non-zero exit so `ticket-auto` halts the pipeline. Tell the user:

```
⛔  ADVERSARIAL REVIEW — BLOCKED

The adversarial review for {TICKET-ID} found blocking issues.
See ## Adversarial Review in notes.md for details.

Fix the plan, then re-run /ticket-appraise-exec {TICKET-ID} --from-step create-artifact.
```

If WARNINGS or PASS, proceed to Step 4.

[ -n "$LOG_FILE" ] && echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|EXEC|adversarial-review|done|{PASS|WARNINGS|BLOCKED}" >> "$LOG_FILE"

---

## Step 3.7 — Derive Verification Plan

[ -n "$LOG_FILE" ] && echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|EXEC|verify-plan-derived|start|Deriving verification plan" >> "$LOG_FILE"

**Only run this step if `{COMPLEXITY}` = complex.** If simple, skip to Step 3.8.

Derive a structured verification plan from the ticket and plan artifact. This step produces the `## Verification Plan` section in notes.md that tells `ticket-verify` exactly what to test, who tests it, and how to navigate there. If derivation fails, the ticket has insufficient information — push back before implementation.

### Inputs to read

1. **Ticket description and acceptance criteria** — from `context.md` or the Linear issue
2. **Plan artifact** — `simple-fix.md` or `openspec/changes/{change-name}/design.md` + `tasks.md` + spec files
3. **`app-knowledge/SKILL.md`** — for known role constraints, role-based UI rules, and navigation patterns
4. **`test-users.json`** — project-local catalog (not bundled; copy `config/test-users.example.json` to your `TICKETS_ROOT` and populate). Provides available roles and emails. If absent, role scope must be inferred from the ticket and app-knowledge.
5. **`notes.md`** — for investigation findings (`## Initial Investigation`, `## Blast Radius`), adversarial review results, and prior art context

### Derivation steps

#### A. Extract acceptance criteria

Identify every acceptance criterion in the ticket. Each criterion is one row in the per-criterion table. Criteria sources, in order of preference:
1. Numbered AC lines in the ticket description (e.g., "AC-1: ...", "1. ...")
2. Bullet points under an "Acceptance Criteria" or "## Expected Behavior" heading
3. Behavioral descriptions in the plan artifact (implementation tasks that describe user-visible outcomes)
4. If no criteria are identifiable anywhere → the ticket is underspecified. Trigger `VERIFY_PLAN_NO_ROLE_SCOPE` (no criteria to derive roles from).

#### B. Determine role scope per criterion

For each criterion, determine which roles are affected. Use the following hierarchy:

1. **Explicit role mention** (confidence: high): If the criterion text says "as an attorney", "admin only", "for debtors", etc. → role scope is the explicitly mentioned role(s). Scope type is "role-specific".

2. **Code path role gating** (confidence: high): If the plan artifact references auth guards, role-based UI components (`*ngIf="role..."`, `hasRole(...)`), or role-specific service methods → role scope is the roles enumerated in the code. Scope type is "role-specific".

3. **App-knowledge role-based UI rules** (confidence: medium): Cross-reference the feature area against `app-knowledge/SKILL.md`. If the app-knowledge file documents a role constraint for that feature area (e.g., "only admins can access user-permission page") → derive role scope from the known rule. Scope type is "role-specific".

4. **Default heuristic** (confidence: low):
   - **Infrastructure changes** (authentication, routing, database schema, shared utilities, logging, error handling) → "global" (all roles). Scope type is "global".
   - **Feature changes** with no role information → "unknown". This triggers a push-back.

5. **Role scope classification:**
   - **global**: Change affects all roles identically. Affected roles = all roles from `test-users.json`.
   - **role-specific**: Change affects only certain roles. Affected roles = only the roles that can verify the behavior.

#### C. Derive navigation path per criterion

For each criterion, determine how to reach the feature in the browser:

1. **URL in ticket**: Extract any URL path from the ticket description (`/handover/`, `/admin/`, `/user-permission/`, `/organisation/`).
2. **nav-hints match**: Check `nav-hints.md` (or the nav-hints SKILL.md) for the feature area keyword. If a navigation path exists for that area, use it.
3. **Infer from feature area**: Map feature area keywords to known URL patterns:
   - "handover" / "matter handover" → `/handover/`
   - "admin" / "user permission" → `/admin/user-permission`
   - "organisation" / "entity" → `/organisation/`
   - "correspondence" / "portfolio" → `/portfolio/`
4. **Unknown**: If no nav path can be determined → trigger `VERIFY_PLAN_NO_NAV_PATH`.

#### D. Extract expected behavior per criterion

For each criterion, extract what "working correctly" looks like:

1. **Acceptance criteria wording**: The criterion itself describes the expected outcome (e.g., "AC-1: Attorney clicks Send and the handover is created" → expected behavior: "Handover created after attorney clicks Send").
2. **"Expected Behaviour" section**: If the ticket has a dedicated expected behavior section, use it.
3. **Plan artifact behavioral descriptions**: Implementation tasks or design.md may describe user-visible outcomes.
4. **Vague language detection**: If the only description is vague ("works correctly", "is fixed", "should be improved", "functions properly") with no observable outcome → trigger `VERIFY_PLAN_VAGUE_BEHAVIOR`.

#### E. Detect test data requirements per criterion

For each criterion, determine whether pre-existing data is needed:

1. **Pre-existing state assumptions**: Does the criterion assume data exists (e.g., "an existing handover", "a debtor with overdue invoices", "a pending correspondence")?
2. **Seed data references**: Does the plan mention `seed-db`, `data.sql`, fixtures, or setup scripts?
3. **Setup steps**: Are there documented steps to create the required data (e.g., "Create a handover first via ...")?
4. If data is required but no setup mechanism is documented → trigger `VERIFY_PLAN_NO_TEST_DATA`.

### Push-back triggers

If any single criterion cannot be fully derived, halt the pipeline. The following gate-stop codes apply:

| Condition | Gate-stop code |
|-----------|---------------|
| Role scope unknown for any criterion | `VERIFY_PLAN_NO_ROLE_SCOPE` |
| Navigation path unknown for any criterion | `VERIFY_PLAN_NO_NAV_PATH` |
| Expected behavior vague for any criterion | `VERIFY_PLAN_VAGUE_BEHAVIOR` |
| Test data required but no setup documented | `VERIFY_PLAN_NO_TEST_DATA` |

**In `--from-auto` mode:** Push-back halts the pipeline immediately:
```bash
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|META|gate-stop|fail|{GATE-STOP-CODE} — {reason}" >> "$LOG_FILE"
```
Stop with non-zero exit so `ticket-auto` halts.

**In interactive mode (no `--from-auto`):** Warn the user but allow override:
```
⚠️  VERIFICATION PLAN — {GATE-STOP-CODE}

The verification plan for {TICKET-ID} could not be fully derived:

{list of criteria and what's missing}

The pipeline cannot verify this ticket reliably. Options:
1. Update the ticket with the missing information and re-run
2. Override and proceed anyway (verification may be incomplete)

Re-run: /ticket-appraise-exec {TICKET-ID} --from-step verify-plan-derived
```

If the user chooses to override, proceed to Step 3.8 with the partial plan. **Write the partial verification plan to notes.md first** — use the same schema below, marking unverifiable criteria with `✗` in the Verifiable column and noting the missing dimension in the relevant column (e.g., "unknown" for role scope, "not specified" for nav path).

### Write verification plan to notes.md

After derivation (full success or partial with override), append a `## Verification Plan` section to notes.md. If a `## Verification Plan` section already exists from a prior run, replace it.

```markdown
## Verification Plan
**Date:** {today}
**Derived by:** ticket-appraise-exec Step 3.7
**Overall role scope:** {global | role-specific: {roles} | mixed}

### Role Scope Assessment

| Feature area | Affected roles | Scope type | Confidence | Basis |
|-------------|---------------|-----------|-----------|-------|
| {feature area} | {role list or "all"} | {global|role-specific} | {high|medium|low} | {explicit mention|code path|app-knowledge|heuristic} |

### Per-Criterion Verification

| # | Criterion | Role scope | Navigation path | Test data needed | Expected behavior | Verifiable |
|---|----------|-----------|----------------|-----------------|-------------------|-----------|
| 1 | {criterion text} | {global|role: {roles}} | {URL path or menu path} | {none|{data description}} | {expected outcome} | {✓|✗} |
| 2 | ... | ... | ... | ... | ... | ... |
```

**Verifiable column:** `✓` if all four dimensions (role scope, nav path, expected behavior, test data) are populated. `✗` if any is missing — but note that missing dimensions trigger push-back above, so this should only appear in interactive override mode.

### Wiki ingestion — Role Scope Registry

After writing the verification plan, append role scope findings to `app-knowledge/SKILL.md` under a `## Role Scope Registry` section. This builds a cumulative knowledge base for future appraisals.

**Entry format:**
```markdown
### {TICKET-ID} — {feature area}
- **Role scope:** {global | role-specific: {roles}}
- **Confidence:** {high|medium|low}
- **Source:** verification plan derivation (ticket-appraise-exec Step 3.7)
- **Date:** {today}
```

**Section creation:** If `app-knowledge/SKILL.md` does not contain a `## Role Scope Registry` section, create it at the end of the file before appending the entry.

**Duplicate handling:** If a prior role scope entry exists for the same ticket ID (re-appraisal), strike through the old entry (`~~...~~`) and append the new entry below it.

**Non-blocking:** Wiki write failure is non-blocking. If `app-knowledge/SKILL.md` cannot be written (permissions, disk full), log a warning and continue:
```bash
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|EXEC|verify-plan-derived|skip|Wiki write failed: {reason} — continuing" >> "$LOG_FILE"
```

### Heartbeat

After derivation completes:
- **Success (all criteria verifiable):** `hb_gate "verify-plan-derived" "ok" "CLEAR" '{"criteria":"{N}","verifiable":"{M}"}'`
- **Partial with override (interactive only):** `hb_gate "verify-plan-derived" "ok" "OVERRIDE" '{"criteria":"{N}","verifiable":"{M}","override":"true"}'`
- **Push-back (any criterion unverifiable, auto mode):** `hb_gate "verify-plan-derived" "fail" "INSUFFICIENT_INFO" '{"criteria":"{N}","verifiable":"{M}"}'`

[ -n "$LOG_FILE" ] && echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|EXEC|verify-plan-derived|done|{CLEAR|INSUFFICIENT_INFO}" >> "$LOG_FILE"

Proceed to Step 3.8.

---

## Step 3.8 — Verification-Readiness Gate

[ -n "$LOG_FILE" ] && echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|EXEC|verify-readiness|start|Checking plan for verification prerequisites" >> "$LOG_FILE"

Check the plan artifact for 4 prerequisites required to verify the ticket:

1. **Test user** — an email, `**User:**` field, role mention, or actual test user from the test user catalog
2. **Navigation target** — a URL path (`/handover/`, `/admin/`), "Navigate to" instruction, or explicit menu path
3. **Expected behavior** — a description of what "working" looks like (from acceptance criteria or a `## Expected Behavior` section)
4. **Environment prerequisites** — any data setup, seed data references, or service dependencies needed before testing

### How to check

**Primary path — read the derived verification plan:**
If `{TICKET_DIR}/notes.md` contains a `## Verification Plan` section with a populated per-criterion table, extract the 4 prerequisites directly from the derived plan's table columns:
1. **Test user** — from the "Role scope" column (if role-specific, the named role is the test user)
2. **Navigation target** — from the "Navigation path" column
3. **Expected behavior** — from the "Expected behavior" column
4. **Environment prerequisites** — from the "Test data needed" column

If any column is empty or missing for a criterion, count that prerequisite as missing for that criterion. If all criteria have the prerequisite populated, count it as found.

**Fallback — scan the plan artifact directly:**
If no `## Verification Plan` section exists in notes.md (backward compat for old tickets), scan the plan artifact:
- If `{COMPLEXITY}` = simple: read `{TICKET_DIR}/simple-fix.md`
- If `{COMPLEXITY}` = complex: find the openspec change dir and read `design.md` and `tasks.md`

For each prerequisite, scan the artifact content:
1. **Test user**: look for an email pattern, `**User:**`, "as an [role]", "log in as", "test as", or a name matching the test user catalog (`test-users.json` — project-local, resolved via `resolve_test_user_catalog`). Also check if the `## Verification Readiness` section from notes.md already has one from a prior run.
2. **Navigation target**: look for URL paths, "Navigate to", "Go to", menu paths, or feature area labels that map to known nav-hints entries.
3. **Expected behavior**: look for acceptance criteria, `## Expected Behavior` sections, or descriptions of observable outcomes. If the artifact references the ticket's AC (e.g., "Verify AC-1: ..."), that counts.
4. **Environment prerequisites**: look for data setup steps, seed data references (`seed-db`, `data.sql`), service dependencies, or pre-existing state descriptions.

### Score

Count how many of the 4 prerequisites are missing:

| Missing | Status |
|---------|--------|
| 0 | CLEAR — all verification prerequisites present |
| 1 | WARNINGS — one prerequisite missing, still verifiable |
| 2+ | INCOMPLETE — too many gaps for reliable verification |

**Backward compat exception:** For tickets without structured plan sections (single-file simple-fix.md with minimal structure), a single missing flag produces WARNINGS, not INCOMPLETE. Only go to INCOMPLETE when 2+ are missing.

### Act on result

**If CLEAR or WARNINGS:**
Proceed to Step 4. Record in the heartbeat:
```
hb_gate "verify-readiness" "ok" "{CLEAR|WARNINGS}" "{\"missing\":\"{N}\"}"
```

**If INCOMPLETE:**

If `--from-auto` is in the arguments:
```bash
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|META|gate-stop|fail|VERIFY_READINESS_INCOMPLETE — plan missing {N} verification prerequisites: {list}" >> "$LOG_FILE"
```
Stop with non-zero exit.

If interactive (no `--from-auto`):
```
⚠️  VERIFICATION-READINESS — INCOMPLETE

The plan for {TICKET-ID} is missing {N} verification prerequisites:

{list of missing prerequisites}

Please update the plan artifact with these details, then re-run
/ticket-appraise-exec {TICKET-ID} --from-step create-artifact.
```

### Write results to notes.md

Append a `## Verification Readiness` section to notes.md:

```markdown
## Verification Readiness
**Date:** {today}
**Status:** {CLEAR | WARNINGS | INCOMPLETE}

| Prerequisite | Status | Source |
|-------------|--------|--------|
| Test user | {found | missing} | {where found or "not specified"} |
| Navigation target | {found | missing} | {where found or "not specified"} |
| Expected behavior | {found | missing} | {where found or "not specified"} |
| Environment prerequisites | {found | missing} | {where found or "not specified"} |
```

If the section already exists from a prior re-run, replace it.

[ -n "$LOG_FILE" ] && echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|EXEC|verify-readiness|done|{CLEAR|WARNINGS|INCOMPLETE}" >> "$LOG_FILE"

---

## Step 4 — Check for re-appraisal skip (after Step 3.8)

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
_rc=$?
if [ "$_rc" -ne 0 ]; then
  hb_retry "flow-sh" "fail" "flow.sh appraise-complete failed (exit ${_rc})" \
    "{\"trigger\":\"appraise-complete\",\"exit_code\":\"${_rc}\",\"ticket\":\"{TICKET-ID}\"}"
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|META|flow-error|fail|exit ${_rc}: appraise-complete" >> {LOG_FILE}
fi
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

{If adversarial review ran:}
**Adversarial review:** {PASS | WARNINGS} — {N issues found, or "no issues"}
{If WARNINGS: see ## Adversarial Review in notes.md before implementing}

**Open questions:**
{bullets or "None"}

**Next step:** {first action}

Linear updated — assigned to you, status → Approve + `claimed` (awaiting approval).

> **Full state lifecycle:**
> Todo + `claimed` (appraise) → Approve + `claimed` (end of exec) → Ready + `approved` (human approves) → Review (after PR) → Done

Run `/ticket-implement {TICKET-ID}` once the `approved` label is added in Linear.
```

[ -n "$LOG_FILE" ] && echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|EXEC|handoff|done|Reported to user" >> "$LOG_FILE"
