#!/usr/bin/env bash
# planner-crosscheck-repo-ref.sh — Discovery-pinned repo ref resolution for
# Crosscheck (issue #217).
#
# Crosscheck's citation linter resolves `path:line` citations against
# whatever branch REPOS_ROOT happens to be checked out to *right now* — not
# the tree Discovery actually explored. On a shared REPOS_ROOT checkout that
# moves between Discovery and Crosscheck (someone switches branches, another
# initiative's pipeline lands commits), two files can genuinely differ
# between the ref Discovery explored and the ref Crosscheck checks against,
# producing CITATION_UNRESOLVED / CITATION_LINE_OUT_OF_RANGE findings
# indistinguishable from a hallucinated citation. Confirmed live on VS-2 and
# VS-3, worked around both times with a throwaway `git worktree`.
#
# The fix has two halves:
#   1. Discovery records the ref it explored to the state log, per repo:
#        META|discovery|repo-ref|<repo>@<branch-or-ref>@<sha>
#      (written directly by the Discovery phase prompt — see
#      planner-phase-prompts.sh — since Discovery is an LLM-reasoning phase,
#      not this deterministic library.)
#   2. Crosscheck reads those entries back (this file) and, for any repo
#      whose live REPOS_ROOT checkout no longer matches the pinned sha,
#      creates an isolated `git worktree` alongside the live repo — never
#      touching it — and excludes the live (now-wrong-branch) copy from
#      citation resolution so it never shadows the worktree.
#
# Hard rule: this library — and everything upstream of it in the planner —
# never runs `git checkout`, `git switch`, or `git reset` against a live
# REPOS_ROOT checkout. It only reads from one, or creates a worktree beside
# it. See ticket-planner SKILL.md's "Crosscheck" section.
#
# Sourceable library — no set -euo pipefail.

_PLANNER_CROSSCHECK_REPO_REF_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if ! declare -f planner_state_log >/dev/null 2>&1; then
  [ -f "${_PLANNER_CROSSCHECK_REPO_REF_LIB_DIR}/planner-state.sh" ] &&
    source "${_PLANNER_CROSSCHECK_REPO_REF_LIB_DIR}/planner-state.sh"
fi

# Read back the most recent repo-ref Discovery recorded for each repo.
# Usage: planner_crosscheck_repo_refs <initiative_id>
# Output (stdout): one "<repo> <ref> <sha>" line per repo, last-write-wins
# per repo name. Nothing if Discovery never recorded a repo-ref (older
# initiatives, or a repo Discovery didn't touch).
planner_crosscheck_repo_refs() {
  local initiative_id="$1"
  local log
  log=$(planner_state_log "$initiative_id")
  [ -f "$log" ] || return 0

  declare -A _pcrr_seen=()
  local line phase step status msg repo rest

  while IFS='|' read -r _ts phase step status msg; do
    [ "$phase" = "META" ] || continue
    [ "$step" = "discovery" ] || continue
    [ "$status" = "repo-ref" ] || continue
    [ -z "$msg" ] && continue

    repo="${msg%%@*}"
    rest="${msg#*@}"
    [ -z "$repo" ] && continue
    [ "$rest" = "$msg" ] && continue # no '@' at all — malformed, skip

    _pcrr_seen["$repo"]="$rest"
  done <"$log"

  local key val ref sha
  for key in "${!_pcrr_seen[@]}"; do
    val="${_pcrr_seen[$key]}"
    ref="${val%%@*}"
    sha="${val#*@}"
    [ "$sha" = "$val" ] && sha="" # no sha half recorded
    echo "${key} ${ref} ${sha}"
  done
}

# Ensure a tree matching <repo>@<sha> is resolvable under <repos_root>,
# without ever mutating the live checkout at <repos_root>/<repo>. If the live
# checkout's current HEAD already matches <sha>, does nothing. Otherwise
# creates (or reuses) an isolated detached worktree alongside the live repo.
# Best-effort: any failure (not a git repo, sha unresolvable, worktree
# creation fails) is silent and non-fatal — Crosscheck falls back to
# resolving against the live checkout rather than blocking the run over
# infrastructure trouble.
#
# Usage: planner_crosscheck_repo_ref_ensure <repos_root> <repo> <ref> <sha>
# Output (stdout): the live repo dir's basename, if it should be excluded
# from citation resolution in favor of the worktree. Empty otherwise.
planner_crosscheck_repo_ref_ensure() {
  local repos_root="$1" repo="$2" ref="$3" sha="$4"
  local live_dir="${repos_root}/${repo}"

  [ -n "$sha" ] || return 0
  [ -d "${live_dir}/.git" ] || return 0

  local live_sha
  live_sha=$(git -C "$live_dir" rev-parse HEAD 2>/dev/null)
  [ -n "$live_sha" ] || return 0
  [ "$live_sha" = "$sha" ] && return 0

  # git worktree add resolves the sha itself — no need to fetch/verify it
  # exists first, the exit code already tells us.
  local safe_ref short_sha worktree_dir
  safe_ref=$(printf '%s' "$ref" | tr -c 'A-Za-z0-9_.' '-')
  short_sha="${sha:0:12}"
  worktree_dir="${repos_root}/${repo}-crosscheck-${safe_ref}-${short_sha}"

  if [ ! -d "$worktree_dir" ]; then
    git -C "$live_dir" worktree add --detach "$worktree_dir" "$sha" \
      >/dev/null 2>&1 || return 0
  fi
  [ -d "$worktree_dir" ] || return 0

  basename "$live_dir"
}

# Apply every repo-ref Discovery recorded for one initiative: for each repo
# whose live checkout no longer matches, ensure an isolated worktree exists
# and collect the live dir's basename so the caller can exclude it from
# resolution.
#
# Usage: planner_crosscheck_repo_ref_setup <initiative_id> <repos_root>
# Output (stdout): space-separated list of live-repo basenames to exclude
# from citation resolution (may be empty — the common case, when the live
# checkout already matches or Discovery recorded no repo-ref).
planner_crosscheck_repo_ref_setup() {
  local initiative_id="$1" repos_root="$2"
  local repo ref sha excl exclusions=""

  while read -r repo ref sha; do
    [ -z "$repo" ] && continue
    excl=$(planner_crosscheck_repo_ref_ensure "$repos_root" "$repo" "$ref" "$sha")
    [ -n "$excl" ] && exclusions="${exclusions}${exclusions:+ }${excl}"
  done < <(planner_crosscheck_repo_refs "$initiative_id")

  echo "$exclusions"
}
