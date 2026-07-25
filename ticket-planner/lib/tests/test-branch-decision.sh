#!/usr/bin/env bash
# test-branch-decision.sh — Tests for planner_branch_directive_recommend
#
# Usage: bash lib/tests/test-branch-decision.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/.."

source "${LIB_DIR}/planner-deps-check.sh"
source "${LIB_DIR}/planner-state.sh"

PASS=0
FAIL=0

# ── Fixture helpers ───────────────────────────────────────────────────────────

# Create a temporary initiative with spec files containing Signals JSON blocks.
# Usage: make_fixture <initiative_id> <spec_names...>
# Each spec_name should be a colon-separated tuple: name:blocked_by_csv
# e.g., make_fixture INIT-TEST-1 "t1:t2,t3" "t2:t3" "t3:"
make_fixture() {
  local initiative_id="$1"
  shift
  local repos_root="${REPOS_ROOT:-${HOME}/repos}"
  local specs_dir="${repos_root}/.ticket-auto/initiatives/${initiative_id}/artifacts/specs"

  mkdir -p "$specs_dir"

  # Write INDEX.md
  echo "# Spec Index" >"${specs_dir}/INDEX.md"

  # Write each spec file
  for spec_def in "$@"; do
    local name="${spec_def%%:*}"
    local blocked_csv="${spec_def#*:}"

    # Build blocked_by JSON array
    local blocked_json="[]"
    if [ -n "$blocked_csv" ] && [ "$blocked_csv" != "$name" ]; then
      blocked_json=$(echo "$blocked_csv" | tr ',' '\n' | jq -R . | jq -s .)
    fi

    # Use printf to avoid heredoc backtick expansion issues.
    # Code fences must be literal backticks, not command substitution.
    printf '## Title\n%s\n\n## Description\nTest spec for %s\n\n## Labels\n- feature\n\n## Signals\n```json\n{\n  "services_identified": 1,\n  "symbols_resolved": 3,\n  "prior_art_found": false,\n  "complexity": "simple",\n  "exploration_depth": "standard",\n  "blocked_by": %s\n}\n```\n' \
      "$name" "$name" "$blocked_json" >"${specs_dir}/${name}.md"
  done
}

# Clean up fixture directory
clean_fixture() {
  local initiative_id="$1"
  local repos_root="${REPOS_ROOT:-${HOME}/repos}"
  rm -rf "${repos_root}/.ticket-auto/initiatives/${initiative_id}"
}

# ── Test cases ────────────────────────────────────────────────────────────────

echo "=== Recommender tests ==="

# Test 1: 2 tickets → no recommendation
echo "--- Test 1: 2 tickets → no ---"
INIT_ID="INIT-TEST-BD-1"
make_fixture "$INIT_ID" "t1:" "t2:t1"
RESULT=$(planner_branch_directive_recommend "$INIT_ID")
RECOMMEND=$(echo "$RESULT" | jq -r '.recommend')
COUNT=$(echo "$RESULT" | jq -r '.ticket_count')
[ "$RECOMMEND" = "false" ] && [ "$COUNT" = "2" ] && echo "PASS: 2 tickets, not recommended" && PASS=$((PASS + 1)) || {
  echo "FAIL: got recommend=$RECOMMEND count=$COUNT"
  FAIL=$((FAIL + 1))
}
clean_fixture "$INIT_ID"

# Test 2: 3 independent tickets → no recommendation
echo "--- Test 2: 3 independent → no ---"
INIT_ID="INIT-TEST-BD-2"
make_fixture "$INIT_ID" "a:" "b:" "c:"
RESULT=$(planner_branch_directive_recommend "$INIT_ID")
RECOMMEND=$(echo "$RESULT" | jq -r '.recommend')
DEPTH=$(echo "$RESULT" | jq -r '.chain_depth')
[ "$RECOMMEND" = "false" ] && [ "$DEPTH" = "0" ] && echo "PASS: 3 independent tickets, not recommended (depth=$DEPTH)" && PASS=$((PASS + 1)) || {
  echo "FAIL: got recommend=$RECOMMEND depth=$DEPTH"
  FAIL=$((FAIL + 1))
}
clean_fixture "$INIT_ID"

# Test 3: 3 tickets chained (depth ≥ 2) → recommendation
echo "--- Test 3: 3 chained (depth 2) → yes ---"
INIT_ID="INIT-TEST-BD-3"
# a → b → c  (c blocked_by b, b blocked_by a)
make_fixture "$INIT_ID" "a:" "b:a" "c:b"
RESULT=$(planner_branch_directive_recommend "$INIT_ID")
RECOMMEND=$(echo "$RESULT" | jq -r '.recommend')
DEPTH=$(echo "$RESULT" | jq -r '.chain_depth')
COUNT=$(echo "$RESULT" | jq -r '.ticket_count')
[ "$RECOMMEND" = "true" ] && [ "$DEPTH" -ge 2 ] && [ "$COUNT" = "3" ] && echo "PASS: 3 chained tickets, recommended (depth=$DEPTH)" && PASS=$((PASS + 1)) || {
  echo "FAIL: got recommend=$RECOMMEND depth=$DEPTH count=$COUNT"
  FAIL=$((FAIL + 1))
}
clean_fixture "$INIT_ID"

# Test 4: 3 tickets with only depth-1 edges → no recommendation
echo "--- Test 4: 3 tickets, depth 1 only → no ---"
INIT_ID="INIT-TEST-BD-4"
# a → b, a → c (b and c both blocked_by a, no deeper chain)
make_fixture "$INIT_ID" "a:" "b:a" "c:a"
RESULT=$(planner_branch_directive_recommend "$INIT_ID")
RECOMMEND=$(echo "$RESULT" | jq -r '.recommend')
DEPTH=$(echo "$RESULT" | jq -r '.chain_depth')
[ "$RECOMMEND" = "false" ] && [ "$DEPTH" -lt 2 ] && echo "PASS: depth-1 only, not recommended (depth=$DEPTH)" && PASS=$((PASS + 1)) || {
  echo "FAIL: got recommend=$RECOMMEND depth=$DEPTH"
  FAIL=$((FAIL + 1))
}
clean_fixture "$INIT_ID"

# Test 5: Determinism — repeated evaluation yields identical output
echo "--- Test 5: determinism ---"
INIT_ID="INIT-TEST-BD-5"
make_fixture "$INIT_ID" "x:" "y:x" "z:y"
R1=$(planner_branch_directive_recommend "$INIT_ID")
R2=$(planner_branch_directive_recommend "$INIT_ID")
[ "$R1" = "$R2" ] && echo "PASS: repeated evaluation yields identical output" && PASS=$((PASS + 1)) || {
  echo "FAIL: runs differ: R1=$R1 R2=$R2"
  FAIL=$((FAIL + 1))
}
clean_fixture "$INIT_ID"

# Test 6: Missing specs directory → graceful failure
echo "--- Test 6: missing directory → graceful ---"
RESULT=$(planner_branch_directive_recommend "INIT-NONEXISTENT" 2>/dev/null) && rc=$? || rc=$?
# jq // treats false as falsy, so use .recommend directly — "false" is the expected string
RECOMMEND=$(echo "$RESULT" | jq -r '.recommend')
[ "$RECOMMEND" = "false" ] && echo "PASS: missing directory returns not-recommended" && PASS=$((PASS + 1)) || {
  echo "FAIL: got recommend=$RECOMMEND rc=$rc"
  FAIL=$((FAIL + 1))
}

# ── Summary ───────────────────────────────────────────────────────────────────

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] && echo "All recommender tests passed." || echo "Some tests FAILED."
exit "$FAIL"
