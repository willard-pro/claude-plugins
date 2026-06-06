# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository. For plugin-specific guidance, see [ticket-auto-pipeline/CLAUDE.md](ticket-auto-pipeline/CLAUDE.md). For maintainer documentation, see [ticket-auto-pipeline/plugin-overview.md](ticket-auto-pipeline/plugin-overview.md).

## Repository purpose

Claude Code plugin marketplace (`willard-pro-claude-plugins`). Currently ships one plugin: `ticket-auto-pipeline` — a fully autonomous Linear ticket pipeline that appraises, implements, verifies, and merges tickets with zero user input.

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
  state-machine.json               # Linear state/label transition definitions
  pipeline-log-format.md           # Shared log schema (ISO|PHASE|STEP|STATUS|MSG)
  pipeline-heartbeat-format.md     # Heartbeat log schema
  docs/pipeline-diagram.html       # Interactive state diagram (GitHub Pages)
  validate-linear-config.sh        # Validates Linear team states/labels match state machine
  install.sh                       # Post-install migration from host-side skills
```

## Skill architecture

Skills are Claude Code `.md` files with YAML frontmatter. Claude Code runs them as slash commands. There are two categories:

**Pipeline skills** (the core workflow): `ticket-auto` (thin stateless dispatch router), `ticket-appraise` (investigation + complexity scoring), `ticket-appraise-exec` (artifact creation), `ticket-implement` (code changes), `ticket-verify` (Playwright UAT), `ticket-flow` (state/label mutations), `ticket-pr-review`, `ticket-pr-iterate`, `ticket-setup`, `ticket-retro`.

**Support skills**: `ticket-critique`, `ticket-detect-resume`, `ticket-document`, `ticket-overseer`, `ticket-fleet-controller`, `ticket-batch-appraise`, `ticket-batch-verify`, `ticket-reproduce`, `ticket-gate-reconcile`, `wiki-maintenance`, `nav-hints`, `app-knowledge`.

## Plan/file name matching — no guessing

When a skill or command references a file by name (e.g., `openspec-propose` pointing at `go-over-what-this-agile-reef.md`), and the exact filename does not exist on disk or in `.claude/plans/`, **abort and ask the user for the correct name**. Do not fuzzy-match to the closest plan and run with it — the wrong plan can produce an entirely wrong change. Only proceed when the file is found verbatim or the user clarifies.

## Determinism boundary

All Linear API mutations flow through `flow.sh` (the `ticket-flow` skill executor) — a deterministic bash script. Skills never call Linear mutation endpoints directly. `flow.sh` handles: state transitions, label add/remove, assignee changes, idempotency checks, and post-trigger state assertions. The state machine definition lives in `state-machine.json` — `flow.sh` reads it, so changes to the JSON take effect without script changes.

## Shared libraries (`lib/`)

- `linear-api.sh` — GraphQL API client with retry logic (3 attempts, exponential backoff). Provides `get_issue`, `get_comments`, `get_team`, `update_issue`, `get_me`, `get_project_config`. Also resolves `UAT_URL` from env → REPOS_ROOT CLAUDE.md files → git root → ancestor walk.
- `ticket-dir.sh` — `resolve_ticket_dir <ID>` finds workspace directories matching `{ID}--slug`.
- `validate-env.sh` — Validates `LINEAR_API_KEY`, `GITHUB_PERSONAL_ACCESS_TOKEN`, and CLAUDE.md fields (`REPOS_ROOT`, `LOCAL_URL`, `UAT_URL`, optional `BE_TEST_CMD`, `SLACK_CHANNEL`, `WIKI_ROOT`).
- `notes-parse.sh` — Extracts complexity score from `notes.md` `## Complexity` section.
- `gate-check.sh` — Deterministic bash gate logic (entry + reapprove modes). Replaces inline LLM reasoning at the gate step.
- `outcome-label-check.sh` — Bash-only post-implement guard for Smooth/Rough/Hard outcome label.
- `detect-resume.sh` — Pipeline log state parser. Called directly as bash by the thin router (not via Claude skill spawn). Outputs 19 routing variables.

## Pipeline log format

Pipe-delimited: `ISO|PHASE|STEP|STATUS|MSG`. Statuses: `start`, `done`, `fail`, `skip`, `waiting`. Phases: `APPRAISE`, `EXEC`, `GATE`, `IMPLEMENT`, `VERIFY`, `PR-REVIEW`, `MAINTENANCE`. `META` is a pseudo-phase for metadata (`schema`, `title`, `gate-result`, `outcome`, `artifact`, `recovery`, `gate-stop`, `trigger-def`). Schema version is `1` — declared as first line. Gate-stop codes (`EXEC_NO_ARTIFACT`, `APPROVAL_REVOKED`, etc.) halt the pipeline on structural failures.

## Key design decisions

- **Crash recovery**: `detect-resume.sh` reads the pipeline log to find the last completed step. The thin router calls it directly as bash (no Claude agent spawn) and resumes from there. The log is the checkpoint mechanism.
- **Sub-agent isolation**: The thin router spawns named agent types (`ticket-appraise-agent`, `ticket-implement-agent`, `ticket-verify-agent`, `ticket-pr-review-agent`, `ticket-maintenance-agent`, `ticket-gate-reconcile-agent`) for each phase. Each agent runs in a fresh isolated session with clean context. Agents write progress entries directly to `$LOG_FILE`. Each agent spawn is bracketed by a 3-step pattern: `spawn_agent_pre` → agent spawn → `spawn_capture` → `spawn_agent_post`.
- **Bash gates**: Gate decisions (artifact existence, complexity coherence, autonomy routing, outcome labels) are deterministic bash scripts — zero Claude agent involvement, zero tokens burned on deterministic comparisons.
- **Router-managed retry loops**: Verify retry (max 3) and PR iteration (max 3) are managed by the router tracking counters from the pipeline log. Each iteration spawns a fresh agent with clean context.
- **Complexity gating**: Simple tickets auto-approve in `auto`/`semi-auto` mode. Complex tickets always gate (require human `approved` label). The `manual` mode gates everything.
- **Phase context file**: Before each agent spawn, the router writes both a ctx file (`/tmp/ticket-auto-{ID}-ctx.txt`) and a spawn-meta file (`/tmp/ticket-auto-{ID}-spawn-meta.txt`). The token-tracker hook reads PHASE from the spawn-meta file (stable per-spawn snapshot) with fallback to the ctx file (legacy).
- **Post-trigger assertions**: After every Linear mutation, `flow.sh` re-fetches the issue and asserts the state/labels match expectations. Mismatch → exit 7 with `STATE_ASSERTION_FAILED`.
- **Idempotency**: `flow.sh` computes the desired end state from current + adds - removes. If nothing would change, it exits 0 without a mutation call.
