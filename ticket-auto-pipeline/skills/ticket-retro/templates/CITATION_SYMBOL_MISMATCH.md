# CITATION_SYMBOL_MISMATCH — Planner Crosscheck Analysis Template

## Pattern

A `ticket-planner` Crosscheck run found a spec claiming a symbol (function, class,
etc.) exists at a cited `path:line`, or that the spec "mirrors the existing `X`", but
the named symbol isn't actually there. Planner defect, not `ticket-auto`.

## What to Look For

In `ticket-planner/lib/planner-crosscheck-citations.sh`: confirm the symbol-extraction
regex handles the target language's declaration syntax (this is the check most
sensitive to language-specific edge cases — decorators, generics, multi-line
signatures).

Root cause is more often upstream, in `ticket-planner/lib/planner-phase-prompts.sh`
(`planner_prompt_specify` or `planner_prompt_architecture`) — a precedent claim
("mirrors the existing X") made from memory/pattern-matching rather than a verified
grep against the live repo.

## Minimal Fix Pattern

If the checker's symbol regex is too narrow, widen it for the language in question.
If citations themselves are unverified, require the Specify prompt to grep for the
symbol before asserting a precedent.

## Related

- `ticket-planner/lib/planner-crosscheck.sh` — orchestrator.
- GitHub #172 (citation linter), #177 (this code reaching `/ticket-retro`).
