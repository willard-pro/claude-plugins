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
  skills/ticket-flow/dispatch-table.json             # Canonical router dispatch table (steps, loop caps, preconditions)
  skills/ticket-flow/gen-dispatch-table.py           # Renders that table into ticket-auto/SKILL.md; --check is the CI drift gate
  pipeline-log-format.md          # Pipeline log schema (ISO|PHASE|STEP|STATUS|MSG)
  pipeline-heartbeat-format.md    # Heartbeat log schema
  docs/ticket-auto-pipeline-diagram.html  # Interactive state diagram (served via GitHub Pages)
  validate-linear-config.sh       # Validates Linear team config matches state machine
  install.sh                      # Migration from host-side skills
```

### `.ticket-auto/` artifact layout (on disk, outside source repos)

```
REPOS_ROOT/.ticket-auto/
  system.md                       # Cross-repo FE→BE contract map
  worktrees/                      # Per-ticket git worktree isolation (Phase 2)
    {TICKET_ID}/
      {repo-slug}/                # Isolated working copy — no shared-clone collisions
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

## Hooks (`hooks/`, registered in `.claude-plugin/plugin.json`)

| Hook | Event | Purpose |
|------|-------|---------|
| `tmp-sweep.sh` | `SessionStart` | Age-based sweep of the pipeline's `/tmp` scratch files (ctx, spawn-meta, env, start-timestamp). A ticket's whole file group is removed once none of its files has been touched for `TICKET_TMP_TTL_MIN` minutes (default 1440 = 24h); `TICKET_TMP_DIR` overrides the directory. Grouping the TTL per ticket is what keeps a long run's `env.sh` — written once at run start — alive while `spawn_agent_pre` keeps rewriting its ctx/spawn-meta. Progress files, stop files and flow locks share the namespace and are deliberately left alone. |
| `token-tracker-start.sh` | `SubagentStart` | Initializes per-spawn token tracking (the start stamp `token-tracker.sh` reads for `elapsed_ms`). Does not fire for a fleetd-dispatched phase, which is not a subagent — fleetd writes the same stamp itself before `execvpe`. |
| `token-tracker.sh` | `SubagentStop` **and** `Stop` | Records token usage against the phase named in the spawn-meta file. Registered on two events because a phase ends two ways: as a **subagent** of the router (`SubagentStop`, tokens on `agent_transcript_path`), or as a **top-level `claude -p` session** dispatched by fleetd (`Stop`, tokens on `transcript_path`) — `SubagentStop` never fires for the latter. Exactly one event is correct per spawn, and spawn-meta's `SPAWNED_BY=fleetd` line (written only by fleetd) says which; without that discriminator both would match a fleetd-spawned phase, since its own subagents stop within the phase's session id, and the phase would be counted twice. The transcript field is never cross-read between events — a wrong measurement corrupts every downstream aggregate, a missing one does not. |
| `agent-activity.sh` | `PostToolUse` (all tools) | Appends `ISO\|PHASE\|TOOL_NAME` to `{log-dir}/{TICKET_ID}-activity.log` — the agent's own liveness pulse, which `fleet-detect.sh`'s `detect_stalls` reads as a second dimension alongside the orchestrator watchdog. Resolves identity exactly as `token-tracker.sh` does (the spawn-meta file whose `SESSION_ID` matches the payload's), so an unrelated session resolves nothing and writes nothing. Unlike every other hook here it fires on **every tool call in every session** with the plugin installed, so it parses the payload with bash regex and formats its timestamp with `printf %(...)T` — no `python3`, no forks in the hot path — and exits 0 on every failure. Ring-capped at `FLEET_ACTIVITY_LOG_MAX_LINES` (500). |
| `tool-error-capture.sh` | `PostToolUseFailure` (all tools) | Appends deduplicated tool errors to `{tid}-tool-errors.log`. Registered without a matcher since fleet-controller 0.11.0: the pipeline's most failure-prone surfaces are not Bash — verify drives Playwright over MCP and every phase reaches Linear the same way, so a Bash-only matcher let an entire verify run fail on browser and MCP errors with the tool-error log staying empty. Classification is two-stage: the tool's identity picks the vocabulary (`playwright_*`, `mcp_*`, or the original Bash tokens), then the message shape picks a token from it — `playwright_timeout` and `timeout` are different problems with different responses. Identity is resolved by matching the payload's `session_id` against spawn-meta's `SESSION_ID` (there is deliberately no ctx-file fallback: the ctx file carries no session id, and with the matcher widened a newest-file scan would attribute an unrelated session's failure to whichever ticket spawned last) |
| `stop-capture.sh` | `Stop` | Captures `last_assistant_message` for a fleetd-spawned worker, so a headless worker's question — the only channel it has, since `AskUserQuestion` is absent from the `-p` tool list — reaches a human via the exit record and Slack notifier. Resolves the ticket by the payload's `session_id` (the hook itself never receives a ticket id): first via the fleet state store's `workers` table (`fleet-controller/lib/fleet-store.sh`'s `fleet_store_worker_by_session`, discovered the same co-installed-plugin way `lib/spawn-helper.sh` finds `fleet-config.sh`), falling back to scanning `{FLEET_STATE_DIR}/*-run.json` when no store is available. Does **not** fire on SIGINT or SIGKILL — those exits simply have no hook-captured field. Silently exits 0 whenever unresolvable (not a fleet-managed worker, e.g. an interactive session) — must never affect ordinary Claude Code usage. |
| `stop-failure.sh` | `StopFailure` | Appends `META\|worker-api-error\|warn\|` to the ticket's own pipeline log when a turn ends on an API error (after retries are exhausted). Same store-then-file session-id resolution as `stop-capture.sh`. |

Both new hooks deliberately avoid two payload assumptions the observed `SessionStart`/`SessionEnd` shapes don't support: no `permission_mode` field exists on any hook payload, and `SessionEnd`'s `reason` is `other` for both signal-terminated and ordinary ends — so neither hook reads a permission mode or a signal-specific reason.

**Watchdog exit conditions** (`lib/spawn-helper.sh:spawn_watchdog_start`): the watchdog now exits (stops emitting `watchdog|alive` heartbeats) on any of: the workspace directory being removed (pre-existing), the tracked `FLEET_WORKER_PID` no longer alive (`kill -0`), that PID having been reused by an unrelated process (`/proc/$PID/stat` field-22 start-ticks compared against `FLEET_WORKER_START_TICKS`, captured at spawn), or `FLEET_WATCHDOG_MAX_ITERATIONS` (default 720 ≈ 12h at the 60s poll interval) being reached. `FLEET_WORKER_PID`/`FLEET_WORKER_START_TICKS` are absent for a non-fleetd invocation, in which case only the workspace-removed and iteration-cap conditions apply.

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
| `linear-api.sh` | `get_issue`, `get_comments`, `get_team`, `update_issue`, `get_me`, `get_project_milestones`, `save_comment`, `resolve_uat_url`. Retry logic (3 attempts, exponential backoff). `resolve_uat_url` resolves the UAT target from env → CLAUDE.md. |
| `flow.sh` (in skills/ticket-flow/) | State machine executor. Reads `skills/ticket-flow/state-machine.json`. Handles state transitions, label add/remove, assignee changes. Idempotency: computes desired end state, skips if no change. Post-trigger assertions: re-fetches issue, exits 7 on mismatch. |
| `heartbeat.sh` | 7 helpers: `hb_init`, `hb_decision`, `hb_fallback`, `hb_heartbeat`, `hb_api`, `hb_gate`, `hb_retry`, `hb_source`. All are no-ops when `HB_LOG_FILE` is unset. |
| `ticket-dir.sh` | `resolve_ticket_dir <ID>` — finds workspace directories matching `{ID}--slug`. |
| `validate-env.sh` | Validates env vars and CLAUDE.md fields. |
| `notes-parse.sh` | Extracts complexity score from `notes.md` `## Complexity` section. |
| `env-check.sh` | Full environment check (env vars, MCP, CLI tools, CLAUDE.md). Dual-mode: `full` (pipe-delimited) and `validate` (colored output). |
| `capture-transcript.sh` | Agent transcript capture for retro analysis. |
| `reconcile-comments.sh` | PR comment reconciliation utility. |
| `fleet-detect.sh` | **EXTRACTED to `fleet-controller/lib/`** — 14 detection engines now live in fleet-controller plugin. |
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
| `prescan-sweep.sh` | Zero-LLM repo-wide freshness sweep. Enumerates every repo under `REPOS_ROOT` and runs `prescan-check.sh` on each, reporting counts by status (`fresh`/`stale`/`decayed`/`missing`) and a `needs_refresh` list. No doc generation, no Agent spawn — the cheap pre-check a scheduled/cron `/ticket-prescan` run gates on so proactive refresh (of repos a ticket never happens to touch) doesn't cost a Claude session when nothing is stale. Exit 0 all fresh, 1 refresh needed, 2 on error. `--format text\|json`. |
| `prescan-verify.sh` | Deterministic post-scan content quality assertions. Checks every expected doc file exists, is non-empty, meets minimum line/heading counts, is not placeholder-only, and has required structure (security warning header, INDEX.md tables, services/ dir). Replaces inline LLM scaffold-verify. |
| `phase-result-parse.sh` | `parse_phase_result --phase <IMPLEMENT\|VERIFY\|PR-REVIEW> --return-file <path> [--log-file <path>] [--ticket-dir <path>]`. Parses the terminal `=== PHASE_RESULT ===` block a loop-bearing phase agent appends to its return, validates it against [docs/phase-result-schema.md](docs/phase-result-schema.md), serializes canonical JSON with `jq` argument binding, and appends `META\|phase-result\|info\|{json}` to the pipeline log. Tolerant at the transport boundary (whitespace, CRLF, blank lines, field order, unknown fields — recorded under `extra`), strict at the contract boundary (required fields, integer types, closed enums, closing marker). Takes the **last** block when a capture file holds several appended attempts. Any rejection degrades the claim to `claimed_verdict=UNKNOWN`, never halts the pipeline, and never emits a success object; `phase` is always populated so every entry is attributable with `jq` alone. Exit 0 valid, 1 unverifiable claim (a normal outcome), 2 parser could not run. Sourceable lib **and** standalone CLI, so a consumer outside the router can reuse it. Observe-only — nothing routes on the channel yet. |
| `return-completeness-check.sh` | Deterministic bash gate for implement-phase completion. Counts unchecked `- [ ]` boxes in tasks.md (openspec) or `## Completion Checklist` in simple-fix.md. Exit 0 complete, 1 incomplete, 2 error. Zero LLM tokens. |
| `corrections-parse.sh` | `append_correction`, `get_corrections`, `get_corrections_by_source`. Atomic `.tmp`→`mv` append of CORRECTIONS blocks to notes.md. Parse with last-match-wins dedup. Torn-block tolerant. |
| `guidance-store.sh` | `guidance_upsert`, `guidance_query`, `guidance_confirm`, `guidance_deprecate`, `guidance_stats`, `_compute_guidance_id`. JSONL-per-component guidance store at `~/.claude/state/ticket-auto/guidance/`. `flock`-guarded concurrent writes, fail-soft on all operations. Three-state lifecycle (`proposed` → `confirmed` → `deprecated`) with transition audit trail. Lazy GC of deprecated entries older than 90 days. Phase 2 RLVR — accumulates inspector verdicts and post-mortem findings into durable, queryable guidance. |
| `planned-ticket-check.sh` | `check_planned_ticket`, `check_planned_ticket_description`. Deterministic bash validator for `## Planner Context` blocks in planned tickets. Exit 0 (valid), 1 (missing/malformed), 2 (low confidence + not pre-approved). Schema-Version tolerance for forward compatibility. Also exports `_extract_planner_context_block` — canonical shared block parser. |
| `branch-directive-check.sh` | `check_branch_directive <EPIC_ID>`, `check_branch_directive_description <description>`. Deterministic bash validator for `## Branch Directive` blocks on epic parents. Exit 0 (valid + emits parsed values), 1 (absent), 2 (malformed). Validates branch names, closed enums, Schema-Version tolerance. The optional `UAT Policy` field (`per-ticket`|`epic`) is parsed and enum-validated at **any** Schema-Version — deliberately not version-gated, so a hand-added field is never a silent no-op — and `BRANCH_DIRECTIVE_UAT_POLICY` is emitted normalised to `per-ticket` when absent. Shares `_extract_md_section` and `_extract_field` from planned-ticket-check.sh. |
| `branch-resolve.sh` | `resolve_branch_context <TICKET_ID> [--branch <override>] [--title <title>] [--parent-json <json>]`, `resolve_uat_policy <TICKET_ID>`, `resolve_merge_policy <TICKET_ID>`, `uat_decide_trigger [--policy] [--uat-url] [--ticket]`. Deterministic branch decision point. Precedence: `--branch` flag → parent epic directive → config default. Under a valid directive, both `BASE_BRANCH` and `INTEGRATION_BRANCH` are the directive's `Branch` (not its `Base`) — children branch off and PR into the shared epic branch. `BRANCH_SOURCE` is `flag`, `epic-directive`, or `default`. Emits `BRANCH_CONTEXT_RESULT` block, including `UAT_POLICY` (`per-ticket`|`epic`) resolved from the parent directive — a `--branch` override retargets the branch but does NOT detach the ticket from its epic's acceptance model. Also emits `MERGE_POLICY` (`manual`|`on-all-children-done`|empty) — unlike `UAT_POLICY`, absence has no normalised default: empty means the ticket has no epic directive at all, distinct from an epic explicitly declaring a policy. `ticket-pr-review` Step 6b reads `MERGE_POLICY` (alongside `AUTONOMY`) to decide whether it may merge a passing PR directly or must leave it for a human. `uat_decide_trigger` is the single UAT-vs-Done decision site: it echoes `pr-review-pass-done` or `pr-review-pass-uat`, evaluating policy **before** the UAT URL (the URL is exported into every agent's env unconditionally, so a later policy check would be unreachable). Depends on config.sh, linear-api.sh, branch-directive-check.sh. |
| `ticket-preamble.sh` | `ticket_preamble_run`, `ticket_preamble_preflight`, `ticket_preamble_project_context`. The once-per-ticket preamble — SKILL.md Steps 0.1–0.6 as one idempotent entrypoint, so fleetd's phase-level dispatch establishes the same operating environment the router does without carrying a second copy of it. Heartbeat init → Linear preflight (sentinel-cached config check + `get_me`) → pipeline-log schema line → branch context → env file via `spawn_write_env` → autonomy and provenance markers. Emits a `TICKET_PREAMBLE_RESULT` block. A branch decision already recorded as `META|branch-context` is **rehydrated, never re-resolved** — re-resolving re-reads the parent epic, so a directive edited mid-ticket would move the target branch between two of the ticket's own phases. Exit codes are distinct per failure: 1 usage, 2 `BRANCH_DIRECTIVE_INVALID` (the only gate-stop, already written to the log), 3 transient branch-resolution failure, 4/5 preflight, 6 env-file write. |
| `worktree.sh` | `worktree_path <TICKET_ID> <repo_slug>`, `ensure_worktree <TICKET_ID> <repo_path> <branch> <base>`, `release_worktree <TICKET_ID>`, `worktree_gc`. Per-ticket git worktree isolation. `ensure_worktree` is idempotent with identity guard (refuses re-checkout on branch mismatch). `release_worktree` is safe to repeat. `worktree_gc` removes terminal-state trees. |
| `epic-precondition.sh` | `is_epic_issue <issue_json>`, `check_precondition <precondition> <subject> <issue_json>`. The epic discriminator and precondition evaluator, sourced by `flow.sh` so tests exercise the executor's real path. Discriminates on the epic marker label (`EPIC_MARKER_LABEL`, default `epic`) or a valid Branch Directive — never on `.issueType.name`, which this workspace does not define. Preconditions are bidirectional: `must_be_epic` and `must_not_be_epic`, both exit 8 on rejection, 9 on an unknown precondition. |
| `epic-branch.sh` | `ensure_epic_branch <EPIC_ID> [repo_path]`, `epic_branch_sync <EPIC_ID> [repo_path]`, `epic_branch_children_done <EPIC_ID> [children_json]`, `epic_branch_open_pr <EPIC_ID> [repo_path] [children_json] [epic_description]`. Epic branch lifecycle management. `ensure_epic_branch` creates from declared base as a plain ref (`git branch`, no checkout — worktree-safe, idempotent). `epic_branch_sync` merges base into epic (never rebases; conflict → report, no force-push). `epic_branch_children_done` pure bash readiness check — the single canonical "all children Done" implementation (the fleet-controller D-12 detector calls it too). `epic_branch_open_pr` opens integration PR (never merges); it skips repos with no commits between base and the epic branch, accepts cached children/description to avoid per-repo re-fetching, and sets `EPIC_BRANCH_PR_STATE` (`open`|`none`) because its exit 0 covers both "a PR is open" and "nothing was opened". All mutating paths gate behind `FLEET_DRY_RUN`. |
| `template-select.sh` | `resolve_template <type>`. Deterministic type-to-template resolver. Maps `bug`/`feature`/`improvement`/`security`/`chore`/`refactor` (alias → improvement). Exit 3 on unknown/empty type — no silent fallback. Pure bash, zero LLM. |
| `planner-artifacts.sh` | `resolve_planner_dir <TID>`, `has_planner_body <TID>`, `has_planner_proposal <TID>`. Resolves `$REPOS_ROOT/.ticket-auto/initiatives/{INIT}/tickets/{TID}/planner/` from the Planner Context block's Initiative field. Exit 0 present, 1 dir missing, 2 no Initiative. |
| `planned-ticket-body-check.sh` | `check_planned_body <TID> <type>`. Validates ticket body has all required sections per type (universal: AC, Test User, Scope; bug: +Repro Steps, Test Data; feature/improvement: +Nav Path). Sets `BODY_CHECK_MISSING` and `BODY_CHECK_EXIT_CODE`. Plane body.md preferred over Linear description. |
| `appraise-exec-planned.sh` | `adopt_planner_proposal <TID> <change-name> [log-file]`. Adopts planner-authored proposal.md into openspec/changes/ for planned tickets. Exit 0 adopted, 1 no proposal (run /opsx:propose), 2 copy error. Extracted from SKILL.md inline bash — deterministic, zero LLM. |

## Personas

The `personas/` directory provides in-house role guidance as plain markdown reference files — no cross-plugin skill activation dependency. See `personas/README.md` for the full selection logic index.

**Architecture**: Two-tier composition. A `base/<role>.md` file defines universal role rules (priority hierarchy, core principles, phase-tailored checklists, preferred tools). A `specializers/<group>/<stack>.md` file adds stack-specific depth (idioms, test framework, pitfalls, detection signals). Skills read both and layer the specializer on top.

**Selection**: `lib/persona-select.sh` auto-selects the correct files from existing pipeline variables (CLAUDE.md Layer column, repo marker files, ticket phase, keyword triggers). Deterministic — no LLM reasoning. Unknown stack → base persona only, empty specializer (graceful fallback).

**Auto-include**: Security persona automatically activates on auth/payment/credential/PII keywords — no extra skill logic needed; the helper emits `PERSONA_AUTO_INCLUDE` when triggers fire.

**Base roles (8)**: architect, backend-developer, frontend-developer, qa-engineer, analyzer, product-owner, security, technical-writer.
**Specializers (11)**: backend/{python,node,java}, frontend/{angular,react,vue}, qa/{playwright-web,api-testing}, architect/{microservices,monolith}.

## State machine

Defined in `skills/ticket-flow/state-machine.json`. 18 triggers across 8 states:

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

Epic acceptance (acts on the epic issue itself, adds/removes no labels):

```
Backlog → Review (epic-integration-open)
Review → UAT     (epic-uat-start)
UAT → Done       (epic-uat-pass)
```

Preconditions are bidirectional. Epic triggers carry `must_be_epic`; every child lifecycle
trigger carries `must_not_be_epic`, so an epic pushed through the ticket pipeline cannot take a
child's pass-to-`Done` trigger and close itself. Evaluated by `lib/epic-precondition.sh`, which
`flow.sh` sources. Rejection is exit 8.

`Blocked` is orthogonal — tickets enter it when waiting on external dependencies.

### Planner labels (ticket-planner enrichment)

Defined in `planner_labels` section of `state-machine.json`. Set by ticket-planner at ticket creation:

| Label | Pattern | Lifecycle |
|---|---|---|
| `planned` | exact | Provenance marker. Once set, never removed. |
| `INIT-*` | wildcard | Links ticket to initiative (e.g., `INIT-42`). Never removed. |
| `pre-approved` | exact | Set when planner confidence ≥ 0.85. Accelerates ticket-appraise fast-path (skips full codebase investigation). Does NOT bypass human approval gate — standard gate rules still apply. Removed by `human-reject` or `re-claim`. |
| `blocked-by:*` | wildcard | Dependency enforcement (e.g., `blocked-by:CRE-100`). Auto-removed when blocker reaches Done. |
| `state:execution` | exact | Epic-only. Marks initiative as ready for fleet dispatch. flow.sh rejects non-Epic issues (exit 8). |
| `bug` | exact | Type label — task is a bug fix. Set by planner at ticket creation. Never removed. Drives template selection and body validation. |
| `feature` | exact | Type label — task is a new feature. Set by planner at ticket creation. Never removed. Drives template selection and body validation. |
| `improvement` | exact | Type label — task is an improvement to existing functionality. Set by planner at ticket creation. Never removed. Drives template selection and body validation. |
| `security` | exact | Type label — task is a security fix or hardening. Set by planner at ticket creation. Never removed. Drives template selection and body validation. |
| `chore` | exact | Type label — task is a maintenance chore. Set by planner at ticket creation. Never removed. Drives template selection and body validation. |

### Planner Context block

When ticket-planner creates a ticket, it appends a `## Planner Context` markdown block to the Linear description. Schema defined in `docs/planner-context-schema.md`. Validated by `lib/planned-ticket-check.sh` (exit 0 = valid, 1 = malformed, 2 = low confidence + not pre-approved).

**Schema-Version 2** (current) adds 5 optional exploration fields: `Exploration Depth` (enum: quick-scan/standard/deep), `Code Paths Traced` (symbol:file list), `API Contracts Analyzed` (CSV), `Alternative Approaches` (semicolon-list), `Open Questions` (semicolon-list). Version 1 blocks remain valid — all Version 2 fields are optional with sensible defaults. See `docs/exploration-depth-levels.md` for depth semantics and `docs/discovery-phase-spec.md` for how openspec-explore integrates into the planner's Discovery phase.

**Exploration depth consumption** (appraise fast-path): The depth declared by the planner controls how much the appraise agent trusts the planner's investigation. `deep` → skip full grep, trust traced paths. `standard` → use targets as primary path, supplement with targeted grep. `quick-scan` → treat targets as hints, do full investigation. Depth mismatch (`quick-scan` on complex ticket) is a soft signal in gate-check.sh — warns, never blocks.

## Pipeline dashboards

`skills/ticket-auto/dashboard.py` has two modes:

```bash
python3 dashboard.py <log-file> [--heartbeat]   # one ticket, step by step
python3 dashboard.py --fleet [<log-dir>]        # every active pipeline, one row each
```

The per-ticket mode answers "what is this ticket doing"; `--fleet` answers "which
of the tickets in flight needs me". Fleet mode globs `<log-dir>/*-pipeline.log`
(default `$FLEET_PIPELINE_LOG_DIR`, else `./logs`), skips any log carrying
`META|outcome` — matching `fleet_detect_all`'s definition of active — and renders
one row per pipeline: phase, step, open-bracket age, agent-activity age, verify
and PR-review counters, and the last gate event. Rows sort oldest-open-bracket
first, so the row most likely to need attention leads.

The bracket and activity columns colour against the same thresholds
`fleet-detect.sh` uses (600/900s and 240/900s), so the dashboard and the detector
never disagree about what "late" means. The activity column is the one an
orchestrator cannot fake: it reads the last entry of `{tid}-activity.log`, written
per tool call by `hooks/agent-activity.sh`, so a hung agent inside a young bracket
is visible here.

The glob is re-evaluated on every refresh rather than cached, so a pipeline that
starts while the dashboard is open appears on the next tick without a restart.

**The router does not spawn a dashboard.** Step 0.6 used to `tmux split-window` a
per-ticket pane on every run when `$TMUX` was set, which produced a pane per ticket
under fleetd and needed a `pgrep` guard so resumes did not stack panes. It now just
prints both commands. The dashboard is an operator tool opened once — `--fleet` covers
the whole workspace and picks up new pipelines by itself.

Reading is pure stdlib (`collect_fleet_rows`, `read_fleet_row`); `rich` is needed
only to render, and its import is guarded so the data layer can be tested in an
environment without it. Tests: `skills/ticket-auto/tests/test_dashboard_fleet.py`.

## Dispatch table (generated)

`skills/ticket-auto/SKILL.md`'s Dispatch Loop table is **generated**, not hand-written.
The canonical source is `skills/ticket-flow/dispatch-table.json`; the renderer is
`skills/ticket-flow/gen-dispatch-table.py`.

```bash
python3 skills/ticket-flow/gen-dispatch-table.py           # print the block
python3 skills/ticket-flow/gen-dispatch-table.py --check   # exit 1 on drift (CI gate)
python3 skills/ticket-flow/gen-dispatch-table.py --write   # rewrite the block in SKILL.md
```

Exit codes: `0` in sync, `1` drift, `2` structural (missing file, missing markers,
malformed JSON). The generator owns only the span between
`<!-- GENERATED:dispatch-table START -->` and `<!-- GENERATED:dispatch-table END -->` —
the rest of SKILL.md stays hand-written. Edit the JSON and regenerate; never hand-edit
the block. `make check-generated` runs the gate as the first dependency of `make test`
and as its own CI step.

The JSON carries more than the three rendered columns: per-step spawn parameters (skill,
phase, `FROM_STEP` variable, extra flags, instructions), the four router-managed loop
caps with their counters and gate-stop codes, the `STEP_2_5`/`STEP_3` alias, the
`VERIFY_LAST=fail` precondition on `STEP_4_5`, and each step's non-agent pre/post
orchestration (`return-completeness-check.sh`, `outcome-label-check.sh`, auto-merge,
phase inspectors). That richer field set exists because fleet-controller's phase-dispatch
module loads the same file as its phase-sequencing input — the prose table and the code
supervisor read one source, so they cannot disagree.

## Pipeline log format

`ISO|PHASE|STEP|STATUS|MSG` — schema version 1. Phases: `APPRAISE`, `EXEC`, `GATE`, `IMPLEMENT`, `VERIFY`, `PR-REVIEW`, `MAINTENANCE`. `META` pseudo-phase for schema, gate results, outcomes, artifacts.

Statuses: `start`, `done`, `fail`, `skip`, `waiting`.

## Heartbeat log format

`ISO|CATEGORY|EVENT|STATUS|MSG|DETAIL` — schema version 1. Parallel stream to pipeline log. Pipeline tracks _what_, heartbeat tracks _why_. 7 categories: `decision`, `fallback`, `heartbeat`, `api`, `gate`, `retry`, `source`.

Consumers: `skills/ticket-auto/dashboard.py` (dual-panel), `skills/ticket-overseer/report.py` (stall detection), `skills/ticket-retro/retro.sh` (trend aggregation).

## Key design decisions

- **Determinism boundary**: AI skills never call Linear mutation endpoints directly. All mutations go through `flow.sh`. Skills plan/reason/navigate; flow.sh executes with idempotency and assertions.
- **Crash recovery**: Pipeline log is the checkpoint. `detect-resume.sh` is called directly as bash by the thin router (no Claude agent spawn). Router re-reads state after every dispatch and resumes from the last completed step.
- **One writer per log-line grammar**: the phase bracket's two markers each have exactly one implementation with two callers — `phase_bracket_open` (the `|waiting|` line and `META|model`) and `phase_terminal_write` (the `done`/`fail` terminal), both in `lib/spawn-helper.sh`. The router reaches them through `spawn_agent_pre`/`spawn_agent_post`; fleetd's phase dispatch calls them directly, because it forks phases itself and bypasses the router entirely. A second implementation of either would drift silently — both copies read correct alone, and the log is what `detect-resume.sh`, the detectors, the dashboard and the OTel exporter all route on.
- **Sub-agent isolation**: Thin router spawns named agent types (`ticket-appraise-agent`, `ticket-implement-agent`, `ticket-verify-agent`, `ticket-pr-review-agent`, `ticket-maintenance-agent`, `ticket-gate-reconcile-agent`, `ticket-prescan-agent`, `guidance-extractor-agent`) per phase. Each agent runs in a fresh isolated session. Router brackets each spawn with `|waiting|`/`|done|` via the 3-step pattern (`spawn_agent_pre` → agent spawn → `spawn_capture` → `spawn_agent_post`).
- **Bash gates**: Gate decisions (artifact existence, complexity coherence, verification readiness, autonomy routing, outcome labels) are deterministic bash scripts (`gate-check.sh`, `outcome-label-check.sh`) — zero Claude agent involvement, zero tokens burned on deterministic comparisons.
- **Router-managed retry loops**: Verify retry (up to 3 attempts), PR iteration (up to 3 cycles), PR feedback reconciliation (up to 3 cycles, `PR_FEEDBACK_EXHAUSTED` gate-stop beyond that), and gate reconcile (up to 3 cycles, `RECONCILE_EXHAUSTED` gate-stop beyond that) are managed by the router tracking counters (`VERIFY_ATTEMPTS`, `ITERATION`, `PR_FEEDBACK_CYCLE`, `RECONCILE_CYCLE`) from the pipeline log. Each iteration spawns a fresh agent with clean context — no accumulated output from prior attempts.
- **Stateless routing**: Router reads all state from pipeline log via `detect-resume.sh` (direct bash invocation, not a Claude skill spawn). After every phase dispatch, router re-reads state. Zero in-memory state between dispatches.
- **Complexity gating**: Simple tickets auto-approve in `auto`/`semi-auto` mode. Complex tickets always gate (require human `approved` label). `manual` mode gates everything.
- **Phase context**: Before each agent spawn, orchestrator writes both a ctx file (`/tmp/ticket-auto-{ID}-ctx.txt` — written and swept, but no longer consumed by anything: `tool-error-capture.sh` moved to session-id resolution and dropped its ctx-file fallback) and a spawn-meta file (`/tmp/ticket-auto-{ID}-spawn-meta.txt`, stamped with `SESSION_ID=$CLAUDE_CODE_SESSION_ID`). `token-tracker-start.sh`/`token-tracker.sh` derive TICKET_ID/PHASE/LOG_FILE solely from the spawn-meta file whose `SESSION_ID` matches the firing hook's own `session_id` — no ls -t across all of /tmp, no ctx-file fallback, no UNKNOWN phase. A subagent stopping with no live pipeline spawn for its session resolves nothing and the hooks exit 0 without writing anywhere. The spawn-meta file persists until the next `spawn_agent_pre` call overwrites it. None of these files is deleted at `spawn_agent_post` — `env.sh` is sourced by every later phase of the same ticket, and spawn-meta is re-read by duplicate `spawn_agent_post` calls and by `tool-error-capture.sh` — so their lifetime is bounded by age instead, via the `SessionStart` `tmp-sweep.sh` hook. `token-tracker.sh` additionally prunes leftover start-timestamp files (>5 min) for its own ticket+phase, unconditionally: that prune used to sit inside the "start file matched" branch, so it never ran in exactly the case that accumulated files.
- **Guidance store** (RLVR Phase 2): Durable filesystem-based store at `~/.claude/state/ticket-auto/guidance/`. JSONL-per-component format (e.g., `lib-gate-check.sh.jsonl`). Entries have a three-state lifecycle (`proposed` → `confirmed` → `deprecated`) with immutable transition audit trail. The `guidance_id` is a stable hash of `component + root_cause + pattern` — same defect across runs produces the same ID, enabling idempotent upsert. `guidance-extractor-agent` classifies inspector verdict patterns by root cause (`skill-file | lib-script | agent-prompt | network-flake`) and writes guidance entries + CORRECTIONS blocks for actionable (skill/lib) defects. Phase 3 post-mortem feeds into the same store for unified accumulation. All operations are `flock`-guarded and fail-soft — the store never blocks the pipeline. Lazy GC removes deprecated entries older than 90 days when a component file exceeds 200 lines.
- **Safety gates**: 16 structural gate-stop codes (EXEC_NO_ARTIFACT, COMPLEXITY_ARTIFACT_MISMATCH, CRITIQUE_SCORE_MISSING, CRITIQUE_BLOCKED, CRITIQUE_SCORE_IMPLAUSIBLE, ZERO_AC, BUG_NO_REPRO, NO_TEMPLATE_FOR_TYPE, PLANNED_BODY_INCOMPLETE, APPROVAL_REVOKED, VERIFY_EXHAUSTED, PR_REVIEW_VERDICT_UNPARSEABLE, PR_FEEDBACK_EXHAUSTED, BRANCH_DIRECTIVE_INVALID, CODE_REVIEW_EXHAUSTED, RECONCILE_EXHAUSTED). Violations emit `|META|gate-stop|fail|<CODE>`.
- **Code-review loop cap**: `ticket-implement` Step 4b's fix-and-re-review loop is capped at 3 cycles (tracked via a `cycle#N` log marker, same convention as PR feedback reconciliation) with only `medium`+ severity findings treated as blockers. Unlike the router-managed loops above, this loop runs entirely inside the single `ticket-implement-agent` spawn — there is no separate router dispatch per cycle, so `detect-resume.sh` does not track it. Exhausting 3 cycles with blockers still open is `CODE_REVIEW_EXHAUSTED`.
- **Idempotency**: flow.sh computes desired end state from current + adds - removes. No change → exit 0 without mutation.

## Known sharp edges

- Pipeline log fragility: `cut -f5` in detect-resume.sh can silently truncate rows containing `|` in the message field. See memory: pipeline-log-fragility.
- Dashboard dead zone: Pipeline log shows `|waiting|` while agent runs but heartbeat log may be silent during long operations. Gap between pipeline log and heartbeat log during sub-agent execution.
- Zombie steps: If agent crashes without writing a terminal status (`done`/`fail`), the step remains `|waiting|` forever. `ticket-detect-resume` treats these as not-started and re-runs the phase. Bracket idempotency guards (tail-check before write) prevent duplicate brackets but do not eliminate the zombie root cause.
- Version synchronization: `plugin.json`, root `README.md`, and `marketplace.json` each carry a version number. Must be updated in all three places on version bump.
- **Worktree isolation is files-only**: Per-ticket git worktrees isolate the working tree (branches, files, index). They do NOT isolate ports, databases, caches, or seeded test state. Concurrent `ticket-verify` runs against a single `LOCAL_URL` still collide on the shared backend. Worktrees fix the git race; the broader resource-isolation problem remains.
- **Minimum git version**: `git worktree` requires git ≥ 2.5 (released 2015). The `git worktree remove` command used by `release_worktree` requires git ≥ 2.17 (released 2018). All supported environments meet this.
- **No migration needed**: Pre-existing branches adopt worktrees by ordinary git operation. `ensure_worktree` calls `git worktree add -b <branch>` which works whether the branch is new or already exists. Existing ticket workspaces continue to function — only new pipeline runs use worktrees.

### Resolved (0.7.11)

- Token phase mislabeling: Token `META|tokens` lines now carry the correct phase label. `token-tracker.sh` reads PHASE from the spawn-meta file (`/tmp/ticket-auto-{ID}-spawn-meta.txt`) — a stable per-spawn snapshot — instead of the volatile ctx file. Fallback chain: spawn-meta → ctx file → UNKNOWN.
- Outcome ordering: `META|outcome` is now guaranteed to be the final entry in the pipeline log. The orchestrator defers outcome until after MAINTENANCE and retro-trigger complete, with a tail-check idempotency guard.
- Bracket duplication: `spawn_agent_pre` and `spawn_agent_post` now tail-check the last log line before writing `waiting`/`done`/`fail` entries. Duplicate calls (e.g., from orchestrator retry/resume paths) are suppressed.
- Retro-trigger duplication: `META|retro-trigger` writes are tail-check guarded — at most one per pipeline run.

## Related docs

- [Pipeline log format](pipeline-log-format.md)
- [Heartbeat log format](pipeline-heartbeat-format.md)
- [State machine](skills/ticket-flow/state-machine.json)
- [Dispatch table](skills/ticket-flow/dispatch-table.json)
- [Planner Context schema](docs/planner-context-schema.md)
- [Branch Directive schema](docs/branch-directive-schema.md)
- [Phase Result schema](docs/phase-result-schema.md)
- [Interactive diagram](../docs/ticket-auto-pipeline-diagram.html)
- [Root CLAUDE.md](../CLAUDE.md)
