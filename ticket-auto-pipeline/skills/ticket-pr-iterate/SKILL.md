---
name: ticket-pr-iterate
description: Incorporates PR review findings back into the implementation plan. Reads the ticket-pr-review comment (or pr-review-session.md), parses gap items, appends a versioned PR Review #N section to the plan artifact, and resets Linear state so ticket-implement can pick up the changes. Use when the user says "/ticket-pr-iterate <ID>", "iterate on PR feedback for <ID>", or "fix review gaps for <ID>".
---

# Ticket PR Iterate

You have been given a ticket ID as the argument (e.g. `WIL-42`). Execute the steps below in order. This skill reads PR review findings and updates the implementation plan so the gaps can be addressed in a new implementation round.

## Pipeline Preamble

If `--from-auto` is present in the arguments, follow the auto-pipeline preamble in `~/.claude/skills/lib/skill-preamble-auto.md` with parameters: TICKET_ID=<from args>, PHASE=PR-REVIEW, HAS_LINEAR_ACCESS=false, HAS_LOGGING=true, HAS_HEARTBEAT=true, EMITS_PHASE_RESULT=false.

**Why `EMITS_PHASE_RESULT=false`** (recorded decision, `rlvr-phase-result-contract` task 5.6): this skill runs inside the PR iteration loop but it is not a verdict-producing phase — it applies requested changes and hands back to IMPLEMENT → VERIFY → PR-REVIEW, all three of which emit. Its own outcome is therefore always re-validated downstream. It also runs under `PHASE=PR-REVIEW` with no verifier of its own, so a block from here would carry the same `(phase, verifier)` pair as the real review and no consumer could tell the two apart. Excluded deliberately, not by omission. Before starting, source the project context: `source /tmp/ticket-auto-{TICKET_ID}-env.sh 2>/dev/null || true`. Otherwise, follow the full pipeline preamble in `~/.claude/skills/lib/skill-preamble.md` with parameters: TICKET_ID=<from args>, PHASE=PR-REVIEW, FROM_FLAG=none, HAS_LINEAR_ACCESS=false, HAS_GUARD=true, HAS_PROJECT_CONTEXT=true, PROJECT_CONTEXT_FIELDS=REPOS_ROOT,ISSUE_PREFIX, HAS_LOGGING=true, HAS_HEARTBEAT=true, HAS_STEP_DISPATCH=true, HAS_TASK_TRACKER=true

### Heartbeat points
- **Findings source**: after locating review findings, write `hb-wrap.sh decision "findings-source" "info" "findings from {PR|session-file}" '{"source":"{pr|session-file}"}'`
- **Session fallback**: if no PR found and falling back to pr-review-session.md, write `hb-wrap.sh fallback "pr-review-data" "fired" "no PR found, using session file" '{"reason":"gh pr view returned no results"}'
- **Verdict already passing**: if verdict is ✅ (no gaps), write `hb-wrap.sh decision "iteration-skip" "info" "PR review already passed, no iteration needed"`
- **Iteration guard**: if N > 3 (too many iterations), write `hb-wrap.sh gate "iteration-limit" "fail" "iteration #{N} exceeds limit" '{"iterations":"{N}"}'`
- **Gap count**: after parsing gaps, write `hb-wrap.sh decision "gap-count" "fired" "{N} gaps to address" '{"count":"{N}"}'`
- **Artifact updated**: after updating the plan artifact, write `hb-wrap.sh decision "plan-updated" "fired" "appended PR Review #{N} to {ARTIFACT}" '{"artifact":"{ARTIFACT}","iteration":"{N}"}'`

### Step dispatch
| `--from-step` value | Skip to | Restore from |
|---------------------|---------|--------------|
| `iterate-load` | Step 2 (find findings) | workspace already loaded; notes.md and context.md available |
| `iterate-findings` | Step 4 (update plan) | gaps already parsed; {N} from existing `## PR Review #` sections in plan |
| `iterate-plan` | Step 5 (update notes) | plan artifact already updated |
| `iterate-notes` | Step 6 (update Linear) | notes.md already updated |
| `iterate-linear` | End — skill already complete | — |

---

## Step 0.6 — Create task tracker

Create a TaskCreate for every remaining step (Steps 1 through 7). Each task subject = the step heading. After each step is fully done, mark it completed with TaskUpdate. At session end, write a trace file:

```bash
cat > {ticket-dir}/pr-iterate-session.md << 'TRACE'
# pr-iterate session — {ISSUE-ID}
**Date:** {today}
**Iteration:** #{N}
**Source:** {PR #{number} | pr-review-session.md}
**Gaps found:** {N}

## Step trace
- [x] Step 1: Load workspace — done
- [x] Step 2: Find PR review findings — {PR #{number} | session file}
- [x] Step 3: Determine iteration number — #{N}
- [x] Step 4: Update plan artifact — {simple-fix.md | openspec tasks.md}
- [x] Step 5: Update notes.md — done
- [x] Step 6: Update Linear — Ready + approved
- [x] Step 7: Report — done

## Gaps addressed this iteration
{gap summaries}
TRACE
```

---

## Step 1 — Load ticket workspace

[ -n "$LOG_FILE" ] && echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|PR-REVIEW|plan-iterate-start|start|Parsing review findings, iteration #{prev+1}" >> "$LOG_FILE"

```bash
find . -type d -name "{TICKET-ID}*"
```

If not found → stop and tell the user to run `/ticket-appraise {TICKET-ID}` first.

Read `context.md` and `notes.md` from the ticket directory.

[ -n "$LOG_FILE" ] && echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|PR-REVIEW|iterate-load|done|Workspace loaded" >> "$LOG_FILE"

---

## Step 2 — Find and parse PR review findings

### Step 2a — Find the PR

```bash
gh pr list --search "{TICKET-ID} in:head" --json number,headRefName,url
```

If a PR is found → capture `{PR_NUMBER}` and `{PR_URL}`, then go to Step 2b.

If no PR is found → check for a local session file:

```bash
find {ticket-dir} -name "pr-review-session.md"
```

- **Found** → read it. Extract the verdict and any gap notes from the step trace. Skip Step 2b and go directly to Step 3.
- **Not found** → stop and tell the user:
  > "No PR or pr-review-session.md found for {TICKET-ID}. Run `/ticket-pr-review {TICKET-ID}` first."

### Step 2b — Fetch the PR review comment

```bash
_review_body=$(gh pr view {PR_NUMBER} --json comments --jq '.comments[] | select(.body | startswith("## Ticket alignment review")) | .body')
_rc=$?
echo "$_review_body"
if [ $_rc -ne 0 ] || [ -z "$_review_body" ]; then
  hb-wrap.sh retry "jq-parse" "fail" "gh --jq extraction failed for PR review comment" \
    "{\"error_type\":\"jq_parse\",\"command\":\"gh pr view\"}"
fi
```

If no matching comment is found → fall back to `pr-review-session.md` as in Step 2a. If that also doesn't exist → stop.

### Step 2c — Parse the findings

From the comment body, extract:

1. **Coverage table rows** — look for lines matching `| N | ... | ⚠️ |` or `| N | ... | ❌ |`. For each:
   - Requirement number
   - Requirement text
   - Status (⚠️ Partial or ❌ Missing)

2. **Verdict** — look for `**Verdict:** ⚠️` or `**Verdict:** ✅`. If ✅, stop and report:
   > "{TICKET-ID} PR review already passed — no gaps to iterate on."

3. **Suggested next steps** — if a `### Suggested next steps` section exists, capture each bullet as a suggested fix for the corresponding gap.

Store these as `{GAPS}` — a list of objects with: `number`, `requirement`, `status`, `suggested_fix` (if available).

[ -n "$LOG_FILE" ] && echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|PR-REVIEW|iterate-findings|done|{N} gaps parsed" >> "$LOG_FILE"

---

## Step 3 — Determine iteration number

Check which plan artifact exists:

```bash
find {ticket-dir} -name "simple-fix.md"
ls openspec/changes/ | grep -i "{ticket-id-lowercase}"
```

- **simple-fix.md found** → set `{ARTIFACT}` = `simple-fix.md`. Count existing `## PR Review #` sections:
  ```bash
  grep -c "^## PR Review #" {ticket-dir}/simple-fix.md
  ```
- **openspec change found** → set `{ARTIFACT}` = `tasks.md` at the openspec path. Count existing `## PR Review #` sections in it.

Set `{N}` = count + 1. If this is the first iteration, `{N}` = 1.

**Guard:** if `{N} > 3` → stop and report:
```
{ticket-id} has reached 3 PR review iterations. Manual intervention recommended — the plan may need a full re-appraisal.
```

---

## Step 4 — Update the plan artifact

### If simple-fix.md

Append to `{ticket-dir}/simple-fix.md`:

```markdown
## PR Review #{N} — {today's date}

**Source:** PR #{PR_NUMBER}
**Verdict:** {N} gap(s) found

{For each gap:}
### Gap {gap.number}: {gap.requirement}

**Status in review:** {gap.status}

{If gap.suggested_fix exists:}
**Suggested fix:** {gap.suggested_fix}

**What needs to change:**
- {Concrete implementation steps — be specific about files, methods, values. Derive from the requirement text and suggested fix. Use the investigation findings in notes.md for file paths and context.}
```

### If openspec tasks.md

Append to the openspec `tasks.md`:

```markdown
## PR Review #{N} — {today's date}

**Source:** PR #{PR_NUMBER}
**Verdict:** {N} gap(s) found

{For each gap, create a numbered task with checkbox:}
- [ ] {N}.{gap.number} {gap.requirement}
  - **Status in review:** {gap.status}
  {If gap.suggested_fix exists:} — {gap.suggested_fix}
```

Use `N` as the task group prefix (e.g., iteration 1 tasks are `1.1`, `1.2`, `1.3`).

**Post-write section verify** — confirm the heading actually landed in the artifact before logging done:

```bash
_section_count=$(grep -c "^## PR Review #${N}" "{ARTIFACT_PATH}" 2>/dev/null || echo 0)
if [ "${_section_count:-0}" -lt 1 ]; then
  [ -n "$LOG_FILE" ] && echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|PR-REVIEW|iterate-plan|fail|PR Review #${N} section missing after write — {ARTIFACT_PATH}" >> "$LOG_FILE"
  # Stop — a truncated write would cause ticket-implement to silently skip all gaps
fi
```

[ -n "$LOG_FILE" ] && echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|PR-REVIEW|iterate-plan|done|{ARTIFACT} updated, iteration #{N}" >> "$LOG_FILE"

---

## Step 5 — Update notes.md

Append to `{ticket-dir}/notes.md` session log:

```markdown
### {today's date} — PR review iteration #{N}
- Source: PR #{PR_NUMBER} | Gaps: {N}
- Updated {ARTIFACT} with PR Review #{N} section
- Linear → Ready, `approved` label added
```

[ -n "$LOG_FILE" ] && echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|PR-REVIEW|iterate-notes|done|notes.md updated" >> "$LOG_FILE"

---

## Step 6 — Update Linear

Delegate to the flow executor:

```
/ticket-flow {TICKET-ID} pr-iterate
_rc=$?
if [ "$_rc" -ne 0 ]; then
  hb-wrap.sh retry "flow-sh" "fail" "flow.sh pr-iterate failed (exit ${_rc})" \
    "{\"trigger\":\"pr-iterate\",\"exit_code\":\"${_rc}\",\"ticket\":\"{TICKET-ID}\"}"
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|META|flow-error|fail|exit ${_rc}: pr-iterate" >> {LOG_FILE}
fi
```

This sets state → `Ready`, adds `approved`, and clears `reviewed`/`rejected`. All other labels (`simple`/`complex`, `Smooth`/`Rough`/`Hard`) are preserved.

[ -n "$LOG_FILE" ] && echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|PR-REVIEW|iterate-linear|done|Ready + approved" >> "$LOG_FILE"

---

## Step 7 — Report

[ -n "$LOG_FILE" ] && echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|PR-REVIEW|plan-iterate-done|done|Iteration #{N} ready" >> "$LOG_FILE"

```
## {TICKET-ID} — PR review iteration #{N} ready

**Source:** PR #{PR_NUMBER} ({PR_URL})
**Gaps found:** {N} (see details below)
**Plan updated:** {ARTIFACT} — `## PR Review #{N}` section appended
**Linear:** Ready + `approved`

### Gaps from review

{For each gap:}
- **#{gap.number}** {gap.requirement} → {gap.status}

### Next step

Run `/ticket-implement {TICKET-ID}` to address these gaps.
```
