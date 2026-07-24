# Full-System Determinism Audit

> **Audit date:** 2026-07-24
> **Scope:** All 7 parts of the ticket-planner integration program + ticket-planner plugin
> **Methodology:** For each component, identify every LLM-dependent path and classify as `appropriate` (LLM is the right tool for the task) or `candidate` (could be moved to deterministic bash). The audit classifies, it does not mandate migration.

## Classification criteria

| Classification | Criteria |
|---------------|----------|
| `appropriate` | Task requires semantic reasoning about code, requirements, UI, or design. No deterministic equivalent exists. |
| `candidate` | Task is mechanical/structural and could be implemented as a bash function with zero reasoning. Migration decision is separate. |
| `deterministic` | Already implemented in bash or JSON config. No LLM involvement. |

## Part 1: fleet-controller-extraction

| Component | Path | Classification | Notes |
|-----------|------|---------------|-------|
| `fleet-detect.sh` (11 detectors) | Detection logic | `deterministic` | Pure bash — log parsing, timestamp comparison, pattern matching |
| `fleet-dispatch.sh` | Ticket dispatch, spawn queue | `deterministic` | Pure bash — label filtering, priority sort, JSONL write |
| `fleet-intervene.sh` | Intervention execution | `deterministic` | Pure bash — escalation through OBSERVE→WARN→KILL→RESTART |
| `fleet-monitor.sh` | Health loop, spawn consumption | `deterministic` | Pure bash — poll cycle, registry read |
| `fleet-feedback.sh` | Feedback aggregation | `deterministic` | Pure bash — log parsing, JSON construction per initiative |
| `fleet-dashboard.sh` | HTML rendering | `deterministic` | Pure bash — template substitution |
| `fleet-registry.sh` | Worker registry | `deterministic` | Pure bash — JSONL append/read |
| `fleet-controller` skill | Orchestrator dispatch | `appropriate` | LLM reasons about fleet health and intervention decisions. Escalation decisions benefit from context (pattern matching across detectors). The detectors are bash; the orchestrator that reads their output is an LLM agent. |

**Part 1 summary:** 0 candidates. The fleet controller achieved its design goal: 11 bash detection engines + LLM orchestrator that reads their output. Detection is deterministic; intervention decisions retain human-quality judgment.

## Part 2: ticket-planner-enrichment

| Component | Path | Classification | Notes |
|-----------|------|---------------|-------|
| `planned-ticket-check.sh` | Context block validation | `deterministic` | Pure bash — parses markdown fields, validates required keys, checks confidence threshold |
| `state-machine.json` | Label registration | `deterministic` | JSON config — planner labels defined declaratively |
| `planner-context-schema.md` | Schema documentation | `deterministic` | Documentation, not code |

**Part 2 summary:** 0 candidates. The enrichment layer is entirely deterministic — schema definition + bash validator. This was the correct design: the contract surface must be mechanically checkable.

## Part 3: ticket-appraise-fast-path

| Component | Path | Classification | Notes |
|-----------|------|---------------|-------|
| `appraise-fast-path.sh` | Fast-path eligibility, field extraction | `deterministic` | Pure bash — label check, confidence comparison, symbol extraction |
| `gate-check.sh --mode entry` Check 2.7 | Planned context validation at gate | `deterministic` | Pure bash — calls `planned-ticket-check.sh`, checks depth mismatch |
| `gate-check.sh --mode entry` (all other checks) | Gate decisions | `deterministic` | Pure bash — complexity, artifact existence, autonomy routing, outcome labels |
| `ticket-appraise` skill Step 3a | Fast-path vs. full investigation routing | `deterministic` | Bash logic routes to fast-path when `planned` + valid context |
| `ticket-appraise` skill | Investigation, complexity scoring | `appropriate` | LLM reasons about codebase scope, prior art, and complexity. This is genuine investigation work — no deterministic equivalent. |
| `ticket-appraise-exec` skill | Artifact creation (simple-fix or openspec change) | `appropriate` | LLM generates implementation plans from investigation notes. |

**Part 3 summary:** 0 candidates. Fast-path routing is correctly bash; investigation and plan-writing are correctly LLM. The split is clean.

## Part 4: fleet-controller-dispatch

| Component | Path | Classification | Notes |
|-----------|------|---------------|-------|
| `fleet-dispatch.sh` | Dispatch logic | `deterministic` | Pure bash — epic validation, child enumeration, blocked-by resolution, priority sort, spawn queue write |
| `fleet-detect.sh` `detect_initiative_dispatch` | Initiative detection | `deterministic` | Pure bash — finds epics with `state:execution` + undispatched children |
| `_fleet_scan_initiative_dispatch` | Auto-dispatch actuation | `deterministic` | Pure bash — calls `fleet_dispatch_initiative` when `FLEET_AUTO_DISPATCH=true` |
| `blocked-by` resolution (inlined in dispatch) | Dependency resolution | `deterministic` | Pure bash — label parsing, skip-if-blocked logic. No standalone `blocked-by-check.sh` exists but functionality is present inline. |

**Part 4 summary:** 0 candidates. All dispatch logic is bash. The one specification-to-implementation gap (no standalone `blocked-by-check.sh`) is deliberate — the logic lives inline at `fleet-dispatch.sh:142-160` and doesn't need extraction until it grows.

## Part 5: ticket-planner-feedback-loop

| Component | Path | Classification | Notes |
|-----------|------|---------------|-------|
| `fleet-feedback.sh` | Feedback aggregation | `deterministic` | Pure bash — parses `META\|planner-feedback` log lines, builds per-initiative JSON |
| `planned-feedback-write.sh` | Feedback emission | `deterministic` | Pure bash — post-implement hook, conditional on `FROM_PLANNED` or `planned` label |
| Epic comment backchannel | Comment posting | `appropriate` | LLM decides what to post on the epic, but the *trigger* (gate-stop, pipeline complete) is deterministic |

**Part 5 summary:** 0 candidates. Feedback write and aggregation are bash. The comment content is appropriately LLM.

## Part 6: ticket-planner-exploration

| Component | Path | Classification | Notes |
|-----------|------|---------------|-------|
| Exploration depth selection | Depth tier assignment | `appropriate` | LLM in Discovery phase selects depth based on initiative risk/complexity. Could be heuristically scored but domain knowledge matters. |
| `openspec-explore` invocation | Codebase exploration | `appropriate` | LLM explores code, traces paths, finds symbols — genuine investigation |
| Exploration accuracy measurement | `missed_symbols`, `false_traces` | `deterministic` | Post-implement bash diff analysis. Computed, not reasoned. |
| Schema-Version 2 fields | Optional context fields | `deterministic` | All new fields are optional — backward-compatible by design. Validator mechanically accepts both versions. |
| Depth mismatch detection | `quick-scan` on complex ticket | `deterministic` | Gate check 2.7 compares depth to complexity — bash comparison, not LLM judgment. |

**Part 6 summary:** 0 candidates. Exploration itself is appropriately LLM (codebase investigation). Accuracy measurement is appropriately bash (diff analysis). The depth mismatch warning is a deterministic gate signal.

## Part 7: ticket-planner-integration (this change)

| Component | Path | Classification | Notes |
|-----------|------|---------------|-------|
| State machine alignment | Planner → ticket-auto mapping | `deterministic` | Documentation + config — no code path, just reference |
| Rollout sequencing | Phase ordering + gates | `deterministic` | Documentation — no code path |
| E2E integration tests | Test assertions | `deterministic` | Bash test scripts with mocked Linear API |
| Cross-plugin references | Reference consistency | `deterministic` | grep verification + manual fixup |
| This audit | Determinism classification | `deterministic` | Documentation — no code path |

## ticket-planner plugin (the producer — built in parallel)

| Component | Path | Classification | Notes |
|-----------|------|---------------|-------|
| `planner-state.sh` | State log, position derivation, transition validation | `deterministic` | Pure bash — same pattern as `detect-resume.sh` |
| `planner-router.sh` | Phase dispatch, resume logic | `deterministic` | Pure bash — reads state log, spawns phase agents, no reasoning |
| `planner-context-gen.sh` | Planner Context block generation, confidence derivation | `deterministic` | Pure bash — structured JSON → markdown, signal-based confidence scoring |
| `planner-deps-check.sh` | Dependency acyclicity (`tsort`), topological sort | `deterministic` | Pure bash — no reasoning, mechanical graph validation |
| `planner-ticket-validate.sh` | Pre-creation validation, idempotency helpers | `deterministic` | Pure bash — calls `planned-ticket-check.sh`, intent/check/create pattern |
| `planner-replan.sh` | Re-plan logic, feedback ingestion, scope restriction | `deterministic` | Pure bash — flag detection, feedback file reading, drift computation |
| `planner-phase-prompts.sh` | Per-phase agent prompt templates | `deterministic` | Bash templates — the prompts are strings, the template selection is mechanical |
| All 12 planner phases | Appraisal, Discovery, Architecture, Proposal, Review, Consensus, OpenSpec, Epic/Story/Ticket Gen, Execution, Completed | `appropriate` | Each phase runs as an isolated Claude agent. These are genuine reasoning tasks: interpreting ideas, exploring code, designing architecture, writing proposals, critiquing plans, generating tickets. |
| `ticket-planner` skill router | Entry point dispatch | `appropriate` | LLM agent dispatches phases — but the router (`planner-router.sh`) is bash. The skill is a thin wrapper. |

**ticket-planner summary:** 0 candidates. The planner achieves the same determinism boundary as ticket-auto: bash router + bash state management + bash validators, with LLM agents only in the reasoning phases.

## Overall system summary

| Category | Count |
|----------|-------|
| Deterministic bash paths | 31 |
| Appropriate LLM paths | 22 |
| Candidates for bash migration | **0** |

### The determinism boundary is correctly placed

Every component respects the same boundary:

```
┌─ Deterministic (bash) ───────────────────────────┐
│ State parsing, position derivation                │
│ Phase transition validation                       │
│ Label filter, priority sort, dispatch             │
│ Context block generation + validation             │
│ Confidence signal derivation                      │
│ Dependency acyclicity (tsort)                     │
│ Entity idempotency (intent→check→create)          │
│ Feedback emission + aggregation                   │
│ Detection engines (11)                            │
│ Gate checks (entry, reapprove)                    │
│ Kill escalation (stop-file→SIGTERM→SIGKILL)       │
│ Spawn queue management                            │
│ Exploration accuracy measurement (diff analysis)  │
└──────────────────────────────────────────────────┘
                        │
                        │ spawn + consume output
                        ▼
┌─ Non-deterministic (LLM) ────────────────────────┐
│ Codebase investigation + complexity scoring       │
│ Code changes + PR creation                        │
│ Playwright UAT verification                       │
│ PR code review                                    │
│ Requirements critique                             │
│ Retrospective analysis                            │
│ Prescan multi-persona fan-out                     │
│ Planner: all 12 phases (idea→tickets)             │
│ Fleet intervention decisions                      │
│ Epic comment content                              │
│ Gate reconciliation (human comment interpretation)│
└──────────────────────────────────────────────────┘
```

### Properties preserved

1. **No LLM ever mutates Linear state directly.** All mutations go through `flow.sh` (bash) or `planner-router.sh` (bash). LLMs reason; bash actuates.
2. **No LLM validates its own output.** Validation is always a separate deterministic pass: `planned-ticket-check.sh` for context blocks, `planner-deps-check.sh` for dependencies, `gate-check.sh` for pipeline gates.
3. **State recovery is deterministic.** Both ticket-auto and ticket-planner derive position by re-reading append-only logs — no state held in LLM context between invocations.
4. **Idempotency is mechanical.** The intent→check→create pattern is bash, not LLM best-effort. Crashes between steps produce exactly one entity.
5. **The Regenerate flag is an explicit gate.** The planner never silently ingests feedback — it requires an explicit flag. This prevents feedback loops from creating non-deterministic behavior that's hard to reason about.

### No regression risk

The determinism boundary has been stable since Part 3 (the first parts that added bash validators). Each subsequent part layered on without crossing it:

- Part 4 (dispatch): added bash dispatch, bash detectors
- Part 5 (feedback): added bash writer, bash aggregator
- Part 6 (exploration): added bash accuracy measurement, optional schema fields
- Part 7 (integration): added bash tests, documentation
- ticket-planner plugin: copied ticket-auto's boundary exactly — bash router/state/validation, LLM phases

### One deliberate gray area

The `ticket-planner` skill entry point is an LLM agent that dispatches phases. The underlying router (`planner-router.sh`) is bash. The skill is a thin wrapper that interprets the user's command (`plan`, `resume`, `status`) and calls the appropriate bash function. This is the same pattern as `/ticket-auto` — the LLM is the CLI parser, not the executor. It could be made fully bash with a CLI argument parser, but the current pattern (LLM as natural-language CLI) is the design choice across all skills in this marketplace. Changing it would be a marketplace-wide change, not a ticket-planner-specific one.
