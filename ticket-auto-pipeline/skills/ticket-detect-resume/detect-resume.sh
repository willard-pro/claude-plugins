#!/usr/bin/env bash
# ticket-detect-resume: parse pipeline log, determine resume point.
# -u (nounset) intentionally omitted: Claude Code shell snapshots inject
# ZSH_VERSION references that trigger false-positive "unbound variable"
# errors in this bash version when nounset is active.
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${CLAUDE_SKILLS_LIB:-$HOME/.claude/skills/lib}"
source "$LIB_DIR/heartbeat.sh"
source "$LIB_DIR/linear-api.sh"
source "$LIB_DIR/ticket-dir.sh"
source "$LIB_DIR/notes-parse.sh"

CURRENT_SCHEMA_VERSION=2

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
hb_init

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
    log_version=$(echo "$schema_line" | awk -F'|' '{print $5}')
    if [ "$log_version" = "$CURRENT_SCHEMA_VERSION" ]; then
      : # Current version — proceed
    elif [ "$log_version" = "1" ]; then
      _plog "$LOG_FILE" "META" "schema" "warn" "Schema v1 detected — pipe-safe extraction not guaranteed"
      hb_gate "schema-check" "warn" "schema v1 accepted with warning — pipe-safe extraction not guaranteed"
    else
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
      _plog "$LOG_FILE" "META" "schema" "info" "1"
      _plog "$LOG_FILE" "META" "migration" "info" "v0-grace-applied"
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
  # Phase order: APPRAISE → REPRODUCE → EXEC → GATE → IMPLEMENT → VERIFY → PR-REVIEW → MAINTENANCE → REPORT
  # Check from latest phase backward.
  if grep -q '^[^|]*|MAINTENANCE|maintenance|done|' "$LOG_FILE"; then
    RESUME_STEP="STEP_6"
  elif grep -q '^[^|]*|MAINTENANCE|maintenance|fail|' "$LOG_FILE"; then
    RESUME_STEP="STEP_6"
  elif grep -q '^[^|]*|MAINTENANCE|maintenance|waiting|' "$LOG_FILE"; then
    RESUME_STEP="STEP_5"
  elif grep -q '^[^|]*|MAINTENANCE|document|done|' "$LOG_FILE"; then
    RESUME_STEP="STEP_5"
  elif grep -q '^[^|]*|MAINTENANCE|document|fail|' "$LOG_FILE"; then
    RESUME_STEP="STEP_5"
  elif grep -q '^[^|]*|MAINTENANCE|document|waiting|' "$LOG_FILE"; then
    RESUME_STEP="STEP_5"
  elif grep -q '^[^|]*|MAINTENANCE|maintenance|' "$LOG_FILE"; then
    RESUME_STEP="STEP_5"
  elif grep -q '^[^|]*|MAINTENANCE|document|' "$LOG_FILE"; then
    RESUME_STEP="STEP_5"
  elif grep -q '^[^|]*|PR-REVIEW|pr-review|done|' "$LOG_FILE"; then
    # PR merge-status check: merged → STEP_6, open with human comments → STEP_5_5, else → STEP_5
    _pr_number=$(grep '^[^|]*|PR-REVIEW|checkout-pr|done|' "$LOG_FILE" 2>/dev/null | tail -1 | awk -F'|' '{print $5}' || true)
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
        _has_new_human=$(echo "$_pr_comments" |
          jq -e --arg ts "$_last_bot_ts" 'select(.createdAt > $ts)' >/dev/null 2>&1 &&
          echo true || echo false)
        if [ "$_has_new_human" = "true" ]; then
          RESUME_STEP="STEP_5_5"
        else
          RESUME_STEP="STEP_5"
        fi
      fi
    else
      # gh unavailable or no PR number found — fall back to STEP_5 (Document + Wiki)
      RESUME_STEP="STEP_5"
      if ! $_gh_available; then
        _plog "$LOG_FILE" "META" "pr-comment-check" "warn" "gh unavailable — falling back to STEP_5"
      fi
    fi
  elif grep -q '^[^|]*|VERIFY|verify|done|PASS' "$LOG_FILE"; then
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
    RESUME_STEP="STEP_2_5"
  elif grep -q '^[^|]*|REPRODUCE|reproduce|' "$LOG_FILE" && ! grep -q '^[^|]*|REPRODUCE|reproduce|done|' "$LOG_FILE"; then
    RESUME_STEP="STEP_1_5"
  elif grep -q '^[^|]*|APPRAISE|appraise|done|' "$LOG_FILE"; then
    RESUME_STEP="STEP_2"
  else
    RESUME_STEP="STEP_1"
  fi
fi

# ── Zombie detection ───────────────────────────────────────────────────────
# Detect steps stuck on "waiting" where the agent process is gone.
# A zombie is: status=waiting, timestamp > 5 min old, no agent process alive.
if [ -s "$LOG_FILE" ]; then
  _zombie_cutoff=$(date -d "5 minutes ago" +%s 2>/dev/null || echo 0)
  if [ "$_zombie_cutoff" -gt 0 ]; then
    while IFS= read -r _zline; do
      _z_iso=$(echo "$_zline" | awk -F'|' '{print $1}')
      _z_phase=$(echo "$_zline" | awk -F'|' '{print $2}')
      _z_step=$(echo "$_zline" | awk -F'|' '{print $3}')

      # Skip non-phase lines (META, schema headers) and inspector steps.
      # Inspector spawns are advisory observers; their zombies must not
      # trigger phase re-runs (RLVR Phase 1 — F4 fix).
      case "$_z_step" in phase-inspector-*) continue ;; esac
      case "$_z_phase" in APPRAISE | REPRODUCE | EXEC | GATE | IMPLEMENT | VERIFY | PR-REVIEW | MAINTENANCE) ;; *) continue ;; esac

      _z_epoch=$(date -d "$_z_iso" +%s 2>/dev/null || echo 0)
      if [ "$_z_epoch" -gt 0 ] && [ "$_z_epoch" -lt "$_zombie_cutoff" ]; then
        # Older than 5 minutes — check for agent process
        if ! pgrep -f "ticket-auto.*${TICKET_ID}" >/dev/null 2>&1; then
          _plog "$LOG_FILE" "$_z_phase" "$_z_step" "fail" "zombie-detected: ${_z_phase} ${_z_step}"
          hb_gate "zombie-detection" "fail" "zombie detected: ${_z_phase}/${_z_step} — re-running phase"

          # Set resume point to re-run the phase
          case "$_z_phase" in
          APPRAISE) RESUME_STEP="STEP_1" ;;
          REPRODUCE) RESUME_STEP="STEP_1_5" ;;
          EXEC) RESUME_STEP="STEP_2" ;;
          GATE) RESUME_STEP="STEP_3" ;;
          IMPLEMENT) RESUME_STEP="STEP_4" ;;
          VERIFY) RESUME_STEP="STEP_4_5" ;;
          PR-REVIEW) RESUME_STEP="STEP_5" ;;
          MAINTENANCE) RESUME_STEP="STEP_5" ;;
          esac
        fi
      fi
    done < <(grep '|waiting|' "$LOG_FILE" 2>/dev/null || true)
  fi
fi

# ── GATE_HELD handling ──────────────────────────────────────────────────────

if [ "$RESUME_STEP" = "GATE_HELD" ]; then
  ISSUE_JSON=$(get_issue "$TICKET_ID" 2>/dev/null || echo 'null')
  if echo "$ISSUE_JSON" | jq -e '.labels.nodes[] | select(.name | ascii_downcase == "approved")' >/dev/null 2>&1; then
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
DOCUMENT_FROM=""
VERIFY_FROM=""
PR_REVIEW_FROM=""
PR_ITERATE_FROM=""

if [ -s "$LOG_FILE" ]; then
  APPRAISE_FROM=$(grep '^[^|]*|APPRAISE|[^|]*|done|' "$LOG_FILE" 2>/dev/null |
    grep -v '|APPRAISE|appraise|done|' |
    tail -1 | awk -F'|' '{print $3}' || true)

  REPRODUCE_FROM=$(grep '^[^|]*|REPRODUCE|[^|]*|done|' "$LOG_FILE" 2>/dev/null |
    grep -v '|REPRODUCE|reproduce|done|' |
    tail -1 | awk -F'|' '{print $3}' || true)

  # EXEC_FROM extracts the last sub-step within the EXEC phase, excluding the
  # terminal EXEC|create-artifact|done| marker. The grep -v '|EXEC|exec|done|'
  # exclusion below is currently a no-op — no producer ever writes "exec" as a
  # step name; the canonical terminal marker is "create-artifact", which this
  # grep already excludes via the |EXEC|[^|]*|done| pattern (it only matches
  # sub-step lines, never the terminal marker). The exclusion is harmless and
  # retained as a safety net in case a legacy log with the old token shape is
  # ever re-read.
  EXEC_FROM=$(grep '^[^|]*|EXEC|[^|]*|done|' "$LOG_FILE" 2>/dev/null |
    grep -v '|EXEC|exec|done|' |
    tail -1 | awk -F'|' '{print $3}' || true)

  IMPLEMENT_FROM=$(grep '^[^|]*|IMPLEMENT|[^|]*|done|' "$LOG_FILE" 2>/dev/null |
    grep -v '|IMPLEMENT|implement|done|' |
    grep -v '|IMPLEMENT|phase-inspector-' |
    tail -1 | awk -F'|' '{print $3}' || true)

  MAINTENANCE_FROM=$(grep '^[^|]*|MAINTENANCE|[^|]*|done|' "$LOG_FILE" 2>/dev/null |
    grep -v '|MAINTENANCE|maintenance|done|' |
    grep -v '|MAINTENANCE|document|done|' |
    grep -v '|MAINTENANCE|prescan|' |
    tail -1 | awk -F'|' '{print $3}' || true)

  DOCUMENT_FROM=$(grep '^[^|]*|MAINTENANCE|document|done|' "$LOG_FILE" 2>/dev/null |
    tail -1 | awk -F'|' '{print $3}' || true)

  VERIFY_FROM=$(grep '^[^|]*|VERIFY|[^|]*|done|' "$LOG_FILE" 2>/dev/null |
    grep -v '|VERIFY|verify|done|' |
    grep -v '|VERIFY|phase-inspector-' |
    tail -1 | awk -F'|' '{print $3}' || true)

  PR_REVIEW_FROM=$(grep '^[^|]*|PR-REVIEW|[^|]*|done|' "$LOG_FILE" 2>/dev/null |
    grep -v '|PR-REVIEW|pr-review|done|' |
    grep -v '|PR-REVIEW|plan-iterate' |
    grep -v '|PR-REVIEW|phase-inspector-' |
    tail -1 | awk -F'|' '{print $3}' || true)

  PR_ITERATE_FROM=$(grep '^[^|]*|PR-REVIEW|iterate-[^|]*|done|' "$LOG_FILE" 2>/dev/null |
    tail -1 | awk -F'|' '{print $3}' || true)
fi

# ── Reconcile cycle extraction ──────────────────────────────────────────────

RECONCILE_CYCLE=$(grep -c '^[^|]*|GATE|reconcile|done|cycle#' "$LOG_FILE" 2>/dev/null || true)
RECONCILE_CYCLE=${RECONCILE_CYCLE:-0}

# ── Browser-state correction ────────────────────────────────────────────────

case "$VERIFY_FROM" in
browser-session | navigate | execute-steps) VERIFY_FROM="build-plan" ;;
esac

# ── Context restoration (mid-pipeline only) ─────────────────────────────────

TICKET_DIR=""
COMPLEXITY=""
ARTIFACT_TYPE=""
BRANCH=""
BASE_BRANCH=""
INTEGRATION_BRANCH=""
BRANCH_SOURCE=""
TICKET_TITLE=""
VERIFY_ATTEMPTS=0
VERIFY_LAST=""
ITERATION=0
PR_FEEDBACK_CYCLE=0

# Branch-context recovery is independent of RESUME_STEP — it's written at
# Step 0.5 before the first agent spawn and must be recoverable from any
# resume state, including STEP_1 and GATE_STILL_HELD.
if [ -s "$LOG_FILE" ]; then
  _branch_ctx=$(grep '^[^|]*|META|branch-context|info|' "$LOG_FILE" 2>/dev/null |
    tail -1 | awk -F'|' '{for(i=5;i<=NF;i++) printf "%s%s", (i>5?"|":""), $i; print ""}' || true)
  if [ -n "$_branch_ctx" ]; then
    BASE_BRANCH=$(echo "$_branch_ctx" | sed -n 's/.*base=\([^;]*\).*/\1/p')
    INTEGRATION_BRANCH=$(echo "$_branch_ctx" | sed -n 's/.*integration=\([^;]*\).*/\1/p')
    BRANCH_SOURCE=$(echo "$_branch_ctx" | sed -n 's/.*source=\([^;]*\).*/\1/p')
  fi
fi

if [ "$RESUME_STEP" != "STEP_1" ] && [ "$RESUME_STEP" != "GATE_STILL_HELD" ]; then
  TICKET_DIR=$(resolve_ticket_dir "$TICKET_ID" "." 2>/dev/null || true)

  if [ -n "$TICKET_DIR" ]; then
    COMPLEXITY=$(get_complexity "$TICKET_DIR" || true)
  fi

  if [ -s "$LOG_FILE" ]; then
    # Actual log line is EXEC|create-artifact|done|{simple-fix|openspec} —
    # "exec" is not a step name ticket-appraise-exec ever writes.
    ARTIFACT_TYPE=$(grep '^[^|]*|EXEC|create-artifact|done|' "$LOG_FILE" 2>/dev/null |
      tail -1 | awk -F'|' '{for(i=5;i<=NF;i++) printf "%s%s", (i>5?"|":""), $i; print ""}' || true)

    BRANCH=$(grep '^[^|]*|IMPLEMENT|checkout-branch|done|' "$LOG_FILE" 2>/dev/null |
      tail -1 | awk -F'|' '{for(i=5;i<=NF;i++) printf "%s%s", (i>5?"|":""), $i; print ""}' || true)

    TICKET_TITLE=$(grep '^[^|]*|META|title|info|' "$LOG_FILE" 2>/dev/null |
      tail -1 | awk -F'|' '{for(i=5;i<=NF;i++) printf "%s%s", (i>5?"|":""), $i; print ""}' | sed 's/^[^:]*: //' || true)

    AUTONOMY=$(grep '^[^|]*|META|autonomy|info|' "$LOG_FILE" 2>/dev/null | tail -1 | awk -F'|' '{for(i=5;i<=NF;i++) printf "%s%s", (i>5?"|":""), $i; print ""}' || true)
    AUTONOMY=${AUTONOMY:-manual}

    # R6: count only terminal FAIL entries — a PASS naturally exits the retry
    # loop and should not inflate the 3-attempt exhaustion cap. Counting
    # both fail|done would ambiguously mix success and failure into the limit.
    VERIFY_ATTEMPTS=$(grep -Ec '^[^|]*\|VERIFY\|verify\|fail\|' "$LOG_FILE" 2>/dev/null || true)
    VERIFY_ATTEMPTS=${VERIFY_ATTEMPTS:-0}

    # WARN is the canonical verdict token spawn_agent_post prepends for a
    # gaps-found PR-review verdict (see pipeline-log-format.md#verdict-tokens).
    # Matching the token avoids the byte-exact warning-emoji coupling this
    # replaced (variation-selector bytes made the old prose match brittle).
    ITERATION=$(grep -c '^[^|]*|PR-REVIEW|pr-review|done|WARN' "$LOG_FILE" 2>/dev/null || true)
    ITERATION=${ITERATION:-0}
    PR_FEEDBACK_CYCLE=$(grep -c '^[^|]*|PR-REVIEW|pr-reconcile|done|cycle#' "$LOG_FILE" 2>/dev/null || true)
    PR_FEEDBACK_CYCLE=${PR_FEEDBACK_CYCLE:-0}

    # R8: distinguish crash-resume-after-verify-fail from a fresh verify dispatch.
    # If the last terminal VERIFY event is a fail with no later IMPLEMENT|implement|done
    # line, the pipeline crashed before re-implementing — resuming straight into verify
    # would re-run against the same broken code. VERIFY_LAST tells STEP_4_5 to dispatch
    # re-implement first instead.
    _verify_last_ln=$(grep -nE '^[^|]*\|VERIFY\|verify\|(done|fail)\|' "$LOG_FILE" 2>/dev/null | tail -1 | cut -d: -f1 || true)
    if [ -n "$_verify_last_ln" ]; then
      _verify_last_content=$(sed -n "${_verify_last_ln}p" "$LOG_FILE")
      if echo "$_verify_last_content" | grep -q '|VERIFY|verify|fail|'; then
        _implement_after=$(awk -F'|' -v n="$_verify_last_ln" 'NR>n && $2=="IMPLEMENT" && $3=="implement" && $4=="done"{f=1; exit} END{print f+0}' "$LOG_FILE")
        [ "$_implement_after" = "0" ] && VERIFY_LAST="fail"
      elif echo "$_verify_last_content" | grep -q '|VERIFY|verify|done|PASS'; then
        VERIFY_LAST="pass"
      fi
    fi
  fi
fi

# ── Output ──────────────────────────────────────────────────────────────────
#
# DETECT_RESUME_RESULT block fields:
#   RESUME_STEP       — next step to execute (STEP_1 through STEP_6, STEP_*_*, GATE_*)
#   APPRAISE_FROM     — sub-step within APPRAISE phase (or empty)
#   REPRODUCE_FROM    — sub-step within REPRODUCE phase (or empty)
#   EXEC_FROM         — sub-step within EXEC phase (or empty)
#   IMPLEMENT_FROM    — sub-step within IMPLEMENT phase (or empty)
#   MAINTENANCE_FROM  — sub-step within MAINTENANCE phase (or empty)
#   DOCUMENT_FROM     — sub-step within document phase (or empty)
#   VERIFY_FROM       — sub-step within VERIFY phase (or empty)
#   PR_REVIEW_FROM    — sub-step within PR-REVIEW phase (or empty)
#   PR_ITERATE_FROM   — sub-step within PR-ITERATE phase (or empty)
#   TICKET_DIR        — workspace directory for the ticket (or empty)
#   COMPLEXITY        — simple|complex (from notes.md)
#   AUTONOMY          — auto|semi-auto|manual (from pipeline log META|autonomy, defaults to manual)
#   ARTIFACT_TYPE     — simple-fix|openspec (from EXEC phase completion line)
#   BRANCH            — git branch name (from IMPLEMENT checkout)
#   BASE_BRANCH       — base branch resolved at Step 0.5 (from META|branch-context)
#   INTEGRATION_BRANCH — integration branch if epic-scoped (from META|branch-context; empty if none)
#   BRANCH_SOURCE     — flag|epic-directive|default (from META|branch-context; empty on legacy logs)
#   TICKET_TITLE      — human-readable ticket title
#   VERIFY_ATTEMPTS   — count of terminal verify fail entries in pipeline log (PASS excluded)
#   VERIFY_LAST       — "fail" if the last terminal VERIFY event is a fail with no
#                       later IMPLEMENT done (crash-resume must re-implement before
#                       re-verifying); "pass" if PASS; empty otherwise
#   ITERATION         — count of PR review WARN-verdict (⚠️) entries in pipeline log
#   RECONCILE_CYCLE   — count of gate reconcile done entries
#   PR_FEEDBACK_CYCLE — count of pr-reconcile done entries

cat <<EOF
DETECT_RESUME_RESULT
  RESUME_STEP:        ${RESUME_STEP}
  APPRAISE_FROM:      ${APPRAISE_FROM:-}
  REPRODUCE_FROM:     ${REPRODUCE_FROM:-}
  EXEC_FROM:          ${EXEC_FROM:-}
  IMPLEMENT_FROM:     ${IMPLEMENT_FROM:-}
  MAINTENANCE_FROM:   ${MAINTENANCE_FROM:-}
  DOCUMENT_FROM:      ${DOCUMENT_FROM:-}
  VERIFY_FROM:        ${VERIFY_FROM:-}
  PR_REVIEW_FROM:     ${PR_REVIEW_FROM:-}
  PR_ITERATE_FROM:    ${PR_ITERATE_FROM:-}
  TICKET_DIR:         ${TICKET_DIR:-}
  COMPLEXITY:         ${COMPLEXITY:-}
  AUTONOMY:           ${AUTONOMY:-manual}
  ARTIFACT_TYPE:      ${ARTIFACT_TYPE:-}
  BRANCH:             ${BRANCH:-}
  BASE_BRANCH:        ${BASE_BRANCH:-}
  INTEGRATION_BRANCH: ${INTEGRATION_BRANCH:-}
  BRANCH_SOURCE:      ${BRANCH_SOURCE:-}
  TICKET_TITLE:       ${TICKET_TITLE:-}
  VERIFY_ATTEMPTS:    ${VERIFY_ATTEMPTS}
  VERIFY_LAST:        ${VERIFY_LAST:-}
  ITERATION:          ${ITERATION}
  RECONCILE_CYCLE:    ${RECONCILE_CYCLE}
  PR_FEEDBACK_CYCLE:  ${PR_FEEDBACK_CYCLE}
END_DETECT_RESUME_RESULT
EOF
