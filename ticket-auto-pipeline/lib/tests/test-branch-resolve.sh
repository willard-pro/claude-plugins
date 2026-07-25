#!/usr/bin/env bash
# test-branch-resolve.sh — unit tests for lib/branch-resolve.sh
# Usage: bash test-branch-resolve.sh [test_name_filter]
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# ── CI-safe declare guards ─────────────────────────────────────────────────
if ! declare -f get_issue >/dev/null 2>&1; then
  get_issue() {
    echo "get_issue: CI stub — override in test setup" >&2
    echo '{"data":{"issue":{"title":"Test ticket","parent":null}}}'
  }
fi
if ! declare -f _plog >/dev/null 2>&1; then
  _plog() { :; }
fi
if ! declare -f hb_gate >/dev/null 2>&1; then
  hb_gate() { :; }
fi
if ! declare -f check_branch_directive_description >/dev/null 2>&1; then
  check_branch_directive_description() {
    # Stub: no directive present
    CHECK_EXIT_CODE=1
    CHECK_RESULT="absent"
    return 1
  }
fi

source "$LIB_DIR/config.sh"
source "$LIB_DIR/planned-ticket-check.sh"
source "$LIB_DIR/branch-directive-check.sh"
source "$LIB_DIR/branch-resolve.sh"

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

# ── Helpers ──────────────────────────────────────────────────────────────────

# Parse a BRANCH_CONTEXT_RESULT block from stdin, emit shell variables
_parse_result() {
  local block
  block=$(cat)
  echo "$block" | while IFS= read -r line; do
    case "$line" in
    "BRANCH_CONTEXT_RESULT") ;;
    "END_BRANCH_CONTEXT_RESULT") ;;
    *)
      local key
      key=$(echo "$line" | sed -n 's/^[[:space:]]*\([A-Z_]*\):[[:space:]]*\(.*\)$/\1/p')
      local val
      val=$(echo "$line" | sed -n 's/^[[:space:]]*\([A-Z_]*\):[[:space:]]*\(.*\)$/\2/p')
      [ -n "$key" ] && echo "${key}='${val}'"
      ;;
    esac
  done
}

# ── Fixtures ────────────────────────────────────────────────────────────────

VALID_DIRECTIVE_PARENT='{
  "id": "CRE-100",
  "description": "## Branch Directive\n**Schema-Version:** 1\n**Branch:** epic/debt-collection-v2\n**Base:** develop\n**Merge Policy:** manual\n**Sync Policy:** rebase-on-base-change\n**Created:** 2026-07-25T10:00:00Z"
}'

MALFORMED_DIRECTIVE_PARENT='{
  "id": "CRE-100",
  "description": "## Branch Directive\n**Schema-Version:** 1\n**Branch:** epic/bad\n**Merge Policy:** manual"
}'

NO_DIRECTIVE_PARENT='{
  "id": "CRE-200",
  "description": "Just a regular epic description."
}'

echo "=== Precedence tests ==="
echo ""

# ── 5.7: Precedence chain ───────────────────────────────────────────────────

# Flag beats directive
test_flag_beats_directive() {
  local output
  output=$(resolve_branch_context "CRE-123" \
    --branch "epic/override-x" \
    --title "Fix auth bug" \
    --parent-json "$VALID_DIRECTIVE_PARENT" 2>/dev/null) || return 1

  local parsed
  parsed=$(echo "$output" | _parse_result)
  eval "$parsed"

  [ "$BRANCH_SOURCE" = "flag" ] || {
    echo "  expected BRANCH_SOURCE=flag, got $BRANCH_SOURCE" >&2
    return 1
  }
  [ "$BASE_BRANCH" = "epic/override-x" ] || {
    echo "  expected BASE_BRANCH=epic/override-x, got $BASE_BRANCH" >&2
    return 1
  }
  [ "$INTEGRATION_BRANCH" = "epic/override-x" ] || {
    echo "  expected INTEGRATION_BRANCH=epic/override-x, got $INTEGRATION_BRANCH" >&2
    return 1
  }
  return 0
}
_run "flag beats directive" test_flag_beats_directive

# Directive beats default
test_directive_beats_default() {
  local output
  output=$(resolve_branch_context "CRE-123" \
    --title "Fix auth bug" \
    --parent-json "$VALID_DIRECTIVE_PARENT" 2>/dev/null) || return 1

  local parsed
  parsed=$(echo "$output" | _parse_result)
  eval "$parsed"

  [ "$BRANCH_SOURCE" = "directive" ] || {
    echo "  expected BRANCH_SOURCE=directive, got $BRANCH_SOURCE" >&2
    return 1
  }
  [ "$BASE_BRANCH" = "develop" ] || {
    echo "  expected BASE_BRANCH=develop, got $BASE_BRANCH" >&2
    return 1
  }
  [ "$INTEGRATION_BRANCH" = "epic/debt-collection-v2" ] || {
    echo "  expected INTEGRATION_BRANCH=epic/debt-collection-v2, got $INTEGRATION_BRANCH" >&2
    return 1
  }
  [ "$EPIC_ID" = "CRE-100" ] || {
    echo "  expected EPIC_ID=CRE-100, got $EPIC_ID" >&2
    return 1
  }
  return 0
}
_run "directive beats default" test_directive_beats_default

# No parent → default
test_no_parent_default() {
  local output
  output=$(resolve_branch_context "CRE-123" \
    --title "Fix auth bug" 2>/dev/null) || return 1

  local parsed
  parsed=$(echo "$output" | _parse_result)
  eval "$parsed"

  [ "$BRANCH_SOURCE" = "default" ] || {
    echo "  expected BRANCH_SOURCE=default, got $BRANCH_SOURCE" >&2
    return 1
  }
  [ "$BASE_BRANCH" = "develop" ] || {
    echo "  expected BASE_BRANCH=develop, got $BASE_BRANCH" >&2
    return 1
  }
  [ -z "$INTEGRATION_BRANCH" ] || {
    echo "  expected empty INTEGRATION_BRANCH, got $INTEGRATION_BRANCH" >&2
    return 1
  }
  [ -z "$EPIC_ID" ] || {
    echo "  expected empty EPIC_ID, got $EPIC_ID" >&2
    return 1
  }
  return 0
}
_run "no parent → default" test_no_parent_default

# Parent without directive → default
test_parent_no_directive() {
  local output
  output=$(resolve_branch_context "CRE-123" \
    --title "Fix auth bug" \
    --parent-json "$NO_DIRECTIVE_PARENT" 2>/dev/null) || return 1

  local parsed
  parsed=$(echo "$output" | _parse_result)
  eval "$parsed"

  [ "$BRANCH_SOURCE" = "default" ] || {
    echo "  expected BRANCH_SOURCE=default, got $BRANCH_SOURCE" >&2
    return 1
  }
  [ "$EPIC_ID" = "CRE-200" ] || {
    echo "  expected EPIC_ID=CRE-200, got $EPIC_ID" >&2
    return 1
  }
  return 0
}
_run "parent without directive → default" test_parent_no_directive

# Malformed directive → BRANCH_DIRECTIVE_INVALID and exit non-zero
test_malformed_directive() {
  local output
  local actual=0
  output=$(resolve_branch_context "CRE-123" \
    --title "Fix auth bug" \
    --parent-json "$MALFORMED_DIRECTIVE_PARENT" 2>&1) || actual=$?

  [ "$actual" -ne 0 ] || {
    echo "  expected non-zero exit" >&2
    return 1
  }
  echo "$output" | grep -q "BRANCH_DIRECTIVE_INVALID" || {
    echo "  expected BRANCH_DIRECTIVE_INVALID in output" >&2
    return 1
  }
  return 0
}
_run "malformed directive → BRANCH_DIRECTIVE_INVALID" test_malformed_directive

# Invalid --branch flag → failure
test_invalid_flag() {
  local actual=0
  resolve_branch_context "CRE-123" \
    --branch "../escape" \
    --title "Fix auth" 2>/dev/null || actual=$?

  [ "$actual" -ne 0 ] || {
    echo "  expected non-zero exit" >&2
    return 1
  }
  return 0
}
_run "invalid --branch flag → failure" test_invalid_flag

# --branch with valid branch name works
test_valid_flag() {
  local output
  output=$(resolve_branch_context "CRE-123" \
    --branch "epic/test-x" \
    --title "Fix auth" 2>/dev/null) || return 1

  local parsed
  parsed=$(echo "$output" | _parse_result)
  eval "$parsed"

  [ "$BRANCH_SOURCE" = "flag" ] || return 1
  [ "$BASE_BRANCH" = "epic/test-x" ] || return 1
  [ "$INTEGRATION_BRANCH" = "epic/test-x" ] || return 1
  return 0
}
_run "--branch with valid name works" test_valid_flag

echo ""
echo "=== Output format tests ==="
echo ""

# BRANCH_CONTEXT_RESULT block structure
test_result_block_structure() {
  local output
  output=$(resolve_branch_context "CRE-123" \
    --title "Fix auth bug" 2>/dev/null) || return 1

  echo "$output" | grep -q "BRANCH_CONTEXT_RESULT" || return 1
  echo "$output" | grep -q "END_BRANCH_CONTEXT_RESULT" || return 1
  echo "$output" | grep -q "TICKET_BRANCH:" || return 1
  echo "$output" | grep -q "BASE_BRANCH:" || return 1
  echo "$output" | grep -q "INTEGRATION_BRANCH:" || return 1
  echo "$output" | grep -q "EPIC_ID:" || return 1
  echo "$output" | grep -q "BRANCH_SOURCE:" || return 1
  return 0
}
_run "result block has all required fields" test_result_block_structure

# TICKET_BRANCH follows naming convention
test_ticket_branch_format() {
  local output
  output=$(resolve_branch_context "CRE-123" \
    --title "Fix auth bug" 2>/dev/null) || return 1

  local tb
  tb=$(echo "$output" | sed -n 's/^[[:space:]]*TICKET_BRANCH:[[:space:]]*\(.*\)$/\1/p')
  # Should start with the prefix and contain the ticket ID
  echo "$tb" | grep -q "CRE-123" || {
    echo "  TICKET_BRANCH missing ticket ID: $tb" >&2
    return 1
  }
  [ ${#tb} -le 60 ] || {
    echo "  TICKET_BRANCH exceeds 60 chars: ${#tb}" >&2
    return 1
  }
  return 0
}
_run "TICKET_BRANCH follows naming convention" test_ticket_branch_format

echo ""
echo "=== Determinism tests ==="
echo ""

# ── 5.8: Determinism ────────────────────────────────────────────────────────

test_determinism() {
  local a b
  a=$(resolve_branch_context "CRE-123" \
    --title "Fix auth bug" \
    --parent-json "$VALID_DIRECTIVE_PARENT" 2>/dev/null)
  b=$(resolve_branch_context "CRE-123" \
    --title "Fix auth bug" \
    --parent-json "$VALID_DIRECTIVE_PARENT" 2>/dev/null)

  [ "$a" = "$b" ] || {
    echo "  outputs differ" >&2
    return 1
  }
  return 0
}
_run "determinism: repeated resolution yields identical output" test_determinism

# Determinism with different inputs should differ
test_different_inputs_differ() {
  local a b
  a=$(resolve_branch_context "CRE-123" --title "Fix auth" 2>/dev/null)
  b=$(resolve_branch_context "CRE-456" --title "Fix auth" 2>/dev/null)

  [ "$a" != "$b" ] || {
    echo "  different tickets should produce different output" >&2
    return 1
  }
  return 0
}
_run "different tickets produce different branches" test_different_inputs_differ

echo ""
echo "=== Edge case tests ==="
echo ""

# Ticket with special chars in title
test_special_title_chars() {
  local output
  output=$(resolve_branch_context "CRE-123" \
    --title "Fix: OAuth & JWT tokens (urgent!!!)" 2>/dev/null) || return 1

  local tb
  tb=$(echo "$output" | sed -n 's/^[[:space:]]*TICKET_BRANCH:[[:space:]]*\(.*\)$/\1/p')
  # Should not contain metacharacters
  echo "$tb" | grep -qv '[;&|()!$`<>]' || {
    echo "  TICKET_BRANCH has metacharacters: $tb" >&2
    return 1
  }
  return 0
}
_run "special title chars are slugified" test_special_title_chars

# Very long title is capped
test_long_title_capped() {
  local output
  output=$(resolve_branch_context "CRE-123" \
    --title "Implement comprehensive two-factor authentication with SMS and email fallback for enterprise customers" 2>/dev/null) || return 1

  local tb
  tb=$(echo "$output" | sed -n 's/^[[:space:]]*TICKET_BRANCH:[[:space:]]*\(.*\)$/\1/p')
  [ ${#tb} -le 60 ] || {
    echo "  TICKET_BRANCH too long: ${#tb} chars" >&2
    return 1
  }
  return 0
}
_run "very long title is capped at 60 chars" test_long_title_capped

# Different base branch in directive
test_directive_different_base() {
  local parent='{
    "id": "CRE-300",
    "description": "## Branch Directive\n**Schema-Version:** 1\n**Branch:** epic/hotfix\n**Base:** main\n**Merge Policy:** manual\n**Sync Policy:** none\n**Created:** 2026-07-25T10:00:00Z"
  }'
  local output
  output=$(resolve_branch_context "CRE-789" \
    --title "Hotfix login" \
    --parent-json "$parent" 2>/dev/null) || return 1

  local parsed
  parsed=$(echo "$output" | _parse_result)
  eval "$parsed"

  [ "$BASE_BRANCH" = "main" ] || {
    echo "  expected BASE_BRANCH=main, got $BASE_BRANCH" >&2
    return 1
  }
  [ "$INTEGRATION_BRANCH" = "epic/hotfix" ] || {
    echo "  expected INTEGRATION_BRANCH=epic/hotfix, got $INTEGRATION_BRANCH" >&2
    return 1
  }
  return 0
}
_run "directive with different base branch" test_directive_different_base

echo ""
echo "=== Results: $((PASS + FAIL)) tests, $PASS passed, $FAIL failed ==="

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
