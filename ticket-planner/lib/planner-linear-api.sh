#!/usr/bin/env bash
# planner-linear-api.sh — Linear GraphQL API client with retry for ticket-planner.
#
# Pattern copied from ticket-auto's lib/linear-api.sh. Wraps curl with retry
# logic (3 attempts, exponential backoff: 1s, 2s, 4s) so transient 429/503
# responses don't count against PLANNER_MAX_PHASE_RETRIES.
#
# Usage:
#   planner_linear_graphql <query_json>
#     query_json: JSON with "query" and optional "variables" fields.
#     Outputs: raw JSON response on stdout.
#     Returns: 0 on success, 1 on permanent failure, 2 on retries exhausted.
#
#   planner_linear_create_issue <team_id> <title> <description> [labels_json] [parent_id]
#     Creates a Linear issue. Returns the created issue JSON on stdout.
#
#   planner_linear_get_issue <issue_id>
#     Fetches a single issue by ID. Returns issue JSON on stdout.
#
# Sourceable library — no set -euo pipefail.

LINEAR_API_URL="${LINEAR_API_URL:-https://api.linear.app/graphql}"

# ── Retry classification ──────────────────────────────────────────────────────

# Classify a curl result as "transient" (retry) or "permanent" (hard-fail).
# Args: <curl_exit_code> <http_status_code> <response_body>
_planner_retry_classify() {
  local curl_exit="$1" http_code="$2" body="$3"

  # curl failed (network error, timeout, etc.)
  if [ "$curl_exit" -ne 0 ]; then
    echo "transient"
    return
  fi

  # HTTP 429 Too Many Requests — rate limiting is transient
  if [ "$http_code" = "429" ]; then
    echo "transient"
    return
  fi

  # HTTP 5xx server errors
  if [[ "$http_code" =~ ^5 ]]; then
    echo "transient"
    return
  fi

  # GraphQL errors — only rate-limit is transient
  if echo "$body" | jq -e '.errors' >/dev/null 2>&1; then
    if echo "$body" | jq -r '.errors[].message // ""' 2>/dev/null | grep -qiE '429|rate[.]limit'; then
      echo "transient"
      return
    fi
    echo "permanent"
    return
  fi

  # Body contains transient keywords (rate limit, timeout, temporary)
  if echo "$body" | grep -qiE 'rate[.]limit|timeout|temporar'; then
    echo "transient"
    return
  fi

  echo "permanent"
}

# ── Low-level GraphQL call ────────────────────────────────────────────────────

# Execute a Linear GraphQL query with retry.
# Args: query_json_string ({"query": "...", "variables": {...}})
# Output: raw JSON response on stdout.
# Returns: 0 on success, 1 on permanent failure, 2 on retries exhausted.
planner_linear_graphql() {
  local payload="$1"

  if [ -z "${LINEAR_API_KEY:-}" ]; then
    echo "planner-linear-api: LINEAR_API_KEY not set" >&2
    return 1
  fi

  local attempt=0
  local max_retries="${LINEAR_MAX_RETRIES:-3}"
  local delays
  read -ra delays <<<"${LINEAR_RETRY_DELAYS:-1 2 4}"
  local resp http_code curl_exit classification

  while true; do
    http_code=""
    curl_exit=0

    resp=$(curl -s -w "\n%{http_code}" \
      -X POST "$LINEAR_API_URL" \
      -H "Authorization: ${LINEAR_API_KEY}" \
      -H "Content-Type: application/json" \
      -d "$payload" 2>/dev/null) || curl_exit=$?

    http_code=$(echo "$resp" | tail -1)
    resp=$(echo "$resp" | sed '$d')

    classification=$(_planner_retry_classify "$curl_exit" "$http_code" "$resp")

    if [ "$classification" = "permanent" ]; then
      echo "planner-linear-api: permanent failure (HTTP $http_code, curl exit $curl_exit)" >&2
      echo "$resp"
      return 1
    fi

    # Transient — retry if attempts remain
    attempt=$((attempt + 1))
    if [ "$attempt" -ge "$max_retries" ]; then
      echo "planner-linear-api: retries exhausted after $attempt attempts (HTTP $http_code)" >&2
      echo "$resp"
      return 2
    fi

    local delay="${delays[$((attempt - 1))]:-4}"
    echo "planner-linear-api: transient failure (HTTP $http_code), retrying in ${delay}s (attempt $attempt/$max_retries)" >&2
    sleep "$delay"
  done
}

# ── Issue helpers ─────────────────────────────────────────────────────────────

# Create a Linear issue.
# Args: <team_id> <title> <description> [labels_json] [parent_id]
# Output: created issue JSON on stdout.
planner_linear_create_issue() {
  local team_id="$1" title="$2" description="$3" labels_json="${4:-[]}" parent_id="${5:-}"

  # Escape the description for JSON embedding
  local esc_description
  esc_description=$(echo "$description" | jq -Rs .)

  local esc_title
  esc_title=$(echo "$title" | jq -Rs .)

  local esc_labels
  esc_labels=$(echo "$labels_json" | jq -c '. | map({name: .})')

  local variables
  if [ -n "$parent_id" ]; then
    variables=$(jq -nc \
      --argjson teamId "$team_id" \
      --argjson title "$esc_title" \
      --argjson description "$esc_description" \
      --argjson labelIds "$esc_labels" \
      --arg parentId "$parent_id" \
      '{
        input: {
          teamId: $teamId,
          title: $title,
          description: $description,
          labelIds: $labelIds,
          parentId: $parentId
        }
      }')
  else
    variables=$(jq -nc \
      --argjson teamId "$team_id" \
      --argjson title "$esc_title" \
      --argjson description "$esc_description" \
      --argjson labelIds "$esc_labels" \
      '{
        input: {
          teamId: $teamId,
          title: $title,
          description: $description,
          labelIds: $labelIds
        }
      }')
  fi

  local query='mutation CreateIssue($input: IssueCreateInput!) { issueCreate(input: $input) { success issue { id identifier title } } }'
  local payload
  payload=$(jq -nc --arg query "$query" --argjson variables "$variables" '{query: $query, variables: $variables}')

  planner_linear_graphql "$payload"
}

# Fetch a single issue by identifier (e.g., "CRE-123").
# Args: <issue_identifier>
# Output: issue JSON on stdout.
planner_linear_get_issue() {
  local identifier="$1"

  local query='query GetIssue($id: String!) { issue(id: $id) { id identifier title description state { name } labels { nodes { name } } parent { id } } }'
  local payload
  payload=$(jq -nc --arg query "$query" --arg id "$identifier" '{query: $query, variables: {id: $id}}')

  planner_linear_graphql "$payload"
}
