#!/usr/bin/env bash
# test-branch-directive-gen.sh — Tests for branch-directive-gen.sh
#
# Tests the generator in isolation plus round-trip validation through
# the downstream branch-directive-check.sh validator.
#
# Usage: bash lib/tests/test-branch-directive-gen.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/.."

# ── Declare-guard stubs (SessionStart hooks don't run in CI) ──────────────────

# Stub heartbeat functions (if heartbeat.sh is sourced transitively)
if ! declare -f hb_init >/dev/null 2>&1; then
  hb_init() { :; }
  hb_heartbeat() { :; }
  hb_gate() { :; }
  hb_decision() { :; }
  hb_fallback() { :; }
  hb_api() { :; }
  hb_retry() { :; }
  hb_source() { :; }
fi

# Stub Linear API functions (if linear-api.sh is sourced transitively)
if ! declare -f get_issue >/dev/null 2>&1; then
  get_issue() { echo '{"id":"'${1:-}'","description":"'${2:-}'"}'; }
  get_comments() { echo "[]"; }
  get_team() { echo "{}"; }
  get_me() { echo "{}"; }
  update_issue() { :; }
  save_comment() { :; }
  get_project_config() { echo "{}"; }
fi

source "${LIB_DIR}/branch-directive-gen.sh"

PASS=0
FAIL=0

# ── Resolve cross-plugin validator ─────────────────────────────────────────────

# Three-level fallback: plugin cache → skills lib → relative path
VALIDATOR=""
if [ -f "${CLAUDE_PLUGIN_ROOT:-}/../../ticket-auto-pipeline/current/lib/branch-directive-check.sh" ]; then
  VALIDATOR="${CLAUDE_PLUGIN_ROOT}/../../ticket-auto-pipeline/current/lib/branch-directive-check.sh"
elif [ -f "${SCRIPT_DIR}/../../../ticket-auto-pipeline/lib/branch-directive-check.sh" ]; then
  VALIDATOR="${SCRIPT_DIR}/../../../ticket-auto-pipeline/lib/branch-directive-check.sh"
elif [ -f "${SCRIPT_DIR}/../../ticket-auto-pipeline/lib/branch-directive-check.sh" ]; then
  VALIDATOR="${SCRIPT_DIR}/../../ticket-auto-pipeline/lib/branch-directive-check.sh"
fi

# ── Generator rejection tests ─────────────────────────────────────────────────

echo "=== Generator rejection tests ==="

# Test G1: Missing required field
echo "--- G1: missing field → rejected ---"
MISSING='{"initiative_id":"INIT-42","title_slug":"test","base_branch":"develop","merge_policy":"manual"}'
branch_directive_generate "$MISSING" >/dev/null 2>&1 && echo "FAIL: missing field accepted" && FAIL=$((FAIL + 1)) || {
  echo "PASS: missing field rejected"
  PASS=$((PASS + 1))
}

# Test G2: Invalid Merge Policy
echo "--- G2: invalid merge policy → rejected ---"
BAD_MERGE='{"initiative_id":"INIT-42","title_slug":"test","base_branch":"develop","merge_policy":"auto","sync_policy":"none"}'
branch_directive_generate "$BAD_MERGE" >/dev/null 2>&1 && echo "FAIL: bad merge policy accepted" && FAIL=$((FAIL + 1)) || {
  echo "PASS: bad merge policy rejected"
  PASS=$((PASS + 1))
}

# Test G3: Invalid Sync Policy
echo "--- G3: invalid sync policy → rejected ---"
BAD_SYNC='{"initiative_id":"INIT-42","title_slug":"test","base_branch":"develop","merge_policy":"manual","sync_policy":"force-push"}'
branch_directive_generate "$BAD_SYNC" >/dev/null 2>&1 && echo "FAIL: bad sync policy accepted" && FAIL=$((FAIL + 1)) || {
  echo "PASS: bad sync policy rejected"
  PASS=$((PASS + 1))
}

# Test G4: Unparseable JSON
echo "--- G4: unparseable JSON → rejected ---"
branch_directive_generate "not json" >/dev/null 2>&1 && echo "FAIL: unparseable accepted" && FAIL=$((FAIL + 1)) || {
  echo "PASS: unparseable rejected"
  PASS=$((PASS + 1))
}

# ── Generator output tests ────────────────────────────────────────────────────

echo ""
echo "=== Generator output tests ==="

# Test G5: Valid input produces expected output
echo "--- G5: valid input → formatted block ---"
VALID='{"initiative_id":"INIT-42","title_slug":"debt-collection","base_branch":"develop","merge_policy":"manual","sync_policy":"none"}'
OUTPUT=$(branch_directive_generate "$VALID")
echo "$OUTPUT" | grep -q "## Branch Directive" && echo "PASS: output has header" && PASS=$((PASS + 1)) || {
  echo "FAIL: missing header"
  FAIL=$((FAIL + 1))
}
echo "$OUTPUT" | grep -q "^\*\*Schema-Version:\*\*" && echo "PASS: Schema-Version present" && PASS=$((PASS + 1)) || {
  echo "FAIL: missing Schema-Version"
  FAIL=$((FAIL + 1))
}
echo "$OUTPUT" | grep -q "^\*\*Branch:\*\*" && echo "PASS: Branch present" && PASS=$((PASS + 1)) || {
  echo "FAIL: missing Branch"
  FAIL=$((FAIL + 1))
}
echo "$OUTPUT" | grep -q "^\*\*Base:\*\*" && echo "PASS: Base present" && PASS=$((PASS + 1)) || {
  echo "FAIL: missing Base"
  FAIL=$((FAIL + 1))
}
echo "$OUTPUT" | grep -q "^\*\*Merge Policy:\*\*" && echo "PASS: Merge Policy present" && PASS=$((PASS + 1)) || {
  echo "FAIL: missing Merge Policy"
  FAIL=$((FAIL + 1))
}
echo "$OUTPUT" | grep -q "^\*\*Sync Policy:\*\*" && echo "PASS: Sync Policy present" && PASS=$((PASS + 1)) || {
  echo "FAIL: missing Sync Policy"
  FAIL=$((FAIL + 1))
}
echo "$OUTPUT" | grep -qE "^\*\*Created:\*\* [0-9]{4}-[0-9]{2}-[0-9]{2}T" && echo "PASS: Created timestamp present" && PASS=$((PASS + 1)) || {
  echo "FAIL: missing or malformed Created"
  FAIL=$((FAIL + 1))
}

# Test G6: Fields appear in exact expected order
echo "--- G6: field order matches validator expectation ---"
FIELD_ORDER=$(echo "$OUTPUT" | grep -E '^\*\*[A-Z]' | sed 's/\*\*\([^*]*\):\*\*.*/\1/')
EXPECTED_ORDER="Schema-Version
Branch
Base
Merge Policy
Sync Policy
Created"
if [ "$FIELD_ORDER" = "$EXPECTED_ORDER" ]; then
  echo "PASS: field order matches validator"
  PASS=$((PASS + 1))
else
  echo "FAIL: field order mismatch"
  echo "  Expected: $EXPECTED_ORDER"
  echo "  Got:      $FIELD_ORDER"
  FAIL=$((FAIL + 1))
fi

# ── Round-trip validator tests ────────────────────────────────────────────────

echo ""
echo "=== Round-trip validator tests ==="

if [ -n "$VALIDATOR" ] && [ -f "$VALIDATOR" ]; then
  echo "Using validator: $VALIDATOR"

  # Resolve and source validator prerequisites
  # branch-directive-check.sh depends on _extract_md_section and _extract_field
  # from planned-ticket-check.sh (same plugin directory as the validator).
  VALIDATOR_DIR="$(dirname "$VALIDATOR")"
  PLANNED_TICKET_CHECK="${VALIDATOR_DIR}/planned-ticket-check.sh"

  if [ -f "$PLANNED_TICKET_CHECK" ]; then
    source "$PLANNED_TICKET_CHECK" 2>/dev/null || true
  fi
  source "$VALIDATOR" 2>/dev/null || true

  # Test R1: Generated output passes the validator
  echo "--- R1: generated block passes validator ---"
  VALID_OUTPUT=$(branch_directive_generate "$VALID")
  if declare -f check_branch_directive_description >/dev/null 2>&1; then
    # Build a description containing the directive block
    FULL_DESC="# Epic: Debt Collection

Some description text.

${VALID_OUTPUT}"
    check_branch_directive_description "$FULL_DESC" >/dev/null 2>&1 && rc=$? || rc=$?
    if [ "$rc" -eq 0 ]; then
      echo "PASS: generated output passes validator (rc=0)"
      PASS=$((PASS + 1))
    else
      echo "FAIL: validator rejected generated output (rc=$rc)"
      echo "  check_branch_directive_check output: $(check_branch_directive_description "$FULL_DESC" 2>&1 || true)"
      FAIL=$((FAIL + 1))
    fi
  else
    echo "SKIP: check_branch_directive_description not available (prereq source failed)"
  fi

  # Test R2: Branch name from derive passes validator
  echo "--- R2: derived branch name is valid ---"
  DERIVED_NAME=$(branch_directive_name_derive "INIT-42" "debt-collection-v2")
  if _validate_branch_name "$DERIVED_NAME" 2>/dev/null; then
    echo "PASS: derived name '$DERIVED_NAME' passes _validate_branch_name"
    PASS=$((PASS + 1))
  else
    echo "FAIL: derived name '$DERIVED_NAME' failed validator"
    FAIL=$((FAIL + 1))
  fi
else
  echo "SKIP: validator not found at any of the expected paths"
  echo "  Checked: plugin cache, skills lib, relative path"
fi

# ── Branch naming tests ──────────────────────────────────────────────────────

echo ""
echo "=== Branch naming tests ==="

# Test N1: Normal name derivation
echo "--- N1: normal name ---"
NAME=$(branch_directive_name_derive "INIT-42" "debt-collection-v2")
echo "  Derived: $NAME"
echo "$NAME" | grep -qE '^epic/init-[0-9]+-' && echo "PASS: normal name derived correctly" && PASS=$((PASS + 1)) || {
  echo "FAIL: unexpected name format"
  FAIL=$((FAIL + 1))
}

# Test N2: Long title truncated cleanly
echo "--- N2: long title truncated ---"
LONG_SLUG=$(python3 -c "print('x' * 70)" 2>/dev/null || printf 'x%.0s' {1..70})
NAME=$(branch_directive_name_derive "INIT-42" "$LONG_SLUG")
echo "  Derived: $NAME (${#NAME} chars)"
[ "${#NAME}" -le 60 ] && echo "PASS: truncated to 60 chars" && PASS=$((PASS + 1)) || {
  echo "FAIL: too long (${#NAME})"
  FAIL=$((FAIL + 1))
}
echo "$NAME" | grep -qv -- '-$' && echo "PASS: no trailing dash" && PASS=$((PASS + 1)) || {
  echo "FAIL: trailing dash"
  FAIL=$((FAIL + 1))
}
echo "$NAME" | grep -qv '/$' && echo "PASS: no trailing slash" && PASS=$((PASS + 1)) || {
  echo "FAIL: trailing slash"
  FAIL=$((FAIL + 1))
}

# Test N3: Title with special chars sanitized
echo "--- N3: special chars sanitized ---"
NAME=$(branch_directive_name_derive "INIT-99" "My Cool Feature!!! (2026)")
echo "  Derived: $NAME"
echo "$NAME" | grep -qv '[!() ]' && echo "PASS: special chars removed" && PASS=$((PASS + 1)) || {
  echo "FAIL: special chars remain"
  FAIL=$((FAIL + 1))
}

# Test N4: Uppercase lowered
echo "--- N4: uppercase lowered ---"
NAME=$(branch_directive_name_derive "INIT-42" "Debt-Collection-V2")
echo "  Derived: $NAME"
echo "$NAME" | grep -q "^epic/init-42-debt-collection-v2$" && echo "PASS: correctly lowercased" && PASS=$((PASS + 1)) || {
  echo "FAIL: not lowercased correctly"
  FAIL=$((FAIL + 1))
}

# Test N5: Leading char is always alphanumeric
echo "--- N5: leading char check ---"
NAME=$(branch_directive_name_derive "INIT-1" "-bad-start")
echo "  Derived: $NAME"
echo "$NAME" | grep -qE '^[a-z0-9]' && echo "PASS: valid leading char" && PASS=$((PASS + 1)) || {
  echo "FAIL: bad leading char"
  FAIL=$((FAIL + 1))
}

# Test N6: No parent path traversal
echo "--- N6: no path traversal ---"
NAME=$(branch_directive_name_derive "INIT-42" "debt-collection-v2")
if ! echo "$NAME" | grep -q '\.\.'; then
  echo "PASS: no .. in name"
  PASS=$((PASS + 1))
else
  echo "FAIL: contains .."
  FAIL=$((FAIL + 1))
fi

# ── UAT Policy (optional field) ───────────────────────────────────────────────

echo ""
echo "=== UAT Policy tests ==="

UAT_EPIC_JSON='{"initiative_id":"INIT-42","title_slug":"debt-collection","base_branch":"develop","merge_policy":"manual","sync_policy":"none","uat_policy":"epic"}'
UAT_PER_TICKET_JSON='{"initiative_id":"INIT-42","title_slug":"debt-collection","base_branch":"develop","merge_policy":"manual","sync_policy":"none","uat_policy":"per-ticket"}'
UAT_BAD_JSON='{"initiative_id":"INIT-42","title_slug":"debt-collection","base_branch":"develop","merge_policy":"manual","sync_policy":"none","uat_policy":"team"}'
UAT_ABSENT_JSON='{"initiative_id":"INIT-42","title_slug":"debt-collection","base_branch":"develop","merge_policy":"manual","sync_policy":"none"}'

echo "--- U1: uat_policy emitted when supplied ---"
OUT=$(branch_directive_generate "$UAT_EPIC_JSON")
if echo "$OUT" | grep -q '^\*\*UAT Policy:\*\* epic$'; then
  echo "PASS: UAT Policy line emitted"
  PASS=$((PASS + 1))
else
  echo "FAIL: UAT Policy line missing from output"
  echo "$OUT"
  FAIL=$((FAIL + 1))
fi

echo "--- U2: field omitted entirely when not supplied ---"
OUT=$(branch_directive_generate "$UAT_ABSENT_JSON")
if echo "$OUT" | grep -q 'UAT Policy'; then
  echo "FAIL: UAT Policy emitted although not requested — pre-existing epics must be byte-identical"
  FAIL=$((FAIL + 1))
else
  echo "PASS: no UAT Policy line when unset"
  PASS=$((PASS + 1))
fi

echo "--- U3: invalid value rejected with no output ---"
OUT=$(branch_directive_generate "$UAT_BAD_JSON" 2>/dev/null) && rc=0 || rc=$?
if [ "$rc" -ne 0 ] && [ -z "$OUT" ]; then
  echo "PASS: invalid uat_policy rejected (rc=$rc, no output)"
  PASS=$((PASS + 1))
else
  echo "FAIL: invalid uat_policy accepted (rc=$rc, output='$OUT')"
  FAIL=$((FAIL + 1))
fi

echo "--- U4: generated epic-policy block round-trips through the validator ---"
if declare -f check_branch_directive_description >/dev/null 2>&1; then
  UAT_OUTPUT=$(branch_directive_generate "$UAT_EPIC_JSON")
  FULL_DESC="# Epic: Debt Collection

Some description text.

${UAT_OUTPUT}"
  PARSED=$(check_branch_directive_description "$FULL_DESC" 2>/dev/null) && rc=0 || rc=$?
  RESOLVED=$(echo "$PARSED" | sed -n "s/^BRANCH_DIRECTIVE_UAT_POLICY='\\(.*\\)'$/\\1/p")
  if [ "$rc" -eq 0 ] && [ "$RESOLVED" = "epic" ]; then
    echo "PASS: round-trip resolves UAT_POLICY=epic"
    PASS=$((PASS + 1))
  else
    echo "FAIL: round-trip rc=$rc resolved='$RESOLVED'"
    FAIL=$((FAIL + 1))
  fi
else
  echo "SKIP: validator not available"
fi

echo "--- U5: per-ticket round-trips as per-ticket ---"
if declare -f check_branch_directive_description >/dev/null 2>&1; then
  UAT_OUTPUT=$(branch_directive_generate "$UAT_PER_TICKET_JSON")
  PARSED=$(check_branch_directive_description "$UAT_OUTPUT" 2>/dev/null) && rc=0 || rc=$?
  RESOLVED=$(echo "$PARSED" | sed -n "s/^BRANCH_DIRECTIVE_UAT_POLICY='\\(.*\\)'$/\\1/p")
  if [ "$rc" -eq 0 ] && [ "$RESOLVED" = "per-ticket" ]; then
    echo "PASS: round-trip resolves UAT_POLICY=per-ticket"
    PASS=$((PASS + 1))
  else
    echo "FAIL: round-trip rc=$rc resolved='$RESOLVED'"
    FAIL=$((FAIL + 1))
  fi
else
  echo "SKIP: validator not available"
fi

echo "--- U6: omitted field round-trips to the per-ticket default ---"
if declare -f check_branch_directive_description >/dev/null 2>&1; then
  UAT_OUTPUT=$(branch_directive_generate "$UAT_ABSENT_JSON")
  PARSED=$(check_branch_directive_description "$UAT_OUTPUT" 2>/dev/null) && rc=0 || rc=$?
  RESOLVED=$(echo "$PARSED" | sed -n "s/^BRANCH_DIRECTIVE_UAT_POLICY='\\(.*\\)'$/\\1/p")
  if [ "$rc" -eq 0 ] && [ "$RESOLVED" = "per-ticket" ]; then
    echo "PASS: absent field resolves to per-ticket"
    PASS=$((PASS + 1))
  else
    echo "FAIL: rc=$rc resolved='$RESOLVED'"
    FAIL=$((FAIL + 1))
  fi
else
  echo "SKIP: validator not available"
fi

# ── Summary ───────────────────────────────────────────────────────────────────

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] && echo "All generator tests passed." || echo "Some tests FAILED."
exit "$FAIL"
