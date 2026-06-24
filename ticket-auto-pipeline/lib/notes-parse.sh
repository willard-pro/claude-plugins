#!/usr/bin/env bash
# get_complexity <ticket-dir>
# Reads the ## Complexity section's **Score:** value from notes.md.
# Emits "simple", "complex", or empty string if absent.
# Exit codes: 0 = found, 1 = file unreadable, 2 = section not found
# -u (nounset) intentionally omitted: Claude Code shell snapshots inject
# ZSH_VERSION references that trigger false-positive "unbound variable"
# errors in this bash version when nounset is active.
set -eo pipefail

get_complexity() {
  local ticket_dir="$1"
  local notes="$ticket_dir/notes.md"

  if [ ! -f "$notes" ]; then
    return 1
  fi

  local score
  score=$(grep -A3 '## Complexity' "$notes" 2>/dev/null |
    grep '^\*\*Score:' |
    awk '{print $2}' |
    tr -d '\r' || true)

  if [ -n "$score" ]; then
    echo "$score"
    return 0
  fi

  return 2
}

# get_critique_score <ticket-dir>
# Reads the ## Readiness Critique section's **Score:** value from notes.md.
# Emits integer (0-100) or empty string if absent.
# Exit codes: 0 = found, 1 = file unreadable, 2 = section not found
get_critique_score() {
  local ticket_dir="$1"
  local notes="$ticket_dir/notes.md"

  if [ ! -f "$notes" ]; then
    return 1
  fi

  local score
  score=$(sed -n '/## Readiness Critique/,/^## /p' "$notes" 2>/dev/null |
    grep '^\*\*Score:' |
    head -1 |
    sed 's/.*\*\*Score:\*\* *//' |
    grep -oP '^[0-9]+' |
    head -1 || true)

  if [ -n "$score" ]; then
    echo "$score"
    return 0
  fi

  return 2
}

# get_critique_status <ticket-dir>
# Reads the ## Readiness Critique section's **Status:** value from notes.md.
# Emits BLOCKED, WARNINGS, CLEAR, or empty string if absent.
# Exit codes: 0 = found, 1 = file unreadable, 2 = section not found
get_critique_status() {
  local ticket_dir="$1"
  local notes="$ticket_dir/notes.md"

  if [ ! -f "$notes" ]; then
    return 1
  fi

  local status
  status=$(sed -n '/## Readiness Critique/,/^## /p' "$notes" 2>/dev/null |
    grep '^\*\*Status:' |
    head -1 |
    sed 's/.*\*\*Status:\*\* *//' |
    grep -oP '(BLOCKED|WARNINGS|CLEAR)' || true)

  if [ -n "$status" ]; then
    echo "$status"
    return 0
  fi

  return 2
}

# get_ac_count <ticket-dir>
# Counts acceptance criteria lines in context.md.
# Counts numbered (1., 2.) and checkbox (- [ ] and - [x]) criteria lines.
# Emits integer count or empty string.
# Exit codes: 0 = found (may be 0), 1 = file unreadable
get_ac_count() {
  local ticket_dir="$1"
  local ctx="$ticket_dir/context.md"

  if [ ! -f "$ctx" ]; then
    return 1
  fi

  local count
  # Count lines that look like acceptance criteria:
  # - Numbered: "1.", "2.", etc. at start of line (with optional whitespace)
  # - Checkbox: "- [ ]", "- [x]", or "- [X]" at start of line
  count=$(grep -cP '^\s*(\d+\.\s|\- \[[ xX]\]\s)' "$ctx" 2>/dev/null || echo "0")
  echo "${count//[^0-9]/}"
  return 0
}

# get_critique_warning_count <ticket-dir>
# Counts [WARNING] markers in the ## Readiness Critique section of notes.md.
# Emits integer count or empty string.
# Exit codes: 0 = found (may be 0), 1 = file unreadable, 2 = section not found
get_critique_warning_count() {
  local ticket_dir="$1"
  local notes="$ticket_dir/notes.md"

  if [ ! -f "$notes" ]; then
    return 1
  fi

  # Check section exists before counting
  if ! grep -q '## Readiness Critique' "$notes" 2>/dev/null; then
    return 2
  fi

  local count
  count=$(sed -n '/## Readiness Critique/,/^## /p' "$notes" 2>/dev/null |
    grep -c '\[WARNING\]' || echo "0")
  echo "${count//[^0-9]/}"
  return 0
}

# get_critique_blocker_count <ticket-dir>
# Counts [BLOCKER] markers in the ## Readiness Critique section of notes.md.
# Emits integer count or empty string.
# Exit codes: 0 = found (may be 0), 1 = file unreadable, 2 = section not found
get_critique_blocker_count() {
  local ticket_dir="$1"
  local notes="$ticket_dir/notes.md"

  if [ ! -f "$notes" ]; then
    return 1
  fi

  # Check section exists before counting
  if ! grep -q '## Readiness Critique' "$notes" 2>/dev/null; then
    return 2
  fi

  local count
  count=$(sed -n '/## Readiness Critique/,/^## /p' "$notes" 2>/dev/null |
    grep -c '\[BLOCKER\]' || echo "0")
  echo "${count//[^0-9]/}"
  return 0
}

# resolve_test_user_catalog [tickets_root]
# Resolves the path to test-users.json.
# Priority: $TICKETS_ROOT/test-users.json → plugin default config/test-users.json
# If TICKETS_ROOT is unset, checks the current directory for a tickets root.
# Emits absolute path or empty string if no catalog found.
# Exit codes: 0 = found, 1 = not found (non-fatal)
resolve_test_user_catalog() {
  local tickets_root="${1:-${TICKETS_ROOT:-.}}"

  # 1. Project-level override: check tickets root first
  if [ -f "$tickets_root/test-users.json" ]; then
    echo "$tickets_root/test-users.json"
    return 0
  fi

  # 2. Plugin default: check alongside other plugin config files
  if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/config/test-users.json" ]; then
    echo "$CLAUDE_PLUGIN_ROOT/config/test-users.json"
    return 0
  fi
  if [ -f "$HOME/.claude/skills/config/test-users.json" ]; then
    echo "$HOME/.claude/skills/config/test-users.json"
    return 0
  fi

  # 3. Check relative to this script (plugin lib dir → config dir)
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  if [ -f "$script_dir/../config/test-users.json" ]; then
    echo "$script_dir/../config/test-users.json"
    return 0
  fi

  return 1
}

# get_test_users_by_role <role> [catalog_path]
# Queries the test user catalog for all users with the given role.
# Resolves catalog path if not provided.
# Emits JSON array of matching user objects, or empty array if none found.
# Exit codes: 0 = success (may be empty), 1 = no catalog file
get_test_users_by_role() {
  local role="$1"
  local catalog_path="${2:-}"

  if [ -z "$catalog_path" ]; then
    catalog_path=$(resolve_test_user_catalog 2>/dev/null || true)
  fi

  if [ -z "$catalog_path" ] || [ ! -f "$catalog_path" ]; then
    echo "[]"
    return 1
  fi

  jq -c --arg role "$role" '[.[] | select(.roles[]? == $role)]' "$catalog_path" 2>/dev/null || echo "[]"
}

# get_test_users_by_env <env> [catalog_path]
# Queries the test user catalog for all users available in the given environment.
# Resolves catalog path if not provided.
# Emits JSON array of matching user objects, or empty array if none found.
# Exit codes: 0 = success (may be empty), 1 = no catalog file
get_test_users_by_env() {
  local env="$1"
  local catalog_path="${2:-}"

  if [ -z "$catalog_path" ]; then
    catalog_path=$(resolve_test_user_catalog 2>/dev/null || true)
  fi

  if [ -z "$catalog_path" ] || [ ! -f "$catalog_path" ]; then
    echo "[]"
    return 1
  fi

  jq -c --arg env "$env" '[.[] | select(.environments[]? == $env)]' "$catalog_path" 2>/dev/null || echo "[]"
}
