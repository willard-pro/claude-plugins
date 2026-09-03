#!/usr/bin/env bash
# test-fleet-detect-signals.sh — unit tests for the Group 9 signal-enrichment
# detectors: detect_runaway_calls (tool-call rate per open bracket) and
# _fleet_workspace_guard (misconfigured vs. genuinely idle workspace).
#
# Both signals exist because the orchestrator heartbeat cannot distinguish the
# states they cover: a runaway agent and a working agent both keep the router
# alive, and a misconfigured fleet and an idle fleet both report zero pipelines.
#
# Usage: bash test-fleet-detect-signals.sh [test_name_filter]
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

_ago() {
  date -u -d "@$(($(date -u +%s) - $1))" +%Y-%m-%dT%H:%M:%SZ
}

_plog() {
  local dir="$1" tid="$2" phase="$3" step="$4" status="$5" msg="$6" age="${7:-10}"
  echo "$(_ago "$age")|${phase}|${step}|${status}|${msg}" >>"${dir}/${tid}-pipeline.log"
}

_open_bracket() {
  local dir="$1" tid="$2" age="${3:-600}"
  _plog "$dir" "$tid" "IMPLEMENT" "implement" "waiting" "Agent launched" "$age"
}

_closed_bracket() {
  local dir="$1" tid="$2"
  _plog "$dir" "$tid" "IMPLEMENT" "implement" "waiting" "Agent launched" 600
  _plog "$dir" "$tid" "IMPLEMENT" "implement" "done" "implemented" 60
}

# n activity lines, all inside the open bracket (age < bracket age).
_activity_burst() {
  local dir="$1" tid="$2" n="$3" age="${4:-30}"
  local i ts
  ts=$(_ago "$age")
  for ((i = 0; i < n; i++)); do
    echo "${ts}|IMPLEMENT|Bash" >>"${dir}/${tid}-activity.log"
  done
}

_own() {
  local dir="$1" tid="$2"
  echo "{\"tid\": \"$tid\", \"session_id\": \"s\", \"generation\": 1}" >"${dir}/${tid}-run.json"
}

source "$LIB_DIR/fleet-detect.sh"

# ── detect_runaway_calls ─────────────────────────────────────────────────────────

test_bracket_under_threshold_is_silent() {
  local ws
  ws=$(_setup_workspace)
  _open_bracket "$ws" "TESTR-1"
  _activity_burst "$ws" "TESTR-1" 10
  _own "$ws" "TESTR-1"

  local sev
  sev=$(detect_runaway_calls "TESTR-1" "$ws")
  [ "$sev" = "0" ] || {
    echo "  expected 0, got $sev"
    return 1
  }
}

test_bracket_over_threshold_warns() {
  local ws
  ws=$(_setup_workspace)
  _open_bracket "$ws" "TESTR-2"
  _activity_burst "$ws" "TESTR-2" 12
  _own "$ws" "TESTR-2"

  local sev
  sev=$(FLEET_RUNAWAY_CALL_THRESHOLD=10 detect_runaway_calls "TESTR-2" "$ws")
  [ "$sev" = "1" ] || {
    echo "  expected 1, got $sev"
    return 1
  }
}

test_threshold_is_exclusive_at_the_boundary() {
  # "exceeds the threshold" — exactly at it is not over it.
  local ws
  ws=$(_setup_workspace)
  _open_bracket "$ws" "TESTR-3"
  _activity_burst "$ws" "TESTR-3" 10
  _own "$ws" "TESTR-3"

  local sev
  sev=$(FLEET_RUNAWAY_CALL_THRESHOLD=10 detect_runaway_calls "TESTR-3" "$ws")
  [ "$sev" = "0" ] || {
    echo "  expected 0 at exactly the threshold, got $sev"
    return 1
  }
}

test_calls_from_earlier_brackets_are_not_counted() {
  # The whole point of scoping to the bracket: a long ticket accumulates
  # hundreds of activity lines legitimately across many phases.
  local ws
  ws=$(_setup_workspace)
  _activity_burst "$ws" "TESTR-4" 50 5000 # old phase, well before the bracket
  _open_bracket "$ws" "TESTR-4" 600
  _activity_burst "$ws" "TESTR-4" 3 30 # current phase
  _own "$ws" "TESTR-4"

  local sev
  sev=$(FLEET_RUNAWAY_CALL_THRESHOLD=10 detect_runaway_calls "TESTR-4" "$ws")
  [ "$sev" = "0" ] || {
    echo "  expected 0 (only 3 calls in this bracket), got $sev"
    return 1
  }
}

test_closed_bracket_is_not_evaluated() {
  local ws
  ws=$(_setup_workspace)
  _closed_bracket "$ws" "TESTR-5"
  _activity_burst "$ws" "TESTR-5" 99
  _own "$ws" "TESTR-5"

  local sev
  sev=$(FLEET_RUNAWAY_CALL_THRESHOLD=1 detect_runaway_calls "TESTR-5" "$ws")
  [ "$sev" = "0" ] || {
    echo "  expected 0 with no open bracket, got $sev"
    return 1
  }
}

test_absent_activity_log_does_not_crash() {
  local ws
  ws=$(_setup_workspace)
  _open_bracket "$ws" "TESTR-6"
  _own "$ws" "TESTR-6"

  local sev
  sev=$(detect_runaway_calls "TESTR-6" "$ws")
  [ "$sev" = "0" ] || {
    echo "  expected 0, got $sev"
    return 1
  }
}

test_manual_run_is_never_escalated_past_warn() {
  # Task 9.5: a human running /ticket-auto by hand trips a call-count threshold
  # as naturally as a runaway agent does, and severity >=2 drives real kills.
  # No run-registry entry is written here — the ticket is not fleetd's.
  local ws
  ws=$(_setup_workspace)
  _open_bracket "$ws" "TESTR-7"
  _activity_burst "$ws" "TESTR-7" 500

  local sev
  sev=$(FLEET_RUNAWAY_CALL_THRESHOLD=1 detect_runaway_calls "TESTR-7" "$ws")
  [ "$sev" -le 1 ] || {
    echo "  expected <=1 for an unowned ticket, got $sev"
    return 1
  }
}

test_runaway_reaches_the_aggregator() {
  local ws out
  ws=$(_setup_workspace)
  _open_bracket "$ws" "TESTR-8"
  _activity_burst "$ws" "TESTR-8" 12
  _own "$ws" "TESTR-8"

  out=$(FLEET_RUNAWAY_CALL_THRESHOLD=10 fleet_detect_all "$ws")
  echo "$out" | jq -e '.pipelines[] | select(.tid=="TESTR-8") | .anomalies | contains("runaway-calls")' >/dev/null || {
    echo "  anomaly label missing from: $out"
    return 1
  }
}

# ── _fleet_workspace_guard ───────────────────────────────────────────────────────

test_missing_workspace_warns_loudly() {
  local ws out
  ws=$(_setup_workspace)
  out=$(_fleet_workspace_guard "${ws}/does-not-exist")
  [ "$(echo "$out" | jq -r '.severity')" = "1" ] || {
    echo "  expected severity 1, got: $out"
    return 1
  }
  echo "$out" | jq -re '.findings | test("does not exist")' >/dev/null || {
    echo "  findings did not name the problem: $out"
    return 1
  }
}

test_missing_workspace_names_the_resolved_path_origin() {
  # The failure this guards is a fleetd started from the wrong cwd, where
  # FLEET_PIPELINE_LOG_DIR is unset and ./logs resolves somewhere unintended.
  # The finding is only actionable if it says where it looked and why.
  local out
  out=$(cd /tmp && FLEET_PIPELINE_LOG_DIR="" bash -c "
    source '$LIB_DIR/fleet-detect.sh'
    _fleet_workspace_guard './logs-definitely-absent'
  ")
  echo "$out" | jq -re '.findings | test("unset")' >/dev/null || {
    echo "  findings did not explain the default resolution: $out"
    return 1
  }
}

test_file_where_directory_expected_warns() {
  local ws out
  ws=$(_setup_workspace)
  : >"${ws}/not-a-dir"
  out=$(_fleet_workspace_guard "${ws}/not-a-dir")
  [ "$(echo "$out" | jq -r '.severity')" = "1" ] || {
    echo "  expected severity 1, got: $out"
    return 1
  }
}

test_idle_but_configured_workspace_is_silent() {
  local ws out
  ws=$(_setup_workspace)
  out=$(_fleet_workspace_guard "$ws")
  [ "$(echo "$out" | jq -r '.severity')" = "0" ] || {
    echo "  expected severity 0 for an idle workspace, got: $out"
    return 1
  }
  [ "$(echo "$out" | jq -r '.findings')" = "" ] || {
    echo "  idle workspace should produce no findings, got: $out"
    return 1
  }
}

test_populated_workspace_is_silent() {
  local ws out
  ws=$(_setup_workspace)
  _open_bracket "$ws" "TESTW-1"
  out=$(_fleet_workspace_guard "$ws")
  [ "$(echo "$out" | jq -r '.severity')" = "0" ] || {
    echo "  expected severity 0, got: $out"
    return 1
  }
}

test_guard_reaches_the_aggregator_on_the_missing_path() {
  # The old early return dropped this entirely: a missing workspace produced a
  # summary that looked identical to a perfectly healthy idle fleet.
  local ws out
  ws=$(_setup_workspace)
  out=$(fleet_detect_all "${ws}/gone")
  echo "$out" | jq -e '.fleet_wide[] | select(.name=="detect_workspace_config") | .severity == 1' >/dev/null || {
    echo "  guard missing from aggregator output: $out"
    return 1
  }
  [ "$(echo "$out" | jq -r '.summary.warn')" = "1" ] || {
    echo "  warn not tallied: $out"
    return 1
  }
}

test_guard_reaches_the_aggregator_on_the_normal_path() {
  local ws out
  ws=$(_setup_workspace)
  out=$(fleet_detect_all "$ws")
  echo "$out" | jq -e '.fleet_wide[] | select(.name=="detect_workspace_config") | .severity == 0' >/dev/null || {
    echo "  guard missing from aggregator output: $out"
    return 1
  }
}

FILTER="${1:-}"
for t in \
  test_bracket_under_threshold_is_silent \
  test_bracket_over_threshold_warns \
  test_threshold_is_exclusive_at_the_boundary \
  test_calls_from_earlier_brackets_are_not_counted \
  test_closed_bracket_is_not_evaluated \
  test_absent_activity_log_does_not_crash \
  test_manual_run_is_never_escalated_past_warn \
  test_runaway_reaches_the_aggregator \
  test_missing_workspace_warns_loudly \
  test_missing_workspace_names_the_resolved_path_origin \
  test_file_where_directory_expected_warns \
  test_idle_but_configured_workspace_is_silent \
  test_populated_workspace_is_silent \
  test_guard_reaches_the_aggregator_on_the_missing_path \
  test_guard_reaches_the_aggregator_on_the_normal_path; do
  if [ -z "$FILTER" ] || [[ "$t" == *"$FILTER"* ]]; then
    _run "$t" "$t"
  fi
done

echo ""
echo "=== $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
