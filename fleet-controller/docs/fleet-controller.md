# Fleet Controller — Architecture & Operations

Parent orchestrator above ticket-planner and ticket-auto. Dispatches planned tickets from initiative epics, monitors all active pipeline health via 11 detection engines, escalates autonomously through OBSERVE → WARN → KILL → KILL+RESTART severity levels, and aggregates execution feedback back to the planner. Bash-only — zero Claude agents, zero LLM reasoning. All detection and intervention is deterministic.

## Architecture Overview

```
┌─────────────────────────────────────────────┐
│              Fleet Controller                │
│  ┌─────────┐ ┌──────────┐ ┌──────────────┐ │
│  │ Detect  │→│Intervene │→│   Dispatch    │ │
│  │ (11 eng)│ │(verified │ │(spawn queue + │ │
│  │         │ │ escalate)│ │   flock)      │ │
│  └─────────┘ └──────────┘ └──────────────┘ │
│         ↑            ↓           ↓          │
│  ┌─────────────────────────────────────┐   │
│  │   Durable State (workspace-relative) │   │
│  │  run-registry │ fence │ spawn-queue  │   │
│  └─────────────────────────────────────┘   │
└─────────────────────────────────────────────┘
         │                          │
         ↓                          ↓
   ticket-auto              ticket-planner
   (pipeline exec)          (initiative mgmt)
```

### Key Principles

1. **Determinism boundary**: All fleet controller operations are deterministic bash. Zero LLM involvement in detection, intervention, dispatch, or feedback.
2. **Owned worker lifecycle**: Whoever starts a worker holds its handle and is the sole authority that can declare it dead (OTP/systemd/Kubernetes pattern).
3. **Single chokepoint**: All Linear mutations flow through `flow.sh`. The generation fence guard lives there, so one check covers every mutation.
4. **Durable state**: Spawn queue, stop files, run registry, and fence markers live under the workspace — a host reboot does not silently drop queued dispatches or in-flight decisions.
5. **Supervisor ownership**: The `fleetd` daemon is the single parent of every worker it spawns. Real PIDs replace sentinel zeros. Kill escalation signals process groups, not individual processes. Crash recovery verifies PID ownership via `/proc/<pid>/stat` start time before adoption.

### fleetd supervisor daemon

`fleetd` (`fleet-controller/fleetd/`) is the long-lived actuator that replaces cron-based fleet invocation. Bash detection engines are unchanged — fleetd invokes them as subprocesses.

**Process model**: `fork()` + `exec()` with `os.setpgid(0, 0)` for process-group isolation. The self-pipe trick handles `SIGCHLD` → `waitpid` reaping without async-signal-unsafe operations in the signal handler.

**Kill escalation**: Cooperative stop (stop files) → grace → `SIGTERM` to process group → grace → `SIGKILL` to process group, with zombie-aware liveness checks (`waitpid` before `kill -0`).

**Crash recovery**: On restart, reads registry entries, verifies PID ownership via `starttime` from `/proc/<pid>/stat` compared against registry `started_at`, and adopts verified survivors into degraded supervision (polling-based exit detection instead of reaping).

**Health API**: `GET http://127.0.0.1:21001/health` — returns live workers with PIDs and phases, queue depth, last cycle timestamp and success/failure, cycle count, and detection summary.

**Generation fencing**: The supervisor assigns generations at spawn (`max(prior_gen, fenced_gen) + 1`), writes fence markers on kill, and `flow.sh` enforces the fence — a worker with `generation <= fenced_generation` cannot mutate Linear state.

**CLI bridge**: The `/fleet-controller` skill writes to `{state_dir}/kill-requests/{tid}.json`; fleetd processes requests and writes result files. No dual authority for process signalling.

## Detection Engines (11 total)

Each engine scores pipelines 0–3 (OBSERVE/WARN/KILL/KILL+RESTART) and returns structured JSON with anomalies. Detection is stateless — engines read pipeline/heartbeat logs on each cycle.

### 1. Phase Failures (`detect_phase_failures`)
**What it catches**: `|fail|` entries on non-MAINTENANCE phases.
**Severity**: 0–3. Gate-stop codes (e.g., `EXEC_NO_ARTIFACT`, `VERIFY_EXHAUSTED`) escalate differently from transient failures.
**Mechanism**: `grep -c` on pipeline log fail entries, cross-referenced with gate-stop classifier.

### 2. Stalls (`detect_stalls`)
**What it catches**: Stale heartbeats — last `orchestrator-waiting` or `watchdog|alive` entry exceeds configured thresholds.
**Severity**: 0 (fresh) → 1 (WARN, >300s) → 2 (KILL, >900s) → 3 (KILL+RESTART, >1800s).
**Mechanism**: `_last_entry_age_secs` computes seconds since last relevant heartbeat entry.

### 3. Zombies (`detect_zombies`)
**What it catches**: Unresolved `|waiting|` entries with no matching terminal (`done`/`fail`).
**Severity**: 0 → 1 (WARN) → 2 (KILL, >900s).
**Mechanism**: State-machine walk across pipeline log — each `waiting` without a matching terminal increments zombie count.

### 4. Loops (`detect_loops`)
**What it catches**: Excessive `decision|loop-back` counts in heartbeat log vs configured caps.
**Severity**: 1 (WARN) → 3 (KILL+RESTART for rogue loops, exhaustion gates).
**Mechanism**: `grep -c` on loop-back markers, compared to `FLEET_LOOP_WARN_CAP` / `FLEET_LOOP_KILL_CAP`.

### 5. Abandonment (`detect_abandoned`)
**What it catches**: Pipeline log exists but no `META|outcome` after threshold hours.
**Severity**: 1 (WARN, >1hr) → 3 (KILL+RESTART, >4hr).
**Mechanism**: Pipeline log mtime age, cross-checked for outcome marker absence.

### 6. Flow Failures (`detect_flow_failures`)
**What it catches**: `retry|flow-sh|fail` entries in heartbeat log — flow.sh API failures.
**Severity**: 1 (WARN, 1 failure) → 2 (KILL, 2+ failures).
**Mechanism**: `grep -c` on heartbeat log flow-sh fail patterns.

### 7. Auto-Mode Blocks (`detect_auto_mode_blocks`)
**What it catches**: `check-approval|fail` in pipeline log + denial patterns in agent output logs.
**Severity**: 1 (WARN, 1 block) → 2 (KILL, 2+ blocks).
**Mechanism**: Combined pipeline log + agent output log pattern matching.

### 8. Tool Errors (`detect_tool_errors`)
**What it catches**: Deduplicated tool-call errors in `{tid}-tool-errors.log`.
**Severity**: 1 (WARN, 1–2 errors) → 2 (KILL, 3+ errors).
**Mechanism**: `sort -u` dedup, `wc -l` count against caps.

### 9. Planner Feedback (`detect_planner_feedback`)
**What it catches**: Uncollected `META|planner-feedback` entries in pipeline logs.
**Severity**: 1 (WARN, uncollected feedback found).
**Mechanism**: `grep -l` for feedback markers, cross-referenced with feedback output directory for collection status.

### 10. Blocked-by Resolution (`detect_blocked_by`)
**What it catches**: Tickets with `blocked-by:{ID}` label where the blocking ticket is Done.
**Severity**: 1 (WARN, unblocked ticket — ready to proceed).
**Mechanism**: Label scan for `blocked-by:`, then `get_issue` to check blocker state.

### 11. Initiative Dispatch (`detect_initiative_dispatch`)
**What it catches**: `state:execution` epics with undispatched planned child tickets.
**Severity**: 1 (WARN, undispatched tickets found).
**Mechanism**: Linear query for epics with `state:execution`, cross-referenced against spawn queue for already-dispatched children.

### Detection Output Format

```json
{
  "pipelines": [
    {
      "tid": "CRE-101",
      "phase": "IMPLEMENT",
      "severity": 2,
      "elapsed_secs": 947,
      "anomalies": "stall:947s flow-fail:2"
    }
  ],
  "fleet_wide": [
    {"code": "undispatched", "count": 3, "initiative": "INIT-42"}
  ],
  "summary": {
    "total": 5,
    "healthy": 2,
    "warn": 1,
    "kill": 1,
    "restart": 1
  }
}
```

## Intervention Safety Model

### Severity Escalation

```
OBSERVE (sev=0) → WARN (sev=1) → KILL (sev=2) → KILL+RESTART (sev=3)
```

| Severity | Code | Action |
|----------|------|--------|
| 0 | OBSERVE | Log detection, no action |
| 1 | WARN | Write alert to dashboard and heartbeat, no destructive action |
| 2 | KILL | Verified escalation — see below |
| 3 | KILL+RESTART | Kill + spawn new pipeline (if auto-restart enabled and under cap) |

### Owned Worker Lifecycle

Fleet controller **owns** each worker it spawns — the same pattern OTP, systemd, and Kubernetes converged on: whoever starts a worker holds its handle and is the sole authority that can declare it dead, with fencing so a superseded worker's side effects are rejected rather than trusted to stop.

#### Run Registry (`{tid}-run.json`)

A per-ticket JSON file written at spawn, containing:
- `tid`: Ticket identifier
- `pid`: Worker process ID (0 sentinel = "being spawned")
- `generation`: Monotonic integer, starts at 1, incremented on every restart
- `started_at`: ISO 8601 timestamp
- `reason`: Spawn reason (dispatch, auto-restart, manual)

Per-ticket files avoid shared-file write races across concurrent spawns and match the existing per-ticket log/heartbeat convention.

**Location**: `{state_dir}/{tid}-run.json` (workspace-relative, survives reboot)

#### Verified Kill Escalation

Sequence, executed by `fleet_kill_pipeline` in `fleet-intervene.sh`:

1. **Stop-files**: Touch `{tid}-pinger-stop` + `{tid}-watchdog-stop` (signals cooperative shutdown)
2. **Grace period**: Wait `FLEET_KILL_GRACE_SECS` (default 10s) for cooperative exit
3. **PID check**: `kill -0` on registry PID — if gone, worker cooperated; finalize and fence
4. **PID-reuse guard**: Before signalling, corroborate PID ownership (process start-time newer than registry `started_at`, or cmdline match). On mismatch, downgrade to `kill-unverified` — do NOT signal
5. **SIGTERM**: Send TERM, wait grace period, check again
6. **SIGKILL**: If still alive, send KILL, brief wait, final check
7. **Finalize**: Write `META|outcome` ONLY after PID confirmed gone
8. **Fence**: Write `{tid}-fence` marker recording the killed generation

If PID never confirms (survives SIGKILL), emit `kill-unverified` WARN — do NOT finalize as `stopped`.

#### Generation Fencing (`{tid}-fence`)

Kill writes a fence marker recording the fenced generation. `flow.sh` — the single chokepoint for every Linear mutation — consults the fence before any API call:

| Scenario | Behavior |
|----------|----------|
| `caller_gen <= fenced_gen` | **Refuse** (exit 10, no Linear call) |
| `caller_gen > fenced_gen` | **Allow** (current generation) |
| No fence marker | **Unrestricted** (backward compatible) |
| Fenced ticket, no generation token | **Refuse** (exit 9, fail-closed) |

Gated behind `FLEET_FENCE_ENFORCE=true` (default). Set to `false` for emergency rollback.

**Location**: `{state_dir}/{tid}-fence`

### Rollback

| Emergency | Flag | Effect |
|-----------|------|--------|
| Kill escalation misbehaving | `FLEET_KILL_VERIFY=false` | Falls back to stop-file-only (pre-escalation behavior) |
| Fencing blocking legitimate mutations | `FLEET_FENCE_ENFORCE=false` | Disables all fence checks in flow.sh |
| Dry-run mode | `FLEET_DRY_RUN=true` | No signals, no outcomes, no fences — prints planned actions |

## Dispatch Flow

1. **Initiative validation**: `fleet_dispatch_initiative` queries Linear for the epic, verifies `state:execution` label
2. **Child enumeration**: Finds child tickets with `planned` label + `Backlog` state
3. **Dependency resolution**: For each `blocked-by:{ID}` label, checks blocker state via `get_issue`; skips blocked tickets
4. **Capacity check**: Computes active pipeline count (pipeline logs without `META|outcome`), respects `FLEET_MAX_CONCURRENT`
5. **Queue write**: Appends JSONL entries to spawn queue under `flock` serialization

### Spawn Queue Format

```jsonl
{"tid":"CRE-101","reason":"planned-dispatch from INIT-42","timestamp":"2026-07-15T10:00:00Z","restarts":0,"dispatch_type":"initial","generation":1}
```

**Location**: `{state_dir}/fleet-{instance}-spawn-queue.jsonl`

### Spawn Queue Serialization

Both append (dispatch) and consume (monitor) take an exclusive `flock` on `${queue_file}.lock` with timeout `FLEET_QUEUE_LOCK_TIMEOUT` (default 5s). On timeout, the monitor skips the cycle with a WARN rather than blocking indefinitely. This eliminates the race where `_spawn_queue_consume` reads the queue, builds surviving entries in memory, then `mv`s a rewritten file over it — destroying any entry appended after the read snapshot.

## Monitor Loop

`fleet_monitor_loop` runs detection + intervention continuously:

```
while stop-file absent:
    data = fleet_detect_all(workspace)
    fleet_render_dashboard(data)
    fleet_write_report(data)
    for pipeline in data.pipelines:
        if severity >= 2:
            hb_fleet_action("anomaly-detected")
            if severity == 3: fleet_restart_pipeline() + _spawn_restart()
            else: fleet_kill_pipeline()
    _spawn_queue_consume(workspace, active_count)
    emit fleet-summary on state change or forced interval
    sleep FLEET_POLL_INTERVAL
```

### Dual Spawn Modes

| Mode | Detection | Behavior |
|------|-----------|----------|
| Interactive (`CLAUDE_CODE_SESSION_ID` set) | Claude Code session | Emits `ACTION:spawn-restart`/`ACTION:spawn-auto` to stdout |
| Cron (`CLAUDE_CODE_SESSION_ID` absent) | Headless | Writes to spawn queue JSONL for external consumer |

### State-Transition Gating

Fleet-summary heartbeats are emitted only on state change OR forced interval (`FLEET_SUMMARY_INTERVAL_CYCLES`, default 10). This prevents noisy repeated heartbeats when fleet health is stable while still guaranteeing periodic baseline emissions.

## Feedback Pipeline

`fleet-feedback.sh` aggregates `META|planner-feedback` entries from pipeline logs:

1. Scans all `{tid}-pipeline.log` files for `META|planner-feedback` entries
2. Groups by `{initiative-id}` (extracted from feedback text or ticket labels)
3. Computes confidence drift: actual outcomes vs planner predictions
4. Writes structured JSON to `$REPOS_ROOT/.ticket-auto/initiatives/{ID}/feedback/{rundate}.json`

## Durable State Reference

All persistent state is workspace-relative — survives host reboot:

| File | Purpose | Format |
|------|---------|--------|
| `{state_dir}/fleet-{instance}-spawn-queue.jsonl` | Pending dispatches | JSONL, `flock`-serialized |
| `{state_dir}/fleet-{instance}-controller-stop` | Graceful shutdown signal | Empty sentinel file |
| `{state_dir}/ticket-auto-{tid}-pinger-stop` | Background pinger shutdown | Empty sentinel file |
| `{state_dir}/ticket-auto-{tid}-watchdog-stop` | Background watchdog shutdown | Empty sentinel file |
| `{state_dir}/{tid}-run.json` | Worker ownership record | JSON: tid, pid, generation, started_at, reason |
| `{state_dir}/{tid}-fence` | Generation fence marker | JSON: tid, fenced_generation, fenced_at |

`state_dir` resolves to `FLEET_STATE_DIR` (env var) or falls back to the workspace directory.

## Configuration

All settings use `${VAR:-default}` pattern for env-var overrides:

### Detection Thresholds

| Variable | Default | Description |
|----------|---------|-------------|
| `FLEET_POLL_INTERVAL` | 30 | Seconds between monitor cycles |
| `FLEET_STALL_WARN_SECS` | 300 | Stale heartbeat threshold for WARN |
| `FLEET_STALL_KILL_SECS` | 900 | Stale heartbeat threshold for KILL |
| `FLEET_STALL_RESTART_SECS` | 1800 | Stale heartbeat threshold for KILL+RESTART |
| `FLEET_ABANDON_WARN_HOURS` | 1 | Abandonment threshold for WARN |
| `FLEET_ABANDON_KILL_HOURS` | 4 | Abandonment threshold for KILL+RESTART |
| `FLEET_ZOMBIE_SECS` | 900 | Unresolved waiting entry threshold |

### Intervention Control

| Variable | Default | Description |
|----------|---------|-------------|
| `FLEET_MAX_RESTARTS` | 2 | Max automatic restarts before giving up |
| `FLEET_AUTO_RESTART` | false | Enable automatic restarts |
| `FLEET_DRY_RUN` | false | Interventions logged, not executed |
| `FLEET_MAX_CONCURRENT` | 3 | Max concurrent pipelines for dispatch |
| `FLEET_KILL_GRACE_SECS` | 10 | Wait for cooperative shutdown before SIGTERM |
| `FLEET_KILL_VERIFY` | true | Fall back to stop-file-only kill when false |

### Fencing & Durable State

| Variable | Default | Description |
|----------|---------|-------------|
| `FLEET_FENCE_ENFORCE` | true | Enable generation fencing in flow.sh |
| `FLEET_STATE_DIR` | (workspace) | Durable state directory |
| `FLEET_QUEUE_LOCK_TIMEOUT` | 5 | Spawn queue flock timeout |
| `FLEET_INSTANCE_ID` | default | Namespace for multi-instance isolation |
| `FLEET_SUMMARY_INTERVAL_CYCLES` | 10 | Cycles between forced fleet-summary heartbeats |

## Dependency Bridge

Fleet controller depends on two libraries defined in `ticket-auto-pipeline/`:
- `linear-api.sh` — GraphQL API client (used by `fleet-dispatch.sh` for Linear queries)
- `heartbeat.sh` — Heartbeat log helpers (used by `fleet-monitor.sh`, `fleet-dashboard.sh`, `fleet-intervene.sh`)

These are sourced from `~/.claude/skills/lib/` (synced by the ticket-auto-pipeline SessionStart hook). Fleet controller does not maintain its own copies — it bridges to the canonical sources.

## Crash Recovery

- **Monitor loop**: Exits on stop-file detection. Cron or a watcher restarts it.
- **Spawn queue**: Survives reboot (workspace-relative). Entries are consumed idempotently — re-dispatching an already-queued ticket is a no-op.
- **Run registry**: Written at spawn. At restart, prior generation is read to compute the next increment.
- **Fence markers**: Persist until cleared by a new generation spawn. Ensure zombie mutations are blocked even across controller restarts.
- **Pipeline logs**: Fleet controller reads pipeline logs; it never writes to them except for intervention markers (`META|fleet-intervention`, `META|outcome`, `META|kill-unverified`).

## Related Docs

- [Fleet-controller robustness critique](fleet-controller-robustness-critique-2026-07-15.md) — deep-dive analysis of pre-escalation gaps
- [Root CLAUDE.md](../CLAUDE.md) — marketplace-wide conventions
- [ticket-auto-pipeline CLAUDE.md](../ticket-auto-pipeline/CLAUDE.md) — pipeline-level guidance
