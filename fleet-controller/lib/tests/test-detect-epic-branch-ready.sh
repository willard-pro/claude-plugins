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
  get_issue() { echo '{"data":{"issue":{"identifier":"STUB","description":""}}}'; }
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
  local children="$1" description="$2"
  jq -nc \
    --argjson children "$children" \
    --arg description "$description" \
    '{data:{issues:{nodes:[{id:"e1",identifier:"INIT-42",description:$description,children:{nodes:$children}}]}}}'
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
    return 0
  }
}

# Run the detector in a clean subshell with the given env, capture stdout.
# Ordering matters: the real epic-branch.sh is sourced BEFORE the open_pr
# recorder mock is installed, so the detector's lazy `! declare -f
# epic_branch_children_done` source is skipped and the mock survives.
_run_detector() {
  local ws="$1" repos_root="$2" auto_pr="$3" calls_file="$4" fixture="$5"
  bash -c "
    get_issue() { echo '{\"data\":{\"issue\":{\"identifier\":\"STUB\",\"description\":\"\"}}}'; }
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
    get_issue() { echo '{\"data\":{\"issue\":{\"identifier\":\"STUB\",\"description\":\"\"}}}'; }
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
    get_issue() { echo '{\"data\":{\"issue\":{\"identifier\":\"STUB\",\"description\":\"\"}}}'; }
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
    _FIXTURE_EPICS_JSON='$(_make_epics_json "$ALL_DONE_CHILDREN_ARR" "$VALID_DIRECTIVE")'
    $(declare -f _mock_linear_curl)
    _mock_linear_curl
    FLEET_PIPELINE_LOG_DIR='$ws'
    source '$LIB_DIR/fleet-detect.sh'
    _fleet_scan_epic_branch_ready '$ws' 2>/dev/null
  " 2>/dev/null || true)

  notready_out=$(bash -c "
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

# ── Run all tests ────────────────────────────────────────────────────────────────

_run "opens_pr_once_per_tracked_repo_when_ready" test_opens_pr_once_per_tracked_repo_when_ready
_run "no_pr_when_not_ready" test_no_pr_when_not_ready
_run "no_pr_when_auto_pr_disabled_but_finding_reported" test_no_pr_when_auto_pr_disabled_but_finding_reported
_run "repeated_cycles_are_noops_via_helper_idempotency" test_repeated_cycles_are_noops_via_helper_idempotency
_run "never_merges_regardless_of_config" test_never_merges_regardless_of_config
_run "readiness_matches_children_done_helper" test_readiness_matches_children_done_helper
_run "non-planned child does not block ready" test_non_planned_child_does_not_block_ready
_run "no_directive_never_reaches_actuation" test_no_directive_never_reaches_actuation

echo ""
echo "=== Results ==="
echo "PASS: $PASS | FAIL: $FAIL"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
