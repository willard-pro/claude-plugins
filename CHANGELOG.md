# Changelog

## 0.13.0 (2026-07-05)

Pipeline integrity, Phase 1 — closes the "agent self-reports done with zero
independent check" hole for the highest-value case: an implement agent claims
`done` while its openspec `tasks.md` still has unchecked boxes. Ships
warn-only, per the `openspec/changes/pipeline-integrity` design — it never
halts the pipeline in this phase; it only measures.

- Feature: new `lib/return-completeness-check.sh` — deterministic bash gate (0 complete / 1 incomplete / 2 error) that counts unchecked `- [ ]` boxes in a ticket's openspec `tasks.md`, resolved by searching `REPOS_ROOT` for the matching change directory (or via `--tasks-file` directly).
- Feature: `ticket-auto`'s STEP_4 (Implement) now runs this gate between `spawn_capture` and `spawn_agent_post`, scoped to openspec tickets only (`{ARTIFACT_TYPE}=openspec`) — simple-fix tickets are ungated in this phase (decision D1).
- Feature: a mismatch logs `|META|gate-warn|info|RETURN_INCOMPLETE — ...` — a new channel distinct from `gate-stop`, so `fleet-detect.sh` never escalates a warn-only mismatch to a human-must-resolve severity.
- Feature: `retro.sh` gains a `GATE_WARN_TOTAL` counter (and `{GATE_WARN_TOTAL}` in the `ticket-retro` report), separate from `GATE_STOP_TOTAL`, so the false-positive rate can be measured before any future flip to enforce mode. New `templates/RETURN_INCOMPLETE.md` investigation guide.
- Documented (not yet enforced): the D3 hard contract — once enforce mode ships (Phase 2), the router MUST call `spawn_agent_post RESULT=fail` on any non-zero gate exit, mirroring `gate-check.sh`'s existing contract.
- Test: added `lib/tests/test-return-completeness.sh` (6 cases: all-checked, unchecked, multi-unchecked count, missing tasks.md, `--tasks-file` bypass, unchecked-item listing), wired into the CI `Makefile`.

## 0.12.13 (2026-07-05)

Router hardening — `ticket-auto`'s thin dispatch router and `detect-resume.sh` coupled
deterministic greps to unspecified LLM free-text/emoji output in several places; this
release closes those gaps (14 findings, Increments A–F of the router-hardening plan).

- Fix: `detect-resume.sh` `VERIFY_ATTEMPTS` now counts only terminal `|VERIFY|verify|(done|fail)|` lines instead of any `|VERIFY|*|fail|` sub-step line — a pre-flight hiccup no longer double-counts a verify attempt. (R6)
- Fix: `MAINTENANCE_FROM` extraction now excludes `|MAINTENANCE|prescan|` lines — the auto-invoked prescan gate no longer gets mistaken for a resumable wiki-maintenance sub-step. (R7)
- Fix: preflight team-resolution distinguishes a failed Linear teams query from a genuine multi-team result, instead of reporting "multiple teams" on any query failure. (R14)
- Fix: `implement-complete`'s `flow.sh` resolution now falls back to the plugin-cache path (matching every other resolution site) and reports failure via `hb_retry` instead of silently swallowing it with `|| true` — plugin-cache-only installs no longer drift Linear state silently. (R3)
- Fix: prescan spawn success is now judged by grepping the captured `AGENT_RESULT` for the skill's completion marker, not by `spawn_capture`'s exit code (which is a log write and always succeeds). (R9)
- Fix: STEP_6's retro auto-trigger condition 2 now tests for positive success markers (`VERIFY|verify|done|PASS` + `PR-REVIEW|post-findings|done|Verdict: ✅`) instead of the absence of the outcome-write marker, which that same step wrote *after* the check ran — the retro agent no longer spawns on every clean run. (R2)
- Fix: `spawn_agent_post`'s done/fail idempotency guard is now tail-scoped (compares only the log's last line) instead of whole-file — loop phases (PR-review iteration, verify retry) now get a fresh terminal log line on every cycle instead of only the first. (R4)
- Feature: `spawn_agent_post` accepts an optional `VERDICT=<PASS|FAIL|OK|WARN|BLOCK>` parameter, prepended to `MSG` as a canonical token (`done|PASS — <text>`). `detect-resume.sh`'s STEP_4_6 routing and `ITERATION` counting now match these tokens instead of router prose / byte-exact emoji bytes. Documented in `pipeline-log-format.md#verdict-tokens`. (R5)
- Fix: added `VERIFY_LAST` resume hint — if the last terminal VERIFY event is a `fail` with no later `IMPLEMENT|implement|done`, the pipeline dispatches re-implement before re-verifying instead of re-running verify against the same unfixed code. (R8)
- Feature: auto-merge now reads the confirmed Linear outcome label via a new `META|outcome-label|info|<value>` line (written by `outcome-label-check.sh`) instead of the IMPLEMENT terminal line, which never carried the Smooth/Rough/Hard value. Auto-merge now fires in both `auto` and `semi-auto` autonomy modes (previously `semi-auto` only, and effectively dead code). (R1)
- Feature: STEP_5_5 (PR comment reconciliation) caps `PR_FEEDBACK_CYCLE` at 3, gate-stopping with `PR_FEEDBACK_EXHAUSTED` on a 4th round of new human comments; `pr-reconcile` now emits a `cycle#N` marker so the counter advances. (R10)
- Fix: the prescan freshness gate is skipped entirely when resuming at STEP_4 or later — crash recovery mid-implement/verify/PR-review/report no longer pays the per-repo freshness-check cost. (R11)
- Fix: the `META|autonomy` write is now guarded against a resume silently re-appending or switching modes — an explicit `META|mode-change|warn|` event is logged when a resume's `--mode` flag differs from the recorded autonomy. (R12)
- Fix: the tmux dashboard pane spawn now checks for an existing `dashboard.py $LOG_FILE` process before splitting a new pane — resuming a pipeline no longer stacks duplicate panes. (R13)
- Test: added ~70 new tests across `test-pipeline-phases.sh`, `test-detect-resume.sh` (new), `test-spawn-helper.sh`, and `test-outcome-label-check.sh` covering every fix above.
- Chore: `marketplace.json` version synced from 0.12.11 to 0.12.13 (had drifted behind `plugin.json` and `README.md`).

## 0.9.1 (2026-06-02)

- Fix: Fleet controller `_flow_mutex_held()` now uses `flock -n` on `./logs/.ticket-flow-{tid}.lock` instead of pidfile `kill -0` on `/tmp/ticket-auto-{tid}-flow.lock` — mutex check was dead code (wrong path, wrong primitive). (F1)
- Fix: Added 6th detector `detect_flow_failures` to fleet-detect.sh — scans heartbeat logs for `retry|flow-sh|fail` entries. 1 failure → WARN, 2+ → KILL. (F4)
- Fix: `fleet_restart_pipeline` now writes `META|fleet-restart-marker` to pipeline log instead of printing `RESTART_ELIGIBLE=` to stdout. Monitor loop updated to scan for markers and emit `ACTION:spawn-restart`. (F5)
- Fix: Heartbeat category `HB` now explicitly rejected in `hb_write` with diagnostic message. Added BASH_SOURCE caller validation warning. (Bug #1)
- Fix: `spawn_agent_pre` captures pinger/watchdog PIDs; `spawn_agent_post` reaps them via PID-targeted `wait` with 5-second timeout. Added stop-file existence check before spawn to close kill-during-spawn race window. (Bug #4, F10)
- Fix: Added `-c` compact flag to intermediate `jq -n` calls in `fleet_detect_all` (entry + summary JSON). Final output remains pretty-printed. (F2)
- Fix: `_last_field` now asserts `idx < 5` — fields 5+ require `_last_msg` to preserve embedded pipe characters. (F3)
- Fix: `fleet_kill_pipeline` guards against nonexistent pipeline logs — returns 1 instead of creating orphaned log directories. (F6)
- Fix: Severity capped at 2 (KILL) when `FLEET_AUTO_RESTART=false` — dashboard labels show "KILL (auto-restart off)" instead of misleading "RESTART". (F7)
- Fix: Added `FLEET_MAX_LOG_AGE_HOURS` config (empty default = no filter) — `fleet_detect_all` skips pipeline logs whose mtime exceeds threshold. (F8)
- Fix: `fleet-intervene.sh` now sources `heartbeat.sh` at file level with declare-guard pattern — `hb_decision` audit calls no longer silently skipped. (F9)
- Cleanup: Removed duplicate `LINEAR_API_KEY` + `chmod` block in `spawn-helper.sh` `spawn_write_env`. Removed duplicate test definitions and dispatcher registrations in `test-spawn-helper.sh`.
- Test: Added 24 new tests across `test-fleet-detect.sh`, `test-fleet-intervene.sh` (new), `test-heartbeat.sh`, and `test-spawn-helper.sh`. All existing tests pass.

## 0.9.0 (2026-06-02)

- Added: Ticket Fleet Controller — automated pipeline intervention with 5 detection engines (phase failures, stalls, zombies, loops, abandonment), severity-based escalation (WARN→KILL→KILL+RESTART), dry-run mode, health dashboard (terminal + markdown report), and three invocation modes (monitor, status, intervene).
- Added: `lib/fleet-detect.sh` (~300 lines) — detection engine with `detect_phase_failures`, `detect_stalls`, `detect_zombies`, `detect_loops`, `detect_abandoned`, `fleet_detect_all` aggregator, and diagnostic context extraction.
- Added: `lib/fleet-intervene.sh` (~150 lines) — intervention library with `fleet_kill_pipeline`, `fleet_restart_pipeline`, `fleet_can_restart`, `FLEET_DRY_RUN` guard, and flow.sh mutex awareness.
- Added: `lib/fleet-dashboard.sh` (~140 lines) — dashboard renderer with `fleet_render_dashboard` (terminal) and `fleet_write_report` (markdown).
- Added: `skills/ticket-fleet-controller/SKILL.md` — fleet controller skill with monitor, status, and intervene modes.
- Added: `lib/tests/test-fleet-detect.sh` — 32 unit tests for detection engine following existing pure-bash harness pattern.
- Added: 7 `FLEET_*` configuration variables to `lib/config.sh` with safe defaults (`FLEET_AUTO_RESTART` defaults to `false`).
- Added: `spawn_fleet_kill` function to `lib/spawn-helper.sh` — unified kill primitive touching both stop files with heartbeat audit.

## 0.8.1 (2026-06-02)

- Fix: Added missing comma after `version` field in `.claude-plugin/plugin.json` — JSON parse error `Expected '}'` prevented plugin installation.

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
