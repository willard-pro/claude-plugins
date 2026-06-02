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

LINEAR_API_URL="${LINEAR_API_URL:-https://api.linear.app/graphql}"

# Check LINEAR_API_KEY is set
check_api_key() {
  if [ -z "${LINEAR_API_KEY:-}" ]; then
    echo "LINEAR_API_KEY not set" >&2
    exit 4
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

  # HTTP 5xx server errors
  if [[ "$http_code" =~ ^5 ]]; then
    echo "transient"
    return
  fi

  # GraphQL-level transient messages
  if echo "$body" | grep -qiE 'rate.limit|timeout|temporar'; then
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
      echo "linear_graphql: transient error (attempt $((attempt + 1))/$max_retries, http=${http_code:-curl-err}), retrying in ${delays[$attempt]}s" >&2
      sleep "${delays[$attempt]}"
      ((attempt++)) || true
      continue
    fi

    if [ "$curl_exit" -ne 0 ]; then
      echo "curl error after $attempt retries: $resp" >&2
      exit 2
    fi

    if [ "$class" = "transient" ]; then
      echo "linear_graphql: transient error persisted after $max_retries attempts (http=$http_code)" >&2
      exit 2
    fi

    # Check for GraphQL errors in the body
    if echo "$resp" | jq -e '.errors' >/dev/null 2>&1; then
      echo "GraphQL error: $(echo "$resp" | jq -r '.errors[0].message // "unknown"')" >&2
      exit 2
    fi

    echo "$resp"
    return 0
  done
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
