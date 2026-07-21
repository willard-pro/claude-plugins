# CLAUDE.md — ticket-planner

Plugin-level guidance for Claude Code when working inside this plugin directory. See also: [repo-level CLAUDE.md](../CLAUDE.md) for marketplace-wide conventions.

## Plugin purpose

Autonomous 12-phase planner that turns business ideas into dependency-ordered planned tickets the existing `ticket-auto` pipeline consumes without special-casing. Sits upstream of `ticket-auto` and `fleet-controller` — plans, then hands off.

Produces against frozen consumption-side contracts: Planner Context block schema, `planned`/`pre-approved`/`Type` labels, artifact plane, and feedback aggregation. Does not re-specify them.

## Directory layout

```
ticket-planner/
  .claude-plugin/plugin.json      # Plugin manifest (name, version, hooks)
  skills/ticket-planner/          # Single skill: /ticket-planner
  lib/                            # Shared bash libraries
  docs/                           # Architecture and reference docs
```

## 12-phase state machine

```
Appraisal → Discovery → Architecture → Proposal → Review → Consensus →
OpenSpec → Epic Gen → Story Gen → Ticket Gen → Execution → Completed
```

Each phase runs as an isolated agent. State lives in a durable append-only log under `${REPOS_ROOT}/.ticket-auto/initiatives/{ID}/`. The router reads the log to derive position — no state held in memory. Resume re-derives position by re-reading the log.

## Key design decisions

- **Stateless-router pattern**, copied deliberately from `ticket-auto`. State lives in a durable log; the router reads it to determine position; each phase runs as an isolated agent with no inline reasoning between phases.
- **Phase transitions recorded before side effects.** Every entity-creating phase first records intent, then checks whether the entity already exists before creating it, keyed by a deterministic identifier. Safe to re-enter any phase.
- **Generate against the validator.** `planned-ticket-check.sh` is invoked on generated tickets before creation. A ticket that fails validation is not created.
- **Confidence per ticket from concrete signals.** Derived from services identified, symbols resolved, prior art found — never a uniform constant.
- **Dependencies as `blocked-by` labels, validated acyclic.** Cycle detection before any ticket is created.
- **Auto-dispatch wired at the detector, approval gate untouched.** Dispatches without human command; still stops every ticket at the human approval gate.
- **Regenerate is an explicit flag.** Feedback ingested only when `Regenerate` label is present. Undispatched Backlog tickets only — in-flight work untouched.

## Determinism boundary

- **Bash side (deterministic):** State log parsing, position derivation, phase transition validation, entity idempotency checks, dependency acyclicity validation, `planned-ticket-check.sh` invocation, confidence signal derivation.
- **Agent side (LLM):** Per-phase reasoning — appraisal, discovery, architecture, proposal, review, consensus, spec writing, ticket body generation, re-planning decisions.

The router is bash; phases are Claude agents. The router never reasons about content — it only reads the log, validates transitions, and spawns the next phase.

## Shared libraries (`lib/`)

| File | Exports |
|------|---------|
| `planner-state.sh` | State log format, state directory layout, `planner_state_read`, `planner_state_write`, `planner_position_derive`, `planner_initiative_dir` |
| `planner-router.sh` | Phase router: `planner_phase_next`, `planner_phase_dispatch`, `planner_phase_validate_transition`. Reads state log, spawns phase agents. |

## State log format

Pipe-delimited, same convention as ticket-auto's pipeline log:
```
ISO|PHASE|STEP|STATUS|MSG
```

Statuses: `start`, `done`, `fail`, `skip`. Phases match the 12-phase machine. `META` is a pseudo-phase for metadata (`schema`, `title`, `initiative-id`, `idea`).

Schema version is `1` — declared as first line.

## State directory layout

```
${REPOS_ROOT}/.ticket-auto/initiatives/{INITIATIVE_ID}/
  state.log           # Append-only phase transition log
  artifacts/          # Per-phase artifacts (proposal, specs, etc.)
  feedback/           # Feedback aggregation (written by fleet-feedback.sh)
```

## Related docs

- [ticket-planner architecture](docs/ticket-planner.md)
- [Root CLAUDE.md](../CLAUDE.md)
- [fleet-controller CLAUDE.md](../fleet-controller/CLAUDE.md)
- [ticket-auto-pipeline CLAUDE.md](../ticket-auto-pipeline/CLAUDE.md)
