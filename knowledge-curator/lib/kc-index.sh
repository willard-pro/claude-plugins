#!/usr/bin/env bash
# kc-index.sh — Rebuild knowledge/INDEX.md from item frontmatter.
#
# Usage: kc-index.sh [knowledge_dir]
#   knowledge_dir defaults to ./knowledge
#
# Scans knowledge/KC-NNNN--*.md files, extracts YAML frontmatter fields,
# and writes a ranked INDEX.md. Items sorted: p1 first, then by
# updated timestamp descending. done/obsolete items excluded.
#
# Exit codes:
#   0 - index rebuilt successfully
#   1 - knowledge directory not found (silent — fail-open)

set -euo pipefail

KNOWLEDGE_DIR="${1:-knowledge}"

# Fail-open: no knowledge directory is not an error
if [ ! -d "$KNOWLEDGE_DIR" ]; then
  exit 0
fi

INDEX_FILE="$KNOWLEDGE_DIR/INDEX.md"
TAB="	"

# ── Extract frontmatter field ────────────────────────────────────────

extract_field() {
  local file="$1"
  local field="$2"
  awk -v field="${field}" '
    BEGIN { in_fm=0; in_list=0; in_dash_list=0 }
    /^---$/ { if (in_fm==0) { in_fm=1; next } else { exit } }
    in_fm==1 && $1 == field":" {
      sub(/^[^:]+:[[:space:]]*/, "")
      if ($0 != "") {
        # Value on same line
        print
        if ($0 ~ /^\[/ && $0 !~ /\]/) { in_list=1 }
        if ($0 !~ /^\[/ || $0 ~ /\]/) { exit }
      } else {
        # Value on subsequent lines (YAML dash-list or indented block)
        in_dash_list=1
      }
      next
    }
    in_list==1 {
      sub(/^[[:space:]]*/, "")
      print
      if ($0 ~ /\]/) { exit }
      next
    }
    in_dash_list==1 {
      # Capture indented continuation lines or dash-list items
      if ($0 ~ /^[[:space:]]/ || $0 ~ /^[[:space:]]*-/) {
        sub(/^[[:space:]]*/, "")
        print
        next
      }
      # Non-indented, non-empty line ends the list
      if ($0 !~ /^[[:space:]]/ && $0 != "") { exit }
    }
  ' "$file" 2>/dev/null || true
}

# Strip surrounding quotes from a value
strip_quotes() {
  sed 's/^"//;s/"$//;s/^'"'"'//;s/'"'"'$//'
}

# ── Collect items ────────────────────────────────────────────────────

ITEMS_TMP=$(mktemp)
trap 'rm -f "$ITEMS_TMP"' EXIT

item_count=0
p1_count=0
in_progress_count=0

for item_file in "$KNOWLEDGE_DIR"/KC-[0-9][0-9][0-9][0-9]--*.md; do
  [ -f "$item_file" ] || continue
  item_count=$((item_count + 1))

  id=$(extract_field "$item_file" "id" | strip_quotes)
  type=$(extract_field "$item_file" "type" | strip_quotes)
  title=$(extract_field "$item_file" "title" | strip_quotes)
  status=$(extract_field "$item_file" "status" | strip_quotes)
  priority=$(extract_field "$item_file" "priority" | strip_quotes)
  created=$(extract_field "$item_file" "created" | strip_quotes)
  updated=$(extract_field "$item_file" "updated" | strip_quotes)
  source=$(extract_field "$item_file" "source" | strip_quotes)
  tags=$(extract_field "$item_file" "tags" | sed 's/[][]//g; s/,/ /g')
  relates=$(extract_field "$item_file" "relates" | tr '\n' ' ' | sed 's/  */ /g; s/^ *//; s/ *$//')

  # Validate required fields are non-empty — skip and warn if corrupt
  if [ -z "$id" ] || [ -z "$type" ] || [ -z "$title" ] || [ -z "$status" ] || [ -z "$priority" ]; then
    echo "WARNING: Skipping item with missing required fields in: $(basename "$item_file")" >&2
    continue
  fi

  # Skip done/obsolete in stack views
  if [ "$status" = "done" ] || [ "$status" = "obsolete" ]; then
    continue
  fi

  [ "$priority" = "p1" ] && p1_count=$((p1_count + 1))
  [ "$status" = "in_progress" ] && in_progress_count=$((in_progress_count + 1))

  sort_key=9
  case "$priority" in
    p1) sort_key=1 ;;
    p2) sort_key=2 ;;
    p3) sort_key=3 ;;
  esac

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$sort_key" "$updated" "$id" "$type" "$title" "$status" "$priority" "$created" "$source" "$tags" "$relates" >> "$ITEMS_TMP"
done

# ── Warn about orphaned .md files that don't match the KC-NNNN pattern ──
for f in "$KNOWLEDGE_DIR"/*.md; do
  [ -f "$f" ] || continue
  basename=$(basename "$f")
  case "$basename" in
    INDEX.md) continue ;;
    KC-[0-9][0-9][0-9][0-9]--*) continue ;;
    *) echo "WARNING: Orphaned file in knowledge/ (won't appear in index): ${basename}" >&2 ;;
  esac
done

# ── Detect vanished items (present in previous build, missing now) ──
REGISTRY_FILE="$KNOWLEDGE_DIR/.kc-item-registry"
if [ -f "$REGISTRY_FILE" ]; then
  while IFS= read -r prev_id; do
    [ -z "$prev_id" ] && continue
    if ! grep -qxF "$prev_id" "$ITEMS_TMP" 2>/dev/null && \
       ! grep -qxF "$prev_id" <(for f in "$KNOWLEDGE_DIR"/KC-[0-9][0-9][0-9][0-9]--*.md; do [ -f "$f" ] && basename "$f" | grep -oE 'KC-[0-9]{4}'; done) 2>/dev/null; then
      echo "WARNING: Previously tracked item vanished: ${prev_id} (file deleted or renamed)" >&2
    fi
  done < "$REGISTRY_FILE"
fi
# Write current item IDs to registry for next-run comparison
for item_file in "$KNOWLEDGE_DIR"/KC-[0-9][0-9][0-9][0-9]--*.md; do
  [ -f "$item_file" ] || continue
  basename "$item_file" | grep -oE 'KC-[0-9]{4}'
done > "$REGISTRY_FILE"

# ── Write INDEX.md ───────────────────────────────────────────────────

now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
{
  echo "# Knowledge Index"
  echo ""
  echo "> Auto-generated by kc-index.sh. Do not edit manually."
  echo "> Generated: ${now}"
  echo ""
  echo "## Summary"
  echo ""
  echo "| Total | P1 | In Progress |"
  echo "|-------|----|-------------|"
  echo "| $item_count | $p1_count | $in_progress_count |"
  echo ""

  if [ "$item_count" -gt 0 ]; then
    echo "## Items"
    echo ""
    echo "| ID | Type | Title | Status | Priority | Updated | Tags | Relates |"
    echo "|----|------|-------|--------|----------|---------|------|---------|"

    sort -t"${TAB}" -k1,1n -k2,2r "$ITEMS_TMP" | while IFS="${TAB}" read -r sort_key updated id type title status priority created source tags relates; do
      relate_short=$(echo "$relates" | grep -oE 'KC-[0-9]{4}' | tr '\n' ' ' | sed 's/ *$//' || true)
      printf '| %s | %s | %s | %s | %s | %s | %s | %s |\n' \
        "$id" "$type" "$title" "$status" "$priority" "$updated" "$tags" "$relate_short"
    done
    echo ""
  else
    echo "_No active items._"
    echo ""
  fi

  echo "## Legend"
  echo ""
  echo "- **Status**: active | in_progress | dormant | done | obsolete"
  echo "- **Priority**: p1 (critical) | p2 (important) | p3 (nice-to-have)"
  echo "- **Types**: idea | proposal | discovery | lesson | decision | reference | experiment"
  echo ""
} > "$INDEX_FILE"

exit 0
