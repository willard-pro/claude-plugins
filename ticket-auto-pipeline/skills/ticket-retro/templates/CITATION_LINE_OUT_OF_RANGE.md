# CITATION_LINE_OUT_OF_RANGE — Planner Crosscheck Analysis Template

## Pattern

A `ticket-planner` Crosscheck run found a spec citation whose file resolves but whose
line number is past the end of the file (or otherwise implausible) — the file existed
but has since shrunk, or the cited line was never right. Planner defect, not
`ticket-auto`.

## What to Look For

In `ticket-planner/lib/planner-crosscheck-citations.sh` (`planner_crosscheck_citations_one`):
confirm the line-count comparison itself is correct (off-by-one against `wc -l`, or
comparing against the wrong file's line count in a multi-file citation).

More often the real fix is upstream in `ticket-planner/lib/planner-phase-prompts.sh`
(`planner_prompt_specify`) — the agent citing a line number from a version of the file
it explored earlier in the pipeline, before a later phase's proposed change shifted
line numbers underneath it.

## Minimal Fix Pattern

If checker logic is wrong, fix the bounds comparison. If it's a staleness problem,
have Specify re-verify citations against the current file state immediately before
writing them, rather than reusing line numbers carried from Discovery/Architecture.

## Related

- `ticket-planner/lib/planner-crosscheck.sh` — orchestrator.
- GitHub #172 (citation linter), #177 (this code reaching `/ticket-retro`).
