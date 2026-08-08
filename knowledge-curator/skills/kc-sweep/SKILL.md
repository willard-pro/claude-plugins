---
name: kc-sweep
description: Scheduled curation sweep over recent claude-mem observations and plan files. Promotes durable items, deduplicates, and administers the knowledge store (flags dormant, duplicate, stale-priority items). Idempotent — running twice with no new observations makes zero changes. Use "/kc-sweep" manually, or register on cron for automatic execution.
---

# Knowledge Sweep

Review recent claude-mem observations and new plan files since the last sweep, promote durable items, and run an administration pass over existing items.

## Prerequisites

- **claude-mem**: Required for observation review (Step 2). If claude-mem is not configured, the sweep skips observation promotion and only processes plan files + administration. Install via the claude-mem plugin if observation promotion is desired.
- **Linear** (optional): Only needed if you want the sweep to cross-reference Linear ticket state. Not required for core sweep operation.

## Cron registration

Register on a daily schedule:

```
CronCreate cron="37 8 * * *" prompt="/kc-sweep" recurring=true
```

(Off-peak minute to avoid :00/:30 fleet contention.)

## Step 1 — Determine last sweep timestamp

Check for a sweep marker file. If none exists, use "24 hours ago" as the lookback window.

```bash
MARKER_FILE="knowledge/.kc-sweep-marker"
if [ -f "$MARKER_FILE" ]; then
  LAST_SWEEP=$(cat "$MARKER_FILE")
else
  LAST_SWEEP=$(date -u -d '24 hours ago' +%Y-%m-%dT%H:%M:%SZ)
fi
```

## Step 2 — Review claude-mem observations

Query claude-mem for observations since the last sweep:

```
mem-search query="decision|lesson|discovery|insight|root cause|park this|remember" limit=30 dateStart=<LAST_SWEEP>
```

For each observation, evaluate durability:
- **Promote** if: it records a decision, lesson learned, root cause, non-obvious discovery, or pattern worth remembering across sessions
- **Skip** if: it's a transient conversation note, a routine tool invocation, or already captured as a knowledge item (matched by `source: claude-mem:<obs-id>`)

For promoted observations, create knowledge items:

```yaml
---
id: KC-NNNN
type: <discovery|lesson|decision>
title: "<derived from observation>"
status: active
priority: p2
project: <repo-slug>
created: <now>
updated: <now>
source: claude-mem:<obs-id>
why: "<one-line rationale, derived from the observation>"
tags: [<derived>]
relates: []
---
# <title>

<observation content, rewritten for human readability>
```

## Step 3 — Review new plan files

Check `~/.claude/plans/` for files created since the last sweep:

```bash
find ~/.claude/plans/ -name "*.md" -newer knowledge/.kc-sweep-marker 2>/dev/null
```

For each new plan file, check if already imported (by `source: plan:<slug>`). If not, create an item (same template as `kc-import` Step 3).

## Step 4 — Administration pass

Review existing items for housekeeping. **All flagging is advisory — never silently change status or priority.**

### 4a — Flag dormant items
Items with `status: active` and `updated` older than 60 days:
- Flag as dormant candidates: "Item `KC-NNNN` has been inactive for N days. Mark dormant? (yes/no)"
- Only change status if user confirms.

### 4b — Flag duplicate items
Items with very similar titles (case-insensitive substring match or shared distinctive terms):
- Flag the newer one: "`KC-NNNN` ("<title>") may duplicate `KC-MMMM` ("<other title>"). Mark relation?"

### 4c — Flag stale p1 items
Items with `priority: p1` and `updated` older than 14 days:
- Flag: "p1 item `KC-NNNN` hasn't been updated in N days. Still p1? (yes/no)"

### 4d — Flag abandoned in_progress items
Items with `status: in_progress` and `updated` older than 24 hours:
- Flag: "`KC-NNNN` has been in_progress for N hours with no update. May be abandoned. Reset to active?"

## Step 5 — Write sweep marker

Update the marker file to now:

```bash
date -u +%Y-%m-%dT%H:%M:%SZ > knowledge/.kc-sweep-marker
```

## Step 6 — Regenerate index

```bash
bash "${CLAUDE_PLUGIN_ROOT}/lib/kc-index.sh" knowledge/
```

Report summary: "Sweep complete: N observations reviewed, M promoted, P plan files imported, Q items flagged for review."

## Idempotency

Running the sweep twice back-to-back with no new observations or plan files must make zero changes on the second run. The sweep marker ensures the lookback window doesn't re-consume already-processed observations. The `source:` field match prevents duplicate promotion.
