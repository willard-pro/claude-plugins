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

  # Create 2 LIVE pipelines: a log without an outcome line does not consume
  # a slot by itself (live-only capacity) — the run-registry pid must be
  # actually alive. Use sleep children so kill -0 succeeds.
  sleep 30 &
  local act1_pid=$!
  sleep 30 &
  local act2_pid=$!
  _plog() {
    local dir="$1" tid="$2" phase="$3" step="$4" status="$5" msg="$6"
    mkdir -p "$dir"
    echo "2026-07-07T10:00:00Z|${phase}|${step}|${status}|${msg}" >>"${dir}/${tid}-pipeline.log"
  }
  _plog "$ws" "ACT-001" "IMPLEMENT" "implement" "done" "active"
  _plog "$ws" "ACT-002" "VERIFY" "verify" "start" "active"
  echo "{\"tid\":\"ACT-001\",\"pid\":\"${act1_pid}\",\"generation\":1,\"reason\":\"test\"}" >"$ws/ACT-001-run.json"
  echo "{\"tid\":\"ACT-002\",\"pid\":\"${act2_pid}\",\"generation\":1,\"reason\":\"test\"}" >"$ws/ACT-002-run.json"

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
  kill "$act1_pid" "$act2_pid" 2>/dev/null || true
  # 2 live + max 3 → only 1 slot available
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

# ── Campaign resume: dispatch reconcile hook + summary ──────────────────────────

# Epic whose child TEST-1 is mid-flight (state Approve, NOT Backlog) with an
# incomplete pipeline log, plus a normal planned Backlog child TEST-2.
_mock_epic_query_campaign() {
  _fleet_linear_query() {
    echo '{"data":{"issue":{"identifier":"INIT-42","labels":{"nodes":[{"name":"state:execution"}]},"children":{"nodes":[
        {"identifier":"TEST-1","state":{"name":"Approve"},"labels":{"nodes":[{"name":"planned"}]},"priority":2},
        {"identifier":"TEST-2","state":{"name":"Backlog"},"labels":{"nodes":[{"name":"planned"}]},"priority":3}
      ]}}}}'
  }
}

# Fake tid (TEST-*) — never matches a real pgrep pattern, keeping the
# live-worker check hermetic without mocking pgrep.
_test_plog() {
  local dir="$1" tid="$2"
  mkdir -p "$dir"
  echo "2026-07-07T10:00:00Z|EXEC|exec|start|mid-flight" >"${dir}/${tid}-pipeline.log"
}

test_dispatch_resumes_incomplete_child() {
  local ws
  ws=$(_setup_workspace)
  _test_plog "$ws" "TEST-1"
  local queue_file="${ws}/fleet-test-resume-spawn-queue.jsonl"

  local output
  output=$(bash -c "
    FLEET_INSTANCE_ID=test-resume
    FLEET_AUTO_RESTART=true
    TICKET_FLOW_LOCK_DIR='$ws/no-flow-locks'
    FLEET_PIPELINE_LOG_DIR='$ws'
    source '$LIB_DIR/fleet-dispatch.sh'
    $(declare -f _mock_epic_query_campaign _mock_epic_no_directive)
    _mock_epic_query_campaign
    _mock_epic_no_directive
    fleet_dispatch_initiative 'INIT-42' '$ws' 2>&1
  " 2>/dev/null || true)

  echo "$output" | grep -q '^  resumed TEST-1$' || {
    echo "expected '  resumed TEST-1' line; output: $output" >&2
    return 1
  }
  echo "$output" | grep -q 'resumed 1 |' || {
    echo "expected 'resumed 1' in summary; output: $output" >&2
    return 1
  }
  # Queue gains the resume entry with the campaign reason.
  [ -f "$queue_file" ] && grep -q '"tid":"TEST-1"' "$queue_file" 2>/dev/null && {
    local reason
    reason=$(grep '"tid":"TEST-1"' "$queue_file" | head -1 | jq -r '.reason // ""')
    [ "$reason" = "campaign-resume from INIT-42" ] || {
      echo "expected campaign-resume reason, got '$reason'" >&2
      return 1
    }
  } || {
    echo "resume entry missing from queue: $(cat "$queue_file" 2>/dev/null)" >&2
    return 1
  }
  # Summary is the LAST stdout line.
  local last_line
  last_line=$(echo "$output" | tail -1)
  echo "$last_line" | grep -q '^fleet_dispatch: resumed 1 | blocked 0 | enqueued 1 ticket(s) for INIT-42$' || {
    echo "expected summary as last line, got '$last_line'" >&2
    return 1
  }
  return 0
}

test_dispatch_dry_run_resume_leaves_queue_untouched() {
  local ws
  ws=$(_setup_workspace)
  _test_plog "$ws" "TEST-1"
  local queue_file="${ws}/fleet-test-dryresume-spawn-queue.jsonl"

  local output
  output=$(bash -c "
    FLEET_INSTANCE_ID=test-dryresume
    FLEET_DRY_RUN=true
    FLEET_AUTO_RESTART=true
    TICKET_FLOW_LOCK_DIR='$ws/no-flow-locks'
    FLEET_PIPELINE_LOG_DIR='$ws'
    source '$LIB_DIR/fleet-dispatch.sh'
    $(declare -f _mock_epic_query_campaign _mock_epic_no_directive)
    _mock_epic_query_campaign
    _mock_epic_no_directive
    fleet_dispatch_initiative 'INIT-42' '$ws' 2>&1
  " 2>/dev/null || true)

  echo "$output" | grep -q '\[DRY-RUN\] would resume TEST-1' || {
    echo "expected dry-run would-resume line; output: $output" >&2
    return 1
  }
  [ ! -f "$queue_file" ] || ! grep -q '"tid":"TEST-1"' "$queue_file" 2>/dev/null || {
    echo "dry-run wrote a resume queue entry" >&2
    return 1
  }
  grep -q '|META|fleet-restart|' "${ws}/TEST-1-pipeline.log" 2>/dev/null && {
    echo "dry-run wrote a restart marker" >&2
    return 1
  }
  local last_line
  last_line=$(echo "$output" | tail -1)
  echo "$last_line" | grep -q '^\[DRY-RUN\] would resume 1 | blocked 0 | would enqueue 1 ticket(s) for INIT-42$' || {
    echo "expected dry-run summary as last line, got '$last_line'" >&2
    return 1
  }
  return 0
}

# A dead pipeline log (no outcome, no worker, no registry pid) must NOT
# consume a capacity slot — the regression this whole change fixes.
test_dispatch_dead_log_does_not_jam_campaign() {
  local ws
  ws=$(_setup_workspace)
  _test_plog "$ws" "TEST-DEAD"
  local queue_file="${ws}/fleet-test-deadlog-spawn-queue.jsonl"

  local output
  output=$(bash -c "
    FLEET_INSTANCE_ID=test-deadlog FLEET_MAX_CONCURRENT=1
    source '$LIB_DIR/fleet-dispatch.sh'
    $(declare -f _mock_epic_query_campaign _mock_epic_no_directive)
    _mock_epic_query_campaign
    _mock_epic_no_directive
    fleet_dispatch_initiative 'INIT-42' '$ws' 2>&1
  " 2>/dev/null || true)

  # TEST-DEAD is not a child of INIT-42, so it was never a candidate for
  # resume — but under the old count it consumed the single slot and TEST-2
  # was never enqueued. Live-only: 0 active → full slot for TEST-2.
  [ -f "$queue_file" ] && grep -q '"tid":"TEST-2"' "$queue_file" 2>/dev/null || {
    echo "dead log jammed dispatch; output: $output; queue: $(cat "$queue_file" 2>/dev/null)" >&2
    return 1
  }
  return 0
}

# The epic's own pending queue entries reserve capacity — a re-dispatch with
# a pending resume entry must not over-enqueue past FLEET_MAX_CONCURRENT.
test_dispatch_reserves_queued_for_epic_slots() {
  local ws
  ws=$(_setup_workspace)
  local queue_file="${ws}/fleet-test-reserve-spawn-queue.jsonl"
  echo '{"tid":"TEST-1","reason":"campaign-resume from INIT-42","timestamp":"2026-08-18T00:00:00Z","restarts":0,"dispatch_type":"initial","generation":1}' >"$queue_file"

  local output
  output=$(bash -c "
    FLEET_INSTANCE_ID=test-reserve FLEET_MAX_CONCURRENT=1
    source '$LIB_DIR/fleet-dispatch.sh'
    $(declare -f _mock_epic_query_campaign _mock_epic_no_directive)
    _mock_epic_query_campaign
    _mock_epic_no_directive
    fleet_dispatch_initiative 'INIT-42' '$ws' 2>&1
  " 2>/dev/null || true)

  # 0 live + 1 queued-for-epic = slot gone → at capacity, TEST-2 not enqueued.
  echo "$output" | grep -q "at capacity" || {
    echo "expected at-capacity; output: $output" >&2
    return 1
  }
  [ "$(grep -c '"tid":"TEST-2"' "$queue_file" 2>/dev/null || true)" = "0" ] || {
    echo "TEST-2 enqueued despite queued-for-epic reservation" >&2
    return 1
  }
  return 0
}

# Every child skipped by blocked-by resolution → blocked N in the summary,
# never a silent "no dispatchable tickets".
test_dispatch_reports_blocked_children() {
  local ws
  ws=$(_setup_workspace)

  local output
  output=$(bash -c "
    FLEET_DRY_RUN=true FLEET_INSTANCE_ID=test-blocked
    source '$LIB_DIR/fleet-dispatch.sh'
    $(declare -f _mock_epic_query_blocker_done _mock_get_issue_blocker_in_progress _mock_epic_no_directive)
    _mock_epic_query_blocker_done
    _mock_get_issue_blocker_in_progress
    _mock_epic_no_directive
    fleet_dispatch_initiative 'INIT-42' '$ws' 2>&1
  " 2>/dev/null || true)

  echo "$output" | grep -q '^  blocked CRE-103$' || {
    echo "expected '  blocked CRE-103' line; output: $output" >&2
    return 1
  }
  local last_line
  last_line=$(echo "$output" | tail -1)
  echo "$last_line" | grep -q '^\[DRY-RUN\] would resume 0 | blocked 1 | would enqueue 0 ticket(s) for INIT-42$' || {
    echo "expected blocked summary as last line, got '$last_line'" >&2
    return 1
  }
  return 0
}

# ── Campaign resume: stop pins incomplete children ──────────────────────────────

# Children query mock for fleet_stop_initiative's step 0.
# NOTE: _STOP_CHILDREN_JSON is deliberately global (not local) — the mock
# reads it at call time, after _mock_stop_children_query has returned.
_mock_stop_children_query() {
  _STOP_CHILDREN_JSON="$1"
  _fleet_linear_query() {
    echo "$_STOP_CHILDREN_JSON"
  }
}

# Incomplete-pipeline child, empty queue, no live workers → the child must
# still land in the stop-file's tickets array (the CRE-9 `tickets: []` gap).
test_stop_pins_incomplete_child_with_empty_queue() {
  local ws
  ws=$(_setup_workspace)
  _test_plog "$ws" "TEST-9"
  local children_json='{"data":{"issue":{"children":{"nodes":[{"identifier":"TEST-9"}]}}}}'

  local output
  output=$(bash -c "
    LINEAR_API_KEY=dummy
    source '$LIB_DIR/fleet-dispatch.sh'
    $(declare -f _mock_stop_children_query)
    _mock_stop_children_query '$children_json'
    fleet_stop_initiative 'INIT-42' 'test' '$ws' 2>&1
  " 2>/dev/null || true)

  echo "$output" | grep -q '  pinned TEST-9 (incomplete pipeline)' || {
    echo "expected incomplete-pipeline pin line; output: $output" >&2
    return 1
  }
  jq -e '.tickets == ["TEST-9"]' "$ws/stop-INIT-42.json" >/dev/null 2>&1 || {
    echo "stop-file tickets: $(cat "$ws/stop-INIT-42.json" 2>/dev/null)" >&2
    return 1
  }
  return 0
}

# Stop purges campaign-resume-reasoned entries (reason match) AND child-tid
# entries with other reasons (tid match); other epics' entries are kept.
test_stop_purges_campaign_resume_and_child_tid_entries() {
  local ws
  ws=$(_setup_workspace)
  echo '{"tid":"TEST-10","reason":"campaign-resume from INIT-42","timestamp":"2026-08-18T00:00:00Z","restarts":0,"dispatch_type":"initial","generation":1}' >"$ws/fleet-default-spawn-queue.jsonl"
  echo '{"tid":"TEST-11","reason":"orphan-reconciliation","timestamp":"2026-08-18T00:00:00Z","restarts":0,"dispatch_type":"initial","generation":1}' >>"$ws/fleet-default-spawn-queue.jsonl"
  echo '{"tid":"TEST-KEEP","reason":"campaign-resume from INIT-43","timestamp":"2026-08-18T00:00:00Z","restarts":0,"dispatch_type":"initial","generation":1}' >>"$ws/fleet-default-spawn-queue.jsonl"
  local children_json='{"data":{"issue":{"children":{"nodes":[{"identifier":"TEST-11"}]}}}}'

  local output
  output=$(bash -c "
    LINEAR_API_KEY=dummy
    source '$LIB_DIR/fleet-dispatch.sh'
    $(declare -f _mock_stop_children_query)
    _mock_stop_children_query '$children_json'
    fleet_stop_initiative 'INIT-42' 'test' '$ws' 2>&1
  " 2>/dev/null || true)

  echo "$output" | grep -q 'purged=\["TEST-10","TEST-11"\]' || {
    echo "expected TEST-10 (reason) + TEST-11 (tid) purged; output: $output" >&2
    return 1
  }
  grep -q '"tid":"TEST-KEEP"' "$ws/fleet-default-spawn-queue.jsonl" 2>/dev/null || {
    echo "INIT-43 entry must be kept; queue: $(cat "$ws/fleet-default-spawn-queue.jsonl" 2>/dev/null)" >&2
    return 1
  }
  grep -q '"tid":"TEST-10"' "$ws/fleet-default-spawn-queue.jsonl" 2>/dev/null && {
    echo "TEST-10 not purged" >&2
    return 1
  }
  return 0
}

# Children-query failure degrades: warning on stderr, stop still completes.
test_stop_children_query_failure_degrades() {
  local ws
  ws=$(_setup_workspace)

  local output
  output=$(bash -c "
    LINEAR_API_KEY=dummy
    source '$LIB_DIR/fleet-dispatch.sh'
    _fleet_linear_query() { return 1; }
    fleet_stop_initiative 'INIT-42' 'test' '$ws' 2>&1
  " 2>/dev/null || true)

  echo "$output" | grep -q 'cannot fetch children of INIT-42' || {
    echo "expected children-fetch warning; output: $output" >&2
    return 1
  }
  echo "$output" | grep -q 'STOP_RESULT|purged=\[\]|killed=\[\]' || {
    echo "stop did not complete after children-query failure; output: $output" >&2
    return 1
  }
  [ -f "$ws/stop-INIT-42.json" ] || {
    echo "stop-file missing despite degradation" >&2
    return 1
  }
  return 0
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

# ── Epic-scoped dispatch lock + stop-file gate ────────────────────────────────────

test_concurrent_same_epic_dispatch_single_entry() {
  local ws
  ws=$(_setup_workspace)

  # Two concurrent dispatches of the same epic — the epic-scoped flock must
  # serialize them so each ticket is enqueued exactly once.
  bash -c "
    source '$LIB_DIR/fleet-dispatch.sh'
    $(declare -f _mock_epic_query_with_children)
    _mock_epic_query_with_children
    $(declare -f _mock_get_issue_blocker_done)
    _mock_get_issue_blocker_done
    fleet_dispatch_initiative 'INIT-42' '$ws'
  " 2>/dev/null &
  local pid1=$!
  bash -c "
    source '$LIB_DIR/fleet-dispatch.sh'
    $(declare -f _mock_epic_query_with_children)
    _mock_epic_query_with_children
    $(declare -f _mock_get_issue_blocker_done)
    _mock_get_issue_blocker_done
    fleet_dispatch_initiative 'INIT-42' '$ws'
  " 2>/dev/null &
  local pid2=$!
  wait "$pid1" "$pid2" 2>/dev/null || true

  local queue_file
  queue_file="$ws/fleet-default-spawn-queue.jsonl"
  [ -f "$queue_file" ] || {
    echo "queue file missing"
    return 1
  }
  local count
  count=$(grep -c '"tid":"CRE-10' "$queue_file" || true)
  # CRE-101 and CRE-103 dispatchable (CRE-102 in progress, CRE-103 blocked-by Done)
  [ "$count" -eq 2 ] || {
    echo "expected 2 entries, got $count"
    return 1
  }
  local tids
  tids=$(jq -r '.tid' "$queue_file" 2>/dev/null | sort | uniq -c | awk '$1 > 1' | wc -l)
  [ "$tids" -eq 0 ] || {
    echo "duplicate entries found"
    return 1
  }
  return 0
}

test_dispatch_lock_different_epics_do_not_block() {
  local ws
  ws=$(_setup_workspace)
  local queue_file
  queue_file="$ws/fleet-default-spawn-queue.jsonl"

  # Hold INIT-43's dispatch lock; dispatching INIT-42 must not block on it.
  (
    flock -x 9
    sleep 2
  ) 9>"${queue_file}.INIT-43.dispatch.lock" &
  local holder=$!
  sleep 0.3

  local output
  output=$(bash -c "
    source '$LIB_DIR/fleet-dispatch.sh'
    $(declare -f _mock_epic_query_with_children)
    _mock_epic_query_with_children
    $(declare -f _mock_get_issue_blocker_done)
    _mock_get_issue_blocker_done
    fleet_dispatch_initiative 'INIT-42' '$ws' 2>&1
  " 2>/dev/null || true)
  wait "$holder" 2>/dev/null || true

  echo "$output" | grep -q "enqueued" || {
    echo "output: $output"
    return 1
  }
  return 0
}

test_stopped_epic_enqueues_nothing() {
  local ws
  ws=$(_setup_workspace)
  echo '{"initiative_id":"INIT-42","stopped_at":"2026-08-18T00:00:00Z","reason":"test","tickets":["CRE-101"]}' >"$ws/stop-INIT-42.json"

  local output
  output=$(bash -c "
    source '$LIB_DIR/fleet-dispatch.sh'
    $(declare -f _mock_epic_query_with_children)
    _mock_epic_query_with_children
    fleet_dispatch_initiative 'INIT-42' '$ws' 2>&1
  " 2>/dev/null || true)

  echo "$output" | grep -q "stopped" || {
    echo "output: $output"
    return 1
  }
  [ ! -f "$ws/fleet-default-spawn-queue.jsonl" ] || {
    echo "queue should not exist"
    return 1
  }
  return 0
}

test_resume_clears_and_dispatches() {
  local ws
  ws=$(_setup_workspace)
  echo '{"initiative_id":"INIT-42","stopped_at":"2026-08-18T00:00:00Z","reason":"test","tickets":["CRE-101"]}' >"$ws/stop-INIT-42.json"

  local output
  output=$(bash -c "
    source '$LIB_DIR/fleet-dispatch.sh'
    $(declare -f _mock_epic_query_with_children)
    _mock_epic_query_with_children
    $(declare -f _mock_get_issue_blocker_done)
    _mock_get_issue_blocker_done
    fleet_dispatch_initiative 'INIT-42' '$ws' --resume 2>&1
  " 2>/dev/null || true)

  echo "$output" | grep -q "stop-file cleared" || {
    echo "output: $output"
    return 1
  }
  [ ! -f "$ws/stop-INIT-42.json" ] || {
    echo "stop-file should be cleared"
    return 1
  }
  [ -f "$ws/fleet-default-spawn-queue.jsonl" ] || {
    echo "queue should exist"
    return 1
  }
  return 0
}

test_stop_file_inert_to_other_epics() {
  local ws
  ws=$(_setup_workspace)
  echo '{"initiative_id":"INIT-43","stopped_at":"2026-08-18T00:00:00Z","reason":"test","tickets":[]}' >"$ws/stop-INIT-43.json"

  local output
  output=$(bash -c "
    source '$LIB_DIR/fleet-dispatch.sh'
    $(declare -f _mock_epic_query_with_children)
    _mock_epic_query_with_children
    $(declare -f _mock_get_issue_blocker_done)
    _mock_get_issue_blocker_done
    fleet_dispatch_initiative 'INIT-42' '$ws' 2>&1
  " 2>/dev/null || true)

  echo "$output" | grep -q "enqueued" || {
    echo "output: $output"
    return 1
  }
  return 0
}

test_stop_initiative_purges_and_writes_stop_file() {
  local ws
  ws=$(_setup_workspace)
  echo '{"tid":"CRE-101","reason":"planned-dispatch from INIT-42","timestamp":"2026-08-18T00:00:00Z","restarts":0,"dispatch_type":"initial","generation":1}' >"$ws/fleet-default-spawn-queue.jsonl"
  echo '{"tid":"CRE-102","reason":"planned-dispatch from INIT-42","timestamp":"2026-08-18T00:00:00Z","restarts":0,"dispatch_type":"initial","generation":1}' >>"$ws/fleet-default-spawn-queue.jsonl"
  # A run-registry entry with a guaranteed-dead PID — the liveness guard must
  # skip it without a kill and without pinning.
  echo '{"tid":"CRE-102","pid":"999999999","generation":1,"started_at":"2026-08-18T00:00:00Z","reason":"planned-dispatch from INIT-42"}' >"$ws/CRE-102-run.json"

  local output
  output=$(bash -c "
    source '$LIB_DIR/fleet-dispatch.sh'
    fleet_stop_initiative 'INIT-42' 'test reason' '$ws' 2>&1
  " 2>/dev/null || true)

  echo "$output" | grep -q "STOP_RESULT|purged=\[\"CRE-101\",\"CRE-102\"\]|killed=\[\]" || {
    echo "output: $output"
    return 1
  }
  [ -f "$ws/stop-INIT-42.json" ] || {
    echo "stop-file missing"
    return 1
  }
  local tickets
  tickets=$(jq -c '.tickets' "$ws/stop-INIT-42.json" 2>/dev/null)
  [ "$tickets" = '["CRE-101","CRE-102"]' ] || {
    echo "tickets: $tickets"
    return 1
  }
  # Queue purged of both entries.
  [ ! -f "$ws/fleet-default-spawn-queue.jsonl" ] || {
    echo "queue should be gone"
    return 1
  }
  return 0
}

test_stop_initiative_idempotent() {
  local ws
  ws=$(_setup_workspace)

  local output2
  output2=$(bash -c "
    source '$LIB_DIR/fleet-dispatch.sh'
    fleet_stop_initiative 'INIT-42' 'first' '$ws' 2>&1 >/dev/null
    fleet_stop_initiative 'INIT-42' 'second' '$ws' 2>&1
  " 2>/dev/null || true)

  echo "$output2" | grep -q "STOP_RESULT|purged=\[\]|killed=\[\]" || {
    echo "output: $output2"
    return 1
  }
  return 0
}

# F2: purge flock failure must abort the stop — no silent "success" report,
# queue untouched, no stop-file.
test_stop_purge_flock_failure_aborts() {
  local ws
  ws=$(_setup_workspace)
  echo '{"tid":"CRE-101","reason":"planned-dispatch from INIT-42","timestamp":"2026-08-18T00:00:00Z","restarts":0,"dispatch_type":"initial","generation":1}' >"$ws/fleet-default-spawn-queue.jsonl"

  local output rc
  output=$(bash -c "
    flock() { return 1; }
    export -f flock
    FLEET_QUEUE_LOCK_TIMEOUT=1
    source '$LIB_DIR/fleet-dispatch.sh'
    fleet_stop_initiative 'INIT-42' 'test' '$ws' 2>&1
  " 2>/dev/null)
  rc=$?

  [ "$rc" -ne 0 ] || {
    echo "expected non-zero rc on purge flock failure, got $rc; output: $output" >&2
    rm -rf "$ws"
    return 1
  }
  echo "$output" | grep -q "stop aborted" || {
    echo "expected abort message; output: $output" >&2
    rm -rf "$ws"
    return 1
  }
  grep -q "CRE-101" "$ws/fleet-default-spawn-queue.jsonl" || {
    echo "queue entry lost on failed purge" >&2
    rm -rf "$ws"
    return 1
  }
  [ ! -f "$ws/stop-INIT-42.json" ] || {
    echo "stop-file written despite failed purge" >&2
    rm -rf "$ws"
    return 1
  }
  rm -rf "$ws"
  return 0
}

# F2: the purge re-reads the queue UNDER the flock. An append landing when
# the lock is acquired (another epic's dispatch) must survive the rewrite —
# the pre-fix code read first and clobbered such appends with stale content.
test_stop_purge_keeps_entry_appended_at_lock_time() {
  local ws
  ws=$(_setup_workspace)
  echo '{"tid":"CRE-101","reason":"planned-dispatch from INIT-42","timestamp":"2026-08-18T00:00:00Z","restarts":0,"dispatch_type":"initial","generation":1}' >"$ws/fleet-default-spawn-queue.jsonl"

  local output
  output=$(bash -c "
    # On lock acquisition, a concurrent dispatcher for INIT-99 appends its
    # entry — the purge must see it and keep it (it re-reads after flock).
    flock() {
      echo '{\"tid\":\"CRE-201\",\"reason\":\"planned-dispatch from INIT-99\",\"timestamp\":\"2026-08-18T00:00:00Z\",\"restarts\":0,\"dispatch_type\":\"initial\",\"generation\":1}' >>'$ws/fleet-default-spawn-queue.jsonl'
      return 0
    }
    export -f flock
    source '$LIB_DIR/fleet-dispatch.sh'
    fleet_stop_initiative 'INIT-42' 'test' '$ws' 2>&1
  " 2>/dev/null || true)

  grep -q "CRE-201" "$ws/fleet-default-spawn-queue.jsonl" || {
    echo "concurrent append clobbered by purge; queue: $(cat "$ws/fleet-default-spawn-queue.jsonl")" >&2
    rm -rf "$ws"
    return 1
  }
  grep -q "CRE-101" "$ws/fleet-default-spawn-queue.jsonl" && {
    echo "INIT-42 entry not purged; queue: $(cat "$ws/fleet-default-spawn-queue.jsonl")" >&2
    rm -rf "$ws"
    return 1
  }
  rm -rf "$ws"
  return 0
}

# F3: a refused kill (rc != 0) must pin the tid WITHOUT reporting it killed.
test_stop_kill_refused_pins_not_killed() {
  local ws
  ws=$(_setup_workspace)
  sleep 30 &
  local worker_pid=$!
  echo "{\"tid\":\"CRE-102\",\"pid\":\"${worker_pid}\",\"generation\":1,\"started_at\":\"2026-08-18T00:00:00Z\",\"reason\":\"planned-dispatch from INIT-42\"}" >"$ws/CRE-102-run.json"

  local output
  output=$(bash -c "
    fleet_kill_pipeline() { return 1; }
    export -f fleet_kill_pipeline
    source '$LIB_DIR/fleet-dispatch.sh'
    fleet_stop_initiative 'INIT-42' 'test' '$ws' 2>&1
  " 2>/dev/null || true)
  kill "$worker_pid" 2>/dev/null || true

  echo "$output" | grep -q 'STOP_RESULT|purged=\[\]|killed=\[\]|pinned=\["CRE-102"\]' || {
    echo "output: $output" >&2
    rm -rf "$ws"
    return 1
  }
  jq -e '.tickets == ["CRE-102"]' "$ws/stop-INIT-42.json" >/dev/null 2>&1 || {
    echo "stop-file tickets: $(cat "$ws/stop-INIT-42.json")" >&2
    rm -rf "$ws"
    return 1
  }
  rm -rf "$ws"
  return 0
}

# F6: a kill that returns success without terminating (kill-unverified
# survivor) is pinned, never reported killed.
test_stop_unverified_survivor_pinned_not_killed() {
  local ws
  ws=$(_setup_workspace)
  sleep 30 &
  local worker_pid=$!
  echo "{\"tid\":\"CRE-102\",\"pid\":\"${worker_pid}\",\"generation\":1,\"started_at\":\"2026-08-18T00:00:00Z\",\"reason\":\"planned-dispatch from INIT-42\"}" >"$ws/CRE-102-run.json"

  local output
  output=$(bash -c "
    fleet_kill_pipeline() { return 0; }
    export -f fleet_kill_pipeline
    source '$LIB_DIR/fleet-dispatch.sh'
    fleet_stop_initiative 'INIT-42' 'test' '$ws' 2>&1
  " 2>/dev/null || true)
  kill "$worker_pid" 2>/dev/null || true

  echo "$output" | grep -q 'killed=\[\]|pinned=\["CRE-102"\]' || {
    echo "output: $output" >&2
    rm -rf "$ws"
    return 1
  }
  jq -e '.tickets == ["CRE-102"]' "$ws/stop-INIT-42.json" >/dev/null 2>&1 || {
    echo "stop-file tickets: $(cat "$ws/stop-INIT-42.json")" >&2
    rm -rf "$ws"
    return 1
  }
  rm -rf "$ws"
  return 0
}

# F6: a dead worker with NO queue entry must be pinned on the FIRST stop —
# otherwise restart reconciliation resurrects the stopped epic's ticket.
test_stop_dead_worker_without_queue_entry_pinned() {
  local ws
  ws=$(_setup_workspace)
  echo '{"tid":"CRE-102","pid":"999999999","generation":1,"started_at":"2026-08-18T00:00:00Z","reason":"planned-dispatch from INIT-42"}' >"$ws/CRE-102-run.json"

  local output
  output=$(bash -c "
    source '$LIB_DIR/fleet-dispatch.sh'
    fleet_stop_initiative 'INIT-42' 'test' '$ws' 2>&1
  " 2>/dev/null || true)

  echo "$output" | grep -q 'purged=\[\]|killed=\[\]|pinned=\["CRE-102"\]' || {
    echo "output: $output" >&2
    rm -rf "$ws"
    return 1
  }
  jq -e '.tickets == ["CRE-102"]' "$ws/stop-INIT-42.json" >/dev/null 2>&1 || {
    echo "stop-file tickets: $(cat "$ws/stop-INIT-42.json")" >&2
    rm -rf "$ws"
    return 1
  }
  rm -rf "$ws"
  return 0
}

_run "dispatch_resumes_incomplete_child" test_dispatch_resumes_incomplete_child
_run "dispatch_dry_run_resume_leaves_queue_untouched" test_dispatch_dry_run_resume_leaves_queue_untouched
_run "dispatch_dead_log_does_not_jam_campaign" test_dispatch_dead_log_does_not_jam_campaign
_run "dispatch_reserves_queued_for_epic_slots" test_dispatch_reserves_queued_for_epic_slots
_run "dispatch_reports_blocked_children" test_dispatch_reports_blocked_children
_run "stop_pins_incomplete_child_with_empty_queue" test_stop_pins_incomplete_child_with_empty_queue
_run "stop_purges_campaign_resume_and_child_tid_entries" test_stop_purges_campaign_resume_and_child_tid_entries
_run "stop_children_query_failure_degrades" test_stop_children_query_failure_degrades
_run "stop_purge_flock_failure_aborts" test_stop_purge_flock_failure_aborts
_run "stop_purge_keeps_entry_appended_at_lock_time" test_stop_purge_keeps_entry_appended_at_lock_time
_run "stop_kill_refused_pins_not_killed" test_stop_kill_refused_pins_not_killed
_run "stop_unverified_survivor_pinned_not_killed" test_stop_unverified_survivor_pinned_not_killed
_run "stop_dead_worker_without_queue_entry_pinned" test_stop_dead_worker_without_queue_entry_pinned
_run "concurrent_same_epic_dispatch_single_entry" test_concurrent_same_epic_dispatch_single_entry
_run "dispatch_lock_different_epics_do_not_block" test_dispatch_lock_different_epics_do_not_block
_run "stopped_epic_enqueues_nothing" test_stopped_epic_enqueues_nothing
_run "resume_clears_and_dispatches" test_resume_clears_and_dispatches
_run "stop_file_inert_to_other_epics" test_stop_file_inert_to_other_epics
_run "stop_initiative_purges_and_writes_stop_file" test_stop_initiative_purges_and_writes_stop_file
_run "stop_initiative_idempotent" test_stop_initiative_idempotent

echo ""
echo "=== Results ==="
echo "PASS: $PASS | FAIL: $FAIL"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
