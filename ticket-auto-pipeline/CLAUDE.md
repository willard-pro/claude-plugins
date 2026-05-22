# CLAUDE.md — ticket-auto-pipeline

Plugin-level guidance for Claude Code when working inside this plugin directory. See also: [repo-level CLAUDE.md](../CLAUDE.md) for marketplace-wide conventions.

## Plugin purpose

Fully autonomous Linear ticket pipeline. Appraise, implement, verify, and merge tickets — zero user input required. 20+ slash commands, state-machine-driven flow control, pipeline safety gates, and retrospective analysis.

## Directory layout

```
ticket-auto-pipeline/
  .claude-plugin/plugin.json      # Plugin manifest (name, version, hooks)
  skills/                         # 20 skill directories, each with SKILL.md
  lib/                            # Shared bash libraries
  state-machine.json              # Linear state/label transition definitions
  pipeline-log-format.md          # Pipeline log schema (ISO|PHASE|STEP|STATUS|MSG)
  pipeline-heartbeat-format.md    # Heartbeat log schema (ISO|CATEGORY|EVENT|STATUS|MSG|DETAIL)
  docs/pipeline-diagram.html      # Interactive state diagram (served via GitHub Pages)
  validate-linear-config.sh       # Validates Linear team config matches state machine
  install.sh                      # Migration from host-side skills
```

## Skill categories

### Pipeline skills (core workflow, called in sequence by ticket-auto)
- `ticket-appraise` — investigation + complexity scoring
- `ticket-appraise-exec` — artifact creation (simple-fix.md or OpenSpec change)
- `ticket-implement` — code changes against workspace
- `ticket-verify` — Playwright UAT verification
- `ticket-pr-review` — PR code review pass
- `ticket-pr-iterate` — iteration on PR feedback
- `ticket-auto` — orchestrator, spawns sub-agents for each phase
- `ticket-flow` — state/label mutation executor (wraps flow.sh)
- `ticket-setup` — workspace scaffolding

### Support skills
- `ticket-document` — post-implement ai-context.md generation
- `ticket-detect-resume` — crash recovery via pipeline log checkpoint
- `ticket-retro` — post-mortem failure analysis from logs
- `ticket-overseer` — pipeline queue dashboard
- `ticket-batch-appraise` / `ticket-batch-verify` — batch operations
- `ticket-reproduce` — bug reproduction (Step 1.5 for bug tickets)
- `ticket-critique` — code/PR critique
- `ticket-env-check` — environment validation
- `wiki-maintenance` — wiki documentation maintenance
- `nav-hints` / `app-knowledge` — navigation and domain knowledge

## Shared libraries (`lib/`)

| File | Exports |
|------|---------|
| `linear-api.sh` | `get_issue`, `get_comments`, `get_team`, `update_issue`, `get_me`, `get_project_config`. Retry logic (3 attempts, exponential backoff). Resolves `UAT_URL` from env → CLAUDE.md → git root ancestor walk. |
| `flow.sh` (in skills/ticket-flow/) | State machine executor. Reads `state-machine.json`. Handles state transitions, label add/remove, assignee changes. Idempotency: computes desired end state, skips if no change. Post-trigger assertions: re-fetches issue, exits 7 on mismatch. |
| `heartbeat.sh` | 7 helpers: `hb_init`, `hb_decision`, `hb_fallback`, `hb_heartbeat`, `hb_api`, `hb_gate`, `hb_retry`, `hb_source`. All are no-ops when `HB_LOG_FILE` is unset. |
| `ticket-dir.sh` | `resolve_ticket_dir <ID>` — finds workspace directories matching `{ID}--slug`. |
| `validate-env.sh` | Validates env vars and CLAUDE.md fields. |
| `notes-parse.sh` | Extracts complexity score from `notes.md` `## Complexity` section. |
| `env-check.sh` | Full environment check (env vars, MCP, CLI tools, CLAUDE.md). Dual-mode: `full` (pipe-delimited) and `validate` (colored output). |
| `capture-transcript.sh` | Agent transcript capture for retro analysis. |
| `reconcile-comments.sh` | PR comment reconciliation utility. |
| `skill-preamble.md` | Shared preamble referenced by all pipeline skill SKILL.md files. Defines parameters and common guard patterns. |

## State machine

Defined in `state-machine.json`. 12 triggers across 8 states:

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
- **Crash recovery**: Pipeline log is the checkpoint. `ticket-detect-resume` reads last completed step. Orchestrator resumes from there.
- **Sub-agent isolation**: Orchestrator spawns `general-purpose` agents per phase. Each writes to `$LOG_FILE`. Orchestrator brackets each spawn with `|waiting|`/`|done|`.
- **Complexity gating**: Simple tickets auto-approve in `auto`/`semi-auto` mode. Complex tickets always gate (require human `approved` label). `manual` mode gates everything.
- **Phase context**: Before each agent spawn, orchestrator writes `PHASE|{LOG_FILE}` to `/tmp/ticket-auto-{ID}-ctx.txt` for the token-tracker hook.
- **Safety gates**: Six structural invariants (artifact existence, complexity coherence, adversarial review, re-approval integrity, remediation brief integrity, PR verdict integrity). Violations emit `|META|gate-stop|fail|<CODE>`.
- **Idempotency**: flow.sh computes desired end state from current + adds - removes. No change → exit 0 without mutation.

## Known sharp edges

- Pipeline log fragility: `cut -f5` in detect-resume.sh can silently truncate rows containing `|` in the message field. See memory: pipeline-log-fragility.
- Dashboard dead zone: Pipeline log shows `|waiting|` while agent runs but heartbeat log may be silent during long operations. Gap between pipeline log and heartbeat log during sub-agent execution.
- Zombie steps: If agent crashes without writing a terminal status (`done`/`fail`), the step remains `|waiting|` forever. `ticket-detect-resume` treats these as not-started and re-runs the phase.
- Version synchronization: `plugin.json`, root `README.md`, and `marketplace.json` each carry a version number. Must be updated in all three places on version bump.

## Related docs

- [Pipeline log format](pipeline-log-format.md)
- [Heartbeat log format](pipeline-heartbeat-format.md)
- [State machine](state-machine.json)
- [Interactive diagram](../docs/pipeline-diagram.html)
- [Root CLAUDE.md](../CLAUDE.md)
