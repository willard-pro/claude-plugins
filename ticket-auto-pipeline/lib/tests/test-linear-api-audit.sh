#!/usr/bin/env bash
# test-linear-api-audit.sh — unit tests for audit API functions in lib/linear-api.sh
# All tests mock linear_graphql — no network required.
# Requires: bash, jq
# Usage: bash test-linear-api-audit.sh [test_name_filter]
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

# ── get_project_milestones tests ───────────────────────────────────────────────

test_get_project_milestones_returns_array() {
  local result
  result=$(bash -c "
    source $LIB_DIR/linear-api.sh
    linear_graphql() { echo '{\"data\":{\"project\":{\"milestones\":{\"nodes\":[{\"id\":\"m1\",\"name\":\"Sprint 1\",\"description\":\"First sprint\",\"targetDate\":\"2026-06-15\",\"status\":\"active\"}]}}}}'; }
    get_project_milestones 'p1'
  " 2>/dev/null) || true
  echo "$result" | jq -e 'type == "array" and .[0].id == "m1"' >/dev/null
}

test_get_project_milestones_empty_array() {
  local result
  result=$(bash -c "
    source $LIB_DIR/linear-api.sh
    linear_graphql() { echo '{\"data\":{\"project\":{\"milestones\":{\"nodes\":[]}}}}'; }
    get_project_milestones 'p1'
  " 2>/dev/null) || true
  echo "$result" | jq -e 'type == "array" and length == 0' >/dev/null
}

test_get_project_milestones_handles_graphql_error() {
  local exit_code=0
  LINEAR_API_KEY=test bash -c "
    source $LIB_DIR/linear-api.sh
    linear_graphql() { echo '{\"errors\":[{\"message\":\"Project not found\"}]}'; exit 2; }
    get_project_milestones 'bad-id'
  " 2>/dev/null || exit_code=$?
  [ "$exit_code" -eq 2 ]
}

# ── get_milestone_issues tests ─────────────────────────────────────────────────

test_get_milestone_issues_returns_meta_and_issues() {
  local result
  result=$(bash -c "
    source $LIB_DIR/linear-api.sh
    linear_graphql() { echo '{\"data\":{\"milestone\":{\"name\":\"Sprint 1\",\"description\":\"Q2 goals\",\"issues\":{\"nodes\":[{\"id\":\"i1\",\"identifier\":\"WIL-1\",\"title\":\"Fix bug\",\"description\":\"A bug\",\"state\":{\"id\":\"s1\",\"name\":\"Todo\",\"type\":\"unstarted\"},\"labels\":{\"nodes\":[]},\"parent\":null,\"assignee\":null,\"createdAt\":\"2026-01-01T00:00:00Z\",\"updatedAt\":\"2026-06-01T00:00:00Z\"}]}}}}'; }
    get_milestone_issues 'm1'
  " 2>/dev/null) || true
  echo "$result" | jq -e '.meta.name == "Sprint 1" and (.issues | type == "array") and .issues[0].identifier == "WIL-1"' >/dev/null
}

test_get_milestone_issues_empty_issues() {
  local result
  result=$(bash -c "
    source $LIB_DIR/linear-api.sh
    linear_graphql() { echo '{\"data\":{\"milestone\":{\"name\":\"Empty Sprint\",\"description\":\"No tickets\",\"issues\":{\"nodes\":[]}}}}'; }
    get_milestone_issues 'm2'
  " 2>/dev/null) || true
  echo "$result" | jq -e '.meta.name == "Empty Sprint" and (.issues | type == "array") and (.issues | length == 0)' >/dev/null
}

test_get_milestone_issues_handles_graphql_error() {
  local exit_code=0
  LINEAR_API_KEY=test bash -c "
    source $LIB_DIR/linear-api.sh
    linear_graphql() { echo '{\"errors\":[{\"message\":\"Milestone not found\"}]}'; exit 2; }
    get_milestone_issues 'bad-milestone'
  " 2>/dev/null || exit_code=$?
  [ "$exit_code" -eq 2 ]
}

test_get_milestone_issues_includes_updated_at() {
  local result
  result=$(bash -c "
    source $LIB_DIR/linear-api.sh
    linear_graphql() { echo '{\"data\":{\"milestone\":{\"name\":\"Sprint\",\"description\":\"Desc\",\"issues\":{\"nodes\":[{\"id\":\"i1\",\"identifier\":\"WIL-1\",\"title\":\"T\",\"description\":\"D\",\"state\":{\"id\":\"s1\",\"name\":\"Todo\",\"type\":\"unstarted\"},\"labels\":{\"nodes\":[]},\"parent\":null,\"assignee\":null,\"createdAt\":\"2026-01-01T00:00:00Z\",\"updatedAt\":\"2026-06-07T12:00:00Z\"}]}}}}'; }
    get_milestone_issues 'm1'
  " 2>/dev/null) || true
  echo "$result" | jq -e '.issues[0].updatedAt == "2026-06-07T12:00:00Z"' >/dev/null
}

# ── get_parent_with_children tests ─────────────────────────────────────────────

test_get_parent_with_children_returns_parent_and_children() {
  local result
  result=$(bash -c "
    source $LIB_DIR/linear-api.sh
    linear_graphql() { echo '{\"data\":{\"issue\":{\"id\":\"p1\",\"identifier\":\"WIL-10\",\"title\":\"Epic: Auth\",\"description\":\"Auth epic\",\"children\":{\"nodes\":[{\"id\":\"c1\",\"identifier\":\"WIL-11\",\"title\":\"Login page\",\"description\":\"Build login\",\"state\":{\"id\":\"s1\",\"name\":\"Todo\",\"type\":\"unstarted\"},\"labels\":{\"nodes\":[]},\"parent\":{\"id\":\"p1\",\"identifier\":\"WIL-10\",\"title\":\"Epic: Auth\"},\"assignee\":null,\"createdAt\":\"2026-01-01T00:00:00Z\",\"updatedAt\":\"2026-06-01T00:00:00Z\"}]}}}}'; }
    get_parent_with_children 'p1'
  " 2>/dev/null) || true
  echo "$result" | jq -e '.parent.identifier == "WIL-10" and (.children | type == "array") and .children[0].identifier == "WIL-11"' >/dev/null
}

test_get_parent_with_children_no_children() {
  local result
  result=$(bash -c "
    source $LIB_DIR/linear-api.sh
    linear_graphql() { echo '{\"data\":{\"issue\":{\"id\":\"p2\",\"identifier\":\"WIL-20\",\"title\":\"Leaf ticket\",\"description\":\"No kids\",\"children\":{\"nodes\":[]}}}}'; }
    get_parent_with_children 'p2'
  " 2>/dev/null) || true
  echo "$result" | jq -e '.parent.identifier == "WIL-20" and (.children | type == "array") and (.children | length == 0)' >/dev/null
}

test_get_parent_with_children_handles_graphql_error() {
  local exit_code=0
  LINEAR_API_KEY=test bash -c "
    source $LIB_DIR/linear-api.sh
    linear_graphql() { echo '{\"errors\":[{\"message\":\"Issue not found\"}]}'; exit 2; }
    get_parent_with_children 'bad-id'
  " 2>/dev/null || exit_code=$?
  [ "$exit_code" -eq 2 ]
}

test_get_parent_with_children_children_have_updated_at() {
  local result
  result=$(bash -c "
    source $LIB_DIR/linear-api.sh
    linear_graphql() { echo '{\"data\":{\"issue\":{\"id\":\"p1\",\"identifier\":\"WIL-10\",\"title\":\"Epic\",\"description\":\"Desc\",\"children\":{\"nodes\":[{\"id\":\"c1\",\"identifier\":\"WIL-11\",\"title\":\"Child\",\"description\":\"C\",\"state\":{\"id\":\"s1\",\"name\":\"Todo\",\"type\":\"unstarted\"},\"labels\":{\"nodes\":[]},\"parent\":{\"id\":\"p1\",\"identifier\":\"WIL-10\",\"title\":\"Epic\"},\"assignee\":null,\"createdAt\":\"2026-01-01T00:00:00Z\",\"updatedAt\":\"2026-06-07T12:00:00Z\"}]}}}}'; }
    get_parent_with_children 'p1'
  " 2>/dev/null) || true
  echo "$result" | jq -e '.children[0].updatedAt == "2026-06-07T12:00:00Z"' >/dev/null
}

# ── dispatch ──────────────────────────────────────────────────────────────────

FILTER="${1:-}"

for fn in \
  test_get_project_milestones_returns_array \
  test_get_project_milestones_empty_array \
  test_get_project_milestones_handles_graphql_error \
  test_get_milestone_issues_returns_meta_and_issues \
  test_get_milestone_issues_empty_issues \
  test_get_milestone_issues_handles_graphql_error \
  test_get_milestone_issues_includes_updated_at \
  test_get_parent_with_children_returns_parent_and_children \
  test_get_parent_with_children_no_children \
  test_get_parent_with_children_handles_graphql_error \
  test_get_parent_with_children_children_have_updated_at; do
  [ -z "$FILTER" ] || [[ "$fn" == *"$FILTER"* ]] || continue
  _run "$fn" "$fn"
done

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
