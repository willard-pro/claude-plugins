#!/usr/bin/env bash
# get_complexity <ticket-dir>
# Reads the ## Complexity section's **Score:** value from notes.md.
# Emits "simple", "complex", or empty string if absent.
# Exit codes: 0 = found, 1 = file unreadable, 2 = section not found
set -euo pipefail

get_complexity() {
  local ticket_dir="$1"
  local notes="$ticket_dir/notes.md"

  if [ ! -f "$notes" ]; then
    return 1
  fi

  local score
  score=$(grep -A3 '## Complexity' "$notes" 2>/dev/null \
    | grep '^\*\*Score:' \
    | awk '{print $2}' \
    | tr -d '\r' || true)

  if [ -n "$score" ]; then
    echo "$score"
    return 0
  fi

  return 2
}
