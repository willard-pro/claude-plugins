# CLAUDE.md — ticket-auto-pipeline

Plugin-level guidance for Claude Code when working inside this plugin directory. See also: [repo-level CLAUDE.md](../CLAUDE.md) for marketplace-wide conventions.

## Plugin purpose

Fully autonomous Linear ticket pipeline. Appraise, implement, verify, and merge tickets — zero user input required. 20+ slash commands, state-machine-driven flow control, pipeline safety gates, and retrospective analysis.

## Directory layout

```
ticket-auto-pipeline/
  .claude-plugin/plugin.json      # Plugin manifest (name, version, hooks)
  skills/                         # 20+ skill directories, each with SKILL.md
  lib/                            # Shared bash libraries
  personas/                       # In-house persona role guidance (base + specializers)
  skills/ticket-flow/state-machine.json              # Linear state/label transition definitions
  pipeline-log-format.md          # Pipeline log schema (ISO|PHASE|STEP|STATUS|MSG)
  pipeline-heartbeat-format.md    # Heartbeat log schema
  docs/pipeline-diagram.html      # Interactive state diagram (served via GitHub Pages)
  validate-linear-config.sh       # Validates Linear team config matches state machine
  install.sh                      # Migration from host-side skills
```

### `.ticket-auto/` artifact layout (on disk, outside source repos)

```
REPOS_ROOT/.ticket-auto/
  system.md                       # Cross-repo FE→BE contract map
  <repo-slug>/
    meta.json                     # SHA, timestamps, schema version, stats
    .lock                         # Flock concurrency guard
    docs/
      overview.md                 # Architecture overview (architect persona)
      processes.md                # Execution flows (analyzer persona)
      security-surfaces.md        # Auth surfaces, PII locations (security persona)
      services/*.md               # Per-service docs (deterministic distiller)
      routes.md                   # API route table (deterministic distiller)
      backend.md / frontend.md    # Layer-specific docs (developer personas)
      INDEX.md                    # Lookup by Topic / Lookup by Service (technical-writer)
```

## Skill categories

### Pipeline skills (core workflow, called in sequence by ticket-auto)
- `ticket-appraise` — investigation + complexity scoring
- `ticket-appraise-exec` — artifact creation (simple-fix.md or OpenSpec change)
- `ticket-implement` — code changes against workspace
- `ticket-verify` — Playwright UAT verification
- `ticket-pr-review` — PR code review pass
- `ticket-pr-iterate` — iteration on PR feedback
- `ticket-auto` — thin stateless dispatch router (zero inline LLM reasoning, bash-only gates, named agent types)
- `ticket-flow` — state/label mutation executor (wraps flow.sh)
- `ticket-setup` — workspace scaffolding

### Support skills
- `ticket-document` — post-implement ai-context.md generation
- `ticket-detect-resume` — crash recovery via pipeline log checkpoint
- `ticket-retro` — post-mortem failure analysis from logs
- `ticket-overseer` — pipeline queue dashboard (human-facing)
- `ticket-fleet-controller` — DEPRECATED forwarder to `fleet-controller` plugin (extracted 2026-07-07). Use `/fleet-controller` instead.
- `ticket-batch-appraise` / `ticket-batch-verify` — batch operations
- `ticket-reproduce` — bug reproduction (Step 1.5 for bug tickets)
- `ticket-gate-reconcile` — post-gate-hold comment reconciliation (isolated agent, spawned by router at STEP_3_5)
- `ticket-critique` — code/PR critique
- `ticket-audit` — cross-ticket audit within milestone or parent/epic; detects duplicates, overlaps, empty tickets, goal misalignment, stale tickets, split candidates, wiki misalignment
- `ticket-audit-exec` — two-phase apply agent for ticket-audit recommendations; delegates needs-info to ticket-critique, posts structural comments
- `ticket-env-check` — environment validation
- `ticket-prescan` — repo prescan for durable agent-knowledge docs under `REPOS_ROOT/.ticket-auto/`
- `wiki-maintenance` — wiki documentation maintenance
- `nav-hints` / `app-knowledge` — navigation and domain knowledge

## Shared libraries (`lib/`)

| File | Exports |
|------|---------|
| `linear-api.sh` | `get_issue`, `get_comments`, `get_team`, `update_issue`, `get_me`, `get_project_milestones`, `save_comment`. Retry logic (3 attempts, exponential backoff). Resolves `UAT_URL` from env → CLAUDE.md → git root ancestor walk. |
| `flow.sh` (in skills/ticket-flow/) | State machine executor. Reads `skills/ticket-flow/state-machine.json`. Handles state transitions, label add/remove, assignee changes. Idempotency: computes desired end state, skips if no change. Post-trigger assertions: re-fetches issue, exits 7 on mismatch. |
| `heartbeat.sh` | 7 helpers: `hb_init`, `hb_decision`, `hb_fallback`, `hb_heartbeat`, `hb_api`, `hb_gate`, `hb_retry`, `hb_source`. All are no-ops when `HB_LOG_FILE` is unset. |
| `ticket-dir.sh` | `resolve_ticket_dir <ID>` — finds workspace directories matching `{ID}--slug`. |
| `validate-env.sh` | Validates env vars and CLAUDE.md fields. |
| `notes-parse.sh` | Extracts complexity score from `notes.md` `## Complexity` section. |
| `env-check.sh` | Full environment check (env vars, MCP, CLI tools, CLAUDE.md). Dual-mode: `full` (pipe-delimited) and `validate` (colored output). |
| `capture-transcript.sh` | Agent transcript capture for retro analysis. |
| `reconcile-comments.sh` | PR comment reconciliation utility. |
| `fleet-detect.sh` | **EXTRACTED to `fleet-controller/lib/`** — 11 detection engines now live in fleet-controller plugin. |
| `fleet-intervene.sh` | **EXTRACTED to `fleet-controller/lib/`** — intervention executor now lives in fleet-controller plugin. |
| `fleet-dashboard.sh` | **EXTRACTED to `fleet-controller/lib/`** — dashboard renderer now lives in fleet-controller plugin. |
| `gate-check.sh` | Deterministic bash gate logic. `--mode entry` checks artifact existence, complexity-artifact coherence, autonomy routing. `--mode reapprove` checks live Linear state for re-approval integrity. Replaces inline LLM gate reasoning. |
| `outcome-label-check.sh` | Bash-only post-implement guard. Verifies Smooth/Rough/Hard outcome label is present on the Linear ticket, applying it if missing via flow.sh. |
| `detect-resume.sh` | Pipeline log state parser. Called directly as bash by the thin router (not via `/ticket-detect-resume` skill). Outputs 21 routing variables (RESUME_STEP, COMPLEXITY, AUTONOMY, VERIFY_ATTEMPTS, VERIFY_LAST, ITERATION, RECONCILE_CYCLE, PR_FEEDBACK_CYCLE, etc.). |
| `audit-size-check.sh` | Deterministic split signal detection. Checks AC count (>5), word count (>400), wiki service count (≥3). Outputs `SIGNAL_COUNT` + `SIGNALS` + templated `SPLIT_SUGGESTION` when 2+ signals fire. |
| `audit-drift-check.sh` | Delta timestamp comparator for ticket-audit re-runs. Compares current Linear `updatedAt` against snapshot inventory. Outputs `CHANGED_IDS` + `NEW_IDS`. Pure bash, no LLM. |
| `audit-title-similarity.sh` | Jaccard similarity on two title strings. Tokenizes to word sets (lowercase, strip punctuation), computes intersection/union, outputs integer 0–100. |
| `audit-scope-check.sh` | Deterministic scope identification. Checks ticket text against wiki service vocabulary + scope indicator keywords. Outputs `SCOPE_FOUND` + `MATCHED_SERVICES`. Replaces LLM Check 4. |
| `audit-repro-check.sh` | Deterministic repro steps detection for bug tickets. Detects numbered steps, action bullets, "Steps to reproduce" sections. Outputs `HAS_REPRO` + `REPRO_COUNT`. Replaces LLM Check 5. |
| `audit-ac-testability.sh` | Deterministic AC testability check. Detects vague/unverifiable language patterns per AC line. Outputs `VAGUE_AC_COUNT` + `VAGUE_ACS`. Pre-filters LLM Check 2. |
| `audit-test-data-check.sh` | Deterministic test data assumption detection. Matches 16 pre-existing-state patterns. Outputs `NEEDS_TEST_DATA` + `ASSUMPTIONS`. Pre-filters LLM Check 3. |
| `audit-overlap-check.sh` | Deterministic AC overlap detection using Jaccard on tokenized AC text. Outputs `OVERLAP_SCORE` + `OVERLAP_THRESHOLD` + `OVERLAP_SHARED_TERMS`. Pre-filters LLM overlap check. |
| `audit-comment-guard.sh` | Idempotency guard for ticket-audit-exec comments. Fetches existing comments via `get_comments()`, greps for `Source: {source-id}`. Exit 0 if found (skip), exit 1 if not found (post). |
| `ticket-audit-exec.sh` | Deterministic operations for ticket-audit-exec skill. `resolve_file`, `parse_checklist` (JSON output), `write_ahead_mark`, `mark_item_done`, `mark_item_failed`, `advance_phase`, `archive_checklist`, `has_pending_items`, `get_item_state`. |
| `skill-preamble.md` | Shared preamble referenced by all pipeline skill SKILL.md files. Defines parameters and common guard patterns. |
| `skill-preamble-auto.md` | Thin router variant of skill-preamble. Used by agents spawned from the thin router. Excludes guard, project context detection, step dispatch, and task tracker sections (handled by the router). |
| `persona-select.sh` | Deterministic base+specializer persona selector. Emits `PERSONA_BASE`, `PERSONA_SPECIALIZER`, `PERSONA_AUTO_INCLUDE` from repo markers, CLAUDE.md Layer column, phase, and keyword triggers. For `PHASE=prescan`, emits `PERSONA_SET` (multi-persona list for fan-out). Follows gate-check.sh philosophy — zero LLM involvement. |
| `prescan-check.sh` | Deterministic freshness gate for `.ticket-auto/` prescan docs. Evaluates marker existence, schema version, integrity, SHA ancestry, source changes, and decay thresholds. Emits `PRESCAN_STATUS`, `PRESCAN_REASON`, `CHANGED_FILES`, `STALENESS_SCORE`, `DIRTY`. Exit 0 fresh, 1 stale/decayed, 2 missing. |
| `prescan-docs.sh` | Deterministic graph-to-markdown distiller. Reads gitnexus JSON (clusters, routes, processes) and assembles `.ticket-auto/docs/` tree via jq. Zero LLM tokens. Produces `services/*.md`, `routes.md`, `processes.md`, `INDEX.md`. Idempotent output for identical input. |
| `prescan-route.sh` | Deterministic INDEX.md keyword→file router. Parses Lookup by Topic/Service tables, matches ticket text against keywords via case-insensitive substring. Emits matched file paths. Replaces LLM keyword-matching in appraise Step 3a. Also supports `--mode repos` for deterministic repo enumeration under REPOS_ROOT. Zero variance between runs. |
| `prescan-verify.sh` | Deterministic post-scan content quality assertions. Checks every expected doc file exists, is non-empty, meets minimum line/heading counts, is not placeholder-only, and has required structure (security warning header, INDEX.md tables, services/ dir). Replaces inline LLM scaffold-verify. |
| `return-completeness-check.sh` | Deterministic bash gate for implement-phase completion. Counts unchecked `- [ ]` boxes in tasks.md (openspec) or `## Completion Checklist` in simple-fix.md. Exit 0 complete, 1 incomplete, 2 error. Zero LLM tokens. |
| `corrections-parse.sh` | `append_correction`, `get_corrections`, `get_corrections_by_source`. Atomic `.tmp`→`mv` append of CORRECTIONS blocks to notes.md. Parse with last-match-wins dedup. Torn-block tolerant. |

## Personas

The `personas/` directory provides in-house role guidance as plain markdown reference files — no cross-plugin skill activation dependency. See `personas/README.md` for the full selection logic index.

**Architecture**: Two-tier composition. A `base/<role>.md` file defines universal role rules (priority hierarchy, core principles, phase-tailored checklists, preferred tools). A `specializers/<group>/<stack>.md` file adds stack-specific depth (idioms, test framework, pitfalls, detection signals). Skills read both and layer the specializer on top.

**Selection**: `lib/persona-select.sh` auto-selects the correct files from existing pipeline variables (CLAUDE.md Layer column, repo marker files, ticket phase, keyword triggers). Deterministic — no LLM reasoning. Unknown stack → base persona only, empty specializer (graceful fallback).

**Auto-include**: Security persona automatically activates on auth/payment/credential/PII keywords — no extra skill logic needed; the helper emits `PERSONA_AUTO_INCLUDE` when triggers fire.

**Base roles (8)**: architect, backend-developer, frontend-developer, qa-engineer, analyzer, product-owner, security, technical-writer.
**Specializers (11)**: backend/{python,node,java}, frontend/{angular,react,vue}, qa/{playwright-web,api-testing}, architect/{microservices,monolith}.

## State machine

Defined in `skills/ticket-flow/state-machine.json`. 15 triggers across 8 states:

```
Backlog → Todo (appraise-start)
Todo → Approve (appraise-complete)
Approve → Ready (human-approve)
Approve → Todo (human-reject)
Ready → Review (implement-complete)
Review → Done (pr-review-pass-done)
Review → UAT (pr-review-pass-uat)
Review → Ready (pr-iterate)
UAT → Done (uat-pass)
UAT → Ready (uat-fail)
```

`Blocked` is orthogonal — tickets enter it when waiting on external dependencies.

## Pipeline log format

`ISO|PHASE|STEP|STATUS|MSG` — schema version 1. Phases: `APPRAISE`, `EXEC`, `GATE`, `IMPLEMENT`, `VERIFY`, `PR-REVIEW`, `MAINTENANCE`. `META` pseudo-phase for schema, gate results, outcomes, artifacts.

Statuses: `start`, `done`, `fail`, `skip`, `waiting`.

## Heartbeat log format

`ISO|CATEGORY|EVENT|STATUS|MSG|DETAIL` — schema version 1. Parallel stream to pipeline log. Pipeline tracks _what_, heartbeat tracks _why_. 7 categories: `decision`, `fallback`, `heartbeat`, `api`, `gate`, `retry`, `source`.

Consumers: `skills/ticket-auto/dashboard.py` (dual-panel), `skills/ticket-overseer/report.py` (stall detection), `skills/ticket-retro/retro.sh` (trend aggregation).

## Key design decisions

- **Determinism boundary**: AI skills never call Linear mutation endpoints directly. All mutations go through `flow.sh`. Skills plan/reason/navigate; flow.sh executes with idempotency and assertions.
- **Crash recovery**: Pipeline log is the checkpoint. `detect-resume.sh` is called directly as bash by the thin router (no Claude agent spawn). Router re-reads state after every dispatch and resumes from the last completed step.
- **Sub-agent isolation**: Thin router spawns named agent types (`ticket-appraise-agent`, `ticket-implement-agent`, `ticket-verify-agent`, `ticket-pr-review-agent`, `ticket-maintenance-agent`, `ticket-gate-reconcile-agent`, `ticket-prescan-agent`) per phase. Each agent runs in a fresh isolated session. Router brackets each spawn with `|waiting|`/`|done|` via the 3-step pattern (`spawn_agent_pre` → agent spawn → `spawn_capture` → `spawn_agent_post`).
- **Bash gates**: Gate decisions (artifact existence, complexity coherence, verification readiness, autonomy routing, outcome labels) are deterministic bash scripts (`gate-check.sh`, `outcome-label-check.sh`) — zero Claude agent involvement, zero tokens burned on deterministic comparisons.
- **Router-managed retry loops**: Verify retry (up to 3 attempts), PR iteration (up to 3 cycles), and PR feedback reconciliation (up to 3 cycles, `PR_FEEDBACK_EXHAUSTED` gate-stop beyond that) are managed by the router tracking counters (`VERIFY_ATTEMPTS`, `ITERATION`, `PR_FEEDBACK_CYCLE`) from the pipeline log. Each iteration spawns a fresh agent with clean context — no accumulated output from prior attempts.
- **Stateless routing**: Router reads all state from pipeline log via `detect-resume.sh` (direct bash invocation, not a Claude skill spawn). After every phase dispatch, router re-reads state. Zero in-memory state between dispatches.
- **Complexity gating**: Simple tickets auto-approve in `auto`/`semi-auto` mode. Complex tickets always gate (require human `approved` label). `manual` mode gates everything.
- **Phase context**: Before each agent spawn, orchestrator writes both a ctx file (`/tmp/ticket-auto-{ID}-ctx.txt`) and a spawn-meta file (`/tmp/ticket-auto-{ID}-spawn-meta.txt`). The token-tracker hook reads PHASE from the spawn-meta file (stable per-spawn snapshot) with fallback to the ctx file (legacy). The spawn-meta file persists until the next `spawn_agent_pre` call overwrites it — this avoids a race where the ctx file shows the next phase before the async SubagentStop hook fires.
- **Safety gates**: 11 structural gate-stop codes (EXEC_NO_ARTIFACT, COMPLEXITY_ARTIFACT_MISMATCH, CRITIQUE_SCORE_MISSING, CRITIQUE_BLOCKED, CRITIQUE_SCORE_IMPLAUSIBLE, ZERO_AC, BUG_NO_REPRO, APPROVAL_REVOKED, VERIFY_EXHAUSTED, PR_REVIEW_VERDICT_UNPARSEABLE, PR_FEEDBACK_EXHAUSTED). Violations emit `|META|gate-stop|fail|<CODE>`.
- **Idempotency**: flow.sh computes desired end state from current + adds - removes. No change → exit 0 without mutation.

## Known sharp edges

- Pipeline log fragility: `cut -f5` in detect-resume.sh can silently truncate rows containing `|` in the message field. See memory: pipeline-log-fragility.
- Dashboard dead zone: Pipeline log shows `|waiting|` while agent runs but heartbeat log may be silent during long operations. Gap between pipeline log and heartbeat log during sub-agent execution.
- Zombie steps: If agent crashes without writing a terminal status (`done`/`fail`), the step remains `|waiting|` forever. `ticket-detect-resume` treats these as not-started and re-runs the phase. Bracket idempotency guards (tail-check before write) prevent duplicate brackets but do not eliminate the zombie root cause.
- Version synchronization: `plugin.json`, root `README.md`, and `marketplace.json` each carry a version number. Must be updated in all three places on version bump.

### Resolved (0.7.11)

- Token phase mislabeling: Token `META|tokens` lines now carry the correct phase label. `token-tracker.sh` reads PHASE from the spawn-meta file (`/tmp/ticket-auto-{ID}-spawn-meta.txt`) — a stable per-spawn snapshot — instead of the volatile ctx file. Fallback chain: spawn-meta → ctx file → UNKNOWN.
- Outcome ordering: `META|outcome` is now guaranteed to be the final entry in the pipeline log. The orchestrator defers outcome until after MAINTENANCE and retro-trigger complete, with a tail-check idempotency guard.
- Bracket duplication: `spawn_agent_pre` and `spawn_agent_post` now tail-check the last log line before writing `waiting`/`done`/`fail` entries. Duplicate calls (e.g., from orchestrator retry/resume paths) are suppressed.
- Retro-trigger duplication: `META|retro-trigger` writes are tail-check guarded — at most one per pipeline run.

## Related docs

- [Pipeline log format](pipeline-log-format.md)
- [Heartbeat log format](pipeline-heartbeat-format.md)
- [State machine](skills/ticket-flow/state-machine.json)
- [Interactive diagram](../docs/pipeline-diagram.html)
- [Root CLAUDE.md](../CLAUDE.md)
