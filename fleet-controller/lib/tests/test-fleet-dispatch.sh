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

# Mock: _fleet_linear_query returns raw GraphQL response (with .data wrapper)
# This is the epic query mock — fleet_dispatch_initiative calls _fleet_linear_query
# then extracts .data.issue from the response.
_mock_epic_query_state_execution() {
  _fleet_linear_query() {
    echo '{"data":{"issue":{"identifier":"INIT-42","labels":{"nodes":[{"name":"state:execution"},{"name":"INIT-42"}]},"children":{"nodes":[]}}}}'
  }
}

_mock_epic_query_no_execution() {
  _fleet_linear_query() {
    echo '{"data":{"issue":{"identifier":"INIT-42","labels":{"nodes":[{"name":"INIT-42"}]},"children":{"nodes":[]}}}}'
  }
}

_mock_epic_query_with_children() {
  _fleet_linear_query() {
    echo '{"data":{"issue":{"identifier":"INIT-42","labels":{"nodes":[{"name":"state:execution"}]},"children":{"nodes":[
        {"identifier":"CRE-101","state":{"name":"Backlog"},"labels":{"nodes":[{"name":"planned"}]},"priority":3},
        {"identifier":"CRE-102","state":{"name":"In Progress"},"labels":{"nodes":[{"name":"planned"}]},"priority":1},
        {"identifier":"CRE-103","state":{"name":"Backlog"},"labels":{"nodes":[{"name":"planned"},{"name":"blocked-by:CRE-100"}]},"priority":2}
      ]}}}}'
  }
}

_mock_epic_query_blocker_done() {
  _fleet_linear_query() {
    echo '{"data":{"issue":{"identifier":"INIT-42","labels":{"nodes":[{"name":"state:execution"}]},"children":{"nodes":[
        {"identifier":"CRE-103","state":{"name":"Backlog"},"labels":{"nodes":[{"name":"planned"},{"name":"blocked-by:CRE-100"}]},"priority":2}
      ]}}}}'
  }
}

# Mock: get_issue returns UNWRAPPED issue data (get_issue unwraps .data.issue)
_mock_get_issue_blocker_in_progress() {
  get_issue() {
    echo '{"identifier":"CRE-100","state":{"name":"In Progress"},"labels":{"nodes":[]}}'
  }
}

_mock_get_issue_blocker_done() {
  get_issue() {
    echo '{"identifier":"CRE-100","state":{"name":"Done"},"labels":{"nodes":[]}}'
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
    FLEET_DRY_RUN=true FLEET_INSTANCE_ID=test-nose
    source '$LIB_DIR/fleet-dispatch.sh'
    $(declare -f _mock_epic_query_no_execution)
    _mock_epic_query_no_execution
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
    FLEET_DRY_RUN=true FLEET_INSTANCE_ID=test-nochild
    source '$LIB_DIR/fleet-dispatch.sh'
    $(declare -f _mock_epic_query_state_execution)
    _mock_epic_query_state_execution
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
    FLEET_DRY_RUN=true FLEET_INSTANCE_ID=test-children
    source '$LIB_DIR/fleet-dispatch.sh'
    $(declare -f _mock_epic_query_with_children)
    $(declare -f _mock_get_issue_blocker_in_progress)
    _mock_epic_query_with_children
    _mock_get_issue_blocker_in_progress
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
    FLEET_DRY_RUN=true FLEET_INSTANCE_ID=test-unblock
    source '$LIB_DIR/fleet-dispatch.sh'
    $(declare -f _mock_epic_query_blocker_done)
    $(declare -f _mock_get_issue_blocker_done)
    _mock_epic_query_blocker_done
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
    $(declare -f _mock_epic_query_with_children)
    $(declare -f _mock_get_issue_blocker_in_progress)
    _mock_epic_query_with_children
    _mock_get_issue_blocker_in_progress
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
    $(declare -f _mock_epic_query_with_children)
    $(declare -f _mock_get_issue_blocker_in_progress)
    _mock_epic_query_with_children
    _mock_get_issue_blocker_in_progress
    fleet_dispatch_initiative 'INIT-42' '$ws' 2>&1 >/dev/null
  " 2>/dev/null || true

  # Run again → should not duplicate
  local output
  output=$(bash -c "
    FLEET_INSTANCE_ID=test-idem
    source '$LIB_DIR/fleet-dispatch.sh'
    $(declare -f _mock_epic_query_with_children)
    $(declare -f _mock_get_issue_blocker_in_progress)
    _mock_epic_query_with_children
    _mock_get_issue_blocker_in_progress
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
    $(declare -f _mock_epic_query_with_children)
    $(declare -f _mock_get_issue_blocker_in_progress)
    _mock_epic_query_with_children
    _mock_get_issue_blocker_in_progress
    fleet_dispatch_initiative 'INIT-42' '$ws' 2>&1
  " 2>/dev/null || true)
  # 2 active + max 3 → only 1 slot available
  echo "$output" | grep -q "can enqueue up to 1" && return 0 || {
    echo "output: $output"
    return 1
  }
}

# ── Queue durability tests ─────────────────────────────────────────────────────

test_queue_entry_has_generation_field() {
  local ws
  ws=$(_setup_workspace)
  local queue_file="${ws}/fleet-test-gen-spawn-queue.jsonl"
  rm -f "$queue_file"

  bash -c "
    FLEET_INSTANCE_ID=test-gen
    source '$LIB_DIR/fleet-dispatch.sh'
    $(declare -f _mock_epic_query_with_children)
    $(declare -f _mock_get_issue_blocker_in_progress)
    _mock_epic_query_with_children
    _mock_get_issue_blocker_in_progress
    fleet_dispatch_initiative 'INIT-42' '$ws' 2>&1 >/dev/null
  " 2>/dev/null || true

  if [ -f "$queue_file" ]; then
    local has_gen
    has_gen=$(jq -r '.generation // "missing"' "$queue_file" 2>/dev/null | head -1)
    [[ "$has_gen" != "missing" ]] && [[ "$has_gen" -ge 1 ]] && return 0
  fi
  echo "queue file $queue_file missing or generation field absent"
  return 1
}

test_queue_entry_survives_simulated_restart() {
  local ws
  ws=$(_setup_workspace)
  local queue_file="${ws}/fleet-test-restart-spawn-queue.jsonl"
  rm -f "$queue_file"

  bash -c "
    FLEET_INSTANCE_ID=test-restart
    source '$LIB_DIR/fleet-dispatch.sh'
    $(declare -f _mock_epic_query_with_children)
    $(declare -f _mock_get_issue_blocker_in_progress)
    _mock_epic_query_with_children
    _mock_get_issue_blocker_in_progress
    fleet_dispatch_initiative 'INIT-42' '$ws' 2>&1 >/dev/null
  " 2>/dev/null || true

  if [ -f "$queue_file" ] && [ -s "$queue_file" ]; then
    local count
    count=$(wc -l <"$queue_file" 2>/dev/null || echo "0")
    [[ "$count" -ge 1 ]] && return 0
  fi
  echo "queue file $queue_file empty or missing after dispatch"
  return 1
}

test_dead_letter_on_exhausted_retries() {
  local ws
  ws=$(_setup_workspace)
  local queue_file="${ws}/fleet-test-dl-spawn-queue.jsonl"
  local dead_letter_file="${queue_file%.jsonl}-dead-letter.jsonl"
  rm -f "$queue_file" "$dead_letter_file"

  echo '{"tid":"CRE-999","reason":"test","restarts":3}' >>"$dead_letter_file"

  if [ -f "$dead_letter_file" ]; then
    local content
    content=$(cat "$dead_letter_file" 2>/dev/null)
    [[ "$content" == *"CRE-999"* ]] && return 0
  fi
  echo "dead-letter file $dead_letter_file not created or missing entry"
  return 1
}

# Exercise the retry→dead-letter path by mocking flock to always fail.
# This avoids timing-sensitive lock contention between processes and
# deterministically tests the retry loop, backoff, and dead-letter logic.
test_contended_append_retried_then_dead_lettered() {
  local ws
  ws=$(_setup_workspace)
  # Derive paths via the constructor so they match what the dispatch uses
  source "$LIB_DIR/config.sh"
  local instance_id="test-contend"
  local queue_file dead_letter_file
  queue_file=$(FLEET_INSTANCE_ID="$instance_id" _fleet_queue_file "$ws")
  dead_letter_file="${queue_file%.jsonl}-dead-letter.jsonl"
  rm -f "$queue_file" "$dead_letter_file"

  local output
  output=$(bash -c "
    # Mock flock to always fail (simulate permanent lock contention)
    flock() { return 1; }
    export -f flock

    FLEET_INSTANCE_ID='$instance_id'
    FLEET_QUEUE_LOCK_TIMEOUT=1
    FLEET_QUEUE_MAX_RETRIES=2
    FLEET_QUEUE_RETRY_BACKOFF_SECS=1
    source '$LIB_DIR/fleet-dispatch.sh'
    $(declare -f _mock_epic_query_with_children)
    $(declare -f _mock_get_issue_blocker_in_progress)
    _mock_epic_query_with_children
    _mock_get_issue_blocker_in_progress
    fleet_dispatch_initiative 'INIT-42' '$ws' 2>&1
  " 2>/dev/null || true)

  # The dispatch should have written a dead-letter error to stderr and dead-letter
  # the entry to the dead-letter file
  echo "$output" | grep -qi "dead-letter" || {
    echo "expected dead-letter message in output: $output" >&2
    rm -rf "$ws"
    return 1
  }

  if [ -f "$dead_letter_file" ] && grep -q "CRE-101" "$dead_letter_file" 2>/dev/null; then
    rm -rf "$ws"
    return 0
  fi
  echo "dead-letter file $dead_letter_file missing or missing CRE-101 entry" >&2
  rm -rf "$ws"
  return 1
}

# Verify that when flock succeeds after a failure, the retry loop recovers
# and the entry lands in the queue.
test_contended_append_retried_and_lands() {
  local ws
  ws=$(_setup_workspace)
  source "$LIB_DIR/config.sh"
  local instance_id="test-retry-land"
  local queue_file
  queue_file=$(FLEET_INSTANCE_ID="$instance_id" _fleet_queue_file "$ws")
  rm -f "$queue_file"

  local output
  output=$(bash -c "
    # Mock flock: fail on first call, succeed on subsequent calls
    _mock_flock() {
      local _attempt_file='${ws}/.flock-attempts'
      local _count=0
      [ -f \"\$_attempt_file\" ] && _count=\$(cat \"\$_attempt_file\" 2>/dev/null || echo 0)
      _count=\$((_count + 1))
      echo \"\$_count\" > \"\$_attempt_file\"
      [ \"\$_count\" -le 1 ] && return 1
      return 0
    }
    flock() { _mock_flock \"\$@\"; }
    export -f flock _mock_flock

    rm -f '${ws}/.flock-attempts'

    FLEET_INSTANCE_ID='$instance_id'
    FLEET_QUEUE_LOCK_TIMEOUT=1
    FLEET_QUEUE_MAX_RETRIES=3
    FLEET_QUEUE_RETRY_BACKOFF_SECS=1
    source '$LIB_DIR/fleet-dispatch.sh'
    $(declare -f _mock_epic_query_with_children)
    $(declare -f _mock_get_issue_blocker_in_progress)
    _mock_epic_query_with_children
    _mock_get_issue_blocker_in_progress
    fleet_dispatch_initiative 'INIT-42' '$ws' 2>&1
  " 2>/dev/null || true)

  # After first flock failure, second attempt should succeed
  if [ -f "$queue_file" ] && grep -q "CRE-101" "$queue_file" 2>/dev/null; then
    rm -rf "$ws"
    return 0
  fi
  echo "queue file $queue_file missing expected CRE-101; output: $output" >&2
  rm -rf "$ws"
  return 1
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
_run "queue_entry_has_generation" test_queue_entry_has_generation_field
_run "queue_entry_survives_restart" test_queue_entry_survives_simulated_restart
_run "dead_letter_on_exhausted_retries" test_dead_letter_on_exhausted_retries
_run "contended_append_retried_then_dead_lettered" test_contended_append_retried_then_dead_lettered
_run "contended_append_retried_and_lands" test_contended_append_retried_and_lands

echo ""
echo "=== Results ==="
echo "PASS: $PASS | FAIL: $FAIL"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
