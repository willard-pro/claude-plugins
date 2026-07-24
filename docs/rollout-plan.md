# Ticket-Planner Rollout Plan

> Documents the rollout sequence for the 7-part ticket-planner integration program.
> Written 2026-07-24 as Part 7 (integration) closes the final gaps.

## Rollout order

The program shipped in dependency order. Each phase layered on the previous — earlier phases could not depend on later ones.

| Phase | Part | Change | What landed | Verification |
|-------|------|--------|-------------|-------------|
| 1 | Part 1 | `fleet-controller-extraction` | Fleet controller extracted to its own plugin. All fleet scripts, detectors, intervention, dashboard moved out of `ticket-auto-pipeline/lib/`. | No stale `fleet-*` references in ticket-auto-pipeline; fleet-controller plugin self-contained with its own `lib/` and `skills/`. |
| 2 | Part 2 | `ticket-planner-enrichment` | `## Planner Context` block schema defined, `planned`/`pre-approved`/`Type` labels registered, `planned-ticket-check.sh` validator shipped. | Validator passes Schema-Version 1 blocks; labels recognized by `state-machine.json`. |
| 3 | Part 3 | `ticket-appraise-fast-path` | ticket-auto appraise consumes Planner Context blocks. Fast-path skips codebase grep for `planned` + valid context + confidence ≥ threshold. Gate Check 2.7 validates context. | Appraise fast-path triggers for planned tickets; unplanned tickets unaffected. |
| 4 | Part 3.5 | `ticket-planner-templates` | Ticket body contract (`body.md`, `exploration.md`, `proposal.md`), type-to-template resolution, `planner-artifacts.sh`. | Templates resolve deterministically; body completeness validated at gate. |
| 5 | Part 4 | `fleet-controller-dispatch` | `fleet-dispatch.sh` enqueues eligible planned children from initiative epics. `blocked-by` resolution, priority sort, spawn queue JSONL. | Dispatcher respects `FLEET_MAX_CONCURRENT`; blocked children skipped; idempotent across cycles. |
| 6 | Part 5 | `ticket-planner-feedback-loop` | `fleet-feedback.sh` aggregates `META\|planner-feedback` pipeline-log entries into per-initiative JSON. `planned-feedback-write.sh` emits the entries. Epic comment backchannel. | Feedback JSON written to `{initiative_dir}/feedback/{rundate}.json`; aggregation includes confidence drift. |
| 7 | Part 6 | `ticket-planner-exploration` | Discovery phase depth tiers (quick-scan/standard/deep). Schema-Version 2 with 5 new optional context fields. Exploration accuracy feedback (`missed_symbols`, `false_traces`). | Depth mismatch warns at gate; accuracy fields populated in feedback; `exploration-depth-levels.md` and `discovery-phase-spec.md` reference docs shipped. |
| 8 | Part 7 | `ticket-planner-integration` | **This change.** Wiring, E2E tests, determinism audit, cross-plugin consistency. No new functional code — ties everything together. | Full test suite passes; determinism audit complete; marketplace.json and CLAUDE.md references consistent. |

### Dependency graph

```
Part 1 (extraction)
  └─→ Part 2 (enrichment)
        ├─→ Part 3 (fast-path)
        │     └─→ Part 3.5 (templates)
        ├─→ Part 4 (dispatch)
        │     └─→ Part 6 (exploration) — extends Parts 3 & 5 schemas
        └─→ Part 5 (feedback)
              └─→ Part 6 (exploration) — extends Part 5 feedback fields
                    └─→ Part 7 (integration) — wires all, always last
```

### Parallel work

`ticket-planner-plugin` (the 12-phase planner producer) was built in parallel with the consumption-side integration. Its groups 1-8 ship independently; group 9 (full end-to-end verification) waits on `fleetd`.

`fleetd-supervisor-daemon` (Python supervisor) shipped alongside Phase 5 — it owns worker lifecycle and is required for headless spawn, which E2E tests need.

## Gating criteria per phase

Each phase must satisfy these before the next begins:

| Gate | Criteria |
|------|----------|
| **Tests** | All tests in the phase's scope pass (`make test`). No regressions in prior phases. |
| **Smoke** | Manual smoke test against live Linear: labels appear, context block is visible, no unexpected mutations. |
| **Rollback** | Rollback procedure documented and tested. Each phase is independently revertible. |
| **Docs** | Reference docs updated (CLAUDE.md, plugin-overview.md, state-machine.json if labels changed). |

## Rollback per phase

Each phase is additive — features layer on, they don't transform existing behavior. Rollback is reverting the change's merge commit. No phase modifies a prior phase's data format in a backward-incompatible way.

| Phase | Rollback impact |
|-------|----------------|
| Part 1 | Fleet controller disappears from marketplace. Running fleet monitor processes continue until killed; no new ones spawn. ticket-auto-pipeline unaffected. |
| Part 2 | `planned` label remains on existing tickets (Linear data, not code). New tickets created without Planner Context block. Validator removed but existing blocks are passive markdown. |
| Part 3 | Appraise falls back to full investigation for planned tickets. No data loss — investigation is the slower default. |
| Part 3.5 | Template selection falls back to generic. Existing `body.md`/`exploration.md`/`proposal.md` artifacts remain on disk (passive). |
| Part 4 | Auto-dispatch stops. Existing spawn-queue entries age out. Manually dispatched tickets continue. |
| Part 5 | Feedback aggregation stops. Existing `feedback/*.json` files remain on disk. Planner operates without feedback signal (same as before Part 5). |
| Part 6 | Schema-Version 2 fields ignored (backward-compatible by design — all new fields are optional). Validator accepts both versions. |
| Part 7 | No functional rollback needed — integration tests and audit docs are passive. Cross-plugin reference fixes stay fixed. |

## Verification checkpoints

### Checkpoint A: After Phase 3 (first end-to-end slice)
- Planned ticket created manually (Planner Context block pasted into description)
- Appraise fast-path triggers, skips codebase grep
- Gate Check 2.7 passes
- Standard pipeline completes (implement, verify, merge)

### Checkpoint B: After Phase 5 (dispatch + feedback)
- Initiative epic with `state:execution` + planned children
- Fleet detector finds undispatched children
- Dispatch enqueues eligible tickets (respecting blocked-by, priority, concurrency)
- Worker completes one ticket → `META|planner-feedback` line in pipeline log
- Feedback aggregated to initiative directory

### Checkpoint C: After Phase 6 (exploration depth)
- Discovery phase selects depth tier based on complexity
- Exploration context fields populated in Planner Context block
- Exploration accuracy measured post-implement (missed symbols, false traces)
- Depth mismatch warns at gate

### Checkpoint D: After Phase 7 (integration — this change)
- Full test suite passes
- Determinism audit complete with classification table
- Cross-plugin references consistent
- `openspec validate` passes on all 6 changes

## Final state

After all 8 phases (7 parts + templates), the system supports:

1. **Plan**: ticket-planner transforms business ideas into initiatives, epics, and planned tickets with structured context blocks
2. **Dispatch**: fleet-controller detects initiatives, resolves dependencies, enqueues tickets
3. **Execute**: ticket-auto appraises (fast-path for planned), implements, verifies, merges
4. **Feedback**: post-implement hook emits planner feedback; fleet aggregates it by initiative
5. **Learn**: planner reads aggregated feedback on Regenerate flag; confidence drift informs re-planning
6. **Observe**: dashboard Initiatives tab surfaces the full flow
