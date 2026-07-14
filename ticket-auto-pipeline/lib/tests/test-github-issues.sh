#!/usr/bin/env bash
# Tests for lib/github-issues.sh
# Run: bash lib/tests/test-github-issues.sh
set -eo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(dirname "$TEST_DIR")"

# ── Mock gh CLI ─────────────────────────────────────────────────────────────
# $GH_MOCK_MODE controls behavior:
#   auth-ok        gh auth status → 0
#   auth-fail      gh auth status → 1
#   lookup-open    gh issue view → {"state":"OPEN","title":"Test Issue"}
#   lookup-closed  gh issue view → {"state":"CLOSED","title":"Resolved Issue"}
#   lookup-none    gh issue view → exit 1
#   create-ok      gh issue create → https://github.com/org/repo/issues/99
#   create-fail    gh issue create → exit 1
#   comment-ok     gh issue comment → https://github.com/org/repo/issues/42#issuecomment-1
#   comment-fail   gh issue comment → exit 1
GH_MOCK_MODE=""

gh() {
  case "$GH_MOCK_MODE" in
    auth-ok)
      [ "$1" = "auth" ] && return 0
      ;;
    auth-fail)
      [ "$1" = "auth" ] && return 1
      ;;
    lookup-open)
      if [ "$1" = "issue" ] && [ "$2" = "view" ]; then
        echo '{"state":"OPEN","title":"Test Issue"}'
        return 0
      fi
      ;;
    lookup-closed)
      if [ "$1" = "issue" ] && [ "$2" = "view" ]; then
        echo '{"state":"CLOSED","title":"Resolved Issue"}'
        return 0
      fi
      ;;
    lookup-none)
      if [ "$1" = "issue" ] && [ "$2" = "view" ]; then
        echo "gh: issue 99999 not found" >&2
        return 1
      fi
      ;;
    create-ok)
      if [ "$1" = "issue" ] && [ "$2" = "create" ]; then
        echo "https://github.com/willard-pro/claude-plugins/issues/99"
        return 0
      fi
      ;;
    create-fail)
      if [ "$1" = "issue" ] && [ "$2" = "create" ]; then
        echo "gh: permission denied" >&2
        return 1
      fi
      ;;
    comment-ok)
      if [ "$1" = "issue" ] && [ "$2" = "comment" ]; then
        echo "https://github.com/willard-pro/claude-plugins/issues/42#issuecomment-1"
        return 0
      fi
      ;;
    comment-fail)
      if [ "$1" = "issue" ] && [ "$2" = "comment" ]; then
        echo "gh: not found" >&2
        return 1
      fi
      ;;
  esac
  echo "gh: unexpected call: $*" >&2
  return 1
}

# ── Setup ───────────────────────────────────────────────────────────────────
# Prevent heartbeat.sh/config.sh/error-handler.sh from writing anywhere
export HB_LOG_FILE=""
export CLAUDE_LOG_FILE=""

source "$LIB_DIR/github-issues.sh"

PASS=0
FAIL=0

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    ((PASS++)) || true
    echo "  PASS: $desc"
  else
    ((FAIL++)) || true
    echo "  FAIL: $desc — expected '$expected', got '$actual'"
  fi
}

assert_ok() {
  local desc="$1" code="$2"
  if [ "$code" -eq 0 ]; then
    ((PASS++)) || true
    echo "  PASS: $desc"
  else
    ((FAIL++)) || true
    echo "  FAIL: $desc — expected exit 0, got $code"
  fi
}

assert_fail() {
  local desc="$1" code="$2"
  if [ "$code" -ne 0 ]; then
    ((PASS++)) || true
    echo "  PASS: $desc"
  else
    ((FAIL++)) || true
    echo "  FAIL: $desc — expected non-zero exit, got $code"
  fi
}

# Safe runner — captures exit code without triggering set -e
run_test() {
  set +e
  "$@" 2>/dev/null
  echo $?
  set -e
}

# ── Test: github_check_auth ─────────────────────────────────────────────────
echo "### github_check_auth"

GH_MOCK_MODE="auth-ok"
CODE=$(run_test github_check_auth)
assert_ok "authenticated when gh auth status succeeds" "$CODE"

GH_MOCK_MODE="auth-fail"
CODE=$(run_test github_check_auth)
assert_fail "unauthenticated when gh auth status fails" "$CODE"

# Test gh CLI not installed — subshell with empty PATH so command -v fails
CODE=$( (unset -f gh; PATH='' github_check_auth) 2>/dev/null; echo $?)
assert_fail "returns 1 when gh not on PATH" "$CODE"

# ── Test: github_issue_lookup ───────────────────────────────────────────────
echo "### github_issue_lookup"

GH_MOCK_MODE="lookup-open"
OUTPUT=$(github_issue_lookup 84 2>/dev/null) || true
CODE=$?
assert_ok "returns 0 for open issue" "$CODE"
assert_eq "returns JSON with OPEN state" "OPEN" "$(echo "$OUTPUT" | jq -r '.state')"

GH_MOCK_MODE="lookup-closed"
OUTPUT=$(github_issue_lookup 84 2>/dev/null) || true
CODE=$?
assert_ok "returns 0 for closed issue" "$CODE"
assert_eq "returns JSON with CLOSED state" "CLOSED" "$(echo "$OUTPUT" | jq -r '.state')"

GH_MOCK_MODE="lookup-none"
CODE=$(run_test github_issue_lookup 99999)
assert_fail "returns non-zero for nonexistent issue" "$CODE"

# Missing number
CODE=$(run_test github_issue_lookup "")
assert_fail "returns non-zero for missing number" "$CODE"

# ── Test: github_issue_create ────────────────────────────────────────────────
echo "### github_issue_create"

BODY_FILE=$(mktemp)
echo "Test body" > "$BODY_FILE"
trap 'rm -f "$BODY_FILE"' EXIT

GH_MOCK_MODE="create-ok"
OUTPUT=$(github_issue_create "Test Title" "bug,P0" "$BODY_FILE" 2>/dev/null) || true
CODE=$?
assert_ok "returns 0 on successful creation" "$CODE"
assert_eq "returns issue URL" "https://github.com/willard-pro/claude-plugins/issues/99" "$OUTPUT"

GH_MOCK_MODE="create-fail"
CODE=$(run_test github_issue_create "Test Title" "bug,P0" "$BODY_FILE")
assert_fail "returns non-zero on creation failure" "$CODE"

# Missing args
CODE=$(run_test github_issue_create "" "bug" "$BODY_FILE")
assert_fail "returns non-zero for missing title" "$CODE"

# Missing body file
CODE=$(run_test github_issue_create "Title" "bug" "/nonexistent/path.md")
assert_fail "returns non-zero for missing body file" "$CODE"

# ── Test: github_issue_comment ───────────────────────────────────────────────
echo "### github_issue_comment"

COMMENT_FILE=$(mktemp)
echo "Test comment" > "$COMMENT_FILE"
trap 'rm -f "$BODY_FILE" "$COMMENT_FILE"' EXIT

GH_MOCK_MODE="comment-ok"
OUTPUT=$(github_issue_comment 42 "$COMMENT_FILE" 2>/dev/null) || true
CODE=$?
assert_ok "returns 0 on successful comment" "$CODE"
assert_eq "returns comment URL" "https://github.com/willard-pro/claude-plugins/issues/42#issuecomment-1" "$OUTPUT"

GH_MOCK_MODE="comment-fail"
CODE=$(run_test github_issue_comment 42 "$COMMENT_FILE")
assert_fail "returns non-zero on comment failure" "$CODE"

# Missing number
CODE=$(run_test github_issue_comment "" "$COMMENT_FILE")
assert_fail "returns non-zero for missing number" "$CODE"

# ── Test: state file roundtrip ───────────────────────────────────────────────
echo "### state file roundtrip"

STATE_FILE=$(mktemp)
trap 'rm -f "$BODY_FILE" "$COMMENT_FILE" "$STATE_FILE"' EXIT

cat > "$STATE_FILE" <<'EOF'
{
  "EXEC_NO_ARTIFACT": {"issue_number": 84, "issue_url": "https://github.com/willard-pro/claude-plugins/issues/84", "last_evidence": "2026-07-10", "count": 4}
}
EOF

READ_BACK=$(jq -r '.EXEC_NO_ARTIFACT.issue_number' "$STATE_FILE")
assert_eq "reads issue_number from state file" "84" "$READ_BACK"

READ_COUNT=$(jq -r '.EXEC_NO_ARTIFACT.count' "$STATE_FILE")
assert_eq "reads count from state file" "4" "$READ_COUNT"

# Test writing updated state
jq --arg code "APPROVAL_REVOKED" \
   --arg num "85" \
   --arg url "https://github.com/willard-pro/claude-plugins/issues/85" \
   --arg date "2026-07-14" \
   --arg count "2" \
   '. + {($code): {issue_number: $num, issue_url: $url, last_evidence: $date, count: $count}}' \
   "$STATE_FILE" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"

READ_NEW=$(jq -r '.APPROVAL_REVOKED.issue_number' "$STATE_FILE")
assert_eq "writes new entry to state file" "85" "$READ_NEW"

# ── Summary ─────────────────────────────────────────────────────────────────
echo ""
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
