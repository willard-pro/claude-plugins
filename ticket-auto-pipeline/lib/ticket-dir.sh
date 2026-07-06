#!/usr/bin/env bash
# resolve_ticket_dir <TICKET_ID> [<root>]
# Single match: emits path on stdout, exit 0.
# Multiple matches: exits non-zero, lists all matches on stderr.
# No match: exits 1, empty stdout.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$SCRIPT_DIR/error-handler.sh" ]; then
  source "$SCRIPT_DIR/error-handler.sh"
fi

resolve_ticket_dir() {
  local ticket_id="$1"
  local root="${2:-.}"
  local matches
  matches=$(find "$root" -maxdepth 2 -type d \
    -iregex ".*/${ticket_id}--[a-z0-9-]+$" 2>/dev/null || true)
  local count
  count=$(echo "$matches" | grep -c . 2>/dev/null || true)
  if [ -z "$matches" ] || [ "$count" -eq 0 ]; then
    hb_heartbeat "ticket-dir-not-found" "no workspace directory for ${ticket_id}" 2>/dev/null || true
    error_return 12 "ticket directory not found for ${ticket_id}"
  elif [ "$count" -eq 1 ]; then
    echo "$matches"
    return 0
  else
    echo "Multiple ticket dirs found for $ticket_id:" >&2
    echo "$matches" >&2
    return 2
  fi
}

# Resolve the plan artifact path with full fallback chain.
# Args: <log_file> <ticket_dir> [ticket_id_lowercase]
#   1. Pipeline log META|artifact|info|plan: entry
#   2. simple-fix.md in ticket directory
#   3. openspec/changes/*/tasks.md matching the ticket ID
# Emits the resolved path on stdout, or empty string if not found.
resolve_plan_path() {
  local log_file="$1"
  local ticket_dir="$2"
  local ticket_id_lc="${3:-}"
  local plan_path

  plan_path=$(grep '|META|artifact|info|plan:' "$log_file" 2>/dev/null | tail -1 | cut -d'|' -f5 | sed 's/^plan://' || true)
  if [ -n "$plan_path" ] && [ -f "$plan_path" ]; then
    echo "$plan_path"
    return 0
  fi

  plan_path=$(find "$ticket_dir" -maxdepth 1 -name "simple-fix.md" -print -quit 2>/dev/null || true)
  if [ -n "$plan_path" ]; then
    echo "$plan_path"
    return 0
  fi

  if [ -n "$ticket_id_lc" ]; then
    local change_dir
    change_dir=$(ls -d openspec/changes/*/ 2>/dev/null | grep -i "$ticket_id_lc" | head -1 || true)
    if [ -n "$change_dir" ]; then
      echo "${change_dir}tasks.md"
      return 0
    fi
  fi

  error_return 12 "plan path not resolved for ${ticket_dir}"
}
