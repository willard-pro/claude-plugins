# Fleet Campaign Resume — 3-Persona Review Checklist (commit 02959a3)

Review of `feat/fleet-campaign-resume` against goal: **resume a campaign after fleetd restart without manual intervention**.
Personas: architect, qa-engineer, analyzer (project personas: `ticket-auto-pipeline/personas/`). All read-only.
Suites run by QA: 104/104 pytest (from repo root), 42/42 dispatch, 26/26 reconcile, 6/6 monitor-dispatch — all green. Suite is green while the central terminal-skip guard is dead code (F01) and its only guard test is tautological (F02).

## P0

- [x] **F01 — `_log_reached_terminal` checks the wrong field index; outcome/dead-letter arms are dead code, completed tickets re-spawn from stale queue entries after restart** — fixed: `last[2]` (STEP) with len guards; unit-tested via `test_log_reached_terminal_mirrors_bash_classifier`. Source: arch+qa+ana.

## P1

- [x] **F02 — Guard test tautological: `assertNotIn('TST-T1', sup._children)` can never fail** — fixed: `ChildTable.__contains__` added + assertion switched to `assertIsNone(sup._children.get('TST-T1'))`. Source: qa+ana.
- [x] **F03 — Kill-resume test passes for the wrong reason; `_log_reached_terminal` has no direct unit test** — fixed: `test_log_reached_terminal_mirrors_bash_classifier` pins 10 log shapes against bash semantics (kill → False, held:gate → False, other outcome → True, dead-letter → True, gate-stop+kill → True, gate-held → False, missing/empty → False). Source: qa.
- [x] **F04 — `set -eo pipefail` leaks into monitor shell via new fleet-dispatch.sh source; transient failure kills the long-running monitor loop** — `fleet-monitor.sh:42` + `linear-api.sh:6`. Fix: save/restore shell options around the `linear-api.sh` source in `fleet-dispatch.sh` (or source in subshell). Test: source fleet-monitor.sh → assert `$-` has no `e`, pipefail off. Source: ana.
- [x] **F05 — `_fleet_tid_live` pgrep substring collision: dead `CRE-7` counts live when `CRE-70` runs** — `fleet-reconcile.sh:44`. Fix: anchor pattern `pgrep -f "ticket-auto ${tid}([^0-9]|$)"`. Test: cmdline `ticket-auto CRE-70` must not make `_fleet_tid_live CRE-7` true. Source: ana+arch.
- [x] **F06 — Stop pin set derived only from Linear query; Linear outage → pins vanish → stopped campaign resurrects after restart** — `fleet-dispatch.sh:661-814`. Fix: derive conservative child set from state dir when Linear fails (or fail closed). Test: children-query failure + incomplete child log, empty queue, no registry → child still in `stop-{epic}.json` tickets. Source: arch.
- [x] **F07 — Duplicate-enqueue race: `_queue_has_ticket` check-then-act outside the queue flock** — `fleet-reconcile.sh:257-260` vs `_fleet_queue_append` flock. Fix: dedupe by tid inside `_fleet_queue_append` under flock. Test: two concurrent appends same tid → exactly one entry. Source: arch.
- [x] **F08 — Dispatch Step 1.75 reconcile passes empty pinned-tids; pinned child can be re-enqueued** — `fleet-dispatch.sh:446-456`. Fix: pass `_collect_stop_pinned_tids` result. Test: stop-file pins one child; dispatch over incomplete log → no resume entry for pinned child. Source: qa+ana.
- [x] **F09 — Python mirror diverges from bash classifier on check ordering (gate-stop + later `held: gate` outcome)** — fixed: mirror reordered outcome-first with bash's kill-arm gate-stop check and a gate-held last-step arm; pinned by `test_log_reached_terminal_mirrors_bash_classifier`. Source: ana.

## P2

- [x] **F10 — Monitor (cron) consume path has no terminal-state check; stale completed entry spawned unconditionally** — `fleet-monitor.sh:116-180`. Fix: route through same kill-aware terminal check. Test: queue entry with `META|outcome|info` log → no spawn action. Source: arch.
- [x] **F11 — Two-source-of-truth classifier (bash vs Python) has no equivalence enforcement; already drifted** — add fixture corpus test (done/kill-resumable/gate-stop+kill/dead-letter/gate-held/empty/mid-flight) asserting bash and Python agree. Source: arch.
- [x] **F12 — `_registry_pid_alive` trusts `kill -0` alone; PID reuse counts dead worker as live** — `fleet-dispatch.sh:86-94`. Fix: compare `/proc/<pid>/stat` start time against `started_at`. Test: run.json with live-but-unrelated PID → count 0. Source: arch+qa.
- [x] **F13 — `_active_pipeline_count` treats any outcome log as inactive even when worker survived (FLEET_KILL_VERIFY=false)** — `fleet-dispatch.sh:110`. Fix: for outcome logs also require worker dead (`! _fleet_tid_live`). Test: kill-outcome + live worker → counted active; + dead worker → not. Source: ana.
- [x] **F14 — SKILL.md duplicated `### Stop (`stop`)` section** — remove old block, keep new. Source: arch.
- [x] **F15 — README.md API contract not updated: `POST /dispatch` now also returns `resumed`/`blocked`** — update README. Source: arch.
- [x] **F16 — No double-dispatch idempotency test** — run `fleet_dispatch_initiative` twice over same workspace → exactly one queue entry per tid, second summary `resumed 0`. Source: qa.
- [x] **F17 — Dispatch dead-letter path untested; summary ignores dead-letter side effect** — test dispatch with child at restart cap → dead-letter entry written; reflect in summary. Source: qa.
- [x] **F18 — Capacity test leaks `sleep 30` processes; no trap cleanup** — `test-fleet-dispatch.sh:270-297`. Fix: trap EXIT kill. Source: qa.
- [x] **F19 — pytest from `fleet-controller/` fails 5/104 daemon tests (harness path trap)** — document repo-root requirement in test header (or make `_fleetd_cmd` fallback). Source: qa.
- [x] **F20 — fleetd and monitor still count capacity from different sources; transient over-allocation possible** — document the bound (do not unify in this pass). Source: ana.

## Verdicts used

- /tmp/persona-findings-architect.md (9 findings)
- /tmp/persona-findings-qa.md (11 findings)
- /tmp/persona-findings-analyzer.md (8 findings)
