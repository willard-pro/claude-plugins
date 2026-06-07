#!/usr/bin/env bash
# audit-scope-check.sh — Deterministic scope identification for ticket-audit.
# Checks whether a ticket's title/description references any known service or
# component from the wiki service vocabulary or CLAUDE.md codebase map.
# Replaces LLM-driven Check 4 ("Scope identifiable").
#
# Input:
#   $1: ticket text (title + description + acceptance criteria)
#   $2: wiki services CSV (e.g., "attorney-service,case-manager,notification-service")
#   $3: additional service patterns (optional, from CLAUDE.md codebase map, space-separated)
#
# Output (sourceable):
#   SCOPE_FOUND=true|false
#   MATCHED_SERVICES="svc1 svc2 ..."
#   MATCHED_PATTERNS="pattern1 pattern2 ..."
#
# Exit: 0 if scope found, 1 if not found
#
# Usage:
#   source audit-scope-check.sh "$ticket_text" "$wiki_csv" "$extra_patterns"
#   if [ "$SCOPE_FOUND" = "true" ]; then ...

set -eo pipefail

audit_scope_check() {
  local text="${1:-}"
  local wiki_csv="${2:-}"
  local extra_patterns="${3:-}"

  SCOPE_FOUND="false"
  MATCHED_SERVICES=""
  MATCHED_PATTERNS=""

  if [ -z "$text" ]; then
    echo "audit-scope-check: no ticket text provided" >&2
    return 0
  fi

  # Lowercase the text for case-insensitive matching
  local lower_text
  lower_text=$(echo "$text" | tr '[:upper:]' '[:lower:]')

  # ── Check wiki services ──────────────────────────────────────────────────
  if [ -n "$wiki_csv" ]; then
    local IFS=','
    for svc in $wiki_csv; do
      svc=$(echo "$svc" | xargs | tr '[:upper:]' '[:lower:]') # trim + lowercase
      [ -z "$svc" ] && continue

      # Match service name (with hyphen/underscore variants)
      local svc_pattern
      svc_pattern=$(echo "$svc" | sed 's/[-_]/[_-]/g')
      if echo "$lower_text" | grep -qE "(^|[^a-z])${svc_pattern}($|[^a-z])" 2>/dev/null; then
        MATCHED_SERVICES="${MATCHED_SERVICES}${svc} "
        SCOPE_FOUND="true"
      fi
    done
    MATCHED_SERVICES=$(echo "$MATCHED_SERVICES" | xargs)
  fi

  # ── Check extra patterns (from CLAUDE.md codebase map) ───────────────────
  if [ -n "$extra_patterns" ]; then
    for pattern in $extra_patterns; do
      [ -z "$pattern" ] && continue
      local lower_pattern
      lower_pattern=$(echo "$pattern" | tr '[:upper:]' '[:lower:]')
      if echo "$lower_text" | grep -qi "$lower_pattern" 2>/dev/null; then
        MATCHED_PATTERNS="${MATCHED_PATTERNS}${pattern} "
        SCOPE_FOUND="true"
      fi
    done
    MATCHED_PATTERNS=$(echo "$MATCHED_PATTERNS" | xargs)
  fi

  # ── Check for common scope indicators in text ────────────────────────────
  # Even without wiki, certain keywords suggest identifiable scope
  if [ "$SCOPE_FOUND" != "true" ]; then
    local scope_indicators="api endpoint controller service component module page form modal route handler repository migration job cron"
    for indicator in $scope_indicators; do
      if echo "$lower_text" | grep -qiE "(^|[^a-z])${indicator}($|[^a-z])" 2>/dev/null; then
        MATCHED_PATTERNS="${MATCHED_PATTERNS}${indicator} "
        SCOPE_FOUND="true"
        break # One indicator is enough to show scope is identifiable
      fi
    done
    MATCHED_PATTERNS=$(echo "$MATCHED_PATTERNS" | xargs)
  fi

  echo "SCOPE_FOUND=$SCOPE_FOUND"
  echo "MATCHED_SERVICES=\"$MATCHED_SERVICES\""
  echo "MATCHED_PATTERNS=\"$MATCHED_PATTERNS\""

  if [ "$SCOPE_FOUND" = "true" ]; then
    return 0
  else
    return 1
  fi
}

# Allow sourcing or direct execution
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  audit_scope_check "$@"
fi
