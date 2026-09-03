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

  # A well-formed GraphQL success response (top-level "data" key, no .errors —
  # already ruled out above) is terminal regardless of what its field content
  # says. Skip the keyword scan below entirely, otherwise a ticket whose title
  # or description legitimately mentions "timeout"/"temporary"/"rate limit"
  # false-positives as transient on a request that already succeeded, burning
  # all retries and then hard-failing a call that worked.
  if echo "$body" | jq -e '.data' >/dev/null 2>&1; then
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
    query: "query($id: String!) { issue(id: $id) { id identifier title description priority url createdAt dueDate team { id name } state { id name type } labels { nodes { id name } } project { id name } parent { id identifier title description } assignee { id name } creator { id name } } }",
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

# Update an issue.
#
# Two argument shapes are supported, and may be combined in a single call:
#
#   1. Legacy positional (backward compatible — pre-existing call shape,
#      unchanged for every current caller):
#        update_issue <issue_id> [state_id] [label_ids_json] [assignee_id]
#      Pass empty strings ("") to skip state/labels/assignee.
#
#   2. Named flags (new — reaches the rest of IssueUpdateInput):
#        update_issue <issue_id> [--state <id>] [--labels <json>] [--assignee <id>]
#                                 [--title <str>] [--description <str>]
#                                 [--project <id>] [--parent <id>] [--priority <0-4>]
#
# Detection is unambiguous, not clever: after <issue_id>, up to 3 leading
# args are consumed as state_id/label_ids/assignee_id (shape 1) ONE AT A
# TIME, stopping the instant an arg starts with "--" — so 0, 1, 2, or 3
# legacy positionals may precede the flags in a single call. Whatever
# remains is parsed strictly as --flag value pairs. An unrecognized --flag
# is a hard error (return 1) rather than a silent no-op.
#
# Only non-empty fields are added to the IssueUpdateInput; omitted/empty
# fields are left untouched on the Linear issue (unchanged behavior for
# state/labels/assignee, extended to title/description/project/parent/priority).
update_issue() {
  local issue_id="$1"
  shift || true

  local state_id="" label_ids="" assignee_id=""
  local title="" description="" project_id="" parent_id="" priority=""

  # Legacy positional mode: consume at most 3 leading args, but stop as
  # soon as a --flag is seen — re-checked before EACH slot, not just once,
  # so a call with 1 or 2 legacy positionals followed by flags parses
  # correctly instead of swallowing the flag token as a positional value.
  if [ $# -gt 0 ] && [[ "$1" != --* ]]; then
    state_id="${1:-}"
    shift
  fi
  if [ $# -gt 0 ] && [[ "$1" != --* ]]; then
    label_ids="${1:-}"
    shift
  fi
  if [ $# -gt 0 ] && [[ "$1" != --* ]]; then
    assignee_id="${1:-}"
    shift
  fi

  while [ $# -gt 0 ]; do
    case "$1" in
    --state)
      state_id="${2:-}"
      shift 2
      ;;
    --labels)
      label_ids="${2:-}"
      shift 2
      ;;
    --assignee)
      assignee_id="${2:-}"
      shift 2
      ;;
    --title)
      title="${2:-}"
      shift 2
      ;;
    --description)
      description="${2:-}"
      shift 2
      ;;
    --project)
      project_id="${2:-}"
      shift 2
      ;;
    --parent)
      parent_id="${2:-}"
      shift 2
      ;;
    --priority)
      priority="${2:-}"
      shift 2
      ;;
    *)
      echo "update_issue: unknown argument: $1" >&2
      return 1
      ;;
    esac
  done

  # Build input object dynamically — only non-empty fields are included.
  local input="{}"
  [ -n "$state_id" ] && input=$(echo "$input" | jq --arg s "$state_id" '. + {stateId: $s}')
  [ -n "$label_ids" ] && input=$(echo "$input" | jq --argjson l "$label_ids" '. + {labelIds: $l}')
  [ -n "$assignee_id" ] && input=$(echo "$input" | jq --arg a "$assignee_id" '. + {assigneeId: $a}')
  [ -n "$title" ] && input=$(echo "$input" | jq --arg v "$title" '. + {title: $v}')
  [ -n "$description" ] && input=$(echo "$input" | jq --arg v "$description" '. + {description: $v}')
  [ -n "$project_id" ] && input=$(echo "$input" | jq --arg v "$project_id" '. + {projectId: $v}')
  [ -n "$parent_id" ] && input=$(echo "$input" | jq --arg v "$parent_id" '. + {parentId: $v}')
  if [ -n "$priority" ]; then
    input=$(echo "$input" | jq --arg v "$priority" '. + {priority: ($v | tonumber)}') || {
      echo "update_issue: --priority must be numeric, got: $priority" >&2
      return 1
    }
  fi

  local query
  query=$(jq -n --arg id "$issue_id" --argjson input "$input" '{
    query: "mutation($id: String!, $input: IssueUpdateInput!) { issueUpdate(id: $id, input: $input) { success issue { id identifier } } }",
    variables: {id: $id, input: $input}
  }')
  local resp
  resp=$(linear_graphql "$query")
  echo "$resp" | jq '.data.issueUpdate'
}

# Create a new Linear issue.
#
# Positional argument shape — deliberately NOT the flag-based style
# update_issue() grew in #284. update_issue() moved to flags because an
# update call legitimately skips almost every field ("4 args is already a
# lot, more make it unreadable"), so flags let a caller name only the
# field(s) it's touching. create_issue() doesn't have that ambiguity: every
# call needs team_id + title + description as required fields, and
# project_id/parent_id/label_ids are a small, fixed, ordered set of optional
# trailing fields — there's no "which of these am I skipping" confusion a
# flag shape would resolve. This mirrors the issue's own suggested
# signature.
#
# ticket-planner/lib/planner-linear-api.sh's planner_linear_build_issue_input()
# builds a comparably-shaped IssueCreateInput, but it additionally resolves
# label NAMES and project/milestone refs to Linear IDs via get_team()/
# get_project() lookups. This helper deliberately does none of that — per
# #283 (which cites #280, handled separately) it accepts only a
# pre-resolved label_ids JSON array, same convention update_issue() already
# uses for its label_ids argument. Callers that need name resolution do it
# themselves before calling in.
#
# Only non-empty optional fields are added to the IssueCreateInput (dynamic
# jq '. + {field: $v}' build, same incremental pattern update_issue() uses).
# The response is guarded with _jq_guard on .data.issueCreate.issue before
# unwrapping — same convention as get_issue()/get_team() — so a malformed
# response or a success:false result (Linear returns a null issue in that
# case) is a clean error return, not a silent/corrupt object.
#
# Args: <team_id> <title> <description> [project_id] [parent_id] [label_ids_json]
# Output: {id, identifier, title, url} JSON on stdout (the created issue).
create_issue() {
  local team_id="$1"
  local title="$2"
  local description="$3"
  local project_id="${4:-}"
  local parent_id="${5:-}"
  local label_ids="${6:-}"

  if [ -z "$team_id" ] || [ -z "$title" ] || [ -z "$description" ]; then
    echo "create_issue: team_id, title, and description are required" >&2
    return 1
  fi

  local input
  input=$(jq -n --arg teamId "$team_id" --arg title "$title" --arg description "$description" '{
    teamId: $teamId,
    title: $title,
    description: $description
  }')
  [ -n "$project_id" ] && input=$(echo "$input" | jq --arg v "$project_id" '. + {projectId: $v}')
  [ -n "$parent_id" ] && input=$(echo "$input" | jq --arg v "$parent_id" '. + {parentId: $v}')
  [ -n "$label_ids" ] && input=$(echo "$input" | jq --argjson l "$label_ids" '. + {labelIds: $l}')

  local query
  query=$(jq -n --argjson input "$input" '{
    query: "mutation($input: IssueCreateInput!) { issueCreate(input: $input) { success issue { id identifier title url } } }",
    variables: {input: $input}
  }')
  local resp
  resp=$(linear_graphql "$query")

  # Type guard: verify .data.issueCreate.issue exists before querying.
  # A success:false response comes back with issue: null, so this guard
  # also catches that case, not just a structurally malformed response.
  if ! _jq_guard "$resp" ".data.issueCreate.issue" "object"; then
    echo "create_issue: unexpected response shape — .data.issueCreate.issue missing or not an object" >&2
    echo "null"
    return 1
  fi
  echo "$resp" | jq '.data.issueCreate.issue'
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

# resolve_uat_url [project_dir]
# Echoes the configured UAT environment URL. Resolution order:
#   1. UAT_URL environment variable
#   2. a UAT_URL line in project_dir/CLAUDE.md (default: current directory)
# Exit 0 when a URL was resolved (echoed on stdout), 1 when none is configured.
#
# Factored out of env-check.sh, which is a reporting script with top-level
# argument parsing and therefore cannot be sourced. This is the resolver that
# replaces get_project_config — a function that no longer exists in this file,
# but which the UAT-vs-Done routing step still called.
resolve_uat_url() {
  local project_dir="${1:-.}"

  if [ -n "${UAT_URL:-}" ]; then
    echo "$UAT_URL"
    return 0
  fi

  local claude_md="$project_dir/CLAUDE.md"
  [ -f "$claude_md" ] || return 1

  local val=""
  # Anchored form first (the authoritative extraction env-check.sh uses),
  # then the looser inline form it also accepts.
  val=$(grep -oP '^`?UAT_URL`?\s*[=:]\s*`?\K[^`\s]+' "$claude_md" 2>/dev/null | head -1 | tr -d ' ' || true)
  if [ -z "$val" ]; then
    val=$(grep -oP 'UAT_URL[=:]\s*\K\S+' "$claude_md" 2>/dev/null | head -1 | tr -d '`' | tr -d ' ' || true)
  fi

  [ -n "$val" ] || return 1
  echo "$val"
  return 0
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
