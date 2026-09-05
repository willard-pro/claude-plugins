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
`setup-workspace` `complexity-sweep` `prior-art` `codebase-investigation` `claim-verify` `handoff`

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

### Relation to the phase-result `VERDICT` field

These are the **router's** tokens, written by `spawn_agent_post`. The `VERDICT` inside a
`=== PHASE_RESULT ===` block is the **agent's own** claim, on a different channel, and the
two vocabularies are not identical. They line up like this:

| Event | Router token (`spawn_agent_post`) | Phase-result `VERDICT` |
|---|---|---|
| VERIFY passed | `PASS` | `PASS` |
| VERIFY failed | `FAIL` | `FAIL` |
| PR review ✅ | **`OK`** | **`PASS`** |
| PR review ⚠️ | `WARN` | `WARN` |
| PR review ❌ | `BLOCK` | `BLOCK` |

`OK` and `PASS` denote the same ✅ event. The router keeps `OK` because `detect-resume.sh`
already counts on it; the phase-result enum keeps `PASS` because it is shared across all
three loop-bearing phases and a phase-specific synonym would make the enum
phase-dependent. A consumer correlating the two channels for the same run must apply this
mapping — it is the one place their vocabularies diverge.

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

### Code review cycle marker

`IMPLEMENT`'s `code-review` terminal entry carries a `cycle#N` counter in `MSG`, same
convention as PR feedback reconciliation. The fix-and-re-review loop is capped at 3 cycles;
only `medium`-severity-and-above findings are blockers and drive re-spawns, `low`-severity
findings are recorded to notes.md but never gate the commit. Exhausting all 3 cycles with
medium+ findings still open is a gate-stop (`CODE_REVIEW_EXHAUSTED`, see below):

```bash
echo "...|IMPLEMENT|code-review|done|cycle#1 clean" >> "$LOG_FILE"
echo "...|IMPLEMENT|code-review|fail|cycle#3 CODE_REVIEW_EXHAUSTED" >> "$LOG_FILE"
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
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|META|branch-context|info|base=develop;integration=;source=default;ticket=feat/CRE-123-fix-auth;uat-policy=per-ticket;merge-policy=" >> "$LOG_FILE"
```

`MSG` grammar: semicolon-delimited key=value pairs. Keys: `base` (always present),
`integration` (empty when base=integration), `source` (flag|epic-directive|default),
`ticket` (always present), `uat-policy` (per-ticket|epic), `merge-policy`
(manual|on-all-children-done|empty). Values MUST NOT contain `|` per the pipe-delimited format
constraint. Branch names are already validated to exclude `;` and `|` by `_validate_branch_name`,
so the semicolon grammar is safe.

`uat-policy` and `merge-policy` are appended in the order they were added, so a log written
before either key existed remains a valid prefix and still parses. `detect-resume.sh` resolves
an absent `uat-policy` to `per-ticket` rather than leaving it empty, so no consumer re-derives
the default — but resolves an absent `merge-policy` to empty, not a default: empty means the
ticket has no epic directive at all, which is a different signal from an epic explicitly
declaring `manual`. `ticket-pr-review` Step 6b reads `merge-policy` (alongside the pipeline's
`autonomy`) to decide whether it may merge a passing PR directly.

### UAT policy decision entry

Written at the UAT-vs-Done routing decision (`ticket-pr-review` Step 6a), and by
`ticket-verify` when it refuses a UAT run under `epic` policy. It records which policy was in
force so that any ticket reaching `Done` without an individual UAT step is explainable from the
log alone.

```bash
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|META|uat-policy|info|epic" >> "$LOG_FILE"
```

`MSG` is the resolved policy: `per-ticket` or `epic`. Under `epic` the child transitions
`Review → Done` via `pr-review-pass-done`; under `per-ticket` with a UAT target it transitions
`Review → UAT` via `pr-review-pass-uat`. The decision itself is computed by `uat_decide_trigger`
in `lib/branch-resolve.sh`, never inferred from ambient environment.

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

### Worker exit entries (worker-reap-recovery)

Written by fleetd (`fleet-controller/fleetd/supervisor.py`) at reap time, for every worker exit — natural or fleet-killed:

```bash
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|META|worker-exit|done|code=0 type=exit gen=1 killed_by_fleet=false" >> "$LOG_FILE"
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|META|worker-exit|fail|code=1 type=exit gen=2 killed_by_fleet=false" >> "$LOG_FILE"
```

`STATUS` is `done` only for a clean `exit_type=exit, exit_code=0`; anything else (non-zero exit, or a signal-derived `exit_type` such as `SIGINT`/`SIGKILL`) is `fail`. `MSG` carries the same fields as the per-generation `{tid}-gen{N}-exit.json` exit record: `code`, `type`, `gen`, and `killed_by_fleet` (`true` only when fleetd's own `kill_worker()` succeeded — never inferred from an exit code, since a headless `claude -p` worker exits 0 on SIGINT).

`stop-failure.sh` (the `StopFailure` hook) appends a second, independent entry when a worker's turn ends on an API error after retries are exhausted:

```bash
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|META|worker-api-error|warn|turn ended on API error (session=<uuid>)" >> "$LOG_FILE"
```

Both are additive — schema version stays **1**.

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

### Run identity entries (Branch A, Commercial Evidence MVP)

Written by `lib/run-identity.sh`, the single writer for these three META keys — both
`lib/ticket-preamble.sh` (fleetd path) and `skills/ticket-auto/SKILL.md` (manual router)
call into it rather than each stamping their own.

**Run window**: a "run" is the span from one `META|run-id` line to the next `META|outcome`
line (or EOF, if the run hasn't ended yet). A pipeline log can hold more than one run —
a ticket re-dispatched after a hold gets a second one. An **open run** exists iff the log's
last `META|run-id` line is later (by line position — the log is append-only) than its last
`META|outcome` line; `run_identity_current` reads this, and `run_identity_stamp` (without
`--new`) is a no-op whenever it finds one already open, which is what makes fleetd's
per-phase preamble re-entry collapse to one `META|run-id` line per run.

```bash
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|META|run-id|info|{\"run_id\":\"CRE-123-2026-09-05T18:00:00Z-4821\",\"gen\":null,\"trigger\":\"manual\",\"pid\":4821}" >> "$LOG_FILE"
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|META|version|info|{\"ticket_auto\":\"0.39.0\",\"fleet\":null,\"cc\":\"2.1.261 (Claude Code)\",\"model_default\":null}" >> "$LOG_FILE"
```

`META|run-id` fields: `run_id` (string, `{TID}-{ISO}-{pid}`), `gen` (integer|null, from
`FLEET_GENERATION`, null until fleet-controller sets it), `trigger` (`fleetd`|`manual`, from
`FLEET_WORKER_PID` or `TICKET_RUN_TRIGGER=fleetd`), `pid` (integer).

`META|version` is written alongside `run-id` in the same `run_identity_stamp` call, one line
per run: `ticket_auto` (this plugin's `plugin.json` version), `fleet` (`FLEET_VERSION`, null
until fleet-controller sets it), `cc` (`CLAUDE_CODE_VERSION` or `claude --version`),
`model_default` (`ANTHROPIC_MODEL`). Every field resolves to `null` independently when its
source is unavailable — same precedent as `META|model`'s `unknown` fallback — so one missing
source never blocks the write of the other three or of the line itself.

```bash
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|META|ticket-meta|info|{\"createdAt\":\"2026-09-01T00:00:00Z\",\"startedAt\":null,\"estimate\":3,\"priority\":2,\"type\":\"bug\",\"planned\":true,\"labels\":[\"bug\",\"planned\"]}" >> "$LOG_FILE"
```

`META|ticket-meta` is ticket-scoped, not run-scoped: written once ever per ticket (guarded by
`grep -q '|META|ticket-meta|'`), since `createdAt`/`estimate`/`priority`/labels don't change
run to run. Requires `LINEAR_API_KEY`; no-ops silently without it, and fails soft on any
Linear error (never blocks the caller). `type` is the first ticket label matching a known
type in `lib/template-select.sh`, or `null` if none match.

All three are additive — schema version stays **1**. A log predating this change has no
`META|run-id` line; `pipeline-postmortem.sh`'s run_id derivation falls back to its prior
"ticket ID + log's first line ISO" behavior in that case.

### pr-created, cache-tokens, complexity (Branch B, Commercial Evidence MVP)

Three additive META lines feed `lib/run-summary.sh`'s `run` event (see
"runs.jsonl" below).

```bash
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|META|pr-created|info|{\"pr\":42,\"url\":\"https://github.com/acme/repo/pull/42\",\"repo\":\"acme/repo\"}" >> "$LOG_FILE"
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|META|cache-tokens|info|VERIFY:8/2" >> "$LOG_FILE"
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|META|complexity|info|simple" >> "$LOG_FILE"
```

`pr-created` is written once per PR by `skills/ticket-verify/SKILL.md` (both
the new-PR and existing-PR code paths converge on one capture site) and by
`lib/epic-branch.sh` for epic integration PRs (`"epic":true`, only when
`$LOG_FILE` is set). Fields: `pr` (integer), `url` (string), `repo`
(`OWNER/REPO` or `null` if unparseable). It is preferred over the older
`PR-REVIEW|checkout-pr|done|<N>` line (number only, no URL/repo) wherever
both exist in a run's window.

`cache-tokens` is written by `hooks/token-tracker.sh` alongside (never
instead of) the existing `META|tokens` line, as `${PHASE}:${CACHE_READ}/${CACHE_CREATE}`.
It is a separate grammar rather than a fourth `META|tokens` field because
four existing consumers (`supervisor.py`, `otel.py`, `dashboard.py`, dexter's
`logparse.py`) parse `META|tokens`'s payload by splitting every slash field —
adding one would silently corrupt all four.

`complexity` is written once per ticket by `lib/gate-check.sh`'s `_gate_entry`
(guarded by a grep for its own prior output, same pattern as
`META|ticket-meta`), present on both the standard gate route and the
planned-ticket fast-path — both flow through `_gate_entry`, so one guarded
write site covers both.

All three are additive — schema version stays **1**.

### runs.jsonl — post-outcome evidence channel (Branch B, Commercial Evidence MVP)

`META|outcome` stays the pipeline log's contractual last line (both terminal
classifiers — `supervisor.py`'s `_log_reached_terminal` and
`fleet-reconcile.sh`'s `fleet_ticket_terminal_state` — read only the log's
last line). Every fact that only becomes knowable **after** outcome — merge
truth, human approval, cost (Branch C) — is recorded instead in
`logs/runs.jsonl`, an append-only, `flock`-guarded file living beside the
pipeline logs. Nothing in this capability ever appends to the pipeline log
past `META|outcome`.

Four event kinds, one writer each, folded by consumers on `tid`/`run_id`:

```bash
# run — lib/run-summary.sh's run_summary_json, appended once per run by
# lib/pipeline-finalize.sh's post-outcome sequence (idempotent: guarded on
# an existing run event for this run_id).
{"kind":"run","tid":"CRE-40","run_id":"CRE-40-2026-09-05T18:00:00Z-4821","gen":null,"trigger":"manual","versions":{"ticket_auto":"0.41.0","fleet":null,"cc":"2.1.261","model_default":null},"models":["claude-sonnet-4"],"complexity":"simple","type":"bug","planned":false,"estimate":null,"autonomy":"auto","ticket_created_at":"2026-09-01T00:00:00Z","started_at":"2026-09-05T18:00:00Z","ended_at":"2026-09-05T18:10:00Z","outcome":"completed: STEP_6","exit_code":0,"gate_held_at":null,"resumed_after_hold_ms":null,"verify_attempts":1,"review_iterations":0,"fix_rounds":0,"reconcile_cycles":0,"gate_stops":[],"pr":{"pr":42,"url":"https://github.com/acme/repo/pull/42","repo":"acme/repo"},"merge_decision":"merged","tokens":{"in":1000,"out":500,"cache":100,"cache_read":80,"cache_write":20},"phase_elapsed_ms":{"VERIFY":5000},"observed_at":"2026-09-05T18:10:01Z"}

# merge — lib/merge-poll.sh, the single merge-truth implementation. One or
# more per PR as state changes (open → merged/closed/stale/unknown-repo).
{"kind":"merge","tid":"CRE-40","pr":42,"repo":"acme/repo","state":"merged","merged_at":"2026-09-05T18:20:00Z","merge_sha":"abc123","observed_at":"2026-09-05T18:20:05Z"}

# human — lib/pipeline-finalize.sh, once per run when LINEAR_API_KEY is set.
# approved_by/approved_at come from Linear's own IssueHistory, not inferred
# from pipeline-resume timing.
{"kind":"human","tid":"CRE-40","run_id":"CRE-40-2026-09-05T18:00:00Z-4821","approved_by":"Jane","approved_at":"2026-09-05T17:55:00Z","human_actions":2,"comment_words":37,"observed_at":"2026-09-05T18:10:01Z"}

# cost — Branch C (fleet-controller), not written by this branch.
```

`run_summary_window LOG_FILE` (the lines from the last `META|run-id` to EOF)
scopes per-run counters (`verify_attempts`, `review_iterations`, `fix_rounds`,
`reconcile_cycles`) to the current run — a held-then-resumed ticket has two
runs in one log, and a naive whole-log grep would double-count the held run's
attempts into the resumed run's. Counters use `detect-resume.sh`'s exact grep
patterns, copied rather than sourced (that script has zombie-synthesis side
effects wrong to trigger from a post-outcome summarizer).

`pipeline-finalize.sh`'s post-outcome sequence runs strictly after
`META|outcome` is on disk: (1) append the `run` event, guarded so a retried
finalize call never duplicates it; (2) if `run.pr` is present, a one-shot
`merge_poll_sweep` under `timeout 20`; (3) if `LINEAR_API_KEY` is set, append
a `human` event. Every step is wrapped `|| true` and never alters the
caller's exit code or touches the pipeline log.

`merge-poll.sh`'s candidate selection re-polls no more than once per
`MERGE_POLL_MIN_INTERVAL_SECS` (default 600) and marks a PR `state:"stale"`
once its run is older than `MERGE_POLL_MAX_AGE_DAYS` (default 14) with no
terminal state yet — converting "we stopped checking" into an honest event
instead of silence. A `pr` with no resolvable `repo` gets `state:"unknown-repo"`
exactly once, never retried.

No schema change: `runs.jsonl` is created on first append, is independent of
the pipeline log's own schema version, and this section is purely additive.

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

### Claim-verifier entries (ticket-appraise Step 3.5)

One entry per claim independently re-checked by the claim-verifier agent — negative-existential
assertions in `## Initial Investigation`/`## Blast Radius`, and `[agent-resolvable]` open
questions being closed inline. `MSG` carries the verdict and claim text (kept under 60 chars
where possible; longer claims are truncated — the full text and evidence live in notes.md, not
the log):

```bash
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|META|claim-verify|info|Claim 1: REFUTED — nothing reads JAVA_OPTS" >> "$LOG_FILE"
```

The step's overall result is a normal `META|gate-result` entry (see above), not a new gate-stop
code — a REFUTED verdict is a self-correcting loop within appraise (fix notes.md, re-verify),
not a structural failure requiring human intervention:

```bash
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|META|gate-result|pass|claim-verify: 3 confirmed, 0 refuted, 1 unverifiable" >> "$LOG_FILE"
```

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

### Phase-result entries (rlvr-phase-result-contract)

A loop-bearing phase agent's own claimed verdict, made machine-readable. Written by
`lib/phase-result-parse.sh`, which parses the terminal `=== PHASE_RESULT ===` block from
the agent's captured return (`./logs/{TID}-{phase}-agent.log`). The MSG is a JSON object:

```bash
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|META|phase-result|info|{\"schema_version\":1,\"phase\":\"VERIFY\",\"verifier\":\"playwright_uat\",\"claimed_verdict\":\"PASS\",\"criteria_met\":3,\"criteria_total\":3,\"attempt\":1,\"evidence\":\"exercised AC1-AC3\",\"unaddressed\":\"\",\"extra\":{},\"parse_status\":\"ok\",\"parse_error\":\"\"}" >> "$LOG_FILE"
```

JSON fields: `schema_version` (integer), `phase` (`IMPLEMENT`|`VERIFY`|`PR-REVIEW`),
`verifier` (one of the 14 established verifier ids), `claimed_verdict`
(`PASS`|`FAIL`|`WARN`|`BLOCK`|`UNKNOWN`), `criteria_met`, `criteria_total`, `attempt`
(integers), `evidence`, `unaddressed` (strings), `extra` (object of unknown keys the
emitter supplied), `parse_status` (`ok`|`invalid`|`absent`), `parse_error` (string).

The full field set, enums and worked examples are in
[docs/phase-result-schema.md](docs/phase-result-schema.md).

Emitted only for the three loop-bearing phases — the phases whose outcome is otherwise
recoverable only by reading agent prose. `APPRAISE`, `EXEC` and `GATE` already publish
their outcome via `META|gate-result` and `META|artifact`; `MAINTENANCE` returns its own
`PRESCAN_RESULT`.

`phase` is always populated, including on a rejected record, so a consumer can attribute
every entry with `jq` alone and never by position. A retried phase writes one entry per
attempt, each carrying its own `attempt`.

**MSG parsing rule**: join fields 5+ with awk (`awk -F'|' '{s=$5; for(i=6;i<=NF;i++) s=s"|"$i; print s}'`), NEVER `cut -f5` — JSON payloads contain `|`.

**Observe-only**: nothing routes on this channel today. The router continues to route on
its `RESULT=done|fail` and `VERDICT=` tokens. Emission rate must be measured in real runs
before any consumer reads it.

#### UNKNOWN fallback rule

Emission depends on an agent following a prompt instruction, and **no deterministic check
can observe whether an LLM followed an instruction**. An absent block, a malformed block,
or a `claimed_verdict` of `UNKNOWN` therefore means *absence of information* — never
failure, and never success.

A consumer that routes on phase results SHALL, on an absent or `UNKNOWN` claim, fall back
to the whole-run classification produced by `fleet_ticket_terminal_state`
(`fleet-controller/lib/fleet-reconcile.sh`) and proceed exactly as it does today. It
SHALL NOT synthesize a verdict, infer one from adjacent log lines, or read a missing
claim as either outcome.

Per-phase data is an enhancement over whole-run data, never a replacement that fails
closed. This rule is written down before any consumer exists so it is not decided under
pressure when the first one is.

### phase-result coexistence

`META|phase-result` is the agent's **claim**. `META|verifier-result` is a **verified**
result. They may coexist in the same log and SHALL NOT be double-counted: a consumer
computing verifier statistics SHALL read only `META|verifier-result`, and a consumer
computing per-phase routing signals SHALL read only `META|phase-result`.

The claim is deliberately never written through `write_verifier_result`. A claimed-PASS
sitting beside a verified-FAIL in the verifier array would trip detection pattern #1
(`flaky_tests`) and #4 (`verdict_disagreement`), inventing signals that do not exist. All
five verifier detection patterns are unaffected by this channel.

`META|phase-result` and `META|gate-warn|RETURN_INCOMPLETE` may likewise coexist — the
first is what the agent said, the second is what the artifact shows. Same rule: read one,
not both.

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
| `PR_REVIEW_EXHAUSTED` | `ITERATION` reached 3 — the pr-review → pr-iterate → re-implement → verify cycle is capped, needs human review (Step 4.6) |
| `BRANCH_DIRECTIVE_INVALID` | Parent epic has a malformed `## Branch Directive` block — gate-stop, no fallback (Step 0.5) |
| `CODE_REVIEW_EXHAUSTED` | Code-review fix-and-re-review loop reached 3 cycles with medium+ severity findings still open (Step 4b) |
| `RECONCILE_EXHAUSTED` | `RECONCILE_CYCLE` reached 3 — gate hold → re-approve → re-hold cycle capped, needs human review (Step 3.5) |

## Ordering guarantees

1. **Outcome is final**: `META|outcome|info|<result>` MUST be the last substantive entry in the log. It SHALL be written after all MAINTENANCE phase steps and retro-trigger evaluation are complete, on every exit path (success, gate-stop, no-op, crash).
2. **Bracket uniqueness**: Each phase-step transition produces exactly one `waiting` entry and exactly one terminal entry (`done`, `fail`, or `skip`). Writers guard against duplicates by tail-checking the last log line before appending.
3. **Token META accuracy**: `META|tokens` lines carry the correct PHASE label matching the agent that consumed those tokens. The phase is resolved from the spawn-meta file (`/tmp/ticket-auto-{ID}-spawn-meta.txt`), not the volatile ctx file.
4. **Retro-trigger before outcome**: `META|retro-trigger` SHALL appear before `META|outcome`, not after. Retro-trigger entries are idempotent — at most one per pipeline run.
5. **MAINTENANCE before outcome**: On success and no-op paths, all `MAINTENANCE|*` entries SHALL appear before `META|outcome`.
6. **Nothing follows outcome** (Branch B, Commercial Evidence MVP): no component SHALL append to the pipeline log after `META|outcome` has been written. Every post-outcome fact (merge truth, human approval, cost) goes to `logs/runs.jsonl` instead — see "runs.jsonl — post-outcome evidence channel" above. The sanctioned fleet-kill postmortem exception (rule 1's note above) predates this rule and is unaffected: it concerns `META|postmortem` timing relative to outcome, not a new pipeline-log append.

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
