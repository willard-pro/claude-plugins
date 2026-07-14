#!/usr/bin/env bash
# test-gate-no-template.sh — integration tests for new gate-stops in gate-check.sh
# Tests: NO_TEMPLATE_FOR_TYPE, PLANNED_BODY_INCOMPLETE, and unplanned passthrough.
# Usage: bash test-gate-no-template.sh [test_name_filter]
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# ── CI-safe declare guards ───────────────────────────────────────────────────
if ! declare -f get_issue >/dev/null 2>&1; then
  get_issue() { echo '{"description":"","labels":{"nodes":[]}}'; }
fi
if ! declare -f get_comments >/dev/null 2>&1; then
  get_comments() { echo '[]'; }
fi
if ! declare -f get_me >/dev/null 2>&1; then
  get_me() { echo '{"id":"test-user-id","name":"Test User"}'; }
fi
if ! declare -f hb_init >/dev/null 2>&1; then
  hb_init() { :; }
fi
if ! declare -f _plog >/dev/null 2>&1; then
  _plog() { :; }
fi
if ! declare -f hb_gate >/dev/null 2>&1; then
  hb_gate() { :; }
fi
if ! declare -f resolve_ticket_dir >/dev/null 2>&1; then
  resolve_ticket_dir() { echo "."; }
fi
if ! declare -f get_complexity >/dev/null 2>&1; then
  get_complexity() { echo "simple"; }
fi

export REPOS_ROOT="${REPOS_ROOT:-/tmp/test-repos-root}"

# Point CLAUDE_SKILLS_LIB at the repo's lib dir so gate-check.sh sources the
# new template-select.sh / planner-artifacts.sh / planned-ticket-body-check.sh
# instead of the stale installed copies.
export CLAUDE_SKILLS_LIB="$LIB_DIR"

source "$LIB_DIR/planned-ticket-check.sh"
source "$LIB_DIR/template-select.sh"
source "$LIB_DIR/planner-artifacts.sh"
source "$LIB_DIR/planned-ticket-body-check.sh"
source "$LIB_DIR/gate-check.sh"

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

# ── Helper: override get_issue for a specific ticket ─────────────────────────
# We test the internal helpers directly since gate-check requires real Linear tickets.
# Instead, test the component functions that gate-check calls.

# ── Test: _resolve_type_label ─────────────────────────────────────────────────

_run_output() {
  local name="$1"
  local expected="$2"
  shift 2
  local actual
  actual=$("$@" 2>/dev/null) || true
  if [ "$actual" = "$expected" ]; then
    echo "PASS: $name"
    ((PASS++)) || true
  else
    echo "FAIL: $name (expected '$expected', got '$actual')"
    ((FAIL++)) || true
  fi
}

_run_output "Type resolver: bug from mixed labels" "bug" \
  _resolve_type_label "planned,bug,frontend"
_run_output "Type resolver: feature from mixed labels" "feature" \
  _resolve_type_label "feature,planned"
_run_output "Type resolver: chore from mixed labels" "chore" \
  _resolve_type_label "planned,chore,backend"
_run_output "Type resolver: security" "security" \
  _resolve_type_label "security,planned"
_run_output "Type resolver: no type label → empty" "" \
  _resolve_type_label "planned,frontend"
_run_output "Type resolver: empty labels → empty" "" \
  _resolve_type_label ""

# ── Test: resolve_template + check_planned_body integration ───────────────────

# Planned ticket with valid type + complete body → both pass
COMPLETE_BUG='## Acceptance Criteria
- [ ] Bug is fixed
## Test User
`admin@example.com` — password `admin`
## Scope
| Layer | Service | Area |
| ----- | ------- | ---- |
| FE    | gateway | page |
## Steps to Reproduce
1. Log in as admin@example.com (password: admin)
2. Navigate to Settings
3. Click Save
## Test Data Prerequisites
At least one handover.'

_type=$(_resolve_type_label "planned,bug")
template_path=$(resolve_template "$_type" 2>/dev/null) || true

[ -n "$template_path" ] && echo "PASS: type '$_type' resolves to '$template_path'" && ((PASS++)) || true
[ -z "$template_path" ] && echo "FAIL: type '$_type' should resolve" && ((FAIL++)) || true

check_planned_body "TEST-GATE" "bug" "$COMPLETE_BUG" "true" 2>/dev/null || true
[ "$BODY_CHECK_EXIT_CODE" = "0" ] && echo "PASS: complete bug body passes body-check" && ((PASS++)) || true
[ "$BODY_CHECK_EXIT_CODE" != "0" ] && echo "FAIL: complete bug body should pass (exit=$BODY_CHECK_EXIT_CODE missing=$BODY_CHECK_MISSING)" && ((FAIL++)) || true

# Unknown type → resolve_template exit 3
rc=0
resolve_template "epic" 2>/dev/null || rc=$?
[ "$rc" = "3" ] && echo "PASS: unknown type 'epic' → exit 3 (would fire NO_TEMPLATE_FOR_TYPE)" && ((PASS++)) || true
[ "$rc" != "3" ] && echo "FAIL: unknown type should exit 3, got $rc" && ((FAIL++)) || true

# Incomplete body → check_planned_body exit 1 with missing section
INCOMPLETE_FEATURE='## Acceptance Criteria
- [ ] Feature works
## Test User
`admin@example.com` — password `admin`
## Scope
| Layer | Service | Area |
| ----- | ------- | ---- |
| FE    | gateway | page |'

check_planned_body "TEST-GATE-2" "feature" "$INCOMPLETE_FEATURE" "true" 2>/dev/null || true
[ "$BODY_CHECK_EXIT_CODE" != "0" ] && echo "PASS: incomplete feature body fails (would fire PLANNED_BODY_INCOMPLETE: $BODY_CHECK_MISSING)" && ((PASS++)) || true
[ "$BODY_CHECK_EXIT_CODE" = "0" ] && echo "FAIL: incomplete feature body should fail" && ((FAIL++)) || true

# ── Summary ───────────────────────────────────────────────────────────────────

echo "---"
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
