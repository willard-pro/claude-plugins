#!/usr/bin/env bash
# planner-router.sh — Phase router for the ticket-planner.
#
# The router is the deterministic core. It reads the state log, derives the
# current phase, validates transitions, and dispatches phases as isolated agents.
# It performs no reasoning of its own — it is a state machine executor.
#
# Pattern copied deliberately from ticket-auto: state lives in a durable log,
# resume re-derives position by re-reading the log.
#
# Sourceable library — no set -euo pipefail.

_source_if_missing() {
  local name="$1" path="$2"
  if ! declare -f "$name" >/dev/null 2>&1; then
    [ -f "$path" ] && source "$path"
  fi
}

# Source state library
_source_if_missing "planner_initiative_dir" "${CLAUDE_PLUGIN_ROOT:-.}/lib/planner-state.sh"

# ── Phase dispatch ─────────────────────────────────────────────────────────────

# Dispatch a single phase. Spawns an isolated agent for the phase.
# The agent writes state log entries directly (same pattern as ticket-auto agents
# writing to pipeline log).
#
# Usage: planner_phase_dispatch <initiative_id> <phase> [idea]
# Returns: 0 on success, non-zero on failure.
planner_phase_dispatch() {
  local initiative_id="$1" phase="$2" idea="${3:-}"
  local state_dir
  state_dir=$(planner_initiative_dir "$initiative_id")

  # Write phase start entry
  planner_state_write "$initiative_id" "$phase" "dispatch" "start" "spawning ${phase} agent"

  # The actual agent spawn is done by the skill file (SKILL.md) — this function
  # provides the routing decision. The skill file reads the phase from the router
  # and spawns the appropriate agent type.
  #
  # This separation mirrors ticket-auto: the router determines what to do next;
  # the skill file orchestrates agent spawns with appropriate context.

  echo "PLANNER_PHASE=$phase"
  echo "PLANNER_INITIATIVE=$initiative_id"
  echo "PLANNER_STATE_DIR=$state_dir"
  if [ -n "$idea" ]; then
    echo "PLANNER_IDEA=$idea"
  fi
}

# ── Full run ───────────────────────────────────────────────────────────────────

# Run the planner from the current position to completion (or until a hold phase).
#
# The router loops: derive position → dispatch phase → wait for completion →
# read state log to determine next phase → repeat.
#
# Phases that require a human hold (if configured) will pause the loop.
#
# Usage: planner_run <initiative_id> [idea]
# Returns: 0 on completion, non-zero if a phase fails.
planner_run() {
  local initiative_id="$1" idea="${2:-}"
  local next_phase

  # Initialize state if needed
  if [ ! -f "$(planner_state_log "$initiative_id")" ]; then
    if [ -z "$idea" ]; then
      echo "ERROR: no state log and no idea provided — cannot initialize" >&2
      return 1
    fi
    planner_state_init "$initiative_id" "$idea"
  fi

  # Read the idea from state log if not provided
  if [ -z "$idea" ]; then
    idea=$(planner_state_read "$initiative_id" | grep '|META|idea|' | tail -1 | cut -d'|' -f5)
  fi

  # Main loop
  while true; do
    next_phase=$(planner_position_derive "$initiative_id")

    if [ -z "$next_phase" ]; then
      echo "PLANNER_COMPLETE=true"
      echo "PLANNER_INITIATIVE=$initiative_id"
      return 0
    fi

    echo "PLANNER_NEXT_PHASE=$next_phase"
    echo "PLANNER_INITIATIVE=$initiative_id"
    echo "PLANNER_IDEA=$idea"

    # The skill file reads PLANNER_NEXT_PHASE and spawns the agent.
    # When the agent completes, it writes done/fail to the state log.
    # The router then loops and re-derives position.
    break
  done
}

# ── Resume ─────────────────────────────────────────────────────────────────────

# Derive position from the log and return what to do next.
# This is a cold-start function: it reads the log and reports current position.
# No memory of prior execution is retained between invocations.
#
# Usage: planner_resume <initiative_id>
# Returns: phase name to resume at, or empty if complete.
planner_resume() {
  local initiative_id="$1"
  local next_phase

  if [ ! -f "$(planner_state_log "$initiative_id")" ]; then
    echo "ERROR: no state log for initiative '$initiative_id' — cannot resume" >&2
    return 1
  fi

  next_phase=$(planner_position_derive "$initiative_id")

  if [ -z "$next_phase" ]; then
    echo "PLANNER_COMPLETE=true"
    echo "PLANNER_INITIATIVE=$initiative_id"
    return 0
  fi

  echo "PLANNER_NEXT_PHASE=$next_phase"
  echo "PLANNER_INITIATIVE=$initiative_id"

  # Also surface the last few log entries for context
  local log_file
  log_file=$(planner_state_log "$initiative_id")
  echo "PLANNER_LAST_LOG=$(tail -5 "$log_file" 2>/dev/null | tr '\n' '|')"
}
