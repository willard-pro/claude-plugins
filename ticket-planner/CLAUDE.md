# CLAUDE.md — ticket-planner

Plugin-level guidance for Claude Code when working inside this plugin directory. See also: [repo-level CLAUDE.md](../CLAUDE.md) for marketplace-wide conventions.

## Plugin purpose

Autonomous 9-phase planner that turns business ideas into dependency-ordered planned tickets the existing `ticket-auto` pipeline consumes without special-casing. Sits upstream of `ticket-auto` and `fleet-controller` — plans, then hands off.

Produces against frozen consumption-side contracts: Planner Context block schema, `planned`/`pre-approved`/`Type` labels, artifact plane, and feedback aggregation. Does not re-specify them.

## Directory layout

```
ticket-planner/
  .claude-plugin/plugin.json      # Plugin manifest (name, version, hooks)
  skills/ticket-planner/SKILL.md  # Single skill: /ticket-planner
  lib/                            # Shared bash libraries (9 files)
  lib/tests/                      # Test suites (6 files)
  docs/                           # Architecture and reference docs
  README.md                       # Marketplace entry point
  plugin-overview.md              # Maintainer-facing design doc
  state-log-format.md             # Standalone log format spec

### Shared docs (repo root)

  docs/ticket-planner-pipeline-diagram.html  # Interactive 9-phase diagram (GitHub Pages)
```

### `.ticket-auto/` artifact layout (on disk, outside source repos)

```
${REPOS_ROOT}/.ticket-auto/initiatives/{INITIATIVE_ID}/
  state.log           # Append-only phase transition log
  .phase-lock         # Concurrency lock (PID + phase name)
  .intents/           # Idempotency intent files — created lazily on first write
    epic-{key}.json
    ticket-{key}.json
  artifacts/          # Per-phase artifacts
    idea.txt          # Original idea (preserves pipes/newlines lost in log)
    appraisal.md      # Phase 1: scope summary, affected services, strategy
    discovery.md      # Phase 2: code paths, symbols, API contracts, prior art
    architecture.md   # Phase 3: decision, alternatives, rationale, risk assessment
    proposal.md       # Phase 4: synthesized proposal (overwritten by Consensus)
    review.md         # Phase 5: review findings with severities
    consensus.md      # Phase 6: findings disposition, changes, deferred items
    specs/            # Phase 4: per-ticket spec files with Signals JSON blocks
      INDEX.md        # Ticket spec index (title, service, dependencies)
      {slug}.md       # Individual ticket spec
    COMPLETED.md      # Phase 9: completion summary with timeline and warnings
  feedback/           # Feedback aggregation (written by fleet-feedback.sh)
    {rundate}.json    # Per-run aggregated feedback
```

## Skill

| Skill | Type | Purpose |
|-------|------|---------|
| [ticket-planner](skills/ticket-planner/SKILL.md) | Pipeline | 9-phase autonomous planner — turns business ideas into dependency-ordered planned tickets. Modes: `plan`, `resume`, `status`, `replan`. |

The planner is a single-skill plugin. The skill SKILL.md serves as both the user-facing slash-command documentation and the agent procedure reference. Architecture documentation lives in `docs/ticket-planner.md` — the skill file references it but does not duplicate it.

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
| `planner-state.sh` | State log format, state directory layout. `planner_validate_initiative_id`, `planner_initiative_dir`, `planner_initiative_dir_init`, `planner_state_log`, `planner_state_read`, `planner_state_write`, `planner_state_init`, `planner_phase_sequence`, `planner_position_derive`, `planner_phase_lock`/`planner_phase_unlock`, `planner_phase_validate_transition`, `planner_phase_is_done`, `planner_state_repair` |
| `planner-router.sh` | Phase router: `planner_phase_dispatch`, `planner_run`, `planner_resume`. Reads state log, spawns phase agents. |
| `planner-phase-prompts.sh` | Per-phase agent prompt templates: `planner_prompt_appraisal`, `planner_prompt_discovery`, `planner_prompt_architecture`, `planner_prompt_specify`, `planner_prompt_review`, `planner_prompt_consensus`, `planner_prompt_epicgen`, `planner_prompt_ticketgen`, `planner_prompt_completed`. Dispatch via `planner_prompt_for_phase`. Input sanitization: `planner_sanitize_input`. |
| `planner-context-gen.sh` | Deterministic Planner Context block generator: `planner_context_generate`, `planner_confidence_derive`. Validates all 11 required fields, emits formatted markdown. |
| `planner-deps-check.sh` | Dependency acyclicity validation: `planner_deps_check_acyclic` (`tsort`-based), `planner_deps_validate_targets`, `planner_deps_topological_sort`, `planner_deps_from_tickets`. |
| `planner-ticket-validate.sh` | Pre-creation validation: `planner_validate_ticket` (wraps `planned-ticket-check.sh`). Idempotency: `planner_record_intent`, `planner_entity_exists`, `planner_entity_get_id`, `planner_entity_mark_created`. Post-creation: `planner_verify_tickets`, `planner_dispatch_gate`. |
| `planner-replan.sh` | Re-planning support: `planner_replan_flag_is_set`, `planner_replan_flag_set`, `planner_feedback_list`, `planner_feedback_read_all`, `planner_feedback_status`, `planner_drift_compute`, `planner_replan_eligible_tickets`, `planner_replan_validate_deps`, `planner_replan_record`. |
| `planner-linear-api.sh` | Linear GraphQL API client with retry (3 attempts, exponential backoff). Wraps curl. `planner_linear_graphql`, `planner_linear_create_issue`, `planner_linear_get_issue`. |
| `planner-spec-validate.sh` | Deterministic spec file validation gate. `planner_spec_validate_all`, `planner_spec_validate_one`. Checks required sections + parseable Signals JSON. |

## State log format

Pipe-delimited, same convention as ticket-auto's pipeline log. Full spec: [state-log-format.md](state-log-format.md).

```
ISO|PHASE|STEP|STATUS|MSG
```

Statuses: `start`, `done`, `fail`, `skip`. Phases: Appraisal, Discovery, Architecture, Specify, Review, Consensus, EpicGen, TicketGen, Completed. `META` pseudo-phase for metadata (`schema`, `title`, `initiative-id`, `idea`). Schema version `1` — declared as first line.

## Known sharp edges

- **Cross-plugin validator dependency:** `planner-ticket-validate.sh` depends on `planned-ticket-check.sh` from `ticket-auto-pipeline`. It resolves via a three-level fallback (plugin cache → skills lib → relative path). If the validator is unavailable (exit 3), ticket creation halts. There is no bundled copy — the dependency is deliberate to avoid schema drift.
- **`planner-artifacts.sh` lives in ticket-auto-pipeline, not planner.** The artifact resolver that reads Planner Context blocks and resolves per-ticket artifact directories is in the downstream plugin. The planner writes artifacts; ticket-auto reads them. Don't look for this file in planner's `lib/`.
- **State log pipe character in message field:** The message field in `ISO|PHASE|STEP|STATUS|MSG` can contain arbitrary text. If a message contains `|`, naive `cut -d'|' -f5` truncates. `planner_state_write` sanitizes the idea field but phase agents write message fields directly. `planner_state_repair` handles this defensively by preserving trailing fields, but consumers that use `cut -f5` may see truncated messages.
- **Phase concurrency lock:** `planner_phase_lock` uses a PID-based lock file. If the lock holder crashes without cleanup, a stale lock blocks resume until manually removed or until the PID is no longer alive. `planner_state_init` auto-removes stale locks, but `planner_phase_lock` itself does not.
- **Prompt phase indices:** The 9 agent prompt functions embed their phase position as "phase N of 9". If the phase sequence changes (new phase inserted, phase removed), every prompt function's index must be updated. There is no centralized constant — each function hardcodes its index. A mismatch would confuse agents about their position in the pipeline.
- **`PLANNER_REVIEW_HOLD`, `PLANNER_CONSENSUS_HOLD`, `PLANNER_MAX_PHASE_RETRIES` documented but unimplemented.** These config variables appear in `docs/ticket-planner.md` under a "Planned" section. The router dispatch loop does not check them. If an operator sets them expecting behavior, nothing happens.

## Related docs

- [ticket-planner architecture](docs/ticket-planner.md)
- [State log format spec](state-log-format.md)
- [Docs index](docs/README.md)
- [Interactive pipeline diagram](../docs/ticket-planner-pipeline-diagram.html)
- [Root CLAUDE.md](../CLAUDE.md)
- [fleet-controller CLAUDE.md](../fleet-controller/CLAUDE.md)
- [ticket-auto-pipeline CLAUDE.md](../ticket-auto-pipeline/CLAUDE.md)
