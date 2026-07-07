#!/usr/bin/env bash
# kc-item.sh — Deterministic knowledge item mutation (agent work contract).
#
# Subcommands:
#   claim <id>            Mark item in_progress. Fails non-zero if already claimed.
#   complete <id>         Mark item done (only from in_progress). Fails if not claimed.
#   release <id>          Release an in_progress item back to active. Fails if not in_progress.
#   add <file>            Validate and index a new item file (already written by caller).
#   edit <id> <f> <v>     Update a single frontmatter field (title, priority, tags, relates, project).
#   status <id>           Print current status of an item.
#
# All subcommands: update `updated` timestamp, regenerate INDEX.md.
# Serialized via flock on the knowledge directory. Sole agent mutation path.
#
# Exit codes:
#   0 - success
#   1 - usage / invalid arguments
#   2 - item not found
#   3 - item already claimed (claim conflict) / item not in_progress (complete/release)
#   4 - schema validation failure
#   5 - flock failure

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KNOWLEDGE_DIR="${KNOWLEDGE_DIR:-knowledge}"

# ── Helpers ──────────────────────────────────────────────────────────

die() { echo "ERROR: $*" >&2; exit "${2:-1}"; }

timestamp() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# Validate id format: KC-NNNN (4 digits). Rejects metacharacters, path traversal.
validate_id() {
  local id="$1"
  [[ "$id" =~ ^KC-[0-9]{4}$ ]]
}

# Validate a path is under the given root. Uses realpath to resolve symlinks
# and canonicalize, then checks the prefix matches the root.
validate_path_under() {
  local path="$1"
  local root="$2"
  local resolved
  resolved=$(realpath "$path" 2>/dev/null) || return 1
  local root_resolved
  root_resolved=$(realpath "$root" 2>/dev/null) || return 1
  [[ "$resolved" == "$root_resolved"/* || "$resolved" == "$root_resolved" ]]
}

find_item_file() {
  local id="$1"
  # Reject non-canonical ids — prevents command injection and path traversal
  if ! validate_id "$id"; then
    die "Invalid id format: ${id} (expected KC-NNNN)" 1
  fi
  local f
  f=$(ls "$KNOWLEDGE_DIR/${id}--"*.md 2>/dev/null | head -1)
  [ -n "$f" ] && echo "$f" || echo ""
}

update_timestamp() {
  local file="$1"
  local ts="$2"
  # Replace the updated: line in frontmatter
  sed -i "s/^updated:.*/updated: ${ts}/" "$file"
}

validate_item() {
  local file="$1"
  local errors=0

  for field in id type title status priority project created updated source; do
    if ! grep -q "^${field}:" "$file"; then
      echo "Missing required field: ${field}" >&2
      errors=$((errors + 1))
    fi
  done

  # Validate enums
  local type
  type=$(awk '/^type:/ {print $2}' "$file")
  case "$type" in
    idea|proposal|discovery|lesson|decision|reference|experiment) ;;
    *) echo "Invalid type: ${type}" >&2; errors=$((errors + 1)) ;;
  esac

  local status
  status=$(awk '/^status:/ {print $2}' "$file")
  case "$status" in
    active|in_progress|dormant|done|obsolete) ;;
    *) echo "Invalid status: ${status}" >&2; errors=$((errors + 1)) ;;
  esac

  local priority
  priority=$(awk '/^priority:/ {print $2}' "$file")
  case "$priority" in
    p1|p2|p3) ;;
    *) echo "Invalid priority: ${priority}" >&2; errors=$((errors + 1)) ;;
  esac

  return "$errors"
}

# ── Main ────────────────────────────────────────────────────────────

subcommand="${1:-}"
shift 2>/dev/null || true

case "$subcommand" in
  claim)
    id="${1:-}"
    [ -z "$id" ] && die "Usage: kc-item.sh claim <id>" 1
    ITEM_FILE=$(find_item_file "$id")
    [ -z "$ITEM_FILE" ] && die "Item not found: $id" 2

    # Guard: only claim active or dormant items (not done, obsolete, or already claimed)
    CURRENT_STATUS=$(awk '/^status:/ {print $2}' "$ITEM_FILE")
    case "$CURRENT_STATUS" in
      active|dormant) ;;
      in_progress) die "Item already claimed: $id (status: in_progress)" 3 ;;
      done|obsolete) die "Cannot claim completed/obsolete item: $id (status: ${CURRENT_STATUS})" 3 ;;
      *) die "Cannot claim item with unknown status: $id (status: ${CURRENT_STATUS})" 3 ;;
    esac

    # Atomic update with flock
    (
      flock -x 9 || die "Failed to acquire lock" 5
      sed -i "s/^status:.*/status: in_progress/" "$ITEM_FILE"
      update_timestamp "$ITEM_FILE" "$(timestamp)"
    ) 9>"$KNOWLEDGE_DIR/.lock"

    # Regenerate index
    "$SCRIPT_DIR/kc-index.sh" "$KNOWLEDGE_DIR"
    echo "Claimed: $id → in_progress"
    ;;

  complete)
    id="${1:-}"
    [ -z "$id" ] && die "Usage: kc-item.sh complete <id>" 1
    ITEM_FILE=$(find_item_file "$id")
    [ -z "$ITEM_FILE" ] && die "Item not found: $id" 2

    # Guard: must be in_progress to complete
    CURRENT_STATUS=$(awk '/^status:/ {print $2}' "$ITEM_FILE")
    if [ "$CURRENT_STATUS" != "in_progress" ]; then
      die "Item not in_progress: $id (status: ${CURRENT_STATUS}). Claim it first." 3
    fi

    (
      flock -x 9 || die "Failed to acquire lock" 5
      sed -i "s/^status:.*/status: done/" "$ITEM_FILE"
      update_timestamp "$ITEM_FILE" "$(timestamp)"
    ) 9>"$KNOWLEDGE_DIR/.lock"

    "$SCRIPT_DIR/kc-index.sh" "$KNOWLEDGE_DIR"
    echo "Completed: $id → done"
    ;;

  release)
    id="${1:-}"
    [ -z "$id" ] && die "Usage: kc-item.sh release <id>" 1
    ITEM_FILE=$(find_item_file "$id")
    [ -z "$ITEM_FILE" ] && die "Item not found: $id" 2

    # Guard: must be in_progress to release
    CURRENT_STATUS=$(awk '/^status:/ {print $2}' "$ITEM_FILE")
    if [ "$CURRENT_STATUS" != "in_progress" ]; then
      die "Item not in_progress: $id (status: ${CURRENT_STATUS}). Nothing to release." 3
    fi

    (
      flock -x 9 || die "Failed to acquire lock" 5
      sed -i "s/^status:.*/status: active/" "$ITEM_FILE"
      update_timestamp "$ITEM_FILE" "$(timestamp)"
    ) 9>"$KNOWLEDGE_DIR/.lock"

    "$SCRIPT_DIR/kc-index.sh" "$KNOWLEDGE_DIR"
    echo "Released: $id → active"
    ;;

  add)
    item_file="${1:-}"
    [ -z "$item_file" ] && die "Usage: kc-item.sh add <file>" 1
    [ ! -f "$item_file" ] && die "File not found: $item_file" 2

    # Path traversal guard: only accept files under CWD or /tmp
    if ! validate_path_under "$item_file" "$PWD" && ! validate_path_under "$item_file" "/tmp"; then
      die "Refusing to add file outside CWD or /tmp: ${item_file}" 1
    fi

    # Validate schema
    if ! validate_item "$item_file"; then
      die "Schema validation failed for: $item_file" 4
    fi

    # Ensure knowledge directory exists
    mkdir -p "$KNOWLEDGE_DIR"

    # Extract id from frontmatter for the target filename
    id=$(awk '/^id:/ {print $2}' "$item_file" | tr -d '"'"'")
    title=$(awk '/^title:/ {sub(/^title: *"?/,""); sub(/"$/,""); print}' "$item_file" | head -1)
    slug=$(echo "$title" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g; s/--*/-/g; s/^-//; s/-$//' | head -c 60)
    target="$KNOWLEDGE_DIR/${id}--${slug}.md"

    # Never overwrite existing. Check both exact filename AND id collision
    # (two items with same id but different slugs would conflict in find_item_file).
    if [ -f "$target" ]; then
      die "Item already exists at $target — use a new id or update the existing item" 4
    fi
    if ls "$KNOWLEDGE_DIR/${id}--"*.md >/dev/null 2>&1; then
      die "Item with id ${id} already exists — use a different id" 4
    fi

    (
      flock -x 9 || die "Failed to acquire lock" 5
      cp "$item_file" "$target"
    ) 9>"$KNOWLEDGE_DIR/.lock"

    "$SCRIPT_DIR/kc-index.sh" "$KNOWLEDGE_DIR"
    echo "Added: $id → $target"
    ;;

  status)
    id="${1:-}"
    [ -z "$id" ] && die "Usage: kc-item.sh status <id>" 1
    ITEM_FILE=$(find_item_file "$id")
    [ -z "$ITEM_FILE" ] && die "Item not found: $id" 2

    awk '/^status:/ {print $2}' "$ITEM_FILE"
    ;;

  edit)
    id="${1:-}"
    field="${2:-}"
    value="${3:-}"
    [ -z "$id" ] && die "Usage: kc-item.sh edit <id> <field> <value>" 1
    [ -z "$field" ] && die "Usage: kc-item.sh edit <id> <field> <value>" 1
    [ -z "$value" ] && die "Usage: kc-item.sh edit <id> <field> <value>" 1
    ITEM_FILE=$(find_item_file "$id")
    [ -z "$ITEM_FILE" ] && die "Item not found: $id" 2

    # Whitelist editable fields — prevents injection and protects structural fields
    case "$field" in
      title|priority|tags|relates|project)
        ;;
      status)
        die "Cannot edit status via edit. Use: claim | release | complete" 1
        ;;
      id|type|created|updated|source)
        die "Field '${field}' is structural and cannot be edited" 1
        ;;
      *)
        die "Unknown or non-editable field: ${field}" 1
        ;;
    esac

    # Validate enum values for restricted fields
    case "$field" in
      priority)
        case "$value" in
          p1|p2|p3) ;;
          *) die "Invalid priority: ${value}. Must be p1, p2, or p3." 4 ;;
        esac
        ;;
    esac

    (
      flock -x 9 || die "Failed to acquire lock" 5
      # Escape sed-special characters in value (/ \ &) for safe substitution.
      # Uses | as delimiter to avoid collisions with / in paths/titles.
      escaped_value=$(echo "$value" | sed 's/[\\/&]/\\&/g')
      sed -i "s|^${field}:.*|${field}: ${escaped_value}|" "$ITEM_FILE"
      update_timestamp "$ITEM_FILE" "$(timestamp)"
    ) 9>"$KNOWLEDGE_DIR/.lock"

    "$SCRIPT_DIR/kc-index.sh" "$KNOWLEDGE_DIR"
    echo "Edited: $id ${field} → ${value}"
    ;;

  *)
    die "Unknown subcommand: ${subcommand:-<empty>}. Use: claim | complete | release | add | edit | status" 1
    ;;
esac
