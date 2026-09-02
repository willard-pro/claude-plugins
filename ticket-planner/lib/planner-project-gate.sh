#!/usr/bin/env bash
# planner-project-gate.sh — Epic Gen's Linear-project gate.
#
# `--project` / `LINEAR_PROJECT` are read once at argument-parsing time and
# persisted as config. When they were never set, Epic Gen used to file the epic —
# and, transitively, every ticket Ticket Gen creates under it — with no project at
# all, and said nothing about it anywhere. Four initiatives and 24 child tickets
# went to Linear that way before a human noticed them missing from the project
# view weeks later (#256).
#
# This gate is the missing feedback. It never guesses a project: the operator
# either confirms the candidate it names or opts out with `--no-project`. That is
# the same discipline `planner_linear_resolve_team_id` already applies to team
# ambiguity — more than one plausible answer is an error, not a guess.
#
# Deterministic bash, called from the Epic Gen agent's setup block. The decision
# and its state-log record both live here, not in the agent's judgement.
#
# Sourceable library — no set -euo pipefail.

_PLANNER_PROJECT_GATE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if ! declare -f planner_state_write >/dev/null 2>&1; then
  source "${_PLANNER_PROJECT_GATE_LIB_DIR}/planner-state.sh"
fi
if ! declare -f planner_linear_list_team_projects >/dev/null 2>&1; then
  source "${_PLANNER_PROJECT_GATE_LIB_DIR}/planner-linear-api.sh"
fi

# Build the text a project name is matched against.
#
# Deliberately narrow: the initiative idea plus the Affected Services of the
# appraisal and the proposal. Matching against whole artifacts would turn any
# passing mention of a project name into a stop.
#
# Usage: planner_project_match_text <initiative_id>
# Output: the match text on stdout (possibly empty).
planner_project_match_text() {
  local initiative_id="$1"
  local state_dir artifact

  state_dir=$(planner_initiative_dir "$initiative_id") || return 1

  cat "${state_dir}/artifacts/idea.txt" 2>/dev/null

  for artifact in appraisal.md proposal.md; do
    [ -f "${state_dir}/artifacts/${artifact}" ] || continue
    # A heading contributes its whole section; a bullet or bold field line (the
    # shape the proposal uses) contributes only itself.
    awk '
      /^#+[[:space:]].*[Aa]ffected[[:space:]]+[Ss]ervices/ { inblock = 1; print; next }
      inblock && /^#+[[:space:]]/ { inblock = 0 }
      inblock { print; next }
      /[Aa]ffected[[:space:]]+[Ss]ervices/ { print }
    ' "${state_dir}/artifacts/${artifact}"
  done
}

# Decide what Epic Gen does when no project was configured.
#
# Writes its own state-log entry on every path that reaches Linear — the omission
# being invisible is the defect this gate exists to fix, so "proceed with no
# project" is recorded as loudly as a stop is.
#
# Usage: planner_project_gate_check <initiative_id> <team_id>
# Returns: 0 to proceed, 1 to stop the phase (reason on stderr).
planner_project_gate_check() {
  local initiative_id="$1" team_id="$2"

  # A configured project needs no gate — Epic Gen resolves it as it always has.
  [ -n "$(planner_config_get "$initiative_id" "linear-project")" ] && return 0

  # --no-project: this workspace does not use Linear projects. Persisted, so the
  # opt-out holds for every later phase and every later resume.
  [ "$(planner_config_get "$initiative_id" "no-project")" = "true" ] && return 0

  local projects_json
  projects_json=$(planner_linear_list_team_projects "$team_id") || {
    planner_state_write "$initiative_id" "EpicGen" "project" "skip" \
      "no project configured and the team's projects could not be listed — pass --project or --no-project"
    return 0
  }

  local count candidates match_count
  count=$(printf '%s' "$projects_json" | jq -r 'length')
  candidates=$(planner_linear_detect_project_candidates \
    "$projects_json" "$(planner_project_match_text "$initiative_id")")

  match_count=0
  [ -n "$candidates" ] && match_count=$(printf '%s\n' "$candidates" | wc -l | tr -d ' ')

  # Exactly one plausible project: stop and ask. Applying it would be a guess,
  # and a guess is what --team's resolver refuses to make for the same reason.
  if [ "$match_count" = "1" ]; then
    local safe_name
    safe_name=$(printf '%s' "$candidates" | tr '|' ' ')
    planner_state_write "$initiative_id" "EpicGen" "project" "fail" \
      "no project configured but team project '${safe_name}' matches this initiative — confirm with --project '${safe_name}' or opt out with --no-project"
    echo "ERROR: EpicGen stopped — no --project was set, but the team project '${safe_name}' matches this initiative." >&2
    echo "Confirm it:  /ticket-planner resume ${initiative_id} --create --project '${safe_name}'" >&2
    echo "Or opt out:  /ticket-planner resume ${initiative_id} --create --no-project" >&2
    return 1
  fi

  # Zero or several: proceeding with no project is still the right default, but
  # it is now on the record where an operator scanning the log will see it.
  planner_state_write "$initiative_id" "EpicGen" "project" "skip" \
    "no project configured — ${count} project(s) on team, ${match_count} matched; pass --project or --no-project to silence this"
  return 0
}
