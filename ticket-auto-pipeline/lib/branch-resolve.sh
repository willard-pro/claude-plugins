#!/usr/bin/env bash
# branch-resolve.sh — deterministic branch decision for ticket-auto.
# Sourceable bash library. Does NOT set -euo pipefail (caller controls error
# handling). Resolves which branches a ticket should target: the ticket's own
# branch, the base branch it builds on, and an optional integration branch.
#
# Precedence chain (first match wins):
#   1. --branch flag               (BRANCH_SOURCE=flag)
#   2. Parent epic branch directive (BRANCH_SOURCE=epic-directive)
#   3. config.sh BASE_BRANCH        (BRANCH_SOURCE=default)
#
# Dependencies: config.sh, linear-api.sh, branch-directive-check.sh, jq
#
# Usage:
#   source lib/branch-resolve.sh

# Source dependencies (main path — previously only self-test mode did this,
# leaving check_branch_directive_description undefined during real resolution).
_BR_LIB_DIR="$(dirname "${BASH_SOURCE[0]}")"
source "$_BR_LIB_DIR/config.sh" 2>/dev/null || true
source "$_BR_LIB_DIR/linear-api.sh" 2>/dev/null || true
source "$_BR_LIB_DIR/branch-directive-check.sh" 2>/dev/null || true

#   resolve_branch_context "CRE-123"
#   resolve_branch_context "CRE-123" --branch "epic/test-x"
#   resolve_branch_context "CRE-123" --title "Fix auth" --parent-json '{"id":"CRE-100","description":"..."}'

# ── Public API ──────────────────────────────────────────────────────────────

# resolve_branch_context <TICKET_ID> [--branch <override>] [--title <title>] [--parent-json <json>]
# Resolves branch decisions for a ticket. Emits BRANCH_CONTEXT_RESULT block.
# When --title and --parent-json are provided, skips the get_issue API call
# (test mode). On directive validation failure, emits BRANCH_DIRECTIVE_INVALID
# marker and exits non-zero.
resolve_branch_context() {
  local ticket_id="$1"
  shift

  local branch_override=""
  local inline_title=""
  local inline_parent_json=""

  while [ $# -gt 0 ]; do
    case "$1" in
    --branch)
      branch_override="$2"
      shift 2
      ;;
    --title)
      inline_title="$2"
      shift 2
      ;;
    --parent-json)
      inline_parent_json="$2"
      shift 2
      ;;
    *)
      echo "branch-resolve: unknown option: $1" >&2
      shift
      ;;
    esac
  done

  local title="$inline_title"
  local parent_id=""
  local parent_description=""

  # Fetch ticket data if not provided inline
  if [ -z "$inline_title" ]; then
    local issue_json
    issue_json=$(get_issue "$ticket_id" 2>/dev/null) || {
      echo "branch-resolve: failed to fetch ticket $ticket_id" >&2
      return 1
    }

    # Type guard
    if ! echo "$issue_json" | jq -e '.id and .title' >/dev/null 2>&1; then
      echo "branch-resolve: unexpected response shape for $ticket_id" >&2
      return 1
    fi

    title=$(echo "$issue_json" | jq -r '.title // ""')
    parent_id=$(echo "$issue_json" | jq -r '.parent.id // ""')
    parent_description=$(echo "$issue_json" | jq -r '.parent.description // ""')
  else
    # Extract parent info from inline JSON
    if [ -n "$inline_parent_json" ]; then
      parent_id=$(echo "$inline_parent_json" | jq -r '.id // ""')
      parent_description=$(echo "$inline_parent_json" | jq -r '.description // ""')
    fi
  fi

  # ── Generate ticket branch name ───────────────────────────────────────────
  local ticket_branch
  ticket_branch=$(_generate_branch_name "$ticket_id" "$title")

  # ── Resolve base and integration branches ─────────────────────────────────
  local base_branch
  local integration_branch=""
  local branch_source=""

  # Precedence 1: --branch flag
  if [ -n "$branch_override" ]; then
    if ! _validate_branch_name "$branch_override"; then
      echo "branch-resolve: --branch override '$branch_override' failed branch-name validation" >&2
      return 2
    fi
    base_branch="$branch_override"
    integration_branch="$branch_override"
    branch_source="flag"
    parent_id="" # explicit override, ignore parent

  # Precedence 2: parent epic directive
  elif [ -n "$parent_id" ] && [ -n "$parent_description" ]; then
    # Validate parent description with branch-directive-check.sh
    local directive_output
    directive_output=$(check_branch_directive_description "$parent_description" 2>/dev/null) || {
      local directive_exit=$?
      if [ "$directive_exit" -eq 2 ]; then
        # Malformed directive — gate-stop
        echo "BRANCH_DIRECTIVE_INVALID" >&2
        echo "branch-resolve: parent $parent_id has a malformed Branch Directive — gate-stop" >&2
        return 2
      fi
      # Exit 1 = absent — fall through to default
    }

    if [ -n "$directive_output" ]; then
      # Parse values from check_branch_directive_description output.
      # Output format: KEY='value' lines with single-quoted, validated values.
      # Targeted sed extraction — no eval, no sourcing untrusted input.
      local parsed_branch parsed_base
      parsed_branch=$(echo "$directive_output" | sed -n "s/^BRANCH_DIRECTIVE_BRANCH='\\(.*\\)'$/\\1/p")
      parsed_base=$(echo "$directive_output" | sed -n "s/^BRANCH_DIRECTIVE_BASE='\\(.*\\)'$/\\1/p")

      if [ -n "$parsed_branch" ] && [ -n "$parsed_base" ]; then
        base_branch="$parsed_branch"
        integration_branch="$parsed_branch"
        branch_source="epic-directive"
      fi
    fi
  fi

  # Precedence 3: config default
  if [ -z "$branch_source" ]; then
    base_branch="${BASE_BRANCH:-develop}"
    branch_source="default"
  fi

  # ── Emit result block ─────────────────────────────────────────────────────
  cat <<EOF
BRANCH_CONTEXT_RESULT
  TICKET_BRANCH:        ${ticket_branch}
  BASE_BRANCH:          ${base_branch}
  INTEGRATION_BRANCH:   ${integration_branch:-}
  EPIC_ID:              ${parent_id:-}
  BRANCH_SOURCE:        ${branch_source}
END_BRANCH_CONTEXT_RESULT
EOF

  return 0
}

# ── Internal helpers ────────────────────────────────────────────────────────

# _generate_branch_name <ticket-id> <title>
# Deterministically generates a branch name: {BRANCH_PREFIX}{ID}-{slug}
# Capped at 60 characters. Uses BRANCH_PREFIX from config (default feat/).
_generate_branch_name() {
  local id="$1"
  local title="$2"
  local prefix="${BRANCH_PREFIX:-feat/}"

  # Slugify title: lowercase, replace non-alphanumeric with hyphens, collapse
  local slug
  slug=$(echo "$title" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g; s/--*/-/g; s/^-//; s/-$//')

  # Build full name
  local full_name="${prefix}${id}-${slug}"

  # Cap at 60 chars, trimming from the slug end
  if [ ${#full_name} -gt 60 ]; then
    local prefix_len=$((${#prefix} + ${#id} + 1)) # +1 for the hyphen
    local max_slug_len=$((60 - prefix_len))
    if [ "$max_slug_len" -lt 1 ]; then
      # Prefix+ID alone exceeds 60 chars — trim the ID suffix
      full_name="${full_name:0:60}"
    else
      slug="${slug:0:$max_slug_len}"
      # Remove trailing hyphen from truncation
      slug="${slug%-}"
      full_name="${prefix}${id}-${slug}"
    fi
  fi

  echo "$full_name"
}

# ── Self-test mode ──────────────────────────────────────────────────────────

if [ "${1:-}" = "--self-test" ]; then
  # Save and clear positional args so sourced deps don't inherit --self-test
  set -- ""
  source "$(dirname "${BASH_SOURCE[0]}")/config.sh" 2>/dev/null || true
  source "$(dirname "${BASH_SOURCE[0]}")/planned-ticket-check.sh" 2>/dev/null || true
  source "$(dirname "${BASH_SOURCE[0]}")/branch-directive-check.sh" 2>/dev/null || true

  echo "Running self-tests..."

  # Slug generation
  result=$(_generate_branch_name "CRE-123" "Fix authentication bug")
  [[ "$result" == feat/CRE-123-fix-authentication-bug ]] && echo "✓ basic slug" || echo "✗ basic slug: got '$result'"

  result=$(_generate_branch_name "CRE-123" "Add User Profile & Settings!!!")
  [[ "$result" == feat/CRE-123-add-user-profile-settings ]] && echo "✓ special chars collapsed" || echo "✗ special chars: got '$result'"

  result=$(_generate_branch_name "CRE-123" "  Leading and trailing spaces  ")
  [[ "$result" == feat/CRE-123-leading-and-trailing-spaces ]] && echo "✓ trimmed" || echo "✗ trimmed: got '$result'"

  result=$(_generate_branch_name "CRE-123" "a very long title that goes on and on and on way past the sixty character limit for branch names")
  [ ${#result} -le 60 ] && echo "✓ capped at 60 chars (len=${#result})" || echo "✗ not capped: len=${#result} '$result'"

  # Determinism
  a=$(_generate_branch_name "CRE-123" "Fix auth")
  b=$(_generate_branch_name "CRE-123" "Fix auth")
  [ "$a" = "$b" ] && echo "✓ deterministic" || echo "✗ not deterministic: '$a' vs '$b'"

  echo "Self-tests complete."
  exit 0
fi
