# Knowledge Curator

Durable cross-project knowledge tracking for Claude Code. Captures ideas, decisions, lessons, and discoveries with low friction, automatically resurfaces relevant items when you need them, and provides a dispatchable work stack for agent workflows.

## Architecture

Knowledge Curator sits as a **thin curation layer** over existing systems (claude-mem, Linear, openspec). It does not create a new silo — it delegates to those systems for what they already do well, and only stores what they don't.

```
        CAPTURE                     STORE                    SURFACE
  ┌──────────────────┐      ┌─────────────────┐      ┌──────────────────┐
  │ you state a      │      │ knowledge/       │      │ SessionStart     │
  │ decision/lesson  ├─────▶│  KC-0001--*.md   ├─────▶│  → top 5 injected│
  │ (auto-detected)  │      │  KC-0002--*.md   │      │                  │
  │                  │      │  KC-0003--*.md   │      │ UserPromptSubmit │
  │ /kc-capture      ├─────▶│  ...             ├─────▶│  → topic match   │
  │ /kc-import       │      │                  │      │                  │
  │ /kc-sweep (cron) ├─────▶│  INDEX.md ◀──────┼───┐  │ /kc              │
  └──────────────────┘      └────────┬─────────┘   │  │  → ranked stack  │
                                      │             │  └──────────────────┘
                                kc-item.sh ─────────┘
                             (flock, sole write path)
```

`knowledge/` files are the source of truth; `INDEX.md` is a disposable rendered view, rebuilt on every mutation. Deleting it loses nothing — the next `kc-item.sh` call or `/kc-sweep` regenerates it from item frontmatter. This mirrors the append-only-log-plus-cheap-index pattern used by `ticket-auto-pipeline`'s pipeline log.

Three automated trigger paths feed the knowledge store:
1. **SessionStart hook** — injects top-priority items at the start of every session
2. **UserPromptSubmit hook** — greps your prompt for matches against the knowledge index
3. **Cron scheduler** — runs a daily sweep over recent observations and plan files

See [docs/kc-architecture.svg](docs/kc-architecture.svg) for the full diagram (renders on GitHub; the block above is the terminal-readable equivalent).

## How it's triggered

### Automatic (no slash command needed)

| Trigger | What happens | Mechanism |
|---------|-------------|-----------|
| **Session starts** | Top 5 items (p1 first) injected as context. If p1 items exist, you see a visible stack summary. | `kc-resurface.sh` hook on `SessionStart` |
| **You mention a topic** | If your prompt contains terms matching knowledge item tags or titles, relevant items are injected as context. | `kc-prompt-match.sh` hook on `UserPromptSubmit` |
| **You make a decision** | `kc-capture` fires proactively when you state a decision, root-cause finding, "let's park this," "remind me about this," an unexpected discovery, or a lesson learned. | Skill description auto-trigger (Claude judges relevance) |
| **Daily sweep** | Reviews recent claude-mem observations and new plan files since last sweep. Promotes durable items, flags dormant/stale/abandoned items. | `CronCreate` on `kc-sweep` |
| **You approve a plan** | Items captured during plan mode (queued in `/tmp/`) are flushed to the knowledge store. | Manual flush step in `kc-capture` skill |

### Manual slash commands

| Command | What it does |
|---------|-------------|
| `/kc` | ASCII stack view, ranked by priority + age − blocked penalty. Top unblocked item highlighted. `done`/`obsolete` excluded, blocked items demoted not hidden. |
| `/kc dormant` | Show items not updated in 30+ days. Flag candidates for status review. |
| `/kc <query>` | Search by topic, tag, or title. Merges `knowledge/` grep results with claude-mem search. |
| `/kc --all-projects` | Cross-repo aggregated view. Scans sibling repos for `knowledge/` directories. |
| `/kc stats` | Ranking report card — how often the `NEXT` pick was the thing you actually claimed. Use it to retune the rank weights from evidence. |
| `/kc-capture` | Manually capture an idea, decision, lesson, or discovery. One item, one relationship suggestion. |
| `/kc-import` | Idempotent import from openspec changes, `~/.claude/plans/`, and Linear tickets. |
| `/kc-sweep` | Run a curation sweep over recent observations and plan files. Promotes durable items. |

### Proactive capture triggers

`kc-capture` fires automatically (no `/kc-capture` needed) when:

- A design approach is explicitly rejected and the reason is explained
- A root cause is found during debugging or investigation
- You say "let's park this," "note this down," "remind me about this," "we should remember this"
- An unexpected finding, insight, or discovery surfaces in conversation
- A decision is made that affects multiple projects or approaches
- A lesson is stated ("turns out...", "lesson learned...", "the key insight is...")

## Item lifecycle

Items follow a deterministic state machine enforced by `kc-item.sh`:

```
                       claim                  complete
             ┌───────────────────▶ in_progress ───────────────▶ done
             │                          │                    (terminal —
             │                          │ release             excluded from
    ┌────────┴────────┐                 │ (abandoned;         stack, kept
    │      active      │◀────────────────┘  no update >24h    on disk)
    └────────┬────────┘                     flags this)
             │      ▲
             │edit/ │claim
             │sweep │
             │(60d+ │
             │idle) │
             ▼      │
       ┌───────────┴┐
       │   dormant   │
       └─────────────┘

    active ──edit (manual)──▶ obsolete   (terminal — excluded from stack)
```

See [docs/kc-lifecycle.svg](docs/kc-lifecycle.svg) for the full diagram (renders on GitHub; the block above is the terminal-readable equivalent).

| Transition | Command | Guard |
|-----------|---------|-------|
| `active` → `in_progress` | `kc-item.sh claim` | Only from `active` or `dormant` |
| `in_progress` → `done` | `kc-item.sh complete` | Only from `in_progress` |
| `in_progress` → `active` | `kc-item.sh release` | Only from `in_progress` (abandoned dispatch) |
| `active` → `dormant` | `kc-item.sh edit` or sweep | Sweep flags after 60 days inactive |
| `active` → `obsolete` | `kc-item.sh edit` | Manual status change |
| Any → field update | `kc-item.sh edit` | Editable: `title`, `priority`, `tags`, `relates`, `project` |

**Stack visibility**: `active`, `in_progress`, and `dormant` items appear in `/kc` and hook injections. `done` and `obsolete` items are excluded from all stack views but their files remain on disk.

## Agent work contract

When you say "implement the top N" or "work through the stack," agents operate under a deterministic contract:

1. **Claim**: `kc-item.sh claim <id>` — marks item `in_progress`. Fails if already claimed by another agent.
2. **Work**: Agent does the work using the item's full markdown content as context.
3. **Complete**: `kc-item.sh complete <id>` — marks item `done`. Removes from stack. Fails if not `in_progress`.
4. **Discover**: `kc-item.sh add <file>` — files new discoveries with `source: agent:<id>` and `discovered-from` relation.
5. **Release**: `kc-item.sh release <id>` — releases claim if agent cannot complete. Item returns to `active`.

**Rules for agents**:
- Claim on start, complete on verified finish, release on failure
- Never fix discovered items in the same run — they go back on the stack
- Never touch other knowledge items — contract is per-item
- Never use the knowledge store as ambient context — only the assigned item

All mutations serialize through `flock` on `knowledge/.lock`. No two agents can mutate simultaneously.

## Item types

| Type | Use for | Typical source |
|------|--------|---------------|
| `idea` | Something worth exploring later | `kc-capture` |
| `proposal` | A structured change proposal | `kc-import` (openspec), `kc-capture` |
| `discovery` | Something learned during investigation | `kc-capture`, `kc-sweep` |
| `lesson` | A mistake or pattern worth remembering | `kc-capture` |
| `decision` | A design or architectural choice made | `kc-capture` |
| `reference` | Pointer to a ticket, PR, or external resource | `kc-import` (Linear) |
| `experiment` | A hypothesis to test | `kc-capture` |

## Priority levels

| Priority | Meaning | Sweep behavior |
|----------|---------|---------------|
| `p1` | Critical — demands attention soon | Flagged if not updated in 14 days |
| `p2` | Important — should be addressed | Default for new items |
| `p3` | Nice-to-have — low urgency | No staleness flag |

## Knowledge store format

Per-repo `knowledge/` directory:

```
knowledge/
├── INDEX.md                      # Generated summary, rebuilt on every mutation
├── .kc-item-registry             # ID list for vanished-item detection
├── .kc-sweep-marker              # Last sweep timestamp
├── .lock                         # flock mutex file
├── KC-0001--use-postgres.md      # One markdown file per item
├── KC-0002--memory-leak-fix.md
└── KC-0003--add-caching-layer.md
```

Each item file uses YAML frontmatter:

```yaml
---
id: KC-0001
type: decision
title: "Use Postgres for primary store"
status: active
priority: p1
project: my-project
created: 2026-07-06T18:00:00Z
updated: 2026-07-06T18:00:00Z
source: manual
why: "avoids running a second database just for search"
tags: [database, architecture]
relates:
  - rel: supersedes
    id: KC-0000
---
# Use Postgres for primary store

Context and details here. Written for a human reader who sees this days or weeks later.
```

`why` is a required, single-line field — the rationale behind the item, shown directly under the title in `/kc` output so the stack is self-explaining without opening each file.

## Worked example

Three items, captured over a few weeks: a `p1` decision, a `p2` idea that depends on it, and an old `p3` lesson nobody's revisited. Here's what `/kc` shows:

```
KNOWLEDGE STACK — my-project    3 items · 1 p1 · 0 in_progress

┌─ NEXT ────────────────────────────────────────────────────────────
│ KC-0001  decision   Use Postgres for primary store                         p1   22d ⚠
│          why: avoids running a second database just for search
└──────────────────────────────────────────────────────────────────

  KC-0003  lesson     Connection pool exhaustion under bursty load           p3   88d 💤
           why: default pool size silently caps concurrent requests at 10
  ── p2 ──
  KC-0002  idea       Add caching layer                                      p2   20d ▲
           why: read latency creeps up once the items table passes 10k rows
           └─ depends  KC-0001  Use Postgres for primary store

⚠ = p1 untouched 14d+   💤 = dormant/idle 60d+   ▲ = blocked on an open dependency
```

Three things worth noticing:

- **`KC-0001` is `NEXT`** — highest-ranked, and not waiting on anything.
- **`KC-0003` (p3) outranks `KC-0002` (p2)** — a stale-priority item nobody touched in 88 days floats up ahead of a fresher-but-blocked p2. This is the age-decay term working as designed: nothing rots silently at the bottom just because it started low-priority.
- **`KC-0002` is marked `▲` and demoted, not hidden** — it's blocked on `KC-0001` via `depends`, so its effective rank drops, but it still shows up with the relation spelled out (`depends → KC-0001`), not just an opaque ID.

This is what makes the stack self-explaining without opening any file: rank, rationale, and relationships are all visible in one screen.

## Is the ranking any good? (`/kc stats`)

The rank weights are a judgement call. There is no way to argue them right in the abstract — so the plugin measures them instead.

Every `/kc` render appends one line to `knowledge/.kc-rank-log` recording what it put in the `NEXT` box and the full display order; every `claim`, `complete`, and `release` appends its own line. `/kc stats` joins the two:

```
RANKING TELEMETRY     2026-06-14 → 2026-07-29

  42 renders · 18 claims

  NEXT box claimed           11  ( 61%)
  claimed from top 3          4  ( 22%)
  claimed further down        2  ( 11%)   avg position 6.0
  not on screen               1  (  6%)
  claimed without a render    0  (  0%)

  claims of blocked items     3
```

Read it like this:

| Signal | What it means | What to change |
|--------|---------------|----------------|
| High **NEXT box claimed** | The score matches how you actually work. | Nothing. |
| High **claimed further down** | The weights are misordering the stack — check `avg position` for how far off. | `priority_weight()` / the `age_bonus` line |
| High **claims of blocked items** | The blocked penalty is too harsh; you work on blocked things regardless. | the `- (blocked * 60)` term |
| High **claimed without a render** | The stack isn't being consulted at all. A workflow problem, not a scoring one. | — |

All three knobs are adjacent lines in `lib/kc-render.sh`. The numbers only mean something after a few weeks of real use — a handful of claims proves nothing either way.

The log is append-only, self-trimming at 1000 lines, and disabled entirely with `KC_RANK_LOG=0`. It records item IDs and timestamps — no titles, no content. Add `knowledge/.kc-rank-log` to your repo's `.gitignore`; it's local churn.

## Install

```
# From the marketplace (recommended)
claude plugins install willard-pro/knowledge-curator

# From source
claude plugins install ./claude-plugins/knowledge-curator
```

No configuration required. The `knowledge/` directory is created on first capture in each repo. Hooks register automatically via `plugin.json`.

## Design decisions

- **Thin curation layer**: Delegates to claude-mem for timeline/sequence, Linear for ticket state. Only stores what those don't.
- **Human-facing scope**: Items are written for human readability. Agents access via the deterministic work contract only — never as ambient context.
- **Low friction or bust**: One-shot capture with one relationship suggestion. Never a multi-question interrogation. Never auto-merge similar items.
- **Deterministic mutation boundary**: `kc-item.sh` is the sole agent mutation path (mirrors `flow.sh` pattern from ticket-auto-pipeline). `flock` serialization prevents parallel corruption.
- **Fail-open hooks**: Both SessionStart and UserPromptSubmit hooks exit 0 silently when `knowledge/` directory doesn't exist. A missing store is not an error.
- **Idempotent import**: Re-running import ingesters updates existing items by `source` field rather than creating duplicates.
- **Deterministic rendering**: `/kc` output comes from `lib/kc-render.sh` (bash, not an LLM judgment call), so the same store always renders the same stack — same rationale as the bash-gate pattern in ticket-auto-pipeline. Ranking is a hybrid score (priority weight + age decay − blocked penalty) rather than pure priority-first, so a blocked p1 doesn't camp at the top forever and an old p3 doesn't rot silently at the bottom.
- **Instrumented, not asserted**: the rank weights above are a guess until proven otherwise, so `lib/kc-rank-log.sh` records what each render promoted against what got claimed and `/kc stats` reports the agreement. Telemetry writers always return 0 — a broken or unwritable log can never break a render or a mutation.

## Limitations

- **Cross-project view (`/kc --all-projects`)**: Uses live filesystem scanning of sibling repos. Fast for a handful of repos (typical workspace), but may slow with dozens. Scan-based, not a prebuilt index.
- **claude-mem dependency**: Sweep observation promotion and sequence/ordering queries require claude-mem. Sweep degrades gracefully (plan files + administration still run without it).
- **No push-on-write**: INDEX.md is rebuilt on mutation, not pushed from external systems. Changes in Linear or openspec require re-running `/kc-import` to sync.
- **Single-repo store**: Each repo has its own `knowledge/` directory. Cross-project queries scan at query time rather than maintaining a central index.
