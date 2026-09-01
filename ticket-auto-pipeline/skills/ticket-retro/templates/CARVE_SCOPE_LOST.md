# CARVE_SCOPE_LOST — Planner Crosscheck Analysis Template

## Pattern

Specify declared it was generating N tickets to cover the proposal's scope
(`state.log`'s `|Specify|synthesize|start|...for N tickets` line), but the resulting
spec set doesn't actually carve up that scope cleanly — a piece of proposed scope has
no owning ticket, or was silently dropped between Specify and the final spec files.
Planner defect, not `ticket-auto`.

## What to Look For

In `ticket-planner/lib/planner-crosscheck-propagation.sh`
(`planner_crosscheck_carve_scope`): confirm the declared-ticket-count extraction from
`state.log` still matches the phrasing Specify's `state.log` entry actually uses — a
prompt wording change can break the `grep` this relies on.

If the count and scope mapping really don't line up, the fix is in
`ticket-planner/lib/planner-phase-prompts.sh` (`planner_prompt_specify`) — the agent
needs to account for 100% of the proposal's declared scope across its generated
tickets, not just hit a target count.

## Minimal Fix Pattern

Checker false-negative: fix the `state.log` count-extraction grep/parse. Real gap:
have Specify enumerate proposal scope items and map each to an owning ticket
explicitly before finalizing.

## Related

- `ticket-planner/lib/planner-crosscheck.sh` — orchestrator.
- GitHub #173 (propagation linter), #177 (this code reaching `/ticket-retro`).
