# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository. For plugin-specific guidance, see [ticket-auto-pipeline/CLAUDE.md](ticket-auto-pipeline/CLAUDE.md). For maintainer documentation, see [ticket-auto-pipeline/plugin-overview.md](ticket-auto-pipeline/plugin-overview.md).

## Repository purpose

Claude Code plugin marketplace (`willard-pro-claude-plugins`). Ships five plugins:

- **`ticket-planner`** — 9-phase autonomous planner turning business ideas into dependency-ordered planned tickets. Sits upstream of ticket-auto. Appraisal → Discovery → Architecture → Specify → Review → Consensus → Epic Gen → Ticket Gen → Completed. Generates Branch Directives for shared epic branches.
- **`ticket-auto-pipeline`** — fully autonomous Linear ticket pipeline that appraises, implements, verifies, and merges tickets with zero user input. Consumes planner output via the `planned` label + Planner Context block.
- **`fleet-controller`** — parent orchestrator above ticket-planner and ticket-auto. Dispatches planned tickets from initiative epics, monitors pipeline health via 12 detection engines, manages epic branch lifecycle (create, sync, GC), aggregates execution feedback back to the planner. Bash-only, zero Claude agents.
- **`knowledge-curator`** — durable cross-project knowledge tracking. Captures ideas, decisions, lessons, and discoveries with automatic resurfacing.
- **`grill-me`** — pre-work readiness gate. Assesses business ideas against profile-driven dimensions, asks ranked clarification questions interactively, and produces cryptographically sealed Validated Business Intent documents. Any agent can invoke it before acting. Sits upstream of ticket-planner as an optional pre-flight gate.

## Ecosystem architecture

```
Business idea → [/grill-me] → sealed intent → [ticket-planner] → initiative epic + planned tickets (Planner Context + labels + Branch Directive)
                                                   ↓
                                             [fleet-controller] → detect initiatives → ensure epic branch → dispatch tickets → spawn queue
                                                   ↓
                                             [ticket-auto-pipeline] → resolve branch → appraise (fast-path for planned) → implement → verify → merge
                                                   ↓
                                             [fleet-controller feedback] → aggregate execution results → per-initiative feedback JSON
                                                   ↓
                                             [ticket-planner re-plan] → (on Regenerate flag) → read feedback → regenerate tickets
```

**Plan → Build → Operate ring**: ticket-planner (Plan) → ticket-auto (Build) → Operate (incident→ticket, post-merge safety) → back to Plan. grill-me sits before Plan — it gates ideas before any state is created.

**Determinism boundary**: bash orchestrates (state parsing, phase routing, validation, dispatch, feedback aggregation). Claude agents reason (appraisal, discovery, architecture, proposal, review, spec writing, ticket generation).

**Shared epic branches**: The ticket-planner may attach a `## Branch Directive` block to epic descriptions (via deterministic heuristic or operator override). ticket-auto resolves branch targets via a deterministic precedence chain: `--branch` CLI flag → parent epic directive → `BASE_BRANCH` default (`develop`). fleet-controller manages epic branch lifecycle (create, sync, GC). A malformed directive gate-stops the pipeline — no fallback. The directive lives only on the epic; it is never copied into child tickets. See [Branch Directive schema](ticket-auto-pipeline/docs/branch-directive-schema.md).

**Epic-level UAT**: an epic may additionally declare `**UAT Policy:** epic` in its Branch Directive. Its children then route `Review → Done` on a passing PR review instead of `Review → UAT`, because a shared epic branch is not observable in UAT until the whole epic integrates — and parking children in `UAT` deadlocks the `blocked-by` chain, which resolves strictly on `Done`. Acceptance moves to the epic issue itself via `epic-integration-open` / `epic-uat-start` / `epic-uat-pass`. The field is optional and defaults to `per-ticket`, so no existing epic changes behaviour.

## Plugin anatomy

```
ticket-auto-pipeline/
  .claude-plugin/plugin.json       # Plugin manifest (name, version, description)
  CLAUDE.md                        # Plugin-level guidance for Claude Code
  plugin-overview.md               # Maintainer-facing architecture & design doc
  README.md                        # User-facing plugin documentation
  skills/                          # 20+ slash-command skill .md files
  lib/                             # Shared bash libraries
  docs/                            # Deep-dive reference docs & design notes
  skills/ticket-flow/state-machine.json  # Linear state/label transition definitions (canonical)
  pipeline-log-format.md           # Shared log schema (ISO|PHASE|STEP|STATUS|MSG)
  pipeline-heartbeat-format.md     # Heartbeat log schema
  docs/ticket-auto-pipeline-diagram.html  # Interactive state diagram (ticket-auto, GitHub Pages)
  docs/ticket-planner-pipeline-diagram.html  # 9-phase planning diagram (ticket-planner, GitHub Pages)
  skills/ticket-flow/validate-linear-config.sh  # Validates Linear team states/labels match state machine
  install.sh                       # Post-install migration from host-side skills
```

## Skill architecture

Skills are Claude Code `.md` files with YAML frontmatter. Claude Code runs them as slash commands. There are two categories:

**Pipeline skills** (the core workflow): `ticket-auto` (thin stateless dispatch router), `ticket-appraise` (investigation + complexity scoring), `ticket-appraise-exec` (artifact creation), `ticket-implement` (code changes), `ticket-verify` (Playwright UAT), `ticket-flow` (state/label mutations), `ticket-pr-review`, `ticket-pr-iterate`, `ticket-setup`, `ticket-retro`.

**Support skills**: `ticket-critique`, `ticket-detect-resume`, `ticket-document`, `ticket-overseer`, `ticket-batch-appraise`, `ticket-batch-verify`, `ticket-reproduce`, `ticket-gate-reconcile`, `ticket-prescan`, `wiki-maintenance`, `nav-hints`, `app-knowledge`.
- `ticket-fleet-controller` — DEPRECATED forwarder → `/fleet-controller:fleet-controller` (extracted to top-level `fleet-controller/` plugin)

## Plan/file name matching — no guessing

When a skill or command references a file by name (e.g., `openspec-propose` pointing at `go-over-what-this-agile-reef.md`), and the exact filename does not exist on disk or in `.claude/plans/`, **abort and ask the user for the correct name**. Do not fuzzy-match to the closest plan and run with it — the wrong plan can produce an entirely wrong change. Only proceed when the file is found verbatim or the user clarifies.

## Determinism boundary

All Linear API mutations flow through `flow.sh` (the `ticket-flow` skill executor) — a deterministic bash script. Skills never call Linear mutation endpoints directly. `flow.sh` handles: state transitions, label add/remove, assignee changes, idempotency checks, post-trigger state assertions, and generation fence checks (`{tid}-fence` — rejects mutations from superseded generations, gated behind `FLEET_FENCE_ENFORCE=true`). The state machine definition lives in `skills/ticket-flow/state-machine.json` — `flow.sh` reads it, so changes to the JSON take effect without script changes.

## Shared libraries (`lib/`)

- `linear-api.sh` — GraphQL API client with retry logic (3 attempts, exponential backoff). Provides `get_issue`, `get_comments`, `get_team`, `update_issue`, `get_me`, `get_project_config`. Also resolves `UAT_URL` from env → REPOS_ROOT CLAUDE.md files → git root → ancestor walk.
- `ticket-dir.sh` — `resolve_ticket_dir <ID>` finds workspace directories matching `{ID}--slug`.
- `validate-env.sh` — Validates `LINEAR_API_KEY`, `GITHUB_PERSONAL_ACCESS_TOKEN`, and CLAUDE.md fields (`REPOS_ROOT`, `LOCAL_URL`, `UAT_URL`, optional `BE_TEST_CMD`, `SLACK_CHANNEL`, `WIKI_ROOT`).
- `notes-parse.sh` — Extracts complexity score from `notes.md` `## Complexity` section.
- `gate-check.sh` — Deterministic bash gate logic (entry + reapprove modes). Replaces inline LLM reasoning at the gate step.
- `outcome-label-check.sh` — Bash-only post-implement guard for Smooth/Rough/Hard outcome label.
- `detect-resume.sh` — Pipeline log state parser. Called directly as bash by the thin router (not via Claude skill spawn). Outputs 21 routing variables.
- `corrections-parse.sh` — `append_correction`, `get_corrections`, `get_corrections_by_source`. Atomic `.tmp`→`mv` append of CORRECTIONS blocks to notes.md. Parse with last-match-wins dedup. Torn-block tolerant.

## Pipeline log format

Pipe-delimited: `ISO|PHASE|STEP|STATUS|MSG`. Statuses: `start`, `done`, `fail`, `skip`, `waiting`. Phases: `APPRAISE`, `EXEC`, `GATE`, `IMPLEMENT`, `VERIFY`, `PR-REVIEW`, `MAINTENANCE`. `META` is a pseudo-phase for metadata (`schema`, `title`, `gate-result`, `outcome`, `artifact`, `recovery`, `gate-stop`, `trigger-def`). Schema version is `1` — declared as first line. Gate-stop codes (`EXEC_NO_ARTIFACT`, `APPROVAL_REVOKED`, etc.) halt the pipeline on structural failures.

## Key design decisions

- **Crash recovery**: `detect-resume.sh` reads the pipeline log to find the last completed step. The thin router calls it directly as bash (no Claude agent spawn) and resumes from there. The log is the checkpoint mechanism.
- **Sub-agent isolation**: The thin router spawns named agent types (`ticket-appraise-agent`, `ticket-implement-agent`, `ticket-verify-agent`, `ticket-pr-review-agent`, `ticket-maintenance-agent`, `ticket-gate-reconcile-agent`) for each phase. Each agent runs in a fresh isolated session with clean context. Agents write progress entries directly to `$LOG_FILE`. Each agent spawn is bracketed by a 3-step pattern: `spawn_agent_pre` → agent spawn → `spawn_capture` → `spawn_agent_post`.
- **Bash gates**: Gate decisions (artifact existence, complexity coherence, autonomy routing, outcome labels) are deterministic bash scripts — zero Claude agent involvement, zero tokens burned on deterministic comparisons.
- **Router-managed retry loops**: Verify retry (max 3), PR iteration (max 3), and PR feedback reconciliation (max 3) are managed by the router tracking counters from the pipeline log. Each iteration spawns a fresh agent with clean context.
- **Complexity gating**: Simple tickets auto-approve in `auto`/`semi-auto` mode. Complex tickets always gate (require human `approved` label). The `manual` mode gates everything.
- **Phase context file**: Before each agent spawn, the router writes both a ctx file (`/tmp/ticket-auto-{ID}-ctx.txt`) and a spawn-meta file (`/tmp/ticket-auto-{ID}-spawn-meta.txt`). The token-tracker hook reads PHASE from the spawn-meta file (stable per-spawn snapshot) with fallback to the ctx file (legacy).
- **Post-trigger assertions**: After every Linear mutation, `flow.sh` re-fetches the issue and asserts the state/labels match expectations. Mismatch → exit 7 with `STATE_ASSERTION_FAILED`.
- **Idempotency**: `flow.sh` computes the desired end state from current + adds - removes. If nothing would change, it exits 0 without a mutation call.

## Commit conventions

- Standard git commit messages — no Co-Authored-By trailers. The harness default `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>` is blocked by the auto mode Content Integrity classifier. Omit it.
- Commit messages should follow conventional commits: `type(scope): description` (e.g., `fix: tighten outcome grep pattern`, `feat: add BE_TEST_RUNNER support`).

## Known sharp edges (harness-level)

- **Co-Authored-By classifier block**: Auto mode Content Integrity classifier rejects commits with the default `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>` trailer. Workaround: omit the trailer. See Commit conventions above.
- **Residual classifier state**: After a blocked commit, the classifier reasoning can leak into subsequent unrelated tool calls (e.g., `spawn_agent_pre` denied with the same reasoning). This is a harness bug — the classifier should scope denial reasoning per-action. Filed as harness-level issue.
