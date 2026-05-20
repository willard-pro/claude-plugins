# Changelog

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
