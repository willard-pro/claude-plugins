#!/usr/bin/env bash
# planned-feedback-write.sh — Post-implement hook that emits META|planner-feedback
# entries to the pipeline log for planned tickets.
#
# Conditional on the planned label or FROM_PLANNED=true — no behavior change
# for unplanned tickets. fleet-feedback.sh aggregates these entries by initiative.
#
# Usage: planned_feedback_write <TICKET_ID> <LOG_FILE>
# Returns: 0 on success (or no-op skip), non-zero on error.
#
# Sourceable library — no set -euo pipefail.

# ── Main entry point ────────────────────────────────────────────────────────────

planned_feedback_write() {
  local tid="$1" log_file="$2"

  # Gate: only emit feedback for planned tickets
  if [ "${FROM_PLANNED:-false}" != "true" ]; then
    # Check if the ticket has the planned label via Linear API
    local has_planned=false
    if declare -f get_issue >/dev/null 2>&1; then
      local labels
      labels=$(get_issue "$tid" 2>/dev/null | jq -r '.labels.nodes[]?.name // empty' 2>/dev/null || true)
      if echo "$labels" | grep -qw 'planned'; then
        has_planned=true
      fi
    fi
    if [ "$has_planned" != "true" ]; then
      return 0  # Not a planned ticket — silent no-op
    fi
  fi

  # Ensure log file exists
  if [ ! -f "$log_file" ]; then
    echo "planned-feedback-write: log file not found: $log_file" >&2
    return 1
  fi

  # ── Gather data from pipeline log ────────────────────────────────────────────

  # Outcome label (Smooth/Rough/Hard)
  local outcome
  outcome=$(grep '^[^|]*|META|outcome-label|info|' "$log_file" 2>/dev/null | tail -1 | awk -F'|' '{for(i=5;i<=NF;i++) printf "%s%s", $i, (i<NF?"|":"")}')

  # Corrections count (from CORRECTIONS blocks in notes.md, or pipeline log)
  local corrections_count=0
  if grep -q '^[^|]*|META|corrections|' "$log_file" 2>/dev/null; then
    corrections_count=$(grep -c '^[^|]*|META|corrections|' "$log_file" 2>/dev/null || echo 0)
  fi

  # Files changed — from IMPLEMENT phase log entries, or git diff
  local files_changed="[]"
  local branch
  branch=$(grep '^[^|]*|META|branch|info|' "$log_file" 2>/dev/null | tail -1 | awk -F'|' '{for(i=5;i<=NF;i++) printf "%s%s", $i, (i<NF?"|":"")}')
  if [ -n "$branch" ] && [ -d "$PWD/.git" ]; then
    # Try to get files changed on the branch vs main
    if git rev-parse "$branch" >/dev/null 2>&1; then
      files_changed=$(git diff --name-only "origin/main...${branch}" 2>/dev/null | jq -R -s 'split("\n") | map(select(length > 0))' 2>/dev/null || echo "[]")
    fi
  fi
  # Fallback: log any files referenced in implement step
  if [ "$files_changed" = "[]" ] || [ "$files_changed" = "" ]; then
    files_changed=$(grep '^[^|]*|IMPLEMENT|' "$log_file" 2>/dev/null | awk -F'|' '{for(i=5;i<=NF;i++) printf "%s%s", $i, (i<NF?"|":"")}' | grep -oP '/?[a-zA-Z0-9_/.-]+\.[a-zA-Z]+' 2>/dev/null | sort -u | jq -R -s 'split("\n") | map(select(length > 0))' 2>/dev/null || echo "[]")
  fi

  # ── Confidence ───────────────────────────────────────────────────────────────

  # Predicted confidence — extracted from Planner Context block in ticket description
  local confidence_predicted=0
  if declare -f get_issue >/dev/null 2>&1; then
    local description
    description=$(get_issue "$tid" 2>/dev/null | jq -r '.description // ""' 2>/dev/null || true)
    if [ -n "$description" ]; then
      # Extract Confidence field from Planner Context block
      local conf_line
      conf_line=$(echo "$description" | sed -n '/## Planner Context/,/^## /p' | grep -i '^\s*-\s*Confidence:' | head -1)
      if [ -n "$conf_line" ]; then
        confidence_predicted=$(echo "$conf_line" | grep -oP '[\d.]+' | head -1 || echo 0)
      fi
    fi
  fi

  # Actual confidence — derived from outcome signals
  local confidence_actual
  confidence_actual=$(_compute_actual_confidence "$outcome" "$corrections_count")

  # ── Services touched ─────────────────────────────────────────────────────────

  local services_touched="[]"
  # Extract from Planner Context block
  if [ -n "$description" ]; then
    services_touched=$(echo "$description" | sed -n '/## Planner Context/,/^## /p' | grep -i '^\s*-\s*Affected Services:' | head -1 | sed 's/.*Affected Services:\s*//' | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | grep -v '^$' | jq -R -s 'split("\n") | map(select(length > 0))' 2>/dev/null || echo "[]")
  fi

  # ── Decision drift ───────────────────────────────────────────────────────────

  local decision_drift
  decision_drift=$(_compute_decision_drift "$confidence_predicted" "$confidence_actual")

  # ── Emit feedback entry ──────────────────────────────────────────────────────

  local payload iso
  payload=$(jq -nc \
    --argjson confidence_predicted "$confidence_predicted" \
    --argjson confidence_actual "$confidence_actual" \
    --arg outcome "$outcome" \
    --argjson corrections_count "$corrections_count" \
    --argjson files_changed "$files_changed" \
    --argjson services_touched "$services_touched" \
    --arg decision_drift "$decision_drift" \
    '{
      confidence_predicted: $confidence_predicted,
      confidence_actual: $confidence_actual,
      outcome: $outcome,
      corrections_count: $corrections_count,
      files_changed: $files_changed,
      services_touched: $services_touched,
      decision_drift: $decision_drift
    }' 2>/dev/null)

  if [ -z "$payload" ]; then
    echo "planned-feedback-write: jq payload construction failed" >&2
    return 1
  fi

  iso=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  echo "${iso}|META|planner-feedback|info|${payload}" >> "$log_file"

  return 0
}

# ── Helpers ─────────────────────────────────────────────────────────────────────

# Compute actual confidence from outcome and corrections.
# Smooth → 0.85+, Rough → 0.50–0.84, Hard → <0.50
# Corrections subtract 0.05 each.
_compute_actual_confidence() {
  local outcome="$1" corrections="${2:-0}"
  local base

  case "$outcome" in
  Smooth) base=90 ;;
  Rough) base=65 ;;
  Hard) base=40 ;;
  *) base=70 ;; # Unknown outcome — neutral
  esac

  # Subtract corrections
  local penalty=$((corrections * 5))
  local score=$((base - penalty))

  # Floor at 10
  [ "$score" -lt 10 ] && score=10

  # Convert to 0-1 scale (divide by 100)
  echo "0.${score}"
}

# Compute decision drift label from predicted vs actual confidence.
# none: ≤0.10, minor: 0.11–0.25, major: >0.25
_compute_decision_drift() {
  local predicted="$1" actual="$2"

  # Handle missing/zero values
  [ -z "$predicted" ] && predicted=0
  [ -z "$actual" ] && actual=0

  # Scale to integer hundredths for bash arithmetic
  local p_int a_int diff
  p_int=$(echo "$predicted * 100" | bc 2>/dev/null | cut -d'.' -f1 || echo 0)
  a_int=$(echo "$actual * 100" | bc 2>/dev/null | cut -d'.' -f1 || echo 0)

  diff=$((p_int - a_int))
  [ "$diff" -lt 0 ] && diff=$((-diff))

  if [ "$diff" -le 10 ]; then
    echo "none"
  elif [ "$diff" -le 25 ]; then
    echo "minor"
  else
    echo "major"
  fi
}
