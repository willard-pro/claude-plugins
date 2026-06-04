---
name: ticket-fleet-controller
description: Monitors all active ticket-auto pipelines using 6 detection engines (phase failures, stalls, zombies, loops, abandonment, flow failures) and escalates autonomously through OBSERVE → WARN → KILL → KILL+RESTART severity levels. All interventions execute through fleet lib functions — no silent mutations outside the declared tool set. In interactive mode (CLAUDE_CODE_SESSION_ID set), spawns restart agents via the Agent tool for KILL+RESTART actions; in cron mode, writes to the spawn queue JSONL for deferred processing.
allowed-tools: Bash, Read, Agent
---

# Ticket Fleet Controller — Automated Pipeline Intervention

The fleet controller watches all active ticket-auto pipelines and acts at defined severity thresholds. It complements `ticket-overseer` — overseer is the dashboard, fleet controller is the circuit breaker.

## When to Use

| Trigger | Mode |
|---------|------|
| `/ticket-fleet-controller monitor` | Continuous detection loop with automated intervention |
| `/ticket-fleet-controller status` | One-shot health dashboard + markdown report |
| `/ticket-fleet-controller intervene <TICKET_ID>` | Manual kill or restart of a specific pipeline |

## Modes

### Monitor (`monitor`)

Runs detection in a continuous loop via `fleet_monitor_loop`, rendering the dashboard each cycle and executing interventions at KILL and KILL+RESTART severities.

```
/ticket-fleet-controller monitor
```

- Polls every `FLEET_POLL_INTERVAL` seconds (default 30)
- Checks for stop file `/tmp/ticket-fleet-controller-stop` at the start of each cycle
- Respects `FLEET_DRY_RUN=true` — detection runs but interventions are logged, not executed
- Exits cleanly when stop file is detected

### Status (`status`)

One-shot health check — renders the dashboard to terminal and writes a report to `logs/reports/fleet-dashboard.md`.

```
/ticket-fleet-controller status
```

### Intervene (`intervene`)

Manual kill or restart for a specific ticket. Useful for operator-driven recovery.

```
/ticket-fleet-controller intervene CRE-47           # kill + attempt restart if eligible
/ticket-fleet-controller intervene CRE-47 --kill     # kill only, no restart
/ticket-fleet-controller intervene CRE-47 --restart  # restart if eligible (implies kill first)
```

## Detection Rules

The fleet controller runs 7 detection engines against every active pipeline:

| Detector | What it catches | Severity |
|----------|----------------|----------|
| Phase failures | `\|fail\|` entries on non-MAINTENANCE phases | WARN (gate-stops may escalate) |
| Stalls | Stale heartbeats (last `orchestrator-waiting` or `watchdog\|alive`) | WARN → KILL → KILL+RESTART based on elapsed time |
| Zombies | Unresolved `\|waiting\|` entries with no matching terminal | WARN → KILL based on age |
| Loops | Excessive `decision\|loop-back` counts vs configured caps | KILL+RESTART for rogue loops and exhaustion gates |
| Abandonment | Pipeline log exists but no `META\|outcome` after threshold | WARN → KILL+RESTART based on elapsed time |
| Flow failures | `retry\|flow-sh\|fail` entries in heartbeat log | WARN (1 failure) → KILL (2+ failures) |
| Auto-mode blocks | `check-approval\|fail` in pipeline log + denial patterns in agent output logs | WARN (1 block) → KILL (2+ blocks) |

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
| `FLEET_MAX_RESTARTS` | 2 | Max automatic restarts before giving up |
| `FLEET_AUTO_RESTART` | false | Must be `true` to enable automatic restarts |
| `FLEET_DRY_RUN` | false | When `true`, interventions are logged not executed |

## Implementation

The skill delegates to `fleet-monitor.sh` for all heavy lifting. That library sources its dependencies via the declare-guard pattern (F9 fix in 0.9.1), so `hb_decision` audit calls execute unconditionally — no need for call-site `declare -f` guards.

The restart spawn path works as follows:
1. `fleet_detect_all` returns severity 3 for pipelines needing restart
2. `fleet_restart_pipeline` kills the old pipeline, writes a `META|fleet-restart-marker` entry
3. The monitor loop scans for fresh markers and emits `ACTION:spawn-restart tid=<id>`
4. The ticket-fleet-controller agent type parses the ACTION line and spawns a `general-purpose` agent for `/ticket-auto {tid} --auto`

This replaces the broken `RESTART_ELIGIBLE=` stdout-echo pattern (F5 fix in 0.9.1).

```
# Status mode — one-shot dashboard + report
source ticket-auto-pipeline/lib/fleet-monitor.sh
data=$(fleet_detect_all ./logs)
fleet_render_dashboard_from_data "$data"
fleet_write_report_from_data "$data" ./logs

# Monitor mode — continuous detection loop
source ticket-auto-pipeline/lib/fleet-monitor.sh
fleet_monitor_loop ./logs

# Intervene mode — manual kill/restart
source ticket-auto-pipeline/lib/fleet-monitor.sh
fleet_kill_pipeline "$TICKET_ID" "manual-intervention" ./logs
# Or: fleet_restart_pipeline "$TICKET_ID" "manual-restart" ./logs
```

## Scheduling (Recommended)

For autonomous operation, schedule the fleet controller via cron:

```
# Status check every 10 minutes
*/10 * * * * cd /path/to/workspace && /ticket-fleet-controller status

# Or continuous monitor via a cron-triggered agent loop
# (monitor mode exits on stop file, so cron restarts it if it dies)
```

## Output

- **Terminal**: Health table with ticket ID, phase, stall time, severity, and anomalies
- **File**: `logs/reports/fleet-dashboard.md` — markdown report with health table + alert details + diagnostic context
- **Interventions**: Pipeline log entries (`META|fleet-intervention`, `META|outcome`) and heartbeat audit entries (`decision|fleet-kill|fired`, `decision|fleet-restart|fired`)

## Related Skills

- `ticket-overseer` — human-facing status reports (complementary)
- `ticket-detect-resume` — crash recovery from pipeline log
- `ticket-retro` — post-mortem failure analysis
