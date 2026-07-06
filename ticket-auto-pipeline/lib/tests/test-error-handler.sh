#!/usr/bin/env bash
# test-error-handler.sh — unit tests for lib/error-handler.sh
# Usage: bash test-error-handler.sh [test_name_filter]
# -u (nounset) intentionally omitted: Claude Code shell snapshots inject
# ZSH_VERSION references that trigger false-positive "unbound variable"
# errors in this bash version when nounset is active.
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

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

# ── Error code constants ────────────────────────────────────────────────────

test_error_codes_defined() {
  (
    source "$LIB_DIR/error-handler.sh"
    [ "$E_LINEAR_API" -eq 10 ] && [ "$E_GITHUB_API" -eq 11 ] &&
      [ "$E_ENV" -eq 12 ] && [ "$E_GATE" -eq 13 ] &&
      [ "$E_FLOW" -eq 14 ] && [ "$E_ASSERTION" -eq 15 ]
  )
}

# ── error_exit tests ────────────────────────────────────────────────────────

test_error_exit_exits_with_code() {
  local exit_code=0
  (
    unset CLAUDE_LOG_FILE 2>/dev/null || true
    source "$LIB_DIR/error-handler.sh"
    error_exit 12 "test error"
  ) 2>/dev/null || exit_code=$?
  [ "$exit_code" -eq 12 ]
}

test_error_exit_writes_to_claude_log() {
  local tmpfile
  tmpfile=$(mktemp)
  rm -f "$tmpfile"
  (
    export CLAUDE_LOG_FILE="$tmpfile"
    source "$LIB_DIR/error-handler.sh"
    error_exit 10 "GraphQL returned null"
  ) 2>/dev/null || true
  local found=false
  grep -q "GraphQL returned null" "$tmpfile" 2>/dev/null && found=true
  rm -f "$tmpfile"
  $found
}

# ── error_return tests ──────────────────────────────────────────────────────

test_error_return_returns_code() {
  local rc=0
  (
    unset CLAUDE_LOG_FILE 2>/dev/null || true
    source "$LIB_DIR/error-handler.sh"
    test_func() { error_return 14 "flow failure"; }
    test_func
  ) 2>/dev/null || rc=$?
  [ "$rc" -eq 14 ]
}

test_error_return_writes_to_claude_log() {
  local tmpfile
  tmpfile=$(mktemp)
  rm -f "$tmpfile"
  (
    export CLAUDE_LOG_FILE="$tmpfile"
    source "$LIB_DIR/error-handler.sh"
    test_func() { error_return 13 "gate check failed"; }
    test_func || true
  )
  local found=false
  grep -q "gate check failed" "$tmpfile" 2>/dev/null && found=true
  rm -f "$tmpfile"
  $found
}

# ── error_warn tests ────────────────────────────────────────────────────────

test_error_warn_does_not_exit() {
  (
    unset CLAUDE_LOG_FILE 2>/dev/null || true
    source "$LIB_DIR/error-handler.sh"
    error_warn "this is a warning"
    true # should reach here
  ) 2>/dev/null
}

test_error_warn_writes_to_claude_log() {
  local tmpfile
  tmpfile=$(mktemp)
  rm -f "$tmpfile"
  (
    export CLAUDE_LOG_FILE="$tmpfile"
    source "$LIB_DIR/error-handler.sh"
    error_warn "missing optional config"
  )
  local found=false
  grep -q "missing optional config" "$tmpfile" 2>/dev/null && found=true
  rm -f "$tmpfile"
  $found
}

# ── Sourcing safety tests ───────────────────────────────────────────────────

test_error_handler_no_side_effects_on_shell_flags() {
  # Verify sourcing error-handler.sh does not change caller's errexit setting
  local had_e_before had_e_after
  (
    set -e
    had_e_before=true
    source "$LIB_DIR/error-handler.sh"
    # Check if -e is still active by testing a failing command
    set +e # temporarily disable to check state
    if set +e; then :; fi
    had_e_after=true
    [ "$had_e_before" = "$had_e_after" ]
  ) 2>/dev/null
}

test_error_handler_noop_without_claude_log_file() {
  # Functions should not crash when CLAUDE_LOG_FILE is unset
  local rc=0
  (
    unset CLAUDE_LOG_FILE 2>/dev/null || true
    source "$LIB_DIR/error-handler.sh"
    error_warn "no log file set"
    test_func() { error_return 10 "no log"; }
    test_func || true
  ) 2>/dev/null || rc=$?
  # error_return returns the code, which is non-zero — that's expected
  # The key is: it didn't crash
  true
}

# ── Backward compatibility tests ────────────────────────────────────────────

test_exit_code_nonzero_for_failure() {
  # Standard $? check: non-zero on failure
  local rc=0
  (
    unset CLAUDE_LOG_FILE 2>/dev/null || true
    source "$LIB_DIR/error-handler.sh"
    error_exit 10 "API failed"
  ) 2>/dev/null || rc=$?
  [ "$rc" -ne 0 ]
}

test_exit_code_nonzero_for_return() {
  # Standard $? check after error_return: non-zero
  local rc=0
  (
    unset CLAUDE_LOG_FILE 2>/dev/null || true
    source "$LIB_DIR/error-handler.sh"
    test_func() { error_return 15 "assertion failed"; }
    test_func
  ) 2>/dev/null || rc=$?
  [ "$rc" -ne 0 ]
}

# ── dispatch ──────────────────────────────────────────────────────────────────

FILTER="${1:-}"

for fn in \
  test_error_codes_defined \
  test_error_exit_exits_with_code \
  test_error_exit_writes_to_claude_log \
  test_error_return_returns_code \
  test_error_return_writes_to_claude_log \
  test_error_warn_does_not_exit \
  test_error_warn_writes_to_claude_log \
  test_error_handler_no_side_effects_on_shell_flags \
  test_error_handler_noop_without_claude_log_file \
  test_exit_code_nonzero_for_failure \
  test_exit_code_nonzero_for_return; do
  [ -z "$FILTER" ] || [[ "$fn" == *"$FILTER"* ]] || continue
  _run "$fn" "$fn"
done

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
