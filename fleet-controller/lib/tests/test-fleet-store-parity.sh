#!/usr/bin/env bash
# test-fleet-store-parity.sh — the detection engines must produce identical
# findings whether their input comes from the pipeline-log files or from the
# fleet state store.
#
# This is the assertion the store migration rests on. `fleet-detect.sh` reads
# through one seam (`_pipeline_rows`), so the filtering, thresholds and
# severities are literally the same code in both directions; what this suite
# proves is that the seam itself is faithful — same line content, same line
# ordering, same line numbers, so position-scoped engines cannot disagree.
#
# Each fixture is run twice against the same workspace: once with no database
# present, once after ingesting those exact logs into one.
#
# Usage: bash test-fleet-store-parity.sh [test_name_filter]
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
FLEET_CONTROLLER_DIR="$(cd "$LIB_DIR/.." && pwd)"

PASS=0
FAIL=0
_run() {
  local name="$1"
  shift
  if "$@"; then
    echo "PASS: $name"
    ((PASS++)) || true
  else
    echo "FAIL: $name"
    ((FAIL++)) || true
  fi
}

_TEST_TMPDIRS=()
_mkws() {
  local d
  d=$(mktemp -d)
  _TEST_TMPDIRS+=("$d")
  echo "$d"
}
_cleanup() {
  local d
  for d in "${_TEST_TMPDIRS[@]}"; do rm -rf "$d" 2>/dev/null || true; done
}
trap _cleanup EXIT

if ! command -v sqlite3 >/dev/null 2>&1; then
  echo "SKIP: sqlite3 not installed — the store's bash read path cannot be exercised"
  exit 0
fi

source "$LIB_DIR/fleet-detect.sh"

_ago() {
  date -u -d "@$(($(date -u +%s) - $1))" +%Y-%m-%dT%H:%M:%SZ
}

_plog() {
  local ws="$1" tid="$2" phase="$3" step="$4" status="$5" msg="$6" age="${7:-60}"
  echo "$(_ago "$age")|${phase}|${step}|${status}|${msg}" >>"${ws}/${tid}-pipeline.log"
}

# A fleetd run-registry entry, so file mode and store mode agree on ownership.
_own() {
  local ws="$1" tid="$2"
  echo "{\"tid\": \"$tid\", \"pid\": \"$$\", \"generation\": 1, \"session_id\": \"s\"}" \
    >"${ws}/${tid}-run.json"
}

# Ingest the workspace's logs and adopt its registry files into a fresh store.
_build_store() {
  local ws="$1"
  python3 - "$FLEET_CONTROLLER_DIR" "$ws" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
from fleetd import store
st = store.open_store(sys.argv[2])
st.ingest_workspace(sys.argv[2])
st.import_legacy_state(sys.argv[2])
st.close()
PY
}

# Every engine whose input the migration moved to the store.
_ENGINES="detect_phase_failures detect_zombies detect_abandoned detect_auto_mode_blocks detect_planner_feedback detect_stalls"

_severities() {
  local ws="$1" tid="$2" engine out=""
  for engine in $_ENGINES; do
    out="${out}${engine}=$("$engine" "$tid" "$ws") "
  done
  echo "$out"
}

# Run every engine against the fixture with no store, then with one, and
# require the two result sets to be identical.
_assert_parity() {
  local ws="$1" tid="$2"
  local from_files from_store

  export FLEET_STATE_DIR="$ws"
  from_files=$(_severities "$ws" "$tid")

  _build_store "$ws" || {
    echo "  store build failed"
    return 1
  }
  fleet_store_ready "$ws" || {
    echo "  store built but not readable"
    return 1
  }
  from_store=$(_severities "$ws" "$tid")

  if [ "$from_files" != "$from_store" ]; then
    echo "  files: $from_files"
    echo "  store: $from_store"
    return 1
  fi
  # A parity assertion that passes because both sides found nothing proves
  # nothing about the seam.
  case "$from_files" in
  *=1* | *=2* | *=3*) return 0 ;;
  esac
  echo "  fixture produced no non-zero severity — parity is vacuous"
  return 1
}

# ── Fixtures ─────────────────────────────────────────────────────────────────

test_parity_phase_failure() {
  local ws
  ws=$(_mkws)
  _own "$ws" "PAR-1"
  _plog "$ws" "PAR-1" "IMPLEMENT" "implement" "fail" "compile error" 120
  _plog "$ws" "PAR-1" "META" "outcome" "info" "completed: failed" 60
  _assert_parity "$ws" "PAR-1"
}

test_parity_gate_stop() {
  local ws
  ws=$(_mkws)
  _own "$ws" "PAR-2"
  _plog "$ws" "PAR-2" "META" "gate-stop" "fail" "EXEC_NO_ARTIFACT" 120
  _plog "$ws" "PAR-2" "META" "outcome" "info" "completed: gate-stop" 60
  _assert_parity "$ws" "PAR-2"
}

test_parity_gate_stop_code_selects_severity() {
  local ws
  ws=$(_mkws)
  _own "$ws" "PAR-2B"
  # This code routes to severity 3 (agent flaked, retryable) where every other
  # code routes to 1. The engine reads it out of MSG, so a seam that dropped or
  # mangled the message body would silently downgrade a restart to a warning —
  # a divergence the other fixtures cannot see, because their severities do not
  # depend on message content.
  _plog "$ws" "PAR-2B" "META" "gate-stop" "fail" "PR_REVIEW_VERDICT_UNPARSEABLE" 120
  _plog "$ws" "PAR-2B" "META" "outcome" "info" "completed: gate-stop" 60
  _assert_parity "$ws" "PAR-2B" || return 1

  local sev
  sev=$(detect_phase_failures "PAR-2B" "$ws")
  [ "$sev" = "3" ] || {
    echo "  expected 3 from the gate-stop code, got $sev"
    return 1
  }
}

test_parity_open_bracket_zombie() {
  local ws
  ws=$(_mkws)
  _own "$ws" "PAR-3"
  # An unresolved waiting entry old enough to be a zombie.
  _plog "$ws" "PAR-3" "IMPLEMENT" "implement" "waiting" "Agent launched" 2000
  _assert_parity "$ws" "PAR-3"
}

test_parity_terminal_from_earlier_cycle_does_not_mask() {
  local ws
  ws=$(_mkws)
  _own "$ws" "PAR-4"
  # The position-scoped case: an old terminal precedes a newer waiting entry
  # for the same phase/step. Line ordering and numbering must survive the
  # round trip through the store, or this silently reads as healthy.
  _plog "$ws" "PAR-4" "VERIFY" "verify" "waiting" "Agent launched" 5000
  _plog "$ws" "PAR-4" "VERIFY" "verify" "done" "FAIL — retry" 4000
  _plog "$ws" "PAR-4" "VERIFY" "verify" "waiting" "Agent launched" 2000
  _assert_parity "$ws" "PAR-4"
}

test_parity_abandoned() {
  local ws
  ws=$(_mkws)
  _own "$ws" "PAR-5"
  # No META|outcome and a long-idle last entry.
  _plog "$ws" "PAR-5" "APPRAISE" "appraise" "done" "appraised" 7200
  _assert_parity "$ws" "PAR-5"
}

test_parity_auto_mode_block() {
  local ws
  ws=$(_mkws)
  _own "$ws" "PAR-6"
  _plog "$ws" "PAR-6" "GATE" "check-approval" "fail" "auto mode denied" 300
  _plog "$ws" "PAR-6" "META" "outcome" "info" "completed: blocked" 60
  _assert_parity "$ws" "PAR-6"
}

test_parity_activity_stall() {
  local ws
  ws=$(_mkws)
  _own "$ws" "PAR-7"
  _plog "$ws" "PAR-7" "IMPLEMENT" "implement" "waiting" "Agent launched" 2000
  echo "$(_ago 1000)|IMPLEMENT|Bash" >>"${ws}/PAR-7-activity.log"
  echo "$(_ago 60)|watchdog|alive|waiting for IMPLEMENT agent" \
    >>"${ws}/PAR-7-heartbeat.log"
  _assert_parity "$ws" "PAR-7"
}

test_parity_message_containing_separators() {
  local ws
  ws=$(_mkws)
  _own "$ws" "PAR-8"
  # A MSG carrying its own pipes. If ingestion split it into extra columns,
  # the reassembled line would differ from the file's and this diverges.
  _plog "$ws" "PAR-8" "IMPLEMENT" "implement" "fail" "err: a|b|c 'quoted'" 120
  _plog "$ws" "PAR-8" "META" "outcome" "info" "completed: failed" 60
  _assert_parity "$ws" "PAR-8"
}

# ── Ownership scoping ────────────────────────────────────────────────────────

test_store_scopes_intervention_to_owned_tickets() {
  local ws
  ws=$(_mkws)
  export FLEET_STATE_DIR="$ws"
  # Same anomaly, no run-registry entry: a human's manual run.
  _plog "$ws" "PAR-9" "IMPLEMENT" "implement" "waiting" "Agent launched" 2000
  echo "$(_ago 1000)|IMPLEMENT|Bash" >>"${ws}/PAR-9-activity.log"
  echo "$(_ago 60)|watchdog|alive|waiting for IMPLEMENT agent" \
    >>"${ws}/PAR-9-heartbeat.log"
  _build_store "$ws" || return 1

  fleet_store_is_owned "PAR-9" "$ws" && {
    echo "  a log-only ticket must not read as fleetd-owned"
    return 1
  }
  local sev
  sev=$(detect_stalls "PAR-9" "$ws")
  # Reported for visibility, never escalated to a kill.
  [ "$sev" = "1" ] || {
    echo "  expected WARN (1), got $sev"
    return 1
  }
}

test_store_allows_intervention_on_owned_tickets() {
  local ws
  ws=$(_mkws)
  export FLEET_STATE_DIR="$ws"
  _own "$ws" "PAR-10"
  _plog "$ws" "PAR-10" "IMPLEMENT" "implement" "waiting" "Agent launched" 2000
  echo "$(_ago 1000)|IMPLEMENT|Bash" >>"${ws}/PAR-10-activity.log"
  echo "$(_ago 60)|watchdog|alive|waiting for IMPLEMENT agent" \
    >>"${ws}/PAR-10-heartbeat.log"
  _build_store "$ws" || return 1

  fleet_store_is_owned "PAR-10" "$ws" || {
    echo "  an imported run-registry entry must read as fleetd-owned"
    return 1
  }
  local sev
  sev=$(detect_stalls "PAR-10" "$ws")
  [ "$sev" = "2" ] || {
    echo "  expected KILL (2), got $sev"
    return 1
  }
}

test_store_rejects_unsafe_ticket_id() {
  local ws
  ws=$(_mkws)
  export FLEET_STATE_DIR="$ws"
  _own "$ws" "PAR-11"
  _plog "$ws" "PAR-11" "APPRAISE" "appraise" "done" "ok" 60
  _build_store "$ws" || return 1

  # Ticket ids reach an SQL string, so anything outside the identifier
  # alphabet is refused rather than escaped.
  fleet_store_owner "PAR-11'; DROP TABLE tickets; --" "$ws" && {
    echo "  unsafe ticket id was not rejected"
    return 1
  }
  local still
  still=$(fleet_store_sql "SELECT COUNT(*) FROM tickets;" "$ws")
  [ "$still" -ge 1 ] || {
    echo "  tickets table did not survive"
    return 1
  }
}

test_engines_fall_back_to_files_without_a_store() {
  local ws
  ws=$(_mkws)
  export FLEET_STATE_DIR="$ws"
  _plog "$ws" "PAR-12" "IMPLEMENT" "implement" "fail" "boom" 120
  _plog "$ws" "PAR-12" "META" "outcome" "info" "completed: failed" 60

  fleet_store_ready "$ws" && {
    echo "  no store should exist yet"
    return 1
  }
  # The manual path runs on hosts with no fleet-controller state at all.
  local sev
  sev=$(detect_phase_failures "PAR-12" "$ws")
  [ "$sev" = "1" ] || {
    echo "  expected 1 from the file fallback, got $sev"
    return 1
  }
}

FILTER="${1:-}"
for t in \
  test_parity_phase_failure \
  test_parity_gate_stop \
  test_parity_gate_stop_code_selects_severity \
  test_parity_open_bracket_zombie \
  test_parity_terminal_from_earlier_cycle_does_not_mask \
  test_parity_abandoned \
  test_parity_auto_mode_block \
  test_parity_activity_stall \
  test_parity_message_containing_separators \
  test_store_scopes_intervention_to_owned_tickets \
  test_store_allows_intervention_on_owned_tickets \
  test_store_rejects_unsafe_ticket_id \
  test_engines_fall_back_to_files_without_a_store; do
  if [ -z "$FILTER" ] || [[ "$t" == *"$FILTER"* ]]; then
    _run "$t" "$t"
  fi
done

echo ""
echo "=== $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
