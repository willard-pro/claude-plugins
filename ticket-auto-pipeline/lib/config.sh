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

# ── Git defaults ──────────────────────────────────────────────────────────────

BASE_BRANCH="${BASE_BRANCH:-develop}"
BRANCH_PREFIX="${BRANCH_PREFIX:-feat/}"

# ── Fleet controller ────────────────────────────────────────────────────────────
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

# ── Conventions for lib/ scripts ────────────────────────────────────────────────
# Temp files: always pair mktemp with trap cleanup:
#   TEMP_FILE=$(mktemp)
#   trap 'rm -f "$TEMP_FILE"' EXIT
# JSON construction: use jq -n --arg, never sed escaping or string concatenation.
# Pipe-delimited logs: validate free-text fields contain no | characters.
