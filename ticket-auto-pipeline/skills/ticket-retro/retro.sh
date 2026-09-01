#!/usr/bin/env bash
# retro.sh — pipeline log aggregator for /ticket-retro
# Reads pipeline logs in a time window, extracts |META| failure events,
# builds failure histograms and complexity prediction accuracy data,
# and emits structured JSON to stdout.
#
# Usage:
#   retro.sh --window <N>d [--force] [<single-log-path>]
#   retro.sh --window 7d
#   retro.sh --window 1 --force ./logs/CRE-47-pipeline.log

# -u (nounset) intentionally omitted: Claude Code shell snapshots inject
# ZSH_VERSION references that trigger false-positive "unbound variable"
# errors in this bash version when nounset is active.
set -eo pipefail

# ══════════════════════════════════════════════════════════════════════════════
# Claude Log Scan Helpers (sourced by ticket-retro SKILL.md)
# ══════════════════════════════════════════════════════════════════════════════

# scan_claude_log_failures <claude-log> <output-file>
# Grep for high-signal failure keywords, capped at 200 lines.
# Returns 1 if log file missing; 0 otherwise (empty output is valid).
scan_claude_log_failures() {
  local claude_log="$1"
  local output="$2"
  [ ! -f "$claude_log" ] && return 1
  grep -i -n \
    -e "permission denied" \
    -e "command not found" \
    -e "no such file" \
    -e "exit code" \
    -e "exited with" \
    -e "timeout" \
    -e "rate limit" \
    -e "429" \
    -e "STATE_ASSERTION_FAILED" \
    -e "EXEC_NO_ARTIFACT" \
    -e "fatal:" \
    -e "could not" \
    -e "unable to" \
    -e "failed to" \
    "$claude_log" 2>/dev/null |
    head -200 >"$output"
  return 0
}

# correlate_failures_with_phase <claude-log> <failures-file> <output-file>
# Takes grep -n failure output (line_num:text), finds the most recent
# phase boundary above each failure, and writes a phase-grouped report.
# Phase boundaries are pipe-delimited lines where field 2 matches a
# known pipeline phase.
correlate_failures_with_phase() {
  local claude_log="$1"
  local failures_file="$2"
  local output="$3"

  [ ! -f "$failures_file" ] && return 1
  [ ! -s "$failures_file" ] && return 1

  # Build a sorted list of phase boundary line numbers and their phase names
  local boundary_file
  boundary_file="$(mktemp)"
  grep -n -E '^\d{4}-\d{2}-\d{2}T[^|]+\|(APPRAISE|EXEC|GATE|IMPLEMENT|VERIFY|PR-REVIEW|MAINTENANCE)\|' \
    "$claude_log" 2>/dev/null |
    cut -d: -f1 |
    while read -r b_ln; do
      phase=$(sed -n "${b_ln}p" "$claude_log" | cut -d'|' -f2)
      echo "${b_ln} ${phase}"
    done >"$boundary_file"

  local tmp_result
  tmp_result="$(mktemp)"

  local has_boundaries=0
  [ -s "$boundary_file" ] && has_boundaries=1

  while IFS=: read -r line_num rest; do
    local phase="Unknown"
    if [ "$has_boundaries" -eq 1 ]; then
      # Find the largest boundary line number <= this failure line
      local prev
      prev=$(awk -v target="$line_num" '$1 <= target { last=$0 } END { print last }' "$boundary_file")
      if [ -n "$prev" ]; then
        phase=$(echo "$prev" | awk '{print $2}')
      fi
    fi
    echo "${phase}|${line_num}|${rest}" >>"$tmp_result"
  done <"$failures_file"

  # Write grouped output
  {
    if [ "$has_boundaries" -eq 0 ]; then
      echo "<!-- Phase correlation unavailable — no phase boundary entries found in Claude log -->"
    fi
    for p in APPRAISE EXEC GATE IMPLEMENT VERIFY PR-REVIEW MAINTENANCE Unknown; do
      local count
      count=$(grep -c "^${p}|" "$tmp_result" 2>/dev/null || echo 0)
      if [ "$count" -gt 0 ]; then
        echo ""
        echo "### ${p} phase — ${count} failure(s)"
        grep "^${p}|" "$tmp_result" | while IFS='|' read -r _ph _ln _rst; do
          echo "- line ${_ln}: ${_rst}"
        done
      fi
    done
  } >"$output"

  rm -f "$boundary_file" "$tmp_result"
  return 0
}

WINDOW="7d"
POSITIONAL_LOG=""
FORCE_RESCAN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
  --window)
    WINDOW="$2"
    shift 2
    ;;
  --force)
    FORCE_RESCAN=1
    shift
    ;;
  *)
    POSITIONAL_LOG="$1"
    shift
    ;;
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
    grep -A3 '## Complexity' "$notes" 2>/dev/null |
      grep '^\*\*Score:' |
      awk '{print $2}' |
      tr -d '\r' ||
      true
  }
}

WINDOW_DAYS="${WINDOW%d}"
LOGS_DIR="./logs"

# ── Cursor file for deduplication ────────────────────────────────────────
CURSOR_FILE="${CURSOR_FILE:-$HOME/.claude/state/ticket-retro/retro-cursor.json}"
declare -A CURSOR_MTIMES=()
declare -A SCANNED_MTIMES=()
LOGS_SKIPPED=0

if [ "$FORCE_RESCAN" -eq 0 ] && [ -f "$CURSOR_FILE" ]; then
  while IFS= read -r entry; do
    [ -z "$entry" ] && continue
    tid=$(echo "$entry" | jq -r '.ticket_id // empty' 2>/dev/null || true)
    mtime=$(echo "$entry" | jq -r '.log_mtime // 0' 2>/dev/null || true)
    [ -n "$tid" ] && [ "$mtime" -gt 0 ] 2>/dev/null && CURSOR_MTIMES["$tid"]="$mtime"
  done < <(jq -c 'to_entries[] | {ticket_id: .key, log_mtime: .value.log_mtime}' "$CURSOR_FILE" 2>/dev/null || true)
fi

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
GATE_WARN_TOTAL=0
CROSSCHECK_BLOCKING_TOTAL=0
CROSSCHECK_WARN_TOTAL=0
LOGS_SCANNED=0
LOGS_WITH_FAILURES=0

# Build predictions as a JSON array string, one element at a time
PREDICTIONS_JSON="["
PRED_FIRST=1

CORRECT_COUNT=0
TOTAL_PAIRS=0

# ── Process each log ─────────────────────────────────────────────────────

for log_file in "${LOG_FILES[@]}"; do
  local_has_failure=0

  stem=$(basename "$log_file" .log)
  ticket_id="${stem%-pipeline}"

  # ── Cursor dedup: skip if log hasn't changed since last scan ──────────
  log_mtime=$(stat -c %Y "$log_file" 2>/dev/null || echo 0)
  if [ "$FORCE_RESCAN" -eq 0 ] && [ -n "${CURSOR_MTIMES[$ticket_id]:-}" ]; then
    stored_mtime="${CURSOR_MTIMES[$ticket_id]}"
    if [ "$log_mtime" -eq "$stored_mtime" ] 2>/dev/null; then
      LOGS_SKIPPED=$((LOGS_SKIPPED + 1))
      continue
    fi
  fi
  LOGS_SCANNED=$((LOGS_SCANNED + 1))
  SCANNED_MTIMES["$ticket_id"]="$log_mtime"

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
    IFS='|' read -r _ts phase step status msg <<<"$line"
    [ "$phase" != "META" ] && continue

    if [ "$step" = "gate-stop" ] && [ "$status" = "fail" ]; then
      GATE_STOP_TOTAL=$((GATE_STOP_TOTAL + 1))
      code=$(echo "$msg" | awk '{print $1}')
      FAILURE_COUNT["$code"]=$((${FAILURE_COUNT["$code"]:-0} + 1))
      local_has_failure=1
    elif [ "$step" = "gate-warn" ] && [ "$status" = "info" ]; then
      # Warn-only completeness-gate telemetry (RETURN_INCOMPLETE) — kept
      # separate from GATE_STOP_TOTAL/FAILURE_COUNT since these never halt
      # the pipeline; counted so Phase 2 can measure the false-positive rate.
      GATE_WARN_TOTAL=$((GATE_WARN_TOTAL + 1))
    elif [ "$step" = "crosscheck" ] && [ "$status" = "fail" ]; then
      # ticket-planner Crosscheck blocking finding (#176). Histogram by CODE
      # like gate-stop, not by step name — "crosscheck" alone would collapse
      # every distinct finding code (CITATION_UNRESOLVED, RESOLUTION_NOT_-
      # PROPAGATED, ...) into one bucket and lose the signal #176 wants.
      CROSSCHECK_BLOCKING_TOTAL=$((CROSSCHECK_BLOCKING_TOTAL + 1))
      code=$(echo "$msg" | awk '{print $1}')
      FAILURE_COUNT["$code"]=$((${FAILURE_COUNT["$code"]:-0} + 1))
      local_has_failure=1
    elif [ "$step" = "crosscheck" ] && [ "$status" = "warn" ]; then
      # Non-blocking Crosscheck finding, written as "info <CODE> <message>"
      # (see planner-crosscheck.sh:_planner_crosscheck_emit_finding) — code
      # is the second token, not the first. Counted separately, never in
      # FAILURE_COUNT, so it can't be mistaken for a blocking finding (#176
      # AC4).
      CROSSCHECK_WARN_TOTAL=$((CROSSCHECK_WARN_TOTAL + 1))
    elif [ "$status" = "fail" ] && [ "$step" != "schema" ] && [ "$step" != "migration" ]; then
      FAILURE_COUNT["$step"]=$((${FAILURE_COUNT["$step"]:-0} + 1))
      local_has_failure=1
    fi
  done <"$log_file"

  [ "$local_has_failure" -eq 1 ] && LOGS_WITH_FAILURES=$((LOGS_WITH_FAILURES + 1))

  # ── Complexity prediction pair ─────────────────────────────────────────
  declared="null"
  if [ -n "$ticket_dir" ] && [ -d "$ticket_dir" ]; then
    d=$(get_complexity "$ticket_dir" || true)
    [ -n "$d" ] && declared="$d"
  fi

  actual="null"
  actual_source="missing"
  # Read the dedicated outcome-label-check.sh marker instead of parsing the
  # free-prose IMPLEMENT|implement|done| message — that message's phrasing
  # varies per agent and broke every comma/regex heuristic tried so far
  # (GitHub #148).
  outcome_line=$(grep '|META|outcome-label|info|' "$log_file" 2>/dev/null | tail -1 || true)
  if [ -n "$outcome_line" ]; then
    actual=$(echo "$outcome_line" | cut -d'|' -f5)
    actual_source="log"
  fi

  # Append to predictions JSON array
  [ "$PRED_FIRST" -eq 1 ] && PRED_FIRST=0 || PREDICTIONS_JSON+=", "
  PREDICTIONS_JSON+="{\"ticket\":\"$ticket_id\",\"declared\":\"$declared\",\"actual\":\"$actual\",\"actual_source\":\"$actual_source\"}"

  # Track accuracy
  if [ "$declared" != "null" ] && [ "$actual" != "null" ]; then
    TOTAL_PAIRS=$((TOTAL_PAIRS + 1))
    _d_lower=$(echo "$declared" | tr '[:upper:]' '[:lower:]')
    if { [ "$_d_lower" = "simple" ] && [ "$actual" = "Smooth" ]; } ||
      { [ "$_d_lower" = "complex" ] && { [ "$actual" = "Rough" ] || [ "$actual" = "Hard" ]; }; }; then
      CORRECT_COUNT=$((CORRECT_COUNT + 1))
    fi
  fi
done

PREDICTIONS_JSON+="]"

# ── Heartbeat log parsing ──────────────────────────────────────────────────

declare -A HB_FALLBACK_COUNT=()
declare -A HB_DECISION_COUNT=()
declare -A HB_RETRY_COUNT=()
HB_LOGS_SCANNED=0
HB_LOGS_WITH_DATA=0

# Error diagnostics state — populated from retry/api/gate fail events
# errors_by_ticket: JSON fragment built as an object string
declare -A TICKET_ERROR_EVENTS=() # ticket_id -> newline-delimited JSON event objects
TOTAL_ERROR_COUNT=0
declare -A ERROR_CATEGORY_HIST=() # event_name -> count

# ── _build_error_event ──────────────────────────────────────────────────────────
# Build a single JSON error event object for retro diagnostics.
# Usage: _build_error_event <category> <event> <message> <timestamp> [detail]
_build_error_event() {
  local category="$1" event="$2" msg="$3" ts="$4" detail="$5"
  local _detail_obj="{}"
  [ -n "$detail" ] && [ "$detail" != "{}" ] && _detail_obj=$(echo "$detail" | jq -c '.' 2>/dev/null || echo "{}")
  jq -c -n \
    --arg category "$category" --arg event "$event" \
    --arg message "$msg" --arg timestamp "$ts" \
    --argjson detail "$_detail_obj" \
    '{category: $category, event: $event, message: $message, timestamp: $timestamp, detail: $detail}'
}

for log_file in "${LOG_FILES[@]}"; do
  stem=$(basename "$log_file" .log)
  ticket_id="${stem%-pipeline}"
  hb_file="$(dirname "$log_file")/${ticket_id}-heartbeat.log"

  if [ ! -f "$hb_file" ]; then
    continue
  fi
  # Skip heartbeat for logs that were cursor-skipped in the pipeline scan
  if [ "$FORCE_RESCAN" -eq 0 ] && [ -n "${CURSOR_MTIMES[$ticket_id]:-}" ] && [ -z "${SCANNED_MTIMES[$ticket_id]:-}" ]; then
    continue
  fi
  HB_LOGS_SCANNED=$((HB_LOGS_SCANNED + 1))
  local_has_hb=0

  while IFS= read -r line; do
    [ -z "$line" ] && continue
    category="" event="" status="" msg="" detail="" ts=""
    ts=$(echo "$line" | cut -d'|' -f1)
    category=$(echo "$line" | cut -d'|' -f2)
    event=$(echo "$line" | cut -d'|' -f3)
    status=$(echo "$line" | cut -d'|' -f4)
    msg=$(echo "$line" | cut -d'|' -f5)
    detail=$(echo "$line" | cut -d'|' -f6)

    [ "$category" = "META" ] && continue

    if [ "$category" = "fallback" ] && [ "$status" = "fired" ]; then
      HB_FALLBACK_COUNT["$event"]=$((${HB_FALLBACK_COUNT["$event"]:-0} + 1))
      local_has_hb=1
    elif [ "$category" = "decision" ] && [ "$status" = "fired" ]; then
      HB_DECISION_COUNT["$event"]=$((${HB_DECISION_COUNT["$event"]:-0} + 1))
      local_has_hb=1
    elif [ "$category" = "retry" ]; then
      HB_RETRY_COUNT["$event"]=$((${HB_RETRY_COUNT["$event"]:-0} + 1))
      local_has_hb=1

      # Capture retry errors for diagnostics (task 4.1)
      if [ "$status" = "fail" ]; then
        TICKET_ERROR_EVENTS["$ticket_id"]+=$(_build_error_event "retry" "$event" "$msg" "$ts" "$detail")$'\n'
        TOTAL_ERROR_COUNT=$((TOTAL_ERROR_COUNT + 1))
        ERROR_CATEGORY_HIST["$event"]=$((${ERROR_CATEGORY_HIST["$event"]:-0} + 1))
      fi

    # Capture api errors for diagnostics (task 4.2)
    elif [ "$category" = "api" ] && [ "$status" = "fail" ]; then
      local_has_hb=1
      TICKET_ERROR_EVENTS["$ticket_id"]+=$(_build_error_event "api" "$event" "$msg" "$ts" "$detail")$'\n'
      TOTAL_ERROR_COUNT=$((TOTAL_ERROR_COUNT + 1))
      ERROR_CATEGORY_HIST["$event"]=$((${ERROR_CATEGORY_HIST["$event"]:-0} + 1))

    # Capture gate errors for diagnostics (task 4.2, gate events with fail status)
    elif [ "$category" = "gate" ] && [ "$status" = "fail" ]; then
      local_has_hb=1
      TICKET_ERROR_EVENTS["$ticket_id"]+=$(_build_error_event "gate" "$event" "$msg" "$ts" "$detail")$'\n'
      TOTAL_ERROR_COUNT=$((TOTAL_ERROR_COUNT + 1))
      ERROR_CATEGORY_HIST["$event"]=$((${ERROR_CATEGORY_HIST["$event"]:-0} + 1))
    fi
  done <"$hb_file"

  [ "$local_has_hb" -eq 1 ] && HB_LOGS_WITH_DATA=$((HB_LOGS_WITH_DATA + 1))
done

# ── Build error diagnostics JSON (tasks 4.3–4.4) ────────────────────────────

# Build errors_by_ticket JSON object: { "CRE-47": [{...}, ...], ... }
ERRORS_BY_TICKET_JSON="{"
_EBT_FIRST=1
for ticket_id in "${!TICKET_ERROR_EVENTS[@]}"; do
  [ "$_EBT_FIRST" -eq 1 ] && _EBT_FIRST=0 || ERRORS_BY_TICKET_JSON+=","
  # Each value in TICKET_ERROR_EVENTS is newline-delimited JSON objects
  _events_arr="["
  _evt_first=1
  while IFS= read -r evt_line; do
    [ -z "$evt_line" ] && continue
    [ "$_evt_first" -eq 1 ] && _evt_first=0 || _events_arr+=","
    _events_arr+="$evt_line"
  done <<<"${TICKET_ERROR_EVENTS[$ticket_id]}"
  _events_arr+="]"
  ERRORS_BY_TICKET_JSON+="\"$ticket_id\":$_events_arr"
done
ERRORS_BY_TICKET_JSON+="}"

# Build error_category_histogram: { "get-issue": 3, "flow-sh": 1, ... }
ERROR_HIST_JSON="{"
_EH_FIRST=1
for evt_name in "${!ERROR_CATEGORY_HIST[@]}"; do
  [ "$_EH_FIRST" -eq 1 ] && _EH_FIRST=0 || ERROR_HIST_JSON+=","
  ERROR_HIST_JSON+="\"$evt_name\":${ERROR_CATEGORY_HIST[$evt_name]}"
done
ERROR_HIST_JSON+="}"

# Build heartbeat-derived JSON
_HB_BUILD_OBJ() {
  local -n _counts=$1
  local first=1
  echo -n "{"
  for key in "${!_counts[@]}"; do
    [ "$first" -eq 1 ] && first=0 || echo -n ", "
    echo -n "\"$key\": ${_counts[$key]}"
  done
  echo -n "}"
}

HB_FALLBACK_JSON=$(_HB_BUILD_OBJ HB_FALLBACK_COUNT)
HB_DECISION_JSON=$(_HB_BUILD_OBJ HB_DECISION_COUNT)
HB_RETRY_JSON=$(_HB_BUILD_OBJ HB_RETRY_COUNT)

# ── Build failure histogram JSON (sorted descending by count) ────────────

HISTOGRAM_JSON="{"
HIST_FIRST=1
for code in "${!FAILURE_COUNT[@]}"; do
  echo "${FAILURE_COUNT[$code]} $code"
done | sort -rn | while read -r count code; do
  # This while-read runs in a subshell due to the pipe, so we use a temp file
  echo "$count $code"
done >/tmp/retro-hist-sorted.$$.txt

# Re-read from temp file to avoid subshell issues
HISTOGRAM_JSON="{"
HIST_FIRST=1
while read -r count code; do
  [ -z "$code" ] && continue
  [ "$HIST_FIRST" -eq 1 ] && HIST_FIRST=0 || HISTOGRAM_JSON+=", "
  HISTOGRAM_JSON+="\"$code\": $count"
done </tmp/retro-hist-sorted.$$.txt
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
  --argjson logs_skipped "$LOGS_SKIPPED" \
  --argjson logs_with_failures "$LOGS_WITH_FAILURES" \
  --argjson gate_stop_total "$GATE_STOP_TOTAL" \
  --argjson gate_warn_total "$GATE_WARN_TOTAL" \
  --argjson crosscheck_blocking_total "$CROSSCHECK_BLOCKING_TOTAL" \
  --argjson crosscheck_warn_total "$CROSSCHECK_WARN_TOTAL" \
  --argjson complexity_accuracy "$ACCURACY" \
  --arg histogram_str "$HISTOGRAM_JSON" \
  --arg predictions_str "$PREDICTIONS_JSON" \
  --argjson hb_logs_scanned "$HB_LOGS_SCANNED" \
  --argjson hb_logs_with_data "$HB_LOGS_WITH_DATA" \
  --arg hb_fallback_str "$HB_FALLBACK_JSON" \
  --arg hb_decision_str "$HB_DECISION_JSON" \
  --arg hb_retry_str "$HB_RETRY_JSON" \
  --argjson total_errors "$TOTAL_ERROR_COUNT" \
  --arg errors_by_ticket_str "$ERRORS_BY_TICKET_JSON" \
  --arg error_hist_str "$ERROR_HIST_JSON" \
  '{
    window_days: $window_days,
    logs_scanned: $logs_scanned,
    logs_skipped: $logs_skipped,
    logs_with_failures: $logs_with_failures,
    failure_histogram: ($histogram_str | fromjson),
    gate_stop_total: $gate_stop_total,
    gate_warn_total: $gate_warn_total,
    crosscheck_blocking_total: $crosscheck_blocking_total,
    crosscheck_warn_total: $crosscheck_warn_total,
    complexity_predictions: ($predictions_str | fromjson),
    complexity_accuracy: $complexity_accuracy,
    heartbeat: {
      logs_scanned: $hb_logs_scanned,
      logs_with_data: $hb_logs_with_data,
      fallback_frequency: ($hb_fallback_str | fromjson),
      decision_patterns: ($hb_decision_str | fromjson),
      retry_distribution: ($hb_retry_str | fromjson)
    },
    error_diagnostics: {
      total_errors: $total_errors,
      errors_by_ticket: ($errors_by_ticket_str | fromjson),
      error_category_histogram: ($error_hist_str | fromjson)
    }
  }'

# ── Write cursor file ────────────────────────────────────────────────────
_CURSOR_JSON="{"
_CURSOR_FIRST=1
for tid in "${!SCANNED_MTIMES[@]}"; do
  _mtime="${SCANNED_MTIMES[$tid]}"
  _now=$(_iso_now)
  [ "$_CURSOR_FIRST" -eq 1 ] && _CURSOR_FIRST=0 || _CURSOR_JSON+=","
  _CURSOR_JSON+="\"$tid\":{\"scanned_at\":\"$_now\",\"log_mtime\":$_mtime}"
done
# Preserve existing cursor entries for tickets not in this scan window
if [ -f "$CURSOR_FILE" ]; then
  _preserved_file="$(mktemp)"
  jq -r 'to_entries[] | "\(.key) \(.value.log_mtime) \(.value.scanned_at)"' "$CURSOR_FILE" 2>/dev/null >"$_preserved_file" || true
  while read -r _tid _mtime _scanned_at; do
    [ -z "$_tid" ] && continue
    if [ -z "${SCANNED_MTIMES[$_tid]:-}" ]; then
      [ "$_CURSOR_FIRST" -eq 1 ] && _CURSOR_FIRST=0 || _CURSOR_JSON+=","
      _CURSOR_JSON+="\"$_tid\":{\"scanned_at\":\"$_scanned_at\",\"log_mtime\":$_mtime}"
    fi
  done <"$_preserved_file"
  rm -f "$_preserved_file"
fi
_CURSOR_JSON+="}"
mkdir -p "$(dirname "$CURSOR_FILE")"
echo "$_CURSOR_JSON" | jq '.' >"$CURSOR_FILE"
