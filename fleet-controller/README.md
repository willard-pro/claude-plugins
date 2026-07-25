# fleet-controller

Parent orchestrator above `ticket-planner` and `ticket-auto-pipeline`. Dispatches planned tickets from initiative epics, watches every running pipeline via 12 detection engines, kills and restarts stuck runs, and feeds execution results back to the planner.

**Bash-only — zero Claude agents.** Every detection and intervention is a deterministic script. Nothing here reasons; it measures and acts on thresholds.

## When you need this

You don't need the fleet controller to run tickets — `/ticket-auto CRE-47` works on its own. You need it when:

- You want **many tickets running unattended** rather than one at a time
- Runs **hang** and you want them detected and restarted without watching a terminal
- You're executing a **planner initiative** and want its tickets dispatched in dependency order
- You want the planner to **learn from what actually happened** during execution

## Install

```bash
# Add the marketplace first (one-time)
claude plugin marketplace add willard-pro/claude-plugins

# fleet-controller depends on libraries from ticket-auto-pipeline — install both
claude plugin install ticket-auto-pipeline@willard-pro-claude-plugins
claude plugin install fleet-controller@willard-pro-claude-plugins
```

`ticket-auto-pipeline` is a hard dependency: fleet-controller sources `linear-api.sh` and `heartbeat.sh` from it rather than keeping its own copies. See [Dependency bridge](#dependency-bridge).

## Quickstart

**1. Confirm the pipeline is configured.** Fleet controller reads the same environment as `ticket-auto-pipeline` (`LINEAR_API_KEY`, `REPOS_ROOT`, and the pipeline logs). If `/ticket-env-check` passes, you're set — there is nothing extra to configure.

**2. Look before you touch anything:**

```
/fleet-controller status
```

One-shot health dashboard for every active pipeline. Read-only — it never intervenes. Run this first.

**3. Start supervising, in dry-run mode:**

```bash
FLEET_DRY_RUN=true FLEET_AUTO_RESTART=false
```

```
/fleet-controller monitor
```

Detection runs and interventions are **logged but not executed**. Watch a few cycles and confirm the decisions it *would* make are ones you'd want.

**4. Go live** once the dry-run output looks right — unset `FLEET_DRY_RUN`, and set `FLEET_AUTO_RESTART=true` only if you want automatic restarts.

> **Both safety switches are conservative by default.** `FLEET_DRY_RUN` is `false` (interventions execute), but `FLEET_AUTO_RESTART` is `false` — so out of the box the controller will kill a hung pipeline but never respawn one. Turn on auto-restart deliberately.

## Modes

| Command | What it does |
|---------|-------------|
| `/fleet-controller status` | One-shot health dashboard + markdown report. Read-only. |
| `/fleet-controller monitor` | Continuous detection loop with automated intervention. |
| `/fleet-controller intervene <TICKET_ID>` | Manually kill or restart one pipeline. |
| `/fleet-controller dispatch <INITIATIVE_ID>` | Queue an initiative's planned tickets for execution. |
| `/fleet-controller feedback` | Aggregate execution results back to the planner. |

### status

Renders a health table (ticket, phase, stall time, severity, anomalies) to the terminal and writes `logs/reports/fleet-dashboard.md`. Start here when something looks wrong.

### monitor

Polls every `FLEET_POLL_INTERVAL` seconds (default 30). Each cycle: run all 12 detectors, render the dashboard, execute interventions at KILL and above, and consume the spawn queue while active pipelines are under `FLEET_MAX_CONCURRENT`.

Stop it by creating the stop file it checks each cycle:

```bash
touch "${FLEET_STATE_DIR}/fleet-default-controller-stop"
```

(Replace `default` with your `FLEET_INSTANCE_ID` if you set one.)

### intervene

```
/fleet-controller intervene CRE-47             # kill, then restart if eligible
/fleet-controller intervene CRE-47 --kill      # kill only
/fleet-controller intervene CRE-47 --restart   # restart (kills first)
```

### dispatch

```
/fleet-controller dispatch INIT-42             # queue all planned child tickets
/fleet-controller dispatch INIT-42 --dry-run   # preview
```

Requires the epic to carry the `state:execution` label (the planner sets this). Finds child tickets labelled `planned` in `Backlog`, skips any still blocked by a `blocked-by:{ID}` dependency, and writes to the spawn queue. **Idempotent** — re-running won't double-queue.

Dispatch only *queues* work; `monitor` (or `fleetd`) executes it.

### feedback

```
/fleet-controller feedback                       # all initiatives
/fleet-controller feedback --initiative INIT-42  # one
/fleet-controller feedback --dry-run             # preview
```

Scans pipeline logs for `META|planner-feedback`, groups by initiative, computes confidence drift (what the planner predicted vs. what happened), and writes `$REPOS_ROOT/.ticket-auto/initiatives/{ID}/feedback/{rundate}.json`. The planner ingests this on `/ticket-planner replan` — but only when the epic carries a `Regenerate` label.

## What it detects

12 engines run against every active pipeline each cycle:

| Detector | Catches | Severity |
|----------|---------|----------|
| Phase failures | `fail` entries on non-MAINTENANCE phases | WARN |
| Stalls | Stale heartbeats | WARN → KILL → KILL+RESTART by elapsed time |
| Zombies | `waiting` entries with no terminal status | WARN → KILL by age |
| Loops | Loop-back counts exceeding configured caps | KILL+RESTART |
| Abandonment | Log exists but no `META\|outcome` past threshold | WARN → KILL+RESTART |
| Flow failures | `flow.sh` retry failures | WARN (1) → KILL (2+) |
| Auto-mode blocks | Approval-check failures + denial patterns | WARN (1) → KILL (2+) |
| Tool errors | Deduplicated tool-call errors | WARN (1–2) → KILL (3+) |
| Planner feedback | Uncollected feedback entries | WARN |
| Blocked-by resolution | Tickets whose blocker is now Done | WARN |
| Initiative dispatch | `state:execution` epics with undispatched tickets | WARN |
| Epic-branch readiness | Epics with all children Done, ready to integrate | WARN |

The last four aren't failures — they're **work waiting to happen**. That's how the controller notices it should dispatch or unblock something.

### Escalation

```
OBSERVE (0) → WARN (1) → KILL (2) → KILL+RESTART (3)
```

- **OBSERVE** — record only
- **WARN** — surface on the dashboard, nothing destructive
- **KILL** — verified escalation: stop-file → grace → `SIGTERM` → grace → `SIGKILL` → re-verify. The pipeline log is finalized **only after the PID is confirmed gone**, then a generation fence marker blocks any superseded zombie from mutating Linear.
- **KILL+RESTART** — kill, then spawn a fresh `/ticket-auto {ID} --auto`. Requires `FLEET_AUTO_RESTART=true` and restart count below `FLEET_MAX_RESTARTS`.

## fleetd — the supervisor daemon

`fleetd` is a stdlib-only Python 3 daemon that owns worker process lifecycle. It's the recommended way to run the fleet continuously, replacing cron-based invocation.

```bash
FLEETD_SPAWN_ENABLED=1 python -m fleet-controller.fleetd --state-dir /path/to/workspace
```

Health API: `GET http://127.0.0.1:21001/health` → live workers, queue depth, cycle status.

**Default is observe-only** — without `FLEETD_SPAWN_ENABLED=1` it runs detection and serves health, but spawns nothing.

### Why it exists

| Cron-based | fleetd |
|-----------|--------|
| PID=0 sentinel in registry | Real PIDs — fleetd forked the process |
| Kill escalation unreachable (no PID to signal) | Full escalation with process-group signalling |
| Spawn instructions printed, unconsumed | Forks `claude` directly |
| No health endpoint | `GET /health` |

Single-instance enforced via `fcntl.flock` on a pidfile. On restart it verifies surviving PIDs against `/proc/<pid>/stat` start time before adopting them, so a recycled PID can't be mistaken for a live worker.

## Configuration

All settings live in `lib/config.sh` using `${VAR:-default}` — override via environment. Safe defaults; nothing is required.

**Detection thresholds**

| Variable | Default | Meaning |
|----------|---------|---------|
| `FLEET_POLL_INTERVAL` | 30 | Seconds between monitor cycles |
| `FLEET_STALL_WARN_SECS` | 300 | Stale heartbeat → WARN |
| `FLEET_STALL_KILL_SECS` | 900 | Stale heartbeat → KILL |
| `FLEET_STALL_RESTART_SECS` | 1800 | Stale heartbeat → KILL+RESTART |
| `FLEET_ZOMBIE_SECS` | 900 | Unresolved `waiting` threshold |
| `FLEET_ABANDON_WARN_HOURS` | 1 | Abandonment → WARN |
| `FLEET_ABANDON_KILL_HOURS` | 4 | Abandonment → KILL+RESTART |

**Intervention control**

| Variable | Default | Meaning |
|----------|---------|---------|
| `FLEET_DRY_RUN` | false | `true` = log interventions, don't execute |
| `FLEET_AUTO_RESTART` | false | Must be `true` for automatic restarts |
| `FLEET_MAX_RESTARTS` | 2 | Restart attempts before giving up |
| `FLEET_MAX_CONCURRENT` | 3 | Concurrent pipeline cap for dispatch |
| `FLEET_KILL_GRACE_SECS` | 10 | Cooperative-shutdown wait before SIGTERM |
| `FLEET_KILL_VERIFY` | true | `false` = stop-file-only kill (legacy compat) |

**State and fencing**

| Variable | Default | Meaning |
|----------|---------|---------|
| `FLEET_STATE_DIR` | (workspace) | Spawn queue, stop files, run registry, fence markers |
| `FLEET_INSTANCE_ID` | `default` | Namespace for stop files and queues |
| `FLEET_FENCE_ENFORCE` | true | Generation fencing in `flow.sh` |
| `FLEET_QUEUE_LOCK_TIMEOUT` | 5 | Seconds to wait for queue `flock` |
| `FLEET_EPIC_BRANCH_SYNC` | — | Epic branch sync behaviour |
| `FLEET_EPIC_AUTO_PR` | — | Auto-open epic integration PRs |
| `FLEETD_SPAWN_ENABLED` | unset | `1` enables fleetd worker spawning |

## Where state lives

| What | Where |
|------|-------|
| Health dashboard report | `logs/reports/fleet-dashboard.md` |
| Spawn queue | `${FLEET_STATE_DIR}/fleet-{instance}-spawn-queue.jsonl` |
| Stop file | `${FLEET_STATE_DIR}/fleet-{instance}-controller-stop` |
| Run registry + fences | `${FLEET_STATE_DIR}/` (per-ticket JSON) |
| Kill requests (fleetd) | `${FLEET_STATE_DIR}/kill-requests/{tid}.json` |
| Aggregated feedback | `$REPOS_ROOT/.ticket-auto/initiatives/{ID}/feedback/` |

Interventions also write audit trails: `META|fleet-intervention` in the pipeline log and `decision|fleet-kill|fired` in the heartbeat log.

## Dependency bridge

Fleet controller depends on two libraries owned by `ticket-auto-pipeline`:

- `linear-api.sh` — GraphQL client, used by `fleet-dispatch.sh`
- `heartbeat.sh` — heartbeat log helpers, used by monitor/dashboard/intervene

Both are sourced from `~/.claude/skills/lib/` (synced by the ticket-auto-pipeline SessionStart hook). Fleet controller deliberately keeps **no copies** — a drifting duplicate would silently break dispatch.

**If dispatch fails to find Linear:** launch Claude Code once with `ticket-auto-pipeline` installed so the hook syncs the shared libraries.

## Migrating from `/ticket-fleet-controller`

The fleet controller used to live inside `ticket-auto-pipeline`. The old `/ticket-fleet-controller` command is a **deprecated forwarder** kept for one release cycle.

```
/ticket-fleet-controller monitor   →   /fleet-controller monitor
```

Update any cron jobs or scripts still calling the old name.

## Documentation

| Document | Audience | Contents |
|----------|----------|----------|
| [docs/fleet-controller.md](docs/fleet-controller.md) | Operators | Detection engines, intervention safety model, dispatch flow, crash recovery |
| [CLAUDE.md](CLAUDE.md) | Claude Code | Plugin architecture, library reference, sharp edges |
| [skills/fleet-controller/SKILL.md](skills/fleet-controller/SKILL.md) | Claude Code | Skill procedure: modes, detection rules, implementation |
| [Root README](../README.md) | Everyone | Marketplace overview and ecosystem flow |

## Ecosystem

```
Business idea → [ticket-planner] → initiative epic + planned tickets
                                       ↓
                              [fleet-controller] → dispatch → monitor → intervene
                                       ↓
                        [ticket-auto-pipeline] → implement → verify → merge
                                       ↓
                              [fleet-controller] → aggregate feedback
                                       ↓
                                [ticket-planner replan]
```

## License

UNLICENSED — proprietary.
