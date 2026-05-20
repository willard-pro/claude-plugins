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
  pipeline-diagram.html            # Interactive state diagram
  validate-linear-config.sh        # Validates Linear team states/labels match state machine
  install.sh                       # Post-install migration from host-side skills
```

## Skill architecture

Skills are Claude Code `.md` files with YAML frontmatter. Claude Code runs them as slash commands. There are two categories:

**Pipeline skills** (the core workflow): `ticket-auto` (orchestrator), `ticket-appraise` (investigation + complexity scoring), `ticket-appraise-exec` (artifact creation), `ticket-implement` (code changes), `ticket-verify` (Playwright UAT), `ticket-flow` (state/label mutations), `ticket-pr-review`, `ticket-pr-iterate`, `ticket-setup`, `ticket-retro`.

**Support skills**: `ticket-critique`, `ticket-detect-resume`, `ticket-overseer`, `ticket-batch-appraise`, `ticket-batch-verify`, `ticket-reproduce`, `wiki-maintenance`, `nav-hints`, `app-knowledge`.

## Determinism boundary

All Linear API mutations flow through `flow.sh` (the `ticket-flow` skill executor) — a deterministic bash script. Skills never call Linear mutation endpoints directly. `flow.sh` handles: state transitions, label add/remove, assignee changes, idempotency checks, and post-trigger state assertions. The state machine definition lives in `state-machine.json` — `flow.sh` reads it, so changes to the JSON take effect without script changes.

## Shared libraries (`lib/`)

- `linear-api.sh` — GraphQL API client with retry logic (3 attempts, exponential backoff). Provides `get_issue`, `get_comments`, `get_team`, `update_issue`, `get_me`, `get_project_config`. Also resolves `UAT_URL` from env → REPOS_ROOT CLAUDE.md files → git root → ancestor walk.
- `ticket-dir.sh` — `resolve_ticket_dir <ID>` finds workspace directories matching `{ID}--slug`.
- `validate-env.sh` — Validates `LINEAR_API_KEY`, `GITHUB_PERSONAL_ACCESS_TOKEN`, and CLAUDE.md fields (`REPOS_ROOT`, `LOCAL_URL`, `UAT_URL`, optional `BE_TEST_CMD`, `SLACK_CHANNEL`, `WIKI_ROOT`).
- `notes-parse.sh` — Extracts complexity score from `notes.md` `## Complexity` section.

## Pipeline log format

Pipe-delimited: `ISO|PHASE|STEP|STATUS|MSG`. Statuses: `start`, `done`, `fail`, `skip`, `waiting`. Phases: `APPRAISE`, `EXEC`, `GATE`, `IMPLEMENT`, `VERIFY`, `PR-REVIEW`, `MAINTENANCE`. `META` is a pseudo-phase for metadata (`schema`, `title`, `gate-result`, `outcome`, `artifact`, `recovery`, `gate-stop`, `trigger-def`). Schema version is `1` — declared as first line. Gate-stop codes (`EXEC_NO_ARTIFACT`, `APPROVAL_REVOKED`, etc.) halt the pipeline on structural failures.

## Key design decisions

- **Crash recovery**: `ticket-detect-resume` reads the pipeline log to find the last completed step and resumes from there. The log is the checkpoint mechanism.
- **Sub-agent isolation**: The orchestrator spawns `general-purpose` agents for each phase. Agents write progress entries directly to `$LOG_FILE`. Each agent spawn is bracketed by a `|waiting|`/`|done|` pair the orchestrator writes.
- **Complexity gating**: Simple tickets auto-approve in `auto`/`semi-auto` mode. Complex tickets always gate (require human `approved` label). The `manual` mode gates everything.
- **Phase context file**: Before each agent spawn, the orchestrator writes `echo "PHASE|{LOG_FILE}" > /tmp/ticket-auto-{ID}-ctx.txt` so the token-tracker hook knows which phase is active.
- **Post-trigger assertions**: After every Linear mutation, `flow.sh` re-fetches the issue and asserts the state/labels match expectations. Mismatch → exit 7 with `STATE_ASSERTION_FAILED`.
- **Idempotency**: `flow.sh` computes the desired end state from current + adds - removes. If nothing would change, it exits 0 without a mutation call.
