#!/usr/bin/env bash
# test-planned-ticket-check.sh — unit tests for lib/planned-ticket-check.sh
# Usage: bash test-planned-ticket-check.sh [test_name_filter]
# -u intentionally omitted: Claude Code shell snapshots inject ZSH_VERSION
# references that trigger false-positive "unbound variable" errors.
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# ── CI-safe declare guards ─────────────────────────────────────────────────
# SessionStart hooks don't run in CI; declare stubs for functions from
# libraries we source that aren't available.
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

source "$LIB_DIR/planned-ticket-check.sh"

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
  if [ "$actual" -eq "$expected" ]; then
    echo "PASS: $name (exit $actual)"
    ((PASS++)) || true
  else
    echo "FAIL: $name (expected exit $expected, got $actual)"
    ((FAIL++)) || true
  fi
}

# ── Test helper: build a Planner Context block ─────────────────────────────

_build_block() {
  local schema_version="${1:-1}"
  local confidence="${2:-0.92}"
  local strategy="${3:-Balanced}"
  local pre_approved="${4:-true}"
  local target_symbols="${5:-DebtCollector.collect:src/collector.ts:42}"
  local initiative="${6:-INIT-42}"
  local epic="${7:-CRE-100}"
  local decision="${8:-Extend DebtCollector with new payment method enum}"
  local affected_services="${9:-debt-collection}"
  local generated="${10:-2026-07-07T18:00:00Z}"
  local regenerate="${11:-false}"

  cat <<EOF
Some ticket description text.

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

## Acceptance Criteria
- [ ] Something works
EOF
}

# ── Test: Schema-Version 1, fully valid block ──────────────────────────────

test_valid_block() {
  local desc
  desc=$(_build_block)
  check_planned_ticket_description "$desc"
}

# ── Test: no block at all ──────────────────────────────────────────────────

test_no_block() {
  local desc="Just a regular ticket description. No planner block here."
  check_planned_ticket_description "$desc"
}

# ── Test: missing required fields ──────────────────────────────────────────

test_missing_fields() {
  local desc
  desc=$(
    cat <<'EOF'
## Planner Context
**Schema-Version:** 1
**Initiative:** INIT-42
**Epic:** CRE-100
**Confidence:** 0.92
EOF
  )
  check_planned_ticket_description "$desc"
}

# ── Test: invalid Confidence (1.5) ─────────────────────────────────────────

test_invalid_confidence() {
  local desc
  desc=$(_build_block "1" "1.5")
  check_planned_ticket_description "$desc"
}

# ── Test: invalid Strategy ("aggressive") ──────────────────────────────────

test_invalid_strategy() {
  local desc
  desc=$(_build_block "1" "0.85" "aggressive")
  check_planned_ticket_description "$desc"
}

# ── Test: invalid Pre-approved ("yes") ─────────────────────────────────────

test_invalid_pre_approved() {
  local desc
  desc=$(_build_block "1" "0.85" "Balanced" "yes")
  check_planned_ticket_description "$desc"
}

# ── Test: low confidence + not pre-approved → exit 2 ───────────────────────

test_low_confidence_not_pre_approved() {
  local desc
  desc=$(_build_block "1" "0.35" "Balanced" "false")
  check_planned_ticket_description "$desc"
}

# ── Test: low confidence + pre-approved true → exit 0 (override) ───────────

test_low_confidence_pre_approved_override() {
  local desc
  desc=$(_build_block "1" "0.35" "Balanced" "true")
  check_planned_ticket_description "$desc"
}

# ── Test: custom PLANNER_CONFIDENCE_THRESHOLD ──────────────────────────────

test_custom_threshold() {
  local desc
  desc=$(_build_block "1" "0.60" "Balanced" "false")
  PLANNER_CONFIDENCE_THRESHOLD=0.70 check_planned_ticket_description "$desc"
}

# ── Test: confidence exactly at threshold boundary (0.5 default) ────────────

test_confidence_at_default_threshold() {
  local desc
  desc=$(_build_block "1" "0.5" "Balanced" "false")
  check_planned_ticket_description "$desc"
}

# ── Test: confidence 0.6 with default threshold (0.5) → exit 0 ─────────────

test_confidence_above_default_threshold() {
  local desc
  desc=$(_build_block "1" "0.6" "Balanced" "false")
  check_planned_ticket_description "$desc"
}

# ── Test: Schema-Version 99 → exit 0 with stderr warning ───────────────────

test_future_schema_version() {
  local desc
  desc=$(_build_block "99")
  local stderr
  stderr=$(check_planned_ticket_description "$desc" 2>&1 >/dev/null) || true
  # Should exit 0
  local rc=$?
  [ $rc -eq 0 ] || return 1
  # Should warn about future version
  echo "$stderr" | grep -q "Schema-Version" || return 1
}

# ── Test: invalid Generated timestamp ──────────────────────────────────────

test_invalid_generated() {
  local desc
  desc=$(_build_block "1" "0.85" "Balanced" "true" "DebtCollector.collect:src/collector.ts:42" "INIT-42" "CRE-100" "Some decision" "debt-collection" "yesterday")
  check_planned_ticket_description "$desc"
}

# ── Test: malformed Target Symbols ─────────────────────────────────────────

test_malformed_target_symbols() {
  local desc
  desc=$(_build_block "1" "0.85" "Balanced" "true" "BadFormatNoColon")
  check_planned_ticket_description "$desc"
}

# ── Test: Regenerate field with invalid value (yes) → exit 1 ───────────────

test_invalid_regenerate() {
  local desc
  desc=$(_build_block "1" "0.85" "Balanced" "true" "DebtCollector.collect:src/collector.ts:42" "INIT-42" "CRE-100" "Some decision" "debt-collection" "2026-07-07T18:00:00Z" "yes")
  check_planned_ticket_description "$desc"
}

# ── Test: Pre-approved case sensitivity ("TRUE") → exit 1 ──────────────────

test_pre_approved_case_sensitivity() {
  local desc
  desc=$(_build_block "1" "0.85" "Balanced" "TRUE")
  check_planned_ticket_description "$desc"
}

# ── Test: Strategy case sensitivity ("conservative") → exit 1 ──────────────

test_strategy_case_sensitivity() {
  local desc
  desc=$(_build_block "1" "0.85" "conservative")
  check_planned_ticket_description "$desc"
}

# ── Test: Check_planned_ticket API fetch path (mocked) ─────────────────────

test_api_fetch_path() {
  # Mock get_issue to return a valid planned ticket
  get_issue() {
    echo '{"description":"## Planner Context\n**Schema-Version:** 1\n**Initiative:** INIT-42\n**Epic:** CRE-100\n**Confidence:** 0.92\n**Strategy:** Balanced\n**Decision:** Fix it\n**Affected Services:** svc\n**Target Symbols:** Foo.bar:src/foo.ts:10\n**Pre-approved:** true\n**Generated:** 2026-07-07T18:00:00Z\n**Regenerate:** false","labels":{"nodes":[{"name":"planned"}]}}'
  }
  check_planned_ticket "CRE-100"
}

# ── Test: check_planned_ticket with not-planned ticket ─────────────────────

test_not_planned_ticket() {
  check_planned_ticket "CRE-999" "Some description" "false"
}

# ── Test: check_planned_ticket with planned + valid block ──────────────────

test_planned_ticket_valid() {
  local desc
  desc=$(_build_block)
  check_planned_ticket "CRE-100" "$desc" "true"
}

# ── Schema-Version 2 tests ──────────────────────────────────────────────────

# Helper: build a Schema-Version 2 block with exploration fields
_build_block_v2() {
  local exploration_depth="${1:-standard}"
  local code_paths="${2:-DebtCollector.collect:src/collector.ts; PaymentGateway.charge:src/gateway.ts}"
  local api_contracts="${3:-debt-collection:POST /collect}"
  local alt_approaches="${4:-Extend collector (rejected: too coupled); Inline fix (selected)}"
  local open_questions="${5:-Should collector retry on 429?}"

  cat <<EOF
Some ticket description text.

## Planner Context
**Schema-Version:** 2
**Initiative:** INIT-42
**Epic:** CRE-100
**Confidence:** 0.92
**Strategy:** Balanced
**Decision:** Extend DebtCollector with new payment method enum
**Affected Services:** debt-collection
**Target Symbols:** DebtCollector.collect:src/collector.ts:42
**Pre-approved:** true
**Generated:** 2026-07-24T18:00:00Z
**Regenerate:** false
**Exploration Depth:** ${exploration_depth}
**Code Paths Traced:** ${code_paths}
**API Contracts Analyzed:** ${api_contracts}
**Alternative Approaches:** ${alt_approaches}
**Open Questions:** ${open_questions}

## Acceptance Criteria
- [ ] Something works
EOF
}

# ── Test: Schema-Version 2, fully valid with exploration fields → exit 0 ─────

test_v2_valid_full() {
  local desc
  desc=$(_build_block_v2)
  check_planned_ticket_description "$desc"
}

# ── Test: Schema-Version 2 with missing optional exploration fields → exit 0 ──

test_v2_missing_optional() {
  local desc
  desc=$(_build_block "2")
  check_planned_ticket_description "$desc"
}

# ── Test: Schema-Version 2, invalid Exploration Depth (thorough) → exit 1 ─────

test_v2_invalid_depth() {
  local desc
  desc=$(_build_block_v2 "thorough")
  check_planned_ticket_description "$desc"
}

# ── Test: Schema-Version 2, invalid Exploration Depth (none) → exit 1 ─────────

test_v2_invalid_depth_none() {
  local desc
  desc=$(_build_block_v2 "none")
  check_planned_ticket_description "$desc"
}

# ── Test: Schema-Version 2, malformed Code Paths Traced → exit 1 ─────────────

test_v2_malformed_code_paths() {
  local desc
  desc=$(_build_block_v2 "standard" "NoColonHere")
  check_planned_ticket_description "$desc"
}

# ── Test: Exploration depth mismatch — quick-scan + complex → exit 1 ──────────

test_depth_mismatch_quick_complex() {
  check_exploration_depth_mismatch "quick-scan" "complex" 1
}

# ── Test: Exploration depth mismatch — deep + complex → exit 0 ────────────────

test_depth_mismatch_deep_complex() {
  check_exploration_depth_mismatch "deep" "complex" 3
}

# ── Test: Exploration depth mismatch — standard + simple → exit 0 ─────────────

test_depth_mismatch_standard_simple() {
  check_exploration_depth_mismatch "standard" "simple" 1
}

# ── Test: Exploration depth mismatch — quick-scan + 5 services → exit 1 ───────

test_depth_mismatch_quick_many_services() {
  check_exploration_depth_mismatch "quick-scan" "simple" 5
}

# ── Run tests ──────────────────────────────────────────────────────────────

echo "=== planned-ticket-check.sh unit tests ==="
echo ""

_run "fully valid block (exit 0)" test_valid_block
_run_exit_code "no block → exit 1" 1 test_no_block
_run_exit_code "missing fields → exit 1" 1 test_missing_fields
_run_exit_code "invalid Confidence (1.5) → exit 1" 1 test_invalid_confidence
_run_exit_code "invalid Strategy (aggressive) → exit 1" 1 test_invalid_strategy
_run_exit_code "invalid Pre-approved (yes) → exit 1" 1 test_invalid_pre_approved
_run_exit_code "low confidence + not pre-approved → exit 2" 2 test_low_confidence_not_pre_approved
_run "low confidence + pre-approved → exit 0" test_low_confidence_pre_approved_override
_run_exit_code "custom threshold 0.70 + conf 0.60 → exit 2" 2 test_custom_threshold
_run "confidence exactly at threshold 0.5 → exit 0" test_confidence_at_default_threshold
_run "confidence 0.6 above default 0.5 → exit 0" test_confidence_above_default_threshold
_run "future Schema-Version → exit 0 + warn" test_future_schema_version
_run_exit_code "invalid Generated (yesterday) → exit 1" 1 test_invalid_generated
_run_exit_code "malformed Target Symbols → exit 1" 1 test_malformed_target_symbols
_run_exit_code "invalid Regenerate (yes) → exit 1" 1 test_invalid_regenerate
_run_exit_code "Pre-approved case sensitivity (TRUE) → exit 1" 1 test_pre_approved_case_sensitivity
_run_exit_code "Strategy case sensitivity (conservative) → exit 1" 1 test_strategy_case_sensitivity
_run "API fetch path with mocked get_issue → exit 0" test_api_fetch_path
_run "not-planned ticket → exit 0" test_not_planned_ticket
_run "planned ticket + valid block → exit 0" test_planned_ticket_valid

echo ""
echo "--- Schema-Version 2 ---"
_run "V2 fully valid with exploration fields → exit 0" test_v2_valid_full
_run "V2 missing optional exploration fields → exit 0" test_v2_missing_optional
_run_exit_code "V2 invalid Exploration Depth (thorough) → exit 1" 1 test_v2_invalid_depth
_run_exit_code "V2 invalid Exploration Depth (none) → exit 1" 1 test_v2_invalid_depth_none
_run_exit_code "V2 malformed Code Paths Traced → exit 1" 1 test_v2_malformed_code_paths

echo ""
echo "--- Exploration depth mismatch ---"
_run_exit_code "quick-scan + complex → exit 1" 1 test_depth_mismatch_quick_complex
_run "deep + complex → exit 0" test_depth_mismatch_deep_complex
_run "standard + simple → exit 0" test_depth_mismatch_standard_simple
_run_exit_code "quick-scan + 5 services → exit 1" 1 test_depth_mismatch_quick_many_services

echo ""
echo "--- _strip_planner_context_block ---"

test_strip_removes_block() {
  local desc stripped
  desc=$(_build_block)
  stripped=$(_strip_planner_context_block "$desc")
  ! echo "$stripped" | grep -q "Planner Context" &&
    ! echo "$stripped" | grep -q "Affected Services" &&
    echo "$stripped" | grep -q "Some ticket description text."
}

test_strip_no_block_is_noop() {
  local desc="Just a regular ticket description. No planner block here."
  local stripped
  stripped=$(_strip_planner_context_block "$desc")
  [ "$stripped" = "$desc" ]
}

test_strip_preserves_trailing_section() {
  local desc stripped
  desc=$(_build_block)
  stripped=$(_strip_planner_context_block "$desc")
  echo "$stripped" | grep -q "## Acceptance Criteria" &&
    echo "$stripped" | grep -q "Something works"
}

_run "strip removes Planner Context block" test_strip_removes_block
_run "strip is a no-op when no block present" test_strip_no_block_is_noop
_run "strip preserves sections after the block" test_strip_preserves_trailing_section

echo ""
echo "=== $((PASS + FAIL)) tests: $PASS pass, $FAIL fail ==="
[ "$FAIL" -eq 0 ] || exit 1
