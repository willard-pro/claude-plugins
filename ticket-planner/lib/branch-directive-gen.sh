#!/usr/bin/env bash
# branch-directive-gen.sh — Deterministic Branch Directive block generator.
#
# Generates the `## Branch Directive` markdown block that branch-directive-check.sh
# validates. Takes structured JSON input; outputs formatted markdown.
#
# The generator is pure bash — no LLM. Generate against the validator, not the
# schema document. Round-trip validation through branch-directive-check.sh is the
# contract test.
#
# Usage:
#   branch_directive_generate <directive_json>
#     directive_json: JSON with required fields.
#     Outputs: formatted `## Branch Directive` markdown block.
#     Returns: 0 on success, 1 if validation fails (no output emitted).
#
#   branch_directive_name_derive <initiative_id> <title_slug>
#     Derives a deterministic branch name. Pure bash, no agent input.
#     Returns: branch name on stdout (e.g., epic/INIT-42-debt-collection).
#
# Sourceable library — no set -euo pipefail.

# ── Configuration ─────────────────────────────────────────────────────────────

BRANCH_DIRECTIVE_GEN_SCHEMA_VERSION="${BRANCH_DIRECTIVE_GEN_SCHEMA_VERSION:-1}"
BRANCH_DIRECTIVE_GEN_MAX_NAME_LENGTH="${BRANCH_DIRECTIVE_GEN_MAX_NAME_LENGTH:-60}"

# Required fields
BRANCH_DIRECTIVE_GEN_REQUIRED_FIELDS=(
  "initiative_id"
  "title_slug"
  "base_branch"
  "merge_policy"
  "sync_policy"
)

# Valid enum values — must match branch-directive-check.sh exactly
VALID_MERGE_POLICIES_GEN=("manual" "on-all-children-done")
VALID_SYNC_POLICIES_GEN=("rebase-on-base-change" "none")

# Optional field. Absent from BRANCH_DIRECTIVE_GEN_REQUIRED_FIELDS on purpose:
# omitting it must remain valid, and the validator resolves the absent case to
# 'per-ticket'. Emitted only when explicitly requested, so directives generated
# before this field existed are byte-identical.
VALID_UAT_POLICIES_GEN=("per-ticket" "epic")

# ── Branch name derivation ───────────────────────────────────────────────────

# Derive a deterministic epic integration branch name from initiative identity.
# Format: epic/{INITIATIVE_ID}-{title-slug}, capped at the configured max length.
#
# Guarantees: no trailing dash or slash after truncation, lowercase, no chars
# outside [a-z0-9._/-], matches ^[a-z0-9]. These properties satisfy the
# branch-directive-check.sh validator by construction — no agent involved.
#
# Usage: branch_directive_name_derive <initiative_id> <title_slug>
branch_directive_name_derive() {
  local initiative_id="$1" title_slug="$2"
  local max_len="${BRANCH_DIRECTIVE_GEN_MAX_NAME_LENGTH}"

  # Build the full name
  local candidate="epic/${initiative_id}-${title_slug}"

  # Lowercase (branch names are case-sensitive on some filesystems, but
  # always-lowercase avoids confusion)
  candidate=$(echo "$candidate" | tr '[:upper:]' '[:lower:]')

  # Replace chars outside [a-z0-9._/-] with dashes
  # Preserve / as path separator
  candidate=$(echo "$candidate" | sed 's/[^a-z0-9._/-]/-/g')

  # Collapse consecutive dashes
  candidate=$(echo "$candidate" | sed 's/--*/-/g')

  # Truncate to max length
  if [ "${#candidate}" -gt "$max_len" ]; then
    candidate="${candidate:0:$max_len}"
    # Strip trailing dash (would produce an invalid branch name)
    candidate=$(echo "$candidate" | sed 's/-*$//')
    # Strip trailing slash (would produce directory ambiguity)
    candidate=$(echo "$candidate" | sed 's|/*$||')
    # Strip trailing dot (confuses some git versions)
    candidate=$(echo "$candidate" | sed 's/\.*$//')
  fi

  # Final safety: ensure minimum length and leading char
  if [ "${#candidate}" -lt 1 ]; then
    echo "ERROR: derived branch name is empty after sanitization" >&2
    return 1
  fi

  # Ensure leading char is lowercase alphanumeric
  if ! echo "$candidate" | grep -qE '^[a-z0-9]'; then
    echo "ERROR: derived branch name starts with invalid char: $candidate" >&2
    return 1
  fi

  echo "$candidate"
  return 0
}

# ── Public API ────────────────────────────────────────────────────────────────

# Resolve the downstream branch-directive-check.sh validator.
# Three-level fallback, same pattern as planner-ticket-validate.sh:
#   1. Plugin cache  →  ~/.claude/plugins/cache/ticket-auto-pipeline/*/lib/
#   2. Skills lib    →  ~/.claude/skills/ticket-auto-pipeline/lib/
#   3. Relative path →  sibling ticket-auto-pipeline/lib/
#
# No bundled copy — the dependency is deliberate to prevent schema drift.
#
# Usage: _resolve_branch_directive_checker
# Output: path to branch-directive-check.sh, or empty string if not found.
_resolve_branch_directive_checker() {
  local checker script_dir

  # Level 1: Plugin cache
  checker=$(find "${HOME}/.claude/plugins/cache" -name "branch-directive-check.sh" \
    -path "*/ticket-auto-pipeline/*/lib/branch-directive-check.sh" 2>/dev/null | sort | tail -1)
  if [ -n "$checker" ] && [ -f "$checker" ]; then
    echo "$checker"
    return 0
  fi

  # Level 2: Skills lib (legacy installs)
  checker="${HOME}/.claude/skills/ticket-auto-pipeline/lib/branch-directive-check.sh"
  if [ -f "$checker" ]; then
    echo "$checker"
    return 0
  fi

  # Level 3: Relative path (sibling in same repo)
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  checker="${script_dir}/../../ticket-auto-pipeline/lib/branch-directive-check.sh"
  if [ -f "$checker" ]; then
    echo "$checker"
    return 0
  fi

  # Not found
  echo ""
  return 1
}

# Resolve planned-ticket-check.sh — branch-directive-check.sh's own prerequisite.
# It is the canonical home of the `_extract_md_section` / `_extract_field`
# markdown helpers, which the Epic Gen phase prompt needs to read a Branch
# Directive back out of an existing epic description (idempotent re-entry).
#
# Same three-level fallback as _resolve_branch_directive_checker above. The
# level-2 path differs: ticket-auto-pipeline's SessionStart hook copies its
# lib/*.sh flat into ~/.claude/skills/lib/, which is where planner-doctor.sh
# and planner-ticket-validate.sh already look for this same file.
#
# Usage: _resolve_planned_ticket_check
# Output: path to planned-ticket-check.sh, or empty string if not found.
_resolve_planned_ticket_check() {
  local checker script_dir

  # Level 1: Plugin cache
  checker=$(find "${HOME}/.claude/plugins/cache" -name "planned-ticket-check.sh" \
    -path "*/ticket-auto-pipeline/*/lib/planned-ticket-check.sh" 2>/dev/null | sort | tail -1)
  if [ -n "$checker" ] && [ -f "$checker" ]; then
    echo "$checker"
    return 0
  fi

  # Level 2: Skills lib (SessionStart hook copy / legacy installs)
  checker="${HOME}/.claude/skills/lib/planned-ticket-check.sh"
  if [ -f "$checker" ]; then
    echo "$checker"
    return 0
  fi

  # Level 3: Relative path (sibling in same repo)
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  checker="${script_dir}/../../ticket-auto-pipeline/lib/planned-ticket-check.sh"
  if [ -f "$checker" ]; then
    echo "$checker"
    return 0
  fi

  # Not found
  echo ""
  return 1
}

# Make the `_extract_md_section` / `_extract_field` markdown helpers available in
# the current shell. Idempotent — a no-op when both are already declared, so a
# caller that has independently sourced planned-ticket-check.sh pays nothing.
#
# Callers must not assume these helpers exist: they are defined in
# ticket-auto-pipeline, not here, and there is no bundled copy. Sourcing the
# canonical file is what keeps the Epic Gen idempotency check reading a Branch
# Directive block by exactly the rules the downstream validator writes it by.
#
# Usage: branch_directive_source_md_helpers
# Returns: 0 when both helpers are declared, 1 when the source file is missing.
branch_directive_source_md_helpers() {
  if declare -f _extract_md_section >/dev/null 2>&1 &&
    declare -f _extract_field >/dev/null 2>&1; then
    return 0
  fi

  local checker
  checker=$(_resolve_planned_ticket_check)
  if [ -z "$checker" ]; then
    echo "branch-directive-gen: planned-ticket-check.sh not found — _extract_md_section/_extract_field unavailable (install ticket-auto-pipeline)" >&2
    return 1
  fi

  # shellcheck source=/dev/null
  source "$checker"

  if ! declare -f _extract_md_section >/dev/null 2>&1 ||
    ! declare -f _extract_field >/dev/null 2>&1; then
    echo "branch-directive-gen: ${checker} sourced but did not define _extract_md_section/_extract_field" >&2
    return 1
  fi

  return 0
}

# Generate a Branch Directive block from JSON input.
# Usage: branch_directive_generate <directive_json>
branch_directive_generate() {
  local directive_json="$1"

  # Validate JSON parseable
  if ! echo "$directive_json" | jq -e . >/dev/null 2>&1; then
    echo "branch-directive-gen: invalid JSON input" >&2
    return 1
  fi

  # Validate all required fields present
  local missing
  missing=$(echo "$directive_json" | jq -r '
    $required[] as $field |
    if has($field) | not then $field else empty end
  ' --argjson required "$(printf '%s\n' "${BRANCH_DIRECTIVE_GEN_REQUIRED_FIELDS[@]}" | jq -R . | jq -s .)" 2>/dev/null)

  if [ -n "$missing" ]; then
    echo "branch-directive-gen: missing required fields: $missing" >&2
    return 1
  fi

  # Extract fields
  local initiative_id title_slug base_branch merge_policy sync_policy created
  initiative_id=$(echo "$directive_json" | jq -r '.initiative_id')
  title_slug=$(echo "$directive_json" | jq -r '.title_slug')
  base_branch=$(echo "$directive_json" | jq -r '.base_branch')
  merge_policy=$(echo "$directive_json" | jq -r '.merge_policy')
  sync_policy=$(echo "$directive_json" | jq -r '.sync_policy')
  created=$(echo "$directive_json" | jq -r '.created // ""')

  local uat_policy
  uat_policy=$(echo "$directive_json" | jq -r '.uat_policy // ""')
  [ "$uat_policy" = "null" ] && uat_policy=''

  # Validate Merge Policy enum
  local valid=false
  for v in "${VALID_MERGE_POLICIES_GEN[@]}"; do
    [ "$merge_policy" = "$v" ] && valid=true && break
  done
  if [ "$valid" != "true" ]; then
    echo "branch-directive-gen: invalid Merge Policy '$merge_policy' (must be manual|on-all-children-done)" >&2
    return 1
  fi

  # Validate Sync Policy enum
  valid=false
  for v in "${VALID_SYNC_POLICIES_GEN[@]}"; do
    [ "$sync_policy" = "$v" ] && valid=true && break
  done
  if [ "$valid" != "true" ]; then
    echo "branch-directive-gen: invalid Sync Policy '$sync_policy' (must be rebase-on-base-change|none)" >&2
    return 1
  fi

  # Validate UAT Policy enum — only when supplied, since the field is optional.
  if [ -n "$uat_policy" ]; then
    valid=false
    for v in "${VALID_UAT_POLICIES_GEN[@]}"; do
      [ "$uat_policy" = "$v" ] && valid=true && break
    done
    if [ "$valid" != "true" ]; then
      echo "branch-directive-gen: invalid UAT Policy '$uat_policy' (must be per-ticket|epic)" >&2
      return 1
    fi
  fi

  # Derive branch name deterministically
  local branch_name
  branch_name=$(branch_directive_name_derive "$initiative_id" "$title_slug") || {
    echo "branch-directive-gen: failed to derive branch name" >&2
    return 1
  }

  # Generate timestamp if not provided
  if [ -z "$created" ] || [ "$created" = "null" ]; then
    created=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  fi

  # ── Emit the formatted block (exact field order the validator expects) ──────
  local schema_version="${BRANCH_DIRECTIVE_GEN_SCHEMA_VERSION}"

  # The UAT Policy line is emitted only when requested. Absent, the validator
  # resolves 'per-ticket', so this keeps output identical to pre-change runs.
  local uat_policy_line=""
  [ -n "$uat_policy" ] && uat_policy_line="**UAT Policy:** ${uat_policy}"

  cat <<BRANCH_DIRECTIVE
## Branch Directive
**Schema-Version:** ${schema_version}
**Branch:** ${branch_name}
**Base:** ${base_branch}
**Merge Policy:** ${merge_policy}
**Sync Policy:** ${sync_policy}${uat_policy_line:+
${uat_policy_line}}
**Created:** ${created}
BRANCH_DIRECTIVE

  return 0
}

# ── Self-test mode ────────────────────────────────────────────────────────────
# Run with --self-test to smoke-check internal helpers.

if [ "${1:-}" = "--self-test" ]; then
  echo "Running self-tests..."

  # Branch name derivation
  name=$(branch_directive_name_derive "INIT-42" "debt-collection-v2")
  echo "$name" | grep -qE '^[a-z0-9]' && echo "✓ name starts with valid char: $name" || echo "✗ bad leading char: $name"
  [ "${#name}" -le 60 ] && echo "✓ name within 60 chars (${#name})" || echo "✗ name too long: ${#name}"
  echo "$name" | grep -q "^epic/" && echo "✓ name has epic/ prefix" || echo "✗ missing epic/ prefix: $name"

  # No trailing dash after truncation
  long_slug=$(python3 -c "print('x' * 70)" 2>/dev/null || printf 'x%.0s' {1..70})
  name=$(branch_directive_name_derive "INIT-42" "$long_slug")
  [ "${#name}" -le 60 ] && echo "✓ long name truncated to ${#name}" || echo "✗ not truncated: ${#name}"
  echo "$name" | grep -qv -- '-$' && echo "✓ no trailing dash" || echo "✗ trailing dash: $name"
  echo "$name" | grep -qv '/$' && echo "✓ no trailing slash" || echo "✗ trailing slash: $name"

  # No forbidden chars
  ! echo "$name" | grep -q '[[:space:];`$(){}\<\>\|\&!#~\\'\''\"*\?]' && echo "✓ no forbidden chars" || echo "✗ forbidden chars found"

  # Generator accepts valid JSON
  valid_json='{"initiative_id":"INIT-42","title_slug":"debt-collection","base_branch":"develop","merge_policy":"manual","sync_policy":"none"}'
  output=$(branch_directive_generate "$valid_json") && rc=$? || rc=$?
  [ "$rc" -eq 0 ] && echo "✓ valid JSON accepted" || echo "✗ valid JSON rejected: rc=$rc"
  echo "$output" | grep -q "## Branch Directive" && echo "✓ output contains header" || echo "✗ missing header"

  # Generator rejects invalid merge policy
  bad_merge='{"initiative_id":"INIT-42","title_slug":"test","base_branch":"develop","merge_policy":"auto","sync_policy":"none"}'
  branch_directive_generate "$bad_merge" >/dev/null 2>&1 && echo "✗ bad merge policy accepted" || echo "✓ bad merge policy rejected"

  # Generator rejects invalid sync policy
  bad_sync='{"initiative_id":"INIT-42","title_slug":"test","base_branch":"develop","merge_policy":"manual","sync_policy":"force-push"}'
  branch_directive_generate "$bad_sync" >/dev/null 2>&1 && echo "✗ bad sync policy accepted" || echo "✓ bad sync policy rejected"

  # Generator rejects missing field
  missing_field='{"initiative_id":"INIT-42","title_slug":"test","base_branch":"develop","merge_policy":"manual"}'
  branch_directive_generate "$missing_field" >/dev/null 2>&1 && echo "✗ missing field accepted" || echo "✓ missing field rejected"

  # Generator rejects unparseable JSON
  branch_directive_generate "not json" >/dev/null 2>&1 && echo "✗ unparseable accepted" || echo "✓ unparseable rejected"

  echo "Self-tests complete."
  exit 0
fi
