# Pipeline Skill Preamble

Shared preamble for ticket-auto-pipeline skills. Each skill references this document with its parameters instead of duplicating the guard, Linear access, logging, heartbeat, step dispatch, and task tracking patterns.

## Parameters

When a skill says "Follow the pipeline preamble with parameters: ...", use the values below. Parameters are **mandatory** unless marked optional.

| Parameter | Description | Default |
|-----------|-------------|---------|
| `{TICKET_ID}` | Linear ticket ID (e.g. WIL-42) | Required |
| `{PHASE}` | Pipeline phase for log entries | Required |
| `{FROM_FLAG}` | Guard skip flag: `--from-auto`, `--from-appraise`, or `none` | `none` |
| `{HAS_LINEAR_ACCESS}` | Whether skill talks to Linear | `true` |
| `{LINEAR_OPS}` | Comma-separated Linear operations needed | `get_issue,get_comments` |
| `{HAS_GUARD}` | Whether skill has working-dir guard | `true` |
| `{HAS_PROJECT_CONTEXT}` | Whether skill reads CLAUDE.md context | `true` |
| `{PROJECT_CONTEXT_FIELDS}` | CLAUDE.md fields to extract | `REPOS_ROOT,ISSUE_PREFIX` |
| `{HAS_LOGGING}` | Whether skill writes pipeline log entries | `true` |
| `{HAS_HEARTBEAT}` | Whether skill writes heartbeat entries | `true` |
| `{HAS_STEP_DISPATCH}` | Whether skill supports --from-step resume | `true` |
| `{HAS_TASK_TRACKER}` | Whether skill creates a TaskCreate tracker | `true` |

---

## 1. Guard — Verify working directory

```
## Guard — Verify working directory

<!-- if {FROM_FLAG} != none -->
If the arguments contain `{FROM_FLAG}`, skip this guard — the caller already verified the working directory.
<!-- endif -->

Run `basename "$(pwd)"`. If the result is NOT `tickets`, abort immediately and tell the user to `cd` to the tickets workspace and re-run.

<!-- if {EXTRA_GUARD} -->
{EXTRA_GUARD}
<!-- endif -->
```

**Extra guard variants:**
- `validate-env`: Run `bash ~/.claude/skills/lib/validate-env.sh ./CLAUDE.md`. If it exits non-zero, report the failures and stop.
- `base-branch`: Declaration that the base branch is `develop` — branch from `develop`, PR into `develop`.

---

## 2. Linear access strategy

<!-- if {HAS_LINEAR_ACCESS} == true -->

```
## Linear access strategy

When `$LINEAR_API_KEY` is set in the environment, use bash calls to `~/.claude/skills/lib/linear-api.sh` for **all** Linear operations. When `$LINEAR_API_KEY` is unset, fall back to MCP tools (`mcp__linear-server__*`).

**Function mapping:**

| Operation | linear-api.sh bash call | MCP fallback |
|-----------|------------------------|--------------|
<!-- for each op in {LINEAR_OPS} -->
| {op_label} | {bash_call} | {mcp_call} |
<!-- endfor -->

Always check `$LINEAR_API_KEY` before each operation and use the appropriate method.
```

<!-- endif -->

**Standard operation rows:**

| Operation | Bash call | MCP fallback |
|-----------|----------|--------------|
| Fetch issue | `bash -c "source ~/.claude/skills/lib/linear-api.sh; get_issue '<id>'"` | `mcp__linear-server__get_issue(id: "<id>")` |
| Fetch comments | `bash -c "source ~/.claude/skills/lib/linear-api.sh; get_comments '<id>'"` | `mcp__linear-server__list_comments(id: "<id>")` |
| Post comment | `bash -c "source ~/.claude/skills/lib/linear-api.sh; save_comment '<id>' '<body>'"` | `mcp__linear-server__save_comment(issueId: "<id>", body: "<body>")` |
| List issues | `bash -c "source ~/.claude/skills/lib/linear-api.sh; list_issues '<team_key>' '<state>'"` | (MCP equivalent if available) |

---

## 3. Step 0 — Clear context

<!-- if {FROM_FLAG} == --from-auto -->

```
## Step 0 — Clear context: Run `/clear`.
```

<!-- endif -->

When `{FROM_FLAG}` is not `--from-auto`, this step is optional — include only if the skill benefits from a clean context before starting.

---

## 4. Step 0.5 — Detect project context

<!-- if {HAS_PROJECT_CONTEXT} == true -->

```
## Step 0.5 — Detect project context

Read `CLAUDE.md` and extract the fields listed in {PROJECT_CONTEXT_FIELDS}.
```

Standard field meanings:
- `REPOS_ROOT` — parent path of all service dirs
- `ISSUE_PREFIX` — issue ID prefix (e.g. `CRE`)
- `BE_SERVICES` — dirs with `Layer = BE`
- `BE_TEST_CMD` — backend test command from Build & Test section
- `FE_TEST_CMD` — frontend test command (skip FE tests if absent)
- `WIKI_ROOT` — path to wiki directory; if not found in CLAUDE.md, look for a default wiki path

<!-- endif -->

---

## 5. Logging (--from-auto)

<!-- if {HAS_LOGGING} == true -->

```
## Logging (--from-auto)

If `$LOG_FILE` is set (passed by the `ticket-auto` orchestrator): read `~/.claude/skills/pipeline-log-format.md`. After each major step below, write progress entries to `$LOG_FILE` using the format defined there. Phase is `{PHASE}`.
```

<!-- endif -->

---

## 6. Heartbeat (--from-auto)

<!-- if {HAS_HEARTBEAT} == true -->

```
## Heartbeat (--from-auto)

If `$HB_LOG_FILE` is set (passed by the orchestrator): call `source ~/.claude/skills/lib/heartbeat.sh` then write heartbeat entries at these decision points:

<!-- skill-specific heartbeat points go here -->
```

Each skill defines its own heartbeat decision points inline. Standard heartbeat functions:
- `hb_decision <tag> <status> <msg> [json]` — critical decision point (complexity score, verdict, mode selection)
- `hb_gate <tag> <status> <msg> [json]` — gate check (approval, CI, coherence)
- `hb_fallback <tag> <status> <msg> [json]` — degraded-path fallback (MCP used instead of bash, missing data)
- `hb_api <tag> <status> <msg> [json]` — external API call result
- `hb_retry <tag> <status> <msg> [json]` — retryable failure
- `hb_heartbeat <tag> <msg> [json]` — informational heartbeat

<!-- endif -->

---

## 7. Step dispatch (--from-step)

<!-- if {HAS_STEP_DISPATCH} == true -->

```
## Step dispatch (--from-step)

If `--from-step {step-name}` is in the arguments, this is a crash-recovery resume. Skip all steps up to and including the named step. Do not re-run skipped steps — restore any variables they would have set from existing files (notes.md, context.md, pipeline log). Proceed directly to the first step after the named step.

<!-- skill-specific dispatch table goes here -->

If `--from-step` is not provided, proceed normally from Step 1.
```

<!-- endif -->

---

## 8. Task tracker

<!-- if {HAS_TASK_TRACKER} == true -->

```
## Step {N} — Create task tracker

**Before proceeding further**, create a TaskCreate for every remaining step. Each task subject = the step heading. This ensures no step is skipped even when context scrolls.

After each step is fully done (including all sub-steps), mark it completed with TaskUpdate. At session end, write a trace file to the ticket directory:

<!-- skill-specific trace template goes here -->
```

<!-- endif -->
