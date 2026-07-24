# Exploration Depth Levels

Defines the three exploration depth tiers used by ticket-planner's Discovery phase (openspec-explore). See also: [discovery-phase-spec.md](discovery-phase-spec.md), [planner-context-schema.md](planner-context-schema.md).

## Overview

Exploration depth controls how thoroughly openspec-explore investigates the codebase during the planner's Discovery phase. The planner selects depth based on initiative risk, complexity, service novelty, and confidence. The declared depth is recorded in the `Exploration Depth` field of the `## Planner Context` block (Schema-Version 2).

## Depth Levels

### quick-scan

**When to use:** Simple bugs, well-known services, low-risk changes.

| Dimension | Expectation |
|---|---|
| Criteria | Single service, well-understood code, low risk, high planner confidence |
| Target Symbols | List of relevant functions/classes with file paths |
| Affected Files | Files likely to be changed |
| Approaches | 1 identified approach |
| API Contract Analysis | None |
| Dependency Graph | None |
| Risk Assessment | Implicit (low risk by definition) |
| Open Questions | May be empty |
| Time Budget | ~2 agent turns |
| Artifact Output | `Target Symbols` + `Affected Services` populated in Planner Context |

**Example:** Fix a typo in an error message, add a missing null check, update a configuration value.

### standard

**When to use:** Feature work, moderate complexity, medium confidence.

| Dimension | Expectation |
|---|---|
| Criteria | 1-3 services, moderate complexity, standard risk profile |
| Target Symbols | Primary symbols with call chain context (3-5 levels deep) |
| Affected Files | Full list of files in traced call chains |
| Approaches | 2-3 approaches compared with brief rationale |
| API Contract Analysis | For services touched — endpoints, request/response shapes, error modes |
| Dependency Graph | Call chain tracing (not full graph) |
| Risk Assessment | Key risks surfaced per approach |
| Open Questions | Unresolved items listed |
| Time Budget | ~5 agent turns |
| Artifact Output | All Planner Context fields populated; exploration notes in planner workspace |

**Example:** Add a new payment method to the debt collector, extend an API endpoint with an optional field, add a notification on state transition.

### deep

**When to use:** Architectural changes, new services, high risk, low confidence, novel services.

| Dimension | Expectation |
|---|---|
| Criteria | 3+ services or new service introduction, architectural pattern change, high risk, any novel service |
| Target Symbols | Exhaustive symbol tracing across all affected services |
| Affected Files | Complete file list from full dependency graph |
| Approaches | 3+ approaches with tradeoff tables (coupling, latency, complexity, risk) |
| API Contract Analysis | Full contract diffs — current vs. proposed for each endpoint |
| Dependency Graph | Full dependency graph (upstream callers, downstream callees, data flow) |
| Risk Assessment | Structured risk register with likelihood × impact per risk |
| Spike Recommendations | When investigation can't resolve a question, recommend a spike |
| Open Questions | May be non-empty (unresolvable without spike) |
| Time Budget | ~10+ agent turns |
| Artifact Output | All Planner Context fields populated; full exploration notes; dependency graph; risk register; spike recommendations in planner workspace |

**Example:** Extract payment processing into a new microservice, replace the authentication system, add a new major feature spanning 3+ services.

**Gate:** `deep` exploration blocks ticket creation until exploration completes. If exploration cannot complete (unresolved questions, missing data), the initiative is flagged for human architectural decision.

## Depth Selection Heuristics

The planner selects depth based on a risk × complexity matrix, modified by confidence and service novelty:

```
                    Low Risk          Medium Risk        High Risk
Low Complexity      quick-scan        standard           deep
Medium Complexity   standard          standard           deep
High Complexity     deep              deep               deep
```

**Modifiers:**
- **Confidence < 0.5:** Floor at `standard` — never use `quick-scan` when confidence is low.
- **Novel service** (no prescan docs, no prior tickets): Force `deep` regardless of risk/complexity.
- **Regenerate flag:** If `Regenerate: true`, minimum `standard` — the planner is re-evaluating.

## Depth Mismatch Detection

`lib/planned-ticket-check.sh::check_exploration_depth_mismatch` detects inconsistencies:

| Mismatch | Signal | Action |
|---|---|---|
| `quick-scan` + complex ticket | WARN | stderr warning; gate surfaces as soft signal |
| `quick-scan` + 5+ services | WARN | stderr warning; gate surfaces as soft signal |
| `deep` + simple single-service | NOTE (no block) | Logged but not surfaced |

Mismatches are signals, not blocks. A human decides whether to escalate.

## Feedback Loop

The `exploration_depth_actual` field in `META|planner-feedback` tracks whether the declared depth was sufficient:

- **`quick-scan` / `standard` / `deep`**: Declared depth was sufficient — implementation touched only traced symbols.
- **`insufficient`**: Implementation touched symbols NOT in `Code Paths Traced` — exploration missed relevant code.

`fleet-feedback.sh` aggregates `insufficient` ratios per initiative, feeding back to the planner to adjust default depth for affected services.
