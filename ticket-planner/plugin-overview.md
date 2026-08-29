# plugin-overview.md — ticket-planner

Maintainer-facing overview of the ticket-planner plugin. Read this before adding features, modifying the state machine, or debugging planning failures.

## Design philosophy

**Determinism at the boundary.** Bash handles state (log parsing, position derivation, phase transition validation, entity idempotency, dependency acyclicity, confidence computation, spec validation). Agents handle reasoning (appraisal, discovery, architecture, proposal/spec synthesis, review, consensus, ticket body generation). The boundary is absolute — agents never mutate state directly; they write log entries the router reads.

**Stateless routing, copied from ticket-auto.** State lives in an append-only log. The router reads it to derive position. Each phase runs as an isolated agent with no inline reasoning between phases. Resume re-derives position by re-reading the log — zero in-memory state between invocations.

**Generate against the validator.** Every ticket is validated by `planned-ticket-check.sh` before creation. A ticket that fails validation is not created. Confidence is derived deterministically from concrete signals (services identified, symbols resolved, prior art, exploration depth, complexity) — never a uniform constant.

**Idempotency by design.** Every entity-creating phase records intent before the API call, checks existence before creating, and marks completion after success. A crash between intent and creation produces exactly one entity on resume.

## Component inventory

### State management

| Component | File | Role |
|-----------|------|------|
| State log helpers | `lib/planner-state.sh` | Log format, read/write/init, position derivation, phase sequence, transition validation, phase locking, state log repair |
| Phase router | `lib/planner-router.sh` | Reads state log, derives position, dispatches phase agents |
| Phase prompts | `lib/planner-phase-prompts.sh` | Per-phase agent prompt templates with input sanitization |

### Validation and gating

| Component | File | Role |
|-----------|------|------|
| Dependency validation | `lib/planner-deps-check.sh` | Acyclicity (`tsort`), topological sort, missing-target detection |
| Ticket validation | `lib/planner-ticket-validate.sh` | Pre-creation validation, idempotency helpers, post-creation verification, dispatch gate |
| Spec validation | `lib/planner-spec-validate.sh` | Deterministic spec file validation — required sections + parseable Signals JSON |
| Context generation | `lib/planner-context-gen.sh` | Deterministic Planner Context block generation, confidence derivation from 5 concrete signals |

### Linear integration

| Component | File | Role |
|-----------|------|------|
| Linear API client | `lib/planner-linear-api.sh` | GraphQL API with retry (3 attempts, exponential backoff), issue creation and retrieval |

### Re-planning

| Component | File | Role |
|-----------|------|------|
| Re-plan support | `lib/planner-replan.sh` | Regenerate flag detection, feedback ingestion, drift computation, scope restriction, post-replan validation |

### Testing

| File | Coverage |
|------|----------|
| `lib/tests/test-planner-state.sh` | State log read/write/init, position derivation, repair, duplicate detection (12 tests) |
| `lib/tests/test-planner-transitions.sh` | Phase transition validation, lifecycle scenarios (23 tests) |
| `lib/tests/test-planner-integration.sh` | End-to-end: state init → phase transitions → position derivation (28 tests) |
| `lib/tests/test-planner-generation.sh` | Idempotency: intent recording, entity existence, entity creation (23 tests) |
| `lib/tests/test-planner-replan.sh` | Re-plan: flag detection, feedback listing, drift computation, record (29 tests) |
| `lib/tests/test-planner-sanitize.sh` | Input sanitization: bidi chars, injection patterns, length limits (27 tests) |

## Architecture: Stateless Router

```
User invokes /ticket-planner plan "idea"
  → SKILL.md sources planner-state.sh + planner-router.sh
    → planner_state_init "$ID" "$IDEA"
    → planner_run "$ID" "$IDEA"
      → dispatch loop:
        1. planner_position_derive → current phase
        2. planner_prompt_for_phase → agent prompt
        3. Spawn isolated agent with prompt
        4. Agent writes state log entries via planner_state_write
        5. Re-read position → next phase or done
      → Completed → planner_position_derive returns "" → stop
```

### Phase dispatch

| # | Phase | Agent prompt | Key artifacts |
|---|-------|-------------|---------------|
| 1 | Appraisal | `planner_prompt_appraisal` | `appraisal.md` |
| 2 | Discovery | `planner_prompt_discovery` | `discovery.md` |
| 3 | Architecture | `planner_prompt_architecture` | `architecture.md` |
| 4 | Specify | `planner_prompt_specify` | `proposal.md`, `specs/*.md` |
| 5 | Review | `planner_prompt_review` | `review.md` |
| 6 | Consensus | `planner_prompt_consensus` | `proposal.md` (overwritten), `consensus.md` |
| 7 | EpicGen | `planner_prompt_epicgen` | Linear epic |
| 8 | TicketGen | `planner_prompt_ticketgen` | Linear tickets, `state:execution` on epic |
| 9 | Completed | `planner_prompt_completed` | `COMPLETED.md` |

## Phase merge history

The original design specified 12 phases. Four were merged in implementation:

| Original | Merged Into | Rationale |
|----------|------------|-----------|
| Proposal + OpenSpec | Specify (phase 4) | Proposal and spec writing share the same upstream artifacts; doing them in one pass avoids context loss between phases |
| StoryGen | TicketGen (phase 8) | Stories are always 1:1 with tickets — no separate decomposition step needed |
| Execution | TicketGen (phase 8) | Setting `state:execution` is a deterministic label operation after ticket verification, not a reasoning phase |

The merge reduced phase count from 12 to 9 without removing any capability. Phase agents produce all the same artifacts.

## Key design decisions

- **Phase sequence is single source of truth.** `planner_phase_sequence` in `planner-state.sh` is the canonical phase list. Position derivation, transition validation, and the dispatch table all derive from it. There is no second copy to drift.
- **Confidence from signals, not self-assessment.** The LLM writes raw signal values (services count, symbols count, prior art boolean, complexity enum, exploration depth enum). A deterministic bash function computes confidence from these. The LLM never sees its own confidence score — it can't game it.
- **Regenerate is an explicit flag.** Feedback is not read by default. The `Regenerate` flag must be set on the Planner Context block before `replan` will ingest feedback. This keeps planner runs reproducible and feedback ingestion a deliberate act.
- **`state:execution` is set by TicketGen, not EpicGen.** The epic is created without the execution label. Only after all child tickets are created and verified does TicketGen apply `state:execution`. This prevents fleet-controller from dispatching a partially-created initiative.
- **Cross-plugin dependency on `planned-ticket-check.sh`.** The planner does not bundle its own ticket validator. It resolves `planned-ticket-check.sh` from ticket-auto-pipeline via a three-level fallback. This is deliberate — schema drift between planner output and pipeline consumption is a hard stop, not a silent degradation.

## Known sharp edges

See [CLAUDE.md § Known sharp edges](CLAUDE.md#known-sharp-edges) for the current list. Key items:

- Cross-plugin validator dependency (three-level fallback, hard stop on unavailable)
- `planner-artifacts.sh` lives in ticket-auto-pipeline, not planner
- Pipe character in state log message field can truncate naive `cut -f5` consumers
- Stale phase lock blocks resume until PID dies or lock is manually removed
- Prompt phase indices are hardcoded — changing phase sequence requires updating 9 prompt functions
- Phase prompts embed bash inside unquoted heredocs, so every `$`, backtick and trailing `\` intended for the agent's shell must be escaped. An unescaped one executes at prompt-generation time and lands in the prompt blank — this is not covered by type checking or linting, only by `test-planner-lib-root.sh`

## Related plugins

- [ticket-auto-pipeline](../ticket-auto-pipeline/) — Downstream consumer. Reads Planner Context blocks, fast-paths `planned`+`pre-approved` tickets.
- [fleet-controller](../fleet-controller/) — Dispatch orchestrator. Detects `state:execution` epics, dispatches child tickets to ticket-auto workers.
