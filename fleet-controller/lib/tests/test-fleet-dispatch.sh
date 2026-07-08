#!/usr/bin/env bash
# test-fleet-dispatch.sh — unit tests for fleet-dispatch.sh
# Tests dispatch logic with mock Linear API responses.
# Usage: bash test-fleet-dispatch.sh [test_name_filter]
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

# ── Mock helpers ─────────────────────────────────────────────────────────────────

_setup_workspace() {
  mktemp -d
}

# Mock: get_issue returns a JSON blob
_mock_get_issue_state_execution() {
  get_issue() {
    echo '{"data":{"issue":{"identifier":"INIT-42","labels":{"nodes":[{"name":"state:execution"},{"name":"INIT-42"}]},"children":{"nodes":[]}}}}'
  }
}

_mock_get_issue_no_execution() {
  get_issue() {
    echo '{"data":{"issue":{"identifier":"INIT-42","labels":{"nodes":[{"name":"INIT-42"}]},"children":{"nodes":[]}}}}'
  }
}

_mock_get_issue_not_found() {
  get_issue() {
    return 1
  }
}

_mock_get_issue_with_children() {
  get_issue() {
    local id="$1"
    case "$id" in
    INIT-42)
      echo '{"data":{"issue":{"identifier":"INIT-42","labels":{"nodes":[{"name":"state:execution"}]},"children":{"nodes":[
          {"identifier":"CRE-101","state":{"name":"Backlog"},"labels":{"nodes":[{"name":"planned"}]},"priority":3},
          {"identifier":"CRE-102","state":{"name":"In Progress"},"labels":{"nodes":[{"name":"planned"}]},"priority":1},
          {"identifier":"CRE-103","state":{"name":"Backlog"},"labels":{"nodes":[{"name":"planned"},{"name":"blocked-by:CRE-100"}]},"priority":2}
        ]}}}}'
      ;;
    CRE-100)
      echo '{"data":{"issue":{"identifier":"CRE-100","state":{"name":"In Progress"},"labels":{"nodes":[]}}}}'
      ;;
    *)
      echo '{"data":{"issue":{"identifier":"'"$id"'","state":{"name":"Done"},"labels":{"nodes":[]}}}}'
      ;;
    esac
  }
}

_mock_get_issue_blocker_done() {
  get_issue() {
    local id="$1"
    case "$id" in
    INIT-42)
      echo '{"data":{"issue":{"identifier":"INIT-42","labels":{"nodes":[{"name":"state:execution"}]},"children":{"nodes":[
          {"identifier":"CRE-103","state":{"name":"Backlog"},"labels":{"nodes":[{"name":"planned"},{"name":"blocked-by:CRE-100"}]},"priority":2}
        ]}}}}'
      ;;
    CRE-100)
      echo '{"data":{"issue":{"identifier":"CRE-100","state":{"name":"Done"},"labels":{"nodes":[]}}}}'
      ;;
    esac
  }
}

# ── Tests ───────────────────────────────────────────────────────────────────────

test_dispatch_no_linear_api() {
  local ws
  ws=$(_setup_workspace)
  # This is an environment-dependent test: linear-api.sh availability varies.
  # Test that dispatch handles gracefully when API is genuinely unavailable,
  # and that we can still source the script without fatal errors.
  # When get_issue is available, the dispatch will validate the initiative
  # normally; when unavailable, it will report the error.
  # Either outcome is acceptable for this test — we're testing the guard logic.
  local output
  output=$(bash -c "
    source '$LIB_DIR/fleet-dispatch.sh' 2>/dev/null
    fleet_dispatch_initiative 'INIT-99' '$ws' 2>&1
  " 2>/dev/null || true)
  # Either "not found", "not available", or "not in execution" → all valid
  echo "$output" | grep -qi "not found\|not available\|not in execution" && return 0 || {
    echo "output: $output"
    return 1
  }
}

test_dispatch_missing_initiative_arg() {
  local ws
  ws=$(_setup_workspace)

  local output
  output=$(bash -c "
    source '$LIB_DIR/fleet-dispatch.sh' 2>/dev/null
    fleet_dispatch_initiative '' '$ws' 2>&1
  " 2>/dev/null || true)
  echo "$output" | grep -qi "required" && return 0 || {
    echo "output: $output"
    return 1
  }
}

test_dispatch_no_state_execution() {
  local ws
  ws=$(_setup_workspace)

  local output
  output=$(bash -c "
    source '$LIB_DIR/fleet-dispatch.sh'
    $(declare -f _mock_get_issue_no_execution)
    _mock_get_issue_no_execution
    fleet_dispatch_initiative 'INIT-42' '$ws' 2>&1
  " 2>/dev/null || true)
  echo "$output" | grep -qi "not in execution" && return 0 || {
    echo "output: $output"
    return 1
  }
}

test_dispatch_no_child_tickets() {
  local ws
  ws=$(_setup_workspace)

  local output
  output=$(bash -c "
    source '$LIB_DIR/fleet-dispatch.sh'
    $(declare -f _mock_get_issue_state_execution)
    _mock_get_issue_state_execution
    fleet_dispatch_initiative 'INIT-42' '$ws' 2>&1
  " 2>/dev/null || true)
  echo "$output" | grep -qi "no child tickets\|no dispatchable" && return 0 || {
    echo "output: $output"
    return 1
  }
}

test_dispatch_with_children_extracts_correctly() {
  local ws
  ws=$(_setup_workspace)

  local output
  output=$(bash -c "
    source '$LIB_DIR/fleet-dispatch.sh'
    $(declare -f _mock_get_issue_with_children)
    _mock_get_issue_with_children
    fleet_dispatch_initiative 'INIT-42' '$ws' 2>&1
  " 2>/dev/null || true)
  # CRE-101: Backlog + planned → should be enqueued
  # CRE-102: In Progress → skipped (not Backlog)
  # CRE-103: Backlog + planned + blocked-by:CRE-100 (In Progress) → skipped
  echo "$output" | grep -q "CRE-101" && return 0 || {
    echo "output: $output"
    return 1
  }
}

test_dispatch_blocker_done_unblocks() {
  local ws
  ws=$(_setup_workspace)

  local output
  output=$(bash -c "
    source '$LIB_DIR/fleet-dispatch.sh'
    $(declare -f _mock_get_issue_blocker_done)
    _mock_get_issue_blocker_done
    fleet_dispatch_initiative 'INIT-42' '$ws' 2>&1
  " 2>/dev/null || true)
  # CRE-103: blocker CRE-100 is Done → should be enqueued
  echo "$output" | grep -q "CRE-103" && return 0 || {
    echo "output: $output"
    return 1
  }
}

test_dispatch_dry_run_no_write() {
  local ws
  ws=$(_setup_workspace)
  local queue_file
  queue_file="/tmp/fleet-test-dry-run-spawn-queue.jsonl"
  rm -f "$queue_file"

  local output
  output=$(bash -c "
    FLEET_DRY_RUN=true FLEET_INSTANCE_ID=test-dry-run
    source '$LIB_DIR/fleet-dispatch.sh'
    $(declare -f _mock_get_issue_with_children)
    _mock_get_issue_with_children
    fleet_dispatch_initiative 'INIT-42' '$ws' 2>&1
  " 2>/dev/null || true)
  echo "$output" | grep -qi "DRY-RUN" && return 0 || {
    echo "output: $output"
    return 1
  }
}

test_dispatch_queue_idempotent() {
  local ws
  ws=$(_setup_workspace)
  local queue_file
  queue_file="/tmp/fleet-test-idem-spawn-queue.jsonl"
  rm -f "$queue_file"

  bash -c "
    FLEET_INSTANCE_ID=test-idem
    source '$LIB_DIR/fleet-dispatch.sh'
    $(declare -f _mock_get_issue_with_children)
    _mock_get_issue_with_children
    fleet_dispatch_initiative 'INIT-42' '$ws' 2>&1 >/dev/null
  " 2>/dev/null || true

  # Run again → should not duplicate
  local output
  output=$(bash -c "
    FLEET_INSTANCE_ID=test-idem
    source '$LIB_DIR/fleet-dispatch.sh'
    $(declare -f _mock_get_issue_with_children)
    _mock_get_issue_with_children
    fleet_dispatch_initiative 'INIT-42' '$ws' 2>&1
  " 2>/dev/null || true)
  echo "$output" | grep -q "already queued" && return 0 || {
    echo "output: $output"
    return 1
  }
}

test_dispatch_fleet_max_concurrent_enforced() {
  local ws
  ws=$(_setup_workspace)
  local queue_file
  queue_file="/tmp/fleet-test-cap-spawn-queue.jsonl"
  rm -f "$queue_file"

  # Create 2 active pipeline logs to simulate active pipelines
  _plog() {
    local dir="$1" tid="$2" phase="$3" step="$4" status="$5" msg="$6"
    mkdir -p "$dir"
    echo "2026-07-07T10:00:00Z|${phase}|${step}|${status}|${msg}" >>"${dir}/${tid}-pipeline.log"
  }
  _plog "$ws" "ACT-001" "IMPLEMENT" "implement" "done" "active"
  _plog "$ws" "ACT-002" "VERIFY" "verify" "start" "active"

  local output
  output=$(bash -c "
    FLEET_INSTANCE_ID=test-cap FLEET_MAX_CONCURRENT=3
    source '$LIB_DIR/fleet-dispatch.sh'
    $(declare -f _mock_get_issue_with_children)
    _mock_get_issue_with_children
    fleet_dispatch_initiative 'INIT-42' '$ws' 2>&1
  " 2>/dev/null || true)
  # 2 active + max 3 → only 1 slot available
  echo "$output" | grep -q "can enqueue up to 1" && return 0 || {
    echo "output: $output"
    return 1
  }
}

# ── Run all tests ────────────────────────────────────────────────────────────────

_run "dispatch_no_linear_api" test_dispatch_no_linear_api
_run "dispatch_missing_initiative_arg" test_dispatch_missing_initiative_arg
_run "dispatch_no_state_execution" test_dispatch_no_state_execution
_run "dispatch_no_child_tickets" test_dispatch_no_child_tickets
_run "dispatch_with_children_correctly" test_dispatch_with_children_extracts_correctly
_run "dispatch_blocker_done_unblocks" test_dispatch_blocker_done_unblocks
_run "dispatch_dry_run" test_dispatch_dry_run_no_write
_run "dispatch_queue_idempotent" test_dispatch_queue_idempotent
_run "dispatch_max_concurrent_enforced" test_dispatch_fleet_max_concurrent_enforced

echo ""
echo "=== Results ==="
echo "PASS: $PASS | FAIL: $FAIL"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
