#!/usr/bin/env bash
# audit-repro-check.sh — Deterministic reproduction steps detection for ticket-audit.
# Checks whether a bug ticket's description contains numbered step-by-step
# reproduction instructions. Replaces LLM-driven Check 5 ("Bug without repro steps").
#
# Input:
#   $1: ticket text (description + acceptance criteria)
#   $2: label CSV (e.g., "bug,frontend") — checks is_bug first
#
# Output (sourceable):
#   IS_BUG=true|false
#   HAS_REPRO=true|false
#   REPRO_COUNT=<n>              — number of numbered steps found
#   REPRO_FOUND_PATTERN="1...2..." — the matching pattern type
#
# Exit: 0 if bug with repro, 1 if bug without repro, 2 if not a bug ticket
#
# Usage:
#   source audit-repro-check.sh "$ticket_text" "$labels"
#   if [ "$IS_BUG" = "true" ] && [ "$HAS_REPRO" != "true" ]; then
#     echo "WARNING: Bug without repro steps"
#   fi

set -eo pipefail

audit_repro_check() {
  local text="${1:-}"
  local labels="${2:-}"

  IS_BUG="false"
  HAS_REPRO="false"
  REPRO_COUNT=0
  REPRO_FOUND_PATTERN=""

  # ── Guard: empty input ──────────────────────────────────────────────────
  if [ -z "$text" ] && [ -z "$labels" ]; then
    echo "IS_BUG=false"
    echo "HAS_REPRO=false"
    echo "REPRO_COUNT=0"
    echo "REPRO_FOUND_PATTERN=\"\""
    return 2
  fi

  # ── Check if this is a bug ticket ────────────────────────────────────────
  if [ -n "$labels" ]; then
    if echo "$labels" | grep -qi 'bug' 2>/dev/null; then
      IS_BUG="true"
    fi
  fi

  # Also check text for bug indicators
  if [ "$IS_BUG" != "true" ] && [ -n "$text" ]; then
    if echo "$text" | grep -qiE '(^|[^a-z])(bug|defect|issue|error|crash|broken|not working)($|[^a-z])' 2>/dev/null; then
      IS_BUG="true"
    fi
  fi

  if [ "$IS_BUG" != "true" ]; then
    echo "IS_BUG=false"
    echo "HAS_REPRO=false"
    echo "REPRO_COUNT=0"
    echo "REPRO_FOUND_PATTERN=\"\""
    return 2
  fi

  # ── Pattern 1: Numbered steps like "1. Go to..." "2. Click..." ──────────
  local numbered_count
  numbered_count=$(echo "$text" | grep -cE '^\s*\d+[.)]\s+' 2>/dev/null || echo 0)

  # ── Pattern 2: "Steps to reproduce" section with bullets ─────────────────
  local has_steps_header
  has_steps_header=$(echo "$text" | grep -ciE 'steps to reproduce|repro steps|reproduction steps|how to reproduce' 2>/dev/null || echo 0)

  # ── Pattern 3: Sequential action words in bullets ────────────────────────
  # "Go to X", "Click Y", "Navigate to Z", "Open W"
  local action_step_count
  action_step_count=$(echo "$text" | grep -cPiE '^\s*[-*]\s*(go to|navigate to|click|open|select|type|enter|press|choose|submit|login|log in|visit|browse to|fill|check|verify|confirm)' 2>/dev/null || echo 0)

  # ── Determine if repro steps exist ───────────────────────────────────────
  # Threshold: 2+ numbered steps, OR steps header + at least 1 action bullet
  if [ "$numbered_count" -ge 2 ] 2>/dev/null; then
    HAS_REPRO="true"
    REPRO_COUNT="$numbered_count"
    REPRO_FOUND_PATTERN="numbered:${numbered_count}_steps"
  elif [ "$has_steps_header" -ge 1 ] 2>/dev/null && [ "$action_step_count" -ge 1 ] 2>/dev/null; then
    HAS_REPRO="true"
    REPRO_COUNT="$action_step_count"
    REPRO_FOUND_PATTERN="section_header:${action_step_count}_actions"
  elif [ "$action_step_count" -ge 2 ] 2>/dev/null; then
    HAS_REPRO="true"
    REPRO_COUNT="$action_step_count"
    REPRO_FOUND_PATTERN="action_bullets:${action_step_count}_steps"
  fi

  echo "IS_BUG=$IS_BUG"
  echo "HAS_REPRO=$HAS_REPRO"
  echo "REPRO_COUNT=$REPRO_COUNT"
  echo "REPRO_FOUND_PATTERN=\"$REPRO_FOUND_PATTERN\""

  if [ "$HAS_REPRO" = "true" ]; then
    return 0
  else
    return 1
  fi
}

# Allow sourcing or direct execution
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  audit_repro_check "$@"
fi
