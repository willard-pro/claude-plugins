# app-knowledge

> Reference knowledge base for app business rules, user roles, UI behaviour, and system conventions. A lookup reference — not an interactive skill.

## What it does

`app-knowledge` is a living reference file rather than an interactive skill — agents read it directly to look up domain facts rather than invoking it as a command. It records business rules, user role definitions, UI behaviour patterns, and system conventions discovered during Playwright sessions and ticket work. Instead of re-deriving the same "what does this role see?" or "what does this field mean?" logic on every ticket, agents consult this file first. New learnings get appended to the relevant section over time so the file grows more useful with each ticket processed.

## How to use

Read the file directly when you need domain context — no slash command required:

```bash
cat ~/.claude/skills/app-knowledge/SKILL.md
```

To add a new learning, append it under the relevant section at the bottom.

Referenced automatically by: `/ticket-verify`, `/ticket-reproduce`.

## Inputs

| Input | Source | Required |
|-------|--------|----------|
| N/A | This skill is read-only reference material | — |

## Outputs / Artifacts

| Artifact | Location | Description |
|----------|----------|-------------|
| N/A | — | No active output; content is the artifact |

## How it works

```mermaid
flowchart TD
    A([Agent needs domain knowledge]) --> B[Read app-knowledge/SKILL.md\ndirectly]
    B --> C{Knowledge found?}
    C -- yes --> D[Apply to current task\nrole / behaviour / convention]
    C -- no --> E[Derive from Playwright\nobservation]
    E --> F[Append new learning\nto app-knowledge]
    D --> G([Continue task])
    F --> G
```

## Related skills

- [`/nav-hints`](nav-hints.md) — click-by-click navigation companion
- [`/ticket-verify`](ticket-verify.md) — primary consumer during UAT sessions
- [`/ticket-reproduce`](ticket-reproduce.md) — reads app-knowledge during bug reproduction
