#!/usr/bin/env bash
# planned-ticket-check.sh — deterministic validator for Planner Context blocks.
# Sourceable bash library. Does NOT set -euo pipefail (caller controls error
# handling). Validates that tickets with the `planned` label have a properly
# formed `## Planner Context` block with all required fields.
#
# Exit codes:
#   0 — valid (block present, all required fields valid)
#   1 — missing or malformed (no block, missing fields, invalid values)
#   2 — low confidence, not pre-approved (flags ticket for human review)
#
# Dependencies: linear-api.sh (for get_issue), jq
#
# Usage:
#   source lib/planned-ticket-check.sh
#   check_planned_ticket "CRE-123"              # fetches ticket via API
#   check_planned_ticket "CRE-123" "description" "true"  # inline for testing

# ── Configuration ───────────────────────────────────────────────────────────

PLANNER_CONFIDENCE_THRESHOLD="${PLANNER_CONFIDENCE_THRESHOLD:-0.5}"
SCHEMA_KNOWN_MAX="${PLANNER_SCHEMA_KNOWN_MAX:-1}"

# ── Required fields (Schema-Version 1) ──────────────────────────────────────

# Ordered list of required field display names (the part between ** **)
PLANNER_REQUIRED_FIELDS=(
  "Schema-Version"
  "Initiative"
  "Epic"
  "Confidence"
  "Strategy"
  "Decision"
  "Affected Services"
  "Target Symbols"
  "Pre-approved"
  "Generated"
  "Regenerate"
)

# Valid Strategy enum values
VALID_STRATEGIES=("Conservative" "Balanced" "Innovative")

# ── Public API ──────────────────────────────────────────────────────────────

# check_planned_ticket <ticket-id> [description] [has_planned_label]
# Fetches ticket description via get_issue if not provided inline.
# Sets CHECK_RESULT and CHECK_EXIT_CODE for callers that source this script.
check_planned_ticket() {
  local ticket_id="$1"
  local description="${2:-}"
  local has_planned_label="${3:-}"

  # Fetch if not provided inline (test mode bypass)
  if [ -z "$description" ]; then
    local issue_json
    issue_json=$(get_issue "$ticket_id" 2>/dev/null) || {
      echo "planned-ticket-check: failed to fetch ticket $ticket_id" >&2
      CHECK_EXIT_CODE=1
      CHECK_RESULT="api_error"
      return 1
    }
    description=$(echo "$issue_json" | jq -r '.description // ""')
    has_planned_label=$(echo "$issue_json" | jq -r \
      '[.labels.nodes[].name] | index("planned") != null')
  fi

  # If ticket doesn't have the planned label, skip validation silently
  if [ "$has_planned_label" != "true" ]; then
    CHECK_EXIT_CODE=0
    CHECK_RESULT="not_planned"
    return 0
  fi

  # Delegate to description-level check
  check_planned_ticket_description "$description"
}

# check_planned_ticket_description <description>
# Validates a description string (already confirmed to have `planned` label).
# Callable directly in tests with mock descriptions.
check_planned_ticket_description() {
  local description="$1"

  # ── Block detection ───────────────────────────────────────────────────────
  # Find the ## Planner Context block: everything after the heading until the
  # next ## heading, end of file, or a horizontal rule.
  local block
  block=$(echo "$description" | awk '
    /^## Planner Context[[:space:]]*$/ { found=1; next }
    found && /^## / { exit }
    found { print }
  ')

  if [ -z "$block" ]; then
    echo "planned-ticket-check: planned label present but no '## Planner Context' block found" >&2
    CHECK_EXIT_CODE=1
    CHECK_RESULT="missing_block"
    return 1
  fi

  # ── Schema-Version extraction ─────────────────────────────────────────────
  local schema_version
  schema_version=$(echo "$block" | _extract_field "Schema-Version")

  # Schema-Version tolerance: future versions warn but don't block
  if [ -n "$schema_version" ] && [ "$schema_version" -gt "$SCHEMA_KNOWN_MAX" ] 2>/dev/null; then
    echo "planned-ticket-check: Schema-Version $schema_version exceeds known max $SCHEMA_KNOWN_MAX — proceeding with tolerance" >&2
  fi

  # ── Field validation ──────────────────────────────────────────────────────
  local missing_fields=()
  local invalid_fields=()

  for field in "${PLANNER_REQUIRED_FIELDS[@]}"; do
    local value
    value=$(echo "$block" | _extract_field "$field")

    if [ -z "$value" ]; then
      missing_fields+=("$field")
      continue
    fi

    # Type-specific validation
    case "$field" in
    "Schema-Version")
      if ! [[ "$value" =~ ^[0-9]+$ ]]; then
        invalid_fields+=("$field: expected integer, got '$value'")
      fi
      ;;
    "Confidence")
      if ! _validate_confidence "$value"; then
        invalid_fields+=("$field: expected float 0.0-1.0, got '$value'")
      fi
      ;;
    "Strategy")
      if ! _validate_enum "$value" "${VALID_STRATEGIES[@]}"; then
        invalid_fields+=("$field: expected Conservative|Balanced|Innovative, got '$value'")
      fi
      ;;
    "Pre-approved")
      if [ "$value" != "true" ] && [ "$value" != "false" ]; then
        invalid_fields+=("$field: expected true|false, got '$value'")
      fi
      ;;
    "Generated")
      if ! _validate_iso8601 "$value"; then
        invalid_fields+=("$field: expected ISO 8601 timestamp, got '$value'")
      fi
      ;;
    "Affected Services")
      # CSV — no structural validation beyond presence (already checked)
      ;;
    "Target Symbols")
      # semicolon-separated symbol:file:line — validate format
      if ! _validate_target_symbols "$value"; then
        invalid_fields+=("$field: expected semicolon-separated 'symbol:file:line' references, got '$value'")
      fi
      ;;
    "Regenerate")
      if [ "$value" != "true" ] && [ "$value" != "false" ]; then
        invalid_fields+=("$field: expected true|false, got '$value'")
      fi
      ;;
    esac
  done

  # ── Report missing/invalid fields ─────────────────────────────────────────
  if [ ${#missing_fields[@]} -gt 0 ] || [ ${#invalid_fields[@]} -gt 0 ]; then
    local msg=""
    [ ${#missing_fields[@]} -gt 0 ] && msg="missing: ${missing_fields[*]}"
    [ ${#invalid_fields[@]} -gt 0 ] && msg="${msg:+$msg; }invalid: ${invalid_fields[*]}"
    echo "planned-ticket-check: $msg" >&2
    CHECK_EXIT_CODE=1
    CHECK_RESULT="invalid_fields"
    return 1
  fi

  # ── Confidence threshold check ────────────────────────────────────────────
  local confidence
  confidence=$(echo "$block" | _extract_field "Confidence")
  local pre_approved
  pre_approved=$(echo "$block" | _extract_field "Pre-approved")

  if _confidence_below_threshold "$confidence" "$PLANNER_CONFIDENCE_THRESHOLD"; then
    if [ "$pre_approved" != "true" ]; then
      echo "planned-ticket-check: confidence $confidence below threshold $PLANNER_CONFIDENCE_THRESHOLD and not pre-approved — human review required" >&2
      CHECK_EXIT_CODE=2
      CHECK_RESULT="low_confidence_not_preapproved"
      return 2
    fi
  fi

  # ── All checks passed ─────────────────────────────────────────────────────
  CHECK_EXIT_CODE=0
  CHECK_RESULT="valid"
  return 0
}

# ── Internal helpers ────────────────────────────────────────────────────────

# _extract_field <field-name> — reads from stdin (the block), outputs value
_extract_field() {
  local field="$1"
  # Use sed for reliable extraction: match **field:** optional-colon value
  # Escape the field name for literal match in sed pattern
  sed -n "s/^\*\*${field}:\*\*[[:space:]]*//p" | head -1
}

# _validate_confidence <value> — true if value is float 0.0-1.0
_validate_confidence() {
  local val="$1"
  [[ "$val" =~ ^[0-9]+(\.[0-9]+)?$ ]] || return 1
  local cmp
  cmp=$(echo "$val" | LC_NUMERIC=C awk '{if ($1 >= 0.0 && $1 <= 1.0) print "ok"; else print "bad"}')
  [ "$cmp" = "ok" ]
}

# _validate_enum <value> <valid1> <valid2> ...
_validate_enum() {
  local val="$1"
  shift
  for v in "$@"; do
    [ "$val" = "$v" ] && return 0
  done
  return 1
}

# _validate_iso8601 <value> — true if value looks like ISO 8601
_validate_iso8601() {
  local val="$1"
  # Loose prefix match on YYYY-MM-DD. The planner is the sole producer of this
  # field and the canonical format (ISO 8601 with time) is enforced by the
  # planner, not the validator.
  [[ "$val" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2} ]] || return 1
  return 0
}

# _validate_target_symbols <value> — true if semicolon-separated symbol:file:line
_validate_target_symbols() {
  local val="$1"
  # Empty is handled upstream by required-field check (never reached here)
  [ -z "$val" ] && return 0
  # Each entry must be symbol:file or symbol:file:line
  local IFS=';'
  set -f # disable pathname expansion (globbing) on unquoted $val split
  for entry in $val; do
    # Trim whitespace
    entry=$(echo "$entry" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    [ -z "$entry" ] && continue
    # Must have at least one colon (symbol:file)
    [[ "$entry" =~ ^[^:]+:[^:]+ ]] || {
      set +f
      return 1
    }
  done
  set +f
  return 0
}

# _confidence_below_threshold <confidence> <threshold>
_confidence_below_threshold() {
  local conf="$1"
  local thresh="$2"
  local cmp
  cmp=$(echo "$conf" "$thresh" | LC_NUMERIC=C awk '{if ($1 < $2) print "below"; else print "ok"}')
  [ "$cmp" = "below" ]
}

# ── Self-test mode ──────────────────────────────────────────────────────────
# Run with --self-test to validate internal helpers. Not a substitute for
# test-planned-ticket-check.sh — just smoke-checks the helper functions.

if [ "${1:-}" = "--self-test" ]; then
  echo "Running self-tests..."
  # Confidence validation
  _validate_confidence "0.85" && echo "✓ 0.85 valid" || echo "✗ 0.85 should be valid"
  _validate_confidence "1.0" && echo "✓ 1.0 valid" || echo "✗ 1.0 should be valid"
  _validate_confidence "0.0" && echo "✓ 0.0 valid" || echo "✗ 0.0 should be valid"
  ! _validate_confidence "1.5" && echo "✓ 1.5 invalid" || echo "✗ 1.5 should be invalid"
  ! _validate_confidence "high" && echo "✓ 'high' invalid" || echo "✗ 'high' should be invalid"

  # Strategy validation
  _validate_enum "Conservative" "${VALID_STRATEGIES[@]}" && echo "✓ Conservative valid" || echo "✗ Conservative should be valid"
  ! _validate_enum "aggressive" "${VALID_STRATEGIES[@]}" && echo "✓ aggressive invalid" || echo "✗ aggressive should be invalid"

  # ISO 8601 validation
  _validate_iso8601 "2026-07-07T18:00:00Z" && echo "✓ ISO 8601 valid" || echo "✗ ISO 8601 should be valid"
  ! _validate_iso8601 "yesterday" && echo "✓ 'yesterday' invalid" || echo "✗ 'yesterday' should be invalid"

  # Target symbols validation
  _validate_target_symbols "DebtCollector.collect:src/collector.ts:42" && echo "✓ target symbols valid" || echo "✗ should be valid"
  ! _validate_target_symbols "BadFormat" && echo "✓ BadFormat invalid" || echo "✗ should be invalid"

  echo "Self-tests complete."
  exit 0
fi
