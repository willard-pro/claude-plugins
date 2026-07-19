# Fleet-controller robustness critique — 2026-07-15

Goal: make fleet-controller trustworthy as a supervisor of *many* concurrent ticket-auto
workers. Findings from a full read of all six libs (`fleet-detect.sh`, `fleet-intervene.sh`,
`fleet-monitor.sh`, `fleet-dispatch.sh`, `fleet-dashboard.sh`, `fleet-feedback.sh`).

## Verdict

The **detection** side is well-built. The **actuation** side is open-loop: fleet-controller
can neither actually kill a worker nor actually start one — both actuators are advisory
(stop-files + `META|outcome` bookkeeping on the kill side; a printed `ACTION:spawn-*` line or
an unconsumed JSONL queue entry on the spawn side). It observes and annotates; it does not
own worker lifecycle. That open loop is the core reason not to trust it at fleet scale.

## What is already right (preserve)

- Determinism boundary (bash-only detection/intervention, no LLM).
- `FLEET_DRY_RUN` gates every destructive path.
- flow.sh mutex awareness before intervening (`_flow_mutex_held`).
- Instance namespacing (`FLEET_INSTANCE_ID`) on stop files / spawn queue.
- Severity ladder with degrade-to-WARN when `FLEET_AUTO_RESTART=false`.
- `_last_msg` awk join fix for pipe-containing MSG fields (avoids `cut -f5` truncation).
- Single detection pass per cycle, reused by dashboard + report + intervention.
- Per-lib test suite.

## Findings

### 1. (P0) "Kill" does not kill the worker — deepest trust gap
`fleet_kill_pipeline` touches `pinger-stop`/`watchdog-stop` files and writes `META|outcome`
to finalize the log, then returns. The **Claude agent session keeps running** — it can keep
mutating Linear, pushing commits, and burning tokens. No PID tracking, no post-kill
verification, no SIGTERM/SIGKILL escalation. A "killed" runaway is only un-watched, not stopped.

### 2. (P0) Spawn/restart is open-loop
Restart and dispatch end at an `ACTION:spawn-*` stdout line (interactive) or a JSONL queue
entry (cron) with **no consumer** that invokes `/ticket-auto <ID> --auto`. Full KILL+RESTART
path today: mark old run dead (while possibly still alive) → print a line nobody reads.
Cross-ref: `ticket-planner-implementation.md` Part 4 `fleet-controller-dispatch` (0/32 TODO).

### 3. (P0, bug) Restart cap double-counted
`_count_restarts` = `grep -c 'fleet-restart'`, but each restart writes TWO matching lines:
`META|fleet-restart|…` and `META|fleet-restart-marker|…`. One restart counts as 2, so
`FLEET_MAX_RESTARTS=2` is exhausted after a single restart. Fix: anchor to `|META|fleet-restart|`.

### 4. (P0, bug) Spawn-queue rewrite loses concurrent appends
`_spawn_queue_consume` reads the queue, builds `remaining_entries` in memory, then `mv`s a
rewritten file over it. Any entry appended by `fleet-dispatch.sh` after the read snapshot is
destroyed by the `mv` (the code comment claims the opposite). Low per-cycle probability, but a
when-not-if at N workers × 30s loop. Fix: `flock` the queue around append + rewrite, or use a
consumed-offset marker instead of rewriting.

### 5. (P0) No run identity → no fencing
Restart reuses `{tid}-pipeline.log`. Because kill is advisory (#1), a zombie old run and a
fresh new run can interleave writes into the same log the detectors parse — detection state
corrupts precisely in the failure case it exists for. Classic supervisor fencing problem:
nothing prevents a superseded run from continuing to act.

### 6. (P1) Log-as-sole-truth fragility
All signals come from log parsing. `_last_entry_age_secs` on a malformed ISO timestamp →
`date -d` yields 0 → apparent age ~56 years → false stall → healthy worker killed. No
corroborating signal. `_active_pipeline_count` = "logs without `META|outcome`" → a crashed
agent that never wrote outcome holds a concurrency slot for hours until `detect_abandoned`
fires, throttling the fleet.

### 7. (P1) Static thresholds cause false kills at scale
`FLEET_STALL_KILL_SECS=900` is global. IMPLEMENT and VERIFY (Playwright UAT) legitimately run
long and quiet. No per-phase thresholds → healthy long-runners get killed → trust collapses.

### 8. (P1) Durable state in /tmp
Spawn queue, stop files, restart intent all live in `/tmp`. Host reboot silently loses queued
dispatches and in-flight restart decisions. Fine for advisory signals; wrong for the queue.

### 9. (P2) Nobody watches the watcher; no blast-radius cap
Nothing monitors the monitor loop's liveness. Instance ID is a namespace, not a lock — two
instances can race. `FLEET_AUTO_RESTART` has no token-budget or restarts-per-hour circuit
breaker beyond the (broken, #3) per-ticket cap. A flapping detector could kill/respawn the
whole fleet in a loop, spending real money each cycle.

## Core pattern

Findings 1, 2, 5 share one root: fleet-controller **signals** where a supervisor must **own**.
OTP, systemd, and Kubernetes converged on the same invariant — the process that starts a
worker holds its handle (PID/lease) and is the only thing that can declare it dead, with
fencing so a superseded worker's writes are rejected rather than trusted to stop. Signal-based
coordination (stop files, printed ACTION lines) only works when every party is healthy — which
is exactly when a supervisor is not needed.

## Recommended modifications (priority order)

### P0 — close the loop (makes it trustworthy)
1. **Own the process.** Spawn workers from a consumer that records PID + run-id
   (`{tid}-run.json`: pid, generation, started-at). Kill = stop files → grace period → verify
   PID gone → SIGTERM → SIGKILL → *then* finalize the log. Maps 1:1 onto the planned Python
   asyncio supervisor — build it as that supervisor's first slice, not throwaway bash.
2. **Fence at the determinism boundary.** Kill writes a fence marker (`{tid}-fence` = killed
   generation); `flow.sh` refuses mutations from a fenced generation. A zombie can then only
   waste its own tokens, never corrupt Linear.
3. **Fix the two bugs** (#3 restart double-count; #4 queue rewrite race via `flock`).
4. **Move spawn queue + restart state out of /tmp** into the workspace/logs dir.

### P1 — calibrate and corroborate
5. Per-phase stall thresholds (`FLEET_STALL_KILL_SECS_IMPLEMENT=2700`, etc.), fall back to global.
6. Active-count = log-not-finalized ∧ PID alive (possible once #1 exists). Frees crashed slots.
7. Malformed-timestamp guard in `_last_entry_age_secs` → emit `log-corrupt` WARN, don't feed
   the stall math.
8. Restart backoff + quarantine: exponential delay between restarts; at cap, add a
   `fleet-quarantined` Linear label + Slack notify instead of a silent dashboard row.

### P2 — supervise the supervisor
9. Run monitor under cron + `flock` (exactly-one-instance, auto-resurrect); emit its own
   heartbeat that a trivial external check alerts on.
10. Fleet-wide circuit breaker: max spawns/hour + per-ticket token-budget ceiling (the existing
    P1 "token budget gate" candidate — the cost sibling of loop detection).

## One-line summary

Detection is trustworthy today; nothing downstream of detection is, because every intervention
ends in a hope rather than a verified state change. Close the actuation loop with owned PIDs +
fencing, fix the two bugs, and the rest is calibration.
