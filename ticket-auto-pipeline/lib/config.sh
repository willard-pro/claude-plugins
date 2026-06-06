#!/usr/bin/env bash
# Centralized configuration for ticket-auto-pipeline.
# Source from any script that needs pipeline constants.
# All values have env var overrides — defaults match historical hardcoded values.

# ── Linear API ────────────────────────────────────────────────────────────────

# Retry delays in seconds (space-separated). One retry per value.
LINEAR_RETRY_DELAYS="${LINEAR_RETRY_DELAYS:-1 2 4}"
# Maximum retry attempts (derived from delay count, but can be overridden).
LINEAR_MAX_RETRIES="${LINEAR_MAX_RETRIES:-3}"

# ── Pipeline limits ───────────────────────────────────────────────────────────

MAX_VERIFY_ATTEMPTS="${MAX_VERIFY_ATTEMPTS:-3}"
MAX_BATCH_TICKETS="${MAX_BATCH_TICKETS:-10}"
MAX_PR_ITERATIONS="${MAX_PR_ITERATIONS:-3}"

# ── Default credentials ───────────────────────────────────────────────────────

UAT_TEST_PASSWORD="${UAT_TEST_PASSWORD:-admin}"

# ── Paths ─────────────────────────────────────────────────────────────────────

PIPELINE_LOGS_DIR="${PIPELINE_LOGS_DIR:-./logs}"
SENTINEL_DIR="${SENTINEL_DIR:-./logs}"

# Pipeline log directory scanned by fleet controller. Override when pipeline
# logs live in a different directory than the fleet controller's own logs.
# Defaults to PIPELINE_LOGS_DIR, then ./logs as final fallback.
FLEET_PIPELINE_LOG_DIR="${FLEET_PIPELINE_LOG_DIR:-${PIPELINE_LOGS_DIR:-./logs}}"

# ── Git defaults ──────────────────────────────────────────────────────────────

BASE_BRANCH="${BASE_BRANCH:-develop}"
BRANCH_PREFIX="${BRANCH_PREFIX:-feat/}"

# ── Fleet controller ────────────────────────────────────────────────────────────

# Instance identity — derived from git remote when available, falls back to PWD basename.
# Env override: FLEET_INSTANCE_ID
if [ -z "${FLEET_INSTANCE_ID:-}" ]; then
  _fleet_git_root=$(git rev-parse --show-toplevel 2>/dev/null || true)
  if [ -n "$_fleet_git_root" ]; then
    _fleet_git_remote=$(git -C "$_fleet_git_root" remote get-url origin 2>/dev/null || true)
    if [ -n "$_fleet_git_remote" ]; then
      # github.com:owner/repo.git → owner-repo
      FLEET_INSTANCE_ID=$(echo "$_fleet_git_remote" | sed 's|.*[:/]\([^/]*/[^/]*\)\.git.*|\1|' | tr '/' '-')
    fi
  fi
  FLEET_INSTANCE_ID="${FLEET_INSTANCE_ID:-$(basename "$PWD")}"
fi

# Debug flag — enables verbose logging when true.
FLEET_DEBUG="${FLEET_DEBUG:-false}"

# Log file paths for fleet controller output.
FLEET_HB_LOG_FILE="${FLEET_HB_LOG_FILE:-./logs/fleet-controller-heartbeat.log}"
FLEET_LOG_FILE="${FLEET_LOG_FILE:-./logs/fleet-controller.log}"

# Number of monitor cycles between full summary reports.
FLEET_SUMMARY_INTERVAL_CYCLES="${FLEET_SUMMARY_INTERVAL_CYCLES:-10}"

# Polling interval in seconds for monitor mode loop.
FLEET_POLL_INTERVAL="${FLEET_POLL_INTERVAL:-30}"

# Stall detection thresholds (seconds since last heartbeat).
# Escalation: WARN → KILL → KILL+RESTART
FLEET_STALL_WARN_SECS="${FLEET_STALL_WARN_SECS:-300}"
FLEET_STALL_KILL_SECS="${FLEET_STALL_KILL_SECS:-900}"
FLEET_STALL_RESTART_SECS="${FLEET_STALL_RESTART_SECS:-1800}"

# Abandonment detection thresholds (hours since last pipeline activity).
FLEET_ABANDON_WARN_HOURS="${FLEET_ABANDON_WARN_HOURS:-1}"
FLEET_ABANDON_KILL_HOURS="${FLEET_ABANDON_KILL_HOURS:-4}"

# Max automatic restarts before giving up. Restart loop circuit breaker.
FLEET_MAX_RESTARTS="${FLEET_MAX_RESTARTS:-2}"

# Auto-restart toggle — defaults to false (must opt in).
# When false, KILL+RESTART degrades to KILL with a logged reason.
FLEET_AUTO_RESTART="${FLEET_AUTO_RESTART:-false}"

# Maximum age of pipeline logs to scan (in hours). Logs whose mtime exceeds
# this threshold are skipped. Empty/unset = no filter (all logs scanned).
# Setting to 0 excludes ALL logs (age always > 0). Operators should leave
# empty to disable the filter, not set it to 0.
FLEET_MAX_LOG_AGE_HOURS="${FLEET_MAX_LOG_AGE_HOURS:-}"

# Tool error capture — dedup window in seconds. Same tool+error_type on the
# same ticket within this window produces at most one log entry.
TOOL_ERROR_DEDUP_WINDOW="${TOOL_ERROR_DEDUP_WINDOW:-300}"

# Tool error detector — dedup window in seconds. Errors with the same
# TOOL_NAME|ERROR_TYPE key separated by less than this window count as one.
FLEET_TOOL_ERROR_WINDOW="${FLEET_TOOL_ERROR_WINDOW:-300}"

# ── Conventions for lib/ scripts ────────────────────────────────────────────────
# Temp files: always pair mktemp with trap cleanup:
#   TEMP_FILE=$(mktemp)
#   trap 'rm -f "$TEMP_FILE"' EXIT
# JSON construction: use jq -n --arg, never sed escaping or string concatenation.
# Pipe-delimited logs: validate free-text fields contain no | characters.
