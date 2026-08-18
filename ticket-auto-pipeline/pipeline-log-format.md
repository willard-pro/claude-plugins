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
`fetch-ticket` `extract-requirements` `find-pr` `validate-diff` `post-findings` `merge-decision` `pr-reconcile`

### MAINTENANCE
`document` `maintenance` `prescan`

### PRESCAN (token-label only)
`PRESCAN` is a free-form token label for prescan spawns — NOT a resumable pipeline phase.
Prescan writes its own repo-scoped log at `~/.claude/logs/prescan-<repo-slug>.log`.
The router brackets auto-invoke prescan spawns as `MAINTENANCE|prescan|waiting`/`done` in the ticket log.

## Verdict tokens

`spawn_agent_post` (in `lib/spawn-helper.sh`) accepts an optional `VERDICT=` parameter. When
set, it is prepended to `MSG` as `{VERDICT} — {MSG}` before the `done`/`fail` line is written.
This gives deterministic consumers (`detect-resume.sh`) a fixed token to grep instead of
coupling to router free-text prose or emoji bytes — the router still writes whatever
human-readable summary it wants in `MSG`, but the token in front of it is guaranteed stable.

| Token   | Meaning                                  | Used by            |
|---------|-------------------------------------------|--------------------|
| `PASS`  | Verify UAT passed                        | VERIFY terminal    |
| `FAIL`  | Verify UAT failed (retryable)            | VERIFY terminal    |
| `OK`    | PR review verdict ✅ — no gaps           | PR-REVIEW terminal |
| `WARN`  | PR review verdict ⚠️ — gaps, iterate     | PR-REVIEW terminal |
| `BLOCK` | PR review verdict ❌ — blocking issues   | PR-REVIEW terminal |

Example:

```bash
spawn_agent_post TICKET_ID=CRE-40 RESULT=done VERDICT=PASS MSG="3/3 criteria met" NEXT_PHASE=PR-REVIEW
# writes: ...|VERIFY|verify|done|PASS — 3/3 criteria met
```

This is additive — schema version stays **1**. Older log lines written before this token set
existed simply have no token prefix; consumers that grep for the token (not just the phase)
treat those as non-matches, which is the correct conservative behavior (unknown verdict ≠ pass).

### PR feedback reconciliation cycle marker

`STEP_5_5`'s `pr-reconcile` terminal entry carries a `cycle#N` counter in `MSG` so
`detect-resume.sh` can compute `PR_FEEDBACK_CYCLE` — the number of reconciliation rounds
already run, capped at 3 (`PR_FEEDBACK_EXHAUSTED` gate-stop, see below):

```bash
echo "...|PR-REVIEW|pr-reconcile|done|cycle#2 reconciled" >> "$LOG_FILE"
```

## META entries

Non-phase metadata. `STEP` is the key, `MSG` is the value:

```bash
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|META|title|info|CRE-40: Ticket title here" >> "$LOG_FILE"
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|META|gate-result|info|simple — auto-approved" >> "$LOG_FILE"
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|META|outcome|info|complete" >> "$LOG_FILE"
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|META|outcome-label|info|Smooth" >> "$LOG_FILE"
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|META|artifact|info|notes:/path/to/tickets/proj/epic/CRE-40--slug/notes.md" >> "$LOG_FILE"
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|META|artifact|info|plan:/path/to/tickets/proj/epic/CRE-40--slug/simple-fix.md" >> "$LOG_FILE"
```

`artifact` entries are cumulative — each call adds a file to the dashboard's document list. `MSG` format: `{label}:{absolute path}`. Standard labels: `notes`, `plan`.

`outcome-label` is distinct from `outcome`: `outcome` (written once, last, by STEP_6) is the
pipeline run's final status; `outcome-label` (written by `outcome-label-check.sh` after every
implement) mirrors the Smooth/Rough/Hard Linear label confirmed for this ticket. The
auto-merge check in `ticket-auto/SKILL.md` reads `outcome-label`, not `outcome` — it needs
the ticket-quality verdict, not the pipeline-run verdict.

### Branch context entry

Written once by `resolve_branch_context` at pipeline start (Step 0.5), before the first agent
spawn. Records the branch decisions for this run so crash-resume can recover them without
re-resolving.

```bash
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|META|branch-context|info|base=develop;integration=;source=default;ticket=feat/CRE-123-fix-auth" >> "$LOG_FILE"
```

`MSG` grammar: semicolon-delimited key=value pairs. Keys: `base` (always present),
`integration` (empty when base=integration), `source` (flag|epic-directive|default),
`ticket` (always present). Values MUST NOT contain `|` per the pipe-delimited format
constraint. Branch names are already validated to exclude `;` and `|` by
`_validate_branch_name`, so the semicolon grammar is safe.

`mode-change` is written to Step 0.6's `META|autonomy` guard instead of a silent re-append
when a resume's `--mode` flag differs from the autonomy already recorded for this run —
gate decisions upstream were made under the old mode, so the switch must be visible, not
last-wins:

```bash
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|META|mode-change|warn|auto (was semi-auto)" >> "$LOG_FILE"
```

### Corrections entries

When `ticket-implement` Step 4c Part 4 fails to write a CORRECTIONS block to notes.md, it emits a non-blocking warning:

```bash
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|META|corrections-error|warn|append_correction failed" >> "$LOG_FILE"
```

`corrections-error` entries are always `warn` status — corrections are a feedback signal, not a pipeline gate. A missing correction never halts the pipeline.

### Gate-warn channel

The `gate-warn` channel (distinct from `gate-stop`) carries non-blocking completeness warnings
from `return-completeness-check.sh`. Unlike `gate-stop`, which halts the pipeline, `gate-warn`
events are informational — they signal a potential issue without changing the phase result.

```bash
# Warn-only (Phase 1): unchecked boxes detected but pipeline continues
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|META|gate-warn|info|RETURN_INCOMPLETE — UNCHECKED_BOXES (unchecked=2/5, artifact=openspec)" >> "$LOG_FILE"
```

Gate-warn codes:
- `RETURN_INCOMPLETE` — one or more `- [ ]` boxes remain unchecked in tasks.md
  or simple-fix.md's `## Completion Checklist`. Emitted by the return-completeness
  gate in warn-only mode (Phase 1). In enforce mode (Phase 2+), this flips to the
  `gate-stop` channel as `RETURN_INCOMPLETE` and triggers `IMPLEMENT_RETRY` (max 2).
- `COMPLETION_CHECKLIST_MISSING` — simple-fix.md lacks a `## Completion Checklist`
  section (artifact predates Section 2 fast-follow). Treated as `error` (exit 2) by
  the gate script; signals the artifact needs re-appraisal.

`gate-warn` counters are tracked separately from `gate-stop` in retro.sh aggregation
(`GATE_WARN_TOTAL` vs `GATE_STOP_TOTAL`) — they drive Phase 2 false-positive measurement,
not severity classification.

### Fleet controller entries

The fleet controller writes these META entries when it intervenes:

```bash
# Intervention — fleet_kill_pipeline writes this when killing a pipeline
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|META|fleet-intervention|warn|KILL|reason=auto-kill" >> "$LOG_FILE"

# Outcome — fleet_kill_pipeline finalizes the pipeline with a stopped outcome
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|META|outcome|info|stopped: fleet-kill|auto-kill" >> "$LOG_FILE"

# Restart — fleet_restart_pipeline writes a restart entry (before restart marker)
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|META|fleet-restart|info|restart auto-restart" >> "$LOG_FILE"

# Restart marker — signals the skill layer to spawn a new pipeline agent
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|META|fleet-restart-marker|info|restart-intent auto-restart" >> "$LOG_FILE"
```

`fleet-restart-marker` entries are scanned by the monitor loop — each one triggers an `ACTION:spawn-restart` directive. `fleet-intervention` and `fleet-restart` entries serve as audit trail; `fleet_can_restart` counts `fleet-restart` entries to enforce the `FLEET_MAX_RESTARTS` circuit breaker.

### Verifier-result entries (Phase 0 RLVR)

Uniform verifier output from all verifier sites. Written by `write_verifier_result` in `lib/verifier-result.sh`. The MSG is a JSON object with fixed fields:

```bash
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|META|verifier-result|info|{\"verifier\":\"gate_check\",\"verdict\":\"PASS\",\"score\":1.0,\"criteria_met\":1,\"criteria_total\":1,\"attempt\":1,\"phase\":\"GATE\"}" >> "$LOG_FILE"
```

JSON fields: `verifier` (identifier, e.g. `unit_tests`, `playwright_uat`, `gate_check`), `verdict` (PASS/FAIL/WARN/BLOCK), `score` (0.0–1.0 on the `_compute_actual_confidence` scale), `criteria_met` (integer), `criteria_total` (integer), `attempt` (integer), `phase` (pipeline phase token).

**MSG parsing rule** (applies to ALL consumers of verifier-result and model entries): join fields 5+ with awk (`awk -F'|' '{s=$5; for(i=6;i<=NF;i++) s=s"|"$i; print s}'`), NEVER `cut -f5`. JSON payloads contain `|` characters that `cut -f5` silently truncates.

### Model identity entries (Phase 0 RLVR)

Written by `spawn_agent_pre` at every agent spawn. Records which model executed each phase:

```bash
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|META|model|info|{\"phase\":\"IMPLEMENT\",\"model\":\"claude-sonnet-4\"}" >> "$LOG_FILE"
```

The model value resolves from the `ANTHROPIC_MODEL` environment variable, falling back to `unknown` when unset or empty (G4: the "router context" branch documented earlier was never implemented). Downstream consumers SHALL treat `unknown` as a first-class identity, never an error. The same model value is also appended as `MODEL=<value>` to the spawn-meta file.

### Phase-inspector entries (Phase 1 RLVR)

Written by the `guidance-extractor-agent` after each pipeline phase completes (post-IMPLEMENT, post-VERIFY, post-PR-REVIEW). Provides per-phase inspection verdicts by reading `META|verifier-result` entries and checking for known defect patterns. The inspector is advisory only — it never gates the pipeline.

```bash
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|META|phase-inspector|info|{\"phase\":\"IMPLEMENT\",\"verdict\":\"PASS\",\"signals\":0,\"detail\":\"All verifiers clean: unit_tests PASS, return_completeness complete, gate_check PASS\",\"verifiers_consulted\":[\"unit_tests\",\"return_completeness\",\"gate_check\"],\"patterns\":[]}" >> "$LOG_FILE"
```

JSON fields:
- `phase` (string): pipeline phase being inspected — IMPLEMENT, VERIFY, or PR-REVIEW
- `verdict` (string): overall inspection verdict — PASS (0 patterns), WARN (≥1 WARN pattern, 0 FAIL), FAIL (≥1 FAIL pattern)
- `signals` (integer): count of detected defect patterns
- `detail` (string): human-readable summary, ≤ 200 characters
- `verifiers_consulted` (array of strings): verifier IDs read for this inspection
- `patterns` (array of objects): detected patterns, each with `pattern` (identifier), `severity` (warn/fail), `evidence` (specific citation)

Detection patterns (Phase 1, all WARN severity):
1. `flaky_tests` — PASS verifier + FAIL verifier on overlapping criteria
2. `missing_requirement` — PR review OK but critique/audit found gaps
3. `trivial_pass` — any verifier PASS with criteria_total ≤ 1
4. `verdict_disagreement` — two verifiers in same phase disagree
5. `incomplete_implementation` — PASS verifier + RETURN_INCOMPLETE gate-warn

**MSG parsing rule**: use awk-join (`awk -F'|' '{s=$5; for(i=6;i<=NF;i++) s=s"|"$i; print s}'`), never `cut -f5`. JSON payloads contain `|` characters.

**Advisory-only semantics**: phase-inspector verdicts are observational. They do not gate pipeline decisions. The router's retry/advance decisions use the phase agent's VERDICT, not the inspector verdict. Phase 2 (Guidance Store) may add optional gate integration after patterns are validated.

**Skip entries**: when no verifier-result entries exist for a phase (e.g., Phase 0 not yet shipped), `phase-inspector.sh` writes a skip entry with `verdict: "WARN"`, `signals: 0`, `verifiers_consulted: []`, and skips agent spawn — zero token burn on empty phases.

**Consumers**: Phase 2 Guidance Store (accumulate and classify), Phase 3 Post-Mortem (cross-run pattern analysis), Phase 4 Reward Shaping (prompt adjustment).

### Post-mortem entries (Phase 3 RLVR)

Written by `pipeline-postmortem.sh` at the end of every pipeline run (via the router's EXIT trap or fleet-controller's kill path). Provides end-of-run analysis: signal counts, exit path derivation, filed issue counts, and mislabeled-outcome detection.

```bash
# "started" marker — written before any analysis begins (idempotency anchor)
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|META|postmortem|info|{\"run_id\":\"CRE-123-2026-08-08T10:00:00Z\",\"status\":\"started\",\"exit_code\":1}" >> "$LOG_FILE"

# Summary entry — written after analysis completes
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|META|postmortem|info|{\"run_id\":\"CRE-123-2026-08-08T10:00:00Z\",\"status\":\"completed\",\"exit_path\":\"gate-stop:EXEC_NO_ARTIFACT\",\"signals\":1,\"filed\":0,\"skipped_known\":0,\"deferred_summary\":1,\"mislabeled_outcome\":\"false\"}" >> "$LOG_FILE"
```

**Status values**: `started` (analysis in progress), `completed` (analysis finished), `clean` (no signals found, no filing needed), `skipped` (gh unavailable, analysis skipped).

**Warn entries**: `skipped: gh unavailable` — written when `gh` CLI is not installed or not authenticated.

**Consumers**: fleet-dashboard.sh (AUTO-RETRO column), fleet-feedback.sh (mislabel detection), Phase 4 reward shaping.

**Fleet-kill ordering**: On fleet-killed pipelines, `META|postmortem` entries MAY appear after `META|outcome`. This is a sanctioned exception to rule 1: fleet-intervene.sh owns the outcome write on kill paths (outcome must be written by the kill path, not the postmortem script), and postmortem runs as a deferred epilogue.

### Planned/unplanned asymmetry

Confidence-weighted verdict processing applies only to planned tickets. Consumers of `META|verifier-result` SHALL check for `META|from-planned|info|true` before applying confidence weighting. Unplanned tickets get the verdict but not confidence-weighted treatment.

### RETURN_INCOMPLETE coexistence

`META|gate-warn|RETURN_INCOMPLETE` and `META|verifier-result` may coexist in the same log. Downstream consumers SHALL read only the verifier-result line, never both, to avoid double-counting.

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
| `PR_FEEDBACK_EXHAUSTED` | `PR_FEEDBACK_CYCLE` reached 3 — reconciliation cycle capped, needs human review (Step 5.5) |
| `BRANCH_DIRECTIVE_INVALID` | Parent epic has a malformed `## Branch Directive` block — gate-stop, no fallback (Step 0.5) |

## Ordering guarantees

1. **Outcome is final**: `META|outcome|info|<result>` MUST be the last substantive entry in the log. It SHALL be written after all MAINTENANCE phase steps and retro-trigger evaluation are complete, on every exit path (success, gate-stop, no-op, crash).
2. **Bracket uniqueness**: Each phase-step transition produces exactly one `waiting` entry and exactly one terminal entry (`done`, `fail`, or `skip`). Writers guard against duplicates by tail-checking the last log line before appending.
3. **Token META accuracy**: `META|tokens` lines carry the correct PHASE label matching the agent that consumed those tokens. The phase is resolved from the spawn-meta file (`/tmp/ticket-auto-{ID}-spawn-meta.txt`), not the volatile ctx file.
4. **Retro-trigger before outcome**: `META|retro-trigger` SHALL appear before `META|outcome`, not after. Retro-trigger entries are idempotent — at most one per pipeline run.
5. **MAINTENANCE before outcome**: On success and no-op paths, all `MAINTENANCE|*` entries SHALL appear before `META|outcome`.

## Rules

1. Write `|start|` before the step begins, `|done|` or `|fail|` after it finishes.
2. Only write steps you actually execute — don't pre-declare future steps.
3. `MSG` should be brief (under 60 chars). Put details in trace.md, not here.
4. If `$LOG_FILE` is unset, skip logging — don't create a file in the wrong place.
5. Before writing `waiting`, `done`, `fail`, or `retro-trigger` entries, tail-check the log: if the last line already contains the same `PHASE|STEP|STATUS` pattern, skip the duplicate write.

## Heartbeat log

A companion heartbeat log captures decisions, fallbacks, retries, and liveness signals at fine granularity. See [`pipeline-heartbeat-format.md`](pipeline-heartbeat-format.md) for the format specification.

## Claude log

A third companion log (`{TICKET-ID}-claude.log`) uses the same `ISO|PHASE|STEP|STATUS|MSG` format with no MSG length restriction. It is written by the orchestrator at three points per phase:

- **Before each agent spawn** — `STEP=handoff STATUS=info` with the full input context (complexity, artifact path, autonomy mode, from_step)
- **After each agent success** — `STATUS=done` with verbose result data (full paths, branch name, exact counts)
- **After each agent failure** — `STEP=context STATUS=fail` with diagnostic context (last heartbeat event, dir existence, resolved paths)

Written via `cl_write` / `cl_init` helpers in `lib/heartbeat.sh`. Available to sub-agents via `$CLAUDE_LOG_FILE` env var. Useful for container debugging where the 60-char MSG limit of the pipeline log hides critical context.
