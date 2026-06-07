#!/usr/bin/env bash
# test-ticket-audit-split-detection.sh — unit tests for audit-size-check.sh
# Tests all 3 signals individually, 2-of-3 combinations, boundary values.
# Requires: bash
# Usage: bash test-ticket-audit-split-detection.sh [test_name_filter]
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Source the helper to get the audit_size_check function
source "$LIB_DIR/audit-size-check.sh"

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

# Helper: run audit_size_check and eval its output to set SIGNAL_COUNT and SIGNALS
_run_size_check() {
  local text="$1"
  local wiki_csv="${2:-}"
  local output
  output=$(audit_size_check "$text" "$wiki_csv")
  eval "$output"
}

# ── Individual signal tests ──────────────────────────────────────────────────

test_ac_count_below_threshold_no_flag() {
  local text="
- Item 1
- Item 2
- Item 3
"
  _run_size_check "$text" ""
  [ "${SIGNAL_COUNT:-0}" -eq 0 ]
}

test_ac_count_above_threshold_flags() {
  local text="
- Item 1
- Item 2
- Item 3
- Item 4
- Item 5
- Item 6
"
  _run_size_check "$text" ""
  echo "$SIGNALS" | grep -q "ac_count" || return 1
  [ "${SIGNAL_COUNT:-0}" -ge 1 ]
}

test_word_count_below_threshold_no_flag() {
  _run_size_check "Short description" ""
  echo "$SIGNALS" | grep -q "word_count" && return 1
  return 0
}

test_word_count_boundary_400_no_flag() {
  local text
  text=$(printf 'word%.0s ' $(seq 1 400))
  _run_size_check "$text" ""
  echo "$SIGNALS" | grep -q "word_count" && return 1
  return 0
}

test_word_count_boundary_401_flags() {
  local text
  text=$(printf 'word%.0s ' $(seq 1 401))
  _run_size_check "$text" ""
  echo "$SIGNALS" | grep -q "word_count" || return 1
}

test_wiki_service_count_below_3_no_flag() {
  _run_size_check "This references attorney-service and case-service but not enough." "attorney-service,case-service,payment-service"
  echo "$SIGNALS" | grep -q "wiki_service_count" && return 1
  return 0
}

test_wiki_service_count_3_flags() {
  _run_size_check "The attorney-service API, case-service module, and payment-service handler all need changes." "attorney-service,case-service,payment-service"
  echo "$SIGNALS" | grep -q "wiki_service_count" || return 1
}

# ── Split candidate: 2+ signals ───────────────────────────────────────────────

test_two_signals_triggers_split() {
  local text
  text=$(printf 'word%.0s ' $(seq 1 401))
  text="$text
- Item 1
- Item 2
- Item 3
- Item 4
- Item 5
- Item 6"
  _run_size_check "$text" ""
  [ "${SIGNAL_COUNT:-0}" -ge 2 ]
}

test_single_signal_no_split() {
  local text
  text=$(printf 'word%.0s ' $(seq 1 401))
  _run_size_check "$text" ""
  [ "${SIGNAL_COUNT:-0}" -lt 2 ]
}

# ── Edge cases ────────────────────────────────────────────────────────────────

test_empty_text_zero_signals() {
  _run_size_check "" ""
  [ "${SIGNAL_COUNT:-0}" -eq 0 ]
}

test_wiki_unset_no_service_signal() {
  _run_size_check "Attorney service, case service, payment service all mentioned." ""
  echo "$SIGNALS" | grep -q "wiki_service_count" && return 1
  return 0
}

# ── dispatch ──────────────────────────────────────────────────────────────────

FILTER="${1:-}"

for fn in \
  test_ac_count_below_threshold_no_flag \
  test_ac_count_above_threshold_flags \
  test_word_count_below_threshold_no_flag \
  test_word_count_boundary_400_no_flag \
  test_word_count_boundary_401_flags \
  test_wiki_service_count_below_3_no_flag \
  test_wiki_service_count_3_flags \
  test_two_signals_triggers_split \
  test_single_signal_no_split \
  test_empty_text_zero_signals \
  test_wiki_unset_no_service_signal; do
  [ -z "$FILTER" ] || [[ "$fn" == *"$FILTER"* ]] || continue
  _run "$fn" "$fn"
done

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
