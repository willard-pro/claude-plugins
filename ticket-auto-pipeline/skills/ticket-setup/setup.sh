#!/usr/bin/env bash
# ticket-setup: deterministic workspace scaffolder for Linear tickets.
# -u (nounset) intentionally omitted: Claude Code shell snapshots inject
# ZSH_VERSION references that trigger false-positive "unbound variable"
# errors in this bash version when nounset is active.
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${CLAUDE_SKILLS_LIB:-$HOME/.claude/skills/lib}"
source "$LIB_DIR/linear-api.sh"

usage() {
  echo "Usage: $0 <TICKET-ID>" >&2
  exit 1
}

TICKET_ID="${1:-}"
[ -z "$TICKET_ID" ] && usage

# ── Guard: verify working directory ─────────────────────────────────────

CWD_NAME=$(basename "$PWD")
if [ "$CWD_NAME" != "tickets" ]; then
  echo "Must be run from tickets workspace" >&2
  exit 5
fi

# ── Fetch ticket from Linear ────────────────────────────────────────────

ISSUE_JSON=$(get_issue "$TICKET_ID")
COMMENTS_JSON=$(get_comments "$TICKET_ID")

# Extract fields
TITLE=$(echo "$ISSUE_JSON" | jq -r '.title // "Untitled"')
DESCRIPTION=$(echo "$ISSUE_JSON" | jq -r '.description // "None"')
STATE_NAME=$(echo "$ISSUE_JSON" | jq -r '.state.name // "Unknown"')
PRIORITY=$(echo "$ISSUE_JSON" | jq -r '.priority // "None"')
LABEL_NAMES=$(echo "$ISSUE_JSON" | jq -r '[.labels.nodes[].name] | join(", ")')
URL=$(echo "$ISSUE_JSON" | jq -r '.url // ""')
PROJECT_NAME=$(echo "$ISSUE_JSON" | jq -r '.project.name // "Unknown"')
PARENT_ID=$(echo "$ISSUE_JSON" | jq -r '.parent.id // empty')
PARENT_TITLE=$(echo "$ISSUE_JSON" | jq -r '.parent.title // empty')
PARENT_IDENTIFIER=$(echo "$ISSUE_JSON" | jq -r '.parent.identifier // empty')
ASSIGNEE_NAME=$(echo "$ISSUE_JSON" | jq -r '.assignee.name // "Unassigned"')
CREATOR_NAME=$(echo "$ISSUE_JSON" | jq -r '.creator.name // "Unknown"')
CREATED_AT=$(echo "$ISSUE_JSON" | jq -r '.createdAt // "Unknown"')
DUE_DATE=$(echo "$ISSUE_JSON" | jq -r '.dueDate // "—"')

# ── Resolve epic context ────────────────────────────────────────────────

EPIC_TITLE="None"
EPIC_ID="None"
if [ -n "$PARENT_ID" ]; then
  PARENT_JSON=$(get_issue "$PARENT_ID" 2>/dev/null || echo 'null')
  EPIC_TITLE=$(echo "$PARENT_JSON" | jq -r '.title // "None"')
  EPIC_ID="$PARENT_IDENTIFIER"
fi

# ── Derive directory path ───────────────────────────────────────────────

slugify() {
  echo "$1" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | sed 's/--*/-/g' | sed 's/^-//;s/-$//' | cut -c1-60
}

TITLE_SLUG=$(slugify "$TITLE")
DIR_NAME="${TICKET_ID}--${TITLE_SLUG}"

# ── Check existing / create ─────────────────────────────────────────────

source "$(dirname "${BASH_SOURCE[0]}")/../lib/ticket-dir.sh"
EXISTING_DIR=$(resolve_ticket_dir "$TICKET_ID" "." 2>/dev/null || true)

if [ -n "$EXISTING_DIR" ]; then
  # Already exists — report and stop
  REL_PATH="${EXISTING_DIR#./}"
  jq -n \
    --arg dir "$(realpath "$EXISTING_DIR")" \
    --arg relative "$REL_PATH" \
    --arg title "$TITLE" \
    --arg url "$URL" \
    --arg status "$STATE_NAME" \
    --arg project "$PROJECT_NAME" \
    --arg epic "${EPIC_TITLE}${EPIC_ID:+ ($EPIC_ID)}" \
    '{
      ticket_dir: $dir,
      relative_path: $relative,
      url: $url,
      title: $title,
      status: $status,
      project: $project,
      epic: $epic,
      existing: true
    }'
  exit 0
fi

# Create directory structure
TICKET_DIR="$PWD/$DIR_NAME"
mkdir -p "$TICKET_DIR/artifacts" "$TICKET_DIR/attachments"
touch "$TICKET_DIR/artifacts/.gitkeep" "$TICKET_DIR/attachments/.gitkeep"

# ── Write context.md ────────────────────────────────────────────────────

cat >"$TICKET_DIR/context.md" <<MDEOF
# ${TICKET_ID}: ${TITLE}

**Linear:** ${URL}
**Project:** ${PROJECT_NAME}
**Epic:** ${EPIC_TITLE}${EPIC_ID:+ (${EPIC_ID})}
**Status:** ${STATE_NAME}
**Priority:** ${PRIORITY}
**Labels:** ${LABEL_NAMES}
**Created by:** ${CREATOR_NAME}
**Created at:** ${CREATED_AT}
**Due:** ${DUE_DATE}
**Assignee:** ${ASSIGNEE_NAME}

---

## Description

${DESCRIPTION}

---

## Links & Attachments

$(echo "$ISSUE_JSON" | jq -r '
  (.attachments.nodes // []) as $atts |
  if ($atts | length) == 0 then "None"
  else $atts[] | "- [\(.title // .url)](\(.url))"
  end
')

---

## Comments

$(echo "$COMMENTS_JSON" | jq -r '
  if . == null or (. | length) == 0 then "None"
  else .[] |
    "**\(.user.name // "Unknown")** (\(.createdAt)):\n\(.body // "_empty_")\n"
  end
')
MDEOF

# ── Write notes.md ──────────────────────────────────────────────────────

TODAY=$(date +%Y-%m-%d)
cat >"$TICKET_DIR/notes.md" <<MDEOF
# Working Notes — ${TICKET_ID}

## Status
**Created:** ${TODAY}
**Current status:** ${STATE_NAME}

## Complexity

**Score:**

## Investigation Notes

### ${TODAY}
- Workspace created.

## Session Log

### ${TODAY}
- Workspace created.
MDEOF

# ── Output summary ──────────────────────────────────────────────────────

jq -n \
  --arg dir "$TICKET_DIR" \
  --arg url "$URL" \
  --arg title "$TITLE" \
  --arg status "$STATE_NAME" \
  --arg project "$PROJECT_NAME" \
  --arg epic "${EPIC_TITLE}${EPIC_ID:+ ($EPIC_ID)}" \
  '{
    ticket_dir: $dir,
    url: $url,
    title: $title,
    status: $status,
    project: $project,
    epic: $epic,
    existing: false
  }'
