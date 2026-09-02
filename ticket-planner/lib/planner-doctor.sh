#!/usr/bin/env bash
# planner-doctor.sh — deterministic preflight checks for ticket-planner (#232).
#
# Every prerequisite gap the planner has hit so far — REPOS_ROOT unset/wrong,
# LINEAR_TEAM_ID unset, the 4 static contract labels silently missing from
# Linear, a live REPOS_ROOT checkout on the wrong branch relative to what
# Discovery explored (#217), a missing per-initiative INIT-* label (#223),
# a referenced-but-missing cross-plugin helper script — was discovered live,
# mid-run, by hitting the failure directly. `planner_doctor_run` checks all
# of them up front, before any Linear write is attempted.
#
# Output: pipe-delimited rows between ---BEGIN_VARS--- / ---END_VARS---, the
# same shape ticket-auto-pipeline's env-check.sh and fleet-controller's
# fleet-env-check.sh already use:
#   NAME|STATUS|VALUE|LOCATION|NOTE
#   STATUS: ok | missing | warn | info | fixed
#
# Usage: planner_doctor_run [initiative_id] [--fix]
#   initiative_id  optional — when given, also checks that the live REPOS_ROOT
#                  checkout for each repo Discovery explored still matches (or
#                  that an isolated worktree can be created), the resume-time
#                  half of #217.
#   --fix          create any missing static contract label via
#                  planner_linear_ensure_label instead of only reporting it.
# Returns: the number of issues found (0 = clean).
#
# Sourceable library — no set -euo pipefail (same convention as its
# planner-crosscheck-*.sh siblings).

_PLANNER_DOCTOR_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if ! declare -f planner_state_log >/dev/null 2>&1; then
  source "${_PLANNER_DOCTOR_LIB_DIR}/planner-state.sh"
fi
if ! declare -f planner_linear_resolve_team_id >/dev/null 2>&1; then
  source "${_PLANNER_DOCTOR_LIB_DIR}/planner-linear-api.sh"
fi
if ! declare -f _resolve_branch_directive_checker >/dev/null 2>&1; then
  source "${_PLANNER_DOCTOR_LIB_DIR}/branch-directive-gen.sh"
fi
if ! declare -f planner_crosscheck_repo_refs >/dev/null 2>&1; then
  source "${_PLANNER_DOCTOR_LIB_DIR}/planner-crosscheck-repo-ref.sh"
fi
if ! declare -f _resolve_grill_seal >/dev/null 2>&1; then
  source "${_PLANNER_DOCTOR_LIB_DIR}/planner-intent-gate.sh"
fi

# The 4 static contract labels — same set named in ticket-planner/CLAUDE.md
# and hard-required by planner_linear_resolve_label_ids. Not centralized
# anywhere else in the codebase; keep in sync with that doc if it ever changes.
_PLANNER_DOCTOR_STATIC_LABELS=(planned epic pre-approved state:execution)

# Resolve planned-ticket-check.sh via the same three-level fallback
# planner_validate_ticket (planner-ticket-validate.sh) uses inline — kept as
# a separate copy deliberately, same as _resolve_branch_directive_checker's
# relationship to it: each caller resolves its own dependency so a missing
# file is reported at the point that actually needs it.
_planner_doctor_resolve_planned_ticket_check() {
  local checker
  checker=$(find "${HOME}/.claude/plugins/cache" -name "planned-ticket-check.sh" \
    -path "*/ticket-auto-pipeline/*/lib/planned-ticket-check.sh" 2>/dev/null | sort | tail -1)
  if [ -n "$checker" ] && [ -f "$checker" ]; then
    echo "$checker"
    return 0
  fi

  checker="${HOME}/.claude/skills/lib/planned-ticket-check.sh"
  if [ -f "$checker" ]; then
    echo "$checker"
    return 0
  fi

  checker="${_PLANNER_DOCTOR_LIB_DIR}/../ticket-auto-pipeline/lib/planned-ticket-check.sh"
  if [ -f "$checker" ]; then
    echo "$checker"
    return 0
  fi

  echo ""
  return 1
}

planner_doctor_run() {
  local initiative_id="" fix_flag="false" arg
  for arg in "$@"; do
    case "$arg" in
    --fix) fix_flag="true" ;;
    --*) ;; # unrecognized flag — a preflight check should not hard-fail on it
    *) [ -z "$initiative_id" ] && initiative_id="$arg" ;;
    esac
  done

  local -a _rows=()
  local _issues=0
  _row() { _rows+=("$1|$2|$3|$4|$5"); }

  # ── 1. REPOS_ROOT ──────────────────────────────────────────────────────
  if [ -z "${REPOS_ROOT:-}" ]; then
    _row "REPOS_ROOT" "missing" "" "env" "unset — required for Discovery, Crosscheck citation resolution, and every phase under \${REPOS_ROOT}/.ticket-auto"
    _issues=$((_issues + 1))
  elif [ ! -d "$REPOS_ROOT" ]; then
    _row "REPOS_ROOT" "missing" "$REPOS_ROOT" "env" "not a directory"
    _issues=$((_issues + 1))
  else
    _row "REPOS_ROOT" "ok" "$REPOS_ROOT" "env" ""
  fi

  # ── 2. Linear team resolution ─────────────────────────────────────────
  local team_id="" team_err="" err_file
  err_file=$(mktemp)
  if [ -z "${LINEAR_API_KEY:-}" ]; then
    _row "LINEAR_TEAM_ID" "missing" "" "env" "LINEAR_API_KEY unset — cannot resolve a team"
    _issues=$((_issues + 1))
  elif team_id=$(planner_linear_resolve_team_id "${LINEAR_TEAM_ID:-}" 2>"$err_file"); then
    _row "LINEAR_TEAM_ID" "ok" "$team_id" "${LINEAR_TEAM_ID:-Linear (only team)}" ""
  else
    team_err=$(tr '\n' ' ' <"$err_file")
    _row "LINEAR_TEAM_ID" "missing" "" "env" "${team_err:-team resolution failed}"
    _issues=$((_issues + 1))
  fi
  rm -f "$err_file"

  # ── 3. Static contract labels ─────────────────────────────────────────
  local label label_ids
  if [ -n "$team_id" ]; then
    for label in "${_PLANNER_DOCTOR_STATIC_LABELS[@]}"; do
      if label_ids=$(planner_linear_resolve_label_ids "$team_id" "$(jq -nc --arg n "$label" '[$n]')" 2>/dev/null); then
        _row "label:${label}" "ok" "$(echo "$label_ids" | jq -r '.[0]')" "Linear" ""
      elif [ "$fix_flag" = "true" ]; then
        if label_ids=$(planner_linear_ensure_label "$team_id" "$label" 2>/dev/null); then
          _row "label:${label}" "fixed" "$label_ids" "Linear" "created by --fix"
        else
          _row "label:${label}" "missing" "" "Linear" "absent — --fix could not create it"
          _issues=$((_issues + 1))
        fi
      else
        _row "label:${label}" "missing" "" "Linear" "absent — create it in Linear, or re-run doctor with --fix"
        _issues=$((_issues + 1))
      fi
    done
  else
    for label in "${_PLANNER_DOCTOR_STATIC_LABELS[@]}"; do
      _row "label:${label}" "warn" "" "Linear" "skipped — team not resolved"
    done
  fi

  # ── 4. Resume-scoped repo-ref check (#217) ────────────────────────────
  if [ -z "$initiative_id" ]; then
    _row "repo-ref" "info" "" "-" "pass an initiative id (e.g. INIT-...) to check resume branch/sha alignment"
  elif [ -z "${REPOS_ROOT:-}" ] || [ ! -d "${REPOS_ROOT:-/nonexistent}" ]; then
    _row "repo-ref" "warn" "" "REPOS_ROOT" "skipped — REPOS_ROOT unresolved"
  else
    local repo ref sha live_dir live_sha excl found="false"
    while read -r repo ref sha; do
      [ -z "$repo" ] && continue
      found="true"
      live_dir="${REPOS_ROOT}/${repo}"
      live_sha=""
      [ -d "${live_dir}/.git" ] && live_sha=$(git -C "$live_dir" rev-parse HEAD 2>/dev/null)

      if [ -z "$sha" ]; then
        _row "repo-ref:${repo}" "info" "" "REPOS_ROOT/${repo}" "Discovery recorded no sha for this repo"
      elif [ "$live_sha" = "$sha" ]; then
        _row "repo-ref:${repo}" "ok" "$sha" "REPOS_ROOT/${repo}" "live checkout matches the ref Discovery explored"
      else
        excl=$(planner_crosscheck_repo_ref_ensure "$REPOS_ROOT" "$repo" "$ref" "$sha")
        if [ -n "$excl" ]; then
          _row "repo-ref:${repo}" "ok" "$sha" "REPOS_ROOT/${repo}-crosscheck-*" "live checkout diverged — isolated worktree ensured"
        else
          _row "repo-ref:${repo}" "missing" "$sha" "REPOS_ROOT/${repo}" "live checkout diverged from Discovery's pinned ref and no worktree could be created"
          _issues=$((_issues + 1))
        fi
      fi
    done < <(planner_crosscheck_repo_refs "$initiative_id")
    [ "$found" = "false" ] && _row "repo-ref" "info" "" "state.log" "no Discovery repo-ref entries recorded for ${initiative_id}"
  fi

  # ── 5. Cross-plugin helper scripts ────────────────────────────────────
  local planned_checker branch_checker grill_checker
  planned_checker=$(_planner_doctor_resolve_planned_ticket_check)
  if [ -n "$planned_checker" ]; then
    _row "planned-ticket-check.sh" "ok" "$planned_checker" "ticket-auto-pipeline" ""
  else
    _row "planned-ticket-check.sh" "missing" "" "ticket-auto-pipeline" "not found — ticket creation validation will hard-stop"
    _issues=$((_issues + 1))
  fi

  branch_checker=$(_resolve_branch_directive_checker 2>/dev/null)
  if [ -n "$branch_checker" ]; then
    _row "branch-directive-check.sh" "ok" "$branch_checker" "ticket-auto-pipeline" ""
  else
    _row "branch-directive-check.sh" "missing" "" "ticket-auto-pipeline" "not found — shared-epic-branch directive generation will hard-stop"
    _issues=$((_issues + 1))
  fi

  grill_checker=$(_resolve_grill_seal 2>/dev/null)
  if [ -n "$grill_checker" ]; then
    _row "grill-seal.sh" "ok" "$grill_checker" "grill-me" ""
  else
    _row "grill-seal.sh" "warn" "" "grill-me" "not found — only required when planning from a grill-me intent file"
  fi

  # ── Emit ───────────────────────────────────────────────────────────────
  echo "---BEGIN_VARS---"
  printf 'NAME|STATUS|VALUE|LOCATION|NOTE\n'
  local row
  for row in "${_rows[@]}"; do echo "$row"; done
  echo "ROWCOUNT=${#_rows[@]}"
  echo "---END_VARS---"

  return "$_issues"
}
