#!/usr/bin/env bash
# Shared Linear GraphQL API helpers. Source this file from skill scripts.
# -u (nounset) intentionally omitted: Claude Code shell snapshots inject
# ZSH_VERSION references that trigger false-positive "unbound variable"
# errors in this bash version when nounset is active.
set -eo pipefail

# Source heartbeat library if available
_HB_LIB="$(dirname "${BASH_SOURCE[0]}")/heartbeat.sh"
[ -f "$_HB_LIB" ] && source "$_HB_LIB"

# Source config for centralized constants
_CONFIG_LIB="$(dirname "${BASH_SOURCE[0]}")/config.sh"
[ -f "$_CONFIG_LIB" ] && source "$_CONFIG_LIB"

# Source error handler for standard error codes
_EH_LIB="$(dirname "${BASH_SOURCE[0]}")/error-handler.sh"
[ -f "$_EH_LIB" ] && source "$_EH_LIB"

LINEAR_API_URL="${LINEAR_API_URL:-https://api.linear.app/graphql}"

# Check LINEAR_API_KEY is set
check_api_key() {
  if [ -z "${LINEAR_API_KEY:-}" ]; then
    # Walk up from PWD (max 3 levels) looking for .env containing LINEAR_API_KEY=
    # Use grep extraction rather than 'source' to avoid executing arbitrary code
    # in .env files. Strips optional single/double quotes from the value.
    local _dir="$PWD"
    local _found=false
    local _key_value
    for _ in 1 2 3; do
      if [ -f "$_dir/.env" ] && grep -q '^LINEAR_API_KEY=' "$_dir/.env" 2>/dev/null; then
        _key_value=$(grep -m1 '^LINEAR_API_KEY=' "$_dir/.env" 2>/dev/null | sed 's/^LINEAR_API_KEY=//')
        # Strip optional surrounding quotes
        _key_value="${_key_value#\"}"
        _key_value="${_key_value%\"}"
        _key_value="${_key_value#\'}"
        _key_value="${_key_value%\'}"
        if [ -n "$_key_value" ]; then
          export LINEAR_API_KEY="$_key_value"
          _found=true
          break
        fi
      fi
      _dir="$(dirname "$_dir")"
    done
    if ! $_found; then
      echo "LINEAR_API_KEY not set and not found in .env" >&2
      exit 4
    fi
  fi
}

# Classify a curl result as "transient" (retry) or "permanent" (hard-fail).
# Args: <curl_exit_code> <http_status_code> <response_body>
_retry_classify() {
  local curl_exit="$1"
  local http_code="$2"
  local body="$3"

  # curl failed (network error, timeout, etc.)
  if [ "$curl_exit" -ne 0 ]; then
    echo "transient"
    return
  fi

  # HTTP 429 Too Many Requests — rate limiting is transient by definition
  if [ "$http_code" = "429" ]; then
    echo "transient"
    return
  fi

  # HTTP 5xx server errors
  if [[ "$http_code" =~ ^5 ]]; then
    echo "transient"
    return
  fi

  # ── GraphQL error detection (run BEFORE transient keyword scan) ─────────────
  # HTTP 200 with {"errors":[...]} is a terminal GraphQL error — NOT transient.
  # Only rate-limit GraphQL errors qualify for retry. All other GraphQL-level
  # errors (validation, auth, field-not-found, etc.) are permanent failures.
  if echo "$body" | jq -e '.errors' >/dev/null 2>&1; then
    # Check if the errors are specifically about rate limiting
    if echo "$body" | jq -r '.errors[].message // ""' 2>/dev/null | grep -qiE '429|rate[.]limit'; then
      echo "transient"
      return
    fi
    # All other GraphQL errors are terminal — no retry
    echo "permanent"
    return
  fi

  # HTTP-level transient messages in the body (non-GraphQL-error responses).
  # Rate-limit info embedded in a 200 response body, timeout/temporary keywords.
  # Use rate[.]limit to avoid the unescaped dot matching any character.
  # NOTE: '429' deliberately excluded — UUID substrings trigger false positives on
  # successful responses (e.g. dd816776-4ce4-429c-ad38). HTTP 429 is caught by the
  # status-code check above; GraphQL rate-limit errors are caught by the .errors block.
  if echo "$body" | grep -qiE 'rate[.]limit|timeout|temporar'; then
    echo "transient"
    return
  fi

  echo "permanent"
}

# Low-level GraphQL call. Args: query_json_string
# query_json_string = jq -n formatted {"query": "...", "variables": {...}}
linear_graphql() {
  local payload="$1"
  check_api_key

  local attempt=0
  read -ra delays <<<"${LINEAR_RETRY_DELAYS:-1 2 4}"
  local max_retries="${LINEAR_MAX_RETRIES:-3}"
  local resp http_code curl_exit

  while true; do
    http_code=""
    curl_exit=0

    local api_start
    api_start=$(date +%s%3N 2>/dev/null || echo 0)

    resp=$(curl -s -w '\n%{http_code}' -X POST "$LINEAR_API_URL" \
      -H "Authorization: ${LINEAR_API_KEY}" \
      -H "Content-Type: application/json" \
      -d "$payload" 2>/dev/null) || curl_exit=$?

    local api_elapsed
    if [ "$api_start" -ne 0 ]; then
      api_elapsed=$(($(date +%s%3N 2>/dev/null || echo 0) - api_start))
    else
      api_elapsed=0
    fi

    if [ "$curl_exit" -eq 0 ]; then
      http_code=$(echo "$resp" | tail -1)
      resp=$(echo "$resp" | head -n -1)
    fi

    local class
    class=$(_retry_classify "$curl_exit" "${http_code:-0}" "$resp")

    # Heartbeat: retry classification
    if [ "$class" = "transient" ]; then
      hb_retry "classify" "info" "transient: HTTP ${http_code:-curl-err}" "{\"http_code\":\"${http_code:-curl-err}\",\"attempt\":\"$((attempt + 1))\"}"
    fi

    # Heartbeat: API call result
    if [ "$curl_exit" -eq 0 ] && [ "$class" = "permanent" ]; then
      hb_api "linear-request" "ok" "GraphQL call succeeded" "{\"elapsed_ms\":\"$api_elapsed\",\"http_code\":\"$http_code\"}"
    elif [ "$curl_exit" -ne 0 ] || { [ "$class" = "transient" ] && [ "$attempt" -ge "$max_retries" ]; }; then
      hb_api "linear-request" "fail" "GraphQL call failed" "{\"elapsed_ms\":\"$api_elapsed\",\"http_code\":\"${http_code:-curl-err}\"}"
    fi

    if [ "$class" = "transient" ] && [ "$attempt" -lt "$max_retries" ]; then
      # Bounds-safe delay lookup: fall back to last array element when
      # attempt index exceeds the configured delays array length.
      local delay
      if [ -n "${delays[$attempt]:-}" ]; then
        delay="${delays[$attempt]}"
      else
        delay="${delays[-1]:-4}"
      fi
      echo "linear_graphql: transient error (attempt $((attempt + 1))/$max_retries, http=${http_code:-curl-err}), retrying in ${delay}s" >&2
      sleep "$delay"
      ((attempt++)) || true
      continue
    fi

    if [ "$curl_exit" -ne 0 ]; then
      echo "curl error after $attempt retries: $resp" >&2
      error_exit 10 "linear_api: API request failed after retries"
    fi

    if [ "$class" = "transient" ]; then
      echo "linear_graphql: transient error persisted after $max_retries attempts (http=$http_code)" >&2
      error_exit 10 "linear_api: API request failed after retries"
    fi

    # Empty-body guard: an HTTP 200 with no response body is a transient
    # read-after-write consistency gap — retry if attempts remain.
    # Only retry when _retry_classify didn't already identify a terminal
    # GraphQL error (checked above — this path only reached for non-error bodies).
    if [ -z "$resp" ] && [ "$attempt" -lt "$max_retries" ]; then
      echo "linear_graphql: empty response body (attempt $((attempt + 1))/$max_retries), retrying" >&2
      ((attempt++)) || true
      continue
    fi

    # Guard: validate resp is valid JSON before querying with jq.
    # Malformed responses (HTML error pages, connection resets, etc.)
    # surface here rather than producing cryptic jq parse errors.
    if ! echo "$resp" | jq empty 2>/dev/null; then
      echo "linear_graphql: response is not valid JSON (HTTP $http_code)" >&2
      # If this was classified as permanent (terminal), error out immediately.
      # Otherwise retry if attempts remain.
      if [ "$class" = "permanent" ]; then
        error_exit 10 "linear_api: non-JSON response (HTTP $http_code)"
      elif [ "$attempt" -lt "$max_retries" ]; then
        ((attempt++)) || true
        continue
      fi
      error_exit 10 "linear_api: non-JSON response after retries (HTTP $http_code)"
    fi

    # Check for GraphQL errors in the body — terminal, surface the message
    if echo "$resp" | jq -e '.errors' >/dev/null 2>&1; then
      local gql_msg
      gql_msg=$(echo "$resp" | jq -r '.errors[0].message // "unknown"' 2>/dev/null || echo "unknown")
      echo "GraphQL error: $gql_msg" >&2
      error_exit 10 "linear_api: GraphQL error — $gql_msg"
    fi

    echo "$resp"
    return 0
  done
}

# ── jq type-guard helpers ────────────────────────────────────────────────────

# Guard: ensure the JSON path exists and is the expected type before querying.
# Usage: _jq_guard <json> <jq_filter> <expected_type>
# Returns 0 if the path exists and matches the type, 1 otherwise.
# expected_type: "array", "object", "string", "number", "boolean", "null"
_jq_guard() {
  local json="$1"
  local filter="$2"
  local expected_type="$3"
  echo "$json" | jq -e --arg t "$expected_type" \
    "($filter) != null and (($filter) | type == \$t)" >/dev/null 2>&1
}

# Fetch an issue with all relevant fields. Returns JSON on stdout.
get_issue() {
  local issue_id="$1"
  local query
  query=$(jq -n --arg id "$issue_id" '{
    query: "query($id: String!) { issue(id: $id) { id identifier title description priority url createdAt dueDate team { id name } state { id name type } labels { nodes { id name } } project { id name } parent { id identifier title } assignee { id name } creator { id name } } }",
    variables: {id: $id}
  }')
  local resp
  resp=$(linear_graphql "$query")
  # Type guard: verify .data.issue exists before querying
  if ! _jq_guard "$resp" ".data.issue" "object"; then
    echo "get_issue: unexpected response shape — .data.issue missing or not an object" >&2
    echo "null"
    return 1
  fi
  echo "$resp" | jq '.data.issue'
}

# Fetch comments for an issue. Returns JSON array on stdout.
get_comments() {
  local issue_id="$1"
  local query
  query=$(jq -n --arg id "$issue_id" '{
    query: "query($id: String!) { issue(id: $id) { comments { nodes { id body createdAt user { id name } } } } }",
    variables: {id: $id}
  }')
  local resp
  resp=$(linear_graphql "$query")
  # Type guard: verify .data.issue.comments.nodes exists as array
  if ! _jq_guard "$resp" ".data.issue.comments.nodes" "array"; then
    # Graceful: may be empty (no comments) — return empty array
    echo "[]"
    return 0
  fi
  echo "$resp" | jq '.data.issue.comments.nodes'
}

# Normalize comments JSON from bash get_comments or MCP fallback to a flat array.
# Reads JSON from stdin, outputs normalized array to stdout.
# Handles: raw array, .data.issue.comments.nodes, .data.issue.comments,
#          .data.comments, .comments
normalize_comments() {
  jq 'if type == "array" then .
      elif (.data?.issue?.comments?.nodes? // false) then .data.issue.comments.nodes
      elif (.data?.issue?.comments // false) then .data.issue.comments
      elif (.data?.comments // false) then .data.comments
      elif (.comments // false) then .comments
      else . end'
}

# Fetch team states and labels. Returns JSON: {states: [...], labels: [...]}
get_team() {
  local team_id="$1"
  local query
  query=$(jq -n --arg tid "$team_id" '{
    query: "query($tid: String!) { team(id: $tid) { id name states { nodes { id name type } } labels { nodes { id name } } } }",
    variables: {tid: $tid}
  }')
  local resp
  resp=$(linear_graphql "$query")
  # Type guard: verify .data.team exists before querying sub-fields
  if ! _jq_guard "$resp" ".data.team" "object"; then
    echo "get_team: unexpected response shape" >&2
    echo '{"states":[],"labels":[]}'
    return 1
  fi
  echo "$resp" | jq '{states: .data.team.states.nodes, labels: .data.team.labels.nodes}'
}

# Update an issue. Pass empty strings to skip state/labels/assignee.
update_issue() {
  local issue_id="$1"
  local state_id="${2:-}"
  local label_ids="${3:-}" # JSON array string e.g. '["id1","id2"]'
  local assignee_id="${4:-}"

  # Build input object dynamically
  local input="{}"
  [ -n "$state_id" ] && input=$(echo "$input" | jq --arg s "$state_id" '. + {stateId: $s}')
  [ -n "$label_ids" ] && input=$(echo "$input" | jq --argjson l "$label_ids" '. + {labelIds: $l}')
  [ -n "$assignee_id" ] && input=$(echo "$input" | jq --arg a "$assignee_id" '. + {assigneeId: $a}')

  local query
  query=$(jq -n --arg id "$issue_id" --argjson input "$input" '{
    query: "mutation($id: String!, $input: IssueUpdateInput!) { issueUpdate(id: $id, input: $input) { success issue { id identifier } } }",
    variables: {id: $id, input: $input}
  }')
  local resp
  resp=$(linear_graphql "$query")
  echo "$resp" | jq '.data.issueUpdate'
}

# Get current user (me) info from Linear
get_me() {
  local query
  query='{"query": "query { viewer { id name } }"}'
  local resp
  resp=$(linear_graphql "$query")
  echo "$resp" | jq '.data.viewer'
}

# ── Audit / milestone / parent-child queries ──────────────────────────────────────

# Fetch milestones for a project. Returns JSON array on stdout.
# Each milestone: {id, name, description, targetDate, status}
get_project_milestones() {
  local project_id="$1"
  local query
  query=$(jq -n --arg pid "$project_id" '{
    query: "query($pid: String!) { project(id: $pid) { milestones { nodes { id name description targetDate status } } } }",
    variables: {pid: $pid}
  }')
  local resp
  resp=$(linear_graphql "$query")
  echo "$resp" | jq '.data.project.milestones.nodes'
}

# Fetch issues under a milestone. Returns JSON: {meta: {name, description}, issues: [...]}
# Each issue includes: id, identifier, title, description, state {id, name, type},
# labels {nodes: [{id, name}]}, parent {id, identifier, title}, assignee {id, name},
# createdAt, updatedAt
get_milestone_issues() {
  local milestone_id="$1"
  local query
  query=$(jq -n --arg mid "$milestone_id" '{
    query: "query($mid: String!) { milestone: node(id: $mid) { ... on Milestone { name description issues { nodes { id identifier title description state { id name type } labels { nodes { id name } } parent { id identifier title } assignee { id name } createdAt updatedAt } } } } }",
    variables: {mid: $mid}
  }')
  local resp
  resp=$(linear_graphql "$query")
  echo "$resp" | jq '{meta: {name: .data.milestone.name, description: .data.milestone.description}, issues: (.data.milestone.issues.nodes // [])}'
}

# Fetch a parent issue with all its children. Returns JSON: {parent: {...}, children: [...]}
# Parent includes: id, identifier, title, description
# Children include same issue fields as get_milestone_issues
get_parent_with_children() {
  local parent_id="$1"
  local query
  query=$(jq -n --arg pid "$parent_id" '{
    query: "query($pid: String!) { issue(id: $pid) { id identifier title description children { nodes { id identifier title description state { id name type } labels { nodes { id name } } parent { id identifier title } assignee { id name } createdAt updatedAt } } } }",
    variables: {pid: $pid}
  }')
  local resp
  resp=$(linear_graphql "$query")
  echo "$resp" | jq '{parent: {id: .data.issue.id, identifier: .data.issue.identifier, title: .data.issue.title, description: .data.issue.description}, children: (.data.issue.children.nodes // [])}'
}

# Post a comment to an issue. Returns comment JSON: {id, body}
save_comment() {
  local issue_id="$1"
  local body="$2"
  local query
  query=$(jq -n --arg issueId "$issue_id" --arg body "$body" '{
    query: "mutation($input: CommentCreateInput!) { commentCreate(input: $input) { success comment { id body } } }",
    variables: {input: {issueId: $issueId, body: $body}}
  }')
  local resp
  resp=$(linear_graphql "$query")
  echo "$resp" | jq '.data.commentCreate.comment'
}
