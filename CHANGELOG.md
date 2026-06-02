# Changelog

## 0.7.10 (2026-06-02)

- Fix: `check_api_key` in `lib/linear-api.sh` now walks up from `$PWD` (max 3 levels) looking for `.env` containing `LINEAR_API_KEY=` — flow.sh invoked via `bash` from SKILL.md needs a fresh shell where the key is absent; `.env` walk-up provides automatic fallback without configuration changes.
- Fix: `lib/env-check.sh` now detects `LINEAR_API_KEY` from `$PROJECT_DIR/.env` in both `full` mode (pipe-delimited output) and `validate` mode (colored output) — emits `auto|(in .env)|.env` when key is read from `.env`, mirroring the existing `TICKET_AUTONOMY` pattern.
- Fix: `spawn_write_env` in `lib/spawn-helper.sh` now auto-appends `export LINEAR_API_KEY="${LINEAR_API_KEY}"` to the generated env file when the key is available — sub-agents can now access the Linear API directly without re-sourcing `.env`.
- Test: Added 8 new tests — 5 for `check_api_key` .env walk-up (current dir, parent dir, no key, key already set, wrong key), 1 for `env-check.sh` .env detection, 2 for `spawn_write_env` key propagation (key set, key unset). All 75 tests pass.

## 0.7.9 (2026-06-02)

- Fix: Added `>/dev/null 2>&1` to `hb_pinger_start` background subshell in `lib/heartbeat.sh` — the pinger inherited stdout from `$(spawn_agent_pre ...)` command substitution, causing bash to wait for ALL pipe writers to close before completing the substitution. This produced a 4+ minute delay on every agent spawn during WIL-39.
- Fix: Wired `spawn_write_env` into orchestrator Step 0.5 of `skills/ticket-auto/SKILL.md` — sub-agents now receive project context (`REPOS_ROOT`, `ISSUE_PREFIX`, `BE_SERVICES`, etc.) via `/tmp/ticket-auto-{ID}-env.sh`. Previously the function was defined but never called, so sub-agents operated without project context.
- Feature: Added optional `sleep_secs` parameter to `spawn_watchdog_start` (default 60s) — matches `hb_pinger_start` API pattern and enables testing without 60s delays.
- Test: Added 4 new tests — `test_pinger_no_stdout_output` (heartbeat), `test_watchdog_emits_heartbeats` (spawn-helper), `test_pre_prompt_includes_env_file_path` (spawn-helper), `test_pre_completes_when_env_file_missing` (spawn-helper). Total test count: 144 → 148.
- Test: Updated `hb_pinger_start` mock comment in `test-spawn-helper.sh` to cross-reference the real stdout isolation test in `test-heartbeat.sh`.

## 0.7.8 (2026-06-02)

- Fix: Swapped PR-REVIEW and MAINTENANCE phase order so documentation is generated after code review passes, preventing stale docs when review requests changes. Updated `detect-resume.sh` step table, `pipeline-log-format.md` documentation, and report table accordingly.
- Fix: Added heartbeat `phase-transition` events at all phase boundaries (START → APPRAISE, APPRAISE → REPRODUCE, REPRODUCE → EXEC, EXEC → GATE). Skipped phases emit transitions with "(skipped)" suffix.
- Feature: Added watchdog heartbeat (`spawn_watchdog_start`/`spawn_watchdog_stop` in `spawn-helper.sh`) that emits liveness signals every 60s during agent wait loops. Integrated into `spawn_agent_pre`/`spawn_agent_post`.
- Fix: Eliminated duplicate pipeline log entries by changing agent-written maintenance entries to use distinct step name `wiki-errata` instead of `maintenance`, preventing collision with `spawn_agent_post` phase bracket.
- Fix: Added guards on `META|title` and `META|artifact` emissions — title deferred until non-empty and non-"unknown", artifact deferred until path is absolute. Title emission uses at-most-once check.
- Test: Added 15 new tests across `test-pipeline-phases.sh` and `test-spawn-helper.sh` covering phase ordering, heartbeat transitions, watchdog behavior, log dedup, and metadata deferral.

## 0.7.6 (2026-06-02)

- Fix: removed `-u` (nounset) from `linear-api.sh` — Claude Code shell snapshots inject `ZSH_VERSION` references that trigger false-positive "unbound variable" errors; stderr pollution could contaminate `linear_graphql` JSON output
- Fix: added missing `-e` flags to multi-expression `sed` in `flow.sh` label substitution (line 102–104) — second expression was interpreted as a filename, blocking `human-approve` and `appraise-start` triggers
- Fix: added `"claimed"` to `removes` array in `state-machine.json` `human-approve` trigger — `claimed` and `approved` share the same Linear label group ("Flow"), causing Linear API to reject the mutation with "labelIds not exclusive child labels"

## 0.7.5 (2026-06-02)

- Fix: `spawn-helper.sh` now sources `heartbeat.sh` at load time — `hb_*` and `cl_write` calls were silently unresolved when `HB_LOG_FILE`/`CLAUDE_LOG_FILE` were set during real pipeline runs
- Fix: corrected `get_issue` return-value documentation and error-detection patterns in `ticket-auto/SKILL.md` and `lib/skill-preamble.md` — `get_issue()` returns the unwrapped issue object, not the raw `.data.issue` response; validation check changed from `jq -e '.data.issue'` to `jq -e '.id'`; jq extraction examples and live bug-label detection code updated accordingly

## 0.6.0 (2026-05-22)

- Feat: unit test suites for all 7 lib scripts (72 tests) — `linear-api.sh`, `env-check.sh`, `notes-parse.sh`, `ticket-dir.sh`, `heartbeat.sh`, `capture-transcript.sh`, `reconcile-comments.sh` — each with a self-contained test harness using `socat` for HTTP stubbing where needed
- Feat: ShellCheck linting across all 28 project shell scripts via `make lint`
- Feat: shfmt formatting enforcement via `make fmt-check` (CI-safe diff mode) and `make fmt` (local auto-fix)
- Feat: GitHub Actions CI workflow (`.github/workflows/test.yml`) — runs lint → format check → tests on push/PR to main; fails build on any non-zero exit
- Chore: `marketplace.json` version synced from 0.4.0 to 0.6.0 (missed 0.4.1, 0.5.0, 0.5.1, 0.5.2 bumps)

## 0.5.2 (2026-05-21)

- Feat: `-claude.log` visibility layer — a third log stream (`{TICKET-ID}-claude.log`) written by the orchestrator at each phase boundary; no 60-char MSG restriction. Carries handoff context before agent spawn, verbose done data after success, and diagnostic failure context (last heartbeat event, path existence) after failure. `cl_write`/`cl_init` helpers added to `lib/heartbeat.sh`; `CLAUDE_LOG_FILE` exported to all 10 agent spawn instructions for sub-agent access.
- Feat: pipeline verify guards — ticket-appraise pre-handoff completeness gate (checks `## Complexity` Score line and `## Initial Investigation` content before handing off to exec), ticket-setup post-script workspace verify (confirms `notes.md` and `context.md` exist after setup.sh), ticket-pr-iterate post-write section check (verifies `## PR Review #N` heading landed in the artifact), ticket-retro proposal file verify (confirms proposal file written before reporting success).

## 0.5.1 (2026-05-21)

- Fix: `flow.sh`, `validate-linear-config.sh`, `detect-resume.sh`, and `setup.sh` all used `$SCRIPT_DIR/../../lib/` to source shared libraries — this path breaks when skills are installed as symlinks (resolves to the plugin cache, not `~/.claude/skills/lib/`). All four scripts now use `${CLAUDE_SKILLS_LIB:-$HOME/.claude/skills/lib}` instead, which works in both symlinked and direct-checkout layouts.
- Fix: `detect-resume.sh` now recognises `META|gate-stop|fail|EXEC_NO_ARTIFACT` in the pipeline log and maps it to `RESUME_STEP=STEP_2` (re-run EXEC), rather than silently advancing to STEP_3 as if EXEC had succeeded.
- Fix: `ticket-appraise-exec` SKILL.md — after writing `simple-fix.md`, the skill now immediately verifies the file exists on disk before logging `create-artifact|done`. The Step 3.4 coherence check now tests the actual file path instead of grepping `notes.md`, closing the gap where a blocked Write (e.g. from a PreToolUse hook) could go undetected.
- Fix: non-English output from DeepSeek models running at `max` effort — resolved by unsetting `CLAUDE_CODE_EFFORT_LEVEL` in the container config rather than adding a language guard to the skill preamble.

## 0.5.0 (2026-05-21)

- Adversarial review (Step 3.6) — spawns an adversarial agent for complex tickets that attacks the implementation plan from 7 angles (edge cases, data assumptions, error handling, security, side effects, test coverage, missing steps); blocks the pipeline on critical findings via `ADVERSARIAL_BLOCKED` gate-stop
- Project readiness (Step 0) in ticket-setup — detects project root, initializes CLAUDE.md via GitNexus/code-scan/empty-seeded paths, ensures GitNexus indexing; environment validation runs first before any external calls
- New safety gate: adversarial review blocked — pipeline halts if the adversarial agent finds blocking issues (incorrect behavior, data loss, security vulnerabilities)
- Documentation: EXEC phase steps, gate-stop codes table, safety gates count (5→6), pipeline log format

## 0.4.1 (2026-05-21)

- Token-tracker hooks — SubagentStart/Stop hooks that track per-phase token usage (input/output/cache) and wall-clock duration, appending `META|tokens` lines to the pipeline log with `elapsed_ms`
- Hooks bundled in `ticket-auto-pipeline/hooks/` and auto-installed via `plugin.json` — no manual setup required

## 0.4.0 (2026-05-20)

- REPRODUCE phase (Step 1.5) for bug tickets — reproduces the bug before implementation begins
- Interactive pipeline state diagram with full-view and phase drill-down
- Transcript capture for retrospective analysis — agent outputs persisted for post-mortem
- Heartbeat error diagnostics — captures API errors and gate-stop causes for retro enrichment
- Skill preamble deduplication — extracted shared preamble from 9 pipeline skills (290 lines removed)
- Env-check unification — dual-mode output (full pipe-delimited + colored validate) with thin wrapper
- jq error guards and flow.sh exit code handling in subskill error patterns
- RCE vector removed, dead code pruned, fragile JSON parsing replaced
- Documentation restructure: CHANGELOG, LICENSE, plugin-overview.md, per-plugin CLAUDE.md, docs/ index
- Catch-up bump: versions 0.3.17–0.3.22 were never tagged; 0.4.0 consolidates PRs #25–#30

## 0.3.16 (2026-05-20)

- PR comment reconciliation (Step 5.5) in ticket-auto pipeline
- Interactive pipeline state diagram with REPRODUCE phase
- Bug reproduction as Step 1.5 for bug tickets

## 0.3.15 (2026-05-20)

- jq error guards and flow.sh exit handling
- Loop agent failure logging
- Subskill error patterns

## 0.3.14 (2026-05-20)

- Env-check unification with dual-mode output (full + validate)
- Thin validate-env.sh wrapper delegates to env-check.sh

## 0.3.12 (2026-05-20)

- Shared skill preamble extraction — deduplicated 290 lines across 9 pipeline skills
- Parameterized agent spawn template

## 0.3.11 (2026-05-20)

- Ticket pipeline cleanup: removed RCE vector, dead code, fragile JSON
- Config centralization
- Defensive shell practices

## 0.3.10 (2026-05-20)

- Transcript capture for retro analysis
- Heartbeat error diagnostics — APPROVAL_REVOKED and VERDICT_UNPARSEABLE gate-stop enrichment
- EXEC_NO_ARTIFACT gate-stop enriched with artifact type and directory context

## 0.3.9 (2026-05-20)

- Gate comment reconciliation with code extraction
- Approval gate mechanism for complex tickets
- State machine trigger to re-add claimed label after approval in Approve state

## 0.3.7 (2026-05-19)

- Pipeline heartbeat log format (parallel stream to pipeline log)
- Heartbeat library (`lib/heartbeat.sh`) with 7 categorized helpers
- Dashboard, report, and retro consumers for heartbeat data

## 0.3.6 (2026-05-18)

- Log improvements: heartbeat log for full pipeline traceability
- Documented heartbeat log format in README

## 0.3.5 (2026-05-18)

- Fixed env-check.sh resolution to prefer plugin cache over synced lib
- Auto-discovery offer for missing/warn env values
- Row-count validation to prevent silent table truncation

## 0.3.4 (2026-05-18)

- Pipe-delimited table output for env-check
- Backtick-wrapped CLAUDE.md value handling
- `--show` flag for raw findings table with resolved env var values

## 0.3.2 (2026-05-17)

- `--summary-file` flag writes findings to file, skill displays verbatim
- Read-only env-check skill (no auto-writes)
- Structured output in env-check.sh for deterministic parsing

## 0.3.1 (2026-05-17)

- Simplified env-check to task-per-variable checklist
- Conversational /ticket-env-check with guided remediation

## 0.3.0 (2026-05-17)

- Removed UAT_URL git remote derivation
- Upgraded LOCAL_URL/UAT_URL to required with env var checks
- Replaced brittle REPOS_ROOT sed derivation with filesystem walk
- Removed project-specific hardcodes from validate-env.sh

## 0.2.4 (2026-05-17)

- Simplified /ticket-env-check output with auto-derived proposals

## 0.2.3 (2026-05-17)

- Simplified /ticket-env-check output
- Fixed env-check paths for plugin cache resolution

## 0.2.2 (2026-05-17)

- Added SessionStart hook to sync lib scripts
- Fallback path resolution for /ticket-env-check

## 0.2.1 (2026-05-17)

- Version bump with path corrections

## 0.2.0 (2026-05-16)

- Marketplace README and CLAUDE.md
- `linear-api.sh` script fallback for container pipeline runs
- `/ticket-env-check` slash command
- Corrected marketplace add command

## 0.1.0 (2026-05-15)

- Initial ticket-auto-pipeline plugin
- Core pipeline skills: ticket-auto, ticket-appraise, ticket-implement, ticket-verify, ticket-pr-review
- State machine (`state-machine.json`) with flow.sh executor
- Pipeline log format for crash recovery
- Shared bash libraries
