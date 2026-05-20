#!/usr/bin/env bash
# Shared agent transcript persistence helpers. Source this file from skill scripts.
# All functions return 0 silently if ticket_id is empty.
set -euo pipefail

# Persist raw agent output to disk for deep-dive debugging.
#
# Args:
#   ticket_id  — ticket identifier (e.g. CRE-47). No-op if empty.
#   phase      — phase name in kebab-case (e.g. appraise, exec, implement, verify,
#                maintenance, pr-review)
#   result     — raw agent output string to persist
#   attempt    — (optional) attempt number for retry phases (e.g. verify). When
#                provided, appends with an "--- Attempt N ---" separator instead of
#                overwriting. Omit for single-attempt phases.
#
# Output path: ./logs/{ticket_id}-{phase}-agent.log
# Single-attempt phases: overwrite mode
# Multi-attempt phases:  append mode with separator
capture_agent_result() {
  local ticket_id="${1:-}"
  local phase="${2:-}"
  local result="${3:-}"
  local attempt="${4:-}"

  [ -z "$ticket_id" ] && return 0
  [ -z "$phase" ] && return 0

  mkdir -p "./logs"

  local log_path="./logs/${ticket_id}-${phase}-agent.log"

  if [ -n "$attempt" ]; then
    printf -- "--- Attempt %s ---\n" "$attempt" >> "$log_path"
    printf "%s\n" "$result" >> "$log_path"
  else
    printf "%s\n" "$result" > "$log_path"
  fi
}
