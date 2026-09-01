# RESOLUTION_NOT_PROPAGATED — Planner Crosscheck Analysis Template

## Pattern

Consensus recorded a resolution for a review finding (a decision, a change to make),
but the resulting spec files never actually incorporated it — the ticket count Specify
declared doesn't line up with what's on disk, or a ticket spec still contradicts a
resolved item. Planner defect, not `ticket-auto`.

## What to Look For

In `ticket-planner/lib/planner-crosscheck-propagation.sh`
(`planner_crosscheck_consensus_propagation`, `planner_crosscheck_carve_scope`): confirm
the term-overlap heuristic used to match a consensus item against spec text isn't
producing false negatives for this specific finding's phrasing (see the file header —
it's backtick-identifier/significant-word overlap, not semantic diffing, so it can miss
a resolution that was applied but reworded).

If the checker correctly found a real gap, the fix belongs in
`ticket-planner/lib/planner-phase-prompts.sh` (`planner_prompt_specify` or
`planner_prompt_consensus`) — Specify needs to actually read Consensus's resolved
items and apply them, not just acknowledge them were decided.

## Minimal Fix Pattern

Checker false-negative: broaden the overlap heuristic for this pattern. Real gap:
tighten the Specify prompt to enumerate Consensus resolutions and require the spec to
address each one explicitly.

## Related

- `ticket-planner/lib/planner-crosscheck.sh` — orchestrator.
- GitHub #173 (propagation linter), #177 (this code reaching `/ticket-retro`).
