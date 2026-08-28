#!/usr/bin/env bash
# branch-directive-check.sh — deterministic validator for Branch Directive blocks.
# Sourceable bash library. Does NOT set -euo pipefail (caller controls error
# handling). Validates that epic tickets have a properly formed
# `## Branch Directive` block with all required fields.
#
# Exit codes:
#   0 — valid (block present, all required fields valid)
#   1 — section absent (no block found — caller falls back to default)
#   2 — present but malformed (missing fields, invalid values, bad branch name)
#
# Dependencies: linear-api.sh (for get_issue), planned-ticket-check.sh (for shared
#               _extract_md_section and _extract_field), jq
#
# Usage:
#   source lib/branch-directive-check.sh
#   check_branch_directive "CRE-123"              # fetches epic via API
#   check_branch_directive "CRE-123" "description" # inline for testing

# ── Configuration ───────────────────────────────────────────────────────────

BRANCH_DIRECTIVE_SCHEMA_KNOWN_MAX="${BRANCH_DIRECTIVE_SCHEMA_KNOWN_MAX:-2}"

# ── Required fields ─────────────────────────────────────────────────────────

BRANCH_DIRECTIVE_REQUIRED_FIELDS=(
  "Schema-Version"
  "Branch"
  "Base"
  "Merge Policy"
  "Sync Policy"
  "Created"
)

# Valid enum values
VALID_MERGE_POLICIES=("manual" "on-all-children-done")
VALID_SYNC_POLICIES=("rebase-on-base-change" "none")

# Optional fields — validated when present, defaulted when absent. NOT listed in
# BRANCH_DIRECTIVE_REQUIRED_FIELDS: absence must not be reported as missing.
VALID_UAT_POLICIES=("per-ticket" "epic")
BRANCH_DIRECTIVE_UAT_POLICY_DEFAULT="per-ticket"

# ── Branch name validation ──────────────────────────────────────────────────

# Branch name regex: lowercase alphanumeric start, then alphanumeric/dot/underscore/
# slash/dash up to 98 more chars. Must not contain .., leading/trailing /,
# whitespace, or shell metacharacters.
BRANCH_NAME_RE='^[a-z0-9][a-z0-9._/-]{0,98}$'

# Characters/metacharacters that MUST NOT appear in branch names
BRANCH_FORBIDDEN_CHARS='[[:space:];`$(){}\<\>\|\&!#~\\'\''"*\?]'

# _validate_branch_name <value> — true if value is a valid branch name
_validate_branch_name() {
  local val="$1"

  # Empty
  [ -z "$val" ] && return 1

  # Must match charset regex (also catches leading /, trailing /, and length)
  [[ "$val" =~ $BRANCH_NAME_RE ]] || return 1

  # Must not end with /
  [[ "$val" == */ ]] && return 1

  # Must not contain ..
  [[ "$val" == *".."* ]] && return 1

  # Must not contain forbidden metacharacters
  [[ "$val" =~ $BRANCH_FORBIDDEN_CHARS ]] && return 1

  return 0
}

# ── Public API ──────────────────────────────────────────────────────────────

# check_branch_directive <epic-id> [description]
# Fetches epic description via get_issue if not provided inline.
# Sets CHECK_RESULT and CHECK_EXIT_CODE for callers that source this script.
check_branch_directive() {
  local epic_id="$1"
  local description="${2:-}"

  # Fetch if not provided inline (test mode bypass)
  if [ -z "$description" ]; then
    local issue_json
    issue_json=$(get_issue "$epic_id" 2>/dev/null) || {
      echo "branch-directive-check: failed to fetch epic $epic_id" >&2
      CHECK_EXIT_CODE=1
      CHECK_RESULT="api_error"
      return 1
    }
    description=$(echo "$issue_json" | jq -r '.description // ""')
  fi

  # Delegate to description-level check
  check_branch_directive_description "$description"
}

# check_branch_directive_description <description>
# Validates a description string for a `## Branch Directive` block.
# Callable directly in tests with mock descriptions.
# On exit 0, emits parsed field values to stdout for caller consumption.
check_branch_directive_description() {
  local description="$1"

  CHECK_PARSED=""

  # ── Block detection ───────────────────────────────────────────────────────
  # Extract via the shared _extract_md_section helper from planned-ticket-check.sh
  local block
  block=$(_extract_md_section "$description" "Branch Directive")

  if [ -z "$block" ]; then
    CHECK_EXIT_CODE=1
    CHECK_RESULT="absent"
    return 1
  fi

  # ── Schema-Version extraction ─────────────────────────────────────────────
  local schema_version
  schema_version=$(echo "$block" | _extract_field "Schema-Version")

  # Schema-Version tolerance: future versions warn but don't block
  if [ -n "$schema_version" ] && [ "$schema_version" -gt "$BRANCH_DIRECTIVE_SCHEMA_KNOWN_MAX" ] 2>/dev/null; then
    echo "branch-directive-check: Schema-Version $schema_version exceeds known max $BRANCH_DIRECTIVE_SCHEMA_KNOWN_MAX — proceeding with tolerance" >&2
  fi

  # ── Schema-Version type check ─────────────────────────────────────────────
  if [ -n "$schema_version" ] && ! [[ "$schema_version" =~ ^[0-9]+$ ]]; then
    echo "branch-directive-check: Schema-Version must be integer, got '$schema_version'" >&2
    CHECK_EXIT_CODE=2
    CHECK_RESULT="malformed"
    return 2
  fi

  # ── Field validation ──────────────────────────────────────────────────────
  local missing_fields=()
  local invalid_fields=()

  for field in "${BRANCH_DIRECTIVE_REQUIRED_FIELDS[@]}"; do
    local value
    value=$(echo "$block" | _extract_field "$field")

    if [ -z "$value" ]; then
      missing_fields+=("$field")
      continue
    fi

    # Type-specific validation
    case "$field" in
    "Schema-Version")
      # Already type-checked above; valid integer passes
      ;;
    "Branch" | "Base")
      if ! _validate_branch_name "$value"; then
        invalid_fields+=("$field: invalid branch name '$value'")
      fi
      ;;
    "Merge Policy")
      if ! _validate_enum "$value" "${VALID_MERGE_POLICIES[@]}"; then
        invalid_fields+=("$field: expected manual|on-all-children-done, got '$value'")
      fi
      ;;
    "Sync Policy")
      if ! _validate_enum "$value" "${VALID_SYNC_POLICIES[@]}"; then
        invalid_fields+=("$field: expected rebase-on-base-change|none, got '$value'")
      fi
      ;;
    "Created")
      if ! _validate_iso8601 "$value"; then
        invalid_fields+=("$field: expected ISO 8601 timestamp, got '$value'")
      fi
      ;;
    esac
  done

  # ── Optional field: UAT Policy ────────────────────────────────────────────
  # Parsed and validated UNCONDITIONALLY, at any declared Schema-Version.
  # Deliberately not version-gated: an operator who hand-adds this line without
  # also bumping Schema-Version must still get the behaviour, otherwise the
  # field is a silent no-op — the exact failure this field exists to fix.
  local uat_policy
  uat_policy=$(echo "$block" | _extract_field "UAT Policy")

  if [ -n "$uat_policy" ] && ! _validate_enum "$uat_policy" "${VALID_UAT_POLICIES[@]}"; then
    invalid_fields+=("UAT Policy: expected per-ticket|epic, got '$uat_policy'")
  fi

  # ── Report missing/invalid fields ─────────────────────────────────────────
  if [ ${#missing_fields[@]} -gt 0 ] || [ ${#invalid_fields[@]} -gt 0 ]; then
    local msg=""
    [ ${#missing_fields[@]} -gt 0 ] && msg="missing: ${missing_fields[*]}"
    [ ${#invalid_fields[@]} -gt 0 ] && msg="${msg:+$msg; }invalid: ${invalid_fields[*]}"
    echo "branch-directive-check: $msg" >&2
    CHECK_EXIT_CODE=2
    CHECK_RESULT="malformed"
    return 2
  fi

  # ── Emit parsed values for caller consumption ─────────────────────────────
  # Output format: one KEY=VALUE per line, values quoted for safe eval/sourcing.
  # Callers can `eval "$parsed"` or grep for specific keys.
  local branch base merge_policy sync_policy created
  branch=$(echo "$block" | _extract_field "Branch")
  base=$(echo "$block" | _extract_field "Base")
  merge_policy=$(echo "$block" | _extract_field "Merge Policy")
  sync_policy=$(echo "$block" | _extract_field "Sync Policy")
  created=$(echo "$block" | _extract_field "Created")

  # Materialise the default here rather than leaving it to consumers, so that
  # every caller reads one normalised value and none re-derives the fallback.
  [ -z "$uat_policy" ] && uat_policy="$BRANCH_DIRECTIVE_UAT_POLICY_DEFAULT"

  cat <<EOF
BRANCH_DIRECTIVE_BRANCH='$branch'
BRANCH_DIRECTIVE_BASE='$base'
BRANCH_DIRECTIVE_MERGE_POLICY='$merge_policy'
BRANCH_DIRECTIVE_SYNC_POLICY='$sync_policy'
BRANCH_DIRECTIVE_UAT_POLICY='$uat_policy'
BRANCH_DIRECTIVE_CREATED='$created'
EOF

  CHECK_EXIT_CODE=0
  CHECK_RESULT="valid"
  return 0
}

# ── Self-test mode ──────────────────────────────────────────────────────────
# Run with --self-test to smoke-check internal helpers.

if [ "${1:-}" = "--self-test" ]; then
  echo "Running self-tests..."

  # Branch name validation
  _validate_branch_name "epic/test-branch" && echo "✓ epic/test-branch valid" || echo "✗ epic/test-branch should be valid"
  _validate_branch_name "develop" && echo "✓ develop valid" || echo "✗ develop should be valid"
  _validate_branch_name "feature/proj-123_fix-auth" && echo "✓ feature/proj-123_fix-auth valid" || echo "✗ should be valid"
  _validate_branch_name "a" && echo "✓ single-char valid" || echo "✗ single-char should be valid"
  ! _validate_branch_name "" && echo "✓ empty invalid" || echo "✗ empty should be invalid"
  ! _validate_branch_name "../escape" && echo "✓ ../escape invalid" || echo "✗ ../escape should be invalid"
  ! _validate_branch_name "/leading-slash" && echo "✓ /leading-slash invalid" || echo "✗ /leading-slash should be invalid"
  ! _validate_branch_name "trailing/" && echo "✓ trailing/ invalid" || echo "✗ trailing/ should be invalid"
  ! _validate_branch_name "has space" && echo "✓ 'has space' invalid" || echo "✗ should be invalid"
  ! _validate_branch_name "semi;colon" && echo "✓ semicolon invalid" || echo "✗ semicolon should be invalid"
  ! _validate_branch_name 'back`tick' && echo "✓ backtick invalid" || echo "✗ backtick should be invalid"
  ! _validate_branch_name 'dollar$(id)' && echo "✓ dollar-subshell invalid" || echo "✗ dollar-subshell should be invalid"

  # Enum validation
  _validate_enum "manual" "${VALID_MERGE_POLICIES[@]}" && echo "✓ manual valid" || echo "✗ manual should be valid"
  _validate_enum "on-all-children-done" "${VALID_MERGE_POLICIES[@]}" && echo "✓ on-all-children-done valid" || echo "✗ should be valid"
  ! _validate_enum "auto" "${VALID_MERGE_POLICIES[@]}" && echo "✓ auto invalid" || echo "✗ auto should be invalid"

  _validate_enum "rebase-on-base-change" "${VALID_SYNC_POLICIES[@]}" && echo "✓ rebase-on-base-change valid" || echo "✗ should be valid"
  _validate_enum "none" "${VALID_SYNC_POLICIES[@]}" && echo "✓ none valid" || echo "✗ none should be valid"
  ! _validate_enum "force-push" "${VALID_SYNC_POLICIES[@]}" && echo "✓ force-push invalid" || echo "✗ force-push should be invalid"

  _validate_enum "per-ticket" "${VALID_UAT_POLICIES[@]}" && echo "✓ per-ticket valid" || echo "✗ per-ticket should be valid"
  _validate_enum "epic" "${VALID_UAT_POLICIES[@]}" && echo "✓ epic valid" || echo "✗ epic should be valid"
  ! _validate_enum "team" "${VALID_UAT_POLICIES[@]}" && echo "✓ team invalid" || echo "✗ team should be invalid"

  # ISO 8601 validation
  _validate_iso8601 "2026-07-25T10:00:00Z" && echo "✓ ISO 8601 valid" || echo "✗ ISO 8601 should be valid"
  ! _validate_iso8601 "yesterday" && echo "✓ 'yesterday' invalid" || echo "✗ 'yesterday' should be invalid"

  echo "Self-tests complete."
  exit 0
fi
