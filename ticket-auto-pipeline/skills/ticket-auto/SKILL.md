---
name: ticket-auto
description: Fully autonomous ticket pipeline — appraise, exec, implement, PR review, merge. Thin stateless router that dispatches to per-phase agents. No inline LLM reasoning between phases. Requires zero user input beyond the ticket ID. Stops only for complex tickets at the approve gate. Supports `--branch <name>` for explicit branch targeting (precedence: flag → parent epic directive → default). Use when the user says "/ticket-auto <ID>", "auto <ID>", "process ticket <ID>", or "run ticket <ID> end to end".
---

# Ticket Auto — Thin Dispatch Router

Thin stateless router. Reads pipeline log state via `detect-resume.sh`, dispatches to the correct phase agent or bash gate, waits for completion, re-reads state, and routes again. **Zero inline LLM reasoning between phases** — every conditional is a deterministic bash comparison.

## Pipeline Preamble

Follow the pipeline preamble in `~/.claude/skills/lib/skill-preamble.md` with parameters: TICKET_ID=<from args>, PHASE=none, FROM_FLAG=none, HAS_LINEAR_ACCESS=true, LINEAR_OPS=get_issue,get_comments,save_comment, HAS_GUARD=true, EXTRA_GUARD=validate-env, HAS_PROJECT_CONTEXT=false, HAS_LOGGING=false, HAS_HEARTBEAT=false, HAS_STEP_DISPATCH=true, HAS_TASK_TRACKER=false

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
  hb-wrap.sh retry "get-issue" "fail" "get_issue failed (exit ${_rc})" \
    "{\"command\":\"get_issue\",\"ticket\":\"{TICKET-ID}\",\"exit_code\":\"${_rc}\",\"error_snippet\":\"$(echo "$_snippet" | tr '"' "'"  | tr '\n' ' ')\"}"
  # Handle failure per-step (report or stop as appropriate)
fi
```

**get_comments failure pattern:**
```bash
_raw=$(bash -c "source ~/.claude/skills/lib/linear-api.sh; get_comments '{TICKET-ID}'" 2>&1)
_rc=$?
if [ $_rc -ne 0 ]; then
  hb-wrap.sh retry "get-comments" "fail" "get_comments failed (exit ${_rc})" \
    "{\"command\":\"get_comments\",\"ticket\":\"{TICKET-ID}\",\"exit_code\":\"${_rc}\"}"
fi
```

**jq extraction failure pattern:** When `jq` fails to extract a field from a Linear API response, capture it before stopping:
```bash
_field=$(echo "$_raw" | jq -r '.fieldName' 2>&1)
if [ $? -ne 0 ] || [ "$_field" = "null" ]; then
  hb-wrap.sh retry "jq-parse" "fail" "jq extraction failed for fieldName" \
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
  hb-wrap.sh retry "flow-sh" "fail" "flow.sh {trigger} failed (exit ${_rc})" \
    "{\"trigger\":\"{trigger}\",\"exit_code\":\"${_rc}\",\"ticket\":\"{TICKET-ID}\",\"error_type\":\"${_error_type}\"}"
fi
```

**API telemetry pattern:** For read operations where elapsed time matters, wrap with `hb_api`:
```bash
_t0=$(date +%s)
_raw=$(bash -c "source ~/.claude/skills/lib/linear-api.sh; get_issue '{TICKET-ID}'" 2>&1)
_rc=$?
_elapsed=$(( $(date +%s) - _t0 ))
hb-wrap.sh api "get-issue" "$( [ $_rc -eq 0 ] && echo ok || echo fail )" \
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

# Resolve --from-planned flag: set when fleetd/fleet-controller dispatches
# a planner-generated ticket. Used by the feedback writer to emit
# META|planner-feedback entries to the pipeline log.
if echo "{TICKET_ARG}" | grep -qw '\-\-from-planned'; then
  FROM_PLANNED="true"
else
  FROM_PLANNED="false"
fi

# Resolve --branch <name> for explicit branch targeting.
# Precedence: --branch flag → parent epic directive → config default.
# Validated by branch-resolve.sh's _validate_branch_name (same charset as directive).
BRANCH_FLAG=""
if echo "{TICKET_ARG}" | grep -q '\-\-branch'; then
  BRANCH_FLAG=$(echo "{TICKET_ARG}" | sed -n 's/.*--branch \([^ ]*\).*/\1/p')
fi

# Strip flags from arg to get the bare ticket ID
TICKET_ID=$(echo "{TICKET_ARG}" | sed 's/--semi-auto//;s/--auto//;s/--manual//;s/--from-planned//;s/--branch [^ ]*//' | tr -s ' ' | xargs)
```

Set `{AUTONOMY}` and `{TICKET_ID}` — used throughout the pipeline.

### Initialize heartbeat log early

The heartbeat log must exist before preflight (Step 0.4) so failures leave a trace. The pipeline log stays at Step 0.6 (dashboard needs it).

```bash
mkdir -p ./logs
HB_LOG_FILE="$PWD/logs/{TICKET-ID}-heartbeat.log"
~/.claude/skills/lib/hb-wrap.sh
source ~/.claude/skills/lib/capture-transcript.sh
export HB_LOG_FILE="$HB_LOG_FILE"
hb_init
# Idempotency guards: skip if already written (prevents duplication on resume)
if ! grep -q '|heartbeat|pipeline-start|' "$HB_LOG_FILE" 2>/dev/null; then
  hb-wrap.sh heartbeat "pipeline-start" "pipeline starting — autonomy={AUTONOMY}, from-planned={FROM_PLANNED}, ticket={TICKET-ID}"
fi
if ! grep -q '|decision|autonomy-resolution|' "$HB_LOG_FILE" 2>/dev/null; then
  hb-wrap.sh decision "autonomy-resolution" "fired" "autonomy set to {AUTONOMY}" '{"mode":"{AUTONOMY}"}'
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
    "source ~/.claude/skills/lib/linear-api.sh; linear_graphql '{\"query\":\"query{teams{nodes{id name}}}\"}'" 2>/dev/null || true)
  team_count=$(echo "$teams" | jq '.data.teams.nodes | length' 2>/dev/null || true)
  if [ -z "$team_count" ] || ! [[ "$team_count" =~ ^[0-9]+$ ]]; then
    echo "Preflight failed: Linear teams query failed — check LINEAR_API_KEY and network connectivity"; exit 1
  fi
  [ "$team_count" -eq 1 ] || { echo "Multiple Linear teams — set LINEAR_TEAM_ID"; exit 1; }
  TEAM_ID=$(echo "$teams" | jq -r '.data.teams.nodes[0].id')
fi

SENTINEL="$SENTINEL_DIR/validated-${TEAM_ID}"
```

**Warm hit** — sentinel exists and hash matches: skip validation.
```bash
if [ -f "$SENTINEL" ] && grep -q "^sm_hash=${SM_HASH}$" "$SENTINEL" 2>/dev/null; then
  echo "Preflight: sentinel valid — skipping Linear config check"
  hb-wrap.sh gate "preflight" "ok" "sentinel valid, skipping config check"
else
  # Cold run — run full validation
  _validate_sh="${HOME}/.claude/skills/ticket-flow/validate-linear-config.sh"
  [ -f "$_validate_sh" ] || _validate_sh=$(find "${HOME}/.claude/plugins/cache" -name "validate-linear-config.sh" -path "*/ticket-auto-pipeline/*/validate-linear-config.sh" 2>/dev/null | sort | tail -1)
  bash "$_validate_sh" "$TEAM_ID" || {
    echo "Preflight failed: Linear config validation error. Fix the team config and retry." >&2
    hb-wrap.sh gate "preflight" "fail" "Linear config validation failed" "{\"team_id\":\"$TEAM_ID\"}"
    exit 1
  }
  hb-wrap.sh gate "preflight" "ok" "Linear config validated" "{\"team_id\":\"$TEAM_ID\"}"
fi
```

**API key check** — always verify connectivity:
```bash
me=$(bash -c "source ~/.claude/skills/lib/linear-api.sh; get_me" 2>&1) || {
  echo "Preflight failed: Linear API key unset or rejected (exit 4). Set LINEAR_API_KEY." >&2
  hb-wrap.sh gate "preflight" "fail" "Linear API key rejected" "{\"exit_code\":\"4\"}"
  exit 4
}
echo "Linear: API key (direct GraphQL) — authenticated as $(echo "$me" | jq -r '.name // "unknown"')"
hb-wrap.sh source "linear-auth" "ok" "authenticated as $(echo "$me" | jq -r '.name // "unknown"')"
```

---

## Step 0.5 — Branch resolution + project context

### 0.5a — Resolve branch context

Resolve branch decisions deterministically via `branch-resolve.sh`. This MUST run before
Step 0.6 (pipeline log init) so the `META|branch-context` entry lands before the first
agent spawn — crash at any later point recovers the decision.

The precedence chain is: `--branch` CLI flag → parent epic directive → config default.

```bash
source ~/.claude/skills/lib/branch-resolve.sh

# Build resolve command — include --branch only if set in Step 0.1
BRANCH_ARGS="{TICKET_ID}"
[ -n "{BRANCH_FLAG}" ] && BRANCH_ARGS="$BRANCH_ARGS --branch {BRANCH_FLAG}"

BRANCH_OUTPUT=$(resolve_branch_context $BRANCH_ARGS 2>&1) || {
  _rc=$?
  if echo "$BRANCH_OUTPUT" | grep -q "BRANCH_DIRECTIVE_INVALID"; then
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|META|gate-stop|fail|BRANCH_DIRECTIVE_INVALID" >> {LOG_FILE}
    hb_gate "branch-context" "fail" "BRANCH_DIRECTIVE_INVALID" "{\"ticket\":\"{TICKET_ID}\"}"
    exit 1
  fi
  # Non-zero for other reasons (API error, etc.) — also stop
  echo "$BRANCH_OUTPUT" >&2
  exit 2
}

# Parse BRANCH_CONTEXT_RESULT block
TICKET_BRANCH=$(echo "$BRANCH_OUTPUT" | sed -n 's/^[[:space:]]*TICKET_BRANCH:[[:space:]]*//p')
BASE_BRANCH=$(echo "$BRANCH_OUTPUT" | sed -n 's/^[[:space:]]*BASE_BRANCH:[[:space:]]*//p')
INTEGRATION_BRANCH=$(echo "$BRANCH_OUTPUT" | sed -n 's/^[[:space:]]*INTEGRATION_BRANCH:[[:space:]]*//p')
BRANCH_SOURCE=$(echo "$BRANCH_OUTPUT" | sed -n 's/^[[:space:]]*BRANCH_SOURCE:[[:space:]]*//p')
UAT_POLICY=$(echo "$BRANCH_OUTPUT" | sed -n 's/^[[:space:]]*UAT_POLICY:[[:space:]]*//p')
MERGE_POLICY=$(echo "$BRANCH_OUTPUT" | sed -n 's/^[[:space:]]*MERGE_POLICY:[[:space:]]*//p')
```

### 0.5b — Write branch-context to pipeline log

Write immediately after resolution, before any agent spawn. The semicolon grammar
(`base=<>;integration=<>;source=<>;ticket=<>;uat-policy=<>;merge-policy=<>`) is parsed by
`detect-resume.sh` on crash-resume. Each field is appended in the order it was added so logs
written before that field existed still parse — every older prefix form remains valid.

```bash
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|META|branch-context|info|base=${BASE_BRANCH};integration=${INTEGRATION_BRANCH};source=${BRANCH_SOURCE};ticket=${TICKET_BRANCH};uat-policy=${UAT_POLICY};merge-policy=${MERGE_POLICY}" >> {LOG_FILE}
hb_gate "branch-context" "ok" "branch decision recorded" \
  "{\"base\":\"${BASE_BRANCH}\",\"integration\":\"${INTEGRATION_BRANCH}\",\"source\":\"${BRANCH_SOURCE}\",\"ticket\":\"${TICKET_BRANCH}\",\"uat_policy\":\"${UAT_POLICY}\",\"merge_policy\":\"${MERGE_POLICY}\"}"
```

### 0.5c — Detect project context

Read `CLAUDE.md` and extract ALL available project-context fields: `{REPOS_ROOT}`, `{ISSUE_PREFIX}`, `{BE_SERVICES}`, `{WIKI_ROOT}`, `{BE_TEST_CMD}`, `{BE_TEST_RUNNER}`, `{FE_TEST_CMD}`, `{LOCAL_URL}`, `{UAT_URL}`, `{SLACK_CHANNEL}`.

After extraction, write the env file that sub-agents source for project context:

```bash
source ~/.claude/skills/lib/spawn-helper.sh
source ~/.claude/skills/lib/phase-inspector.sh
spawn_write_env \
  TICKET_ID="{TICKET_ID}" \
  REPOS_ROOT="{REPOS_ROOT}" \
  ISSUE_PREFIX="{ISSUE_PREFIX}" \
  BE_SERVICES="{BE_SERVICES}" \
  WIKI_ROOT="{WIKI_ROOT}" \
  BE_TEST_CMD="{BE_TEST_CMD}" \
  BE_TEST_RUNNER="{BE_TEST_RUNNER}" \
  FE_TEST_CMD="{FE_TEST_CMD}" \
  LOCAL_URL="{LOCAL_URL}" \
  UAT_URL="{UAT_URL}" \
  SLACK_CHANNEL="{SLACK_CHANNEL}" \
  FROM_PLANNED="{FROM_PLANNED}" \
  BASE_BRANCH="${BASE_BRANCH}" \
  INTEGRATION_BRANCH="${INTEGRATION_BRANCH}" \
  TICKET_BRANCH="${TICKET_BRANCH}" \
  UAT_POLICY="${UAT_POLICY}" \
  AUTONOMY="{AUTONOMY}" \
  MERGE_POLICY="${MERGE_POLICY}"
```

This MUST run before Step 0.6 (pipeline log init) and before Step 1 (first agent spawn). The env file is needed by every `spawn_agent_pre` call — sub-agents source it via `source /tmp/ticket-auto-{TICKET_ID}-env.sh`. `AUTONOMY` and `MERGE_POLICY` are what `ticket-pr-review` Step 6b reads to decide whether it may merge a passing PR directly or must leave it for a human — see [Auto-merge logic](#auto-merge-logic) below, which applies the same `AUTONOMY` rule at the router level.

---

## Step 0.6 — Initialize pipeline log

Initialize the pipeline log and launch the dashboard (heartbeat log already initialized after Step 0.1):

```bash
mkdir -p ./logs
LOG_FILE="$PWD/logs/{TICKET-ID}-pipeline.log"
CLAUDE_LOG_FILE="$PWD/logs/{TICKET-ID}-claude.log"
touch "$LOG_FILE"
cl_init
YELLOW=$(tput setaf 3); BOLD=$(tput bold); RESET=$(tput sgr0)
if [ -n "$TMUX" ]; then
  # Check for an existing dashboard pane for this ticket before spawning another —
  # every resume would otherwise stack a new pane on top of prior ones (R13).
  if pgrep -f "dashboard.py $LOG_FILE" >/dev/null 2>&1; then
    echo "${BOLD}${YELLOW}(Dashboard already running for {TICKET-ID} — skipping duplicate pane.)${RESET}"
  else
    tmux split-window -h "python3 ~/.claude/skills/ticket-auto/dashboard.py $LOG_FILE; read"
    echo "${BOLD}${YELLOW}(Dashboard opened in right pane.)${RESET}"
  fi
else
  echo "${BOLD}${YELLOW}Dashboard ready. In a second terminal run:${RESET}"
  echo "${BOLD}${YELLOW}  python3 ~/.claude/skills/ticket-auto/dashboard.py $LOG_FILE${RESET}"
fi
```

Log the resolved autonomy mode immediately after dashboard launch. Guard the write so a
resume doesn't silently re-append (or silently switch modes mid-pipeline after gate
decisions were already made under the old mode) — an explicit `mode-change` event is
logged instead when the flag differs from what's recorded (R12):
```bash
_recorded_autonomy=$(grep '^[^|]*|META|autonomy|info|' {LOG_FILE} 2>/dev/null | tail -1 | cut -d'|' -f5-)
if [ -z "$_recorded_autonomy" ]; then
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|META|autonomy|info|{AUTONOMY}" >> {LOG_FILE}
elif [ "$_recorded_autonomy" != "{AUTONOMY}" ]; then
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|META|mode-change|warn|{AUTONOMY} (was $_recorded_autonomy)" >> {LOG_FILE}
fi
# Log from-planned provenance — idempotent (written once, never changed).
# fleet-feedback.sh reads this to determine whether to expect META|planner-feedback entries.
if ! grep -q '^[^|]*|META|from-planned|' {LOG_FILE} 2>/dev/null; then
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|META|from-planned|info|{FROM_PLANNED}" >> {LOG_FILE}
fi
hb-wrap.sh gate "phase-transition" "ok" "START → APPRAISE"
```

### Step 0.65 — Exit finalizer (RLVR Phase 3)

Every exit path in the router MUST call `pipeline-finalize.sh` to run post-mortem analysis and write `META|outcome`. This replaces the bash trap approach (which cannot persist across separate Bash tool calls in the harness execution model).

**Usage pattern at every exit point:**
```bash
bash ~/.claude/skills/lib/pipeline-finalize.sh "{TICKET_ID}" <exit-code> "{LOG_FILE}" || true
exit <exit-code>
```

`pipeline-finalize.sh` handles: postmortem analysis (fail-soft, timeout 60s), outcome derivation from log evidence (not exit code alone), and tail-check idempotency (F10: only skips if outcome IS the last log line — prevents stale outcomes from crash-resume blocking fresh writes).

**Covered exit paths:** gate-stop, gate-held, VERIFY_EXHAUSTED, PR_FEEDBACK_EXHAUSTED, router-error, STEP_6 completion. Fleet-killed pipelines use the fleet-side trigger (`fleet-controller/lib/fleet-intervene.sh`).

### :rotating_light: CRITICAL — Agent isolation requirement

**Every phase agent MUST run in an isolated Agent invocation, never inline.** The `Skill` tool runs skills INLINE in the router's context window — it burns tokens on phase-internal details that the router should never see. The `Agent` tool spawns an isolated subagent that returns only its final result.

**Absolute rule:** After `spawn_agent_pre` produces `$_prompt`, you MUST use the `Agent` tool. You MUST NOT use the `Skill` tool for phase dispatch. The `Skill` tool is for running skills inline; the `Agent` tool is for spawning isolated subagents. Phase dispatch requires isolation.

If you use `Skill` instead of `Agent`, every phase's full context (code reads, file writes, test output, internal reasoning) burns tokens in the router's window. A 4-phase pipeline will consume 150k–300k tokens instead of ~15k for the router + per-agent summaries.

### Agent spawn template

Every agent spawn follows this 3-step pattern:

1. **Pre-spawn** — `spawn_agent_pre` prints the `AGENT_PROMPT` line. Capture it:
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
   `spawn_agent_pre` outputs a line starting with `AGENT_PROMPT=`. Everything after `AGENT_PROMPT=` is the exact prompt the agent needs.

2. **Spawn** — invoke the `Agent` tool with the prompt from `$_prompt`. Extract the text after `AGENT_PROMPT=` and pass it as the `prompt` parameter:
   ```
   Agent tool call:
     description: "<phase> agent for {TICKET-ID}"
     prompt: <content after AGENT_PROMPT= from step 1>
     subagent_type: "general-purpose"
   ```
   **NEVER use `Skill` tool here.** `Skill` runs inline and defeats isolation. Always `Agent` with `subagent_type: "general-purpose"`.

3. **Post-spawn** — `spawn_capture` persists agent output to `-{phase}-agent.log`, then `spawn_agent_post` writes done/fail log entries, stops pinger, and writes heartbeat transitions.

   **Hand the return over as a file, never as a quoted argument.** Write the
   agent's return verbatim into `/tmp/ticket-auto-{TICKET-ID}-agent-return.txt`
   using a **quoted** heredoc (`<<'AGENT_RETURN_EOF'` — the quotes are what stop
   the shell expanding `$`, backticks and `$(...)` inside the return), then pass
   the path. A return containing `"` or `$` interpolated into `RESULT="..."` is
   truncated at best and evaluated at worst:
   ```bash
   cat > /tmp/ticket-auto-{TICKET-ID}-agent-return.txt <<'AGENT_RETURN_EOF'
   <the agent's return text, verbatim and unmodified>
   AGENT_RETURN_EOF

   spawn_capture TICKET_ID={TICKET-ID} PHASE=<phase> RESULT_FILE=/tmp/ticket-auto-{TICKET-ID}-agent-return.txt [ATTEMPT=<n>]
   # On success:
   spawn_agent_post TICKET_ID={TICKET-ID} RESULT=done MSG="<result>" NEXT_PHASE=<next>
   # On failure (blocking):
   spawn_agent_post TICKET_ID={TICKET-ID} RESULT=fail MSG="<reason>"
   # On failure (non-blocking, e.g. document/wiki):
   FAIL_ACTION=warn-continue spawn_agent_post TICKET_ID={TICKET-ID} RESULT=fail MSG="<reason>"
   ```

   **Verdict phases (VERIFY, PR-REVIEW only)** — pass `VERDICT=<token>` so `spawn_agent_post`
   prepends a canonical token to `MSG` (`done|PASS — <result>`). This decouples
   `detect-resume.sh`'s resume grep from router free-text prose or emoji bytes. See
   [Verdict tokens](../../pipeline-log-format.md#verdict-tokens) for the full token table.
   ```bash
   spawn_agent_post TICKET_ID={TICKET-ID} RESULT=done VERDICT=PASS MSG="<result>" NEXT_PHASE=<next>
   spawn_agent_post TICKET_ID={TICKET-ID} RESULT=done VERDICT=WARN MSG="Verdict: ⚠️ <summary>" NEXT_PHASE=<next>
   ```

### Self-check after each spawn

Before proceeding to the next dispatch, verify:
- [ ] I used `Agent` tool (not `Skill`) for the phase agent
- [ ] I ran `spawn_agent_post` after the agent returned
- [ ] I re-ran `detect-resume.sh` to get fresh state

---

## Step 0.7 — State detection (direct bash invocation)

Resolve the `detect-resume.sh` path dynamically and invoke directly as bash — no Claude agent spawn. This replaces the old pattern of calling the `ticket-detect-resume` skill:

```bash
# Resolve detect-resume.sh path dynamically
DETECT_SH="$HOME/.claude/skills/ticket-detect-resume/detect-resume.sh"
if [ ! -f "$DETECT_SH" ]; then
  DETECT_SH=$(find "$HOME/.claude/plugins/cache" -name detect-resume.sh -path "*/ticket-detect-resume/*" 2>/dev/null | head -1)
fi
[ -z "$DETECT_SH" ] && { echo "detect-resume.sh not found"; exit 1; }
```

For every dispatch decision, re-run `detect-resume.sh` to get fresh state:

```bash
DETECT_OUTPUT=$(bash "$DETECT_SH" "{TICKET_ID}")
```

Parse the `DETECT_RESUME_RESULT` block and set all routing variables:
`{RESUME_STEP}`, `{APPRAISE_FROM}`, `{REPRODUCE_FROM}`, `{EXEC_FROM}`, `{IMPLEMENT_FROM}`, `{MAINTENANCE_FROM}`, `{DOCUMENT_FROM}`, `{VERIFY_FROM}`, `{PR_REVIEW_FROM}`, `{PR_ITERATE_FROM}`, `{TICKET_DIR}`, `{COMPLEXITY}`, `{AUTONOMY}`, `{ARTIFACT_TYPE}`, `{BRANCH}`, `{BASE_BRANCH}`, `{INTEGRATION_BRANCH}`, `{BRANCH_SOURCE}`, `{MERGE_POLICY}`, `{TICKET_TITLE}`, `{VERIFY_ATTEMPTS}`, `{VERIFY_LAST}`, `{ITERATION}`, `{RECONCILE_CYCLE}`, `{PR_FEEDBACK_CYCLE}`.

**If `RESUME_STEP = SCHEMA_MISMATCH`:**
Report the schema mismatch with log vs expected version numbers. Stop here.

**If `RESUME_STEP = GATE_STILL_HELD`:**
Report that the ticket is still held and requires the `approved` label. Stop here.

**If recovering (`RESUME_STEP ≠ STEP_1`):**
```bash
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|META|recovery|info|Resuming from {RESUME_STEP}" >> {LOG_FILE}
```

**Before the recovery log entry, rehydrate the branch env vars from `detect-resume.sh` output** — on a crash-recovery the router does not re-run `resolve_branch_context`. The branch decisions were written to `META|branch-context` at Step 0.5b and are now in the `DETECT_RESUME_RESULT` block as `BASE_BRANCH`, `INTEGRATION_BRANCH`, `BRANCH_SOURCE`,
`UAT_POLICY`, `MERGE_POLICY`. Write them back to the env file so sub-agents see branch vars even on resume — `AUTONOMY` is rehydrated too, from the same `DETECT_RESUME_RESULT` block (it comes from `META|autonomy|info|`, not branch-context, but needs the same resume-time re-export or a resumed pipeline's `ticket-pr-review` spawn would merge unconditionally):

```bash
if [ -n "{BASE_BRANCH}" ] || [ -n "{TICKET_BRANCH}" ]; then
  source ~/.claude/skills/lib/spawn-helper.sh
  spawn_write_env \
    TICKET_ID="{TICKET_ID}" \
    REPOS_ROOT="{REPOS_ROOT}" \
    ISSUE_PREFIX="{ISSUE_PREFIX}" \
    BE_SERVICES="{BE_SERVICES}" \
    WIKI_ROOT="{WIKI_ROOT}" \
    BE_TEST_CMD="{BE_TEST_CMD}" \
    BE_TEST_RUNNER="{BE_TEST_RUNNER}" \
    FE_TEST_CMD="{FE_TEST_CMD}" \
    LOCAL_URL="{LOCAL_URL}" \
    UAT_URL="{UAT_URL}" \
    SLACK_CHANNEL="{SLACK_CHANNEL}" \
    FROM_PLANNED="{FROM_PLANNED}" \
    BASE_BRANCH="{BASE_BRANCH}" \
    INTEGRATION_BRANCH="{INTEGRATION_BRANCH}" \
    TICKET_BRANCH="{TICKET_BRANCH}" \
    UAT_POLICY="{UAT_POLICY}" \
    AUTONOMY="{AUTONOMY}" \
    MERGE_POLICY="{MERGE_POLICY}"
fi
```

The guard `[ -n "{BASE_BRANCH}" ] || [ -n "{TICKET_BRANCH}" ]` skips this on
legacy logs that predate branch-context. `spawn_write_env` is idempotent — the
env file is regenerated with the same values.

---

## Prescan gate (Phase 2 — auto-invoke before appraise)

Before entering the dispatch loop, ensure prescan docs are fresh for each repo affected by this ticket. Prescan is an optimization, not a correctness requirement — failures or lock contention MUST NOT block the pipeline.

### Skip on late resume

Prescan only benefits the appraise phase — skip the entire gate when resuming at STEP_4
or later. Crash recovery mid-implement/verify/PR-review/report should not pay the
per-repo freshness-check cost on every resume:

```bash
case "{RESUME_STEP}" in
STEP_4 | STEP_4_5 | STEP_4_6 | STEP_5 | STEP_5_5 | STEP_6 | done)
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|MAINTENANCE|prescan|skip|resuming at {RESUME_STEP} — prescan skipped" >> {LOG_FILE}
  ;;
*)
  # Not a late resume — run the freshness gate below.
  ;;
esac
```

If `{RESUME_STEP}` matched the case above, skip the rest of this section entirely and go
straight to the Dispatch Loop.

### Identify affected repos

Primary: Derive the repo(s) this ticket touches from the project CLAUDE.md codebase map and ticket labels/description.

**Safety net — deterministic enumeration:** As a fallback, also scan all repos under `REPOS_ROOT`. The freshness gate is a cheap single-bash-call per repo (~10ms for `fresh`), so overscanning is harmless. This guarantees no repo is missed if the LLM misidentifies the affected set.

```bash
_derive_slug() { basename "$repo" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g'; }

# Deterministic enumeration of all repos under REPOS_ROOT.
# -type d excludes git-worktree ".git" *files* (worktree pointer files, e.g.
# under .ticket-auto/worktrees/**), which would otherwise resolve to bogus
# ancestor paths. %h is already the repo root (parent of the matched ".git"
# dir) — do not dirname() it again, that walks one level too high.
REPOS=()
while IFS= read -r -d '' repo_dir; do
  REPOS+=("$repo_dir")
done < <(find "$REPOS_ROOT" -maxdepth 3 -name ".git" -type d -printf '%h\0' 2>/dev/null || true)

# If no repos found, skip prescan entirely (nothing to scan)
if [ ${#REPOS[@]} -eq 0 ]; then
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|MAINTENANCE|prescan|skip|no repos found under REPOS_ROOT" >> {LOG_FILE}
fi
```

### Run freshness gate

For each repo under `REPOS_ROOT`:

```bash
eval $(bash "$HOME/.claude/skills/lib/prescan-check.sh" "$repo" --repos-root "$REPOS_ROOT")
```

Branch on status:

- **`fresh`**: Skip. Log nothing — overhead is one bash call per repo.
- **`stale`, `decayed`, or `missing`**: Attempt prescan spawn.
- **`missing` with `no_marker`**: First-time scan — full fan-out needed.

### Acquire lock and spawn (if stale/decayed/missing)

Use flock-based concurrency — non-blocking, skip on contention:

```bash
LOCK_FILE="$REPOS_ROOT/.ticket-auto/$slug/.lock"
mkdir -p "$(dirname "$LOCK_FILE")"
exec {lock_fd}>"$LOCK_FILE"
if flock -n "$lock_fd"; then
  # Lock acquired — proceed with prescan spawn
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|MAINTENANCE|prescan|waiting|$slug prescan triggered ($PRESCAN_STATUS)" >> {LOG_FILE}

  # Spawn using standard bracketed pattern
  _prompt=$(spawn_agent_pre \
    PHASE=MAINTENANCE STEP=prescan TICKET_ID={TICKET-ID} \
    SKILL=/ticket-prescan REPO="$repo" REPO_SLUG="$slug" CADENCE="$PRESCAN_STATUS" \
    DESCRIPTION="Refresh prescan docs for $slug ($PRESCAN_STATUS)" \
    INSTRUCTIONS="Run /ticket-prescan --from-auto on $repo. Cadence: $PRESCAN_STATUS.")

  AGENT_RESULT=$(Agent "$_prompt" \
    agentType="ticket-prescan-agent" \
    description="Prescan $slug ($PRESCAN_STATUS)")

  # Hand the return over as a file (quoted heredoc — see "Agent spawn template").
  cat > /tmp/ticket-auto-{TICKET-ID}-agent-return.txt <<'AGENT_RETURN_EOF'
<the prescan agent's return text, verbatim>
AGENT_RETURN_EOF

  spawn_capture TICKET_ID={TICKET-ID} PHASE=MAINTENANCE RESULT_FILE=/tmp/ticket-auto-{TICKET-ID}-agent-return.txt

  # Judge success by the PRESCAN_RESULT block's per-repo marker, not spawn_capture's
  # exit code (spawn_capture is a log write and succeeds regardless of agent outcome).
  if grep -q "$slug: scanned" /tmp/ticket-auto-{TICKET-ID}-agent-return.txt; then
    spawn_agent_post TICKET_ID={TICKET-ID} RESULT=done \
      MSG="$slug prescan complete: $PRESCAN_STATUS → fresh" NEXT_PHASE=APPRAISE
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|MAINTENANCE|prescan|done|$slug prescan complete" >> {LOG_FILE}
  else
    FAIL_ACTION=warn-continue spawn_agent_post TICKET_ID={TICKET-ID} RESULT=fail \
      MSG="$slug prescan failed (non-blocking)"
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|MAINTENANCE|prescan|fail|$slug prescan failed" >> {LOG_FILE}
  fi

  flock -u "$lock_fd"
else
  # Lock contended — skip, proceed to appraise
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|MAINTENANCE|prescan|skip|$slug locked by another process" >> {LOG_FILE}
fi
```

### Token-tracker label

The token-tracker hook labels prescan spawns as `PRESCAN` in the `META|tokens` free-form label field. The spawn-meta file written by `spawn_agent_pre` sets `PHASE=MAINTENANCE` which the hook reads. The `PRESCAN` label is informational only — NOT a resumable pipeline phase.

### Non-blocking invariant

Prescan failure, timeout, or lock contention SHALL NEVER prevent the pipeline from proceeding. On any failure path, log the issue and continue to the dispatch loop. Appraise Step 3a handles missing/stale prescan docs via the fallthrough chain: INDEX.md → claude-mem corpus → WIKI_ROOT → Path B from-scratch.

---

## Dispatch Loop

After state detection, enter the stateless dispatch loop. Re-run `detect-resume.sh` before each dispatch decision to get current state from the pipeline log.

**At every agent dispatch site:** Run `spawn_agent_pre` → spawn via `Agent` tool (NOT `Skill`) → `spawn_capture` → `spawn_agent_post` → re-run `detect-resume.sh`. See "Agent spawn template" above for the exact 3-step pattern.

**`Skill` tool is BANNED at all agent dispatch sites.** The `Skill` tool runs skills inline in the router's context. The `Agent` tool spawns isolated subagents. Every phase dispatch MUST use `Agent`.

### Dispatch table

| RESUME_STEP | Action | Type |
|-------------|--------|------|
| `STEP_1` | Spawn `ticket-appraise` agent | Agent |
| `STEP_1_5` | Spawn `ticket-reproduce` agent | Agent |
| `STEP_2` | Spawn `ticket-appraise-exec` agent | Agent |
| `STEP_2_5` | Run `bash gate-check.sh --mode entry` | **Bash only** |
| `STEP_3` | Alias for `STEP_2_5` — run `bash gate-check.sh --mode entry` | **Bash only** |
| `STEP_3_5` | Spawn `ticket-gate-reconcile` agent | Agent |
| `STEP_4` | Spawn `ticket-implement` agent, run `return-completeness-check.sh` (openspec tickets only), then `outcome-label-check.sh` | Agent + Bash |
| `STEP_4_5` | Verify retry sub-loop (see below) | Router-managed loop |
| `STEP_4_6` | PR review + iteration sub-loop (see below) | Router-managed loop |
| `STEP_5` | Spawn `ticket-document`, then `wiki-maintenance` (sequential) | Agent |
| `STEP_5_5` | PR comment reconciliation | Agent |
| `STEP_6` | Retro check + optional `ticket-retro` + outcome write | Bash + Agent |
| `done` | Exit 0 | — |
| `*` (unknown) | Log error, exit 1 | — |

### STEP_1 — Appraise

**Before the agent spawn, claim the ticket immediately** so Linear reflects that work has started. Complexity defaults to `simple` — the appraise agent corrects it in Step 4 when the real score is known. `flow.sh` is idempotent: re-calling with the same params is a no-op.

```bash
_flow_sh="${HOME}/.claude/skills/ticket-flow/flow.sh"
[ -f "$_flow_sh" ] || _flow_sh=$(find "${HOME}/.claude/plugins/cache" -name "flow.sh" -path "*/ticket-auto-pipeline/*/skills/ticket-flow/flow.sh" 2>/dev/null | sort | tail -1)

bash "$_flow_sh" "{TICKET-ID}" "appraise-start" --data complexity=simple 2>&1
_rc=$?
if [ $_rc -ne 0 ]; then
  hb-wrap.sh retry "flow-sh" "fail" "flow.sh appraise-start failed (exit ${_rc})" \
    "{\"trigger\":\"appraise-start\",\"exit_code\":\"${_rc}\",\"ticket\":\"{TICKET-ID}\"}"
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|META|flow-error|fail|exit ${_rc}: appraise-start" >> {LOG_FILE}
  bash ~/.claude/skills/lib/pipeline-finalize.sh "{TICKET_ID}" 1 "{LOG_FILE}" || true
  exit 1
fi
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|META|ticket-claimed|info|{TICKET-ID} claimed → Todo" >> {LOG_FILE}
hb-wrap.sh gate "ticket-claimed" "ok" "ticket claimed — Todo + claimed label + assigned"
```

```
STEP=appraise PHASE=APPRAISE SKILL=/ticket-appraise FROM_STEP={APPRAISE_FROM}
DESCRIPTION="Investigate the ticket and produce complexity score"
INSTRUCTIONS="Follow the skill exactly."
NEXT_PHASE=APPRAISE
```

### STEP_1_5 — Reproduce (bug tickets only)

```
STEP=reproduce PHASE=REPRODUCE SKILL=/ticket-reproduce FROM_STEP={REPRODUCE_FROM}
DESCRIPTION="Reproduce the bug and capture evidence"
INSTRUCTIONS="Follow the skill exactly."
NEXT_PHASE=REPRODUCE
```

### STEP_2 — Appraise Exec

```
STEP=exec PHASE=EXEC SKILL=/ticket-appraise-exec FROM_STEP={EXEC_FROM}
DESCRIPTION="Create implementation artifacts (simple-fix.md or OpenSpec change)"
INSTRUCTIONS="Follow the skill exactly."
NEXT_PHASE=EXEC
```

### STEP_2_5 — Gate Check (bash only, no agent)

Run `gate-check.sh` in entry mode — deterministic bash, no Claude agent involved:

```bash
_gate_sh="${HOME}/.claude/skills/lib/gate-check.sh"
bash "$_gate_sh" "{TICKET_ID}" "{LOG_FILE}" "{HB_LOG_FILE}" --mode entry
_gate_rc=$?

if [ $_gate_rc -eq 0 ]; then
  # Auto-approved — loop back to state detection
  hb-wrap.sh gate "phase-transition" "ok" "GATE → IMPLEMENT"
elif [ $_gate_rc -eq 1 ]; then
  # Held — fleet controller will detect, stop here
  echo "Gate held for {TICKET_ID}. Add 'approved' label to proceed."
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|META|gate-held|info|held" >> {LOG_FILE}
  bash ~/.claude/skills/lib/pipeline-finalize.sh "{TICKET_ID}" 0 "{LOG_FILE}" || true
  exit 0
else
  # Gate-stop (exit 2) — structural failure
  echo "Gate-stop fired for {TICKET_ID}. Check pipeline log for code."
  bash ~/.claude/skills/lib/pipeline-finalize.sh "{TICKET_ID}" 1 "{LOG_FILE}" || true
  exit 1
fi
```

### STEP_3_5 — Gate Reconcile

Spawned only when a held ticket is re-approved. **Before dispatching**, check
`RECONCILE_CYCLE` from `detect-resume.sh`. Caps at 3, matching the
`VERIFY_ATTEMPTS`/`ITERATION`/`PR_FEEDBACK_CYCLE` cap pattern — otherwise a
hold → re-approve → re-hold cycle could repeat without bound:

```bash
if [ "{RECONCILE_CYCLE}" -ge 3 ]; then
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|META|gate-stop|fail|RECONCILE_EXHAUSTED" >> "{LOG_FILE}"
  echo "Gate reconciliation exhausted after 3 cycles for {TICKET_ID}. Needs human review."
  bash ~/.claude/skills/lib/pipeline-finalize.sh "{TICKET_ID}" 1 "{LOG_FILE}" || true
  exit 1
fi
```

```
STEP=reconcile PHASE=GATE SKILL=/ticket-gate-reconcile
DESCRIPTION="Reconcile comments after gate hold and re-approval"
INSTRUCTIONS="Follow the skill exactly. Load context from env.sh, pipeline log, and artifact files."
NEXT_PHASE=GATE
```

### STEP_4 — Implement

Spawn implement agent. This phase overrides the generic post-spawn step: run
`spawn_capture` as usual, but insert `return-completeness-check.sh` **before**
`spawn_agent_post` — the gate must see the agent's returned work before the
router commits the phase as `done`.

**Pre-warming (openspec tickets):** For complex/openspec tickets, the implement
agent may time out during context loading before any work is done. When
`{ARTIFACT_TYPE}` is `openspec`, the pre-spawn step MUST load the artifact
into context before spawning the implement agent:

```bash
# Pre-warm: load artifact content into the agent's initial context
if [ "{ARTIFACT_TYPE}" = "openspec" ]; then
  # Read tasks.md and relevant files into the agent session to avoid
  # timeout during initial context loading
  _artifact_dir="$(dirname "{ARTIFACT_PATH}")"
  echo "Pre-warming implement agent: loading openspec artifact from $_artifact_dir"
fi
```

**Timeout guidance:** For openspec tickets, the implement agent requires at
least 10 minutes of context processing time. The router does not set the
agent timeout directly (harness-controlled), but pre-warming reduces the
risk of timeout during initial context load.

```
STEP=implement PHASE=IMPLEMENT SKILL=/ticket-implement FROM_STEP={IMPLEMENT_FROM}
EXTRA_FLAGS="--from-auto --mode extract"
DESCRIPTION="Implement the changes described in the artifact"
INSTRUCTIONS="Use Serena for all code navigation. For openspec tickets: first read tasks.md in full, then proceed task by task. Pre-warm by reading all task descriptions before starting implementation."
NEXT_PHASE=IMPLEMENT
```

```bash
# Hand the return over as a file (quoted heredoc — see "Agent spawn template").
cat > /tmp/ticket-auto-{TICKET-ID}-agent-return.txt <<'AGENT_RETURN_EOF'
<the implement agent's return text, verbatim>
AGENT_RETURN_EOF

spawn_capture TICKET_ID={TICKET-ID} PHASE=IMPLEMENT RESULT_FILE=/tmp/ticket-auto-{TICKET-ID}-agent-return.txt

# Phase-result parse (advisory, observe-only). Converts the agent's terminal
# === PHASE_RESULT === block into META|phase-result|info|{json} on the pipeline log.
# Runs after spawn_capture and before spawn_agent_post — the same insertion point as
# return-completeness-check.sh below, and before the phase inspector appends to the
# same capture file.
# Exit 1 (absent or malformed block → claimed_verdict=UNKNOWN) is a NORMAL outcome,
# not an error. Nothing routes on this channel in this increment, so a parser failure
# cannot halt a run. Hence `|| true`.
_prp_sh="${HOME}/.claude/skills/lib/phase-result-parse.sh"
bash "$_prp_sh" --phase IMPLEMENT \
  --return-file "./logs/{TICKET_ID}-implement-agent.log" \
  --log-file "{LOG_FILE}" >/dev/null 2>&1 || true

# Return-completeness gate — runs for all artifact types.
# Handles both openspec tasks.md and simple-fix.md Completion Checklist
# internally. Resolution order: tasks.md first, simple-fix.md fallback.
_rcc_sh="${HOME}/.claude/skills/lib/return-completeness-check.sh"
_rcc_out=$(bash "$_rcc_sh" "{TICKET_ID}" --repos-root "{REPOS_ROOT}" 2>/dev/null) || true
eval "$_rcc_out" 2>/dev/null || true
if [ "${RETURN_COMPLETENESS_STATUS:-complete}" != "complete" ]; then
  # Warn-only (Phase 1): log via gate-warn, never gate-stop. Does NOT
  # flip done->fail — the pipeline continues as if the phase were done.
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|META|gate-warn|info|RETURN_INCOMPLETE — ${REASON:-unknown} (unchecked=${UNCHECKED_COUNT:-?}/${TOTAL_COUNT:-?}, artifact=${ARTIFACT_TYPE:-?})" >> "{LOG_FILE}"
fi

# On success:
spawn_agent_post TICKET_ID={TICKET-ID} RESULT=done MSG="<result>" NEXT_PHASE=IMPLEMENT
# On failure (blocking):
spawn_agent_post TICKET_ID={TICKET-ID} RESULT=fail MSG="<reason>"
```

**Hard contract (D3):** whenever `return-completeness-check.sh` exits non-zero
in enforce mode (Phase 2+), the router MUST call `spawn_agent_post RESULT=fail`
— no code path may call `RESULT=done` on a non-zero exit once enforce mode is
active. This mirrors `gate-check.sh`'s existing exit-code contract. In Phase 1
(warn-only, current), the gate never changes `RESULT` — this note documents
the contract ahead of the Phase 2 flip, it does not yet apply.

After implement completes, always run outcome-label-check:
```bash
_outcome_sh="${HOME}/.claude/skills/lib/outcome-label-check.sh"
bash "$_outcome_sh" "{TICKET_ID}" "{LOG_FILE}"
```

Then emit planner feedback for planned tickets (no-op for unplanned):
```bash
_feedback_sh="${HOME}/.claude/skills/lib/planned-feedback-write.sh"
[ -f "$_feedback_sh" ] || _feedback_sh=$(find "${HOME}/.claude/plugins/cache" -name "planned-feedback-write.sh" -path "*/ticket-auto-pipeline/*/lib/planned-feedback-write.sh" 2>/dev/null | sort | tail -1)
if [ -f "$_feedback_sh" ]; then
  source "$_feedback_sh"
  planned_feedback_write "{TICKET_ID}" "{LOG_FILE}" || true
fi

# Phase inspector (RLVR Phase 1): post-IMPLEMENT advisory inspection.
# Assembles verifier context; if results exist, spawn guidance-extractor-agent.
# Uses standard spawn pattern — assemble_inspector_context produces INSTRUCTIONS,
# router spawns agent, then runs spawn_capture + spawn_agent_post.
source ~/.claude/skills/lib/phase-inspector.sh 2>/dev/null || true
_pi_out=$(assemble_inspector_context "IMPLEMENT" "{TICKET_ID}" "{LOG_FILE}") || true
if echo "$_pi_out" | grep -q '^INSPECTOR_INSTRUCTIONS='; then
  _pi_instructions=$(echo "$_pi_out" | awk '/^INSPECTOR_INSTRUCTIONS=/{sub(/^INSPECTOR_INSTRUCTIONS=/,""); found=1; print; next} found{print}')
  echo "PHASE_INSPECTOR_READY=IMPLEMENT"
else
  echo "PHASE_INSPECTOR_READY=skip"
fi
```

**If PHASE_INSPECTOR_READY is not "skip":** spawn the guidance-extractor-agent using the standard pattern:

```
STEP=phase-inspector-implement PHASE=IMPLEMENT SKILL=/guidance-extractor
EXTRA_FLAGS="--from-auto --mode extract"
DESCRIPTION="Phase inspector for IMPLEMENT"
INSTRUCTIONS=<_pi_instructions contents>
FAIL_ACTION=warn-continue
```

After the agent returns:

```bash
cat > /tmp/ticket-auto-{TICKET-ID}-agent-return.txt <<'AGENT_RETURN_EOF'
<the inspector agent's return text, verbatim>
AGENT_RETURN_EOF

# ATTEMPT=inspector puts this capture in append-with-separator mode. Without it
# the inspector's return overwrites the implement agent's at the same path
# (./logs/{TID}-implement-agent.log), destroying the parser's input.
spawn_capture TICKET_ID={TICKET-ID} PHASE=IMPLEMENT RESULT_FILE=/tmp/ticket-auto-{TICKET-ID}-agent-return.txt ATTEMPT=inspector
spawn_agent_post TICKET_ID={TICKET-ID} RESULT=done MSG="Phase inspector completed for IMPLEMENT" PHASE=IMPLEMENT STEP=phase-inspector-implement 2>/dev/null || true
```

Then transition from Ready → Review via implement-complete:
```bash
flow_sh="${HOME}/.claude/skills/ticket-flow/flow.sh"
[ -f "$flow_sh" ] || flow_sh=$(find "${HOME}/.claude/plugins/cache" -name "flow.sh" -path "*/ticket-auto-pipeline/*/skills/ticket-flow/flow.sh" 2>/dev/null | sort | tail -1)
if [ -z "$flow_sh" ]; then
  hb-wrap.sh retry "flow-sh" "fail" "flow.sh not found for implement-complete" \
    "{\"trigger\":\"implement-complete\",\"ticket\":\"{TICKET_ID}\",\"error_type\":\"resolution_failure\"}"
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|META|flow-error|fail|implement-complete: flow.sh not found" >> "{LOG_FILE}"
else
  bash "$flow_sh" "{TICKET_ID}" "implement-complete" 2>&1
  _rc=$?
  if [ $_rc -ne 0 ]; then
    _error_type=$( [ $_rc -eq 7 ] && echo "state_assertion" || echo "flow_error" )
    hb-wrap.sh retry "flow-sh" "fail" "flow.sh implement-complete failed (exit ${_rc})" \
      "{\"trigger\":\"implement-complete\",\"exit_code\":\"${_rc}\",\"ticket\":\"{TICKET_ID}\",\"error_type\":\"${_error_type}\"}"
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|META|flow-error|fail|exit ${_rc}: implement-complete" >> "{LOG_FILE}"
  fi
fi
```

### STEP_4_5 — Verify (with retry sub-loop)

The router manages the verify→implement→verify retry loop. The verify agent has a
**hard cap of 2 total attempts** (1 initial + 1 retry). After 2 failures, the pipeline
stops with VERIFY_EXHAUSTED.

**Before dispatching**, run a pre-spawn health check and export CLAUDE_LOG_FILE:

```bash
# Pre-spawn MCP health check — confirm Playwright and Linear MCP are reachable
# before spawning an agent that will inevitably fail without them.
_verify_mcp_ok=true
mcp__plugin_playwright_playwright__browser_navigate 2>/dev/null || _verify_mcp_ok=false
mcp__linear-server__get_issue 2>/dev/null || _verify_mcp_ok=false
if ! $_verify_mcp_ok; then
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|META|preflight|fail|VERIFY_PREFLIGHT_FAILED — MCP tools unreachable" >> "{LOG_FILE}"
  # Count as an attempt and proceed — if both attempts fail due to MCP,
  # VERIFY_EXHAUSTED will fire with a clear diagnostic.
fi

# Export CLAUDE_LOG_FILE for crash diagnostics — survives agent crashes
export CLAUDE_LOG_FILE="/tmp/ticket-auto-{TICKET-ID}-verify-$(date +%s).log"
```

**Before dispatching**, check `VERIFY_LAST` from `detect-resume.sh`. `VERIFY_LAST=fail` means
the pipeline crashed after a terminal verify FAIL but before the re-implement step ran —
resuming straight into verify would re-run against the same unfixed code. Dispatch
re-implement first in that case, not verify:

```bash
if [ "{VERIFY_LAST}" = "fail" ]; then
  # Dispatch re-implement (FROM_STEP={IMPLEMENT_FROM}) first, then fall through to verify below
else
  # Dispatch verify directly
fi
```

```
STEP=verify PHASE=VERIFY SKILL=/ticket-verify FROM_STEP={VERIFY_FROM}
EXTRA_FLAGS="--from-auto --mode extract"
DESCRIPTION="Run Playwright UAT verification"
INSTRUCTIONS="Follow the skill exactly. Use per-criterion checkpointing: after each criterion passes, write VERIFY|checkpoint|done|criterion-{N}-pass to LOG_FILE. If the agent crashes, resume from the last checkpoint — do not restart from criterion 1."
NEXT_PHASE=VERIFY
```

**After verify completes**, write the terminal entry with a canonical `VERDICT` token
(see [Verdict tokens](../../pipeline-log-format.md#verdict-tokens)) so PASS/FAIL never
depends on router prose, then re-run `detect-resume.sh` and check VERIFY_ATTEMPTS:

```bash
# Capture first. VERIFY retries, so ATTEMPT is mandatory here — without it the
# second attempt overwrites the first at ./logs/{TID}-verify-agent.log and the
# retry history is gone.
cat > /tmp/ticket-auto-{TICKET-ID}-agent-return.txt <<'AGENT_RETURN_EOF'
<the verify agent's return text, verbatim>
AGENT_RETURN_EOF

spawn_capture TICKET_ID={TICKET-ID} PHASE=VERIFY \
  RESULT_FILE=/tmp/ticket-auto-{TICKET-ID}-agent-return.txt \
  ATTEMPT=$(({VERIFY_ATTEMPTS} + 1))

# Phase-result parse (advisory, observe-only) — see STEP_4 for the full rationale.
# The parser takes the LAST block in the capture file, which is this attempt's.
_prp_sh="${HOME}/.claude/skills/lib/phase-result-parse.sh"
bash "$_prp_sh" --phase VERIFY \
  --return-file "./logs/{TICKET_ID}-verify-agent.log" \
  --log-file "{LOG_FILE}" >/dev/null 2>&1 || true

spawn_agent_post TICKET_ID={TICKET-ID} RESULT=done VERDICT=PASS MSG="<summary>" NEXT_PHASE=PR-REVIEW LOOP_BEARING=true  # on PASS
spawn_agent_post TICKET_ID={TICKET-ID} RESULT=fail VERDICT=FAIL MSG="<summary>" LOOP_BEARING=true                         # on FAIL

# Phase inspector (RLVR Phase 1): post-VERIFY advisory inspection.
# Assembles verifier context; if results exist, spawn guidance-extractor-agent.
# Non-blocking — runs before the retry/advance decision but does not affect it.
_pi_out=$(assemble_inspector_context "VERIFY" "{TICKET_ID}" "{LOG_FILE}" "IMPLEMENT") || true
if echo "$_pi_out" | grep -q '^INSPECTOR_INSTRUCTIONS='; then
  _pi_instructions=$(echo "$_pi_out" | awk '/^INSPECTOR_INSTRUCTIONS=/{sub(/^INSPECTOR_INSTRUCTIONS=/,""); found=1; print; next} found{print}')
  echo "PHASE_INSPECTOR_READY=VERIFY"
else
  echo "PHASE_INSPECTOR_READY=skip"
fi
```

**If PHASE_INSPECTOR_READY is not "skip":** spawn the guidance-extractor-agent:

```
STEP=phase-inspector-verify PHASE=VERIFY SKILL=/guidance-extractor
EXTRA_FLAGS="--from-auto --mode extract"
DESCRIPTION="Phase inspector for VERIFY"
INSTRUCTIONS=<_pi_instructions contents>
FAIL_ACTION=warn-continue
```

After the agent returns:

```bash
cat > /tmp/ticket-auto-{TICKET-ID}-agent-return.txt <<'AGENT_RETURN_EOF'
<the inspector agent's return text, verbatim>
AGENT_RETURN_EOF

# ATTEMPT=inspector — append, do not overwrite the verify agent's own capture.
spawn_capture TICKET_ID={TICKET-ID} PHASE=VERIFY RESULT_FILE=/tmp/ticket-auto-{TICKET-ID}-agent-return.txt ATTEMPT=inspector
spawn_agent_post TICKET_ID={TICKET-ID} RESULT=done MSG="Phase inspector completed for VERIFY" PHASE=VERIFY STEP=phase-inspector-verify 2>/dev/null || true
```

Then evaluate the verify verdict for retry/advance:

```bash
# If VERIFY fail AND VERIFY_ATTEMPTS < 2 (hard cap) → loop to re-implement
# Hard cap reduced from 3 to 2 — verify agent instability means retry #3
# rarely succeeds and just wastes tokens on crash-loops.
if grep -q '^[^|]*|VERIFY|verify|fail|' "{LOG_FILE}"; then
  if [ "{VERIFY_ATTEMPTS}" -ge 2 ]; then
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|META|gate-stop|fail|VERIFY_EXHAUSTED" >> "{LOG_FILE}"
    bash ~/.claude/skills/lib/pipeline-finalize.sh "{TICKET_ID}" 1 "{LOG_FILE}" || true
    exit 1
  fi
  # Re-implement with --from-auto, then outcome-check, then loop back to verify
fi
# If VERIFY PASS → proceed to STEP_4_6
```

### STEP_4_6 — PR Review (with iteration sub-loop)

The router manages the pr-review→pr-iterate→re-implement→verify→pr-review cycle.

```
STEP=pr-review PHASE=PR-REVIEW SKILL=/ticket-pr-review
DESCRIPTION="Review the PR for code quality and correctness"
INSTRUCTIONS="Follow the skill exactly. Return verdict: ✅ ✅, ⚠️, or ❌."
NEXT_PHASE=PR-REVIEW
```

**After PR review completes**, write the terminal entry with a canonical `VERDICT` token
mapped from the review's emoji verdict (see
[Verdict tokens](../../pipeline-log-format.md#verdict-tokens)) — this is what `ITERATION`
counts on, so it must never be skipped or left as free-text prose:

```bash
# Capture first. PR-REVIEW iterates, so ATTEMPT is mandatory — without it a
# second review cycle overwrites the first at ./logs/{TID}-pr-review-agent.log.
cat > /tmp/ticket-auto-{TICKET-ID}-agent-return.txt <<'AGENT_RETURN_EOF'
<the pr-review agent's return text, verbatim>
AGENT_RETURN_EOF

spawn_capture TICKET_ID={TICKET-ID} PHASE=PR-REVIEW \
  RESULT_FILE=/tmp/ticket-auto-{TICKET-ID}-agent-return.txt \
  ATTEMPT=$(({ITERATION} + 1))

# Phase-result parse (advisory, observe-only) — see STEP_4 for the full rationale.
# This is the last gate before merge, so it is the record most worth having; it is
# still observe-only, and the router's VERDICT token below remains what routes.
_prp_sh="${HOME}/.claude/skills/lib/phase-result-parse.sh"
bash "$_prp_sh" --phase PR-REVIEW \
  --return-file "./logs/{TICKET_ID}-pr-review-agent.log" \
  --log-file "{LOG_FILE}" >/dev/null 2>&1 || true

# ✅ → VERDICT=OK
# ⚠️ → VERDICT=WARN
# ❌ → VERDICT=BLOCK
spawn_agent_post TICKET_ID={TICKET-ID} RESULT=done VERDICT=<OK|WARN|BLOCK> MSG="Verdict: <emoji> <summary>" NEXT_PHASE=<next> LOOP_BEARING=true
```

**After spawn_agent_post**, run the phase inspector (RLVR Phase 1) — post-PR-REVIEW advisory inspection. Non-blocking:

```bash
_pi_out=$(assemble_inspector_context "PR-REVIEW" "{TICKET_ID}" "{LOG_FILE}" "IMPLEMENT VERIFY") || true
if echo "$_pi_out" | grep -q '^INSPECTOR_INSTRUCTIONS='; then
  _pi_instructions=$(echo "$_pi_out" | awk '/^INSPECTOR_INSTRUCTIONS=/{sub(/^INSPECTOR_INSTRUCTIONS=/,""); found=1; print; next} found{print}')
  echo "PHASE_INSPECTOR_READY=PR-REVIEW"
else
  echo "PHASE_INSPECTOR_READY=skip"
fi
```

**If PHASE_INSPECTOR_READY is not "skip":** spawn the guidance-extractor-agent:

```
STEP=phase-inspector-pr-review PHASE=PR-REVIEW SKILL=/guidance-extractor
EXTRA_FLAGS="--from-auto --mode extract"
DESCRIPTION="Phase inspector for PR-REVIEW"
INSTRUCTIONS=<_pi_instructions contents>
FAIL_ACTION=warn-continue
```

After the agent returns:

```bash
cat > /tmp/ticket-auto-{TICKET-ID}-agent-return.txt <<'AGENT_RETURN_EOF'
<the inspector agent's return text, verbatim>
AGENT_RETURN_EOF

# ATTEMPT=inspector — append, do not overwrite the pr-review agent's own capture.
spawn_capture TICKET_ID={TICKET-ID} PHASE=PR-REVIEW RESULT_FILE=/tmp/ticket-auto-{TICKET-ID}-agent-return.txt ATTEMPT=inspector
spawn_agent_post TICKET_ID={TICKET-ID} RESULT=done MSG="Phase inspector completed for PR-REVIEW" PHASE=PR-REVIEW STEP=phase-inspector-pr-review 2>/dev/null || true
```

Then evaluate verdict:

```bash
# ✅ (VERDICT=OK) → proceed to STEP_5 (Document + Wiki)
# ⚠️ (VERDICT=WARN) AND ITERATION < 3 → run gate-check.sh --mode reapprove, spawn pr-iterate → implement → outcome-check → implement-complete → verify → loop back to pr-review
# ❌ (VERDICT=BLOCK) OR ITERATION >= 3 → gate-stop
```

**PR iteration loop:**

```
STEP=pr-iterate PHASE=PR-REVIEW SKILL=/ticket-pr-iterate
DESCRIPTION="Iterate on PR feedback"
INSTRUCTIONS="Apply the requested changes from the PR review."
NEXT_PHASE=PR-REVIEW
```

### Auto-merge logic

After PR review ✅, check auto-merge eligibility. Both `auto` and `semi-auto` modes merge
(only `manual` never does); the outcome is read from the `META|outcome-label|info|` line
written by `outcome-label-check.sh` — the confirmed Linear label — not from the IMPLEMENT
terminal line, which never carries the Smooth/Rough/Hard value:

```bash
# Auto-merge guard: integration PRs must never be auto-merged.
# This is the second guard (the first is in epic_branch_open_pr itself).
# If this ticket's PR targets an epic integration branch, skip auto-merge.
if [ -n "{INTEGRATION_BRANCH}" ]; then
  _pr_head=$(gh pr view "$_pr_num" --json headRefName --jq '.headRefName' 2>/dev/null || true)
  if [ "$_pr_head" = "{INTEGRATION_BRANCH}" ]; then
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|META|pr-auto-merge|skip|INTEGRATION_PR_GUARD: $_pr_num is integration PR, not auto-merging" >> "{LOG_FILE}"
    _pr_num=""
  fi
fi

if { [ "{AUTONOMY}" = "auto" ] || [ "{AUTONOMY}" = "semi-auto" ]; } && [ "{COMPLEXITY}" = "simple" ]; then
  OUTCOME=$(grep '^[^|]*|META|outcome-label|info|' "{LOG_FILE}" | tail -1 | cut -d'|' -f5-)
  if [ "$OUTCOME" = "Smooth" ]; then
    _pr_num=$(grep '^[^|]*|PR-REVIEW|checkout-pr|done|' "{LOG_FILE}" | tail -1 | cut -d'|' -f5-)
    if [ -n "$_pr_num" ]; then
      gh pr merge "$_pr_num" --squash --auto || true
    fi
  fi
fi
```

### STEP_5 — Document + Wiki Maintenance

Sequential spawns (non-blocking — `FAIL_ACTION=warn-continue`):

```
STEP=document PHASE=MAINTENANCE SKILL=/ticket-document
DESCRIPTION="Generate ai-context.md documentation"
INSTRUCTIONS="Follow the skill exactly."
FAIL_ACTION=warn-continue
NEXT_PHASE=MAINTENANCE
```

```
STEP=wiki-maintenance PHASE=MAINTENANCE SKILL=/wiki-maintenance
DESCRIPTION="Process wiki errata and update documentation"
INSTRUCTIONS="Follow the skill exactly."
FAIL_ACTION=warn-continue
NEXT_PHASE=MAINTENANCE
```

### STEP_5_5 — PR Comment Reconciliation

**Before dispatching**, check `PR_FEEDBACK_CYCLE` from `detect-resume.sh`. Caps at 3,
matching the `VERIFY_ATTEMPTS`/`ITERATION` cap pattern — otherwise a single reviewer
leaving repeated new comments could cycle the pipeline indefinitely:

```bash
if [ "{PR_FEEDBACK_CYCLE}" -ge 3 ]; then
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|META|gate-stop|fail|PR_FEEDBACK_EXHAUSTED" >> "{LOG_FILE}"
  echo "PR feedback reconciliation exhausted after 3 cycles for {TICKET_ID}. Needs human review."
  bash ~/.claude/skills/lib/pipeline-finalize.sh "{TICKET_ID}" 1 "{LOG_FILE}" || true
  exit 1
fi
```

```
STEP=pr-reconcile PHASE=PR-REVIEW SKILL=/ticket-pr-iterate
DESCRIPTION="Reconcile PR comments from human reviewers"
INSTRUCTIONS="Check for new human comments on the open PR. Apply amend/push-back/clean logic."
NEXT_PHASE=PR-REVIEW
```

**After pr-reconcile completes**, write the terminal entry with a `cycle#N` counter so
`PR_FEEDBACK_CYCLE` (see `detect-resume.sh`) can track reconciliation rounds — without
this, the cap above never advances past 0:

```bash
spawn_agent_post TICKET_ID={TICKET-ID} RESULT=done MSG="cycle#$(({PR_FEEDBACK_CYCLE} + 1)) reconciled" NEXT_PHASE=PR-REVIEW LOOP_BEARING=true
```

### STEP_6 — Report

Retro auto-trigger check (bash only):
```bash
# Condition 1: did any gate-stop fire during this run?
if grep -q '|META|gate-stop|fail|' "{LOG_FILE}"; then
  NEEDS_RETRO=true
fi
# Condition 2: did the ticket NOT reach a successful outcome?
# Tested as the absence of positive success markers (verify PASS + PR-review ✅).
# The prior version tested the absence of the STEP_6 outcome-write marker below —
# that line's only writer is this same step, written after this check ran, so the
# condition was tautologically true on every run.
# PR-REVIEW's own Verdict tokens (pipeline-log-format.md) are OK/WARN/BLOCK, never
# PASS — PASS is VERIFY-only. The literal 'PASS' check below never matched a real
# PR-REVIEW success line, so this condition was true on every run regardless of
# outcome (false-positive retro trigger — GitHub #149).
if ! grep -q '^[^|]*|VERIFY|verify|done|PASS' "{LOG_FILE}" || ! grep -q '^[^|]*|PR-REVIEW|pr-review|done|OK' "{LOG_FILE}"; then
  NEEDS_RETRO=true
fi
# Condition 3: did any heartbeat fallback event fire?
# Fallback events signal degraded paths — missing tools, unconfigured services,
# path resolution failures. Even if the pipeline "succeeded," fallbacks mean
# something is drifting and needs attention.
if grep -q '|fallback|' "{HB_LOG_FILE}" 2>/dev/null; then
  NEEDS_RETRO=true
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|META|drift|warn|drift detected — heartbeat fallback events present" >> "{LOG_FILE}"
fi
# Condition 4: VERIFY_EXHAUSTED — verify phase exhausted all retries.
# Condition 1 covers this via gate-stop, but gate-stop lines can be written
# in agent sub-shells where the log write may not be visible to the router's
# file descriptor. Explicit check as a safety net.
if grep -q 'VERIFY_EXHAUSTED' "{LOG_FILE}" 2>/dev/null; then
  NEEDS_RETRO=true
fi
# Condition 5: VERIFY_FAIL — verify phase explicit failure.
# Same sub-shell visibility concern as Condition 4.
if grep -q '^[^|]*|VERIFY|verify|fail|' "{LOG_FILE}" 2>/dev/null; then
  NEEDS_RETRO=true
fi
```

If `NEEDS_RETRO=true`, spawn `ticket-retro` agent. Then release the worktree (non-fatal):

```bash
# Release worktree — non-fatal: a failed removal warns but never halts the pipeline.
# Ordered after STEP_5 (ticket-document + wiki-maintenance) so document agents still
# have access to the worktree for git diff/log operations.
if [ -n "${WORKTREE_ROOT:-}" ] && [ -f "$HOME/.claude/skills/lib/worktree.sh" ]; then
  source "$HOME/.claude/skills/lib/worktree.sh"
  release_worktree "{TICKET_ID}" || \
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|META|worktree-release|warn|release_worktree failed for {TICKET_ID}" >> "{LOG_FILE}"
fi

# META|outcome is written by pipeline-finalize.sh (Step 0.65) — called at
# every exit point (gate-stop, gate-held, exhaustion, router-error, STEP_6).
# Tail-check idempotency guard prevents double-writing on crash-resume.
```

### Default case — Unknown RESUME_STEP

```bash
echo "Unknown RESUME_STEP: {RESUME_STEP}" >&2
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|META|router-error|fail|Unknown RESUME_STEP: {RESUME_STEP}" >> "{LOG_FILE}"
bash ~/.claude/skills/lib/pipeline-finalize.sh "{TICKET_ID}" 1 "{LOG_FILE}" || true
exit 1
```

---

## Router invariants

1. **No inline LLM reasoning**: Every conditional between dispatch calls is a deterministic bash comparison (string equality, numeric comparison, file existence check).
2. **Stateless router**: All state lives in the pipeline log. The router re-reads it via `detect-resume.sh` before every dispatch decision.
3. **3-step spawn pattern at every dispatch site**: `spawn_agent_pre` → agent spawn → `spawn_capture` (saves agent return value to `-{phase}-agent.log`) → `spawn_agent_post`. Token-tracker SubagentStop hook captures token counts only — agent output text logging requires the explicit `spawn_capture` step. The agent's return is handed to `spawn_capture` as a **file** (`RESULT_FILE=`, written with a quoted heredoc), never interpolated into a quoted `RESULT="..."` argument.
7. **Phase results are observe-only**: `phase-result-parse.sh` runs at the three loop-bearing sites (IMPLEMENT, VERIFY, PR-REVIEW) between `spawn_capture` and `spawn_agent_post`, and only appends `META|phase-result|info|{json}` to the log. The router continues to route on its existing `RESULT=done|fail` and `VERDICT=` tokens. The parser emits no gate-stop code, and every call site is `|| true`-guarded, so a parser failure cannot halt a run. See [phase-result schema](../../docs/phase-result-schema.md).
4. **Sequential dispatch**: Agents are spawned one at a time. The dispatch loop guarantees only one agent is in flight at a time.
5. **Bash gates**: Gate decisions are deterministic bash scripts (`gate-check.sh`, `outcome-label-check.sh`), not Claude agents.
6. **Router-managed loops**: Verify retry and PR iteration loops are managed by the router tracking counters from the pipeline log, not by phase agents internally.

---

## Step trace

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
- [x] Step 2.5: Gate — {auto-approved|held: <reason>|gate-stop: <code>}
- [x] Step 4: Implement — {Smooth|Rough|Hard}
- [x] Step 4.5: Verify — {✅ PASS (N attempts)|❌ FAIL after N|skipped: no UI}
- [x] Step 4.6: PR review — {✅|⚠️|❌}, {N} iterations
- [x] Step 5: Document + Wiki — ai-context.md ({trivial|non-trivial}), {N} errata
- [x] Step 6: Report — retro check + worktree release + outcome
TRACE
```
