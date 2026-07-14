# Chore / Maintenance Template

> Copy everything below this line into the Linear ticket description.
> Fill in `{placeholders}`. Remove any sections that don't apply.
> Labels to set: `chore`

---

{Descriptive Name}

## Summary

{One sentence: what maintenance task is needed and why now.}

## Background / Motivation

{Why this chore is needed — tech debt reduction, dependency update, tooling improvement, performance optimization, or infrastructure change.}

## Proposed Changes

{What should be done — be specific about files, packages, configurations, or processes affected.}

## Acceptance Criteria

- [ ] {Observable fact — e.g. "All dependencies are updated to latest compatible versions"}
- [ ] {Observable fact — e.g. "Build passes without deprecation warnings"}
- [ ] {Observable fact}

> One criterion per line. No "and". No vague phrases like "dependencies are up to date".

## Out of Scope

{What this chore explicitly does NOT cover. Helps prevent scope creep.}

## Scope

| Layer | Service       | Area                         |
| ----- | ------------- | ---------------------------- |
| BE    | {service}     | {package / module}           |
| Infra | {system}      | {component}                  |

## Test User

`{email or role}` — password `admin`

## Environment

- [ ] Local (`http://localhost:9000`)
- [ ] UAT (`https://uat.credit-network.biz/`)

## Related Tickets

{Linear IDs, or None}
