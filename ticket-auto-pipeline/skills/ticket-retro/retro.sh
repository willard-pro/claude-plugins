#!/usr/bin/env bash
# retro.sh — pipeline log aggregator for /ticket-retro
# Reads pipeline logs in a time window, extracts |META| failure events,
# builds failure histograms and complexity prediction accuracy data,
# and emits structured JSON to stdout.
#
# Usage:
#   retro.sh --window <N>d [<single-log-path>]
#   retro.sh --window 7d
#   retro.sh --window 1 ./logs/CRE-47-pipeline.log

set -euo pipefail

WINDOW="7d"
POSITIONAL_LOG=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --window) WINDOW="$2"; shift 2 ;;
    *) POSITIONAL_LOG="$1"; shift ;;
  esac
done

# ── Source the shared complexity parser ──────────────────────────────────
LIBS_DIR="$(dirname "$(readlink -f "$0")")/../lib"
# shellcheck source=../lib/notes-parse.sh
source "$LIBS_DIR/notes-parse.sh" 2>/dev/null || {
  get_complexity() {
    local ticket_dir="$1"
    local notes="$ticket_dir/notes.md"
    [ -f "$notes" ] || return 0
    grep -A3 '## Complexity' "$notes" 2>/dev/null \
      | grep '^\*\*Score:' \
      | awk '{print $2}' \
      | tr -d '\r' \
      || true
  }
}

WINDOW_DAYS="${WINDOW%d}"
LOGS_DIR="./logs"

# ── Log file discovery ───────────────────────────────────────────────────

declare -a LOG_FILES=()

if [ -n "$POSITIONAL_LOG" ]; then
  [ -f "$POSITIONAL_LOG" ] && LOG_FILES=("$POSITIONAL_LOG")
else
  if [ -d "$LOGS_DIR" ]; then
    while IFS= read -r -d '' log; do
      LOG_FILES+=("$log")
    done < <(find "$LOGS_DIR" -name '*-pipeline.log' -mtime -"$WINDOW_DAYS" -print0 2>/dev/null || true)
  fi
fi

if [ ${#LOG_FILES[@]} -eq 0 ]; then
  echo "no pipeline logs found in window" >&2
  exit 1
fi

# ── Aggregation state ────────────────────────────────────────────────────

declare -A FAILURE_COUNT=()
GATE_STOP_TOTAL=0
LOGS_SCANNED=0
LOGS_WITH_FAILURES=0

# Build predictions as a JSON array string, one element at a time
PREDICTIONS_JSON="["
PRED_FIRST=1

CORRECT_COUNT=0
TOTAL_PAIRS=0

# ── Process each log ─────────────────────────────────────────────────────

for log_file in "${LOG_FILES[@]}"; do
  LOGS_SCANNED=$((LOGS_SCANNED + 1))
  local_has_failure=0

  stem=$(basename "$log_file" .log)
  ticket_id="${stem%-pipeline}"

  # Resolve ticket directory from the log's notes artifact line
  ticket_dir=""
  notes_line=$(grep '|META|artifact|info|notes:' "$log_file" 2>/dev/null | tail -1 || true)
  if [ -n "$notes_line" ]; then
    notes_path=$(echo "$notes_line" | cut -d'|' -f5 | sed 's/^notes://')
    [ -n "$notes_path" ] && [ -f "$notes_path" ] && ticket_dir=$(dirname "$notes_path")
  fi
  [ -z "$ticket_dir" ] && ticket_dir=$(find . -type d -name "${ticket_id}*" -print -quit 2>/dev/null || true)

  # ── Scan for failures ─────────────────────────────────────────────────
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    IFS='|' read -r _ts phase step status msg <<< "$line"
    [ "$phase" != "META" ] && continue

    if [ "$step" = "gate-stop" ] && [ "$status" = "fail" ]; then
      GATE_STOP_TOTAL=$((GATE_STOP_TOTAL + 1))
      code=$(echo "$msg" | awk '{print $1}')
      FAILURE_COUNT["$code"]=$((${FAILURE_COUNT["$code"]:-0} + 1))
      local_has_failure=1
    elif [ "$status" = "fail" ] && [ "$step" != "schema" ] && [ "$step" != "migration" ]; then
      FAILURE_COUNT["$step"]=$((${FAILURE_COUNT["$step"]:-0} + 1))
      local_has_failure=1
    fi
  done < "$log_file"

  [ "$local_has_failure" -eq 1 ] && LOGS_WITH_FAILURES=$((LOGS_WITH_FAILURES + 1))

  # ── Complexity prediction pair ─────────────────────────────────────────
  declared="null"
  if [ -n "$ticket_dir" ] && [ -d "$ticket_dir" ]; then
    d=$(get_complexity "$ticket_dir" || true)
    [ -n "$d" ] && declared="$d"
  fi

  actual="null"
  actual_source="missing"
  outcome_line=$(grep '|IMPLEMENT|implement|done|' "$log_file" 2>/dev/null | tail -1 || true)
  if [ -n "$outcome_line" ]; then
    outcome_msg=$(echo "$outcome_line" | cut -d'|' -f5)
    actual=$(echo "$outcome_msg" | cut -d',' -f1)
    actual_source="log"
  fi

  # Append to predictions JSON array
  [ "$PRED_FIRST" -eq 1 ] && PRED_FIRST=0 || PREDICTIONS_JSON+=", "
  PREDICTIONS_JSON+="{\"ticket\":\"$ticket_id\",\"declared\":\"$declared\",\"actual\":\"$actual\",\"actual_source\":\"$actual_source\"}"

  # Track accuracy
  if [ "$declared" != "null" ] && [ "$actual" != "null" ]; then
    TOTAL_PAIRS=$((TOTAL_PAIRS + 1))
    if { [ "$declared" = "simple" ] && [ "$actual" = "Smooth" ]; } || \
       { [ "$declared" = "complex" ] && { [ "$actual" = "Rough" ] || [ "$actual" = "Hard" ]; }; }; then
      CORRECT_COUNT=$((CORRECT_COUNT + 1))
    fi
  fi
done

PREDICTIONS_JSON+="]"

# ── Build failure histogram JSON (sorted descending by count) ────────────

HISTOGRAM_JSON="{"
HIST_FIRST=1
for code in "${!FAILURE_COUNT[@]}"; do
  echo "${FAILURE_COUNT[$code]} $code"
done | sort -rn | while read -r count code; do
  # This while-read runs in a subshell due to the pipe, so we use a temp file
  echo "$count $code"
done > /tmp/retro-hist-sorted.$$.txt

# Re-read from temp file to avoid subshell issues
HISTOGRAM_JSON="{"
HIST_FIRST=1
while read -r count code; do
  [ -z "$code" ] && continue
  [ "$HIST_FIRST" -eq 1 ] && HIST_FIRST=0 || HISTOGRAM_JSON+=", "
  HISTOGRAM_JSON+="\"$code\": $count"
done < /tmp/retro-hist-sorted.$$.txt
HISTOGRAM_JSON+="}"
rm -f /tmp/retro-hist-sorted.$$.txt

# ── Compute complexity accuracy ──────────────────────────────────────────

ACCURACY=0
if [ "$TOTAL_PAIRS" -gt 0 ]; then
  ACCURACY=$(awk "BEGIN { printf \"%.3f\", $CORRECT_COUNT / $TOTAL_PAIRS }")
fi

# ── Emit final JSON ──────────────────────────────────────────────────────

jq -n \
  --argjson window_days "$WINDOW_DAYS" \
  --argjson logs_scanned "$LOGS_SCANNED" \
  --argjson logs_with_failures "$LOGS_WITH_FAILURES" \
  --argjson gate_stop_total "$GATE_STOP_TOTAL" \
  --argjson complexity_accuracy "$ACCURACY" \
  --arg histogram_str "$HISTOGRAM_JSON" \
  --arg predictions_str "$PREDICTIONS_JSON" \
  '{
    window_days: $window_days,
    logs_scanned: $logs_scanned,
    logs_with_failures: $logs_with_failures,
    failure_histogram: ($histogram_str | fromjson),
    gate_stop_total: $gate_stop_total,
    complexity_predictions: ($predictions_str | fromjson),
    complexity_accuracy: $complexity_accuracy
  }'
