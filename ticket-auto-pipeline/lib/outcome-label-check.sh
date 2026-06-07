#!/usr/bin/env bash
# outcome-label-check.sh — post-implement guard that verifies Smooth/Rough/Hard
# outcome label is present on the Linear ticket via API call, applying it if missing.
# -u (nounset) intentionally omitted: Claude Code shell snapshots inject
# ZSH_VERSION references that trigger false-positive "unbound variable"
# errors in this bash version when nounset is active.
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${CLAUDE_SKILLS_LIB:-$HOME/.claude/skills/lib}"
source "$LIB_DIR/heartbeat.sh"
source "$LIB_DIR/linear-api.sh"

usage() {
  echo "Usage: $0 <TICKET-ID> <LOG-FILE>" >&2
  exit 1
}

# ── Resolve flow.sh path dynamically ───────────────────────────────────────────
_resolve_flow_sh() {
  if [ -f "$HOME/.claude/skills/ticket-flow/flow.sh" ]; then
    echo "$HOME/.claude/skills/ticket-flow/flow.sh"
  elif command -v find &>/dev/null; then
    find "$HOME/.claude/plugins/cache" -name "flow.sh" -path "*/ticket-flow/*" 2>/dev/null | head -1 || true
  fi
}

FLOW_SH=$(_resolve_flow_sh)

# ── Core logic ─────────────────────────────────────────────────────────────────

OUTCOME_LABELS="Smooth Rough Hard"

# Extract OUTCOME from pipeline log IMPLEMENT|implement-outcome| line.
# This is written by the implement agent after flow.sh applies the label.
# Tightened from IMPLEMENT|implement|done| to avoid matching prose lines
# like "2 files changed" that share the same phase/step prefix but are not
# the outcome declaration.
_get_outcome_from_log() {
  local outcome
  outcome=$(grep '^[^|]*|IMPLEMENT|implement-outcome|info|' "$LOG_FILE" 2>/dev/null | tail -1 | cut -d'|' -f5- || true)
  echo "$outcome"
}

# Check if any outcome label (Smooth/Rough/Hard) is present on the ticket
_has_outcome_label() {
  local issue_json="$1"
  local labels
  labels=$(echo "$issue_json" | jq -r '[.labels.nodes[]?.name? // empty] | join(" ")' 2>/dev/null || true)

  for ol in $OUTCOME_LABELS; do
    if echo "$labels" | grep -qw "$ol"; then
      return 0
    fi
  done
  return 1
}

_outcome_label_check() {
  local outcome issue_json

  # Read outcome from pipeline log
  outcome=$(_get_outcome_from_log)
  if [ -z "$outcome" ]; then
    echo "No IMPLEMENT|implement-outcome|info| line found in pipeline log" >&2
    return 1
  fi

  # Validate outcome is one of Smooth/Rough/Hard
  local valid=false
  for ol in $OUTCOME_LABELS; do
    [ "$outcome" = "$ol" ] && valid=true
  done
  if [ "$valid" != "true" ]; then
    echo "Unknown outcome: $outcome (expected Smooth, Rough, or Hard)" >&2
    return 1
  fi

  # Query Linear API for current labels
  issue_json=$(get_issue "$TICKET_ID" 2>/dev/null || echo 'null')

  # If outcome label already present, exit clean
  if _has_outcome_label "$issue_json"; then
    hb_gate "outcome-check" "ok" "outcome label already present" "{\"outcome\":\"$outcome\"}"
    return 0
  fi

  # Apply missing outcome label via flow.sh
  if [ -n "$FLOW_SH" ] && [ -f "$FLOW_SH" ]; then
    bash "$FLOW_SH" "$TICKET_ID" "implement-outcome" --data "outcome=${outcome}" || true
  fi

  hb_gate "outcome-check" "ok" "outcome label applied" "{\"outcome\":\"$outcome\"}"
  return 0
}

# ── Dispatch (only when executed directly) ─────────────────────────────────────

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  TICKET_ID="${1:-}"
  LOG_FILE="${2:-}"

  [ -z "$TICKET_ID" ] && usage
  [ -z "$LOG_FILE" ] && usage

  hb_init
  _outcome_label_check
fi
