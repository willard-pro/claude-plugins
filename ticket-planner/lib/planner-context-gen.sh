#!/usr/bin/env bash
# planner-context-gen.sh — Deterministic Planner Context block generator.
#
# Generates the `## Planner Context` markdown block that planned-ticket-check.sh
# validates. Takes structured JSON input; outputs formatted markdown.
#
# The generator is pure bash — no LLM. The planner agent supplies the values;
# this script ensures correct format. Generate against the validator, not the
# schema document.
#
# Usage:
#   planner_context_generate <context_json>
#     context_json: JSON with all 10 required fields.
#     Outputs: formatted `## Planner Context` markdown block.
#     Returns: 0 on success, 1 if required fields missing.
#
# Sourceable library — no set -euo pipefail.

# Required fields per Schema-Version 1
PLANNER_CONTEXT_FIELDS=(
  "Schema-Version"
  "Initiative"
  "Epic"
  "Confidence"
  "Strategy"
  "Decision"
  "Affected Services"
  "Target Symbols"
  "Pre-approved"
  "Generated"
  "Regenerate"
)

# ── Public API ─────────────────────────────────────────────────────────────────

# Generate a Planner Context block from JSON input.
# Usage: planner_context_generate <context_json>
planner_context_generate() {
  local context_json="$1"

  # Validate JSON parseable
  if ! echo "$context_json" | jq -e . >/dev/null 2>&1; then
    echo "planner-context-gen: invalid JSON input" >&2
    return 1
  fi

  # Validate all required fields present
  local missing
  missing=$(echo "$context_json" | jq -r '
    $required[] as $field |
    if has($field) | not then $field else empty end
  ' --argjson required "$(printf '%s\n' "${PLANNER_CONTEXT_FIELDS[@]}" | jq -R . | jq -s .)" 2>/dev/null)

  if [ -n "$missing" ]; then
    echo "planner-context-gen: missing required fields: $missing" >&2
    return 1
  fi

  # Extract fields
  local schema_version initiative epic confidence strategy decision
  local affected_services target_symbols pre_approved generated regenerate

  schema_version=$(echo "$context_json" | jq -r '.["Schema-Version"]')
  initiative=$(echo "$context_json" | jq -r '.Initiative')
  epic=$(echo "$context_json" | jq -r '.Epic')
  confidence=$(echo "$context_json" | jq -r '.Confidence')
  strategy=$(echo "$context_json" | jq -r '.Strategy')
  decision=$(echo "$context_json" | jq -r '.Decision')
  affected_services=$(echo "$context_json" | jq -r '.["Affected Services"]')
  target_symbols=$(echo "$context_json" | jq -r '.["Target Symbols"]')
  pre_approved=$(echo "$context_json" | jq -r '.["Pre-approved"]')
  generated=$(echo "$context_json" | jq -r '.Generated')
  regenerate=$(echo "$context_json" | jq -r '.Regenerate')

  # Validate Strategy enum
  case "$strategy" in
  Conservative | Balanced | Innovative) ;;
  *)
    echo "planner-context-gen: invalid Strategy '$strategy' (must be Conservative|Balanced|Innovative)" >&2
    return 1
    ;;
  esac

  # Validate Pre-approved is boolean
  case "$pre_approved" in
  true | false) ;;
  *)
    echo "planner-context-gen: invalid Pre-approved '$pre_approved' (must be true|false)" >&2
    return 1
    ;;
  esac

  # Validate Regenerate is boolean
  case "$regenerate" in
  true | false) ;;
  *)
    echo "planner-context-gen: invalid Regenerate '$regenerate' (must be true|false)" >&2
    return 1
    ;;
  esac

  # Generate timestamp if not provided
  if [ -z "$generated" ] || [ "$generated" = "null" ]; then
    generated=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  fi

  # Emit the formatted block
  cat <<PLANNER_CONTEXT
## Planner Context
**Schema-Version:** ${schema_version}
**Initiative:** ${initiative}
**Epic:** ${epic}
**Confidence:** ${confidence}
**Strategy:** ${strategy}
**Decision:** ${decision}
**Affected Services:** ${affected_services}
**Target Symbols:** ${target_symbols}
**Pre-approved:** ${pre_approved}
**Generated:** ${generated}
**Regenerate:** ${regenerate}
PLANNER_CONTEXT

  return 0
}

# ── Confidence helpers ─────────────────────────────────────────────────────────

# Derive per-ticket confidence from concrete generation signals.
# Never a uniform constant — must vary across tickets with differing evidence.
#
# Input: JSON with signal fields.
#   services_identified: count of affected services with code paths traced (0-N)
#   symbols_resolved: count of target symbols with confirmed file:line (0-N)
#   prior_art_found: whether similar implementation patterns were found (bool)
#   complexity: "simple" | "moderate" | "complex"
#   exploration_depth: "quick-scan" | "standard" | "deep"
#
# Output: confidence score 0.0–1.0.
#
# Usage: planner_confidence_derive <signals_json>
planner_confidence_derive() {
  local signals_json="$1"

  local services_identified symbols_resolved prior_art_found complexity exploration_depth
  services_identified=$(echo "$signals_json" | jq -r '.services_identified // 0')
  symbols_resolved=$(echo "$signals_json" | jq -r '.symbols_resolved // 0')
  prior_art_found=$(echo "$signals_json" | jq -r '.prior_art_found // false')
  complexity=$(echo "$signals_json" | jq -r '.complexity // "moderate"')
  exploration_depth=$(echo "$signals_json" | jq -r '.exploration_depth // "standard"')

  # Base confidence starts at 0.5 (neutral)
  local score=50

  # Services identified: +5 per service, max +20
  local svc_bonus=$((services_identified * 5))
  [ "$svc_bonus" -gt 20 ] && svc_bonus=20
  score=$((score + svc_bonus))

  # Symbols resolved: +3 per symbol, max +15
  local sym_bonus=$((symbols_resolved * 3))
  [ "$sym_bonus" -gt 15 ] && sym_bonus=15
  score=$((score + sym_bonus))

  # Prior art: +10 if found
  if [ "$prior_art_found" = "true" ]; then
    score=$((score + 10))
  fi

  # Exploration depth bonus
  case "$exploration_depth" in
  deep) score=$((score + 10)) ;;
  standard) score=$((score + 5)) ;;
  *) ;; # quick-scan: no bonus
  esac

  # Complexity penalty
  case "$complexity" in
  complex) score=$((score - 15)) ;;
  moderate) ;; # no penalty
  simple) score=$((score + 5)) ;;
  esac

  # Clamp to 0-100
  [ "$score" -lt 5 ] && score=5
  [ "$score" -gt 95 ] && score=95

  # Format as 0.XX
  if [ "$score" -ge 100 ]; then
    echo "0.99"
  else
    printf "0.%02d" "$score"
  fi
}
