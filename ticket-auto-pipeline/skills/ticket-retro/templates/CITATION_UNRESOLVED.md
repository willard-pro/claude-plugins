# CITATION_UNRESOLVED — Planner Crosscheck Analysis Template

## Pattern

A `ticket-planner` Crosscheck run found a spec that cites a `path:line` or a
`symbol:path:line` Signals.TargetSymbols entry that does not resolve against
`REPOS_ROOT` — the file doesn't exist, or the symbol isn't found in it. This is a
planner defect, not a `ticket-auto` one: the finding names a spec the planner itself
wrote.

## What to Look For

In `ticket-planner/lib/planner-crosscheck-citations.sh` (`planner_crosscheck_citations_one`):

1. Is the citation format the check expects still what Specify actually emits?
2. Is `REPOS_ROOT` resolution correct for the repo the citation targets (multi-repo
   initiatives)?

The likelier root cause is upstream, in `ticket-planner/lib/planner-phase-prompts.sh`
(`planner_prompt_specify`): is the agent citing paths from stale exploration context
(a `discovery.md` written before a later architecture change), or citing a symbol it
never actually verified against the repo?

## Minimal Fix Pattern

If the checker's parsing is wrong, fix the regex/extraction in
`planner-crosscheck-citations.sh`. If the citations themselves are the problem,
tighten the Specify prompt to require verifying each citation against a live grep
before writing it, not just carrying it forward from Discovery.

## Related

- `ticket-planner/lib/planner-crosscheck.sh` — orchestrator, writes the
  `META|crosscheck|fail|CITATION_UNRESOLVED ...` line this template was matched on.
- GitHub #172 (citation linter), #177 (this code reaching `/ticket-retro`).
