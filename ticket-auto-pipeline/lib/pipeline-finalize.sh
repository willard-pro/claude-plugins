#!/usr/bin/env bash
# pipeline-finalize.sh — deterministic exit finalizer for ticket-auto router.
# RLVR Phase 3: runs postmortem analysis, writes META|outcome, and exits.
# Commercial Evidence MVP (Branch B): also appends the post-outcome
# runs.jsonl sequence — run event, merge-poll sweep, human event — all
# strictly AFTER META|outcome is on disk, never modifying the pipeline log.
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

_PF_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

TICKET_ID="${1:-}"
EXIT_CODE="${2:-0}"
LOG_FILE="${3:-}"
OUTCOME_OVERRIDE="${4:-}"

if [ -z "$TICKET_ID" ] || [ -z "$LOG_FILE" ]; then
  echo "[pipeline-finalize] WARN: missing required args" >&2
  exit "${EXIT_CODE}"
fi

# ── Human hold detection (human-hold-protocol) ──────────────────────────────
# True when the log's latest *valid* human-hold record has no later
# `META|human-hold-released` marker. Mirrors the `held: gate` sibling: a hold
# is a log fact here, not a store lookup — pipeline-finalize.sh runs inside
# the router/worker process, which never opens the fleet state store. An
# `invalid` record is deliberately NOT a hold (human-hold-request spec: "An
# invalid request creates no hold row") — it stays visible to
# `detect_human_hold` without parking the ticket on a premise nothing could
# parse.
_pf_has_unreleased_human_hold() {
  local log_file="$1"
  local last_valid_lineno=0 lineno=0 line step msg
  while IFS= read -r line; do
    lineno=$((lineno + 1))
    step=$(printf '%s' "$line" | awk -F'|' '{print $3}')
    [ "$step" = "human-hold" ] || continue
    msg=$(printf '%s' "$line" | awk -F'|' '{s=$5; for(i=6;i<=NF;i++) s=s"|"$i; print s}')
    case "$msg" in *'"parse_status":"ok"'*) last_valid_lineno=$lineno ;; esac
  done <"$log_file"
  [ "$last_valid_lineno" -gt 0 ] || return 1

  local released_lineno=0
  lineno=0
  while IFS= read -r line; do
    lineno=$((lineno + 1))
    step=$(printf '%s' "$line" | awk -F'|' '{print $3}')
    [ "$step" = "human-hold-released" ] && released_lineno=$lineno
  done <"$log_file"

  [ "$released_lineno" -gt "$last_valid_lineno" ] && return 1
  return 0
}

# ── Post-outcome evidence sequence (Branch B, Commercial Evidence MVP) ──────
# Runs AFTER META|outcome is already on disk (guaranteed by every call site
# below). Every step is wrapped `|| true` and never touches EXIT_CODE or the
# pipeline log — all facts land in runs.jsonl instead.
_pf_post_outcome() {
  local tid="$1" exit_code="$2" log_file="$3"

  [ -f "$_PF_LIB_DIR/run-summary.sh" ] || return 0
  source "$_PF_LIB_DIR/run-summary.sh" 2>/dev/null || return 0

  local runs_file
  runs_file="$(dirname "$log_file")/runs.jsonl"

  # Idempotency guard: skip the whole sequence if a run event for this
  # run_id already exists (F: idempotent re-run of finalize itself).
  local run_id
  run_id=$(run_summary_window "$log_file" 2>/dev/null | grep '|META|run-id|info|' | tail -1 |
    awk -F'|' '{s=$5; for(i=6;i<=NF;i++) s=s"|"$i; print s}' | jq -r '.run_id // empty' 2>/dev/null) || true

  if [ -n "$run_id" ] && [ -f "$runs_file" ] &&
    jq -e --arg rid "$run_id" 'select(.kind == "run" and .run_id == $rid)' "$runs_file" >/dev/null 2>&1; then
    return 0
  fi

  local run_json
  run_json=$(run_summary_json "$tid" "$log_file" "$exit_code" 2>/dev/null) || run_json=""
  [ -n "$run_json" ] && runs_append "$runs_file" "$run_json"

  # One-shot merge-poll sweep, only when this run produced a PR. Via the CLI
  # entrypoint (not a sourced function call) so `timeout` can actually bound
  # it — timeout cannot exec a bash function directly (same constraint
  # documented in run-identity.sh's run_identity_ticket_meta).
  local has_pr
  has_pr=$(echo "$run_json" | jq -r '(.pr // null) != null' 2>/dev/null) || has_pr="false"
  if [ "$has_pr" = "true" ] && [ -f "$_PF_LIB_DIR/merge-poll.sh" ] && command -v gh >/dev/null 2>&1; then
    timeout 20 bash "$_PF_LIB_DIR/merge-poll.sh" --tid "$tid" "$runs_file" 2>/dev/null || true
  fi

  # Human event, only when a Linear key is available.
  if [ -n "${LINEAR_API_KEY:-}" ] && [ -f "$_PF_LIB_DIR/linear-api.sh" ]; then
    local history_json comments_json me_json my_id human_json
    history_json=$(timeout 20 bash -c "source '$_PF_LIB_DIR/linear-api.sh'; get_issue_history '$tid'" 2>/dev/null) || history_json=""
    comments_json=$(timeout 20 bash -c "source '$_PF_LIB_DIR/linear-api.sh'; get_comments '$tid'" 2>/dev/null) || comments_json=""
    me_json=$(timeout 20 bash -c "source '$_PF_LIB_DIR/linear-api.sh'; get_me" 2>/dev/null) || me_json=""
    echo "$history_json" | jq -e . >/dev/null 2>&1 || history_json="[]"
    echo "$comments_json" | jq -e . >/dev/null 2>&1 || comments_json="[]"
    my_id=$(echo "$me_json" | jq -r '.id // empty' 2>/dev/null) || true

    human_json=$(jq -nc \
      --argjson history "$history_json" --argjson comments "$comments_json" \
      --arg my_id "${my_id:-}" --arg tid "$tid" --arg run_id "${run_id:-}" '
      def is_approval_label: (.addedLabels // []) | map(.name // "" | ascii_downcase) | any(contains("approved"));
      def is_human: (.botActor == null) and ((.actor.id // "") != $my_id);
      ($history | map(select(is_approval_label and is_human)) | sort_by(.createdAt) | last) as $approval |
      ($history | map(select(is_human))) as $human_actions |
      ($comments | map(select((.user.id // "") != $my_id)) | map(.body // "" | split(" ") | length) | add // 0) as $comment_words |
      {
        kind: "human", tid: $tid, run_id: (if $run_id == "" then null else $run_id end),
        approved_by: ($approval.actor.name // null),
        approved_at: ($approval.createdAt // null),
        human_actions: ($human_actions | length),
        comment_words: $comment_words,
        observed_at: (now | strftime("%Y-%m-%dT%H:%M:%SZ"))
      }' 2>/dev/null) || human_json=""
    [ -n "$human_json" ] && runs_append "$runs_file" "$human_json"
  fi

  return 0
}

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
elif _pf_has_unreleased_human_hold "$LOG_FILE"; then
  _outcome_summary="held: human"
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
# mid-log. Only a tail-match indicates this run already wrote outcome. Either
# way, the post-outcome sequence below still runs — it is guarded on its own
# run_id idempotency key, independent of this outcome-write guard, so a
# retried finalize call reaches it even when the outcome line was written by
# an earlier call.
_last_line=$(tail -1 "$LOG_FILE" 2>/dev/null || true)
if ! echo "$_last_line" | grep -q '|META|outcome|info|'; then
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|META|outcome|info|${_outcome_summary}" >>"$LOG_FILE"
fi

_pf_post_outcome "$TICKET_ID" "$EXIT_CODE" "$LOG_FILE" || true

exit "${EXIT_CODE}"
