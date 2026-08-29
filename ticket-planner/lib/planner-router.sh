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

# Source sibling libraries. BASH_SOURCE is the only lookup that cannot depend on
# CLAUDE_PLUGIN_ROOT being set — an unset-or-wrong value used to leave the router
# silently unsourced (it fell back to "." — the caller's cwd).
_PLANNER_ROUTER_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_source_if_missing "planner_initiative_dir" "${_PLANNER_ROUTER_LIB_DIR}/planner-state.sh"

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

# ── Stop conditions (holds and --until) ────────────────────────────────────────
#
# Three operator controls answer the same question — at which phase does the
# dispatch loop stop? Rather than three checks in the loop, they collapse into a
# single "earliest stop phase":
#
#   --until <Phase> / PLANNER_UNTIL   stop after <Phase> completes
#   --dry-run                          alias for --until Consensus (the last
#                                      phase before any Linear entity is created)
#   PLANNER_REVIEW_HOLD=true           stop after Review
#   PLANNER_CONSENSUS_HOLD=true        stop after Consensus
#
# Stopping is not a special mode: the router holds no in-memory state, so a stop
# is just "quit dispatching", and `resume` is the continuation — the same path
# crash recovery already uses.

# Phase after which a --dry-run stops. Consensus is the last artifact-only phase;
# EpicGen is the first Linear write.
PLANNER_DRY_RUN_PHASE="Consensus"

# Resolve the effective stop phase from flags and env.
# Usage: planner_stop_phase
# Output: phase name on stdout, or empty when the run should go to completion.
planner_stop_phase() {
  local -a candidates=()

  [ -n "${PLANNER_UNTIL:-}" ] && candidates+=("$PLANNER_UNTIL")
  [ "${PLANNER_REVIEW_HOLD:-false}" = "true" ] && candidates+=("Review")
  [ "${PLANNER_CONSENSUS_HOLD:-false}" = "true" ] && candidates+=("Consensus")

  [ "${#candidates[@]}" -eq 0 ] && {
    echo ""
    return 0
  }

  # Earliest wins — a hold before the --until target still stops the run there.
  local best="" best_idx=-1 phase idx
  for phase in "${candidates[@]}"; do
    idx=$(planner_phase_index "$phase") || continue
    if [ "$best_idx" -lt 0 ] || [ "$idx" -lt "$best_idx" ]; then
      best="$phase"
      best_idx="$idx"
    fi
  done

  echo "$best"
}

# Should the loop stop now that <phase> has completed?
# Usage: planner_should_stop_after <phase>
# Returns: 0 to stop, 1 to keep dispatching.
planner_should_stop_after() {
  local phase="$1"
  local stop
  stop=$(planner_stop_phase)

  [ -z "$stop" ] && return 1
  [ "$phase" = "$stop" ] && return 0
  return 1
}

# Validate a --until / PLANNER_UNTIL value against the canonical phase sequence.
# The sequence is the single source of truth — never validate against a second list.
#
# Usage: planner_until_validate <until_phase> [initiative_id]
# Returns: 0 valid, 1 unknown phase, 2 phase already passed.
planner_until_validate() {
  local until_phase="$1" initiative_id="${2:-}"
  local -a phase_sequence
  planner_phase_sequence phase_sequence

  local until_idx
  # planner_phase_index returns 1 for an unknown name; tolerate it here so the
  # error is reported below rather than tripping a caller's errexit.
  until_idx=$(planner_phase_index "$until_phase" || true)
  if [ "$until_idx" -lt 0 ]; then
    local joined
    joined=$(printf '%s, ' "${phase_sequence[@]}")
    echo "ERROR: unknown phase '${until_phase}' for --until. Valid phases: ${joined%, }" >&2
    return 1
  fi

  # Nothing more to check for a fresh run — the position check needs a state log.
  if [ -z "$initiative_id" ] || [ ! -f "$(planner_state_log "$initiative_id")" ]; then
    return 0
  fi

  local current current_idx
  current=$(planner_position_derive "$initiative_id")
  if [ -z "$current" ]; then
    echo "ERROR: initiative '${initiative_id}' is already complete — --until ${until_phase} has nothing to stop." >&2
    return 2
  fi

  current_idx=$(planner_phase_index "$current" || true)
  if [ "$until_idx" -lt "$current_idx" ]; then
    echo "ERROR: --until ${until_phase} names a phase already passed — '${initiative_id}' is at ${current}." >&2
    return 2
  fi

  return 0
}

# ── Retry budget ───────────────────────────────────────────────────────────────

# Has <phase> exhausted its retry budget? Derived from `fail` entries in the log,
# so the count survives a crashed router the same way position does.
#
# Usage: planner_phase_retries_exhausted <initiative_id> <phase>
# Returns: 0 when the budget is spent (stop), 1 when a retry remains.
planner_phase_retries_exhausted() {
  local initiative_id="$1" phase="$2"
  local max="${PLANNER_MAX_PHASE_RETRIES:-2}"
  local fails
  fails=$(planner_phase_fail_count "$initiative_id" "$phase")

  # `fails` counts attempts that already failed; the budget is retries *after*
  # the first attempt, so failing once with max=2 still leaves two retries.
  [ "$fails" -gt "$max" ]
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
