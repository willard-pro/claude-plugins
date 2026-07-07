---
name: kc-capture
description: Low-friction knowledge capture. Use proactively whenever a durable idea, decision, lesson, or discovery emerges in conversation — especially when a design approach is rejected (and why), a root cause is found, the user says "let's park this" or "remind me about this", or an unexpected finding surfaces. Also use when the user explicitly says "/kc-capture" or "capture this". Single-pass drafting: one item, one relationship suggestion. Never auto-merge.
---

# Knowledge Capture

Capture a durable knowledge item from the current conversation. Write one markdown file in `knowledge/` with YAML frontmatter, then suggest one relationship to an existing item. Never auto-merge — always write a separate file.

## When to fire (proactive triggers)

Invoke this skill WITHOUT the user typing `/kc-capture` when:
- A design approach is explicitly rejected and the reason is explained
- A root cause is found during debugging/investigation
- The user says "let's park this", "note this down", "remind me about this", "we should remember this"
- An unexpected finding, insight, or discovery surfaces
- A decision is made that affects multiple projects/approaches
- A lesson is stated ("turns out...", "lesson learned...", "the key insight is...")

## Step 1 — Determine item type

From the conversation context, pick the best-fit type:
- `idea` — something worth exploring later, not yet decided
- `decision` — a design or architectural choice made
- `discovery` — something learned during investigation
- `lesson` — a mistake or pattern worth remembering
- `reference` — pointer to an external resource (ticket, PR, doc)
- `experiment` — hypothesis to test

## Step 2 — Search for similar items

Before drafting, check for existing related items:

```bash
# Grep knowledge/INDEX.md for similar titles/tags
grep -i "<keyword1>\|<keyword2>" knowledge/INDEX.md 2>/dev/null || true
```

Also query claude-mem for recent related observations:
```
mem-search query="<concept>" limit=5
```

## Step 3 — Draft the item

Allocate the next `KC-NNNN` id. Find the highest existing id:

```bash
latest=$(ls knowledge/KC-[0-9][0-9][0-9][0-9]--*.md 2>/dev/null | sort -V | tail -1)
if [ -n "$latest" ]; then
  latest_id=$(basename "$latest" | grep -oE 'KC-[0-9]{4}' | head -1)
  next_num=$((10#${latest_id#KC-} + 1))
  printf -v next_id "KC-%04d" "$next_num"
else
  next_id="KC-0001"
fi
```

This handles the zero-items case (first capture in a fresh repo starts at KC-0001).

Write to `knowledge/KC-NNNN--<slug>.md` using the frontmatter schema:

```yaml
---
id: KC-NNNN
type: <type>
title: "<one-line summary>"
status: active
priority: p2
project: <repo-slug>
created: <ISO timestamp>
updated: <ISO timestamp>
source: manual
tags: [<comma-separated>]
relates: []
---
# <title>

<2-5 sentences of context. What, why, key details. Write for a human
reader who sees this item days or weeks later.>
```

**Priority defaults**: p2 (important) unless clearly p1 (critical/blocking) or p3 (nice-to-have). Only mark p1 if this item genuinely demands attention soon.

## Step 4 — Relationship suggestion (one-shot, accept/reject)

If similar items were found in Step 2, suggest ONE relationship. Present it as a yes/no question:

> Found related item `KC-0003` ("<title>"). Suggested relationship: `refines`.
> Include this? (yes/no)

- If user says yes → add `{rel: refines, id: KC-0003}` to the `relates` list.
- If user says no → leave `relates: []`.
- If no similar items → skip.

**Never suggest more than one relationship.** The goal is low friction, not exhaustive cataloging.

## Step 5 — Regenerate INDEX.md

After writing the item file, rebuild the index:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/lib/kc-index.sh" knowledge/
```

## Plan-mode behavior

If plan mode is active, DO NOT write the item file. Instead:
1. Allocate the next id (this is safe — the id isn't consumed until the file is written)
2. Draft the item content with the allocated id
3. Queue it by writing the draft to `/tmp/kc-capture-queue-<next_id>.md`
4. Tell the user: "Item KC-NNNN queued — will be written after plan approval."
5. After plan approval (`exitPlanMode`), immediately write ALL queued items from `/tmp/kc-capture-queue-*.md` to `knowledge/` and rebuild the index:
   ```bash
   for qf in /tmp/kc-capture-queue-*.md; do
     [ -f "$qf" ] || continue
     mv "$qf" "knowledge/$(basename "$qf" | sed 's/^kc-capture-queue-//')"
   done
   bash "${CLAUDE_PLUGIN_ROOT}/lib/kc-index.sh" knowledge/
   ```
6. This is a hard requirement — do not leave queued files in /tmp. If you cannot flush for any reason, tell the user explicitly which items are still queued and where.

The sweep (`kc-sweep`) acts as a fallback net for any queued items that are lost — but it only scans claude-mem observations and `~/.claude/plans/`, not `/tmp/`. Manual recovery from `/tmp/kc-capture-queue-*.md` may be needed if the flush step is missed.
