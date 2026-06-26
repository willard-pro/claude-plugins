#!/usr/bin/env bash
# persona-refresh.sh — deterministic persona file mutations.
# Mechanical operations for the ticket-persona-refresh skill. The skill does the
# research + diff generation; this script does the file writes. Follows the
# flow.sh philosophy: deterministic mutations with idempotency guards.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PERSONAS_DIR="${CLAUDE_PLUGIN_ROOT:-$SCRIPT_DIR/..}/personas"
CHANGELOG="$PERSONAS_DIR/CHANGELOG.md"

# ── Usage ──────────────────────────────────────────────────────────────────────

usage() {
  cat >&2 <<'EOF'
Usage: persona-refresh.sh <command> [args]

Commands:
  persona-refresh.sh bump <file>
    Bump version integer + update last-reviewed to today in a persona file.

  persona-refresh.sh changelog <section> <entry>
    Append a dated entry to personas/CHANGELOG.md under the given section.
    Section: Changed | Added | Removed
    Entry: free-text description (quoted).

  persona-refresh.sh apply <file>
    Replace a persona file with new content from stdin.
    Writes to a temp file first, then mv (atomic replace).

Examples:
  persona-refresh.sh bump personas/specializers/backend/python.md
  persona-refresh.sh changelog Changed "python.md (v1→v2): Added pytest 8.x guidance"
  cat updated.md | persona-refresh.sh apply personas/base/analyzer.md
EOF
  exit 1
}

# ── Validation ─────────────────────────────────────────────────────────────────

die() { echo "ERROR: $*" >&2; exit 1; }

require_persona_file() {
  local f="$1"
  [ -f "$f" ] || die "not a file: $f"
  # Must be inside personas/ directory
  [[ "$(realpath "$f")" == "$(realpath "$PERSONAS_DIR")"/* ]] || die "not in personas dir: $f"
}

# ── bump ──────────────────────────────────────────────────────────────────────

cmd_bump() {
  local file="$1"
  require_persona_file "$file"

  local today
  today=$(date -u +%Y-%m-%d)

  # Read current version
  local current
  current=$(sed -n '/^version:/s/^version: *//p' "$file")
  if [ -z "$current" ]; then
    die "no version field found in $file"
  fi

  local new=$((current + 1))

  # Update version
  sed -i "s/^version: $current$/version: $new/" "$file"

  # Update last-reviewed
  sed -i "s/^last-reviewed: .*/last-reviewed: $today/" "$file"

  echo "Bumped $file: v$current → v$new (reviewed $today)"
}

# ── changelog ──────────────────────────────────────────────────────────────────

cmd_changelog() {
  local section="$1"
  local entry="$2"

  case "$section" in
    Changed|Added|Removed) ;;
    *) die "invalid section '$section'. Must be Changed, Added, or Removed." ;;
  esac

  [ -f "$CHANGELOG" ] || die "CHANGELOG.md not found at $CHANGELOG"

  local today
  today=$(date -u +%Y-%m-%d)

  local tmp
  tmp=$(mktemp)

  # Strategy: stream through the changelog, inserting the entry at the right
  # spot. Avoids fragile sed -i with multiline insertions.
  local inserted=0

  if grep -q "^## $today" "$CHANGELOG"; then
    # Today's date section exists. Find the ### <section> under it.
    local in_date=0 in_target_section=0

    while IFS= read -r line; do
      # Track when we enter/leave today's date section
      if [[ "$line" =~ ^##\ $today ]]; then
        in_date=1
        in_target_section=0
        echo "$line" >> "$tmp"
        continue
      fi

      # Leaving today's section (next ## header)
      if [ "$in_date" -eq 1 ] && [[ "$line" =~ ^##\  ]]; then
        # If we never found the target section, add it now before this next date
        if [ "$inserted" -eq 0 ]; then
          echo "" >> "$tmp"
          echo "### $section" >> "$tmp"
          echo "- $entry" >> "$tmp"
          echo "" >> "$tmp"
          inserted=1
        fi
        in_date=0
      fi

      # Check for target section header within today's date
      if [ "$in_date" -eq 1 ] && [ "$line" = "### $section" ]; then
        in_target_section=1
        echo "$line" >> "$tmp"
        echo "- $entry" >> "$tmp"
        inserted=1
        continue
      fi

      # Track when we leave target section (next ### or blank+next ###)
      if [ "$in_target_section" -eq 1 ] && [[ "$line" =~ ^###\  ]]; then
        in_target_section=0
        # Don't skip — this is the next section header, keep it
      fi

      echo "$line" >> "$tmp"
    done < "$CHANGELOG"

    # If we reached EOF still in today's section without finding target,
    # append at end of file
    if [ "$inserted" -eq 0 ] && [ "$in_date" -eq 1 ]; then
      echo "" >> "$tmp"
      echo "### $section" >> "$tmp"
      echo "- $entry" >> "$tmp"
      inserted=1
    fi
  else
    # No date section for today — insert after the title line (line 1)
    local line_num=0
    while IFS= read -r line; do
      line_num=$((line_num + 1))
      if [ "$line_num" -eq 1 ]; then
        echo "$line" >> "$tmp"
        echo "" >> "$tmp"
        echo "## $today" >> "$tmp"
        echo "" >> "$tmp"
        echo "### $section" >> "$tmp"
        echo "- $entry" >> "$tmp"
        inserted=1
      else
        echo "$line" >> "$tmp"
      fi
    done < "$CHANGELOG"
  fi

  mv "$tmp" "$CHANGELOG"
  echo "Appended to CHANGELOG: [$section] $entry"
}

# ── apply ──────────────────────────────────────────────────────────────────────

cmd_apply() {
  local file="$1"
  require_persona_file "$file"

  # Read new content from stdin
  local tmp
  tmp=$(mktemp)
  cat > "$tmp"

  # Validate: new content must be non-empty
  [ -s "$tmp" ] || die "refusing to write empty content to $file"

  # Validate: new content must have valid YAML frontmatter delimiters
  grep -q '^---$' "$tmp" || die "new content missing opening frontmatter (---)"

  # Atomic replace
  mv "$tmp" "$file"
  echo "Applied new content to $file"
}

# ── Main ───────────────────────────────────────────────────────────────────────

[ $# -ge 1 ] || usage

CMD="${1:-}"
shift || true

case "$CMD" in
  bump)
    [ $# -ge 1 ] || die "bump requires <file>"
    cmd_bump "$1"
    ;;
  changelog)
    [ $# -ge 2 ] || die "changelog requires <section> <entry>"
    cmd_changelog "$1" "$2"
    ;;
  apply)
    [ $# -ge 1 ] || die "apply requires <file>"
    cmd_apply "$1"
    ;;
  --help|-h)
    usage
    ;;
  *)
    die "unknown command: $CMD"
    ;;
esac
