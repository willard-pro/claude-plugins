#!/usr/bin/env bash
# GitHub Issues API helpers for ticket-retro --post-to-github.
# Source this file from skill scripts that need to create or update
# GitHub issues. Wraps the `gh` CLI with heartbeat instrumentation and
# canonical error handling.
#
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

# Error code for GitHub API failures (defined in error-handler.sh, fallback here)
E_GITHUB_API="${E_GITHUB_API:-11}"

# ── github_check_auth ─────────────────────────────────────────────────────────
# Verify gh CLI is installed and authenticated.
# Returns 0 if authenticated, 1 if not.
github_check_auth() {
  if ! command -v gh &>/dev/null; then
    echo "github_check_auth: gh CLI not found on PATH" >&2
    return 1
  fi

  local start elapsed
  start=$(date +%s%3N 2>/dev/null || echo 0)

  if gh auth status &>/dev/null; then
    elapsed=$(($(date +%s%3N 2>/dev/null || echo 0) - start))
    hb_api "github-request" "ok" "gh auth status succeeded" "{\"elapsed_ms\":\"$elapsed\"}"
    return 0
  fi

  elapsed=$(($(date +%s%3N 2>/dev/null || echo 0) - start))
  hb_api "github-request" "fail" "gh auth status failed" "{\"elapsed_ms\":\"$elapsed\"}"
  echo "github_check_auth: gh not authenticated — run 'gh auth login'" >&2
  return 1
}

# ── github_issue_lookup ──────────────────────────────────────────────────────
# Fetch the state and title of an existing GitHub issue.
# Usage: github_issue_lookup <number>
# Outputs JSON: {"state": "OPEN|CLOSED", "title": "..."}
# Returns 0 on success, non-zero if issue not found or API error.
github_issue_lookup() {
  local number="$1"
  local repo="${GITHUB_ISSUE_REPO:-willard-pro/claude-plugins}"

  if [ -z "$number" ]; then
    echo "github_issue_lookup: missing issue number" >&2
    return "$E_GITHUB_API"
  fi

  local start elapsed output
  start=$(date +%s%3N 2>/dev/null || echo 0)

  output=$(gh issue view "$number" --repo "$repo" --json state,title 2>&1) || {
    elapsed=$(($(date +%s%3N 2>/dev/null || echo 0) - start))
    hb_api "github-request" "fail" "gh issue view failed" "{\"elapsed_ms\":\"$elapsed\",\"issue\":\"$number\"}"
    echo "github_issue_lookup: issue #${number} lookup failed: $output" >&2
    return "$E_GITHUB_API"
  }

  elapsed=$(($(date +%s%3N 2>/dev/null || echo 0) - start))
  hb_api "github-request" "ok" "gh issue view succeeded" "{\"elapsed_ms\":\"$elapsed\",\"issue\":\"$number\"}"
  echo "$output"
}

# ── github_issue_create ──────────────────────────────────────────────────────
# Create a new GitHub issue.
# Usage: github_issue_create <title> <labels> <body_file>
#   labels: comma-separated string (e.g. "bug,P0")
#   body_file: path to a markdown file with the issue body
# Outputs the new issue URL on stdout.
# Returns 0 on success, non-zero on failure.
github_issue_create() {
  local title="$1"
  local labels="$2"
  local body_file="$3"
  local repo="${GITHUB_ISSUE_REPO:-willard-pro/claude-plugins}"

  if [ -z "$title" ] || [ -z "$body_file" ]; then
    echo "github_issue_create: missing title or body_file" >&2
    return "$E_GITHUB_API"
  fi

  if [ ! -f "$body_file" ]; then
    echo "github_issue_create: body file not found: $body_file" >&2
    return "$E_GITHUB_API"
  fi

  local start elapsed output
  start=$(date +%s%3N 2>/dev/null || echo 0)

  output=$(gh issue create \
    --repo "$repo" \
    --title "$title" \
    --label "$labels" \
    --body-file "$body_file" 2>&1) || {
    elapsed=$(($(date +%s%3N 2>/dev/null || echo 0) - start))
    hb_api "github-request" "fail" "gh issue create failed" "{\"elapsed_ms\":\"$elapsed\",\"title\":\"$title\"}"
    echo "github_issue_create: creation failed: $output" >&2
    return "$E_GITHUB_API"
  }

  elapsed=$(($(date +%s%3N 2>/dev/null || echo 0) - start))
  hb_api "github-request" "ok" "gh issue create succeeded" "{\"elapsed_ms\":\"$elapsed\",\"title\":\"$title\"}"
  echo "$output"
}

# ── github_issue_comment ─────────────────────────────────────────────────────
# Add a comment to an existing GitHub issue.
# Usage: github_issue_comment <number> <body_file>
#   body_file: path to a markdown file with the comment body
# Outputs the comment URL on stdout.
# Returns 0 on success, non-zero on failure.
github_issue_comment() {
  local number="$1"
  local body_file="$2"
  local repo="${GITHUB_ISSUE_REPO:-willard-pro/claude-plugins}"

  if [ -z "$number" ] || [ -z "$body_file" ]; then
    echo "github_issue_comment: missing number or body_file" >&2
    return "$E_GITHUB_API"
  fi

  if [ ! -f "$body_file" ]; then
    echo "github_issue_comment: body file not found: $body_file" >&2
    return "$E_GITHUB_API"
  fi

  # Guard against oversized comments
  local body_size
  body_size=$(wc -c < "$body_file" 2>/dev/null || echo 0)
  local max_size="${GITHUB_ISSUE_MAX_COMMENT_SIZE:-60000}"
  if [ "$body_size" -gt "$max_size" ]; then
    echo "github_issue_comment: body file exceeds max size (${body_size} > ${max_size})" >&2
    return "$E_GITHUB_API"
  fi

  local start elapsed output
  start=$(date +%s%3N 2>/dev/null || echo 0)

  output=$(gh issue comment "$number" \
    --repo "$repo" \
    --body-file "$body_file" 2>&1) || {
    elapsed=$(($(date +%s%3N 2>/dev/null || echo 0) - start))
    hb_api "github-request" "fail" "gh issue comment failed" "{\"elapsed_ms\":\"$elapsed\",\"issue\":\"$number\"}"
    echo "github_issue_comment: comment failed: $output" >&2
    return "$E_GITHUB_API"
  }

  elapsed=$(($(date +%s%3N 2>/dev/null || echo 0) - start))
  hb_api "github-request" "ok" "gh issue comment succeeded" "{\"elapsed_ms\":\"$elapsed\",\"issue\":\"$number\"}"
  echo "$output"
}
