# Pipeline Heartbeat Log Format

Fine-grained operational log for the ticket-auto pipeline. Records decisions, fallbacks, retries, liveness signals, API calls, gate rulings, and configuration provenance. Complements the pipeline log (`pipeline-log-format.md`) which tracks _what_ happened — this tracks _why_.

## Format

```
ISO|CATEGORY|EVENT|STATUS|MSG|DETAIL
```

6 fields, pipe-delimited. No escaping. `ISO` = UTC timestamp from `date -u +%Y-%m-%dT%H:%M:%SZ`. `DETAIL` = flat JSON object with string values, `{}`, or empty. All writes go through `lib/heartbeat.sh` helpers — agents supply values; the library enforces format.

## Categories

| Category | Meaning | Typical status |
|----------|---------|----------------|
| `decision` | A determination was made (complexity score, merge verdict, etc.) | `fired` |
| `fallback` | Primary path was unavailable, fallback activated | `fired` |
| `heartbeat` | Periodic liveness signal during long operations | `ok` |
| `api` | External API call made (Linear, GitHub, Playwright browser) | `ok`, `fail` |
| `gate` | Gate evaluation: trigger dispatch, assertion, idempotency check | `ok`, `fail` |
| `retry` | Error classification and retry decision | `info`, `fired` |
| `source` | Configuration value provenance (UAT_URL resolution, etc.) | `info` |

### META

`META` is reserved for the schema header line only and is not a regular category:

```
ISO|META|schema|info|1|{}
```

## Statuses

| Status | Meaning |
|--------|---------|
| `ok` | Operation succeeded |
| `warn` | Operation succeeded with caveats |
| `fail` | Operation failed |
| `info` | Informational (classification, resolution) |
| `fired` | Decision/fallback triggered |

## DETAIL field constraints

- Must be a flat JSON object with string values only (e.g., `{"key":"value"}`)
- May be `{}` (empty JSON object) or empty
- No nested objects, no arrays, no multi-line content
- `hb_write` validates with `jq` — invalid JSON is logged to stderr and the entry is skipped

## Schema version header

Every new heartbeat log begins with a schema declaration as its first line:

```
ISO|META|schema|info|1|{}
```

Written by `hb_init` — idempotent, only writes if the file is empty or doesn't exist.

Current schema version: **1**

## Common events

### Decision events (`hb_decision`)

| Event | When | DETAIL |
|-------|------|--------|
| `autonomy-resolution` | Orchestrator resolves auto/semi-auto/manual | `{"mode":"<mode>"}` |
| `complexity-score` | Appraise agent determines complexity | `{"axes":"<list>","score":"<simple\|complex>"}` |
| `complexity-read` | Exec agent reads complexity from notes.md | `{"score":"<simple\|complex>"}` |
| `blast-radius` | Appraise agent completes codebase investigation | `{"file_count":"<N>"}` |
| `prior-art` | Appraise agent finds or fails to find prior art | — |
| `regression-verdict` | Appraise or exec agent completes regression check | `{"verdict":"<risky\|clean\|CONFLICT\|ADJACENT\|SUPERSEDES\|clear>"}` |
| `artifact-created` | Exec agent creates simple-fix.md or openspec change | `{"type":"<simple-fix\|openspec>"}` |
| `artifact-path` | Implement agent detects plan artifact | `{"type":"<simple-fix\|openspec>"}` |
| `implementation-mode` | Implement agent selects simple or openspec path | `{"mode":"<simple\|openspec>"}` |
| `re-appraisal-skip` | Exec agent skips Linear post after re-appraisal | — |
| `verification-verdict` | Verify agent renders final pass/fail | `{"verdict":"<PASS\|FAIL>","criteria_met":"<N>","criteria_total":"<M>"}` |
| `requirement-extraction` | PR review agent extracts ticket requirements | `{"count":"<N>"}` |
| `merge-decision` | PR review agent renders merge verdict, or orchestrator auto-merges | `{"verdict":"<✅\|⚠️\|❌>","reason":"<...>"}` |
| `findings-source` | PR iterate agent locates review findings | `{"source":"<pr\|session-file>"}` |
| `iteration-skip` | PR iterate agent detects already-passing review | — |
| `gap-count` | PR iterate agent parses gap count | `{"count":"<N>"}` |
| `plan-updated` | PR iterate agent updates plan artifact | `{"artifact":"<ARTIFACT>","iteration":"<N>"}` |
| `errata-count` | Wiki maintenance agent discovers errata | `{"count":"<N>"}` |
| `wiki-file-created` | Wiki maintenance creates new wiki file | `{"file":"<filename>"}` |
| `errata-skipped` | Wiki maintenance skips unclear entry | `{"ticket":"<TICKET-ID>"}` |
| `maintenance-complete` | Wiki maintenance finishes | `{"processed":"<N>","modified":"<M>"}` |
| `gate-result` | Orchestrator evaluates complexity gate outcome | `{"reason":"<complex\|manual-mode\|simple>"}` |
| `loop-back` | Orchestrator transitions between loop iterations | `{"attempt":"<N>\|iteration":"<N>"\|...}` |
| `pipeline-outcome` | Pipeline terminates (complete or stopped) | `{"outcome":"<complete\|stopped: ...>","reason":"<...>"}` |
| `retro-trigger` | Orchestrator decides whether to invoke retro | `{"gate_stops":"<N>","outcome":"<...>"}` |
| `fleet-kill` | Fleet controller kills a pipeline | `{"reason":"<auto-kill\|manual-intervention\|...>"}` |
| `fleet-restart` | Fleet controller restarts a pipeline (kill + spawn new) | `{"reason":"<auto-restart\|manual-restart\|...>"}` |

### Fallback events (`hb_fallback`)

| Event | When | DETAIL |
|-------|------|--------|
| `linear-api` | MCP Linear tool unavailable, using bash | `{"reason":"<...>"}` |
| `impact-data` | gitnexus impact unavailable, using grep | `{"reason":"<...>"}` |
| `browser-resume` | Playwright session lost, rebuilding | `{"reason":"<...>"}` |
| `wiki-bootstrap` | Wiki path not found, using default or aborting | `{"reason":"<...>"}` |
| `pr-review-data` | No PR found, falling back to session file | `{"reason":"<...>"}` |

### Heartbeat events (`hb_heartbeat`)

| Event | When |
|-------|------|
| `pipeline-start` | Pipeline begins execution (after autonomy resolution) |
| `orchestrator-waiting` | Orchestrator waiting for agent to complete |
| `agent-returned` | Agent completed (done or failed) — carries phase and result |
| `phase-transition` | Pipeline moves to next phase |

### API events (`hb_api`)

| Event | When | DETAIL |
|-------|------|--------|
| `linear-request` | Linear GraphQL call | `{"elapsed_ms":"<...>","http_code":"<...>"}` |
| `github-request` | GitHub API call | `{"elapsed_ms":"<...>"}` |
| `browser-navigate` | Playwright navigation | `{"url":"<...>","title":"<...>"}` |
| `browser-session` | Playwright session start or failure | — |

### Gate events (`hb_gate`)

| Event | When | DETAIL |
|-------|------|--------|
| `preflight` | Sentinel/config validation, gate evaluation start, or re-approval check | varies |
| `artifact-detect` | Orchestrator checks for plan artifact existence | `{"path":"<...>"\|"expected":"<...>"}` |
| `coherence-check` | Exec agent verifies complexity-artifact match | `{"declared":"<...>","artifact":"<...>"}` |
| `verdict-parse` | Orchestrator validates PR review verdict line | `{"count":"<N>"\|"verdict":"<...>"}` |
| `ci-checks` | PR review agent checks CI status | `{"state":"<passing\|failing>"}` |
| `iteration-limit` | PR iterate agent detects too many iterations | `{"iterations":"<N>"}` |
| `verify-exhausted` | Verify attempts reach max (3) | `{"attempts":"<N>"}` |
| `iteration-exhausted` | PR iterations reach max (3) | `{"iterations":"<N>"}` |
| `reverify-exhausted` | Re-verify retries reach max (3) | `{"retries":"<N>","iteration":"<N>"}` |
| `combined-cap` | Combined retry cap (verify + iteration + reverify) reached | `{"total_retries":"<N>"}` |
| `trigger-dispatch` | Flow trigger decision | `{"trigger":"<name>"}` |
| `assertion` | Post-trigger state assertion result | `{"trigger":"<name>"}` |
| `idempotent-skip` | Desired state already matches, no mutation | `{"trigger":"<name>"}` |
| `schema-check` | detect-resume validates heartbeat log or schema version | `{"file":"<path>"}` |
| `resume-point` | detect-resume determines resume point | — |

### Retry events (`hb_retry`)

| Event | When | DETAIL |
|-------|------|--------|
| `classify` | Error classified as transient or permanent | `{"http_code":"<...>","attempt":"<...>"}` |
| `flow-sh` | flow.sh trigger dispatch failed (exit > 0) | `{"trigger":"<name>","exit_code":"<N>","attempt":"<N>"}` |

### Source events (`hb_source`)

| Event | When | DETAIL |
|-------|------|--------|
| `uat-url` | UAT_URL resolution tier determined | `{"tier":"<env\|claude-md\|workspace\|git-root\|ancestor\|none>"}` |
| `linear-auth` | Linear API authentication confirmed | — |

## Usage

`$HB_LOG_FILE` is an absolute path set by the orchestrator (e.g., `/path/to/logs/CRE-42-heartbeat.log`). Agents source the library and call helpers:

```bash
source /path/to/lib/heartbeat.sh
export HB_LOG_FILE="/path/to/logs/CRE-42-heartbeat.log"

hb_decision "complexity-score" "fired" "simple, axes: cross-layer" '{"axes":"cross-layer","score":"simple"}'
hb_fallback "linear-api" "fired" "MCP unavailable, using bash" '{"reason":"MCP tool not found"}'
hb_heartbeat "orchestrator-waiting" "agent appraise running"
hb_api "linear-request" "ok" "get_issue CRE-42" '{"elapsed_ms":"234"}'
hb_retry "classify" "info" "transient: HTTP 503" '{"http_code":"503","attempt":"1"}'
hb_gate "preflight" "ok" "all sentinels passed" '{"passed":"3","failed":"0"}'
hb_source "uat-url" "info" "resolved from CLAUDE.md" '{"tier":"claude-md"}'
```

All helpers are no-ops if `$HB_LOG_FILE` is unset — scripts can unconditionally source and call without conditional logic.

## Validation

`hb_validate_line` validates a single line. `hb_validate_file` validates an entire log file — checks schema header, validates every line, returns error count. Called by `detect-resume.sh` before heartbeat parsing.

## Relationship to pipeline log

The pipeline log (`pipeline-log-format.md`) records phase/step transitions — it answers "what happened and in what order." The heartbeat log records decisions, fallbacks, retries, and liveness signals — it answers "why did it happen that way." Both share the pipe-delimited convention and UTC timestamp format.
