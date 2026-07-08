---
name: fleet-controller
description: Monitors all active ticket-auto pipelines using 11 detection engines (phase failures, stalls, zombies, loops, abandonment, flow failures, auto-mode blocks, tool errors, planner feedback, blocked-by resolution, initiative dispatch) and escalates autonomously through OBSERVE → WARN → KILL → KILL+RESTART severity levels. All interventions execute through fleet lib functions — no silent mutations outside the declared tool set.
allowed-tools: Bash, Read, Agent
---

# Fleet Controller — Automated Pipeline Orchestration

Parent orchestrator above ticket-planner and ticket-auto. Dispatches planned tickets, monitors pipeline health, aggregates execution feedback. Bash-only — zero Claude agents for detection/intervention.

## When to Use

| Trigger | Mode |
|---------|------|
| `/fleet-controller monitor` | Continuous detection loop with automated intervention |
| `/fleet-controller status` | One-shot health dashboard + markdown report |
| `/fleet-controller intervene <TICKET_ID>` | Manual kill or restart of a specific pipeline |
| `/fleet-controller dispatch <INITIATIVE_ID>` | Dispatch planned child tickets from an initiative epic |
| `/fleet-controller feedback` | Aggregate planner feedback across all initiatives |

## Modes

### Monitor (`monitor`)

Runs detection in a continuous loop via `fleet_monitor_loop`, rendering the dashboard each cycle and executing interventions at KILL and KILL+RESTART severities. Also consumes the spawn queue for planned-ticket dispatch.

```
/fleet-controller monitor
```

- Polls every `FLEET_POLL_INTERVAL` seconds (default 30)
- Checks for stop file `/tmp/fleet-{instance}-controller-stop` at the start of each cycle
- Respects `FLEET_DRY_RUN=true` — detection runs but interventions are logged, not executed
- Consumes spawn queue entries when active pipeline count < `FLEET_MAX_CONCURRENT`
- Exits cleanly when stop file is detected

### Status (`status`)

One-shot health check — renders the dashboard to terminal and writes a report to `logs/reports/fleet-dashboard.md`.

```
/fleet-controller status
```

### Intervene (`intervene`)

Manual kill or restart for a specific ticket. Useful for operator-driven recovery.

```
/fleet-controller intervene CRE-47           # kill + attempt restart if eligible
/fleet-controller intervene CRE-47 --kill     # kill only, no restart
/fleet-controller intervene CRE-47 --restart  # restart if eligible (implies kill first)
```

### Dispatch (`dispatch`)

Enqueue planned child tickets from an initiative epic for execution by the monitor loop.

```
/fleet-controller dispatch INIT-42           # dispatch all planned child tickets
/fleet-controller dispatch INIT-42 --dry-run  # preview without enqueuing
```

- Validates the epic has `state:execution` label
- Finds child tickets with `planned` label + `Backlog` state
- Resolves `blocked-by:{ID}` dependencies (skips blocked tickets)
- Writes to spawn queue at `/tmp/fleet-{instance}-spawn-queue.jsonl`
- Respects `FLEET_MAX_CONCURRENT` cap
- Idempotent — re-running won't duplicate already-queued tickets

### Feedback (`feedback`)

Aggregate `META|planner-feedback` entries from pipeline logs across all active workspaces.

```
/fleet-controller feedback                  # aggregate all feedback
/fleet-controller feedback --initiative INIT-42  # filter to single initiative
/fleet-controller feedback --dry-run        # preview without writing
```

- Groups feedback by `{initiative-id}` label
- Computes confidence drift (actual vs. predicted)
- Writes to `$REPOS_ROOT/.ticket-auto/initiatives/{ID}/feedback/{rundate}.json`

## Detection Rules

The fleet controller runs 11 detection engines against every active pipeline:

| Detector | What it catches | Severity |
|----------|----------------|----------|
| Phase failures | `\|fail\|` entries on non-MAINTENANCE phases | WARN (gate-stops may escalate) |
| Stalls | Stale heartbeats (last `orchestrator-waiting` or `watchdog\|alive`) | WARN → KILL → KILL+RESTART based on elapsed time |
| Zombies | Unresolved `\|waiting\|` entries with no matching terminal | WARN → KILL based on age |
| Loops | Excessive `decision\|loop-back` counts vs configured caps | KILL+RESTART for rogue loops and exhaustion gates |
| Abandonment | Pipeline log exists but no `META\|outcome` after threshold | WARN → KILL+RESTART based on elapsed time |
| Flow failures | `retry\|flow-sh\|fail` entries in heartbeat log | WARN (1 failure) → KILL (2+ failures) |
| Auto-mode blocks | `check-approval\|fail` in pipeline log + denial patterns in agent output logs | WARN (1 block) → KILL (2+ blocks) |
| Tool errors | Deduplicated tool-call errors in `{tid}-tool-errors.log` | WARN (1-2) → KILL (3+) |
| Planner feedback | Uncollected `META\|planner-feedback` entries | WARN (uncollected feedback found) |
| Blocked-by resolution | Tickets where blocking ticket is Done | WARN (unblocked ticket found) |
| Initiative dispatch | `state:execution` epics with undispatched planned tickets | WARN (undispatched tickets found) |

## Escalation Path

```
OBSERVE (sev=0) → WARN (sev=1) → KILL (sev=2) → KILL+RESTART (sev=3)
```

- **OBSERVE**: Log detection results, no action
- **WARN**: Write alert to dashboard, no destructive action
- **KILL**: Touch stop files (`/tmp/ticket-auto-{ID}-pinger-stop`, `/tmp/ticket-auto-{ID}-watchdog-stop`), finalize pipeline log, write heartbeat audit
- **KILL+RESTART**: Kill + spawn new `/ticket-auto {ID} --auto` agent (if `FLEET_AUTO_RESTART=true` and restart count < `FLEET_MAX_RESTARTS`)

## Configuration

All settings in `lib/config.sh` with `${VAR:-default}` pattern:

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

## Implementation

The skill delegates to fleet lib scripts for all heavy lifting:

```
# Status mode — one-shot dashboard + report
source fleet-controller/lib/fleet-monitor.sh
data=$(fleet_detect_all ./logs)
fleet_render_dashboard_from_data "$data"
fleet_write_report_from_data "$data" ./logs

# Monitor mode — continuous detection loop
source fleet-controller/lib/fleet-monitor.sh
fleet_monitor_loop ./logs

# Intervene mode — manual kill/restart
source fleet-controller/lib/fleet-intervene.sh
fleet_kill_pipeline "$TICKET_ID" "manual-intervention" ./logs
# Or: fleet_restart_pipeline "$TICKET_ID" "manual-restart" ./logs

# Dispatch mode — enqueue planned tickets
source fleet-controller/lib/fleet-dispatch.sh
fleet_dispatch_initiative "INIT-42"

# Feedback mode — aggregate planner feedback
source fleet-controller/lib/fleet-feedback.sh
fleet_aggregate_feedback
```

## Scheduling (Recommended)

For autonomous operation, schedule the fleet controller via cron:

```
# Status check every 10 minutes
*/10 * * * * cd /path/to/workspace && /fleet-controller status

# Or continuous monitor via a cron-triggered agent loop
# (monitor mode exits on stop file, so cron restarts it if it dies)
```

## Output

- **Terminal**: Health table with ticket ID, phase, stall time, severity, and anomalies
- **File**: `logs/reports/fleet-dashboard.md` — markdown report with health table + alert details + diagnostic context
- **Interventions**: Pipeline log entries (`META|fleet-intervention`, `META|outcome`) and heartbeat audit entries (`decision|fleet-kill|fired`, `decision|fleet-restart|fired`)
- **Dispatch**: `/tmp/fleet-{instance}-spawn-queue.jsonl` — JSONL entries consumed by monitor loop
- **Feedback**: `$REPOS_ROOT/.ticket-auto/initiatives/{ID}/feedback/{rundate}.json`

## Related Skills

- `ticket-auto-pipeline:ticket-overseer` — human-facing status reports (complementary)
- `ticket-auto-pipeline:ticket-detect-resume` — crash recovery from pipeline log
- `ticket-auto-pipeline:ticket-retro` — post-mortem failure analysis
