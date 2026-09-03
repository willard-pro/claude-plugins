# CLAUDE.md — fleet-controller

Plugin-level guidance for Claude Code when working inside this plugin directory. See also: [repo-level CLAUDE.md](../CLAUDE.md) for marketplace-wide conventions.

## Plugin purpose

Parent orchestrator above ticket-planner and ticket-auto. Fleet controller dispatches planned tickets from initiative epics, monitors all active pipeline health via 14 detection engines, and aggregates execution feedback back to the planner. Bash-only — zero Claude agents, zero LLM reasoning. All detection and intervention is deterministic.

## Directory layout

```
fleet-controller/
  .claude-plugin/plugin.json      # Plugin manifest (name, version, hooks)
  skills/fleet-controller/        # Single skill: /fleet-controller
  lib/                            # Shared bash libraries
  lib/tests/                      # Test suites
  fleetd/                         # Python 3 supervisor daemon (stdlib-only)
  fleetd/schema.sql               # Fleet state store schema (SQLite, v1)
  fleetd/store.py                 # State store module — fleetd is its sole writer
  fleetd/phase_dispatch.py        # Phase-level dispatch — table loader, classifier, spawn construction, loop caps, spawn bracket
  fleetd/gate_hold.py             # Gate-hold reconciliation on its own cadence (a hold is a row, not a process)
  fleetd/preamble.py              # Once-per-ticket preamble caller — env file, log init, branch context, preflight
  fleetd/otel.py                  # OTel exporter — the ONLY module with a third-party dep
  fleetd/requirements-otel.txt    # That dep, optional and deliberately not project-wide
  docs/                           # Architecture and reference docs
```

## fleetd supervisor daemon

`fleetd` is a long-lived Python 3 daemon that owns worker process lifecycle. It replaces cron-based fleet invocation for spawn and kill operations. Detection engines remain in bash; fleetd invokes them as subprocesses.

**Key properties:**
- **Real PIDs**: Every worker's registry PID is the PID of a process fleetd forked. No sentinel zeros. (The legacy cron/monitor path writes a PID=0 sentinel until the spawn captures the real PID — startup reconciliation's live-process check compensates so such workers are not re-enqueued.)
- **Single-instance**: `fcntl.flock` on a pidfile; kernel releases on death.
- **Kill escalation**: Cooperative stop → SIGINT → SIGTERM → SIGKILL, signalling the process group, with a liveness re-check + zombie reap + fence write after each rung. The SIGINT rung exists because a headless `claude -p` worker exits **0** on SIGINT, not a signal-derived code — so `killed_by_fleet` attribution comes from `kill_worker()`'s own success, never from an exit code (a bare `exit 143`/`0` is not proof of anything). See "Worker exit records" below.
- **Crash recovery**: On restart, verifies surviving PIDs via `/proc/<pid>/stat` start time before adoption. When `/proc` start-time verification is unavailable, falls back to a cmdline substring match — a known limitation: a reused PID whose command line happens to contain the ticket ID could be misadopted (documented and tested, not fixed). Stale registry deletion preserves the last-known generation to `{tid}-last-generation` so a reconciled re-spawn continues the generation sequence. Startup orphan reconciliation (pipeline-log-based, read-only) re-enqueues `incomplete` tickets whose workers died while fleetd was down; the restart cap reuses the existing `FLEET_MAX_RESTARTS` mechanism.
- **Generation fencing**: Supervisor assigns generations above any fenced predecessor.
- **CLI alignment**: The `/fleet-controller` skill writes kill requests to `{state_dir}/kill-requests/`; fleetd processes them.
- **Worker identity**: fleetd generates a `--session-id <uuid>` before exec (not the `SessionStart` hook — that can't fire for a worker SIGKILLed before startup completes) and appends `--output-format json` for machine-readable `session_id`/`stop_reason`/`total_cost_usd`/`permission_denials`/`is_error` on the final turn. `FLEET_WORKER_PID` and `FLEET_WORKER_START_TICKS` (the child's own PID + `/proc` start-ticks) are stamped into the worker's env so the ticket-auto-pipeline watchdog (`spawn-helper.sh`) can tell a live worker from a stale/reused PID instead of trusting its own continued existence as a liveness proxy.
- **Explicit permission mode**: fleetd appends `--permission-mode ${FLEET_WORKER_PERMISSION_MODE:-bypassPermissions}` unless `CLAUDE_CMD` already specifies one. `dontAsk`/`auto` are deliberately never defaulted to — `auto` has no turn boundary in non-interactive mode, so one classifier denial silently poisons the rest of the run.
- **Deterministic-failure circuit breaker**: a streak of `FLEET_DETERMINISTIC_FAILURE_COUNT` consecutive fast (`< FLEET_DETERMINISTIC_FAILURE_SECS`) non-zero-exit workers halts dispatch (`spawn_enabled=False`) instead of burning `FLEET_MAX_RESTARTS` per ticket — a bad `CLAUDE_CMD` or expired auth would otherwise restart every ticket in the fleet to the cap before anyone noticed.

**Invocation:** `python -m fleet-controller.fleetd [--port PORT] [--state-dir DIR]`

**Gating:** Set `FLEETD_SPAWN_ENABLED=1` to enable worker spawning. Default is observe-only (detection + health API, no spawns).

**HTTP control surface (on-demand, loopback-bound):** alongside `GET /health`, fleetd serves `POST /dispatch` (scoped dispatch of one epic against the running daemon — same `fleet_dispatch_initiative` the skill and auto-sweep call, spawns immediately instead of waiting for the poll cycle), `POST /stop` (epic-scoped stop: purge queue, escalate-kill workers, write `stop-{epic}.json`; the single bash implementation is `fleet_stop_initiative`, also reachable via the skill's `stop` subcommand with the daemon down), and read-only `GET /workers`, `GET /workers/<tid>` (phase/anomalies/tokens/confidence per worker), `GET /queue`, `GET /epics`. Use these as an alternative to the `/fleet-controller dispatch` skill (on-demand, no restart-to-reconfigure) and to the fleet dashboard (per-ticket detail without re-rendering the whole fleet). Dispatch is the single start/resume/un-stop entry point: a stop-file gates every dispatch trigger path until an explicit `resume: true` clears it; the auto-sweep never clears. See README "HTTP API" for request/response shapes.

## Worker exit records & recovery

Every worker exit — natural or fleet-killed — is persisted per-generation, never overwriting a prior generation's record:

- `{tid}-gen{N}.json` / `{tid}-gen{N}.stderr` — captured stdout/stderr, opened `O_APPEND` at spawn.
- `{tid}-gen{N}-exit.json` — `{tid, generation, pid, exit_code, exit_type, exited_at, killed_by_fleet, terminal, session_id, last_assistant_message, action}` (+ `suppressed_retry_reason` when set). `killed_by_fleet` is `True` only when written from `kill_worker()`'s own success (never inferred from an exit code); `terminal` reflects whether the ticket's pipeline log already reached `META|outcome|`. `FLEET_WORKER_LOG_RETENTION` (default 3) generations of these files are kept per ticket; older ones are swept at each reap.
- `{tid}-gen{N}-hook.json` — written by the `Stop` hook (`ticket-auto-pipeline/hooks/stop-capture.sh`) with `last_assistant_message`, the only channel a headless worker's question travels through (`AskUserQuestion` is absent from the `-p` tool list). Merged into the exit record when present; absent whenever `Stop` doesn't fire — SIGINT and SIGKILL never trigger it, only a cooperative stop or a normal completion do. `hooks/stop-failure.sh` (`StopFailure`) instead appends a `META|worker-api-error|warn|` line to the ticket's own pipeline log when a turn ends on an API error.

A natural (non-fleet-killed) exit over a **non-terminal** pipeline log — the only reliable "did it actually finish" signal — triggers scoped reap-time recovery: `reconcile_orphaned_tickets(scope_tids=[tid])` calls the existing `fleet_reconcile_orphans` (bash), which shares the restart cap / stop-pin / dead-letter logic with startup reconciliation via `FLEET_RECONCILE_TIDS`. Exit code `127` (fleetd's own exec-failure sentinel) and a tripped circuit breaker both skip reconciliation — recorded as `action: "skipped: exec-failure"` / `"skipped: circuit-breaker (...)"` on the exit record — rather than burning a restart credit on a failure that will only repeat.

The pipeline log gains one new `META` step: `META|worker-exit|done|fail|code=<N> type=<T> gen=<G> killed_by_fleet=<bool>`, appended at reap time regardless of recovery outcome.

**Slack notifier** (`lib/fleet-notify.sh`): posts via `chat.postMessage` (never a webhook — webhooks don't return the `ts` a reply thread needs) for a non-terminal natural exit or a dead-letter, never for clean completion. Content is observed facts only — ticket, phase, generation, elapsed, exit classification, recovery decision, and the captured final assistant message when present — deliberately not classified as "question vs. failure." Follow-ups for the same ticket reply into the stored `{tid}-slack-thread.json` thread. Requires `SLACK_BOT_TOKEN` + `SLACK_CHANNEL`; absent or misconfigured, or a transport failure, degrades to a log-only line and never affects reaping, reconciliation, or the daemon.

## Skills

- `fleet-controller` — `/fleet-controller:fleet-controller` slash command. Subcommands: `detect`, `intervene`, `dashboard`, `dispatch`, `feedback`.
- `fleet-env-check` — `/fleet-controller:fleet-env-check` slash command. Validates `LINEAR_API_KEY`, `REPOS_ROOT`, the fleetd worker spawn command (`CLAUDE_BIN`/`CLAUDE_CMD`), and `jq`/`git`/`python3`/`gh`. Read-only, smaller scope than ticket-auto-pipeline's `ticket-env-check` (no hooks/spawn-permission/UAT_URL checks — those are ticket-auto concerns).

## Shared libraries (`lib/`)

| File | Exports |
|------|---------|
| `fleet-config.sh` | Configuration defaults: `FLEET_STATE_DIR`, `FLEET_KILL_GRACE_SECS`, `FLEET_KILL_VERIFY`, `FLEET_FENCE_ENFORCE`, `FLEET_QUEUE_LOCK_TIMEOUT`. State-directory resolver: `_fleet_state_dir <workspace>`. |
| `fleet-detect.sh` | 14 detection engines: `detect_phase_failures`, `detect_stalls`, `detect_zombies`, `detect_loops`, `detect_abandoned`, `detect_flow_failures`, `detect_auto_mode_blocks`, `detect_tool_errors`, `detect_planner_feedback`, `detect_blocked_by`, `detect_initiative_dispatch`, `detect_epic_branch_ready`, `detect_runaway_calls`, `detect_workspace_config`. Aggregator: `fleet_detect_all` outputs JSON. Sourceable library — no `set -euo pipefail`. |
| `fleet-intervene.sh` | Intervention executor: `fleet_kill_pipeline` (verified escalation with PID-reuse guard), `fleet_can_restart`, `fleet_restart_pipeline`, `fleet_stop_background`. flow.sh mutex-aware, `FLEET_DRY_RUN` guard. |
| `fleet-monitor.sh` | Monitor loop: `fleet_monitor_cycle` (one detection + intervention pass), `fleet_monitor_loop` (continuous polling with stop-file gating). Spawn queue consumption integrated with `flock` serialization. Dual-mode: interactive (ACTION:spawn-restart) or cron (JSONL queue). |
| `fleet-store.sh` | Read-only bash access to the fleet state store via the `sqlite3` CLI: `fleet_store_ready`, `fleet_store_sql`, `fleet_store_pipeline_rows`, `fleet_store_owner`, `fleet_store_is_owned`, `fleet_store_position`, `fleet_store_last_activity_epoch`, `fleet_store_in_flight`, `fleet_store_fence_allows`. Every function degrades to "no store" rather than failing, so a host with no fleetd — or no sqlite3 — keeps working on the file path. Ticket ids are validated against an identifier alphabet before reaching an SQL string, not escaped. |
| `fleet-registry.sh` | Run registry + generation fence helpers: `registry_write`, `registry_read`, `registry_pid`, `registry_generation`, `registry_exists`, `registry_clear`, `fence_write`, `fence_read`, `fence_is_superseded`, `fence_clear`. Per-ticket JSON files; no shared-file races. |
| `fleetd/otel.py` | OTel exporter — derives GenAI-convention spans from the pipeline and activity logs, ships OTLP. Pure stdlib at import time; the `opentelemetry` dependency is lazy and inside the exporter process. Supervised by fleetd under the fixed id `otel-exporter`. |
| `fleet-dashboard.sh` | Dashboard renderer: `fleet_render_dashboard` / `fleet_render_dashboard_from_data` (terminal health table) and `fleet_write_report` / `fleet_write_report_from_data` (markdown report). |
| `fleet-dispatch.sh` | Planned-ticket dispatch. Reads initiative epics from Linear via `lib/linear-api.sh`, validates `state:execution`, ensures the epic branch exists in **every** working repo under `REPOS_ROOT` before enqueue (multi-repo precondition — creation failure in any repo gate-stops with `EPIC_BRANCH_UNAVAILABLE`; sync failure in one repo warns and continues), resolves `blocked-by` dependencies, orders tickets by explicit dispatch rank (`Urgent`→`High`→`Medium`→`Low`→`No priority` last), writes spawn queue JSONL with `generation` field via shared `_fleet_queue_append` (flock, retry, dead-letter). Respects `FLEET_MAX_CONCURRENT` and `FLEET_DRY_RUN`. |
| `fleet-feedback.sh` | Feedback aggregation. Scans pipeline logs for `META\|planner-feedback`, groups by `{initiative-id}`, computes confidence drift, writes `$REPOS_ROOT/.ticket-auto/initiatives/{ID}/feedback/{rundate}.json`. |
| `fleet-env-check.sh` | Standalone (not sourced) — validates `LINEAR_API_KEY`, `REPOS_ROOT`, `GITHUB_PERSONAL_ACCESS_TOKEN`/`GH_TOKEN` (only required when `FLEET_EPIC_AUTO_PR=true`), `SLACK_BOT_TOKEN` (optional), the fleetd worker spawn command (`CLAUDE_CMD` if set, else `CLAUDE_BIN`) including its permission mode, and `jq`/`git`/`python3`/`gh` presence. Same `NAME\|STATUS\|VALUE\|LOCATION\|NOTE` pipe-delimited contract as ticket-auto-pipeline's `env-check.sh`. Masks secret values to `****` + last 4 chars — never echoes secrets in full. The live permission probe (an actual worker turn) is opt-in via `FLEET_ENV_CHECK_LIVE_PROBE=true` — off by default so `make test`/CI never spawns a real worker. |
| `fleet-notify.sh` | Deterministic Slack notifier: `fleet_slack_post <tid> <state_dir> <text>` (transport — `chat.postMessage`, persists/reuses `{tid}-slack-thread.json`'s `ts`), `fleet_notify_worker_event <tid> <state_dir> <event_type> [detail]` (`event_type`: `non-terminal-exit`\|`dead-letter` — builds the message from the ticket's exit record + pipeline log). Called from `supervisor.py`'s reap path and from `fleet-reconcile.sh`'s dead-letter branch. Fail-soft throughout. |
### Canonical library sources (dependency bridge)

Fleet controller depends on two libraries defined in `ticket-auto-pipeline/`:
- `linear-api.sh` — GraphQL API client (used by `fleet-dispatch.sh` for Linear queries)
- `heartbeat.sh` — Heartbeat log helpers (used by `fleet-monitor.sh`, `fleet-dashboard.sh`, `fleet-intervene.sh`)

These are sourced via `_source_if_missing` from `~/.claude/skills/lib/` (synced by the ticket-auto-pipeline SessionStart hook). Fleet controller does NOT maintain its own copies — it bridges to the canonical sources.

## Detection engines (14 total)

| # | Detector | What it catches | Severity range |
|---|----------|----------------|----------------|
| 1 | `detect_phase_failures` | `\|fail\|` entries on non-MAINTENANCE phases | 0–3 |
| 2 | `detect_stalls` | Stale heartbeats (last `orchestrator-waiting` or `watchdog\|alive`) | 0–3 |
| 3 | `detect_zombies` | Unresolved `\|waiting\|` entries with no matching terminal | 0–2 |
| 4 | `detect_loops` | Excessive `decision\|loop-back` counts vs configured caps | 0–3 |
| 5 | `detect_abandoned` | Pipeline log exists but no `META\|outcome` after threshold | 0–3 |
| 6 | `detect_flow_failures` | `retry\|flow-sh\|fail` entries in heartbeat log | 0–2 |
| 7 | `detect_auto_mode_blocks` | `check-approval\|fail` + denial patterns in agent logs | 0–2 |
| 8 | `detect_tool_errors` | Deduplicated tool errors in `{tid}-tool-errors.log` | 0–2 |
| 9 | `detect_planner_feedback` | Uncollected `META\|planner-feedback` entries | 0–1 |
| 10 | `detect_blocked_by` | Tickets with `blocked-by:{ID}` where blocker is Done | 0–1 |
| 11 | `detect_initiative_dispatch` | `state:execution` epics with undispatched planned tickets | 0–1 |
| 12 | `detect_epic_branch_ready` | Directive-carrying `state:execution` epics with all children Done; when `FLEET_EPIC_AUTO_PR=true`, actuates by calling `epic_branch_open_pr` once per tracked repo (never auto-merged) | 0–1 |
| 13 | `detect_runaway_calls` | Tool-call count within the current open spawn bracket above `FLEET_RUNAWAY_CALL_THRESHOLD`. Per-ticket. The inverse of `detect_stalls`' activity dimension: a runaway agent never stops calling tools, which looks as healthy to the watchdog as a stalled one looks dead | 0–1 |
| 14 | `detect_workspace_config` | Fleet-wide. The pipeline log directory is missing, is not a directory, or is unreadable. `FLEET_PIPELINE_LOG_DIR` defaults to the *relative* `./logs`, so a fleetd started from the wrong working directory monitors nothing and reports a clean bill of health — this is the only engine that fires when there is no pipeline to inspect. An existing but empty directory is a genuinely idle fleet and stays silent | 0–1 |

## Fleet state store (SQLite)

`fleetd/store.py` over `fleetd/schema.sql`. One database holding fleet-controller's operational state, replacing both the per-ticket JSON file conventions and the habit of answering "what is happening right now" by globbing `logs/*-pipeline.log` and re-parsing them on every sweep.

**Authorship decides authority.** Two classes of table, and the distinction is the design:

| Class | Tables | Authority |
|-------|--------|-----------|
| fleetd-authored | `tickets`, `workers`, `phase_runs` | Authoritative. fleetd performed the dispatch, so it knows these first-hand rather than inferring them. Nothing else writes them. |
| projection | `log_events`, `phase_results`, `activity_events` | The append-only logs remain the source of truth. On disagreement the log wins. All are rebuildable from the logs alone. |

**fleetd is the sole writer.** Every phase is an independent `claude -p` process and every tool call fires a `PostToolUse` hook; letting either write here would put dozens of uncoordinated short-lived writers on the write path. They keep appending to their logs — no change required of them — and fleetd ingests. WAL mode lets detectors and dashboards read while the writer works. Bash reads through `lib/fleet-store.sh`, which uses `sqlite3 -readonly`.

**Location and lifecycle.** `${FLEET_STATE_DIR}/fleet-state.db` (falling back to the workspace, via the same `_fleet_state_dir` resolver every other piece of fleet state uses), so it inherits the reboot-surviving lifecycle the run registry and fence markers already have. No separate backup: everything that matters for recovery is either derivable from the logs or re-imported from the registry files on next start. `log_events` and `activity_events` are pruned past `FLEET_STORE_EVENT_RETENTION_DAYS` (default 30) — safe because they are projections, and retention is about query cost, not durability. Deleting the database costs a slow cold start, never data.

**Startup.** `scan_workers` runs `_store_bootstrap` after registry adoption: `import_legacy_state` adopts surviving `*-run.json` and `*-fence` files, then `ingest_workspace` projects the logs. Idempotent, and also the recovery path when the database has been deleted. Each detection cycle calls `_store_sync` first, which ingests only the bytes written since the last pass.

**Fail-soft everywhere.** Every store call in `supervisor.py` goes through `_store_do`, which swallows all exceptions and warns once per distinct failure. A supervisor that cannot open its store must still supervise processes: losing the store costs a slower cold start, losing the supervisor loses the fleet. `FLEET_STORE_ENABLE=false` disables it entirely.

**Fence files are still written.** `_write_fence_files` writes both the store row and the `{tid}-fence` marker. `flow.sh`'s fence guard runs inside a worker and still reads the file; dropping it would let a superseded generation's Linear mutations through, which is the one thing the fence exists to prevent. The file goes away when every consumer reads the store.

**Detector input.** `fleet-detect.sh` reads pipeline-log lines through one seam, `_pipeline_rows`, which returns store rows when a store is available and file lines otherwise. One seam rather than a store-backed variant per engine: the filtering, thresholds and severities stay literally the same code, which is what makes the parity assertion (`lib/tests/test-fleet-store-parity.sh`) cheap and meaningful. The heartbeat-log engines (`detect_stalls`' heartbeat dimension, `detect_loops`) and the Linear-API engines are unaffected — the store does not ingest those inputs.

## OTel exporter

`fleetd/otel.py` derives OpenTelemetry GenAI-convention spans by tailing the
pipeline log and the agent-activity log, and ships them to an OTLP collector.
Off by default (`FLEET_OTEL_ENABLE=false`).

```bash
python3 -m pip install -r fleet-controller/fleetd/requirements-otel.txt
export FLEET_OTEL_ENABLE=true FLEET_OTEL_ENDPOINT=http://collector:4318
# fleetd spawns and supervises it; or run it standalone:
python3 fleet-controller/fleetd/otel.py --log-dir ./logs
```

**Derived, never hand-instrumented (D5).** No phase skill, hook, or fleetd
module emits a span at the point of action. A log `printf` and an OTel SDK call
sitting side by side eventually disagree — a new phase gets one and not the
other — and then two things claim to say what happened. There is one writer of
truth (the log) and one reader that translates it, which also means a new phase
skill is traced correctly by writing its log lines correctly and nothing else.

**Downstream, never authoritative (D5).** `detect-resume.sh`, the gate scripts,
`fleet-detect.sh` and `dashboard.py --fleet` all read the pipeline log directly.
Nothing waits on the exporter or notices its absence. Stopping it, or pointing
it at a collector that is down, costs traces and nothing else — the SDK retries
with backoff and the process exits cleanly.

**Span model.** One root span per ticket (`pipeline {TID}`), opened on first
sight and closed on `META|outcome`; one child span per phase/step bracket
(`invoke_agent {phase}.{step}`), from its `|waiting|` line to its terminal.
A `|fail|` terminal sets span status ERROR. Attributes follow the GenAI
conventions — `gen_ai.system`, `gen_ai.operation.name`, `gen_ai.agent.name`,
`gen_ai.request.model` from `META|model`, `gen_ai.usage.*` from `META|tokens` —
plus `ticket.id` and `pipeline.*`. Tool calls from the activity log attach to
the span that contains them as a count attribute and bounded span events, not
as spans of their own: one span per tool call would swamp a trace whose useful
unit is the phase.

**Why spans wait before emission.** `META|tokens|info|` is written by the
SubagentStop hook a moment *after* the router writes the phase terminal, so a
span emitted the instant its bracket closes always loses its token counts.
Completed spans sit in a buffer for `FLEET_OTEL_SPAN_GRACE_SECS` (30) so late
enrichment attaches. A ticket reaching its outcome flushes its spans
immediately — nothing more can arrive for a finished ticket.

**Supervision (task 8.5).** The exporter is a fleetd child under the fixed
identifier `otel-exporter`: spawned through the same `spawn_worker` fork/exec,
a run-registry entry while active, reaped by the same `ChildReaper`, stopped
through the same kill escalation, respawned on crash with a bounded backoff
(5s → 30s → 2m → 10m). Its exit is branched away from the ticket reap path
before anything else runs: sending it down that path would write a
`META|worker-exit` line into an `otel-exporter-pipeline.log`, which
`fleet_detect_all` would then glob and report as a stuck pipeline — the monitor
manufacturing findings about itself.

**The one dependency (D11).** `opentelemetry-sdk` is the repository's first
third-party Python dependency, and it is quarantined to this module.
`supervisor.py` and `store.py` stay pure-stdlib; the SDK import is lazy and
inside the exporter *process*. Without the packages the exporter starts, says
so once on stderr, and emits nothing — fleetd is unaffected. CI runs the whole
suite without them for exactly that reason, then installs them in a later step
so the real SDK path is covered too.

## Severity scale

| Code | Name | Action |
|------|------|--------|
| 0 | OBSERVE | Log only, no action |
| 1 | WARN | Alert, no destructive action |
| 2 | KILL | Touch stop files, finalize pipeline log |
| 3 | KILL+RESTART | Kill + spawn new pipeline (unless `FLEET_AUTO_RESTART=false`) |
| 4 | KILL degraded to WARN | KILL severity downgraded (e.g., non-retryable gate-stop) |

## Key design decisions

- **Bash-only, zero LLM**: Fleet controller never spawns Claude agents. Detection, dispatch, intervention, and feedback are all deterministic bash scripts. The skill file is the human interface for manual intervention.
- **Detection engines are sourceable library**: `fleet-detect.sh` exports functions as a sourceable bash library — no `-euo pipefail`. Callers source it and call individual detectors or the aggregator `fleet_detect_all`.
- **Dispatch uses spawn queue file**: `fleet-dispatch.sh` writes to `{state_dir}/fleet-{instance}-spawn-queue.jsonl` (resolved via `_fleet_queue_file` — `FLEET_STATE_DIR` env or the workspace logs dir, never `/tmp`). The monitor loop or fleetd consumes the queue. Separation of concerns — dispatch identifies work, the consumer executes it.
- **Feedback writes to REPOS_ROOT, not Linear**: `fleet-feedback.sh` collects and structures data; agents act on it. The determinism boundary — fleet controller scripts are bash, Linear comment posting is an agent responsibility.
- **Intervention respects flow.sh mutex**: Kill/restart operations check for flow.sh locks (`/tmp/ticket-flow-{ID}.lock`) before acting. `FLEET_DRY_RUN=true` makes all interventions no-op. Kill escalation is verified: stop-files → grace → SIGTERM → grace → SIGKILL → re-verify, with PID-reuse guard. Fence markers prevent superseded zombie mutations at flow.sh.
- **Owned worker lifecycle**: Run registry (`{tid}-run.json`) records PID + generation at spawn. Generation fencing (`{tid}-fence`) blocks superseded workers at flow.sh (fleet-registry.sh). Per-ticket JSON files avoid shared-file write races. Durable state under workspace, not /tmp.
- **fleetd is externally supervised, not self-supervised**: A shipped systemd unit (`Restart=always`) or a documented cron watchdog restarts fleetd itself — see `docs/process-supervision.md`. The existing single-instance `flock` guard prevents a supervisor restart from racing a still-shutting-down instance into a second concurrent supervisor.
- **Epic branch creation is worktree-safe**: `ensure_epic_branch` creates the branch as a plain ref (`git branch`), never checking it out — the shared clone's checked-out HEAD and working tree are never mutated by branch creation.
- **Dead-letter entries are surfaced**: Every dead-letter write emits a structured `fleet-dead-letter|tid=<TID>|reason=<REASON>` line (and, from reconciliation, a `META|dead-letter|warn|reason=…` marker on the ticket's pipeline log) so a status-reporting script can surface it — nothing sits silently on disk. (Note: `/ticket-overseer` does NOT scan for dead-letters — wire a consumer before assuming visibility.)
- **Plugin manifest mimics ticket-auto-pipeline structure**: Same `.claude-plugin/plugin.json` conventions. No custom agent types — fleet controller doesn't spawn Claude agents.
- **Dependency bridge**: Fleet controller sources `linear-api.sh` and `heartbeat.sh` from `~/.claude/skills/lib/` (synced by ticket-auto-pipeline's SessionStart hook). Does not maintain its own copies — uses the canonical sources.
- **Detector output format preserved**: Existing 8 detectors produce byte-identical output after migration. New detectors follow same severity convention and pipe-delimited output format.

## Determinism boundary

All fleet controller operations are deterministic bash — no Claude agent involvement, no LLM reasoning. The determinism boundary is:
- **Fleet controller side (bash)**: Detection, dispatch planning, feedback aggregation, verified kill escalation (stop-files → SIGTERM → SIGKILL → fence), pipeline log finalization, run registry and fence marker writes
- **Agent side (Claude)**: Actual ticket-auto pipeline execution, Linear comment posting (feedback acting), ticket appraisal/implementation/verification

Fleet controller reads from pipeline logs and heartbeat logs; it never writes to them except for intervention markers, fence markers, and run registry entries (`META|fleet-intervention`, `META|outcome`) and stop-file touches. Dispatch writes to a separate spawn queue; feedback writes to a separate feedback directory.

## Configuration

All settings use `${VAR:-default}` pattern for env-var overrides:

| Variable | Default | Description |
|----------|---------|-------------|
| `FLEET_STATE_DIR` | (workspace) | Directory for spawn queue, stop files, run registry, fence markers — survives reboot |
| `FLEET_KILL_GRACE_SECS` | 10 | Wait for cooperative shutdown before SIGTERM |
| `FLEET_KILL_VERIFY` | true | Fall back to stop-file-only kill when false |
| `FLEET_FENCE_ENFORCE` | true | Enable generation fencing in flow.sh |
| `FLEET_QUEUE_LOCK_TIMEOUT` | 5 | Spawn queue flock timeout in seconds |
| `FLEET_POLL_INTERVAL` | 30 | Seconds between monitor cycles |
| `FLEET_STALL_WARN_SECS` | 600 | Stale heartbeat threshold for WARN. Raised from 300 — background subagents are waited for up to 10 minutes at exit (`CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS`), so 300 false-positived on a worker legitimately still exiting. Must stay strictly less than `FLEET_STALL_KILL_SECS`/`FLEET_STALL_RESTART_SECS` |
| `FLEET_STALL_KILL_SECS` | 900 | Stale heartbeat threshold for KILL |
| `FLEET_STALL_RESTART_SECS` | 1800 | Stale heartbeat threshold for KILL+RESTART |
| `FLEET_ABANDON_WARN_HOURS` | 1 | Abandonment threshold for WARN |
| `FLEET_ABANDON_KILL_HOURS` | 4 | Abandonment threshold for KILL+RESTART |
| `FLEET_ZOMBIE_SECS` | 900 | Unresolved waiting entry threshold |
| `FLEET_ACTIVITY_WARN_SECS` | 240 | Agent-activity staleness → WARN. Second, independent liveness input to `detect_stalls`, read from `{tid}-activity.log` (written per tool call by `ticket-auto-pipeline/hooks/agent-activity.sh`) and applied only while a spawn bracket is open. The watchdog `alive` line proves the *router* is running; this proves the *agent* is. 240s is deliberately well under `FLEET_STALL_WARN_SECS` — an agent that has made no tool call in 4 minutes is anomalous even though a router waiting 4 minutes is not |
| `FLEET_ACTIVITY_STALE_SECS` | 900 | Agent-activity staleness → KILL. Capped at WARN for tickets with no fleetd run-registry entry, so a human running `/ticket-auto` by hand — who reads output and thinks between tool calls — is never escalated to an intervention |
| `FLEET_FOREIGN_ACTIVITY_SECS` | 300 | Seconds of `{tid}-activity.log` silence after which an open pipeline bracket that fleetd does not own reads as a crashed run rather than as another orchestrator's live session. The dual-invocation interlock (`detect_foreign_run`) defers dispatch only when all three hold: an unresolved `|waiting|` bracket, no live fleetd worker, and a tool call inside this window. The window is what separates a **foreign run** from an **orphan** — collapse them and every crash recovery looks like a human at the keyboard, and fleetd stops recovering anything. A cooperative lock was rejected: the manual path is an LLM following prose, and a lock that is usually honoured turns a visible collision into a rare one nobody watches for |
| `FLEET_GATE_RECONCILE_INTERVAL` | 300 | Seconds between gate-hold reconciliation passes — deliberately its own cadence, not a step of the detection sweep. Detection reads local logs and runs every 30s; a held-ticket re-check is a Linear round trip per held ticket, and a human attaching an `approved` label is not a sub-minute-latency event. The probe re-runs `gate-check.sh --mode entry` (never `--mode reapprove`, which writes `APPROVAL_REVOKED` on any non-pass and would gate-stop a ticket nobody has looked at yet) against a scratch log, appending its lines to the real pipeline log only when the answer changed — a ticket held over a weekend must not accumulate one identical `GATE\|gate\|fail\|held:` line per pass |
| `FLEET_STORE_ENABLE` | true | Set `false` to disable the state store entirely — fleetd stops writing it and every detection engine falls back to reading the log files, which is the pre-store behaviour |
| `FLEET_STORE_EVENT_RETENTION_DAYS` | 30 | Age past which `log_events`/`activity_events` projection rows are pruned. Projections only — nothing fleetd authored is ever pruned, and anything dropped returns on a rebuild |
| `FLEET_ACTIVITY_LOG_MAX_LINES` | 500 | Ring cap on `{tid}-activity.log`. Read by the hook, not the detector: only the last line's age and the current bracket's line count have consumers |
| `FLEET_RUNAWAY_CALL_THRESHOLD` | 300 | Tool calls within one open spawn bracket above which `detect_runaway_calls` emits WARN. The mirror image of the activity-stall signal: a stalled agent stops calling tools, a runaway one never stops, and both keep the router's watchdog chirping. Counted per bracket rather than per log, so a long ticket is not flagged for being long. Must stay below `FLEET_ACTIVITY_LOG_MAX_LINES` — the activity log is ring-capped, so the count saturates there and a threshold above the cap is unreachable. WARN-only by design; a high call count is evidence, never proof |
| `FLEET_MAX_RESTARTS` | 2 | Max automatic restarts before giving up |
| `FLEET_AUTO_DISPATCH` | false | Must be `true` to enable automatic dispatch of planned tickets from initiative epics. Detection still runs and reports; dispatch is the actuation step. Human approval gate still stops every auto-dispatched ticket. |
| `FLEET_AUTO_RESTART` | true | Automatic restarts are enabled by default; set to `false` to opt out |
| `FLEET_DRY_RUN` | false | When `true`, interventions are logged not executed |
| `FLEET_EPIC_BRANCH_SYNC` | true | Sync base changes into epic branch each dispatch cycle — safety mechanism against branch rot |
| `FLEET_EPIC_AUTO_PR` | false | Automatically open integration PRs when all children Done — detection runs, actuation is opt-in |
| `FLEET_AUTO_DISPATCH` | false | When `false` (the documented default) fleetd sits idle — detection reports, dispatch happens only when explicitly triggered (skill or `POST /dispatch`). When `true`, the global sweep of `state:execution` epics runs unchanged. |
| `FLEET_DISPATCH_LOCK_TIMEOUT` | 5 | Seconds to wait for the epic-scoped dispatch flock (`{queue}.{epic}.dispatch.lock`) per attempt — serializes dispatch/stop per epic across processes |
| `FLEET_MAX_CONCURRENT` | 3 | Max concurrent pipelines for dispatch |
| `FLEET_EPIC_REPOS_DEPTH` | 3 | Levels of non-repo directories `_fleet_repos_under_root` descends into looking for nested service repos (e.g. `microservices/<svc>`) before giving up |
| `FLEET_EPIC_REPOS` | (unset) | Comma- or colon-separated list of explicit repo paths — when set, bypasses `_fleet_repos_under_root` directory discovery entirely; for operators pinning the exact repo set |
| `FLEET_POSTMORTEM_ON_KILL` | false | Run pipeline post-mortem analysis on fleet-killed pipelines (RLVR Phase 3). Opt-in — kills can be mass interventions; network cost and gh rate limits argue for per-kill opt-in. |
| `FLEET_INSTANCE_ID` | default | Namespace for stop files and spawn queues |
| `FLEET_SUMMARY_INTERVAL_CYCLES` | 10 | Cycles between forced fleet-summary heartbeat emissions |
| `CLAUDE_BIN` | `claude` | Worker binary name used by fleetd's `spawn_worker` |
| `CLAUDE_CMD` | (unset) | Full worker command line, overrides `CLAUDE_BIN` — e.g. `claude-deepseek 2 --bypass`. The `-p '/ticket-auto {tid} ...'` invocation is always appended after it |
| `FLEET_WORKER_PERMISSION_MODE` | `bypassPermissions` | Appended as `--permission-mode` unless `CLAUDE_CMD` already specifies one. `dontAsk`/`auto` are not sane defaults for a headless worker — see design.md Decision 9 |
| `FLEET_WORKER_DISALLOWED_TOOLS` | (unset) | Passed through to the worker invocation when set — comma-separated tool names to block. Recommended defense-in-depth given `bypassPermissions` is the default worker mode (e.g. `Bash(rm -rf:*),Bash(sudo:*)`) — not enforced by fleetd, since the pipeline's autonomy model already requires unattended write access to the workspace |
| `FLEET_WORKER_LOG_RETENTION` | 3 | Generations of `{tid}-gen{N}.json`/`.stderr`/`-exit.json` kept per ticket; older ones are swept at reap |
| `FLEET_DETERMINISTIC_FAILURE_SECS` | 5 | A worker exit faster than this counts toward the deterministic-failure circuit breaker streak |
| `FLEET_DETERMINISTIC_FAILURE_COUNT` | 3 | Consecutive fast-failure streak length that trips the circuit breaker (halts dispatch) |
| `FLEET_ENV_CHECK_LIVE_PROBE` | false | Opt-in: `fleet-env-check.sh` spawns one real worker turn to verify `permission_denials == []`. Off by default — never runs in `make test`/CI |
| `SLACK_BOT_TOKEN` | (unset) | Bot token for `fleet-notify.sh`'s `chat.postMessage` calls. Absent → notifications degrade to log-only |

## Known sharp edges

- **Dependency on ticket-auto-pipeline libs**: Fleet controller bridges to `linear-api.sh` and `heartbeat.sh` from ticket-auto-pipeline. If those change, fleet controller must be tested.
- **Spawn queue is file-based**: No atomicity guarantees for concurrent readers. Single-writer (dispatch) single-reader (monitor) design avoids this in practice.
- **Pipeline log fragility**: `_last_field` correctly uses awk joins for field 5+ (message) to avoid `cut -f5` truncation. New detectors must use `_last_msg` for message fields.
- **Stop file namespacing**: Uses `FLEET_INSTANCE_ID` to avoid collisions between multiple fleet controller instances.

## Related docs

- [Fleet controller architecture](docs/fleet-controller.md)
- [Root CLAUDE.md](../CLAUDE.md)
- [ticket-auto-pipeline CLAUDE.md](../ticket-auto-pipeline/CLAUDE.md)
