#!/usr/bin/env bash
# resolve_ticket_dir <TICKET_ID> [<root>]
# Single match: emits path on stdout, exit 0.
# Multiple matches: exits non-zero, lists all matches on stderr.
# No match: exits 1, empty stdout.
resolve_ticket_dir() {
  local ticket_id="$1"
  local root="${2:-.}"
  local matches
  matches=$(find "$root" -maxdepth 2 -type d \
    -regex ".*/${ticket_id}--[a-z0-9-]+$" 2>/dev/null || true)
  local count
  count=$(echo "$matches" | grep -c . 2>/dev/null || true)
  if [ -z "$matches" ] || [ "$count" -eq 0 ]; then
    return 1
  elif [ "$count" -eq 1 ]; then
    echo "$matches"
    return 0
  else
    echo "Multiple ticket dirs found for $ticket_id:" >&2
    echo "$matches" >&2
    return 2
  fi
}
