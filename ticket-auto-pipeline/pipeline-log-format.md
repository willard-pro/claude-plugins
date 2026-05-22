# Pipeline Log Format

Shared format spec for ticket-auto pipeline logging. Skills read this to write progress entries directly to `$LOG_FILE` so the dashboard shows live updates.

## Format

```
ISO|PHASE|STEP|STATUS|MSG
```

Pipe-delimited, no escaping. `ISO` = UTC timestamp from `date -u +%Y-%m-%dT%H:%M:%SZ`.

## Usage

`$LOG_FILE` is an absolute path set by the orchestrator (e.g. `/path/to/logs/CRE-40-pipeline.log`). Write one line per step:

```bash
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|APPRAISE|complexity-sweep|start|Running complexity sweep" >> "$LOG_FILE"
```

Never use `>>` without a trailing newline on the echo string. Always quote `$LOG_FILE`.

## Statuses

| Status | Meaning |
|--------|---------|
| `start`   | Step began |
| `done`    | Step completed successfully |
| `fail`    | Step failed |
| `skip`    | Step skipped (not applicable) |
| `waiting` | Agent spawned, waiting for result |

## Phases & Steps

### APPRAISE
`setup-workspace` `complexity-sweep` `prior-art` `codebase-investigation` `handoff`

### REPRODUCE
`reproduce` `setup` `plan` `execute`

### EXEC
`load-workspace` `create-artifact` `regression-guard` `adversarial-review` `post-linear` `handoff`

### GATE
`gate`

### IMPLEMENT
`check-approval` `detect-path` `checkout-branch` `implement` `run-tests` `code-review` `commit-push`

### VERIFY
`load-requirements` `launch-browser` `execute-steps` `evaluate` `report`

### PR-REVIEW
`fetch-ticket` `extract-requirements` `find-pr` `validate-diff` `post-findings` `merge-decision`

### MAINTENANCE
`document` `maintenance`

## META entries

Non-phase metadata. `STEP` is the key, `MSG` is the value:

```bash
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|META|title|info|CRE-40: Ticket title here" >> "$LOG_FILE"
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|META|gate-result|info|simple — auto-approved" >> "$LOG_FILE"
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|META|outcome|info|complete" >> "$LOG_FILE"
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|META|artifact|info|notes:/path/to/tickets/proj/epic/CRE-40--slug/notes.md" >> "$LOG_FILE"
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|META|artifact|info|plan:/path/to/tickets/proj/epic/CRE-40--slug/simple-fix.md" >> "$LOG_FILE"
```

`artifact` entries are cumulative — each call adds a file to the dashboard's document list. `MSG` format: `{label}:{absolute path}`. Standard labels: `notes`, `plan`.

## Schema version header

Every new pipeline log begins with a schema declaration as its first line:

```bash
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|META|schema|info|1" >> "$LOG_FILE"
```

`detect-resume.sh` reads this line. On explicit version mismatch it emits `RESUME_STEP: SCHEMA_MISMATCH` and aborts rather than guessing. On absence in a non-empty log that otherwise matches the `ISO|PHASE|STEP|STATUS|MSG` format, it applies v0 grace: appends `|META|schema|info|1` and `|META|migration|info|v0-grace-applied` and continues.

Current schema version: **1**

## Gate-stop codes

When `ticket-auto` halts a pipeline for a structural reason (missing artifact, ambiguous state), it emits:

```bash
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|META|gate-stop|fail|<CODE>" >> "$LOG_FILE"
```

| Code | Meaning |
|------|---------|
| `EXEC_NO_ARTIFACT` | Exec phase produced no artifact file (Phase 2) |
| `COMPLEXITY_ARTIFACT_MISMATCH` | Complexity label and artifact type disagree (Phase 2) |
| `APPROVAL_REVOKED` | `approved` label was removed before implement phase started (Phase 2) |
| `REMEDIATION_BRIEF_TRUNCATED` | REMEDIATION_BRIEF from verify exceeded length limit (Phase 2) |
| `PR_REVIEW_VERDICT_UNPARSEABLE` | PR review returned no parseable ✅/⚠️/❌ verdict line (Phase 2) |
| `ADVERSARIAL_BLOCKED` | Adversarial review found blocking issues in the implementation plan (Phase 2) |
| `REPRO_NOT_CONFIRMED` | Reproduce skill determined bug does not manifest on UAT (Step 1.5) |
| `REPRO_BLOCKED` | Reproduce skill blocked — insufficient detail in ticket (Step 1.5) |

## Rules

1. Write `|start|` before the step begins, `|done|` or `|fail|` after it finishes.
2. Only write steps you actually execute — don't pre-declare future steps.
3. `MSG` should be brief (under 60 chars). Put details in trace.md, not here.
4. If `$LOG_FILE` is unset, skip logging — don't create a file in the wrong place.

## Heartbeat log

A companion heartbeat log captures decisions, fallbacks, retries, and liveness signals at fine granularity. See [`pipeline-heartbeat-format.md`](pipeline-heartbeat-format.md) for the format specification.

## Claude log

A third companion log (`{TICKET-ID}-claude.log`) uses the same `ISO|PHASE|STEP|STATUS|MSG` format with no MSG length restriction. It is written by the orchestrator at three points per phase:

- **Before each agent spawn** — `STEP=handoff STATUS=info` with the full input context (complexity, artifact path, autonomy mode, from_step)
- **After each agent success** — `STATUS=done` with verbose result data (full paths, branch name, exact counts)
- **After each agent failure** — `STEP=context STATUS=fail` with diagnostic context (last heartbeat event, dir existence, resolved paths)

Written via `cl_write` / `cl_init` helpers in `lib/heartbeat.sh`. Available to sub-agents via `$CLAUDE_LOG_FILE` env var. Useful for container debugging where the 60-char MSG limit of the pipeline log hides critical context.
