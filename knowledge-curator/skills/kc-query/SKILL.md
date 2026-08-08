---
name: kc-query
description: Query the knowledge store. Bare "/kc" shows the ranked outstanding stack (p1 first, then by staleness). "/kc dormant" shows items not updated recently. "/kc <query>" searches by topic, tag, or title across the knowledge store and claude-mem. "/kc --all-projects" aggregates across sibling repos. "/kc stats" reports whether the ranking matches what you actually work on. Use for "what do we know about X", "show me the knowledge stack", "what should I work on next", and any knowledge-related query.
---

# Knowledge Query (/kc)

Query and resurface knowledge items. Five modes depending on arguments.

## Mode 1: Bare `/kc` — ranked stack view

Render the deterministic ASCII stack view. This is a bash script, not an LLM judgment call — the same store always renders the same way:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/lib/kc-render.sh" knowledge
```

Print its output verbatim in a code block — do not re-summarize or re-rank it. It ranks by a hybrid score (priority + age decay − blocked penalty, see `lib/kc-render.sh` header comment), highlights the top unblocked item in a `NEXT` box, and shows each item's `why` line plus depth-1 relations with the relation type preserved (e.g. `depends → KC-0002`). `done`/`obsolete` items are excluded; blocked items are demoted, never hidden.

Every render is logged to `knowledge/.kc-rank-log` (see Mode 5) — that is what makes the ranking auditable rather than a black box.

## Mode 2: `/kc dormant` — staleness view

Show items whose `updated` timestamp is more than 30 days ago. Sort by staleness (oldest first). Flag items that may need re-evaluation or status change.

```bash
# Find dormant candidates from INDEX.md
awk '/^\| KC-/ && /active|dormant/' knowledge/INDEX.md
```

## Mode 3: `/kc <query>` — topic search

Search for items matching the query text. Merge results from two sources:

1. **knowledge/ grep**: grep the query terms against `knowledge/INDEX.md` and against individual item file titles
2. **claude-mem search**: run `mem-search query="<query>" limit=5` for conversation-level matches

Present knowledge items first (more durable), then claude-mem observations (more ephemeral). Clearly label which is which.

## Mode 4: `/kc --all-projects` — cross-project view

Scan sibling repositories for `knowledge/` directories. Use `REPOS_ROOT` from CLAUDE.md, or default to walking the git root's parent directory.

```bash
for repo in $(ls -d ../*/ 2>/dev/null); do
  if [ -f "${repo}knowledge/INDEX.md" ]; then
    echo "### $(basename $repo)"
    grep '^| KC-' "${repo}knowledge/INDEX.md" | head -10
    echo ""
  fi
done
```

Aggregate and apply the same ranking rules as Mode 1 across all discovered repos. Note in the output that this is a live scan (may slow with many repos — documented limitation).

## Mode 5: `/kc stats` — is the ranking any good?

Report how often the `NEXT` box matched what actually got claimed:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/lib/kc-render.sh" --stats knowledge
```

Print the output verbatim. It reports facts, not a verdict — there is no "correct" agreement rate, only the trend and what it implies:

| Signal | What it means | Where to retune |
|--------|---------------|-----------------|
| High **NEXT box claimed** | The score matches how you work. Leave it alone. | — |
| High **claimed further down** | Priority/age weights are misordering the stack. Check `avg position`. | `priority_weight()` / `age_bonus` in `lib/kc-render.sh` |
| High **claims of blocked items** | The blocked penalty is too harsh — you work on blocked things anyway. | the `- (blocked * 60)` term |
| High **claimed without a render** | The stack isn't being consulted at all — a workflow signal, not a scoring one. | — |

Do not offer to retune the weights off a handful of claims. The numbers only mean something after a few weeks of real use. If the user asks for a change, it is confined to `priority_weight()`, the `age_bonus` line, and the `- (blocked * 60)` term in `lib/kc-render.sh`.

## Sequence/timeline questions — delegate to claude-mem

When the user asks "in what order did X happen" or "what was the sequence of...", delegate to claude-mem rather than trying to reconstruct from knowledge item timestamps:

```
mem-search query="<sequence topic>" limit=10
```

Follow up with `timeline(anchor=<obs-id>)` for context around the key observation. Knowledge items only carry `created`/`updated` timestamps — not detailed event history.

## Agent dispatch workflow

When the user says "implement the top N" or "work through the stack":

1. Show the top-N ranked items
2. For each item, spawn an agent with the item content as context
3. Each agent MUST: `kc-item.sh claim <id>` on start, `kc-item.sh complete <id>` on verified completion, `kc-item.sh add <file>` for any durable discoveries (with `source: agent:<id>` and `discovered-from` relation)
4. Agents MUST NOT: fix discovered items in the same run, touch other knowledge items, use the knowledge store as ambient context

The agent prompt should include the item's full markdown content and these instructions.
