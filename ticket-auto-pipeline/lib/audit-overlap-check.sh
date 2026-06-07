#!/usr/bin/env bash
# audit-overlap-check.sh — Deterministic AC overlap detection for cross-ticket analysis.
# Computes Jaccard similarity on acceptance criteria text between two tickets.
# Used as a pre-filter: high overlap → flag for LLM confirmation; low overlap → skip.
# Replaces LLM-driven overlap detection for clear cases.
#
# Input:
#   $1: acceptance criteria text from ticket A
#   $2: acceptance criteria text from ticket B
#
# Output (sourceable):
#   OVERLAP_SCORE=<n>          — Jaccard similarity 0–100
#   OVERLAP_THRESHOLD=above|below  — above means ≥50%, needs LLM confirmation
#   OVERLAP_SHARED_TERMS="..." — top shared terms (for LLM context)
#
# Exit: 0 if above threshold, 1 if below
#
# Usage:
#   source audit-overlap-check.sh "$ac_text_a" "$ac_text_b"
#   if [ "$OVERLAP_THRESHOLD" = "above" ]; then ...

set -eo pipefail

# Tokenize text for Jaccard: lowercase, strip punctuation, split, dedup, filter short words
_tokenize_ac() {
  echo "$1" |
    tr '[:upper:]' '[:lower:]' |
    sed 's/[^a-z0-9[:space:]]/ /g' |
    tr -s '[:space:]' '\n' |
    grep -vE '^(the|a|an|is|are|be|to|of|in|for|on|and|or|it|at|by|as|with|can|has|will)$' |
    grep -vE '^[0-9]+$' |
    grep -vE '^.{1,2}$' |
    sort -u |
    grep -v '^$' || true
}

audit_overlap_check() {
  local ac_a="${1:-}"
  local ac_b="${2:-}"

  OVERLAP_SCORE=0
  OVERLAP_THRESHOLD="below"
  OVERLAP_SHARED_TERMS=""

  if [ -z "$ac_a" ] || [ -z "$ac_b" ]; then
    echo "OVERLAP_SCORE=0"
    echo 'OVERLAP_THRESHOLD="below"'
    echo 'OVERLAP_SHARED_TERMS=""'
    return 1
  fi

  local set_a set_b
  set_a=$(_tokenize_ac "$ac_a")
  set_b=$(_tokenize_ac "$ac_b")

  if [ -z "$set_a" ] && [ -z "$set_b" ]; then
    echo "OVERLAP_SCORE=100"
    echo 'OVERLAP_THRESHOLD="above"'
    echo 'OVERLAP_SHARED_TERMS=""'
    return 0
  fi

  if [ -z "$set_a" ] || [ -z "$set_b" ]; then
    echo "OVERLAP_SCORE=0"
    echo 'OVERLAP_THRESHOLD="below"'
    echo 'OVERLAP_SHARED_TERMS=""'
    return 1
  fi

  # Compute intersection and union
  local intersection union
  intersection=$(comm -12 <(echo "$set_a") <(echo "$set_b") | wc -l)
  union=$(comm <(echo "$set_a") <(echo "$set_b") | wc -l)

  if [ "$union" -eq 0 ]; then
    echo "OVERLAP_SCORE=0"
    echo 'OVERLAP_THRESHOLD="below"'
    echo 'OVERLAP_SHARED_TERMS=""'
    return 1
  fi

  # Jaccard: intersection / union * 100
  OVERLAP_SCORE=$(awk "BEGIN { printf \"%.0f\", ($intersection / $union) * 100 }")

  # Get top shared terms for LLM context
  OVERLAP_SHARED_TERMS=$(comm -12 <(echo "$set_a") <(echo "$set_b") | head -10 | tr '\n' ' ' | xargs)

  # Threshold: ≥50% overlap → above threshold, needs LLM confirmation
  if [ "$OVERLAP_SCORE" -ge 50 ] 2>/dev/null; then
    OVERLAP_THRESHOLD="above"
  fi

  echo "OVERLAP_SCORE=$OVERLAP_SCORE"
  echo "OVERLAP_THRESHOLD=\"$OVERLAP_THRESHOLD\""
  echo "OVERLAP_SHARED_TERMS=\"$OVERLAP_SHARED_TERMS\""

  if [ "$OVERLAP_THRESHOLD" = "above" ]; then
    return 0
  else
    return 1
  fi
}

# Allow sourcing or direct execution
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  audit_overlap_check "$@"
fi
