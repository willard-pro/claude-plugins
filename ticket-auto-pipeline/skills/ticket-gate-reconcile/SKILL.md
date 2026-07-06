---
name: ticket-gate-reconcile
description: Post-gate-hold comment reconciliation agent. Spawned when a held ticket is re-approved. Fetches Linear comments, evaluates open questions, incorporates user guidance into the plan artifact, and either passes clean or re-holds with an amendment cycle. Extracted from ticket-auto Step 3.5.
---

# Ticket Gate Reconcile

**Entry condition:** `RESUME_STEP=STEP_3_5` — gate was held, `approved` label has been re-added.

## Step 1 — Load context (agent starts cold)

Source the project environment file and extract ticket metadata:

```bash
source /tmp/ticket-auto-{TICKET-ID}-env.sh

# Read pipeline log for gate state
LOG_FILE="$PWD/logs/{TICKET-ID}-pipeline.log"
HB_LOG_FILE="$PWD/logs/{TICKET-ID}-heartbeat.log"

~/.claude/skills/lib/hb-wrap.sh
source ~/.claude/skills/lib/linear-api.sh
source ~/.claude/skills/lib/ticket-dir.sh
source ~/.claude/skills/lib/notes-parse.sh

# Extract ARTIFACT_TYPE from EXEC create-artifact line (canonical token), with
# notes.md fallback matching the COMPLEXITY resolution pattern below.
ARTIFACT_TYPE=$(grep '^[^|]*|EXEC|create-artifact|done|' "$LOG_FILE" 2>/dev/null | tail -1 | cut -d'|' -f5- || true)
if [ -z "$ARTIFACT_TYPE" ]; then
  # Fallback: read artifact type from notes.md (same source as COMPLEXITY)
  if [ -f "$NOTES_PATH" ]; then
    ARTIFACT_TYPE=$(grep -i 'artifact.type' "$NOTES_PATH" 2>/dev/null | tail -1 | cut -d: -f2- | sed 's/^[[:space:]]*//' || true)
  fi
  ARTIFACT_TYPE="${ARTIFACT_TYPE:-simple-fix}"
fi

# Resolve ticket directory
TICKET_DIR=$(resolve_ticket_dir "{TICKET-ID}" "." 2>/dev/null || echo ".")

# Read notes.md for open questions context
NOTES_PATH="$TICKET_DIR/notes.md"
if [ -f "$NOTES_PATH" ]; then
  COMPLEXITY=$(get_complexity "$TICKET_DIR" 2>/dev/null || echo "$COMPLEXITY")
fi

# Read the plan artifact for amendment context
if echo "$ARTIFACT_TYPE" | grep -q 'openspec'; then
  ARTIFACT_PATH="$TICKET_DIR/openspec/changes/$(ls "$TICKET_DIR/openspec/changes/" 2>/dev/null | head -1)/tasks.md"
else
  ARTIFACT_PATH="$TICKET_DIR/simple-fix.md"
fi

hb_init
hb-wrap.sh gate "reconcile" "start" "gate-reconcile agent starting" "{\"complexity\":\"$COMPLEXITY\"}"
```

## Step 2 — Resolve gate cycle and fetch comments

Initialize the cycle counter and fetch Linear comments:

```bash
RECONCILE_N=$(grep -c '^[^|]*|GATE|reconcile|done|cycle#' "$LOG_FILE" 2>/dev/null || true)
RECONCILE_N=${RECONCILE_N:-0}
RECONCILE_N=$((RECONCILE_N + 1))

if [ -n "${LINEAR_API_KEY:-}" ]; then
  COMMENTS_JSON=$(bash -c "source ~/.claude/skills/lib/linear-api.sh; get_comments '{TICKET-ID}'")
else
  COMMENTS_JSON=$(mcp__linear-server__list_comments id="{TICKET-ID}")
fi

# Normalize to flat array of {createdAt, body, user: {name}} objects
COMMENTS_JSON=$(echo "$COMMENTS_JSON" | bash -c "source ~/.claude/skills/lib/linear-api.sh; normalize_comments")
```

## Step 3 — Run comment reconciliation

```bash
RECONCILE_OUTPUT=$(echo "$COMMENTS_JSON" | bash ~/.claude/skills/lib/reconcile-comments.sh "{TICKET-ID}" "$LOG_FILE")
echo "$RECONCILE_OUTPUT"
```

Parse the output to set `{LAST_RECONCILE_AT}`, `{APPRAISAL_COMMENT_AT}`, and `{UNPROCESSED_COMMENTS}`.

**How it works:** The script (`lib/reconcile-comments.sh`) identifies the appraisal comment by `**Ticket appraised**` prefix and amendment comments by `**Amendment cycle #` prefix. `LAST_RECONCILE_AT` is the later of the two — everything after it is from the current hold window. Pipeline-authored comments are excluded, so `UNPROCESSED_COMMENTS` contains only user-authored comments in `timestamp|user|body` format.

## Step 4 — Read open questions from notes.md

```bash
RAW_SECTION=$(sed -n '/^## Open Questions/,/^## /p' "$NOTES_PATH")
if echo "$RAW_SECTION" | grep -q '^## '; then
  RAW_SECTION=$(echo "$RAW_SECTION" | sed '/^## Open Questions$/!{/^## /q}')
fi
OPEN_QUESTIONS_LIST=$(echo "$RAW_SECTION" | grep '^\-' || true)
```

If `{OPEN_QUESTIONS_LIST}` is empty or contains only placeholder text ("None", "—"), skip the unanswered-questions check in Step 5.

## Step 5 — Evaluate hold conditions

Two independent conditions. If either triggers, the pipeline holds (proceed to Step 6).

**Condition 1 — Unanswered open questions:**

For each bullet in `{OPEN_QUESTIONS_LIST}`, scan `{UNPROCESSED_COMMENTS}` and all post-appraisal comments for a concrete answer. Use semantic judgment:
- A concrete answer resolves, decides, or explicitly dismisses the question
- Vague replies ("we'll see", "TBD", "maybe", "I'll think about it") do NOT count as answers
- If ANY question lacks a concrete answer → set `HOLD_REASON=unanswered_questions`

**Condition 2 — Unprocessed user comments:**

If `{UNPROCESSED_COMMENTS}` is non-empty → set `HOLD_REASON=unprocessed_comments` (combine with condition 1 if both apply: `HOLD_REASON=unanswered_questions+unprocessed_comments`).

**If neither condition triggers** → skip to Step 8 (clean pass).

## Step 6 — Amendment logic

When a hold condition is active, incorporate user feedback into the plan artifact before re-claiming.

Read the current plan artifact from `$ARTIFACT_PATH`. Append an `## Amendment #N` section (where N = `{RECONCILE_N}`) that:
1. Summarizes the user comments being incorporated
2. Lists concrete changes to the plan required by the feedback
3. Notes any design decisions made during reconciliation

Update `## Open Questions` in notes.md:
- Mark resolved questions with `~~strikethrough~~` (do NOT delete them — preserve history)
- If new unresolvable questions arise from amendment, append them as new bullets

## Step 7 — Post amendment, re-claim, hold

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

Call `re-claim` to remove the `approved` label:

```bash
_flow_sh="${HOME}/.claude/skills/ticket-flow/flow.sh"
[ -f "$_flow_sh" ] || _flow_sh=$(find "${HOME}/.claude/plugins/cache" -name "flow.sh" -path "*/ticket-auto-pipeline/*/skills/ticket-flow/flow.sh" 2>/dev/null | sort | tail -1)
bash "$_flow_sh" "{TICKET-ID}" "re-claim"
```

Write the held log entry:

```bash
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|GATE|reconcile|done|cycle#${RECONCILE_N}|held: ${HOLD_REASON}" >> "$LOG_FILE"
hb-wrap.sh decision "reconcile-result" "fired" "held: ${HOLD_REASON}" "{\"cycle\":\"${RECONCILE_N}\",\"reason\":\"${HOLD_REASON}\"}"
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

## Step 8 — Clean pass

No hold conditions active. All open questions are answered and no unprocessed user comments exist. Write the clean log entry:

```bash
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|GATE|reconcile|done|clean" >> "$LOG_FILE"
hb-wrap.sh decision "reconcile-result" "fired" "clean pass — no unprocessed comments or unanswered questions" "{\"cycle\":\"${RECONCILE_N}\"}"
hb-wrap.sh gate "reconcile" "ok" "clean pass — proceeding to implement"
hb-wrap.sh gate "phase-transition" "ok" "GATE → IMPLEMENT"
```

The router will detect this gate event and proceed to STEP_4.
