# Changelog

Version numbers track **`ticket-auto-pipeline`**, the original plugin in this
marketplace. Where a release also moved `ticket-planner`, `fleet-controller`, or
`knowledge-curator`, those versions are called out in the entry.

> **Backfill note (2026-07-25):** entries for 0.14.0 through 0.21.1 were
> reconstructed from git history — the changelog had lapsed after 0.13.0 while
> `plugin.json` advanced to 0.21.1. They are accurate as to what shipped, but are
> summaries written after the fact rather than release-time notes.
>
> Two numbering artifacts surfaced during the reconstruction, recorded rather
> than silently corrected:
> - **0.13.0 was never a `plugin.json` version.** The commit that added the
>   0.12.13 and 0.13.0 entries below bumped `plugin.json` straight from 0.12.12
>   to 0.14.0. Those two entries describe work that shipped as 0.14.0.
> - **0.19.0 never existed.** `plugin.json` went 0.18.0 → 0.20.0. The Phase 2
>   commit message claims `0.19.0→0.20.0`, but no 0.19.0 was ever committed.

## ticket-auto-pipeline 0.29.8 (2026-09-01)

Closes #189 — `ticket-pr-review` Step 6b merged any PR with a ✅ verdict
directly via the GitHub REST API, with no awareness of the pipeline's own
`autonomy` setting or an epic's Branch Directive `Merge Policy`. The router's
own auto-merge logic (in `ticket-auto/SKILL.md`) correctly gates merge on
`{ autonomy=auto || autonomy=semi-auto } && complexity=simple` and never fires
in `manual` mode — but that gate runs *after* `STEP_4_6`, by which point
`ticket-pr-review` had already merged the PR itself. Confirmed live on CRE-22
(`autonomy=manual`, epic `Merge Policy: manual`): two child PRs were merged
with zero human sign-off the moment review passed.

- Fix: `resolve_branch_context` (`lib/branch-resolve.sh`) now also resolves
  and emits `MERGE_POLICY` from the parent epic's Branch Directive, mirroring
  the existing `UAT_POLICY` field — but, unlike `UAT_POLICY`, absence stays
  empty rather than materialising a default: "no epic opinion" and "epic
  requires manual merge" must stay distinguishable. New standalone
  `resolve_merge_policy <TICKET_ID>` helper mirrors `resolve_uat_policy` for
  invocations outside a pipeline run.
- `spawn_write_env` (`lib/spawn-helper.sh`) now accepts and exports `AUTONOMY`
  and `MERGE_POLICY` into the per-ticket agent env file — neither was plumbed
  through at all before this change, so `ticket-pr-review` had no way to see
  either signal even if it had checked.
- `ticket-auto/SKILL.md` Step 0.5 resolves and writes both fields (including
  on crash-resume rehydration), and `detect-resume.sh` parses `merge-policy`
  from the `META|branch-context` log line so a resumed pipeline doesn't lose
  the epic's policy.
- `ticket-pr-review/SKILL.md` Step 6b now checks `AUTONOMY`/`MERGE_POLICY`
  before spending any CI/conflict-check API calls: a non-`auto`/`semi-auto`
  autonomy or a declared epic `Merge Policy` (both existing enum values
  require a human — there is no `auto` value) skips the direct merge and
  reports the PR as ready for a human to merge instead. A standalone
  `/ticket-pr-review` invocation outside a pipeline run has neither env var
  set and falls back to resolving `MERGE_POLICY` directly (so it still
  honours an epic directive); `AUTONOMY` has no standalone meaning and stays
  non-blocking for that case, preserving existing interactive behaviour.
- New/updated tests: `test-branch-resolve.sh` (+7), `test-detect-resume.sh`
  (+2), `test-spawn-helper.sh` (+1 new, plus `AUTONOMY`/`MERGE_POLICY`
  assertions added to the existing all-fields test) covering resolution,
  defaulting, and env-file plumbing for both fields.

## ticket-planner 0.8.4 (2026-09-01)

Closes #175 — the fourth and final Crosscheck check family,
`planner-crosscheck-contracts.sh`. Every planner phase is scoped to one
initiative, so nothing ever checked whether a structure one initiative's
specs borrow from a sibling initiative's specs actually has the shape the
borrowing epic assumes. The August 31 audit found two live instances in
`INIT-1788116082-4791` (Evidence-Based Confidence): a dependent epic
inherited the wrong one of two contradictory upstream shapes for
`ClassificationResult`/`_llm_classify()` confidence reporting (per-field vs.
top-level), and a dependent epic retired `ValidationOutcome` mentioning only
its own call site while three upstream VS-6 tickets still gated on it.

- New: `planner_crosscheck_contract_undefined` — a spec paragraph declaring
  a structure "gains/adds fields for ..." in prose only, with no other
  backtick-quoted identifier anywhere in the paragraph, leaves the shape
  undefined for whoever reads it next. Code: `CONTRACT_UNDEFINED`
  (warn-level — an ambiguous upstream shape is a prompt for human judgment,
  not by itself proof of a defect). Needs no cross-initiative view.
- New: `planner_crosscheck_contract_mismatch` — for every backtick-quoted
  structure this initiative's specs share with a sibling initiative's specs
  under `${REPOS_ROOT}/.ticket-auto/initiatives/*/artifacts/specs`, compares
  the other backtick-quoted terms co-mentioned with it in each side's
  paragraph. A disjoint term set, or one side describing it as per-field and
  the other as top-level/document-level, is reported quoting both
  paragraphs. Code: `CONTRACT_MISMATCH` (blocking).
- New: `planner_crosscheck_contract_consumers_unnotified` — a paragraph that
  retires/removes/deprecates/replaces a structure without naming (by ticket
  slug) every other spec — in this initiative or a sibling — that still
  mentions that structure. Code: `CONTRACT_CONSUMERS_UNNOTIFIED` (blocking).
- True cross-language structural diffing needs a parser per language and a
  resolved symbol table — out of reach for a planner that only reads prose
  specs. This is the same bounded, backtick-identifier heuristic tradeoff
  `planner-crosscheck-bypass.sh` and `planner-crosscheck-propagation.sh`
  already make, documented in the file header. Reuses
  `planner-crosscheck-propagation.sh`'s known-slug helpers and
  `planner-crosscheck-bypass.sh`'s paragraph splitter rather than
  duplicating them.
- Wired into `planner-crosscheck.sh`'s orchestrator alongside the citation,
  propagation, and bypass families; `CONTRACT_UNDEFINED` added to
  `PLANNER_CROSSCHECK_WARN_CODES`.
- New test suite `test-planner-crosscheck-contracts.sh` (19 tests) covering
  all three checks plus the public entry point and the no-cross-initiative-
  references fast no-op (issue AC3).

## ticket-planner 0.8.3 / ticket-auto-pipeline 0.29.7 (2026-09-01)

Closes #190 — `_retry_classify` (and `_planner_retry_classify`, the same
function duplicated in `planner-linear-api.sh`) ran its transient-keyword
scan (`rate.limit|timeout|temporar`) against the raw response body on every
call, including well-formed GraphQL successes. A Linear issue whose title or
description legitimately mentions "timeout" (e.g. a Feign `connectTimeout`
config fix) made `get_issue`/`flow.sh` misclassify the successful response as
transient, burn all three retries, then hard-fail a call that had already
worked — discarding the real response entirely.

- Fix: both classifiers now short-circuit to `permanent` when the body
  already parses as a well-formed GraphQL success response (top-level `data`
  key present, `.errors` already ruled out above) — before reaching the
  keyword scan. Same false-positive class the existing `429`-substring
  exclusion above it already guards against, just via payload content
  instead of an HTTP status code.
- Found and fixed live in the Credit Network Biz workspace (CRE-66);
  `ticket-planner`'s copy carried the identical latent bug though it was
  never exercised in the original repro.
- New regression tests in both `test-linear-api.sh` and
  `test-planner-linear-api.sh` cover a success body containing "timeout" and
  "temporary"/"rate.limit", plus (planner side) confirming a genuinely
  non-GraphQL-success body still classifies as transient.

## ticket-planner 0.8.2 (2026-09-01)

Closes #174 — a third Crosscheck check family, `planner-crosscheck-bypass.sh`.
An August 31 audit of all seven existing initiatives found the planner
reasons forward from "what shall we build" and never asks "what already
exists that contradicts it": a pre-existing writer of the same guarded data
can silently defeat an epic's central guarantee while every spec in the set
stays internally correct.

- New: `planner_crosscheck_bypass_sweep` — for every spec paragraph that
  both names a backtick-quoted resource and matches a guard-declaration
  phrase ("derived from", "never overwritten", "hand-set", "only ... may",
  "must be audited/locked"), searches `REPOS_ROOT` for other file:line sites
  naming that resource on a line that looks like a write or definition site,
  excluding every file already cited anywhere in the spec set. Code:
  `BYPASS_PATH_UNADDRESSED` (blocking). True cross-runtime concept matching
  (the audit's `buildStorageKey` / `_build_classified_key` example — two
  functions with no shared name) needs an LLM; this is the bounded,
  deterministic slice of it, same tradeoff `planner-crosscheck-propagation.sh`
  already makes for term-only prose.
- New: `planner_crosscheck_discovery_gap` — a discovery.md self-declared
  exploration limitation ("quick-scan", "did not trace", "not explored",
  "assumed", ...) must have its substance recorded in proposal.md's Out of
  Scope section, or later phases reason confidently over a region the
  pipeline itself flagged as unexamined. Code: `DISCOVERY_GAP_UNRESOLVED`
  (warn) — a declared gap is a prompt for human judgment, not by itself
  proof of a defect.
- Changed: `planner-crosscheck.sh` wires the new family into
  `planner_crosscheck_run` alongside citation and propagation, and adds
  `DISCOVERY_GAP_UNRESOLVED` to `PLANNER_CROSSCHECK_WARN_CODES`.
- New test: `lib/tests/test-planner-crosscheck-bypass.sh` (11 assertions).

#175 (cross-initiative contract checking) remains separate and unimplemented.

## ticket-auto-pipeline 0.29.6 (2026-09-01)

Closes #186 — `gate-check.sh`'s entry gate had two false-hold bugs, both
found live while running CRE-22 (a complex, build-only, manual-autonomy
ticket) through the pipeline.

- **Manual-mode complex tickets could never clear the entry gate.**
  `_gate_entry`'s Check 3 ("complex tickets are always held")
  unconditionally returned before Check 4 — the check specifically
  designed to override the hold once a human approves in Linear
  (`approved` label + `Ready` state) — ever ran, but Check 4 only fires
  for `autonomy=manual`. Check 2.8b already handled the equivalent case
  for `auto`/`semi-auto`; its own comment ("manual has its own check at
  Check 4") described intent the code never implemented. Added Check
  2.8c, evaluated before Check 3, mirroring 2.8b for manual autonomy.
- **Build-only/API-only tickets could be held forever by an
  unsatisfiable nav-path critique finding.** The critique-plan
  cross-validation block ran unconditionally, unlike the mode-aware
  `missing_count` check just above it, which correctly skips
  browser-only prerequisites (nav path, test user) for tickets with no
  UI. A critique correctly flagging "no navigation path" on a
  build-only ticket held it indefinitely, since no plan can supply a
  navigation path that doesn't exist. Gated the whole block on
  `_ticket_mode = browser`.
- 3 new tests in `test-gate-check.sh`: manual+complex+approved passes,
  manual+complex+unapproved still holds (regression guard), and
  build-only cross-validation is skipped.

## ticket-auto-pipeline 0.29.5 (2026-09-01)

Closes #181 — prescan docs for repos outside a ticket's own scope sat
permanently `decayed`/`missing`, because nothing proactively refreshed
them independent of ticket dispatch. `/ticket-prescan` (bare, no repo
argument) already walks every repo under `REPOS_ROOT` and refreshes
anything non-fresh — but the only thing that ever invoked it that way
was `ticket-auto`'s per-ticket "Prescan gate", competing with that
ticket's own budget rather than running on a standing schedule.

- Added `lib/prescan-sweep.sh`: a zero-LLM, zero-Agent-spawn freshness
  sweep. Enumerates every repo under `REPOS_ROOT` the same way the
  per-ticket safety net does, runs `prescan-check.sh` on each, and
  reports counts by status plus a `needs_refresh` list (`--format
  text|json`). Exit 0 all fresh, 1 refresh needed, 2 on error.
- Documented (`skills/ticket-prescan/SKILL.md`) how to schedule bare
  `/ticket-prescan` runs (via the `schedule` skill or cron) decoupled
  from ticket dispatch, gated behind `prescan-sweep.sh` so a scheduled
  run that finds nothing stale never has to spawn a Claude session.
- 9 new tests in `test-prescan-sweep.sh` covering status counting, the
  `needs_refresh` list, both output formats, and error paths.

## ticket-auto-pipeline 0.29.4 (2026-09-01)

Closes #177 — `/ticket-retro` could not see `ticket-planner` runs at all.
`retro.sh`'s directory-mode log discovery was hardcoded to ticket-auto's
`./logs/*-pipeline.log` shape; the planner's `state.log` lives at a
different root (`${REPOS_ROOT}/.ticket-auto/initiatives/{INIT_ID}/state.log`),
under a fixed filename, keyed by initiative id rather than a `-pipeline.log`
stem.

- Fixed (ticket-auto-pipeline): `retro.sh` now discovers both log sources in
  `--window` mode — ticket-auto's `./logs/*-pipeline.log` and the planner's
  `${REPOS_ROOT}/.ticket-auto/initiatives/*/state.log` — tagging each
  discovered log with its source and reporting per-source
  scanned/skipped/with_failures counts in a new `logs_by_source` JSON field.
  Guarded on `PLANNER_INITIATIVES_DIR` existing, so a host with no planner
  runs (or `REPOS_ROOT` unset) sees byte-identical ticket-auto-only
  behaviour.
- Complexity-prediction accuracy (declared vs. actual) stays ticket-auto-only
  — planner initiatives have no `notes.md` score or outcome label, so
  planner-sourced logs are excluded from `complexity_predictions` rather
  than padding it with nulls. The planner's analogous quality signal
  (Crosscheck finding rate) is already reported via `crosscheck_*_total`.
- Cursor dedup (`retro-cursor.json`) works unmodified across both sources:
  ticket-auto ids (`CRE-47`) and planner initiative ids (`INIT-...`) are
  disjoint namespaces by construction, so a flat ticket-id key already
  dedupes each source independently.
- Added six planner Crosscheck codes (`CITATION_UNRESOLVED`,
  `CITATION_LINE_OUT_OF_RANGE`, `CITATION_SYMBOL_MISMATCH`,
  `RESOLUTION_NOT_PROPAGATED`, `FORWARD_REF_UNFULFILLED`,
  `CARVE_SCOPE_LOST`) to `ticket-retro/SKILL.md`'s code→skill-file mapping
  and per-code templates, so a proposal generated from a planner finding
  names `ticket-planner/lib/...` files as implicated — not a
  `ticket-auto-pipeline` skill.
- Added `ticket-auto-pipeline/lib/tests/test-retro-planner-source.sh` (6
  tests) covering multi-source discovery, per-source counts, cursor dedup,
  and ticket-auto-only backward compatibility.

## ticket-planner 0.8.1 / ticket-auto-pipeline 0.29.3 (2026-09-01)

Closes out the two remaining acceptance criteria on #176 that 0.8.0 left
open: the retro histogram claim was unverified, and `status` mode didn't
surface Crosscheck findings at all.

- Fixed (ticket-auto-pipeline): `retro.sh`'s failure-histogram parser
  bucketed every `META|crosscheck|fail` line under a single `"crosscheck"`
  key (it used `$step` as the bucket, the same generic path every other
  phase's fail line takes) instead of extracting the finding code the way
  it already does for `gate-stop`. Every distinct finding
  (`CITATION_UNRESOLVED`, `RESOLUTION_NOT_PROPAGATED`, ...) collapsed into
  one undifferentiated count — running retro directly against a planner
  `state.log`, as #176 AC2 asked, showed this immediately. Crosscheck now
  gets its own branch mirroring `gate-stop`'s, plus two new JSON fields,
  `crosscheck_blocking_total` and `crosscheck_warn_total`, so warn-level
  findings (`info <CODE> <message>`) are counted separately and never land
  in the blocking histogram (AC4). New test:
  `lib/tests/test-retro-crosscheck.sh`.
- New (ticket-planner): `planner_crosscheck_findings_summary
  <initiative_id>` in `lib/planner-crosscheck.sh` — reads recorded
  `META|crosscheck` entries back for `status` mode (#176 AC5), one
  `<count> <blocking|warn> <CODE>` line per distinct code plus a `TOTAL:`
  line. Scoped to the most recent Crosscheck attempt only (everything since
  the last `Crosscheck|check|start` marker) — state.log is append-only, so
  without that scoping a finding fixed by an earlier `resume` would report
  as outstanding forever.
- Changed: `SKILL.md` status mode now calls the new summary function and
  reports a "Crosscheck findings" section when the most recent attempt left
  any.

## ticket-planner 0.8.0 (2026-09-01)

Crosscheck lands as phase 7 of the planner's state machine, between Consensus
and Epic Gen — the last artifact-only phase, and the first point anything
compares the settled artifacts against each other and the live repo rather
than validating one file at a time. It wires in the two deterministic linters
built in 0.7.2/0.7.3 (citation resolution + precedent grep, and cross-ticket
propagation), which existed but had no call site (#178, closing out #176 for
the two check families that are implemented; #174/#175 remain separate,
unimplemented issues).

- New: `lib/planner-crosscheck.sh` — `planner_crosscheck_run <initiative_id>`
  runs both linters, writes every finding to state.log as
  `META|crosscheck|fail|<CODE> <message>` (the shape `ticket-retro`'s
  failure-histogram parser already reads, once #177 points it at planner
  logs), and writes the phase's own `Crosscheck|check|{start,done,fail}`
  progress markers.
- Changed: `planner_phase_sequence` gains `Crosscheck` between `Consensus`
  and `EpicGen` (9 phases → 10). `PLANNER_DRY_RUN_PHASE` and
  `PLANNER_CREATE_GATE_PHASE` move from `Consensus` to `Crosscheck` — `plan`
  now runs Crosscheck unconditionally (it's artifact-only, so authorization
  doesn't gate it) before stopping at the create-gate boundary.
  `planner_position_derive`, the retry budget, and `--until` validation need
  no changes — they're all derived from `planner_phase_sequence`.
- Changed: Crosscheck is dispatched as plain bash from SKILL.md's dispatch
  loop, not an Agent spawn — the only phase where that's true. A blocking
  finding stops the loop immediately (not folded into the phase-retry
  budget): the check is deterministic, so re-running it against unedited
  artifacts can't produce a different answer. Fixing the cited artifact and
  running `resume` re-runs Crosscheck and proceeds once clean.
- Docs: every phase-count/phase-sequence reference across the plugin
  (`CLAUDE.md` ×2, `SKILL.md`, `plugin-overview.md`, `docs/ticket-planner.md`,
  `state-log-format.md`, both `README.md`s, `plugin.json`,
  `marketplace.json`) updated 9→10 phases together, to avoid the "12-phase
  vs 9-phase" doc-drift bug class from the 0.21.2 entry below.

## fleet-controller 0.7.0 (2026-08-19)

`fleet_dispatch_initiative` becomes the single repeatable campaign command:
every invocation reconciles the epic's children (resume dead pipelines),
enqueues the next wave, and reports what it did. Fixes the four root causes
that made campaigns stall after a killed worker: unreachable reconcile
(startup-only), kill-poisoned classification, a dead-log capacity jam, and a
stop-file that pinned nothing.

- New: dispatch runs a campaign reconcile (Step 1.75) before child
  enumeration — `fleet_reconcile_orphans` scoped to ALL of the epic's
  children via new `FLEET_RECONCILE_TIDS` (space-separated scope; unset =
  the startup path's global scan), re-enqueueing incomplete pipelines with
  reason `campaign-resume from {epic}` (`FLEET_RECONCILE_EPIC`).
  `FLEET_RECONCILE_DRY_RUN` previews would-resume/would-dead-letter without
  writing. Generation resolution and the `FLEET_MAX_RESTARTS` cap are the
  existing mechanisms — no second counting scheme.
- Changed: `fleet_ticket_terminal_state` classifies a
  `stopped: fleet-kill` outcome as `incomplete` (kill = pause, stop-file
  pin = stop) unless the log carries a `|META|gate-stop|fail|` line
  (structural stop must not resume). Ships together with the stop-pinning
  fix — the pin is the load-bearing guard.
- Changed: capacity is live-only. `_active_pipeline_count` counts a
  no-outcome pipeline log only when its worker is pgrep-live or
  run-registry-alive; dispatch additionally reserves slots for the epic's
  own pending queue entries (`_fleet_queued_count_for_epic`). The monitor
  loop's consume path uses the same helper — fleetd and the monitor agree
  on capacity. A dead log no longer jams a campaign.
- Changed: `fleet_stop_initiative` resolves the epic's children from
  Linear, purges queue entries by reason
  (`planned-dispatch|campaign-resume from {epic}`) OR child tid, kills
  workers matching the same alternation, and pins every child whose
  pipeline log classifies incomplete — a stop with an empty queue and no
  live workers now pins its mid-flight children (the `tickets: []` gap).
  A children-query failure degrades with a warning, never aborts the stop.
- New: dispatch reports per-tid `  resumed {tid}` / `  blocked {tid}` /
  `  enqueued {tid}` lines and a summary last line
  (`fleet_dispatch: resumed N | blocked N | enqueued N ticket(s) for
  {epic}`; dry-run variant). `POST /dispatch` responses gain `resumed` and
  `blocked` arrays; `GET /epics` attributes `campaign-resume`-reasoned
  entries to their epic.
- Changed: fleetd's `_consume_queue_locked` stale-entry check now uses
  `_log_reached_terminal`, the Python mirror of the resume-relevant bash
  classification rules — the raw `|META|outcome|` grep would have dropped
  the campaign-resume entries. Both sides cross-reference each other.

## fleet-controller 0.6.0 (2026-08-18)

fleetd grows an on-demand HTTP control/query surface, an epic-scoped stop
lifecycle, and per-worker live status.

- New: HTTP API on the existing loopback server — `POST /dispatch` (scoped
  dispatch of one epic against the running daemon, independent of
  `FLEET_AUTO_DISPATCH`; reuses `fleet_dispatch_initiative`, so validation
  and idempotency are identical to the skill path, and spawns immediately
  rather than waiting for the poll cycle), `POST /stop` (epic-scoped stop:
  purge queue, escalate-kill workers, write stop-file), `GET /workers` and
  `GET /workers/<tid>` (live phase/anomalies/tokens/confidence per worker),
  `GET /queue` (entries + malformed lines), `GET /epics` (state-dir
  derivation — stopped/queued/running, no Linear calls). `GET /health`
  shape is unchanged and now documented. A single `threading.RLock`
  serializes all state mutation between the HTTP thread and the main loop.
- New: `fleet_stop_initiative` — the single stop implementation (skill
  `stop` subcommand and `POST /stop` both call it; works with fleetd down).
  Writes `stop-{epic}.json` pinning stopped tickets; every dispatch trigger
  path early-exits for a stopped epic, startup reconciliation skips pinned
  tickets, and only an explicit resume (`--resume` / `"resume": true`)
  clears it — dispatch is the single start/resume/un-stop entry point.
- New: epic-scoped dispatch flock (`{queue}.{epic}.dispatch.lock`) closes
  the check-then-append race between concurrent dispatchers (skill vs. HTTP
  vs. auto-sweep); `FLEET_DISPATCH_LOCK_TIMEOUT` (default 5).
- New: `FLEET_AUTO_DISPATCH` is a documented `fleet-config.sh` flag
  (default `false`, idle-until-invoked — behavior unchanged, now explicit).
- New: detection-cycle per-ticket results (phase, anomalies) are merged
  into live worker records instead of discarded — the previously-dead
  `ChildTable.update_phase` is now wired, with an `update_anomalies`
  sibling. Tokens are summed from `META|tokens` entries at query time;
  `confidence_predicted` is parsed once from the Planner Context block
  (cached), `confidence_actual` stays explicit `null` until the
  `META|planner-feedback` entry exists.
- New: `detect_initiative_dispatch` findings name an epic's stop-file when
  one is present, so a stopped epic is visible on the dashboard, not just
  on disk.

## fleet-controller 0.5.0 (2026-08-18)

`fleetd` worker spawn command is now configurable, plus a new environment
check skill.

- New: `CLAUDE_CMD` env var — a full shell-style command line (e.g.
  `claude-deepseek 2 --bypass`) that replaces the bare worker binary name.
  Takes precedence over the existing `CLAUDE_BIN`; the `-p '/ticket-auto
  {tid} --auto --from-planned'` invocation is always appended after it.
- Fix: `Supervisor._claude_bin` was set from the `claude_bin` constructor
  arg / `CLAUDE_BIN` env var but never threaded through to `spawn_worker` —
  it had no effect since the class was introduced. Now wired through
  `_consume_queue` alongside the new `_claude_cmd`.
- New: `/fleet-env-check` skill + `lib/fleet-env-check.sh` — validates
  `LINEAR_API_KEY`, `REPOS_ROOT`, `GITHUB_PERSONAL_ACCESS_TOKEN`/`GH_TOKEN`
  (only required when `FLEET_EPIC_AUTO_PR=true`), the fleetd worker spawn
  command (surfaces a missing `CLAUDE_CMD`/`CLAUDE_BIN` binary before
  fleetd hits it as a silent per-spawn `OSError`), and `jq`/`git`/`python3`/`gh`
  presence. Same pipe-delimited contract as ticket-auto-pipeline's
  `env-check.sh`, but scoped to fleet-controller's much smaller surface —
  no hooks/spawn-permission/UAT_URL checks. Masks secret values to `****` +
  last 4 chars rather than echoing them in full.

## ticket-auto-pipeline 0.26.0 · fleet-controller 0.4.0 (2026-08-17)

`fleetd` process supervision hardening plus two epic-branch correctness fixes.

- New: `fleet-reconcile.sh` — startup orphan reconciliation. Classifies every
  ticket with a pipeline log using the log alone (no Linear/gh calls) and
  re-enqueues tickets whose worker died while `fleetd` itself was down, so a
  controller crash no longer silently ends the run.
- New: `fleet-controller/systemd/fleetd.service` and
  `docs/process-supervision.md` — `fleetd` is externally supervised
  (`Restart=always`), not self-supervised; the existing single-instance
  `flock` guard prevents a supervisor restart from racing a still-shutting-down
  instance into a second concurrent supervisor.
- Fix: generation continuity survives registry-entry deletion. A dead or
  unverifiable worker's generation is preserved to `{tid}-last-generation`
  before its registry entry is deleted, so a reconciled re-spawn continues the
  generation sequence instead of restarting at 1.
- Fix: the spawn-queue rewrite in `fleetd` is now serialized with the same
  `flock` sidecar the bash dispatch-append path uses — a dispatch append
  landing between `fleetd`'s read and its rename was previously silently lost.
- Fix: `_fleet_scan_initiative_dispatch` now threads the workspace through to
  dispatch, so auto-dispatched spawn-queue entries resolve to the durable path
  `fleetd` actually reads instead of a CWD-relative one; also drops a stray
  epic Linear-state filter that made `state:execution` epics invisible to
  detection.
- Fix (`ticket-auto-pipeline`): epic-directive branch resolution was setting
  the base branch to the directive's `Base` instead of its `Branch` —
  children were not actually branching off / PR'ing into the shared epic
  branch as designed.
- Fix (`ticket-auto-pipeline`): `epic_branch_children_done` counted
  non-planned children toward the total, making epic readiness practically
  unreachable on epics with any unplanned future work.
- Chore: `fleet-controller/lib/config.sh` renamed to `fleet-config.sh` to
  avoid a collision with the SessionStart lib-sync step; `ticket-auto-pipeline`
  callers fall back to the old name for pre-rename installs.

## ticket-planner 0.4.0 · grill-me 0.1.0 (2026-07-26)

New `grill-me` plugin — a pre-work readiness gate that assesses business ideas
against profile-driven quality dimensions before any planning starts. The
ticket-planner gains an optional pre-flight gate that validates sealed intent
documents, making the planner refuse under-specified or tampered inputs before
creating any initiative state.

- New: `grill-me` plugin — profile-driven readiness assessment, deterministic
  bash scoring engine, interactive clarification question loop, and a
  cryptographic SHA-256 intent seal that makes tampering detectable.
- New: `product-idea` profile with 10 weighted dimensions, 3 qualitative flags
  (overscoped, conflicting_requirements, solution_masquerading_as_problem),
  configurable thresholds, and per-dimension evaluation probes.
- New: `planner-intent-gate.sh` — pre-flight gate that resolves `grill-seal.sh`
  through a three-level fallback (plugin cache → skills lib → relative path) and
  validates intent documents before `planner_state_init`. A tampered file, a
  missing seal, or a `do-not-proceed` verdict is a hard stop. No bundled copy
  of the verifier — a drifting duplicate would silently pass invalid seals.
- New: `PLANNER_REQUIRE_INTENT` (default `false`) — when `true`, raw idea strings
  are refused; the planner directs the user to `/grill-me`.
- Changed: Appraisal phase prompt now reads `${state_dir}/artifacts/intent.md`
  when present and treats it as authoritative for objective, scope, and criteria.
- Changed: ticket-planner 0.3.1 → 0.4.0.
- Tests: 55 new tests across 5 suites — profile validation (13), scoring engine
  (23), seal generation/verification (11), document rendering (5), and planner
  intent gate (14). Wired into `make test` via `test-grill` and
  `test-planner-intent-gate` targets.
- Fix: `planner-intent-gate.sh` carried file-scope `set -euo pipefail`, unlike
  every other sourceable file in `ticket-planner/lib/` — sourcing it into the
  router's shell silently turned on errexit there. A second leak in the same
  function unconditionally re-enabled errexit after an internal `set +e` probe,
  regardless of the caller's prior state; both now save/restore correctly.
- Fix: `_resolve_grill_seal`'s plugin-cache fallback assumed a non-versioned
  cache path that never matches the real marketplace-installed layout
  (`.../grill-me/{version}/lib/grill-seal.sh`), silently falling through to
  lower-priority resolution on every real install. Now mirrors
  `_resolve_branch_directive_checker`'s versioned-glob pattern exactly.
- Fix: `IDEA` derivation from `## Objective` in `ticket-planner`'s plan-mode
  step produced an empty idea for multi-line objectives, lowercase-starting
  prose, or the `_None specified_` placeholder, and its `|| echo "$path"`
  fallback was dead code (`head` always exits 0). Replaced with a full-section
  extraction that falls back on emptiness, not on exit status.
- Fix: `### Out of scope` rendered the `scope` dimension's `gap` field
  (assessment incompleteness) as if it were a stated exclusion. Added a
  `boundary` field to the assessment JSON contract for explicitly-stated
  exclusions; the renderer now sources `### Out of scope` from it.
- Fix: `## Open Gaps` rows were built by index-aligning the result's
  profile-ordered dimensions array against the assessment's array, which the
  scorer's own omission-coercion behavior guarantees can diverge in order and
  completeness — misattributing gap text across dimensions. Now looked up by
  dimension id.
- Docs: reconciled the `intent-document` openspec section-order requirement
  with the renderer, skill doc, and render test (all of which already agreed
  with each other) — only the spec had `Assumptions` ordered before
  `Risks`/`Edge Cases`.

## 0.21.2 (2026-07-25)

Documentation restructure — the root README covered install and configure but
never said what to type, and `fleet-controller` was listed in the marketplace
table with a link to a README that did not exist.

- Docs: root README rewritten as a high-level entry point — goal-indexed "which plugin do I need", ecosystem flow diagram, two-path first-run walkthrough, seven-phase run description, symptom-to-link troubleshooting table, and a documentation map indexing every doc by audience (previously only two of four plugin READMEs were linked at all).
- Docs: new `fleet-controller/README.md` — when the plugin is needed, dry-run-first quickstart, all five modes, the 12 detection engines, escalation path, `fleetd`, configuration reference, and migration off the deprecated `/ticket-fleet-controller`.
- Docs: `ticket-auto-pipeline/README.md` gains a Documentation map; it never linked its own `plugin-overview.md` or `docs/` index.
- Fix: `validate-linear-config.sh` path was wrong in three places — the script lives under `skills/ticket-flow/`, so the documented Configure step failed with "No such file". Replaced with the plugin-cache `find` idiom used elsewhere, since marketplace users have no clone.
- Fix: planner described as 12-phase in the root README and `marketplace.json` (listing merged-away phases such as Story Gen); actual is 9-phase per `plugin.json`, `SKILL.md`, and `CLAUDE.md`.
- Fix: "six phases" claim followed by a five-item diagram; actual is seven.
- Fix: `ticket-auto-pipeline` README taught the deprecated `/ticket-fleet-controller` commands; now points at the extracted plugin.
- Fix: duplicate `Crash recovery` heading silently broke anchor links — the troubleshooting one renamed to "Resuming an interrupted run".
- Chore: fleet-controller 0.3.1 → 0.3.2. `ticket-planner` intentionally unbumped — only its marketplace description changed, which is marketplace-level metadata, not plugin content.

## 0.21.1 (2026-07-25)

Release packaging for the shared epic-branch programme — 4 phases, 229 tasks,
4831 LOC across 46 files.

- Chore: patch bumps across three plugins for marketplace update detection — ticket-planner 0.3.0 → 0.3.1, fleet-controller 0.3.0 → 0.3.1.
- Docs: root README lists all 4 plugins (previously only `ticket-auto-pipeline`).
- Docs: root CLAUDE.md corrected — 12-phase → 9-phase planner, 11 → 12 detection engines; the engine count propagated across all CLAUDE.md and SKILL.md files.
- Docs: plugin descriptions gain epic branch, worktree, and Branch Directive mentions.

## 0.21.0 (2026-07-25)

Shared epic-branch programme, Phase 3 — epic branch lifecycle management.
fleet-controller 0.2.1 → 0.3.0.

- Feature: new `lib/epic-branch.sh` — `ensure_epic_branch` (create/push the directive-declared branch, idempotent), `epic_branch_sync` (merge base into epic; never rebases, never force-pushes), `epic_branch_children_done` (pure bash readiness check), `epic_branch_open_pr` (opens an integration PR, never auto-merges). All mutating paths gate behind `FLEET_DRY_RUN`.
- Feature: `fleet-dispatch.sh` fetches epic description in GraphQL, enforces an epic-branch precondition before enqueue, and syncs per cycle behind the `FLEET_EPIC_BRANCH_SYNC` gate.
- Feature: 12th detection engine `_fleet_scan_epic_branch_ready` registered in `fleet_detect_all` (D-12, severity 0–1).
- Feature: `fleet-monitor.sh` runs `worktree_gc` each cycle (non-fatal), closing a Phase 2 gap.
- Feature: `INTEGRATION_PR_GUARD` added before auto-merge squash; new config `FLEET_EPIC_BRANCH_SYNC` (default true) and `FLEET_EPIC_AUTO_PR` (default false).
- Test: 20 tests using an origin fixture and `gh` function mocks; all 4 shared-branch programme suites wired into the Makefile.

## 0.20.0 (2026-07-25)

Shared epic-branch programme, Phase 2 — per-ticket git worktree isolation.
Replaces shared-clone checkout, fixing the concurrent-pipeline race where two
tickets on the same repo observed each other's branches and uncommitted changes.

- Feature: `lib/spawn-helper.sh` gains `WORKTREE_ROOT` transport (param parser, heredoc placeholder, sed replacement). 60/60 tests pass.
- Feature: 5 skills migrated to worktrees — `ticket-implement` (`ensure_worktree` replaces cd+checkout+pull+checkout-b), `ticket-verify` (`gh pr list/create` use the worktree path), `ticket-document` (git diff/log and branch detection via worktree), `ticket-pr-review` (diff and conflict check in worktree), `ticket-auto` (`release_worktree` in STEP_6, non-fatal, after document).
- Chore: audit clean — 0 `cd {repo-path}`, 0 literal `develop`, `REPOS_ROOT` confined to prescan loops.
- Docs: 3 sharp edges recorded — worktree isolation is files-only (ports, databases, and seeded test state still collide), minimum git 2.17 for `git worktree remove`, and no migration needed for pre-existing branches.
- Known gap: 5 verification tasks deferred (end-to-end, concurrency, crash-resume, wrong-branch guard, `release_worktree` confirmation) — all require live Linear ticket runs.

## 0.18.0 (2026-07-24)

Planner integration, Part 7 — rollout, alignment, and a full determinism audit.
ticket-planner 0.2.0, fleet-controller 0.2.1.

- Docs: new `docs/rollout-plan.md` — 8-phase sequence with gating criteria and rollback procedures.
- Docs: new `docs/planner-state-alignment.md` — planner-to-ticket-auto state mapping, label bridge, confidence flow.
- Docs: new `docs/determinism-audit-2026-07-24.md` — full-system audit across all 7 parts; **0 candidates found for further bash migration**.
- Docs: root CLAUDE.md updated to the 4-plugin ecosystem architecture with a determinism boundary diagram.
- Test: new `test-handoff-e2e.sh` — 16 end-to-end integration tests with a mocked Linear API (planned ticket validation, depth mismatch, blocked-by resolution, concurrency, unplanned isolation).

## 0.17.0 (2026-07-24)

Exploration depth levels — Planner Context Schema-Version 2.

- Feature: `planned-ticket-check.sh` supports Schema-Version 2 with 5 optional exploration fields (Exploration Depth, Code Paths Traced, API Contracts Analyzed, Alternative Approaches, Open Questions). `SCHEMA_KNOWN_MAX` bumped to 2, forward-compatible with future versions.
- Feature: Exploration Depth enum validation (`quick-scan`/`standard`/`deep`) and Code Paths Traced format validation (`symbol:file`).
- Feature: `check_exploration_depth_mismatch()` detects quick-scan-on-complex tickets; surfaced in `gate-check.sh` as a **soft signal that warns but never blocks**.
- Feature: `planned-feedback-write.sh` computes `exploration_depth_actual`, `missed_symbols`, and `false_traces` from the diff versus traced paths; `fleet-feedback.sh` aggregates `exploration_accuracy` per initiative.
- Docs: appraise depth-consumption guidance (deep → trust traced paths, standard → supplement with targeted grep, quick-scan → full investigation). New `exploration-depth-levels.md` and `discovery-phase-spec.md`.
- Test: 9 new cases (5 V2 validation, 4 depth mismatch); all 29 pass, shfmt clean.

## 0.16.1 (2026-07-22)

Resolves 7 GitHub issues (#97–#103), including a P0 that broke `flow.sh` entirely.

- Fix (P0, #97): `linear-api.sh` removed `429` from the transient-keyword regex. UUID substrings (e.g. `dd816776-4ce4-429c-ad38`) triggered false-positive transient classification on every labels/states query, breaking `flow.sh`. HTTP 429 is already caught by the status-code check and GraphQL rate-limit errors by the `.errors` block.
- Fix (P1, #98): `gate-check.sh` allows complex + auto/semi-auto + approved to bypass the unconditional complex hold — a human approval label now auto-approves complex tickets in non-manual modes.
- Fix (P2, #99): `gate-check.sh` accepts both `✓` and `Y` in the verification plan Verifiable column; agents write ASCII `Y` but the grep required the Unicode mark.
- Fix (P2, #100): `gate-check.sh` accepts openspec directories as artifacts — `[ -f ]` returned false for directories, causing `EXEC_NO_ARTIFACT` false positives on every openspec ticket.
- Fix (P2, #102): `gate-check.sh` decouples the verification check from `critique_score`, preventing false holds on tickets with neither a verification plan section nor a critique.
- Fix (P2, #101): `spawn-helper.sh` sources `capture-transcript.sh` in `spawn_capture` when `capture_agent_result` is not loaded.

## 0.16.0 (2026-07-21)

- Docs: reconciled the ticket-planner tracker against shipped code. Parts 4 and 5 were marked TODO with 0 tasks while the fleet-side code had shipped on 2026-07-15.
- Docs: recorded 3 remaining gaps at the time — `--from-planned` flag, feedback writer, detection-to-dispatch actuation.
- Docs: noted fleetd-supervisor-daemon complete (PR #104, 58/58 tasks).

## 0.15.1 (2026-07-14)

- Feature: `ticket-retro` gains `--post-to-github` — a deterministic GitHub issue pipeline. New `lib/github-issues.sh` (4 functions wrapping the `gh` CLI with heartbeat instrumentation) and `lib/github-issue-retro.sh` (state file I/O, severity mapping, threshold check, create-vs-comment decisions — all mechanics in bash, content from AI).
- Feature: single `lib/github-issue-body.template.md` with `{PLACEHOLDER}` variables for consistent issue formatting; the SessionStart hook copies `*.template.md` to `lib/`.
- Feature: 3 new config constants — `GITHUB_ISSUE_REPO`, `GITHUB_ISSUE_STALE_DAYS`, `GITHUB_ISSUE_MAX_COMMENT_SIZE`.
- Design: deduplication via a local JSON state file, not GitHub labels. Graceful degradation — `gh` unavailable warns and skips, and the proposal is still written. Fleet-controller deliberately excluded as an architectural boundary.
- Test: 21 unit tests with a mocked `gh` CLI.

## 0.15.0 (2026-07-14)

Template selection, body validation, and the artifact plane for planned tickets.

- Feature: `lib/template-select.sh` — deterministic type-to-template resolution (`bug`/`feature`/`improvement`/`security`/`chore`, with `refactor` aliased to improvement).
- Feature: `lib/planner-artifacts.sh` — resolves the shared plane path `REPOS_ROOT/.ticket-auto/initiatives/{INIT}/tickets/{TID}/planner/`.
- Feature: `lib/planned-ticket-body-check.sh` — validates required body sections per type (universal: AC / Test User / Scope; bug adds Repro + Test Data; feature and improvement add Nav Path).
- Feature: two new gate-stops in `gate-check.sh` Check 2.7 — `NO_TEMPLATE_FOR_TYPE` and `PLANNED_BODY_INCOMPLETE`.
- Refactor: `planned-ticket-check.sh` exports the canonical `_extract_planner_context_block` as a single source of truth, deduped from `appraise-fast-path.sh`.
- Feature: `state-machine.json` registers Type labels (bug/feature/improvement/security/chore) and corrects the `pre-approved` description. New `templates/chore.md`.
- Feature: `setup.sh` seeds `context.md` from the plane's `body.md` on planned tickets; `ticket-appraise-exec` reuses `planner/proposal.md` when present; `ticket-verify` prefers the plane-seeded `context.md` over the Linear description.
- Test: 4 new suites (40 tests); all 120 existing plus new tests pass, lint and fmt-check clean.

## 0.14.3 (2026-07-08)

Appraise fast-path for planned tickets — Phase 2 of ticket-planner enrichment.
When a ticket carries the `planned` label and a valid `## Planner Context`
block, appraise skips the complexity sweep, prior art search, and codebase
investigation, using the planner's pre-computed metadata instead.

- Feature: `lib/appraise-fast-path.sh` — deterministic eligibility check, field extraction, strategy-to-complexity mapping (Conservative → simple; Balanced/Innovative → complex), and printf-based `notes.md` generation.
- Feature: SKILL.md Step 1.3 dispatches at bash level via `fast_path_action()`, replacing an LLM-interpreted decision table.
- Fix (post-review hardening): heredoc replaced with printf as defense-in-depth against shell injection; delegation to `planned-ticket-check.sh` helpers eliminates duplicated sed/awk; `unset_fast_path_vars()` prevents stale variable leaks across invocations; case catch-all added for unexpected validator exit codes.
- Test: 20 unit tests, wired into Makefile discovery.

## 0.14.2 (2026-07-08)

- Chore: version bump only, no functional change.

## 0.14.1 (2026-07-07)

Fleet controller extracted from `ticket-auto-pipeline/lib/` into a standalone
top-level `fleet-controller/` plugin (v0.1.0). Fleet sits architecturally above
both ticket-planner and ticket-auto as the parent orchestrator — the extraction
makes that explicit.

- **BREAKING (internal):** fleet lib scripts and the skill move to a new plugin namespace. The runtime skill path changes from `/ticket-auto-pipeline:ticket-fleet-controller` to `/fleet-controller:fleet-controller`. A deprecated forwarder remains for one release cycle.
- Feature: new plugin ships 6 lib scripts, 8 test files, 122 tests.
- Feature: 3 new detection engines — `detect_planner_feedback`, `detect_blocked_by`, `detect_initiative_dispatch` (11 total, up from 8).
- Feature: `fleet-dispatch.sh` — initiative epic to spawn queue dispatch with blocked-by resolution and `FLEET_MAX_CONCURRENT` enforcement.
- Feature: `fleet-feedback.sh` — `META|planner-feedback` aggregation grouped by initiative, structured JSON with confidence drift tracking.
- Feature: `fleet-monitor.sh` integrates spawn queue consumption into the monitor loop; `fleet-dashboard.sh` adds fleet-wide detector rows to terminal and markdown output.
- Chore: removed 4 fleet scripts and 4 tests from `ticket-auto-pipeline/lib/`.

## 0.14.0 (2026-07-06)

Closes 32+ integrity defects across prescan, router, pipeline phases, and
observability. **This is the release that shipped the work described in the
0.12.13 and 0.13.0 entries below** — `plugin.json` went from 0.12.12 straight to
0.14.0 in this commit.

- Fix: prescan — gitnexus indexing gaps, corpus-build failures, fan-out issues.
- Fix: router hardening, 14 fixes — 4 P0 (auto-merge dead code, retro firing every run, silent `flow.sh` skip, loop dedup suppression) and 5 P1 routing/counting integrity bugs.
- Feature: pipeline integrity Phase 1 — `return-completeness-check.sh` (warn-only, openspec-scoped); Section 2 — `simple-fix.md` Completion Checklist gate; Phase 3 — CORRECTIONS back-feed library with 3 consumers and round-trip tests; Phase 4 — prescan title fix via `meta.json` `doc_titles`.
- Fix: ticket-auto integrity hardening, 18 defects across 9 increments (A–I) — EXEC artifact-type token closeout (`exec|done|` → `create-artifact|done|`); router grep fixes and `VERIFY_ATTEMPTS` semantics; `gate-check.sh` `set -e` fix; `state-machine.json` unified to a single source with the root copy deleted; `flow.sh` from-precondition guard (warn-only `ILLEGAL_TRANSITION`); `linear-api.sh`/`flow.sh` robustness (429 retry, empty-200, lock path); outcome-label grep fix and `corrections-parse.sh` flock concurrency; loop-counter freeze fix hard-requiring `VERDICT=`/`cycle#N`; test and doc hygiene.

## 0.13.0 (2026-07-05)

Pipeline integrity, Phase 1 — closes the "agent self-reports done with zero
independent check" hole for the highest-value case: an implement agent claims
`done` while its openspec `tasks.md` still has unchecked boxes. Ships
warn-only, per the `openspec/changes/pipeline-integrity` design — it never
halts the pipeline in this phase; it only measures.

- Feature: new `lib/return-completeness-check.sh` — deterministic bash gate (0 complete / 1 incomplete / 2 error) that counts unchecked `- [ ]` boxes in a ticket's openspec `tasks.md`, resolved by searching `REPOS_ROOT` for the matching change directory (or via `--tasks-file` directly).
- Feature: `ticket-auto`'s STEP_4 (Implement) now runs this gate between `spawn_capture` and `spawn_agent_post`, scoped to openspec tickets only (`{ARTIFACT_TYPE}=openspec`) — simple-fix tickets are ungated in this phase (decision D1).
- Feature: a mismatch logs `|META|gate-warn|info|RETURN_INCOMPLETE — ...` — a new channel distinct from `gate-stop`, so `fleet-detect.sh` never escalates a warn-only mismatch to a human-must-resolve severity.
- Feature: `retro.sh` gains a `GATE_WARN_TOTAL` counter (and `{GATE_WARN_TOTAL}` in the `ticket-retro` report), separate from `GATE_STOP_TOTAL`, so the false-positive rate can be measured before any future flip to enforce mode. New `templates/RETURN_INCOMPLETE.md` investigation guide.
- Documented (not yet enforced): the D3 hard contract — once enforce mode ships (Phase 2), the router MUST call `spawn_agent_post RESULT=fail` on any non-zero gate exit, mirroring `gate-check.sh`'s existing contract.
- Test: added `lib/tests/test-return-completeness.sh` (6 cases: all-checked, unchecked, multi-unchecked count, missing tasks.md, `--tasks-file` bypass, unchecked-item listing), wired into the CI `Makefile`.

## 0.12.13 (2026-07-05)

Router hardening — `ticket-auto`'s thin dispatch router and `detect-resume.sh` coupled
deterministic greps to unspecified LLM free-text/emoji output in several places; this
release closes those gaps (14 findings, Increments A–F of the router-hardening plan).

- Fix: `detect-resume.sh` `VERIFY_ATTEMPTS` now counts only terminal `|VERIFY|verify|(done|fail)|` lines instead of any `|VERIFY|*|fail|` sub-step line — a pre-flight hiccup no longer double-counts a verify attempt. (R6)
- Fix: `MAINTENANCE_FROM` extraction now excludes `|MAINTENANCE|prescan|` lines — the auto-invoked prescan gate no longer gets mistaken for a resumable wiki-maintenance sub-step. (R7)
- Fix: preflight team-resolution distinguishes a failed Linear teams query from a genuine multi-team result, instead of reporting "multiple teams" on any query failure. (R14)
- Fix: `implement-complete`'s `flow.sh` resolution now falls back to the plugin-cache path (matching every other resolution site) and reports failure via `hb_retry` instead of silently swallowing it with `|| true` — plugin-cache-only installs no longer drift Linear state silently. (R3)
- Fix: prescan spawn success is now judged by grepping the captured `AGENT_RESULT` for the skill's completion marker, not by `spawn_capture`'s exit code (which is a log write and always succeeds). (R9)
- Fix: STEP_6's retro auto-trigger condition 2 now tests for positive success markers (`VERIFY|verify|done|PASS` + `PR-REVIEW|post-findings|done|Verdict: ✅`) instead of the absence of the outcome-write marker, which that same step wrote *after* the check ran — the retro agent no longer spawns on every clean run. (R2)
- Fix: `spawn_agent_post`'s done/fail idempotency guard is now tail-scoped (compares only the log's last line) instead of whole-file — loop phases (PR-review iteration, verify retry) now get a fresh terminal log line on every cycle instead of only the first. (R4)
- Feature: `spawn_agent_post` accepts an optional `VERDICT=<PASS|FAIL|OK|WARN|BLOCK>` parameter, prepended to `MSG` as a canonical token (`done|PASS — <text>`). `detect-resume.sh`'s STEP_4_6 routing and `ITERATION` counting now match these tokens instead of router prose / byte-exact emoji bytes. Documented in `pipeline-log-format.md#verdict-tokens`. (R5)
- Fix: added `VERIFY_LAST` resume hint — if the last terminal VERIFY event is a `fail` with no later `IMPLEMENT|implement|done`, the pipeline dispatches re-implement before re-verifying instead of re-running verify against the same unfixed code. (R8)
- Feature: auto-merge now reads the confirmed Linear outcome label via a new `META|outcome-label|info|<value>` line (written by `outcome-label-check.sh`) instead of the IMPLEMENT terminal line, which never carried the Smooth/Rough/Hard value. Auto-merge now fires in both `auto` and `semi-auto` autonomy modes (previously `semi-auto` only, and effectively dead code). (R1)
- Feature: STEP_5_5 (PR comment reconciliation) caps `PR_FEEDBACK_CYCLE` at 3, gate-stopping with `PR_FEEDBACK_EXHAUSTED` on a 4th round of new human comments; `pr-reconcile` now emits a `cycle#N` marker so the counter advances. (R10)
- Fix: the prescan freshness gate is skipped entirely when resuming at STEP_4 or later — crash recovery mid-implement/verify/PR-review/report no longer pays the per-repo freshness-check cost. (R11)
- Fix: the `META|autonomy` write is now guarded against a resume silently re-appending or switching modes — an explicit `META|mode-change|warn|` event is logged when a resume's `--mode` flag differs from the recorded autonomy. (R12)
- Fix: the tmux dashboard pane spawn now checks for an existing `dashboard.py $LOG_FILE` process before splitting a new pane — resuming a pipeline no longer stacks duplicate panes. (R13)
- Test: added ~70 new tests across `test-pipeline-phases.sh`, `test-detect-resume.sh` (new), `test-spawn-helper.sh`, and `test-outcome-label-check.sh` covering every fix above.
- Chore: `marketplace.json` version synced from 0.12.11 to 0.12.13 (had drifted behind `plugin.json` and `README.md`).

## 0.9.1 (2026-06-02)

- Fix: Fleet controller `_flow_mutex_held()` now uses `flock -n` on `./logs/.ticket-flow-{tid}.lock` instead of pidfile `kill -0` on `/tmp/ticket-auto-{tid}-flow.lock` — mutex check was dead code (wrong path, wrong primitive). (F1)
- Fix: Added 6th detector `detect_flow_failures` to fleet-detect.sh — scans heartbeat logs for `retry|flow-sh|fail` entries. 1 failure → WARN, 2+ → KILL. (F4)
- Fix: `fleet_restart_pipeline` now writes `META|fleet-restart-marker` to pipeline log instead of printing `RESTART_ELIGIBLE=` to stdout. Monitor loop updated to scan for markers and emit `ACTION:spawn-restart`. (F5)
- Fix: Heartbeat category `HB` now explicitly rejected in `hb_write` with diagnostic message. Added BASH_SOURCE caller validation warning. (Bug #1)
- Fix: `spawn_agent_pre` captures pinger/watchdog PIDs; `spawn_agent_post` reaps them via PID-targeted `wait` with 5-second timeout. Added stop-file existence check before spawn to close kill-during-spawn race window. (Bug #4, F10)
- Fix: Added `-c` compact flag to intermediate `jq -n` calls in `fleet_detect_all` (entry + summary JSON). Final output remains pretty-printed. (F2)
- Fix: `_last_field` now asserts `idx < 5` — fields 5+ require `_last_msg` to preserve embedded pipe characters. (F3)
- Fix: `fleet_kill_pipeline` guards against nonexistent pipeline logs — returns 1 instead of creating orphaned log directories. (F6)
- Fix: Severity capped at 2 (KILL) when `FLEET_AUTO_RESTART=false` — dashboard labels show "KILL (auto-restart off)" instead of misleading "RESTART". (F7)
- Fix: Added `FLEET_MAX_LOG_AGE_HOURS` config (empty default = no filter) — `fleet_detect_all` skips pipeline logs whose mtime exceeds threshold. (F8)
- Fix: `fleet-intervene.sh` now sources `heartbeat.sh` at file level with declare-guard pattern — `hb_decision` audit calls no longer silently skipped. (F9)
- Cleanup: Removed duplicate `LINEAR_API_KEY` + `chmod` block in `spawn-helper.sh` `spawn_write_env`. Removed duplicate test definitions and dispatcher registrations in `test-spawn-helper.sh`.
- Test: Added 24 new tests across `test-fleet-detect.sh`, `test-fleet-intervene.sh` (new), `test-heartbeat.sh`, and `test-spawn-helper.sh`. All existing tests pass.

## 0.9.0 (2026-06-02)

- Added: Ticket Fleet Controller — automated pipeline intervention with 5 detection engines (phase failures, stalls, zombies, loops, abandonment), severity-based escalation (WARN→KILL→KILL+RESTART), dry-run mode, health dashboard (terminal + markdown report), and three invocation modes (monitor, status, intervene).
- Added: `lib/fleet-detect.sh` (~300 lines) — detection engine with `detect_phase_failures`, `detect_stalls`, `detect_zombies`, `detect_loops`, `detect_abandoned`, `fleet_detect_all` aggregator, and diagnostic context extraction.
- Added: `lib/fleet-intervene.sh` (~150 lines) — intervention library with `fleet_kill_pipeline`, `fleet_restart_pipeline`, `fleet_can_restart`, `FLEET_DRY_RUN` guard, and flow.sh mutex awareness.
- Added: `lib/fleet-dashboard.sh` (~140 lines) — dashboard renderer with `fleet_render_dashboard` (terminal) and `fleet_write_report` (markdown).
- Added: `skills/ticket-fleet-controller/SKILL.md` — fleet controller skill with monitor, status, and intervene modes.
- Added: `lib/tests/test-fleet-detect.sh` — 32 unit tests for detection engine following existing pure-bash harness pattern.
- Added: 7 `FLEET_*` configuration variables to `lib/config.sh` with safe defaults (`FLEET_AUTO_RESTART` defaults to `false`).
- Added: `spawn_fleet_kill` function to `lib/spawn-helper.sh` — unified kill primitive touching both stop files with heartbeat audit.

## 0.8.1 (2026-06-02)

- Fix: Added missing comma after `version` field in `.claude-plugin/plugin.json` — JSON parse error `Expected '}'` prevented plugin installation.

## 0.7.10 (2026-06-02)

- Fix: `check_api_key` in `lib/linear-api.sh` now walks up from `$PWD` (max 3 levels) looking for `.env` containing `LINEAR_API_KEY=` — flow.sh invoked via `bash` from SKILL.md needs a fresh shell where the key is absent; `.env` walk-up provides automatic fallback without configuration changes.
- Fix: `lib/env-check.sh` now detects `LINEAR_API_KEY` from `$PROJECT_DIR/.env` in both `full` mode (pipe-delimited output) and `validate` mode (colored output) — emits `auto|(in .env)|.env` when key is read from `.env`, mirroring the existing `TICKET_AUTONOMY` pattern.
- Fix: `spawn_write_env` in `lib/spawn-helper.sh` now auto-appends `export LINEAR_API_KEY="${LINEAR_API_KEY}"` to the generated env file when the key is available — sub-agents can now access the Linear API directly without re-sourcing `.env`.
- Test: Added 8 new tests — 5 for `check_api_key` .env walk-up (current dir, parent dir, no key, key already set, wrong key), 1 for `env-check.sh` .env detection, 2 for `spawn_write_env` key propagation (key set, key unset). All 75 tests pass.

## 0.7.9 (2026-06-02)

- Fix: Added `>/dev/null 2>&1` to `hb_pinger_start` background subshell in `lib/heartbeat.sh` — the pinger inherited stdout from `$(spawn_agent_pre ...)` command substitution, causing bash to wait for ALL pipe writers to close before completing the substitution. This produced a 4+ minute delay on every agent spawn during WIL-39.
- Fix: Wired `spawn_write_env` into orchestrator Step 0.5 of `skills/ticket-auto/SKILL.md` — sub-agents now receive project context (`REPOS_ROOT`, `ISSUE_PREFIX`, `BE_SERVICES`, etc.) via `/tmp/ticket-auto-{ID}-env.sh`. Previously the function was defined but never called, so sub-agents operated without project context.
- Feature: Added optional `sleep_secs` parameter to `spawn_watchdog_start` (default 60s) — matches `hb_pinger_start` API pattern and enables testing without 60s delays.
- Test: Added 4 new tests — `test_pinger_no_stdout_output` (heartbeat), `test_watchdog_emits_heartbeats` (spawn-helper), `test_pre_prompt_includes_env_file_path` (spawn-helper), `test_pre_completes_when_env_file_missing` (spawn-helper). Total test count: 144 → 148.
- Test: Updated `hb_pinger_start` mock comment in `test-spawn-helper.sh` to cross-reference the real stdout isolation test in `test-heartbeat.sh`.

## 0.7.8 (2026-06-02)

- Fix: Swapped PR-REVIEW and MAINTENANCE phase order so documentation is generated after code review passes, preventing stale docs when review requests changes. Updated `detect-resume.sh` step table, `pipeline-log-format.md` documentation, and report table accordingly.
- Fix: Added heartbeat `phase-transition` events at all phase boundaries (START → APPRAISE, APPRAISE → REPRODUCE, REPRODUCE → EXEC, EXEC → GATE). Skipped phases emit transitions with "(skipped)" suffix.
- Feature: Added watchdog heartbeat (`spawn_watchdog_start`/`spawn_watchdog_stop` in `spawn-helper.sh`) that emits liveness signals every 60s during agent wait loops. Integrated into `spawn_agent_pre`/`spawn_agent_post`.
- Fix: Eliminated duplicate pipeline log entries by changing agent-written maintenance entries to use distinct step name `wiki-errata` instead of `maintenance`, preventing collision with `spawn_agent_post` phase bracket.
- Fix: Added guards on `META|title` and `META|artifact` emissions — title deferred until non-empty and non-"unknown", artifact deferred until path is absolute. Title emission uses at-most-once check.
- Test: Added 15 new tests across `test-pipeline-phases.sh` and `test-spawn-helper.sh` covering phase ordering, heartbeat transitions, watchdog behavior, log dedup, and metadata deferral.

## 0.7.6 (2026-06-02)

- Fix: removed `-u` (nounset) from `linear-api.sh` — Claude Code shell snapshots inject `ZSH_VERSION` references that trigger false-positive "unbound variable" errors; stderr pollution could contaminate `linear_graphql` JSON output
- Fix: added missing `-e` flags to multi-expression `sed` in `flow.sh` label substitution (line 102–104) — second expression was interpreted as a filename, blocking `human-approve` and `appraise-start` triggers
- Fix: added `"claimed"` to `removes` array in `state-machine.json` `human-approve` trigger — `claimed` and `approved` share the same Linear label group ("Flow"), causing Linear API to reject the mutation with "labelIds not exclusive child labels"

## 0.7.5 (2026-06-02)

- Fix: `spawn-helper.sh` now sources `heartbeat.sh` at load time — `hb_*` and `cl_write` calls were silently unresolved when `HB_LOG_FILE`/`CLAUDE_LOG_FILE` were set during real pipeline runs
- Fix: corrected `get_issue` return-value documentation and error-detection patterns in `ticket-auto/SKILL.md` and `lib/skill-preamble.md` — `get_issue()` returns the unwrapped issue object, not the raw `.data.issue` response; validation check changed from `jq -e '.data.issue'` to `jq -e '.id'`; jq extraction examples and live bug-label detection code updated accordingly

## 0.6.0 (2026-05-22)

- Feat: unit test suites for all 7 lib scripts (72 tests) — `linear-api.sh`, `env-check.sh`, `notes-parse.sh`, `ticket-dir.sh`, `heartbeat.sh`, `capture-transcript.sh`, `reconcile-comments.sh` — each with a self-contained test harness using `socat` for HTTP stubbing where needed
- Feat: ShellCheck linting across all 28 project shell scripts via `make lint`
- Feat: shfmt formatting enforcement via `make fmt-check` (CI-safe diff mode) and `make fmt` (local auto-fix)
- Feat: GitHub Actions CI workflow (`.github/workflows/test.yml`) — runs lint → format check → tests on push/PR to main; fails build on any non-zero exit
- Chore: `marketplace.json` version synced from 0.4.0 to 0.6.0 (missed 0.4.1, 0.5.0, 0.5.1, 0.5.2 bumps)

## 0.5.2 (2026-05-21)

- Feat: `-claude.log` visibility layer — a third log stream (`{TICKET-ID}-claude.log`) written by the orchestrator at each phase boundary; no 60-char MSG restriction. Carries handoff context before agent spawn, verbose done data after success, and diagnostic failure context (last heartbeat event, path existence) after failure. `cl_write`/`cl_init` helpers added to `lib/heartbeat.sh`; `CLAUDE_LOG_FILE` exported to all 10 agent spawn instructions for sub-agent access.
- Feat: pipeline verify guards — ticket-appraise pre-handoff completeness gate (checks `## Complexity` Score line and `## Initial Investigation` content before handing off to exec), ticket-setup post-script workspace verify (confirms `notes.md` and `context.md` exist after setup.sh), ticket-pr-iterate post-write section check (verifies `## PR Review #N` heading landed in the artifact), ticket-retro proposal file verify (confirms proposal file written before reporting success).

## 0.5.1 (2026-05-21)

- Fix: `flow.sh`, `validate-linear-config.sh`, `detect-resume.sh`, and `setup.sh` all used `$SCRIPT_DIR/../../lib/` to source shared libraries — this path breaks when skills are installed as symlinks (resolves to the plugin cache, not `~/.claude/skills/lib/`). All four scripts now use `${CLAUDE_SKILLS_LIB:-$HOME/.claude/skills/lib}` instead, which works in both symlinked and direct-checkout layouts.
- Fix: `detect-resume.sh` now recognises `META|gate-stop|fail|EXEC_NO_ARTIFACT` in the pipeline log and maps it to `RESUME_STEP=STEP_2` (re-run EXEC), rather than silently advancing to STEP_3 as if EXEC had succeeded.
- Fix: `ticket-appraise-exec` SKILL.md — after writing `simple-fix.md`, the skill now immediately verifies the file exists on disk before logging `create-artifact|done`. The Step 3.4 coherence check now tests the actual file path instead of grepping `notes.md`, closing the gap where a blocked Write (e.g. from a PreToolUse hook) could go undetected.
- Fix: non-English output from DeepSeek models running at `max` effort — resolved by unsetting `CLAUDE_CODE_EFFORT_LEVEL` in the container config rather than adding a language guard to the skill preamble.

## 0.5.0 (2026-05-21)

- Adversarial review (Step 3.6) — spawns an adversarial agent for complex tickets that attacks the implementation plan from 7 angles (edge cases, data assumptions, error handling, security, side effects, test coverage, missing steps); blocks the pipeline on critical findings via `ADVERSARIAL_BLOCKED` gate-stop
- Project readiness (Step 0) in ticket-setup — detects project root, initializes CLAUDE.md via GitNexus/code-scan/empty-seeded paths, ensures GitNexus indexing; environment validation runs first before any external calls
- New safety gate: adversarial review blocked — pipeline halts if the adversarial agent finds blocking issues (incorrect behavior, data loss, security vulnerabilities)
- Documentation: EXEC phase steps, gate-stop codes table, safety gates count (5→6), pipeline log format

## 0.4.1 (2026-05-21)

- Token-tracker hooks — SubagentStart/Stop hooks that track per-phase token usage (input/output/cache) and wall-clock duration, appending `META|tokens` lines to the pipeline log with `elapsed_ms`
- Hooks bundled in `ticket-auto-pipeline/hooks/` and auto-installed via `plugin.json` — no manual setup required

## 0.4.0 (2026-05-20)

- REPRODUCE phase (Step 1.5) for bug tickets — reproduces the bug before implementation begins
- Interactive pipeline state diagram with full-view and phase drill-down
- Transcript capture for retrospective analysis — agent outputs persisted for post-mortem
- Heartbeat error diagnostics — captures API errors and gate-stop causes for retro enrichment
- Skill preamble deduplication — extracted shared preamble from 9 pipeline skills (290 lines removed)
- Env-check unification — dual-mode output (full pipe-delimited + colored validate) with thin wrapper
- jq error guards and flow.sh exit code handling in subskill error patterns
- RCE vector removed, dead code pruned, fragile JSON parsing replaced
- Documentation restructure: CHANGELOG, LICENSE, plugin-overview.md, per-plugin CLAUDE.md, docs/ index
- Catch-up bump: versions 0.3.17–0.3.22 were never tagged; 0.4.0 consolidates PRs #25–#30

## 0.3.16 (2026-05-20)

- PR comment reconciliation (Step 5.5) in ticket-auto pipeline
- Interactive pipeline state diagram with REPRODUCE phase
- Bug reproduction as Step 1.5 for bug tickets

## 0.3.15 (2026-05-20)

- jq error guards and flow.sh exit handling
- Loop agent failure logging
- Subskill error patterns

## 0.3.14 (2026-05-20)

- Env-check unification with dual-mode output (full + validate)
- Thin validate-env.sh wrapper delegates to env-check.sh

## 0.3.12 (2026-05-20)

- Shared skill preamble extraction — deduplicated 290 lines across 9 pipeline skills
- Parameterized agent spawn template

## 0.3.11 (2026-05-20)

- Ticket pipeline cleanup: removed RCE vector, dead code, fragile JSON
- Config centralization
- Defensive shell practices

## 0.3.10 (2026-05-20)

- Transcript capture for retro analysis
- Heartbeat error diagnostics — APPROVAL_REVOKED and VERDICT_UNPARSEABLE gate-stop enrichment
- EXEC_NO_ARTIFACT gate-stop enriched with artifact type and directory context

## 0.3.9 (2026-05-20)

- Gate comment reconciliation with code extraction
- Approval gate mechanism for complex tickets
- State machine trigger to re-add claimed label after approval in Approve state

## 0.3.7 (2026-05-19)

- Pipeline heartbeat log format (parallel stream to pipeline log)
- Heartbeat library (`lib/heartbeat.sh`) with 7 categorized helpers
- Dashboard, report, and retro consumers for heartbeat data

## 0.3.6 (2026-05-18)

- Log improvements: heartbeat log for full pipeline traceability
- Documented heartbeat log format in README

## 0.3.5 (2026-05-18)

- Fixed env-check.sh resolution to prefer plugin cache over synced lib
- Auto-discovery offer for missing/warn env values
- Row-count validation to prevent silent table truncation

## 0.3.4 (2026-05-18)

- Pipe-delimited table output for env-check
- Backtick-wrapped CLAUDE.md value handling
- `--show` flag for raw findings table with resolved env var values

## 0.3.2 (2026-05-17)

- `--summary-file` flag writes findings to file, skill displays verbatim
- Read-only env-check skill (no auto-writes)
- Structured output in env-check.sh for deterministic parsing

## 0.3.1 (2026-05-17)

- Simplified env-check to task-per-variable checklist
- Conversational /ticket-env-check with guided remediation

## 0.3.0 (2026-05-17)

- Removed UAT_URL git remote derivation
- Upgraded LOCAL_URL/UAT_URL to required with env var checks
- Replaced brittle REPOS_ROOT sed derivation with filesystem walk
- Removed project-specific hardcodes from validate-env.sh

## 0.2.4 (2026-05-17)

- Simplified /ticket-env-check output with auto-derived proposals

## 0.2.3 (2026-05-17)

- Simplified /ticket-env-check output
- Fixed env-check paths for plugin cache resolution

## 0.2.2 (2026-05-17)

- Added SessionStart hook to sync lib scripts
- Fallback path resolution for /ticket-env-check

## 0.2.1 (2026-05-17)

- Version bump with path corrections

## 0.2.0 (2026-05-16)

- Marketplace README and CLAUDE.md
- `linear-api.sh` script fallback for container pipeline runs
- `/ticket-env-check` slash command
- Corrected marketplace add command

## 0.1.0 (2026-05-15)

- Initial ticket-auto-pipeline plugin
- Core pipeline skills: ticket-auto, ticket-appraise, ticket-implement, ticket-verify, ticket-pr-review
- State machine (`state-machine.json`) with flow.sh executor
- Pipeline log format for crash recovery
- Shared bash libraries
