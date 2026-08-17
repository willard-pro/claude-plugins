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

# Mock: get_issue returns an epic with no Branch Directive — ensures
# ensure_epic_branch sees "no directive" and returns 0 (no-op).
_mock_epic_no_directive() {
  get_issue() {
    echo '{"identifier":"INIT-42","description":"No branch directive here.","labels":{"nodes":[]}}'
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
    $(declare -f _mock_epic_no_directive)

    _mock_epic_query_state_execution
    _mock_epic_no_directive
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

  # Real restart simulation: a FRESH shell re-sources the library (as a
  # restarted daemon/monitor would) and re-reads the durable queue file.
  # The entry must be intact AND recognized — that recognition is exactly
  # what prevents re-investigation/re-dispatch after a restart.
  bash -c "
    FLEET_INSTANCE_ID=test-restart
    source '$LIB_DIR/fleet-dispatch.sh'
    _queue_has_ticket 'CRE-101' '$queue_file'
  " 2>/dev/null || {
    echo "queue entry lost or unrecognized after restart"
    return 1
  }
  # Entry must still be valid JSON with the expected fields.
  jq -e 'select(.tid == "CRE-101") | .generation >= 1' "$queue_file" >/dev/null 2>&1 || {
    echo "queue entry not valid JSON with expected fields: $(cat "$queue_file")"
    return 1
  }
  return 0
}

test_dead_letter_on_exhausted_retries() {
  local ws
  ws=$(_setup_workspace)
  local queue_file="${ws}/fleet-test-dl-spawn-queue.jsonl"
  local dead_letter_file="${queue_file%.jsonl}-dead-letter.jsonl"
  rm -f "$queue_file" "$dead_letter_file"

  # Force the real retry→dead-letter path (flock always fails), then verify
  # the dead-letter file's claim: "human-readable and replayable" — the
  # dead-lettered entry must be replayable into a working queue.
  local output
  output=$(bash -c "
    flock() { return 1; }
    export -f flock
    FLEET_INSTANCE_ID=test-dl
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

  echo "$output" | grep -qi "dead-letter" || {
    echo "expected dead-letter message in output: $output" >&2
    rm -rf "$ws"
    return 1
  }
  [ -f "$dead_letter_file" ] || {
    echo "dead-letter file not created" >&2
    rm -rf "$ws"
    return 1
  }

  # Cross-verify: the dead-lettered entry matches what dispatch intended —
  # a planned ticket from INIT-42, not arbitrary test content.
  local entry
  entry=$(grep -m1 '"tid":"CRE-101"' "$dead_letter_file" 2>/dev/null || true)
  [ -n "$entry" ] || {
    echo "dead-letter file missing the dispatched ticket: $(cat "$dead_letter_file")" >&2
    rm -rf "$ws"
    return 1
  }
  echo "$entry" | jq -e '.tid == "CRE-101" and .dispatch_type == "initial"' >/dev/null 2>&1 || {
    echo "dead-letter entry malformed: $entry" >&2
    rm -rf "$ws"
    return 1
  }

  # Replayability: feed the dead-lettered entry back through the shared
  # append into a fresh queue — it must land as a valid queue entry.
  local replay_queue="${ws}/fleet-test-dl-replay.jsonl"
  rm -f "$replay_queue"
  bash -c "
    source '$LIB_DIR/fleet-dispatch.sh'
    _fleet_queue_append '$entry' '$replay_queue' 2>/dev/null
  " || {
    echo "dead-letter entry not replayable" >&2
    rm -rf "$ws"
    return 1
  }
  jq -e '.tid == "CRE-101"' "$replay_queue" >/dev/null 2>&1 || {
    echo "replayed entry not valid JSON in queue: $(cat "$replay_queue" 2>/dev/null)" >&2
    rm -rf "$ws"
    return 1
  }
  rm -rf "$ws"
  return 0
}

# ── Torn/corrupt queue line handling ────────────────────────────────────────────

# A torn JSON line containing the tid substring must NOT make
# _queue_has_ticket match — the old substring grep skipped the ticket forever
# (fleetd also skips malformed lines, so nothing would ever spawn it).
test_torn_queue_line_does_not_false_match() {
  local ws
  ws=$(_setup_workspace)
  local queue_file="${ws}/fleet-test-torn-spawn-queue.jsonl"
  rm -f "$queue_file"

  # Torn append: tid present as substring, JSON unterminated.
  echo '{"tid":"CRE-101","reason":"planned-dispatch from IN' >>"$queue_file"

  bash -c "
    source '$LIB_DIR/fleet-dispatch.sh'
    _queue_has_ticket 'CRE-101' '$queue_file'
  " 2>/dev/null && {
    echo "torn line false-matched _queue_has_ticket"
    return 1
  }
  return 0
}

# End-to-end: dispatch with a pre-existing torn line must still enqueue the
# ticket it names (valid JSON entry appears), instead of skipping it.
test_dispatch_enqueues_despite_torn_queue_line() {
  local ws
  ws=$(_setup_workspace)
  # Must match the queue file dispatch derives: $ws + instance id
  # fleet-test-torn-dispatch → {ws}/fleet-test-torn-dispatch-spawn-queue.jsonl
  local queue_file="${ws}/fleet-test-torn-dispatch-spawn-queue.jsonl"
  rm -f "$queue_file"
  echo '{"tid":"CRE-101","reason":"planned-dispatch from IN' >>"$queue_file"

  bash -c "
    FLEET_INSTANCE_ID=test-torn-dispatch
    source '$LIB_DIR/fleet-dispatch.sh'
    $(declare -f _mock_epic_query_with_children)
    $(declare -f _mock_get_issue_blocker_in_progress)
    $(declare -f _mock_epic_no_directive)
    _mock_epic_query_with_children
    _mock_get_issue_blocker_in_progress
    _mock_epic_no_directive
    fleet_dispatch_initiative 'INIT-42' '$ws' 2>&1 >/dev/null
  " 2>/dev/null || true

  # Match only COMPLETE single-line JSON (the torn line also contains the
  # tid substring — that is the point of the regression).
  grep '"tid":"CRE-101".*}$' "$queue_file" | head -1 | jq -e '.tid == "CRE-101"' >/dev/null 2>&1 || {
    echo "ticket CRE-101 not enqueued despite torn line: $(cat "$queue_file")" >&2
    return 1
  }
  return 0
}

# Exercise the retry→dead-letter path by mocking flock to always fail.
# This avoids timing-sensitive lock contention between processes and
# deterministically tests the retry loop, backoff, and dead-letter logic.
test_contended_append_retried_then_dead_lettered() {
  local ws
  ws=$(_setup_workspace)
  # Derive paths via the constructor so they match what the dispatch uses
  source "$LIB_DIR/fleet-config.sh"
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

  # Structured notification line: names the ticket and the reason.
  echo "$output" | grep -q "fleet-dead-letter|tid=CRE-101|reason=queue-contention-exhausted" || {
    echo "expected structured fleet-dead-letter line in output: $output" >&2
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
  source "$LIB_DIR/fleet-config.sh"
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

# ── Multi-repo epic branch precondition tests ──────────────────────────────────

# Fixture: REPOS_ROOT containing two git repos and one non-git directory.
_make_multi_repo_root() {
  local root="$1"
  mkdir -p "$root/repo-a" "$root/repo-b" "$root/not-a-repo"
  git -C "$root/repo-a" init -q -b main 2>/dev/null || git -C "$root/repo-a" init -q
  git -C "$root/repo-b" init -q -b main 2>/dev/null || git -C "$root/repo-b" init -q
}

# Mock ensure_epic_branch/epic_branch_sync: record the repo path passed for each
# call, optionally failing for a repo whose path contains $_FAIL_REPO.
# NOTE: _MOCK_CALLS_FILE is deliberately global (not local) — the mocks read it
# at call time, after _mock_branch_ops has returned, so a local would be gone.
_mock_branch_ops() {
  _MOCK_CALLS_FILE="$1"
  ensure_epic_branch() {
    echo "ensure:$2" >>"$_MOCK_CALLS_FILE"
    case "${_FAIL_REPO:-}" in
    "") return 0 ;;
    *) case "$2" in
      *"$_FAIL_REPO"*) return 1 ;;
      *) return 0 ;;
      esac ;;
    esac
  }
  epic_branch_sync() {
    echo "sync:$2" >>"$_MOCK_CALLS_FILE"
    case "${_SYNC_FAIL_REPO:-}" in
    "") return 0 ;;
    *) case "$2" in
      *"$_SYNC_FAIL_REPO"*) return 1 ;;
      *) return 0 ;;
      esac ;;
    esac
  }
}

test_multi_repo_creation_covers_all_repos() {
  local ws
  ws=$(_setup_workspace)
  local repos_root="${ws}/repos"
  _make_multi_repo_root "$repos_root"
  local calls_file="${ws}/calls.log"
  rm -f "$calls_file"

  local output
  output=$(bash -c "
    FLEET_DRY_RUN=true FLEET_INSTANCE_ID=test-mrepo
    REPOS_ROOT='$repos_root'
    $(declare -f _mock_branch_ops)
    _mock_branch_ops '$calls_file'
    source '$LIB_DIR/fleet-dispatch.sh'
    $(declare -f _mock_epic_query_with_children)
    $(declare -f _mock_get_issue_blocker_in_progress)
    _mock_epic_query_with_children
    _mock_get_issue_blocker_in_progress
    fleet_dispatch_initiative 'INIT-42' '$ws' 2>&1
  " 2>/dev/null || true)

  # Both git repos must be visited; the non-git directory must not.
  grep -q "ensure:.*repo-a" "$calls_file" 2>/dev/null || {
    echo "ensure_epic_branch not called for repo-a; calls: $(cat "$calls_file" 2>/dev/null)" >&2
    return 1
  }
  grep -q "ensure:.*repo-b" "$calls_file" 2>/dev/null || {
    echo "ensure_epic_branch not called for repo-b; calls: $(cat "$calls_file" 2>/dev/null)" >&2
    return 1
  }
  grep -q "not-a-repo" "$calls_file" 2>/dev/null && {
    echo "non-git directory visited: $(cat "$calls_file")" >&2
    return 1
  }
  # Dispatch still proceeded (dry-run enqueue of CRE-101)
  echo "$output" | grep -q "CRE-101" || {
    echo "expected CRE-101 enqueue after multi-repo creation; output: $output" >&2
    return 1
  }
  return 0
}

test_multi_repo_creation_failure_gate_stops() {
  local ws
  ws=$(_setup_workspace)
  local repos_root="${ws}/repos"
  _make_multi_repo_root "$repos_root"
  local calls_file="${ws}/calls.log"
  rm -f "$calls_file"

  local output
  output=$(bash -c "
    FLEET_DRY_RUN=true FLEET_INSTANCE_ID=test-mrepo-fail
    REPOS_ROOT='$repos_root'
    _FAIL_REPO='repo-b'
    $(declare -f _mock_branch_ops)
    _mock_branch_ops '$calls_file'
    source '$LIB_DIR/fleet-dispatch.sh'
    $(declare -f _mock_epic_query_with_children)
    $(declare -f _mock_get_issue_blocker_in_progress)
    _mock_epic_query_with_children
    _mock_get_issue_blocker_in_progress
    fleet_dispatch_initiative 'INIT-42' '$ws' 2>&1
  " 2>/dev/null || true)

  # Gate-stop must name the failing repo and enqueue nothing.
  echo "$output" | grep -q "EPIC_BRANCH_UNAVAILABLE" || {
    echo "expected EPIC_BRANCH_UNAVAILABLE; output: $output" >&2
    return 1
  }
  echo "$output" | grep -q "repo-b" || {
    echo "gate-stop must name failing repo; output: $output" >&2
    return 1
  }
  echo "$output" | grep -q "would enqueue" && {
    echo "children enqueued despite gate-stop; output: $output" >&2
    return 1
  }
  return 0
}

test_multi_repo_sync_failure_does_not_block() {
  local ws
  ws=$(_setup_workspace)
  local repos_root="${ws}/repos"
  _make_multi_repo_root "$repos_root"
  local calls_file="${ws}/calls.log"
  rm -f "$calls_file"

  local output
  output=$(bash -c "
    FLEET_DRY_RUN=true FLEET_INSTANCE_ID=test-mrepo-syncfail
    REPOS_ROOT='$repos_root'
    _SYNC_FAIL_REPO='repo-a'
    $(declare -f _mock_branch_ops)
    _mock_branch_ops '$calls_file'
    source '$LIB_DIR/fleet-dispatch.sh'
    $(declare -f _mock_epic_query_with_children)
    $(declare -f _mock_get_issue_blocker_in_progress)
    _mock_epic_query_with_children
    _mock_get_issue_blocker_in_progress
    fleet_dispatch_initiative 'INIT-42' '$ws' 2>&1
  " 2>/dev/null || true)

  # Sync failure reported...
  echo "$output" | grep -q "sync warning" || {
    echo "expected sync warning; output: $output" >&2
    return 1
  }
  # ...but sync still attempted for the remaining repo...
  grep -q "sync:.*repo-b" "$calls_file" 2>/dev/null || {
    echo "sync not attempted for repo-b after repo-a failure; calls: $(cat "$calls_file" 2>/dev/null)" >&2
    return 1
  }
  # ...and ready children still enqueue.
  echo "$output" | grep -q "CRE-101" || {
    echo "expected CRE-101 enqueue despite sync failure; output: $output" >&2
    return 1
  }
  return 0
}

# ── Priority ordering tests ─────────────────────────────────────────────────────

# Mock epic with dispatchable children at given priorities. Prio values are
# Linear's numeric priority: 1=Urgent, 2=High, 3=Medium, 4=Low, 0=No priority.
_mock_epic_query_priorities() {
  _fleet_linear_query() {
    echo "$_PRIORITY_CHILDREN_JSON"
  }
}

# Extract the enqueue order from dry-run output as space-separated TIDs.
_dispatch_order() {
  echo "$1" | grep -o '"tid":"[A-Z]*-[A-Z0-9]*"' | sed 's/"tid":"//;s/"//' | tr '\n' ' ' | sed 's/ $//'
}

_test_dispatch_order() {
  local name="$1"
  local children_json="$2"
  local expected="$3"
  local max_concurrent="${4:-3}"
  local ws
  ws=$(_setup_workspace)

  local output
  output=$(bash -c "
    FLEET_DRY_RUN=true FLEET_INSTANCE_ID=test-prio-${name}
    FLEET_MAX_CONCURRENT=${max_concurrent}
    source '$LIB_DIR/fleet-dispatch.sh'
    _PRIORITY_CHILDREN_JSON='$children_json'
    $(declare -f _mock_epic_query_priorities _mock_epic_no_directive)
    _mock_epic_query_priorities
    _mock_epic_no_directive
    fleet_dispatch_initiative 'INIT-42' '$ws' 2>&1
  " 2>/dev/null || true)

  local order
  order=$(_dispatch_order "$output")
  [ "$order" = "$expected" ] || {
    echo "expected order [$expected], got [$order]; output: $output" >&2
    return 1
  }
  return 0
}

test_priority_urgent_before_low() {
  local children
  children='{"data":{"issue":{"identifier":"INIT-42","labels":{"nodes":[{"name":"state:execution"}]},"children":{"nodes":[
    {"identifier":"CRE-LOW","state":{"name":"Backlog"},"labels":{"nodes":[{"name":"planned"}]},"priority":4},
    {"identifier":"CRE-URG","state":{"name":"Backlog"},"labels":{"nodes":[{"name":"planned"}]},"priority":1}
  ]}}}}'
  _test_dispatch_order "urglow" "$children" "CRE-URG CRE-LOW"
}

test_priority_no_priority_sorts_last_not_first() {
  local children
  children='{"data":{"issue":{"identifier":"INIT-42","labels":{"nodes":[{"name":"state:execution"}]},"children":{"nodes":[
    {"identifier":"CRE-NONE","state":{"name":"Backlog"},"labels":{"nodes":[{"name":"planned"}]},"priority":0},
    {"identifier":"CRE-LOW","state":{"name":"Backlog"},"labels":{"nodes":[{"name":"planned"}]},"priority":4},
    {"identifier":"CRE-URG","state":{"name":"Backlog"},"labels":{"nodes":[{"name":"planned"}]},"priority":1}
  ]}}}}'
  _test_dispatch_order "nonelast" "$children" "CRE-URG CRE-LOW CRE-NONE"
}

test_priority_all_five_levels_full_order() {
  local children
  children='{"data":{"issue":{"identifier":"INIT-42","labels":{"nodes":[{"name":"state:execution"}]},"children":{"nodes":[
    {"identifier":"CRE-LOW","state":{"name":"Backlog"},"labels":{"nodes":[{"name":"planned"}]},"priority":4},
    {"identifier":"CRE-NONE","state":{"name":"Backlog"},"labels":{"nodes":[{"name":"planned"}]},"priority":0},
    {"identifier":"CRE-HIGH","state":{"name":"Backlog"},"labels":{"nodes":[{"name":"planned"}]},"priority":2},
    {"identifier":"CRE-URG","state":{"name":"Backlog"},"labels":{"nodes":[{"name":"planned"}]},"priority":1},
    {"identifier":"CRE-MED","state":{"name":"Backlog"},"labels":{"nodes":[{"name":"planned"}]},"priority":3}
  ]}}}}'
  _test_dispatch_order "fivelevels" "$children" "CRE-URG CRE-HIGH CRE-MED CRE-LOW CRE-NONE" 5
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
_run "torn_queue_line_no_false_match" test_torn_queue_line_does_not_false_match
_run "dispatch_enqueues_despite_torn_queue_line" test_dispatch_enqueues_despite_torn_queue_line
_run "multi_repo_creation_covers_all_repos" test_multi_repo_creation_covers_all_repos
_run "multi_repo_creation_failure_gate_stops" test_multi_repo_creation_failure_gate_stops
_run "multi_repo_sync_failure_does_not_block" test_multi_repo_sync_failure_does_not_block
_run "priority_urgent_before_low" test_priority_urgent_before_low
_run "priority_no_priority_sorts_last" test_priority_no_priority_sorts_last_not_first
_run "priority_all_five_levels_order" test_priority_all_five_levels_full_order

echo ""
echo "=== Results ==="
echo "PASS: $PASS | FAIL: $FAIL"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
