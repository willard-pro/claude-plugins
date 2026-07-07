#!/usr/bin/env bash
# kc-resurface.sh — SessionStart hook for knowledge-curator.
#
# Injects top-N priority knowledge items as context at session start.
# Fail-open: exits 0 silently when no knowledge/ directory exists.
#
# Reads knowledge/INDEX.md to find top items. Injects a context block
# with the top items. If p1 or overdue items exist, injects instruction
# to open first reply with visible stack summary.
#
# Performance target: <50ms for typical INDEX.md.

set -euo pipefail

KNOWLEDGE_DIR="./knowledge"
INDEX_FILE="$KNOWLEDGE_DIR/INDEX.md"

# Fail-open: no knowledge directory = silent no-op
[ -d "$KNOWLEDGE_DIR" ] || exit 0
[ -f "$INDEX_FILE" ] || exit 0

# Parse summary table by header names (not positional), so adding columns
# to the index format doesn't silently break count extraction.
# Table format: | Total | P1 | In Progress |
extract_summary_col() {
  local col_name="$1"
  awk -v col="$col_name" '
    BEGIN { FS=" *\\| *"; in_summary=0 }
    /^## Summary/ { in_summary=1; next }
    in_summary && /^## / { in_summary=0; exit }
    in_summary && /\| Total \|/ {
      for (i=2; i<=NF; i++) {
        gsub(/^ +| +$/, "", $i)
        if ($i == col) { col_idx=i; next }
      }
    }
    in_summary && col_idx && /^\| [0-9]+/ {
      gsub(/^ +| +$/, "", $(col_idx))
      print $(col_idx)
      exit
    }
  ' "$INDEX_FILE" 2>/dev/null
}

p1_count=$(extract_summary_col "P1")
p1_count="${p1_count:-0}"

in_progress_count=$(extract_summary_col "In Progress")
in_progress_count="${in_progress_count:-0}"

# Get top-N items from the Items table (skip header rows)
# Table format: | ID | Type | Title | Status | Priority | Updated | Tags |
top_items=$(awk '
  BEGIN { in_table=0; count=0 }
  /^## Items/ { in_table=1; next }
  /^## / && in_table { in_table=0 }
  in_table && /^\| KC-/ && count < 5 {
    print
    count++
  }
' "$INDEX_FILE" 2>/dev/null || true)

if [ -z "$top_items" ] && [ "$p1_count" = "0" ]; then
  exit 0
fi

# Emit context block to stdout (harness injects this as context)
cat <<KC_CONTEXT
<!-- KC-RESURFACE: knowledge-curator top items -->
## Knowledge Stack
$( [ "$p1_count" -gt 0 ] && echo "**${p1_count} p1 item(s) need attention.**" )
$( [ "$in_progress_count" -gt 0 ] && echo "${in_progress_count} item(s) in progress." )
$( [ -n "$top_items" ] && echo "$top_items" )
<!-- /KC-RESURFACE -->
KC_CONTEXT

exit 0
