#!/usr/bin/env bash
# test-linear-api.sh — unit tests for lib/linear-api.sh
# All tests mock curl/linear_graphql — no network or socat required.
# Requires: bash, jq
# Usage: bash test-linear-api.sh [test_name_filter]
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

# Issue #190: a successful GraphQL response whose field content legitimately
# mentions "timeout"/"temporar"/"rate.limit" must not be misclassified as
# transient — the keyword scan only applies to non-GraphQL-success bodies.
test_retry_classify_200_with_timeout_in_body_is_permanent() {
  local result
  result=$(bash -c "source $LIB_DIR/linear-api.sh; _retry_classify 0 200 '{\"data\":{\"issue\":{\"title\":\"Fix Feign connectTimeout/readTimeout config\"}}}'" 2>/dev/null)
  [ "$result" = "permanent" ]
}

test_retry_classify_200_with_temporary_in_body_is_permanent() {
  local result
  result=$(bash -c "source $LIB_DIR/linear-api.sh; _retry_classify 0 200 '{\"data\":{\"issue\":{\"description\":\"temporary workaround for rate.limit handling\"}}}'" 2>/dev/null)
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
  local tmpfile
  tmpfile=$(mktemp)
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
  local tmpfile
  tmpfile=$(mktemp)
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

# Issue #284: legacy positional call sites (flow.sh) must keep working
# unchanged — same 4-arg shape, exact values land in the mutation input.
test_update_issue_positional_backward_compat_values() {
  local tmpfile
  tmpfile=$(mktemp)
  bash -c "
    source $LIB_DIR/linear-api.sh
    linear_graphql() { echo \"\$1\" > '$tmpfile'; echo '{\"data\":{\"issueUpdate\":{\"success\":true,\"issue\":{\"id\":\"i1\",\"identifier\":\"WIL-1\"}}}}'; }
    update_issue 'i1' 'state-1' '[\"label-1\"]' 'assignee-1'
  " 2>/dev/null
  jq -e '.variables.input == {"stateId":"state-1","labelIds":["label-1"],"assigneeId":"assignee-1"}' "$tmpfile" >/dev/null 2>&1
  local result=$?
  rm -f "$tmpfile"
  return $result
}

# Issue #284: --title alone, no positional args at all.
test_update_issue_title_flag_only() {
  local tmpfile
  tmpfile=$(mktemp)
  bash -c "
    source $LIB_DIR/linear-api.sh
    linear_graphql() { echo \"\$1\" > '$tmpfile'; echo '{\"data\":{\"issueUpdate\":{\"success\":true,\"issue\":{\"id\":\"i1\",\"identifier\":\"WIL-1\"}}}}'; }
    update_issue 'i1' --title 'New Title'
  " 2>/dev/null
  jq -e '.variables.input == {"title":"New Title"}' "$tmpfile" >/dev/null 2>&1
  local result=$?
  rm -f "$tmpfile"
  return $result
}

# Issue #284: --description alone.
test_update_issue_description_flag_only() {
  local tmpfile
  tmpfile=$(mktemp)
  bash -c "
    source $LIB_DIR/linear-api.sh
    linear_graphql() { echo \"\$1\" > '$tmpfile'; echo '{\"data\":{\"issueUpdate\":{\"success\":true,\"issue\":{\"id\":\"i1\",\"identifier\":\"WIL-1\"}}}}'; }
    update_issue 'i1' --description 'New Description'
  " 2>/dev/null
  jq -e '.variables.input == {"description":"New Description"}' "$tmpfile" >/dev/null 2>&1
  local result=$?
  rm -f "$tmpfile"
  return $result
}

# Issue #284: multiple new flags combined (title + project + parent + priority) —
# and confirms omitted fields (state/labels/assignee/description) are NOT present.
test_update_issue_multiple_flags_combined() {
  local tmpfile
  tmpfile=$(mktemp)
  bash -c "
    source $LIB_DIR/linear-api.sh
    linear_graphql() { echo \"\$1\" > '$tmpfile'; echo '{\"data\":{\"issueUpdate\":{\"success\":true,\"issue\":{\"id\":\"i1\",\"identifier\":\"WIL-1\"}}}}'; }
    update_issue 'i1' --title 'Rescoped title' --project 'proj-1' --parent 'par-1' --priority 2
  " 2>/dev/null
  jq -e '.variables.input == {"title":"Rescoped title","projectId":"proj-1","parentId":"par-1","priority":2}' "$tmpfile" >/dev/null 2>&1
  local result=$?
  rm -f "$tmpfile"
  return $result
}

# Issue #284: positional state/labels/assignee combined with a new named flag
# (the concrete CRE-67 rescope shape: keep state/labels, change title).
test_update_issue_flags_combined_with_positional() {
  local tmpfile
  tmpfile=$(mktemp)
  bash -c "
    source $LIB_DIR/linear-api.sh
    linear_graphql() { echo \"\$1\" > '$tmpfile'; echo '{\"data\":{\"issueUpdate\":{\"success\":true,\"issue\":{\"id\":\"i1\",\"identifier\":\"WIL-1\"}}}}'; }
    update_issue 'i1' 'state-1' '' 'assignee-1' --title 'SPA-fallback-only title' --description 'trimmed AC1'
  " 2>/dev/null
  jq -e '.variables.input == {"stateId":"state-1","assigneeId":"assignee-1","title":"SPA-fallback-only title","description":"trimmed AC1"}' "$tmpfile" >/dev/null 2>&1
  local result=$?
  rm -f "$tmpfile"
  return $result
}

# Issue #284: omitted fields must not appear in the input at all, not even as null.
test_update_issue_omitted_fields_absent() {
  local tmpfile
  tmpfile=$(mktemp)
  bash -c "
    source $LIB_DIR/linear-api.sh
    linear_graphql() { echo \"\$1\" > '$tmpfile'; echo '{\"data\":{\"issueUpdate\":{\"success\":true,\"issue\":{\"id\":\"i1\",\"identifier\":\"WIL-1\"}}}}'; }
    update_issue 'i1' --title 'Only title'
  " 2>/dev/null
  jq -e '.variables.input | (has("description") or has("projectId") or has("parentId") or has("priority") or has("stateId") or has("labelIds") or has("assigneeId")) | not' "$tmpfile" >/dev/null 2>&1
  local result=$?
  rm -f "$tmpfile"
  return $result
}

# Issue #284: an unrecognized flag is a hard error, not a silent no-op.
test_update_issue_unknown_flag_errors() {
  local rc=0
  bash -c "
    source $LIB_DIR/linear-api.sh
    linear_graphql() { echo '{\"data\":{\"issueUpdate\":{\"success\":true}}}'; }
    update_issue 'i1' --bogus 'x'
  " >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 1 ]
}

# Issue #284: --priority must be numeric.
test_update_issue_invalid_priority_errors() {
  local rc=0
  bash -c "
    source $LIB_DIR/linear-api.sh
    linear_graphql() { echo '{\"data\":{\"issueUpdate\":{\"success\":true}}}'; }
    update_issue 'i1' --priority 'not-a-number'
  " >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 1 ]
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

test_check_api_key_finds_key_in_current_dir_dotenv() {
  local tmpdir exit_code
  tmpdir=$(mktemp -d)
  echo 'LINEAR_API_KEY=test-key-from-dotenv' >"$tmpdir/.env"
  exit_code=0
  (
    cd "$tmpdir" || exit 1
    unset LINEAR_API_KEY
    source "$LIB_DIR/linear-api.sh"
    # Call check_api_key directly — should find key from .env and set it
    check_api_key
    [ "$LINEAR_API_KEY" = "test-key-from-dotenv" ]
  ) 2>/dev/null || exit_code=$?
  rm -rf "$tmpdir"
  [ "$exit_code" -eq 0 ]
}

test_check_api_key_finds_key_in_parent_dir_dotenv() {
  local tmpdir exit_code
  tmpdir=$(mktemp -d)
  mkdir -p "$tmpdir/logs"
  echo 'LINEAR_API_KEY=parent-dotenv-key' >"$tmpdir/.env"
  exit_code=0
  (
    cd "$tmpdir/logs" || exit 1
    unset LINEAR_API_KEY
    source "$LIB_DIR/linear-api.sh"
    check_api_key
    [ "$LINEAR_API_KEY" = "parent-dotenv-key" ]
  ) 2>/dev/null || exit_code=$?
  rm -rf "$tmpdir"
  [ "$exit_code" -eq 0 ]
}

test_check_api_key_exits_4_when_dotenv_has_no_linear_key() {
  local tmpdir exit_code
  tmpdir=$(mktemp -d)
  echo 'OTHER_KEY=some-value' >"$tmpdir/.env"
  exit_code=0
  (
    cd "$tmpdir" || exit 1
    unset LINEAR_API_KEY
    source "$LIB_DIR/linear-api.sh"
    check_api_key
  ) 2>/dev/null || exit_code=$?
  rm -rf "$tmpdir"
  [ "$exit_code" -eq 4 ]
}

test_check_api_key_skips_dotenv_when_key_already_set() {
  local tmpdir exit_code
  tmpdir=$(mktemp -d)
  echo 'LINEAR_API_KEY=should-not-use-this' >"$tmpdir/.env"
  exit_code=0
  (
    cd "$tmpdir" || exit 1
    export LINEAR_API_KEY=already-set
    source "$LIB_DIR/linear-api.sh"
    check_api_key
    [ "$LINEAR_API_KEY" = "already-set" ]
  ) 2>/dev/null || exit_code=$?
  rm -rf "$tmpdir"
  [ "$exit_code" -eq 0 ]
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
  # Migration to error-handler.sh: E_LINEAR_API=10
  [ "$exit_code" -eq 10 ]
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
  # Migration to error-handler.sh: E_LINEAR_API=10
  [ "$exit_code" -eq 10 ]
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
  test_retry_classify_200_with_timeout_in_body_is_permanent \
  test_retry_classify_200_with_temporary_in_body_is_permanent \
  test_normalize_passthrough_when_already_array \
  test_normalize_data_issue_comments_nodes_shape \
  test_normalize_data_issue_comments_shape \
  test_normalize_dot_comments_shape \
  test_update_issue_skips_empty_state_id \
  test_update_issue_all_fields \
  test_update_issue_positional_backward_compat_values \
  test_update_issue_title_flag_only \
  test_update_issue_description_flag_only \
  test_update_issue_multiple_flags_combined \
  test_update_issue_flags_combined_with_positional \
  test_update_issue_omitted_fields_absent \
  test_update_issue_unknown_flag_errors \
  test_update_issue_invalid_priority_errors \
  test_get_me_returns_viewer \
  test_check_api_key_exits_4_when_unset \
  test_check_api_key_finds_key_in_current_dir_dotenv \
  test_check_api_key_finds_key_in_parent_dir_dotenv \
  test_check_api_key_exits_4_when_dotenv_has_no_linear_key \
  test_check_api_key_skips_dotenv_when_key_already_set \
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
