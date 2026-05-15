#!/usr/bin/env bash
# get_complexity <ticket-dir>
# Reads the ## Complexity section's **Score:** value from notes.md.
# Emits "simple", "complex", or empty string if absent.
get_complexity() {
  local ticket_dir="$1"
  local notes="$ticket_dir/notes.md"
  [ -f "$notes" ] || return 0
  grep -A3 '## Complexity' "$notes" 2>/dev/null \
    | grep '^\*\*Score:' \
    | awk '{print $2}' \
    | tr -d '\r' \
    || true
}
