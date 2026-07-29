# CLAUDE.md — knowledge-curator

Plugin-level guidance for Claude Code when working inside this plugin directory. See also: [repo-level CLAUDE.md](../CLAUDE.md) for marketplace-wide conventions.

## Plugin purpose

Durable cross-project knowledge tracking. Captures ideas, decisions, lessons, and discoveries with low friction, automatically resurfaces relevant items, and provides a dispatchable work stack for agent workflows. Thin curation layer over existing systems (claude-mem, Linear, openspec) — does NOT create a new knowledge silo.

## Directory layout

```
knowledge-curator/
  .claude-plugin/plugin.json     # Plugin manifest (name, version, hooks)
  skills/                        # 4 skill directories: kc-capture, kc-query, kc-import, kc-sweep
  lib/                           # Shared bash libraries
  hooks/                          # SessionStart + UserPromptSubmit hooks
  docs/                          # Design docs and reference material
  README.md                      # User-facing documentation
  CLAUDE.md                      # This file
```

## Per-repo knowledge store

Each consuming repo gets a `knowledge/` directory at its root:
- `knowledge/KC-NNNN--<slug>.md` — one markdown file per item with YAML frontmatter
- `knowledge/INDEX.md` — generated summary of all items, rebuilt on every mutation
- `knowledge/.kc-rank-log` — ranking telemetry, append-only, self-trimming (see below). Local churn — add it to the consuming repo's `.gitignore`.

## Skill categories

### Core skills
- `kc-capture` — low-friction capture with similar-item search and relationship suggestion
- `kc-query` (`/kc`) — query/resurface behavior, dormant/priority ranking, cross-project rollup
- `kc-import` — idempotent ingesters from openspec, plan files, and Linear
- `kc-sweep` — scheduled curation sweep over recent observations and plan files

## Shared libraries (`lib/`)

| File | Purpose |
|------|---------|
| `kc-index.sh` | Rebuild `knowledge/INDEX.md` from item frontmatter. Called after every add/update. |
| `kc-item.sh` | Deterministic item mutation: `claim`, `complete`, `release`, `add`, `edit`, `status`. `flock`-serialized. Sole agent mutation path. |
| `kc-render.sh` | Deterministic ASCII stack renderer for `/kc` bare mode. Reads item files directly (not INDEX.md) so it can show `why` and full relation type. Hybrid rank score: priority + age decay − blocked penalty. Read-only, no mutation. |
| `kc-rank-log.sh` | Ranking telemetry. Source for `kc_rank_log` (append), run for `stats`. Records what each render promoted vs what got claimed, so the rank weights can be retuned from evidence. Append-only, fail-open, `KC_RANK_LOG=0` to disable. |
| `kc-resurface.sh` | SessionStart hook: inject top-N items as context when `knowledge/` exists. |
| `kc-prompt-match.sh` | UserPromptSubmit hook: grep prompt against INDEX.md tags/titles, inject matches. |

## Item frontmatter schema

```yaml
---
id: KC-0001
type: idea | proposal | discovery | lesson | decision | reference | experiment
title: "Short human-readable title"
status: active | in_progress | dormant | done | obsolete
priority: p1 | p2 | p3
project: <repo-slug>
created: 2026-07-06T18:00:00Z
updated: 2026-07-06T18:00:00Z
source: manual | openspec:<change> | linear:<ID> | claude-mem:<obs-id> | plan:<slug> | agent:<item-id>
why: "<one-line rationale — required>"
tags: [tag1, tag2]
relates:
  - rel: supersedes | contradicts | extends | depends | alternative | refines | discovered-from
    id: KC-NNNN
---
```

## Key design decisions

- **Thin curation layer**: Delegates to claude-mem for sequence/timeline, Linear for ticket priority/state. Never rebuilds what already exists.
- **Human-facing scope**: Items are written for human readability. Agents only consume via the work contract (claim/complete/add). The store is NOT ambient agent context.
- **Never auto-merge**: Two similar items always stay separate files; relationship recorded in `relates`, never combined.
- **Deterministic mutation boundary**: `kc-item.sh` is the sole agent mutation path (mirrors `flow.sh` pattern from ticket-auto-pipeline). `flock` serialization prevents parallel corruption.
- **Fail-open hooks**: Both SessionStart and UserPromptSubmit hooks exit 0 silently when `knowledge/` directory doesn't exist.
- **Plan-mode compatibility**: Resurfacing hooks fire normally (read-only). `kc-capture` queues writes during plan mode, flushes after approval.
- **The ranking is instrumented, not asserted**: the `/kc` rank weights are a judgement call that cannot be validated in the abstract. Rather than argue about them, `kc-rank-log.sh` records what each render promoted against what was actually claimed, and `/kc stats` reports the agreement. Writers are dumb and always return 0 — telemetry can never break a render or a mutation. Retune from the report, not from intuition.

## Related docs

- [README.md](README.md) — user-facing documentation with architecture and lifecycle diagrams
- [docs/kc-architecture.svg](docs/kc-architecture.svg) — system architecture flow diagram (triggers, capture, store, surface, agents)
- [docs/kc-lifecycle.svg](docs/kc-lifecycle.svg) — item state machine (active → in_progress → done, release path)
- [docs/qa-coverage-audit-2026-07-07.md](docs/qa-coverage-audit-2026-07-07.md) — test coverage audit (22 gaps found, all fixed)
- [Repo-level CLAUDE.md](../CLAUDE.md)
- [ticket-auto-pipeline CLAUDE.md](../ticket-auto-pipeline/CLAUDE.md) — plugin anatomy reference
