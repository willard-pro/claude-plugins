#!/usr/bin/env bash
# test-branch-directive-check.sh — unit tests for lib/branch-directive-check.sh
# Usage: bash test-branch-directive-check.sh [test_name_filter]
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

# Source planned-ticket-check.sh first — provides _extract_md_section and _extract_field
source "$LIB_DIR/planned-ticket-check.sh"
source "$LIB_DIR/branch-directive-check.sh"

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

_run_exit_code_stderr() {
  # Like _run_exit_code but allows stderr (injection cases produce error messages)
  local name="$1"
  local expected="$2"
  shift 2
  local actual=0
  "$@" 2>/tmp/bdc-test-stderr.txt || actual=$?
  if [ "$actual" -eq "$expected" ]; then
    echo "PASS: $name (exit $actual)"
    ((PASS++)) || true
  else
    echo "FAIL: $name (expected exit $expected, got $actual)"
    echo "  stderr: $(cat /tmp/bdc-test-stderr.txt)"
    ((FAIL++)) || true
  fi
}

# ── Fixtures ────────────────────────────────────────────────────────────────

VALID_BLOCK_DESC='## Branch Directive
**Schema-Version:** 1
**Branch:** epic/debt-collection-v2
**Base:** develop
**Merge Policy:** manual
**Sync Policy:** rebase-on-base-change
**Created:** 2026-07-25T10:00:00Z'

NO_DIRECTIVE_DESC='Some ticket body without a Branch Directive block.
## Other Section
Some other content.'

MISSING_FIELDS_DESC='## Branch Directive
**Schema-Version:** 1
**Branch:** epic/my-feature
**Base:** develop
**Merge Policy:** manual
Missing Sync Policy and Created.'

BAD_ENUM_DESC='## Branch Directive
**Schema-Version:** 1
**Branch:** epic/my-feature
**Base:** develop
**Merge Policy:** auto
**Sync Policy:** rebase-on-base-change
**Created:** 2026-07-25T10:00:00Z'

NON_INTEGER_VERSION_DESC='## Branch Directive
**Schema-Version:** one
**Branch:** epic/my-feature
**Base:** develop
**Merge Policy:** manual
**Sync Policy:** rebase-on-base-change
**Created:** 2026-07-25T10:00:00Z'

# ── UAT Policy fixtures (optional field) ─────────────────────────────────────

UAT_EPIC_DESC='## Branch Directive
**Schema-Version:** 2
**Branch:** epic/debt-collection-v2
**Base:** develop
**Merge Policy:** manual
**Sync Policy:** rebase-on-base-change
**UAT Policy:** epic
**Created:** 2026-07-25T10:00:00Z'

UAT_PER_TICKET_DESC='## Branch Directive
**Schema-Version:** 2
**Branch:** epic/debt-collection-v2
**Base:** develop
**Merge Policy:** manual
**Sync Policy:** rebase-on-base-change
**UAT Policy:** per-ticket
**Created:** 2026-07-25T10:00:00Z'

UAT_BAD_VALUE_DESC='## Branch Directive
**Schema-Version:** 2
**Branch:** epic/debt-collection-v2
**Base:** develop
**Merge Policy:** manual
**Sync Policy:** rebase-on-base-change
**UAT Policy:** team
**Created:** 2026-07-25T10:00:00Z'

# The migration case: the field hand-added to a directive still declaring the
# schema version that predates it. Presence must bind; version must not gate.
UAT_OLD_SCHEMA_DESC='## Branch Directive
**Schema-Version:** 1
**Branch:** epic/debt-collection-v2
**Base:** develop
**Merge Policy:** manual
**Sync Policy:** rebase-on-base-change
**UAT Policy:** epic
**Created:** 2026-07-25T10:00:00Z'

BAD_BRANCH_DESC='## Branch Directive
**Schema-Version:** 1
**Branch:** ../escape/develop
**Base:** develop
**Merge Policy:** manual
**Sync Policy:** rebase-on-base-change
**Created:** 2026-07-25T10:00:00Z'

# ── 3.8: Core validation tests ──────────────────────────────────────────────

echo "=== Core validation tests ==="
echo ""

# Valid block → exit 0 with correct parsed values
_run_exit_code "valid block exits 0" 0 \
  check_branch_directive_description "$VALID_BLOCK_DESC"

# Verify parsed values are emitted on exit 0
test_valid_parsed_values() {
  local output
  output=$(check_branch_directive_description "$VALID_BLOCK_DESC" 2>/dev/null) || return 1
  echo "$output" | grep -q "BRANCH_DIRECTIVE_BRANCH='epic/debt-collection-v2'" || return 1
  echo "$output" | grep -q "BRANCH_DIRECTIVE_BASE='develop'" || return 1
  echo "$output" | grep -q "BRANCH_DIRECTIVE_MERGE_POLICY='manual'" || return 1
  echo "$output" | grep -q "BRANCH_DIRECTIVE_SYNC_POLICY='rebase-on-base-change'" || return 1
  echo "$output" | grep -q "BRANCH_DIRECTIVE_CREATED='2026-07-25T10:00:00Z'" || return 1
  return 0
}
_run "valid block emits parsed values" test_valid_parsed_values

# Absent section → exit 1
_run_exit_code "absent section exits 1" 1 \
  check_branch_directive_description "$NO_DIRECTIVE_DESC"

# Missing fields → exit 2
_run_exit_code "missing fields exit 2" 2 \
  check_branch_directive_description "$MISSING_FIELDS_DESC"

# Bad enum → exit 2
_run_exit_code "bad enum exit 2" 2 \
  check_branch_directive_description "$BAD_ENUM_DESC"

# Non-integer version → exit 2
_run_exit_code "non-integer version exit 2" 2 \
  check_branch_directive_description "$NON_INTEGER_VERSION_DESC"

# Bad branch name (..) → exit 2
_run_exit_code "bad branch name (..) exit 2" 2 \
  check_branch_directive_description "$BAD_BRANCH_DESC"

# Future Schema-Version → exit 0 + warn on stderr
test_future_version() {
  local desc='## Branch Directive
**Schema-Version:** 99
**Branch:** epic/my-feature
**Base:** develop
**Merge Policy:** manual
**Sync Policy:** none
**Created:** 2026-07-25T10:00:00Z'
  local output
  # Capture both stdout and stderr
  output=$(check_branch_directive_description "$desc" 2>&1) || return 1
  # Should produce warning on stderr about version
  echo "$output" | grep -q "tolerance" || return 1
  return 0
}
_run "future Schema-Version warns and exits 0" test_future_version

# Empty description
_run_exit_code "empty description exits 1" 1 \
  check_branch_directive_description ""

echo ""
echo "=== Injection tests ==="
echo ""

# ── 3.9: Injection cases ────────────────────────────────────────────────────

INJECTION_BASE='## Branch Directive
**Schema-Version:** 1
**Branch:** %s
**Base:** develop
**Merge Policy:** manual
**Sync Policy:** none
**Created:** 2026-07-25T10:00:00Z'

test_injection() {
  local label="$1"
  local bad_branch="$2"
  local desc
  desc=$(printf "$INJECTION_BASE" "$bad_branch")
  local actual=0
  check_branch_directive_description "$desc" 2>/dev/null || actual=$?
  [ "$actual" -eq 2 ] || {
    echo "  branch: '$bad_branch'" >&2
    return 1
  }
  return 0
}

_run "injection: .. traversal" \
  test_injection "dotdot" "../escape/develop"

_run "injection: leading /" \
  test_injection "lead-slash" "/absolute/path"

_run "injection: embedded ;" \
  test_injection "semicolon" "safe;rm -rf /"

_run "injection: backtick" \
  test_injection "backtick" 'safe`id`'

_run "injection: \$()" \
  test_injection "dollar-subshell" 'safe$(id)'

# Newline in field value: _extract_field is line-based, so the newline truncates.
# If the pre-newline part is a valid branch name, validation passes. If empty,
# the field is treated as missing → exit 2.
test_newline_valid() {
  local desc
  desc=$(printf "$INJECTION_BASE" $'safe\nmalicious')
  # Pre-newline value is "safe" → valid branch name → exit 0
  check_branch_directive_description "$desc" 2>/dev/null || return 1
  return 0
}
_run "injection: newline (truncates to valid)" test_newline_valid

test_newline_empty() {
  local desc
  desc=$(printf "$INJECTION_BASE" $'\nmalicious')
  # Pre-newline value is empty → missing field → exit 2
  local actual=0
  check_branch_directive_description "$desc" 2>/dev/null || actual=$?
  [ "$actual" -eq 2 ] || {
    echo "  got exit $actual" >&2
    return 1
  }
  return 0
}
_run "injection: newline at start (empty field → exit 2)" test_newline_empty

_run "injection: whitespace" \
  test_injection "space" "has space"

_run "injection: tab" \
  test_injection "tab" $'has\ttab'

_run "injection: pipe" \
  test_injection "pipe" "safe|cat /etc/passwd"

_run "injection: redirect" \
  test_injection "redirect" "safe>/etc/passwd"

_run "injection: trailing /" \
  test_injection "trailing-slash" "trailing/"

echo ""
echo "=== edge cases ==="
echo ""

# Merge Policy = on-all-children-done
test_merge_policy_children() {
  local desc='## Branch Directive
**Schema-Version:** 1
**Branch:** epic/my-feature
**Base:** main
**Merge Policy:** on-all-children-done
**Sync Policy:** none
**Created:** 2026-07-25T10:00:00Z'
  check_branch_directive_description "$desc" 2>/dev/null || return 1
  return 0
}
_run "merge policy on-all-children-done valid" test_merge_policy_children

# Sync Policy = none
test_sync_policy_none() {
  local desc='## Branch Directive
**Schema-Version:** 1
**Branch:** epic/my-feature
**Base:** main
**Merge Policy:** manual
**Sync Policy:** none
**Created:** 2026-07-25T10:00:00Z'
  check_branch_directive_description "$desc" 2>/dev/null || return 1
  return 0
}
_run "sync policy none valid" test_sync_policy_none

# Base different from develop
test_base_main() {
  local desc='## Branch Directive
**Schema-Version:** 1
**Branch:** epic/hotfix
**Base:** main
**Merge Policy:** manual
**Sync Policy:** rebase-on-base-change
**Created:** 2026-07-25T10:00:00Z'
  local output
  output=$(check_branch_directive_description "$desc" 2>/dev/null) || return 1
  echo "$output" | grep -q "BRANCH_DIRECTIVE_BASE='main'" || return 1
  return 0
}
_run "base can be main" test_base_main

# CHECK_RESULT variable is set
test_check_result_var() {
  local desc='## Branch Directive
**Schema-Version:** 1
**Branch:** epic/test
**Base:** develop
**Merge Policy:** manual
**Sync Policy:** none
**Created:** 2026-07-25T10:00:00Z'
  check_branch_directive_description "$desc" 2>/dev/null
  [ "$CHECK_RESULT" = "valid" ] || return 1
  [ "$CHECK_EXIT_CODE" -eq 0 ] || return 1
  return 0
}
_run "CHECK_RESULT set to valid on success" test_check_result_var

test_check_result_absent() {
  check_branch_directive_description "$NO_DIRECTIVE_DESC" 2>/dev/null || true
  [ "$CHECK_RESULT" = "absent" ] || {
    echo "  got CHECK_RESULT=$CHECK_RESULT" >&2
    return 1
  }
  [ "$CHECK_EXIT_CODE" -eq 1 ] || {
    echo "  got CHECK_EXIT_CODE=$CHECK_EXIT_CODE" >&2
    return 1
  }
  return 0
}
_run "CHECK_RESULT set to absent" test_check_result_absent

test_check_result_malformed() {
  check_branch_directive_description "$BAD_ENUM_DESC" 2>/dev/null || true
  [ "$CHECK_RESULT" = "malformed" ] || {
    echo "  got CHECK_RESULT=$CHECK_RESULT" >&2
    return 1
  }
  [ "$CHECK_EXIT_CODE" -eq 2 ] || {
    echo "  got CHECK_EXIT_CODE=$CHECK_EXIT_CODE" >&2
    return 1
  }
  return 0
}
_run "CHECK_RESULT set to malformed" test_check_result_malformed

# ── UAT Policy tests ─────────────────────────────────────────────────────────

echo ""
echo "=== UAT Policy tests ==="
echo ""

# _uat_policy_of <description> — echoes the emitted BRANCH_DIRECTIVE_UAT_POLICY.
_uat_policy_of() {
  check_branch_directive_description "$1" 2>/dev/null |
    sed -n "s/^BRANCH_DIRECTIVE_UAT_POLICY='\\(.*\\)'$/\\1/p"
}

test_uat_policy_absent_defaults_to_per_ticket() {
  local got
  got=$(_uat_policy_of "$VALID_BLOCK_DESC")
  [ "$got" = "per-ticket" ] || {
    echo "  expected per-ticket, got '$got'" >&2
    return 1
  }
  return 0
}
_run "UAT Policy absent defaults to per-ticket" test_uat_policy_absent_defaults_to_per_ticket

test_uat_policy_absent_still_valid() {
  check_branch_directive_description "$VALID_BLOCK_DESC" >/dev/null 2>&1 || {
    echo "  directive without UAT Policy must remain valid" >&2
    return 1
  }
  return 0
}
_run "UAT Policy is optional — pre-existing directive still validates" test_uat_policy_absent_still_valid

test_uat_policy_epic_parsed() {
  local got
  got=$(_uat_policy_of "$UAT_EPIC_DESC")
  [ "$got" = "epic" ] || {
    echo "  expected epic, got '$got'" >&2
    return 1
  }
  return 0
}
_run "UAT Policy: epic is parsed" test_uat_policy_epic_parsed

test_uat_policy_per_ticket_parsed() {
  local got
  got=$(_uat_policy_of "$UAT_PER_TICKET_DESC")
  [ "$got" = "per-ticket" ] || {
    echo "  expected per-ticket, got '$got'" >&2
    return 1
  }
  return 0
}
_run "UAT Policy: per-ticket is parsed" test_uat_policy_per_ticket_parsed

test_uat_policy_invalid_is_malformed() {
  local rc=0
  check_branch_directive_description "$UAT_BAD_VALUE_DESC" >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 2 ] || {
    echo "  expected exit 2 (malformed) for invalid value, got $rc" >&2
    return 1
  }
  return 0
}
_run "UAT Policy invalid value exits malformed" test_uat_policy_invalid_is_malformed

test_uat_policy_takes_effect_under_older_schema_version() {
  # Presence binds, version does not gate. If this regresses, an operator who
  # hand-adds the field without bumping Schema-Version gets silence.
  local got
  got=$(_uat_policy_of "$UAT_OLD_SCHEMA_DESC")
  [ "$got" = "epic" ] || {
    echo "  field ignored under older declared schema version, got '$got'" >&2
    return 1
  }
  return 0
}
_run "UAT Policy takes effect under an older declared schema version" test_uat_policy_takes_effect_under_older_schema_version

# ── Results ──────────────────────────────────────────────────────────────────

echo ""
echo "=== Results: $((PASS + FAIL)) tests, $PASS passed, $FAIL failed ==="

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
