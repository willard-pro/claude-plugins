#!/usr/bin/env bash
# audit-test-data-check.sh — Deterministic test data assumption detection.
# Finds phrases in ticket text that assume pre-existing data state without
# describing how to set it up. Replaces LLM-driven Check 3 ("Missing test data
# assumptions") for obvious cases; LLM handles borderline.
#
# Input: ticket text (stdin or $1) — description + acceptance criteria
#
# Output (sourceable):
#   ASSUMPTION_COUNT=<n>
#   ASSUMPTIONS="pattern1|pattern2|..." — pipe-delimited list of found assumptions
#   NEEDS_TEST_DATA=true|false
#
# Exit: 0 if no assumptions found, 1 if assumptions found
#
# Usage:
#   source audit-test-data-check.sh "$ticket_text"
#   if [ "$NEEDS_TEST_DATA" = "true" ]; then ...

set -eo pipefail

audit_test_data_check() {
  local text="${1:-$(cat)}"

  ASSUMPTION_COUNT=0
  ASSUMPTIONS=""
  NEEDS_TEST_DATA="false"

  if [ -z "$text" ]; then
    echo "ASSUMPTION_COUNT=0"
    echo 'ASSUMPTIONS=""'
    echo "NEEDS_TEST_DATA=false"
    return 0
  fi

  local lower_text
  lower_text=$(echo "$text" | tr '[:upper:]' '[:lower:]')

  # ── Assumption patterns ──────────────────────────────────────────────────
  # Each pattern describes text that implies pre-existing data/state.
  # Format: "pattern|label for output"
  local patterns
  patterns=(
    'an existing |assumes existing entity'
    'already existing |assumes pre-existing data'
    'the existing |assumes existing entity'
    'when there is already |assumes pre-existing state'
    'after creating |assumes prior setup step'
    'the record created in |assumes data from other ticket'
    'use the .* from |assumes data from other source'
    'with the same .* as |assumes matching data exists'
    'in state |assumes specific state precondition'
    'the handover |assumes handover exists'
    'a case in |assumes case data exists'
    'login as |assumes test user exists'
    'the user has |assumes user data exists'
    'the account (has|with) |assumes account configuration'
    'pre-existing |assumes pre-existing data'
    'setup (before|prior) |assumes setup not described'
  )

  local found_assumptions=""

  for entry in "${patterns[@]}"; do
    local pattern="${entry%%|*}"
    local label="${entry##*|}"

    if echo "$lower_text" | grep -qE "$pattern" 2>/dev/null; then
      ASSUMPTION_COUNT=$((ASSUMPTION_COUNT + 1))
      if [ -z "$found_assumptions" ]; then
        found_assumptions="$label"
      else
        found_assumptions="${found_assumptions}|${label}"
      fi
      NEEDS_TEST_DATA="true"
    fi
  done

  ASSUMPTIONS="$found_assumptions"

  # ── Check if setup is described for found assumptions ────────────────────
  # If the text ALSO describes how to set up the data, downgrade the finding.
  local has_setup_description
  has_setup_description=$(echo "$lower_text" | grep -ciE \
    '(how to (create|set up|configure)|to create this|steps? to (create|prepare|set up)|setup instructions|test data[:.])' \
    2>/dev/null || echo 0)

  if [ "$has_setup_description" -ge 1 ] 2>/dev/null; then
    # Setup IS described — assumptions are addressed
    NEEDS_TEST_DATA="false"
    echo "audit-test-data-check: assumptions found but setup is described — clearing flag" >&2
  fi

  echo "ASSUMPTION_COUNT=$ASSUMPTION_COUNT"
  echo "ASSUMPTIONS=\"$ASSUMPTIONS\""
  echo "NEEDS_TEST_DATA=$NEEDS_TEST_DATA"

  if [ "$NEEDS_TEST_DATA" = "true" ]; then
    return 1
  else
    return 0
  fi
}

# Allow sourcing or direct execution
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  audit_test_data_check "$@"
fi
