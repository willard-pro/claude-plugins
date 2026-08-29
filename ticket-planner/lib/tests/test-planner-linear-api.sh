#!/usr/bin/env bash
# test-planner-linear-api.sh — Payload-shape tests for planner-linear-api.sh.
#
# planner_linear_create_issue had zero coverage, which is how two independent
# IssueCreateInput defects shipped (issue #139): labelIds carrying {name:...}
# objects where the schema wants UUIDs, and teamId passed through `jq --argjson`,
# which aborts on a bare UUID because it is not valid JSON.
#
# These tests assert on the built JSON only — no network, no token.
#
# Run: bash ticket-planner/lib/tests/test-planner-linear-api.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/.."

source "${LIB_DIR}/planner-linear-api.sh"

TEAM_UUID="c33944ff-9aee-408e-b98e-00dbaa98ae02"

QUERY_LOG=""
CAPTURE_FILE=""
trap 'rm -f "$QUERY_LOG" "$CAPTURE_FILE"' EXIT

PASS=0
FAIL=0
pass() {
  echo "  PASS $1"
  PASS=$((PASS + 1))
}
fail() {
  echo "  FAIL $1: $2"
  FAIL=$((FAIL + 1))
}

echo "=== planner-linear-api.sh tests ==="

# ── Test 1: a bare UUID teamId builds a valid payload ───────────────────────────
#
# The regression that motivates this file. `--argjson teamId "$TEAM_UUID"` makes
# jq exit non-zero before any payload exists.

echo "--- Test 1: bare-UUID teamId ---"

if out=$(planner_linear_build_issue_input "$TEAM_UUID" "Title" "Body" '["id-1"]' 2>&1); then
  pass "jq exits 0 with a bare-UUID team id"
else
  fail "jq exits 0 with a bare-UUID team id" "$out"
fi

got=$(planner_linear_build_issue_input "$TEAM_UUID" "Title" "Body" '["id-1"]' | jq -r '.input.teamId')
if [ "$got" = "$TEAM_UUID" ]; then
  pass "teamId round-trips as a string"
else
  fail "teamId round-trips as a string" "got '$got'"
fi

# ── Test 2: labelIds is an array of plain strings, never name objects ───────────

echo "--- Test 2: labelIds shape ---"

payload=$(planner_linear_build_issue_input "$TEAM_UUID" "T" "D" '["uuid-a","uuid-b"]')

if [ "$(echo "$payload" | jq -r '.input.labelIds | map(type) | unique | join(",")')" = "string" ]; then
  pass "labelIds is an array of strings (not {name:...} objects)"
else
  fail "labelIds is an array of strings" "$(echo "$payload" | jq -c '.input.labelIds')"
fi

if [ "$(echo "$payload" | jq -r '[.input.labelIds[] | has("name")? // false] | any')" != "true" ]; then
  pass "no labelIds entry carries a name key"
else
  fail "no labelIds entry carries a name key" "$(echo "$payload" | jq -c '.input.labelIds')"
fi

# ── Test 3: multi-line and pipe-bearing text survives encoding ──────────────────

echo "--- Test 3: description encoding ---"

desc=$'## Planner Context\n\n| a | b |\n| 1 | 2 |\n"quoted" and \\backslash'
got=$(planner_linear_build_issue_input "$TEAM_UUID" "T" "$desc" | jq -r '.input.description')
if [ "$got" = "$desc" ]; then
  pass "multi-line description with pipes, quotes and backslashes round-trips"
else
  fail "description round-trips" "got '$got'"
fi

# ── Test 4: optional fields are omitted, not nulled ─────────────────────────────
#
# A workspace that does not use projects must see the exact payload it saw before
# projectId was plumbed (issue #142) — absence, not null.

echo "--- Test 4: optional field omission ---"

minimal=$(planner_linear_build_issue_input "$TEAM_UUID" "T" "D")
keys=$(echo "$minimal" | jq -r '.input | keys | join(",")')
if [ "$keys" = "description,labelIds,teamId,title" ]; then
  pass "empty optional args produce exactly the four base keys"
else
  fail "empty optional args produce four base keys" "got '$keys'"
fi

for field in parentId projectId projectMilestoneId; do
  if [ "$(echo "$minimal" | jq "has(\"input\") and (.input | has(\"$field\"))")" = "false" ]; then
    pass "${field} absent when not supplied"
  else
    fail "${field} absent when not supplied" "present"
  fi
done

# ── Test 5: supplied optional fields land ──────────────────────────────────────

echo "--- Test 5: project and milestone are plumbed ---"

full=$(planner_linear_build_issue_input "$TEAM_UUID" "T" "D" '["l"]' "parent-1" "proj-1" "ms-1")
for pair in "parentId:parent-1" "projectId:proj-1" "projectMilestoneId:ms-1"; do
  field="${pair%%:*}"
  want="${pair#*:}"
  got=$(echo "$full" | jq -r ".input.${field}")
  if [ "$got" = "$want" ]; then
    pass "${field} = ${want}"
  else
    fail "${field} = ${want}" "got '$got'"
  fi
done

# ── Test 6: label name → UUID resolution ───────────────────────────────────────

echo "--- Test 6: label resolution ---"

# Stub the transport. Everything above this point is network-free; this replaces
# the one function that would reach out.
planner_linear_graphql() {
  cat <<'JSON'
{"data":{"issueLabels":{"nodes":[
  {"id":"uuid-planned","name":"planned","team":{"id":"c33944ff-9aee-408e-b98e-00dbaa98ae02"}},
  {"id":"uuid-preapp","name":"pre-approved","team":null},
  {"id":"uuid-other-team","name":"planned","team":{"id":"other-team"}}
]}}}
JSON
}

unset _PLANNER_LABEL_CACHE
declare -gA _PLANNER_LABEL_CACHE

got=$(planner_linear_resolve_label_ids "$TEAM_UUID" '["planned","pre-approved"]')
if [ "$got" = '["uuid-planned","uuid-preapp"]' ]; then
  pass "names resolve to UUIDs, team label preferred over a same-named other-team label"
else
  fail "names resolve to UUIDs" "got '$got'"
fi

if err=$(planner_linear_resolve_label_ids "$TEAM_UUID" '["planned","nonexistent"]' 2>&1); then
  fail "unknown label is a hard failure" "returned 0 with '$err'"
else
  if echo "$err" | grep -q "nonexistent"; then
    pass "unknown label hard-fails and names the missing label"
  else
    fail "unknown label names the missing label" "$err"
  fi
fi

got=$(planner_linear_resolve_label_ids "$TEAM_UUID" '[]')
if [ "$got" = "[]" ]; then
  pass "empty label list resolves to an empty array without a query"
else
  fail "empty label list" "got '$got'"
fi

got=$(planner_linear_resolve_label_ids "$TEAM_UUID" '["11111111-2222-3333-4444-555555555555"]')
if [ "$got" = '["11111111-2222-3333-4444-555555555555"]' ]; then
  pass "already-resolved UUIDs pass through untouched"
else
  fail "UUID passthrough" "got '$got'"
fi

# The lookup is name-filtered rather than a full workspace listing, so it stays
# correct once the blocked-by:* / INIT-* families outgrow any page size. That
# makes the per-team cache incremental: only names it does not hold are queried.

echo "--- Test 6b: incremental label cache ---"

QUERY_LOG="$(mktemp)"

CATALOGUE='[
  {"id":"uuid-planned","name":"planned","team":{"id":"c33944ff-9aee-408e-b98e-00dbaa98ae02"}},
  {"id":"uuid-preapp","name":"pre-approved","team":null},
  {"id":"uuid-init","name":"INIT-42","team":null}
]'

planner_linear_graphql() {
  local names
  names=$(echo "$1" | jq -c '.variables.names')
  echo "$names" >>"$QUERY_LOG"
  # Mirror the real filtered query: return only the requested names.
  jq -nc --argjson catalogue "$CATALOGUE" --argjson names "$names" \
    '{data: {issueLabels: {nodes: [$catalogue[] | select(.name as $n | $names | index($n))]}}}'
}

unset _PLANNER_LABEL_CACHE
declare -gA _PLANNER_LABEL_CACHE

planner_linear_resolve_label_ids "$TEAM_UUID" '["planned","pre-approved"]' >/dev/null
planner_linear_resolve_label_ids "$TEAM_UUID" '["planned","INIT-42"]' >/dev/null

if [ "$(wc -l <"$QUERY_LOG")" = "2" ]; then
  pass "a second call with a new name issues exactly one more query"
else
  fail "one query per new-name batch" "$(wc -l <"$QUERY_LOG") queries"
fi

if [ "$(sed -n 2p "$QUERY_LOG")" = '["INIT-42"]' ]; then
  pass "the second query asks only for the uncached name"
else
  fail "second query asks only for uncached names" "$(sed -n 2p "$QUERY_LOG")"
fi

planner_linear_resolve_label_ids "$TEAM_UUID" '["planned","pre-approved","INIT-42"]' >/dev/null
if [ "$(wc -l <"$QUERY_LOG")" = "2" ]; then
  pass "a fully cached call issues no query at all"
else
  fail "fully cached call issues no query" "$(wc -l <"$QUERY_LOG") queries"
fi

got=$(planner_linear_resolve_label_ids "$TEAM_UUID" '["INIT-42","planned"]')
if [ "$got" = '["uuid-init","uuid-planned"]' ]; then
  pass "ids come back in the requested order, not catalogue order"
else
  fail "requested order preserved" "got '$got'"
fi

# ── Test 7: end-to-end input, labels resolved ──────────────────────────────────

echo "--- Test 7: create_issue builds a schema-valid input ---"

# create_issue is invoked inside a command substitution, so a variable set by the
# stub would not survive the subshell. Capture to a file instead.
CAPTURE_FILE="$(mktemp)"

planner_linear_graphql() {
  local body="$1"
  if echo "$body" | grep -q "issueCreate"; then
    printf '%s' "$body" >"$CAPTURE_FILE"
    echo '{"data":{"issueCreate":{"success":true,"issue":{"id":"i1","identifier":"CRE-1","title":"T","url":"u"}}}}'
    return 0
  fi
  echo '{"data":{"issueLabels":{"nodes":[{"id":"uuid-planned","name":"planned","team":{"id":"c33944ff-9aee-408e-b98e-00dbaa98ae02"}}]}}}'
}

unset _PLANNER_LABEL_CACHE
declare -gA _PLANNER_LABEL_CACHE

resp=$(LINEAR_PROJECT="" LINEAR_PROJECT_MILESTONE="" \
  planner_linear_create_issue "$TEAM_UUID" "My ticket" "Body" '["planned"]')

if [ "$(echo "$resp" | jq -r '.data.issueCreate.issue.identifier')" = "CRE-1" ]; then
  pass "create_issue returns the created issue JSON"
else
  fail "create_issue returns issue JSON" "$resp"
fi

if [ "$(jq -r '.variables.input.labelIds | join(",")' "$CAPTURE_FILE")" = "uuid-planned" ]; then
  pass "create_issue sends resolved label UUIDs in the mutation"
else
  fail "create_issue sends resolved label UUIDs" "$(jq -c '.variables.input' "$CAPTURE_FILE")"
fi

if [ "$(jq -r '.variables.input.teamId' "$CAPTURE_FILE")" = "$TEAM_UUID" ]; then
  pass "create_issue sends teamId as a string"
else
  fail "create_issue sends teamId" "$(jq -c '.variables.input' "$CAPTURE_FILE")"
fi

echo ""
echo "=== planner-linear-api.sh: ${PASS} passed, ${FAIL} failed ==="
[ "$FAIL" -eq 0 ]
