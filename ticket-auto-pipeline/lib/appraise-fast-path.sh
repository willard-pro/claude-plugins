#!/usr/bin/env bash
# appraise-fast-path.sh — deterministic fast-path eligibility and Planner Context
# extraction for the ticket-appraise skill.
#
# Sourceable bash library. Does NOT set -euo pipefail (caller controls error
# handling). Phase 2 of the ticket-planner enrichment: acts on the Planner
# Context block that Phase 1 (gate-check.sh) validated passively.
#
# Exit codes from check_fast_path_eligible:
#   0 — fast-path eligible (planned label + valid Planner Context + confidence ok)
#   1 — not eligible (no planned label, no block, or malformed)
#   2 — low confidence, not pre-approved (requires human review, no fast-path)
#
# Dependencies: planned-ticket-check.sh (for field extraction), jq
#
# Usage:
#   source lib/appraise-fast-path.sh
#   source lib/planned-ticket-check.sh
#   check_fast_path_eligible "CRE-123"              # fetches ticket via API
#   check_fast_path_eligible "CRE-123" "$desc" "true"  # inline for testing

# ── Configuration ───────────────────────────────────────────────────────────

FAST_PATH_CONFIDENCE_THRESHOLD="${FAST_PATH_CONFIDENCE_THRESHOLD:-0.85}"
# Pre-approved tickets skip the confidence threshold — the planner declared them
# ready. Non-pre-approved tickets must meet the confidence threshold.

# ── Public API ──────────────────────────────────────────────────────────────

# unset_fast_path_vars — cleanup globals before (re-)invocation.
# Prevents stale values from a prior ticket's fast-path check leaking into a
# subsequent invocation within the same bash process.
unset_fast_path_vars() {
  unset FAST_PATH_ELIGIBLE FAST_PATH_REASON FAST_PATH_EXIT_CODE FAST_PATH_BLOCK
  unset FAST_PATH_SCHEMA_VERSION FAST_PATH_INITIATIVE FAST_PATH_EPIC
  unset FAST_PATH_CONFIDENCE FAST_PATH_STRATEGY FAST_PATH_DECISION
  unset FAST_PATH_AFFECTED_SERVICES FAST_PATH_TARGET_SYMBOLS
  unset FAST_PATH_PRE_APPROVED FAST_PATH_GENERATED FAST_PATH_REGENERATE
}

# fast_path_action <eligible> <reason>
# Deterministic action dispatcher. Replaces the LLM-interpreted markdown table
# in SKILL.md Step 1.3b with a bash-level routing decision.
# Outputs: fast_path_active | warn_and_proceed | proceed_normally
fast_path_action() {
  case "$1:$2" in
  true:*) echo "fast_path_active" ;;
  false:malformed_block | false:low_confidence_not_preapproved)
    echo "warn_and_proceed"
    ;;
  false:*) echo "proceed_normally" ;;
  esac
}

# check_fast_path_eligible <ticket-id> [description] [has_planned_label]
# Exit codes:
#   0 — fast-path eligible (planned label + valid Planner Context + confidence ok)
#   1 — not eligible (no planned label, no block, malformed, or api error)
#   2 — confidence gated: either below validation threshold (0.5) + not pre-approved,
#       or below fast-path threshold (0.85). Requires full investigation.
# Sets FAST_PATH_ELIGIBLE (true/false), FAST_PATH_REASON, and FAST_PATH_EXIT_CODE.
# Also extracts all Planner Context fields into FAST_PATH_* variables on success.
check_fast_path_eligible() {
  local ticket_id="$1"
  local description="${2:-}"
  local has_planned_label="${3:-}"

  # Reset globals before every invocation to prevent stale-value leaks
  unset_fast_path_vars
  FAST_PATH_ELIGIBLE="false"
  FAST_PATH_REASON=""
  FAST_PATH_EXIT_CODE=1

  # Fetch if not provided inline (test mode bypass)
  if [ -z "$description" ]; then
    local issue_json
    issue_json=$(get_issue "$ticket_id" 2>/dev/null) || {
      FAST_PATH_REASON="api_error"
      FAST_PATH_EXIT_CODE=1
      return 1
    }
    description=$(echo "$issue_json" | jq -r '.description // ""')
    has_planned_label=$(echo "$issue_json" | jq -r \
      '[.labels.nodes[].name] | index("planned") != null')
  fi

  # Guard: must have planned label
  if [ "$has_planned_label" != "true" ]; then
    FAST_PATH_REASON="not_planned"
    FAST_PATH_EXIT_CODE=1
    return 1
  fi

  # Delegate to planned-ticket-check for block validation
  local check_rc=0
  check_planned_ticket_description "$description" 2>/dev/null || check_rc=$?

  case "$check_rc" in
  0) ;; # valid — continue
  1)
    FAST_PATH_REASON="malformed_block"
    FAST_PATH_EXIT_CODE=1
    return 1
    ;;
  2)
    FAST_PATH_REASON="low_confidence_not_preapproved"
    FAST_PATH_EXIT_CODE=2
    return 2
    ;;
  *)
    FAST_PATH_REASON="unexpected_validation_error"
    FAST_PATH_EXIT_CODE=1
    return 1
    ;;
  esac

  # Extract Planner Context block
  _extract_planner_block "$description"

  # Determine eligibility based on Pre-approved + Confidence
  local pre_approved confidence
  pre_approved=$(_extract_field_from_block "Pre-approved")
  confidence=$(_extract_field_from_block "Confidence")

  # Pre-approved tickets always eligible
  if [ "$pre_approved" = "true" ]; then
    FAST_PATH_ELIGIBLE="true"
    FAST_PATH_REASON="pre_approved"
    FAST_PATH_EXIT_CODE=0
    _extract_all_fields
    return 0
  fi

  # Non-pre-approved: must meet confidence threshold
  if _confidence_at_or_above "$confidence" "$FAST_PATH_CONFIDENCE_THRESHOLD"; then
    FAST_PATH_ELIGIBLE="true"
    FAST_PATH_REASON="confidence_met"
    FAST_PATH_EXIT_CODE=0
    _extract_all_fields
    return 0
  fi

  FAST_PATH_REASON="confidence_below_threshold"
  FAST_PATH_EXIT_CODE=2
  return 2
}

# map_strategy_to_complexity <strategy>
# Maps a Planner Context Strategy value to a complexity score.
# Conservative → simple (minimal change, low risk)
# Balanced → complex (moderate change, standard risk)
# Innovative → complex (significant change, higher risk)
# Emits "simple" or "complex".
map_strategy_to_complexity() {
  local strategy="$1"
  case "$strategy" in
  "Conservative") echo "simple" ;;
  "Balanced" | "Innovative") echo "complex" ;;
  *) echo "complex" ;; # Unknown strategy → err on side of caution
  esac
}

# generate_fast_path_notes <ticket-dir> <issue-id>
# Writes the fast-path appraisal content to notes.md.
# Reads FAST_PATH_* variables set by check_fast_path_eligible.
# Overwrites notes.md with the full appraisal template + planner-derived content.
# Uses printf (not heredoc) to prevent second-pass shell expansion of field values
# that may contain backticks or $() from the Planner Context block.
generate_fast_path_notes() {
  local ticket_dir="$1"
  local issue_id="$2"
  local today
  today=$(date +%Y-%m-%d)

  local notes="$ticket_dir/notes.md"
  local complexity
  complexity=$(map_strategy_to_complexity "${FAST_PATH_STRATEGY:-Balanced}")

  # Build target symbols bullet list
  local target_symbols_bullets
  target_symbols_bullets=$(echo "${FAST_PATH_TARGET_SYMBOLS:-}" | tr ';' '\n' | sed 's/^[[:space:]]*/- /')

  # Build regenerate warning (if applicable)
  local regenerate_warning=""
  if [ "${FAST_PATH_REGENERATE:-false}" = "true" ]; then
    regenerate_warning="- ⚠️ Planner recommends regenerating this ticket's plan — plan may be stale."
  fi

  {
    printf '# Working Notes — %s\n\n' "$issue_id"
    printf '## Status\n'
    printf '**Appraised:** %s\n' "$today"
    printf '**Current status:** (fast-path — planned ticket)\n\n'
    printf '## Complexity\n'
    printf '**Score:** %s\n' "$complexity"
    printf '**Axes fired:** none (fast-path — planner-provided)\n'
    printf '**Reason:** Strategy=%s, Confidence=%s. Planner declared this as `%s` with Pre-approved=%s.\n\n' \
      "${FAST_PATH_STRATEGY:-unknown}" "${FAST_PATH_CONFIDENCE:-unknown}" \
      "${FAST_PATH_STRATEGY:-unknown}" "${FAST_PATH_PRE_APPROVED:-false}"
    printf '## Prior Art\n'
    printf 'No prior art search performed (fast-path — planner-provided context).\n'
    printf '**Planner Decision:** %s\n\n' "${FAST_PATH_DECISION:-none}"
    printf '## Initial Investigation\n'
    printf '**Source:** Planner Context (fast-path — skipped codebase investigation)\n\n'
    printf '**Initiative:** %s\n' "${FAST_PATH_INITIATIVE:-unknown}"
    printf '**Epic:** %s\n' "${FAST_PATH_EPIC:-unknown}"
    printf '**Affected Services:** %s\n' "${FAST_PATH_AFFECTED_SERVICES:-none}"
    printf '**Target Symbols:**\n'
    printf '%s\n' "$target_symbols_bullets"
    printf '\n'
    printf '**Planner Strategy:** %s\n' "${FAST_PATH_STRATEGY:-unknown}"
    printf '**Planner Decision:** %s\n' "${FAST_PATH_DECISION:-none}"
    printf '**Planner Confidence:** %s\n' "${FAST_PATH_CONFIDENCE:-unknown}"
    printf '**Pre-approved:** %s\n' "${FAST_PATH_PRE_APPROVED:-false}"
    printf '**Generated:** %s\n' "${FAST_PATH_GENERATED:-unknown}"
    printf '**Regenerate:** %s\n\n' "${FAST_PATH_REGENERATE:-false}"
    printf '## Open Questions\n\n'
    printf -- '- Verify target symbols against live source (fast-path skips codebase investigation).\n'
    if [ -n "$regenerate_warning" ]; then
      printf '%s\n' "$regenerate_warning"
    fi
    printf '\n## Next Steps\n\n'
    printf -- '- Run /ticket-appraise-exec to create artifacts.\n'
    printf -- '- Confirm target symbols exist at listed paths before implementing.\n\n'
    printf '## Session Log\n\n'
    printf '### %s\n' "$today"
    printf -- '- Fast-path appraisal from Planner Context (reason: %s).\n' "${FAST_PATH_REASON:-unknown}"
    printf -- '- Complexity: %s (from Strategy=%s).\n' "$complexity" "${FAST_PATH_STRATEGY:-unknown}"
    printf -- '- Skipped: complexity sweep, prior-art search, codebase investigation.\n'
    printf -- '- Still required: readiness critique, blast radius analysis.\n'
  } >"$notes"

  return 0
}

# ── Internal helpers ────────────────────────────────────────────────────────

# _extract_planner_block <description>
# Extracts the ## Planner Context block into FAST_PATH_BLOCK.
# Delegates to planned-ticket-check.sh's canonical _extract_planner_context_block
# — the single source of truth for block-delimiter rules.
_extract_planner_block() {
  local description="$1"
  FAST_PATH_BLOCK=$(_extract_planner_context_block "$description")
}

# _extract_field_from_block <field-name>
# Delegates to planned-ticket-check.sh's _extract_field (stdin-based) by piping
# FAST_PATH_BLOCK through it. Avoids duplicating the sed extraction regex.
_extract_field_from_block() {
  local field="$1"
  echo "${FAST_PATH_BLOCK:-}" | _extract_field "$field"
}

# _extract_all_fields — populates all FAST_PATH_* variables from the block
_extract_all_fields() {
  FAST_PATH_SCHEMA_VERSION=$(_extract_field_from_block "Schema-Version")
  FAST_PATH_INITIATIVE=$(_extract_field_from_block "Initiative")
  FAST_PATH_EPIC=$(_extract_field_from_block "Epic")
  FAST_PATH_CONFIDENCE=$(_extract_field_from_block "Confidence")
  FAST_PATH_STRATEGY=$(_extract_field_from_block "Strategy")
  FAST_PATH_DECISION=$(_extract_field_from_block "Decision")
  FAST_PATH_AFFECTED_SERVICES=$(_extract_field_from_block "Affected Services")
  FAST_PATH_TARGET_SYMBOLS=$(_extract_field_from_block "Target Symbols")
  FAST_PATH_PRE_APPROVED=$(_extract_field_from_block "Pre-approved")
  FAST_PATH_GENERATED=$(_extract_field_from_block "Generated")
  FAST_PATH_REGENERATE=$(_extract_field_from_block "Regenerate")
}

# _confidence_at_or_above <confidence> <threshold>
# true if confidence >= threshold. Delegates to planned-ticket-check.sh's
# _confidence_below_threshold (inverse) to guarantee the two can never drift.
_confidence_at_or_above() {
  ! _confidence_below_threshold "$1" "$2"
}

# ── Self-test mode ──────────────────────────────────────────────────────────

if [ "${1:-}" = "--self-test" ]; then
  echo "Running self-tests..."

  # Strategy → complexity mapping
  test "$(map_strategy_to_complexity "Conservative")" = "simple" &&
    echo "✓ Conservative → simple" || echo "✗ Conservative → simple"
  test "$(map_strategy_to_complexity "Balanced")" = "complex" &&
    echo "✓ Balanced → complex" || echo "✗ Balanced → complex"
  test "$(map_strategy_to_complexity "Innovative")" = "complex" &&
    echo "✓ Innovative → complex" || echo "✗ Innovative → complex"
  test "$(map_strategy_to_complexity "garbage")" = "complex" &&
    echo "✓ unknown → complex (safe default)" || echo "✗ unknown → complex"

  # Confidence threshold
  _confidence_at_or_above "0.90" "0.85" && echo "✓ 0.90 >= 0.85" || echo "✗ 0.90 >= 0.85"
  _confidence_at_or_above "0.85" "0.85" && echo "✓ 0.85 >= 0.85" || echo "✗ 0.85 >= 0.85"
  ! _confidence_at_or_above "0.70" "0.85" && echo "✓ 0.70 < 0.85" || echo "✗ 0.70 < 0.85"

  echo "Helper self-tests complete — run test-appraise-fast-path.sh for full coverage."
  exit 0
fi
