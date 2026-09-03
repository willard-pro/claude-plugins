#!/usr/bin/env bash
# fleet-store.sh — read-only bash access to the fleet state store.
#
# The store (fleetd/store.py, schema at fleetd/schema.sql) has exactly one
# writer: the fleetd supervisor. Everything on the bash side — detection
# engines, dashboards, hooks — reads through this file, and reads through
# `sqlite3 -readonly`, so a crashed or hung reader can neither corrupt the
# database nor take a lock the writer needs.
#
# Every function degrades to "no store" rather than failing: the store may be
# absent because fleetd has never run here, because sqlite3 is not installed,
# or because someone deleted it to force a rebuild. Callers use
# `fleet_store_ready` to choose their input and keep their existing file-based
# path as the fallback — which is also what keeps the manual pipeline working
# on a host with no fleet-controller at all.
#
# NOTE: Does NOT set -euo pipefail — this is a sourceable library.

# Source config for the state-dir resolver, unless a caller already loaded it.
if ! declare -f _fleet_state_dir >/dev/null 2>&1; then
  _FLEET_STORE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  [ -f "$_FLEET_STORE_DIR/fleet-config.sh" ] && source "$_FLEET_STORE_DIR/fleet-config.sh"
fi

FLEET_STORE_DB_NAME="${FLEET_STORE_DB_NAME:-fleet-state.db}"

# Path to the database. Lives beside the rest of fleet's durable state, so it
# inherits FLEET_STATE_DIR's reboot-surviving lifecycle instead of inventing
# a second one.
# Usage: _fleet_store_path [workspace]
_fleet_store_path() {
  local workspace="${1:-${FLEET_PIPELINE_LOG_DIR:-./logs}}"
  local dir
  if declare -f _fleet_state_dir >/dev/null 2>&1; then
    dir=$(_fleet_state_dir "$workspace")
  else
    dir="${FLEET_STATE_DIR:-$workspace}"
  fi
  echo "${dir}/${FLEET_STORE_DB_NAME}"
}

# True when the store can actually be read. Callers branch on this rather than
# assuming, because "no store" is a normal state, not an error.
# Usage: fleet_store_ready [workspace]
fleet_store_ready() {
  [ "${FLEET_STORE_ENABLE:-true}" = "true" ] || return 1
  command -v sqlite3 >/dev/null 2>&1 || return 1
  local db
  db=$(_fleet_store_path "${1:-}")
  [ -f "$db" ] && [ -s "$db" ]
}

# Ticket ids reach an SQL string, so they are validated rather than escaped.
# Linear identifiers are [A-Z]+-[0-9]+; the pattern here is deliberately a
# little wider to cover test fixtures, and rejects everything else.
_fleet_store_safe_tid() {
  case "$1" in
  '' | *[!A-Za-z0-9_-]*) return 1 ;;
  esac
  return 0
}

# Run a read-only query. Prints nothing and returns non-zero when the store is
# unavailable, so `|| true` style callers see an empty result, not an error.
# Usage: fleet_store_sql <sql> [workspace]
fleet_store_sql() {
  local sql="$1"
  local workspace="${2:-}"
  fleet_store_ready "$workspace" || return 1
  local db
  db=$(_fleet_store_path "$workspace")
  sqlite3 -readonly -batch "$db" "$sql" 2>/dev/null
}

# Pipeline-log lines for a ticket, in `grep -n` shape (`lineno:line`) so a
# caller can swap this in for `grep -n '' file` without changing how it parses.
#
# This is the migration seam for the detection engines: their filtering,
# thresholds and severities are untouched, only where the lines come from
# changes. The rows were parsed once at ingest instead of re-parsed on every
# sweep — which is the actual cost the store removes.
#
# Reassembled as a single column so a `|` inside MSG cannot be mistaken for a
# column separator.
# Usage: fleet_store_pipeline_rows <tid> [workspace]
fleet_store_pipeline_rows() {
  local tid="$1" workspace="${2:-}"
  _fleet_store_safe_tid "$tid" || return 1
  fleet_store_sql "SELECT line_no || ':' || iso || '|' || phase || '|' || step \
|| '|' || status || '|' || msg FROM log_events WHERE tid = '${tid}' \
ORDER BY line_no;" "$workspace"
}

# Ownership: 'fleetd', 'manual', or empty when the ticket is unknown to the
# store. Severity >= 2 intervention keys on this — a human running the
# pipeline by hand writes to the same logs the detectors read, so log presence
# is not evidence of ownership.
# Usage: fleet_store_owner <tid> [workspace]
fleet_store_owner() {
  local tid="$1" workspace="${2:-}"
  _fleet_store_safe_tid "$tid" || return 1
  fleet_store_sql "SELECT owner FROM tickets WHERE tid = '${tid}';" "$workspace"
}

# Usage: fleet_store_is_owned <tid> [workspace] — returns 0 when fleetd owns it.
fleet_store_is_owned() {
  local tid="$1" workspace="${2:-}"
  _fleet_store_safe_tid "$tid" || return 1
  local owned
  owned=$(fleet_store_sql "SELECT 1 FROM tickets WHERE tid = '${tid}' \
AND owner = 'fleetd' UNION SELECT 1 FROM workers WHERE tid = '${tid}' \
AND status = 'running' LIMIT 1;" "$workspace")
  [ "$owned" = "1" ]
}

# Recorded dispatch position, empty when none. The automated path reads this
# instead of re-deriving position from the log.
# Usage: fleet_store_position <tid> [workspace]
fleet_store_position() {
  local tid="$1" workspace="${2:-}"
  _fleet_store_safe_tid "$tid" || return 1
  fleet_store_sql "SELECT position FROM tickets WHERE tid = '${tid}';" "$workspace"
}

# Epoch seconds of the ticket's most recent agent tool call, empty when none.
# Usage: fleet_store_last_activity_epoch <tid> [workspace]
fleet_store_last_activity_epoch() {
  local tid="$1" workspace="${2:-}"
  _fleet_store_safe_tid "$tid" || return 1
  fleet_store_sql "SELECT MAX(epoch) FROM activity_events WHERE tid = '${tid}' \
AND epoch IS NOT NULL;" "$workspace"
}

# Tickets with a running worker — "what is in flight right now" as one query
# rather than a glob over the log directory.
# Usage: fleet_store_in_flight [workspace]
fleet_store_in_flight() {
  fleet_store_sql "SELECT DISTINCT tid FROM workers WHERE status = 'running' \
ORDER BY tid;" "${1:-}"
}

# Generation fence, preserving the file-based semantics exactly: unfenced is
# allowed, fenced with no caller generation fails closed, and a caller
# generation at or below the fenced one is refused as superseded.
# Usage: fleet_store_fence_allows <tid> <caller_generation> [workspace]
fleet_store_fence_allows() {
  local tid="$1" caller="$2" workspace="${3:-}"
  _fleet_store_safe_tid "$tid" || return 1
  local fenced
  fenced=$(fleet_store_sql "SELECT COALESCE(fenced_generation, '') FROM tickets \
WHERE tid = '${tid}';" "$workspace")
  [ -z "$fenced" ] && return 0
  case "$caller" in
  '' | *[!0-9]*) return 1 ;;
  esac
  [ "$caller" -gt "$fenced" ]
}
