---
name: ticket-pr-review
description: Reviews a pull request by extracting requirements from its Linear ticket, validating the changed code against those requirements, and posting findings to the PR. Use when the user says "/ticket-pr-review <TICKET-ID>", "review PR for <TICKET-ID>", or "verify <TICKET-ID> against ticket".
---

# Ticket PR Review

You have been given a ticket ID as the argument (e.g. `WIL-42`). Execute the full review sequence below in order.

## Guard — Verify working directory

If the arguments contain `--from-auto`, skip this guard — `ticket-auto` already verified the working directory.

Run `basename "$(pwd)"`. If the result is NOT `tickets`, abort immediately and tell the user to `cd` to the tickets workspace and re-run.

---

## Linear access strategy

When `$LINEAR_API_KEY` is set in the environment, use bash calls to `~/.claude/skills/lib/linear-api.sh` for **all** Linear operations. When `$LINEAR_API_KEY` is unset, fall back to MCP tools (`mcp__linear-server__*`).

**Function mapping:**

| Operation | linear-api.sh bash call | MCP fallback |
|-----------|------------------------|--------------|
| Fetch issue | `bash -c "source ~/.claude/skills/lib/linear-api.sh; get_issue '<id>'"` | `mcp__linear-server__get_issue(id: "<id>")` |
| Post comment | `bash -c "source ~/.claude/skills/lib/linear-api.sh; save_comment '<id>' '<body>'"` | `mcp__linear-server__save_comment(issueId: "<id>", body: "<body>")` |

Always check `$LINEAR_API_KEY` before each operation and use the appropriate method.

---

## Step 0 — Clear context: Run `/clear`.

---

## Step 0.5 — Detect project context

Read `CLAUDE.md` and extract: `{ISSUE_PREFIX}` (issue ID prefix, e.g. `CRE`), `{REPOS_ROOT}` (parent path of all service dirs).

---

## Logging (--from-auto)

If `$LOG_FILE` is set (passed by the `ticket-auto` orchestrator): read `~/.claude/skills/pipeline-log-format.md`. After each major step below, write progress entries to `$LOG_FILE` using the format defined there. Phase is `PR-REVIEW`.

---

## Step dispatch (--from-step)

If `--from-step {step-name}` is in the arguments, this is a crash-recovery resume. Skip all steps up to and including the named step. Do not re-run them. Proceed directly to the first step after the named step.

| `--from-step` value | Skip to | Restore from |
|---------------------|---------|--------------|
| `fetch-ticket` | Step 2 (extract requirements) | ticket data already cached; re-fetch if needed |
| `extract-requirements` | Step 3 (find PR) | requirements log entry or re-extract from ticket |
| `find-pr` | Step 4 (get changed code) | PR number from log `find-pr\|done` entry |
| `validate-diff` | Step 6 (post findings) | validation results from notes or re-run |
| `post-findings` | Step 6b (merge decision) | verdict from log `post-findings\|done` entry |
| `merge-decision` | End — skill already complete | — |

If `--from-step` is not provided, proceed normally from Step 1.

---

## Step 0.6 — Create task tracker

Create a TaskCreate for every remaining step (Steps 1 through 7). Each task subject = the step heading. After each step is fully done, mark it completed with TaskUpdate. At session end, write a trace file to the ticket directory:

```bash
cat > {ticket-dir}/pr-review-session.md << 'TRACE'
# pr-review session — {ISSUE-ID}
**Date:** {today}
**PR:** {PR URL}
**Verdict:** {pass|gaps found}
**Merged:** {yes|no|skipped}

## Step trace
- [x] Step 1: Fetch ticket — done
- [x] Step 2: Extract requirements — {N} requirements
- [x] Step 3: Find PR — #{number}
- [x] Step 4: Get changed code — {N} files
- [x] Step 5: Validate requirements — {pass/fail count}
- [x] Step 6: Post findings + label — done
- [x] Step 6a: Update Linear label — {reviewed|rejected}
- [x] Step 6b: CI check gate — {all green|blocked: {check names}|skipped (gaps)}
- [x] Step 6b-merge: Merge — {merged|skipped|failed: reason}
- [x] Step 7: Report — done
TRACE
```

---

## Step 1 — Fetch the Linear ticket

[ -n "$LOG_FILE" ] && echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|PR-REVIEW|fetch-ticket|start|Fetching ticket" >> "$LOG_FILE"

Call the Linear access strategy to fetch the ticket (bash `get_issue` when `LINEAR_API_KEY` is set, MCP `get_issue` fallback otherwise).

Capture:
- `title`, `description` (requirements source)
- `labels`, `status`, `url`

[ -n "$LOG_FILE" ] && echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|PR-REVIEW|fetch-ticket|done|Fetched" >> "$LOG_FILE"

---

## Step 2 — Extract requirements

Activate the analyzer persona:
```
/buddy:persona-analyzer
```

[ -n "$LOG_FILE" ] && echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|PR-REVIEW|extract-requirements|start|Extracting requirements" >> "$LOG_FILE"

Parse the ticket description into a numbered requirements checklist. Each item must be a concrete, verifiable statement — not a paraphrase of intent. If acceptance criteria are explicitly listed, use those verbatim. If not, derive them from the description.

Record the checklist — it drives the validation in Step 5.

[ -n "$LOG_FILE" ] && echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|PR-REVIEW|extract-requirements|done|{N} requirements" >> "$LOG_FILE"

---

## Step 3 — Find the PR and branch

[ -n "$LOG_FILE" ] && echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|PR-REVIEW|find-pr|start|Finding PR" >> "$LOG_FILE"

```bash
gh pr list --search "{TICKET-ID} in:head" --json number,headRefName,baseRefName,url
```

If no PR is found → stop and tell the user:
> "No open PR found for {TICKET-ID}. Open a PR first, then re-run."

Capture: `number`, `headRefName`, `baseRefName`, `url`.

Resolve the repo path from the CLAUDE.md codebase map based on the affected service.

[ -n "$LOG_FILE" ] && echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|PR-REVIEW|find-pr|done|PR #{number}" >> "$LOG_FILE"

---

## Step 4 — Get changed code

```bash
git -C {repo-path} fetch origin
git -C {repo-path} diff origin/{baseRefName}...origin/{headRefName}
```

This produces the full set of changes introduced by the branch relative to its base.

---

## Step 4.5 — Structural impact analysis (GitNexus)

[ -n "$LOG_FILE" ] && echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|PR-REVIEW|gitnexus-impact|start|Running detect_changes" >> "$LOG_FILE"

Call `mcp__gitnexus__detect_changes` with `scope: "compare"` and `base_ref: "{baseRefName}"`. This maps the full PR diff against the knowledge graph.

**If results are returned:**
- Record each affected execution flow with its risk level
- If any flow has HIGH or CRITICAL risk, flag it prominently in the findings

**If zero results or GitNexus unavailable:**
- Note that changed files have no indexed execution flows (shell scripts, config, docs — expected for some repos)
- Log a warning and proceed — never block on GitNexus availability

[ -n "$LOG_FILE" ] && echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|PR-REVIEW|gitnexus-impact|done|{N} affected flows, risk: {highest-risk}" >> "$LOG_FILE"

---

## Step 5 — Validate requirements against diff

[ -n "$LOG_FILE" ] && echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|PR-REVIEW|validate-diff|start|Validating against requirements" >> "$LOG_FILE"

For each requirement from Step 2, evaluate whether the diff contains code that directly addresses it:

- **✅ Addressed** — the diff contains code that directly implements or fixes it
- **⚠️ Partial** — some but not all of the requirement is visible in the diff
- **❌ Missing** — no corresponding change found in the diff

Build a requirements coverage table:

| # | Requirement | Status |
|---|---|---|
| 1 | {requirement} | ✅ / ⚠️ / ❌ |

[ -n "$LOG_FILE" ] && echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|PR-REVIEW|validate-diff|done|Coverage: {pass}/{total}" >> "$LOG_FILE"

---

## Step 6 — Post findings to PR + update Linear

[ -n "$LOG_FILE" ] && echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|PR-REVIEW|post-findings|start|Posting review findings" >> "$LOG_FILE"

Format the findings as a GitHub comment and post:

```bash
gh pr comment {number} --body "$(cat <<'EOF'
## Ticket alignment review — {TICKET-ID}

**Ticket:** {Linear URL}

### Requirements coverage

| # | Requirement | Status |
|---|---|---|
{table rows}

{If GitNexus returned results:}
### Structural impact (GitNexus)

| Affected Flow | Risk |
|---------------|------|
{table rows from detect_changes}

{If any HIGH/CRITICAL risk:} ⚠️  High structural impact detected — review the affected execution flows above carefully.

**Verdict:** ✅ All requirements addressed
— or —
**Verdict:** ⚠️ Gaps found — see partial/missing rows above

{If gaps: ### Suggested next steps
- {For each ❌ or ⚠️: "Add a commit addressing X" or "Confirm with the team if X was intentionally descoped"}}
EOF
)"
```

### Step 6a — Update Linear label

Delegate to the flow executor:

- **Verdict ⚠️** (gaps found) → `/ticket-flow {TICKET-ID} pr-review-fail`
- **Verdict ✅** → check UAT_URL, then pick the right variant:
  ```bash
  config=$(bash -c "source ~/.claude/skills/lib/linear-api.sh; get_project_config")
  uat_url=$(echo "$config" | jq -r '.UAT_URL // empty')
  if [ -n "$uat_url" ]; then
    /ticket-flow {TICKET-ID} pr-review-pass-uat
  else
    /ticket-flow {TICKET-ID} pr-review-pass-done
  fi
  ```

This adds `reviewed` or `rejected`, keeping all other labels.

[ -n "$LOG_FILE" ] && echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|PR-REVIEW|post-findings|done|Verdict: {✅|⚠️}" >> "$LOG_FILE"

### Step 6b — Merge PR if all requirements addressed

[ -n "$LOG_FILE" ] && echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|PR-REVIEW|merge-decision|start|Merge decision" >> "$LOG_FILE"

If the verdict has ⚠️ or ❌, skip this step entirely.

If the verdict is ✅, **first check that all GitHub build checks have passed** before merging:

```bash
gh pr checks {number} --repo {owner}/{repo} --json name,status,conclusion
```

Parse the JSON array. Evaluate every check:
- `status` must be `COMPLETED` for all checks — if any is `IN_PROGRESS` or `QUEUED`, the build is still running
- `conclusion` must be one of `SUCCESS`, `NEUTRAL`, or `SKIPPED` — any `FAILURE`, `CANCELLED`, `TIMED_OUT`, or `ACTION_REQUIRED` is a hard block

**If any check is not COMPLETED, or has a blocking conclusion:**

Do NOT merge. Report to the user:

```
⛔ PR #{number} has failing or pending build checks — merge blocked.

| Check | Status | Conclusion |
|-------|--------|------------|
| {name} | {status} | {conclusion} |
...

Fix the failing checks and re-run `/ticket-pr-review {TICKET-ID}` or merge manually once they pass.
```

Post the same message as a PR comment.

[ -n "$LOG_FILE" ] && echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|PR-REVIEW|merge-decision|done|blocked: failing checks" >> "$LOG_FILE"

**If all checks are COMPLETED with SUCCESS/NEUTRAL/SKIPPED:**

Scan the diff captured in Step 4 for conflict markers before merging:

```bash
git -C {repo-path} diff origin/{baseRefName}...origin/{headRefName} | grep -n "^[+].*\(<<<<<<<\|=======\|>>>>>>>\)"
```

If any conflict markers are found, do NOT merge. Report to the user:

```
⛔ PR #{number} contains conflict markers — merge blocked.

Lines with conflict markers:
{grep output}

Resolve the conflicts on the branch and re-run `/ticket-pr-review {TICKET-ID}`.
```

Post the same message as a PR comment.

[ -n "$LOG_FILE" ] && echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|PR-REVIEW|merge-decision|done|blocked: conflict markers" >> "$LOG_FILE"

**If no conflict markers found:**

```bash
gh pr merge {number} --squash --delete-branch
```

If the merge fails (conflicts, branch protection, etc.), report it to the user — do not force-merge.

[ -n "$LOG_FILE" ] && echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|PR-REVIEW|merge-decision|done|{merged|skipped}" >> "$LOG_FILE"

---

## Step 7 — Report to user

```
## {TICKET-ID} — PR alignment review complete

**PR:** {PR URL}
**Verdict:** {✅ All requirements addressed | ⚠️ Gaps found}

Findings posted to PR #{number}.
```
