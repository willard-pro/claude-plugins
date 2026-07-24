# Discovery Phase Specification

Defines how openspec-explore integrates into ticket-planner's Discovery phase. See also: [exploration-depth-levels.md](exploration-depth-levels.md).

## Role in the Planner State Machine

```
Appraisal → Discovery → Architecture → Proposal → Review → Consensus →
OpenSpec → Epic Gen → Story Gen → Ticket Gen → Execution → Completed
```

Discovery is the second phase. It investigates what exists and what's possible. Architecture (next phase) decides what to build using Discovery's outputs.

## Integration Model

**Decision (D-1): openspec-explore IS Discovery.** The planner's Discovery phase is not a wrapper that calls explore — it IS `/opsx:explore` invoked with a structured prompt. openspec-explore's five core activities fully cover Discovery's needs:

| openspec-explore Activity | Discovery Use |
|---|---|
| Explore the problem space | Clarify initiative scope, challenge assumptions |
| Investigate the codebase | Trace symbols, map call chains, analyze APIs |
| Compare options | Evaluate architectural approaches with tradeoffs |
| Visualize | ASCII diagrams of data flows, dependencies |
| Surface risks and unknowns | Identify failure points, flag investigation gaps |

## Invocation Pattern

The planner invokes openspec-explore with a structured prompt when transitioning from Appraisal to Discovery:

```
/opsx:explore "Initiative {ID}: investigate {Target Services}, trace {Key Symbols},
  compare architectural approaches, surface risks. Depth: {depth-level}."
```

**Parameters:**
- `{ID}`: Initiative identifier (e.g., `INIT-42`)
- `{Target Services}`: Comma-separated service names from Appraisal phase
- `{Key Symbols}`: Initial symbol hints from Appraisal (may be empty for novel services)
- `{depth-level}`: One of `quick-scan`, `standard`, `deep` — selected by planner using the heuristics in [exploration-depth-levels.md](exploration-depth-levels.md)

## Artifact Output

Exploration produces markdown artifacts in the planner's workspace. Only summaries flow into the Planner Context block; detailed artifacts stay in the planner's domain.

### Planner Context Fields (flow to ticket-auto)

| Field | Schema-Version | Required | Source |
|---|---|---|---|
| `Exploration Depth` | 2 | No | Planner declares intended depth |
| `Code Paths Traced` | 2 | No | Symbols traced during exploration |
| `API Contracts Analyzed` | 2 | No | Endpoints whose contracts were reviewed |
| `Alternative Approaches` | 2 | No | Approaches considered and rejected |
| `Open Questions` | 2 | No | Unresolved investigation items |

### Planner Workspace Artifacts (stay in planner domain)

- Full exploration notes (markdown)
- Dependency graph (ASCII diagram for `deep`)
- Risk register (`deep` only)
- Spike recommendations (`deep` only)
- API contract diffs (`deep` only)

## Discovery → Architecture Handoff

When Discovery completes, Architecture receives:

1. **Traced call chains**: `Code Paths Traced` — Architecture uses these to scope the change, not to re-investigate.
2. **API contract analysis**: `API Contracts Analyzed` — Architecture understands current contracts before designing changes.
3. **Alternative approaches**: `Alternative Approaches` — Architecture knows what was rejected and why.
4. **Open questions**: `Open Questions` — Architecture knows what's still uncertain.
5. **Risk register** (`deep` only): Structured risks — Architecture designs mitigations.

**Constraint:** Architecture SHALL NOT re-investigate symbols already traced during Discovery. If exploration was `deep`, the Architecture phase starts with a complete map.

## Gates

### deep Exploration Gate

When depth is `deep`, ticket creation is blocked until exploration completes. The planner SHALL NOT transition to Architecture if:
- No dependency graph was produced (exploration failed or was interrupted)
- Required `deep` artifacts are missing (risk register, API contract diffs)

Incomplete `deep` exploration → either re-enter Discovery or flag initiative for human review.

### Incomplete Exploration Gate

When exploration did not complete at any depth level (e.g., openspec-explore timed out or hit an error), the planner SHALL:
1. Retry at the same depth level (once)
2. If still incomplete, fall back to `standard` depth and flag the initiative
3. Surface the incompleteness in `Open Questions`

## explore → propose Flow

When exploration crystallizes findings into a clear approach, openspec-explore offers to transition to `openspec-propose`:

> "Ready to start? I can create a change proposal."

The planner then transitions Discovery → Architecture → Proposal. If exploration does NOT crystallize (multiple approaches with no clear winner, unresolved questions), the planner flags the initiative for human architectural decision.

## Determinism Boundary

openspec-explore is an LLM-based skill — the exploration itself is non-deterministic. The handoff contract (Planner Context fields) is deterministic: field names, formats, and validation rules are defined by `lib/planned-ticket-check.sh`. The exploration accuracy feedback loop (`exploration_depth_actual`, `missed_symbols`, `false_traces`) provides deterministic measurement of exploration quality.
