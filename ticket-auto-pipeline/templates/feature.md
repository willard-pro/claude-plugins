# New Feature Template

> Copy everything below this line into the Linear ticket description.
> Fill in `{placeholders}`. Remove any sections that don't apply.
> Labels to set: `feature`

---

{Descriptive Name}

## Summary

{One sentence: what the feature does and who benefits.}

## Background / Motivation

{Why this is needed — business context, user pain point, or gap in the current system.}

## Proposed Behaviour

{How it should work, screen by screen or step by step. Be specific about UI elements, labels, and states.}

## Acceptance Criteria

- [ ] {Observable fact — e.g. "A 'Payment Reminder' option appears in the document type dropdown"}
- [ ] {Observable fact — e.g. "Submitting the form with a blank agent message shows a validation error"}
- [ ] {Observable fact}

> One criterion per line. No "and". No vague phrases like "feature works" or "is displayed correctly".

## Out of Scope

{What this ticket explicitly does NOT cover. Helps prevent scope creep during appraisal.}

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

{What must exist before verification can run — e.g. "Org with at least one active handover."}

## Related Tickets

{Linear IDs, or None}
