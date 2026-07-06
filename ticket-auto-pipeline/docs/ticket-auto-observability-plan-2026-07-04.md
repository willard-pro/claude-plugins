# ticket-auto Observability & Fleet Real-Time Control — Findings & Incremental Plan

**Date:** 2026-07-04
**Status:** Planned (not started)
**Goal (user-stated):** full visibility on pipelines; fleet controller able to monitor
pipeline agents in real time and exert better control.
**Scope reviewed:** the three log streams (pipeline / heartbeat / claude), the in-flight
window mechanisms (`hb_pinger_start`, `spawn_watchdog_start`), hooks (`token-tracker`,
`tool-error-capture`), `capture-transcript.sh`, fleet engines (`fleet-detect.sh` stall +
zombie), `dashboard.py`, fleet cadence.
**Companion plans:** `ticket-auto-router-hardening-plan-2026-07-04.md` (R4/R13 interact
with O2/O4 below), `pipeline-integrity-plan-2026-07-04.md` (G1 gate-warn channel is a
fleet-consumption precedent).

---

## The architectural finding

**Every liveness signal the fleet reads is orchestrator-side; the thing that hangs is the
agent.** Trace:

- While an agent is in flight, the orchestrator runs two background emitters: the pinger
  (`heartbeat.sh:183` — `orchestrator-waiting|pinger i/80` every 90s, max 80 iterations
  ≈ 2h) and the watchdog (`spawn-helper.sh:492` — `watchdog|alive|waiting for {phase}
  agent` every 60s, **unbounded `while true`**, stop-file only, disowned).
- The fleet stall engine (`fleet-detect.sh` `detect_stalls`) computes staleness from the
  latest `orchestrator-waiting|watchdog|alive` line, thresholds 300/900/1800s.
- **Neither emitter knows anything about the agent.** A hung agent (stuck Playwright,
  rate-limited API loop, dead MCP server) keeps both ticking → heartbeat always fresh →
  stall severity 0, for up to ~2 hours until pinger exhaustion.
- Worse: the watchdog is a disowned infinite loop. If the **orchestrator itself dies**
  without running `spawn_agent_post` (no stop-file), the watchdog survives re-parented and
  emits `alive` forever → the stall engine **can never fire on a dead router**. The
  heartbeat stream actively lies.

The only real net today is the zombie engine (`detect_zombies`: `|waiting|` lines with no
terminal, threshold `FLEET_ZOMBIE_SECS=900`). Two problems: (a) 15 minutes of blindness,
and it cannot distinguish a healthy long-running implement from a hung one — same signal;
(b) its terminal-matching greps the **whole file** for `|phase|step|done/fail/skip|`, so in
retry loops, attempt 1's terminal masks attempt 2's zombie — the same whole-file-matching
disease as router-hardening R4.

**The missing primitive is an agent-side activity signal.** Everything else in this plan
hangs off that.

---

## Findings

### O1 — No agent-side liveness signal (critical; the real-time gap)

As traced above. **Fix — three coordinated pieces:**

1. **Activity hook (the new primitive):** a `PostToolUse` hook (sibling of
   `token-tracker.sh`, same spawn-meta → ctx-file ticket resolution) that on **every tool
   call** in a pipeline session appends `ISO|PHASE|TOOL_NAME` to
   `logs/{TICKET_ID}-activity.log` (ring-capped, e.g. keep last 500 lines). Agents make
   tool calls continuously — this is the ground-truth "agent last did something at T"
   signal, resolution seconds not minutes.
2. **Fleet consumes it:** stall engine gains an agent-activity input — age of last
   activity line, with its own thresholds (suggest WARN 240s / KILL-candidate 900s while a
   spawn bracket is open). Orchestrator heartbeats remain as a *router*-liveness signal,
   but agent-liveness now has a truthful source. Healthy-long-running vs hung becomes
   distinguishable: waiting bracket open + activity fresh = healthy; activity stale = hung.
3. **Make heartbeat absence meaningful:** bound the watchdog (`max_iter` like the pinger)
   and add a `spawn_agent_post`-side sweep that kills orphaned pinger/watchdog PIDs from
   prior brackets. A dead orchestrator must eventually go *silent*, not immortally "alive."

### O2 — Zombie engine's whole-file terminal matching masks retry-loop zombies

`detect_zombies` counts `|phase|step|(done|fail|skip)|` anywhere in the log to decide a
`waiting` entry is closed. In verify-retry / pr-iterate cycles, attempt 1's terminal
closes attempt 2's zombie. **Fix:** match terminals **after** the waiting line's position
(line-offset scoped), not file-wide. Coordinate with router-hardening R4 (tail-scoped
dedup) — both fixes touch the same bracket-pairing semantics and should share a fixture
test set of retry-loop logs.

### O3 — Agent output is post-hoc only

`capture_agent_result` persists the agent's final output *after* return; nothing streams
in-flight. With O1's activity hook, **liveness** no longer needs streaming; in-flight
**content** (what is it doing?) remains invisible. Acceptable near-term. Optional later:
the activity hook already records tool names — extend it to include a truncated
tool-input summary (e.g. first 80 chars of Bash `description`) for a cheap live "what's
it doing" feed without transcript streaming. Defer full transcript streaming.

### O4 — No fleet-wide live view

`dashboard.py` is per-ticket, single log file, launched ad hoc (tmux split per run —
router-hardening R13). Fleet-wide state exists only as poll-time snapshots
(`fleet_render_dashboard` / `fleet_write_report`). **Fix:** a `--fleet` mode for
`dashboard.py`: glob `logs/*-pipeline.log`, one row per active pipeline — phase, step,
bracket age, **agent activity age (O1)**, verify/iterate counters, last gate event —
refreshed live. This is the "full visibility" deliverable; it is mostly a consumer of O1.

### O5 — The "why" stream goes quiet exactly when it matters

Heartbeat categories (decision/fallback/api/gate/retry) are rich in the router but sparse
inside agents: the spawn env-prefix does export `HB_LOG_FILE` and source `heartbeat.sh`
(`spawn-helper.sh:264`), yet phase skills mostly write bare pipeline-log step lines (e.g.
verify's `pre-flight` echoes) and rarely call `hb_*` during work. **Fix (instruction
hardening):** each phase skill's major steps emit one `hb_heartbeat`/`hb_decision` line —
notably the long-running ones: implement code-writing stages, verify navigation. Cheap,
markdown-only, high dashboard value. (Honest caveat: LLM-instruction compliance, not
enforceable — same class as prescan fan-out. The activity hook (O1) is the deterministic
backstop; this just adds semantic color.)

### O6 — No mid-flight cost signal

`token-tracker.sh` fires on SubagentStop — a runaway agent burning 200k tokens is
invisible until it stops. True mid-flight token telemetry needs harness support, but O1's
activity log gives a free proxy: **tool-call count per bracket**. Fleet can WARN on
`activity_lines > N` (e.g. 300) for a single bracket — catches runaway loops (the
prescan run's 215-call session would have tripped this). Add as a fleet engine input.

### O7 — Tool-error capture is Bash-centric

`tool-error-capture.sh` (PostToolUseFailure) declares itself Bash-focused. The failures
that actually kill verify runs are Playwright/MCP tool errors. **Fix:** verify the hook
matcher covers all tools (not just Bash); extend its error classifier with
playwright/MCP-shaped error types so fleet's flow-failure engine sees browser deaths.

### O8 — Fleet silently sees nothing if the log dir is wrong

Engines default to `${FLEET_PIPELINE_LOG_DIR:-./logs}` — CWD-dependent. A cron-mode fleet
controller launched from the wrong directory finds no logs and reports **all-quiet** —
indistinguishable from genuinely idle. **Fix:** fleet startup asserts the log dir exists
AND distinguishes "dir missing/empty" (config error → WARN loudly) from "no active
pipelines" (normal). One guard block.

---

## Incremental rollout

| Increment | Items | Deliverables |
|---|---|---|
| **1 — Agent liveness MVP** (do first) | O1 | `hooks/agent-activity.sh` (PostToolUse) + hook registration; stall-engine activity input + thresholds; watchdog `max_iter` + orphan sweep; fixture tests (fresh activity vs stale vs absent) |
| **2 — Truthful zombie detection** | O2 | position-scoped terminal matching; shared retry-loop log fixtures with router-hardening R4 |
| **3 — Fleet live dashboard** | O4 (+consumes O1) | `dashboard.py --fleet` mode; row per pipeline; activity-age column; replaces ad-hoc per-ticket panes (fold in router-hardening R13) |
| **4 — Signal enrichment** | O5, O6, O7, O8 | hb instruction hardening in phase skills; tool-call-count WARN engine; tool-error coverage extension; log-dir guard |
| **5 — Deferred** | O3 full streaming | only if Increment 1–3 leave a real debugging gap |

Definition of done per increment: shfmt/shellcheck clean, fixture tests in `lib/tests/`,
`FLEET_DRY_RUN` respected for any new intervention path, version bump per branch.

**Threshold defaults to confirm before Increment 1:** activity WARN 240s / stale 900s
while bracket open; runaway tool-call WARN at 300 calls/bracket. All overridable via
`FLEET_*` env vars like existing knobs.

---

## Interaction map

- **O1 activity hook** reuses token-tracker's spawn-meta resolution — no new state files.
- **O2 + R4** (router plan) are the same disease (whole-file matching vs loop brackets);
  fix together with shared fixtures.
- **O4 + R13**: the fleet dashboard subsumes the per-ticket tmux-pane idempotency fix.
- **O1 thresholds vs integrity-plan gates**: activity staleness is fleet-side observation
  (kill/restart authority); the integrity plan's gates are router-side validation. No
  overlap — different planes, keep it that way.
