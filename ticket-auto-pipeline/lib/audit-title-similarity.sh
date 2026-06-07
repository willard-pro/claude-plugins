#!/usr/bin/env bash
# audit-title-similarity.sh — Jaccard similarity on two title strings.
# Tokenizes to word sets (lowercase, strip punctuation), computes intersection/union.
# Outputs integer 0–100.
#
# Usage:
#   score=$(bash audit-title-similarity.sh "title one" "title two")
#   echo "$score"

set -eo pipefail

# Tokenize a string: lowercase, strip punctuation, split on whitespace, de-duplicate
_tokenize() {
  echo "$1" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9[:space:]]//g' | tr -s '[:space:]' '\n' | sort -u | grep -v '^$'
}

audit_title_similarity() {
  local title1="$1"
  local title2="$2"

  local set1 set2
  set1=$(_tokenize "$title1")
  set2=$(_tokenize "$title2")

  if [ -z "$set1" ] && [ -z "$set2" ]; then
    echo "100"
    return 0
  fi

  if [ -z "$set1" ] || [ -z "$set2" ]; then
    echo "0"
    return 0
  fi

  # Compute intersection and union sizes
  local intersection union
  intersection=$(comm -12 <(echo "$set1") <(echo "$set2") | wc -l)
  union=$(comm <(echo "$set1") <(echo "$set2") | wc -l)

  if [ "$union" -eq 0 ]; then
    echo "0"
    return 0
  fi

  # Jaccard: intersection / union * 100
  local score
  score=$(awk "BEGIN { printf \"%.0f\", ($intersection / $union) * 100 }")
  echo "$score"
}

# Allow sourcing or direct execution
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  audit_title_similarity "$@"
fi
