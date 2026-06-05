---
name: ticket-auto
description: Fully autonomous ticket pipeline — appraise, exec, implement, PR review, merge. Thin stateless router that dispatches to per-phase agents. No inline LLM reasoning between phases. Requires zero user input beyond the ticket ID. Stops only for complex tickets at the approve gate. Use when the user says "/ticket-auto <ID>", "auto <ID>", "process ticket <ID>", or "run ticket <ID> end to end".
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

---

## Step 0.5 — Detect project context

Read `CLAUDE.md` and extract ALL available project-context fields: `{REPOS_ROOT}`, `{ISSUE_PREFIX}`, `{BE_SERVICES}`, `{WIKI_ROOT}`, `{BE_TEST_CMD}`, `{FE_TEST_CMD}`, `{LOCAL_URL}`, `{UAT_URL}`, `{SLACK_CHANNEL}`.

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

### Agent spawn template

Every agent spawn follows this 3-step pattern:

1. **Pre-spawn** — `spawn_agent_pre` handles the waiting log entry, heartbeat pinger start, phase context file, cl_write handoff, and prints the full agent prompt:
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

2. **Spawn** — pass `$_prompt` to the phase-appropriate agent (e.g., `ticket-appraise` agent type).

3. **Post-spawn** — `spawn_capture` persists agent output to `-{phase}-agent.log`, then `spawn_agent_post` writes done/fail log entries, stops pinger, and writes heartbeat transitions:
   ```bash
   spawn_capture TICKET_ID={TICKET-ID} PHASE=<phase> RESULT="$AGENT_RESULT"
   # On success:
   spawn_agent_post TICKET_ID={TICKET-ID} RESULT=done MSG="<result>" NEXT_PHASE=<next>
   # On failure (blocking):
   spawn_agent_post TICKET_ID={TICKET-ID} RESULT=fail MSG="<reason>"
   # On failure (non-blocking, e.g. document/wiki):
   FAIL_ACTION=warn-continue spawn_agent_post TICKET_ID={TICKET-ID} RESULT=fail MSG="<reason>"
   ```

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
`{RESUME_STEP}`, `{APPRAISE_FROM}`, `{REPRODUCE_FROM}`, `{EXEC_FROM}`, `{IMPLEMENT_FROM}`, `{MAINTENANCE_FROM}`, `{DOCUMENT_FROM}`, `{VERIFY_FROM}`, `{PR_REVIEW_FROM}`, `{PR_ITERATE_FROM}`, `{TICKET_DIR}`, `{COMPLEXITY}`, `{AUTONOMY}`, `{ARTIFACT_TYPE}`, `{BRANCH}`, `{TICKET_TITLE}`, `{VERIFY_ATTEMPTS}`, `{ITERATION}`, `{RECONCILE_CYCLE}`, `{PR_FEEDBACK_CYCLE}`.

**If `RESUME_STEP = SCHEMA_MISMATCH`:**
Report the schema mismatch with log vs expected version numbers. Stop here.

**If `RESUME_STEP = GATE_STILL_HELD`:**
Report that the ticket is still held and requires the `approved` label. Stop here.

**If recovering (`RESUME_STEP ≠ STEP_1`):**
```bash
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|META|recovery|info|Resuming from {RESUME_STEP}" >> {LOG_FILE}
```

---

## Dispatch Loop

After state detection, enter the stateless dispatch loop. Re-run `detect-resume.sh` before each dispatch decision to get current state from the pipeline log.

### Dispatch table

| RESUME_STEP | Action | Type |
|-------------|--------|------|
| `STEP_1` | Spawn `ticket-appraise` agent | Agent |
| `STEP_1_5` | Spawn `ticket-reproduce` agent | Agent |
| `STEP_2` | Spawn `ticket-appraise-exec` agent | Agent |
| `STEP_2_5` | Run `bash gate-check.sh --mode entry` | **Bash only** |
| `STEP_3_5` | Spawn `ticket-gate-reconcile` agent | Agent |
| `STEP_4` | Spawn `ticket-implement` agent, then run `outcome-label-check.sh` | Agent + Bash |
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
  hb_retry "flow-sh" "fail" "flow.sh appraise-start failed (exit ${_rc})" \
    "{\"trigger\":\"appraise-start\",\"exit_code\":\"${_rc}\",\"ticket\":\"{TICKET-ID}\"}"
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|META|flow-error|fail|exit ${_rc}: appraise-start" >> {LOG_FILE}
  exit 1
fi
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|META|ticket-claimed|info|{TICKET-ID} claimed → Todo" >> {LOG_FILE}
hb_gate "ticket-claimed" "ok" "ticket claimed — Todo + claimed label + assigned"
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
  hb_gate "phase-transition" "ok" "GATE → IMPLEMENT"
elif [ $_gate_rc -eq 1 ]; then
  # Held — fleet controller will detect, stop here
  echo "Gate held for {TICKET_ID}. Add 'approved' label to proceed."
  exit 0
else
  # Gate-stop (exit 2) — structural failure
  echo "Gate-stop fired for {TICKET_ID}. Check pipeline log for code."
  exit 1
fi
```

### STEP_3_5 — Gate Reconcile

Spawned only when a held ticket is re-approved:

```
STEP=reconcile PHASE=GATE SKILL=/ticket-gate-reconcile
DESCRIPTION="Reconcile comments after gate hold and re-approval"
INSTRUCTIONS="Follow the skill exactly. Load context from env.sh, pipeline log, and artifact files."
NEXT_PHASE=GATE
```

### STEP_4 — Implement

Spawn implement agent, then run outcome-label-check:

```
STEP=implement PHASE=IMPLEMENT SKILL=/ticket-implement FROM_STEP={IMPLEMENT_FROM}
EXTRA_FLAGS="--from-auto"
DESCRIPTION="Implement the changes described in the artifact"
INSTRUCTIONS="Use Serena for all code navigation."
NEXT_PHASE=IMPLEMENT
```

After implement completes, always run outcome-label-check:
```bash
_outcome_sh="${HOME}/.claude/skills/lib/outcome-label-check.sh"
bash "$_outcome_sh" "{TICKET_ID}" "{LOG_FILE}"
```

Then transition from Ready → Review via implement-complete:
```bash
flow_sh=$(find "$HOME/.claude/skills" -name "flow.sh" -path "*/ticket-flow/*" 2>/dev/null | head -1)
[ -n "$flow_sh" ] && bash "$flow_sh" "{TICKET_ID}" "implement-complete" || true
```

### STEP_4_5 — Verify (with retry sub-loop)

The router manages the verify→implement→verify retry loop.

```
STEP=verify PHASE=VERIFY SKILL=/ticket-verify FROM_STEP={VERIFY_FROM}
EXTRA_FLAGS="--from-auto"
DESCRIPTION="Run Playwright UAT verification"
INSTRUCTIONS="Follow the skill exactly."
NEXT_PHASE=VERIFY
```

**After verify completes**, re-run `detect-resume.sh` and check VERIFY_ATTEMPTS:

```bash
# If VERIFY fail AND VERIFY_ATTEMPTS < 3 → loop to re-implement
if grep -q '^[^|]*|VERIFY|verify|fail|' "{LOG_FILE}"; then
  if [ "{VERIFY_ATTEMPTS}" -ge 3 ]; then
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|META|gate-stop|fail|VERIFY_EXHAUSTED" >> "{LOG_FILE}"
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

**After PR review completes**, evaluate verdict:

```bash
# ✅ → proceed to STEP_5 (Document + Wiki)
# ⚠️ AND ITERATION < 3 → run gate-check.sh --mode reapprove, spawn pr-iterate → implement → outcome-check → implement-complete → verify → loop back to pr-review
# ❌ OR ITERATION >= 3 → gate-stop
```

**PR iteration loop:**

```
STEP=pr-iterate PHASE=PR-REVIEW SKILL=/ticket-pr-iterate
DESCRIPTION="Iterate on PR feedback"
INSTRUCTIONS="Apply the requested changes from the PR review."
NEXT_PHASE=PR-REVIEW
```

### Auto-merge logic

After PR review ✅, check auto-merge eligibility:

```bash
if [ "{AUTONOMY}" = "semi-auto" ] && [ "{COMPLEXITY}" = "simple" ]; then
  OUTCOME=$(grep '^[^|]*|IMPLEMENT|implement|done|' "{LOG_FILE}" | tail -1 | cut -d'|' -f5-)
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

```
STEP=pr-reconcile PHASE=PR-REVIEW SKILL=/ticket-pr-iterate
DESCRIPTION="Reconcile PR comments from human reviewers"
INSTRUCTIONS="Check for new human comments on the open PR. Apply amend/push-back/clean logic."
NEXT_PHASE=PR-REVIEW
```

### STEP_6 — Report

Retro auto-trigger check (bash only):
```bash
# Condition 1: did any gate-stop fire during this run?
if grep -q '|META|gate-stop|fail|' "{LOG_FILE}"; then
  NEEDS_RETRO=true
fi
# Condition 2: did the ticket NOT reach a successful outcome?
if ! grep -q '|META|outcome|info|completed:' "{LOG_FILE}"; then
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
```

If `NEEDS_RETRO=true`, spawn `ticket-retro` agent. Then write outcome:

```bash
# Idempotency guard: skip if outcome already written
if ! grep -q '|META|outcome|info|' "{LOG_FILE}"; then
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|META|outcome|info|completed: {outcome summary}" >> "{LOG_FILE}"
fi
```

### Default case — Unknown RESUME_STEP

```bash
echo "Unknown RESUME_STEP: {RESUME_STEP}" >&2
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|META|router-error|fail|Unknown RESUME_STEP: {RESUME_STEP}" >> "{LOG_FILE}"
exit 1
```

---

## Router invariants

1. **No inline LLM reasoning**: Every conditional between dispatch calls is a deterministic bash comparison (string equality, numeric comparison, file existence check).
2. **Stateless router**: All state lives in the pipeline log. The router re-reads it via `detect-resume.sh` before every dispatch decision.
3. **3-step spawn pattern at every dispatch site**: `spawn_agent_pre` → agent spawn → `spawn_capture` (saves agent return value to `-{phase}-agent.log`) → `spawn_agent_post`. Token-tracker SubagentStop hook captures token counts only — agent output text logging requires the explicit `spawn_capture` step.
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
- [x] Step 6: Report — done
TRACE
```
