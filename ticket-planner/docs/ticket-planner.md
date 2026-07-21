# Ticket Planner — Architecture and Reference

The ticket-planner is the autonomous planning layer that sits upstream of `ticket-auto` and `fleet-controller`. It turns business ideas into dependency-ordered planned tickets the existing pipeline consumes without special-casing.

## Architecture

```
User idea → [ticket-planner] → Linear initiative + epic + planned tickets
                                    ↓
                              [fleet-controller dispatch] → spawn queue
                                    ↓
                              [ticket-auto] → implement → verify → merge
                                    ↓
                              [fleet-feedback] → aggregated feedback JSON
                                    ↓
                        (Regenerate flag) → [ticket-planner re-plan]
```

The planner is a separate plugin from `ticket-auto-pipeline` and `fleet-controller` — same precedent as fleet-controller's extraction. It has its own version, release cadence, and marketplace entry. Planner churn cannot destabilize ticket execution.

## Operator-Facing Flow

### Starting a planning run

```
/ticket-planner plan "Add real-time collaboration to the document editor"
```

The planner initializes a state directory under `${REPOS_ROOT}/.ticket-auto/initiatives/{ID}/`, writes the idea to the state log, and begins the 12-phase state machine. Each phase runs as an isolated Claude agent. The router advances sequentially through phases with no inline reasoning between them.

### What auto-dispatch does

When the Execution phase completes, the initiative epic receives the `state:execution` label. The fleet-controller detector `_fleet_scan_initiative_dispatch` finds it during its next poll cycle and — when `FLEET_AUTO_DISPATCH=true` — calls `fleet_dispatch_initiative`, which:

1. Validates the epic has `state:execution`
2. Enumerates child tickets with `planned` label in `Backlog` state
3. Resolves `blocked-by:{ID}` dependencies (skips blocked tickets)
4. Writes spawn queue entries under `flock` serialization
5. Respects `FLEET_MAX_CONCURRENT` and `FLEET_DRY_RUN`

The spawn queue is consumed by `fleetd` (the Python supervisor daemon), which forks workers running `ticket-auto {TID} --auto --from-planned`.

### What the approval gate still holds

**Auto-dispatch automates dispatch — it does not automate approval.** Every auto-dispatched ticket still stops at the human approval gate. This is a deliberate design decision, not an oversight:

- Dispatch decides *which* tickets enter the pipeline. Automating this removes a mechanical step a human adds no judgement to.
- Approval decides *whether* a ticket's plan is acted on. Automating this would remove the only place a human sees the plan before code is written, on a system that spends money per ticket.

The `planned-entry-gate` capability (confidence ≥ 0.85 + `pre-approved` → bypass human gate) is specified but deliberately unimplemented. See [Planned-Entry Gate Dormancy](#planned-entry-gate-dormancy) below.

### Resuming after interruption

```
/ticket-planner resume INIT-42
```

The router reads the state log, finds the last incomplete phase, and resumes from there. Completed phases are skipped. Entity-creating phases are idempotent — a crash between intent and creation produces exactly one entity on resume.

### Checking status

```
/ticket-planner status INIT-42
```

Shows the current phase, initiative metadata, and the last few state log entries.

## State Machine

12 phases, strictly linear. Each phase runs as an isolated Claude agent. The router is bash — it reads the state log, derives position, and dispatches phases. It performs no reasoning of its own.

```
Appraisal → Discovery → Architecture → Proposal → Review → Consensus →
OpenSpec → EpicGen → StoryGen → TicketGen → Execution → Completed
```

### Phase Details

| # | Phase | Agent role | Output | Deterministic gates |
|---|-------|-----------|--------|---------------------|
| 1 | **Appraisal** | Interprets the business idea, establishes initiative scope, identifies affected repositories | Scope summary, repo list | — |
| 2 | **Discovery** | Explores affected repos, traces code paths, gathers context on symbols and APIs | Code paths, symbol references, API contracts | — |
| 3 | **Architecture** | Determines technical approach, evaluates alternatives | Architecture decision record | — |
| 4 | **Proposal** | Produces the full initiative proposal artifact | `proposal.md` in artifact plane | — |
| 5 | **Review** | Critiques the proposal for gaps, risks, and feasibility | Review findings | Configurable hold (`PLANNER_REVIEW_HOLD`) |
| 6 | **Consensus** | Resolves review findings into a settled, actionable plan | Finalized proposal | Configurable hold (`PLANNER_CONSENSUS_HOLD`) |
| 7 | **OpenSpec** | Emits specification artifacts the generation phases consume | Spec documents in artifact plane | — |
| 8 | **Epic Gen** | Creates the initiative epic in Linear with `state:execution` and `INIT-{id}` labels | Linear epic | Idempotency: records intent before creation, checks existence by initiative ID |
| 9 | **Story Gen** | Generates story descriptions from specs | Story descriptions | May collapse into Ticket Gen if stories are always 1:1 with tickets |
| 10 | **Ticket Gen** | Creates planned child tickets in Backlog with full labels and Planner Context blocks | Linear tickets | `planner-deps-check.sh` (acyclicity), `planner-context-gen.sh` (block format), `planned-ticket-check.sh` (validation before creation) |
| 11 | **Execution** | Labels the epic for execution, hands off to fleet auto-dispatch | `state:execution` label on epic | `FLEET_AUTO_DISPATCH` flag gates actuation |
| 12 | **Completed** | Terminal phase — no further transitions permitted | Completed state log entry | Phase transition validator rejects any transition from Completed |

### Failure handling

If a phase fails (`fail` status in state log), the router halts. The operator can:
- Re-run the phase by triggering resume (phases are idempotent)
- Manually intervene and skip the phase by writing `skip` to the state log
- Abandon the initiative

Max retries per phase: `PLANNER_MAX_PHASE_RETRIES` (default 2).

## State Representation

State lives in an append-only pipe-delimited log at `${REPOS_ROOT}/.ticket-auto/initiatives/{ID}/state.log`. Format:

```
ISO|PHASE|STEP|STATUS|MSG
```

Schema version `1` declared as the first line. The router re-derives position by reading the log — no state held in memory between invocations.

### State Directory Layout

```
${REPOS_ROOT}/.ticket-auto/initiatives/{INITIATIVE_ID}/
  state.log           # Append-only phase transition log
  .intents/           # Idempotency intent files (one JSON per entity)
    epic-main.json
    ticket-1.json
  artifacts/          # Per-phase artifacts (proposal.md, specs/, etc.)
  feedback/           # Feedback aggregation (written by fleet-feedback.sh)
    2026-07-21.json
```

## Resume Semantics

1. Read the state log in reverse (`tac`).
2. Find the last phase with a terminal entry (`done`, `fail`, `skip`).
3. Check if a `start` entry exists after the last completed phase (crash mid-phase).
4. If crashed mid-phase, resume at that phase (every phase is idempotent).
5. If no crash detected, advance to the next phase after the last completed.
6. If the last completed phase is `Completed`, the run is done (empty string returned).

Partial trailing writes (crash mid-write) are ignored — `cut -d'|'` cannot parse incomplete lines, so position derivation correctly falls through to the last valid `done` entry.

## Idempotency

Every entity-creating phase (EpicGen, StoryGen, TicketGen) follows a three-step pattern:

1. **Record intent** — `planner_record_intent` writes a JSON file to `.intents/{entity_key}.json` with status `"intent"`. Call BEFORE the Linear API call. Idempotent: if intent already exists, this is a no-op.
2. **Check existence** — `planner_entity_exists` checks if the intent file has status `"created"`. If so, the entity was already created — skip the API call.
3. **Mark created** — `planner_entity_mark_created` writes the Linear ID and sets status `"created"`. Call AFTER a successful Linear API call.

A crash between step 1 and step 3 produces exactly one entity on resume: the intent file exists with status `"intent"`, `planner_entity_exists` returns false, and the phase re-executes the API call. The deterministic entity key prevents duplicates.

## Contracts

The planner produces against four frozen consumption-side contracts. These are specified in earlier OpenSpec changes and are not re-specified here.

### 1. Planner Context Block

`## Planner Context` markdown block in ticket descriptions. Schema-Version 1 with 11 fields:

| Field | Type | Description |
|-------|------|-------------|
| Schema-Version | integer | Schema version (currently 1) |
| Initiative | string | Initiative identifier (e.g., `INIT-42`) |
| Epic | string | Parent epic identifier |
| Confidence | float (0.0-1.0) | Planner's confidence in correctness |
| Strategy | enum | Conservative / Balanced / Innovative |
| Decision | string | One-sentence architectural decision |
| Affected Services | CSV | Comma-separated service names |
| Target Symbols | semicolon-list | `symbol:file:line` references |
| Pre-approved | boolean | Ready for accelerated appraisal |
| Generated | ISO 8601 | When the context was created |
| Regenerate | boolean | Whether re-planning is recommended |

**Validator:** `planned-ticket-check.sh` (exit 0 = valid, 1 = malformed, 2 = low confidence + not pre-approved).

**Generator:** `planner-context-gen.sh` — takes structured JSON, validates all fields, emits formatted markdown. Generate against the validator, not the schema document.

### 2. Labels

| Label | Pattern | Set by | Lifecycle |
|-------|---------|--------|-----------|
| `planned` | exact | Ticket Gen | Once set, never removed. Provenance marker. |
| `INIT-*` | wildcard | Ticket Gen | Links ticket to initiative. Never removed. |
| `pre-approved` | exact | Ticket Gen (when confidence ≥ 0.85) | Accelerates fast-path. Removed by `human-reject`. |
| `blocked-by:*` | wildcard | Ticket Gen | Dependency enforcement. Auto-removed when blocker reaches Done. |
| `state:execution` | exact | Epic Gen (on epic) | Marks initiative ready for dispatch. |
| `Type` labels | exact | Ticket Gen | `bug`/`feature`/`improvement`/`security`/`chore`. Drives template selection. |

### 3. Artifact Plane

`planner-artifacts.sh` resolves per-ticket artifact directories from the Planner Context block's Initiative field. Path: `${REPOS_ROOT}/.ticket-auto/initiatives/{INIT}/tickets/{TID}/planner/`.

Per-initiative artifacts (proposal, specs) live under `${REPOS_ROOT}/.ticket-auto/initiatives/{INIT}/artifacts/`.

### 4. Feedback

`fleet-feedback.sh` aggregates `META|planner-feedback` entries from pipeline logs, grouped by initiative ID. `planned-feedback-write.sh` (post-implement hook in ticket-auto) emits these entries.

Feedback payload:
```json
{
  "confidence_predicted": 0.85,
  "confidence_actual": 0.70,
  "outcome": "Rough",
  "corrections_count": 2,
  "files_changed": ["src/auth.ts"],
  "services_touched": ["auth"],
  "decision_drift": "minor"
}
```

Aggregated to `${REPOS_ROOT}/.ticket-auto/initiatives/{ID}/feedback/{rundate}.json` with summary statistics (total tickets, avg confidence, drift count, services touched).

## Confidence Derivation

Confidence is derived from five concrete signals — never a uniform constant. A planner that emits uniformly high confidence would silently disable the investigation that catches its own mistakes.

| Signal | Effect | Rationale |
|--------|--------|-----------|
| Services identified | +5 per service (max +20) | More services traced → higher confidence in scope understanding |
| Symbols resolved | +3 per symbol (max +15) | More symbols with confirmed file:line → higher confidence in code understanding |
| Prior art found | +10 if true | Similar patterns in codebase → higher confidence in approach |
| Exploration depth | +5 standard, +10 deep | Deeper exploration → more evidence |
| Complexity | -15 complex, +5 simple | Complex tickets have more unknown unknowns |

Score clamped to 0.05–0.95. `planner_confidence_derive` in `planner-context-gen.sh` implements this.

## Dependency Validation

Dependencies are expressed as `blocked-by:{ID}` labels. `planner-deps-check.sh` validates that:

1. The dependency set forms a DAG (no cycles). Uses `tsort` for cycle detection.
2. All `blocked-by` targets exist in the ticket set (no dangling references).
3. Topological sort determines dispatch order.

A cyclic dependency set produces no tickets — the error is reported before any Linear API call.

## Auto-Dispatch

When the Execution phase completes, the initiative epic gets `state:execution`. The fleet-controller detector `_fleet_scan_initiative_dispatch` finds it during its next poll cycle.

**Gating:** `FLEET_AUTO_DISPATCH=true` must be set. When false (default), the detector reports undispatched initiatives at severity 1 (WARN) but does not actuate. This allows observe-only operation during rollout.

**Idempotency:** `fleet_dispatch_initiative` checks the spawn queue for already-queued entries before enqueuing. Re-running dispatch does not duplicate entries.

**Concurrency:** `FLEET_MAX_CONCURRENT` caps active pipelines. `FLEET_DRY_RUN` makes dispatch no-op for preview.

## Re-Planning

When an initiative carries the `Regenerate` flag (set to `true` in the Planner Context block), the planner:

1. Reads aggregated feedback JSONs from `{initiative_dir}/feedback/`.
2. Computes confidence drift from predicted vs actual outcomes.
3. Regenerates tickets still in `Backlog` and not present in the spawn queue.
4. Dispatched, in-progress, and completed tickets are left unchanged and reported as such.
5. Validates the regenerated dependency set remains acyclic.

**Regenerate is an explicit flag, not a default.** Reading feedback on every re-plan would make planner output depend on execution history in ways that are hard to reason about. Requiring the flag makes feedback ingestion a deliberate act with a visible trigger.

## Determinism Boundary

| Bash (deterministic) | Agent (LLM) |
|---------------------|-------------|
| State log parsing and position derivation | Per-phase content reasoning |
| Phase transition validation | Appraisal scope decisions |
| Entity idempotency (intent→check→create) | Discovery code path selection |
| Dependency acyclicity (`tsort`) | Architecture approach evaluation |
| Planner Context block generation | Proposal and spec authoring |
| Confidence signal derivation | Review critique generation |
| Pre-creation validation (`planned-ticket-check.sh`) | Ticket body content |
| Auto-dispatch detection and enqueuing | Re-planning decisions |

The router never reasons about content. Phases never mutate state directly (they write log entries the router reads).

## Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `PLANNER_REVIEW_HOLD` | false | When `true`, Review phase pauses for human input |
| `PLANNER_CONSENSUS_HOLD` | false | When `true`, Consensus phase pauses for human input |
| `PLANNER_MAX_PHASE_RETRIES` | 2 | Max retries per phase before failing the run |
| `PLANNER_CONFIDENCE_THRESHOLD` | 0.5 | Minimum confidence for valid ticket (used by `planned-ticket-check.sh`) |
| `FLEET_AUTO_DISPATCH` | false | Must be `true` to enable automatic dispatch from detection |
| `FLEET_MAX_CONCURRENT` | 3 | Max concurrent pipelines for dispatch |
| `FLEET_DRY_RUN` | false | When `true`, dispatch is preview-only |

## Planned-Entry Gate Dormancy

The `planned-entry-gate` capability is specified in `ticket-planner-enrichment` but deliberately unimplemented. It would allow confidence ≥ 0.85 plus `pre-approved` to bypass the human approval gate.

**Why it stays dormant:**

1. **Dispatch and approval are independent controls.** Automating dispatch removes a mechanical step; automating approval removes the only point where a human sees the plan before code is written.
2. **The system spends real money per ticket.** A bad auto-approved plan fans out into many expensive workers.
3. **Confidence calibration is unproven.** The feedback loop has never received real input (the feedback writer just shipped). Until confidence drift is measured across multiple completed initiatives, self-assessed confidence is not trustworthy enough to gate on.

**What would have to be true to revisit this decision:**

1. Confidence drift is measured across ≥ 10 completed initiatives with real feedback data.
2. Drift is consistently ≤ 0.10 (minor or none) for tickets with confidence ≥ 0.85.
3. No auto-approved ticket has produced a production incident or required emergency rollback.
4. The operator explicitly opts in — auto-approval is never the default.

Even then, auto-approval should be a per-initiative flag (`--auto-approve`), not a global setting. The cost of a false positive (bad code merged) vastly exceeds the cost of a false negative (human reviews a good plan).

The capability is left specified rather than removed so the design rationale is preserved. Removing it would invite someone to re-specify it without understanding why it was deferred.

## Future Enhancements

See `ticket-planner-implementation.md` in the repo root for the full candidate list:

- **Constitution / immutable-rules primitive** — per-initiative `constitution.md` validated at the entry gate
- **EARS notation for acceptance criteria** — deterministically-checkable AC shape
- **Critique-refine loop in planning phases** — iterate the proposal in Review→Consensus, not just pass/fail
- **Per-initiative dependency graph visualization** — surfaced in the dexter dashboard Initiatives tab
