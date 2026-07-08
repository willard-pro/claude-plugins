#!/usr/bin/env bash
# test-appraise-fast-path.sh — unit tests for lib/appraise-fast-path.sh
# Usage: bash test-appraise-fast-path.sh [test_name_filter]
# -u intentionally omitted: Claude Code shell snapshots inject ZSH_VERSION
# references that trigger false-positive "unbound variable" errors.
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# ── CI-safe declare guards ─────────────────────────────────────────────────
if ! declare -f get_issue >/dev/null 2>&1; then
  get_issue() {
    echo "get_issue: CI stub — override in test setup" >&2
    echo '{"description":"","labels":{"nodes":[]}}'
  }
fi
if ! declare -f _plog >/dev/null 2>&1; then
  _plog() { :; }
fi
if ! declare -f hb_gate >/dev/null 2>&1; then
  hb_gate() { :; }
fi

# Export threshold constants so tests are explicit about their values
# rather than relying on defaults that could silently change.
export FAST_PATH_CONFIDENCE_THRESHOLD="${FAST_PATH_CONFIDENCE_THRESHOLD:-0.85}"
export PLANNER_CONFIDENCE_THRESHOLD="${PLANNER_CONFIDENCE_THRESHOLD:-0.50}"

source "$LIB_DIR/planned-ticket-check.sh"
source "$LIB_DIR/appraise-fast-path.sh"

PASS=0
FAIL=0

_run() {
  local name="$1"
  shift
  if "$@" 2>/dev/null; then
    echo "PASS: $name"
    ((PASS++)) || true
  else
    echo "FAIL: $name"
    ((FAIL++)) || true
  fi
}

_run_exit_code() {
  local name="$1"
  local expected="$2"
  shift 2
  local actual=0
  "$@" 2>/dev/null || actual=$?
  # If the test function swallows the exit (|| true), check FAST_PATH_EXIT_CODE
  if [ "$actual" -eq 0 ] 2>/dev/null && [ -n "${FAST_PATH_EXIT_CODE:-}" ]; then
    actual=${FAST_PATH_EXIT_CODE}
  fi
  if [ "$actual" -eq "$expected" ]; then
    echo "PASS: $name (exit $actual)"
    ((PASS++)) || true
  else
    echo "FAIL: $name (expected exit $expected, got $actual)"
    ((FAIL++)) || true
  fi
}

_run_fast_path() {
  local name="$1"
  local expected_eligible="$2"
  shift 2
  check_fast_path_eligible "TEST-1" "$1" "true" 2>/dev/null || true
  if [ "$FAST_PATH_ELIGIBLE" = "$expected_eligible" ]; then
    echo "PASS: $name (eligible=$FAST_PATH_ELIGIBLE, reason=$FAST_PATH_REASON)"
    ((PASS++)) || true
  else
    echo "FAIL: $name (expected eligible=$expected_eligible, got $FAST_PATH_ELIGIBLE, reason=$FAST_PATH_REASON)"
    ((FAIL++)) || true
  fi
}

# ── Test helper: build a Planner Context block ─────────────────────────────

_build_planner_block() {
  local confidence="${1:-0.92}"
  local pre_approved="${2:-true}"
  local strategy="${3:-Balanced}"
  local regenerate="${4:-false}"
  local schema_version="${5:-1}"

  cat <<BLOCK
## Planner Context
**Schema-Version:** ${schema_version}
**Initiative:** INIT-42
**Epic:** CRE-100
**Confidence:** ${confidence}
**Strategy:** ${strategy}
**Decision:** Extend DebtCollector with new payment method enum
**Affected Services:** debt-collection, payment-gateway
**Target Symbols:** DebtCollector.collect:src/collector.ts:42;PaymentMethod.parse:src/payment.ts:88
**Pre-approved:** ${pre_approved}
**Generated:** 2026-07-07T18:00:00Z
**Regenerate:** ${regenerate}
BLOCK
}

_build_ticket_description() {
  local confidence="${1:-0.92}"
  local pre_approved="${2:-true}"
  local strategy="${3:-Balanced}"
  local regenerate="${4:-false}"
  local schema_version="${5:-1}"

  cat <<DESC
This is a ticket description about fixing the payment collection flow.

$(_build_planner_block "$confidence" "$pre_approved" "$strategy" "$regenerate" "$schema_version")

## Acceptance Criteria
- [ ] Payments can be collected with new method
- [ ] Backward compatible with existing methods
DESC
}

# ── Eligibility tests ──────────────────────────────────────────────────────

test_api_error() {
  # Simulate get_issue failure by calling with only ticket ID (no inline desc).
  # The CI stub for get_issue returns empty description/labels, which causes
  # check_planned_ticket_description to see no planned label → not_planned.
  # For a true api_error test, we override get_issue to fail:
  local orig_get_issue
  orig_get_issue=$(declare -f get_issue 2>/dev/null || true)
  get_issue() { return 1; }
  check_fast_path_eligible "TEST-1" "" "" 2>/dev/null || true
  [ "$FAST_PATH_ELIGIBLE" = "false" ] && [ "$FAST_PATH_REASON" = "api_error" ]
  # Restore
  if [ -n "$orig_get_issue" ]; then
    eval "$orig_get_issue"
  fi
}

test_no_planned_label() {
  check_fast_path_eligible "TEST-1" "Just a normal ticket" "false" 2>/dev/null || true
  [ "$FAST_PATH_ELIGIBLE" = "false" ] && [ "$FAST_PATH_REASON" = "not_planned" ]
}

test_pre_approved_true() {
  local desc
  desc=$(_build_ticket_description "0.92" "true")
  check_fast_path_eligible "TEST-1" "$desc" "true" 2>/dev/null || true
  [ "$FAST_PATH_ELIGIBLE" = "true" ] && [ "$FAST_PATH_REASON" = "pre_approved" ]
}

test_high_confidence_not_pre_approved() {
  local desc
  desc=$(_build_ticket_description "0.90" "false")
  check_fast_path_eligible "TEST-1" "$desc" "true" 2>/dev/null || true
  [ "$FAST_PATH_ELIGIBLE" = "true" ] && [ "$FAST_PATH_REASON" = "confidence_met" ]
}

test_low_confidence_not_pre_approved() {
  local desc
  desc=$(_build_ticket_description "0.35" "false")
  check_fast_path_eligible "TEST-1" "$desc" "true" 2>/dev/null || true
  # Gets caught by validator (PLANNER_CONFIDENCE_THRESHOLD=0.5), not the
  # fast-path confidence check (FAST_PATH_CONFIDENCE_THRESHOLD=0.85).
  [ "$FAST_PATH_ELIGIBLE" = "false" ] && [ "$FAST_PATH_REASON" = "low_confidence_not_preapproved" ]
}

test_low_confidence_but_pre_approved() {
  local desc
  desc=$(_build_ticket_description "0.35" "true")
  check_fast_path_eligible "TEST-1" "$desc" "true" 2>/dev/null || true
  [ "$FAST_PATH_ELIGIBLE" = "true" ] && [ "$FAST_PATH_REASON" = "pre_approved" ]
}

test_missing_planner_block() {
  local desc="Just a regular ticket with planned label but no block"
  check_fast_path_eligible "TEST-1" "$desc" "true" 2>/dev/null || true
  [ "$FAST_PATH_ELIGIBLE" = "false" ] && [ "$FAST_PATH_REASON" = "malformed_block" ]
}

test_malformed_block_missing_fields() {
  local desc="## Planner Context
**Schema-Version:** 1
**Initiative:** INIT-42"
  check_fast_path_eligible "TEST-1" "$desc" "true" 2>/dev/null || true
  [ "$FAST_PATH_ELIGIBLE" = "false" ] && [ "$FAST_PATH_REASON" = "malformed_block" ]
}

test_future_schema_version_accepted() {
  local desc
  desc=$(_build_ticket_description "0.92" "true" "Balanced" "false" "3")
  check_fast_path_eligible "TEST-1" "$desc" "true" 2>/dev/null || true
  # Future schema versions are tolerated — should still be eligible
  [ "$FAST_PATH_ELIGIBLE" = "true" ]
}

# ── Field extraction tests ─────────────────────────────────────────────────

test_field_extraction_after_eligible() {
  local desc
  desc=$(_build_ticket_description "0.88" "true" "Innovative" "true")
  check_fast_path_eligible "TEST-1" "$desc" "true" 2>/dev/null || true
  [ "$FAST_PATH_ELIGIBLE" = "true" ] || return 1
  [ "$FAST_PATH_INITIATIVE" = "INIT-42" ] || {
    echo "  expected INIT-42, got $FAST_PATH_INITIATIVE"
    return 1
  }
  [ "$FAST_PATH_EPIC" = "CRE-100" ] || {
    echo "  expected CRE-100, got $FAST_PATH_EPIC"
    return 1
  }
  [ "$FAST_PATH_CONFIDENCE" = "0.88" ] || {
    echo "  expected 0.88, got $FAST_PATH_CONFIDENCE"
    return 1
  }
  [ "$FAST_PATH_STRATEGY" = "Innovative" ] || {
    echo "  expected Innovative, got $FAST_PATH_STRATEGY"
    return 1
  }
  [ "$FAST_PATH_DECISION" = "Extend DebtCollector with new payment method enum" ] || {
    echo "  decision mismatch"
    return 1
  }
  [ "$FAST_PATH_AFFECTED_SERVICES" = "debt-collection, payment-gateway" ] || {
    echo "  services mismatch"
    return 1
  }
  [ "$FAST_PATH_TARGET_SYMBOLS" = "DebtCollector.collect:src/collector.ts:42;PaymentMethod.parse:src/payment.ts:88" ] || {
    echo "  symbols mismatch"
    return 1
  }
  [ "$FAST_PATH_PRE_APPROVED" = "true" ] || {
    echo "  pre-approved mismatch"
    return 1
  }
  [ "$FAST_PATH_GENERATED" = "2026-07-07T18:00:00Z" ] || {
    echo "  generated mismatch"
    return 1
  }
  [ "$FAST_PATH_REGENERATE" = "true" ] || {
    echo "  regenerate mismatch"
    return 1
  }
  [ "$FAST_PATH_SCHEMA_VERSION" = "1" ] || {
    echo "  schema-version mismatch"
    return 1
  }
}

# ── Strategy → complexity mapping tests ────────────────────────────────────

test_conservative_is_simple() {
  [ "$(map_strategy_to_complexity "Conservative")" = "simple" ]
}

test_balanced_is_complex() {
  [ "$(map_strategy_to_complexity "Balanced")" = "complex" ]
}

test_innovative_is_complex() {
  [ "$(map_strategy_to_complexity "Innovative")" = "complex" ]
}

test_unknown_strategy_defaults_to_complex() {
  [ "$(map_strategy_to_complexity "chaos")" = "complex" ]
}

# ── Notes generation tests ─────────────────────────────────────────────────

test_generate_fast_path_notes() {
  local tmpdir
  tmpdir=$(mktemp -d)
  local desc
  desc=$(_build_ticket_description "0.92" "true" "Conservative" "false")

  # Run eligibility check to populate FAST_PATH_* variables
  check_fast_path_eligible "TEST-1" "$desc" "true" 2>/dev/null || true
  [ "$FAST_PATH_ELIGIBLE" = "true" ] || {
    rm -rf "$tmpdir"
    return 1
  }

  generate_fast_path_notes "$tmpdir" "CRE-200"

  # Verify key sections exist
  grep -q "^# Working Notes — CRE-200" "$tmpdir/notes.md" || {
    rm -rf "$tmpdir"
    echo "  missing title"
    return 1
  }
  grep -q "^\*\*Score:\*\* simple" "$tmpdir/notes.md" || {
    rm -rf "$tmpdir"
    echo "  missing complexity"
    return 1
  }
  grep -q "fast-path" "$tmpdir/notes.md" || {
    rm -rf "$tmpdir"
    echo "  missing fast-path marker"
    return 1
  }
  grep -q "Planner Decision:" "$tmpdir/notes.md" || {
    rm -rf "$tmpdir"
    echo "  missing decision"
    return 1
  }
  grep -q "INIT-42" "$tmpdir/notes.md" || {
    rm -rf "$tmpdir"
    echo "  missing initiative"
    return 1
  }
  grep -q "debt-collection" "$tmpdir/notes.md" || {
    rm -rf "$tmpdir"
    echo "  missing affected services"
    return 1
  }
  grep -q "DebtCollector.collect" "$tmpdir/notes.md" || {
    rm -rf "$tmpdir"
    echo "  missing target symbols"
    return 1
  }
  grep -q "readiness critique" "$tmpdir/notes.md" || {
    rm -rf "$tmpdir"
    echo "  missing still-required note"
    return 1
  }

  rm -rf "$tmpdir"
  return 0
}

test_generate_fast_path_notes_regenerate_warning() {
  local tmpdir
  tmpdir=$(mktemp -d)
  local desc
  desc=$(_build_ticket_description "0.92" "true" "Balanced" "true")

  check_fast_path_eligible "TEST-1" "$desc" "true" 2>/dev/null || true
  generate_fast_path_notes "$tmpdir" "CRE-201"

  grep -q "Planner recommends regenerating" "$tmpdir/notes.md" || {
    rm -rf "$tmpdir"
    echo "  missing regenerate warning"
    return 1
  }

  rm -rf "$tmpdir"
  return 0
}

# ── Edge case tests ────────────────────────────────────────────────────────

test_confidence_exactly_at_threshold() {
  local desc
  desc=$(_build_ticket_description "0.85" "false")
  check_fast_path_eligible "TEST-1" "$desc" "true" 2>/dev/null || true
  [ "$FAST_PATH_ELIGIBLE" = "true" ] && [ "$FAST_PATH_REASON" = "confidence_met" ]
}

test_confidence_just_below_threshold() {
  local desc
  desc=$(_build_ticket_description "0.84" "false")
  check_fast_path_eligible "TEST-1" "$desc" "true" 2>/dev/null || true
  [ "$FAST_PATH_ELIGIBLE" = "false" ] && [ "$FAST_PATH_REASON" = "confidence_below_threshold" ]
}

test_pre_approved_trumps_low_confidence() {
  # Even at 0.10 confidence, pre-approved=true should be eligible
  local desc
  desc=$(_build_ticket_description "0.10" "true")
  check_fast_path_eligible "TEST-1" "$desc" "true" 2>/dev/null || true
  [ "$FAST_PATH_ELIGIBLE" = "true" ] && [ "$FAST_PATH_REASON" = "pre_approved" ]
}

test_empty_target_symbols_rejected() {
  local desc
  desc=$(
    cat <<DESC
Ticket description.

## Planner Context
**Schema-Version:** 1
**Initiative:** INIT-42
**Epic:** CRE-100
**Confidence:** 0.92
**Strategy:** Conservative
**Decision:** Simple fix
**Affected Services:** debt-collection
**Target Symbols:**
**Pre-approved:** true
**Generated:** 2026-07-07T18:00:00Z
**Regenerate:** false
DESC
  )
  check_fast_path_eligible "TEST-1" "$desc" "true" 2>/dev/null || true
  # Empty Target Symbols is a required field — treated as missing, not valid
  [ "$FAST_PATH_ELIGIBLE" = "false" ] && [ "$FAST_PATH_REASON" = "malformed_block" ]
}

# ── Test runner ─────────────────────────────────────────────────────────────

FILTER="${1:-}"

echo "=== Eligibility tests ==="
_run "api_error (get_issue fails)" test_api_error
_run "no planned label" test_no_planned_label
_run "pre-approved=true" test_pre_approved_true
_run "high confidence, not pre-approved" test_high_confidence_not_pre_approved
_run_exit_code "low confidence, not pre-approved (exit 2)" 2 test_low_confidence_not_pre_approved
_run "low confidence but pre-approved" test_low_confidence_but_pre_approved
_run "missing Planner Context block" test_missing_planner_block
_run "malformed block (missing fields)" test_malformed_block_missing_fields
_run "future schema version accepted" test_future_schema_version_accepted

echo ""
echo "=== Field extraction tests ==="
_run "all fields extracted" test_field_extraction_after_eligible

echo ""
echo "=== Strategy mapping tests ==="
_run "Conservative → simple" test_conservative_is_simple
_run "Balanced → complex" test_balanced_is_complex
_run "Innovative → complex" test_innovative_is_complex
_run "unknown → complex (safe default)" test_unknown_strategy_defaults_to_complex

echo ""
echo "=== Notes generation tests ==="
_run "generate fast-path notes.md" test_generate_fast_path_notes
_run "regenerate warning in notes" test_generate_fast_path_notes_regenerate_warning

echo ""
echo "=== Edge case tests ==="
_run "confidence exactly at threshold" test_confidence_exactly_at_threshold
_run "confidence just below threshold" test_confidence_just_below_threshold
_run "pre-approved trumps low confidence" test_pre_approved_trumps_low_confidence
_run "empty target symbols rejected" test_empty_target_symbols_rejected

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
