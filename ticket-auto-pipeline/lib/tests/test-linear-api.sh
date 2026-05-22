#!/usr/bin/env bash
# test-linear-api.sh — unit tests for lib/linear-api.sh
# All tests mock curl/linear_graphql — no network or socat required.
# Requires: bash, jq
# Usage: bash test-linear-api.sh [test_name_filter]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

PASS=0
FAIL=0

_run() {
  local name="$1"; shift
  if "$@" 2>/dev/null; then
    echo "PASS: $name"; ((PASS++)) || true
  else
    echo "FAIL: $name"; ((FAIL++)) || true
  fi
}

# ── _retry_classify unit tests (no network) ──────────────────────────────────

test_retry_classify_curl_error_is_transient() {
  local result
  result=$(bash -c "source $LIB_DIR/linear-api.sh; _retry_classify 1 0 ''" 2>/dev/null)
  [ "$result" = "transient" ]
}

test_retry_classify_5xx_is_transient() {
  local result
  result=$(bash -c "source $LIB_DIR/linear-api.sh; _retry_classify 0 503 ''" 2>/dev/null)
  [ "$result" = "transient" ]
}

test_retry_classify_graphql_rate_limit_transient() {
  local result
  result=$(bash -c "source $LIB_DIR/linear-api.sh; _retry_classify 0 200 '{\"errors\":[{\"message\":\"rate.limit exceeded\"}]}'" 2>/dev/null)
  [ "$result" = "transient" ]
}

test_retry_classify_200_is_permanent() {
  local result
  result=$(bash -c "source $LIB_DIR/linear-api.sh; _retry_classify 0 200 '{\"data\":{\"viewer\":{\"id\":\"u1\"}}}'" 2>/dev/null)
  [ "$result" = "permanent" ]
}

# ── normalize_comments unit tests (no network) ───────────────────────────────

test_normalize_passthrough_when_already_array() {
  local result
  result=$(echo '[{"id":"c1","body":"hi"}]' | bash -c "source $LIB_DIR/linear-api.sh; normalize_comments" 2>/dev/null)
  echo "$result" | jq -e 'type == "array" and .[0].id == "c1"' >/dev/null
}

test_normalize_data_issue_comments_nodes_shape() {
  local input='{"data":{"issue":{"comments":{"nodes":[{"id":"c1"}]}}}}'
  local result
  result=$(echo "$input" | bash -c "source $LIB_DIR/linear-api.sh; normalize_comments" 2>/dev/null)
  echo "$result" | jq -e 'type == "array" and .[0].id == "c1"' >/dev/null
}

test_normalize_data_issue_comments_shape() {
  local input='{"data":{"issue":{"comments":[{"id":"c2"}]}}}'
  local result
  result=$(echo "$input" | bash -c "source $LIB_DIR/linear-api.sh; normalize_comments" 2>/dev/null)
  echo "$result" | jq -e 'type == "array" and .[0].id == "c2"' >/dev/null
}

test_normalize_dot_comments_shape() {
  local input='{"comments":[{"id":"c3"}]}'
  local result
  result=$(echo "$input" | bash -c "source $LIB_DIR/linear-api.sh; normalize_comments" 2>/dev/null)
  echo "$result" | jq -e 'type == "array" and .[0].id == "c3"' >/dev/null
}

# ── update_issue payload tests (mock linear_graphql) ─────────────────────────

test_update_issue_skips_empty_state_id() {
  local tmpfile; tmpfile=$(mktemp)
  bash -c "
    source $LIB_DIR/linear-api.sh
    linear_graphql() { echo \"\$1\" > '$tmpfile'; echo '{\"data\":{\"issueUpdate\":{\"success\":true,\"issue\":{\"id\":\"i1\",\"identifier\":\"WIL-1\"}}}}'; }
    update_issue 'i1' '' '' ''
  " 2>/dev/null
  local result=0
  jq -e '.variables.input | has("stateId")' "$tmpfile" >/dev/null 2>&1 && result=1
  rm -f "$tmpfile"
  return $result
}

test_update_issue_all_fields() {
  local tmpfile; tmpfile=$(mktemp)
  bash -c "
    source $LIB_DIR/linear-api.sh
    linear_graphql() { echo \"\$1\" > '$tmpfile'; echo '{\"data\":{\"issueUpdate\":{\"success\":true,\"issue\":{\"id\":\"i1\",\"identifier\":\"WIL-1\"}}}}'; }
    update_issue 'i1' 'state-1' '[\"label-1\"]' 'assignee-1'
  " 2>/dev/null
  jq -e '.variables.input | has("stateId") and has("labelIds") and has("assigneeId")' "$tmpfile" >/dev/null 2>&1
  local result=$?
  rm -f "$tmpfile"
  return $result
}

# ── get_me test (mock linear_graphql) ────────────────────────────────────────

test_get_me_returns_viewer() {
  local result
  result=$(bash -c "
    source $LIB_DIR/linear-api.sh
    linear_graphql() { echo '{\"data\":{\"viewer\":{\"id\":\"u1\",\"name\":\"Test User\"}}}'; }
    get_me
  " 2>/dev/null) || true
  echo "$result" | jq -e '.id == "u1"' >/dev/null
}

# ── get_issue tests (mock linear_graphql) ───────────────────────────────────────

test_check_api_key_exits_4_when_unset() {
  local exit_code=0
  bash -c "unset LINEAR_API_KEY; source $LIB_DIR/linear-api.sh; get_issue 'i1'" 2>/dev/null || exit_code=$?
  [ "$exit_code" -eq 4 ]
}

test_get_issue_success() {
  local result
  result=$(bash -c "
    source $LIB_DIR/linear-api.sh
    linear_graphql() { echo '{\"data\":{\"issue\":{\"id\":\"i1\",\"title\":\"Test Issue\"}}}'; }
    get_issue 'i1'
  " 2>/dev/null) || true
  echo "$result" | jq -e '.id == "i1"' >/dev/null
}

test_graphql_error_in_body_exits_2() {
  local exit_code=0
  LINEAR_API_KEY=test bash -c "
    source $LIB_DIR/linear-api.sh
    # Mock curl to return GraphQL errors body with HTTP 200
    curl() { printf '%s\\n%d' '{\"errors\":[{\"message\":\"Not found\"}]}' 200; }
    # Call linear_graphql directly — get_issue swallows exit codes via
    # command substitution, so test at the linear_graphql level.
    linear_graphql '{\"query\":\"query{viewer{id}}\"}'
  " 2>/dev/null || exit_code=$?
  [ "$exit_code" -eq 2 ]
}

test_retry_three_503s_exits_2() {
  local exit_code=0
  LINEAR_API_KEY=test bash -c "
    source $LIB_DIR/linear-api.sh
    # Every curl call fails — all attempts + retries exhausted → exit 2
    curl() { return 7; }
    LINEAR_RETRY_DELAYS='0 0 0' \
      linear_graphql '{\"query\":\"query{viewer{id}}\"}'
  " 2>/dev/null || exit_code=$?
  [ "$exit_code" -eq 2 ]
}

test_retry_503_then_200_succeeds() {
  local result
  result=$(LINEAR_API_KEY=test bash -c "
    source $LIB_DIR/linear-api.sh
    _ctr=\$(mktemp); echo 0 > \"\$_ctr\"
    curl() {
      n=\$(cat \"\$_ctr\"); n=\$((n+1)); echo \$n > \"\$_ctr\"
      if [ \$n -eq 1 ]; then
        printf '\\n503'  # transient HTTP 503, empty body
      else
        printf '%s\\n%d' '{\"data\":{\"issue\":{\"id\":\"i1\",\"title\":\"Retried\"}}}' 200
      fi
      return 0
    }
    LINEAR_RETRY_DELAYS='0 0 0' get_issue 'i1'
  " 2>/dev/null) || true
  echo "$result" | jq -e '.id == "i1"' >/dev/null
}

# ── save_comment test (mock linear_graphql) ────────────────────────────────────

test_save_comment_success() {
  local result
  result=$(bash -c "
    source $LIB_DIR/linear-api.sh
    linear_graphql() { echo '{\"data\":{\"commentCreate\":{\"success\":true,\"comment\":{\"id\":\"c1\",\"body\":\"hello\"}}}}'; }
    save_comment 'i1' 'hello'
  " 2>/dev/null) || true
  echo "$result" | jq -e '.id == "c1"' >/dev/null
}

# ── get_comments test (mock linear_graphql) ────────────────────────────────────

test_get_comments_returns_array() {
  local result
  result=$(bash -c "
    source $LIB_DIR/linear-api.sh
    linear_graphql() { echo '{\"data\":{\"issue\":{\"comments\":{\"nodes\":[{\"id\":\"c1\",\"body\":\"hi\"}]}}}}'; }
    get_comments 'i1'
  " 2>/dev/null) || true
  echo "$result" | jq -e 'type == "array" and .[0].id == "c1"' >/dev/null
}

# ── get_team test (mock linear_graphql) ────────────────────────────────────────

test_get_team_returns_states_labels() {
  local result
  result=$(bash -c "
    source $LIB_DIR/linear-api.sh
    linear_graphql() { echo '{\"data\":{\"team\":{\"id\":\"t1\",\"name\":\"Willard\",\"states\":{\"nodes\":[{\"id\":\"s1\",\"name\":\"Todo\",\"type\":\"unstarted\"}]},\"labels\":{\"nodes\":[{\"id\":\"l1\",\"name\":\"bug\"}]}}}}'; }
    get_team 't1'
  " 2>/dev/null) || true
  echo "$result" | jq -e '.states | type == "array"' >/dev/null
}

# ── dispatch ──────────────────────────────────────────────────────────────────

FILTER="${1:-}"

for fn in \
  test_retry_classify_curl_error_is_transient \
  test_retry_classify_5xx_is_transient \
  test_retry_classify_graphql_rate_limit_transient \
  test_retry_classify_200_is_permanent \
  test_normalize_passthrough_when_already_array \
  test_normalize_data_issue_comments_nodes_shape \
  test_normalize_data_issue_comments_shape \
  test_normalize_dot_comments_shape \
  test_update_issue_skips_empty_state_id \
  test_update_issue_all_fields \
  test_get_me_returns_viewer \
  test_check_api_key_exits_4_when_unset \
  test_get_issue_success \
  test_graphql_error_in_body_exits_2 \
  test_retry_three_503s_exits_2 \
  test_retry_503_then_200_succeeds \
  test_save_comment_success \
  test_get_comments_returns_array \
  test_get_team_returns_states_labels; do
  [ -z "$FILTER" ] || [[ "$fn" == *"$FILTER"* ]] || continue
  _run "$fn" "$fn"
done

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
