#!/usr/bin/env bash
# ticket-audit-exec.sh — Deterministic operations for ticket-audit-exec skill.
# Sourced from SKILL.md; each function is a self-contained operation.
# Reads recommendation checklist files, parses phase/items, manages file state.
#
# Usage (sourced):
#   source lib/ticket-audit-exec.sh
#   resolve_file ""           # => prints TARGET_FILE=...
#   parse_checklist "$file"   # => prints JSON with phase, items, counts

set -eo pipefail

# ── File resolution ──────────────────────────────────────────────────────────────

# resolve_file [specified_path]
# If specified_path is non-empty: verify it exists, print TARGET_FILE=<path>.
# If empty: select most-recent .md from $AUDIT_DIR/recommendations/.
# Exits 1 if no file found.
resolve_file() {
  local specified="$1"

  # Source config for AUDIT_DIR
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  source "$SCRIPT_DIR/config.sh"

  if [ -n "$specified" ]; then
    if [ ! -f "$specified" ]; then
      echo "resolve_file error: file not found: $specified" >&2
      return 1
    fi
    echo "TARGET_FILE=$specified"
    return 0
  fi

  local rec_dir="${AUDIT_DIR}/recommendations"

  if [ ! -d "$rec_dir" ]; then
    echo "resolve_file error: directory not found: $rec_dir" >&2
    return 1
  fi

  # Sort by mtime descending, alpha descending tie-break
  local target
  target=$(ls -1t "$rec_dir"/*.md 2>/dev/null | while read -r f; do
    mtime=$(stat -c %Y "$f" 2>/dev/null || echo 0)
    printf '%s %s\n' "$mtime" "$f"
  done | sort -k1,1nr -k2,2r | head -1 | awk '{print $2}')

  if [ -z "$target" ] || [ ! -f "$target" ]; then
    echo "resolve_file error: no .md files found in $rec_dir" >&2
    return 1
  fi

  echo "TARGET_FILE=$target"
}

# ── Checklist parsing ───────────────────────────────────────────────────────────

# parse_checklist <file>
# Outputs JSON with: phase, source_id, needs_info_items (array),
# structural_items (array), pending_needs_info (count), pending_structural (count).
parse_checklist() {
  local file="$1"

  if [ ! -f "$file" ]; then
    echo '{"error":"file not found"}' >&2
    return 1
  fi

  # Extract Phase header
  local phase
  phase=$(grep -m1 '^Phase:' "$file" 2>/dev/null | sed 's/^Phase: *//' | tr -d '\r')
  case "$phase" in
  "needs-info") phase="needs-info" ;;
  "needs-info-done") phase="needs-info-done" ;;
  "structural-done") phase="structural-done" ;;
  *)
    if [ -n "$phase" ]; then
      echo "parse_checklist warning: unrecognized Phase '$phase', treating as needs-info" >&2
    fi
    phase="needs-info"
    ;;
  esac

  # Extract Source header
  local source_id
  source_id=$(grep -m1 '^Source:' "$file" 2>/dev/null | sed 's/^Source: *//' | tr -d '\r')
  if [ -z "$source_id" ]; then
    source_id="ticket-audit-exec:$(basename "$file" .md)"
  fi

  # Parse items by section
  local needs_info_json="[]"
  local structural_json="[]"
  local in_section="none"
  local needs_info_count=0
  local structural_count=0
  local ni_pending=0
  local st_pending=0

  while IFS= read -r line; do
    # Section detection
    if [[ "$line" =~ ^##\ Needs\ Info ]]; then
      in_section="needs-info"
      continue
    elif [[ "$line" =~ ^##\ Structural ]] || [[ "$line" =~ ^##\ Drift ]]; then
      in_section="structural"
      continue
    elif [[ "$line" =~ ^##\ (Goal\ Context|Ticket\ Inventory|Audit\ Summary) ]]; then
      in_section="none"
      continue
    fi

    # Item detection within sections
    local re_checkbox='^- \[.\] '
    if [ "$in_section" != "none" ] && [[ "$line" =~ $re_checkbox ]]; then
      # Extract ticket IDs (first and all) and detail
      local tid state detail
      tid=$(echo "$line" | sed -n 's/^- \[.\] *\([A-Z][A-Z]*-[0-9][0-9]*\).*/\1/p')
      # Extract all ticket IDs from the line (for merge/duplicate findings)
      all_tids=$(echo "$line" | grep -oE '[A-Z]+-[0-9]+' | tr '\n' ' ' | xargs)
      detail=$(echo "$line" | sed -n 's/^[^—]*— *//p')
      # Strip finding type prefix from detail to avoid redundancy (e.g., "needs-info: rest" → "rest")
      detail_clean=$(echo "$detail" | sed 's/^[^:]*: *//')

      # Classify state (use variables for regex to avoid bash >/< issues)
      local re_complete='^- \[x\] '
      local re_failed='^- \[!\] '
      local re_resumed='^- \[>\] '
      if [[ "$line" =~ $re_complete ]]; then
        state="complete"
      elif [[ "$line" =~ $re_failed ]]; then
        state="failed"
      elif [[ "$line" =~ $re_resumed ]]; then
        state="resumed"
      else
        state="pending"
      fi

      # Build JSON entry
      local entry
      entry=$(jq -n \
        --arg tid "$tid" \
        --arg all_tids "$all_tids" \
        --arg state "$state" \
        --arg detail "$detail" \
        --arg detail_clean "$detail_clean" \
        --arg raw "$line" \
        '{ticket_id: $tid, all_ticket_ids: $all_tids, state: $state, detail: $detail, detail_clean: $detail_clean, raw: $raw}')

      if [ "$in_section" = "needs-info" ]; then
        needs_info_json=$(echo "$needs_info_json" | jq --argjson e "$entry" '. + [$e]')
        needs_info_count=$((needs_info_count + 1))
        if [ "$state" = "pending" ] || [ "$state" = "resumed" ]; then
          ni_pending=$((ni_pending + 1))
        fi
      elif [ "$in_section" = "structural" ]; then
        structural_json=$(echo "$structural_json" | jq --argjson e "$entry" '. + [$e]')
        structural_count=$((structural_count + 1))
        if [ "$state" = "pending" ] || [ "$state" = "resumed" ]; then
          st_pending=$((st_pending + 1))
        fi
      fi
    fi
  done <"$file"

  # Output as JSON
  jq -n \
    --arg phase "$phase" \
    --arg source_id "$source_id" \
    --argjson needs_info_items "$needs_info_json" \
    --argjson structural_items "$structural_json" \
    --argjson pending_needs_info "$ni_pending" \
    --argjson pending_structural "$st_pending" \
    --argjson total_needs_info "$needs_info_count" \
    --argjson total_structural "$structural_count" \
    '{
      phase: $phase,
      source_id: $source_id,
      needs_info_items: $needs_info_items,
      structural_items: $structural_items,
      pending_needs_info: $pending_needs_info,
      pending_structural: $pending_structural,
      total_needs_info: $total_needs_info,
      total_structural: $total_structural
    }'
}

# ── File mutations ──────────────────────────────────────────────────────────────

# write_ahead_mark <file> <ticket_id>
# Marks item as in-progress: "- [ ] TICKET" or "- [>] TICKET" → "- [>] TICKET"
# Idempotent — no-op if already [>] or [x] or [!].
write_ahead_mark() {
  local file="$1"
  local tid="$2"

  if [ ! -f "$file" ]; then
    echo "write_ahead_mark: file not found: $file" >&2
    return 1
  fi

  # Only change [ ] → [>]; leave [x], [!], [>] alone
  sed -i "s/^- \[ \] \($tid \)/- [>] \1/" "$file"
  echo "write_ahead_mark: $tid marked [>]"
}

# mark_item_done <file> <ticket_id>
# Marks an in-progress or pending item as complete.
mark_item_done() {
  local file="$1"
  local tid="$2"

  sed -i "s/^- \[.\] \($tid \)/- [x] \1/" "$file"
  echo "mark_item_done: $tid marked [x]"
}

# mark_item_failed <file> <ticket_id>
# Marks an in-progress or pending item as failed.
mark_item_failed() {
  local file="$1"
  local tid="$2"

  sed -i "s/^- \[.\] \($tid \)/- [x] \1/" "$file"
  # Actually, spec says mark [!] not [x]
  sed -i "s/^- \[x\] \($tid \)/- [!] \1/" "$file"
  echo "mark_item_failed: $tid marked [!]"
}

# advance_phase <file> <new_phase>
# Updates the Phase header. Valid values: needs-info, needs-info-done, structural-done.
advance_phase() {
  local file="$1"
  local new_phase="$2"

  case "$new_phase" in
  "needs-info" | "needs-info-done" | "structural-done") ;;
  *)
    echo "advance_phase: invalid phase '$new_phase'" >&2
    return 1
    ;;
  esac

  # Replace Phase: line (only first occurrence)
  sed -i "0,/^Phase:.*/s/^Phase:.*/Phase: $new_phase/" "$file"
  echo "advance_phase: set to $new_phase"
}

# archive_checklist <file>
# Moves file to $AUDIT_DIR/archive/, creating directory if needed.
# Prints ARCHIVE_PATH=<path>.
archive_checklist() {
  local file="$1"

  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  source "$SCRIPT_DIR/config.sh"

  local archive_dir="${AUDIT_DIR}/archive"
  mkdir -p "$archive_dir"

  local archive_name
  archive_name=$(basename "$file")
  mv "$file" "${archive_dir}/${archive_name}"
  echo "ARCHIVE_PATH=${archive_dir}/${archive_name}"
}

# ── Query helpers ────────────────────────────────────────────────────────────────

# has_pending_items <file>
# Exit 0 if any [ ] or [>] items remain, exit 1 otherwise.
has_pending_items() {
  local file="$1"
  if grep -q '^- \[[ >]\]' "$file" 2>/dev/null; then
    return 0
  else
    return 1
  fi
}

# get_item_state <file> <ticket_id>
# Prints the current state character: ' ' (pending), '>' (resumed), 'x' (complete), '!' (failed).
get_item_state() {
  local file="$1"
  local tid="$2"
  local line
  line=$(grep -m1 "^\- \[.\] $tid " "$file" 2>/dev/null || echo "")
  if [ -z "$line" ]; then
    echo "?"
  else
    echo "$line" | sed -n 's/^- \[\(.\)\].*/\1/p'
  fi
}

# Allow sourcing without executing
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "This script is meant to be sourced, not executed directly." >&2
  echo "Usage: source lib/ticket-audit-exec.sh" >&2
  exit 1
fi
