# Knowledge Curator

Durable cross-project knowledge tracking for Claude Code. Captures ideas, decisions, lessons, and discoveries with low friction, automatically resurfaces relevant items when you need them, and provides a dispatchable work stack.

## Why

Working across many projects, it's easy to lose track of issues raised, plans created, their sequence, priority, and how they relate. Traditional solutions fail because:

- **Manual capture tools die of neglect** — too much friction, too many fields
- **Knowledge fragments across systems** — claude-mem, Linear, openspec, auto-memory each own a piece
- **No automatic resurfacing** — you have to remember to query, which you won't

Knowledge Curator fixes this by being a **thin curation layer** over what already exists, not a new silo.

## What it does

- **Low-friction capture** (`kc-capture`): One-shot drafting with similar-item search. Proactively triggered in conversation — no slash command needed.
- **Automatic resurfacing**: Session start shows top-priority items. On-topic prompts surface relevant knowledge. You don't have to remember to query.
- **Scheduled sweep** (`kc-sweep`): Cron-driven backstop that reviews recent observations and promotes durable ones. Missed nothing is permanent.
- **Cross-project view** (`/kc --all-projects`): "What have I decided across all my repos?" in one query.
- **Dispatchable work stack**: `/kc` shows ranked outstanding items. "Implement the top 3" spawns agents with claim/complete/discover contract.

## Install

Add to your Claude Code plugins:

```
# From the marketplace (recommended)
claude plugins install willard-pro/knowledge-curator

# From source
claude plugins install ./claude-plugins/knowledge-curator
```

No configuration required. The `knowledge/` directory is created on first capture in each repo.

## Usage

| Command | What it does |
|---------|-------------|
| `/kc` | Show ranked outstanding items (p1 first, then staleness) |
| `/kc dormant` | Show items that haven't been updated recently |
| `/kc <query>` | Search by topic, tag, or title |
| `/kc --all-projects` | Cross-repo aggregated view |
| `/kc-capture` | Manually capture an idea, decision, or lesson |
| `/kc-import` | Import from openspec changes, plan files, and Linear |
| `/kc-sweep` | Run a curation sweep over recent observations |

Proactive capture: state a decision, root-cause finding, or "let's park this" in conversation and `kc-capture` fires automatically.

## Item types

| Type | Use for |
|------|--------|
| `idea` | Something worth exploring later |
| `proposal` | A structured change proposal (often from openspec) |
| `discovery` | Something learned during investigation |
| `lesson` | A mistake or pattern worth remembering |
| `decision` | A design or architectural choice made |
| `reference` | Pointer to a ticket, PR, or external resource |
| `experiment` | A hypothesis to test |

## How it works

- **Store**: Per-repo `knowledge/` directory with one markdown file per item + generated `INDEX.md`
- **Resurfacing**: SessionStart hook injects top-N items. UserPromptSubmit hook greps for tag/title matches.
- **Sweep**: Cron-registered review of claude-mem observations and plan files. Promotes durable items, flags dormant ones.
- **Import**: Idempotent ingestion from openspec changes, `~/.claude/plans/`, and Linear. Matched on `source:` field.

## Design philosophy

- **Thin layer, not new silo**: Delegates to claude-mem for timeline, Linear for ticket state. Only stores what those don't.
- **Human-facing**: Items are written for you to read and decide. Not ambient agent context.
- **Low friction or bust**: One-shot capture. Never a multi-question interrogation. Never auto-merge.
- **Deterministic mutation boundary**: Agents mutate only through `kc-item.sh` (mirrors `flow.sh` pattern).

## License

UNLICENSED — proprietary.
