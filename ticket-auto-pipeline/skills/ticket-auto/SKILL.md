---
name: ticket-auto
description: Fully autonomous ticket pipeline — appraise, exec, implement, PR review, merge. Requires zero user input beyond the ticket ID. Stops only for complex tickets at the approve gate. Use when the user says "/ticket-auto <ID>", "auto <ID>", "process ticket <ID>", or "run ticket <ID> end to end".
---

# Ticket Auto — Autonomous Pipeline

You have been given a ticket ID as the argument (e.g. `WIL-42`). Execute the full pipeline below — no user interaction beyond reporting results.

## Pipeline Preamble

Follow the pipeline preamble in `~/.claude/skills/lib/skill-preamble.md` with parameters: TICKET_ID=<from args>, PHASE=none, FROM_FLAG=none, HAS_LINEAR_ACCESS=true, LINEAR_OPS=get_issue,get_comments,save_comment, HAS_GUARD=true, EXTRA_GUARD=validate-env, HAS_PROJECT_CONTEXT=false, HAS_LOGGING=false, HAS_HEARTBEAT=false, HAS_STEP_DISPATCH=false, HAS_TASK_TRACKER=false

---

## Linear access strategy

When `$LINEAR_API_KEY` is set in the environment, use bash calls to `~/.claude/skills/lib/linear-api.sh` for **all** Linear operations. When `$LINEAR_API_KEY` is unset, fall back to MCP tools (`mcp__linear-server__*`).

**Check before each Linear operation:**
```bash
if [ -n "${LINEAR_API_KEY:-}" ]; then
  # Use linear-api.sh
  result=$(bash -c "source ~/.claude/skills/lib/linear-api.sh; <function> <args>")
else
  # Use MCP fallback
  mcp__linear-server__<tool>(...)
fi
```

**Function mapping:**

| Operation | linear-api.sh call | MCP fallback |
|-----------|-------------------|--------------|
| Fetch issue | `get_issue "<id>"` | `mcp__linear-server__get_issue(id: "<id>")` |
| Fetch comments | `get_comments "<id>"` | `mcp__linear-server__list_comments(id: "<id>")` |
| Post comment | `save_comment "<id>" "<body>"` | `mcp__linear-server__save_comment(issueId: "<id>", body: "<body>")` |

The `get_issue` function returns the issue object already unwrapped from `.data.issue` — use `jq` to extract fields directly (e.g., `.id`, `.title`, `.labels`). The `get_comments` function returns a JSON array of comment nodes.

### API error capture convention

After every Linear API call (`get_issue`, `get_comments`, `save_comment`, `get_me`), capture failures in the heartbeat log using `hb_retry`. This is mandatory — never silently discard API errors.

**get_issue failure pattern:**
```bash
_raw=$(bash -c "source ~/.claude/skills/lib/linear-api.sh; get_issue '{TICKET-ID}'" 2>&1)
_rc=$?
if [ $_rc -ne 0 ] || ! echo "$_raw" | jq -e '.id' >/dev/null 2>&1; then
  _snippet=$(echo "$_raw" | head -c 200)
  hb_retry "get-issue" "fail" "get_issue failed (exit ${_rc})" \
    "{\"command\":\"get_issue\",\"ticket\":\"{TICKET-ID}\",\"exit_code\":\"${_rc}\",\"error_snippet\":\"$(echo "$_snippet" | tr '"' "'"  | tr '\n' ' ')\"}"
  # Handle failure per-step (report or stop as appropriate)
fi
```

**get_comments failure pattern:**
```bash
_raw=$(bash -c "source ~/.claude/skills/lib/linear-api.sh; get_comments '{TICKET-ID}'" 2>&1)
_rc=$?
if [ $_rc -ne 0 ]; then
  hb_retry "get-comments" "fail" "get_comments failed (exit ${_rc})" \
    "{\"command\":\"get_comments\",\"ticket\":\"{TICKET-ID}\",\"exit_code\":\"${_rc}\"}"
fi
```

**jq extraction failure pattern:** When `jq` fails to extract a field from a Linear API response, capture it before stopping:
```bash
_field=$(echo "$_raw" | jq -r '.fieldName' 2>&1)
if [ $? -ne 0 ] || [ "$_field" = "null" ]; then
  hb_retry "jq-parse" "fail" "jq extraction failed for fieldName" \
    "{\"error_type\":\"jq_parse\",\"command\":\"get_issue\",\"field\":\"fieldName\"}"
fi
```

**flow.sh failure pattern:** After every `flow.sh` invocation, capture non-zero exits:
```bash
_flow_sh="${HOME}/.claude/skills/ticket-flow/flow.sh"
[ -f "$_flow_sh" ] || _flow_sh=$(find "${HOME}/.claude/plugins/cache" -name "flow.sh" -path "*/ticket-auto-pipeline/*/skills/ticket-flow/flow.sh" 2>/dev/null | sort | tail -1)
bash "$_flow_sh" "{TICKET-ID}" "{trigger}" 2>&1
_rc=$?
if [ $_rc -ne 0 ]; then
  _error_type=$( [ $_rc -eq 7 ] && echo "state_assertion" || echo "flow_error" )
  hb_retry "flow-sh" "fail" "flow.sh {trigger} failed (exit ${_rc})" \
    "{\"trigger\":\"{trigger}\",\"exit_code\":\"${_rc}\",\"ticket\":\"{TICKET-ID}\",\"error_type\":\"${_error_type}\"}"
fi
```

**API telemetry pattern:** For read operations where elapsed time matters, wrap with `hb_api`:
```bash
_t0=$(date +%s)
_raw=$(bash -c "source ~/.claude/skills/lib/linear-api.sh; get_issue '{TICKET-ID}'" 2>&1)
_rc=$?
_elapsed=$(( $(date +%s) - _t0 ))
hb_api "get-issue" "$( [ $_rc -eq 0 ] && echo ok || echo fail )" \
  "get_issue {TICKET-ID} (${_elapsed}s)" \
  "{\"command\":\"get_issue\",\"ticket\":\"{TICKET-ID}\",\"elapsed_s\":\"${_elapsed}\",\"exit_code\":\"${_rc}\"}"
```

Apply the API telemetry pattern to `get_issue` and `get_comments` calls at each step.

---

## Step 0 — Clear context: Run `/clear`.

---

## Step 0.1 — Resolve autonomy flag

Resolve `{AUTONOMY}` from the argument string using three-tier precedence: CLI arg → `$TICKET_AUTONOMY` env var → `manual` default.

```bash
if echo "{TICKET_ARG}" | grep -qw '\-\-semi-auto'; then
  AUTONOMY="semi-auto"
elif echo "{TICKET_ARG}" | grep -qw '\-\-auto'; then
  AUTONOMY="auto"
elif echo "{TICKET_ARG}" | grep -qw '\-\-manual'; then
  AUTONOMY="manual"
elif [ -n "$TICKET_AUTONOMY" ]; then
  case "$TICKET_AUTONOMY" in
    manual|auto|semi-auto) AUTONOMY="$TICKET_AUTONOMY" ;;
    *) echo "WARN: unrecognised TICKET_AUTONOMY value '$TICKET_AUTONOMY', defaulting to manual"
       AUTONOMY="manual" ;;
  esac
else
  AUTONOMY="manual"
fi
# Strip flag from arg to get the bare ticket ID
TICKET_ID=$(echo "{TICKET_ARG}" | sed 's/--semi-auto//;s/--auto//;s/--manual//' | tr -s ' ' | xargs)
```

Set `{AUTONOMY}` and `{TICKET_ID}` — used throughout the pipeline.

### Initialize heartbeat log early

The heartbeat log must exist before preflight (Step 0.4) so failures leave a trace. The pipeline log stays at Step 0.6 (dashboard needs it).

```bash
mkdir -p ./logs
HB_LOG_FILE="$PWD/logs/{TICKET-ID}-heartbeat.log"
source ~/.claude/skills/lib/heartbeat.sh
source ~/.claude/skills/lib/capture-transcript.sh
export HB_LOG_FILE="$HB_LOG_FILE"
hb_init
# Idempotency guards: skip if already written (prevents duplication on resume)
if ! grep -q '|heartbeat|pipeline-start|' "$HB_LOG_FILE" 2>/dev/null; then
  hb_heartbeat "pipeline-start" "pipeline starting — autonomy={AUTONOMY}, ticket={TICKET-ID}"
fi
if ! grep -q '|decision|autonomy-resolution|' "$HB_LOG_FILE" 2>/dev/null; then
  hb_decision "autonomy-resolution" "fired" "autonomy set to {AUTONOMY}" '{"mode":"{AUTONOMY}"}'
fi
```

---

## Step 0.4 — Preflight: Linear config + API key check

Before creating any log file, validate that the Linear team is correctly configured.

```bash
SENTINEL_DIR="$HOME/.claude/state/ticket-flow"
SM="$HOME/.claude/skills/ticket-flow/state-machine.json"
SM_HASH=$(sha256sum "$SM" | cut -d' ' -f1)

# Resolve team ID from env or first available team
TEAM_ID="${LINEAR_TEAM_ID:-}"
if [ -z "$TEAM_ID" ]; then
  teams=$(LINEAR_API_KEY="$LINEAR_API_KEY" bash -c \
    "source ~/.claude/skills/lib/linear-api.sh; linear_graphql '{\"query\":\"query{teams{nodes{id name}}}\"}'")
  team_count=$(echo "$teams" | jq '.data.teams.nodes | length')
  [ "$team_count" -eq 1 ] || { echo "Multiple Linear teams — set LINEAR_TEAM_ID"; exit 1; }
  TEAM_ID=$(echo "$teams" | jq -r '.data.teams.nodes[0].id')
fi

SENTINEL="$SENTINEL_DIR/validated-${TEAM_ID}"
```

**Warm hit** — sentinel exists and hash matches: skip validation.
```bash
if [ -f "$SENTINEL" ] && grep -q "^sm_hash=${SM_HASH}$" "$SENTINEL" 2>/dev/null; then
  echo "Preflight: sentinel valid — skipping Linear config check"
  hb_gate "preflight" "ok" "sentinel valid, skipping config check"
  # Log after pipeline log is initialized (Step 0.6 logs META|preflight|skip|sentinel-valid)
else
  # Cold run — run full validation
  _validate_sh="${HOME}/.claude/skills/ticket-flow/validate-linear-config.sh"
  [ -f "$_validate_sh" ] || _validate_sh=$(find "${HOME}/.claude/plugins/cache" -name "validate-linear-config.sh" -path "*/ticket-auto-pipeline/*/validate-linear-config.sh" 2>/dev/null | sort | tail -1)
  bash "$_validate_sh" "$TEAM_ID" || {
    echo "Preflight failed: Linear config validation error. Fix the team config and retry." >&2
    hb_gate "preflight" "fail" "Linear config validation failed" "{\"team_id\":\"$TEAM_ID\"}"
    exit 1
  }
  hb_gate "preflight" "ok" "Linear config validated" "{\"team_id\":\"$TEAM_ID\"}"
fi
```

**API key check** — always verify connectivity:
```bash
me=$(bash -c "source ~/.claude/skills/lib/linear-api.sh; get_me" 2>&1) || {
  echo "Preflight failed: Linear API key unset or rejected (exit 4). Set LINEAR_API_KEY." >&2
  hb_gate "preflight" "fail" "Linear API key rejected" "{\"exit_code\":\"4\"}"
  exit 4
}
echo "Linear: API key (direct GraphQL) — authenticated as $(echo "$me" | jq -r '.name // "unknown"')"
hb_source "linear-auth" "ok" "authenticated as $(echo "$me" | jq -r '.name // "unknown"')"
```

Log preflight result after the pipeline log is initialized in Step 0.6:
- Warm hit: `|META|preflight|skip|sentinel-valid`
- Cold run: `|META|preflight|ok|<states>/<labels>` (written by validate-linear-config.sh itself)

---

## Step 0.5 — Detect project context

Read `CLAUDE.md` and extract ALL available project-context fields: `{REPOS_ROOT}` (parent path of all service dirs), `{ISSUE_PREFIX}` (issue ID prefix, e.g. `CRE`), `{BE_SERVICES}` (BE service dir names), `{WIKI_ROOT}` (wiki directory path; use default if not found), `{BE_TEST_CMD}` (backend test command), `{FE_TEST_CMD}` (frontend test command; skip FE tests if absent), `{LOCAL_URL}` (local dev URL), `{UAT_URL}` (UAT base URL), `{SLACK_CHANNEL}` (Slack channel for notifications).

After extraction, write the env file that sub-agents source for project context:

```bash
source ~/.claude/skills/lib/spawn-helper.sh
spawn_write_env \
  TICKET_ID="{TICKET_ID}" \
  REPOS_ROOT="{REPOS_ROOT}" \
  ISSUE_PREFIX="{ISSUE_PREFIX}" \
  BE_SERVICES="{BE_SERVICES}" \
  WIKI_ROOT="{WIKI_ROOT}" \
  BE_TEST_CMD="{BE_TEST_CMD}" \
  FE_TEST_CMD="{FE_TEST_CMD}" \
  LOCAL_URL="{LOCAL_URL}" \
  UAT_URL="{UAT_URL}" \
  SLACK_CHANNEL="{SLACK_CHANNEL}"
```

This MUST run before Step 0.6 (pipeline log init) and before Step 1 (first agent spawn). The env file is needed by every `spawn_agent_pre` call — sub-agents source it via `source /tmp/ticket-auto-{TICKET_ID}-env.sh`.

---

## Step 0.6 — Create task tracker + initialize pipeline log

Initialize retry counters:
- `{VERIFY_ATTEMPTS}` = 0 (capped at 3, for Step 4.5 retries)
- `{VERIFY_RETRIES}` = 0 (capped at 3, resets per PR iteration, for Step 5d2 retries)

Create a TaskCreate for every remaining step (Steps 1 through 6). Each task subject = the step heading. Mark each step completed as soon as it finishes — do not batch.

Initialize the pipeline log and launch the dashboard (heartbeat log already initialized after Step 0.1):

```bash
mkdir -p ./logs
LOG_FILE="$PWD/logs/{TICKET-ID}-pipeline.log"
CLAUDE_LOG_FILE="$PWD/logs/{TICKET-ID}-claude.log"
touch "$LOG_FILE"
cl_init
YELLOW=$(tput setaf 3); BOLD=$(tput bold); RESET=$(tput sgr0)
if [ -n "$TMUX" ]; then
  tmux split-window -h "python3 ~/.claude/skills/ticket-auto/dashboard.py $LOG_FILE; read"
  echo "${BOLD}${YELLOW}(Dashboard opened in right pane.)${RESET}"
else
  echo "${BOLD}${YELLOW}Dashboard ready. In a second terminal run:${RESET}"
  echo "${BOLD}${YELLOW}  python3 ~/.claude/skills/ticket-auto/dashboard.py $LOG_FILE${RESET}"
fi
```

Log the resolved autonomy mode immediately after dashboard launch:
```bash
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|META|autonomy|info|{AUTONOMY}" >> {LOG_FILE}
hb_gate "phase-transition" "ok" "START → APPRAISE"
```

### Logging convention

The orchestrator owns the pipeline log file. Sub-agents write their own step-level progress directly to `$LOG_FILE` using the format from `~/.claude/skills/pipeline-log-format.md`. Each sub-agent skill has a `## Logging (--from-auto)` section that handles this.

### Agent spawn template

Every agent spawn follows this pattern with 8 slots. Fill all slots explicitly — no implicit defaults.

```
## {PHASE} spawn
Follow the agent spawn template with: PHASE={PHASE}, SKILL={SKILL}, DESCRIPTION={DESCRIPTION}, EXTRA_FLAGS={EXTRA_FLAGS}, SKILL_INSTRUCTIONS={SKILL_INSTRUCTIONS}, EXTRACT={EXTRACT}, FAIL_ACTION={FAIL_ACTION}, NEXT_PHASE={NEXT_PHASE}
```

**Slots:**

| Slot | Description |
|------|-------------|
| `{PHASE}` | Uppercase phase: APPRAISE, REPRODUCE, EXEC, IMPLEMENT, VERIFY, MAINTENANCE, PR-REVIEW |
| `{SKILL}` | Slash command: `/ticket-appraise`, `/ticket-reproduce`, `/ticket-appraise-exec`, `/ticket-implement`, `/ticket-verify`, `/wiki-maintenance`, `/ticket-document`, `/ticket-pr-review`, `/ticket-pr-iterate` |
| `{DESCRIPTION}` | What the agent does (for the waiting log entry) |
| `{EXTRA_FLAGS}` | Flags like `--from-auto`, `--env local`, `--from-step {FROM}` |
| `{SKILL_INSTRUCTIONS}` | Additional instructions after the exports (e.g., "Follow the skill exactly.", "Use Serena for all code navigation.") |
| `{EXTRACT}` | Fields to extract from agent output |
| `{FAIL_ACTION}` | `stop` or `warn-continue` (maintenance is non-blocking) |
| `{NEXT_PHASE}` | Next phase for the transition heartbeat |

**Execution sequence (using spawn-helper.sh):**

All spawn boilerplate is handled by `lib/spawn-helper.sh`. Each spawn site follows this 3-step pattern:

1. **Pre-spawn** — `spawn_agent_pre` handles the waiting log entry, heartbeat pinger start, phase context file, cl_write handoff, and prints the full agent prompt (including env sourcing):
   ```bash
   source ~/.claude/skills/lib/spawn-helper.sh
   _prompt=$(spawn_agent_pre \
     PHASE=<phase> STEP=<step> TICKET_ID={TICKET-ID} \
     LOG_FILE={LOG_FILE} HB_LOG_FILE={HB_LOG_FILE} CLAUDE_LOG_FILE=$CLAUDE_LOG_FILE \
     SKILL=/ticket-<skill> FLAGS="--from-auto" \
     FROM_STEP={<FROM>} \
     DESCRIPTION="<what the agent does>" \
     INSTRUCTIONS="<additional skill-specific instructions>")
   ```

2. **Spawn** — pass `$_prompt` to the phase-appropriate agent (e.g., `ticket-appraise-agent`).

3. **Post-spawn** — `spawn_capture` persists output, then `spawn_agent_post` writes done/fail log entries, stops pinger, and writes heartbeat transitions:
   ```bash
   spawn_capture TICKET_ID={TICKET-ID} PHASE=<phase> RESULT="$AGENT_RESULT"
   # On success:
   spawn_agent_post TICKET_ID={TICKET-ID} RESULT=done MSG="<result>" NEXT_PHASE=<next>
   # On failure (blocking):
   spawn_agent_post TICKET_ID={TICKET-ID} RESULT=fail MSG="<reason>"
   # On failure (non-blocking, e.g. document/wiki):
   FAIL_ACTION=warn-continue spawn_agent_post TICKET_ID={TICKET-ID} RESULT=fail MSG="<reason>"
   ```

At session end, write a trace file:

```bash
cat > {ticket-dir}/auto-session.md << 'TRACE'
# auto session — {ISSUE-ID}
**Date:** {today}
**Outcome:** {completed | stopped: <reason>}

## Step trace
- [x] Step 1: Appraise — {simple|complex}, {N} files traced
- [x] Step 1.5: Reproduce — {REPRODUCED|NOT_REPRODUCED|BLOCKED|skipped: not bug}
- [x] Step 2: Exec — {simple-fix|openspec: <name>}
- [x] Step 3: Gate — {auto-approved|stopped: complex}
- [x] Step 4: Implement — {Smooth|Rough|Hard}
- [x] Step 4.5: Verify — {✅ PASS (N attempts)|❌ FAIL after N|skipped: no UI}
- [x] Step 4.6: PR review — {✅|⚠️}, {N} iterations, {N} re-verify retries
- [x] Step 5: Document + Wiki — ai-context.md ({trivial|non-trivial}), {N} errata processed, {N} ai-context findings promoted
- [x] Step 6: Report — done
TRACE
```

---

## Step 0.7 — Crash-recovery detection

Run `/ticket-detect-resume {TICKET-ID}` inline (execute the skill logic directly — no agent spawn needed). Parse the `DETECT_RESUME_RESULT` block and set all variables:

`{RESUME_STEP}`, `{APPRAISE_FROM}`, `{REPRODUCE_FROM}`, `{EXEC_FROM}`, `{IMPLEMENT_FROM}`, `{MAINTENANCE_FROM}`, `{DOCUMENT_FROM}`, `{VERIFY_FROM}`, `{PR_REVIEW_FROM}`, `{PR_ITERATE_FROM}`, `{TICKET_DIR}`, `{COMPLEXITY}`, `{ARTIFACT_TYPE}`, `{BRANCH}`, `{TICKET_TITLE}`, `{VERIFY_ATTEMPTS}`, `{ITERATION}`, `{PR_FEEDBACK_CYCLE}`, `{AUTONOMY}` (read from `META|autonomy|info|` log line).

**If `RESUME_STEP = SCHEMA_MISMATCH`:**
Report:
```
{TICKET-ID} pipeline log has an incompatible schema version.
Log file: {LOG_FILE}
Log version: {SCHEMA_LOG_VERSION}  Expected: {SCHEMA_EXPECTED}

The log cannot be safely resumed. Options:
  1. Archive the log (mv {LOG_FILE} {LOG_FILE}.bak) and restart from Step 1.
  2. Investigate manually if a partial run may have left Linear state inconsistent.
```
Stop here.

**If `RESUME_STEP = GATE_STILL_HELD`:**
Report:
```
{TICKET-ID} is still held — the gate fired because this is a complex ticket.
Add the `approved` label in Linear and re-run `/ticket-auto {TICKET-ID}`.
```
Stop here.

**If recovering (`RESUME_STEP ≠ STEP_1`):**
```bash
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|META|recovery|info|Resuming from {RESUME_STEP}" >> {LOG_FILE}
```
Mark tasks for all steps before `{RESUME_STEP}` as completed in the TaskCreate tracker.

---

## Entry-point dispatch

Based on `{RESUME_STEP}`, jump directly to the corresponding step. Steps before the entry point are not executed.

| RESUME_STEP | Jump to |
|-------------|---------|
| STEP_1 | Step 1 (Appraise) |
| STEP_1_5 | Step 1.5 (Reproduce) |
| STEP_2 | Step 2 (Exec) |
| STEP_3 | Step 3 (Gate) |
| STEP_3_5 | Step 3.5 (Comment Reconciliation) |
| STEP_4 | Step 4 (Implement) |
| STEP_4_5 | Step 4.5 (Verify) |
| STEP_4_6 | Step 4.6 (PR Review loop) |
| STEP_5 | Step 5 (Document + Wiki Maintenance) |
| STEP_5_5 | Step 5.5 (PR Comment Reconciliation) |
| STEP_6 | Step 6 (Report) |

---

## Step 1 — Appraise

### Appraise spawn

Run pre-spawn boilerplate (waiting log, heartbeat pinger, phase context). Capture the generated agent prompt:
```bash
source ~/.claude/skills/lib/spawn-helper.sh
_appraise_prompt=$(spawn_agent_pre \
  PHASE=APPRAISE STEP=appraise TICKET_ID={TICKET-ID} \
  LOG_FILE={LOG_FILE} HB_LOG_FILE={HB_LOG_FILE} CLAUDE_LOG_FILE=$CLAUDE_LOG_FILE \
  SKILL=/ticket-appraise FLAGS="--from-auto" \
  FROM_STEP={APPRAISE_FROM} \
  DESCRIPTION="investigating {TICKET-ID}" \
  INSTRUCTIONS="Follow the skill exactly. When you hit Resume mode and the workspace already exists, if asked 'continue or re-investigate?', choose 'continue' — do not prompt. Report only the final handoff output.")
```

Spawn a `ticket-appraise-agent` with `$_appraise_prompt` as the instruction.

Wait for the agent. Persist:
```bash
spawn_capture TICKET_ID={TICKET-ID} PHASE=appraise RESULT="$AGENT_RESULT"
```

Extract from its result:
- `{COMPLEXITY}` — `simple` or `complex`
- `{TICKET_DIR}` — local workspace path (derive from the find command in Step 1 of appraise-exec pattern, or read from agent output)
- `{TICKET_TITLE}` — the full ticket title. If not present in the agent's handoff, fetch it via the Linear access strategy above (bash `get_issue` when key is set, MCP fallback otherwise) before writing the META title line.

If the agent fails → post fail and stop:
```bash
spawn_agent_post TICKET_ID={TICKET-ID} RESULT=fail
```
Stop here.

On success → post done, then write META title/artifact lines:
```bash
spawn_agent_post TICKET_ID={TICKET-ID} RESULT=done \
  MSG="{COMPLEXITY}, {N} files traced" NEXT_PHASE=EXEC
# Guard: only emit title if resolved (not empty, not "unknown")
if [ -n "{TICKET_TITLE}" ] && [ "{TICKET_TITLE}" != "unknown" ] && ! echo "{TICKET_TITLE}" | grep -q '^unknown$'; then
  # Guard: only emit if no prior META|title entry exists (at-most-once)
  if ! grep -q '|META|title|info|' {LOG_FILE} 2>/dev/null; then
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|META|title|info|{TICKET-ID}: {TICKET_TITLE}" >> {LOG_FILE}
  fi
fi
# Guard: only emit artifact if path is absolute
if [ -n "{TICKET_DIR}" ] && [ "$(echo '{TICKET_DIR}' | cut -c1)" = "/" ]; then
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|META|artifact|info|notes:{TICKET_DIR}/notes.md" >> {LOG_FILE}
fi
```

---

## Step 1.5 — Reproduce (bug tickets only)

### Bug label detection

Extract labels from `$ISSUE_JSON` (already fetched during appraise):

```bash
_bug_labels=$(echo "$ISSUE_JSON" | jq -r '.labels.nodes[].name // empty' 2>/dev/null | grep -c "bug" || echo "0")
```

If `_bug_labels` is 0 → skip Step 1.5. Write a skip log entry and proceed to Step 2:

```bash
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|REPRODUCE|reproduce|skip|not a bug ticket" >> {LOG_FILE}
hb_gate "phase-transition" "ok" "APPRAISE → REPRODUCE (skipped)"
```

Then jump to **Step 2 — Exec**.

If `_bug_labels` is > 0 → proceed with the reproduce spawn below.

### Reproduce spawn

```bash
hb_gate "phase-transition" "ok" "APPRAISE → REPRODUCE"
```

Run pre-spawn boilerplate. Capture the generated agent prompt:
```bash
source ~/.claude/skills/lib/spawn-helper.sh
_reproduce_prompt=$(spawn_agent_pre \
  PHASE=REPRODUCE STEP=reproduce TICKET_ID={TICKET-ID} \
  LOG_FILE={LOG_FILE} HB_LOG_FILE={HB_LOG_FILE} CLAUDE_LOG_FILE=$CLAUDE_LOG_FILE \
  SKILL=/ticket-reproduce FLAGS="--from-auto" \
  FROM_STEP={REPRODUCE_FROM} \
  DESCRIPTION="reproducing bug for {TICKET-ID}" \
  INSTRUCTIONS="Follow the skill exactly. Report only the final handoff output.")
```

Spawn a `ticket-appraise-agent` with `$_reproduce_prompt` as the instruction.

Wait for the agent. Persist:
```bash
spawn_capture TICKET_ID={TICKET-ID} PHASE=reproduce RESULT="$AGENT_RESULT"
```

Extract:
- `{REPRODUCE_RESULT}` — `REPRODUCED`, `NOT_REPRODUCED`, or `BLOCKED`

If the agent fails → post fail and stop:
```bash
spawn_agent_post TICKET_ID={TICKET-ID} RESULT=fail
```
Stop.

On success, branch on `{REPRODUCE_RESULT}`:

**REPRODUCED** — bug confirmed, proceed to Exec:
```bash
spawn_agent_post TICKET_ID={TICKET-ID} RESULT=done \
  MSG="REPRODUCED" NEXT_PHASE=EXEC
hb_gate "phase-transition" "ok" "REPRODUCE → EXEC"
```
Continue to **Step 2 — Exec**.

**NOT_REPRODUCED** — bug doesn't manifest, gate-stop:
```bash
spawn_agent_post TICKET_ID={TICKET-ID} RESULT=done MSG="NOT_REPRODUCED"
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|META|gate-stop|fail|REPRO_NOT_CONFIRMED" >> {LOG_FILE}
hb_heartbeat "gate-stop" "fail" "REPRO_NOT_CONFIRMED — bug not reproducible on UAT"
```
Stop. The reproduce skill already posted findings to Linear. No code changes were made.

**BLOCKED** — insufficient info, add needs-info label and gate-stop:
```bash
spawn_agent_post TICKET_ID={TICKET-ID} RESULT=done MSG="BLOCKED"
_flow_sh="${HOME}/.claude/skills/ticket-flow/flow.sh"
[ -f "$_flow_sh" ] || _flow_sh=$(find "${HOME}/.claude/plugins/cache" -name "flow.sh" -path "*/ticket-auto-pipeline/*/skills/ticket-flow/flow.sh" 2>/dev/null | sort | tail -1)
bash "$_flow_sh" "{TICKET-ID}" "needs-info" 2>&1
_rc=$?
if [ $_rc -ne 0 ]; then
  _error_type=$( [ $_rc -eq 7 ] && echo "state_assertion" || echo "flow_error" )
  hb_retry "flow-sh" "fail" "flow.sh needs-info failed (exit ${_rc})" \
    "{\"error_type\":\"${_error_type}\",\"exit_code\":${_rc},\"trigger\":\"needs-info\"}"
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|META|flow-error|fail|needs-info trigger failed (exit ${_rc})" >> {LOG_FILE}
fi
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|META|gate-stop|fail|REPRO_BLOCKED" >> {LOG_FILE}
hb_heartbeat "gate-stop" "fail" "REPRO_BLOCKED — insufficient detail to reproduce"
```
Stop. The reproduce skill already posted a Linear comment requesting details. The `needs-info` label has been added.

---

## Step 2 — Exec

### Exec spawn

Run pre-spawn boilerplate. Capture the generated agent prompt:
```bash
source ~/.claude/skills/lib/spawn-helper.sh
_exec_prompt=$(spawn_agent_pre \
  PHASE=EXEC STEP=exec TICKET_ID={TICKET-ID} \
  LOG_FILE={LOG_FILE} HB_LOG_FILE={HB_LOG_FILE} CLAUDE_LOG_FILE=$CLAUDE_LOG_FILE \
  SKILL=/ticket-appraise-exec FLAGS="--from-auto" \
  FROM_STEP={EXEC_FROM} \
  DESCRIPTION="creating artifacts for {TICKET-ID}" \
  INSTRUCTIONS="Follow the skill exactly. Report only the final handoff output.")
```

Spawn a `ticket-appraise-agent` with `$_exec_prompt` as the instruction.

Wait for the agent. Persist:
```bash
spawn_capture TICKET_ID={TICKET-ID} PHASE=exec RESULT="$AGENT_RESULT"
```

Extract:
- `{ARTIFACT_TYPE}` — `simple-fix` or `openspec:<name>`

If the agent fails → post fail and stop:
```bash
spawn_agent_post TICKET_ID={TICKET-ID} RESULT=fail
```
Stop.

On success → post done, then resolve the plan artifact path:
```bash
spawn_agent_post TICKET_ID={TICKET-ID} RESULT=done \
  MSG="{ARTIFACT_TYPE}" NEXT_PHASE=GATE
source ~/.claude/skills/lib/ticket-dir.sh
PLAN_PATH=$(resolve_plan_path "{LOG_FILE}" "{TICKET_DIR}" "{ticket-id-lowercase}")
if [ -n "$PLAN_PATH" ] && [ "$(echo "$PLAN_PATH" | cut -c1)" = "/" ]; then
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|META|artifact|info|plan:$PLAN_PATH" >> {LOG_FILE}
fi
```

---

## Step 2.5 — Artifact-existence gate

**Skip this step when `RESUME_STEP >= STEP_3_5`** — the artifact was already validated in the prior run.

Resolve the plan artifact path:
```bash
source ~/.claude/skills/lib/ticket-dir.sh
PLAN_PATH=$(resolve_plan_path "{LOG_FILE}" "{TICKET_DIR}" "{ticket-id-lowercase}")
```

If `PLAN_PATH` is still empty, or the file does not exist on disk:
```bash
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|META|gate-stop|fail|EXEC_NO_ARTIFACT — expected: ${PLAN_PATH:-unknown}" >> {LOG_FILE}
_artifact_type="{ARTIFACT_TYPE:-unknown}"
hb_gate "artifact-detect" "fail" "artifact file not found" \
  "{\"expected\":\"${PLAN_PATH:-unknown}\",\"artifact_type\":\"${_artifact_type}\",\"ticket_dir\":\"{TICKET_DIR:-unknown}\"}"
```
```bash
hb_decision "pipeline-outcome" "fired" "stopped: artifact not found" '{"reason":"exec-no-artifact","expected":"${PLAN_PATH:-unknown}"}'
```
Stop. Report: `{TICKET-ID} pipeline halted: artifact file not found at '${PLAN_PATH}'. Re-run Step 2 or check ticket-appraise-exec output.`

On success:
```bash
hb_gate "artifact-detect" "ok" "artifact file confirmed" "{\"path\":\"$PLAN_PATH\"}"
hb_gate "phase-transition" "ok" "EXEC → GATE"
```
Proceed to Step 3.

---

## Step 3 — Gate

Read `notes.md` from the ticket directory to confirm complexity:

```bash
find . -type d -name "{TICKET-ID}*"
```

Read `{ticket-dir}/notes.md` and extract the `## Complexity` section.

Write the gate start event:
```bash
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|GATE|gate|start|Evaluating complexity gate" >> {LOG_FILE}
hb_gate "preflight" "fired" "gate evaluation started" '{"complexity":"{COMPLEXITY}","autonomy":"{AUTONOMY}"}'
```

- **`complex`** → held regardless of flag. Write log events, then stop:
  ```bash
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|META|gate-result|info|complex — held ({AUTONOMY})" >> {LOG_FILE}
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|GATE|gate|fail|held: complex ticket" >> {LOG_FILE}
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|META|outcome|info|stopped: complex" >> {LOG_FILE}
  hb_decision "gate-result" "fired" "held: complex ticket" '{"reason":"complex"}'
  ```
  Report:

```
## {TICKET-ID} — gate held

**Reason:** Complex ticket — multi-service or cross-layer changes.
**Artifacts:** {ticket-dir} (notes.md + {ARTIFACT_TYPE})
**To proceed:** Review the plan, then add the `approved` label and re-run `/ticket-auto {TICKET-ID} --auto`.
```

  Mark remaining tasks as deleted (they won't run this session).
  ```bash
  hb_decision "pipeline-outcome" "fired" "stopped: complex ticket held" '{"reason":"complex"}'
  ```
  Stop here.

- **`simple` + `{AUTONOMY}` = `manual`** → held. Write log events, then stop:
  ```bash
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|META|gate-result|info|simple — held (manual mode)" >> {LOG_FILE}
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|GATE|gate|fail|held: manual mode" >> {LOG_FILE}
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|META|outcome|info|stopped: manual" >> {LOG_FILE}
  hb_decision "gate-result" "fired" "held: manual mode" '{"reason":"manual-mode"}'
  ```
  Report:

```
## {TICKET-ID} — gate held

**Reason:** Manual mode — human approval required for all tickets.
**Artifacts:** {ticket-dir} (notes.md + {ARTIFACT_TYPE})
**To proceed:** Run `/ticket-flow {TICKET-ID} human-approve`, then re-run `/ticket-auto {TICKET-ID} --auto`.
```

  Mark remaining tasks as deleted.
  ```bash
  hb_decision "pipeline-outcome" "fired" "stopped: manual mode" '{"reason":"manual-mode"}'
  ```
  Stop here.

- **`simple` + `{AUTONOMY}` = `auto` or `semi-auto`** → auto-approve. Run `/ticket-flow {TICKET-ID} human-approve`. Write log events:
  ```bash
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|META|gate-result|info|simple — auto-approved ({AUTONOMY})" >> {LOG_FILE}
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|GATE|gate|done|auto-approved" >> {LOG_FILE}
  hb_decision "gate-result" "fired" "auto-approved: simple" '{"reason":"simple","autonomy":"{AUTONOMY}"}'
  hb_gate "phase-transition" "ok" "GATE → IMPLEMENT"
  ```
  Proceed to Step 4.

---

## Step 3.5 — Comment Reconciliation

**Only entered when `{RESUME_STEP}` = `STEP_3_5`** (gate was held, `approved` label is now present). This step acts as a post-gate quality gate: it re-fetches Linear comments, checks for unanswered open questions, incorporates new user guidance into the plan, and loops with re-approval until clean.

Initialize the cycle counter:
```bash
RECONCILE_N=$(({RECONCILE_CYCLE} + 1))
```

### Step 3.5a — Fetch all comments

Fetch comments using the Linear access strategy, then normalize via `normalize_comments` from `linear-api.sh`:

```bash
if [ -n "${LINEAR_API_KEY:-}" ]; then
  COMMENTS_JSON=$(bash -c "source ~/.claude/skills/lib/linear-api.sh; get_comments '{TICKET-ID}'")
else
  COMMENTS_JSON=$(mcp__linear-server__list_comments id="{TICKET-ID}")
fi

# Normalize to a flat array of {createdAt, body, user: {name}} objects
# normalize_comments handles all known response wrappers (array, .data.issue.comments.nodes, .data.issue.comments, .data.comments, .comments)
COMMENTS_JSON=$(echo "$COMMENTS_JSON" | bash -c "source ~/.claude/skills/lib/linear-api.sh; normalize_comments")
```

### Step 3.5b — Identify boundary comments

Run `reconcile-comments.sh` to find appraisal/amendment boundaries and extract unprocessed user comments:

```bash
RECONCILE_OUTPUT=$(echo "$COMMENTS_JSON" | bash ~/.claude/skills/lib/reconcile-comments.sh "{TICKET-ID}" "{LOG_FILE}")
echo "$RECONCILE_OUTPUT"
```

Parse the output to set `{LAST_RECONCILE_AT}`, `{APPRAISAL_COMMENT_AT}`, and `{UNPROCESSED_COMMENTS}`.

**How it works:** The script identifies the appraisal comment by `**Ticket appraised**` prefix and amendment comments by `**Amendment cycle #` prefix. `LAST_RECONCILE_AT` is the later of the two — everything after it is from the current hold window. Pipeline-authored comments are excluded, so `UNPROCESSED_COMMENTS` contains only user-authored comments in `timestamp|user|body` format.

### Step 3.5c — Read open questions

Read the `## Open Questions` section from notes.md:

```bash
NOTES_PATH="{TICKET_DIR}/notes.md"
# sed range prints from Open Questions to next ## heading, or to EOF if last section.
# grep '^\-' limits to bullet lines, but a trailing bullet list after Open Questions
# could leak in. Guard: if sed output contains another ## heading, truncate at it.
RAW_SECTION=$(sed -n '/^## Open Questions/,/^## /p' "$NOTES_PATH")
if echo "$RAW_SECTION" | grep -q '^## '; then
  RAW_SECTION=$(echo "$RAW_SECTION" | sed '/^## Open Questions$/!{/^## /q}')
fi
OPEN_QUESTIONS_LIST=$(echo "$RAW_SECTION" | grep '^\-' || true)
```

If `{OPEN_QUESTIONS_LIST}` is empty or contains only placeholder text ("None", "—"), skip the unanswered-questions check in Step 3.5d.

### Step 3.5d — Evaluate hold conditions

Two independent conditions. If either triggers, the pipeline holds (proceed to Step 3.5e).

**Condition 1 — Unanswered open questions:**

For each bullet in `{OPEN_QUESTIONS_LIST}`, scan `{UNPROCESSED_COMMENTS}` and all post-appraisal comments for a concrete answer. Use semantic judgment:
- A concrete answer resolves, decides, or explicitly dismisses the question
- Vague replies ("we'll see", "TBD", "maybe", "I'll think about it") do NOT count as answers
- If ANY question lacks a concrete answer → set `HOLD_REASON=unanswered_questions`

**Condition 2 — Unprocessed user comments:**

If `{UNPROCESSED_COMMENTS}` is non-empty → set `HOLD_REASON=unprocessed_comments` (combine with condition 1 if both apply: `HOLD_REASON=unanswered_questions+unprocessed_comments`).

**If neither condition triggers** → skip to Step 3.5g (clean pass).

### Step 3.5e — Amendment logic

When a hold condition is active, incorporate user feedback into the plan artifact before re-claiming.

Resolve the plan path:
```bash
source ~/.claude/skills/lib/ticket-dir.sh
PLAN_PATH=$(resolve_plan_path "{LOG_FILE}" "{TICKET_DIR}" "{ticket-id-lowercase}")
```

Read the current plan artifact (simple-fix.md or openspec tasks.md). Append an `## Amendment #N` section (where N = `{RECONCILE_N}`) that:
1. Summarizes the user comments being incorporated
2. Lists concrete changes to the plan required by the feedback
3. Notes any design decisions made during reconciliation

Update `## Open Questions` in notes.md:
- Mark resolved questions with `~~strikethrough~~` (do NOT delete them — preserve history)
- If new unresolvable questions arise from amendment, append them as new bullets

### Step 3.5f — Post amendment, re-claim, hold

Post an amendment comment to Linear summarizing what changed and what's still open:

```bash
AMENDMENT_BODY="**Amendment cycle #${RECONCILE_N}**

## Changes incorporated
{summary of incorporated user comments and plan changes}

## Open questions remaining
{list of still-unanswered questions, or 'None — all questions resolved'}

## New questions raised by this cycle
{list of new questions, or 'None'}"
```

Use the Linear access strategy to post the comment (bash `save_comment` when `LINEAR_API_KEY` is set, MCP fallback otherwise).

Call `re-claim` to remove the `approved` label without changing the ticket's Linear state:

```bash
_flow_sh="${HOME}/.claude/skills/ticket-flow/flow.sh"
[ -f "$_flow_sh" ] || _flow_sh=$(find "${HOME}/.claude/plugins/cache" -name "flow.sh" -path "*/ticket-auto-pipeline/*/skills/ticket-flow/flow.sh" 2>/dev/null | sort | tail -1)
bash "$_flow_sh" "{TICKET-ID}" "re-claim"
```

Write the held log entry:

```bash
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|GATE|reconcile|done|cycle#${RECONCILE_N}|held: ${HOLD_REASON}" >> {LOG_FILE}
hb_decision "reconcile-result" "fired" "held: ${HOLD_REASON}" "{\"cycle\":\"${RECONCILE_N}\",\"reason\":\"${HOLD_REASON}\"}"
```

Stop with a user-facing report:

```
## {TICKET-ID} — amendment cycle #{RECONCILE_N}

**Hold reason:** {HOLD_REASON}

### Incorporated
{summary of what was incorporated into the plan}

### Open questions
{list of still-unanswered questions}

### Next step
Review the amendment comment in Linear, then add the `approved` label and re-run `/ticket-auto {TICKET-ID} --auto`.
```

Mark remaining tasks as deleted (they won't run this session).

```bash
hb_decision "pipeline-outcome" "fired" "stopped: amendment cycle #${RECONCILE_N}" "{\"reason\":\"${HOLD_REASON}\",\"cycle\":\"${RECONCILE_N}\"}"
```

Stop here.

### Step 3.5g — Clean pass

No hold conditions active. All open questions are answered and no unprocessed user comments exist. Write the clean log entry and continue:

```bash
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|GATE|reconcile|done|clean" >> {LOG_FILE}
hb_decision "reconcile-result" "fired" "clean pass — no unprocessed comments or unanswered questions" "{\"cycle\":\"${RECONCILE_N}\"}"
hb_gate "reconcile" "ok" "clean pass — proceeding to implement"
hb_gate "phase-transition" "ok" "GATE → IMPLEMENT"
```

Proceed to Step 4.

---
## Step 4 — Implement

Fetch the ticket via the Linear access strategy (bash `get_issue` when `LINEAR_API_KEY` is set, MCP fallback otherwise) and verify the `approved` label is present. If missing (shouldn't happen given Step 3 or Step 3.5, but verify) — add it now for simple tickets, or stop for complex.

### Implement spawn

Run pre-spawn boilerplate. Capture the generated agent prompt:
```bash
source ~/.claude/skills/lib/spawn-helper.sh
_implement_prompt=$(spawn_agent_pre \
  PHASE=IMPLEMENT STEP=implement TICKET_ID={TICKET-ID} \
  LOG_FILE={LOG_FILE} HB_LOG_FILE={HB_LOG_FILE} CLAUDE_LOG_FILE=$CLAUDE_LOG_FILE \
  SKILL=/ticket-implement FLAGS="--from-auto" \
  FROM_STEP={IMPLEMENT_FROM} \
  DESCRIPTION="implementing {TICKET-ID}" \
  INSTRUCTIONS="Follow the skill exactly. Use Serena for all code navigation — mandatory. Commit and push. Report the final output including branch name.")
```

Spawn a `ticket-implement-agent` with `$_implement_prompt` as the instruction.
After this agent returns, clear `{IMPLEMENT_FROM}` (set to empty) — loop re-invocations in Step 5d always start fresh.

Wait for the agent. Persist:
```bash
spawn_capture TICKET_ID={TICKET-ID} PHASE=implement RESULT="$AGENT_RESULT"
```

Extract:
- `{OUTCOME}` — `Smooth`, `Rough`, or `Hard`
- `{MISMATCH}` — whether a complexity mismatch was reported (look for "Complexity mismatch" in the output)

If the agent fails → post fail and stop:
```bash
spawn_agent_post TICKET_ID={TICKET-ID} RESULT=fail
```
Stop.

On success → post done:
```bash
spawn_agent_post TICKET_ID={TICKET-ID} RESULT=done \
  MSG="{OUTCOME}, branch: {branch}" NEXT_PHASE=VERIFY
```

### Step 4a — Verify outcome label

Fetch the ticket via the Linear access strategy. Check that:

**Outcome label is present:** The `Smooth`, `Rough`, or `Hard` label must be set. If missing, run `/ticket-flow {TICKET-ID} implement-outcome --data outcome={OUTCOME}`.

This is critical for training data (predicted-vs-actual complexity pairs). State change to `Review` happens in Step 4.5 — verification gates PR creation and `implement-complete`.

---

## Step 4.5 — Verify on localhost

Only if the ticket has a UI surface. Otherwise:
```bash
hb_decision "verification-verdict" "skip" "no UI surface — verification skipped"
hb_heartbeat "phase-transition" "IMPLEMENT → PR-REVIEW (verify skipped)"
```
Proceed to Step 4.6 (PR Review).

### Step 4.5a — Verification attempt

Run pre-spawn boilerplate. Capture the generated agent prompt:
```bash
source ~/.claude/skills/lib/spawn-helper.sh
_verify_prompt=$(spawn_agent_pre \
  PHASE=VERIFY STEP=verify TICKET_ID={TICKET-ID} \
  LOG_FILE={LOG_FILE} HB_LOG_FILE={HB_LOG_FILE} CLAUDE_LOG_FILE=$CLAUDE_LOG_FILE \
  SKILL=/ticket-verify FLAGS="--from-auto --env local" \
  FROM_STEP={VERIFY_FROM} \
  DESCRIPTION="verifying {TICKET-ID} (attempt $(({VERIFY_ATTEMPTS}+1))/3)" \
  INSTRUCTIONS="Follow the skill exactly. Run Playwright UAT against localhost. Report only the final handoff output.")
```

Spawn a `ticket-verify-agent` with `$_verify_prompt` as the instruction.
After this agent returns, clear `{VERIFY_FROM}` (set to empty) — retry re-invocations always start fresh.

Wait for the agent. Persist (attempt number tracks retries):
```bash
spawn_capture TICKET_ID={TICKET-ID} PHASE=verify RESULT="$AGENT_RESULT" ATTEMPT="$(({VERIFY_ATTEMPTS}+1))"
```

Extract `{VERDICT}` (PASS or FAIL).

**PASS:**
```bash
spawn_agent_post TICKET_ID={TICKET-ID} RESULT=done \
  MSG="PASS on attempt {VERIFY_ATTEMPTS}" NEXT_PHASE=PR-REVIEW
```

**FAIL:**
```bash
spawn_agent_post TICKET_ID={TICKET-ID} RESULT=fail \
  MSG="FAIL — criteria not met (attempt {VERIFY_ATTEMPTS}/3)"
```

- **PASS** → proceed to Step 4.6 (PR Review).
- **FAIL** → proceed to Step 4.5b.

### Step 4.5b — Retry decision

Increment `{VERIFY_ATTEMPTS}`.

If `{VERIFY_ATTEMPTS} >= 3`:
  ```bash
  hb_gate "verify-exhausted" "fail" "max verify attempts (3) reached" "{\"attempts\":\"{VERIFY_ATTEMPTS}\"}"
  hb_decision "pipeline-outcome" "fired" "stopped: verify exhausted" '{"reason":"verify-exhausted","attempts":"{VERIFY_ATTEMPTS}"}'
  ```
  Stop. Report:
  ```
  ## {TICKET-ID} — max verify attempts reached

  **Failed criteria:** {list}
  See {ticket-dir}/notes.md for the REMEDIATION_BRIEF.
  Manual intervention needed.
  ```

If `{VERIFY_ATTEMPTS} < 3`:
  ```bash
  hb_decision "loop-back" "fired" "verify fail → re-implement" "{\"attempt\":\"{VERIFY_ATTEMPTS}\",\"max\":\"3\"}"
  ```
  Report "Verification attempt {VERIFY_ATTEMPTS}/3 failed. Re-implementing."
  **Loop back to Step 4** (re-spawn the implement agent with `--from-auto`).
  ticket-implement Step 2.5 detects the Verification FAIL in notes.md,
  appends `## Verification #N` to the plan, and implements the fix.
  After Step 4 completes, proceed through 4a to 4.5a again.
  Step 4.6 (PR Review) runs after VERIFY passes.
  Do NOT re-initialize `{VERIFY_ATTEMPTS}`.

Pass `--from-auto` to the ticket-implement agent spawn in Step 4 — add `--from-auto` to the agent prompt.

---

## Step 4.6 — PR Review + Iteration Loop

Initialize `{ITERATION}` = 0. The loop runs at most 3 times.

### Step 5a — Run PR review

### PR Review spawn

Run pre-spawn boilerplate. Capture the generated agent prompt:
```bash
source ~/.claude/skills/lib/spawn-helper.sh
_pr_review_prompt=$(spawn_agent_pre \
  PHASE=PR-REVIEW STEP=pr-review TICKET_ID={TICKET-ID} \
  LOG_FILE={LOG_FILE} HB_LOG_FILE={HB_LOG_FILE} CLAUDE_LOG_FILE=$CLAUDE_LOG_FILE \
  SKILL=/ticket-pr-review FLAGS="--from-auto" \
  FROM_STEP={PR_REVIEW_FROM} \
  DESCRIPTION="reviewing PR for {TICKET-ID} (iteration {ITERATION})" \
  INSTRUCTIONS="Follow the skill exactly. Validate the PR diff against the ticket requirements. Post findings. If all requirements addressed (verdict ✅), merge via squash. Report the final output.")
```

Spawn a `ticket-pr-review-agent` with `$_pr_review_prompt` as the instruction.
After this agent returns, clear `{PR_REVIEW_FROM}` — subsequent iterations start fresh.

Wait for the agent. Persist:
```bash
spawn_capture TICKET_ID={TICKET-ID} PHASE=pr-review RESULT="$AGENT_RESULT"
```

Extract:
- `{VERDICT}` — ✅ all addressed, or ⚠️ gaps found
- `{MERGED}` — yes, no, or skipped

If the agent fails → post fail and stop:
```bash
spawn_agent_post TICKET_ID={TICKET-ID} RESULT=fail \
  MSG="Agent failed (iteration {ITERATION})"
```
Stop.

On success:
```bash
spawn_agent_post TICKET_ID={TICKET-ID} RESULT=done \
  MSG="Verdict: {VERDICT}, merged: {MERGED}" NEXT_PHASE=MAINTENANCE
```

**Verdict-line integrity gate** — before any branching, count parseable verdict lines in the pr-review output:
```bash
VERDICT_COUNT=$(echo "{PR_REVIEW_OUTPUT}" | grep -cP '^\*\*Verdict:\*\* [✅⚠️]' || true)
```

If `VERDICT_COUNT` ≠ 1:
```bash
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|META|gate-stop|fail|PR_REVIEW_VERDICT_UNPARSEABLE — found ${VERDICT_COUNT} Verdict lines" >> {LOG_FILE}
_output_len=$(echo "{PR_REVIEW_OUTPUT}" | wc -c | tr -d ' ')
hb_gate "verdict-parse" "fail" "unparseable verdict in PR review output" \
  "{\"count\":\"${VERDICT_COUNT}\",\"expected\":\"1\",\"output_chars\":\"${_output_len}\"}"
```
```bash
hb_decision "pipeline-outcome" "fired" "stopped: verdict unparseable" '{"reason":"verdict-unparseable","count":"${VERDICT_COUNT}"}'
```
Stop. Report: `{TICKET-ID} pipeline halted: expected 1 **Verdict:** ✅/⚠️ line, found ${VERDICT_COUNT}. PR review output may be malformed.`

On `VERDICT_COUNT` = 1:
```bash
hb_gate "verdict-parse" "ok" "verdict line parseable" "{\"verdict\":\"{VERDICT}\"}"
```
Extract `{VERDICT}` from that line and proceed.

### Step 5b — Decision

- **Verdict ✅** → check auto-merge conditions:
  - If `{AUTONOMY}` = `semi-auto` AND `{COMPLEXITY}` = `simple` AND `{OUTCOME}` = `Smooth`:
    ```bash
    # Capture stderr for diagnostics on merge failure.
    # gh pr merge exit codes: 0=merged, 1=generic fail (transient), 2=conflict,
    # 3=already merged (idempotent), 4=branch protection (transient).
    _merge_stderr=$(mktemp)
    if gh pr merge --squash --auto {PR_URL} 2>"$_merge_stderr"; then
      _merge_rc=0
    else
      _merge_rc=$?
    fi
    _merge_stderr_head=$(head -5 "$_merge_stderr" 2>/dev/null || echo "(empty)")
    rm -f "$_merge_stderr"

    if [ "$_merge_rc" -eq 0 ] || [ "$_merge_rc" -eq 3 ]; then
      # 0 = merged, 3 = already merged (idempotent success)
      echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|PR-REVIEW|pr-review|done|Verdict: ✅, merged: auto-merged (semi-auto, simple+Smooth)" >> {LOG_FILE}
      hb_decision "merge-decision" "fired" "auto-merged" '{"reason":"semi-auto+simple+Smooth","verdict":"✅","rc":'"$_merge_rc"'}'
    elif [ "$_merge_rc" -eq 2 ]; then
      # Merge conflict — permanent, needs human intervention
      echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|PR-REVIEW|merge-decision|fail|merge conflict (exit $_merge_rc): ${_merge_stderr_head}" >> {LOG_FILE}
      hb_decision "merge-decision" "fail" "merge conflict" "{\"rc\":$_merge_rc}"
      # Do NOT set MERGED — flow to human-intervention path
    else
      # Exit 1 (generic) or 4 (branch protection) — transient, retry-able
      echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|PR-REVIEW|merge-decision|fail|merge failed (exit $_merge_rc): ${_merge_stderr_head}" >> {LOG_FILE}
      hb_retry "merge" "fail" "gh pr merge exit $_merge_rc" "{\"rc\":$_merge_rc,\"stderr\":\"${_merge_stderr_head}\"}"
      # Set {MERGED} = retry — caller should retry with backoff
    fi
    ```
    Set `{MERGED}` = `auto-merged`.
    ```bash
    hb_heartbeat "phase-transition" "PR-REVIEW → MAINTENANCE"
    ```
    Break out of loop. Go to Step 6 (Report).
  - Otherwise (wrong flag, complex ticket, or outcome ≠ Smooth) → normal merge flow. The PR review agent already handles merge.
    ```bash
    hb_decision "merge-decision" "fired" "merged via PR review agent" '{"verdict":"✅","autonomy":"{AUTONOMY}","complexity":"{COMPLEXITY}"}'
    hb_heartbeat "phase-transition" "PR-REVIEW → MAINTENANCE"
    ```
    Set `{MERGED}` = `yes`. Break out of loop. Go to Step 6 (Report).
- **Verdict ⚠️** → auto-merge blocked regardless of flag. Increment `{ITERATION}`. If `{ITERATION} + {PR_FEEDBACK_CYCLE} >= 3` → stop and report:
  ```
  ## {TICKET-ID} — max re-implement rounds reached

  PR review found gaps after {ITERATION} bot iterations + {PR_FEEDBACK_CYCLE} human feedback cycles (combined cap of 3). Manual intervention needed.
  PR: {PR_URL}
  ```
  ```bash
  hb_gate "iteration-exhausted" "fail" "max iterations (3) reached — manual intervention needed" "{\"iterations\":\"{ITERATION}\"}"
  hb_decision "pipeline-outcome" "fired" "stopped: max iterations reached" '{"reason":"iteration-exhausted","iterations":"{ITERATION}"}'
  ```
  Otherwise proceed to Step 5c.

### Step 5c — Iterate

```bash
hb_decision "loop-back" "fired" "pr-review gaps → pr-iterate" "{\"iteration\":\"{ITERATION}\"}"
```

### PR Iterate spawn

Run pre-spawn boilerplate. Capture the generated agent prompt:
```bash
source ~/.claude/skills/lib/spawn-helper.sh
_pr_iterate_prompt=$(spawn_agent_pre \
  PHASE=PR-REVIEW STEP=plan-iterate-start TICKET_ID={TICKET-ID} \
  LOG_FILE={LOG_FILE} HB_LOG_FILE={HB_LOG_FILE} CLAUDE_LOG_FILE=$CLAUDE_LOG_FILE \
  SKILL=/ticket-pr-iterate FLAGS="--from-auto" \
  FROM_STEP={PR_ITERATE_FROM} \
  DESCRIPTION="iterating on PR feedback for {TICKET-ID} (iteration {ITERATION})" \
  INSTRUCTIONS="Follow the skill exactly. Parse the PR review findings, append a PR Review #{ITERATION} section to the plan, update Linear to Ready + approved. Report the final output.")
```

Spawn a `ticket-pr-review-agent` with `$_pr_iterate_prompt` as the instruction.
After this agent returns, clear `{PR_ITERATE_FROM}`.

Wait for the agent. Persist:
```bash
spawn_capture TICKET_ID={TICKET-ID} PHASE=pr-iterate RESULT="$AGENT_RESULT"
```

If the agent fails → post fail and stop:
```bash
spawn_agent_post TICKET_ID={TICKET-ID} RESULT=fail \
  MSG="Agent failed (iteration {ITERATION})"
```
Stop.

On success:
```bash
spawn_agent_post TICKET_ID={TICKET-ID} RESULT=done \
  MSG="Plan updated with PR Review #{ITERATION}" NEXT_PHASE=RE-IMPLEMENT
```

### Step 5d — Re-implement

```bash
hb_decision "loop-back" "fired" "pr-iterate → re-implement" "{\"iteration\":\"{ITERATION}\"}"
```

**Re-approval gate** — live Linear check before re-spawning implement:

```bash
LIVE=$(if [ -n "${LINEAR_API_KEY:-}" ]; then
  bash -c "source ~/.claude/skills/lib/linear-api.sh; get_issue '{TICKET-ID}'"
else
  mcp__linear-server__get_issue id="{TICKET-ID}"
fi)
LIVE_STATE=$(echo "$LIVE" | jq -r '.state.name')
LIVE_LABELS=$(echo "$LIVE" | jq -r '[.labels.nodes[].name]')
```

Assert both conditions:
- `LIVE_STATE` = `Ready`
- `approved` label present in `LIVE_LABELS`

If either fails:
```bash
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|META|gate-stop|fail|APPROVAL_REVOKED — state={LIVE_STATE} approved={true|false}" >> {LOG_FILE}
_approved_present=$(echo "$LIVE_LABELS" | jq -r 'any(. == "approved")' 2>/dev/null || echo "unknown")
hb_gate "approval-revoked" "fail" "approval revoked before re-implement" \
  "{\"state\":\"${LIVE_STATE}\",\"approved_present\":\"${_approved_present}\",\"expected_state\":\"Ready\",\"expected_approved\":\"true\"}"
```
```bash
hb_decision "pipeline-outcome" "fired" "stopped: approval revoked" '{"reason":"approval-revoked","state":"{LIVE_STATE}"}'
```
Stop. Report: `{TICKET-ID} pipeline halted: approval revoked between pr-iterate and re-implement. State: {LIVE_STATE}. Labels: {LIVE_LABELS}. Re-approve the ticket to continue.`

On pass:
```bash
hb_gate "preflight" "ok" "re-approval confirmed — state={LIVE_STATE}" "{\"state\":\"{LIVE_STATE}\"}"
```

### Re-implement spawn

Run pre-spawn boilerplate. Capture the generated agent prompt:
```bash
source ~/.claude/skills/lib/spawn-helper.sh
_reimplement_prompt=$(spawn_agent_pre \
  PHASE=IMPLEMENT STEP=re-implement TICKET_ID={TICKET-ID} \
  LOG_FILE={LOG_FILE} HB_LOG_FILE={HB_LOG_FILE} CLAUDE_LOG_FILE=$CLAUDE_LOG_FILE \
  SKILL=/ticket-implement FLAGS="--from-auto" \
  DESCRIPTION="re-implementing {TICKET-ID} (iteration {ITERATION})" \
  INSTRUCTIONS="Follow the skill exactly. Read the updated plan (including the PR Review #{ITERATION} section), implement the changes, write tests, commit, and push. Report the final output including branch name.")
```

Spawn a `ticket-implement-agent` with `$_reimplement_prompt` as the instruction.

Wait for the agent. Persist:
```bash
spawn_capture TICKET_ID={TICKET-ID} PHASE=re-implement RESULT="$AGENT_RESULT" ATTEMPT="{ITERATION}"
```

Extract:
- `{OUTCOME}` — `Smooth`, `Rough`, or `Hard`

If the agent fails → post fail and stop:
```bash
spawn_agent_post TICKET_ID={TICKET-ID} RESULT=fail \
  MSG="Agent failed (iteration {ITERATION})"
```
Stop.

On success:
```bash
spawn_agent_post TICKET_ID={TICKET-ID} RESULT=done \
  MSG="{OUTCOME}, iteration {ITERATION}" NEXT_PHASE=RE-VERIFY
```

### Step 5d2 — Re-verify

Reset `{VERIFY_RETRIES}` = 0 (fresh counter for this PR iteration).

#### Step 5d2-verify

Run `/ticket-verify {TICKET-ID} --env local --from-auto`.
After the agent returns, persist the raw output:
```bash
capture_agent_result "{TICKET-ID}" "re-verify" "$AGENT_RESULT" "$(({VERIFY_RETRIES}+1))" "{ITERATION}"
```
Extract `{VERDICT}` (PASS or FAIL).

Write log result event:
```bash
# PASS:
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|VERIFY|re-verify|done|PASS (iteration {ITERATION})" >> {LOG_FILE}
hb_heartbeat "agent-returned" "re-verify agent done — PASS (iteration {ITERATION})"
hb_heartbeat "phase-transition" "RE-VERIFY → MAINTENANCE"
# FAIL:
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|VERIFY|re-verify|fail|FAIL — criteria not met (iteration {ITERATION})" >> {LOG_FILE}
hb_heartbeat "agent-returned" "re-verify agent done — FAIL (iteration {ITERATION}, retry {VERIFY_RETRIES})"
```

- **PASS** → run Step 5 (Document + Wiki) to regenerate ai-context.md and incorporate any new errata from re-implementation, then proceed to Step 5e.
- **FAIL** → proceed to retry logic below.

#### Step 5d2-retry

Increment `{VERIFY_RETRIES}`.

If `{VERIFY_RETRIES} >= 3`:
  ```bash
  hb_gate "reverify-exhausted" "fail" "max re-verify retries (3) reached" "{\"retries\":\"{VERIFY_RETRIES}\",\"iteration\":\"{ITERATION}\"}"
  hb_decision "pipeline-outcome" "fired" "stopped: reverify exhausted" '{"reason":"reverify-exhausted","retries":"{VERIFY_RETRIES}","iteration":"{ITERATION}"}'
  ```
  Stop. Report:
  ```
  ## {TICKET-ID} — max re-verify retries reached

  PR iteration {ITERATION}: verification still failing after 3 re-attempts.
  Manual intervention needed.
  ```
  Do NOT increment `{ITERATION}`.

If `{VERIFY_RETRIES} < 3`:
  ```bash
  hb_decision "loop-back" "fired" "re-verify fail → re-implement" "{\"retry\":\"{VERIFY_RETRIES}\",\"max\":\"3\",\"iteration\":\"{ITERATION}\"}"
  ```
  Report "Re-verify retry {VERIFY_RETRIES}/3 (PR iteration {ITERATION})."
  **Loop back to Step 5d** (re-spawn ticket-implement with `--from-auto`).
  ticket-implement Step 2.5 detects the new Verification FAIL.
  After re-implementation, go to Step 5d2-verify again.

### Step 5e — Loop back

```bash
hb_decision "loop-back" "fired" "re-implement+verify done → re-review" "{\"iteration\":\"{ITERATION}\"}"
```
Go back to Step 5a (re-run PR review on the updated PR).

---

## Step 5 — Document + Wiki Maintenance

Generate `ai-context.md` in the ticket directory, then incorporate any unresolved errata into the project wiki. Both run in a single agent spawn — the agent executes both sub-tasks sequentially, writing separate pipeline log entries for each.

### Combined maintenance spawn

Run pre-spawn boilerplate. Capture the generated agent prompt:
```bash
source ~/.claude/skills/lib/spawn-helper.sh
_maintenance_prompt=$(spawn_agent_pre \
  PHASE=MAINTENANCE STEP=maintenance TICKET_ID={TICKET-ID} \
  LOG_FILE={LOG_FILE} HB_LOG_FILE={HB_LOG_FILE} CLAUDE_LOG_FILE=$CLAUDE_LOG_FILE \
  SKILL=none FLAGS="--from-auto" \
  DESCRIPTION="document + wiki maintenance for {TICKET-ID}" \
  INSTRUCTIONS="You are performing post-implement maintenance for {TICKET-ID}. Execute both sub-tasks in order, writing separate pipeline log entries for each.

SUB-TASK 1 — Generate ai-context.md:
1. Source the project env: source /tmp/ticket-auto-{TICKET-ID}-env.sh 2>/dev/null || true
2. Read notes.md from {TICKET_DIR}. Extract complexity and key findings.
3. Diff the branch against develop: git diff develop...{BRANCH}
4. Get commit log: git log develop..{BRANCH} --oneline
5. Classify significance (trivial vs non-trivial) based on the diff content.
6. Write ai-context.md to {TICKET_DIR} following the ticket-document skill format.
7. Append to notes.md session log: '- ai-context.md written ({N} patterns, {N} decisions)'
8. Write pipeline log: \$(date -u +%Y-%m-%dT%H:%M:%SZ)|MAINTENANCE|document|done|{DOCUMENT_FILE} ({PATTERNS} patterns, {DECISIONS} decisions, {SIGNIFICANCE}) >> {LOG_FILE}
9. If document generation fails: \$(date -u +%Y-%m-%dT%H:%M:%SZ)|MAINTENANCE|document|fail|Agent failed — continuing >> {LOG_FILE}

SUB-TASK 2 — Wiki Maintenance:
1. Use \$WIKI_ROOT from the environment (sourced above). If unset, skip wiki maintenance.
2. Scan wiki files under \$WIKI_ROOT for unresolved errata entries (## Errata sections, non-strikethrough).
3. Also scan recent ai-context.md files (find . -path '*/tickets/*/ai-context.md' -newermt '90 days ago').
4. For each unresolved errata entry: apply the fix to the wiki flow file, mark resolved with strikethrough + date.
5. For ai-context findings meeting inclusion criteria: promote to wiki entries.
6. Write pipeline log: \$(date -u +%Y-%m-%dT%H:%M:%SZ)|MAINTENANCE|wiki-errata|done|{ERRATA_COUNT} errata incorporated, {AI_CONTEXT_FINDINGS} ai-context findings promoted >> {LOG_FILE}
7. If wiki maintenance fails: \$(date -u +%Y-%m-%dT%H:%M:%SZ)|MAINTENANCE|wiki-errata|fail|Agent failed — continuing >> {LOG_FILE}

At the end, emit a MAINTENANCE_RESULT block:
=== MAINTENANCE_RESULT ===
document_file={path to ai-context.md or 'none'}
patterns={N}
decisions={N}
significance={trivial|non-trivial}
errata_count={N}
ai_context_findings={N}
=== END MAINTENANCE_RESULT ===")
```

Spawn a `ticket-maintenance-agent` with `$_maintenance_prompt` as the instruction.

Wait for the agent. Persist:
```bash
spawn_capture TICKET_ID={TICKET-ID} PHASE=maintenance RESULT="$AGENT_RESULT"
```

Extract from the MAINTENANCE_RESULT block:
- `{DOCUMENT_FILE}` — path to ai-context.md, or `none` if failed
- `{PATTERNS}` — number of patterns documented (0 if trivial or failed)
- `{DECISIONS}` — number of decisions documented (0 if trivial or failed)
- `{SIGNIFICANCE}` — `trivial` or `non-trivial`
- `{ERRATA_COUNT}` — number of errata entries processed (0 if none)
- `{AI_CONTEXT_FINDINGS}` — number of ai-context findings promoted to wiki (0 if none)

If the agent fails → log a warning but continue (maintenance is non-blocking):
```bash
FAIL_ACTION=warn-continue spawn_agent_post TICKET_ID={TICKET-ID} RESULT=fail \
  MSG="Agent failed — continuing"
```

On success:
```bash
spawn_agent_post TICKET_ID={TICKET-ID} RESULT=done \
  MSG="doc={DOCUMENT_FILE} ({SIGNIFICANCE}) errata={ERRATA_COUNT} wiki_findings={AI_CONTEXT_FINDINGS}" \
  NEXT_PHASE=REPORT
```

Non-blocking: maintenance agent failure does not stop the pipeline. Both ai-context.md and wiki errata are nice-to-haves — the pipeline proceeds to report regardless.

---

## Step 5.5 — PR Comment Reconciliation

**Only entered when `{RESUME_STEP}` = `STEP_5_5`** (PR review posted, PR is open, human comments detected). This step fetches human-authored PR comments, classifies change requests, amends the plan for in-scope changes, and pushes back on out-of-scope or ambiguous requests.

### Step 5.5 header and cycle initialization

```bash
PR_FEEDBACK_N=$(({PR_FEEDBACK_CYCLE} + 1))
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|PR-REVIEW|pr-reconcile|start|cycle#${PR_FEEDBACK_N} — scanning human PR comments" >> {LOG_FILE}
hb_heartbeat "pr-reconcile-start" "cycle#${PR_FEEDBACK_N} — PR comment reconciliation started"
```

**Combined loop cap check:**

```bash
COMBINED_ROUNDS=$(({ITERATION} + {PR_FEEDBACK_CYCLE}))
if [ "$COMBINED_ROUNDS" -ge 3 ]; then
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|META|gate-stop|fail|COMBINED_CAP_HIT — ITERATION={ITERATION} + PR_FEEDBACK_CYCLE={PR_FEEDBACK_CYCLE} >= 3" >> {LOG_FILE}
  hb_gate "combined-cap" "fail" "max re-implement rounds (3) reached" "{\"iterations\":\"{ITERATION}\",\"pr_feedback_cycles\":\"{PR_FEEDBACK_CYCLE}\",\"combined\":\"${COMBINED_ROUNDS}\"}"
  hb_decision "pipeline-outcome" "fired" "stopped: combined cap hit" '{"reason":"combined-cap","iterations":"{ITERATION}","pr_feedback_cycles":"{PR_FEEDBACK_CYCLE}"}'
  # Report and stop
fi
```

If the combined cap is hit, stop with:
```
## {TICKET-ID} — max re-implement rounds reached

PR review found gaps after {ITERATION} bot iterations + {PR_FEEDBACK_CYCLE} human feedback cycles (combined cap of 3). Manual intervention needed.

### Unresolved
{list of unresolved PR comments}

PR: {PR_URL}
```

Mark remaining tasks as deleted. Stop here.

If under cap, proceed.

### Step 5.5a — Fetch PR metadata and comments

Resolve the PR number from the pipeline log:

```bash
_pr_number=$(grep '^[^|]*|PR-REVIEW|checkout-pr|done|' {LOG_FILE} 2>/dev/null | tail -1 | cut -d'|' -f5 || true)
if [ -z "$_pr_number" ]; then
  _pr_number=$(grep -oP 'PR-REVIEW\|pr-review\|done\|.*?\b(\d+)\b' {LOG_FILE} 2>/dev/null | grep -oP '\d+$' | tail -1 || true)
fi
```

Fetch PR metadata and all comments:

```bash
_PR_JSON=$(gh pr view "$_pr_number" --json number,url,headRefName,comments 2>/dev/null || echo '{"error":"gh failed"}')
_PR_URL=$(echo "$_PR_JSON" | jq -r '.url // ""')
_PR_BRANCH=$(echo "$_PR_JSON" | jq -r '.headRefName // ""')
_PR_COMMENTS=$(echo "$_PR_JSON" | jq -r '.comments // []')
```

Log the PR context:

```bash
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|PR-REVIEW|pr-reconcile|info|PR #${_pr_number} — ${_PR_URL} — branch: ${_PR_BRANCH}" >> {LOG_FILE}
```

### Step 5.5b — Resolve bot identity and compute comment boundary

```bash
_bot_user=$(gh api user --jq '.login' 2>/dev/null || echo "")
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|PR-REVIEW|pr-reconcile|info|Bot identity: ${_bot_user}" >> {LOG_FILE}
```

Compute the comment boundary — the last bot-authored comment timestamp:

```bash
_last_bot_ts=$(echo "$_PR_COMMENTS" | jq -r --arg bot "$_bot_user" '[.[] | select(.author.login == $bot or .author.login == "github-actions[bot]")] | last | .createdAt // ""' 2>/dev/null)
```

If no bot comment exists (first PR review crashed before posting), use the pipeline session start as the boundary:

```bash
if [ -z "$_last_bot_ts" ]; then
  _last_bot_ts=$(grep '^[^|]*|PR-REVIEW|pr-review|done|' {LOG_FILE} 2>/dev/null | tail -1 | cut -d'|' -f1 || true)
fi
```

### Step 5.5c — Extract human comments after boundary

```bash
# Filter to human-authored comments after the boundary
_human_comments=$(echo "$_PR_COMMENTS" | jq -r --arg bot "$_bot_user" --arg ts "$_last_bot_ts" \
  '[.[] | select(.author.login != $bot and .author.login != "github-actions[bot]" and .createdAt > $ts)] | group_by(.author.login)')
```

Log the extraction result:

```bash
_human_author_count=$(echo "$_human_comments" | jq -r 'length // 0' 2>/dev/null)
_total_comment_count=$(echo "$_human_comments" | jq -r '[.[] | length] | add // 0' 2>/dev/null)
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|PR-REVIEW|pr-reconcile|info|${_human_author_count} human authors, ${_total_comment_count} comments after boundary" >> {LOG_FILE}
```

If `_total_comment_count` is 0 → skip to Step 5.5g (clean pass).

### Step 5.5d — Extract change requests and determine scope

For each human author group, read the comment bodies and extract change requests. Use semantic judgment to classify each:

- **In-scope**: Directly relates to a ticket requirement. The change is a refinement, bug fix, or edge-case handling within the ticket's stated scope.
- **Out-of-scope**: New feature, separate concern, or change unrelated to any ticket requirement.
- **Ambiguous**: Unclear, contradictory, or lacks enough detail to implement.

Read the ticket requirements from the plan artifact:

```bash
source ~/.claude/skills/lib/ticket-dir.sh
PLAN_PATH=$(resolve_plan_path "{LOG_FILE}" "{TICKET_DIR}" "{ticket-id-lowercase}")
```

Read `{TICKET_DIR}/notes.md` for the original ticket requirements. For each human comment, produce a classification table:

```
| Author | Comment | Request | Scope | Action |
|--------|---------|---------|-------|--------|
| @user  | summary | change  | in-scope/out-of-scope/ambiguous | incorporate/push-back |
```

Log the classification:

```bash
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|PR-REVIEW|pr-reconcile|info|Classification: {N} in-scope, {M} out-of-scope, {P} ambiguous" >> {LOG_FILE}
```

### Step 5.5e — Amendment path (in-scope changes)

**Only if one or more requests are classified as in-scope.**

Amend the plan artifact with a new `## PR Feedback #{PR_FEEDBACK_N}` section:

```markdown
## PR Feedback #{PR_FEEDBACK_N}

**Source:** Human PR review — {author list}
**Date:** {today}

### Changes requested
{list of in-scope change requests with PR comment references}

### What changed
{concrete plan amendments — specific files, logic changes, new edge cases}

### Implementation steps
{numbered list of implementation actions derived from the feedback}
```

The `## PR Feedback #{N}` section is distinct from `## PR Review #{N}` (used by bot review iterations) — the two feedback sources are tracked separately in the plan artifact.

Update notes.md:
- Append a `## PR Feedback #{PR_FEEDBACK_N}` section linking to the plan amendment
- Update `## Open Questions` if new questions arose from the feedback

Increment `PR_FEEDBACK_CYCLE` in the log (writes the done entry in Step 5.5 completion below).

Post a summary comment to Linear:

```bash
SUMMARY_BODY="**PR Feedback Cycle #${PR_FEEDBACK_N}**

## Human PR comments incorporated
{summary of incorporated changes}

## PR replies
{list of PR threads replied to, with links}

## Next step
Re-implementing with amended plan. See PR for updated code."
```

Use the Linear access strategy to post the comment.

### Step 5.5f — Push-back path (out-of-scope or ambiguous)

**For each out-of-scope or ambiguous request**, reply directly to the PR comment thread:

```bash
# Out-of-scope reply template
gh pr comment "$_pr_number" --body "**Out of scope for this ticket.** {rationale — why this change doesn't relate to ticket requirements}. Consider filing a follow-up ticket if this is important." --reply-to {comment_id}

# Ambiguous reply template
gh pr comment "$_pr_number" --body "Could you clarify what you're looking for here? {specific question about the request}." --reply-to {comment_id}
```

Post a summary to Linear listing all push-backs:

```bash
PUSHBACK_BODY="**PR Feedback Cycle #${PR_FEEDBACK_N} — Push-backs**

## Out-of-scope requests
{list with rationale for each}

## Ambiguous requests
{list with clarification questions asked}

## Next step
Waiting for human clarification on the PR. No code changes from this cycle."
```

Use the Linear access strategy to post the comment.

Write the held log entry:

```bash
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|PR-REVIEW|pr-reconcile|done|cycle#${PR_FEEDBACK_N}|held: push-back — {N} out-of-scope, {M} ambiguous" >> {LOG_FILE}
hb_decision "pr-reconcile-result" "fired" "held: push-back" "{\"cycle\":\"${PR_FEEDBACK_N}\",\"out_of_scope\":\"{N}\",\"ambiguous\":\"{M}\"}"
```

Stop. Report:
```
## {TICKET-ID} — PR feedback push-back

**Cycle:** #{PR_FEEDBACK_N}

### Out-of-scope requests pushed back
{list with rationale}

### Ambiguous requests needing clarification
{list with questions asked}

PR replies posted. No code changes. Human clarification needed.
```

Mark remaining tasks as deleted. Stop here.

### Step 5.5g — Clean pass

No human comments to process (or all were already processed). Log clean pass:

```bash
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|PR-REVIEW|pr-reconcile|done|clean" >> {LOG_FILE}
hb_decision "pr-reconcile-result" "fired" "clean pass — no unprocessed human comments" "{\"cycle\":\"${PR_FEEDBACK_N}\"}"
```

Proceed to Step 6 (Report).

---

## Step 5.5 Post-Amendment — Re-enter Implement Loop

**Only when Step 5.5e produced plan amendments (in-scope changes were incorporated).**

### Step 5.5-post-a — Log amendment completion

```bash
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|PR-REVIEW|pr-reconcile|done|cycle#${PR_FEEDBACK_N}|held: human feedback incorporated" >> {LOG_FILE}
hb_decision "pr-reconcile-result" "fired" "amended — re-entering implement loop" "{\"cycle\":\"${PR_FEEDBACK_N}\",\"pr_feedback_cycles\":\"{PR_FEEDBACK_CYCLE}\"}"
```

### Step 5.5-post-b — Re-enter implement phase

Set up the implement spawn with the amended plan. Follow the same pattern as Step 5d (Re-implement) but using `--from-auto`:

### Re-implement spawn (from human feedback)

Run pre-spawn boilerplate. Capture the generated agent prompt:
```bash
source ~/.claude/skills/lib/spawn-helper.sh
_fb_implement_prompt=$(spawn_agent_pre \
  PHASE=IMPLEMENT STEP=implement TICKET_ID={TICKET-ID} \
  LOG_FILE={LOG_FILE} HB_LOG_FILE={HB_LOG_FILE} CLAUDE_LOG_FILE=$CLAUDE_LOG_FILE \
  SKILL=/ticket-implement FLAGS="--from-auto" \
  DESCRIPTION="implementing human PR feedback for {TICKET-ID} (PR feedback cycle {PR_FEEDBACK_N})" \
  INSTRUCTIONS="Follow the skill exactly. Read the updated plan (including the PR Feedback #{PR_FEEDBACK_N} section), implement the changes, write tests, commit, and push. Report the final output including branch name.")
```

Spawn a `ticket-implement-agent` with `$_fb_implement_prompt` as the instruction.

Wait for the agent. Persist:
```bash
spawn_capture TICKET_ID={TICKET-ID} PHASE=implement-feedback RESULT="$AGENT_RESULT" ATTEMPT="{PR_FEEDBACK_N}"
```

Extract:
- `{OUTCOME}` — `Smooth`, `Rough`, or `Hard`

If the agent fails → post fail and stop:
```bash
spawn_agent_post TICKET_ID={TICKET-ID} RESULT=fail \
  MSG="Agent failed (PR feedback cycle {PR_FEEDBACK_N})"
```
Stop.

On success:
```bash
spawn_agent_post TICKET_ID={TICKET-ID} RESULT=done \
  MSG="{OUTCOME}, branch: {branch} (PR feedback cycle {PR_FEEDBACK_N})" NEXT_PHASE=VERIFY
```

### Step 5.5-post-c — Verify

Run `/ticket-verify {TICKET-ID} --env local --from-auto`. After the agent returns, persist output:

```bash
capture_agent_result "{TICKET-ID}" "verify-feedback" "$AGENT_RESULT" "{PR_FEEDBACK_N}"
```

Extract `{VERDICT}` (PASS or FAIL). On FAIL, apply the standard verify retry logic from Step 4.5b (up to 3 attempts, loop back to implement on retry). On PASS, proceed.

### Step 5.5-post-d — Document + Wiki Maintenance

Regenerate `ai-context.md` and run wiki maintenance in a single agent spawn (non-blocking, same pattern as Step 4.6):

Run pre-spawn boilerplate. Capture the generated agent prompt:
```bash
source ~/.claude/skills/lib/spawn-helper.sh
_fb_maintenance_prompt=$(spawn_agent_pre \
  PHASE=MAINTENANCE STEP=maintenance TICKET_ID={TICKET-ID} \
  LOG_FILE={LOG_FILE} HB_LOG_FILE={HB_LOG_FILE} CLAUDE_LOG_FILE=$CLAUDE_LOG_FILE \
  SKILL=none FLAGS="--from-auto" \
  DESCRIPTION="document + wiki maintenance for {TICKET-ID} (post-feedback cycle {PR_FEEDBACK_N})" \
  INSTRUCTIONS="Execute both sub-tasks in order (same pattern as Step 4.6 combined maintenance):

SUB-TASK 1 — Regenerate ai-context.md:
1. Source: source /tmp/ticket-auto-{TICKET-ID}-env.sh 2>/dev/null || true
2. Read notes.md from {TICKET_DIR}, including PR Feedback sections.
3. Diff the branch against develop, classify significance, write ai-context.md.
4. Write pipeline log: \$(date -u +%Y-%m-%dT%H:%M:%SZ)|MAINTENANCE|document|done|{DOCUMENT_FILE} ({PATTERNS} patterns, {DECISIONS} decisions, {SIGNIFICANCE}) >> {LOG_FILE}
5. On failure: \$(date -u +%Y-%m-%dT%H:%M:%SZ)|MAINTENANCE|document|fail|Agent failed — continuing >> {LOG_FILE}

SUB-TASK 2 — Wiki Maintenance:
1. Use \$WIKI_ROOT from env. If unset, skip.
2. Process unresolved errata, promote ai-context findings.
3. Write pipeline log: \$(date -u +%Y-%m-%dT%H:%M:%SZ)|MAINTENANCE|wiki-errata|done|{ERRATA_COUNT} errata, {AI_CONTEXT_FINDINGS} findings >> {LOG_FILE}
4. On failure: \$(date -u +%Y-%m-%dT%H:%M:%SZ)|MAINTENANCE|wiki-errata|fail|Agent failed — continuing >> {LOG_FILE}

Emit MAINTENANCE_RESULT block as in Step 4.6.")
```

Spawn a `ticket-maintenance-agent` with `$_fb_maintenance_prompt`. Wait, persist:
```bash
spawn_capture TICKET_ID={TICKET-ID} PHASE=maintenance-feedback RESULT="$AGENT_RESULT" ATTEMPT="{PR_FEEDBACK_N}"
```

Extract `{DOCUMENT_FILE}`, `{PATTERNS}`, `{DECISIONS}`, `{SIGNIFICANCE}`, `{ERRATA_COUNT}`, `{AI_CONTEXT_FINDINGS}`.

On failure (non-blocking):
```bash
FAIL_ACTION=warn-continue spawn_agent_post TICKET_ID={TICKET-ID} RESULT=fail \
  MSG="Agent failed — continuing"
```

On success, include phase-transition heartbeat:
```bash
spawn_agent_post TICKET_ID={TICKET-ID} RESULT=done \
  MSG="doc={DOCUMENT_FILE} ({SIGNIFICANCE}) errata={ERRATA_COUNT} wiki_findings={AI_CONTEXT_FINDINGS}" \
  NEXT_PHASE=PR-REVIEW
```

### Step 5.5-post-e — Re-run PR review

Run a fresh PR review on the updated branch:

### PR Review spawn (post-feedback)

Run pre-spawn boilerplate. Capture the generated agent prompt:
```bash
source ~/.claude/skills/lib/spawn-helper.sh
_fb_pr_review_prompt=$(spawn_agent_pre \
  PHASE=PR-REVIEW STEP=pr-review TICKET_ID={TICKET-ID} \
  LOG_FILE={LOG_FILE} HB_LOG_FILE={HB_LOG_FILE} CLAUDE_LOG_FILE=$CLAUDE_LOG_FILE \
  SKILL=/ticket-pr-review FLAGS="--from-auto" \
  DESCRIPTION="re-reviewing PR after human feedback for {TICKET-ID} (cycle {PR_FEEDBACK_N})" \
  INSTRUCTIONS="Follow the skill exactly. Validate the PR diff against the ticket requirements (including PR Feedback #{PR_FEEDBACK_N} amendments). Post a fresh ## Ticket alignment review comment with updated coverage table. If all requirements addressed (verdict ✅), merge via squash. Report the final output.")
```

Spawn a `ticket-pr-review-agent` with `$_fb_pr_review_prompt` as the instruction.

Wait for the agent. Persist:
```bash
spawn_capture TICKET_ID={TICKET-ID} PHASE=pr-review-feedback RESULT="$AGENT_RESULT" ATTEMPT="{PR_FEEDBACK_N}"
```

Extract:
- `{VERDICT}` — ✅ all addressed, or ⚠️ gaps found
- `{MERGED}` — yes, no, or skipped

If the agent fails → post fail and stop:
```bash
spawn_agent_post TICKET_ID={TICKET-ID} RESULT=fail \
  MSG="Agent failed (post-feedback cycle {PR_FEEDBACK_N})"
```
Stop.

On success:
```bash
spawn_agent_post TICKET_ID={TICKET-ID} RESULT=done \
  MSG="Verdict: {VERDICT}, merged: {MERGED} (post-feedback cycle {PR_FEEDBACK_N})" NEXT_PHASE=REPORT
```

- **Verdict ✅** → proceed to Step 6 (Report).
- **Verdict ⚠️** → this is a bot-review iteration (not human feedback). Increment `{ITERATION}`. Apply the ⚠️ branch from Step 5b (combined cap check, then iterate or stop).

---

## Step 6 — Report

**CRITICAL ORDERING CONSTRAINT:** Do NOT write `META|outcome` until ALL of these have completed:
1. Step 5 (Document + Wiki Maintenance) — verified by `|MAINTENANCE|maintenance|done|` or `|MAINTENANCE|maintenance|fail|` in the log
2. Step 6a (Retro auto-trigger) — retro-trigger entry written (or skipped)

The outcome line MUST be the final substantive entry in the pipeline log. On every exit path (success, gate-stop, no-op, crash), verify that no maintenance or retro steps remain before writing outcome.

### Step 6a — Retro auto-trigger check

Before writing the final outcome, check whether this run warrants a retrospection:

```bash
# Condition 1: did any gate-stop fire during this run?
GATE_STOP_COUNT=$(grep -c '|META|gate-stop|fail|' {LOG_FILE} 2>/dev/null || echo 0)

# Condition 2: did the ticket NOT reach a successful outcome?
OUTCOME_LINE=$(grep '|IMPLEMENT|implement|done|' {LOG_FILE} 2>/dev/null | tail -1 || true)
OUTCOME_LABEL=""
if [ -n "$OUTCOME_LINE" ]; then
  OUTCOME_MSG=$(echo "$OUTCOME_LINE" | cut -d'|' -f5)
  OUTCOME_LABEL=$(echo "$OUTCOME_MSG" | cut -d',' -f1)
fi
```

If either condition is true (`GATE_STOP_COUNT > 0` or `OUTCOME_LABEL` is not one of `Smooth`, `Rough`, `Hard`), invoke the retro skill. Otherwise skip.

**Triggered:**
```bash
hb_decision "retro-trigger" "fired" "pipeline warrants retrospection" "{\"gate_stops\":\"${GATE_STOP_COUNT}\",\"outcome\":\"${OUTCOME_LABEL:-none}\"}"
```
```
Pipeline outcome for {TICKET-ID} warrants retrospection.
Gate-stops detected: {GATE_STOP_COUNT}
Outcome label: {OUTCOME_LABEL:-none}
Invoking /ticket-retro --window 1 {LOG_FILE}
```

Invoke via Claude's Skill tool — do NOT shell out via Bash, the AI reasoning step in the retro skill needs the orchestrator's model session:
```
Skill(skill="ticket-retro", args="--window 1 {LOG_FILE}")
```

If the retro invocation fails (skill not found, retro.sh error), log a warning but do NOT change the ticket outcome:
```bash
# Idempotency guard: skip if retro-trigger already written
if ! tail -1 {LOG_FILE} 2>/dev/null | grep -q '|META|retro-trigger|'; then
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|META|retro-trigger|fail|/ticket-retro invocation failed — continuing" >> {LOG_FILE}
fi
```

**Skipped (clean run):**
```bash
# Idempotency guard: skip if retro-trigger already written
if ! tail -1 {LOG_FILE} 2>/dev/null | grep -q '|META|retro-trigger|'; then
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|META|retro-trigger|skip|clean run, retro skipped" >> {LOG_FILE}
fi
hb_decision "retro-trigger" "skip" "clean run, retro skipped"
```

Do NOT block the pipeline on retro failure — the ticket outcome is already determined.

### Step 6b — Write outcome and report

**Before writing outcome**, verify MAINTENANCE has completed:
```bash
# Verify maintenance completed (or was skipped/not applicable)
if ! grep -q '|MAINTENANCE|maintenance|' {LOG_FILE} 2>/dev/null; then
  # Maintenance hasn't run yet — check if it was skipped on this path
  # (gate-stop paths skip maintenance; success paths must have it)
  if grep -q '|GATE|gate|fail|held:' {LOG_FILE} 2>/dev/null; then
    : # Gate-stop: maintenance was skipped, outcome already written at gate
  else
    echo "WARNING: outcome written but no MAINTENANCE entries found — verify ordering" >&2
  fi
fi
```

Write the pipeline outcome event (idempotent — skip if already the last line):
```bash
# Idempotency guard: skip if outcome already written
if ! tail -1 {LOG_FILE} 2>/dev/null | grep -q '|META|outcome|'; then
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|META|outcome|info|complete" >> {LOG_FILE}
fi
hb_decision "pipeline-outcome" "fired" "pipeline complete" '{"outcome":"complete","iterations":"{ITERATION}","merged":"{MERGED}"}'
```

```
## {TICKET-ID} — pipeline complete

| Phase | Result |
|---|---|
| Autonomy | {manual\|auto\|semi-auto} |
| Appraise | {simple|complex}, {N} files traced |
| Reproduce | {REPRODUCED\|NOT_REPRODUCED\|BLOCKED\|skipped: not bug} |
| Exec | {simple-fix | openspec: <name>} |
| Gate | {auto-approved | held} |
| Implement | {Smooth|Rough|Hard}, PRs: {URLs} |
| Verify | {✅ PASS ({VERIFY_ATTEMPTS} attempts)|❌ FAIL after {VERIFY_ATTEMPTS}|skipped} |
| PR Review | {✅|⚠️}, merged: {yes\|auto-merged (semi-auto, simple+Smooth)\|no} |
| Wiki Maintenance | {N} errata incorporated |
| PR iteration re-verify | {VERIFY_RETRIES} retries across iterations |
| Iterations | {ITERATION} |
| Retro | {triggered → ~/.claude/state/ticket-retro/proposals/{date}-retro.md \| skipped (clean run)} |

**Local:** {ticket-dir}
**Linear:** {ticket URL}

{If merged: ✅ All done.}
{If gaps after max iterations: ⚠️ PR still has unaddressed requirements after 3 rounds — check the PR comments and intervene manually.}
{If mismatch: ⚡ Complexity prediction missed — appraisal gap recorded in claude-mem.}
```
