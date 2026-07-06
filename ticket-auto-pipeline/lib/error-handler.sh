#!/usr/bin/env bash
# error-handler.sh — unified error handling for ticket-auto-pipeline bash libraries.
# Source this file to get standard error codes and error reporting functions.
# Shell flags intentionally NOT set here — this is a sourceable library matching
# the heartbeat.sh convention. Callers that want strict mode set it themselves.
#
# Error code ranges:
#   0         Success
#   1-9       Standard shell / caller-specific exit codes
#   10-19     Pipeline error codes (reserved)
#   20+       Script-specific error codes

# Standard pipeline error codes
E_LINEAR_API=10
E_GITHUB_API=11
E_ENV=12
E_GATE=13
E_FLOW=14
E_ASSERTION=15

# Source heartbeat.sh for cl_write (used to write to CLAUDE_LOG_FILE)
# Guard against double-sourcing — cl_write may already be defined.
if ! declare -f cl_write >/dev/null 2>&1; then
  _EH_HEARTBEAT_LIB="$(dirname "${BASH_SOURCE[0]}")/heartbeat.sh"
  if [ -f "$_EH_HEARTBEAT_LIB" ]; then
    source "$_EH_HEARTBEAT_LIB"
  fi
fi

# ── error_exit ──────────────────────────────────────────────────────────────
# Log the error via cl_write and exit with the given code.
# Usage: error_exit <code> <msg>
error_exit() {
  local code="$1"
  local msg="${2:-unknown error}"
  if declare -f cl_write >/dev/null 2>&1 && [ -n "${CLAUDE_LOG_FILE:-}" ]; then
    cl_write "META" "error" "fail" "[${code}] ${msg}"
  fi
  echo "ERROR [${code}]: ${msg}" >&2
  exit "$code"
}

# ── error_return ────────────────────────────────────────────────────────────
# Log the error via cl_write and return the given code.
# Usage: error_return <code> <msg>
error_return() {
  local code="$1"
  local msg="${2:-unknown error}"
  if declare -f cl_write >/dev/null 2>&1 && [ -n "${CLAUDE_LOG_FILE:-}" ]; then
    cl_write "META" "error" "fail" "[${code}] ${msg}"
  fi
  echo "ERROR [${code}]: ${msg}" >&2
  return "$code"
}

# ── error_warn ──────────────────────────────────────────────────────────────
# Log a warning via cl_write and continue execution.
# Usage: error_warn <msg>
error_warn() {
  local msg="${1:-unknown warning}"
  if declare -f cl_write >/dev/null 2>&1 && [ -n "${CLAUDE_LOG_FILE:-}" ]; then
    cl_write "META" "warn" "warn" "${msg}"
  fi
  echo "WARN: ${msg}" >&2
}
