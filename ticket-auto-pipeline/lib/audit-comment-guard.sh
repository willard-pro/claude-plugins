#!/usr/bin/env bash
# audit-comment-guard.sh — Idempotency guard for ticket-audit-exec comments.
# Fetches existing ticket comments, greps for Source: {source-id}.
# Exit 0 if found (skip posting), exit 1 if not found (safe to post).
#
# Usage:
#   bash audit-comment-guard.sh <ticket_id> <source_id>
#   if [ $? -eq 0 ]; then echo "Already posted, skip"; fi

set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

audit_comment_guard() {
  local ticket_id="$1"
  local source_id="$2"

  if [ -z "$ticket_id" ] || [ -z "$source_id" ]; then
    echo "Usage: audit-comment-guard.sh <ticket_id> <source_id>" >&2
    exit 2
  fi

  # Source linear-api.sh for get_comments
  local api_lib="$SCRIPT_DIR/linear-api.sh"
  if [ ! -f "$api_lib" ]; then
    echo "audit-comment-guard: cannot find linear-api.sh" >&2
    exit 2
  fi
  source "$api_lib"

  local comments
  comments=$(get_comments "$ticket_id" 2>/dev/null || echo "[]")

  # Search for the source marker in comment bodies
  local marker="Source: ${source_id}"
  if echo "$comments" | jq -e --arg marker "$marker" '.[] | select(.body | contains($marker))' >/dev/null 2>&1; then
    exit 0  # Found — skip
  else
    exit 1  # Not found — safe to post
  fi
}

# Allow sourcing or direct execution
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  audit_comment_guard "$@"
fi
