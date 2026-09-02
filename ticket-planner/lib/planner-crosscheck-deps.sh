#!/usr/bin/env bash
# planner-crosscheck-deps.sh — Dangling blocked-by reference detector.
#
# Part of the Crosscheck check family (issue #178). This is #221: Specify
# writes each spec's dependencies as `blocked-by:<ref>` tokens on the spec's
# `## Labels` line — the same line Ticket Gen reads to set the real Linear
# `blocked-by:{ID}` label, and the same line
# `planner_branch_directive_recommend` (planner-deps-check.sh) reads to
# compute the shared-branch heuristic. Neither of those call sites, nor any
# Crosscheck check, ever confirms `<ref>` actually names a sibling spec. On
# VS-3 (INIT-1788079199-4192) all 5 specs used a short-form sibling reference
# in `## Labels` that didn't resolve to a real ticket id at Ticket Gen time —
# caught and fixed by hand before dispatch, but a dangling ref reaching Ticket
# Gen's `issueCreate` call unnoticed is a harder failure to recover from
# (partial ticket creation mid-dispatch) than catching it here, at the
# artifact-only gate.
#
# Extraction mirrors `planner_branch_directive_recommend`'s Labels-line
# parsing exactly (same awk anchor, same backtick-tolerant token regex) so
# this check validates the identical token set that recommender and Ticket
# Gen actually consume — not a stricter or looser re-derivation of it.
#
# Resolution: a token resolves if it equals a sibling spec's slug (the spec
# filename minus `.md`) exactly, or is an unambiguous `-`-bounded prefix of
# exactly one sibling slug (the same short-form convention
# `planner_branch_directive_recommend` already tolerates, e.g. `exc-1` for
# `exc-1-something`). A token matching zero slugs, or matching more than one
# slug as a prefix, does not resolve.
#
# Exempt: a token that is an existing Linear issue identifier (`WIL-83`) is a
# cross-initiative prerequisite (#227), not a sibling reference — see
# `planner_deps_is_external_ref` in planner-deps-check.sh. It is already a real
# ticket ID that Ticket Gen applies verbatim, so there is no sibling spec for it
# to resolve against. Sibling resolution is attempted first, so an exempt token
# is only ever one that names nothing inside the initiative.
#
# Code: DANGLING_BLOCKED_BY. Blocking (not in PLANNER_CROSSCHECK_WARN_CODES in
# planner-crosscheck.sh) — same class of defect the citation linter blocks
# on: an artifact silently wrong about a load-bearing planner contract, not a
# matter for human judgment.
#
# Usage:
#   planner_crosscheck_deps <initiative_id>
#     Returns: 0 if clean, 1 if any finding was reported.
#
# Sourceable library — no set -euo pipefail.

_PLANNER_CROSSCHECK_DEPS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if ! declare -f _planner_crosscheck_known_slugs >/dev/null 2>&1; then
  # shellcheck source=planner-crosscheck-propagation.sh
  [ -f "${_PLANNER_CROSSCHECK_DEPS_LIB_DIR}/planner-crosscheck-propagation.sh" ] &&
    source "${_PLANNER_CROSSCHECK_DEPS_LIB_DIR}/planner-crosscheck-propagation.sh"
fi

if ! declare -f planner_deps_is_external_ref >/dev/null 2>&1; then
  # shellcheck source=planner-deps-check.sh
  [ -f "${_PLANNER_CROSSCHECK_DEPS_LIB_DIR}/planner-deps-check.sh" ] &&
    source "${_PLANNER_CROSSCHECK_DEPS_LIB_DIR}/planner-deps-check.sh"
fi

# Extract the `blocked-by:<ref>` tokens (backticks stripped) from <spec_file>'s
# `## Labels` line. Empty output if there is no Labels line, or it has no
# blocked-by tokens.
# Usage: _planner_crosscheck_deps_tokens <spec_file>
_planner_crosscheck_deps_tokens() {
  local spec_file="$1"
  local labels_line
  labels_line=$(awk '/^## Labels/{f=1;next} f && NF{print; exit}' "$spec_file" 2>/dev/null)
  [ -z "$labels_line" ] && return 0

  # grep legitimately exits 1 when the Labels line has no blocked-by token —
  # neutralize that so it doesn't read as a function failure to callers.
  echo "$labels_line" | { grep -oE 'blocked-by:`?[A-Za-z0-9_-]+`?' || true; } |
    sed -E 's/blocked-by:`?([A-Za-z0-9_-]+)`?/\1/'
}

# For an initiative's spec files, report every `blocked-by:<ref>` token on a
# `## Labels` line that does not resolve — exactly or as an unambiguous
# `-`-bounded prefix — to another spec file's slug in the same initiative.
# Usage: planner_crosscheck_deps <initiative_id>
# Returns: 0 if clean, 1 if any finding was reported.
planner_crosscheck_deps() {
  local initiative_id="$1"
  local repos_root="${REPOS_ROOT:-${HOME}/repos}"
  local specs_dir="${repos_root}/.ticket-auto/initiatives/${initiative_id}/artifacts/specs"
  [ -d "$specs_dir" ] || return 0

  local -a known_slugs
  mapfile -t known_slugs < <(_planner_crosscheck_known_slugs "$specs_dir")
  [ "${#known_slugs[@]}" -ge 1 ] || return 0

  local -a out_lines=()
  local spec_file base tok s exact
  local -a tokens_arr matches

  for spec_file in "$specs_dir"/*.md; do
    [ -f "$spec_file" ] || continue
    base="$(basename "$spec_file" .md)"
    [ "$base" = "INDEX" ] && continue

    tokens_arr=()
    mapfile -t tokens_arr < <(_planner_crosscheck_deps_tokens "$spec_file")
    [ "${#tokens_arr[@]}" -eq 0 ] && continue

    for tok in "${tokens_arr[@]}"; do
      [ -z "$tok" ] && continue

      exact=""
      for s in "${known_slugs[@]}"; do
        if [ "$s" = "$tok" ]; then
          exact="$s"
          break
        fi
      done
      [ -n "$exact" ] && continue

      # A cross-initiative prerequisite names an existing ticket by its real
      # Linear identifier (#227) — it is already resolved, so there is no
      # sibling spec for it to point at and no dangling reference to report.
      # Sibling resolution above still wins, so this only ever fires for a
      # token that names nothing inside the initiative.
      planner_deps_is_external_ref "$tok" && continue

      matches=()
      for s in "${known_slugs[@]}"; do
        case "$s" in
        "${tok}-"*) matches+=("$s") ;;
        esac
      done

      if [ "${#matches[@]}" -eq 0 ]; then
        out_lines+=("planner-crosscheck-deps: DANGLING_BLOCKED_BY ${base}.md references blocked-by:${tok} which does not resolve to any sibling spec in this initiative")
      elif [ "${#matches[@]}" -gt 1 ]; then
        local joined
        joined=$(printf '%s,' "${matches[@]}")
        joined="${joined%,}"
        out_lines+=("planner-crosscheck-deps: DANGLING_BLOCKED_BY ${base}.md references blocked-by:${tok} which is an ambiguous prefix matching multiple sibling specs: ${joined}")
      fi
    done
  done

  [ "${#out_lines[@]}" -eq 0 ] && return 0

  printf '%s\n' "${out_lines[@]}" | sort
  return 1
}
