---
name: ticket-retro
description: Post-pipeline retrospection — aggregates pipeline log failures and produces a dated proposal with unified diffs for skill-file fixes. Use when the user says "/ticket-retro", "/ticket-retro --window 7d", "run retro", or "retrospect the pipeline".
---

# Ticket Retro — Pipeline Retrospection & Fix Proposals

You are the `/ticket-retro` skill. Your job is to aggregate pipeline log failures, classify patterns, propose minimal diffs for implicated skill files, and write a dated proposal report. You NEVER modify skill files directly — you only write to `~/.claude/state/ticket-retro/proposals/`.

## Invocation

```
/ticket-retro [--window Nd] [--post-to-linear]
```

- `--window Nd`: days of log history to scan (default: `7d`)
- `--post-to-linear`: if present, post a summary comment to the Linear retro issue configured in `RETRO_LINEAR_ISSUE`

## Guard — Ensure state directory

```bash
mkdir -p ~/.claude/state/ticket-retro/proposals
```

This is user state, not skill-bundle state. It survives plugin upgrades.

---

## Step 1 — Aggregate logs via retro.sh

Invoke `retro.sh` with the window flag:

```bash
bash ~/.claude/skills/ticket-retro/retro.sh --window {WINDOW}
```

If `retro.sh` exits non-zero, report the stderr message and stop — no logs were found in the window.

Parse the JSON output into the following variables:
- `{FAILURE_HISTOGRAM}` — object, keyed by error code, values are counts
- `{GATE_STOP_TOTAL}` — total gate-stop events
- `{COMPLEXITY_PREDICTIONS}` — array of `{ticket, declared, actual, actual_source}`
- `{COMPLEXITY_ACCURACY}` — float 0–1
- `{LOGS_SCANNED}`, `{LOGS_WITH_FAILURES}` — counts

If `{FAILURE_HISTOGRAM}` is empty (no failures), skip to Step 4 to write a short "clean window" report.

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

### 3b — Read the implicated skill file

The template identifies which skill file(s) to inspect. Read the relevant sections of that skill file. For gate-stop codes the mapping is:

| Code | Primary Skill File |
|------|-------------------|
| `EXEC_NO_ARTIFACT` | `ticket-appraise-exec/SKILL.md` |
| `COMPLEXITY_ARTIFACT_MISMATCH` | `ticket-appraise-exec/SKILL.md` |
| `APPROVAL_REVOKED` | `ticket-auto/SKILL.md` (Step 5d), `ticket-pr-iterate/SKILL.md` |
| `REMEDIATION_BRIEF_TRUNCATED` | `ticket-verify/SKILL.md`, `ticket-implement/SKILL.md` |
| `PR_REVIEW_VERDICT_UNPARSEABLE` | `ticket-pr-review/SKILL.md` |

For the `complexity-drift` meta-code (accuracy < 0.5): inspect `ticket-appraise/SKILL.md`.

### 3c — Generate a unified diff

Produce a minimal unified diff that would fix the recurring failure. The diff should:
- Target the specific section of the skill file where the failure originates
- Be minimal — one focused change, not a rewrite
- Be presented in a fenced `diff` code block

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

### Section: Pattern Analysis

One subsection per failure code with count ≥ 2:

```markdown
## Pattern Analysis

### EXEC_NO_ARTIFACT (4 occurrences)

**Pattern:** <description from template>

**Implicated:** `ticket-appraise-exec/SKILL.md`

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

## Completion

Report to the user:

```
## Ticket Retro Complete

**Window:** {WINDOW}
**Logs scanned:** {LOGS_SCANNED}
**Logs with failures:** {LOGS_WITH_FAILURES}
**Gate-stop events:** {GATE_STOP_TOTAL}
**Complexity accuracy:** {COMPLEXITY_ACCURACY}

**Proposal written:** ~/.claude/state/ticket-retro/proposals/{YYYY-MM-DD}-retro.md
{Diff count} diff proposals generated.

Apply with:
  cd ~/.claude/skills && git apply < ~/.claude/state/ticket-retro/proposals/{YYYY-MM-DD}-retro.md
```
