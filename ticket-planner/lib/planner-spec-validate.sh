#!/usr/bin/env bash
# planner-spec-validate.sh — Deterministic spec file validation gate.
#
# Called between Specify and Epic Gen — the last checkpoint before irreversible
# Linear API calls. Validates that every spec file has required sections and
# parseable Signals JSON. Structural only — does NOT validate semantic correctness
# (that's what Review phase is for).
#
# Usage:
#   planner_spec_validate_all <initiative_id>
#     Returns: 0 if all spec files pass, 1 if any fail (reports each failure).
#
#   planner_spec_validate_one <spec_file>
#     Returns: 0 if spec passes, 1 if it fails.
#
# Sourceable library — no set -euo pipefail.

# ── Required sections per spec ─────────────────────────────────────────────────

PLANNER_SPEC_REQUIRED_SECTIONS=(
  "## Title"
  "## Description"
  "## Labels"
  "## Signals"
)

# ── Validation ─────────────────────────────────────────────────────────────────

# Validate a single spec file has all required sections and valid Signals JSON.
# Usage: planner_spec_validate_one <spec_file>
# Returns: 0 if valid, 1 if invalid (reports each missing section to stderr).
planner_spec_validate_one() {
  local spec_file="$1"
  local failures=0

  if [ ! -f "$spec_file" ]; then
    echo "planner-spec-validate: spec file not found: $spec_file" >&2
    return 1
  fi

  local content
  content=$(cat "$spec_file")

  # 1. Check required sections
  for section in "${PLANNER_SPEC_REQUIRED_SECTIONS[@]}"; do
    if ! echo "$content" | grep -qF "$section" 2>/dev/null; then
      echo "planner-spec-validate: $spec_file — missing section: $section" >&2
      failures=$((failures + 1))
    fi
  done

  # 2. Extract and validate Signals JSON block
  local signals_json
  signals_json=$(echo "$content" | sed -n '/```json/,/```/p' | sed '1d;$d' 2>/dev/null)

  if [ -z "$signals_json" ]; then
    echo "planner-spec-validate: $spec_file — missing or empty Signals JSON block" >&2
    failures=$((failures + 1))
  elif ! echo "$signals_json" | jq -e . >/dev/null 2>&1; then
    echo "planner-spec-validate: $spec_file — Signals JSON is not parseable" >&2
    failures=$((failures + 1))
  else
    # Validate required signal fields
    local missing_signal
    missing_signal=$(echo "$signals_json" | jq -r '
      ["services_identified","symbols_resolved","prior_art_found","complexity","exploration_depth"][] as $field |
      if has($field) | not then $field else empty end
    ' 2>/dev/null)
    if [ -n "$missing_signal" ]; then
      echo "planner-spec-validate: $spec_file — Signals JSON missing fields: $missing_signal" >&2
      failures=$((failures + 1))
    fi
  fi

  return $((failures > 0 ? 1 : 0))
}

# Validate all spec files in an initiative's artifacts/specs/ directory.
# Usage: planner_spec_validate_all <initiative_id>
# Returns: 0 if all pass, 1 if any fail.
planner_spec_validate_all() {
  local initiative_id="$1"
  local repos_root="${REPOS_ROOT:-${HOME}/repos}"
  local specs_dir="${repos_root}/.ticket-auto/initiatives/${initiative_id}/artifacts/specs"

  if [ ! -d "$specs_dir" ]; then
    echo "planner-spec-validate: specs directory not found: $specs_dir" >&2
    return 1
  fi

  local total=0 passed=0 failed=0
  local spec_file

  for spec_file in "$specs_dir"/*.md; do
    [ -f "$spec_file" ] || continue
    # Skip INDEX.md
    [ "$(basename "$spec_file")" = "INDEX.md" ] && continue

    total=$((total + 1))
    if planner_spec_validate_one "$spec_file"; then
      passed=$((passed + 1))
    else
      failed=$((failed + 1))
    fi
  done

  echo "planner-spec-validate: $passed passed, $failed failed out of $total spec files"
  return $((failed > 0 ? 1 : 0))
}
