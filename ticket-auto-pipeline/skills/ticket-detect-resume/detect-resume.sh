#!/usr/bin/env bash
# ticket-detect-resume: parse pipeline log, determine resume point.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${CLAUDE_SKILLS_LIB:-$HOME/.claude/skills/lib}"
source "$LIB_DIR/heartbeat.sh"
source "$LIB_DIR/linear-api.sh"
source "$LIB_DIR/ticket-dir.sh"
source "$LIB_DIR/notes-parse.sh"

CURRENT_SCHEMA_VERSION=1

usage() {
  echo "Usage: $0 <TICKET-ID>" >&2
  echo "  Reads \$PWD/logs/{TICKET-ID}-pipeline.log to determine where the last" >&2
  echo "  ticket-auto run left off." >&2
  exit 1
}

TICKET_ID="${1:-}"
[ -z "$TICKET_ID" ] && usage

LOG_FILE="$PWD/logs/${TICKET_ID}-pipeline.log"
HB_LOG_FILE="$PWD/logs/${TICKET_ID}-heartbeat.log"

# ── Heartbeat log validation ─────────────────────────────────────────────────
if [ -f "$HB_LOG_FILE" ]; then
  if ! hb_validate_file "$HB_LOG_FILE" 2>/dev/null; then
    hb_gate "schema-check" "fail" "heartbeat log validation failed" "{\"file\":\"$HB_LOG_FILE\"}"
  else
    hb_gate "schema-check" "ok" "heartbeat log valid" "{\"file\":\"$HB_LOG_FILE\"}"
  fi
fi

# ── Schema version check ─────────────────────────────────────────────────────
# Must happen before any resume logic so a mismatch aborts cleanly.

if [ -s "$LOG_FILE" ]; then
  schema_line=$(grep '^[^|]*|META|schema|info|' "$LOG_FILE" 2>/dev/null | head -1 || true)

  if [ -n "$schema_line" ]; then
    log_version=$(echo "$schema_line" | cut -d'|' -f5)
    if [ "$log_version" != "$CURRENT_SCHEMA_VERSION" ]; then
      cat <<EOF
DETECT_RESUME_RESULT
  RESUME_STEP:        SCHEMA_MISMATCH
  SCHEMA_LOG_VERSION: ${log_version}
  SCHEMA_EXPECTED:    ${CURRENT_SCHEMA_VERSION}
  LOG_FILE:           ${LOG_FILE}
END_DETECT_RESUME_RESULT
EOF
      exit 0
    fi
  else
    # No schema line in a non-empty log — apply v0 grace if entries look valid
    if grep -qP '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\|[A-Z-]+\|[^|]+\|[^|]+\|' "$LOG_FILE" 2>/dev/null; then
      echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|META|schema|info|1" >> "$LOG_FILE"
      echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|META|migration|info|v0-grace-applied" >> "$LOG_FILE"
      hb_gate "schema-check" "ok" "v0-grace applied — no schema header, entries look valid"
    else
      cat <<EOF
DETECT_RESUME_RESULT
  RESUME_STEP:        SCHEMA_MISMATCH
  SCHEMA_LOG_VERSION: none
  SCHEMA_EXPECTED:    ${CURRENT_SCHEMA_VERSION}
  LOG_FILE:           ${LOG_FILE}
END_DETECT_RESUME_RESULT
EOF
      exit 0
    fi
  fi
fi

# ── Level 1: RESUME_STEP detection ──────────────────────────────────────────

if [ ! -s "$LOG_FILE" ]; then
  RESUME_STEP="STEP_1"
else
  if grep -q '^[^|]*|PR-REVIEW|pr-review|done|' "$LOG_FILE"; then
    # PR merge-status check: open PR with human comments → STEP_5_5, else STEP_6
    _pr_number=$(grep '^[^|]*|PR-REVIEW|checkout-pr|done|' "$LOG_FILE" 2>/dev/null | tail -1 | cut -d'|' -f5 || true)
    if [ -z "$_pr_number" ]; then
      _pr_number=$(grep -oP 'PR-REVIEW\|pr-review\|done\|.*?\b(\d+)\b' "$LOG_FILE" 2>/dev/null | grep -oP '\d+$' | tail -1 || true)
    fi
    _gh_available=false
    if command -v gh &>/dev/null && gh auth status &>/dev/null 2>&1; then
      _gh_available=true
    fi
    if $_gh_available && [ -n "$_pr_number" ]; then
      _pr_state=$(gh pr view "$_pr_number" --json state --jq '.state' 2>/dev/null || echo "unknown")
      if [ "$_pr_state" = "MERGED" ] || [ "$_pr_state" = "CLOSED" ]; then
        RESUME_STEP="STEP_6"
      else
        # PR is open — resolve bot identity and check for human comments
        _bot_user=$(gh api user --jq '.login' 2>/dev/null || echo "")
        _pr_comments=$(gh pr view "$_pr_number" --json comments --jq '.comments[] | select(.author.login != "'"$_bot_user"'" and .author.login != "github-actions[bot]") | {createdAt: .createdAt, author: .author.login, body: .body}' 2>/dev/null || echo "[]")
        # Find last bot comment timestamp as boundary
        _last_bot_ts=$(gh pr view "$_pr_number" --json comments --jq '[.comments[] | select(.author.login == "'"$_bot_user"'" or .author.login == "github-actions[bot]")] | last | .createdAt' 2>/dev/null || echo "")
        _has_new_human=false
        if [ "$_pr_comments" != "[]" ] && [ -n "$_pr_comments" ]; then
          if [ -n "$_last_bot_ts" ]; then
            _has_new_human=$(echo "$_pr_comments" | jq -e --arg ts "$_last_bot_ts" 'select(.createdAt > $ts) | length > 0' 2>/dev/null && echo true || echo false)
          else
            _has_new_human=$(echo "$_pr_comments" | jq -e 'length > 0' 2>/dev/null && echo true || echo false)
          fi
        fi
        if [ "$_has_new_human" = "true" ]; then
          RESUME_STEP="STEP_5_5"
        else
          RESUME_STEP="STEP_6"
        fi
      fi
    else
      # gh unavailable or no PR number found — fall back to STEP_6
      RESUME_STEP="STEP_6"
      if ! $_gh_available; then
        echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|META|pr-comment-check|warn|gh unavailable — falling back to STEP_6" >> "$LOG_FILE"
      fi
    fi
  elif grep -q '^[^|]*|VERIFY|verify|done|PASS' "$LOG_FILE"; then
    RESUME_STEP="STEP_5"
  elif grep -q '^[^|]*|MAINTENANCE|maintenance|done|' "$LOG_FILE"; then
    RESUME_STEP="STEP_5"
  elif grep -q '^[^|]*|MAINTENANCE|maintenance|' "$LOG_FILE"; then
    RESUME_STEP="STEP_4_6"
  elif grep -q '^[^|]*|VERIFY|verify|' "$LOG_FILE"; then
    RESUME_STEP="STEP_4_5"
  elif grep -q '^[^|]*|IMPLEMENT|implement|done|' "$LOG_FILE"; then
    RESUME_STEP="STEP_4_5"
  elif grep -q '^[^|]*|GATE|gate|done|' "$LOG_FILE"; then
    RESUME_STEP="STEP_4"
  elif grep -q '^[^|]*|GATE|gate|fail|held' "$LOG_FILE"; then
    RESUME_STEP="GATE_HELD"
  elif grep -q '^[^|]*|META|gate-stop|fail|EXEC_NO_ARTIFACT' "$LOG_FILE"; then
    # EXEC phase claimed done but artifact was never written — re-run EXEC
    RESUME_STEP="STEP_2"
    hb_gate "resume-point" "ok" "EXEC_NO_ARTIFACT detected — resuming at STEP_2 (re-run EXEC)"
  elif grep -q '^[^|]*|EXEC|exec|done|' "$LOG_FILE"; then
    RESUME_STEP="STEP_3"
  elif grep -q '^[^|]*|REPRODUCE|reproduce|' "$LOG_FILE" && ! grep -q '^[^|]*|REPRODUCE|reproduce|done|' "$LOG_FILE"; then
    RESUME_STEP="STEP_1_5"
  elif grep -q '^[^|]*|APPRAISE|appraise|done|' "$LOG_FILE"; then
    RESUME_STEP="STEP_2"
  else
    RESUME_STEP="STEP_1"
  fi
fi

# ── GATE_HELD handling ──────────────────────────────────────────────────────

if [ "$RESUME_STEP" = "GATE_HELD" ]; then
  ISSUE_JSON=$((get_issue "$TICKET_ID" 2>/dev/null) || echo 'null')
  if echo "$ISSUE_JSON" | jq -e '.labels.nodes[] | select(.name | ascii_downcase == "approved")' > /dev/null 2>&1; then
    RESUME_STEP="STEP_3_5"
    hb_gate "resume-point" "ok" "gate was held but approved label found — resuming at STEP_3_5 (comment reconciliation)"
  else
    RESUME_STEP="GATE_STILL_HELD"
    hb_gate "resume-point" "fail" "gate still held — requires approval"
  fi
fi

# ── Level 2: per-sub-skill _FROM extraction ─────────────────────────────────

APPRAISE_FROM=""
REPRODUCE_FROM=""
EXEC_FROM=""
IMPLEMENT_FROM=""
MAINTENANCE_FROM=""
VERIFY_FROM=""
PR_REVIEW_FROM=""
PR_ITERATE_FROM=""

if [ -s "$LOG_FILE" ]; then
  APPRAISE_FROM=$(grep '^[^|]*|APPRAISE|[^|]*|done|' "$LOG_FILE" 2>/dev/null \
    | grep -v '|APPRAISE|appraise|done|' \
    | tail -1 | cut -d'|' -f3 || true)

  REPRODUCE_FROM=$(grep '^[^|]*|REPRODUCE|[^|]*|done|' "$LOG_FILE" 2>/dev/null \
    | grep -v '|REPRODUCE|reproduce|done|' \
    | tail -1 | cut -d'|' -f3 || true)

  EXEC_FROM=$(grep '^[^|]*|EXEC|[^|]*|done|' "$LOG_FILE" 2>/dev/null \
    | grep -v '|EXEC|exec|done|' \
    | tail -1 | cut -d'|' -f3 || true)

  IMPLEMENT_FROM=$(grep '^[^|]*|IMPLEMENT|[^|]*|done|' "$LOG_FILE" 2>/dev/null \
    | grep -v '|IMPLEMENT|implement|done|' \
    | tail -1 | cut -d'|' -f3 || true)

  MAINTENANCE_FROM=$(grep '^[^|]*|MAINTENANCE|[^|]*|done|' "$LOG_FILE" 2>/dev/null \
    | grep -v '|MAINTENANCE|maintenance|done|' \
    | tail -1 | cut -d'|' -f3 || true)

  VERIFY_FROM=$(grep '^[^|]*|VERIFY|[^|]*|done|' "$LOG_FILE" 2>/dev/null \
    | grep -v '|VERIFY|verify|done|' \
    | tail -1 | cut -d'|' -f3 || true)

  PR_REVIEW_FROM=$(grep '^[^|]*|PR-REVIEW|[^|]*|done|' "$LOG_FILE" 2>/dev/null \
    | grep -v '|PR-REVIEW|pr-review|done|' \
    | grep -v '|PR-REVIEW|plan-iterate' \
    | tail -1 | cut -d'|' -f3 || true)

  PR_ITERATE_FROM=$(grep '^[^|]*|PR-REVIEW|iterate-[^|]*|done|' "$LOG_FILE" 2>/dev/null \
    | tail -1 | cut -d'|' -f3 || true)
fi

# ── Reconcile cycle extraction ──────────────────────────────────────────────

RECONCILE_CYCLE=$(grep -c '^[^|]*|GATE|reconcile|done|cycle#' "$LOG_FILE" 2>/dev/null || true)
RECONCILE_CYCLE=${RECONCILE_CYCLE:-0}

# ── Browser-state correction ────────────────────────────────────────────────

case "$VERIFY_FROM" in
  browser-session|navigate|execute-steps) VERIFY_FROM="build-plan" ;;
esac

# ── Context restoration (mid-pipeline only) ─────────────────────────────────

TICKET_DIR=""
COMPLEXITY=""
ARTIFACT_TYPE=""
BRANCH=""
TICKET_TITLE=""
VERIFY_ATTEMPTS=0
ITERATION=0

if [ "$RESUME_STEP" != "STEP_1" ] && [ "$RESUME_STEP" != "GATE_STILL_HELD" ]; then
  TICKET_DIR=$(resolve_ticket_dir "$TICKET_ID" "." 2>/dev/null || true)

  if [ -n "$TICKET_DIR" ]; then
    COMPLEXITY=$(get_complexity "$TICKET_DIR" || true)
  fi

  if [ -s "$LOG_FILE" ]; then
    ARTIFACT_TYPE=$(grep '^[^|]*|EXEC|exec|done|' "$LOG_FILE" 2>/dev/null \
      | tail -1 | cut -d'|' -f5 || true)

    BRANCH=$(grep '^[^|]*|IMPLEMENT|checkout-branch|done|' "$LOG_FILE" 2>/dev/null \
      | tail -1 | cut -d'|' -f5 || true)

    TICKET_TITLE=$(grep '^[^|]*|META|title|info|' "$LOG_FILE" 2>/dev/null \
      | tail -1 | cut -d'|' -f5 | sed 's/^[^:]*: //' || true)

    VERIFY_ATTEMPTS=$(grep -c '^[^|]*|VERIFY|[^|]*|fail|' "$LOG_FILE" 2>/dev/null || true)
    VERIFY_ATTEMPTS=${VERIFY_ATTEMPTS:-0}

    ITERATION=$(grep -c '^[^|]*|PR-REVIEW|pr-review|done|Verdict.*⚠️' "$LOG_FILE" 2>/dev/null || true)
    ITERATION=${ITERATION:-0}
    PR_FEEDBACK_CYCLE=$(grep -c '^[^|]*|PR-REVIEW|pr-reconcile|done|cycle#' "$LOG_FILE" 2>/dev/null || true)
    PR_FEEDBACK_CYCLE=${PR_FEEDBACK_CYCLE:-0}
  fi
fi

# ── Output ──────────────────────────────────────────────────────────────────

cat <<EOF
DETECT_RESUME_RESULT
  RESUME_STEP:        ${RESUME_STEP}
  APPRAISE_FROM:      ${APPRAISE_FROM:-}
  REPRODUCE_FROM:     ${REPRODUCE_FROM:-}
  EXEC_FROM:          ${EXEC_FROM:-}
  IMPLEMENT_FROM:     ${IMPLEMENT_FROM:-}
  MAINTENANCE_FROM:   ${MAINTENANCE_FROM:-}
  VERIFY_FROM:        ${VERIFY_FROM:-}
  PR_REVIEW_FROM:     ${PR_REVIEW_FROM:-}
  PR_ITERATE_FROM:    ${PR_ITERATE_FROM:-}
  TICKET_DIR:         ${TICKET_DIR:-}
  COMPLEXITY:         ${COMPLEXITY:-}
  ARTIFACT_TYPE:      ${ARTIFACT_TYPE:-}
  BRANCH:             ${BRANCH:-}
  TICKET_TITLE:       ${TICKET_TITLE:-}
  VERIFY_ATTEMPTS:    ${VERIFY_ATTEMPTS}
  ITERATION:          ${ITERATION}
  RECONCILE_CYCLE:    ${RECONCILE_CYCLE}
  PR_FEEDBACK_CYCLE:  ${PR_FEEDBACK_CYCLE}
END_DETECT_RESUME_RESULT
EOF
