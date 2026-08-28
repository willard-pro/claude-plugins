#!/usr/bin/env bash
# test-detect-epic-branch-ready.sh — tests for the D-12 epic-branch-readiness
# detector's actuation wiring (epic_branch_open_pr) and its use of the
# canonical epic_branch_children_done helper.
# Usage: bash test-detect-epic-branch-ready.sh [test_name_filter]
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TAP_LIB_DIR="$(cd "$LIB_DIR/../../ticket-auto-pipeline/lib" && pwd)"

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

# ── Stubs (CI-safe, before sourcing the library) ───────────────────────────────

if ! declare -f get_issue >/dev/null 2>&1; then
  # Unwrapped shape — get_issue in linear-api.sh returns .data.issue itself.
  get_issue() { echo '{"identifier":"STUB","description":""}'; }
fi

source "$TAP_LIB_DIR/planned-ticket-check.sh" 2>/dev/null || true
source "$TAP_LIB_DIR/branch-directive-check.sh" 2>/dev/null || true
source "$TAP_LIB_DIR/epic-branch.sh" 2>/dev/null || true
source "$LIB_DIR/fleet-detect.sh" 2>/dev/null || true

# ── Fixtures ────────────────────────────────────────────────────────────────────

VALID_DIRECTIVE='## Branch Directive
**Schema-Version:** 1
**Branch:** epic/test-branch
**Base:** develop
**Merge Policy:** manual
**Sync Policy:** none
**Created:** 2026-07-25T10:00:00Z'

# GraphQL response the detector's curl would return. _FIXTURE_EPICS_JSON env
# selects between: all children Done, one child in progress, or no directive.
_mock_linear_curl() {
  curl() {
    cat >/dev/null # consume the -d @- body
    echo "$_FIXTURE_EPICS_JSON"
  }
}

_make_epics_json() {
  local children="$1" description="$2" epic_state="${3:-Backlog}"
  jq -nc \
    --argjson children "$children" \
    --arg description "$description" \
    --arg state "$epic_state" \
    '{data:{issues:{nodes:[{id:"e1",identifier:"INIT-42",description:$description,state:{name:$state},children:{nodes:$children}}]}}}'
}

# JSONL children streams (one child object per line) — the format
# epic_branch_children_done consumes. Children carry the planned label: the
# readiness contract is "planned children are all Done".
ALL_DONE_CHILDREN='{"id":"c1","identifier":"CRE-1","state":{"name":"Done"},"labels":{"nodes":[{"name":"planned"}]}}
{"id":"c2","identifier":"CRE-2","state":{"name":"Done"},"labels":{"nodes":[{"name":"planned"}]}}'

ONE_IN_PROGRESS_CHILDREN='{"id":"c1","identifier":"CRE-1","state":{"name":"Done"},"labels":{"nodes":[{"name":"planned"}]}}
{"id":"c2","identifier":"CRE-2","state":{"name":"In Progress"},"labels":{"nodes":[{"name":"planned"}]}}'

# Compact JSON arrays for the GraphQL fixture (children.nodes is an array).
ALL_DONE_CHILDREN_ARR='[{"id":"c1","identifier":"CRE-1","state":{"name":"Done"},"labels":{"nodes":[{"name":"planned"}]}},{"id":"c2","identifier":"CRE-2","state":{"name":"Done"},"labels":{"nodes":[{"name":"planned"}]}}]'
ONE_IN_PROGRESS_CHILDREN_ARR='[{"id":"c1","identifier":"CRE-1","state":{"name":"Done"},"labels":{"nodes":[{"name":"planned"}]}},{"id":"c2","identifier":"CRE-2","state":{"name":"In Progress"},"labels":{"nodes":[{"name":"planned"}]}}]'

# A non-planned child (future work) that must not block readiness.
NON_PLANNED_CHILD_ARR='[{"id":"c1","identifier":"CRE-1","state":{"name":"Done"},"labels":{"nodes":[{"name":"planned"}]}},{"id":"c2","identifier":"CRE-2","state":{"name":"Todo"},"labels":{"nodes":[]}}]'

# Fixture REPOS_ROOT: two git repos (tracked set) + one non-git dir.
_make_repos_root() {
  local root="$1"
  mkdir -p "$root/repo-a" "$root/repo-b" "$root/not-a-repo"
  git -C "$root/repo-a" init -q -b main 2>/dev/null || git -C "$root/repo-a" init -q
  git -C "$root/repo-b" init -q -b main 2>/dev/null || git -C "$root/repo-b" init -q
}

# Record epic_branch_open_pr invocations into _OPEN_PR_CALLS (global).
_mock_open_pr_recorder() {
  _OPEN_PR_CALLS="$1"
  epic_branch_open_pr() {
    echo "$2" >>"$_OPEN_PR_CALLS"
    EPIC_BRANCH_PR_STATE="open"
    return 0
  }
}

# Recorder that returns success WITHOUT any PR existing — the shape the real
# helper takes when the repo has no epic commits, or nothing was opened. Exit 0
# here must NOT be read as evidence that a PR is open.
_mock_open_pr_no_pr() {
  _OPEN_PR_CALLS="$1"
  epic_branch_open_pr() {
    echo "$2" >>"$_OPEN_PR_CALLS"
    EPIC_BRANCH_PR_STATE="none"
    return 0
  }
}

# Like _mock_open_pr_recorder, but also writes prose to stdout — this is what
# the real epic_branch_open_pr does (progress lines, the created PR URL). The
# detector's own stdout is captured by command substitution, so any leak here
# corrupts its JSON result.
_mock_open_pr_noisy() {
  _OPEN_PR_CALLS="$1"
  epic_branch_open_pr() {
    echo "$2" >>"$_OPEN_PR_CALLS"
    echo "epic-branch: opening integration PR for $1 in $2"
    echo "https://github.com/example/repo/pull/42"
    EPIC_BRANCH_PR_STATE="open"
    return 0
  }
}

# Run the detector in a clean subshell with the given env, capture stdout.
# Ordering matters: the real epic-branch.sh is sourced BEFORE the open_pr
# recorder mock is installed, so the detector's lazy `! declare -f
# epic_branch_children_done` source is skipped and the mock survives.
_run_detector() {
  local ws="$1" repos_root="$2" auto_pr="$3" calls_file="$4" fixture="$5"
  local children_arr="${6:-$ALL_DONE_CHILDREN_ARR}"
  bash -c "
    get_issue() { echo '{\"identifier\":\"STUB\",\"description\":\"\"}'; }
    _STUB_CHILDREN='$children_arr'
    get_parent_with_children() { echo '{\"children\":'\"\$_STUB_CHILDREN\"'}'; }
    source '$TAP_LIB_DIR/planned-ticket-check.sh' 2>/dev/null || true
    source '$TAP_LIB_DIR/branch-directive-check.sh' 2>/dev/null || true
    source '$TAP_LIB_DIR/epic-branch.sh' 2>/dev/null || true
    _FIXTURE_EPICS_JSON='$fixture'
    $(declare -f _mock_linear_curl _mock_open_pr_recorder)
    _mock_linear_curl
    _mock_open_pr_recorder '$calls_file'
    REPOS_ROOT='$repos_root'
    FLEET_EPIC_AUTO_PR='$auto_pr'
    FLEET_PIPELINE_LOG_DIR='$ws'
    source '$LIB_DIR/fleet-detect.sh'
    _fleet_scan_epic_branch_ready '$ws' 2>/dev/null
  " 2>/dev/null || true
}

# Run the detector with a recording stub for the state-advancement helper, so
# tests can assert how many times (and whether) the epic was advanced.
_run_detector_recording_advance() {
  local ws="$1" repos_root="$2" calls_file="$3" fixture="$4" advance_file="$5" mock_fn="${6:-_mock_open_pr_recorder}"
  bash -c "
    get_issue() { echo '{\"identifier\":\"STUB\",\"description\":\"\"}'; }
    _STUB_CHILDREN='$ALL_DONE_CHILDREN_ARR'
    get_parent_with_children() { echo '{\"children\":'\"\$_STUB_CHILDREN\"'}'; }
    source '$TAP_LIB_DIR/planned-ticket-check.sh' 2>/dev/null || true
    source '$TAP_LIB_DIR/branch-directive-check.sh' 2>/dev/null || true
    source '$TAP_LIB_DIR/epic-branch.sh' 2>/dev/null || true
    _FIXTURE_EPICS_JSON='$fixture'
    $(declare -f _mock_linear_curl _mock_open_pr_recorder _mock_open_pr_noisy _mock_open_pr_no_pr)
    _mock_linear_curl
    $mock_fn '$calls_file'
    REPOS_ROOT='$repos_root'
    FLEET_EPIC_AUTO_PR='true'
    FLEET_PIPELINE_LOG_DIR='$ws'
    source '$LIB_DIR/fleet-detect.sh'
    _fleet_advance_epic_state() { echo \"\$1\" >> '$advance_file'; return 0; }
    _fleet_scan_epic_branch_ready '$ws' 2>/dev/null
  " 2>/dev/null || true
}

# ── Tests ───────────────────────────────────────────────────────────────────────

test_opens_pr_once_per_tracked_repo_when_ready() {
  local ws
  ws=$(mktemp -d)
  local repos_root="${ws}/repos"
  _make_repos_root "$repos_root"
  local calls_file="${ws}/calls.log"
  rm -f "$calls_file"

  local fixture
  fixture=$(_make_epics_json "$ALL_DONE_CHILDREN_ARR" "$VALID_DIRECTIVE")
  local out
  out=$(_run_detector "$ws" "$repos_root" "true" "$calls_file" "$fixture")

  # Finding reported at severity 1
  [ "$(echo "$out" | jq -r '.severity')" = "1" ] || {
    echo "expected severity 1, got: $out" >&2
    return 1
  }
  # open_pr called once per tracked git repo, never for the non-git dir
  local a_count b_count n_count
  a_count=$(grep -c "repo-a" "$calls_file" 2>/dev/null || true)
  b_count=$(grep -c "repo-b" "$calls_file" 2>/dev/null || true)
  n_count=$(grep -c "not-a-repo" "$calls_file" 2>/dev/null || true)
  [ "$a_count" = "1" ] && [ "$b_count" = "1" ] && [ "$n_count" = "0" ] || {
    echo "expected one call per tracked repo (a=1,b=1,n=0), got a=$a_count b=$b_count n=$n_count; calls: $(cat "$calls_file" 2>/dev/null)" >&2
    return 1
  }
  return 0
}

test_no_pr_when_not_ready() {
  local ws
  ws=$(mktemp -d)
  local repos_root="${ws}/repos"
  _make_repos_root "$repos_root"
  local calls_file="${ws}/calls.log"
  rm -f "$calls_file"

  local fixture
  fixture=$(_make_epics_json "$ONE_IN_PROGRESS_CHILDREN_ARR" "$VALID_DIRECTIVE")
  local out
  out=$(_run_detector "$ws" "$repos_root" "true" "$calls_file" "$fixture")

  [ "$(echo "$out" | jq -r '.severity')" = "0" ] || {
    echo "expected severity 0 when not ready, got: $out" >&2
    return 1
  }
  [ ! -s "$calls_file" ] || {
    echo "open_pr called despite not ready: $(cat "$calls_file")" >&2
    return 1
  }
  return 0
}

test_no_pr_when_auto_pr_disabled_but_finding_reported() {
  local ws
  ws=$(mktemp -d)
  local repos_root="${ws}/repos"
  _make_repos_root "$repos_root"
  local calls_file="${ws}/calls.log"
  rm -f "$calls_file"

  local fixture
  fixture=$(_make_epics_json "$ALL_DONE_CHILDREN_ARR" "$VALID_DIRECTIVE")

  # Unset FLEET_EPIC_AUTO_PR (default false)
  local out
  out=$(bash -c "
    get_issue() { echo '{\"identifier\":\"STUB\",\"description\":\"\"}'; }
    source '$TAP_LIB_DIR/planned-ticket-check.sh' 2>/dev/null || true
    source '$TAP_LIB_DIR/branch-directive-check.sh' 2>/dev/null || true
    source '$TAP_LIB_DIR/epic-branch.sh' 2>/dev/null || true
    _FIXTURE_EPICS_JSON='$fixture'
    $(declare -f _mock_linear_curl _mock_open_pr_recorder)
    _mock_linear_curl
    _mock_open_pr_recorder '$calls_file'
    REPOS_ROOT='$repos_root'
    FLEET_PIPELINE_LOG_DIR='$ws'
    source '$LIB_DIR/fleet-detect.sh'
    _fleet_scan_epic_branch_ready '$ws' 2>/dev/null
  " 2>/dev/null || true)

  [ "$(echo "$out" | jq -r '.severity')" = "1" ] || {
    echo "expected severity 1 (finding reported) with auto-pr off, got: $out" >&2
    return 1
  }
  [ ! -s "$calls_file" ] || {
    echo "open_pr called despite FLEET_EPIC_AUTO_PR disabled: $(cat "$calls_file")" >&2
    return 1
  }
  return 0
}

test_repeated_cycles_are_noops_via_helper_idempotency() {
  local ws
  ws=$(mktemp -d)
  local repos_root="${ws}/repos"
  _make_repos_root "$repos_root"
  local calls_file="${ws}/calls.log"
  rm -f "$calls_file"

  local fixture
  fixture=$(_make_epics_json "$ALL_DONE_CHILDREN_ARR" "$VALID_DIRECTIVE")

  _run_detector "$ws" "$repos_root" "true" "$calls_file" "$fixture" >/dev/null
  _run_detector "$ws" "$repos_root" "true" "$calls_file" "$fixture" >/dev/null

  # The detector delegates idempotency to epic_branch_open_pr (existing-PR
  # check, unit-tested in test-epic-branch.sh). At the detector level the
  # second cycle must produce identical per-repo call coverage — the recorder
  # mock counts every call, so two cycles yield two calls per repo and no
  # detector-level explosion or drift.
  local a_count b_count
  a_count=$(grep -c "repo-a" "$calls_file" 2>/dev/null || true)
  b_count=$(grep -c "repo-b" "$calls_file" 2>/dev/null || true)
  [ "$a_count" = "2" ] && [ "$b_count" = "2" ] || {
    echo "expected 2 calls per repo across 2 cycles, got a=$a_count b=$b_count" >&2
    return 1
  }
  return 0
}

test_never_merges_regardless_of_config() {
  local ws
  ws=$(mktemp -d)
  local repos_root="${ws}/repos"
  _make_repos_root "$repos_root"
  local calls_file="${ws}/calls.log"
  local gh_log="${ws}/gh.log"
  rm -f "$calls_file" "$gh_log"

  local fixture
  fixture=$(_make_epics_json "$ALL_DONE_CHILDREN_ARR" "$VALID_DIRECTIVE")

  # Wrap gh so any merge invocation is recorded — none may ever occur from
  # the detector, regardless of FLEET_EPIC_AUTO_PR.
  bash -c "
    gh() { echo \"gh \$*\" >> '$gh_log'; return 0; }
    export -f gh
    get_issue() { echo '{\"identifier\":\"STUB\",\"description\":\"\"}'; }
    source '$TAP_LIB_DIR/planned-ticket-check.sh' 2>/dev/null || true
    source '$TAP_LIB_DIR/branch-directive-check.sh' 2>/dev/null || true
    source '$TAP_LIB_DIR/epic-branch.sh' 2>/dev/null || true
    _FIXTURE_EPICS_JSON='$fixture'
    $(declare -f _mock_linear_curl _mock_open_pr_recorder)
    _mock_linear_curl
    _mock_open_pr_recorder '$calls_file'
    REPOS_ROOT='$repos_root'
    FLEET_EPIC_AUTO_PR=true
    FLEET_PIPELINE_LOG_DIR='$ws'
    source '$LIB_DIR/fleet-detect.sh'
    _fleet_scan_epic_branch_ready '$ws' >/dev/null 2>&1
  " >/dev/null 2>&1 || true

  ! grep -q "merge" "$gh_log" 2>/dev/null || {
    echo "gh merge invoked from detector: $(cat "$gh_log")" >&2
    return 1
  }
  return 0
}

test_readiness_matches_children_done_helper() {
  local ws
  ws=$(mktemp -d)

  # Same children fixture fed to both the helper and the detector — the
  # detector's severity must agree with the helper's exit code in both
  # ready and not-ready cases.
  local ready_out notready_out helper_ready helper_notready
  helper_ready=0
  helper_notready=0

  epic_branch_children_done "INIT-42" "$ALL_DONE_CHILDREN" 2>/dev/null || helper_ready=$?
  epic_branch_children_done "INIT-42" "$ONE_IN_PROGRESS_CHILDREN" 2>/dev/null || helper_notready=$?

  ready_out=$(bash -c "
    get_issue() { echo '{\"identifier\":\"STUB\",\"description\":\"\"}'; }
    _FIXTURE_EPICS_JSON='$(_make_epics_json "$ALL_DONE_CHILDREN_ARR" "$VALID_DIRECTIVE")'
    $(declare -f _mock_linear_curl)
    _mock_linear_curl
    FLEET_PIPELINE_LOG_DIR='$ws'
    source '$LIB_DIR/fleet-detect.sh'
    _fleet_scan_epic_branch_ready '$ws' 2>/dev/null
  " 2>/dev/null || true)

  notready_out=$(bash -c "
    get_issue() { echo '{\"identifier\":\"STUB\",\"description\":\"\"}'; }
    _FIXTURE_EPICS_JSON='$(_make_epics_json "$ONE_IN_PROGRESS_CHILDREN_ARR" "$VALID_DIRECTIVE")'
    $(declare -f _mock_linear_curl)
    _mock_linear_curl
    FLEET_PIPELINE_LOG_DIR='$ws'
    source '$LIB_DIR/fleet-detect.sh'
    _fleet_scan_epic_branch_ready '$ws' 2>/dev/null
  " 2>/dev/null || true)

  [ "$helper_ready" = "0" ] || {
    echo "helper should report ready for all-done fixture (rc=$helper_ready)" >&2
    return 1
  }
  [ "$helper_notready" != "0" ] || {
    echo "helper should report not-ready for in-progress fixture" >&2
    return 1
  }
  [ "$(echo "$ready_out" | jq -r '.severity')" = "1" ] || {
    echo "detector should report ready (sev 1) for all-done fixture: $ready_out" >&2
    return 1
  }
  [ "$(echo "$notready_out" | jq -r '.severity')" = "0" ] || {
    echo "detector should report not-ready (sev 0) for in-progress fixture: $notready_out" >&2
    return 1
  }
  return 0
}

test_non_planned_child_does_not_block_ready() {
  local ws
  ws=$(mktemp -d)
  local repos_root="${ws}/repos"
  _make_repos_root "$repos_root"
  local calls_file="${ws}/calls.log"
  rm -f "$calls_file"

  local fixture
  fixture=$(_make_epics_json "$NON_PLANNED_CHILD_ARR" "$VALID_DIRECTIVE")
  local out
  out=$(_run_detector "$ws" "$repos_root" "true" "$calls_file" "$fixture")

  [ "$(echo "$out" | jq -r '.severity')" = "1" ] || {
    echo "expected severity 1 (non-planned child must not block), got: $out" >&2
    return 1
  }
  [ -s "$calls_file" ] || {
    echo "open_pr not called despite readiness" >&2
    return 1
  }
  return 0
}

test_no_directive_never_reaches_actuation() {
  local ws
  ws=$(mktemp -d)
  local repos_root="${ws}/repos"
  _make_repos_root "$repos_root"
  local calls_file="${ws}/calls.log"
  rm -f "$calls_file"

  local fixture
  fixture=$(_make_epics_json "$ALL_DONE_CHILDREN_ARR" "No directive here.")
  local out
  out=$(_run_detector "$ws" "$repos_root" "true" "$calls_file" "$fixture")

  [ "$(echo "$out" | jq -r '.severity')" = "0" ] || {
    echo "expected severity 0 without directive, got: $out" >&2
    return 1
  }
  [ ! -s "$calls_file" ] || {
    echo "open_pr called without directive: $(cat "$calls_file")" >&2
    return 1
  }
  return 0
}

test_actuation_stdout_does_not_contaminate_result() {
  local ws
  ws=$(mktemp -d)
  local repos_root="${ws}/repos"
  _make_repos_root "$repos_root"
  local calls_file="${ws}/calls.log"
  rm -f "$calls_file"

  local fixture
  fixture=$(_make_epics_json "$ALL_DONE_CHILDREN_ARR" "$VALID_DIRECTIVE")

  local out
  out=$(bash -c "
    get_issue() { echo '{\"identifier\":\"STUB\",\"description\":\"\"}'; }
    source '$TAP_LIB_DIR/planned-ticket-check.sh' 2>/dev/null || true
    source '$TAP_LIB_DIR/branch-directive-check.sh' 2>/dev/null || true
    source '$TAP_LIB_DIR/epic-branch.sh' 2>/dev/null || true
    _FIXTURE_EPICS_JSON='$fixture'
    $(declare -f _mock_linear_curl _mock_open_pr_noisy)
    _mock_linear_curl
    _mock_open_pr_noisy '$calls_file'
    REPOS_ROOT='$repos_root'
    FLEET_EPIC_AUTO_PR='true'
    FLEET_PIPELINE_LOG_DIR='$ws'
    source '$LIB_DIR/fleet-detect.sh'
    _fleet_scan_epic_branch_ready '$ws' 2>/dev/null
  " 2>/dev/null || true)

  # Guard against a vacuous assertion: the PR path must actually have run,
  # otherwise there was no output to contaminate with.
  [ -s "$calls_file" ] || {
    echo "open_pr never invoked — purity assertion would be vacuous" >&2
    return 1
  }

  echo "$out" | jq -e . >/dev/null 2>&1 || {
    echo "detector stdout is not parseable JSON: $out" >&2
    return 1
  }
  [ "$(echo "$out" | jq -r '.severity')" = "1" ] || {
    echo "expected severity 1, got: $out" >&2
    return 1
  }
  if echo "$out" | command grep -q "pull/42"; then
    echo "actuation stdout leaked into detector result: $out" >&2
    return 1
  fi
  return 0
}

test_epic_already_advanced_is_skipped_before_repo_work() {
  local ws
  ws=$(mktemp -d)
  local repos_root="${ws}/repos"
  _make_repos_root "$repos_root"
  local calls_file="${ws}/calls.log"
  local advance_file="${ws}/advance.log"
  rm -f "$calls_file" "$advance_file"

  # Epic already at Review — an operator (or an earlier cycle) advanced it.
  local fixture
  fixture=$(_make_epics_json "$ALL_DONE_CHILDREN_ARR" "$VALID_DIRECTIVE" "Review")
  local out
  out=$(_run_detector_recording_advance "$ws" "$repos_root" "$calls_file" "$fixture" "$advance_file")

  # Skipped before ANY per-repository work.
  [ ! -s "$calls_file" ] || {
    echo "  per-repo work performed for an already-advanced epic: $(cat "$calls_file")" >&2
    return 1
  }
  [ ! -s "$advance_file" ] || {
    echo "  epic state advanced again — this is the regression loop: $(cat "$advance_file")" >&2
    return 1
  }
  [ "$(echo "$out" | jq -r '.severity')" = "0" ] || {
    echo "  expected severity 0 for a skipped epic, got: $out" >&2
    return 1
  }
  return 0
}

test_completed_epic_is_not_rescanned() {
  # state:execution is never removed, so without the guard a Done epic is
  # rescanned — repo loop included — on every cycle forever.
  local ws
  ws=$(mktemp -d)
  local repos_root="${ws}/repos"
  _make_repos_root "$repos_root"
  local calls_file="${ws}/calls.log"
  local advance_file="${ws}/advance.log"
  rm -f "$calls_file" "$advance_file"

  local fixture
  fixture=$(_make_epics_json "$ALL_DONE_CHILDREN_ARR" "$VALID_DIRECTIVE" "Done")
  _run_detector_recording_advance "$ws" "$repos_root" "$calls_file" "$fixture" "$advance_file" >/dev/null

  [ ! -s "$calls_file" ] || {
    echo "  completed epic was rescanned: $(cat "$calls_file")" >&2
    return 1
  }
  return 0
}

test_epic_not_regressed_across_repeated_cycles() {
  local ws
  ws=$(mktemp -d)
  local repos_root="${ws}/repos"
  _make_repos_root "$repos_root"
  local calls_file="${ws}/calls.log"
  local advance_file="${ws}/advance.log"
  rm -f "$calls_file" "$advance_file"

  # Cycle 1: epic still in Backlog — advancement expected exactly once.
  local fixture_before
  fixture_before=$(_make_epics_json "$ALL_DONE_CHILDREN_ARR" "$VALID_DIRECTIVE" "Backlog")
  _run_detector_recording_advance "$ws" "$repos_root" "$calls_file" "$fixture_before" "$advance_file" >/dev/null

  local first_count
  first_count=$(grep -c "INIT-42" "$advance_file" 2>/dev/null || true)
  [ "$first_count" = "1" ] || {
    echo "  expected exactly 1 advancement on the first cycle, got $first_count" >&2
    return 1
  }

  # Cycles 2 and 3: the epic is now at Review — no further advancement, ever.
  local fixture_after
  fixture_after=$(_make_epics_json "$ALL_DONE_CHILDREN_ARR" "$VALID_DIRECTIVE" "Review")
  _run_detector_recording_advance "$ws" "$repos_root" "$calls_file" "$fixture_after" "$advance_file" >/dev/null
  _run_detector_recording_advance "$ws" "$repos_root" "$calls_file" "$fixture_after" "$advance_file" >/dev/null

  local total
  total=$(grep -c "INIT-42" "$advance_file" 2>/dev/null || true)
  [ "$total" = "1" ] || {
    echo "  epic advanced $total times across 3 cycles — expected 1" >&2
    return 1
  }
  return 0
}

test_advance_once_per_epic_not_per_repo() {
  local ws
  ws=$(mktemp -d)
  local repos_root="${ws}/repos"
  _make_repos_root "$repos_root"
  local calls_file="${ws}/calls.log"
  local advance_file="${ws}/advance.log"
  rm -f "$calls_file" "$advance_file"

  local fixture
  fixture=$(_make_epics_json "$ALL_DONE_CHILDREN_ARR" "$VALID_DIRECTIVE" "Backlog")
  _run_detector_recording_advance "$ws" "$repos_root" "$calls_file" "$fixture" "$advance_file" >/dev/null

  # Two tracked repos were visited...
  local repo_calls
  repo_calls=$(grep -c "repo-" "$calls_file" 2>/dev/null || true)
  [ "$repo_calls" = "2" ] || {
    echo "  expected 2 per-repo calls, got $repo_calls" >&2
    return 1
  }
  # ...but the epic advanced exactly once.
  local advances
  advances=$(grep -c "INIT-42" "$advance_file" 2>/dev/null || true)
  [ "$advances" = "1" ] || {
    echo "  expected 1 advancement across 2 repos, got $advances" >&2
    return 1
  }
  return 0
}

test_no_advance_when_no_pr_observed() {
  # The PR helper returns success while opening nothing. Loop completion must
  # not be mistaken for evidence that an integration PR exists.
  local ws
  ws=$(mktemp -d)
  local repos_root="${ws}/repos"
  _make_repos_root "$repos_root"
  local calls_file="${ws}/calls.log"
  local advance_file="${ws}/advance.log"
  rm -f "$calls_file" "$advance_file"

  local fixture
  fixture=$(_make_epics_json "$ALL_DONE_CHILDREN_ARR" "$VALID_DIRECTIVE" "Backlog")
  _run_detector_recording_advance "$ws" "$repos_root" "$calls_file" "$fixture" "$advance_file" "_mock_open_pr_no_pr" >/dev/null

  # The loop ran over both repos and returned success...
  [ -s "$calls_file" ] || {
    echo "  PR routine never invoked — assertion would be vacuous" >&2
    return 1
  }
  # ...and the epic was NOT advanced.
  [ ! -s "$advance_file" ] || {
    echo "  epic advanced with zero PRs open: $(cat "$advance_file")" >&2
    return 1
  }
  return 0
}

# ── Run all tests ────────────────────────────────────────────────────────────────

_run "opens_pr_once_per_tracked_repo_when_ready" test_opens_pr_once_per_tracked_repo_when_ready
_run "no_pr_when_not_ready" test_no_pr_when_not_ready
_run "no_pr_when_auto_pr_disabled_but_finding_reported" test_no_pr_when_auto_pr_disabled_but_finding_reported
_run "repeated_cycles_are_noops_via_helper_idempotency" test_repeated_cycles_are_noops_via_helper_idempotency
_run "never_merges_regardless_of_config" test_never_merges_regardless_of_config
_run "readiness_matches_children_done_helper" test_readiness_matches_children_done_helper
_run "non-planned child does not block ready" test_non_planned_child_does_not_block_ready
_run "no_directive_never_reaches_actuation" test_no_directive_never_reaches_actuation
_run "actuation_stdout_does_not_contaminate_result" test_actuation_stdout_does_not_contaminate_result
_run "epic already advanced is skipped before repo work" test_epic_already_advanced_is_skipped_before_repo_work
_run "completed epic is not rescanned" test_completed_epic_is_not_rescanned
_run "epic is not regressed across repeated cycles" test_epic_not_regressed_across_repeated_cycles
_run "advancement is once per epic, not per repo" test_advance_once_per_epic_not_per_repo
_run "no advancement when no PR is observed open" test_no_advance_when_no_pr_observed

echo ""
echo "=== Results ==="
echo "PASS: $PASS | FAIL: $FAIL"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
