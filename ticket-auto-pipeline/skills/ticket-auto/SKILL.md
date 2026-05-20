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

The `get_issue` function returns JSON at `.data.issue` — use `jq` to extract fields. The `get_comments` function returns a JSON array of comment nodes.

### API error capture convention

After every Linear API call (`get_issue`, `get_comments`, `save_comment`, `get_me`), capture failures in the heartbeat log using `hb_retry`. This is mandatory — never silently discard API errors.

**get_issue failure pattern:**
```bash
_raw=$(bash -c "source ~/.claude/skills/lib/linear-api.sh; get_issue '{TICKET-ID}'" 2>&1)
_rc=$?
if [ $_rc -ne 0 ] || ! echo "$_raw" | jq -e '.data.issue' >/dev/null 2>&1; then
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
_field=$(echo "$_raw" | jq -r '.data.issue.fieldName' 2>&1)
if [ $? -ne 0 ] || [ "$_field" = "null" ]; then
  hb_retry "jq-parse" "fail" "jq extraction failed for fieldName" \
    "{\"error_type\":\"jq_parse\",\"command\":\"get_issue\",\"field\":\"fieldName\"}"
fi
```

**flow.sh failure pattern:** After every `flow.sh` invocation, capture non-zero exits:
```bash
bash ~/.claude/skills/ticket-flow/flow.sh "{TICKET-ID}" "{trigger}" 2>&1
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
hb_heartbeat "pipeline-start" "pipeline starting — autonomy={AUTONOMY}, ticket={TICKET-ID}"
hb_decision "autonomy-resolution" "fired" "autonomy set to {AUTONOMY}" '{"mode":"{AUTONOMY}"}'
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
  bash ~/.claude/skills/ticket-flow/validate-linear-config.sh "$TEAM_ID" || {
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

Read `CLAUDE.md` and extract: `{REPOS_ROOT}` (parent path of all service dirs), `{ISSUE_PREFIX}` (issue ID prefix, e.g. `CRE`), `{BE_SERVICES}` (BE service dir names).

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
touch "$LOG_FILE"
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
| `{PHASE}` | Uppercase phase: APPRAISE, EXEC, IMPLEMENT, VERIFY, MAINTENANCE, PR-REVIEW |
| `{SKILL}` | Slash command: `/ticket-appraise`, `/ticket-appraise-exec`, `/ticket-implement`, `/ticket-verify`, `/wiki-maintenance`, `/ticket-pr-review`, `/ticket-pr-iterate` |
| `{DESCRIPTION}` | What the agent does (for the waiting log entry) |
| `{EXTRA_FLAGS}` | Flags like `--from-auto`, `--env local`, `--from-step {FROM}` |
| `{SKILL_INSTRUCTIONS}` | Additional instructions after the exports (e.g., "Follow the skill exactly.", "Use Serena for all code navigation.") |
| `{EXTRACT}` | Fields to extract from agent output |
| `{FAIL_ACTION}` | `stop` or `warn-continue` (maintenance is non-blocking) |
| `{NEXT_PHASE}` | Next phase for the transition heartbeat |

**Execution sequence:**

1. Write waiting log entry:
   ```bash
   echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|{PHASE}|{phase}|waiting|Agent launched — {DESCRIPTION}" >> {LOG_FILE}
   hb_heartbeat "orchestrator-waiting" "agent {phase} launched"
   ```

2. Write phase context file:
   ```bash
   echo "{PHASE}|{LOG_FILE}" > /tmp/ticket-auto-{TICKET-ID}-ctx.txt
   ```

3. Spawn `general-purpose` agent:
   ```
   Run {SKILL} {TICKET-ID} {EXTRA_FLAGS}. Before starting, run: export LOG_FILE="{LOG_FILE}"; export HB_LOG_FILE="{HB_LOG_FILE}"; source ~/.claude/skills/lib/heartbeat.sh. {SKILL_INSTRUCTIONS}
   ```

4. Wait for agent. Persist output:
   ```bash
   capture_agent_result "{TICKET-ID}" "{phase}" "$AGENT_RESULT"
   ```

5. Extract `{EXTRACT}` from result.

6. On failure:
   ```bash
   echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|{PHASE}|{phase}|fail|Agent failed{if FAIL_ACTION=warn-continue: ` — continuing`}" >> {LOG_FILE}
   hb_heartbeat "agent-returned" "{phase} agent failed"
   ```
   → `{FAIL_ACTION}`

7. On success:
   ```bash
   echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|{PHASE}|{phase}|done|{result}" >> {LOG_FILE}
   hb_heartbeat "agent-returned" "{phase} agent done — {result}"
   hb_heartbeat "phase-transition" "{PHASE} → {NEXT_PHASE}"
   ```

At session end, write a trace file:

```bash
cat > {ticket-dir}/auto-session.md << 'TRACE'
# auto session — {ISSUE-ID}
**Date:** {today}
**Outcome:** {completed | stopped: <reason>}

## Step trace
- [x] Step 1: Appraise — {simple|complex}, {N} files traced
- [x] Step 2: Exec — {simple-fix|openspec: <name>}
- [x] Step 3: Gate — {auto-approved|stopped: complex}
- [x] Step 4: Implement — {Smooth|Rough|Hard}
- [x] Step 4.6: Wiki Maintenance — {N} errata processed
- [x] Step 4.5: Verify — {✅ PASS (N attempts)|❌ FAIL after N|skipped: no UI}
- [x] Step 5: PR review — {✅|⚠️}, {N} iterations, {N} re-verify retries
- [x] Step 6: Report — done
TRACE
```

---

## Step 0.7 — Crash-recovery detection

Run `/ticket-detect-resume {TICKET-ID}` inline (execute the skill logic directly — no agent spawn needed). Parse the `DETECT_RESUME_RESULT` block and set all variables:

`{RESUME_STEP}`, `{APPRAISE_FROM}`, `{EXEC_FROM}`, `{IMPLEMENT_FROM}`, `{MAINTENANCE_FROM}`, `{VERIFY_FROM}`, `{PR_REVIEW_FROM}`, `{PR_ITERATE_FROM}`, `{TICKET_DIR}`, `{COMPLEXITY}`, `{ARTIFACT_TYPE}`, `{BRANCH}`, `{TICKET_TITLE}`, `{VERIFY_ATTEMPTS}`, `{ITERATION}`, `{AUTONOMY}` (read from `META|autonomy|info|` log line).

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
| STEP_2 | Step 2 (Exec) |
| STEP_3 | Step 3 (Gate) |
| STEP_3_5 | Step 3.5 (Comment Reconciliation) |
| STEP_4 | Step 4 (Implement) |
| STEP_4_5 | Step 4.5 (Verify) |
| STEP_4_6 | Step 4.6 (Wiki Maintenance) |
| STEP_5 | Step 5 (PR Review loop) |
| STEP_6 | Step 6 (Report) |

---

## Step 1 — Appraise

### Appraise spawn
Follow the agent spawn template with: PHASE=APPRAISE, SKILL=/ticket-appraise, DESCRIPTION=investigating {TICKET-ID}, EXTRA_FLAGS=--from-auto{if {APPRAISE_FROM} is non-empty: ` --from-step {APPRAISE_FROM}`}, SKILL_INSTRUCTIONS=Follow the skill exactly. When you hit Resume mode and the workspace already exists, if asked "continue or re-investigate?", choose "continue" — do not prompt. Report only the final handoff output., EXTRACT=COMPLEXITY, TICKET_DIR, TICKET_TITLE, FAIL_ACTION=stop, NEXT_PHASE=EXEC

Write the waiting log entry:
```bash
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|APPRAISE|appraise|waiting|Agent launched — investigating {TICKET-ID}" >> {LOG_FILE}
hb_heartbeat "orchestrator-waiting" "agent appraise launched"
```

Write the phase context file so the token-tracker hook knows where to log:

```bash
echo "APPRAISE|{LOG_FILE}" > /tmp/ticket-auto-{TICKET-ID}-ctx.txt
```

Spawn a `general-purpose` agent to investigate the ticket:

```
Run /ticket-appraise {TICKET-ID} --from-auto{if {APPRAISE_FROM} is non-empty: ` --from-step {APPRAISE_FROM}`}. Before starting, run: export LOG_FILE="{LOG_FILE}"; export HB_LOG_FILE="{HB_LOG_FILE}"; source ~/.claude/skills/lib/heartbeat.sh. Follow the skill exactly. When you hit Resume mode and the workspace already exists, if asked "continue or re-investigate?", choose "continue" — do not prompt. Report only the final handoff output.
```

Wait for the agent. Persist the raw output immediately before extracting any fields:
```bash
capture_agent_result "{TICKET-ID}" "appraise" "$AGENT_RESULT"
```

Extract from its result:
- `{COMPLEXITY}` — `simple` or `complex`
- `{TICKET_DIR}` — local workspace path (derive from the find command in Step 1 of appraise-exec pattern, or read from agent output)
- `{TICKET_TITLE}` — the full ticket title. If not present in the agent's handoff, fetch it via the Linear access strategy above (bash `get_issue` when key is set, MCP fallback otherwise) before writing the META title line.

If the agent fails → write fail log and stop:
```bash
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|APPRAISE|appraise|fail|Agent failed" >> {LOG_FILE}
hb_heartbeat "agent-returned" "appraise agent failed"
```

On success, write the done log entry and META title:
```bash
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|APPRAISE|appraise|done|{COMPLEXITY}, {N} files traced" >> {LOG_FILE}
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|META|title|info|{TICKET-ID}: {TICKET_TITLE}" >> {LOG_FILE}
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|META|artifact|info|notes:{TICKET_DIR}/notes.md" >> {LOG_FILE}
hb_heartbeat "agent-returned" "appraise agent done — {COMPLEXITY}"
hb_heartbeat "phase-transition" "APPRAISE → EXEC"
```

---

## Step 2 — Exec

### Exec spawn
Follow the agent spawn template with: PHASE=EXEC, SKILL=/ticket-appraise-exec, DESCRIPTION=creating artifacts for {TICKET-ID}, EXTRA_FLAGS=--from-auto{if {EXEC_FROM} is non-empty: ` --from-step {EXEC_FROM}`}, SKILL_INSTRUCTIONS=Follow the skill exactly. Report only the final handoff output., EXTRACT=ARTIFACT_TYPE, FAIL_ACTION=stop, NEXT_PHASE=GATE

Write the waiting log entry:

Write the phase context file so the token-tracker hook knows where to log:

```bash
echo "EXEC|{LOG_FILE}" > /tmp/ticket-auto-{TICKET-ID}-ctx.txt
```

Spawn a `general-purpose` agent to create artifacts:

```
Run /ticket-appraise-exec {TICKET-ID} --from-auto{if {EXEC_FROM} is non-empty: ` --from-step {EXEC_FROM}`}. Before starting, run: export LOG_FILE="{LOG_FILE}"; export HB_LOG_FILE="{HB_LOG_FILE}"; source ~/.claude/skills/lib/heartbeat.sh. Follow the skill exactly. Report only the final handoff output.
```

Wait for the agent. Persist the raw output immediately before extracting any fields:
```bash
capture_agent_result "{TICKET-ID}" "exec" "$AGENT_RESULT"
```

Extract:
- `{ARTIFACT_TYPE}` — `simple-fix` or `openspec:<name>`

If the agent fails → write fail log and stop:
```bash
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|EXEC|exec|fail|Agent failed" >> {LOG_FILE}
hb_heartbeat "agent-returned" "exec agent failed"
```

On success:
```bash
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|EXEC|exec|done|{ARTIFACT_TYPE}" >> {LOG_FILE}
hb_heartbeat "agent-returned" "exec agent done — {ARTIFACT_TYPE}"
hb_heartbeat "phase-transition" "EXEC → GATE"
```

Resolve and log the plan artifact path so the dashboard can display it:

```bash
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/ticket-dir.sh"
PLAN_PATH=$(resolve_plan_path "{LOG_FILE}" "{TICKET_DIR}" "{ticket-id-lowercase}")
if [ -n "$PLAN_PATH" ]; then
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
  hb_heartbeat "phase-transition" "GATE → IMPLEMENT"
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
bash ~/.claude/skills/ticket-flow/flow.sh "{TICKET-ID}" "re-claim"
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
hb_heartbeat "phase-transition" "GATE → IMPLEMENT"
```

Proceed to Step 4.

---
## Step 4 — Implement

Fetch the ticket via the Linear access strategy (bash `get_issue` when `LINEAR_API_KEY` is set, MCP fallback otherwise) and verify the `approved` label is present. If missing (shouldn't happen given Step 3 or Step 3.5, but verify) — add it now for simple tickets, or stop for complex.

### Implement spawn
Follow the agent spawn template with: PHASE=IMPLEMENT, SKILL=/ticket-implement, DESCRIPTION=implementing {TICKET-ID}, EXTRA_FLAGS=--from-auto{if {IMPLEMENT_FROM} is non-empty: ` --from-step {IMPLEMENT_FROM}`}, SKILL_INSTRUCTIONS=Follow the skill exactly. Use Serena for all code navigation — mandatory. Commit and push. Report the final output including branch name. After this agent returns, clear `{IMPLEMENT_FROM}` (set to empty) — loop re-invocations in Step 5d always start fresh., EXTRACT=OUTCOME, MISMATCH, FAIL_ACTION=stop, NEXT_PHASE=VERIFY

Write the waiting log entry:

Write the phase context file so the token-tracker hook knows where to log:

```bash
echo "IMPLEMENT|{LOG_FILE}" > /tmp/ticket-auto-{TICKET-ID}-ctx.txt
```

Spawn a `general-purpose` agent:

```
Run /ticket-implement {TICKET-ID} --from-auto{if {IMPLEMENT_FROM} is non-empty: ` --from-step {IMPLEMENT_FROM}`}. Before starting, run: export LOG_FILE="{LOG_FILE}"; export HB_LOG_FILE="{HB_LOG_FILE}"; source ~/.claude/skills/lib/heartbeat.sh. Follow the skill exactly. Use Serena for all code navigation — mandatory. Commit and push. Report the final output including branch name.

After this agent returns, clear `{IMPLEMENT_FROM}` (set to empty) — loop re-invocations in Step 5d always start fresh.
```

Wait for the agent. Persist the raw output immediately before extracting any fields:
```bash
capture_agent_result "{TICKET-ID}" "implement" "$AGENT_RESULT"
```

Extract:
- `{OUTCOME}` — `Smooth`, `Rough`, or `Hard`
- `{MISMATCH}` — whether a complexity mismatch was reported (look for "Complexity mismatch" in the output)

If the agent fails → write fail log and stop:
```bash
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|IMPLEMENT|implement|fail|Agent failed" >> {LOG_FILE}
hb_heartbeat "agent-returned" "implement agent failed"
```

On success:
```bash
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|IMPLEMENT|implement|done|{OUTCOME}, branch: {branch}" >> {LOG_FILE}
hb_heartbeat "agent-returned" "implement agent done — {OUTCOME}"
hb_heartbeat "phase-transition" "IMPLEMENT → VERIFY"
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
hb_heartbeat "phase-transition" "IMPLEMENT → MAINTENANCE (verify skipped)"
```
Proceed to Step 4.6 (Wiki Maintenance).

### Step 4.5a — Verification attempt

Write log start event:
```bash
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|VERIFY|verify|start|Attempt {VERIFY_ATTEMPTS}/3 — running Playwright UAT" >> {LOG_FILE}
hb_heartbeat "orchestrator-waiting" "verify attempt $(({VERIFY_ATTEMPTS}+1))/3"
```

Write the phase context file so the token-tracker hook knows where to log:

```bash
echo "VERIFY|{LOG_FILE}" > /tmp/ticket-auto-{TICKET-ID}-ctx.txt
```

Run `/ticket-verify {TICKET-ID} --env local --from-auto{if {VERIFY_FROM} is non-empty: ` --from-step {VERIFY_FROM}`}`.
After the agent returns, persist the raw output using append mode (attempt number tracks retries):
```bash
capture_agent_result "{TICKET-ID}" "verify" "$AGENT_RESULT" "$(({VERIFY_ATTEMPTS}+1))"
```
Extract `{VERDICT}` (PASS or FAIL).
After this call, clear `{VERIFY_FROM}` (set to empty) — retry re-invocations always start fresh.

Write log result event:
```bash
# PASS:
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|VERIFY|verify|done|PASS" >> {LOG_FILE}
hb_heartbeat "agent-returned" "verify agent done — PASS"
hb_heartbeat "phase-transition" "VERIFY → MAINTENANCE"
# FAIL:
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|VERIFY|verify|fail|FAIL — criteria not met" >> {LOG_FILE}
hb_heartbeat "agent-returned" "verify agent done — FAIL"
```

- **PASS** → proceed to Step 4.6 (Wiki Maintenance).
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
  Step 4.6 (Wiki Maintenance) runs after VERIFY passes.
  Do NOT re-initialize `{VERIFY_ATTEMPTS}`.

Pass `--from-auto` to the ticket-implement agent spawn in Step 4 — add `--from-auto` to the agent prompt.

---

## Step 4.6 — Wiki Maintenance

Incorporate any errata discovered during implementation into the project wiki so downstream tickets benefit from corrected call chains.

### Maintenance spawn
Follow the agent spawn template with: PHASE=MAINTENANCE, SKILL=/wiki-maintenance, DESCRIPTION=wiki maintenance for {TICKET-ID}, EXTRA_FLAGS=, SKILL_INSTRUCTIONS=Process any unresolved errata entries that were appended by ticket-implement Step 4c. Edit only wiki files — do not modify source code. Report the final output including count of errata processed and files modified., EXTRACT=ERRATA_COUNT, FAIL_ACTION=warn-continue, NEXT_PHASE=PR-REVIEW

Write the waiting log entry:

Write the phase context file so the token-tracker hook knows where to log:

```bash
echo "MAINTENANCE|{LOG_FILE}" > /tmp/ticket-auto-{TICKET-ID}-ctx.txt
```

Spawn a `general-purpose` agent:

```
Run /wiki-maintenance. Before starting, run: export LOG_FILE="{LOG_FILE}"; export HB_LOG_FILE="{HB_LOG_FILE}"; source ~/.claude/skills/lib/heartbeat.sh. Process any unresolved errata entries that were appended by ticket-implement Step 4c. Edit only wiki files — do not modify source code. Report the final output including count of errata processed and files modified.
```

Wait for the agent. Persist the raw output immediately before extracting any fields:
```bash
capture_agent_result "{TICKET-ID}" "maintenance" "$AGENT_RESULT"
```

Extract:
- `{ERRATA_COUNT}` — number of errata entries processed (0 if none)

If the agent fails → log a warning but continue (wiki maintenance is non-blocking):
```bash
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|MAINTENANCE|maintenance|fail|Agent failed — continuing" >> {LOG_FILE}
hb_heartbeat "agent-returned" "wiki-maintenance agent failed — continuing (non-blocking)"
```

On success:
```bash
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|MAINTENANCE|maintenance|done|{ERRATA_COUNT} errata incorporated" >> {LOG_FILE}
hb_heartbeat "agent-returned" "wiki-maintenance agent done — {ERRATA_COUNT} errata"
hb_heartbeat "phase-transition" "MAINTENANCE → PR-REVIEW"
```

Non-blocking: wiki maintenance failure does not stop the pipeline. The errata remain unresolved and will be picked up by the next ticket's maintenance run.

---

## Step 5 — PR Review + Iteration Loop

Initialize `{ITERATION}` = 0. The loop runs at most 3 times.

### Step 5a — Run PR review

### PR Review spawn
Follow the agent spawn template with: PHASE=PR-REVIEW, SKILL=/ticket-pr-review, DESCRIPTION=reviewing PR for {TICKET-ID}, EXTRA_FLAGS=--from-auto{if {PR_REVIEW_FROM} is non-empty: ` --from-step {PR_REVIEW_FROM}`}, SKILL_INSTRUCTIONS=Follow the skill exactly. Validate the PR diff against the ticket requirements. Post findings. If all requirements addressed (verdict ✅), merge via squash. Report the final output. After this agent returns, clear `{PR_REVIEW_FROM}` — subsequent iterations start fresh., EXTRACT=VERDICT, MERGED, FAIL_ACTION=stop, NEXT_PHASE=REPORT

Write the waiting log entry:

Write the phase context file so the token-tracker hook knows where to log:

```bash
echo "PR-REVIEW|{LOG_FILE}" > /tmp/ticket-auto-{TICKET-ID}-ctx.txt
```

Spawn a `general-purpose` agent:

```
Run /ticket-pr-review {TICKET-ID} --from-auto{if {PR_REVIEW_FROM} is non-empty: ` --from-step {PR_REVIEW_FROM}`}. Before starting, run: export LOG_FILE="{LOG_FILE}"; export HB_LOG_FILE="{HB_LOG_FILE}"; source ~/.claude/skills/lib/heartbeat.sh. Follow the skill exactly. Validate the PR diff against the ticket requirements. Post findings. If all requirements addressed (verdict ✅), merge via squash. Report the final output.

After this agent returns, clear `{PR_REVIEW_FROM}` — subsequent iterations start fresh.
```

Wait for the agent. Persist the raw output immediately before extracting any fields:
```bash
capture_agent_result "{TICKET-ID}" "pr-review" "$AGENT_RESULT"
```

Extract:
- `{VERDICT}` — ✅ all addressed, or ⚠️ gaps found
- `{MERGED}` — yes, no, or skipped

If the agent fails → write fail log and stop:
```bash
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|PR-REVIEW|pr-review|fail|Agent failed" >> {LOG_FILE}
hb_heartbeat "agent-returned" "pr-review agent failed"
```

On success:
```bash
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|PR-REVIEW|pr-review|done|Verdict: {VERDICT}, merged: {MERGED}" >> {LOG_FILE}
hb_heartbeat "agent-returned" "pr-review agent done — verdict {VERDICT}"
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
    gh pr merge --squash --auto {PR_URL}
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|PR-REVIEW|pr-review|done|Verdict: ✅, merged: auto-merged (semi-auto, simple+Smooth)" >> {LOG_FILE}
    hb_decision "merge-decision" "fired" "auto-merged" '{"reason":"semi-auto+simple+Smooth","verdict":"✅"}'
    ```
    Set `{MERGED}` = `auto-merged`.
    ```bash
    hb_heartbeat "phase-transition" "PR-REVIEW → REPORT"
    ```
    Break out of loop. Go to Step 6 (Report).
  - Otherwise (wrong flag, complex ticket, or outcome ≠ Smooth) → normal merge flow. The PR review agent already handles merge.
    ```bash
    hb_decision "merge-decision" "fired" "merged via PR review agent" '{"verdict":"✅","autonomy":"{AUTONOMY}","complexity":"{COMPLEXITY}"}'
    hb_heartbeat "phase-transition" "PR-REVIEW → REPORT"
    ```
    Set `{MERGED}` = `yes`. Break out of loop. Go to Step 6 (Report).
- **Verdict ⚠️** → auto-merge blocked regardless of flag. Increment `{ITERATION}`. If `{ITERATION} >= 3` → stop and report:
  ```
  ## {TICKET-ID} — max iterations reached

  PR review found gaps after 3 implementation attempts. Manual intervention needed.
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
Follow the agent spawn template with: PHASE=PR-REVIEW, SKILL=/ticket-pr-iterate, DESCRIPTION=iterating on PR feedback for {TICKET-ID}, EXTRA_FLAGS=--from-auto{if {PR_ITERATE_FROM} is non-empty: ` --from-step {PR_ITERATE_FROM}`}, SKILL_INSTRUCTIONS=Follow the skill exactly. Parse the PR review findings, append a PR Review #{ITERATION} section to the plan, update Linear to Ready + approved. Report the final output. After this agent returns, clear `{PR_ITERATE_FROM}`., EXTRACT=none, FAIL_ACTION=stop, NEXT_PHASE=RE-IMPLEMENT

Write the phase context file:
```

Wait for the agent. If it fails → stop and report.

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

Write the phase context file so the token-tracker hook knows where to log:

```bash
echo "IMPLEMENT|{LOG_FILE}" > /tmp/ticket-auto-{TICKET-ID}-ctx.txt
```

### Re-implement spawn
Follow the agent spawn template with: PHASE=IMPLEMENT, SKILL=/ticket-implement, DESCRIPTION=re-implementing {TICKET-ID} (iteration {ITERATION}), EXTRA_FLAGS=--from-auto, SKILL_INSTRUCTIONS=Follow the skill exactly. Read the updated plan (including the PR Review #{ITERATION} section), implement the changes, write tests, commit, and push. Report the final output including branch name., EXTRACT=OUTCOME, FAIL_ACTION=stop, NEXT_PHASE=RE-VERIFY

Spawn a `general-purpose` agent:

```
Run /ticket-implement {TICKET-ID} --from-auto. Before starting, run: export LOG_FILE="{LOG_FILE}"; export HB_LOG_FILE="{HB_LOG_FILE}"; source ~/.claude/skills/lib/heartbeat.sh. Follow the skill exactly. Read the updated plan (including the PR Review #{ITERATION} section), implement the changes, write tests, commit, and push. Report the final output including branch name.
```

Wait for the agent. Persist the raw output immediately before extracting any fields:
```bash
capture_agent_result "{TICKET-ID}" "re-implement" "$AGENT_RESULT" "{ITERATION}"
```

Extract:
- `{OUTCOME}` — `Smooth`, `Rough`, or `Hard`

If the agent fails → write fail log and stop:
```bash
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|IMPLEMENT|re-implement|fail|Agent failed (iteration {ITERATION})" >> {LOG_FILE}
hb_heartbeat "agent-returned" "re-implement agent failed (iteration {ITERATION})"
```

On success:
```bash
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|IMPLEMENT|re-implement|done|{OUTCOME}, iteration {ITERATION}" >> {LOG_FILE}
hb_heartbeat "agent-returned" "re-implement agent done — {OUTCOME} (iteration {ITERATION})"
hb_heartbeat "phase-transition" "IMPLEMENT → RE-VERIFY"
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

- **PASS** → run Step 4.6 (Wiki Maintenance) to incorporate any new errata from re-implementation, then proceed to Step 5e.
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

## Step 6 — Report

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
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|META|retro-trigger|fail|/ticket-retro invocation failed — continuing" >> {LOG_FILE}
```

**Skipped (clean run):**
```bash
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|META|retro-trigger|skip|clean run, retro skipped" >> {LOG_FILE}
hb_decision "retro-trigger" "skip" "clean run, retro skipped"
```

Do NOT block the pipeline on retro failure — the ticket outcome is already determined.

### Step 6b — Write outcome and report

Write the pipeline outcome event:
```bash
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|META|outcome|info|complete" >> {LOG_FILE}
hb_decision "pipeline-outcome" "fired" "pipeline complete" '{"outcome":"complete","iterations":"{ITERATION}","merged":"{MERGED}"}'
```

```
## {TICKET-ID} — pipeline complete

| Phase | Result |
|---|---|
| Autonomy | {manual\|auto\|semi-auto} |
| Appraise | {simple|complex}, {N} files traced |
| Exec | {simple-fix | openspec: <name>} |
| Gate | {auto-approved | held} |
| Implement | {Smooth|Rough|Hard}, PRs: {URLs} |
| Wiki Maintenance | {N} errata incorporated |
| Verify | {✅ PASS ({VERIFY_ATTEMPTS} attempts)|❌ FAIL after {VERIFY_ATTEMPTS}|skipped} |
| PR Review | {✅|⚠️}, merged: {yes\|auto-merged (semi-auto, simple+Smooth)\|no} |
| PR iteration re-verify | {VERIFY_RETRIES} retries across iterations |
| Iterations | {ITERATION} |
| Retro | {triggered → ~/.claude/state/ticket-retro/proposals/{date}-retro.md \| skipped (clean run)} |

**Local:** {ticket-dir}
**Linear:** {ticket URL}

{If merged: ✅ All done.}
{If gaps after max iterations: ⚠️ PR still has unaddressed requirements after 3 rounds — check the PR comments and intervene manually.}
{If mismatch: ⚡ Complexity prediction missed — appraisal gap recorded in claude-mem.}
```
