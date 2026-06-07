#!/usr/bin/env bash
# audit-size-check.sh — Deterministic split signal detection for ticket-audit.
# Accepts ticket text on stdin or via args. Outputs SIGNAL_COUNT, SIGNALS,
# and templated SPLIT_SUGGESTION when threshold is met. No LLM. Pure bash.
#
# Signals checked (ticket flagged as split candidate when 2+ fire):
#   1. AC count > 5 (grep -c on bullet/numbered lines)
#   2. Word count > 400 (wc -w on substantive description)
#   3. References 3+ wiki services (requires WIKI_SERVICES env var with JSON array)
#
# Output format (sourceable):
#   SIGNAL_COUNT=<n>
#   SIGNALS="ac_count word_count wiki_service_count"
#   SPLIT_SUGGESTION="<templated suggestion text when 2+ signals>"
#
# Usage:
#   source audit-size-check.sh "ticket text here" ["wiki_service1,wiki_service2,..."]
#   echo "$SIGNAL_COUNT $SIGNALS"

set -eo pipefail

audit_size_check() {
  local text="${1:-$(cat)}"
  local wiki_services_csv="${2:-}"

  local signal_count=0
  local signals=""

  # Signal 1: AC count > 5
  # Count bullet points and numbered list items in the text
  local ac_count
  ac_count=$(echo "$text" | grep -cE '^\s*[-*+]\s|^\s*\d+[.)]\s' 2>/dev/null || echo 0)
  if [ "$ac_count" -gt 5 ] 2>/dev/null; then
    signal_count=$((signal_count + 1))
    signals="${signals}ac_count "
  fi

  # Signal 2: Word count > 400
  # Strip markdown formatting and count substantive words
  local stripped word_count
  stripped=$(echo "$text" | sed 's/[#*_`~>|\[\]()]//g' | tr -s '[:space:]' ' ')
  word_count=$(echo "$stripped" | wc -w)
  if [ "$word_count" -gt 400 ] 2>/dev/null; then
    signal_count=$((signal_count + 1))
    signals="${signals}word_count "
  fi

  # Signal 3: References 3+ wiki services
  if [ -n "$wiki_services_csv" ]; then
    local service_count=0
    local IFS=','
    for svc in $wiki_services_csv; do
      svc=$(echo "$svc" | xargs)  # trim whitespace
      [ -z "$svc" ] && continue
      if echo "$text" | grep -qi "$svc" 2>/dev/null; then
        service_count=$((service_count + 1))
      fi
    done
    if [ "$service_count" -ge 3 ] 2>/dev/null; then
      signal_count=$((signal_count + 1))
      signals="${signals}wiki_service_count "
    fi
  fi

  # Trim trailing space
  signals=$(echo "$signals" | xargs)

  # ── Generate templated split suggestion ──────────────────────────────────
  SPLIT_SUGGESTION=""
  if [ "$signal_count" -ge 2 ] 2>/dev/null; then
    local parts=""
    # Build suggestion based on which signals fired
    if echo "$signals" | grep -q "ac_count"; then
      parts="${parts}${ac_count} acceptance criteria"
    fi
    if echo "$signals" | grep -q "word_count"; then
      parts="${parts}${parts:+, }large scope (${word_count}+ words)"
    fi
    if echo "$signals" | grep -q "wiki_service_count"; then
      parts="${parts}${parts:+, }touches ${service_count}+ services"
    fi

    SPLIT_SUGGESTION="Split candidate: ticket spans ${parts}. Suggested split by: "
    if echo "$signals" | grep -q "wiki_service_count"; then
      SPLIT_SUGGESTION="${SPLIT_SUGGESTION}service boundary (one ticket per service)"
    elif echo "$signals" | grep -q "ac_count" && echo "$signals" | grep -q "word_count"; then
      SPLIT_SUGGESTION="${SPLIT_SUGGESTION}logical feature boundary (group 2-3 related ACs per ticket)"
    else
      SPLIT_SUGGESTION="${SPLIT_SUGGESTION}user story boundary (one clear outcome per ticket)"
    fi
  fi

  # Set globals for direct variable access (consistent with other audit-*.sh scripts)
  # shellcheck disable=SC2034  # variables consumed externally by callers
  SIGNAL_COUNT=$signal_count
  SIGNALS="$signals"

  # Output as sourceable vars (for eval-based consumers)
  echo "SIGNAL_COUNT=$signal_count"
  echo "SIGNALS=\"$signals\""
  echo "SPLIT_SUGGESTION=\"$SPLIT_SUGGESTION\""
}

# Allow sourcing or direct execution
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  audit_size_check "$@"
fi
