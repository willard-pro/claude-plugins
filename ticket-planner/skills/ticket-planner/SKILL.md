---
name: ticket-planner
description: 12-phase autonomous planner — turns a business idea into dependency-ordered planned tickets. Phases: Appraisal → Discovery → Architecture → Proposal → Review → Consensus → OpenSpec → Epic Gen → Story Gen → Ticket Gen → Execution → Completed. Produces against frozen Planner Context and labels contracts.
allowed-tools: Bash, Read, Agent
---

# Ticket Planner — Idea-to-Tickets Pipeline

Autonomous 12-phase planner that turns business ideas into Linear initiatives, epics, and dependency-ordered planned tickets the existing `ticket-auto` pipeline consumes without special-casing.

Sits upstream of `ticket-auto` and `fleet-controller`. Produces against frozen consumption-side contracts — does not re-specify them.

## When to Use

| Trigger | Mode |
|---------|------|
| `/ticket-planner plan "idea"` | Start a new initiative from an idea |
| `/ticket-planner resume <INIT_ID>` | Resume a crashed or paused initiative |
| `/ticket-planner status <INIT_ID>` | Show current phase and recent log entries |

## Modes

### Plan (`plan`)

Start a new planning run from a business idea. The planner initializes the state directory, creates the state log, and begins at the Appraisal phase. Each phase runs as an isolated agent; the router advances sequentially through the 12-phase state machine.

```
/ticket-planner plan "Add real-time collaboration to the document editor"
```

If the run is interrupted (crash, timeout, manual stop), resume with `resume` — the router re-derives position from the state log and continues from where it left off.

### Resume (`resume`)

Continue an interrupted or paused run. The router reads the state log, finds the last incomplete phase, and resumes from there. Completed phases are skipped.

```
/ticket-planner resume INIT-42
```

### Status (`status`)

Show the current phase, initiative metadata, and the last few state log entries. Useful for checking whether a run is in progress, paused, or complete.

```
/ticket-planner status INIT-42
```

## The 12 Phases

| # | Phase | What it does | Output |
|---|-------|-------------|--------|
| 1 | Appraisal | Interprets the idea, establishes initiative scope | Scope summary |
| 2 | Discovery | Explores affected repos, gathers context | Code paths, symbols, APIs |
| 3 | Architecture | Determines the technical approach | Architecture decision record |
| 4 | Proposal | Produces the initiative proposal artifact | `proposal.md` |
| 5 | Review | Critiques the proposal (internal by default) | Review findings |
| 6 | Consensus | Resolves review findings into a settled plan | Finalized proposal |
| 7 | OpenSpec | Emits specification artifacts | Spec documents |
| 8 | Epic Gen | Creates the initiative epic in Linear | Linear epic with `state:execution` |
| 9 | Story Gen | Generates stories from the spec | Story descriptions |
| 10 | Ticket Gen | Creates planned child tickets in Backlog | Linear tickets with `planned` label |
| 11 | Execution | Labels the epic for execution, hands off to dispatch | Auto-dispatch to `fleet-controller` |
| 12 | Completed | Terminal phase — no further transitions | Completed state |

## Contracts (frozen — the planner produces against these)

The planner does not re-specify these. They are the interface to the downstream pipeline:

- **Planner Context block** — `## Planner Context` in ticket description, validated by `planned-ticket-check.sh`
- **Labels** — `planned`, `pre-approved`, `INIT-{id}`, `Type`, `blocked-by:{ID}`
- **Artifact plane** — `planner-artifacts.sh` resolves to `${REPOS_ROOT}/.ticket-auto/initiatives/{ID}/artifacts/`
- **Feedback** — `fleet-feedback.sh` aggregates `META|planner-feedback` from pipeline logs

## State and Resume

State lives in an append-only pipe-delimited log at `${REPOS_ROOT}/.ticket-auto/initiatives/{ID}/state.log`. The router re-derives position by reading the log — no state held in memory between invocations.

If a crash occurs mid-phase, the router resumes at that phase. Each entity-creating phase is idempotent: it records intent before creating, and checks existence before creating. A crash between intent and creation produces exactly one entity on resume.

## Determinism Boundary

- **Bash side (deterministic):** State log parsing, position derivation, phase transition validation, entity idempotency checks, dependency acyclicity validation, `planned-ticket-check.sh` invocation.
- **Agent side (LLM):** Per-phase content — appraisal, discovery, architecture, proposal, review, consensus, spec writing, ticket body generation.

The router never reasons about content; phases never mutate state directly (they write log entries that the router reads).

## Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `PLANNER_REVIEW_HOLD` | false | When `true`, Review phase pauses for human input |
| `PLANNER_CONSENSUS_HOLD` | false | When `true`, Consensus phase pauses for human input |
| `PLANNER_MAX_PHASE_RETRIES` | 2 | Max retries per phase before failing the run |
