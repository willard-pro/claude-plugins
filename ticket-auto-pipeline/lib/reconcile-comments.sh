#!/usr/bin/env bash
# reconcile-comments.sh — boundary detection for pipeline comment reconciliation.
# Reads normalized comments JSON array from stdin.
# Args: <ticket_id> <log_file>
# Outputs structured key:value data for the orchestrator to parse.
set -euo pipefail

TICKET_ID="${1:-}"
LOG_FILE="${2:-}"
[ -z "$TICKET_ID" ] && {
  echo "Usage: $0 <ticket_id> <log_file>" >&2
  exit 1
}
[ -z "$LOG_FILE" ] && {
  echo "Usage: $0 <ticket_id> <log_file>" >&2
  exit 1
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/linear-api.sh"

# Read stdin and normalize
COMMENTS_JSON=$(cat | normalize_comments)

# Find appraisal comment by content prefix
APPRAISAL_COMMENT_AT=$(echo "$COMMENTS_JSON" | jq -r \
  '.[] | select(.body // "" | startswith("**Ticket appraised**")) | .createdAt' |
  sort | tail -1)

# Fallback to pipeline log if no appraisal comment found (deleted, or pre-standardization)
if [ -z "$APPRAISAL_COMMENT_AT" ]; then
  APPRAISAL_COMMENT_AT=$(grep '|APPRAISE|appraise|done|' "$LOG_FILE" 2>/dev/null |
    head -1 | cut -d'|' -f1 || true)
fi

# Find last amendment comment from a prior reconciliation cycle
LAST_AMENDMENT_AT=$(echo "$COMMENTS_JSON" | jq -r \
  '.[] | select(.body // "" | startswith("**Amendment cycle #")) | .createdAt' |
  sort | tail -1)

# LAST_RECONCILE_AT is the later of appraisal vs amendment boundary
if [ -n "$LAST_AMENDMENT_AT" ] && [[ "$LAST_AMENDMENT_AT" > "$APPRAISAL_COMMENT_AT" ]]; then
  LAST_RECONCILE_AT="$LAST_AMENDMENT_AT"
else
  LAST_RECONCILE_AT="$APPRAISAL_COMMENT_AT"
fi

# Extract comments strictly after boundary, excluding pipeline-authored comments
UNPROCESSED_COMMENTS=$(echo "$COMMENTS_JSON" | jq -r --arg boundary "$LAST_RECONCILE_AT" \
  '.[] | select(.createdAt > $boundary) | select(.body // "" | startswith("**Ticket appraised**") or startswith("**Amendment cycle #") | not) | "\(.createdAt)|\(.user.name)|\(.body)"')

echo "LAST_RECONCILE_AT: ${LAST_RECONCILE_AT}"
echo "APPRAISAL_COMMENT_AT: ${APPRAISAL_COMMENT_AT}"
echo "UNPROCESSED_COMMENTS:"
if [ -n "$UNPROCESSED_COMMENTS" ]; then
  echo "$UNPROCESSED_COMMENTS"
else
  echo "(none)"
fi
