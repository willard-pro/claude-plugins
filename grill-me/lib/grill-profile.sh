#!/usr/bin/env bash
# ── grill-profile.sh ──────────────────────────────────────────────────────────
# Profile loading and validation for the grill-me readiness gate.
#
# Exports:
#   grill_profile_load     <profile-path>          → JSON on stdout
#   grill_profile_validate <profile-json-string>   → exit 0 | non-zero
#   grill_profile_list     <profiles-dir>          → space-separated id list
#
# Profile validation enforces:
#   1. dimension weights are integers summing to exactly 100
#   2. dimension ids are unique
#   3. at least one dimension is marked critical: true
#   4. 0 < warn < ready <= 100
#   5. every dimension has a non-empty id, label, and a positive integer weight
#   6. max_questions is a positive integer
#   7. flag ids and cap values are valid
#
# On any validation failure, exits non-zero. There is no default-profile fallback.
# ───────────────────────────────────────────────────────────────────────────────

set -euo pipefail

# ── grill_profile_load ────────────────────────────────────────────────────────
# Reads a profile JSON file and prints it to stdout.
# Usage: grill_profile_load <path-to-profile.json>
# ──────────────────────────────────────────────────────────────────────────────
grill_profile_load() {
  local profile_path="$1"

  if [ ! -f "$profile_path" ]; then
    echo "grill-profile: profile not found: ${profile_path}" >&2
    return 2
  fi

  if ! jq '.' "$profile_path" >/dev/null 2>&1; then
    echo "grill-profile: invalid JSON in profile: ${profile_path}" >&2
    return 2
  fi

  cat "$profile_path"
}

# ── grill_profile_validate ────────────────────────────────────────────────────
# Validates a profile JSON string against structural rules.
# Usage: grill_profile_validate <json-string>
# Returns: exit 0 if valid, non-zero with message on stderr if invalid.
# ──────────────────────────────────────────────────────────────────────────────
grill_profile_validate() {
  local json="$1"

  # ── required top-level fields ────────────────────────────────────────────
  local id label version max_questions
  id=$(echo "$json" | jq -r '.id // empty')
  label=$(echo "$json" | jq -r '.label // empty')
  version=$(echo "$json" | jq -r '.version // empty')
  max_questions=$(echo "$json" | jq -r '.max_questions // empty')

  if [ -z "$id" ]; then
    echo "grill-profile: profile missing required field: id" >&2
    return 1
  fi
  if [ -z "$label" ]; then
    echo "grill-profile: profile missing required field: label" >&2
    return 1
  fi
  if [ -z "$version" ]; then
    echo "grill-profile: profile missing required field: version" >&2
    return 1
  fi
  if [ -z "$max_questions" ] || ! [ "$max_questions" -gt 0 ] 2>/dev/null; then
    echo "grill-profile: max_questions must be a positive integer" >&2
    return 1
  fi

  # ── thresholds ────────────────────────────────────────────────────────────
  local ready warn
  ready=$(echo "$json" | jq -r '.thresholds.ready // empty')
  warn=$(echo "$json" | jq -r '.thresholds.warn // empty')

  if [ -z "$ready" ] || [ -z "$warn" ]; then
    echo "grill-profile: thresholds must contain ready and warn" >&2
    return 1
  fi

  # 0 < warn < ready <= 100
  if ! [ "$warn" -gt 0 ] 2>/dev/null; then
    echo "grill-profile: warn threshold (${warn}) must be > 0" >&2
    return 1
  fi
  if ! [ "$ready" -le 100 ] 2>/dev/null; then
    echo "grill-profile: ready threshold (${ready}) must be <= 100" >&2
    return 1
  fi
  if ! [ "$ready" -gt "$warn" ] 2>/dev/null; then
    echo "grill-profile: ready threshold (${ready}) must be > warn threshold (${warn})" >&2
    return 1
  fi

  # ── dimensions ────────────────────────────────────────────────────────────
  local dim_count
  dim_count=$(echo "$json" | jq '.dimensions | length')
  if [ -z "$dim_count" ] || [ "$dim_count" -eq 0 ]; then
    echo "grill-profile: at least one dimension is required" >&2
    return 1
  fi

  # Check weight sum
  local weight_sum
  weight_sum=$(echo "$json" | jq '[.dimensions[].weight] | add')
  if [ "$weight_sum" != "100" ]; then
    echo "grill-profile: dimension weights sum to ${weight_sum}, must be exactly 100" >&2
    return 1
  fi

  # Check unique dimension ids
  local dup_ids
  dup_ids=$(echo "$json" | jq -r '.dimensions[].id' | sort | uniq -d)
  if [ -n "$dup_ids" ]; then
    echo "grill-profile: duplicate dimension ids: ${dup_ids}" >&2
    return 1
  fi

  # Check at least one critical dimension
  local critical_count
  critical_count=$(echo "$json" | jq '[.dimensions[] | select(.critical == true)] | length')
  if [ "$critical_count" -eq 0 ]; then
    echo "grill-profile: at least one dimension must be marked critical: true" >&2
    return 1
  fi

  # Validate each dimension
  local dim_errors
  dim_errors=$(echo "$json" | jq -r '
    .dimensions | to_entries[] |
    select(.value.id == null or .value.id == "" or
           .value.label == null or .value.label == "" or
           .value.weight == null or (.value.weight | type != "number") or
           .value.weight <= 0 or ((.value.weight | floor) != .value.weight))
    | "dimension[\(.key)]: id, label, and positive integer weight are required"
  ')
  if [ -n "$dim_errors" ]; then
    echo "grill-profile: ${dim_errors}" >&2
    return 1
  fi

  # ── flags ─────────────────────────────────────────────────────────────────
  local flag_errors
  flag_errors=$(echo "$json" | jq -r '
    .flags // {} | to_entries[] |
    select(
      (.value.penalty == null) or
      ((.value.penalty | type) != "number") or
      ((.value.penalty | floor) != .value.penalty) or
      (.value.penalty < 0) or
      (.value.cap != null and ((.value.cap | tostring) | IN("ready","proceed-with-warnings","do-not-proceed") | not))
    )
    | "flag[\(.key)]: requires non-negative integer penalty and cap must be a valid recommendation tier or null"
  ')
  if [ -n "$flag_errors" ]; then
    echo "grill-profile: ${flag_errors}" >&2
    return 1
  fi

  return 0
}

# ── grill_profile_list ────────────────────────────────────────────────────────
# Lists available profile ids from a profiles directory.
# Usage: grill_profile_list <profiles-dir>
# ──────────────────────────────────────────────────────────────────────────────
grill_profile_list() {
  local profiles_dir="$1"

  if [ ! -d "$profiles_dir" ]; then
    echo "grill-profile: profiles directory not found: ${profiles_dir}" >&2
    return 2
  fi

  local ids=""
  local file
  for file in "$profiles_dir"/*.json; do
    [ -f "$file" ] || continue
    local pid
    pid=$(jq -r '.id // empty' "$file" 2>/dev/null)
    if [ -n "$pid" ]; then
      if [ -z "$ids" ]; then
        ids="$pid"
      else
        ids="${ids} ${pid}"
      fi
    fi
  done
  echo "$ids"
}
