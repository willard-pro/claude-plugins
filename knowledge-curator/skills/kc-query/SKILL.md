---
name: kc-query
description: Query the knowledge store. Bare "/kc" shows the ranked outstanding stack (p1 first, then by staleness). "/kc dormant" shows items not updated recently. "/kc <query>" searches by topic, tag, or title across the knowledge store and claude-mem. "/kc --all-projects" aggregates across sibling repos. Use for "what do we know about X", "show me the knowledge stack", "what should I work on next", and any knowledge-related query.
---

# Knowledge Query (/kc)

Query and resurface knowledge items. Four modes depending on arguments.

## Mode 1: Bare `/kc` — ranked stack view

Show the outstanding items ranked: p1 items first (by updated timestamp, oldest first), then p2 items (by updated timestamp, oldest first), then p3. Exclude `done` and `obsolete` items.

Read from `knowledge/INDEX.md`:

```bash
cat knowledge/INDEX.md
```

Present as a clean table with the top items. If p1 items exist, prefix with: "**N p1 item(s) need attention.**"

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
