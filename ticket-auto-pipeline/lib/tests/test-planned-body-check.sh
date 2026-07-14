#!/usr/bin/env bash
# test-planned-body-check.sh — unit tests for lib/planned-ticket-body-check.sh
# Usage: bash test-planned-body-check.sh [test_name_filter]
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# ── CI-safe declare guards ───────────────────────────────────────────────────
if ! declare -f get_issue >/dev/null 2>&1; then
  get_issue() {
    echo "get_issue: CI stub" >&2
    echo '{"description":"","labels":{"nodes":[]}}'
  }
fi
if ! declare -f _plog >/dev/null 2>&1; then
  _plog() { :; }
fi
if ! declare -f hb_gate >/dev/null 2>&1; then
  hb_gate() { :; }
fi

export REPOS_ROOT="${REPOS_ROOT:-/tmp/test-repos-root}"

source "$LIB_DIR/planned-ticket-check.sh"
source "$LIB_DIR/planner-artifacts.sh"
source "$LIB_DIR/planned-ticket-body-check.sh"

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

_run_check() {
  local name="$1"
  local expected_exit="$2"
  local expected_missing="$3"
  shift 3
  check_planned_body "$@" 2>/dev/null || true
  if [ "$BODY_CHECK_EXIT_CODE" = "$expected_exit" ]; then
    if [ -n "$expected_missing" ]; then
      if echo "$BODY_CHECK_MISSING" | grep -q "$expected_missing"; then
        echo "PASS: $name (exit=$BODY_CHECK_EXIT_CODE missing='$BODY_CHECK_MISSING')"
        ((PASS++)) || true
      else
        echo "FAIL: $name (expected missing='$expected_missing', got '$BODY_CHECK_MISSING')"
        ((FAIL++)) || true
      fi
    else
      echo "PASS: $name (exit=$BODY_CHECK_EXIT_CODE)"
      ((PASS++)) || true
    fi
  else
    echo "FAIL: $name (expected exit $expected_exit, got $BODY_CHECK_EXIT_CODE, missing='$BODY_CHECK_MISSING')"
    ((FAIL++)) || true
  fi
}

# ── Test bodies ───────────────────────────────────────────────────────────────

COMPLETE_BUG_BODY='## Acceptance Criteria
- [ ] Save button works after form is filled
- [ ] Error toast appears on validation failure
## Test User
`admin@example.com` — password `admin`
## Scope
| Layer | Service | Area |
| ----- | ------- | ---- |
| FE    | gateway | handover-form |
## Steps to Reproduce
1. Log in as admin@example.com (password: admin)
2. Navigate via `Handover > Pending`
3. Click on handover #123
4. Observe that save button is disabled
## Test Data Prerequisites
At least one handover in status Pending assigned to test user.'

COMPLETE_FEATURE_BODY='## Acceptance Criteria
- [ ] New "Export CSV" button appears on handover list
- [ ] Clicking button downloads CSV with correct columns
## Test User
`admin@example.com` — password `admin`
## Scope
| Layer | Service | Area |
| ----- | ------- | ---- |
| FE    | gateway | handover-list |
| BE    | handover | export-service |
## Navigation Path
`Handover > List > Export CSV`'

FEATURE_MISSING_NAV='## Acceptance Criteria
- [ ] Feature works as expected
## Test User
`admin@example.com` — password `admin`
## Scope
| Layer | Service | Area |
| ----- | ------- | ---- |
| FE    | gateway | page |'

BUG_MISSING_REPRO='## Acceptance Criteria
- [ ] Bug is fixed
## Test User
`admin@example.com` — password `admin`
## Scope
| Layer | Service | Area |
| ----- | ------- | ---- |
| FE    | gateway | page |'

# ── Tests ─────────────────────────────────────────────────────────────────────

# 1. Complete bug body → exit 0
_run_check "complete bug body passes" 0 "" \
  "TEST-1" "bug" "$COMPLETE_BUG_BODY" "true"

# 2. Complete feature body → exit 0
_run_check "complete feature body passes" 0 "" \
  "TEST-2" "feature" "$COMPLETE_FEATURE_BODY" "true"

# 3. Feature missing Navigation Path → exit 1
_run_check "feature missing Nav Path fails" 1 "Navigation Path" \
  "TEST-3" "feature" "$FEATURE_MISSING_NAV" "true"

# 4. Bug missing Steps to Reproduce → exit 1
_run_check "bug missing repro steps fails" 1 "Steps to Reproduce" \
  "TEST-4" "bug" "$BUG_MISSING_REPRO" "true"

# 5. Empty body → exit 2 (body_source_unavailable)
_run_check "empty body → exit 2" 2 "body_source_unavailable" \
  "TEST-5" "bug" "" "true"

# 6. Plane body.md preferred over description (when plane exists)
TEST_DIR="$REPOS_ROOT/.ticket-auto/initiatives/INIT-42/tickets/TEST-6/planner"
mkdir -p "$TEST_DIR"
echo "$COMPLETE_BUG_BODY" >"$TEST_DIR/body.md"
# Provide a desc with Planner Context (so plane resolves) but thin body content that
# would fail if used — the plane body.md should be preferred instead.
PLANE_DESC_WITH_THIN_BODY='## Planner Context
**Schema-Version:** 1
**Initiative:** INIT-42
**Epic:** EPIC-1
**Confidence:** 0.92
**Strategy:** Conservative
**Decision:** Fix bug
**Affected Services:** collector
**Target Symbols:** DebtCollector.collect:src/collector.ts:42
**Pre-approved:** true
**Generated:** 2026-07-01T12:00:00Z
**Regenerate:** false

thin description body — this should NOT be used because plane body.md exists'
_run_check "plane body preferred — complete bug passes even with thin desc" 0 "" \
  "TEST-6" "bug" "$PLANE_DESC_WITH_THIN_BODY" "true"

# 7. chore type — universal sections only (no Nav Path required)
CHORE_BODY='## Acceptance Criteria
- [ ] Dependencies updated
## Test User
`admin@example.com` — password `admin`
## Scope
| Layer | Service | Area |
| ----- | ------- | ---- |
| Infra | ci      | pipeline |'
_run_check "chore body with universal sections passes" 0 "" \
  "TEST-7" "chore" "$CHORE_BODY" "true"

# 8. Security type — universal sections only
_run_check "security body with universal sections passes" 0 "" \
  "TEST-8" "security" "$CHORE_BODY" "true"

# Cleanup
rm -rf "$REPOS_ROOT/.ticket-auto"

# ── Summary ───────────────────────────────────────────────────────────────────

echo "---"
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
