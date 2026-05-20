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

# ── Conventions for lib/ scripts ────────────────────────────────────────────────
# Temp files: always pair mktemp with trap cleanup:
#   TEMP_FILE=$(mktemp)
#   trap 'rm -f "$TEMP_FILE"' EXIT
# JSON construction: use jq -n --arg, never sed escaping or string concatenation.
# Pipe-delimited logs: validate free-text fields contain no | characters.
