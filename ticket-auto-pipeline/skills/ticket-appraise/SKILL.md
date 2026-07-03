---
name: ticket-appraise
description: Investigation planner for a Linear ticket. Fetches the issue, creates the local directory structure, runs a complexity sweep, searches prior art, and traces the full codebase call chain. Writes findings to notes.md. Use when the user says "appraise ticket <ID>", "/ticket-appraise <ID>", or "take on ticket <ID>". After this completes, run /ticket-appraise-exec to create artifacts and update Linear.
---

# Ticket Appraise — Planner

You have been given a ticket ID as the argument (e.g. `WIL-42`). Execute the investigation sequence below in order. This skill ends with notes.md fully populated. The executor skill (`/ticket-appraise-exec`) handles artifact creation and Linear updates.

## Pipeline Preamble

If `--from-auto` is present in the arguments, follow the auto-pipeline preamble in `~/.claude/skills/lib/skill-preamble-auto.md` with parameters: TICKET_ID=<from args>, PHASE=APPRAISE, HAS_LINEAR_ACCESS=true, LINEAR_OPS=get_issue,get_comments, HAS_LOGGING=true, HAS_HEARTBEAT=true. Before starting, source the project context: `source /tmp/ticket-auto-{TICKET_ID}-env.sh 2>/dev/null || true`. Otherwise, follow the full pipeline preamble in `~/.claude/skills/lib/skill-preamble.md` with parameters: TICKET_ID=<from args>, PHASE=APPRAISE, FROM_FLAG=none, HAS_LINEAR_ACCESS=true, LINEAR_OPS=get_issue,get_comments, HAS_GUARD=true, HAS_PROJECT_CONTEXT=true, PROJECT_CONTEXT_FIELDS=REPOS_ROOT,ISSUE_PREFIX,BE_SERVICES,WIKI_ROOT, HAS_LOGGING=true, HAS_HEARTBEAT=true, HAS_STEP_DISPATCH=true, HAS_TASK_TRACKER=true

### Heartbeat points
- **Complexity axes**: after complexity sweep, write `hb_decision "complexity-score" "fired" "...score..." '{"axes":"...","score":"..."}'`
- **Blast radius**: after codebase investigation, write `hb_decision "blast-radius" "fired" "...N files..." '{"file_count":"N"}'`
- **Prior art**: if prior art found, write `hb_decision "prior-art" "fired" "...N matches..."`; if none found, write `hb_decision "prior-art" "info" "no prior art found"`
- **Wiki bootstrap**: if WIKI_ROOT not found in CLAUDE.md and fallback path used, write `hb_fallback "wiki-bootstrap" "fired" "using default wiki path" '{"reason":"WIKI_ROOT not in CLAUDE.md"}'`
- **Regression verdict**: after the regression check, write `hb_decision "regression-verdict" "fired" "risky|clean" '{"verdict":"risky|clean"}'`
- **Impact data fallback**: if gitnexus impact unavailable, write `hb_fallback "impact-data" "fired" "using local grep" '{"reason":"MCP tool unavailable"}'`

### Step dispatch
Also: if `--from-step` is set, **suppress Resume Mode** in Step 1 — the workspace exists by definition, and re-evaluation is not needed.

| `--from-step` value | Skip to | Restore from |
|---------------------|---------|--------------|
| `setup-workspace` | Step 2 (complexity sweep) | ticket-setup output already in notes.md |
| `complexity-sweep` | Step 2.6 (prior art) | `## Complexity` in notes.md |
| `prior-art` | Step 3 (codebase investigation) | `## Prior Art` in notes.md |
| `codebase-investigation` | Step 5 (report/handoff) | `## Initial Investigation` in notes.md |
| `handoff` | End — skill already complete | — |

---

## Step 1 — Set up local workspace

[ -n "$LOG_FILE" ] && echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|APPRAISE|setup-workspace|start|Creating ticket workspace" >> "$LOG_FILE"

Run `/ticket-setup {TICKET-ID}` and wait for it to complete.

- If ticket-setup reports **workspace already exists** → skip to **Resume mode** at the bottom of this skill.
- If ticket-setup reports **workspace created** → continue to Step 2.

The ticket-setup output provides: directory path, title, user, status, priority, labels, epic, environment. Use these values throughout the remaining steps — do not re-fetch from Linear.

[ -n "$LOG_FILE" ] && echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|APPRAISE|setup-workspace|done|Workspace ready" >> "$LOG_FILE"

---

## Step 1.5 — Create task tracker

**Before proceeding further**, create a TaskCreate for every remaining step in this skill (Steps 2 through 5 below). Each task subject = the step heading (e.g. "Step 2: Expand notes.md for appraisal"). This ensures no step is skipped even when context scrolls.

After each step is fully done (including all sub-steps), mark it completed with TaskUpdate. At session end, write a trace file to the ticket directory:

```bash
cat > {ticket-dir}/appraise-session.md << 'TRACE'
# appraise session — {ISSUE-ID}
**Date:** {today}
**Complexity:** {simple|complex}

## Step trace
- [x] Step 2: Expand notes.md — done
- [x] Step 2.5: Complexity sweep — {score}, axes: {list}
- [x] Step 2.6: Prior-art search — {hits} hits
- [x] Step 2.7: Readiness critique — {BLOCKED|WARNINGS|CLEAR}
- [x] Step 3: Investigate codebase — {N} files traced
- [x] Step 4: Label ticket — {complexity} label applied
- [x] Step 5: Hand off — reported to user
TRACE
```

---

## Step 2 — Expand notes.md for appraisal

ticket-setup writes a minimal notes.md stub. Replace it with the full appraisal template:

```markdown
# Working Notes — {ISSUE-ID}

## Status
**Appraised:** {today's date}
**Current status:** {Linear status}

## Initial Investigation

{After completing Step 3, summarise your code findings here — relevant files, components, services, suspected root cause or implementation area.}

## Open Questions

- {List anything unclear from the ticket description}

## Next Steps

- {First concrete action to move this ticket forward}

## Session Log

### {today's date}
- Ticket appraised and local workspace created.
```

---

## Step 2.5 — Complexity sweep

Activate the analyzer persona before scoring:

Run `lib/persona-select.sh --repo <repo> --phase appraise` and read the persona file at `$PERSONA_BASE`. Inject its content as role context for this step.

[ -n "$LOG_FILE" ] && echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|APPRAISE|complexity-sweep|start|Scoring complexity axes" >> "$LOG_FILE"

Score the ticket on the three axes below using only what ticket-setup already returned (title, description, labels, comments, epic). No codebase reads yet. Classification as `complex` requires 2 or more axes to fire — a single axis alone (e.g., `cross-layer` only) classifies as `simple`.

| Axis                | Fires when                                                                                                                                             |
| ------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------ |
| **Multi-service**   | Description mentions more than one service, or the affected area is ambiguous (e.g. "payment flow", "attorney assignment", "reporting")                |
| **Cross-layer**     | Fix clearly requires both frontend AND backend changes, OR touches high-risk areas: DB migrations, Feign clients, payments, PDF generation, async jobs |
| **Prior rejection** | Comments contain a previous appraisal that was marked `rejected`, or the ticket description says "tried X, didn't work"                                |

**If fewer than 2 axes fire → proceed to Step 2.6, then Step 3 (inline).**

**If 2 or more axes fire → proceed to Step 2.6, then Step 3-Agent (delegated) instead.**

Record the decision in notes.md under a `## Complexity` heading:

```markdown
## Complexity
**Score:** {simple | complex}
**Axes fired:** {list fired axes, or "none"}
**Reason:** {one sentence}
```

[ -n "$LOG_FILE" ] && echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|APPRAISE|complexity-sweep|done|{simple|complex}, axes: {list}" >> "$LOG_FILE"

---

## Step 2.6 — Prior-art search (claude-mem)

[ -n "$LOG_FILE" ] && echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|APPRAISE|prior-art|start|Searching claude-mem" >> "$LOG_FILE"

Run the `/claude-mem:mem-search` skill with 2–3 keywords derived from the ticket title and description (e.g. component name, feature area, error message fragment). Keep the query tight — one focused search, not multiple.

**Evaluate each hit:**

| Confidence          | Criteria                                                              |
| ------------------- | --------------------------------------------------------------------- |
| **High (≥80%)**     | Same component/service, same symptom or change type, outcome recorded |
| **Medium (40–79%)** | Related area or similar pattern, but different scope or older context |
| **Low (<40%)**      | Superficially related keyword match only                              |

Discard hits below 40% — do not record noise.

**For each kept hit, append to notes.md under a `## Prior Art` heading:**

```markdown
## Prior Art

### {hit title or session ID} — {High | Medium} confidence ({score}%)
**Relevance:** {one sentence: why this hit applies}
**Key finding:** {the specific decision, fix, or pattern from that session}
**Incorporate:** {how this should inform the current investigation or implementation}
```

If no hits score ≥40%, write:

```markdown
## Prior Art
No relevant prior art found.
```

**Also search local tickets:**

Derive 2–3 file or component keywords from the affected area identified so far (e.g. `progress-update`, `AttorneyProfileController`, `HandoverRepository`). Use the ticket directory path from Step 1 as `{TICKET-DIR}`. Then run:

```bash
grep -rl "{keyword1}\|{keyword2}" . --include="notes.md" | grep -v "{TICKET-DIR}" | head -20
```

For each match, read just the `## Status`, `## Initial Investigation`, and `## Complexity` sections of that notes.md. Evaluate confidence using the same High/Medium/Low criteria as the claude-mem hits above. Discard hits below 40%.

Append local hits to the same `## Prior Art` section, tagged `[local-ticket]`:

```markdown
### {TICKET-ID} ({directory name}) — {High | Medium} confidence ({score}%) [local-ticket]
**Relevance:** {one sentence: why this hit applies}
**Key finding:** {what was fixed or changed, with file path if found}
**Incorporate:** {how this affects the current investigation or implementation}
```

If no local hits score ≥40%, do not add a new entry — the section already reflects the claude-mem result.

**Also search ai-context.md files (post-implement documentation):**

Run a second grep for `ai-context.md` files using the same keywords:

```bash
grep -rl "{keyword1}\|{keyword2}" . --include="ai-context.md" | grep -v "{TICKET-DIR}" | head -20
```

For each match, read the full `ai-context.md` file (it is short by design — a single page with named sections). Evaluate confidence using the same High/Medium/Low criteria as the local ticket hits above, with these additional factors:

- **Recency**: newer `ai-context.md` (by the Date header) scores higher. Parse the date from the `**Date:**` metadata line.
- **Keyword density**: more term matches across sections (especially **Watch out for** and **Patterns used**) scores higher.
- **Complexity match**: same complexity level as the current ticket scores higher.

**Staleness threshold:** If an `ai-context.md` file's Date header is older than 90 days from today, tag it `[ai-context-stale]` and assign Low confidence regardless of content match. The Date field uses ISO 8601 format (`YYYY-MM-DD`) — parse it directly. The file is still recorded in Prior Art — stale context is better than no context, but the agent should not weight it heavily.

**Result cap:** If more than 5 `ai-context.md` hits pass the confidence threshold, only the top 5 ranked by confidence receive full file reads and Prior Art entries. The remaining hits are summarized as a single line:

```markdown
- {N} additional ai-context.md hits below cutoff — not read
```

Append ai-context.md hits to the same `## Prior Art` section, tagged `[ai-context]` (or `[ai-context-stale]` if older than 90 days):

```markdown
### {TICKET-ID} ({directory name}) — {High | Medium} confidence ({score}%) [ai-context]
**Relevance:** {one sentence: why this hit applies}
**Key finding:** {the specific patterns, gotchas, or decisions from the ai-context.md that apply}
**Incorporate:** {how this should inform the current investigation or implementation}
```

If no ai-context.md hits score ≥40%, do not add a new entry — the section already reflects the claude-mem and local-ticket results.

[ -n "$LOG_FILE" ] && echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|APPRAISE|prior-art|done|{N} hits" >> "$LOG_FILE"

Proceed to Step 2.7.

---

## Step 2.7 — Readiness critique

[ -n "$LOG_FILE" ] && echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|APPRAISE|critique|start|Validating ticket completeness" >> "$LOG_FILE"

Run:

```
/ticket-critique {TICKET-ID} --from-appraise
```

- If the skill reports **BLOCKED** → the ticket is missing required information. Stop here — do not proceed to Step 3. The skill has already posted a comment to Linear and added `needs-info`.
- If the skill reports **WARNINGS** or **CLEAR** → proceed to Step 3 or Step 3-Agent per the complexity decision from Step 2.5.

[ -n "$LOG_FILE" ] && echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|APPRAISE|critique|done|{BLOCKED|WARNINGS|CLEAR}" >> "$LOG_FILE"

---

## Step 2.8 — Blast Radius Analysis (GitNexus)

[ -n "$LOG_FILE" ] && echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|APPRAISE|blast-radius|start|Running impact analysis" >> "$LOG_FILE"

Derive target symbols from the ticket title, description, and labels. Extract at minimum: the primary component/module name, any mentioned API endpoints, and any class or file names referenced in the ticket. Use these as targets for `impact()`.

Call `mcp__gitnexus__impact` for each target symbol:
- `target`: the symbol name (function, class, file, or component)
- `direction`: `"upstream"` (what depends on this)
- `maxDepth`: 3

If the symbol is ambiguous (multiple candidates), pick the highest-relevance result and record all candidates.

**Record results in notes.md** under a `## Blast Radius` section:

```markdown
## Blast Radius

| Target | Risk | d=1 (WILL BREAK) | d=2 (LIKELY AFFECTED) | Affected Flows |
|--------|------|-------------------|------------------------|----------------|
| `{symbol}` | LOW/MEDIUM/HIGH/CRITICAL | {count} callers | {count} indirect | {flow names} |

**Analysis:** {one sentence summarizing what the blast radius means for this ticket}
```

**Re-evaluate complexity:** If any target reports HIGH or CRITICAL risk, OR any target has 3+ d=1 callers, OR 2+ execution flows are affected — and the current classification from Step 2.5 is `simple` — override to `complex` and update the `## Complexity` section in notes.md with the reason:

```markdown
**Score:** complex (overridden from simple — blast radius: {reason})
```

**Non-blocking fallback:** If the `mcp__gitnexus__impact` tool is unavailable or returns an error, log a warning and proceed:

```bash
[ -n "$LOG_FILE" ] && echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|APPRAISE|blast-radius|warn|GitNexus unavailable — falling back to manual tracing" >> "$LOG_FILE"
```

Do NOT block the pipeline on GitNexus availability. The complexity classification from Step 2.5 stands if blast radius data is unavailable.

[ -n "$LOG_FILE" ] && echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|APPRAISE|blast-radius|done|Risk: {highest-risk}, d=1: {max-d1-callers}" >> "$LOG_FILE"

---

## Step 3 — Investigate the codebase (inline path — simple tickets only)

[ -n "$LOG_FILE" ] && echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|APPRAISE|codebase-investigation|start|Tracing call chain" >> "$LOG_FILE"

Based on the ticket's description and labels, identify which service(s) are involved. Use the codebase map from CLAUDE.md to find the right repository under `{REPOS_ROOT}` (resolved in Step 0.5).

### 3a — Load prescan knowledge (Tier 1), then wiki (Tier 3)

Prescan-agent docs under `REPOS_ROOT/.ticket-auto/<repo-slug>/docs/` are the preferred knowledge source — pre-built, freshness-tracked, and verified against live source. The fallthrough chain is:

**Tier 1 → prescan INDEX.md routing** → **Tier 2 → claude-mem corpus** → **Tier 3 → WIKI_ROOT** → **Path B from-scratch**

---

#### 3a.0 — Identify affected repos and check prescan freshness

**Deterministic repo enumeration** via `prescan-route.sh` (mode=repos) — no LLM judgment on which repos are affected:

```bash
REPOS=$(bash "$HOME/.claude/skills/lib/prescan-route.sh" --mode repos --repos-root "$REPOS_ROOT")
```

For each repo in the list, derive the slug and check freshness:

1. Derive the repo slug: `_derive_slug() { basename "$repo" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g'; }`
2. Run the freshness gate:
   ```bash
   eval $(bash "$HOME/.claude/skills/lib/prescan-check.sh" "$repo" --repos-root "$REPOS_ROOT")
   ```
3. Record the status:
   - `PRESCAN_STATUS=fresh` → trust prescan docs, tag findings `(prescan-confirmed)`
   - `PRESCAN_STATUS=stale` or `decayed` → load prescan docs but treat ALL entries as **unconfirmed** — re-verify every file:line reference against live source before trusting. Demote unverifiable entries to open questions.
   - `PRESCAN_STATUS=missing` → skip prescan entirely, fall through to Tier 3 (wiki).

---

#### 3a.1 — Tier 1: INDEX.md routing (primary path)

**If `PRESCAN_STATUS` is `fresh`, `stale`, or `decayed`** and `.ticket-auto/<repo-slug>/docs/INDEX.md` exists:

**Deterministic keyword routing** via `prescan-route.sh` (mode=index) — bash parses the table, does case-insensitive substring matching, emits the file list. Zero LLM variance between runs:

```bash
MATCHED=$(bash "$HOME/.claude/skills/lib/prescan-route.sh" --mode index \
  --index "$REPOS_ROOT/.ticket-auto/$slug/docs/INDEX.md" \
  --ticket-title "{TICKET_TITLE}" \
  --ticket-labels "{TICKET_LABELS}" \
  --ticket-desc "{TICKET_DESC_FIRST_500}")
# PRESCAN_ROUTE_COUNT and matched file paths are emitted
```

1. **If `PRESCAN_ROUTE_COUNT > 0`:** bash matched keywords → load the matched files. Use `smart_outline` first to confirm relevance before reading full files.
2. **Verify against live source**: For every file:line reference found in prescan docs, confirm the referenced symbol still exists via `smart_search` or `smart_outline` on the source repo. Confirmed entries → tag `(prescan-confirmed)`. Unconfirmed entries → tag `(prescan-unconfirmed)` and note as open questions if `PRESCAN_STATUS` is stale/decayed.
3. Set `{PRESCAN_FLOW}` = the shortest non-index matched file (most focused prescan doc). Each doc contains pre-traced call chains with real class names, endpoints, and entity fields. If multiple files match, prefer `services/*.md` over top-level docs because service files are more targeted.
4. Record prescan docs loaded in notes.md under Initial Investigation: `**Prescan bootstrap:** {list of files loaded} ({fresh|stale|decayed}) — routed by prescan-route.sh`
5. **If `PRESCAN_ROUTE_COUNT = 0`:** INDEX.md keyword matching found nothing → fall through to Tier 2 (claude-mem corpus).

---

#### 3a.2 — Tier 2: claude-mem corpus fallback (semantic search)

**If Tier 1 returned no matches**, attempt semantic search via the prescan knowledge corpus:

1. Prime the corpus: `mcp__plugin_claude-mem_mcp-search__prime_corpus(name="prescan-<repo-slug>")`
2. Query semantically: `mcp__plugin_claude-mem_mcp-search__query_corpus(name="prescan-<repo-slug>", question="{ticket title + description}")`
3. If the corpus returns relevant doc references → load and verify those files (same verification as Tier 1 step 3).
4. If corpus query returns nothing, or claude-mem MCP is unavailable → fall through to Tier 3.
5. Record: `**Prescan corpus:** <repo-slug> — {matches found | no match | unavailable}`

**If `PRESCAN_STATUS` is `missing` (no prescan exists):** skip directly to Tier 3.

---

#### 3a.3 — Tier 3: Wiki context (existing path, unchanged)

**If Tiers 1 and 2 produced no usable results, and `{WIKI_ROOT}` is set (from Step 0.5):**

1. Read `{WIKI_ROOT}/index.md`. It contains a **Lookup by Topic** section with keyword-to-file mappings, and a **Lookup by Service** table. Match the ticket's labels, title, and description against the topic keywords in the index to identify which wiki files to load. The index is the authoritative routing table — do not use any hardcoded keyword list.
2. **Scoped loading via smart_search**: Instead of loading every matched wiki file, use `smart_search` with the ticket's keywords, service names, and entity names against the wiki root to identify the most relevant files. Then use `smart_outline` on candidate files to confirm relevance before reading. Only Read the files (or sections) that smart_search confirms as relevant.
3. Set `{WIKI_FLOW}` = the first flow file loaded (or the most relevant). Each file contains pre-traced call chains with real class names, endpoints, and entity fields.
4. Also load `{WIKI_ROOT}/services.md` (service responsibilities and Feign wiring) — outline first, then read only the relevant service sections.
5. Record the wiki files loaded in notes.md under Initial Investigation: `**Wiki bootstrap:** {list of files loaded}`
6. If no topic in the index matches, or smart_search returns no results, leave `{WIKI_FLOW}` empty — fall through to full discovery in 3c.

**If `{WIKI_ROOT}` is empty and no prescan docs were found:** skip to 3b. No knowledge base is available for this project.

---

#### 3a.4 — Cross-repo prescan

For tickets spanning multiple repos, also load `REPOS_ROOT/.ticket-auto/system.md` (if it exists). This cross-repo contract map documents FE→BE API contracts, shared types, and service boundaries. Use it to confirm which repo owns each layer of the call chain.

### 3b — Read the service CLAUDE.md

Read the `CLAUDE.md` for every affected repository before touching any code. This sets the architectural context for everything that follows.

### 3c — Trace the full call chain

**Path P — Prescan-bootstrapped (`{PRESCAN_FLOW}` was loaded in 3a.1):**

For each layer listed in the prescan doc, use `smart_search` or `smart_outline` to confirm the file and method still exist at the listed paths. Read only the pinpointed method — do not scan whole files. After confirming each layer, append to Initial Investigation with: `(prescan-confirmed)` for fresh prescans, or `(prescan-verified)` for stale/decayed prescans where you re-verified the reference.

If a symbol was renamed or moved, note the discrepancy and mark the finding `(prescan-stale)`. For stale/decayed prescans, demote unverifiable entries to the Open Questions section.

Skip the full traversal instructions below — you already have your roadmap.

**Path A — Wiki-bootstrapped (`{WIKI_FLOW}` was loaded in 3a.3):**

For each layer listed in the wiki flow file, use Serena to confirm the file and method still exist at the listed paths. Read only the pinpointed method — do not scan whole files. After confirming each layer, append the confirmed path to Initial Investigation with: `(wiki-confirmed)`.

If a class has been renamed or moved, note the discrepancy but continue. The wiki may be slightly stale — your job is to verify and update, not rediscover.

Skip the full traversal instructions below — you already have your roadmap.

**Path B — No prescan or wiki (`{PRESCAN_FLOW}` and `{WIKI_FLOW}` are both empty):**

**Preferred path — smart_search pre-filter:** Use `smart_search` first to locate symbols by name, class, or function. For each hit, use `smart_outline` to get a structural view (methods, signatures, imports) without loading full files. Then `smart_unfold` or `Read` only the confirmed symbols. This is 5-10x more token-efficient than full file reads.

**Fallback — Serena:** If smart_search is unavailable or returns no results, use Serena for code navigation: symbol search or go_to_definition to locate, find_references to trace downstream effects, symbols_overview for file structure. Only Read after Serena has pinpointed the location — never grep for symbols.

**Last resort — grep:** If neither smart_search nor Serena is available, use `grep -r` to locate symbols by name. This is the least efficient path and should only be used when both structural tools are unavailable.

Do not stop at the first plausible file. Trace the feature end-to-end across all layers involved:

**Frontend tickets:** template → component → service → HTTP call → backend API endpoint
**Backend tickets:** API endpoint → delegate/controller → service → repository/feign client → database or downstream service
**Full-stack tickets:** trace both directions and identify where they meet

For each layer, use Serena to locate the specific file and method. Read only the relevant section after Serena has pinpointed it — do not scan whole files.

**Write findings to notes.md as you go — do not wait until the end of the step.** After each layer is traced, append what you found to the **Initial Investigation** section immediately.

### 3d — Confirm data availability

Explicitly answer: **Is the data already available at the point where the fix needs to happen?**

- For frontend fixes: is the field already on the model/interface? Is it already returned by the API call? Or does the backend need to change?
- For backend fixes: does the required data exist in the DB/entity, or does a migration need to be added?

Document the answer in notes.md. This determines whether the ticket is frontend-only, backend-only, or full-stack — and must be explicit, not assumed.

### 3e — Validation pass

After drafting the Initial Investigation, run a second pass over every finding:

For each bullet point, ask: **"Have I read the actual code that confirms this?"**

- If yes — keep it, ensure the file path and line number are cited.
- If it's inferred — either confirm it now, or rewrite it as an open question.

Remove or demote anything that is assumption rather than confirmed evidence.

[ -n "$LOG_FILE" ] && echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|APPRAISE|codebase-investigation|done|{N} files traced" >> "$LOG_FILE"

---

## Step 3-Agent — Investigate the codebase (delegated path — complex tickets)

[ -n "$LOG_FILE" ] && echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|APPRAISE|codebase-investigation|start|Delegating to Explore agent" >> "$LOG_FILE"

### 3-Agent-a — Load prescan knowledge and wiki context

Run exactly the same multi-tier loading logic as Step 3a above:

1. **Tier 1 (prescan INDEX.md):** Read `REPOS_ROOT/.ticket-auto/<repo-slug>/docs/INDEX.md`, run `prescan-check.sh` for freshness, match ticket keywords against Lookup by Topic/Service tables, load and verify identified files, tag confirmed entries `(prescan-confirmed)`, set `{PRESCAN_FLOW}` if a relevant doc is found.
2. **Tier 2 (claude-mem corpus):** If Tier 1 misses, prime and query the prescan corpus semantically.
3. **Tier 3 (wiki):** If prescan produced nothing and `{WIKI_ROOT}` is set, load wiki index and flow files as before. Set `{WIKI_FLOW}` to the most relevant flow file or leave empty.
4. **Cross-repo:** For multi-repo tickets, load `REPOS_ROOT/.ticket-auto/system.md`.

Record all findings in notes.md. This runs for BOTH paths — simple (3a) and complex (here).

### 3-Agent-b — Spawn the Explore agent

Spawn an `Explore` subagent to perform the investigation in isolation. Give it **no opinion** about where the fix should be — only facts and questions.

**Prompt the agent with:**

```
You are investigating a codebase for a ticket. Your job is to trace the code and report only confirmed evidence — no speculation.

Ticket: {ISSUE-ID} — {title}
Description: {description}
Labels: {labels}

Repos to search (under {REPOS_ROOT} — resolved from the project CLAUDE.md codebase map):
{list repos from CLAUDE.md codebase map that are plausibly involved}

{If PRESCAN_FLOW was loaded above, include this paragraph verbatim:}
A prescan doc at `{PRESCAN_FLOW}` contains a pre-traced call chain for this feature area. Read it now. It lists real class names, method signatures, endpoints, and entity fields that were verified against source at scan time. Start by CONFIRMING those paths — do not rediscover from scratch. If a symbol was renamed or moved, note it. For stale/decayed prescans, re-verify every reference against live source; demote unverifiable entries to open questions.

{If WIKI_FLOW was loaded above (and no prescan was available), include this paragraph verbatim:}
A wiki file at `{WIKI_FLOW}` contains a pre-traced call chain for this feature area. Read it now. It lists real class names, method signatures, endpoints, and entity fields. Start by CONFIRMING those paths — do not rediscover from scratch. If a class was renamed or moved, note it but follow the wiki's structure.

IMPORTANT — Prefer smart_search for code navigation: use `smart_search` to locate symbols by name, `smart_outline` for structural views, `smart_unfold` or `Read` to load only confirmed symbols. Fall back to Serena if smart_search returns nothing: symbol search or go_to_definition to locate, find_references to trace usages, symbols_overview for file structure. Only Read after pinpointing — never scan whole files. Use grep only as last resort.

Answer each question below with specific file paths and line numbers. If you cannot confirm an answer, say "NOT FOUND" — do not guess.

1. Trace the full call chain end-to-end (frontend → backend or backend → DB). For each layer: file path, method/function name, line number.
2. At the point where the fix needs to happen: is the required data already available, or does it need to come from somewhere else? Where exactly?
3. Are there any existing tests covering this area? If so, list them.
4. If the service uses MapStruct (look for `@Mapper` annotated interfaces): read every mapper file that touches the affected entity and list all `@Mapping` annotations, including any `expression = "java(...)"` strings. These are invisible to symbol-based reference search and must be read directly.
5. List anything you searched for but could not locate.
```

**When the agent returns:**

- Copy its findings verbatim into the **Initial Investigation** section of notes.md
- Append a `**Source:** Explore agent (isolated run)` note
- Do NOT re-interpret or summarise — use the raw evidence as-is

[ -n "$LOG_FILE" ] && echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|APPRAISE|codebase-investigation|done|{N} files traced" >> "$LOG_FILE"

---

## Step 4 — Update ticket in Linear

When called via `/ticket-auto`, the ticket was already claimed (Backlog → Todo + `claimed`) before the appraise agent spawned. This call is a **corrective idempotent pass** — it ensures the complexity label matches the actual investigation result. When called standalone (not via ticket-auto), this is the initial claim.

Delegate to the flow executor (safe to re-call — `flow.sh` skips if nothing changed):

```
/ticket-flow {TICKET-ID} appraise-start --data complexity={simple|complex}
_rc=$?
if [ "$_rc" -ne 0 ]; then
  hb_retry "flow-sh" "fail" "flow.sh appraise-start failed (exit ${_rc})" \
    "{\"trigger\":\"appraise-start\",\"exit_code\":\"${_rc}\",\"ticket\":\"{TICKET-ID}\"}"
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|META|flow-error|fail|exit ${_rc}: appraise-start" >> {LOG_FILE}
fi
```

This sets state → `Todo`, assignee → `me`, and adds `claimed` + the complexity label. If the ticket was already claimed by the router, only the complexity label is corrected (if different from the default `simple`).

---

## Step 5 — Hand off to executor

[ -n "$LOG_FILE" ] && echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|APPRAISE|handoff|start|Writing final report" >> "$LOG_FILE"

**Pre-handoff completeness gate** — before reporting, verify `notes.md` is ready for the executor:

```bash
NOTES_FILE="{ticket-dir}/notes.md"

# Check ## Complexity section with a populated Score line
_score=$(grep -A5 "^## Complexity" "$NOTES_FILE" 2>/dev/null | grep "^\*\*Score:\*\*" | grep -oi "simple\|complex" | head -1)
if [ -z "$_score" ]; then
  [ -n "$LOG_FILE" ] && echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|APPRAISE|handoff|fail|notes.md missing ## Complexity with Score" >> "$LOG_FILE"
  # Stop — tell the user the complexity sweep is incomplete
fi

# Check ## Initial Investigation section has content beyond the template stub
_inv_lines=$(awk '/^## Initial Investigation/{found=1; next} found && /^## /{exit} found{print}' "$NOTES_FILE" | grep -vc "^\s*$")
if [ "${_inv_lines:-0}" -lt 2 ]; then
  [ -n "$LOG_FILE" ] && echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|APPRAISE|handoff|fail|notes.md ## Initial Investigation is empty or stub" >> "$LOG_FILE"
  # Stop — tell the user to complete Step 3 before running ticket-appraise-exec
fi
```

If either check fails, stop and tell the user which section is incomplete. Do not run `/ticket-appraise-exec` — it will fail at its own guard with a less specific error.

Tell the user:

```
## {TICKET-ID} — investigation complete

**Complexity:** {simple | complex}
**Axes fired:** {list or "none"}

**Key findings:**
{2-4 bullets from Initial Investigation}

**Open questions:**
{bullets or "None"}

notes.md is fully populated. Review it, then run:

/ticket-appraise-exec {TICKET-ID}

This will create the change artifacts and update Linear.
```

[ -n "$LOG_FILE" ] && echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|APPRAISE|handoff|done|Reported to user" >> "$LOG_FILE"

---

## Resume mode (ticket directory already exists)

If ticket-setup reported workspace already exists in Step 1:

1. Read `context.md` and `notes.md` from the existing directory.
2. Fetch the current state from Linear using the Linear access strategy above (bash `get_issue` + `get_comments` when `LINEAR_API_KEY` is set, MCP fallback otherwise).
3. **Diff comments** — compare Linear's current comments against the Comments section in `context.md`:
   - Count comments in `context.md` (count `**` bold author lines under `## Comments`). If Linear has more, or if any comment body/timestamp differs materially — new activity exists.
   - **If no new comments:** tell the user current status and last session notes. Ask: "Want to continue where you left off, or re-investigate?" Skip the rest of this section.
   - **If new comments found:** continue to step 4.
4. **Present new comments** — show the user what's new (author, timestamp, body excerpt).
5. **Append to notes.md** under a new `### {today's date} — comments update` session log entry:
   ```markdown
   ### {today's date} — comments update
   - New comments from Linear (N since last appraisal):
     - **{author}** ({timestamp}): {body excerpt}
   ```
6. **Re-evaluate complexity** — run Step 2.5 (complexity sweep) again, considering the new comments as additional input. If the score changes, update the `## Complexity` section in notes.md and note the change in the session log.
7. **Check artifact staleness:**
   ```bash
   find {ticket-dir} -name "simple-fix.md"
   ls openspec/changes/ | grep -i "{ticket-id-lowercase}"
   ```
   If either exists, the plan may be stale. Append to notes.md session log:
   ```
   - ⚠️ Artifacts exist (simple-fix.md / openspec change). New comments may require plan updates.
   ```
8. **Record re-appraisal marker in notes.md.** Append a `## Re-appraisal` section:
	   ```markdown
	   ## Re-appraisal
	   **Date:** {today}
	   **Changes detected:** {yes | no}
	   **Reason:** {e.g. "N new comments since last appraisal" or "no new activity — nothing to update"}
	   ```
	   Set `Changes detected: yes` if: new comments found, complexity score changed, or artifacts are stale. Otherwise `no`.

	10. **Tell the user:**
   ```
   ## {TICKET-ID} — re-appraisal

   **Changes detected:** {yes | no}
   {If yes: list what changed}

   **Complexity:** {unchanged | changed: {old} → {new}}
   **Artifacts:** {up to date | ⚠️ may be stale — re-run `/ticket-appraise-exec {TICKET-ID}` to regenerate}
   ```

11. Do NOT overwrite `context.md`. The comments section there is a snapshot from initial intake. You may append to `notes.md`.
