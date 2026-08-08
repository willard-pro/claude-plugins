---
name: ticket-retro
description: Post-pipeline retrospection — aggregates pipeline log failures and produces a dated proposal with unified diffs for skill-file fixes. Use when the user says "/ticket-retro", "/ticket-retro --window 7d", "run retro", or "retrospect the pipeline".
---

# Ticket Retro — Pipeline Retrospection & Fix Proposals

You are the `/ticket-retro` skill. Your job is to aggregate pipeline log failures, classify patterns, propose minimal diffs for implicated skill files, and write a dated proposal report. You NEVER modify skill files directly — you only write to `~/.claude/state/ticket-retro/proposals/`.

## Invocation

```
/ticket-retro [--window Nd] [--post-to-linear] [--post-to-github] [--force]
```

- `--window Nd`: days of log history to scan (default: `7d`)
- `--post-to-linear`: if present, post a summary comment to the Linear retro issue configured in `RETRO_LINEAR_ISSUE`
- `--post-to-github`: if present, auto-create GitHub issues for recurring failure patterns (count ≥ 2) with severity labels
- `--force`: re-scan all logs even if unchanged since last retro (bypasses the cursor deduplication)

## Guard — Ensure state directory

```bash
mkdir -p ~/.claude/state/ticket-retro/proposals
```

This is user state, not skill-bundle state. It survives plugin upgrades.

---

## Step 1 — Aggregate logs via retro.sh

Invoke `retro.sh` with the window flag. Include `--force` to bypass cursor-based deduplication:

```bash
bash ~/.claude/skills/ticket-retro/retro.sh --window {WINDOW}
```

`retro.sh` maintains a cursor file at `~/.claude/state/ticket-retro/retro-cursor.json` that records the last-scanned mtime for each log. On subsequent runs, logs whose mtime hasn't changed are skipped. This prevents re-reporting failures from logs that were already analyzed in a prior retro run. Use `--force` to re-scan all logs regardless.

If `retro.sh` exits non-zero, report the stderr message and stop — no logs were found in the window.

Parse the JSON output into the following variables:
- `{FAILURE_HISTOGRAM}` — object, keyed by error code, values are counts
- `{GATE_STOP_TOTAL}` — total gate-stop events
- `{GATE_WARN_TOTAL}` — total gate-warn events (e.g. `RETURN_INCOMPLETE` in Phase 1 warn-only mode); tracked separately since these never halt the pipeline — used to measure false-positive rate before a warn-only gate flips to enforce
- `{COMPLEXITY_PREDICTIONS}` — array of `{ticket, declared, actual, actual_source}`
- `{COMPLEXITY_ACCURACY}` — float 0–1
- `{LOGS_SCANNED}`, `{LOGS_SKIPPED}`, `{LOGS_WITH_FAILURES}` — counts. `LOGS_SCANNED` counts only newly-scanned logs (not cursor-skipped). `LOGS_SKIPPED` counts logs that were skipped because their mtime matched the cursor.
- `{ERROR_DIAGNOSTICS}` — object with `total_errors`, `errors_by_ticket`, `error_category_histogram` (from heartbeat structured error events)

If `{FAILURE_HISTOGRAM}` is empty (no failures), skip to Step 4 to write a short "clean window" report.

---

## Step 1.5 — Scan Claude log for failure signals and improvement hints

Source `retro.sh` for the Claude log scan helpers, then scan `$CLAUDE_LOG_FILE` (if set and present) for failure signals, `★ Insight` blocks, and `RETRO|hint` entries:

```bash
CLAUDE_FAILURES="/tmp/claude-log-failures.txt"
CLAUDE_INSIGHTS="/tmp/claude-log-insights.txt"
CLAUDE_HINTS="/tmp/claude-log-hints.txt"
CLAUDE_CORRELATED="/tmp/claude-log-correlated.txt"

if [ -n "${CLAUDE_LOG_FILE:-}" ] && [ -f "$CLAUDE_LOG_FILE" ]; then
  RETRO_SH="$(dirname "$(readlink -f "$0")")/retro.sh"
  source "$RETRO_SH"

  # Phase 1: Failure signal scan
  scan_claude_log_failures "$CLAUDE_LOG_FILE" "$CLAUDE_FAILURES" || true

  # Phase 2a: ★ Insight block scan
  grep -n -A5 "★ Insight" "$CLAUDE_LOG_FILE" 2>/dev/null | head -100 > "$CLAUDE_INSIGHTS" || true

  # Phase 2b: RETRO|hint entries
  grep -n "RETRO|hint" "$CLAUDE_LOG_FILE" 2>/dev/null | head -50 > "$CLAUDE_HINTS" || true

  # Phase 3: Phase-windowed correlation on failures
  if [ -s "$CLAUDE_FAILURES" ]; then
    correlate_failures_with_phase "$CLAUDE_LOG_FILE" "$CLAUDE_FAILURES" "$CLAUDE_CORRELATED" || true
  fi

  echo "claude-log-scan: done"
else
  echo "claude-log-scan: skipped (CLAUDE_LOG_FILE not set or file missing)"
fi
```

Read the output files into context variables:
- `{CLAUDE_FAILURES}` — content of `/tmp/claude-log-failures.txt` (failure keyword hits, line-numbered)
- `{CLAUDE_INSIGHTS}` — content of `/tmp/claude-log-insights.txt` (★ Insight blocks with 5 lines context)
- `{CLAUDE_HINTS}` — content of `/tmp/claude-log-hints.txt` (RETRO|hint entries verbatim)
- `{CLAUDE_CORRELATED}` — content of `/tmp/claude-log-correlated.txt` (phase-grouped failure report, or empty if no phase boundaries)

If `$CLAUDE_LOG_FILE` is unset or missing, all variables are empty and all Claude log sections are omitted from the proposal.

---

## Step 2 — Load prior proposal context

Check for a prior proposal to avoid re-proposing already-submitted fixes:

```bash
ls -t ~/.claude/state/ticket-retro/proposals/*-retro.md 2>/dev/null | head -1
```

If a file exists, read it and extract:
- The failure codes that already had diffs proposed (look for `### <CODE>` subsections under "Pattern Analysis")
- Any "previously proposed — verify if applied" annotations

Store as `{PRIOR_PROPOSAL_CONTEXT}` — used in Step 3 to annotate repeated proposals.

---

## Step 3 — Generate per-failure-class diff proposals

For each failure code in `{FAILURE_HISTOGRAM}` where count ≥ 2:

### 3a — Load the template

```bash
TEMPLATE="~/.claude/skills/ticket-retro/templates/{CODE}.md"
```

If the template file exists, read it. If not, use the generic fallback: "Investigate the skill file that produces or handles `{CODE}` events. Look for the log-write site and the decision logic that leads to this failure."

### 3a.5 — Extract heartbeat error context for this failure code

Before reading the implicated skill file, check `{ERROR_DIAGNOSTICS}` for structured error events related to this failure code:

```bash
# Find tickets in the failure histogram that also have heartbeat error events
# Cross-reference by checking errors_by_ticket for tickets that produced this failure code
```

For each ticket that contributed to this failure code count, check `{ERROR_DIAGNOSTICS}.errors_by_ticket[ticket]` for error events. Extract:
- `event` — error event name (e.g. `get-issue`, `flow-sh`, `jq-parse`)
- `message` — human-readable failure description
- `detail` — structured key-value pairs (command, ticket, exit_code, error_snippet, etc.)
- `timestamp` — when the failure occurred

Store as `{ERROR_CONTEXT}` for use in steps 3b and 3c.

Also check if an agent transcript file exists on disk for any implicated ticket:
```bash
TRANSCRIPT_PATH="./logs/{TICKET-ID}-{phase}-agent.log"  # e.g. logs/CRE-47-exec-agent.log
```
Store the path as `{TRANSCRIPT_PATH}` if the file exists (used in Step 4 proposal — reference only, never grep the content).

### 3b — Read the implicated skill file

The template identifies which skill file(s) to inspect. Read the relevant sections of that skill file. For gate-stop codes the mapping is:

| Code | Primary Skill File |
|------|-------------------|
| `EXEC_NO_ARTIFACT` | `ticket-appraise-exec/SKILL.md` |
| `COMPLEXITY_ARTIFACT_MISMATCH` | `ticket-appraise-exec/SKILL.md` |
| `APPROVAL_REVOKED` | `ticket-auto/SKILL.md` (Step 5d), `ticket-pr-iterate/SKILL.md` |
| `REMEDIATION_BRIEF_TRUNCATED` | `ticket-verify/SKILL.md`, `ticket-implement/SKILL.md` |
| `PR_REVIEW_VERDICT_UNPARSEABLE` | `ticket-pr-review/SKILL.md` |
| `RETURN_INCOMPLETE` | `ticket-auto/SKILL.md` (STEP_4), `lib/return-completeness-check.sh` |

For the `complexity-drift` meta-code (accuracy < 0.5): inspect `ticket-appraise/SKILL.md`.

### 3b.5 — GitHub severity mapping (for --post-to-github)

When `--post-to-github` is active, map each failure code to severity and type labels:

| Failure Code | Severity | Type Label |
|-------------|----------|------------|
| `EXEC_NO_ARTIFACT` | P0 | bug |
| `APPROVAL_REVOKED` | P0 | bug |
| `PR_REVIEW_VERDICT_UNPARSEABLE` | P1 | bug |
| `COMPLEXITY_ARTIFACT_MISMATCH` | P2 | bug |
| `REMEDIATION_BRIEF_TRUNCATED` | P2 | bug |
| `RETURN_INCOMPLETE` | P3 | improvement |
| `complexity-drift` | P3 | improvement |
| Unknown / new codes | P2 | bug |

Gate-stop codes (those emitted as `|META|gate-stop|fail|<CODE>`) map to `bug`. Warning/drift codes map to `improvement`. The combined label string is `{type},{severity}` (e.g., `bug,P0`, `improvement,P3`).

**Authoritative implementation**: The bash function `github_retro_map_severity()` in `lib/github-issue-retro.sh` is the canonical source — it uses a case statement, not AI table parsing. The table above is documentation; the bash function is execution.

### 3c — Generate a unified diff

Produce a minimal unified diff that would fix the recurring failure. The diff should:
- Target the specific section of the skill file where the failure originates
- Be minimal — one focused change, not a rewrite
- Be presented in a fenced `diff` code block
- Where `{ERROR_CONTEXT}` provides structured detail (e.g. `error_snippet`, `error_type`, `exit_code`), use those specific values to inform the proposed fix rather than making assumptions about the root cause

If the same diff was proposed in `{PRIOR_PROPOSAL_CONTEXT}`, note "Previously proposed on {date} — verify if applied" instead of repeating the full diff.

Collect all diffs into `{ALL_DIFFS}` for Step 4.

---

## Step 4 — Write the proposal

Write `~/.claude/state/ticket-retro/proposals/{YYYY-MM-DD}-retro.md` with these sections in order:

### Section: Failure Histogram

Markdown table of error codes and their frequencies, sorted descending:

```markdown
## Failure Histogram

| Code | Count |
|------|-------|
| EXEC_NO_ARTIFACT | 4 |
| APPROVAL_REVOKED | 2 |
```

### Section: Complexity Prediction Accuracy

Table of predicted vs. actual complexity with per-ticket rows and aggregate accuracy:

```markdown
## Complexity Prediction Accuracy

| Ticket | Declared | Actual | Source |
|--------|----------|--------|--------|
| CRE-47 | simple | Smooth | log |
| CRE-48 | complex | Hard | log |

**Accuracy:** 0.750 (3/4 correct)
```

### Section: Claude Log Failures (if scan ran)

If `{CLAUDE_LOG_FILE}` was set and the scan found failures, include this section:

```markdown
## Claude Log Failures

<!-- If phase correlation succeeded, use correlated output: -->
{CLAUDE_CORRELATED}

<!-- If phase correlation was unavailable but failures were found, use flat list: -->
<!-- If neither, state: "No failure signals detected in Claude log." -->
```

**Phase-correlated format** (when `{CLAUDE_CORRELATED}` is non-empty): Use the content verbatim — it already has per-phase `###` headings with line-numbered failure entries.

**Flat format** (when `{CLAUDE_CORRELATED}` is empty but `{CLAUDE_FAILURES}` has content): List each failure line with its line number. Precede with the "Phase correlation unavailable" note from the correlated output if present.

If `{CLAUDE_FAILURES}` is empty (scan ran but found nothing): Write "No failure signals detected in Claude log."

If the scan was skipped (CLAUDE_LOG_FILE unset): Omit this section entirely.

### Section: Agent Improvement Hints (if scan ran)

If `{CLAUDE_LOG_FILE}` was set and either insights or hints were found, include this section:

```markdown
## Agent Improvement Hints

### Insight Blocks

<!-- If {CLAUDE_INSIGHTS} is non-empty, list each Insight block verbatim: -->
{CLAUDE_INSIGHTS}

<!-- If empty: "No ★ Insight blocks found." -->

### Explicit Hints

<!-- If {CLAUDE_HINTS} is non-empty, list each RETRO|hint entry verbatim: -->
{CLAUDE_HINTS}

<!-- If empty: "No explicit RETRO|hint entries found." -->
```

If both Insight Blocks and Explicit Hints are empty, write "No agent improvement hints found."

If the scan was skipped (CLAUDE_LOG_FILE unset): Omit this section entirely.

### Section: Pattern Analysis

One subsection per failure code with count ≥ 2:

```markdown
## Pattern Analysis

### EXEC_NO_ARTIFACT (4 occurrences)

**Pattern:** <description from template>

**Implicated:** `ticket-appraise-exec/SKILL.md`

**Diagnostic context** (from heartbeat error events, if available):
- Event: `<event name>` — `<message>`
- Detail: `<key: value>` pairs from DETAIL JSON (e.g. `expected: ./tickets/CRE-47--slug/simple-fix.md`, `artifact_type: simple-fix`)
- (If no heartbeat error events for this failure code: "No structured diagnostic data — error capture may predate this run.")

**Transcript** (for manual investigation, if available):
`./logs/{TICKET-ID}-{phase}-agent.log`

**Proposed fix:**

` ``diff
--- a/skills/ticket-appraise-exec/SKILL.md
+++ b/skills/ticket-appraise-exec/SKILL.md
@@ -X,Y +X,Y @@
 ...
` ``

### APPROVAL_REVOKED (2 occurrences)

...
```

If a diff was previously proposed (from Step 2 context), add: `> ⚠️ Previously proposed on {date} — verify if applied.`

### Section: Single-occurrence Notes

Brief notes on codes that appeared exactly once:

```markdown
## Single-occurrence Notes

- **PR_REVIEW_VERDICT_UNPARSEABLE** (1 occurrence, CRE-49): isolated incident — monitor in next window before proposing a diff.
```

### Section: Apply Instructions

```markdown
## Apply Instructions

To apply all proposed diffs:

` ``bash
cd ~/.claude/skills
git apply < ~/.claude/state/ticket-retro/proposals/{YYYY-MM-DD}-retro.md
` ``

Review each diff before applying. The `--reject` flag saves rejected hunks as `*.rej` files for manual resolution.
```

If no diffs were proposed (empty Pattern Analysis):

```markdown
## Apply Instructions

No diffs proposed — review single-occurrence notes above. Re-run with a wider window (`--window 30d`) if patterns haven't emerged yet.
```

### Section: GitHub Issues (if --post-to-github)

If `--post-to-github` was used and GitHub operations completed, include this section:

```markdown
## GitHub Issues

| Failure Code | Action | Issue |
|-------------|--------|-------|
| EXEC_NO_ARTIFACT | Created | [willard-pro/claude-plugins#99](https://github.com/willard-pro/claude-plugins/issues/99) |
| APPROVAL_REVOKED | Updated | [willard-pro/claude-plugins#85](https://github.com/willard-pro/claude-plugins/issues/85) |
```

If no failure codes met the count ≥ 2 threshold:
```markdown
## GitHub Issues

No new issues — all failure codes below the count ≥ 2 threshold.
```

If `--post-to-github` was used but auth failed:
```markdown
## GitHub Issues

GitHub posting skipped — `gh` CLI not authenticated. Run `gh auth login` and re-run retro with `--post-to-github`.
```

**Proposal verify** — confirm the file was written before reporting success:

```bash
_proposal_file="$HOME/.claude/state/ticket-retro/proposals/{YYYY-MM-DD}-retro.md"
if [ ! -f "$_proposal_file" ]; then
  echo "retro: proposal file not written at ${_proposal_file}" >&2
  exit 1
fi
```

If missing, stop — do not proceed to Step 5 or report the retro as complete.

---

## Step 5 — Post to Linear (if --post-to-linear)

If `--post-to-linear` is present:

Check `RETRO_LINEAR_ISSUE`:
```bash
if [ -z "$RETRO_LINEAR_ISSUE" ]; then
  echo "WARN: RETRO_LINEAR_ISSUE not set — skipping Linear post"
else
  # Post a summary comment
fi
```

If set, post a summary comment to that Linear issue using `mcp__linear-server__save_comment`:

```markdown
## Retro — {YYYY-MM-DD} (window: {WINDOW})

**Logs scanned:** {LOGS_SCANNED} | **With failures:** {LOGS_WITH_FAILURES}

### Failure Histogram
| Code | Count |
|------|-------|
...

### Complexity Accuracy: {COMPLEXITY_ACCURACY}

Full proposal: `~/.claude/state/ticket-retro/proposals/{YYYY-MM-DD}-retro.md`
```

If `RETRO_LINEAR_ISSUE` is unset, log the warning and skip — the proposal is still written.

---

## Step 5.5 — Post to GitHub (if --post-to-github)

If `--post-to-github` is present:

### 5.5a — Source library and check auth

```bash
GITHUB_ISSUES_LIB="$HOME/.claude/skills/lib/github-issues.sh"
if [ -f "$GITHUB_ISSUES_LIB" ]; then
  source "$GITHUB_ISSUES_LIB"
else
  echo "WARN: github-issues.sh not found at $GITHUB_ISSUES_LIB — skipping GitHub post"
fi

if ! declare -f github_check_auth >/dev/null 2>&1; then
  echo "WARN: github_check_auth not available — skipping GitHub post"
elif ! github_check_auth; then
  echo "WARN: gh CLI not authenticated — skipping GitHub post (proposal still written)"
fi
```

If `github_check_auth` fails or the library is unavailable, skip all GitHub operations. The proposal is still written — this is graceful degradation.

### 5.5b — Generate issue body and comment files

For each failure code in `{FAILURE_HISTOGRAM}` where count ≥ 2:

1. **Map severity** using the table in Step 3b.5 (the authoritative mapping is the bash `github_retro_map_severity` function — the table is documentation)

2. **Fill the issue body template** (`lib/github-issue-body.template.md`) with placeholders from the pattern analysis in Step 3:
   - `{FAILURE_CODE}`, `{PATTERN_SUMMARY}`, `{PATTERN_DESCRIPTION}`, `{EXPECTED_BEHAVIOR}`, `{STEPS}`, `{ROOT_CAUSE}`, `{FILES}`, `{FIX_APPROACH}`, `{CONSTRAINTS}`, `{VERIFICATION_CHECKLIST}`, `{RELATED}`, `{WINDOW}`, `{COUNT}`
   - Write the filled body to a temp file: `/tmp/issue-body-{CODE}.md`

3. **Prepare the evidence comment** (used if an existing open issue is found):
   ```markdown
   ## New evidence — window: {WINDOW}, occurrences: {COUNT}
   
   **Date:** {YYYY-MM-DD}
   
   Additional occurrence(s) of this failure pattern detected in the current retro window.
   See proposal at `~/.claude/state/ticket-retro/proposals/{YYYY-MM-DD}-retro.md` for updated analysis.
   ```
   - Write to a temp file: `/tmp/evidence-{CODE}.md`

4. **Build the input JSON** for `github_retro_process`:
   ```json
   {
     "codes": {
       "EXEC_NO_ARTIFACT": {
         "count": 4,
         "title": "Fix EXEC_NO_ARTIFACT — artifact not found after exec phase",
         "body_file": "/tmp/issue-body-EXEC_NO_ARTIFACT.md",
         "comment_file": "/tmp/evidence-EXEC_NO_ARTIFACT.md"
       }
     }
   }
   ```
   The `title` format is: `Fix {FAILURE_CODE} — {PATTERN_SUMMARY}`

5. **Write the input JSON** to a temp file:
   ```bash
   INPUT_FILE=$(mktemp)
   echo "$INPUT_JSON" > "$INPUT_FILE"
   ```

### 5.5c — Execute deterministic state machine

```bash
GITHUB_RETRO_LIB="$HOME/.claude/skills/lib/github-issue-retro.sh"
if [ -f "$GITHUB_RETRO_LIB" ]; then
  source "$GITHUB_RETRO_LIB"
  RESULT=$(github_retro_process "$INPUT_FILE")
  echo "$RESULT"
else
  echo "WARN: github-issue-retro.sh not found — skipping GitHub post"
fi
```

This single call handles ALL deterministic mechanics:
- Threshold check (count ≥ 2 → gate, <2 → skip)
- State file read (`~/.claude/state/ticket-retro/github-issues.json`)
- Severity mapping (bash case statement — no AI interpretation)
- Open-issue check (`github_issue_lookup` → OPEN, CLOSED, or NOT_FOUND)
- Create vs. comment decision
- State file update (atomic write + JSON validation)
- Incremental state writes (after each successful operation)

The result JSON has the shape:
```json
{
  "created": [{"code": "EXEC_NO_ARTIFACT", "url": "https://..."}],
  "updated": [{"code": "APPROVAL_REVOKED", "url": "https://..."}],
  "skipped": ["RETURN_INCOMPLETE"]
}
```

### 5.5d — Report

Extract counts from the result:
```bash
GITHUB_CREATED=$(echo "$RESULT" | jq '.created | length')
GITHUB_UPDATED=$(echo "$RESULT" | jq '.updated | length')
```

Emit summary:
```
GitHub issues: {GITHUB_CREATED} created, {GITHUB_UPDATED} updated
```

Store `{GITHUB_CREATED}` and `{GITHUB_UPDATED}` for the proposal GitHub Issues subsection and the completion summary.

Clean up temp files:
```bash
rm -f "$INPUT_FILE" /tmp/issue-body-*.md /tmp/evidence-*.md
```

---

## Completion

**G1 — RLVR Phase 0**: Before reporting, record the retro verdict as a verifier-result:
```bash
source ~/.claude/skills/lib/verifier-result.sh
write_verifier_result \
  verifier=ticket_retro verdict=<PASS|WARN|FAIL> \
  criteria_met=<fixes-found> criteria_total=<failure-classes> \
  phase=MAINTENANCE
```
Choose verdict: PASS if no failure classes found, WARN if failures found but diffs generated, FAIL if diffs could not be generated for critical classes.

Report to the user:

```
## Ticket Retro Complete

**Window:** {WINDOW}
**Logs scanned:** {LOGS_SCANNED}
**Logs with failures:** {LOGS_WITH_FAILURES}
**Gate-stop events:** {GATE_STOP_TOTAL}
**Gate-warn events:** {GATE_WARN_TOTAL}
**Complexity accuracy:** {COMPLEXITY_ACCURACY}

**Proposal written:** ~/.claude/state/ticket-retro/proposals/{YYYY-MM-DD}-retro.md
{Diff count} diff proposals generated.
{GitHub summary line}

Apply with:
  cd ~/.claude/skills && git apply < ~/.claude/state/ticket-retro/proposals/{YYYY-MM-DD}-retro.md
```

The `{GitHub summary line}` is:
- If `--post-to-github` was used and succeeded: `**GitHub issues:** {GITHUB_CREATED} created, {GITHUB_UPDATED} updated`
- If `--post-to-github` was used but auth failed: `**GitHub issues:** skipped — gh not authenticated`
- If `--post-to-github` was not used: omitted entirely
