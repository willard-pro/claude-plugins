# Improvement Template

> Copy everything below this line into the Linear ticket description.
> Fill in `{placeholders}`. Remove any sections that don't apply.
> Labels to set: `improvement`

---

{Descriptive Name}

## Summary

{One sentence: which existing feature is being improved and how.}

## Current Behaviour

{What it does now — be specific enough that someone unfamiliar can reproduce the starting state.}

## Desired Behaviour

{What it should do instead. Delta only — describe the change, not the full feature.}

## Motivation

{Why the current behaviour is insufficient — user friction, data accuracy, performance, or business rule change.}

## Acceptance Criteria

- [ ] {Observable fact — e.g. "Pagination controls appear below the user list when results exceed 20 rows"}
- [ ] {Observable fact — e.g. "Navigating to page 2 preserves the active filter"}
- [ ] {Observable fact}

> One criterion per line. No "and". No vague phrases.

## Scope

| Layer | Service       | Area                         |
| ----- | ------------- | ---------------------------- |
| FE    | gateway       | {component / page}           |
| BE    | {service}     | {controller / entity / repo} |

## Test User

`{email or role}` — password `admin`

## Navigation Path

`{Menu > Submenu > Page}` — click-by-click; do NOT paste a URL.

## Test Data Prerequisites

{What must exist before verification can run — e.g. "More than 20 users registered in the org."}

## Related Tickets

{Linear IDs, or None}
