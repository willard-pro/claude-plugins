# CLAUDE.md — fleet-controller

Plugin-level guidance for Claude Code when working inside this plugin directory. See also: [repo-level CLAUDE.md](../CLAUDE.md) for marketplace-wide conventions.

## Plugin purpose

Parent orchestrator above ticket-planner and ticket-auto. Fleet controller dispatches planned tickets from initiative epics, monitors all active pipeline health via 11 detection engines, and aggregates execution feedback back to the planner. Bash-only — zero Claude agents, zero LLM reasoning. All detection and intervention is deterministic.

## Directory layout

```
fleet-controller/
  .claude-plugin/plugin.json      # Plugin manifest (name, version, hooks)
  skills/fleet-controller/        # Single skill: /fleet-controller
  lib/                            # Shared bash libraries
  lib/tests/                      # Test suites
  docs/                           # Architecture and reference docs
```

## Skill

- `fleet-controller` — `/fleet-controller:fleet-controller` slash command. Subcommands: `detect`, `intervene`, `dashboard`, `dispatch`, `feedback`.

## Shared libraries (`lib/`)

| File | Exports |
|------|---------|
| `fleet-detect.sh` | 11 detection engines: `detect_phase_failures`, `detect_stalls`, `detect_zombies`, `detect_loops`, `detect_abandoned`, `detect_flow_failures`, `detect_auto_mode_blocks`, `detect_tool_errors`, `detect_planner_feedback`, `detect_blocked_by`, `detect_initiative_dispatch`. Aggregator: `fleet_detect_all` outputs JSON. Sourceable library — no `set -euo pipefail`. |
| `fleet-intervene.sh` | Intervention executor: `fleet_kill_pipeline`, `fleet_can_restart`, `fleet_restart_pipeline`, `fleet_stop_background`. flow.sh mutex-aware, `FLEET_DRY_RUN` guard. |
| `fleet-monitor.sh` | Monitor loop: `fleet_monitor_cycle` (one detection + intervention pass), `fleet_monitor_loop` (continuous polling with stop-file gating). Spawn queue consumption integrated. Dual-mode: interactive (ACTION:spawn-restart) or cron (JSONL queue). |
| `fleet-dashboard.sh` | Dashboard renderer: `fleet_render_dashboard` / `fleet_render_dashboard_from_data` (terminal health table) and `fleet_write_report` / `fleet_write_report_from_data` (markdown report). |
| `fleet-dispatch.sh` | Planned-ticket dispatch. Reads initiative epics from Linear via `lib/linear-api.sh`, validates `state:execution`, resolves `blocked-by` dependencies, writes spawn queue JSONL. Respects `FLEET_MAX_CONCURRENT` and `FLEET_DRY_RUN`. |
| `fleet-feedback.sh` | Feedback aggregation. Scans pipeline logs for `META|planner-feedback`, groups by `{initiative-id}`, computes confidence drift, writes `$REPOS_ROOT/.ticket-auto/initiatives/{ID}/feedback/{rundate}.json`. |

### Canonical library sources (dependency bridge)

Fleet controller depends on two libraries defined in `ticket-auto-pipeline/`:
- `linear-api.sh` — GraphQL API client (used by `fleet-dispatch.sh` for Linear queries)
- `heartbeat.sh` — Heartbeat log helpers (used by `fleet-monitor.sh`, `fleet-dashboard.sh`, `fleet-intervene.sh`)

These are sourced via `_source_if_missing` from `~/.claude/skills/lib/` (synced by the ticket-auto-pipeline SessionStart hook). Fleet controller does NOT maintain its own copies — it bridges to the canonical sources.

## Detection engines (11 total)

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

## Severity scale

| Code | Name | Action |
|------|------|--------|
| 0 | OBSERVE | Log only, no action |
| 1 | WARN | Alert, no destructive action |
| 2 | KILL | Touch stop files, finalize pipeline log |
| 3 | KILL+RESTART | Kill + spawn new pipeline (if `FLEET_AUTO_RESTART=true`) |
| 4 | KILL degraded to WARN | KILL severity downgraded (e.g., non-retryable gate-stop) |

## Key design decisions

- **Bash-only, zero LLM**: Fleet controller never spawns Claude agents. Detection, dispatch, intervention, and feedback are all deterministic bash scripts. The skill file is the human interface for manual intervention.
- **Detection engines are sourceable library**: `fleet-detect.sh` exports functions as a sourceable bash library — no `-euo pipefail`. Callers source it and call individual detectors or the aggregator `fleet_detect_all`.
- **Dispatch uses spawn queue file**: `fleet-dispatch.sh` writes to `/tmp/fleet-{instance}-spawn-queue.jsonl`. The monitor loop consumes the queue. Separation of concerns — dispatch identifies work, monitor executes it.
- **Feedback writes to REPOS_ROOT, not Linear**: `fleet-feedback.sh` collects and structures data; agents act on it. The determinism boundary — fleet controller scripts are bash, Linear comment posting is an agent responsibility.
- **Intervention respects flow.sh mutex**: Kill/restart operations check for flow.sh locks (`/tmp/ticket-flow-{ID}.lock`) before acting. `FLEET_DRY_RUN=true` makes all interventions no-op.
- **Plugin manifest mimics ticket-auto-pipeline structure**: Same `.claude-plugin/plugin.json` conventions. No custom agent types — fleet controller doesn't spawn Claude agents.
- **Dependency bridge**: Fleet controller sources `linear-api.sh` and `heartbeat.sh` from `~/.claude/skills/lib/` (synced by ticket-auto-pipeline's SessionStart hook). Does not maintain its own copies — uses the canonical sources.
- **Detector output format preserved**: Existing 8 detectors produce byte-identical output after migration. New detectors follow same severity convention and pipe-delimited output format.

## Determinism boundary

All fleet controller operations are deterministic bash — no Claude agent involvement, no LLM reasoning. The determinism boundary is:
- **Fleet controller side (bash)**: Detection, dispatch planning, feedback aggregation, stop-file touches, pipeline log finalization
- **Agent side (Claude)**: Actual ticket-auto pipeline execution, Linear comment posting (feedback acting), ticket appraisal/implementation/verification

Fleet controller reads from pipeline logs and heartbeat logs; it never writes to them except for intervention markers (`META|fleet-intervention`, `META|outcome`) and stop-file touches. Dispatch writes to a separate spawn queue; feedback writes to a separate feedback directory.

## Configuration

All settings use `${VAR:-default}` pattern for env-var overrides:

| Variable | Default | Description |
|----------|---------|-------------|
| `FLEET_POLL_INTERVAL` | 30 | Seconds between monitor cycles |
| `FLEET_STALL_WARN_SECS` | 300 | Stale heartbeat threshold for WARN |
| `FLEET_STALL_KILL_SECS` | 900 | Stale heartbeat threshold for KILL |
| `FLEET_STALL_RESTART_SECS` | 1800 | Stale heartbeat threshold for KILL+RESTART |
| `FLEET_ABANDON_WARN_HOURS` | 1 | Abandonment threshold for WARN |
| `FLEET_ABANDON_KILL_HOURS` | 4 | Abandonment threshold for KILL+RESTART |
| `FLEET_ZOMBIE_SECS` | 900 | Unresolved waiting entry threshold |
| `FLEET_MAX_RESTARTS` | 2 | Max automatic restarts before giving up |
| `FLEET_AUTO_RESTART` | false | Must be `true` to enable automatic restarts |
| `FLEET_DRY_RUN` | false | When `true`, interventions are logged not executed |
| `FLEET_MAX_CONCURRENT` | 3 | Max concurrent pipelines for dispatch |
| `FLEET_INSTANCE_ID` | default | Namespace for stop files and spawn queues |
| `FLEET_SUMMARY_INTERVAL_CYCLES` | 10 | Cycles between forced fleet-summary heartbeat emissions |

## Known sharp edges

- **Dependency on ticket-auto-pipeline libs**: Fleet controller bridges to `linear-api.sh` and `heartbeat.sh` from ticket-auto-pipeline. If those change, fleet controller must be tested.
- **Spawn queue is file-based**: No atomicity guarantees for concurrent readers. Single-writer (dispatch) single-reader (monitor) design avoids this in practice.
- **Pipeline log fragility**: `_last_field` correctly uses awk joins for field 5+ (message) to avoid `cut -f5` truncation. New detectors must use `_last_msg` for message fields.
- **Stop file namespacing**: Uses `FLEET_INSTANCE_ID` to avoid collisions between multiple fleet controller instances.

## Related docs

- [Fleet controller architecture](docs/fleet-controller.md)
- [Root CLAUDE.md](../CLAUDE.md)
- [ticket-auto-pipeline CLAUDE.md](../ticket-auto-pipeline/CLAUDE.md)
