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

## State Machine

12 phases, strictly linear. Each phase runs as an isolated Claude agent. The router is bash — it reads the state log, derives position, and dispatches phases. It performs no reasoning of its own.

```
Appraisal → Discovery → Architecture → Proposal → Review → Consensus →
OpenSpec → EpicGen → StoryGen → TicketGen → Execution → Completed
```

## State Representation

State lives in an append-only pipe-delimited log at `${REPOS_ROOT}/.ticket-auto/initiatives/{ID}/state.log`. Format:

```
ISO|PHASE|STEP|STATUS|MSG
```

Schema version `1` declared as the first line. The router re-derives position by reading the log — no state held in memory between invocations.

## Resume Semantics

1. Read the state log in reverse.
2. Find the last phase with a terminal entry (`done`, `fail`, `skip`).
3. Check if a `start` entry exists after the last completed phase (crash mid-phase).
4. If crashed mid-phase, resume at that phase (phase is idempotent).
5. If no crash detected, advance to the next phase after the last completed.
6. If the last completed phase is `Completed`, the run is done.

## Idempotency

Every entity-creating phase (EpicGen, StoryGen, TicketGen) follows a two-step pattern:
1. Record intent in the state log ("about to create epic X").
2. Check if epic X already exists (by deterministic identifier).
3. If it exists, skip creation and write `done`.
4. If it doesn't exist, create it and write `done`.

This means a crash between steps 1 and 4 produces exactly one entity on resume.

## Contracts

The planner produces against four frozen contracts:

1. **Planner Context block** — `## Planner Context` in ticket description. Validated by `planned-ticket-check.sh`. Must pass before ticket creation.
2. **Labels** — `planned`, `pre-approved`, `INIT-{id}`, `Type`, `blocked-by:{ID}`. Applied to each generated ticket.
3. **Artifact plane** — `planner-artifacts.sh` resolves to `${REPOS_ROOT}/.ticket-auto/initiatives/{ID}/artifacts/`. Per-phase artifacts written here.
4. **Feedback** — `fleet-feedback.sh` aggregates `META|planner-feedback` from pipeline logs. Writer emits to pipeline log at post-implement.

## Auto-Dispatch

When the Execution phase completes, the initiative epic gets `state:execution`. The fleet-controller detector `detect_initiative_dispatch` finds it and invokes `fleet_dispatch_initiative`, which enqueues planned children into the spawn queue. The human approval gate still stops every ticket.

## Re-Planning

When an initiative carries the `Regenerate` label, the planner:
1. Reads aggregated feedback JSONs from `{initiative_dir}/feedback/`.
2. Computes confidence drift from predicted vs actual outcomes.
3. Regenerates tickets still in `Backlog` and not in the spawn queue.
4. Dispatched, in-progress, and completed tickets are left unchanged.

## Future Enhancements

See `ticket-planner-implementation.md` in the repo root for candidate enhancements:
- Constitution / immutable-rules primitive
- EARS notation for acceptance criteria
- Critique-refine loop in planning phases
- Per-initiative dependency graph visualization
