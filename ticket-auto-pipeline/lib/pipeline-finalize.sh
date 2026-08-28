#!/usr/bin/env bash
# pipeline-finalize.sh — deterministic exit finalizer for ticket-auto router.
# RLVR Phase 3: runs postmortem analysis, writes META|outcome, and exits.
#
# Called at every router exit point (gate-stop, gate-held, exhaustion,
# STEP_6 completion, router-error) to ensure postmortem coverage and
# outcome writing on ALL paths.
#
# Usage: pipeline-finalize.sh <ticket-id> <exit-code> <log-file> [outcome-override]
#
# Exit code: the original exit code is preserved.
#
# -u intentionally omitted: Claude Code shell snapshots inject ZSH_VERSION.
set -eo pipefail

TICKET_ID="${1:-}"
EXIT_CODE="${2:-0}"
LOG_FILE="${3:-}"
OUTCOME_OVERRIDE="${4:-}"

if [ -z "$TICKET_ID" ] || [ -z "$LOG_FILE" ]; then
  echo "[pipeline-finalize] WARN: missing required args" >&2
  exit "${EXIT_CODE}"
fi

# ── Post-mortem analysis ────────────────────────────────────────────────────

_pm_script="$HOME/.claude/skills/lib/pipeline-postmortem.sh"
if [ ! -f "$_pm_script" ]; then
  _pm_script=$(find "$HOME/.claude/plugins/cache" -name pipeline-postmortem.sh -path "*/ticket-auto-pipeline/*" 2>/dev/null | sort | tail -1)
fi

if [ -n "$_pm_script" ] && [ -f "$_pm_script" ]; then
  timeout 60 bash "$_pm_script" "$TICKET_ID" --exit-code "$EXIT_CODE" 2>&1 || true
fi

# ── Outcome write ───────────────────────────────────────────────────────────
# Replaces the old STEP_6-only outcome write and the trap handler's
# idempotency-guarded write. Uses a tail-check guard: only skips if the
# LAST substantive line in the log is an outcome — prevents stale outcomes
# from crash-resume from blocking a fresh write (F10 fix).

if [ ! -f "$LOG_FILE" ]; then
  exit "${EXIT_CODE}"
fi

# Derive outcome summary from log evidence, not exit code alone (F07 fix).
# EXIT_CODE==0 is checked before any grep-based failure derivation: this
# function is called at every router exit point, and on a long-lived,
# multi-generation pipeline log a ticket that failed early (gate-stop,
# gate-held, VERIFY_EXHAUSTED, ...) in a superseded earlier generation but
# went on to genuinely complete would otherwise have its final "completed:
# STEP_6" outcome permanently overwritten by that stale historical marker —
# the grep checks below have no notion of "was this later resolved," same
# class of bug as the zombie-detection fix in detect-resume.sh. A clean
# exit code from the STEP_6 completion call site is unambiguous: it can only
# mean the run succeeded just now, so it must win over any log history.
_outcome_summary=""
if [ -n "$OUTCOME_OVERRIDE" ]; then
  _outcome_summary="$OUTCOME_OVERRIDE"
elif [ "$EXIT_CODE" -eq 0 ]; then
  _outcome_summary="completed: STEP_6"
elif grep -q '|META|gate-held|' "$LOG_FILE" 2>/dev/null; then
  _outcome_summary="held: gate"
elif grep -q '|META|gate-stop|fail|' "$LOG_FILE" 2>/dev/null; then
  _gs_code=$(grep '|META|gate-stop|fail|' "$LOG_FILE" | tail -1 | awk -F'|' '{for(i=5;i<=NF;i++) printf "%s%s", $i, (i==NF?"":"|")}')
  _outcome_summary="stopped: gate-stop ${_gs_code}"
elif grep -q 'VERIFY_EXHAUSTED' "$LOG_FILE" 2>/dev/null; then
  _outcome_summary="stopped: VERIFY_EXHAUSTED"
elif grep -q 'PR_FEEDBACK_EXHAUSTED' "$LOG_FILE" 2>/dev/null; then
  _outcome_summary="stopped: PR_FEEDBACK_EXHAUSTED"
else
  _outcome_summary="stopped: exit ${EXIT_CODE}"
fi

# Tail-check guard: skip only if the LAST line is an outcome entry (F10 fix).
# A grep anywhere in the log means nothing — crash-resume leaves stale outcomes
# mid-log. Only a tail-match indicates this run already wrote outcome.
_last_line=$(tail -1 "$LOG_FILE" 2>/dev/null || true)
if echo "$_last_line" | grep -q '|META|outcome|info|'; then
  exit "${EXIT_CODE}"
fi

echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|META|outcome|info|${_outcome_summary}" >>"$LOG_FILE"

exit "${EXIT_CODE}"
