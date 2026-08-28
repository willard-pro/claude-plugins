# CLAUDE.md — fleet-controller

Plugin-level guidance for Claude Code when working inside this plugin directory. See also: [repo-level CLAUDE.md](../CLAUDE.md) for marketplace-wide conventions.

## Plugin purpose

Parent orchestrator above ticket-planner and ticket-auto. Fleet controller dispatches planned tickets from initiative epics, monitors all active pipeline health via 12 detection engines, and aggregates execution feedback back to the planner. Bash-only — zero Claude agents, zero LLM reasoning. All detection and intervention is deterministic.

## Directory layout

```
fleet-controller/
  .claude-plugin/plugin.json      # Plugin manifest (name, version, hooks)
  skills/fleet-controller/        # Single skill: /fleet-controller
  lib/                            # Shared bash libraries
  lib/tests/                      # Test suites
  fleetd/                         # Python 3 supervisor daemon (stdlib-only)
  docs/                           # Architecture and reference docs
```

## fleetd supervisor daemon

`fleetd` is a long-lived Python 3 daemon that owns worker process lifecycle. It replaces cron-based fleet invocation for spawn and kill operations. Detection engines remain in bash; fleetd invokes them as subprocesses.

**Key properties:**
- **Real PIDs**: Every worker's registry PID is the PID of a process fleetd forked. No sentinel zeros. (The legacy cron/monitor path writes a PID=0 sentinel until the spawn captures the real PID — startup reconciliation's live-process check compensates so such workers are not re-enqueued.)
- **Single-instance**: `fcntl.flock` on a pidfile; kernel releases on death.
- **Kill escalation**: Cooperative stop → SIGTERM → SIGKILL, signalling the process group.
- **Crash recovery**: On restart, verifies surviving PIDs via `/proc/<pid>/stat` start time before adoption. When `/proc` start-time verification is unavailable, falls back to a cmdline substring match — a known limitation: a reused PID whose command line happens to contain the ticket ID could be misadopted (documented and tested, not fixed). Stale registry deletion preserves the last-known generation to `{tid}-last-generation` so a reconciled re-spawn continues the generation sequence. Startup orphan reconciliation (pipeline-log-based, read-only) re-enqueues `incomplete` tickets whose workers died while fleetd was down; the restart cap reuses the existing `FLEET_MAX_RESTARTS` mechanism.
- **Generation fencing**: Supervisor assigns generations above any fenced predecessor.
- **CLI alignment**: The `/fleet-controller` skill writes kill requests to `{state_dir}/kill-requests/`; fleetd processes them.

**Invocation:** `python -m fleet-controller.fleetd [--port PORT] [--state-dir DIR]`

**Gating:** Set `FLEETD_SPAWN_ENABLED=1` to enable worker spawning. Default is observe-only (detection + health API, no spawns).

**HTTP control surface (on-demand, loopback-bound):** alongside `GET /health`, fleetd serves `POST /dispatch` (scoped dispatch of one epic against the running daemon — same `fleet_dispatch_initiative` the skill and auto-sweep call, spawns immediately instead of waiting for the poll cycle), `POST /stop` (epic-scoped stop: purge queue, escalate-kill workers, write `stop-{epic}.json`; the single bash implementation is `fleet_stop_initiative`, also reachable via the skill's `stop` subcommand with the daemon down), and read-only `GET /workers`, `GET /workers/<tid>` (phase/anomalies/tokens/confidence per worker), `GET /queue`, `GET /epics`. Use these as an alternative to the `/fleet-controller dispatch` skill (on-demand, no restart-to-reconfigure) and to the fleet dashboard (per-ticket detail without re-rendering the whole fleet). Dispatch is the single start/resume/un-stop entry point: a stop-file gates every dispatch trigger path until an explicit `resume: true` clears it; the auto-sweep never clears. See README "HTTP API" for request/response shapes.

## Skills

- `fleet-controller` — `/fleet-controller:fleet-controller` slash command. Subcommands: `detect`, `intervene`, `dashboard`, `dispatch`, `feedback`.
- `fleet-env-check` — `/fleet-controller:fleet-env-check` slash command. Validates `LINEAR_API_KEY`, `REPOS_ROOT`, the fleetd worker spawn command (`CLAUDE_BIN`/`CLAUDE_CMD`), and `jq`/`git`/`python3`/`gh`. Read-only, smaller scope than ticket-auto-pipeline's `ticket-env-check` (no hooks/spawn-permission/UAT_URL checks — those are ticket-auto concerns).

## Shared libraries (`lib/`)

| File | Exports |
|------|---------|
| `fleet-config.sh` | Configuration defaults: `FLEET_STATE_DIR`, `FLEET_KILL_GRACE_SECS`, `FLEET_KILL_VERIFY`, `FLEET_FENCE_ENFORCE`, `FLEET_QUEUE_LOCK_TIMEOUT`. State-directory resolver: `_fleet_state_dir <workspace>`. |
| `fleet-detect.sh` | 12 detection engines: `detect_phase_failures`, `detect_stalls`, `detect_zombies`, `detect_loops`, `detect_abandoned`, `detect_flow_failures`, `detect_auto_mode_blocks`, `detect_tool_errors`, `detect_planner_feedback`, `detect_blocked_by`, `detect_initiative_dispatch`, `detect_epic_branch_ready`. Aggregator: `fleet_detect_all` outputs JSON. Sourceable library — no `set -euo pipefail`. |
| `fleet-intervene.sh` | Intervention executor: `fleet_kill_pipeline` (verified escalation with PID-reuse guard), `fleet_can_restart`, `fleet_restart_pipeline`, `fleet_stop_background`. flow.sh mutex-aware, `FLEET_DRY_RUN` guard. |
| `fleet-monitor.sh` | Monitor loop: `fleet_monitor_cycle` (one detection + intervention pass), `fleet_monitor_loop` (continuous polling with stop-file gating). Spawn queue consumption integrated with `flock` serialization. Dual-mode: interactive (ACTION:spawn-restart) or cron (JSONL queue). |
| `fleet-registry.sh` | Run registry + generation fence helpers: `registry_write`, `registry_read`, `registry_pid`, `registry_generation`, `registry_exists`, `registry_clear`, `fence_write`, `fence_read`, `fence_is_superseded`, `fence_clear`. Per-ticket JSON files; no shared-file races. |
| `fleet-dashboard.sh` | Dashboard renderer: `fleet_render_dashboard` / `fleet_render_dashboard_from_data` (terminal health table) and `fleet_write_report` / `fleet_write_report_from_data` (markdown report). |
| `fleet-dispatch.sh` | Planned-ticket dispatch. Reads initiative epics from Linear via `lib/linear-api.sh`, validates `state:execution`, ensures the epic branch exists in **every** working repo under `REPOS_ROOT` before enqueue (multi-repo precondition — creation failure in any repo gate-stops with `EPIC_BRANCH_UNAVAILABLE`; sync failure in one repo warns and continues), resolves `blocked-by` dependencies, orders tickets by explicit dispatch rank (`Urgent`→`High`→`Medium`→`Low`→`No priority` last), writes spawn queue JSONL with `generation` field via shared `_fleet_queue_append` (flock, retry, dead-letter). Respects `FLEET_MAX_CONCURRENT` and `FLEET_DRY_RUN`. |
| `fleet-feedback.sh` | Feedback aggregation. Scans pipeline logs for `META\|planner-feedback`, groups by `{initiative-id}`, computes confidence drift, writes `$REPOS_ROOT/.ticket-auto/initiatives/{ID}/feedback/{rundate}.json`. |
| `fleet-env-check.sh` | Standalone (not sourced) — validates `LINEAR_API_KEY`, `REPOS_ROOT`, `GITHUB_PERSONAL_ACCESS_TOKEN`/`GH_TOKEN` (only required when `FLEET_EPIC_AUTO_PR=true`), the fleetd worker spawn command (`CLAUDE_CMD` if set, else `CLAUDE_BIN`), and `jq`/`git`/`python3`/`gh` presence. Same `NAME\|STATUS\|VALUE\|LOCATION\|NOTE` pipe-delimited contract as ticket-auto-pipeline's `env-check.sh`. Masks `LINEAR_API_KEY`/`GITHUB_PERSONAL_ACCESS_TOKEN`/`GH_TOKEN` values to `****` + last 4 chars — never echoes secrets in full. |
### Canonical library sources (dependency bridge)

Fleet controller depends on two libraries defined in `ticket-auto-pipeline/`:
- `linear-api.sh` — GraphQL API client (used by `fleet-dispatch.sh` for Linear queries)
- `heartbeat.sh` — Heartbeat log helpers (used by `fleet-monitor.sh`, `fleet-dashboard.sh`, `fleet-intervene.sh`)

These are sourced via `_source_if_missing` from `~/.claude/skills/lib/` (synced by the ticket-auto-pipeline SessionStart hook). Fleet controller does NOT maintain its own copies — it bridges to the canonical sources.

## Detection engines (12 total)

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
| `FLEET_STALL_WARN_SECS` | 300 | Stale heartbeat threshold for WARN |
| `FLEET_STALL_KILL_SECS` | 900 | Stale heartbeat threshold for KILL |
| `FLEET_STALL_RESTART_SECS` | 1800 | Stale heartbeat threshold for KILL+RESTART |
| `FLEET_ABANDON_WARN_HOURS` | 1 | Abandonment threshold for WARN |
| `FLEET_ABANDON_KILL_HOURS` | 4 | Abandonment threshold for KILL+RESTART |
| `FLEET_ZOMBIE_SECS` | 900 | Unresolved waiting entry threshold |
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

## Known sharp edges

- **Dependency on ticket-auto-pipeline libs**: Fleet controller bridges to `linear-api.sh` and `heartbeat.sh` from ticket-auto-pipeline. If those change, fleet controller must be tested.
- **Spawn queue is file-based**: No atomicity guarantees for concurrent readers. Single-writer (dispatch) single-reader (monitor) design avoids this in practice.
- **Pipeline log fragility**: `_last_field` correctly uses awk joins for field 5+ (message) to avoid `cut -f5` truncation. New detectors must use `_last_msg` for message fields.
- **Stop file namespacing**: Uses `FLEET_INSTANCE_ID` to avoid collisions between multiple fleet controller instances.

## Related docs

- [Fleet controller architecture](docs/fleet-controller.md)
- [Root CLAUDE.md](../CLAUDE.md)
- [ticket-auto-pipeline CLAUDE.md](../ticket-auto-pipeline/CLAUDE.md)
