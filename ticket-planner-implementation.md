# Ticket-Planner Implementation Sequence

> Cross-session tracker for the ticket-planner openspec program.
> Last updated: 2026-07-21 (reconciled against filesystem — filesystem is authoritative)

## Overview

The ticket-planner integration is a **7-part program** (7.5 counting `ticket-planner-templates`)
of openspec changes that wires an external `ticket-planner` into the existing `ticket-auto`
pipeline and `fleet-controller`. Parts build on each other; the determinism boundary (bash
orchestration vs. LLM work) is preserved throughout.

**ticket-planner is an external system this repo does not own** — these changes integrate with
it, they don't implement it. Per `ticket-planner-integration/proposal.md`, its internal state
machine has 12 phases:

```
Appraisal → Discovery → Architecture → Proposal → Review → Consensus →
OpenSpec → Epic Gen → Story Gen → Ticket Gen → Execution → Completed
```

Only 2 of the 12 phases have real spec depth on our side — the rest are named handoff points
`ticket-planner-integration` must map onto ticket-auto's own states, not phases we control:
- **Discovery** — depth tiers (quick-scan/standard/deep) specified by `ticket-planner-exploration`
- **Ticket Gen** — output contract specified by `ticket-planner-enrichment` (metadata) +
  `ticket-planner-templates` (body content, this session's addition)

Core contract introduced in Part 2: the `## Planner Context` block in a Linear ticket +
the `planned` / `pre-approved` labels. Everything downstream reads that block.

## Status board

| Part | Change | Status | Tasks | Role |
|------|--------|--------|-------|------|
| 1 | `fleet-controller-extraction`   | ✅ archived | —      | Extracted fleet-controller to its own plugin |
| 2 | `ticket-planner-enrichment`     | ✅ archived | —      | Defined `## Planner Context` block + `planned`/`pre-approved` labels |
| 3 | `ticket-appraise-fast-path`     | ✅ archived | 32/32  | ticket-auto *acts* on planner metadata (merged PR #82) |
| 3.5 | `ticket-planner-templates`    | ✅ merged (PR #89) | 45/45  | ticket body contract + template selection — closes the body/template gap |
| — | `fleetd-supervisor-daemon`      | ✅ merged (PR #104) | 58/58  | Python supervisor daemon — groups 2-11 all shipped. Owns worker lifecycle (real PIDs), kill escalation, crash recovery, generation fencing, CLI alignment. Required for headless spawn. |
| 4 | `fleet-controller-dispatch`     | ◉ PARTIAL  | fleet side done | fleet-dispatch.sh (277L), fleet-detect.sh detectors, fleet-monitor.sh spawn queue, tests all shipped. **Missing:** `--from-planned` flag on ticket-auto, `blocked-by-check.sh` standalone script. Detection is observe-only (warns, does not call `fleet_dispatch_initiative`). |
| 5 | `ticket-planner-feedback-loop`  | ◉ PARTIAL  | aggregation done | fleet-feedback.sh (276L) + tests shipped. **Missing:** feedback writer — nothing in ticket-auto emits `META\|planner-feedback` lines. Feedback loop has zero input. |
| 6 | `ticket-planner-exploration`    | ◉ TODO     | 0/43   | Discovery-phase depth tiers (EXTENDS parts 3 & 5 — do after them) |
| 7 | `ticket-planner-integration`    | ◉ TODO     | 0/31   | wiring + rollout sequencing + full determinism audit (ALWAYS LAST) |

## Remaining work (reconciled 2026-07-21)

The three gaps below are Part 4 + Part 5 leftovers that the `ticket-planner-plugin`
OpenSpec change (groups 2 and 3) closes. They are not separate parts — they're the
planner plugin's integration work.

### Gap A: `--from-planned` flag on ticket-auto (Part 4 leftover)
- `fleetd/supervisor.py:823` already spawns workers with `--from-planned`.
- `ticket-auto-pipeline` has no handler for this flag — it's silently ignored.
- Add flag parsing to the ticket-auto skill/router so a dispatched worker knows it
  came from a planner dispatch (vs. inferring from the `planned` label alone).

### Gap B: Feedback writer (Part 5 leftover)
- `fleet-feedback.sh` (276L) aggregates `META|planner-feedback` pipeline log entries.
- Nothing in ticket-auto-pipeline emits these entries — the aggregation engine has
  zero input.
- Implement `planned-feedback-write.sh`: post-implement hook writing decision drift,
  confidence_actual, files changed, services touched, corrections. Conditional on
  `planned` label.

### Gap C: Detection → dispatch actuation (Part 4 leftover)
- `_fleet_scan_initiative_dispatch` (fleet-detect.sh:547) detects undispatched
  initiatives but only warns (severity 1). `fleet_dispatch_initiative` is fully
  implemented and callable — nothing calls it automatically.
- Wire the detector to invoke dispatch (not just warn) when undispatched children
  are found. Respect `FLEET_MAX_CONCURRENT` and `FLEET_DRY_RUN`.

### `blocked-by-check.sh` — deliberately not a gap
- The Part 4 proposal specified a standalone `blocked-by-check.sh`. This was never
  created, but its logic lives inside `fleet-dispatch.sh:142-160` (dispatch-time
  resolution) and `fleet-detect.sh:465` (detection). Functionality exists; a
  separate file isn't needed unless the logic grows.

### `fleetd-supervisor-daemon` — complete
- All 11 groups (58 tasks) shipped and merged (PR #104, commit `fe3ce5d`).
- Headless spawn works. The daemon owns worker lifecycle with real PIDs.
- This unblocks the ticket-planner-plugin's end-to-end verification (group 9).

### 6. ticket-planner-exploration (43 tasks) — unchanged, still TODO
- Defines how openspec-explore integrates into the Discovery phase.
- 3 depth tiers: quick-scan / standard / deep.
- MODIFIES existing schemas — goes late to avoid churn.

### 7. ticket-planner-integration (31 tasks) — unchanged, still TODO, ALWAYS LAST
- No new code. Ties everything together:
  - State-machine alignment: planner states → ticket-auto states.
  - 4-phase rollout sequencing with gating criteria + rollback.
  - End-to-end integration tests (planner creates ticket → fleet dispatches →
    ticket-auto executes → feedback aggregates → planner learns).
  - Full-system determinism audit across all changes — classify every LLM-dependent path
    as "appropriate" or "bash-migration candidate".
  - Cross-plugin reference updates (fleet-controller, ticket-auto-pipeline, marketplace.json).

## Candidate enhancements (web scan 2026-07-09)

Our 12 planner phases align with the field's SDD spine (Kiro Requirements→Design→Tasks; Spec Kit
Specify→Plan→Tasks→Implement) and we already **exceed** it on two axes the literature wants but shipped tools
lack: a discrete **Consensus** phase and the full **initiative→epic→story→ticket** Gen cascade. Four gaps the
field recommends that we don't yet have. Not yet scoped into any Part — evaluate and slot when relevant.

1. **Constitution / immutable-rules primitive (clearest gap).** Both Spec Kit and Kiro center on a
   "constitution" file — high-level immutable principles applied to every change so the AI can't quietly drop
   standards. We have `state-machine.json` (mechanics) + CLAUDE.md (guidance) but no per-initiative constitution
   the planner phases must honor and the gate can check. Candidate: `initiatives/{INIT}/constitution.md` on the
   artifact plane defined in `ticket-planner-templates`, validated at the entry gate the same way we validate
   the body. Fits the determinism ethos — a constitution is deterministically checkable.
2. **EARS notation for acceptance criteria.** Kiro generates ACs in EARS (Easy Approach to Requirements Syntax)
   for edge-case coverage. Our `planned-ticket-body-check.sh` (`ticket-planner-templates`) validates AC
   presence/structure but not form/quality. EARS is a deterministically-checkable AC shape — natural upgrade
   target for the body-check validator, fits "validate, don't synthesize" (planner writes EARS, we assert form).
3. **Critique-refine loop in the planning phases, not just pre-implement.** Literature: robust planners
   enumerate alternatives and run critique-refine loops to repair omissions. Our `ticket-critique` is
   execution-side (pre-implement). Confirm the **Review → Consensus** phases run a critique-*refine* loop
   (iterate the proposal), not just pass/fail. If pass/fail only, that's the enhancement.
4. **Keep + market the traceable handoff chain.** BMAD-METHOD's headline is a traceable chain from requirements
   through delivery via file-based handoffs — exactly our artifact plane + Planner Context contract (validation
   we're on the right architecture). Our feedback loop (Part 5) extends the chain *past* delivery back to the
   planner — further than BMAD. Preserve this property as phases are wired; it's a differentiator.

Counterpoint to hold in mind (GSD philosophy): "complexity should live in the system, not the workflow." 12
phases is a lot. Each phase boundary must earn its place as a determinism/checkpoint gate — if a phase has no
gate behind it, it's ceremony. See [[planner-competitive-landscape]] memory for full landscape + sources.

## ticket-auto candidate gates (web scan 2026-07-09)

> Scope: these are **ticket-auto** (execution pipeline) quality/safety gates — separate from the ticket-planner
> program above. Recorded here as the shared working tracker; move to a dedicated ticket-auto tracker or
> `plugin-overview.md` if this list grows. Web comparison found our *process discipline* (determinism,
> checkpointing, independent PR review, critique, retro) is ahead of most public pipelines, but we're behind on
> **gates on the output itself** — security, coverage, post-merge safety. All three are the deterministic-bash-gate
> shape we're already good at. Full landscape + sources in [[planner-competitive-landscape]] memory.

Our phases: `APPRAISE → EXEC → GATE → IMPLEMENT → VERIFY → PR-REVIEW → MAINTENANCE`. Field spine adds a
**monitor/rollback** beat after merge that we lack entirely.

1. **Security-scan gate — P0, highest ROI, best fit.** Field calls this "the highest-value check for AI PRs"
   (agents reproduce insecure training-data patterns). We only have `personas/base/security.md` (advisory LLM
   guidance), no blocking scan. Add `lib/security-scan.sh` running Gitleaks (secrets) + Semgrep
   (injection/`eval()`/SQL-concat) on the diff during IMPLEMENT or pre-PR → new gate-stop `SECURITY_SCAN_FAILED`.
   Persona stays the reasoning layer, lib becomes the enforcement layer (same split as `template-select.sh`).
2. **Diff-line coverage gate — P0.** We run `make test` (pass/fail) but don't measure changed-line coverage.
   Field: gate on *changed lines*, not repo-wide %; fail if the diff lowers coverage. Deterministic, cheap →
   `COVERAGE_REGRESSION` gate-stop. Closes the "fluent but untested" hole.
3. **Post-merge safety phase — P1, biggest phase-level gap.** Zero rollback/revert/canary/monitor today; our
   pipeline ends at merge. Minimal: post-merge verify + auto-revert trigger if the merged change breaks
   build/smoke. This is where the field is investing most ("40% of enterprises embedding rollback triggers in
   CI/CD by 2026").
4. **Token/cost budget gate — P1.** We *track* tokens (token-tracker hook) but don't *enforce* a ceiling. Add a
   budget ceiling that halts a ticket burning abnormal tokens — a cost sibling to fleet-controller's loop
   detection. Ties into [[ticket-auto-observability]].
5. **Human-readable PR summary before merge — P2.** Symphony pattern: agent posts "what changed and why" so a
   10-sec human skim catches obvious failures. `ticket-document` writes AI-context, not a human PR summary. Cheap
   even in full-auto — it's the artifact a human reads when spot-checking.

## Future direction: the Operate layer (third pillar) — web scan 2026-07-09

> Strategic note, not scoped work. Spans both systems. Full landscape + sources in
> [[operate-layer-third-pillar]] memory.

**The ring, not the line.** ticket-planner (Plan) → ticket-auto (Build) → **[Operate]** → back to Plan.
The post-build space the field calls **AIOps / AI SRE / Agentic SRE** (AWS DevOps Agent + Azure SRE Agent both
GA March 2026; market $14.6B→$36B by 2030) is a **layer, not a phase** — it's continuous and event-driven
(fires on telemetry/incidents), so it can't be sequenced as "step 8 after MAINTENANCE." It has its own internal
6-stage pipeline (`detect → correlate → investigate → remediate → verify → learn`) — a whole third system
parallel to ticket-auto, not a step inside it.

**Opinion: do NOT build an AIOps platform** — that category has GA'd incumbents with telemetry/anomaly ML we
can't match; competing there is off-mission. Instead own the **two seams** where our moat (determinism boundary
+ planner) is the differentiator:

1. **Downward seam = a real phase inside ticket-auto** — the P1 "post-merge safety" gate above (deploy-verify +
   bounded auto-revert). Verifying *our own deploy* is legitimately a ticket-auto phase; small, ours.
2. **Upward seam = the layer's real value** — "incident → validated remediation ticket." *Consume* an
   incumbent's detection (Datadog/AWS/Azure webhook or raw logs); own the path that turns a production signal
   into an **appraised, planner-shaped ticket** re-entering ticket-planner. Extends the Part 5 feedback ring one
   hop: auto → production → planner. Our edge is the disciplined "turn incident into gated remediation," not the
   detection.

**Differentiation wedge:** the field reports *"cascading service degradation from over-eager auto-remediators"*
and that *"governance must be strongest at the remediation boundary"* — that IS our determinism boundary,
verbatim. The AIOps space is discovering the discipline we already built.

**Guardrail:** production remediation is higher-stakes than PR merges. Start **read-only** (incident → ticket,
human dispatches) before ever auto-remediating. Earn autonomy the way ticket-auto did. Field's remediation
tiering (routine / familiar-with-ambiguity / novel-needs-human) maps onto our complexity gating.

## Notes / gotchas

- **Tracker reconciled 2026-07-21:** Parts 4 and 5 were marked TODO with 0 tasks but
  fleet-side code shipped 2026-07-15 (PR #96 + PR #104). Three gaps remain — see
  "Remaining work" section above. The `ticket-planner-plugin` openspec change closes
  all three in groups 2 and 3. Filesystem is authoritative where it disagrees with
  this tracker.
- **Part 3 was merged before its openspec change was archived.** PR #82
  (`feat(appraise): add fast-path…`, commit 476290f) landed `lib/appraise-fast-path.sh`
  (304 lines), `SKILL.md` Step 3a, and 444 lines of tests. Tasks were reconciled and the
  change archived on 2026-07-08 without re-implementing. Watch for the same pattern on
  future parts — check `git log` before starting.
- **`gate-check.sh --mode planned-entry` was never actually shipped.** The `planned-entry-gate`
  spec (archived under `ticket-planner-enrichment`) describes a confidence-based auto-approve
  mode (`--mode planned-entry`) that reads `pre-approved` + confidence to skip the human
  approval gate. Verified 2026-07-09: `gate-check.sh` only accepts `--mode <entry|reapprove>` —
  that third mode doesn't exist. What actually runs is Check 2.7 inside `--mode entry`, which is
  explicitly commented "Phase 1 — passive, observe-only... Does NOT change gate behavior." So
  `pre-approved` today only accelerates `ticket-appraise` fast-path eligibility — it does not
  bypass the approval gate as the original spec claimed. Corrected in `ticket-planner-templates`'s
  `planner-labels` delta spec. If a future part is tempted to build the dormant `planned-entry`
  mode for real, first decide deliberately whether that's still wanted — it was never flagged as
  abandoned, just never wired up.
- **Version bump per branch/PR**: each new branch must bump the plugin version for
  marketplace update detection.
- **Pre-PR checklist**: `make lint && make fmt-check && make test` before any PR.
- **Commits**: conventional commits, NO `Co-Authored-By` trailer (auto-mode Content
  Integrity classifier blocks it).

## claude-mem anchors
- Obs #5966, #5967 (2026-07-08): architecture + sequence discovery.
