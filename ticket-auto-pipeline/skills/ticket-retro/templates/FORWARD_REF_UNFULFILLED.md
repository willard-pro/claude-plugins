# FORWARD_REF_UNFULFILLED — Planner Crosscheck Analysis Template

## Pattern

A ticket spec references a structure, field, or capability that a later ticket in the
same initiative is supposed to provide, but no ticket in the set actually delivers it
— a forward reference that never resolves anywhere in the generated spec set. Planner
defect, not `ticket-auto`.

## What to Look For

In `ticket-planner/lib/planner-crosscheck-propagation.sh`
(`planner_crosscheck_forward_references`, see `_PLANNER_CROSSCHECK_FORWARD_REF_PATTERNS`):
confirm the forward-reference phrase patterns still match how Specify actually phrases
"will be added by ticket X" / "provided by a later ticket" language — a prompt wording
change can silently make this check blind.

If the pattern matched correctly, the gap is in `ticket-planner/lib/planner-phase-prompts.sh`
(`planner_prompt_specify`) — either the referencing ticket is wrong about which sibling
ticket owns the structure, or the owning ticket's spec was never written to actually
provide it.

## Minimal Fix Pattern

Checker false-negative: add/adjust a pattern in `_PLANNER_CROSSCHECK_FORWARD_REF_PATTERNS`.
Real gap: have Specify cross-reference sibling ticket specs before finalizing a forward
reference, not just assert one exists.

## Related

- `ticket-planner/lib/planner-crosscheck.sh` — orchestrator.
- GitHub #173 (propagation linter), #177 (this code reaching `/ticket-retro`).
