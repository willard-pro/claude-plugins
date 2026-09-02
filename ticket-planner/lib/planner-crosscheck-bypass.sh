#!/usr/bin/env bash
# planner-crosscheck-bypass.sh — Bypass-path sweep + discovery-gap escalation.
#
# Part of the Crosscheck check family (issue #178). This is #174: the planner
# reasons forward from "what shall we build" and never asks "what already
# exists that contradicts it". When an epic's purpose is to guard a field,
# enforce an invariant, or replace a path, a pre-existing writer of the same
# data silently defeats it — and every spec in the set can still be
# internally correct.
#
# WHY THIS IS A HEURISTIC, NOT TRUE CONCEPT MATCHING
# ---------------------------------------------------
# The audit's worked example (a Python `_build_classified_key()` bypassing a
# TypeScript `buildStorageKey`) is only findable by asking "what else builds
# storage keys" — the two functions share no name. True concept matching
# needs an LLM. This script instead requires the guard declaration to name
# its resource with a backtick-quoted identifier (a column, key, or field
# name spec prose already tends to quote) and searches REPOS_ROOT for other
# lines that both contain that identifier and look like a write/definition
# site. That is narrower than the issue's full ambition, but it is bounded,
# deterministic, and catches the class of defect the issue describes: a
# named resource with an undisclosed second writer. A guard sentence with no
# backtick identifier is out of scope for Part A — same tradeoff
# planner-crosscheck-propagation.sh makes for term-only prose.
#
# Two checks:
#
#   Part A — bypass sweep. For every spec paragraph that both (1) matches a
#   guard-declaration phrase ("derived from", "never overwritten",
#   "hand-set", "only ... may", "must be audited", "must be locked") and (2)
#   names a backtick-quoted resource, search REPOS_ROOT for other file:line
#   sites that mention that resource on a line that looks like a write or
#   definition, excluding every file already cited anywhere in the spec set.
#   Code: BYPASS_PATH_UNADDRESSED. Blocks EpicGen.
#
#   Part B — discovery gap escalation. discovery.md admissions of a
#   self-declared exploration limitation ("quick-scan", "did not trace",
#   "not explored", "assumed", ...) must have their substance recorded in
#   proposal.md's Out of Scope section — otherwise later phases reason
#   confidently over a region the pipeline itself flagged as unexamined.
#   Code: DISCOVERY_GAP_UNRESOLVED. Warn-level (see
#   PLANNER_CROSSCHECK_WARN_CODES in planner-crosscheck.sh) — a declared gap
#   is a prompt for human judgment, not by itself proof of a defect.
#
# Usage:
#   planner_crosscheck_bypass <initiative_id>
#     Runs both checks. Returns 0 if clean, 1 if any check reported a finding.
#
# Sourceable library — no set -euo pipefail.

_PLANNER_CROSSCHECK_BYPASS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Reuses propagation.sh's term-extraction/threshold helpers
# (_planner_crosscheck_prop_terms, _planner_crosscheck_prop_threshold,
# _planner_crosscheck_prop_presence_count) rather than duplicating them.
if ! declare -f _planner_crosscheck_prop_terms >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  [ -f "${_PLANNER_CROSSCHECK_BYPASS_LIB_DIR}/planner-crosscheck-propagation.sh" ] &&
    source "${_PLANNER_CROSSCHECK_BYPASS_LIB_DIR}/planner-crosscheck-propagation.sh"
fi

# ── Config ──────────────────────────────────────────────────────────────────

# Directory components excluded from repo-wide search — same rationale as
# planner-crosscheck-citations.sh: .ticket-auto is the planner's own working
# directory, searching it back would let a spec's prose "resolve" its own
# claim. .claude is excluded because REPOS_ROOT commonly holds sibling repos
# like dotfiles whose .claude/projects/**/tool-results/*.txt cache raw
# Claude Code session transcripts — free text that can quote real code
# verbatim (a pasted diff, a grepped SQL line) and false-positive as an
# undisclosed second writer, even though it is not part of any codebase.
PLANNER_CROSSCHECK_BYPASS_EXCLUDE_DIRS=("node_modules" ".venv" ".git" ".ticket-auto" ".claude" "ledgerly" "tickets")

# Extensions a `path:line` citation token is recognized against.
PLANNER_CROSSCHECK_BYPASS_CITE_EXT_LIST=(ts tsx js jsx py rb go java sql)
_PLANNER_CROSSCHECK_BYPASS_CITE_EXTENSIONS=$(
  IFS='|'
  echo "${PLANNER_CROSSCHECK_BYPASS_CITE_EXT_LIST[*]}"
)
PLANNER_CROSSCHECK_BYPASS_CITE_REGEX="[A-Za-z0-9_./-]+\\.(${_PLANNER_CROSSCHECK_BYPASS_CITE_EXTENSIONS}):[0-9]+(-[0-9]+)?"

# Phrases that declare a guarded invariant over a named resource. Combined
# into a single grep -E alternation.
PLANNER_CROSSCHECK_BYPASS_GUARD_PHRASES=(
  "derived from"
  "never overwritten"
  "never hand-set"
  "hand-set"
  "only [a-z ]+ may"
  "must be audited"
  "must be locked"
  "always locked"
  "authoris(ed|ation)"
  "authoriz(ed|ation)"
)

# Path components that mark a file as a test file, not production source.
# A test that calls a guarded function (e.g. `result = await
# match_allowed_senders(...)`) matches the write-marker regex below — the
# call looks exactly like an assignment — but a test invoking the cited
# function is exercising the addressed site, not an undisclosed second
# writer of it. Observed live: this pattern alone produced 7 of 15
# BYPASS_PATH_UNADDRESSED findings against worker/tests/test_resolve.py.
PLANNER_CROSSCHECK_BYPASS_TEST_PATH_REGEX='(^|/)(tests?|__tests__|spec)/|(^|/)test_[^/]+\.(py|rb)$|[^/]+_test\.(py|go)$|\.(test|spec)\.(ts|tsx|js|jsx)$'

# Lines that look like a write or definition site — deliberately broad
# (function/route/assignment/SQL-mutation shapes across common languages)
# since the whole point is to catch a writer the spec author didn't expect.
PLANNER_CROSSCHECK_BYPASS_WRITE_MARKERS=(
  "^[[:space:]]*def "
  "^[[:space:]]*(export )?(async )?function "
  "^[[:space:]]*(export )?const [A-Za-z_][A-Za-z0-9_]*[[:space:]]*="
  "^[[:space:]]*[A-Za-z_][A-Za-z0-9_.]*[[:space:]]*="
  "UPDATE "
  "INSERT INTO"
  "\\.patch\\("
  "\\.post\\("
  "\\.put\\("
  "@app\\.route"
  "@router\\."
  "router\\.(patch|post|put)"
)

_planner_crosscheck_bypass_guard_regex() {
  local IFS='|'
  echo "${PLANNER_CROSSCHECK_BYPASS_GUARD_PHRASES[*]}"
}

_planner_crosscheck_bypass_write_regex() {
  local IFS='|'
  echo "${PLANNER_CROSSCHECK_BYPASS_WRITE_MARKERS[*]}"
}

# ── Part A: bypass sweep ─────────────────────────────────────────────────────

# Split a file into blank-line-delimited paragraphs.
# Usage: _planner_crosscheck_bypass_blocks <file>
# Output: blocks separated by a NUL byte.
_planner_crosscheck_bypass_blocks() {
  local file="$1"
  awk 'BEGIN{RS=""; ORS="\0"} {print}' "$file" 2>/dev/null
}

# List every `path:line` citation's bare path across every spec file — the
# set of files this initiative's specs already claim to address. A candidate
# writer under one of these paths is not a bypass; it's the addressed site.
# Usage: _planner_crosscheck_bypass_addressed_paths <specs_dir>
_planner_crosscheck_bypass_addressed_paths() {
  local specs_dir="$1"
  local spec_file
  for spec_file in "$specs_dir"/*.md; do
    [ -f "$spec_file" ] || continue
    grep -ohE "$PLANNER_CROSSCHECK_BYPASS_CITE_REGEX" "$spec_file" 2>/dev/null |
      sed -E 's/:[0-9]+(-[0-9]+)?$//'
  done | sort -u
}

# Search REPOS_ROOT for other file:line sites naming every one of the given
# terms on a line that looks like a write/definition site.
# Usage: _planner_crosscheck_bypass_search_writers <repos_root> <term1> [<term2> ...]
# Output: one "<file>:<line_num>:<line_text>" per hit.
_planner_crosscheck_bypass_search_writers() {
  local repos_root="$1"
  shift
  local -a terms=("$@")
  [ "${#terms[@]}" -eq 0 ] && return 0

  local write_regex
  write_regex=$(_planner_crosscheck_bypass_write_regex)

  local -a exclude_args=()
  local dir
  for dir in "${PLANNER_CROSSCHECK_BYPASS_EXCLUDE_DIRS[@]}"; do
    exclude_args+=(--exclude-dir="$dir")
  done

  local first_term="${terms[0]}"
  local file
  while IFS= read -r file; do
    [ -f "$file" ] || continue
    echo "$file" | grep -qiE "$PLANNER_CROSSCHECK_BYPASS_TEST_PATH_REGEX" && continue
    local line_num_and_line line_num line t all_present
    while IFS=: read -r line_num line; do
      [ -z "$line" ] && continue
      echo "$line" | grep -qiE "$write_regex" || continue

      all_present=1
      for t in "${terms[@]}"; do
        echo "$line" | grep -qiF "$t" || {
          all_present=0
          break
        }
      done
      [ "$all_present" -eq 1 ] && echo "${file}:${line_num}:${line}"
    done < <(grep -niF "$first_term" "$file" 2>/dev/null)
  done < <(grep -rlIF "${exclude_args[@]}" "$first_term" "$repos_root" 2>/dev/null)
}

# Run the bypass sweep across every spec in an initiative.
# Usage: planner_crosscheck_bypass_sweep <specs_dir> <repos_root>
# Returns: 0 if clean, 1 if any finding was reported.
planner_crosscheck_bypass_sweep() {
  local specs_dir="$1" repos_root="$2"
  local failures=0

  [ -d "$specs_dir" ] || return 0
  [ -d "$repos_root" ] || return 0

  local -a addressed_paths
  mapfile -t addressed_paths < <(_planner_crosscheck_bypass_addressed_paths "$specs_dir")

  local guard_regex
  guard_regex=$(_planner_crosscheck_bypass_guard_regex)

  local spec_file
  for spec_file in "$specs_dir"/*.md; do
    [ -f "$spec_file" ] || continue
    [ "$(basename "$spec_file")" = "INDEX.md" ] && continue

    local block
    while IFS= read -r -d '' block; do
      [ -z "$block" ] && continue
      echo "$block" | grep -qiE "$guard_regex" || continue

      local -a terms
      mapfile -t terms < <(echo "$block" | grep -oE '`[^`]+`' | sed -e 's/^`//' -e 's/`$//' | sort -u)
      [ "${#terms[@]}" -eq 0 ] && continue

      local -a block_citations
      mapfile -t block_citations < <(echo "$block" | grep -oE "$PLANNER_CROSSCHECK_BYPASS_CITE_REGEX" | sed -E 's/:[0-9]+(-[0-9]+)?$//' | sort -u)

      local hit
      while IFS= read -r hit; do
        [ -z "$hit" ] && continue
        local hit_file="${hit%%:*}"
        local rest="${hit#*:}"
        local hit_line="${rest%%:*}"
        local hit_text="${rest#*:}"

        local skip=0 af
        for af in "${addressed_paths[@]}" "${block_citations[@]}"; do
          [ -z "$af" ] && continue
          case "$hit_file" in
          *"$af") skip=1 ;;
          esac
          [ "$skip" -eq 1 ] && break
        done
        [ "$skip" -eq 1 ] && continue

        echo "planner-crosscheck-bypass: BYPASS_PATH_UNADDRESSED terms=[${terms[*]}] → ${hit_file}:${hit_line} (expected coverage from $(basename "$spec_file")) — $(echo "$hit_text" | cut -c1-160)"
        failures=$((failures + 1))
      done < <(_planner_crosscheck_bypass_search_writers "$repos_root" "${terms[@]}")

    done < <(_planner_crosscheck_bypass_blocks "$spec_file")
  done

  return $((failures > 0 ? 1 : 0))
}

# ── Part B: discovery gap escalation ────────────────────────────────────────

PLANNER_CROSSCHECK_BYPASS_GAP_PHRASES=(
  "quick-scan"
  "quick scan"
  "did not trace"
  "did not fully explore"
  "did not explore"
  "not explored"
  "not fully traced"
  "assumed"
)

_planner_crosscheck_bypass_gap_regex() {
  local IFS='|'
  echo "${PLANNER_CROSSCHECK_BYPASS_GAP_PHRASES[*]}"
}

# Extract a proposal.md's "## Out of Scope" section body (case-insensitive
# heading match; stops at the next heading of the same or higher level).
# Usage: _planner_crosscheck_bypass_out_of_scope_section <proposal_file>
_planner_crosscheck_bypass_out_of_scope_section() {
  local file="$1"
  [ -f "$file" ] || return 0
  awk '
    BEGIN{capture=0}
    { line=tolower($0) }
    line ~ /^#+[ \t]*out of scope/ { capture=1; next }
    /^#+[ \t]/ { if (capture) exit }
    capture { print }
  ' "$file" 2>/dev/null
}

# Check every discovery.md self-declared exploration gap has its substance
# recorded in proposal.md's Out of Scope section.
# Usage: planner_crosscheck_discovery_gap <discovery_file> <proposal_file>
# Returns: 0 if clean, 1 if any finding was reported.
planner_crosscheck_discovery_gap() {
  local discovery_file="$1" proposal_file="$2"
  local failures=0

  [ -f "$discovery_file" ] || return 0

  local out_of_scope=""
  [ -f "$proposal_file" ] && out_of_scope=$(_planner_crosscheck_bypass_out_of_scope_section "$proposal_file")

  # _planner_crosscheck_prop_presence_count re-reads its file argument once
  # per term — a process-substitution fd can only be read once, so the
  # Out of Scope text is written to a real temp file up front.
  local oos_file=""
  if [ -n "$out_of_scope" ]; then
    oos_file=$(mktemp)
    printf '%s\n' "$out_of_scope" >"$oos_file"
  fi

  local gap_regex
  gap_regex=$(_planner_crosscheck_bypass_gap_regex)

  local line_num line
  while IFS=: read -r line_num line; do
    [ -z "$line" ] && continue

    local -a terms
    mapfile -t terms < <(_planner_crosscheck_prop_terms "$line")
    [ "${#terms[@]}" -eq 0 ] && continue

    local resolved=0
    if [ -n "$oos_file" ]; then
      local threshold count
      threshold=$(_planner_crosscheck_prop_threshold "${#terms[@]}")
      count=$(_planner_crosscheck_prop_presence_count "$oos_file" "${terms[@]}")
      [ "$count" -ge "$threshold" ] && resolved=1
    fi

    if [ "$resolved" -eq 0 ]; then
      local snippet
      snippet=$(echo "$line" | cut -c1-140)
      echo "planner-crosscheck-bypass: DISCOVERY_GAP_UNRESOLVED ${discovery_file}:${line_num} → \"${snippet}\" not recorded in proposal.md Out of Scope"
      failures=$((failures + 1))
    fi
  done < <(grep -niE "$gap_regex" "$discovery_file" 2>/dev/null)

  [ -n "$oos_file" ] && rm -f "$oos_file"

  return $((failures > 0 ? 1 : 0))
}

# ── Public entry point ───────────────────────────────────────────────────────

# Run both checks for an initiative.
# Usage: planner_crosscheck_bypass <initiative_id>
# Returns: 0 if all clean, 1 if any check reported a finding.
planner_crosscheck_bypass() {
  local initiative_id="$1"
  local repos_root="${REPOS_ROOT:-${HOME}/repos}"
  local artifacts_dir="${repos_root}/.ticket-auto/initiatives/${initiative_id}/artifacts"

  if [ ! -d "$artifacts_dir" ]; then
    echo "planner-crosscheck-bypass: artifacts directory not found: $artifacts_dir" >&2
    return 1
  fi

  local specs_dir="${artifacts_dir}/specs"
  local discovery_file="${artifacts_dir}/discovery.md"
  local proposal_file="${artifacts_dir}/proposal.md"

  local failures=0
  planner_crosscheck_bypass_sweep "$specs_dir" "$repos_root" || failures=$((failures + 1))
  planner_crosscheck_discovery_gap "$discovery_file" "$proposal_file" || failures=$((failures + 1))

  return $((failures > 0 ? 1 : 0))
}
