#!/usr/bin/env bash
# audit-ac-testability.sh — Deterministic acceptance criteria testability check.
# Detects vague/unverifiable language in acceptance criteria using keyword patterns.
# Replaces LLM-driven Check 2 ("Untestable acceptance criteria") for obvious cases;
# LLM handles borderline cases that pass the deterministic filter.
#
# Input: acceptance criteria text (stdin or $1)
#
# Output (sourceable):
#   VAGUE_AC_COUNT=<n>           — number of ACs with vague language
#   VAGUE_ACS="ac1|ac2|..."      — pipe-delimited list of vague ACs
#   ALL_CLEAR=true|false          — true if no vague patterns found
#
# Exit: 0 if all clear, 1 if vague ACs found
#
# Usage:
#   source audit-ac-testability.sh "$ac_text"
#   if [ "$ALL_CLEAR" != "true" ]; then ...

set -eo pipefail

audit_ac_testability() {
  local text="${1:-$(cat)}"

  VAGUE_AC_COUNT=0
  VAGUE_ACS=""
  ALL_CLEAR="true"

  if [ -z "$text" ]; then
    echo "VAGUE_AC_COUNT=0"
    echo 'VAGUE_ACS=""'
    echo "ALL_CLEAR=true"
    return 0
  fi

  # ── Vague language patterns ──────────────────────────────────────────────
  # These patterns indicate subjective/unverifiable outcomes.
  # Each is a regex alternation applied per-AC-line.
  local vague_patterns
  vague_patterns=(
    'should work'
    'should be (fixed|improved|better|good|fine|ok|okay)'
    'works (correctly|as expected|properly)'
    'looks? (better|good|nice|correct|right)'
    'is (fixed|improved|better|working)'
    'no (errors|issues|problems)'
    'everything (works|is|looks)'
    'seems (to be|fine|ok|okay)'
    'as expected$'
    'properly$'
    'correctly$'
  )

  # ── Split text into individual AC lines ──────────────────────────────────
  # ACs are typically bullet points: "- ..." or "* ..." or "1. ..." or "AC: ..."
  local ac_lines
  ac_lines=$(echo "$text" | grep -E '^\s*[-*]|^\s*\d+[.)]|^\s*AC[:]' 2>/dev/null || echo "")

  if [ -z "$ac_lines" ]; then
    # No bullet-separated ACs — treat the whole text as one AC
    ac_lines="$text"
  fi

  # ── Check each AC line against vague patterns ────────────────────────────
  local lower_line
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    lower_line=$(echo "$line" | tr '[:upper:]' '[:lower:]')

    local is_vague=false
    for pat in "${vague_patterns[@]}"; do
      if echo "$lower_line" | grep -qE "$pat" 2>/dev/null; then
        is_vague=true
        break
      fi
    done

    if $is_vague; then
      VAGUE_AC_COUNT=$((VAGUE_AC_COUNT + 1))
      # Truncate long lines for the output list
      local truncated
      truncated=$(echo "$line" | xargs | cut -c1-80)
      if [ -z "$VAGUE_ACS" ]; then
        VAGUE_ACS="$truncated"
      else
        VAGUE_ACS="${VAGUE_ACS}|${truncated}"
      fi
      ALL_CLEAR="false"
    fi
  done <<< "$ac_lines"

  echo "VAGUE_AC_COUNT=$VAGUE_AC_COUNT"
  echo "VAGUE_ACS=\"$VAGUE_ACS\""
  echo "ALL_CLEAR=$ALL_CLEAR"

  if [ "$ALL_CLEAR" = "true" ]; then
    return 0
  else
    return 1
  fi
}

# Allow sourcing or direct execution
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  audit_ac_testability "$@"
fi
