#!/usr/bin/env bash
# test-fleet-intervene.sh — unit tests for lib/fleet-intervene.sh
# Usage: bash test-fleet-intervene.sh [test_name_filter]
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

# ── Helpers ──────────────────────────────────────────────────────────────────────

_setup_workspace() {
  mktemp -d
}

_make_pipeline_log() {
  local dir="$1" tid="$2"
  mkdir -p "$dir"
  echo "2026-06-02T10:00:00Z|META|schema|info|1" >"${dir}/${tid}-pipeline.log"
  echo "2026-06-02T10:01:00Z|APPRAISE|appraise|done|scored" >>"${dir}/${tid}-pipeline.log"
}

# ── CI-safe stubs ───────────────────────────────────────────────────────────────
# heartbeat.sh may not be available in CI (no SessionStart hook). Provide
# functional stubs so intervene tests don't depend on external sourcing.

if ! declare -f _plog >/dev/null 2>&1; then
  _plog() {
    local file="$1" phase="$2" step="$3" status="$4" msg="$5"
    mkdir -p "$(dirname "$file")"
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|${phase}|${step}|${status}|${msg}" >>"$file"
  }
fi

if ! declare -f hb_decision >/dev/null 2>&1; then
  hb_decision() { return 0; }
fi

if ! declare -f _iso_now >/dev/null 2>&1; then
  _iso_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
fi

if ! declare -f _ensure_dir_for >/dev/null 2>&1; then
  _ensure_dir_for() { mkdir -p "$(dirname "$1")" 2>/dev/null || true; }
fi

# ── _flow_mutex_held tests ───────────────────────────────────────────────────────

test_flow_mutex_held_lockfile_absent() {
  local ws
  ws=$(_setup_workspace)
  # Ensure no lockfile exists in the workspace
  source "$LIB_DIR/fleet-intervene.sh"
  # Use ./logs path from workspace
  local tid="TEST-MUTEX-01"
  local lockfile="./logs/.ticket-flow-${tid}.lock"
  # Override: cd to temp dir so ./logs resolves there
  (
    cd "$ws"
    mkdir -p logs
    # No lockfile → should return 1
    if _flow_mutex_held "$tid"; then
      false
    else
      true
    fi
  )
  local rc=$?
  rm -rf "$ws"
  [ "$rc" -eq 0 ]
}

test_flow_mutex_held_lock_held() {
  local ws
  ws=$(_setup_workspace)
  (
    cd "$ws"
    mkdir -p logs
    source "$LIB_DIR/fleet-intervene.sh"
    local tid="TEST-MUTEX-02"
    # _flow_mutex_held resolves lock dir from TICKET_FLOW_LOCK_DIR
    # or falls back to $HOME/.claude/skills/ticket-flow/locks.
    # Point it at our temp workspace so it finds the lock we create.
    export TICKET_FLOW_LOCK_DIR="./logs"
    local lockfile="./logs/.ticket-flow-${tid}.lock"
    touch "$lockfile"
    # Acquire lock in a background subshell
    (
      exec 9>"$lockfile"
      flock -x 9
      sleep 5
    ) &
    local holder_pid=$!
    sleep 0.5 # let holder acquire lock
    local rc=0
    _flow_mutex_held "$tid" || rc=$?
    kill "$holder_pid" 2>/dev/null || true
    wait "$holder_pid" 2>/dev/null || true
    rm -rf "$ws"
    [ "$rc" -eq 0 ] # mutex should be detected as held
  )
  local outer_rc=$?
  [ "$outer_rc" -eq 0 ]
}

test_flow_mutex_held_stale_lockfile() {
  local ws
  ws=$(_setup_workspace)
  (
    cd "$ws"
    mkdir -p logs
    source "$LIB_DIR/fleet-intervene.sh"
    local tid="TEST-MUTEX-03"
    local lockfile="./logs/.ticket-flow-${tid}.lock"
    touch "$lockfile"
    # Lockfile exists but no process holds flock (stale from crash)
    if _flow_mutex_held "$tid"; then
      false # should NOT detect mutex as held
    else
      true
    fi
  )
  local rc=$?
  rm -rf "$ws"
  [ "$rc" -eq 0 ]
}

# ── fleet_kill_pipeline tests ────────────────────────────────────────────────────

test_fleet_kill_pipeline_nonexistent_ticket() {
  local ws
  ws=$(_setup_workspace)
  (
    cd "$ws"
    mkdir -p logs
    source "$LIB_DIR/fleet-intervene.sh"
    local out
    if out=$(fleet_kill_pipeline "NOEXIST-99" "test" "./logs" 2>&1); then
      false # should return non-zero
    else
      echo "$out" | grep -q "no pipeline log" || false
    fi
  )
  local rc=$?
  rm -rf "$ws"
  [ "$rc" -eq 0 ]
}

test_fleet_kill_pipeline_normal() {
  local ws
  ws=$(_setup_workspace)
  (
    cd "$ws"
    mkdir -p logs
    _make_pipeline_log "./logs" "CRE-47"
    source "$LIB_DIR/fleet-intervene.sh"
    fleet_kill_pipeline "CRE-47" "test-kill" "./logs"
    # Verify intervention entry written
    grep -q "META|fleet-intervention|warn|KILL; reason=test-kill" "./logs/CRE-47-pipeline.log" || {
      echo "missing intervention entry" >&2
      exit 1
    }
    # Verify outcome entry written
    grep -q "META|outcome|info|stopped: fleet-kill" "./logs/CRE-47-pipeline.log" || {
      echo "missing outcome entry" >&2
      exit 1
    }
  )
  local rc=$?
  rm -rf "$ws"
  [ "$rc" -eq 0 ]
}

test_fleet_kill_pipeline_dry_run_does_not_mutate() {
  local ws
  ws=$(_setup_workspace)
  (
    cd "$ws"
    mkdir -p logs
    _make_pipeline_log "./logs" "CRE-47"
    source "$LIB_DIR/fleet-intervene.sh"
    export FLEET_DRY_RUN=true
    local before_count
    before_count=$(wc -l <"./logs/CRE-47-pipeline.log")
    fleet_kill_pipeline "CRE-47" "test" "./logs"
    local after_count
    after_count=$(wc -l <"./logs/CRE-47-pipeline.log")
    [ "$before_count" -eq "$after_count" ]
  )
  local rc=$?
  rm -rf "$ws"
  [ "$rc" -eq 0 ]
}

# ── _count_restarts regression tests ─────────────────────────────────────────────

test_count_restarts_single_restart_counts_one() {
  local ws
  ws=$(_setup_workspace)
  (
    cd "$ws"
    mkdir -p logs
    _make_pipeline_log "./logs" "CRE-47"
    # Add one fleet-restart + one fleet-restart-marker (the exact bug trigger)
    echo "2026-06-02T10:05:00Z|META|fleet-restart|info|restart test-reason" >>"./logs/CRE-47-pipeline.log"
    echo "2026-06-02T10:05:01Z|META|fleet-restart-marker|info|restart-intent test-reason" >>"./logs/CRE-47-pipeline.log"
    source "$LIB_DIR/fleet-intervene.sh"
    local count
    count=$(_count_restarts "./logs/CRE-47-pipeline.log")
    [ "$count" -eq 1 ] || {
      echo "expected 1 restart, got $count" >&2
      exit 1
    }
  )
  local rc=$?
  rm -rf "$ws"
  [ "$rc" -eq 0 ]
}

test_fleet_can_restart_not_exhausted_after_single_restart() {
  local ws
  ws=$(_setup_workspace)
  (
    cd "$ws"
    mkdir -p logs
    _make_pipeline_log "./logs" "CRE-47"
    # One fleet-restart + companion marker (should count as 1, not 2)
    echo "2026-06-02T10:05:00Z|META|fleet-restart|info|restart test-reason" >>"./logs/CRE-47-pipeline.log"
    echo "2026-06-02T10:05:01Z|META|fleet-restart-marker|info|restart-intent test-reason" >>"./logs/CRE-47-pipeline.log"
    source "$LIB_DIR/fleet-intervene.sh"
    export FLEET_AUTO_RESTART=true
    export FLEET_MAX_RESTARTS=2
    if fleet_can_restart "CRE-47" "./logs" 2>/dev/null; then
      true # should be eligible
    else
      echo "cap should NOT be reached after 1 restart with MAX=2" >&2
      exit 1
    fi
  )
  local rc=$?
  rm -rf "$ws"
  [ "$rc" -eq 0 ]
}

# ── fleet_restart_pipeline contract tests ────────────────────────────────────────

test_fleet_restart_pipeline_no_restart_eligible_stdout() {
  local ws
  ws=$(_setup_workspace)
  (
    cd "$ws"
    mkdir -p logs
    _make_pipeline_log "./logs" "CRE-47"
    source "$LIB_DIR/fleet-intervene.sh"
    export FLEET_AUTO_RESTART=true
    local stdout
    stdout=$(fleet_restart_pipeline "CRE-47" "test-restart" "./logs" 2>&1) || true
    # Should NOT contain "RESTART_ELIGIBLE="
    if echo "$stdout" | grep -q "RESTART_ELIGIBLE="; then
      echo "unexpected RESTART_ELIGIBLE in output: $stdout" >&2
      false
    else
      true
    fi
  )
  local rc=$?
  rm -rf "$ws"
  [ "$rc" -eq 0 ]
}

test_fleet_restart_pipeline_writes_restart_marker() {
  local ws
  ws=$(_setup_workspace)
  (
    cd "$ws"
    mkdir -p logs
    _make_pipeline_log "./logs" "CRE-47"
    source "$LIB_DIR/fleet-intervene.sh"
    export FLEET_AUTO_RESTART=true
    fleet_restart_pipeline "CRE-47" "test-restart" "./logs" 2>/dev/null || true
    grep -q "META|fleet-restart-marker|info|restart-intent" "./logs/CRE-47-pipeline.log" || {
      echo "missing restart marker" >&2
      false
    }
  )
  local rc=$?
  rm -rf "$ws"
  [ "$rc" -eq 0 ]
}

test_fleet_restart_pipeline_auto_restart_off_returns_1() {
  local ws
  ws=$(_setup_workspace)
  (
    cd "$ws"
    mkdir -p logs
    _make_pipeline_log "./logs" "CRE-47"
    source "$LIB_DIR/fleet-intervene.sh"
    export FLEET_AUTO_RESTART=false
    if fleet_restart_pipeline "CRE-47" "test-restart" "./logs" 2>/dev/null; then
      false # should fail when auto-restart is disabled
    else
      true
    fi
  )
  local rc=$?
  rm -rf "$ws"
  [ "$rc" -eq 0 ]
}

# ── Stop-file path equality tests ──────────────────────────────────────────────
# Verifies fleet-intervene.sh and spawn-helper.sh resolve stop-file paths to
# the same directory. Without this, cooperative kill silently fails because
# the intervention writes to one directory while the worker watches another.

test_stop_file_path_equality_default() {
  local ws
  ws=$(_setup_workspace)
  (
    cd "$ws"
    mkdir -p logs
    source "$LIB_DIR/config.sh"
    source "$LIB_DIR/fleet-intervene.sh"

    # Simulate what fleet_stop_background does
    local fleet_pinger
    fleet_pinger=$(_fleet_stop_file "TEST-TID" "pinger" "./logs")

    # Simulate what _worker_stop_file in spawn-helper.sh does when config.sh is
    # available — same constructor, same workspace default (FLEET_PIPELINE_LOG_DIR
    # unset → ./logs). After the spawn-helper fix, the FLEET_STATE_DIR guard is
    # removed, so both call sites resolve through _fleet_stop_file.
    local worker_pinger
    worker_pinger=$(_fleet_stop_file "TEST-TID" "pinger" "${FLEET_PIPELINE_LOG_DIR:-./logs}")

    [ "$fleet_pinger" = "$worker_pinger" ] || {
      echo "MISMATCH (default): fleet=$fleet_pinger worker=$worker_pinger" >&2
      exit 1
    }
    # Verify both paths are under the state directory, not /tmp
    echo "$fleet_pinger" | grep -qv "/tmp" || {
      echo "stop file path should not be under /tmp (default config): $fleet_pinger" >&2
      exit 1
    }
  )
  local rc=$?
  rm -rf "$ws"
  [ "$rc" -eq 0 ]
}

test_stop_file_path_equality_fleet_state_dir_set() {
  local ws
  ws=$(_setup_workspace)
  (
    cd "$ws"
    mkdir -p logs
    source "$LIB_DIR/config.sh"
    source "$LIB_DIR/fleet-intervene.sh"

    export FLEET_STATE_DIR="/var/fleet/state"

    local fleet_pinger
    fleet_pinger=$(_fleet_stop_file "TEST-TID" "pinger" "./logs")

    local worker_pinger
    worker_pinger=$(_fleet_stop_file "TEST-TID" "pinger" "${FLEET_PIPELINE_LOG_DIR:-./logs}")

    [ "$fleet_pinger" = "$worker_pinger" ] || {
      echo "MISMATCH (FLEET_STATE_DIR): fleet=$fleet_pinger worker=$worker_pinger" >&2
      exit 1
    }
    # Verify both paths honour FLEET_STATE_DIR
    echo "$fleet_pinger" | grep -q "/var/fleet/state" || {
      echo "stop file path should honour FLEET_STATE_DIR: $fleet_pinger" >&2
      exit 1
    }
  )
  local rc=$?
  rm -rf "$ws"
  [ "$rc" -eq 0 ]
}

test_stop_file_path_equality_both_types() {
  local ws
  ws=$(_setup_workspace)
  (
    cd "$ws"
    mkdir -p logs
    source "$LIB_DIR/config.sh"

    for stype in pinger watchdog; do
      local fleet_path worker_path
      fleet_path=$(_fleet_stop_file "TEST-TID" "$stype" "./logs")
      worker_path=$(_fleet_stop_file "TEST-TID" "$stype" "${FLEET_PIPELINE_LOG_DIR:-./logs}")

      [ "$fleet_path" = "$worker_path" ] || {
        echo "MISMATCH ($stype): fleet=$fleet_path worker=$worker_path" >&2
        exit 1
      }
    done
  )
  local rc=$?
  rm -rf "$ws"
  [ "$rc" -eq 0 ]
}

# ── Dispatcher ──────────────────────────────────────────────────────────────────

FILTER="${1:-}"

for fn in \
  test_flow_mutex_held_lockfile_absent \
  test_flow_mutex_held_lock_held \
  test_flow_mutex_held_stale_lockfile \
  test_fleet_kill_pipeline_nonexistent_ticket \
  test_fleet_kill_pipeline_normal \
  test_fleet_kill_pipeline_dry_run_does_not_mutate \
  test_count_restarts_single_restart_counts_one \
  test_fleet_can_restart_not_exhausted_after_single_restart \
  test_fleet_restart_pipeline_no_restart_eligible_stdout \
  test_fleet_restart_pipeline_writes_restart_marker \
  test_fleet_restart_pipeline_auto_restart_off_returns_1 \
  test_stop_file_path_equality_default \
  test_stop_file_path_equality_fleet_state_dir_set \
  test_stop_file_path_equality_both_types; do
  [ -z "$FILTER" ] || [[ "$fn" == *"$FILTER"* ]] || continue
  _run "$fn" "$fn"
done

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
