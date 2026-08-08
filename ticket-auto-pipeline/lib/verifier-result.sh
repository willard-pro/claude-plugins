#!/usr/bin/env bash
# verifier-result.sh — Uniform verifier-result recording for ticket-auto-pipeline.
# Phase 0 of the RLVR program.
#
# Usage: source this file, then call write_verifier_result with named params.
#
#   write_verifier_result \
#     verifier=<id> verdict=<PASS|FAIL|WARN|BLOCK> \
#     [criteria_met=<int>] [criteria_total=<int>] \
#     [attempt=<int>] [phase=<token>] \
#     [outcome=<Smooth|Rough|Hard>] [corrections=<int>]
#
# All params after the first nine are ignored (forward-compat).
# If LOG_FILE is unset or empty, the function logs to stderr and returns 0.

# -u (nounset) intentionally omitted: Claude Code shell snapshots inject
# ZSH_VERSION references that trigger false-positive "unbound variable"
# errors in this bash version when nounset is active. Repo convention
# across 10+ lib files omits -u for this reason (F3).
set -eo pipefail

# ── Score helpers ────────────────────────────────────────────────────────────────

# F9: _compute_actual_confidence extracted to lib/confidence.sh to prevent drift
# between verifier-result.sh and planned-feedback-write.sh.
VERIFIER_RESULT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$VERIFIER_RESULT_DIR/confidence.sh" ]; then
  source "$VERIFIER_RESULT_DIR/confidence.sh"
elif [ -f "${CLAUDE_SKILLS_LIB:-$HOME/.claude/skills/lib}/confidence.sh" ]; then
  source "${CLAUDE_SKILLS_LIB:-$HOME/.claude/skills/lib}/confidence.sh"
fi

# ── Primary function ─────────────────────────────────────────────────────────────

write_verifier_result() {
  local verifier="" verdict="" criteria_met=0 criteria_total=0 attempt=1 phase=""
  local outcome="" corrections=0

  # Parse named params
  # F14: ${arg#prefix=} strips only the first '=' — verifier names MUST NOT
  # contain '='. All current verifier names are constants (gate_check,
  # return_completeness, playwright_uat, etc.) so this is safe in practice.
  for arg in "$@"; do
    case "$arg" in
    verifier=*) verifier="${arg#verifier=}" ;;
    verdict=*) verdict="${arg#verdict=}" ;;
    criteria_met=*) criteria_met="${arg#criteria_met=}" ;;
    criteria_total=*) criteria_total="${arg#criteria_total=}" ;;
    attempt=*) attempt="${arg#attempt=}" ;;
    phase=*) phase="${arg#phase=}" ;;
    outcome=*) outcome="${arg#outcome=}" ;;
    corrections=*) corrections="${arg#corrections=}" ;;
    esac
  done

  # Validate required fields
  if [ -z "$verifier" ] || [ -z "$verdict" ]; then
    echo "[verifier-result] WARN: missing required field (verifier or verdict), skipping" >&2
    return 0
  fi

  # Validate verdict enum
  case "$verdict" in
  PASS | FAIL | WARN | BLOCK) ;;
  *)
    echo "[verifier-result] WARN: invalid verdict '${verdict}', skipping" >&2
    return 0
    ;;
  esac

  # Validate criteria_met/criteria_total are integers
  if ! [[ "$criteria_met" =~ ^[0-9]+$ ]]; then
    criteria_met=0
  fi
  if ! [[ "$criteria_total" =~ ^[0-9]+$ ]]; then
    criteria_total=0
  fi
  if ! [[ "$attempt" =~ ^[0-9]+$ ]]; then
    attempt=1
  fi
  if ! [[ "$corrections" =~ ^[0-9]+$ ]]; then
    corrections=0
  fi

  # Compute score
  local score
  case "$verdict" in
  PASS) score="1.0" ;;
  FAIL)
    if [ "$criteria_total" -eq 0 ]; then
      score="0.0"
    else
      # Bash division to 3 decimal places
      score=$(awk "BEGIN { printf \"%.3f\", $criteria_met / $criteria_total }")
    fi
    ;;
  WARN) score="0.7" ;;
  BLOCK) score="0.0" ;;
  esac

  # If outcome is provided, override with confidence scale score
  if [ -n "$outcome" ]; then
    score=$(_compute_actual_confidence "$outcome" "$corrections")
  fi

  # F8: clamp score to [0,1] — criteria_met > criteria_total would produce
  # score > 1.0; PASS defaults to 1.0 which is within range but any future
  # code path that computes a ratio on PASS must stay bounded.
  # awk float comparison: exit 0 if score > 1.0, exit 1 otherwise.
  if awk "BEGIN { exit($score > 1.0 ? 0 : 1) }" 2>/dev/null; then
    score="1.0"
  elif awk "BEGIN { exit($score < 0.0 ? 0 : 1) }" 2>/dev/null; then
    score="0.0"
  fi

  # Build JSON payload
  local iso
  iso=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  local json
  json=$(printf '{"verifier":"%s","verdict":"%s","score":%s,"criteria_met":%d,"criteria_total":%d,"attempt":%d,"phase":"%s"}' \
    "$verifier" "$verdict" "$score" "$criteria_met" "$criteria_total" "$attempt" "$phase")

  # Validate JSON with jq; skip on failure
  if ! command -v jq >/dev/null 2>&1; then
    echo "[verifier-result] WARN: jq not available, skipping verifier-result write" >&2
    return 0
  fi

  if ! echo "$json" | jq -e . >/dev/null 2>&1; then
    echo "[verifier-result] WARN: jq validation failed for payload, skipping" >&2
    return 0
  fi

  # Write to pipeline log
  if [ -z "${LOG_FILE:-}" ]; then
    echo "[verifier-result] WARN: LOG_FILE unset, skipping verifier-result write" >&2
    return 0
  fi

  # F4: guard the final log append — disk full or unwritable LOG_FILE must not
  # abort the caller (all 6 pre-write validation paths return 0 gracefully)
  echo "${iso}|META|verifier-result|info|${json}" >>"$LOG_FILE" || {
    echo "[verifier-result] WARN: log write failed (LOG_FILE=${LOG_FILE})" >&2
    return 0
  }
  return 0
}
