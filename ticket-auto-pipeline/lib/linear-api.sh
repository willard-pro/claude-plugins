#!/usr/bin/env bash
# Shared Linear GraphQL API helpers. Source this file from skill scripts.
set -euo pipefail

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
    echo "transient"; return
  fi

  # HTTP 5xx server errors
  if [[ "$http_code" =~ ^5 ]]; then
    echo "transient"; return
  fi

  # GraphQL-level transient messages
  if echo "$body" | grep -qiE 'rate.limit|timeout|temporar'; then
    echo "transient"; return
  fi

  echo "permanent"
}

# Low-level GraphQL call. Args: query_json_string
# query_json_string = jq -n formatted {"query": "...", "variables": {...}}
linear_graphql() {
  local payload="$1"
  check_api_key

  local attempt=0
  local delays=(1 2 4)
  local resp http_code curl_exit

  while true; do
    http_code=""
    curl_exit=0
    resp=$(curl -s -w '\n%{http_code}' -X POST "$LINEAR_API_URL" \
      -H "Authorization: ${LINEAR_API_KEY}" \
      -H "Content-Type: application/json" \
      -d "$payload" 2>&1) || curl_exit=$?

    if [ "$curl_exit" -eq 0 ]; then
      http_code=$(echo "$resp" | tail -1)
      resp=$(echo "$resp" | head -n -1)
    fi

    local class
    class=$(_retry_classify "$curl_exit" "${http_code:-0}" "$resp")

    if [ "$class" = "transient" ] && [ "$attempt" -lt 3 ]; then
      echo "linear_graphql: transient error (attempt $((attempt+1))/3, http=${http_code:-curl-err}), retrying in ${delays[$attempt]}s" >&2
      sleep "${delays[$attempt]}"
      ((attempt++)) || true
      continue
    fi

    if [ "$curl_exit" -ne 0 ]; then
      echo "curl error after $attempt retries: $resp" >&2
      exit 2
    fi

    if [ "$class" = "transient" ]; then
      echo "linear_graphql: transient error persisted after 3 attempts (http=$http_code)" >&2
      exit 2
    fi

    # Check for GraphQL errors in the body
    if echo "$resp" | jq -e '.errors' > /dev/null 2>&1; then
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
  local label_ids="${3:-}"   # JSON array string e.g. '["id1","id2"]'
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

# Get project-level config (currently searches for UAT_URL).
# Returns JSON: {"UAT_URL": "<url>", "source": "<description>"}
# Resolution order:
#   1. $UAT_URL env var
#   2. $REPOS_ROOT children CLAUDE.md files
#   3. git rev-parse --show-toplevel CLAUDE.md
#   4. Ancestor walk up to 5 levels above CWD
get_project_config() {
  local project_name="${1:-}"
  local uat_url=""
  local source=""

  # 1. Environment variable
  if [ -n "${UAT_URL:-}" ]; then
    uat_url="$UAT_URL"
    source="env:UAT_URL"
  fi

  # 2. REPOS_ROOT children
  if [ -z "$uat_url" ] && [ -n "${REPOS_ROOT:-}" ] && [ -d "${REPOS_ROOT:-}" ]; then
    for claude_md in "$REPOS_ROOT"/*/CLAUDE.md; do
      [ -f "$claude_md" ] || continue
      local found
      found=$(grep -hoP 'UAT_URL[=:]\s*\K\S+' "$claude_md" 2>/dev/null | head -1 || true)
      if [ -n "$found" ]; then
        uat_url="$found"
        source="repos-root:$claude_md"
        break
      fi
    done
  fi

  # 3. Legacy workspace roots (container and host paths)
  if [ -z "$uat_url" ]; then
    for ws in /home/dexter/repos /home/mortal/workspace/workbench; do
      [ -d "$ws" ] || continue
      local found
      found=$(grep -rhoP 'UAT_URL[=:]\s*\K\S+' "$ws"/*/CLAUDE.md 2>/dev/null | head -1 || true)
      if [ -n "$found" ]; then
        uat_url="$found"
        source="workspace:$ws"
        break
      fi
    done
  fi

  # 4. Git repo root CLAUDE.md
  if [ -z "$uat_url" ]; then
    local git_root
    git_root=$(git rev-parse --show-toplevel 2>/dev/null || true)
    if [ -n "$git_root" ] && [ -f "$git_root/CLAUDE.md" ]; then
      local found
      found=$(grep -hoP 'UAT_URL[=:]\s*\K\S+' "$git_root/CLAUDE.md" 2>/dev/null || true)
      if [ -n "$found" ]; then
        uat_url="$found"
        source="git-root:$git_root/CLAUDE.md"
      fi
    fi
  fi

  # 5. Ancestor walk (bounded to 5 levels above CWD)
  if [ -z "$uat_url" ]; then
    local dir="$PWD"
    local level=0
    while [ "$level" -lt 5 ] && [ "$dir" != "/" ]; do
      dir="$(dirname "$dir")"
      ((level++)) || true
      if [ -f "$dir/CLAUDE.md" ]; then
        local found
        found=$(grep -hoP 'UAT_URL[=:]\s*\K\S+' "$dir/CLAUDE.md" 2>/dev/null || true)
        if [ -n "$found" ]; then
          uat_url="$found"
          source="ancestor:$dir/CLAUDE.md"
          break
        fi
      fi
    done
  fi

  # Emit pipeline log if LOG_FILE is set
  if [ -n "${LOG_FILE:-}" ]; then
    if [ -n "$uat_url" ]; then
      echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|META|uat-url|info|${source}:${uat_url}" >> "$LOG_FILE"
    else
      echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|META|uat-url|warn|missing" >> "$LOG_FILE"
      echo "WARN: no UAT_URL found in env, workspace, git root, or ancestor CLAUDE.md files" >&2
    fi
  fi

  echo "{\"UAT_URL\": \"${uat_url:-}\", \"source\": \"${source:-}\"}"
}

# Get current user (me) info from Linear
get_me() {
  local query
  query='{"query": "query { viewer { id name } }"}'
  local resp
  resp=$(linear_graphql "$query")
  echo "$resp" | jq '.data.viewer'
}
