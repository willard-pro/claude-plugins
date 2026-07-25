# CLAUDE.md — ticket-planner

Plugin-level guidance for Claude Code when working inside this plugin directory. See also: [repo-level CLAUDE.md](../CLAUDE.md) for marketplace-wide conventions.

## Plugin purpose

Autonomous 9-phase planner that turns business ideas into dependency-ordered planned tickets the existing `ticket-auto` pipeline consumes without special-casing. Sits upstream of `ticket-auto` and `fleet-controller` — plans, then hands off.

Produces against frozen consumption-side contracts: Planner Context block schema, `planned`/`pre-approved`/`Type` labels, artifact plane, and feedback aggregation. Does not re-specify them.

## Directory layout

```
ticket-planner/
  .claude-plugin/plugin.json      # Plugin manifest (name, version, hooks)
  skills/ticket-planner/          # Single skill: /ticket-planner
  lib/                            # Shared bash libraries
  docs/                           # Architecture and reference docs
```

## 9-phase state machine

```
Appraisal → Discovery → Architecture → Specify → Review → Consensus →
EpicGen → TicketGen → Completed
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
- **`planned-entry-gate` stays dormant by decision.** Specified but deliberately unimplemented. Confidence ≥ 0.85 + `pre-approved` would bypass human approval gate. Revisit only after: ≥ 10 completed initiatives with real feedback data, drift consistently ≤ 0.10 at confidence ≥ 0.85, zero incidents from auto-approved tickets, and explicit operator opt-in. See `docs/ticket-planner.md#planned-entry-gate-dormancy`.

## Determinism boundary

- **Bash side (deterministic):** State log parsing, position derivation, phase transition validation, entity idempotency checks, dependency acyclicity validation, `planned-ticket-check.sh` invocation, confidence signal derivation.
- **Agent side (LLM):** Per-phase reasoning — appraisal, discovery, architecture, proposal, review, consensus, spec writing, ticket body generation, re-planning decisions.

The router is bash; phases are Claude agents. The router never reasons about content — it only reads the log, validates transitions, and spawns the next phase.

## Shared libraries (`lib/`)

| File | Exports |
|------|---------|
| `planner-state.sh` | State log format, state directory layout, `planner_state_read`, `planner_state_write`, `planner_state_init`, `planner_position_derive`, `planner_initiative_dir`, `planner_phase_sequence`, `planner_phase_validate_transition`, `planner_phase_is_done`, `planner_phase_lock`/`planner_phase_unlock`, `planner_state_repair`, `planner_validate_initiative_id` |
| `planner-router.sh` | Phase router: `planner_phase_dispatch`, `planner_run`, `planner_resume`. Reads state log, spawns phase agents. |
| `planner-phase-prompts.sh` | Per-phase agent prompt templates: `planner_prompt_appraisal`, `planner_prompt_discovery`, `planner_prompt_architecture`, `planner_prompt_specify`, `planner_prompt_review`, `planner_prompt_consensus`, `planner_prompt_epicgen`, `planner_prompt_ticketgen`, `planner_prompt_completed`. Dispatch via `planner_prompt_for_phase`. |
| `planner-context-gen.sh` | Deterministic Planner Context block generator, confidence derivation from concrete signals. |
| `planner-deps-check.sh` | Dependency acyclicity validation (`tsort`-based), topological sort, missing-target detection. |
| `planner-ticket-validate.sh` | Pre-creation validation against `planned-ticket-check.sh`, idempotency helpers (`record_intent`, `entity_exists`, `entity_mark_created`). |
| `planner-replan.sh` | Re-planning support: regenerate-flag detection, feedback ingestion, drift computation, scope restriction, post-replan dependency validation. |
| `planner-linear-api.sh` | Linear GraphQL API client with retry (3 attempts, exponential backoff). Wraps curl. `planner_linear_graphql`, `planner_linear_create_issue`, `planner_linear_get_issue`. |
| `planner-spec-validate.sh` | Deterministic spec file validation gate. `planner_spec_validate_all`, `planner_spec_validate_one`. Checks required sections + parseable Signals JSON. |

## State log format

Pipe-delimited, same convention as ticket-auto's pipeline log:
```
ISO|PHASE|STEP|STATUS|MSG
```

Statuses: `start`, `done`, `fail`, `skip`. Phases match the 9-phase machine: Appraisal, Discovery, Architecture, Specify, Review, Consensus, EpicGen, TicketGen, Completed. `META` is a pseudo-phase for metadata (`schema`, `title`, `initiative-id`, `idea`).

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
