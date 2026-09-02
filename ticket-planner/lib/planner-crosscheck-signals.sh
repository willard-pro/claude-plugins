#!/usr/bin/env bash
# planner-crosscheck-signals.sh — Uniform per-ticket Signals block detector.
#
# Part of the Crosscheck check family (issue #178). This is #220: Specify
# writes one `## Signals` JSON block per ticket spec (services_identified,
# symbols_resolved, prior_art_found, complexity, exploration_depth) — the raw
# inputs `planner_confidence_derive` (`planner-context-gen.sh`) turns into a
# per-ticket confidence score. On VS-2 (INIT-1788079196-3438) all 8 of the
# initiative's spec files carried the same byte-identical Signals block —
# the initiative-level exploration signals, copy-pasted instead of computed
# per ticket — which would have produced the exact same 0.85 confidence for
# every ticket, from a schema migration to a from-scratch FE review UI.
# Ticket Gen's own agent happened to notice and halted rather than create
# tickets with fake variance; nothing in Crosscheck, which runs before Ticket
# Gen and is supposed to be the deterministic gate, caught it.
#
# Two groupings, checked in order so a file set already reported as
# byte-identical isn't reported again as merely near-identical:
#
#   1. Byte-identical — the whole Signals JSON block (key order and
#      whitespace normalized via `jq -S -c`) matches across 2+ specs.
#   2. Near-identical — services_identified, symbols_resolved, and
#      prior_art_found (the three fields the issue calls out — the ones a
#      genuine per-ticket exploration would vary) match across 2+ specs not
#      already reported in (1). The all-zero/false combination is excluded:
#      it is the legitimate default for a handful of genuinely trivial
#      tickets Discovery found nothing new for, not evidence of copy-paste.
#
# Code: SIGNALS_UNIFORM. Blocking (not in PLANNER_CROSSCHECK_WARN_CODES in
# planner-crosscheck.sh) — this is the same class of defect the citation
# linter blocks on: an artifact silently wrong about a load-bearing planner
# contract, not a matter for human judgment.
#
# Usage:
#   planner_crosscheck_signals <initiative_id>
#     Returns: 0 if clean, 1 if any finding was reported.
#
# Sourceable library — no set -euo pipefail.

# Extract the Signals JSON block from <spec_file>, canonicalized (sorted
# keys, compact) so two blocks that differ only in key order or whitespace
# still compare equal. Empty output if the block is missing or unparseable.
# Usage: _planner_crosscheck_signals_extract <spec_file>
_planner_crosscheck_signals_extract() {
  local spec_file="$1"
  local raw
  raw=$(sed -n '/```json/,/```/p' "$spec_file" 2>/dev/null | sed '1d;$d')
  [ -z "$raw" ] && return 1
  echo "$raw" | jq -S -c . 2>/dev/null
}

# The three-field near-identical key from an already-canonicalized Signals
# JSON blob. Missing fields default the same way planner_confidence_derive
# does, so a spec that omits a field still groups with one that states the
# same default explicitly.
# Usage: _planner_crosscheck_signals_key <canonical_json>
_planner_crosscheck_signals_key() {
  local json="$1"
  echo "$json" | jq -c '{
    services_identified: (.services_identified // 0),
    symbols_resolved: (.symbols_resolved // 0),
    prior_art_found: (.prior_art_found // false)
  }' 2>/dev/null
}

# True if <key> (as produced by _planner_crosscheck_signals_key) is the
# all-zero/false default — legitimately common for trivial tickets, not
# evidence of copy-paste on its own.
# Usage: _planner_crosscheck_signals_is_trivial_key <key>
_planner_crosscheck_signals_is_trivial_key() {
  [ "$1" = '{"services_identified":0,"symbols_resolved":0,"prior_art_found":false}' ]
}

# For an initiative's spec files, report every group of 2+ specs whose
# Signals blocks are byte-identical (or near-identical on the three fields
# above) as SIGNALS_UNIFORM.
# Usage: planner_crosscheck_signals <initiative_id>
# Returns: 0 if clean, 1 if any finding was reported.
planner_crosscheck_signals() {
  local initiative_id="$1"
  local repos_root="${REPOS_ROOT:-${HOME}/repos}"
  local specs_dir="${repos_root}/.ticket-auto/initiatives/${initiative_id}/artifacts/specs"
  [ -d "$specs_dir" ] || return 0

  declare -A _sig_full_files=()
  declare -A _sig_key_files=()
  declare -A _sig_flagged=()

  local spec_file base json key
  for spec_file in "$specs_dir"/*.md; do
    [ -f "$spec_file" ] || continue
    base="$(basename "$spec_file")"
    [ "$base" = "INDEX.md" ] && continue

    json=$(_planner_crosscheck_signals_extract "$spec_file") || continue
    [ -z "$json" ] && continue

    _sig_full_files["$json"]="${_sig_full_files[$json]:+${_sig_full_files[$json]} }${base}"

    key=$(_planner_crosscheck_signals_key "$json")
    [ -z "$key" ] && continue
    _sig_key_files["$key"]="${_sig_key_files[$key]:+${_sig_key_files[$key]} }${base}"
  done

  local -a out_lines=()
  local group files count

  for group in "${!_sig_full_files[@]}"; do
    files="${_sig_full_files[$group]}"
    count=$(echo "$files" | wc -w | tr -d ' ')
    [ "$count" -lt 2 ] && continue
    files=$(echo "$files" | tr ' ' '\n' | sort | tr '\n' ' ')
    files="${files% }"
    out_lines+=("planner-crosscheck-signals: SIGNALS_UNIFORM ${count} specs share byte-identical Signals JSON: ${files} — ${group}")
    local f
    for f in $files; do _sig_flagged["$f"]=1; done
  done

  for group in "${!_sig_key_files[@]}"; do
    _planner_crosscheck_signals_is_trivial_key "$group" && continue

    local -a remaining=()
    local f
    for f in ${_sig_key_files[$group]}; do
      [ -n "${_sig_flagged[$f]:-}" ] && continue
      remaining+=("$f")
    done
    [ "${#remaining[@]}" -lt 2 ] && continue

    files=$(printf '%s\n' "${remaining[@]}" | sort | tr '\n' ' ')
    files="${files% }"
    out_lines+=("planner-crosscheck-signals: SIGNALS_UNIFORM ${#remaining[@]} specs share near-identical Signals (services_identified/symbols_resolved/prior_art_found): ${files} — ${group}")
  done

  [ "${#out_lines[@]}" -eq 0 ] && return 0

  printf '%s\n' "${out_lines[@]}" | sort
  return 1
}
