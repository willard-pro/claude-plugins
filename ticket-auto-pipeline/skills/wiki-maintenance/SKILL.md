---
name: wiki-maintenance
description: Incorporates unresolved errata entries from ticket-implement feedback into wiki flow files. Reads all ## Errata sections under the project's WIKI_ROOT, applies each gap fix to the relevant flow section, and marks entries resolved. Use when wiki errata has accumulated (~5+ unresolved entries), or the user says "maintain wiki", "update wiki from errata", "incorporate errata", or "fix wiki gaps".
---

# Wiki Maintenance — Errata Incorporation

You are maintaining pre-traced call-chain wiki files. Your input is errata entries appended by `ticket-implement` Step 4c — each entry describes a gap found during actual ticket work. Your job is to incorporate those fixes into the flow content and mark them resolved.

## Logging (--from-auto)

If `$LOG_FILE` is set (passed by the `ticket-auto` orchestrator): read `~/.claude/skills/pipeline-log-format.md`. Write progress entries at step boundaries. Phase is `MAINTENANCE`.

## Heartbeat (--from-auto)

If `$HB_LOG_FILE` is set (passed by the orchestrator): call `~/.claude/skills/lib/hb-wrap.sh` then write heartbeat entries at these points:
- **Wiki bootstrap**: if WIKI_ROOT not set in environment or CLAUDE.md, write `hb-wrap.sh fallback "wiki-bootstrap" "fail" "WIKI_ROOT not configured" '{"reason":"no WIKI_ROOT configured"}'`
- **Errata discovered**: after scanning all wiki files, write `hb-wrap.sh decision "errata-count" "info" "{N} unresolved entries found" '{"count":"{N}"}'`; if none found, write `hb-wrap.sh decision "errata-count" "info" "all errata resolved"`
- **New file created**: if a fix requires creating a new wiki file, write `hb-wrap.sh decision "wiki-file-created" "fired" "created {filename}" '{"file":"{filename}"}'`
- **Unclear entry**: if an errata entry is unclear and skipped, write `hb-wrap.sh decision "errata-skipped" "warn" "unclear entry skipped" '{"ticket":"{TICKET-ID}"}'`
- **Maintenance complete**: after all entries processed, write `hb-wrap.sh decision "maintenance-complete" "fired" "{N} errata processed, {M} ai-context findings promoted, {K} files modified" '{"errata_processed":"{N}","ai_context_findings":"{M}","modified":"{K}"}'`

---

## Step 0 — Load project context

If `--from-auto` is set: source the project context env file instead of reading CLAUDE.md.

```bash
source /tmp/ticket-auto-{TICKET_ID}-env.sh 2>/dev/null || true
```

Use `$WIKI_ROOT` from the environment. If `$WIKI_ROOT` is empty, fall back to reading CLAUDE.md in the current directory.

Stop here if no `WIKI_ROOT` is available — no wiki exists for this project.

After resolving:
```
WIKI_ROOT = {resolved absolute path}
```

---

## Step 1 — Discover unresolved errata

List all markdown files under `{WIKI_ROOT}` recursively, excluding `index.md`:

```bash
find {WIKI_ROOT} -name "*.md" ! -name "index.md" | sort
```

For each file, grep for `## Errata` — if found, read the errata section. Parse each entry to identify:

- **Status**: Unresolved entries are normal markdown. Resolved entries are struck through (`~~entire line~~`).
- **Ticket ID** — the ticket that discovered the gap
- **Gap** — what was missed
- **Root cause** — why the wiki didn't catch it
- **Fix** — what should be added/changed

If no unresolved entries exist across all files, report:
```
No unresolved errata — skipping to Step 2.5 (ai-context.md synthesis).
```
then proceed directly to **Step 2.5** — do NOT stop the skill here. Step 2.5's
ai-context.md promotion must run independently of whether any ticket in this
window logged an errata gap; gating it on errata existence silently drops
successful-ticket findings (patterns/decisions/gotchas) whenever no sibling
ticket happened to also log a failure in the same window.

If entries exist, summarize:
```
## Unresolved errata

| File | Ticket | Gap (summary) |
|------|--------|---------------|
| flows/handover.md | CRE-47 | BomFeignClient.getCommission() not in payment flow |
| flows/billing.md | CRE-52 | BodyServiceResourceUsage.reference field use undocumented |
```

Proceed to Step 2.

---

## Step 2 — Process entries (one at a time)

Work through unresolved entries in order. For each:

### 2a — Read the context

1. Read the errata entry's `Fix:` line — this tells you what to add.
2. Read the relevant section of the flow file that the errata references. The `Gap:` and `Root cause:` lines tell you where.

### 2b — Apply the fix

Edit the flow file to incorporate the missing detail. Common patterns:

| Gap type | Where to fix | Example change |
|----------|-------------|----------------|
| Missing Feign client call in flow | Add a sub-step to the flow section listing the Feign call | "6. Call `BomFeignClient.charge(reserve=true, usage)` via `POST /body-service-resource-usages/charge`" |
| Entity field not documented | Add the field to the entity table | `amount` \| `BigDecimal(21,2)` \| Recovery amount |
| Method signature stale | Update class name or method name in the Key Classes table | Replace `ReportJobService.setStatus()` with correct method |
| Missing endpoint | Add to REST Endpoints table | Add row with method, path, purpose |
| Cross-service dependency undocumented | Add a "## Dependencies" section or note in the flow | "Requires BOM service for commission calculation via `BomFeignClient`" |

After editing, the flow file must still read as a coherent document — the errata entry should describe a fix, but you apply it as part of the regular flow structure.

**If the fix requires creating a new wiki file** (e.g. a flow that has no wiki page yet):

1. Create the file with YAML frontmatter — use this schema:
   ```yaml
   ---
   services: [list of microservice names]
   entities: [list of key JPA entities or domain objects]
   flows: [list of flow names this file covers]
   keywords: [searchable terms a ticket description might contain]
   related: ["path/to/related-file.md", ...]
   ---
   ```
2. Add a row to the **File Registry** table in `{WIKI_ROOT}/index.md`.
3. Add entries to the **Lookup by Topic** and **Lookup by Service** sections of `index.md`.
4. Add the new file to the `related:` frontmatter field of any existing files it is related to.

### 2c — Mark resolved

After incorporating the fix, strike through the errata entry and append a resolution date:

```markdown
### ~~CRE-47 — Hard (predicted simple) — incorporated 2026-05-15~~
~~**Date:** 2026-05-10~~
~~**Gap:** BomFeignClient not in payment flow~~
~~**Root cause:** Wiki only traced HandoverPaymentServiceImpl~~
~~**Fix:** Add BomFeignClient.charge() step~~
```

Do NOT delete the entry — the struck-through history shows what has been maintained and when.

---

## Step 2.5 — Synthesize ai-context.md findings

In addition to errata (failures), scan recent `ai-context.md` files (successes) across ticket directories. Promote non-obvious findings into consolidated wiki entries.

### 2.5a — Discover ai-context.md files

Find `ai-context.md` files created within the last 90 days:

```bash
find . -path "*/tickets/*/ai-context.md" -newermt "90 days ago" 2>/dev/null | head -50
```

If the `tickets` directory is elsewhere, derive the path from the ticket-auto workspace structure or search from the repo root. If no files are found, skip to Step 3.

### 2.5b — Read and evaluate each file

Read each `ai-context.md` file. It is short by design (a single page with named sections). For each file, evaluate findings against these criteria:

**Inclusion criteria** (promote to wiki):
- New conventions or patterns not already documented in the wiki — discovered from the **Patterns used** section
- Gotchas involving undocumented invariants or hidden coupling — from the **Watch out for** section
- Decisions with non-obvious rationale — from the **Decisions** section
- Cross-cutting changes that touch multiple modules — derived from the **What changed** and **Key files** sections

**Exclusion criteria** (stay in ai-context.md only):
- File-by-file change summaries from **What changed** — too granular for wiki
- Findings already covered by an existing wiki entry — check before creating
- Trivial-change one-liners ("Trivial change — no architectural impact")
- Findings from files tagged `[ai-context-stale]` (already marked stale by appraise)

### 2.5c — Write or update wiki entries

For each finding that meets inclusion criteria, check if the wiki already has a relevant entry. Read the most relevant wiki file(s) identified via `{WIKI_ROOT}/index.md`.

**If the finding is already documented:** update the existing entry with the additional source ticket reference (e.g., add `(WIL-67)` to an existing line). Do NOT create a duplicate entry.

**If the finding is new:** add it to the appropriate wiki file. Each entry has two sections:

```markdown
### {topic} (human)

**Summary:** {high-level summary of what's changed in this area — terse, skimmable}
**Convention changes:** {new or updated conventions — one-liners}
**Notable gotchas:** {watch-out items — one per line, with source ticket IDs}

### {topic} (AI)

**File paths:** {list of relevant files with one-line role descriptions}
**Call chains:** {trace paths if applicable}
**Patterns:** {pattern descriptions with rationale}
**Decisions:** {decision rationales with context}
**Source tickets:** {list of ticket IDs that contributed to this entry}
```

The human-facing section (`(human)`) is for quick skimming — it answers "what's changed here recently?" The AI-facing section (`(AI)`) is what the appraise agent reads — it provides the details needed to implement in this area.

### 2.5d — Count and track

Track the number of ai-context.md files processed and the number of findings promoted to wiki. These counts are included in the Step 3 report alongside errata counts.

---

## Step 2.6 — Incorporate CORRECTIONS from ai-context.md

When `ticket-document` writes ai-context.md, it carries forward CORRECTIONS blocks written by `ticket-implement` Step 4c Part 4. These corrections identify mismatches between predicted complexity and actual outcome, tagged with a source (`appraise`, `exec`, `prescan`, or `wiki`). This step processes corrections alongside errata entries.

For each `ai-context.md` file read in Step 2.5, check the `## Corrections from Implementation` section:

1. **source=wiki**: Treat these as direct wiki errata — they describe gaps in wiki flow files discovered during implementation. Apply the same fix workflow as Step 2b (read context, apply fix to the appropriate wiki file). If the fix lands cleanly, strike through the correction as resolved. If unclear, append a `<!-- UNCLEAR: {why} -->` comment and skip.

2. **source=prescan** or **source=appraise**: These describe appraisal/investigation gaps, not wiki file defects. Evaluate each entry: if it reveals a reproducible pattern that the wiki should warn about (e.g., "entity X always needs field Y but the wiki doesn't mention it"), promote it to a wiki entry under the relevant flow file. If it is a one-off ticket-specific miss (e.g., "ticket description was vague"), skip — it is not actionable for the wiki.

3. **source=exec**: These describe plan-artifact gaps. Skip — exec-level corrections are plan-specific and not wiki-material.

Append resolved corrections to the wiki errata sections in the same struck-through format as Step 2c, with a `[corrections]` tag to distinguish them from implement-phase errata:

```markdown
### ~~{TICKET-ID} — {Smooth|Rough|Hard} (predicted {simple|complex}) [corrections] — incorporated {date}~~
~~**Date:** {date}~~
~~**Fact:** {fact from corrections block}~~
~~**Source:** {appraise|prescan|wiki}~~
~~**Corrected:** {corrected detail}~~
```

Track resolved correction count separately from errata count. Include both in the Step 3 report.

---

## Step 3 — Report

```
## Wiki maintenance complete

**Errata processed:** {count}
**ai-context findings promoted:** {count}
**Files modified:** {list}

**Changes:**
1. {file} — {what was added/changed}
2. ...
```

---

## Notes

- **One entry at a time** — read context, apply fix, mark resolved, then move to the next. Do not batch.
- **Errna format is canonical** — the `### {TICKET-ID} — {Hard|Rough} (predicted {simple|complex})` header identifies the entry. Do not alter existing resolved entries.
- **If an errata entry is unclear** — mark it with a comment and skip: `<!-- UNCLEAR: {why} -->` instead of resolving.
- **Source is authoritative** — if an errata entry contradicts the wiki flow, trust the errata (it comes from actual ticket implementation, not pre-computed analysis). Verify by reading the referenced source code if needed.
- **Scope** — writes only to files under `{WIKI_ROOT}/`. Does not modify source code.
