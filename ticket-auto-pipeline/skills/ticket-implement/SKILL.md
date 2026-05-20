---
name: ticket-implement
description: Full implementation workflow for a Linear ticket that has been approved. Loads the ticket workspace, moves to Ready, sets up branches on affected repos, runs the implementation (simple-fix or openspec), commits, and pushes. PR creation and close-out are gated by /ticket-verify. Use when the user says "/ticket-implement <ID>", "implement ticket <ID>", "start implementing <ID>", or "work on <ID>" after appraisal/approval is done.
---

# Ticket Implement

You have been given a ticket ID as the argument (e.g. `WIL-42`). Execute the full implementation sequence below in order.

**BASE BRANCH:** Always `develop`. Branch from `develop`, PR into `develop`. Never use `main` or any other base. If `develop` doesn't exist locally, `git fetch origin && git checkout -b develop origin/develop`.

## Pipeline Preamble

Follow the pipeline preamble in `~/.claude/skills/lib/skill-preamble.md` with parameters: TICKET_ID=<from args>, PHASE=IMPLEMENT, FROM_FLAG=--from-auto, EXTRA_GUARD=base-branch, HAS_LINEAR_ACCESS=true, LINEAR_OPS=get_issue,save_comment, HAS_GUARD=true, HAS_PROJECT_CONTEXT=true, PROJECT_CONTEXT_FIELDS=REPOS_ROOT,ISSUE_PREFIX,BE_SERVICES,BE_TEST_CMD,FE_TEST_CMD, HAS_LOGGING=true, HAS_HEARTBEAT=true, HAS_STEP_DISPATCH=true, HAS_TASK_TRACKER=true

### Heartbeat points
- **Test command**: if BE_TEST_CMD found, write `hb_heartbeat "test-command" "BE_TEST_CMD configured" '{"cmd":"<cmd>"}'`; if absent, write `hb_heartbeat "test-command" "skip" "no BE_TEST_CMD"`
- **Artifact path**: after detecting the plan artifact, write `hb_decision "artifact-path" "info" "artifact detected" '{"type":"simple-fix|openspec"}'`
- **Implementation mode**: after detect-path, write `hb_decision "implementation-mode" "fired" "simple|openspec" '{"mode":"..."}'`

### Step dispatch
**Context restoration when skipping early steps:**
- Branch name: read from notes.md `### ... — pre-implementation checkpoint` entry or from `IMPLEMENT|checkout-branch|done|` in `$LOG_FILE`.
- Implementation mode: read from `IMPLEMENT|detect-path|done|` in `$LOG_FILE` (value: `simple-fix` or `openspec`).
- Affected repos: re-derive from notes.md `Initial Investigation` section and CLAUDE.md table.

| `--from-step` value | Skip to | Restore |
|---------------------|---------|---------|
| `check-approval` | Step 2 (detect path) | ticket dir from find; notes.md and context.md |
| `detect-path` | Step 3 (checkout branch) | mode from log `detect-path\|done` entry |
| `checkout-branch` | Step 4 (implement) | branch from notes.md checkpoint; mode from log |
| `implement` | Step 4b (write tests) | changed files from `git diff --name-only develop` |
| `run-tests` | Step 4b code-review | — |
| `code-review` | Step 5 (commit/push) | — |
| `commit-push` | End — skill already complete | — |

---

## Step 0.6 — Create task tracker

Create a TaskCreate for every remaining step (Steps 1 through 6). Each task subject = the step heading. After each step is fully done (including sub-steps like 4b, 4c), mark it completed with TaskUpdate. At session end, write a trace file:

```bash
cat > {ticket-dir}/implement-session.md << 'TRACE'
# implement session — {ISSUE-ID}
**Date:** {today}
**Branch:** {branch-name}
**Mode:** {simple-fix | openspec: <name>}
**Outcome:** {Smooth|Rough|Hard}

## Step trace
- [x] Step 1: Approval guard + load workspace — approved
- [x] Step 2: Set Ready + identify path — {mode}
- [x] Step 3: Checkout and branch — {branch}
- [x] Step 4: Implement — {N} files changed
- [x] Step 4b: Tests + code review — {pass/failures}
- [x] Step 4c: Rate complexity — {Smooth|Rough|Hard}
- [x] Step 5: Commit, push, PR — {PR URL}
- [x] Step 6: Close out — Review
TRACE
```

---

## Step 1 — Approval guard + load workspace

[ -n "$LOG_FILE" ] && echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|IMPLEMENT|check-approval|start|Checking authorization" >> "$LOG_FILE"

Fetch the ticket from Linear using the Linear access strategy (bash `get_issue` when `LINEAR_API_KEY` is set, MCP fallback otherwise):

**Determine authorization:**

- If `approved` label is present → authorized. This is a fresh implementation or human-re-approved rework.
- If `approved` is absent but `rejected` is present → authorized for UAT rework. Note: "UAT rework cycle — `rejected` label signals authorization for rework. Proceeding to Step 2 which will read the REMEDIATION_BRIEF from the plan."
- If NEITHER `approved` nor `rejected` is present → stop and report:
  ```
  ⛔ {TICKET-ID} not approved yet. Add the `approved` label in Linear (or the `rejected` label for UAT rework), then re-run.
  ```

**When authorized,** find the local directory:
```bash
find . -type d -name "{TICKET-ID}*"
```

If not found → tell the user to run `/ticket-appraise {TICKET-ID}` first. Stop here.

Read `context.md` and `notes.md`.

**Regression Risk gate:** Check notes.md for a `## ⚠️ Regression Risk` section.

If it exists AND `**Status:** UNACKNOWLEDGED` is present → stop immediately:

```
⚠️  Implementation blocked — unacknowledged regression risk.

Open notes.md for {TICKET-ID} and review the ## Regression Risk section.
Then change:
  **Status:** UNACKNOWLEDGED
to:
  **Status:** ACKNOWLEDGED

Re-run /ticket-implement {TICKET-ID} after acknowledging.
```

If the section is absent, or Status is `ACKNOWLEDGED` → proceed normally.

Append a session checkpoint:
```markdown
### {today's date} — implementation session started
- Authorization: {approved | rejected (UAT rework)}. Repos and branch to be confirmed in Step 2.
```

[ -n "$LOG_FILE" ] && echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|IMPLEMENT|check-approval|done|Authorized" >> "$LOG_FILE"

---

## Step 2 — Identify implementation path

Log the step start:
```bash
[ -n "$LOG_FILE" ] && echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|IMPLEMENT|detect-path|start|Identifying implementation path" >> "$LOG_FILE"
```

From `notes.md` and `context.md`, identify affected repos. Cross-reference with the CLAUDE.md codebase table for full paths.

**Implementation path:**
```bash
find . -name "simple-fix.md" -path "*{TICKET-ID}*"
```
- Found → mode **simple-fix**. Read the file now.
- Not found → mode **openspec**. Locate the change:
  ```bash
  ls openspec/changes/ | grep -i "{ticket-id-lowercase}"
  ```

**Activate persona** based on the `Layer` column in CLAUDE.md for each affected repo. For `FE+BE` monorepos, use the layer boundary table to classify by actual files touched:

- All `FE` → `/buddy:persona-frontend`
- All `BE` / `infra` → `/buddy:persona-backend`
- Mixed → activate both; switch at the FE/BE boundary. Note the boundary in `notes.md`.

[ -n "$LOG_FILE" ] && echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|IMPLEMENT|detect-path|done|{simple-fix|openspec}" >> "$LOG_FILE"

---

## Step 2.5 — Detect verification re-run

Count all `### {date} — Verification FAIL` entries in `notes.md`. Count all `## Verification #` sections in the plan artifact (`simple-fix.md` or openspec `tasks.md`).

- **If `FAIL_COUNT` = 0** → gate skipped (no brief expected). Proceed to Step 3.
- **If `FAIL_COUNT` <= `SECTION_COUNT`** → all failures already addressed. Proceed to Step 3.
- **If `FAIL_COUNT` > `SECTION_COUNT`** → unaddressed failures remain. Before reading the section, assert the closing marker:

**REMEDIATION_BRIEF integrity check:**
```bash
# Find the last ## Verification # section in the plan
LAST_SECTION_LINE=$(grep -n '^## Verification #' "$PLAN" | tail -1 | cut -d: -f1)
# Extract the non-blank lines of that section up to the next ## heading or EOF
SECTION_TAIL=$(awk "NR>$LAST_SECTION_LINE && /^## / {exit} NF" "$PLAN" | tail -1)
```
If `SECTION_TAIL` ≠ `<!-- /REMEDIATION_BRIEF -->`:
```bash
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|META|gate-stop|fail|REMEDIATION_BRIEF_TRUNCATED — marker missing in: $PLAN" >> "$LOG_FILE"
```
Stop. Report: `{TICKET-ID} pipeline halted: REMEDIATION_BRIEF closing marker missing in ${PLAN}. The verify step may have been interrupted mid-write. Re-run ticket-verify to regenerate the brief.`

On marker present proceed to process the failures:
1. Count existing `## Verification #` sections in the plan to determine N (0 if none)
2. Extract from notes.md: env, failed step, expected, observed, console errors
3. Append to the plan artifact (`simple-fix.md` or `openspec tasks.md`):

```markdown
## Verification #{N+1}

**Date:** {date from notes.md}
**Environment:** {env}
**Failed at step:** {N} — {step description}

### Gaps
| # | Expected | Observed |
|---|----------|----------|
| 1 | {expected} | {observed} |

### Diagnostics
**Console errors:** {count or "none"}
```

4. Append to `notes.md`:
```markdown
### {today's date} — verification re-run #{N+1}
- Addressing verification failures from {date}. Plan updated.
```

When implementing, the `## Verification #N` section is treated the same as `## PR Review #N` — each gap must be resolved before the implementation round is complete.

### Part B — Extract REMEDIATION_BRIEF from the Verification section

After appending the Gaps table, read the `## Verification #{N+1}` section from the plan artifact. If additional REMEDIATION_BRIEF fields are present (written by `ticket-verify` Step 7c5), extract them into the implementation context.

Parse these headings from the `## Verification #{N+1}` section:

| Heading in plan | Source |
|-----------------|--------|
| `### Suggested Fix` | SUGGESTED_FIX — verifier's hypothesis about root cause |
| `### Expected` | WHAT_WAS_EXPECTED |
| `### Observed` | WHAT_FAILED |
| `### Diagnostics` | CURRENT_URL, CONSOLE_ERRORS, SNAPSHOT_EXCERPT |
| `### Context Files` | CONTEXT_FILES |

**If the section contains only a Gaps table** (pre-Change-2 format): the richer context is not available. Proceed with gaps-only mode as before.

**If REMEDIATION_BRIEF fields are present**, emit this context block:

```
## UAT Rework Context — {TICKET-ID}

**Suggested Fix (from ticket-verify):**
{SUGGESTED_FIX}

**What was expected:**
{WHAT_WAS_EXPECTED}

**What failed:**
{WHAT_FAILED}

**Console errors:** {CONSOLE_ERRORS}
**URL at failure:** {CURRENT_URL}

**Context files:** {CONTEXT_FILES}

Use the Suggested Fix as the starting point for rework. Cross-reference with the original plan and any PR Review gaps.
```

The SUGGESTED_FIX provides the implementer with the verifier's hypothesis about the root cause, allowing targeted rework without re-investigating from scratch. The `## Verification #N` gaps must still be resolved alongside any `## PR Review #N` gaps. These are treated identically — each must be addressed before the implementation round is complete.

---

## Step 3 — Checkout and branch

[ -n "$LOG_FILE" ] && echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|IMPLEMENT|checkout-branch|start|Creating branch" >> "$LOG_FILE"

For each affected repo:
```bash
cd {repo-path} && git checkout develop && git pull
```

Stop and ask the user if any repo has uncommitted changes or conflicts.

**Branch name:** `{prefix}{TICKET-ID}-{title-slug}` (max 60 chars)
- Label `bug` → `bugfix/`; label `feature` or `enhancement` → `feature/`; default → `feature/`

Create on every affected repo:
```bash
cd {repo-path} && git checkout -b {branch-name} 2>/dev/null || git checkout {branch-name}
```

Append to `notes.md`:
```markdown
### {today's date} — pre-implementation checkpoint
- Repos: {list} | Branch: {branch-name} | Mode: {simple-fix | openspec: <name>}
```

[ -n "$LOG_FILE" ] && echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|IMPLEMENT|checkout-branch|done|{branch-name}" >> "$LOG_FILE"

---

## Step 4 — Implement

[ -n "$LOG_FILE" ] && echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|IMPLEMENT|implement|start|Implementing changes" >> "$LOG_FILE"

**Use Serena for all real-time code navigation during editing — mandatory for both modes.** Before any file is read or edited: symbol search or go_to_definition to locate the target, find_references to check downstream impact. Read only what Serena has pinpointed — never scan whole files.

**Before editing, run GitNexus blast radius:** Call `mcp__gitnexus__impact` on each target symbol from the plan. Compare the result's d=1 (WILL BREAK) callers against the affected files listed in the plan. If any d=1 symbol is NOT in the plan, append it to the implementation scope. If GitNexus is unavailable, log a warning and proceed — never block on it.

### Simple-fix mode

Work through each change in `simple-fix.md` in order.

### Openspec mode

Spawn a `general-purpose` agent to apply the change and return a difficulty summary. The branch is already checked out — no isolation needed.

**Prompt the agent with:**
```
Apply the openspec change `{change-name}` by running `/opsx:apply` in the repo at `{repo-path}`. Follow its instructions fully.

Use Serena for all real-time code navigation during editing. Before any file is read or edited: symbol search or go_to_definition to locate the target, find_references to check downstream impact. Read only what Serena has pinpointed — never scan whole files. Before starting edits, run GitNexus `impact()` on target symbols to map blast radius.

Track these metrics as you work:
- fix_cycles: how many times did you need to fix and re-run tests?
- discovery_rounds: how many rounds of unexpected investigation beyond the plan were needed?
- plan_deviation: "followed" (as-written) | "adapted" (one step changed) | "rewrote" (approach changed)
- changes_made: list of "file:line — what changed" entries

When complete, return ONLY this JSON (no other text):
{
  "fix_cycles": N,
  "discovery_rounds": N,
  "plan_deviation": "followed|adapted|rewrote",
  "changes_made": ["file:line — what changed"],
  "notes": "anything unexpected encountered"
}
```

**Save the returned JSON as `{DIFFICULTY_SUMMARY}` — Step 4c uses it.**

[ -n "$LOG_FILE" ] && echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|IMPLEMENT|implement|done|{N} files changed" >> "$LOG_FILE"

---

## Step 4b — Write tests + run tests + code review (mandatory for all modes)

### Write unit tests

**After implementation is complete, write tests covering the changed logic.** This is mandatory — do not skip.

- **If `{BE_TEST_CMD}` is defined and the ticket touches a BE repo:** Write tests in the repo's test directory. Create `tests/` if it doesn't exist. Test any new or modified functions/methods, including error paths. Install the test framework if needed (e.g. `pip install pytest`).
- **If `{FE_TEST_CMD}` is defined and the ticket touches a non-BE repo:** Write tests alongside the changed files or in `__tests__/`. Test new or modified components, API routes, and utility functions. Install the test framework if needed.
- **If neither is defined:** Skip all tests. Do not invent or install a test framework. Note "no test command configured" in the session log and move on.
- **DB migrations:** If the change includes a migration, write a test that verifies the new schema (column exists, index exists, constraint works).

### Run tests

[ -n "$LOG_FILE" ] && echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|IMPLEMENT|run-tests|start|Running tests" >> "$LOG_FILE"

```bash
# BE repos (only if BE_TEST_CMD is defined)
cd {repo-path} && {BE_TEST_CMD}

# FE repos (only if FE_TEST_CMD is defined)
cd {repo-path} && {FE_TEST_CMD}
```

If tests fail → fix the code or the tests, re-run. Do not proceed until all tests pass. Skip a test command only if its corresponding variable is not defined in CLAUDE.md.

[ -n "$LOG_FILE" ] && echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|IMPLEMENT|run-tests|done|Tests pass" >> "$LOG_FILE"

### Code review

[ -n "$LOG_FILE" ] && echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|IMPLEMENT|code-review|start|Reviewing changes" >> "$LOG_FILE"

Spawn a `general-purpose` agent for each repo with changes. Pass it:
- The repo path and branch name
- The list of changed files (`git diff --name-only develop`)
- The ticket ID and a one-sentence description of what was implemented
- This exact instruction: **Invoke `Skill("superpowers:requesting-code-review")` — use the Skill tool with this exact name. Do NOT use any other review tool, plugin, or slash command.**

The agent returns a findings list. **All findings at any severity are blockers.** For each finding: fix the code, re-run unit tests, then re-spawn the agent with the updated file list. Do not proceed to commit until the review returns clean.

[ -n "$LOG_FILE" ] && echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|IMPLEMENT|code-review|done|Clean" >> "$LOG_FILE"

---

## Step 4c — Rate actual complexity and update Linear label

Assign an outcome label based on implementation difficulty:

| Label | Criteria |
|---|---|
| `Smooth` | Plan was accurate, followed without deviation, tests passed first run, no extra discovery needed |
| `Rough` | 1–2 fix cycles needed, or minor gaps required small additional investigation |
| `Hard` | Multiple fix/test cycles, significant extra discovery, or the plan was materially incomplete |

Rate from `{DIFFICULTY_SUMMARY}` (openspec) or in-context history (simple-fix). Take the worst signal: fix cycles (0/1–2/3+ → Smooth/Rough/Hard), discovery rounds (none/minor/significant), plan deviation (followed/adapted/rewrote).

**Update Linear:**

```
/ticket-flow {TICKET-ID} implement-outcome --data outcome={Smooth|Rough|Hard}
```

This adds the outcome label while preserving all existing labels including `simple`/`complex`. The pairing of predicted complexity and actual outcome is preserved for training and history.

**Mismatch retrospective (only if prediction and outcome disagree):**

A mismatch means the appraisal missed something. When `simple` + `Rough`/`Hard`, or `complex` + `Smooth`:

1. **Post a Linear comment** via the Linear access strategy (bash `save_comment` when `LINEAR_API_KEY` is set, MCP fallback otherwise):
   ```
   **Complexity mismatch** — predicted `{simple|complex}`, ran `{Smooth|Rough|Hard}`.

   **What the investigation missed:**
   {Specific gap: was the data not where the plan said? Was there an undiscovered dependency? Did a test reveal an assumption was wrong? Be concrete.}

   **What would have caught it:**
   {One sentence: the question the appraise investigation should have asked but didn't.}
   ```

2. **Save to claude-mem** — write a feedback memory capturing the pattern so future appraisals on similar tickets benefit:
   - Component or service area involved
   - What signal the complexity sweep missed
   - What to look for next time in that area

3. **Append wiki errata (only if wiki was used for this ticket):** Check notes.md for a `Wiki bootstrap:` line under Initial Investigation. If found, open the referenced wiki flow file(s) and append an errata entry at the end:

   ```markdown
   ### {TICKET-ID} — {Hard | Rough} (predicted {simple | complex})
   **Date:** {today's date}
   **Gap:** {What was missed: undiscovered Feign dependency? Entity field not in wiki? Method signature wrong?}
   **Root cause:** {Why the wiki didn't catch it — missing section, stale path, assumption in flow description}
   **Fix:** {What to add/change in this wiki file to prevent the next ticket from hitting the same gap}
   ```

   - If the file already has an `## Errata` section, append to it. If not, create the section.
   - If multiple wiki files were loaded, append to the most specific flow file. If the gap is cross-service (e.g. credit-report → BOM interaction), append to both.
   - If no `Wiki bootstrap:` line exists, skip — the mismatch was not wiki-related.

---

## Step 5 — Commit and push

[ -n "$LOG_FILE" ] && echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|IMPLEMENT|commit-push|start|Committing and pushing" >> "$LOG_FILE"

For each affected repo:
1. Run `/commit-commands:commit` to create the commit.
2. **Pre-push safety check — GitNexus `detect_changes`:** Call `mcp__gitnexus__detect_changes` with `scope: "compare"` and `base_ref: "develop"`. This maps the full branch diff against the knowledge graph.
   - If the result shows `risk_level: "high"` or `"critical"`, OR affected execution flows outside the ticket's stated scope: append a warning to the handoff output.
   - If GitNexus is unavailable: log a warning and proceed — never block on it.
3. Push: `git push origin {branch-name}`

### Commit title template

```
type(TICKET-ID): imperative-mood description
```

| Type | When |
|------|------|
| `feat` | Feature |
| `fix` | Bug |
| `refactor` | Refactor |
| `chore` | Tooling, deps, config |

The ticket ID is **mandatory** — no bare descriptive titles.

**Examples:**
- `feat(WIL-34): add hash-based duplicate document detection`
- `fix(WIL-35): add SSE log replay buffer for late-connecting clients`

**Append to `notes.md`:**
```markdown
### {today's date} — committed
- Branch: `{branch-name}` on {repo}
- Pushed — awaiting verification before PR
```

**Report:**
```
## {TICKET-ID} committed

Branch: `{branch-name}` pushed to {repo}.
```

No PR created yet. No Linear state change. The calling pipeline (`ticket-auto` or user) handles verification and PR creation.

[ -n "$LOG_FILE" ] && echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|IMPLEMENT|commit-push|done|Pushed {branch-name}" >> "$LOG_FILE"
