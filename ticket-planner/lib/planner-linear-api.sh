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
#   planner_linear_create_issue <team_id> <title> <description> [labels_json] [parent_id] [project_ref] [milestone_ref]
#     Creates a Linear issue. labels_json holds label NAMES (resolved to UUIDs
#     internally); project_ref/milestone_ref take a name or UUID and default to
#     $LINEAR_PROJECT / $LINEAR_PROJECT_MILESTONE. Returns issue JSON on stdout.
#
#   planner_linear_build_issue_input <team_id> <title> <description> [label_ids_json] [parent_id] [project_id] [milestone_id]
#     Pure payload builder — no network. Unit-testable IssueCreateInput shape.
#
#   planner_linear_resolve_label_ids <team_id> <label_names_json>
#     Maps label names to UUIDs. Hard-fails naming any unresolvable label.
#
#   planner_linear_resolve_team_id [name_key_or_id]
#     Resolves the team to create on: explicit ref → $LINEAR_TEAM_ID → the only
#     team. Ambiguity is an error, never a guess.
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

# ── Name → id resolution ──────────────────────────────────────────────────────

# True when the argument already looks like a Linear entity UUID.
_planner_is_uuid() {
  [[ "$1" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]
}

# Per-team name→id cache, so creating N tickets costs one lookup per distinct
# label, not one per ticket. Holds a JSON object: {"planned": "uuid", ...}.
declare -gA _PLANNER_LABEL_CACHE 2>/dev/null || true

# Resolve label NAMES to label UUIDs for a team.
#
# IssueCreateInput.labelIds is typed [String!] and takes label UUIDs. Linear does
# not create labels implicitly and has no name-based variant on this input, so
# names must be resolved first. An unresolvable name is a hard failure: silently
# dropping one would produce a ticket without `planned`, which planned-ticket-check.sh
# and the whole ticket-auto fast-path depend on.
#
# The query filters on the requested names rather than listing the workspace, so
# it stays correct in a workspace whose `blocked-by:*` and `INIT-*` families have
# grown past any page size. Workspace-level labels (team == null) are usable by
# any team, so both are accepted, with a team-owned label winning over a
# workspace one of the same name.
#
# Usage: planner_linear_resolve_label_ids <team_id> <label_names_json>
# Output: JSON array of label UUIDs on stdout, in the requested order.
# Returns: 0 on success, 1 when any name is unresolvable.
planner_linear_resolve_label_ids() {
  local team_id="$1" names_json="${2:-[]}"

  # Nothing to resolve
  if [ -z "$names_json" ] || [ "$(echo "$names_json" | jq -r 'length')" = "0" ]; then
    echo "[]"
    return 0
  fi

  # Already UUIDs — pass through untouched (callers may pre-resolve). Matched on
  # the full UUID shape, not a prefix, so a label legitimately named like one
  # ("deadbeef-migration") is still resolved rather than sent through as an id.
  if [ "$(echo "$names_json" | jq -r 'map(test("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")) | all')" = "true" ]; then
    echo "$names_json" | jq -c .
    return 0
  fi

  local cache="${_PLANNER_LABEL_CACHE[$team_id]:-}"
  [ -z "$cache" ] && cache="{}"

  # Only look up names the cache does not already hold.
  local wanted
  wanted=$(jq -nc --argjson names "$names_json" --argjson cache "$cache" \
    '[$names[] as $n | select($cache | has($n) | not) | $n] | unique')

  if [ "$(echo "$wanted" | jq -r 'length')" != "0" ]; then
    local query='query LabelIds($names: [String!]!) { issueLabels(first: 250, filter: { name: { in: $names } }) { nodes { id name team { id } } } }'
    local payload resp nodes
    payload=$(jq -nc --arg query "$query" --argjson names "$wanted" \
      '{query: $query, variables: {names: $names}}')
    resp=$(planner_linear_graphql "$payload") || {
      echo "planner-linear-api: label lookup failed for team ${team_id}" >&2
      return 1
    }
    nodes=$(echo "$resp" | jq -c '.data.issueLabels.nodes // []')
    if [ "$nodes" = "null" ]; then nodes="[]"; fi

    # Merge into the cache, preferring a team-owned label over a same-named
    # workspace one.
    cache=$(jq -nc --argjson cache "$cache" --argjson nodes "$nodes" --arg teamId "$team_id" \
      '$cache + (
         [ $nodes[] | .name ] | unique
         | map(. as $n
             | ( [ $nodes[] | select(.name == $n) ]
                 | ( map(select(.team.id == $teamId)) + map(select(.team == null)) )
                 | first )
             | select(. != null)
             | {key: $n, value: .id})
         | from_entries
       )')
    _PLANNER_LABEL_CACHE[$team_id]="$cache"
  fi

  local missing
  missing=$(jq -rn --argjson names "$names_json" --argjson cache "$cache" \
    '[$names[] as $n | select($cache | has($n) | not) | $n] | unique | join(", ")')
  if [ -n "$missing" ]; then
    echo "planner-linear-api: unknown label(s) for team ${team_id}: ${missing}" >&2
    echo "Create them in Linear (or via issueLabelCreate) before planning — the planner" >&2
    echo "does not create labels implicitly, and dropping one would break the ticket-auto fast-path." >&2
    return 1
  fi

  jq -cn --argjson names "$names_json" --argjson cache "$cache" '[$names[] as $n | $cache[$n]]'
}

# Resolve a Linear project by name or id, scoped to a team.
# ── Team resolution ───────────────────────────────────────────────────────────

# Resolve the Linear team to create issues on.
#
# Every issue the planner creates needs a teamId, and nothing else in the planner
# derives one — the phase prompts referenced a $TEAM_ID that was never assigned,
# so every create call would have gone out with an empty team. Resolution order:
#
#   1. an explicit ref (the --team flag, persisted as config)
#   2. $LINEAR_TEAM_ID, the convention ticket-auto already uses
#   3. the workspace's only team, when there is exactly one
#
# More than one team with no ref is an error, not a guess: picking one would file
# a whole initiative against the wrong board.
#
# Usage: planner_linear_resolve_team_id [name_key_or_id]
# Output: team UUID on stdout. Returns 1 if unresolvable.
planner_linear_resolve_team_id() {
  local ref="${1:-${LINEAR_TEAM_ID:-}}"

  if _planner_is_uuid "$ref"; then
    echo "$ref"
    return 0
  fi

  local query='query Teams { teams(first: 250) { nodes { id key name } } }'
  local payload resp id count
  payload=$(jq -nc --arg query "$query" '{query: $query}')
  resp=$(planner_linear_graphql "$payload") || return 1

  if [ -n "$ref" ]; then
    # A team is addressable by key ("CRE") or by name — accept either.
    id=$(echo "$resp" | jq -r --arg ref "$ref" \
      '[.data.teams.nodes[]? | select(.key == $ref or .name == $ref) | .id] | first // ""')
    if [ -z "$id" ]; then
      echo "planner-linear-api: no team with key or name '${ref}'" >&2
      echo "Available: $(echo "$resp" | jq -r '[.data.teams.nodes[]? | "\(.key) (\(.name))"] | join(", ")')" >&2
      return 1
    fi
    echo "$id"
    return 0
  fi

  count=$(echo "$resp" | jq -r '[.data.teams.nodes[]?] | length')
  if [ "$count" = "1" ]; then
    echo "$resp" | jq -r '.data.teams.nodes[0].id'
    return 0
  fi

  if [ "$count" = "0" ]; then
    echo "planner-linear-api: the API token has access to no teams" >&2
    return 1
  fi

  echo "planner-linear-api: ${count} teams are visible — set LINEAR_TEAM_ID or pass --team" >&2
  echo "Available: $(echo "$resp" | jq -r '[.data.teams.nodes[]? | "\(.key) (\(.name))"] | join(", ")')" >&2
  return 1
}

# Usage: planner_linear_resolve_project <team_id> <name_or_id>
# Output: project UUID on stdout. Returns 1 if not found.
planner_linear_resolve_project() {
  local team_id="$1" ref="$2"

  [ -z "$ref" ] && {
    echo ""
    return 0
  }
  if _planner_is_uuid "$ref"; then
    echo "$ref"
    return 0
  fi

  local query='query TeamProjects($teamId: String!) { team(id: $teamId) { projects(first: 250) { nodes { id name } } } }'
  local payload resp id
  payload=$(jq -nc --arg query "$query" --arg teamId "$team_id" '{query: $query, variables: {teamId: $teamId}}')
  resp=$(planner_linear_graphql "$payload") || return 1

  id=$(echo "$resp" | jq -r --arg name "$ref" \
    '[.data.team.projects.nodes[]? | select(.name == $name) | .id] | first // ""')
  if [ -z "$id" ]; then
    echo "planner-linear-api: no project named '${ref}' on team ${team_id}" >&2
    echo "Available: $(echo "$resp" | jq -r '[.data.team.projects.nodes[]?.name] | join(", ")')" >&2
    return 1
  fi
  echo "$id"
}

# Resolve a project milestone by name or id within a project.
# Milestone creation is deliberately out of scope — a missing milestone is an error.
# Usage: planner_linear_resolve_milestone <project_id> <name_or_id>
# Output: milestone UUID on stdout. Returns 1 if not found.
planner_linear_resolve_milestone() {
  local project_id="$1" ref="$2"

  [ -z "$ref" ] && {
    echo ""
    return 0
  }
  if _planner_is_uuid "$ref"; then
    echo "$ref"
    return 0
  fi
  if [ -z "$project_id" ]; then
    echo "planner-linear-api: cannot resolve milestone '${ref}' without a project" >&2
    return 1
  fi

  local query='query ProjectMilestones($id: String!) { project(id: $id) { projectMilestones(first: 250) { nodes { id name } } } }'
  local payload resp id
  payload=$(jq -nc --arg query "$query" --arg id "$project_id" '{query: $query, variables: {id: $id}}')
  resp=$(planner_linear_graphql "$payload") || return 1

  id=$(echo "$resp" | jq -r --arg name "$ref" \
    '[.data.project.projectMilestones.nodes[]? | select(.name == $name) | .id] | first // ""')
  if [ -z "$id" ]; then
    echo "planner-linear-api: no milestone named '${ref}' in project ${project_id}" >&2
    echo "Available: $(echo "$resp" | jq -r '[.data.project.projectMilestones.nodes[]?.name] | join(", ")')" >&2
    return 1
  fi
  echo "$id"
}

# ── Issue helpers ─────────────────────────────────────────────────────────────

# Build the IssueCreateInput variables payload. Pure — makes no network call, so
# the payload shape is unit-testable without a token.
#
# Every scalar goes through `jq --arg`, which takes its value as a literal string.
# `--argjson` parses its value as JSON and so aborts on a bare UUID — that was the
# teamId defect. Optional fields are omitted entirely when empty rather than sent
# as null, so a workspace that does not use projects sees an unchanged payload.
#
# Args: <team_id> <title> <description> [label_ids_json] [parent_id] [project_id] [project_milestone_id]
# Output: {"input": {...}} on stdout.
planner_linear_build_issue_input() {
  local team_id="$1" title="$2" description="$3"
  local label_ids_json="${4:-[]}" parent_id="${5:-}" project_id="${6:-}" milestone_id="${7:-}"

  [ -z "$label_ids_json" ] && label_ids_json="[]"

  jq -nc \
    --arg teamId "$team_id" \
    --arg title "$title" \
    --arg description "$description" \
    --argjson labelIds "$label_ids_json" \
    --arg parentId "$parent_id" \
    --arg projectId "$project_id" \
    --arg projectMilestoneId "$milestone_id" \
    '{
      input: (
        {
          teamId: $teamId,
          title: $title,
          description: $description,
          labelIds: $labelIds
        }
        + (if $parentId == "" then {} else {parentId: $parentId} end)
        + (if $projectId == "" then {} else {projectId: $projectId} end)
        + (if $projectMilestoneId == "" then {} else {projectMilestoneId: $projectMilestoneId} end)
      )
    }'
}

# Create a Linear issue.
#
# `labels_json` accepts label NAMES (the natural thing for callers to have) and
# resolves them to UUIDs before the mutation. Passing UUIDs directly also works.
# `project_ref` / `milestone_ref` accept a name or a UUID; both are optional and
# omitted from the input when empty.
#
# Args: <team_id> <title> <description> [labels_json] [parent_id] [project_ref] [milestone_ref]
# Output: created issue JSON on stdout.
planner_linear_create_issue() {
  local team_id="$1" title="$2" description="$3"
  local labels_json="${4:-[]}" parent_id="${5:-}"
  local project_ref="${6:-${LINEAR_PROJECT:-}}"
  local milestone_ref="${7:-${LINEAR_PROJECT_MILESTONE:-}}"

  local label_ids
  label_ids=$(planner_linear_resolve_label_ids "$team_id" "$labels_json") || return 1

  local project_id=""
  if [ -n "$project_ref" ]; then
    project_id=$(planner_linear_resolve_project "$team_id" "$project_ref") || return 1
  fi

  local milestone_id=""
  if [ -n "$milestone_ref" ]; then
    milestone_id=$(planner_linear_resolve_milestone "$project_id" "$milestone_ref") || return 1
  fi

  local variables
  variables=$(planner_linear_build_issue_input \
    "$team_id" "$title" "$description" "$label_ids" "$parent_id" "$project_id" "$milestone_id")

  local query='mutation CreateIssue($input: IssueCreateInput!) { issueCreate(input: $input) { success issue { id identifier title url } } }'
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
