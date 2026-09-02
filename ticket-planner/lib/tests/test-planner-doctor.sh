#!/usr/bin/env bash
# test-planner-doctor.sh — Tests for planner-doctor.sh (#232: /ticket-planner
# doctor preflight command).
#
# Every gap this file guards against was a real mid-run failure first:
# REPOS_ROOT unset/wrong, LINEAR_TEAM_ID unset, the 4 static contract labels
# silently missing, a live REPOS_ROOT checkout on the wrong branch relative
# to Discovery (#217), a missing INIT-* label (#223).
#
# Run: bash ticket-planner/lib/tests/test-planner-doctor.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/.."

source "${LIB_DIR}/planner-doctor.sh"

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

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

# Extract VALUE|STATUS-ish fields for one NAME from a doctor output blob.
# Usage: doctor_field <output> <name> <column 2|3|4|5>
doctor_row() {
  local output="$1" name="$2"
  echo "$output" | awk -F'|' -v n="$name" '$1==n{print;exit}'
}

echo "=== planner-doctor tests ==="

# ── Test 1: REPOS_ROOT states ────────────────────────────────────────────

echo "--- Test 1: REPOS_ROOT ---"

unset LINEAR_API_KEY LINEAR_TEAM_ID
unset REPOS_ROOT
OUT=$(planner_doctor_run 2>/dev/null)
ROW=$(doctor_row "$OUT" "REPOS_ROOT")
if echo "$ROW" | grep -q '|missing|'; then
  pass "unset REPOS_ROOT is reported missing"
else
  fail "unset REPOS_ROOT reported missing" "$ROW"
fi

export REPOS_ROOT="${TMPDIR}/does-not-exist"
OUT=$(planner_doctor_run 2>/dev/null)
ROW=$(doctor_row "$OUT" "REPOS_ROOT")
if echo "$ROW" | grep -q '|missing|'; then
  pass "REPOS_ROOT pointing at a non-directory is reported missing"
else
  fail "non-directory REPOS_ROOT reported missing" "$ROW"
fi

export REPOS_ROOT="${TMPDIR}/repos"
mkdir -p "$REPOS_ROOT"
OUT=$(planner_doctor_run 2>/dev/null)
ROW=$(doctor_row "$OUT" "REPOS_ROOT")
if echo "$ROW" | grep -q "|ok|${REPOS_ROOT}|"; then
  pass "a real REPOS_ROOT directory resolves ok"
else
  fail "real REPOS_ROOT resolves ok" "$ROW"
fi

# ── Test 2: Linear team + label resolution (mocked) ─────────────────────

echo "--- Test 2: team + static labels ---"

MOCK_TEAMS='{"data":{"teams":{"nodes":[{"id":"team-uuid-1","key":"CRE","name":"Credit"}]}}}'
MOCK_LABELS_ALL_PRESENT='{"data":{"issueLabels":{"nodes":[
  {"id":"lbl-planned","name":"planned","team":{"id":"team-uuid-1"}},
  {"id":"lbl-epic","name":"epic","team":{"id":"team-uuid-1"}},
  {"id":"lbl-pre-approved","name":"pre-approved","team":{"id":"team-uuid-1"}},
  {"id":"lbl-state-exec","name":"state:execution","team":{"id":"team-uuid-1"}}
]}}}'
MOCK_LABELS_ONE_MISSING='{"data":{"issueLabels":{"nodes":[
  {"id":"lbl-planned","name":"planned","team":{"id":"team-uuid-1"}},
  {"id":"lbl-epic","name":"epic","team":{"id":"team-uuid-1"}},
  {"id":"lbl-pre-approved","name":"pre-approved","team":{"id":"team-uuid-1"}}
]}}}'
MOCK_CREATE_LABEL='{"data":{"issueLabelCreate":{"success":true,"issueLabel":{"id":"lbl-new","name":"state:execution"}}}}'

_LABELS_RESPONSE="$MOCK_LABELS_ALL_PRESENT"
planner_linear_graphql() {
  local payload="$1"
  if echo "$payload" | grep -q '"query Teams'; then
    echo "$MOCK_TEAMS"
  elif echo "$payload" | grep -q '"query LabelIds'; then
    echo "$_LABELS_RESPONSE"
  elif echo "$payload" | grep -q '"mutation CreateLabel'; then
    echo "$MOCK_CREATE_LABEL"
  fi
}

export LINEAR_API_KEY="test-key"
export LINEAR_TEAM_ID="CRE"

OUT=$(planner_doctor_run 2>/dev/null)
ROW=$(doctor_row "$OUT" "LINEAR_TEAM_ID")
if echo "$ROW" | grep -q "|ok|team-uuid-1|"; then
  pass "team resolves via mocked Linear API"
else
  fail "team resolves" "$ROW"
fi

if echo "$OUT" | grep -q '^label:planned|ok|' &&
  echo "$OUT" | grep -q '^label:epic|ok|' &&
  echo "$OUT" | grep -q '^label:pre-approved|ok|' &&
  echo "$OUT" | grep -q '^label:state:execution|ok|'; then
  pass "all 4 static labels report ok when present"
else
  fail "all 4 static labels ok" "$OUT"
fi

# Missing LINEAR_API_KEY → team unresolved → labels skipped, not silently ok.
unset LINEAR_API_KEY
OUT=$(planner_doctor_run 2>/dev/null)
if doctor_row "$OUT" "LINEAR_TEAM_ID" | grep -q '|missing|' &&
  echo "$OUT" | grep -q '^label:planned|warn|'; then
  pass "missing LINEAR_API_KEY skips (not fakes) label checks"
else
  fail "missing LINEAR_API_KEY skips label checks" "$OUT"
fi
export LINEAR_API_KEY="test-key"

# One label genuinely missing — the exact defect from #223, found twice.
_LABELS_RESPONSE="$MOCK_LABELS_ONE_MISSING"
OUT=$(planner_doctor_run 2>/dev/null)
if echo "$OUT" | grep -q '^label:state:execution|missing|'; then
  pass "a genuinely missing static label is reported missing"
else
  fail "missing static label reported" "$OUT"
fi
EXIT_CODE=0
planner_doctor_run >/dev/null 2>&1 || EXIT_CODE=$?
if [ "$EXIT_CODE" -gt 0 ]; then
  pass "a missing label is reflected in the non-zero return code"
else
  fail "non-zero return on missing label" "exit=$EXIT_CODE"
fi

# --fix creates the missing label instead of only reporting it.
OUT=$(planner_doctor_run --fix 2>/dev/null)
if echo "$OUT" | grep -q '^label:state:execution|fixed|lbl-new|'; then
  pass "--fix creates a genuinely missing static label"
else
  fail "--fix creates missing label" "$OUT"
fi

_LABELS_RESPONSE="$MOCK_LABELS_ALL_PRESENT"

# ── Test 3: resume-scoped repo-ref check (#217) ──────────────────────────

echo "--- Test 3: resume-scoped repo-ref alignment ---"

REPO_DIR="${REPOS_ROOT}/ledgerly"
mkdir -p "${REPO_DIR}"
git -C "$REPOS_ROOT" init -q ledgerly
git -C "$REPO_DIR" config user.email "test@example.com"
git -C "$REPO_DIR" config user.name "Test"
echo "one" >"${REPO_DIR}/a.txt"
git -C "$REPO_DIR" add -A
git -C "$REPO_DIR" commit -q -m "baseline"
git -C "$REPO_DIR" branch -M main
BASELINE_SHA=$(git -C "$REPO_DIR" rev-parse HEAD)

git -C "$REPO_DIR" checkout -q -b develop
echo "two" >"${REPO_DIR}/b.txt"
git -C "$REPO_DIR" add -A
git -C "$REPO_DIR" commit -q -m "develop work"
DEVELOP_SHA=$(git -C "$REPO_DIR" rev-parse HEAD)
git -C "$REPO_DIR" checkout -q main

source "${LIB_DIR}/planner-state.sh"
INIT_ID="INIT-doctor-test-1"
planner_state_init "$INIT_ID" "doctor test" >/dev/null 2>&1
planner_state_write "$INIT_ID" "META" "discovery" "repo-ref" "ledgerly@develop@${DEVELOP_SHA}" >/dev/null 2>&1

OUT=$(planner_doctor_run "$INIT_ID" 2>/dev/null)
ROW=$(doctor_row "$OUT" "repo-ref:ledgerly")
if echo "$ROW" | grep -q '|ok|' && echo "$ROW" | grep -q "REPOS_ROOT/ledgerly-crosscheck"; then
  pass "a diverged live checkout gets an isolated worktree, reported ok"
else
  fail "diverged checkout ensures a worktree" "$ROW"
fi

# Live checkout already at the pinned sha — no worktree needed.
git -C "$REPO_DIR" checkout -q develop 2>/dev/null || true
INIT_ID2="INIT-doctor-test-2"
planner_state_init "$INIT_ID2" "doctor test 2" >/dev/null 2>&1
planner_state_write "$INIT_ID2" "META" "discovery" "repo-ref" "ledgerly@develop@${DEVELOP_SHA}" >/dev/null 2>&1
OUT=$(planner_doctor_run "$INIT_ID2" 2>/dev/null)
ROW=$(doctor_row "$OUT" "repo-ref:ledgerly")
if echo "$ROW" | grep -q "|ok|${DEVELOP_SHA}|REPOS_ROOT/ledgerly|"; then
  pass "a live checkout already matching Discovery's ref needs no worktree"
else
  fail "matching checkout reported ok without a worktree" "$ROW"
fi
git -C "$REPO_DIR" checkout -q main

# No initiative id — repo-ref check is informational, not a failure.
OUT=$(planner_doctor_run 2>/dev/null)
ROW=$(doctor_row "$OUT" "repo-ref")
if echo "$ROW" | grep -q '|info|'; then
  pass "omitting the initiative id reports repo-ref as informational"
else
  fail "no-initiative-id repo-ref is informational" "$ROW"
fi

# ── Test 4: cross-plugin helper scripts resolve from this checkout ──────

echo "--- Test 4: helper scripts ---"

OUT=$(planner_doctor_run 2>/dev/null)
if doctor_row "$OUT" "planned-ticket-check.sh" | grep -q '|ok|' &&
  doctor_row "$OUT" "branch-directive-check.sh" | grep -q '|ok|'; then
  pass "cross-plugin validator scripts resolve from the sibling plugin checkout"
else
  fail "cross-plugin validators resolve" "$OUT"
fi

# ── Test 5: output shape ─────────────────────────────────────────────────

echo "--- Test 5: output shape ---"

if echo "$OUT" | grep -q '^---BEGIN_VARS---$' && echo "$OUT" | grep -q '^---END_VARS---$'; then
  pass "output is wrapped in BEGIN/END markers"
else
  fail "BEGIN/END markers present" "$OUT"
fi

ROWCOUNT_LINE=$(echo "$OUT" | grep '^ROWCOUNT=')
DECLARED=${ROWCOUNT_LINE#ROWCOUNT=}
ACTUAL=$(echo "$OUT" | sed -n '/^---BEGIN_VARS---$/,/^---END_VARS---$/p' | grep -c '|')
# ACTUAL includes the header row; DECLARED counts data rows only.
if [ "$((ACTUAL - 1))" = "$DECLARED" ]; then
  pass "ROWCOUNT matches the number of emitted data rows"
else
  fail "ROWCOUNT matches emitted rows" "declared=$DECLARED actual_data_rows=$((ACTUAL - 1))"
fi

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
