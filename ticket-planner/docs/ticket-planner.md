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

The planner initializes a state directory under `${REPOS_ROOT}/.ticket-auto/initiatives/{ID}/`, writes the idea to the state log, and begins the 9-phase state machine. Each phase runs as an isolated Claude agent. The router advances sequentially through phases with no inline reasoning between them.

### What auto-dispatch does

When the TicketGen phase completes successfully, the initiative epic receives the `state:execution` label. The fleet-controller detector `_fleet_scan_initiative_dispatch` finds it during its next poll cycle and — when `FLEET_AUTO_DISPATCH=true` — calls `fleet_dispatch_initiative`, which:

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

9 phases, strictly linear. Each phase runs as an isolated Claude agent. The router is bash — it reads the state log, derives position, and dispatches phases. It performs no reasoning of its own.

```
Appraisal → Discovery → Architecture → Specify → Review → Consensus →
EpicGen → TicketGen → Completed
```

### Phase Details

| # | Phase | Agent role | Output | Deterministic gates |
|---|-------|-----------|--------|---------------------|
| 1 | **Appraisal** | Interprets the business idea, establishes initiative scope, identifies affected repositories | Scope summary, repo list | — |
| 2 | **Discovery** | Explores affected repos, traces code paths, gathers context on symbols and APIs | Code paths, symbol references, API contracts | — |
| 3 | **Architecture** | Determines technical approach, evaluates alternatives | Architecture decision record | — |
| 4 | **Specify** | Synthesizes proposal + writes per-ticket spec files with signals in a single pass | `proposal.md`, spec files in `artifacts/specs/` | — |
| 5 | **Review** | Critiques the proposal for gaps, risks, and feasibility | Review findings | — |
| 6 | **Consensus** | Resolves review findings into a settled, actionable plan | Finalized proposal | — |
| 7 | **EpicGen** | Creates the initiative epic in Linear | Linear epic with `INIT-{id}` and `epic` labels | Idempotency: records intent before creation, checks existence by initiative ID |
| 8 | **TicketGen** | Creates planned child tickets in Backlog with full labels and Planner Context blocks, validates dependency DAG, sets `state:execution` on epic | Linear tickets, `state:execution` label on epic | `planner-deps-check.sh` (acyclicity), `planner-context-gen.sh` (block format), `planned-ticket-check.sh` (validation before creation) |
| 9 | **Completed** | Terminal phase — writes completion summary, no further transitions permitted | Completed state log entry, `COMPLETED.md` | Phase transition validator rejects any transition from Completed |

**Phase merge notes:** The original 12-phase design separated Proposal, OpenSpec, StoryGen, and Execution as standalone phases. These were merged into Specify (Proposal + OpenSpec) and TicketGen (StoryGen + Execution labelling) to reduce phase count from 12 to 9. The merged phases handle all the same work — no capability was removed.

### Failure handling

If a phase fails (`fail` status in state log), the router halts. The operator can:
- Re-run the phase by triggering resume (phases are idempotent)
- Manually intervene and skip the phase by writing `skip` to the state log
- Abandon the initiative

Max retries per phase: retry on `fail` or crash (phases are idempotent, so re-running is safe). `PLANNER_MAX_PHASE_RETRIES` (default 2) bounds this. The count is derived by `planner_phase_retries_exhausted` from `fail` entries in the state log rather than held in memory, so the budget survives a crashed router the same way position does.

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
  .intents/           # Idempotency intent files — created lazily on first intent write
    epic-main.json
    ticket-1.json
  artifacts/          # Per-phase artifacts (proposal.md, specs/, etc.)
  feedback/           # Feedback aggregation (written by fleet-feedback.sh)
    2026-07-21.json
```

## Resume Semantics

1. Read the state log in reverse (`tac`).
2. Find the last phase with a terminal entry (`done` or `skip`). `fail` is explicitly excluded — a failed phase is not complete and will be re-executed on resume.
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

`planner-artifacts.sh` (in `ticket-auto-pipeline/lib/`) resolves per-ticket artifact directories from the Planner Context block's Initiative field. Path: `${REPOS_ROOT}/.ticket-auto/initiatives/{INIT}/tickets/{TID}/planner/`.

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

When TicketGen completes successfully, the initiative epic gets `state:execution`. The fleet-controller detector `_fleet_scan_initiative_dispatch` finds it during its next poll cycle.

**Gating:** `FLEET_AUTO_DISPATCH=true` must be set. When false (default), the detector reports undispatched initiatives at severity 1 (WARN) but does not actuate. This allows observe-only operation during rollout.

**Idempotency:** `fleet_dispatch_initiative` checks the spawn queue for already-queued entries before enqueuing. Re-running dispatch does not duplicate entries.

**Concurrency:** `FLEET_MAX_CONCURRENT` caps active pipelines. `FLEET_DRY_RUN` makes dispatch no-op for preview.

## Shared-Branch Directive

When Epic Gen creates an initiative epic, a deterministic bash heuristic decides whether the epic should carry a `## Branch Directive` block. The directive declares a shared integration branch that child tickets target — downstream, `ticket-auto-pipeline` resolves it via `branch-resolve.sh` and `fleet-controller` manages its lifecycle via `epic-branch.sh`.

### Decision Rule

The recommender (`planner_branch_directive_recommend`) applies a two-condition rule, both required:

- **≥ 3 planned tickets** — fewer tickets don't warrant shared-branch overhead
- **Dependency chain depth ≥ 2** — chained tickets genuinely build on each other

Ticket count alone is insufficient — independent tickets serialised behind a single integration PR gain nothing. Chain depth (computed via DP on the topological ordering) is the signal that tickets form an integrated unit.

### Thresholds

The thresholds are **provisional and unvalidated** against real usage data. The asymmetry is deliberate:

- **Under-recommending** costs the operator one flag (`--shared-branch`)
- **Over-recommending** silently changes the merge topology of ordinary work

When uncertain, don't recommend. Both override flags exist so the heuristic is never the final word.

### Operator Overrides

| Flag | Behavior |
|------|----------|
| `--shared-branch` | Force directive emission regardless of heuristic |
| `--no-shared-branch` | Suppress directive regardless of heuristic |

Supplying both is an error. Neither flag defers to the heuristic.

### Design Decisions

- **The decision is bash, not agent judgement.** "Do these tickets belong on one branch?" is a question about dependency graph shape, not content. Reproducibility matters — merge topology must not depend on sampling variance.
- **The branch name is derived, not authored.** `epic/{INITIATIVE_ID}-{title-slug}`, deterministic, satisfying the downstream validator's charset rules by construction. No agent-supplied content.
- **Generate against the validator.** `branch-directive-gen.sh` round-trips through `branch-directive-check.sh` (downstream plugin). No bundled copy — a drifting duplicate would silently produce blocks that fail validation.
- **Nothing is added to the Planner Context block.** Children inherit the branch by parent lookup. Adding a branch field to each child would mean an epic edit silently desynchronises every child, with no arbiter.

### Ticket Gen Unchanged

The Ticket Generation phase is deliberately unaffected. Child tickets inherit the shared branch by parent lookup at execution time. No branch information is written into child ticket bodies or Planner Context blocks. The Planner Context block schema version is unchanged.

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
| Shared-branch recommendation (heuristic) | — |
| Planner Context block generation | Proposal and spec authoring |
| Directive block generation (branch naming) | — |
| Confidence signal derivation | Review critique generation |
| Pre-creation validation (`planned-ticket-check.sh`) | Ticket body content |
| Auto-dispatch detection and enqueuing | Re-planning decisions |

The router never reasons about content. Phases never mutate state directly (they write log entries the router reads).

## Configuration

### Planner variables

| Variable | Default | Description |
|----------|---------|-------------|
| `PLANNER_CONFIDENCE_THRESHOLD` | 0.85 | Minimum confidence for `pre-approved` label |
| `PLANNER_IDEA_MAX_LENGTH` | 2000 | Maximum idea length in chars (truncated with warning) |
| `PLANNER_TSORT_TIMEOUT` | 30 | Seconds before timing out dependency graph sort |
| `PLANNER_PHASE_TIMEOUT` | 600 | Seconds before timing out a hung phase agent |

### Cross-plugin variables (fleet-controller)

| Variable | Default | Description |
|----------|---------|-------------|
| `FLEET_AUTO_DISPATCH` | false | Must be `true` to enable automatic dispatch from detection |
| `FLEET_MAX_CONCURRENT` | 3 | Max concurrent pipelines for dispatch |
| `FLEET_DRY_RUN` | false | When `true`, dispatch is preview-only |

### Environment

| Variable | Default | Description |
|----------|---------|-------------|
| `REPOS_ROOT` | `${HOME}/repos` | Root for initiative directories and repo discovery |
| `LINEAR_API_KEY` | (required) | Linear API authentication token |
| `LINEAR_TEAM_ID` | *(unset)* | Team key, name or id to create on, the fallback for `--team`. Unset resolves to the workspace's only team; several visible teams is an error naming them, never a guess |
| `LINEAR_API_URL` | `https://api.linear.app/graphql` | Linear GraphQL API endpoint |
| `LINEAR_MAX_RETRIES` | 3 | Max Linear API call retries |
| `LINEAR_RETRY_DELAYS` | `1 2 4` | Retry backoff delays in seconds |
| `CLAUDE_PLUGIN_ROOT` | (resolved at runtime) | Plugin cache location for library sourcing |

### The create gate and stop conditions

Phases 1–6 write only to disk. Epic Gen (phase 7) is the first Linear write, and the
dispatch loop **stops on that boundary unless the initiative has been explicitly
authorized to cross it**. That default is a constant, not runtime state: there is no
flag whose absence permits creation, and nothing that has to propagate correctly for
the safe outcome to hold.

Crossing the boundary takes a separate invocation:

```
/ticket-planner plan "…"                  # → Appraisal … Consensus, nothing in Linear
/ticket-planner resume INIT-42 --create   # → Epic Gen, Ticket Gen, Completed
```

`--create` is read once, at the top of that invocation, and written to the state log
as `META|create-authorized|done` **before the loop starts**. Every later check reads
it back from disk, so the authorization survives a crashed router and the process
boundary between phases — the same durability the retry budget gets from `fail`
entries. A `resume` after a crash mid-Epic-Gen proceeds without re-passing the flag.

| Variable | Default | Description |
|----------|---------|-------------|
| `PLANNER_UNTIL` | *(unset)* | Phase to stop after. Read **once, during argument parsing**, and persisted as `META|stop-after` |
| `PLANNER_REVIEW_HOLD` | false | When `true`, stop after Review — folded into `--until Review` at parsing time |
| `PLANNER_MAX_PHASE_RETRIES` | 2 | Max retries per phase before failing the run |

`PLANNER_CONSENSUS_HOLD` was removed: stopping before the first Linear write is now
the default and needs no variable.

Both controls resolve through a single function, `planner_stop_phase <initiative_id>`,
which returns the **earliest** applicable stop point — `--until TicketGen` on an
unauthorized initiative still stops at Consensus. There is one stop condition in the
dispatch loop, not several, so the forms cannot diverge.

Two further guards sit under the stop check, because the failure being prevented is
silent entity creation: `planner_create_gate_check` refuses to dispatch a write phase
without authorization, and the Epic Gen and Ticket Gen prompts re-verify it from the
state log inside the agent.

Stopping is not a distinct mode. The router holds no in-memory state, so a stop is
just "quit dispatching", and `resume` is the continuation — the same path crash
recovery already uses.

#### Why the controls live on disk

Every value that survives the dispatch loop correctly — the initiative ID, the idea,
the current phase, retry counts — survives by being re-derived from disk or re-supplied
as a literal argument, never by shell persistence. The loop is not one process: an
Agent tool call sits between every pair of phases, so each iteration runs in a fresh
shell and an `export` from argument parsing is gone by the next one.

The stop conditions and project/milestone flags were, briefly, the only pieces of state
that tried to cross that boundary via `export`, and they were the only pieces that were
broken — `--dry-run` silently did nothing (#144), the same root cause as the plugin-root
defect before it (#138). `test-planner-config-durability.sh` now runs each step in a
separate process so a regression fails a test rather than shipping.

### Projects and milestones

| Variable | Default | Description |
|----------|---------|-------------|
| `LINEAR_PROJECT` | *(unset)* | Default project name or id, the fallback for `--project`. Read once during argument parsing |
| `LINEAR_PROJECT_MILESTONE` | *(unset)* | Default project milestone, the fallback for `--milestone`. Read once during argument parsing |

The ref given is persisted as `META|linear-project`; Epic Gen resolves it to a UUID
against the team, records the result as `META|linear-project-id`, and Ticket Gen reads
that id straight back. The team itself follows the same path — `META|linear-team` →
`planner_linear_resolve_team_id` in Epic Gen → `META|linear-team-id`, reused verbatim by
Ticket Gen, because children on a different team from their parent epic cannot be fixed
without deleting and recreating them. The epic and every child therefore land in the same project off
a single name lookup, and no phase reads the variable from its environment.

Which project an initiative belongs to is an operator decision, so it comes from
configuration rather than agent judgement — it stays on the deterministic side of the
boundary. With both unset, no `projectId` is sent and the payload is byte-identical to
what workspaces that do not use projects saw before. A named milestone that does not
exist is an error; the planner does not create milestones.

The resolved ids are recorded at EpicGen as `EpicGen|project|done|project=… milestone=…`
so a later reader can tell where the initiative was filed without re-querying Linear.

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

Candidate enhancements identified during the 7-part integration programme:

- **Constitution / immutable-rules primitive** — per-initiative `constitution.md` validated at the entry gate
- **EARS notation for acceptance criteria** — deterministically-checkable AC shape
- **Critique-refine loop in planning phases** — iterate the proposal in Review→Consensus, not just pass/fail
- **Per-initiative dependency graph visualization** — surfaced in the dexter dashboard Initiatives tab
