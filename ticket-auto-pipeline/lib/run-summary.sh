#!/usr/bin/env bash
# run-summary.sh — builds the `run` event object appended to runs.jsonl
# (Branch B of the Commercial Evidence MVP, next.md Step 1 / design.md).
#
# Per-run counters are computed from the run's own window (last META|run-id
# line to EOF), using detect-resume.sh's exact grep patterns copied verbatim
# rather than sourcing that script — detect-resume.sh has zombie-synthesis
# side effects that must never fire from a post-outcome summarizer.
#
# -u (nounset) intentionally omitted, matching run-identity.sh: Claude Code
# shell snapshots inject ZSH_VERSION references that trip it.
set -eo pipefail

_RS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if ! declare -f _plog >/dev/null 2>&1; then
  [ -f "$_RS_LIB_DIR/heartbeat.sh" ] && source "$_RS_LIB_DIR/heartbeat.sh"
fi
if ! declare -f run_identity_current >/dev/null 2>&1; then
  [ -f "$_RS_LIB_DIR/run-identity.sh" ] && source "$_RS_LIB_DIR/run-identity.sh"
fi

# ── run_summary_window ───────────────────────────────────────────────────────
# Prints the lines from the last META|run-id line (inclusive) to EOF. Falls
# back to the whole log when no run-id line exists (pre-Branch-A log).
run_summary_window() {
  local log_file="$1"
  [ -f "$log_file" ] || return 0

  local start_line
  start_line=$(grep -n '|META|run-id|info|' "$log_file" 2>/dev/null | tail -1 | cut -d: -f1) || true

  if [ -z "$start_line" ]; then
    cat "$log_file" 2>/dev/null
  else
    tail -n "+${start_line}" "$log_file" 2>/dev/null
  fi
}

# ── Field-5+ join helper (JSON payloads contain `|`, never cut -f5) ─────────
_rs_field5() {
  awk -F'|' '{s=$5; for(i=6;i<=NF;i++) s=s"|"$i; print s}'
}

# ── run_summary_json ──────────────────────────────────────────────────────────
# Usage: run_summary_json TID LOG_FILE EXIT_CODE
# Prints a single-line JSON `run` event object on stdout. Never fails —
# every extraction degrades to null/0 on missing data.
run_summary_json() {
  local tid="$1" log_file="$2" exit_code="${3:-0}"
  [ -n "$tid" ] && [ -n "$log_file" ] || {
    echo "run_summary_json: TID and LOG_FILE required" >&2
    return 0
  }

  local window
  window=$(run_summary_window "$log_file" 2>/dev/null) || window=""

  # ── Per-run counters (detect-resume.sh's exact patterns, not sourced) ──────
  local verify_attempts review_iterations fix_rounds reconcile_cycles
  verify_attempts=$(grep -cE '^[^|]*\|VERIFY\|verify\|fail\|' <<<"$window" 2>/dev/null || true)
  review_iterations=$(grep -c '|PR-REVIEW|pr-review|done|WARN' <<<"$window" 2>/dev/null || true)
  fix_rounds=$(grep -c '|PR-REVIEW|pr-reconcile|done|cycle#' <<<"$window" 2>/dev/null || true)
  reconcile_cycles=$(grep -c '|GATE|reconcile|done|cycle#' <<<"$window" 2>/dev/null || true)
  verify_attempts=${verify_attempts:-0}
  review_iterations=${review_iterations:-0}
  fix_rounds=${fix_rounds:-0}
  reconcile_cycles=${reconcile_cycles:-0}

  # ── gate_stops[] ────────────────────────────────────────────────────────────
  local gate_stops_json
  gate_stops_json=$(grep '|META|gate-stop|fail|' <<<"$window" 2>/dev/null | _rs_field5 |
    jq -Rrs 'split("\n") | map(select(length > 0))' 2>/dev/null) || gate_stops_json="[]"
  [ -n "$gate_stops_json" ] || gate_stops_json="[]"

  # ── models[] ─────────────────────────────────────────────────────────────────
  local models_json
  models_json=$(grep '|META|model|info|' <<<"$window" 2>/dev/null | _rs_field5 |
    jq -sc 'map(.model // empty) | map(select(length > 0)) | unique' 2>/dev/null) || models_json="[]"
  [ -n "$models_json" ] || models_json="[]"

  # ── run-id line: run_id, gen, trigger, started_at ───────────────────────────
  local run_id_line run_id_json started_at gen trigger
  run_id_line=$(grep '|META|run-id|info|' <<<"$window" 2>/dev/null | tail -1) || true
  started_at=$(cut -d'|' -f1 <<<"$run_id_line" 2>/dev/null) || true
  run_id_json=$(_rs_field5 <<<"$run_id_line" 2>/dev/null) || true
  gen=$(jq -r '.gen // empty' <<<"$run_id_json" 2>/dev/null) || true
  trigger=$(jq -r '.trigger // empty' <<<"$run_id_json" 2>/dev/null) || true

  # ── version line (this run's own META|version) ──────────────────────────────
  local versions_json
  versions_json=$(grep '|META|version|info|' <<<"$window" 2>/dev/null | tail -1 | _rs_field5) || true
  [ -n "$versions_json" ] || versions_json="null"
  echo "$versions_json" | jq -e . >/dev/null 2>&1 || versions_json="null"

  # ── outcome (within the window, i.e. this run's own outcome) ────────────────
  local outcome_line outcome ended_at
  outcome_line=$(grep '|META|outcome|info|' <<<"$window" 2>/dev/null | tail -1) || true
  outcome=$(_rs_field5 <<<"$outcome_line" 2>/dev/null) || true
  ended_at=$(cut -d'|' -f1 <<<"$outcome_line" 2>/dev/null) || true

  # ── gate_held_at / resumed_after_hold_ms — bridge from the PREVIOUS run ─────
  # The previous run's outcome (if "held: ...") sits immediately before this
  # run's own META|run-id line in the whole log, not in the window.
  local gate_held_at="null" resumed_after_hold_ms="null"
  if [ -n "$run_id_line" ]; then
    local prev_outcome_line
    prev_outcome_line=$(grep -B 1000000 -F "$run_id_line" "$log_file" 2>/dev/null |
      grep '|META|outcome|info|' | tail -1) || true
    if [ -n "$prev_outcome_line" ] && grep -qF "held:" <<<"$(_rs_field5 <<<"$prev_outcome_line")"; then
      local t1 t2 e1 e2
      t1=$(cut -d'|' -f1 <<<"$prev_outcome_line")
      t2="$started_at"
      gate_held_at=$(jq -Rn --arg t "$t1" '$t')
      e1=$(date -d "$t1" +%s 2>/dev/null || echo "")
      e2=$(date -d "$t2" +%s 2>/dev/null || echo "")
      if [ -n "$e1" ] && [ -n "$e2" ]; then
        resumed_after_hold_ms=$(((e2 - e1) * 1000))
      fi
    fi
  fi

  # ── pr — prefer META|pr-created over PR-REVIEW|checkout-pr ─────────────────
  local pr_json
  pr_json=$(grep '|META|pr-created|info|' <<<"$window" 2>/dev/null | tail -1 | _rs_field5) || true
  if [ -z "$pr_json" ] || ! echo "$pr_json" | jq -e . >/dev/null 2>&1; then
    local checkout_pr_num
    checkout_pr_num=$(grep '|PR-REVIEW|checkout-pr|done|' <<<"$window" 2>/dev/null | tail -1 | _rs_field5) || true
    if [ -n "$checkout_pr_num" ]; then
      pr_json=$(jq -nc --arg n "$checkout_pr_num" '{pr: ($n | tonumber? // null), url: null, repo: null}' 2>/dev/null) || pr_json="null"
    else
      pr_json="null"
    fi
  fi
  [ -n "$pr_json" ] || pr_json="null"

  # ── merge_decision ───────────────────────────────────────────────────────────
  local merge_decision
  merge_decision=$(grep '|PR-REVIEW|merge-decision|' <<<"$window" 2>/dev/null | tail -1 | _rs_field5) || true

  # ── tokens {in,out,cache,cache_read,cache_write} + phase_elapsed_ms ─────────
  local tok_in=0 tok_out=0 tok_cache=0 cache_read=0 cache_write=0
  local phase_elapsed_json="{}"
  if [ -n "$window" ]; then
    local _tok_line _phase _rest _nums _in _out _cache _elapsed
    while IFS= read -r _tok_line; do
      [ -z "$_tok_line" ] && continue
      _rest=$(_rs_field5 <<<"$_tok_line")
      _phase="${_rest%%:*}"
      _nums="${_rest#*:}"
      _elapsed="${_nums##*elapsed_ms=}"
      case "$_nums" in *elapsed_ms=*) _nums="${_nums%%|elapsed_ms=*}" ;; *) _elapsed="" ;; esac
      _in=$(cut -d/ -f1 <<<"$_nums")
      _out=$(cut -d/ -f2 <<<"$_nums")
      _cache=$(cut -d/ -f3 <<<"$_nums")
      [[ "$_in" =~ ^[0-9]+$ ]] && tok_in=$((tok_in + _in))
      [[ "$_out" =~ ^[0-9]+$ ]] && tok_out=$((tok_out + _out))
      [[ "$_cache" =~ ^[0-9]+$ ]] && tok_cache=$((tok_cache + _cache))
      if [[ "$_elapsed" =~ ^[0-9]+$ ]] && [ -n "$_phase" ]; then
        phase_elapsed_json=$(jq -c --arg p "$_phase" --argjson ms "$_elapsed" '.[$p] = $ms' <<<"$phase_elapsed_json" 2>/dev/null) || phase_elapsed_json="{}"
      fi
    done < <(grep '|META|tokens|info|' <<<"$window" 2>/dev/null || true)

    while IFS= read -r _tok_line; do
      [ -z "$_tok_line" ] && continue
      _rest=$(_rs_field5 <<<"$_tok_line")
      _nums="${_rest#*:}"
      _in=$(cut -d/ -f1 <<<"$_nums")
      _out=$(cut -d/ -f2 <<<"$_nums")
      [[ "$_in" =~ ^[0-9]+$ ]] && cache_read=$((cache_read + _in))
      [[ "$_out" =~ ^[0-9]+$ ]] && cache_write=$((cache_write + _out))
    done < <(grep '|META|cache-tokens|info|' <<<"$window" 2>/dev/null || true)
  fi
  [ -n "$phase_elapsed_json" ] || phase_elapsed_json="{}"

  # ── Whole-log, ticket-scoped fields (not run-scoped) ────────────────────────
  local ticket_meta_json ticket_created_at ticket_type ticket_planned ticket_estimate
  ticket_meta_json=$(grep '|META|ticket-meta|info|' "$log_file" 2>/dev/null | tail -1 | _rs_field5) || true
  ticket_created_at=$(jq -r '.createdAt // empty' <<<"$ticket_meta_json" 2>/dev/null) || true
  ticket_type=$(jq -r '.type // empty' <<<"$ticket_meta_json" 2>/dev/null) || true
  ticket_planned=$(jq -r '.planned // empty' <<<"$ticket_meta_json" 2>/dev/null) || true
  ticket_estimate=$(jq -r '.estimate // empty' <<<"$ticket_meta_json" 2>/dev/null) || true

  local complexity autonomy
  complexity=$(grep '|META|complexity|info|' "$log_file" 2>/dev/null | tail -1 | _rs_field5) || true
  autonomy=$(grep '|META|autonomy|info|' "$log_file" 2>/dev/null | tail -1 | _rs_field5) || true

  jq -nc \
    --arg tid "$tid" \
    --arg run_id "$(jq -r '.run_id // empty' <<<"$run_id_json" 2>/dev/null)" \
    --argjson gen "${gen:-null}" \
    --arg trigger "${trigger:-}" \
    --argjson versions "$versions_json" \
    --argjson models "$models_json" \
    --arg complexity "${complexity:-}" \
    --arg type "${ticket_type:-}" \
    --arg planned "${ticket_planned:-}" \
    --arg estimate "${ticket_estimate:-}" \
    --arg autonomy "${autonomy:-}" \
    --arg ticket_created_at "${ticket_created_at:-}" \
    --arg started_at "${started_at:-}" \
    --arg ended_at "${ended_at:-}" \
    --arg outcome "${outcome:-}" \
    --argjson exit_code "${exit_code:-0}" \
    --argjson gate_held_at "${gate_held_at:-null}" \
    --argjson resumed_after_hold_ms "${resumed_after_hold_ms:-null}" \
    --argjson verify_attempts "$verify_attempts" \
    --argjson review_iterations "$review_iterations" \
    --argjson fix_rounds "$fix_rounds" \
    --argjson reconcile_cycles "$reconcile_cycles" \
    --argjson gate_stops "$gate_stops_json" \
    --argjson pr "$pr_json" \
    --arg merge_decision "${merge_decision:-}" \
    --argjson tok_in "$tok_in" --argjson tok_out "$tok_out" --argjson tok_cache "$tok_cache" \
    --argjson cache_read "$cache_read" --argjson cache_write "$cache_write" \
    --argjson phase_elapsed_ms "$phase_elapsed_json" \
    '{
      kind: "run",
      tid: $tid,
      run_id: (if $run_id == "" then null else $run_id end),
      gen: $gen,
      trigger: (if $trigger == "" then null else $trigger end),
      versions: $versions,
      models: $models,
      complexity: (if $complexity == "" then null else $complexity end),
      type: (if $type == "" then null else $type end),
      planned: (if $planned == "" then null elif $planned == "true" then true elif $planned == "false" then false else null end),
      estimate: (if $estimate == "" then null else ($estimate | tonumber? // null) end),
      autonomy: (if $autonomy == "" then null else $autonomy end),
      ticket_created_at: (if $ticket_created_at == "" then null else $ticket_created_at end),
      started_at: (if $started_at == "" then null else $started_at end),
      ended_at: (if $ended_at == "" then null else $ended_at end),
      outcome: (if $outcome == "" then null else $outcome end),
      exit_code: $exit_code,
      gate_held_at: $gate_held_at,
      resumed_after_hold_ms: $resumed_after_hold_ms,
      verify_attempts: $verify_attempts,
      review_iterations: $review_iterations,
      fix_rounds: $fix_rounds,
      reconcile_cycles: $reconcile_cycles,
      gate_stops: $gate_stops,
      pr: $pr,
      merge_decision: (if $merge_decision == "" then null else $merge_decision end),
      tokens: {in: $tok_in, out: $tok_out, cache: $tok_cache, cache_read: $cache_read, cache_write: $cache_write},
      phase_elapsed_ms: $phase_elapsed_ms,
      observed_at: (now | strftime("%Y-%m-%dT%H:%M:%SZ"))
    }' 2>/dev/null
}

# ── runs_append ────────────────────────────────────────────────────────────────
# Usage: runs_append RUNS_FILE JSON
# flock-guarded, fail-soft append of one JSON line. Never blocks or fails the
# caller — a lock timeout or write error is swallowed after a stderr warning.
runs_append() {
  local runs_file="$1" json="$2"
  [ -n "$runs_file" ] && [ -n "$json" ] || return 0

  mkdir -p "$(dirname "$runs_file")" 2>/dev/null || true

  local lockfile="${runs_file}.lock"
  exec 8>"$lockfile" 2>/dev/null || return 0
  if ! flock -w 5 8 2>/dev/null; then
    echo "runs_append: lock timeout (5s) for $runs_file" >&2
    exec 8>&-
    return 0
  fi

  printf '%s\n' "$json" >>"$runs_file" 2>/dev/null || echo "runs_append: write failed for $runs_file" >&2

  exec 8>&-
  return 0
}

# ── CLI entrypoint ────────────────────────────────────────────────────────────

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  case "${1:-}" in
  window)
    shift
    run_summary_window "$@"
    ;;
  json)
    shift
    run_summary_json "$@"
    ;;
  *)
    echo "Usage: run-summary.sh window LOG_FILE | json TID LOG_FILE EXIT_CODE" >&2
    exit 1
    ;;
  esac
fi
