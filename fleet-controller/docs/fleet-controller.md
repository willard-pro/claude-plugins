# Fleet Controller — Architecture & Operations

Parent orchestrator above ticket-planner and ticket-auto. Dispatches planned tickets from initiative epics, monitors all active pipeline health via 12 detection engines, escalates autonomously through OBSERVE → WARN → KILL → KILL+RESTART severity levels, and aggregates execution feedback back to the planner. Bash-only — zero Claude agents, zero LLM reasoning. All detection and intervention is deterministic.

## Architecture Overview

```
┌─────────────────────────────────────────────┐
│              Fleet Controller                │
│  ┌─────────┐ ┌──────────┐ ┌──────────────┐ │
│  │ Detect  │→│Intervene │→│   Dispatch    │ │
│  │(12 eng) │ │(verified │ │(spawn queue + │ │
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

## Detection Engines (12 total)

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

### 12. Epic Branch Ready (`detect_epic_branch_ready`)
**What it catches**: Directive-carrying `state:execution` epics whose planned children are all Done — the epic is ready for its integration PR.
**Severity**: 1 (WARN, ready epic with no integration PR yet).
**Actuation**: When `FLEET_EPIC_AUTO_PR=true`, the detector calls `epic_branch_open_pr` once per repository the epic branch was created in (the same repo set dispatch's precondition iterates — shared `_fleet_repos_under_root` enumeration, not a re-guess). With actuation off (default) the finding is reported but no PR opens. Repeated cycles are no-ops via `epic_branch_open_pr`'s existing-PR idempotency check. The integration PR is **never auto-merged** under any configuration — merging stays a permanent human gate enforced by two independent guards.
**Readiness**: Delegated to the canonical `epic_branch_children_done` helper — no independent inline evaluation. This codebase has exactly one implementation of "are all of this epic's children Done".

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

`fleet_dispatch_initiative` is the single repeatable campaign command: run it
any time, and it resumes dead/incomplete child pipelines, enqueues the
newly-unblocked next wave, and skips what is queued/running/done. Consecutive
calls converge (second call enqueues/resumes zero when nothing changed).

1. **Initiative validation**: queries Linear for the epic, verifies `state:execution` label; stop-file gate (only `--resume` clears)
2. **Campaign reconcile (Step 1.75)**: runs the shared `fleet_reconcile_orphans` scoped to ALL of the epic's children (`FLEET_RECONCILE_TIDS` = every child identifier from the epic query, regardless of label/state — a mid-flight child is not in Backlog), re-enqueueing incomplete pipelines with reason `campaign-resume from {epic}` (`FLEET_RECONCILE_EPIC`). Dry-run propagates via `FLEET_RECONCILE_DRY_RUN`. Killed pipelines are resumable: `fleet_ticket_terminal_state` classifies a `stopped: fleet-kill` outcome as `incomplete` unless the log carries a `|META|gate-stop|fail|` line. The startup path sets none of these envs and stays global.
3. **Child enumeration**: Finds child tickets with `planned` label + `Backlog` state
4. **Dependency resolution**: For each `blocked-by:{ID}` label, checks blocker state via `get_issue`; skipped children are reported as `  blocked {tid}` (never silent)
5. **Capacity check**: **live-only** — `_active_pipeline_count` counts a no-outcome pipeline log only when its worker is pgrep-live or run-registry-alive (`kill -0` on the registry pid); dispatch additionally reserves `_fleet_queued_count_for_epic` slots for the epic's own pending queue entries (`planned-dispatch` or `campaign-resume from {epic}`). A dead log never consumes a slot. The monitor loop's consume path uses the same helper, so fleetd and the monitor agree on capacity.
6. **Queue write**: Appends JSONL entries to spawn queue under `flock` serialization
7. **Summary**: last stdout line is `fleet_dispatch: resumed N | blocked N | enqueued N ticket(s) for {epic}` (dry-run: `[DRY-RUN] would resume N | blocked N | would enqueue N ...`); `POST /dispatch` parses the per-tid lines into `resumed`/`blocked` arrays alongside `queued`

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
| `{state_dir}/{tid}-last-generation` | Preserved last-known generation (written before a stale registry entry is deleted) | JSON: generation |
| `{state_dir}/fleet-{instance}-spawn-queue-dead-letter.jsonl` | Entries that could not be enqueued or restarted | JSONL, human-readable and replayable |

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
| `FLEET_AUTO_RESTART` | true | Automatic restarts enabled by default; set `false` to opt out |
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
| `FLEET_RECONCILE_TIDS` | (unset) | Space-separated tid scope for `fleet_reconcile_orphans`; unset = global scan (startup path) |
| `FLEET_RECONCILE_EPIC` | (unset) | Re-enqueue reason `campaign-resume from {epic}` instead of `orphan-reconciliation` |
| `FLEET_RECONCILE_DRY_RUN` | (unset) | Non-empty (not `0`/`false`) = dry run: report intents, write nothing |

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

### fleetd's own restart is externally supervised

fleetd does not supervise itself — a crashed daemon is restarted by the host's
init system, not by fleetd. See [Process Supervision](process-supervision.md):
a shipped systemd unit (`Restart=always`, bounded `RestartSec`) is the primary
path, with a documented cron-watchdog fallback for non-systemd hosts. The
existing single-instance `flock` guard composes with both: a supervisor
restart racing a still-shutting-down instance fails the lock instead of
running two supervisors.

### Startup orphan reconciliation

A worker that dies *while fleetd is down* leaves a stale run-registry entry
that `scan_workers` deletes — without this step the ticket would be silently
lost. Once at startup, immediately after worker adoption and before the first
detection cycle, fleetd runs `fleet_reconcile_orphans` (bash,
`fleet-controller/lib/fleet-reconcile.sh`):

1. Glob every `{tid}-pipeline.log` in the state dir (scoped by
   `FLEET_RECONCILE_TIDS` when set — dispatch passes an epic's children; the
   startup path leaves it unset and scans globally).
2. Skip tickets with an adopted-live worker (the just-adopted set is passed
   in) or an unconsumed spawn-queue entry.
3. Classify the rest read-only (no Linear/gh calls): `done` (terminal outcome
   or gate-stop), `gate-held` (waiting on the human), `incomplete` (mid-flight).
   A `stopped: fleet-kill` outcome classifies `incomplete` — kill is a pause,
   the stop-file pin is the stop — unless a gate-stop marker exists.
4. Re-enqueue `incomplete` tickets via the shared `_fleet_queue_append`
   (same flock/retry/dead-letter logic as normal dispatch). Entries carry no
   branch/epic context — the re-spawned `ticket-auto` resolves or rehydrates
   its own, exactly as for any other re-invocation. Entry reason is
   `orphan-reconciliation` on the startup path, `campaign-resume from {epic}`
   when `FLEET_RECONCILE_EPIC` is set. `FLEET_RECONCILE_DRY_RUN` prints
   would-resume/would-dead-letter lines and writes nothing.
5. Restart counting and the cap use the **existing**
   `fleet_can_restart`/`_count_restarts`/`FLEET_MAX_RESTARTS` mechanism — a
   live-reap restart and an orphan restart are the same event type and share
   one counter. At the cap the ticket is dead-lettered with reason
   `orphaned-after-max-restarts` instead of looping forever.

A reconciliation failure logs and continues — it never blocks daemon startup.

### Stop pins every child that could otherwise resume

`fleet_stop_initiative` resolves the epic's children from Linear (light
`issue(id) { children { nodes { identifier } } }` query) and:
- **purges** queue entries whose reason matches `planned-dispatch from
  {epic}` OR `campaign-resume from {epic}` (space-terminated match), or
  whose tid is one of the resolved children;
- **kills** running workers whose run-registry reason matches the same
  alternation;
- **pins** — the stop-file `tickets` array is the union of purged, killed,
  and every child whose pipeline log classifies `incomplete` (fallback when
  the classifier is unavailable: log exists without `|META|outcome|`).

A stop with an empty queue and no live workers therefore still pins its
mid-flight children — the `tickets: []` gap that once let an orphan be
re-adopted after a stop. A children-query failure degrades with a warning
and an empty child set; the stop never aborts on a Linear outage.

### fleetd's consume check mirrors the bash classifier

`_consume_queue_locked` (supervisor.py) evaluates each queue entry's
pipeline log with `_log_reached_terminal` — the Python mirror of the
resume-relevant rules in `fleet_ticket_terminal_state` (kill outcomes are
resumable, gate-stop and dead-letter are terminal, `held: gate` is not).
The raw `|META|outcome|` grep it replaces would have dropped the
campaign-resume entries the classification fix produces. Keep the two in
sync: both sides carry cross-referencing comments.

### Generation continuity across stale-registry deletion

Before `scan_registry` deletes a stale `{tid}-run.json` (dead PID or
unverifiable ownership), it preserves the entry's `generation` to
`{tid}-last-generation` in the same state dir. The next spawn computes
`generation = max(fence's fenced_generation, registry generation,
preserved last-known generation) + 1` — so a reconciled re-spawn continues the
existing generation sequence instead of restarting at 1. This continuity
holds on the fleetd path (fleetd computes the generation itself); the
cron/monitor path trusts the queue entry's `generation` field, which writers
always emit as 1 — a monitor-spawned restart of a fenced ticket runs at
generation 1 and IS rejected by `fleet-generation-fencing`.

### Dead-lettered tickets are surfaced

Every dead-letter write (queue-contention-exhausted from the append path,
orphaned-after-max-restarts from reconciliation) also emits a structured line
— `fleet-dead-letter|tid=<TID>|reason=<REASON>` — and the reconciliation path
writes a `META|dead-letter|warn|reason=<REASON>` marker to the ticket's own
pipeline log. The dead-letter file is human-readable and replayable — feed
its lines back through `_fleet_queue_append` to re-queue. No shipped
consumer scans dead-letters yet (`/ticket-overseer` does not); wire one
before assuming visibility. A permanently-stuck ticket no longer sits
silently on disk, but it needs an operator (or a future dashboard) to see it.

## Related Docs

- [Process Supervision](process-supervision.md) — systemd unit + cron watchdog fallback for keeping fleetd itself running
- [Fleet-controller robustness critique](fleet-controller-robustness-critique-2026-07-15.md) — deep-dive analysis of pre-escalation gaps
- [Root CLAUDE.md](../CLAUDE.md) — marketplace-wide conventions
- [ticket-auto-pipeline CLAUDE.md](../ticket-auto-pipeline/CLAUDE.md) — pipeline-level guidance
