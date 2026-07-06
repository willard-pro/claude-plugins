#!/usr/bin/env bash
# get_complexity <ticket-dir>
# Reads the ## Complexity section's **Score:** value from notes.md.
# Emits "simple", "complex", or empty string if absent.
# Exit codes: 0 = found, 1 = file unreadable, 2 = section not found
# -u (nounset) intentionally omitted: Claude Code shell snapshots inject
# ZSH_VERSION references that trigger false-positive "unbound variable"
# errors in this bash version when nounset is active.
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$SCRIPT_DIR/error-handler.sh" ]; then
  source "$SCRIPT_DIR/error-handler.sh"
fi

get_complexity() {
  local ticket_dir="$1"
  local notes="$ticket_dir/notes.md"

  if [ ! -f "$notes" ]; then
    error_return 12 "notes-parse: file not found"
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
    error_return 12 "notes-parse: file not found"
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
    error_return 12 "notes-parse: file not found"
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
    error_return 12 "notes-parse: file not found"
  fi

  local count
  # Count numbered (1., 2.) and checkbox (- [ ] and - [x]) criteria lines.
  # CRITICAL: stop counting at repro section headings — reproduction steps
  # are numbered but are NOT acceptance criteria.
  # Strategy: extract everything before the first repro/non-AC section heading,
  # then count AC lines within that prefix only.
  local prefix
  prefix=$(sed -E '/^#*\s*(Steps to Repro|Reproduct|How to Repro|Reproduction Steps|To Reproduce|Background|Context|Environment|Notes|Setup|Prerequisites)/Iq' "$ctx" 2>/dev/null || true)
  if [ -z "$prefix" ]; then
    # sed failed or file is entirely repro steps — count from whole file as fallback
    prefix=$(cat "$ctx" 2>/dev/null || true)
  fi
  count=$(echo "$prefix" | grep -cP '^\s*(\d+\.\s|\- \[[ xX]\]\s)' 2>/dev/null || true)
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
    error_return 12 "notes-parse: file not found"
  fi

  # Check section exists before counting
  if ! grep -q '## Readiness Critique' "$notes" 2>/dev/null; then
    return 2
  fi

  local count
  count=$(sed -n '/## Readiness Critique/,/^## /p' "$notes" 2>/dev/null |
    grep -c '\[WARNING\]' || true)
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
    error_return 12 "notes-parse: file not found"
  fi

  # Check section exists before counting
  if ! grep -q '## Readiness Critique' "$notes" 2>/dev/null; then
    return 2
  fi

  local count
  count=$(sed -n '/## Readiness Critique/,/^## /p' "$notes" 2>/dev/null |
    grep -c '\[BLOCKER\]' || true)
  echo "${count//[^0-9]/}"
  return 0
}

# resolve_test_user_catalog [tickets_root]
# Resolves the path to test-users.json. NOT bundled with the plugin — must be
# created per-project. Copy config/test-users.example.json and populate with
# real credentials in your TICKETS_ROOT or installed plugin config dir.
# Priority: $TICKETS_ROOT/test-users.json → $CLAUDE_PLUGIN_ROOT/config/ → ~/.claude/skills/config/
# Emits absolute path or empty string if no catalog found (non-fatal).
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
  # test-users.json is not committed to the repo — this path resolves only for
  # local dev copies where the file was placed manually.
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  if [ -f "$script_dir/../config/test-users.json" ]; then
    echo "$script_dir/../config/test-users.json"
    return 0
  fi

  return 1
}

# get_ticket_type <ticket-dir>
# Detects bug vs. feature from context.md labels.
# Emits "bug", "feature", or "unknown".
# Exit codes: 0 = found, 1 = file unreadable
get_ticket_type() {
  local ticket_dir="$1"
  local ctx="$ticket_dir/context.md"

  if [ ! -f "$ctx" ]; then
    error_return 12 "notes-parse: file not found"
  fi

  # Check for bug label
  if grep -qiP '\*\*Labels?:?\*\*[^*]*bug' "$ctx" 2>/dev/null; then
    echo "bug"
    return 0
  fi

  # Check for feature/enhancement label
  if grep -qiP '\*\*Labels?:?\*\*[^*]*(feature|enhancement)' "$ctx" 2>/dev/null; then
    echo "feature"
    return 0
  fi

  # Check description for bug indicators (no label but reads like a bug)
  if grep -qiP '(bug|defect|broken|not working|error|crash|regression)' "$ctx" 2>/dev/null; then
    # Weak signal — only use if no feature indicators present
    if ! grep -qiP '(feature|enhancement|new |add |implement|build|create)' "$ctx" 2>/dev/null; then
      echo "bug"
      return 0
    fi
  fi

  echo "feature"
  return 0
}

# get_has_repro_steps <ticket-dir>
# Detects whether the ticket has reproduction steps for bug verification.
# Checks context.md for numbered browser-action steps or a repro section heading.
# Emits "true" or "false".
# Exit codes: 0 = checked, 1 = file unreadable
get_has_repro_steps() {
  local ticket_dir="$1"
  local ctx="$ticket_dir/context.md"

  if [ ! -f "$ctx" ]; then
    error_return 12 "notes-parse: file not found"
  fi

  # Pattern 1: "Steps to reproduce" or "Reproduction" heading
  if grep -qiP '(steps to repro|reproduc|how to repro|reproduction steps|to reproduce)' "$ctx" 2>/dev/null; then
    echo "true"
    return 0
  fi

  # Pattern 2: At least 2 sequential numbered lines with browser action verbs
  local numbered_count
  numbered_count=$(grep -ciP '^\s*\d+[\.\)]\s+(Go to|Navigate|Click|Open|Log in|Select|Type|Enter|Press|Choose|Check|Verify|See|Observe|Confirm)' "$ctx" 2>/dev/null || true)
  if [ "${numbered_count//[^0-9]/}" -ge 2 ] 2>/dev/null; then
    echo "true"
    return 0
  fi

  # Pattern 3: Checkbox repro steps with action verbs
  local checkbox_count
  checkbox_count=$(grep -ciP '^\s*- \[[ xX]\]\s*(Go to|Navigate|Click|Open|Log in|Select|Type|Enter)' "$ctx" 2>/dev/null || true)
  if [ "${checkbox_count//[^0-9]/}" -ge 2 ] 2>/dev/null; then
    echo "true"
    return 0
  fi

  echo "false"
  return 0
}

# get_critique_has_finding <ticket-dir> <pattern>
# Checks if the ## Readiness Critique section contains a finding matching pattern.
# Used for cross-validation: verify the plan addresses gaps the critique flagged.
# Exit codes: 0 = found, 1 = not found / file missing / section absent
get_critique_has_finding() {
  local ticket_dir="$1"
  local pattern="$2"
  local notes="$ticket_dir/notes.md"

  if [ ! -f "$notes" ]; then
    error_return 12 "notes-parse: file not found"
  fi

  if ! grep -q '## Readiness Critique' "$notes" 2>/dev/null; then
    error_return 12 "notes-parse: file not found"
  fi

  sed -n '/## Readiness Critique/,/^## /p' "$notes" 2>/dev/null | grep -q "$pattern" 2>/dev/null
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
    error_return 12 "notes-parse: file not found"
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
    error_return 12 "notes-parse: file not found"
  fi

  jq -c --arg env "$env" '[.[] | select(.environments[]? == $env)]' "$catalog_path" 2>/dev/null || echo "[]"
}
