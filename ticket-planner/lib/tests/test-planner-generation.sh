#!/usr/bin/env bash
# test-planner-generation.sh — Tests for planner generation primitives:
# planner-deps-check.sh, planner-context-gen.sh, planner-ticket-validate.sh
#
# Run: bash ticket-planner/lib/tests/test-planner-generation.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/.."

source "${LIB_DIR}/planner-deps-check.sh"
source "${LIB_DIR}/planner-context-gen.sh"
source "${LIB_DIR}/planner-ticket-validate.sh"

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

# Set REPOS_ROOT for idempotency helpers
export REPOS_ROOT="$TMPDIR"

PASS=0
FAIL=0
pass() {
  echo "  PASS $1"
  PASS=$((PASS + 1))
}
fail() {
  echo "  FAIL $1: $2"
  FAIL=$((FAIL + 1))
}

echo "=== planner generation primitives tests ==="

# ═══════════════════════════════════════════════════════════════════════════════
# planner-deps-check.sh
# ═══════════════════════════════════════════════════════════════════════════════

echo "--- deps: empty graph ---"
if planner_deps_check_acyclic "{}"; then
  pass "empty graph is acyclic"
else
  fail "empty graph is acyclic" "returned cyclic"
fi

echo "--- deps: simple acyclic chain ---"
# T2 depends on T1, T3 depends on T2
deps='{"T1":[],"T2":["T1"],"T3":["T2"]}'
if planner_deps_check_acyclic "$deps"; then
  pass "chain T1→T2→T3 is acyclic"
else
  fail "chain T1→T2→T3 is acyclic" "returned cyclic"
fi

echo "--- deps: simple cycle ---"
# T1 depends on T2, T2 depends on T1
deps='{"T1":["T2"],"T2":["T1"]}'
if ! planner_deps_check_acyclic "$deps" 2>/dev/null; then
  pass "mutual dependency T1↔T2 is cyclic"
else
  fail "mutual dependency T1↔T2 is cyclic" "returned acyclic"
fi

echo "--- deps: diamond (acyclic) ---"
# T1→T2, T1→T3, T2→T4, T3→T4
deps='{"T1":[],"T2":["T1"],"T3":["T1"],"T4":["T2","T3"]}'
if planner_deps_check_acyclic "$deps"; then
  pass "diamond dependency is acyclic"
else
  fail "diamond dependency is acyclic" "returned cyclic"
fi

echo "--- deps: topological sort ---"
sorted=$(planner_deps_topological_sort "$deps")
if [ "$(echo "$sorted" | jq -r 'length')" -eq 4 ]; then
  pass "topological sort returns 4 tickets"
else
  fail "topological sort returns 4 tickets" "got $(echo "$sorted" | jq -r 'length')"
fi

echo "--- deps: cyclic sort returns empty ---"
sorted=$(planner_deps_topological_sort '{"T1":["T2"],"T2":["T1"]}')
if [ "$sorted" = "[]" ]; then
  pass "cyclic dependency returns empty topological sort"
else
  fail "cyclic dependency returns empty" "got $sorted"
fi

echo "--- deps: validate missing targets ---"
deps='{"T1":["T2"]}'
tickets='["T1"]'
if ! planner_deps_validate_targets "$deps" "$tickets" 2>/dev/null; then
  pass "T1 depends on missing T2 → validation fails"
else
  fail "T1 depends on missing T2" "validation passed"
fi

echo "--- deps: validate good targets ---"
deps='{"T1":["T2"]}'
tickets='["T1","T2"]'
if planner_deps_validate_targets "$deps" "$tickets"; then
  pass "T1 depends on T2 which exists → validation passes"
else
  fail "T1 depends on T2 which exists" "validation failed"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# planner-context-gen.sh
# ═══════════════════════════════════════════════════════════════════════════════

echo "--- context-gen: valid block ---"
ctx=$(
  cat <<'JSON'
{
  "Schema-Version": 1,
  "Initiative": "INIT-42",
  "Epic": "CRE-100",
  "Confidence": 0.85,
  "Strategy": "Balanced",
  "Decision": "Extend DebtCollector with new payment method enum",
  "Affected Services": "debt-collection, payment-gateway",
  "Target Symbols": "DebtCollector.collect:src/collector.ts:42; PaymentMethod.parse:src/payment.ts:88",
  "Pre-approved": true,
  "Generated": "2026-07-21T00:00:00Z",
  "Regenerate": false
}
JSON
)
block=$(planner_context_generate "$ctx" 2>&1) || { fail "valid block generation" "$block"; }
if echo "$block" | grep -q '## Planner Context'; then
  pass "valid block has Planner Context heading"
else
  fail "valid block has Planner Context heading" "missing"
fi
if echo "$block" | grep -q '\*\*Confidence:\*\* 0.85'; then
  pass "valid block includes Confidence field"
else
  fail "valid block includes Confidence field" "missing"
fi
# Verify it passes the validator by checking required fields are present
for field in "Schema-Version" "Initiative" "Epic" "Confidence" "Strategy" \
  "Decision" "Affected Services" "Target Symbols" "Pre-approved" \
  "Generated" "Regenerate"; do
  if echo "$block" | grep -q "\*\*${field}:\*\*"; then
    : # present
  else
    fail "  required field '$field' present" "missing in generated block"
  fi
done
pass "all required fields present in generated block"

echo "--- context-gen: invalid strategy ---"
ctx='{"Schema-Version":1,"Initiative":"INIT-1","Epic":"CRE-1","Confidence":0.5,"Strategy":"Unknown","Decision":"test","Affected Services":"svc","Target Symbols":"","Pre-approved":false,"Generated":"","Regenerate":false}'
if ! planner_context_generate "$ctx" 2>/dev/null; then
  pass "invalid Strategy rejected"
else
  fail "invalid Strategy rejected" "generated with bad strategy"
fi

echo "--- context-gen: missing fields ---"
ctx='{"Schema-Version":1}'
if ! planner_context_generate "$ctx" 2>/dev/null; then
  pass "missing fields rejected"
else
  fail "missing fields rejected" "generated with missing fields"
fi

echo "--- context-gen: auto-generates timestamp ---"
ctx=$(
  cat <<'JSON'
{
  "Schema-Version": 1,
  "Initiative": "INIT-1",
  "Epic": "CRE-1",
  "Confidence": 0.5,
  "Strategy": "Conservative",
  "Decision": "test",
  "Affected Services": "svc",
  "Target Symbols": "",
  "Pre-approved": false,
  "Generated": "",
  "Regenerate": false
}
JSON
)
block=$(planner_context_generate "$ctx" 2>&1)
if echo "$block" | grep -qE '\*\*Generated:\*\* 20[0-9]{2}-[0-9]{2}-[0-9]{2}T'; then
  pass "empty Generated field auto-filled with ISO timestamp"
else
  fail "empty Generated field auto-filled" "missing timestamp"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# planner_confidence_derive
# ═══════════════════════════════════════════════════════════════════════════════

echo "--- confidence: strong signals ---"
conf=$(planner_confidence_derive '{"services_identified":4,"symbols_resolved":5,"prior_art_found":true,"complexity":"simple","exploration_depth":"deep"}')
# 50 + 20 + 15 + 10 + 10 + 5 = 110 → clamp to 95 → 0.95
if [ "$conf" = "0.95" ]; then
  pass "strong signals → 0.95"
else
  fail "strong signals → 0.95" "got $conf"
fi

echo "--- confidence: weak signals ---"
conf=$(planner_confidence_derive '{"services_identified":0,"symbols_resolved":0,"prior_art_found":false,"complexity":"complex","exploration_depth":"quick-scan"}')
# 50 + 0 + 0 + 0 + 0 - 15 = 35 → 0.35
if [ "$conf" = "0.35" ]; then
  pass "weak signals + complex → 0.35"
else
  fail "weak signals + complex → 0.35" "got $conf"
fi

echo "--- confidence: moderate signals ---"
conf=$(planner_confidence_derive '{"services_identified":2,"symbols_resolved":3,"prior_art_found":true,"complexity":"moderate","exploration_depth":"standard"}')
# 50 + 10 + 9 + 10 + 5 + 0 = 84 → 0.84
if [ "$conf" = "0.84" ]; then
  pass "moderate signals → 0.84"
else
  fail "moderate signals → 0.84" "got $conf"
fi

echo "--- confidence: varies across different evidence ---"
conf1=$(planner_confidence_derive '{"services_identified":4,"symbols_resolved":5,"prior_art_found":true,"complexity":"simple","exploration_depth":"deep"}')
conf2=$(planner_confidence_derive '{"services_identified":1,"symbols_resolved":2,"prior_art_found":false,"complexity":"complex","exploration_depth":"quick-scan"}')
if [ "$conf1" != "$conf2" ]; then
  pass "confidence varies across tickets with differing evidence"
else
  fail "confidence varies across tickets" "both returned $conf1"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# planner-ticket-validate.sh — idempotency
# ═══════════════════════════════════════════════════════════════════════════════

echo "--- idempotency: record intent ---"
planner_record_intent "INIT-TEST" "EpicGen" "epic" "epic-main"
intent_file="${TMPDIR}/.ticket-auto/initiatives/INIT-TEST/.intents/epic-main.json"
if [ -f "$intent_file" ]; then
  pass "intent file created"
else
  fail "intent file created" "file not found: $intent_file"
fi

echo "--- idempotency: entity not yet created ---"
if ! planner_entity_exists "INIT-TEST" "epic-main"; then
  pass "entity not yet marked created → returns false"
else
  fail "entity not yet marked created" "returned true"
fi

echo "--- idempotency: mark created ---"
planner_entity_mark_created "INIT-TEST" "epic-main" "CRE-999"
if planner_entity_exists "INIT-TEST" "epic-main"; then
  pass "entity marked created → returns true"
else
  fail "entity marked created" "returned false"
fi

echo "--- idempotency: get created ID ---"
lid=$(planner_entity_get_id "INIT-TEST" "epic-main")
if [ "$lid" = "CRE-999" ]; then
  pass "entity get_id returns Linear ID"
else
  fail "entity get_id returns Linear ID" "got '$lid'"
fi

echo "--- idempotency: duplicate record_intent is no-op ---"
planner_record_intent "INIT-TEST" "EpicGen" "epic" "epic-main"
status=$(jq -r '.status' "$intent_file")
if [ "$status" = "created" ]; then
  pass "re-recording intent does not overwrite created status"
else
  fail "re-recording intent does not overwrite created" "status=$status"
fi

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -gt 0 ] && exit 1 || exit 0
