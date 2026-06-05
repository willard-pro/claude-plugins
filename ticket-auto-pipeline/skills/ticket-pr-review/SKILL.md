---
name: ticket-pr-review
description: Reviews a pull request by extracting requirements from its Linear ticket, validating the changed code against those requirements, and posting findings to the PR. Use when the user says "/ticket-pr-review <TICKET-ID>", "review PR for <TICKET-ID>", or "verify <TICKET-ID> against ticket".
---

# Ticket PR Review

You have been given a ticket ID as the argument (e.g. `WIL-42`). Execute the full review sequence below in order.

## Pipeline Preamble

If `--from-auto` is present in the arguments, follow the auto-pipeline preamble in `~/.claude/skills/lib/skill-preamble-auto.md` with parameters: TICKET_ID=<from args>, PHASE=PR-REVIEW, HAS_LINEAR_ACCESS=true, LINEAR_OPS=get_issue,save_comment, HAS_LOGGING=true, HAS_HEARTBEAT=true. Before starting, source the project context: `source /tmp/ticket-auto-{TICKET_ID}-env.sh 2>/dev/null || true`. Otherwise, follow the full pipeline preamble in `~/.claude/skills/lib/skill-preamble.md` with parameters: TICKET_ID=<from args>, PHASE=PR-REVIEW, FROM_FLAG=none, HAS_LINEAR_ACCESS=true, LINEAR_OPS=get_issue,save_comment, HAS_GUARD=true, HAS_PROJECT_CONTEXT=true, PROJECT_CONTEXT_FIELDS=ISSUE_PREFIX,REPOS_ROOT, HAS_LOGGING=true, HAS_HEARTBEAT=true, HAS_STEP_DISPATCH=true, HAS_TASK_TRACKER=true

### Heartbeat points
- **Requirement extraction**: after extracting requirements from the ticket, write `hb_decision "requirement-extraction" "ok" "extracted N requirements" '{"count":"N"}'`
- **CI checks**: after checking CI status, write `hb_gate "ci-checks" "ok|fail" "CI status: <state>" '{"state":"<passing|failing>"}'`
- **Merge decision**: after rendering verdict, write `hb_decision "merge-decision" "fired" "verdict" '{"verdict":"<✅|⚠️|❌>"}'`

### Step dispatch
| `--from-step` value | Skip to | Restore from |
|---------------------|---------|--------------|
| `fetch-ticket` | Step 2 (extract requirements) | ticket data already cached; re-fetch if needed |
| `extract-requirements` | Step 3 (find PR) | requirements log entry or re-extract from ticket |
| `find-pr` | Step 4 (get changed code) | PR number from log `find-pr\|done` entry |
| `validate-diff` | Step 6 (post findings) | validation results from notes or re-run |
| `post-findings` | Step 6b (merge decision) | verdict from log `post-findings\|done` entry |
| `merge-decision` | End — skill already complete | — |

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
Extract `owner` and `repo` from the PR URL (`https://github.com/{owner}/{repo}/pull/{number}`) for REST API calls in subsequent steps.

Resolve the repo path from the CLAUDE.md codebase map based on the affected service.

[ -n "$LOG_FILE" ] && echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|PR-REVIEW|find-pr|done|PR #{number}" >> "$LOG_FILE"
# Write PR number to pipeline log for detect-resume.sh (primary lookup, not fallback)
[ -n "$LOG_FILE" ] && echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|PR-REVIEW|checkout-pr|done|{number}" >> "$LOG_FILE"

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
gh api "repos/{owner}/{repo}/issues/{number}/comments" -f body="$(cat <<'EOF'
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
**Why REST API:** `gh pr comment` uses GraphQL which has eventual consistency — a newly created PR may not be queryable for several seconds. The REST `/issues/{number}/comments` endpoint is immediately consistent.

### Step 6a — Update Linear label

Delegate to the flow executor:

- **Verdict ⚠️** (gaps found):
  ```bash
  /ticket-flow {TICKET-ID} pr-review-fail
  _rc=$?
  if [ "$_rc" -ne 0 ]; then
    hb_retry "flow-sh" "fail" "flow.sh pr-review-fail failed (exit ${_rc})" \
      "{\"trigger\":\"pr-review-fail\",\"exit_code\":\"${_rc}\",\"ticket\":\"{TICKET-ID}\"}"
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|META|flow-error|fail|exit ${_rc}: pr-review-fail" >> {LOG_FILE}
  fi
  ```
- **Verdict ✅** → check UAT_URL, then pick the right variant:
  ```bash
  config=$(bash -c "source ~/.claude/skills/lib/linear-api.sh; get_project_config")
  uat_url=$(echo "$config" | jq -r '.UAT_URL // empty')
  if [ $? -ne 0 ]; then
    hb_retry "jq-parse" "fail" "jq extraction failed for UAT_URL" \
      "{\"error_type\":\"jq_parse\",\"field\":\"UAT_URL\"}"
  fi
  if [ -n "$uat_url" ]; then
    /ticket-flow {TICKET-ID} pr-review-pass-uat
    _rc=$?
    if [ "$_rc" -ne 0 ]; then
      hb_retry "flow-sh" "fail" "flow.sh pr-review-pass-uat failed (exit ${_rc})" \
        "{\"trigger\":\"pr-review-pass-uat\",\"exit_code\":\"${_rc}\",\"ticket\":\"{TICKET-ID}\"}"
      echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|META|flow-error|fail|exit ${_rc}: pr-review-pass-uat" >> {LOG_FILE}
    fi
  else
    /ticket-flow {TICKET-ID} pr-review-pass-done
    _rc=$?
    if [ "$_rc" -ne 0 ]; then
      hb_retry "flow-sh" "fail" "flow.sh pr-review-pass-done failed (exit ${_rc})" \
        "{\"trigger\":\"pr-review-pass-done\",\"exit_code\":\"${_rc}\",\"ticket\":\"{TICKET-ID}\"}"
      echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|META|flow-error|fail|exit ${_rc}: pr-review-pass-done" >> {LOG_FILE}
    fi
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
gh api "repos/{owner}/{repo}/pulls/{number}/merge" -X PUT -f merge_method=squash 2>&1 || {
  echo "ERROR: REST API merge failed for PR #{number}" >&2
  hb_retry "pr-merge" "fail" "REST API merge failed for PR #{number}" \
    "{\"pr_number\":\"{number}\",\"owner\":\"{owner}\",\"repo\":\"{repo}\"}"
  [ -n "$LOG_FILE" ] && echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|PR-REVIEW|merge-decision|fail|gh api merge failed for PR #{number}" >> "$LOG_FILE"
}
```
**Why REST API:** `gh pr merge` uses GraphQL which has eventual consistency — a newly created PR may not be immediately queryable. The REST `/pulls/{number}/merge` endpoint is immediately consistent and avoids the "Could not resolve to a PullRequest" error.

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
