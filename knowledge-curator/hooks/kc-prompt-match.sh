#!/usr/bin/env bash
# kc-prompt-match.sh — UserPromptSubmit hook for knowledge-curator.
#
# Greps the user's prompt against knowledge/INDEX.md tags and titles.
# On match, injects relevant items as context.
# Fail-open: exits 0 silently on no match, missing directory, or any error.
#
# Performance target: <100ms for typical INDEX.md against a typical prompt.
# Pure bash grep — no LLM call, no external process beyond grep.

set -euo pipefail

KNOWLEDGE_DIR="./knowledge"
INDEX_FILE="$KNOWLEDGE_DIR/INDEX.md"

# Fail-open: no knowledge directory = silent no-op
[ -d "$KNOWLEDGE_DIR" ] || exit 0
[ -f "$INDEX_FILE" ] || exit 0

# Read prompt from stdin (harness passes the user prompt)
PROMPT=$(cat 2>/dev/null || echo "")
[ -z "$PROMPT" ] && exit 0

# Extract potential search terms from prompt (words 3+ chars, skip common words)
TERMS=$(echo "$PROMPT" | tr -c '[:alnum:]-\n' ' ' | tr '[:upper:]' '[:lower:]' | tr ' ' '\n' | \
  grep -vE '^(the|and|for|that|this|with|from|have|are|was|not|but|all|can|has|had|been|were|will|would|which|their|about|when|what|each|some|them|more|also|into|than|other|very|just|like|over|after|then|only|new|now|its|may|such|should|could|these|said|there|being)$' | \
  grep -E '^.{3,}$' | sort -u || true)

[ -z "$TERMS" ] && exit 0

# Grep INDEX.md for matching terms in tags, titles, or item IDs
MATCHES=""
for term in $TERMS; do
  while IFS= read -r line; do
    # Avoid duplicate lines
    if ! echo "$MATCHES" | grep -qF "$line"; then
      MATCHES="${MATCHES}${line}"$'\n'
    fi
  done < <(grep -i "$term" "$INDEX_FILE" 2>/dev/null | grep -E '^\| KC-' | head -3 || true)
done

MATCHES=$(echo "$MATCHES" | sed '/^$/d' | head -5)

[ -z "$MATCHES" ] && exit 0

# Emit matched items as context
cat <<KC_CONTEXT
<!-- KC-PROMPT-MATCH: knowledge-curator relevant items -->
## Related Knowledge
The following knowledge items may be relevant:
$MATCHES
<!-- /KC-PROMPT-MATCH -->
KC_CONTEXT

exit 0
