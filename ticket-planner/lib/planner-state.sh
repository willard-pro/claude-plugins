#!/usr/bin/env bash
# planner-state.sh — State log format and state directory helpers for ticket-planner.
#
# The planner uses an append-only pipe-delimited state log (same convention as
# ticket-auto's pipeline log). The router reads the log to derive the current
# phase; resume re-derives position by re-reading the log. No state held in memory.
#
# Log format: ISO|PHASE|STEP|STATUS|MSG
# Statuses: start, done, fail, skip
# Schema version: 1 (declared as first line)
#
# Sourceable library — no set -euo pipefail.

# ── Initiative ID validation ────────────────────────────────────────────────────

# Validate initiative_id against the expected pattern.
# Rejects path traversal sequences and non-conforming IDs before any path construction.
# Usage: planner_validate_initiative_id <initiative_id>
# Returns: 0 if valid, 1 if invalid (writes reason to stderr).
PLANNER_ID_PATTERN='^INIT-[A-Za-z0-9_-]+$'
planner_validate_initiative_id() {
  local id="$1"

  if [ -z "$id" ]; then
    echo "ERROR: initiative ID is empty" >&2
    return 1
  fi

  # Reject path traversal sequences
  case "$id" in
  *..* | */* | *\\*)
    echo "ERROR: initiative ID contains path traversal characters: '$id'" >&2
    return 1
    ;;
  esac

  # Reject if it doesn't match the expected pattern
  if ! echo "$id" | grep -qE "$PLANNER_ID_PATTERN"; then
    echo "ERROR: initiative ID '$id' does not match expected pattern ${PLANNER_ID_PATTERN}" >&2
    return 1
  fi

  return 0
}

# ── State directory ────────────────────────────────────────────────────────────

# Resolve the initiative state directory.
# Validates the initiative_id before constructing the path.
# Usage: planner_initiative_dir <initiative_id>
planner_initiative_dir() {
  local initiative_id="$1"
  local repos_root="${REPOS_ROOT:-${HOME}/repos}"

  # Path traversal guard: validate the ID
  if ! planner_validate_initiative_id "$initiative_id"; then
    echo "ERROR: invalid initiative ID '${initiative_id}'" >&2
    return 1
  fi

  local dir="${repos_root}/.ticket-auto/initiatives/${initiative_id}"

  # Defense-in-depth: verify the resolved path is still under the expected root
  local resolved
  if command -v realpath >/dev/null 2>&1; then
    resolved=$(realpath "$dir" 2>/dev/null || echo "$dir")
  else
    resolved=$(readlink -f "$dir" 2>/dev/null || echo "$dir")
  fi
  local expected_prefix="${repos_root}/.ticket-auto/initiatives"
  case "$resolved" in
  "${expected_prefix}"/*) ;;
  *)
    echo "ERROR: resolved path '${resolved}' is outside expected root '${expected_prefix}'" >&2
    return 1
    ;;
  esac

  echo "$dir"
}

# Ensure the initiative state directory and its subdirectories exist.
# Usage: planner_initiative_dir_init <initiative_id>
planner_initiative_dir_init() {
  local initiative_id="$1"
  local dir
  dir=$(planner_initiative_dir "$initiative_id")
  mkdir -p "${dir}/artifacts" "${dir}/feedback"
  echo "$dir"
}

# ── State log ──────────────────────────────────────────────────────────────────

# Path to the state log for an initiative.
# Usage: planner_state_log <initiative_id>
planner_state_log() {
  local initiative_id="$1"
  local dir
  dir=$(planner_initiative_dir "$initiative_id")
  echo "${dir}/state.log"
}

# Read the entire state log for an initiative.
# Usage: planner_state_read <initiative_id>
# Returns: all log lines, or empty if no log exists.
planner_state_read() {
  local initiative_id="$1"
  local log_file
  log_file=$(planner_state_log "$initiative_id")
  if [ -f "$log_file" ]; then
    cat "$log_file"
  fi
}

# Append a line to the state log. Atomic via mv (write to .tmp, then mv).
# Usage: planner_state_write <initiative_id> <phase> <step> <status> <message>
planner_state_write() {
  local initiative_id="$1" phase="$2" step="$3" status="$4" message="$5"
  local log_file iso
  log_file=$(planner_state_log "$initiative_id")
  iso=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  # Ensure directory exists
  mkdir -p "$(dirname "$log_file")"

  printf '%s|%s|%s|%s|%s\n' "$iso" "$phase" "$step" "$status" "$message" >>"$log_file"
}

# Initialize a new state log with the schema line and META entries.
# Idempotent — does nothing if the log already exists.
# Usage: planner_state_init <initiative_id> <idea>
planner_state_init() {
  local initiative_id="$1" idea="$2"
  local log_file
  log_file=$(planner_state_log "$initiative_id")

  if [ -f "$log_file" ]; then
    return 0
  fi

  planner_initiative_dir_init "$initiative_id"

  # Schema declaration (first line)
  planner_state_write "$initiative_id" "META" "schema" "start" "1"

  # Initiative identity
  planner_state_write "$initiative_id" "META" "initiative-id" "start" "$initiative_id"

  # The idea that spawned this initiative
  planner_state_write "$initiative_id" "META" "idea" "start" "$idea"
}

# ── Position derivation ────────────────────────────────────────────────────────

# Derive the current phase from the state log.
# Reads the log, finds the last completed phase, returns the next phase to run.
# Handles: incomplete trailing entries (crashed mid-phase → resume at that phase),
# missing logs (→ start at Appraisal), terminal phases (→ empty string = done).
#
# Usage: planner_position_derive <initiative_id>
# Returns: next phase name, or empty string if at terminal state.
planner_position_derive() {
  local initiative_id="$1"
  local log_file phase_sequence current_phase
  log_file=$(planner_state_log "$initiative_id")

  # Define the phase sequence (12 phases)
  phase_sequence=(
    "Appraisal" "Discovery" "Architecture" "Proposal" "Review" "Consensus"
    "OpenSpec" "EpicGen" "StoryGen" "TicketGen" "Execution" "Completed"
  )

  if [ ! -f "$log_file" ]; then
    echo "${phase_sequence[0]}"
    return 0
  fi

  # Find the last line with a non-META phase and a terminal status (done/fail/skip)
  # We walk the log in reverse to find the most recently completed phase.
  local last_completed=""
  local last_started=""
  local line phase status

  while IFS='|' read -r _iso phase _step status _msg; do
    # Skip META lines
    [ "$phase" = "META" ] && continue

    # Track the last phase that has a start entry (may be incomplete)
    if [ "$status" = "start" ] && [ -z "$last_started" ]; then
      last_started="$phase"
    fi

    # Track the last phase that has a terminal entry (done, fail, skip)
    if [ "$status" = "done" ] || [ "$status" = "fail" ] || [ "$status" = "skip" ]; then
      last_completed="$phase"
      break
    fi
  done < <(tac "$log_file" 2>/dev/null)

  # If a phase was started but not completed, resume at that phase
  if [ -n "$last_started" ]; then
    # Check if the started phase is after the last completed phase
    # (i.e., the crash happened mid-phase, resume there)
    local started_idx=-1 completed_idx=-1 i
    for i in "${!phase_sequence[@]}"; do
      [ "${phase_sequence[$i]}" = "$last_started" ] && started_idx=$i
      [ "${phase_sequence[$i]}" = "$last_completed" ] && completed_idx=$i
    done

    if [ "$started_idx" -gt "$completed_idx" ]; then
      echo "$last_started"
      return 0
    fi
  fi

  # Advance to the next phase after the last completed
  if [ -z "$last_completed" ]; then
    # No phase has completed — start at the beginning
    echo "${phase_sequence[0]}"
    return 0
  fi

  # Find the next phase in the sequence
  local found=0
  for phase in "${phase_sequence[@]}"; do
    if [ "$found" -eq 1 ]; then
      echo "$phase"
      return 0
    fi
    if [ "$phase" = "$last_completed" ]; then
      found=1
    fi
  done

  # If last_completed was the terminal phase, we're done
  echo ""
}

# ── Validation ─────────────────────────────────────────────────────────────────

# Validate that a transition from one phase to another is legal.
# The 12-phase sequence is strictly linear — no skipping, no backtracking.
# Usage: planner_phase_validate_transition <initiative_id> <from_phase> <to_phase>
# Returns: 0 if legal, 1 if illegal.
planner_phase_validate_transition() {
  local initiative_id="$1" from="$2" to="$3"

  local phase_sequence=(
    "Appraisal" "Discovery" "Architecture" "Proposal" "Review" "Consensus"
    "OpenSpec" "EpicGen" "StoryGen" "TicketGen" "Execution" "Completed"
  )

  # Transition to same phase is legal (resume after crash)
  if [ "$from" = "$to" ]; then
    return 0
  fi

  local from_idx=-1 to_idx=-1 i
  for i in "${!phase_sequence[@]}"; do
    [ "${phase_sequence[$i]}" = "$from" ] && from_idx=$i
    [ "${phase_sequence[$i]}" = "$to" ] && to_idx=$i
  done

  # from phase must exist in sequence
  if [ "$from_idx" -lt 0 ]; then
    echo "ERROR: unknown phase '$from'" >&2
    return 1
  fi

  # to phase must exist in sequence
  if [ "$to_idx" -lt 0 ]; then
    echo "ERROR: unknown phase '$to'" >&2
    return 1
  fi

  # to must be exactly one step ahead of from (or equal, handled above)
  if [ "$to_idx" -ne $((from_idx + 1)) ]; then
    echo "ERROR: illegal transition '$from' → '$to' (expected '${phase_sequence[$((from_idx + 1))]}')" >&2
    return 1
  fi

  return 0
}

# ── Idempotency ────────────────────────────────────────────────────────────────

# Check whether a phase has already been completed in the state log.
# Used by phase agents to avoid re-executing completed work on resume.
# Usage: planner_phase_is_done <initiative_id> <phase>
# Returns: 0 if done, 1 if not done.
planner_phase_is_done() {
  local initiative_id="$1" phase="$2"
  local log_file
  log_file=$(planner_state_log "$initiative_id")

  if [ ! -f "$log_file" ]; then
    return 1
  fi

  grep -q "^[^|]*|${phase}|[^|]*|done|" "$log_file" 2>/dev/null
}
