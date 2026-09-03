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

# Issue #284 regression: exactly 1 legacy positional (state only) before a
# flag must not swallow the flag token as label_ids.
test_update_issue_one_positional_then_flag() {
  local tmpfile
  tmpfile=$(mktemp)
  bash -c "
    source $LIB_DIR/linear-api.sh
    linear_graphql() { echo \"\$1\" > '$tmpfile'; echo '{\"data\":{\"issueUpdate\":{\"success\":true,\"issue\":{\"id\":\"i1\",\"identifier\":\"WIL-1\"}}}}'; }
    update_issue 'i1' 'state-1' --title 'New Title'
  " 2>/dev/null
  jq -e '.variables.input == {"stateId":"state-1","title":"New Title"}' "$tmpfile" >/dev/null 2>&1
  local result=$?
  rm -f "$tmpfile"
  return $result
}

# Issue #284 regression: exactly 2 legacy positionals (state + labels) before
# a flag must not swallow the flag token as assignee_id.
test_update_issue_two_positional_then_flag() {
  local tmpfile
  tmpfile=$(mktemp)
  bash -c "
    source $LIB_DIR/linear-api.sh
    linear_graphql() { echo \"\$1\" > '$tmpfile'; echo '{\"data\":{\"issueUpdate\":{\"success\":true,\"issue\":{\"id\":\"i1\",\"identifier\":\"WIL-1\"}}}}'; }
    update_issue 'i1' 'state-1' '[\"label-1\"]' --description 'New Description'
  " 2>/dev/null
  jq -e '.variables.input == {"stateId":"state-1","labelIds":["label-1"],"description":"New Description"}' "$tmpfile" >/dev/null 2>&1
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

# ── create_issue tests (mock linear_graphql) ──────────────────────────────────

# Issue #283: required-fields-only call (team_id, title, description) —
# optional fields all omitted, mutation input carries exactly the 3 required keys.
test_create_issue_required_fields_only() {
  local tmpfile
  tmpfile=$(mktemp)
  bash -c "
    source $LIB_DIR/linear-api.sh
    linear_graphql() { echo \"\$1\" > '$tmpfile'; echo '{\"data\":{\"issueCreate\":{\"success\":true,\"issue\":{\"id\":\"i2\",\"identifier\":\"WIL-2\",\"title\":\"New ticket\",\"url\":\"https://linear.app/x/issue/WIL-2\"}}}}'; }
    create_issue 'team-1' 'New ticket' 'A description'
  " 2>/dev/null
  jq -e '.variables.input == {"teamId":"team-1","title":"New ticket","description":"A description"}' "$tmpfile" >/dev/null 2>&1
  local result=$?
  rm -f "$tmpfile"
  return $result
}

# Issue #283: all optional fields combined (project_id, parent_id, label_ids).
test_create_issue_all_optional_fields_combined() {
  local tmpfile
  tmpfile=$(mktemp)
  bash -c "
    source $LIB_DIR/linear-api.sh
    linear_graphql() { echo \"\$1\" > '$tmpfile'; echo '{\"data\":{\"issueCreate\":{\"success\":true,\"issue\":{\"id\":\"i2\",\"identifier\":\"WIL-2\",\"title\":\"New ticket\",\"url\":\"https://linear.app/x/issue/WIL-2\"}}}}'; }
    create_issue 'team-1' 'New ticket' 'A description' 'proj-1' 'par-1' '[\"label-1\",\"label-2\"]'
  " 2>/dev/null
  jq -e '.variables.input == {"teamId":"team-1","title":"New ticket","description":"A description","projectId":"proj-1","parentId":"par-1","labelIds":["label-1","label-2"]}' "$tmpfile" >/dev/null 2>&1
  local result=$?
  rm -f "$tmpfile"
  return $result
}

# Issue #283: omitted optional fields must be absent from the mutation input,
# not present as null.
test_create_issue_omitted_optional_fields_absent() {
  local tmpfile
  tmpfile=$(mktemp)
  bash -c "
    source $LIB_DIR/linear-api.sh
    linear_graphql() { echo \"\$1\" > '$tmpfile'; echo '{\"data\":{\"issueCreate\":{\"success\":true,\"issue\":{\"id\":\"i2\",\"identifier\":\"WIL-2\"}}}}'; }
    create_issue 'team-1' 'New ticket' 'A description'
  " 2>/dev/null
  jq -e '.variables.input | (has("projectId") or has("parentId") or has("labelIds")) | not' "$tmpfile" >/dev/null 2>&1
  local result=$?
  rm -f "$tmpfile"
  return $result
}

# Issue #283: the created issue object (id/identifier/title/url) is returned
# on the happy path.
test_create_issue_returns_issue_object() {
  local result
  result=$(bash -c "
    source $LIB_DIR/linear-api.sh
    linear_graphql() { echo '{\"data\":{\"issueCreate\":{\"success\":true,\"issue\":{\"id\":\"i2\",\"identifier\":\"WIL-2\",\"title\":\"New ticket\",\"url\":\"https://linear.app/x/issue/WIL-2\"}}}}'; }
    create_issue 'team-1' 'New ticket' 'A description'
  " 2>/dev/null) || true
  echo "$result" | jq -e '.id == "i2" and .identifier == "WIL-2" and .url == "https://linear.app/x/issue/WIL-2"' >/dev/null
}

# Issue #283: response-guard failure — success:false (issue comes back null)
# must return a clean error, not corrupt/silent output.
test_create_issue_success_false_errors() {
  local rc=0
  bash -c "
    source $LIB_DIR/linear-api.sh
    linear_graphql() { echo '{\"data\":{\"issueCreate\":{\"success\":false,\"issue\":null}}}'; }
    create_issue 'team-1' 'New ticket' 'A description'
  " >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 1 ]
}

# Issue #283: response-guard failure — malformed response (missing issueCreate
# entirely) must return a clean error, not a jq crash or silent bad output.
test_create_issue_malformed_response_errors() {
  local rc=0
  bash -c "
    source $LIB_DIR/linear-api.sh
    linear_graphql() { echo '{\"data\":{}}'; }
    create_issue 'team-1' 'New ticket' 'A description'
  " >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 1 ]
}

# Issue #283: required fields (team_id/title/description) must not be empty —
# a hard error before any network call, not a malformed mutation.
test_create_issue_missing_required_field_errors() {
  local rc=0
  bash -c "
    source $LIB_DIR/linear-api.sh
    linear_graphql() { echo '{\"data\":{\"issueCreate\":{\"success\":true,\"issue\":{\"id\":\"i2\"}}}}'; }
    create_issue 'team-1' '' 'A description'
  " >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 1 ]
}

# Code review fix: a non-JSON-array label_ids must fail cleanly with a
# return 1 and a stderr message, not abort the whole script via an
# unguarded 'jq --argjson' under set -e.
test_create_issue_invalid_label_ids_errors_cleanly() {
  local out rc=0
  out=$(bash -c "
    source $LIB_DIR/linear-api.sh
    linear_graphql() { echo 'SENTINEL_SHOULD_NOT_BE_CALLED'; }
    create_issue 'team-1' 'New ticket' 'A description' '' '' 'not-json'
  " 2>&1) || rc=$?
  [ "$rc" -eq 1 ] && ! echo "$out" | grep -q SENTINEL_SHOULD_NOT_BE_CALLED
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

# get_team() must paginate labels.nodes (issue #280) — a single unpaginated
# fetch silently drops any label past Linear's default page-size cutoff.
# This mock serves 3 pages, branching on the `after` cursor in the request
# variables, and asserts all 3 pages' labels land in the merged result —
# not just page 1.
test_get_team_paginates_labels_across_multiple_pages() {
  local result
  result=$(bash -c "
    source $LIB_DIR/linear-api.sh
    linear_graphql() {
      local payload=\"\$1\"
      local after
      after=\$(echo \"\$payload\" | jq -r '.variables.after // \"none\"')
      if [ \"\$after\" = \"cur2\" ]; then
        echo '{\"data\":{\"team\":{\"id\":\"t1\",\"name\":\"Willard\",\"states\":{\"nodes\":[]},\"labels\":{\"nodes\":[{\"id\":\"l3\",\"name\":\"claimed\"}],\"pageInfo\":{\"hasNextPage\":false,\"endCursor\":null}}}}}'
      elif [ \"\$after\" = \"cur1\" ]; then
        echo '{\"data\":{\"team\":{\"id\":\"t1\",\"name\":\"Willard\",\"states\":{\"nodes\":[]},\"labels\":{\"nodes\":[{\"id\":\"l2\",\"name\":\"feature\"}],\"pageInfo\":{\"hasNextPage\":true,\"endCursor\":\"cur2\"}}}}}'
      else
        echo '{\"data\":{\"team\":{\"id\":\"t1\",\"name\":\"Willard\",\"states\":{\"nodes\":[{\"id\":\"s1\",\"name\":\"Todo\",\"type\":\"unstarted\"}]},\"labels\":{\"nodes\":[{\"id\":\"l1\",\"name\":\"bug\"}],\"pageInfo\":{\"hasNextPage\":true,\"endCursor\":\"cur1\"}}}}}'
      fi
    }
    get_team 't1'
  " 2>/dev/null) || true
  echo "$result" | jq -e '
    (.labels | length == 3) and
    ((.labels | map(.id) | sort) == ["l1","l2","l3"]) and
    (.states | length == 1)
  ' >/dev/null
}

# Backward compat: a team under the page-size cutoff (hasNextPage: false on
# page 1) must resolve in exactly one linear_graphql call — pagination must
# not add a spurious extra round-trip for the common case.
test_get_team_single_page_no_extra_call() {
  local tmpfile
  tmpfile=$(mktemp)
  echo 0 >"$tmpfile"
  local result
  result=$(bash -c "
    source $LIB_DIR/linear-api.sh
    linear_graphql() {
      local n
      n=\$(cat '$tmpfile')
      n=\$((n + 1))
      echo \"\$n\" > '$tmpfile'
      echo '{\"data\":{\"team\":{\"id\":\"t1\",\"name\":\"Willard\",\"states\":{\"nodes\":[{\"id\":\"s1\",\"name\":\"Todo\",\"type\":\"unstarted\"}]},\"labels\":{\"nodes\":[{\"id\":\"l1\",\"name\":\"bug\"},{\"id\":\"l2\",\"name\":\"claimed\"}],\"pageInfo\":{\"hasNextPage\":false,\"endCursor\":null}}}}}'
    }
    get_team 't1'
  " 2>/dev/null) || true
  local calls
  calls=$(cat "$tmpfile")
  rm -f "$tmpfile"
  echo "$result" | jq -e '.labels | length == 2' >/dev/null && [ "$calls" = "1" ]
}

# Linear rejects `after` without `first` (CannotUseWithoutAny) — the first
# page's request must omit the `after` variable entirely (not send it as
# null/empty), and only start supplying it once a cursor exists.
test_get_team_first_page_omits_after_variable() {
  local tmpfile
  tmpfile=$(mktemp)
  bash -c "
    source $LIB_DIR/linear-api.sh
    linear_graphql() { echo \"\$1\" > '$tmpfile'; echo '{\"data\":{\"team\":{\"id\":\"t1\",\"name\":\"Willard\",\"states\":{\"nodes\":[]},\"labels\":{\"nodes\":[],\"pageInfo\":{\"hasNextPage\":false,\"endCursor\":null}}}}}'; }
    get_team 't1'
  " >/dev/null 2>/dev/null || true
  local has_after
  has_after=$(jq -r '.variables | has("after")' "$tmpfile" 2>/dev/null) || true
  rm -f "$tmpfile"
  [ "$has_after" = "false" ]
}

# Code review fix: a guard failure on page 2+ (e.g. a transient API error
# mid-pagination) must be a hard failure — return 1, not a truncated-but-
# "successful" partial label set. Silently returning page 1's labels only
# would be the exact silent-truncation bug #280 was filed to fix, just
# triggered by a transient error instead of missing pagination.
test_get_team_page_two_guard_failure_is_hard_error() {
  local rc=0
  local result
  result=$(bash -c "
    source $LIB_DIR/linear-api.sh
    linear_graphql() {
      local payload=\"\$1\"
      local after
      after=\$(echo \"\$payload\" | jq -r '.variables.after // \"none\"')
      if [ \"\$after\" = \"cur1\" ]; then
        echo 'not valid json — simulates a transient API error'
      else
        echo '{\"data\":{\"team\":{\"id\":\"t1\",\"name\":\"Willard\",\"states\":{\"nodes\":[]},\"labels\":{\"nodes\":[{\"id\":\"l1\",\"name\":\"bug\"}],\"pageInfo\":{\"hasNextPage\":true,\"endCursor\":\"cur1\"}}}}}'
      fi
    }
    get_team 't1'
  " 2>/dev/null) || rc=$?
  [ "$rc" -eq 1 ] && ! echo "$result" | jq -e '.labels | length == 1' >/dev/null 2>&1
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
  test_update_issue_one_positional_then_flag \
  test_update_issue_two_positional_then_flag \
  test_update_issue_omitted_fields_absent \
  test_update_issue_unknown_flag_errors \
  test_update_issue_invalid_priority_errors \
  test_create_issue_required_fields_only \
  test_create_issue_all_optional_fields_combined \
  test_create_issue_omitted_optional_fields_absent \
  test_create_issue_returns_issue_object \
  test_create_issue_success_false_errors \
  test_create_issue_malformed_response_errors \
  test_create_issue_missing_required_field_errors \
  test_create_issue_invalid_label_ids_errors_cleanly \
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
  test_get_team_returns_states_labels \
  test_get_team_paginates_labels_across_multiple_pages \
  test_get_team_single_page_no_extra_call \
  test_get_team_first_page_omits_after_variable \
  test_get_team_page_two_guard_failure_is_hard_error; do
  [ -z "$FILTER" ] || [[ "$fn" == *"$FILTER"* ]] || continue
  _run "$fn" "$fn"
done

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
