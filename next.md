# Next — pipeline work queue

Ordered backlog for the ticket-auto / fleet-controller pipeline. Ordering rationale is at the
bottom. Update the checkboxes as work lands; move completed steps to the archive section.

> Public repo — no ticket IDs, no customer data in this file.

Last reviewed: 2026-09-06 (Step 5 landed; Step 6 held for real-run validation)

---

## Step 0 — Extract standalone bug fixes

Buried inside the queued plans but dependent on none of them. Two are causing silent harm today.
Estimated: one sitting for all three.

- [x] **Narrow the `META|outcome` detector skip** — `fleet-controller/lib/fleet-detect.sh:1360`
      and `detect_abandoned:571`. Done 2026-09-05: added `_pipeline_genuinely_terminal`/
      `_pipeline_is_held` helpers; the sweep now runs a held-aware `detect_abandoned` (WARN-only,
      never escalates to kill/restart — no process exists to kill, and restarting would just
      duplicate the wait) for held tickets, while the other 10 process-liveness detectors
      (stalls/zombies/loops/...) stay skipped for them since they'd false-positive on a cleanly
      exited router within minutes. Also fixed the same skip shape in `detect_blocked_by`'s own
      sweep (line ~1199, not in the original two sites but identical bug). 61/61 fleet-detect
      tests pass.
      Source plan: human-hold.

- [x] **`held: ` prefix match in `fleet_ticket_terminal_state`** —
      `fleet-controller/lib/fleet-reconcile.sh:87-145`, plus the documented pairwise-sync partner
      `_log_reached_terminal:1971`. Done 2026-09-05: both now match the `held: ` prefix instead of
      the exact string `held: gate`, so a future hold kind (e.g. human-hold's external-wait) won't
      fall through to `done`. `phase_dispatch.py:281`'s `in ('done','gate-held','gate-stopped')`
      needed no change — it consumes the same fixed vocabulary, not its own classification.
      34/34 fleet-reconcile tests, 5/5 supervisor terminal-state tests pass.
      Source plan: human-hold.

- [x] **Agent-type enforcement decision + fix.** Decided: wire it up (not delete).
      Root cause was deeper than "not wired" — `agentTypes` in `plugin.json` was never a real
      Claude Code plugin schema field (confirmed against docs.claude.com); the real mechanism is
      `agents/*.md` files with YAML frontmatter, referenced as `subagent_type:
      "ticket-auto-pipeline:<name>-agent"`. Done 2026-09-05: converted the 8 JSON entries to
      `ticket-auto-pipeline/agents/*.md`, deleted the dead `agentTypes` block, added `spawn.agent`
      to the 7 dispatch-table.json steps that have a dedicated type (2 loop steps —
      `/ticket-pr-iterate`, `/ticket-retro` — stay `general-purpose`, no type ever existed for
      them), extended `gen-dispatch-table.py` to render an "Agent types" table into SKILL.md,
      threaded `AGENT_TYPE` through `spawn_agent_pre` (manual router path) and `agent`/`--agent`
      through `phase_dispatch.build_phase_spawn` → `supervisor.spawn_worker`/`_build_worker_cmd`
      (fleetd path). `CLAUDE.md`/`plugin-overview.md` updated to describe the real mechanism.
      101/101 spawn-helper, 116/116 phase-dispatch, 26/26 relevant supervisor tests pass.
      Source plans: agent-observer (`--agent`), plus the Phase-1 investigation (router path).

- [x] **Latent: `META|worker-exit` is appended after `META|outcome` at reap**
      (`fleetd/supervisor.py:2916`). Done 2026-09-05: added `_last_effective_line`
      (fleet-detect.sh) and the matching Python skip-trailing-worker-exit loop in
      `_log_reached_terminal`; both classifiers (and the new helpers above) now find the real
      last outcome/dead-letter line instead of misreading a completed pipeline as `incomplete`
      once fleetd has reaped it — which would have silently defeated the stale-queue-entry skip
      at `supervisor.py:3024` and let fleetd re-spawn an already-finished ticket.

---

## Step 1 — Commercial evidence MVP (runs.jsonl)

**Plan:** `~/.claude/plans/based-on-all-we-eager-valley.md`
**Audit:** "Provable Fleet" artifact, 2026-09-05 (private) — 20-section audit of what the
platform can prove from its own data.
**Size:** three PR-sized branches, no schema change, no new services.
**Openspec changes** (proposed 2026-09-05, all 4/4 artifacts complete, `openspec validate --strict`
clean). Sequence — apply strictly in this order, one `/opsx:apply` + PR per change:
1. `commercial-evidence-run-identity` (Branch A)
2. `commercial-evidence-runs-jsonl` (Branch B) — depends on A's `run-identity.sh`/`META|run-id`
3. `commercial-evidence-fleet-cost-events` (Branch C) — depends on B's `runs.jsonl`/`merge-poll.sh`

Makes the three facts a buyer needs recordable per run: whether the PR actually **merged** and
when (today `gh pr merge --auto` fires and nothing learns the result), **which run / version**
produced an outcome (no run-id, no plugin version, re-runs append to one log), and **USD cost**
(fleetd writes the harness `total_cost_usd` to `{tid}-gen{N}.json` and never reads it). Plus
human approval actor/time from Linear `IssueHistory`.

Design invariant: `META|outcome` stays the pipeline log's last line (both terminal classifiers
read only the last line), so **every post-outcome fact goes to `logs/runs.jsonl`** — an
append-only event log with four kinds: `run`, `merge`, `cost`, `human`.

- [x] **A — `feat(ticket-auto-pipeline)`: run identity, version stamp, ticket-meta, per-run
      postmortem.** Openspec: `commercial-evidence-run-identity`. New `lib/run-identity.sh` (single writer for `META|run-id` + `META|version`,
      called by both `ticket-preamble.sh` and the router's Step 0.6 with `--new`; log-based
      "open run" guard, not env); `META|ticket-meta` from `get_issue` (+`estimate startedAt
      completedAt`); `pipeline-postmortem.sh` run_id from the last `META|run-id` (today it is
      constant per ticket, so post-mortem fires once ever); `preamble.py` passes
      `TICKET_RUN_TRIGGER=fleetd`. Merged 2026-09-05 (PR #299, ticket-auto-pipeline 0.40.0).
- [x] **B — `feat(ticket-auto-pipeline)`: runs.jsonl record, merge poll, Linear history.**
      Openspec: `commercial-evidence-runs-jsonl`. `META|pr-created` in ticket-verify (capture the `gh pr create` URL — it is not captured
      today), `META|cache-tokens` as a *separate* line (four consumers sum every slash field of
      `META|tokens`), guarded `META|complexity` in gate-check; new `lib/run-summary.sh` (window =
      last `META|run-id` → EOF, counters via detect-resume's exact grep patterns, never sources
      detect-resume.sh); new `lib/merge-poll.sh` (the one merge-truth implementation:
      `gh pr view --json state,mergedAt,mergeCommit`, 10-min re-poll floor, 14-day stale);
      `get_issue_history` in linear-api.sh; `pipeline-finalize.sh` appends `run` + one-shot
      merge sweep + `human` event after the outcome line, all fail-soft. Merged 2026-09-05
      (PR #300, ticket-auto-pipeline 0.41.0).
- [x] **C — `feat(fleet-controller)`: worker cost events, merge-poll cadence, generation/version
      env.** Openspec: `commercial-evidence-fleet-cost-events`. `worker_cost_usd()` beside `worker_return_text`; read in reap and fleet-kill paths
      before the generation-file sweep; `cost_usd` on the exit record + `cost` event;
      `FLEET_GENERATION`/`FLEET_VERSION` in worker env (neither exists today); merge-poll sweep
      every `FLEET_MERGE_POLL_CYCLES` (10) as a bash subprocess. Implemented 2026-09-05, `make
      lint`/`make fmt-check`/`make test` all green, fleet-controller 0.22.1 — PR #301 open,
      pending merge.

**Step 1 complete** (2026-09-05): all three branches implemented and tested; A and B merged to
main, C awaiting PR #301 merge. Dexter follow-up (below) can start as soon as that lands.

Follow-up in the **dexter repo** (separate plan, not tracked here): The Bench executive view
reading `runs.jsonl` — five tiles (autonomous merge rate, cycle time P50/P90, cost per merged
ticket, first-pass rate, post-merge defects 30 d) with n / window / Wilson CI / maturity badge;
fix the `success_rate` denominator (excludes held tickets today); cohort → ticket drill-down.
Also a recovery-success tile — a query over `run` + `cost` events, no new instrumentation.

Evidence Phase 2 (after Step 4, see below): `exit_class` incl. timeout + persisted detection
events; post-merge defect/revert scan on the merge SHA with 7/30/90-day delayed windows; queue
wait (rides on the human-hold migration); merge-conflict rate under parallel dispatch.

---

## Step 2 — Skill-version attribution (measurement Phase 1, **reduced**)

**Plan:** `~/.claude/plans/no-edits-write-up-composed-fountain.md`
**Memory:** `project_skill-version-attribution-phase1`
**Openspec change:** `skill-prompt-fingerprint` (proposed 2026-09-05, 4/4 artifacts,
`openspec validate --strict` clean). One PR. Note the plan is stale on two points the change
corrects: Step 0 made `agents/*.md` **live** prompt material (they must be fingerprinted, the
plan says the opposite), and the emission is one field on `META|version`, so
`spawn-helper.sh` is untouched — the Step 2 / Step 4 conflict listed below no longer applies.

Step 1A already ships `META|run-id` and `META|version` (plan items 3–4) and Step 1B ships
`runs.jsonl` — so this plan shrinks to the prompt-material fingerprint and stops needing a
bash grouper:

**Status: implemented 2026-09-05 on `feat/skill-prompt-fingerprint` (ticket-auto-pipeline 0.42.0).**

- [x] 1. `prompt_manifests` block in `skills/ticket-flow/dispatch-table.json` — 12 skills.
      Membership verified per skill, not grepped: `ticket-appraise-exec`'s "Run
      `/ticket-implement`" and `ticket-appraise`'s "`/ticket-appraise-exec`" are both prose
      inside user-facing handoff blocks and are excluded.
- [x] 2. `hooks/skill-fingerprint.sh` (SessionStart, third, after lib-sync) +
      `lib/skill-version.sh` + 24 tests. ~0.2s per run.
- [x] 3. `skills` `{sha256, manifest_n}` + `skills_unresolved` **on the existing
      `META|version` object** — not a second line, `spawn-helper.sh` untouched.
      `run-summary.sh` needed no change; that passthrough is now asserted by test.
- [x] 4. ~~`META|run-id` at Step 0.6 + postmortem suppression fix~~ — delivered by Step 1A
      (`commercial-evidence-run-identity`), nothing to do here.
- [x] 5. Grouping is a `jq` group-by over `runs.jsonl` — a documented query in
      `pipeline-log-format.md`, not code. No bash grouper written; a cohort test in
      `test-run-summary.sh` pins the property.
- [x] 6. Docs (`pipeline-log-format.md`, `CLAUDE.md`), version bump 0.41.0 → 0.42.0, CHANGELOG

**Two corrections to the change's own design, found during implementation:**

1. The spec said the work set is `steps[].spawn.skill`, which yields **9** skills. The design's
   own count ("12 distinct skills") only holds if `post_dispatch`, `sub_steps` and `sequence`
   entries count too — all four shapes carry `instructions` that `spawn_agent_pre` concatenates
   into `AGENT_PROMPT`. Implemented as the broader union: 12 distinct across 15 blocks.
2. **Host-side skill copies shadow the plugin's** on this machine:
   `~/.claude/skills/ticket-implement/SKILL.md` is 30083 bytes vs the plugin's 30794 (same for
   `ticket-verify`, `app-knowledge`). `spawn-helper.sh:487` emits `Run /ticket-implement`
   unqualified, so resolution may pick the stale host copy — the exact failure D2 guards against,
   at a root the design did not anticipate. Manifests follow the design (`plugin:` for
   `SKILL.md`), which is correct on a clean install. **The fix is to run
   `ticket-auto-pipeline/install.sh`**, which archives these leftovers; it has never been run
   here. Worth doing before trusting a fingerprint on this box.

- [ ] 8.6 End-to-end on one real ticket — not run: needs the tickets host. Verify with
      `grep '|META|version|' logs/<TID>-pipeline.log | jq -r '.skills | keys | length'` and
      confirm the same object appears in that run's `runs.jsonl` `run` event.

Still observational: no randomisation, task mix drifts, models change underneath. Report deltas
per version with n and CI; say "associated with", never "caused". Without Step 1B's merge truth
there is no verified outcome to group by — which is why this now sits second.

Later measurement phases (local `verifier_results`/`phase_attribution` tables, traces + Langfuse
canary, score shipping) remain **optional** and unscheduled.

---

## Step 3 — Human-hold / external-wait (remainder)

**Plan:** `~/.claude/plans/go-over-the-current-soft-dahl.md`
**Memory:** `project_human-hold-external-wait`
**Openspec changes** (proposed 2026-09-06, both 4/4 artifacts, `openspec validate --strict`
clean). Sequence — apply strictly in this order, one `/opsx:apply` + PR per change:
1. **`human-hold-store-foundation` — implemented 2026-09-06 on
   `feat/human-hold-store-foundation` (fleet-controller 0.23.0), 41/41 tasks, `make
   lint`/`fmt-check`/`check-generated`/`test` all green.** Schema v2 (`gate_held` → `held` +
   `hold_kind`/`hold_id`/`hold_generation`/`hold_attempts`/`notify_state`/`notified_at`/
   `escalated_at`/`released_at`), additive forward migration in `store.py` (`_MIGRATIONS` table,
   v1→v2 declared non-additive — verified no production store exists), the `set_hold`/
   `release_hold` CAS pair (`mint_hold_id`), the `held=1` spawn guard in
   `_consume_queue_locked`, and `Supervisor._hold_reconcile_pass` wired into the **live**
   `run_observe` loop on `gate_hold.is_due(...)`/`FLEET_GATE_RECONCILE_INTERVAL` for the existing
   `gate` kind. `gate_hold.py` gained a fourth outcome, `UNAVAILABLE` (probe timeout,
   undocumented exit code, or an unregistered kind), distinct from `hold` — `human` is reserved by
   the CHECK constraint and resolves to `UNAVAILABLE`, never released, never gate-stopped, so this
   change and the dependent one below are safe in either review order. Ships standalone value:
   gate holds get a live reconciler for the first time. The store/CAS/wiring half of Step 3 is
   done — `human-hold-protocol` below is now unblocked.
2. **`human-hold-protocol` — implemented 2026-09-06 on `feat/human-hold-store-foundation`
   (ticket-auto-pipeline 0.43.0, fleet-controller 0.24.0), 43/43 tasks (two are inherently
   live/operational and are follow-ups below, not unchecked work), `make lint`/`fmt-check`/
   `check-generated`/`test` all green.** `=== HUMAN_HOLD ===` marker + `human-hold-parse.sh`
   (redaction, four refused fields, `absent` writes nothing while `invalid` still logs), the
   preamble section, `held: human` in `pipeline-finalize.sh`, `detect_human_hold` and
   `fleet_notify_hold` (both pipeline-log-driven — live today, no store dependency), the `human`
   release predicate registered into `gate_hold.py`'s dispatch, `post_human_hold_comment` +
   `human_hold_attempt_exceeds_max` (`HUMAN_HOLD_EXHAUSTED`), `human_hold_requested`/
   `human_hold_parse_status` on `runs.jsonl`'s `run` event. `needs-info` reused unchanged.

Makes "blocked on a human" a first-class recoverable fleet state — a hold is a row, not a stalled
process. Reviewed to 10/10 on 2026-09-03. Step 0 already removed its two urgent bug fixes.

**Four corrections to the plan, found while writing the changes (three while proposing, one while
implementing):**

1. **Detector severity caps at 1, not 2.** The plan specifies severity 1 at 2h → **2** at 24h,
   reasoning "severity 3 triggers intervention, and a ticket must never be killed for waiting on
   a person." That is off by one here: severity **2** already *is* an intervention — *KILL: touch
   stop files, finalize pipeline log*. On a held ticket that kills nothing (the router exited
   cleanly) and finalizes the log **over** the `held:` outcome, which is the hold's own audit
   record and the line both terminal classifiers key on — the escalation meant to raise the alarm
   would make the waiting ticket look finished. Step 0 reached the same conclusion independently
   for `detect_abandoned`. So the cap is 1, and the 24h escalation moves to the **notifier**
   (gated on `escalated_at`), which is the mechanism that actually reaches a person anyway.
2. **`run-summary.sh` needs no fix.** `lib/run-summary.sh:110` already greps `held:` as a
   substring, so a `held: <kind>` outcome is bridged correctly today. Downgraded from a fix to a
   pinning test, which ships with change 2.
3. **The v1→v2 rename is declared non-additive**, so it refuses rather than silently migrating —
   safe only because no production store exists. The migration machinery added in change 1
   governs v2 onward, and v2 is the last version permitted to take that shortcut. Once it exists,
   the evidence queue-wait column (carry the enqueue timestamp into `workers`) is a one-liner.
4. **`fleet_notify_hold`'s idempotency keys off a per-ticket sidecar file, not the store's
   `notify_state` column** design.md D7 names as authoritative. A bash library cannot write the
   fleet state store — fleetd is its sole writer — and the row carries no question/blocks text
   regardless, so the notifier needs the pipeline log either way. It keeps `{tid}-hold-notify.json`
   instead, exactly the pattern `fleet_slack_post` already used for its own thread bookkeeping.
   Every observable guarantee in the spec (one send per hold, restart-safe, failure retried,
   escalate once) holds under this mechanism; only the storage location moved.

Regression fixture: `fleet-controller/lib/tests/fixtures/human-hold-160h-pipeline.log` — synthetic
and scrubbed (no real ticket data exists to replay; the actual 160h incident used a different,
pre-this-mechanism ask-form), shaped like the incident this change targets.

**Follow-ups, deliberately deferred rather than guessed at:**

- **No live caller creates a `hold_kind='human'` row yet.** Nothing calls `store.set_hold` for a
  fresh human-hold request — the same pre-existing, explicitly accepted gap
  `human-hold-store-foundation` left for the `gate` kind ("`gate_hold.py` has no live caller").
  `post_human_hold_comment`/`human_hold_attempt_exceeds_max`/the `human` predicate all ship
  tested and ready; wiring `META|human-hold` → `store.set_hold` → Linear comment → first notify
  is real, scoped follow-up work, not done here speculatively.
- **Task 8.2 (measure real emission rate) needs a week of real runs** — cannot be done from this
  session. `human_hold_requested`/`human_hold_parse_status` now exist on `runs.jsonl`'s `run`
  event specifically so this is a `jq` query once runs exist, per design.md's Risk: if the rate
  stays near zero, the honest conclusion is the preamble channel doesn't work and the request must
  come from somewhere deterministic — do not build further consumers before that measurement.
- **Task 9.5 (end-to-end against real Linear)** needs a live fleetd + a scratch ticket on the
  tickets host — same "live verification pending" status prior changes in this queue have shipped
  under (e.g. `fleet-reconcile-gate-retry`).
- **Migrating the four legacy ask-forms** (`needs-info` label alone, `[needs-human]` in
  `notes.md`, `META|human-decision`, prose in an agent return) onto this mechanism — explicitly
  out of scope per design.md's Open Questions; revisit once the emission-rate measurement above
  lands, since migrating onto an unused mechanism is wasted work.

---

## Step 4 — RLVR phase-result contract

**Openspec changes:** `rlvr-phase-result-contract`, then `rlvr-verdict-recompute`
(note: `openspec/` is gitignored — these exist only on local disk)
**Memory:** `project_rlvr-return-contract`

Agent returns a machine-readable claim; bash recomputes; the delta is the reward signal. On the
critical path to workflow-driven execution and to finishing fleetd phase supervision.

1. **`rlvr-phase-result-contract` — merged earlier (PR #279), archived.** The
   `=== PHASE_RESULT ===` transport, `lib/phase-result-parse.sh`, and the
   `META|phase-result` channel for the three loop-bearing phases (IMPLEMENT,
   VERIFY, PR-REVIEW). Observe-only; nothing routes on it. **Gap carried
   forward, not fixed here:** `runs.jsonl`'s `run` record still has no
   `phase_result_emitted` field, so emission rate has not actually been
   measured yet — the consumer-gating condition this change specified is
   still open.
2. **`rlvr-verdict-recompute` — implemented 2026-09-06 (ticket-auto-pipeline
   0.44.0), 15/17 tasks (2 telemetry-review tasks are gated on real-run data,
   not done here), `make lint`/`fmt-check`/`test` all green.** New
   `lib/verdict-recompute.sh` (VERIFY only): reuses `phase-result-parse.sh`'s
   parser (sourced, log-free) for the claim and `return-completeness-check.sh`'s
   section-scoped checkbox counter (sourced) for the verified side — counts
   `- [x]`/`- [ ]` in `verify-session.md`'s `## Step trace`, gated on the file
   postdating the phase's own bracket-open line. Emits `META|claim-delta` with
   `direction` (`aligned`/`optimistic`/`pessimistic`/`unknown`). Wired into
   `skills/ticket-auto/SKILL.md` immediately after `phase-result-parse.sh`,
   same observe-only guarantees. 17/17 new tests.

If the follow-up's `direction` comes back `aligned` on essentially every ticket, the routing
increments get **dropped** — that is an intended outcome, not a failure.

---

## Step 5 — Agent Observer

**Plan:** `~/.claude/plans/delightful-spinning-snowglobe.md`
**Memory:** `project_agent-observer-plan`
**Openspec change:** `agent-observer` (implemented 2026-09-06, 43/43 tasks; `openspec/` is
gitignored, exists only on local disk).

**Implemented 2026-09-06 on `feat/agent-observer` (fleet-controller 0.25.0), PR #309 open,
pending merge.** `fleetd/observer.py`, a fleet-wide sidecar modelled on `otel.py`'s own
spawn/backoff/reap/stop supervision, tails phase workers' `--output-format stream-json
--verbose` transcripts (opt-in via `FLEET_OBSERVER_ENABLE`) and computes 8 deterministic
findings — `CLAIM_CONTRADICTION`, `REPEATED_FAILURE`, `SCOPE_VIOLATION`, `UNEXPECTED_TOOL`,
`RUNAWAY_COST`, `LONG_TOOL_CALL`, `DEGRADED_SESSION`, `PERMISSION_DENIED` — against a
per-phase contract (`build_phase_contract`) sourced from the dispatch table and each agent's
own `agents/*.md` frontmatter. Findings surface via a new `findings` table (schema v3,
PROJECTION class), `/health` counts, a `fleet-dashboard.sh` FINDINGS column, and
`detect_observer_findings` (16th detection engine, hard-capped at WARN). Fully inert by
default — confirmed via two full `make test` runs with `FLEET_OBSERVER_ENABLE` unset.

Both urgent side-findings from the plan were resolved as part of this change rather than
filed separately: `--agent` threading turned out to already exist (the plan's premise was
stale against an installed-plugin-cache lag, corrected in the change's own design doc), and
the phase-slug sweep leak (`fleetd/supervisor.py`'s stale-generation-file sweep matching only
`{tid}-gen{N}`, never `{tid}-{phase}-gen{N}.*`) was fixed directly in Inc 1
(`_sweep_stale_generation_files` now takes a `phase` param).

Probe fixtures used: `fleet-controller/fleetd/tests/fixtures/stream-json-*.ndjson`.

---

## Step 6 — Agent Mesh MVP (PC agent ↔ server agent)

**Held (2026-09-06): do not start until a few real ticket runs have exercised the recent
batch of changes** (Steps 3/4/5 — human-hold, RLVR verdict recompute, agent-observer — plus
the commercial-evidence branches). All of it is implemented and unit-tested but largely
unverified against live fleetd/Linear traffic on the tickets host. Agent Mesh's task-delegation
phase (Phase 3) adds another consumer of the same reap path several of those changes just
touched (`fleetd/supervisor.py`) — better to know the current batch is solid first than debug
two layers of new behavior at once.

**Plan:** `~/.claude/plans/i-want-you-to-zesty-quilt.md`

Investigated 2026-09-06: how much of an Agent Mesh foundation (identity, capabilities,
endpoint, status, permissions, trust) already exists, and the smallest step to get two
Claude agents on different machines discovering, delegating, and returning structured
results. Verdict: ~60% of the foundation exists; no new major infrastructure component
needed — fleetd's existing loopback HTTP server, reached over an SSH tunnel with a bearer
token, is the endpoint.

**Not started.** Four-phase plan in the file above:
- Phase 0 — prove communication (zero code: systemd fleetd + SSH tunnel + curl).
- Phase 1 — agent identity + registration (`agent_id`, bearer token, `GET /agent` card,
  threading HTTP server, `FLEET_AGENT_ID` stamped alongside `FLEET_GENERATION`).
- Phase 2 — capabilities + discovery (derive from `fleet-env-check.sh` + installed
  `agents/*.md`, cached; client-side `FLEET_MESH_PEERS`, no server-side registry).
- Phase 3 — task delegation (`POST /tasks` with `run_prompt`/`run_ticket`; the reaper needs
  a `reason`-keyed branch — modelled on the existing otel-exporter branch — so a mesh task
  is never misclassified as an orphaned ticket and re-enqueued).
- Phase 4 — evidence (assemble existing `PHASE_RESULT`/exit-record/`runs.jsonl` objects;
  no new trust primitive).

Cut from MVP: `run_phase` (phase-level dispatch isn't rolled out yet), a server-side
`/peers` registry, mTLS/signing/RBAC, dexter Workflows integration.

---

## Ordering rationale

1. **Active harm first.** Step 0's first two items mean held tickets are invisible to every
   detector and can be marked done while still waiting. Cheapest fixes in the backlog, largest
   real-world cost today.
2. **Sales evidence accrues in calendar time.** Step 1 is the proof the platform can be sold on:
   every week without `runs.jsonl` is a week of merges, costs and approvals that can never be
   reconstructed (merge truth is not in any log; `--auto` merges leave no local trace). It also
   subsumes the run-id/version half of the old attribution plan, so doing it first removes work
   from Step 2 rather than adding to it. The 30-day defect tile and any percentage with n ≥ 30
   need elapsed time nobody can engineer around — start recording now.
3. **Attribution needs a verified outcome to group by.** Step 2's "did this skill edit help?"
   is unanswerable against self-reported `completed`; with Step 1B's confirmed merges it becomes
   an observational cohort query. Hence 2 after 1, and much smaller than before.
4. **Schema work in one place.** Step 3 owns the store migration; Step 1 avoided touching the
   schema so it never blocks on it, and the evidence queue-wait column rides on Step 3's
   migration for free.
5. **Dependencies last.** Step 5 genuinely needs Step 4. Step 4 unblocks programmatic
   orchestration generally, and `runs.jsonl` gives it an emission-rate measurement for free.
6. **Largest and most diagnostic last.** Once Step 0 extracts its urgent findings, the observer's
   remaining value is investigative rather than corrective.

### Parallel track

The Dexter executive view (Step 1 follow-up) lives in another repo and only needs `runs.jsonl`
lines to exist — it can start as soon as Step 1B merges and run alongside Steps 2–3 without a
file conflict.

### Known scheduling conflicts

- ~~Step 2 and Step 4 both edit `ticket-auto-pipeline/lib/spawn-helper.sh`~~ — resolved by the
  `skill-prompt-fingerprint` design: emission is a field on the existing `META|version` line
  written by `run-identity.sh`, not a per-phase line at `phase_bracket_open`, so Step 2 does not
  touch `spawn-helper.sh` at all.
- Step 1A/B and Step 2 both edit `lib/ticket-preamble.sh` and `lib/run-identity.sh` (Step 2
  extends the `META|version` object). Sequential, in that order.
- Step 1C and Step 3 both edit `fleetd/supervisor.py`'s reap path and worker env. Sequential.

### Repo conventions that apply to every step

- Bump the plugin version on each branch (marketplace update detection).
- `make lint && make fmt-check && make test` before opening any PR.
- `shfmt -i 2` — run `make fmt`, not bare `shfmt`.
- Never pipe `make test` into another command; redirect to a file (the spawn-helper test leaks
  orphans that hang the pipe).
- `make check-generated` must stay green — none of the steps above touches
  `dispatch-table.json` except Step 2 item 1, which must regenerate `ticket-auto/SKILL.md`.

---

## Archive

_Move completed steps here with the date and PR number._
