#!/usr/bin/env bash
# test-fleet-detect-activity.sh — unit tests for the agent-activity liveness
# dimension of detect_stalls (fleetd-phase-supervisor, agent-liveness-mvp).
#
# The dimension exists to separate two failures the heartbeat dimension cannot
# tell apart: a dead router (watchdog silent) and a hung agent under a healthy
# router (watchdog chirping, agent making no tool calls).
#
# Usage: bash test-fleet-detect-activity.sh [test_name_filter]
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

_TEST_TMPDIRS=()
_setup_workspace() {
  local d
  d=$(mktemp -d)
  _TEST_TMPDIRS+=("$d")
  echo "$d"
}
_cleanup() {
  local d
  for d in "${_TEST_TMPDIRS[@]}"; do
    rm -rf "$d" 2>/dev/null || true
  done
}
trap _cleanup EXIT

# Seconds-ago timestamp in the pipeline log's ISO format.
_ago() {
  date -u -d "@$(($(date -u +%s) - $1))" +%Y-%m-%dT%H:%M:%SZ
}

_plog() {
  local dir="$1" tid="$2" phase="$3" step="$4" status="$5" msg="$6" age="${7:-10}"
  echo "$(_ago "$age")|${phase}|${step}|${status}|${msg}" >>"${dir}/${tid}-pipeline.log"
}

# An open bracket: a |waiting| entry with no terminal after it.
_open_bracket() {
  local dir="$1" tid="$2" age="${3:-1200}"
  _plog "$dir" "$tid" "IMPLEMENT" "implement" "waiting" "Agent launched" "$age"
}

# A closed bracket: the same waiting entry, followed by its terminal.
_closed_bracket() {
  local dir="$1" tid="$2"
  _plog "$dir" "$tid" "IMPLEMENT" "implement" "waiting" "Agent launched" 1200
  _plog "$dir" "$tid" "IMPLEMENT" "implement" "done" "implemented" 60
}

_activity() {
  local dir="$1" tid="$2" age="$3"
  echo "$(_ago "$age")|IMPLEMENT|Bash" >>"${dir}/${tid}-activity.log"
}

_heartbeat() {
  local dir="$1" tid="$2" age="$3"
  echo "$(_ago "$age")|watchdog|alive|waiting for IMPLEMENT agent" >>"${dir}/${tid}-heartbeat.log"
}

# A fleetd run-registry entry — what _fleet_owns_ticket keys on.
_own() {
  local dir="$1" tid="$2"
  echo "{\"tid\": \"$tid\", \"session_id\": \"s\", \"generation\": 1}" >"${dir}/${tid}-run.json"
}

source "$LIB_DIR/fleet-detect.sh"

# ── Tests ────────────────────────────────────────────────────────────────────────

test_fresh_activity_open_bracket_is_healthy() {
  local ws
  ws=$(_setup_workspace)
  _open_bracket "$ws" "TESTA-1"
  _activity "$ws" "TESTA-1" 30
  _heartbeat "$ws" "TESTA-1" 30
  _own "$ws" "TESTA-1"

  local sev
  sev=$(detect_stalls "TESTA-1" "$ws")
  [ "$sev" = "0" ] || {
    echo "  expected 0, got $sev"
    return 1
  }
}

test_stale_activity_fresh_heartbeat_is_flagged() {
  local ws
  ws=$(_setup_workspace)
  _open_bracket "$ws" "TESTA-2"
  _activity "$ws" "TESTA-2" 1000
  _heartbeat "$ws" "TESTA-2" 30
  _own "$ws" "TESTA-2"

  # Heartbeat dimension alone would be 0 here (30s < 600s warn) — the only
  # thing that can raise severity is the agent's own silence.
  local sev
  sev=$(detect_stalls "TESTA-2" "$ws")
  [ "$sev" = "2" ] || {
    echo "  expected 2, got $sev"
    return 1
  }
}

test_activity_warn_band() {
  local ws
  ws=$(_setup_workspace)
  _open_bracket "$ws" "TESTA-3"
  _activity "$ws" "TESTA-3" 300
  _heartbeat "$ws" "TESTA-3" 30
  _own "$ws" "TESTA-3"

  local sev
  sev=$(detect_stalls "TESTA-3" "$ws")
  [ "$sev" = "1" ] || {
    echo "  expected 1, got $sev"
    return 1
  }
}

test_absent_activity_log_does_not_crash() {
  local ws
  ws=$(_setup_workspace)
  _open_bracket "$ws" "TESTA-4"
  _heartbeat "$ws" "TESTA-4" 30

  local sev
  sev=$(detect_stalls "TESTA-4" "$ws")
  [ "$sev" = "0" ] || {
    echo "  expected 0, got $sev"
    return 1
  }
}

test_activity_ignored_when_bracket_closed() {
  local ws
  ws=$(_setup_workspace)
  _closed_bracket "$ws" "TESTA-5"
  _activity "$ws" "TESTA-5" 5000
  _heartbeat "$ws" "TESTA-5" 30
  _own "$ws" "TESTA-5"

  # Between brackets no agent is expected to be calling tools, so a cold
  # activity log means nothing.
  local sev
  sev=$(detect_stalls "TESTA-5" "$ws")
  [ "$sev" = "0" ] || {
    echo "  expected 0, got $sev"
    return 1
  }
}

test_thresholds_are_overridable() {
  local ws
  ws=$(_setup_workspace)
  _open_bracket "$ws" "TESTA-6"
  _activity "$ws" "TESTA-6" 60
  _heartbeat "$ws" "TESTA-6" 30
  _own "$ws" "TESTA-6"

  local sev
  sev=$(FLEET_ACTIVITY_WARN_SECS=10 FLEET_ACTIVITY_STALE_SECS=3000 detect_stalls "TESTA-6" "$ws")
  [ "$sev" = "1" ] || {
    echo "  expected 1, got $sev"
    return 1
  }

  sev=$(FLEET_ACTIVITY_WARN_SECS=10 FLEET_ACTIVITY_STALE_SECS=20 detect_stalls "TESTA-6" "$ws")
  [ "$sev" = "2" ] || {
    echo "  expected 2, got $sev"
    return 1
  }
}

test_manual_run_is_capped_at_warn() {
  local ws
  ws=$(_setup_workspace)
  _open_bracket "$ws" "TESTA-7"
  _activity "$ws" "TESTA-7" 1000
  _heartbeat "$ws" "TESTA-7" 30
  # No run-registry entry — a human running /ticket-auto by hand. Severity >=2
  # is what drives fleet-intervene.sh's kills, so this must not reach it.

  local sev
  sev=$(detect_stalls "TESTA-7" "$ws")
  [ "$sev" = "1" ] || {
    echo "  expected 1, got $sev"
    return 1
  }
}

test_heartbeat_dimension_still_applies() {
  local ws
  ws=$(_setup_workspace)
  _open_bracket "$ws" "TESTA-8"
  _activity "$ws" "TESTA-8" 5
  _heartbeat "$ws" "TESTA-8" 1000
  _own "$ws" "TESTA-8"

  # Fresh agent activity must not mask a stalled orchestrator: the two
  # dimensions are independent and the result is their max.
  local sev
  sev=$(detect_stalls "TESTA-8" "$ws")
  [ "$sev" = "2" ] || {
    echo "  expected 2, got $sev"
    return 1
  }
}

test_activity_without_heartbeat_log_is_evaluated() {
  local ws
  ws=$(_setup_workspace)
  _open_bracket "$ws" "TESTA-9"
  _activity "$ws" "TESTA-9" 1000
  _own "$ws" "TESTA-9"

  # No heartbeat log at all — the old code returned 0 unconditionally here.
  local sev
  sev=$(detect_stalls "TESTA-9" "$ws")
  [ "$sev" = "2" ] || {
    echo "  expected 2, got $sev"
    return 1
  }
}

FILTER="${1:-}"
for t in \
  test_fresh_activity_open_bracket_is_healthy \
  test_stale_activity_fresh_heartbeat_is_flagged \
  test_activity_warn_band \
  test_absent_activity_log_does_not_crash \
  test_activity_ignored_when_bracket_closed \
  test_thresholds_are_overridable \
  test_manual_run_is_capped_at_warn \
  test_heartbeat_dimension_still_applies \
  test_activity_without_heartbeat_log_is_evaluated; do
  if [ -z "$FILTER" ] || [[ "$t" == *"$FILTER"* ]]; then
    _run "$t" "$t"
  fi
done

echo ""
echo "=== $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
