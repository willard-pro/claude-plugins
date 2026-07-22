#!/usr/bin/env bash
# planner-replan.sh — Re-planning support: feedback ingestion, drift computation,
# scope restriction, and regenerate-flag detection.
#
# Re-planning is gated on the `Regenerate` flag. Without it, feedback is not read.
# When the flag is present, aggregated feedback JSONs are ingested, confidence
# drift is computed, and undispatched Backlog tickets are regenerated with
# adjusted confidence. Dispatched, in-progress, and completed tickets are untouched.
#
# Sourceable library — no set -euo pipefail.

_source_if_missing() {
  local name="$1" path="$2"
  if ! declare -f "$name" >/dev/null 2>&1; then
    [ -f "$path" ] && source "$path"
  fi
}

# Validate initiative ID and resolve the state directory.
# All re-plan functions MUST use this — never call planner_initiative_dir directly.
# Usage: _planner_replan_state_dir <initiative_id>
# Returns: state directory path, or empty string + error on stderr if invalid.
_planner_replan_state_dir() {
  local initiative_id="$1"
  local state_dir

  # Validate initiative_id before any path construction
  _source_if_missing "planner_validate_initiative_id" "${CLAUDE_PLUGIN_ROOT:-.}/lib/planner-state.sh"

  if ! planner_validate_initiative_id "$initiative_id" 2>/dev/null; then
    echo "ERROR: invalid initiative ID '${initiative_id}' — rejected for path safety" >&2
    return 1
  fi

  state_dir=$(planner_initiative_dir "$initiative_id" 2>/dev/null) || {
    echo "ERROR: could not resolve state directory for '${initiative_id}'" >&2
    return 1
  }

  echo "$state_dir"
  return 0
}

# ── Regenerate-flag detection ───────────────────────────────────────────────────

# Check whether an initiative has the Regenerate flag set.
# Looks in: state log META entries, proposal.md, and planner context blocks
# in generated ticket specs.
#
# Usage: planner_replan_flag_is_set <initiative_id>
# Returns: 0 if Regenerate flag is present and true, 1 otherwise.
planner_replan_flag_is_set() {
  local initiative_id="$1"
  local state_dir
  state_dir=$(_planner_replan_state_dir "$initiative_id") || return 1

  # Check state log for regenerate marker
  if [ -f "${state_dir}/state.log" ]; then
    if grep -q '|META|replan-flag|start|true' "${state_dir}/state.log" 2>/dev/null; then
      return 0
    fi
  fi

  # Check proposal for regenerate field
  if [ -f "${state_dir}/artifacts/proposal.md" ]; then
    if grep -qi 'regenerate.*true' "${state_dir}/artifacts/proposal.md" 2>/dev/null; then
      return 0
    fi
  fi

  # Check ticket specs for Regenerate: true in Planner Context
  if [ -d "${state_dir}/artifacts/specs" ]; then
    if grep -rl '"Regenerate".*true' "${state_dir}/artifacts/specs/" 2>/dev/null | grep -q .; then
      return 0
    fi
  fi

  return 1
}

# Set the regenerate flag for an initiative.
# Usage: planner_replan_flag_set <initiative_id>
planner_replan_flag_set() {
  local initiative_id="$1"
  _source_if_missing "planner_state_write" "${CLAUDE_PLUGIN_ROOT:-.}/lib/planner-state.sh"
  planner_state_write "$initiative_id" "META" "replan-flag" "start" "true"
}

# ── Feedback ingestion ──────────────────────────────────────────────────────────

# List all feedback files for an initiative, sorted by date (newest first).
# Usage: planner_feedback_list <initiative_id>
# Returns: newline-separated list of absolute paths, empty if none.
planner_feedback_list() {
  local initiative_id="$1"
  local feedback_dir
  feedback_dir="$(_planner_replan_state_dir "$initiative_id")/feedback"

  if [ ! -d "$feedback_dir" ]; then
    return 0
  fi

  find "$feedback_dir" -name '*.json' -type f 2>/dev/null | sort -r
}

# Read all feedback JSONs and merge into a single array.
# Usage: planner_feedback_read_all <initiative_id>
# Returns: JSON array of feedback objects, empty array if no feedback.
planner_feedback_read_all() {
  local initiative_id="$1"
  local feedback_dir
  feedback_dir="$(_planner_replan_state_dir "$initiative_id")/feedback"

  if [ ! -d "$feedback_dir" ]; then
    echo "[]"
    return 0
  fi

  local files
  files=$(find "$feedback_dir" -name '*.json' -type f 2>/dev/null | sort -r)
  if [ -z "$files" ]; then
    echo "[]"
    return 0
  fi

  # Merge all feedback files into a single JSON array
  local first=true
  echo "["
  while IFS= read -r f; do
    if [ -s "$f" ]; then
      if $first; then
        first=false
      else
        echo ","
      fi
      cat "$f"
    fi
  done <<<"$files"
  echo "]"
}

# Check if feedback exists for an initiative (distinguishes absent from unreadable).
# Usage: planner_feedback_exists <initiative_id>
# Returns: JSON with status and details.
#   {"status":"present","count":N,"newest":"YYYY-MM-DD"} or
#   {"status":"absent"} or
#   {"status":"unreadable","files":["path"],"errors":["msg"]}
planner_feedback_status() {
  local initiative_id="$1"
  local feedback_dir
  feedback_dir="$(_planner_replan_state_dir "$initiative_id")/feedback"

  if [ ! -d "$feedback_dir" ]; then
    echo '{"status":"absent"}'
    return 0
  fi

  local files unreadable valid_files
  files=$(find "$feedback_dir" -name '*.json' -type f 2>/dev/null)
  if [ -z "$files" ]; then
    echo '{"status":"absent"}'
    return 0
  fi

  # Check each file is valid JSON
  unreadable=""
  valid_files=""
  while IFS= read -r f; do
    if jq -e . "$f" >/dev/null 2>&1; then
      valid_files="${valid_files}${f}\n"
    else
      unreadable="${unreadable}${f}\n"
    fi
  done <<<"$files"

  local count
  count=$(echo -e "$valid_files" | grep -c . 2>/dev/null || echo 0)

  if [ -n "$unreadable" ]; then
    local unreadable_json errors_json
    unreadable_json=$(echo -e "$unreadable" | grep . | jq -R -s 'split("\n") | map(select(length > 0))')
    echo "{\"status\":\"unreadable\",\"count\":${count},\"unreadable\":${unreadable_json}}"
    return 0
  fi

  local newest
  newest=$(echo -e "$valid_files" | grep . | head -1 | xargs -r basename 2>/dev/null | sed 's/\.json$//')
  echo "{\"status\":\"present\",\"count\":${count},\"newest\":\"${newest}\"}"
}

# ── Drift computation ───────────────────────────────────────────────────────────

# Compute confidence drift from predicted vs actual outcomes.
# Input: feedback JSON (merged array from planner_feedback_read_all)
# Output: per-ticket drift objects and aggregate summary.
#
# Usage: planner_drift_compute <feedback_json>
# Returns: JSON object with per_ticket drift and aggregate summary.
planner_drift_compute() {
  local feedback_json="$1"

  if [ -z "$feedback_json" ] || [ "$feedback_json" = "[]" ]; then
    echo '{"per_ticket":[],"aggregate":{"avg_drift":0,"drift_count":0,"systematic_overconfidence":false,"max_drift":0,"min_drift":0}}'
    return 0
  fi

  echo "$feedback_json" | jq '
    # Flatten if nested: each feedback file may contain multiple tickets
    [ .[] | if type == "array" then .[] else . end | select(.confidence_predicted != null) ] as $entries |

    # Per-ticket drift
    ($entries | map({
      ticket_id: (.ticket_id // "unknown"),
      confidence_predicted: .confidence_predicted,
      confidence_actual: .confidence_actual,
      drift: (.confidence_actual - .confidence_predicted),
      outcome: (.outcome // "unknown"),
      corrections_count: (.corrections_count // 0),
      decision_drift: (.decision_drift // "none")
    })) as $per_ticket |

    # Aggregate
    ($per_ticket | map(.drift) | select(length > 0)) as $drifts |

    {
      per_ticket: $per_ticket,
      aggregate: {
        avg_drift: ($drifts | if length > 0 then (add / length) else 0 end),
        drift_count: ($drifts | length),
        systematic_overconfidence: ($drifts | if length > 0 then ((add / length) > 0.15) else false end),
        max_drift: ($drifts | if length > 0 then max else 0 end),
        min_drift: ($drifts | if length > 0 then min else 0 end)
      }
    }
  ' 2>/dev/null || echo '{"per_ticket":[],"aggregate":{"avg_drift":0,"drift_count":0,"systematic_overconfidence":false}}'
}

# ── Scope restriction ──────────────────────────────────────────────────────────

# Identify tickets eligible for regeneration.
# Only undispatched Backlog tickets are eligible — dispatched, in-progress,
# and completed tickets are left unchanged.
#
# Usage: planner_replan_eligible_tickets <initiative_id>
# Returns: JSON array of eligible ticket entity keys.
planner_replan_eligible_tickets() {
  local initiative_id="$1"
  local intents_dir
  intents_dir="$(_planner_replan_state_dir "$initiative_id")/.intents"

  if [ ! -d "$intents_dir" ]; then
    echo "[]"
    return 0
  fi

  # List all ticket intent files that are in "created" status
  # These are the tickets we created — we need to check which are still in Backlog
  local eligible
  eligible=$(find "$intents_dir" -name 'ticket-*.json' -type f 2>/dev/null | while read -r intent_file; do
    local entity_key status linear_id
    entity_key=$(basename "$intent_file" .json)
    status=$(jq -r '.status // "unknown"' "$intent_file" 2>/dev/null)
    linear_id=$(jq -r '.linear_id // empty' "$intent_file" 2>/dev/null)

    # Only consider created tickets
    if [ "$status" != "created" ] || [ -z "$linear_id" ]; then
      continue
    fi

    # Check if this ticket is already dispatched (in spawn queue)
    # The spawn queue lives under fleet-controller's state dir
    local spawn_dir="${REPOS_ROOT:-${HOME}/repos}/.ticket-auto/spawn-queue"
    if [ -d "$spawn_dir" ]; then
      if grep -qr "$linear_id" "$spawn_dir" 2>/dev/null; then
        continue # Already dispatched — skip
      fi
    fi

    # Check if the ticket has moved past Backlog via pipeline log
    # Look for pipeline log files matching this ticket ID
    local pipeline_dir="${REPOS_ROOT:-${HOME}/repos}/.ticket-auto/pipelines"
    if [ -d "$pipeline_dir" ]; then
      if find "$pipeline_dir" -name "${linear_id}--*" -type d 2>/dev/null | grep -q .; then
        continue # Has a pipeline directory — in progress or completed
      fi
    fi

    # This ticket is eligible
    echo "$entity_key"
  done)

  if [ -z "$eligible" ]; then
    echo "[]"
  else
    echo "$eligible" | jq -R -s 'split("\n") | map(select(length > 0))'
  fi
}

# ── Re-plan state log recording ─────────────────────────────────────────────────

# Record a re-plan event in the state log.
# Usage: planner_replan_record <initiative_id> <trigger_flag> <feedback_files> \
#          <tickets_regenerated> <tickets_unchanged> <tickets_skipped> \
#          <drift_summary_json>
planner_replan_record() {
  local initiative_id="$1" trigger_flag="$2" feedback_files="$3"
  local tickets_regenerated="$4" tickets_unchanged="$5" tickets_skipped="$6"
  local drift_summary_json="$7"

  _source_if_missing "planner_state_write" "${CLAUDE_PLUGIN_ROOT:-.}/lib/planner-state.sh"

  planner_state_write "$initiative_id" "META" "replan-start" "start" \
    "Regenerate-flag: ${trigger_flag}, feedback files: ${feedback_files}"

  planner_state_write "$initiative_id" "META" "replan-drift" "start" \
    "Drift summary: ${drift_summary_json}"

  planner_state_write "$initiative_id" "META" "replan-result" "start" \
    "Regenerated: ${tickets_regenerated}, unchanged: ${tickets_unchanged}, skipped: ${tickets_skipped}"
}

# ── Post-replan dependency validation ───────────────────────────────────────────

# After regeneration, verify the dependency set is still acyclic.
# Reuses planner_deps_check_acyclic from planner-deps-check.sh.
#
# Usage: planner_replan_validate_deps <initiative_id>
# Returns: 0 if acyclic, 1 if cyclic (writes cycle to stderr).
planner_replan_validate_deps() {
  local initiative_id="$1"
  local specs_dir
  specs_dir="$(_planner_replan_state_dir "$initiative_id")/artifacts/specs"

  _source_if_missing "planner_deps_check_acyclic" "${CLAUDE_PLUGIN_ROOT:-.}/lib/planner-deps-check.sh"

  if [ ! -d "$specs_dir" ]; then
    return 0 # No specs — nothing to validate
  fi

  # Extract dependency graph from spec files
  # Each spec has a "blocked-by" label field or dependency section
  local deps_json
  deps_json=$(grep -rl 'blocked-by' "$specs_dir" 2>/dev/null | while read -r spec_file; do
    local ticket_slug blocked_by
    ticket_slug=$(basename "$spec_file" .md)
    blocked_by=$(grep 'blocked-by:' "$spec_file" 2>/dev/null | sed 's/.*blocked-by:{\([^}]*\)}.*/\1/' | tr ',' '\n' | sed 's/^ *//;s/ *$//' | grep . | jq -R -s 'split("\n") | map(select(length > 0))')
    if [ -n "$blocked_by" ] && [ "$blocked_by" != "[]" ]; then
      echo "{\"$ticket_slug\":$blocked_by}"
    fi
  done | jq -s 'add // {}')

  if [ -z "$deps_json" ] || [ "$deps_json" = "{}" ]; then
    return 0
  fi

  planner_deps_check_acyclic "$deps_json"
}
