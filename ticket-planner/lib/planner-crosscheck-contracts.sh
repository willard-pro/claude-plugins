#!/usr/bin/env bash
# planner-crosscheck-contracts.sh — Cross-initiative contract shape checker.
#
# Part of the Crosscheck check family (issue #178). This is #175: every
# planner phase is scoped to one initiative, so nothing ever asks "does the
# structure this epic borrows from a sibling initiative's specs actually
# look the way this epic assumes it does?" The August 31 seven-initiative
# audit found two live instances: a dependent epic inheriting the WRONG one
# of two contradictory upstream shapes, and a dependent epic retiring a
# contract three other upstream tickets still read.
#
# WHY THIS IS A HEURISTIC, NOT TRUE CONTRACT DIFFING
# ---------------------------------------------------
# True structural diffing (parsing a dataclass, a SQL schema, a TypeScript
# interface) needs a real parser per language and a resolved symbol table —
# out of reach for a planner that only ever reads prose specs, not code.
# This script instead treats every backtick-quoted identifier as a
# "structure" (function name, column, dataclass field, config key — same
# convention planner-crosscheck-bypass.sh uses for guarded resources) and
# compares the *other* backtick-quoted identifiers co-mentioned with it in
# the same paragraph, plus a small fixed set of shape-descriptor phrase
# pairs ("per-field" vs "top-level"/"document-level" — the audit's actual
# contradiction). That is narrower than full shape validation, but it is
# bounded, deterministic, and catches the class of defect the issue
# describes without an LLM in the loop.
#
# Three checks, all requiring only artifacts already on disk:
#
#   planner_crosscheck_contract_undefined — a spec paragraph that declares a
#   structure "gains/adds fields for ..." in prose only (no backtick-quoted
#   field names anywhere else in the paragraph) leaves the field names
#   undefined for whoever reads them next. Code: CONTRACT_UNDEFINED.
#   Warn-level (see PLANNER_CROSSCHECK_WARN_CODES in planner-crosscheck.sh) —
#   an ambiguous upstream shape is a prompt for human judgment, not by
#   itself proof a mismatch happened. Needs no cross-initiative view.
#
#   planner_crosscheck_contract_mismatch — a structure named in both this
#   initiative's specs and a sibling initiative's specs, where the two
#   paragraphs' co-mentioned shape terms are disjoint, or where one
#   describes it as per-field and the other as top-level/document-level.
#   Code: CONTRACT_MISMATCH. Blocking.
#
#   planner_crosscheck_contract_consumers_unnotified — a spec paragraph that
#   retires/removes/deprecates/replaces a structure without naming (by
#   ticket slug) every other spec — in this initiative or a sibling — that
#   still mentions that structure. Code: CONTRACT_CONSUMERS_UNNOTIFIED.
#   Blocking.
#
# Usage:
#   planner_crosscheck_contracts <initiative_id>
#     Runs all three checks. Returns 0 if clean (or warn-only), 1 if any
#     blocking finding was reported.
#
# Sourceable library — no set -euo pipefail.

_PLANNER_CROSSCHECK_CONTRACTS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Reuses propagation.sh's known-slug helpers and bypass.sh's paragraph
# splitter rather than duplicating them.
if ! declare -f _planner_crosscheck_known_slugs >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  [ -f "${_PLANNER_CROSSCHECK_CONTRACTS_LIB_DIR}/planner-crosscheck-propagation.sh" ] &&
    source "${_PLANNER_CROSSCHECK_CONTRACTS_LIB_DIR}/planner-crosscheck-propagation.sh"
fi
if ! declare -f _planner_crosscheck_bypass_blocks >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  [ -f "${_PLANNER_CROSSCHECK_CONTRACTS_LIB_DIR}/planner-crosscheck-bypass.sh" ] &&
    source "${_PLANNER_CROSSCHECK_CONTRACTS_LIB_DIR}/planner-crosscheck-bypass.sh"
fi

# A backtick span counts as a "structure" candidate when it looks like a
# single code identifier (letters/digits/underscore/dot, optional trailing
# call parens) at least 3 characters long — filters out prose backtick
# quotes ("`must be locked`"-style guard phrases are multi-word and never
# match) without needing a language-aware parser.
PLANNER_CROSSCHECK_CONTRACTS_STRUCTURE_REGEX='^[A-Za-z_][A-Za-z0-9_.]{2,}(\(\))?$'

# ── Small array helpers ──────────────────────────────────────────────────────

# Usage: _planner_crosscheck_contracts_array_has <needle> <hay...>
_planner_crosscheck_contracts_array_has() {
  local needle="$1"
  shift
  local x
  for x in "$@"; do
    [ "$x" = "$needle" ] && return 0
  done
  return 1
}

# ── Cross-initiative discovery ──────────────────────────────────────────────

# List sibling initiative IDs (directories under <initiatives_root> that
# have an artifacts/specs directory), excluding <self_id>.
# Usage: _planner_crosscheck_contracts_sibling_ids <initiatives_root> <self_id>
_planner_crosscheck_contracts_sibling_ids() {
  local initiatives_root="$1" self_id="$2"
  local d base
  [ -d "$initiatives_root" ] || return 0
  for d in "$initiatives_root"/*/; do
    [ -d "$d" ] || continue
    base="$(basename "$d")"
    [ "$base" = "$self_id" ] && continue
    [ -d "${d}artifacts/specs" ] || continue
    echo "$base"
  done
}

# List distinct structure-candidate backtick identifiers across every spec
# file in <specs_dir> (case preserved — identifier case is meaningful).
# Usage: _planner_crosscheck_contracts_structures_in_dir <specs_dir>
_planner_crosscheck_contracts_structures_in_dir() {
  local specs_dir="$1"
  local f
  [ -d "$specs_dir" ] || return 0
  for f in "$specs_dir"/*.md; do
    [ -f "$f" ] || continue
    [ "$(basename "$f")" = "INDEX.md" ] && continue
    grep -ohE '`[^`]+`' "$f" 2>/dev/null | sed -e 's/^`//' -e 's/`$//'
  done | grep -E "$PLANNER_CROSSCHECK_CONTRACTS_STRUCTURE_REGEX" | sort -u
}

# List spec files in <specs_dir> whose text contains a literal backtick
# mention of <structure> (excludes INDEX.md).
# Usage: _planner_crosscheck_contracts_files_with_structure <specs_dir> <structure>
_planner_crosscheck_contracts_files_with_structure() {
  local specs_dir="$1" structure="$2"
  [ -d "$specs_dir" ] || return 0
  grep -lF "\`${structure}\`" "$specs_dir"/*.md 2>/dev/null | grep -v '/INDEX\.md$'
}

# Print the first blank-line-delimited paragraph in <file> that mentions a
# literal backtick <structure>. Returns 1 if no such paragraph exists.
# Usage: _planner_crosscheck_contracts_first_block_with_structure <file> <structure>
_planner_crosscheck_contracts_first_block_with_structure() {
  local file="$1" structure="$2" block
  while IFS= read -r -d '' block; do
    [ -z "$block" ] && continue
    if echo "$block" | grep -qF "\`${structure}\`"; then
      printf '%s' "$block"
      return 0
    fi
  done < <(_planner_crosscheck_bypass_blocks "$file")
  return 1
}

# ── Check A: undefined structure fields ──────────────────────────────────────

PLANNER_CROSSCHECK_CONTRACTS_UNDEF_REGEX='(gains?|adds?) (a )?fields?|new fields?'

# For every spec paragraph declaring a structure "gains/adds fields for ..."
# in prose only (no other backtick-quoted identifier anywhere in the
# paragraph besides the structure's own name), report CONTRACT_UNDEFINED.
# Usage: planner_crosscheck_contract_undefined <specs_dir>
# Returns: 0 if clean, 1 if any finding was reported.
planner_crosscheck_contract_undefined() {
  local specs_dir="$1"
  local failures=0
  [ -d "$specs_dir" ] || return 0

  local spec_file
  for spec_file in "$specs_dir"/*.md; do
    [ -f "$spec_file" ] || continue
    [ "$(basename "$spec_file")" = "INDEX.md" ] && continue

    local block
    while IFS= read -r -d '' block; do
      [ -z "$block" ] && continue
      echo "$block" | grep -qiE "$PLANNER_CROSSCHECK_CONTRACTS_UNDEF_REGEX" || continue

      local structure
      structure=$(echo "$block" | grep -oE '`[^`]+`' | head -1 | sed -e 's/^`//' -e 's/`$//')
      [ -z "$structure" ] && structure="(unnamed structure)"

      # Strip only the first backtick span (the structure's own name) —
      # if any backtick identifier survives, the fields ARE canonically
      # named somewhere in this paragraph and this is not a finding.
      local remainder
      remainder=$(echo "$block" | sed '0,/`[^`]*`/{s/`[^`]*`//}')
      echo "$remainder" | grep -qE '`[^`]+`' && continue

      local snippet
      snippet=$(echo "$block" | tr '\n' ' ' | cut -c1-160)
      echo "planner-crosscheck-contracts: CONTRACT_UNDEFINED ${spec_file} \`${structure}\` declares new fields without canonical names: \"${snippet}\""
      failures=$((failures + 1))
    done < <(_planner_crosscheck_bypass_blocks "$spec_file")
  done

  return $((failures > 0 ? 1 : 0))
}

# ── Check B: cross-initiative shape mismatch ────────────────────────────────

# Backtick-quoted terms co-mentioned with <structure> in <block>, lowercased
# and deduped, excluding <structure> itself and every <exclude...> token
# (known ticket slugs — a slug reference is not a shape term).
# Usage: _planner_crosscheck_contracts_shape_terms <block> <structure> [<exclude>...]
_planner_crosscheck_contracts_shape_terms() {
  local block="$1" structure="$2"
  shift 2
  local -a exclude=("$structure" "$@")
  local t skip e
  echo "$block" | grep -oE '`[^`]+`' | sed -e 's/^`//' -e 's/`$//' |
    while IFS= read -r t; do
      [ -z "$t" ] && continue
      skip=0
      for e in "${exclude[@]}"; do
        [ "$t" = "$e" ] && skip=1 && break
      done
      [ "$skip" -eq 0 ] && echo "$t" | tr '[:upper:]' '[:lower:]'
    done | sort -u
}

# Fixed shape-descriptor phrase pairs — the audit's actual contradiction
# ("return per-field confidence, not one document-level score" vs "a single
# top-level confidence key"). Prints a space-joined subset of
# {PER_FIELD, TOP_LEVEL} found in <block>.
# Usage: _planner_crosscheck_contracts_descriptor <block>
_planner_crosscheck_contracts_descriptor() {
  local block="$1"
  local lower
  lower=$(echo "$block" | tr '[:upper:]' '[:lower:]')
  local out=""
  case "$lower" in
  *"per-field"* | *"per field"*) out="PER_FIELD" ;;
  esac
  case "$lower" in
  *"top-level"* | *"top level"* | *"document-level"* | *"document level"*)
    out="${out:+${out} }TOP_LEVEL"
    ;;
  esac
  echo "$out"
}

# For every structure this initiative's specs share with a sibling
# initiative's specs, compare the co-mentioned shape terms (and the
# per-field/top-level descriptor pair). Report a disjoint or contradictory
# pair as CONTRACT_MISMATCH, quoting both sides.
# Usage: planner_crosscheck_contract_mismatch <self_id> <specs_dir> <repos_root>
# Returns: 0 if clean, 1 if any finding was reported.
planner_crosscheck_contract_mismatch() {
  local self_id="$1" specs_dir="$2" repos_root="$3"
  local failures=0
  [ -d "$specs_dir" ] || return 0

  local initiatives_root="${repos_root}/.ticket-auto/initiatives"
  [ -d "$initiatives_root" ] || return 0

  local -a self_slugs
  mapfile -t self_slugs < <(_planner_crosscheck_known_slugs "$specs_dir")

  local -a mine
  mapfile -t mine < <(_planner_crosscheck_contracts_structures_in_dir "$specs_dir")
  [ "${#mine[@]}" -eq 0 ] && return 0

  local sib_id
  while IFS= read -r sib_id; do
    [ -z "$sib_id" ] && continue
    local sib_specs="${initiatives_root}/${sib_id}/artifacts/specs"

    local -a sib_slugs
    mapfile -t sib_slugs < <(_planner_crosscheck_known_slugs "$sib_specs")

    local -a sib_structures
    mapfile -t sib_structures < <(_planner_crosscheck_contracts_structures_in_dir "$sib_specs")
    [ "${#sib_structures[@]}" -eq 0 ] && continue

    local s
    for s in "${mine[@]}"; do
      _planner_crosscheck_contracts_array_has "$s" "${sib_structures[@]}" || continue
      _planner_crosscheck_contracts_array_has "$s" "${self_slugs[@]}" && continue
      _planner_crosscheck_contracts_array_has "$s" "${sib_slugs[@]}" && continue

      local fileA
      while IFS= read -r fileA; do
        [ -z "$fileA" ] && continue
        local blockA
        blockA=$(_planner_crosscheck_contracts_first_block_with_structure "$fileA" "$s") || continue

        local fileB
        while IFS= read -r fileB; do
          [ -z "$fileB" ] && continue
          local blockB
          blockB=$(_planner_crosscheck_contracts_first_block_with_structure "$fileB" "$s") || continue

          local -a shapeA shapeB
          mapfile -t shapeA < <(_planner_crosscheck_contracts_shape_terms "$blockA" "$s" "${self_slugs[@]}" "${sib_slugs[@]}")
          mapfile -t shapeB < <(_planner_crosscheck_contracts_shape_terms "$blockB" "$s" "${self_slugs[@]}" "${sib_slugs[@]}")

          local descA descB
          descA=$(_planner_crosscheck_contracts_descriptor "$blockA")
          descB=$(_planner_crosscheck_contracts_descriptor "$blockB")

          local overlap=0 t
          if [ "${#shapeA[@]}" -gt 0 ] && [ "${#shapeB[@]}" -gt 0 ]; then
            for t in "${shapeA[@]}"; do
              _planner_crosscheck_contracts_array_has "$t" "${shapeB[@]}" && overlap=1 && break
            done
          fi

          local reason=""
          if [ "${#shapeA[@]}" -gt 0 ] && [ "${#shapeB[@]}" -gt 0 ] && [ "$overlap" -eq 0 ]; then
            reason="disjoint shape terms: $(basename "$fileA")=[${shapeA[*]}] vs $(basename "$fileB")=[${shapeB[*]}]"
          fi
          if { [[ "$descA" == *PER_FIELD* ]] && [[ "$descB" == *TOP_LEVEL* ]]; } ||
            { [[ "$descA" == *TOP_LEVEL* ]] && [[ "$descB" == *PER_FIELD* ]]; }; then
            [ -n "$reason" ] && reason="${reason}; "
            reason="${reason}shape-descriptor conflict: $(basename "$fileA")=[${descA}] vs $(basename "$fileB")=[${descB}]"
          fi

          if [ -n "$reason" ]; then
            local snipA snipB
            snipA=$(echo "$blockA" | tr '\n' ' ' | cut -c1-160)
            snipB=$(echo "$blockB" | tr '\n' ' ' | cut -c1-160)
            echo "planner-crosscheck-contracts: CONTRACT_MISMATCH \`${s}\` borrowed by ${self_id}/$(basename "$fileA") from ${sib_id}/$(basename "$fileB") — ${reason} | ${self_id}: \"${snipA}\" | ${sib_id}: \"${snipB}\""
            failures=$((failures + 1))
          fi
        done < <(_planner_crosscheck_contracts_files_with_structure "$sib_specs" "$s")
      done < <(_planner_crosscheck_contracts_files_with_structure "$specs_dir" "$s")
    done
  done < <(_planner_crosscheck_contracts_sibling_ids "$initiatives_root" "$self_id")

  return $((failures > 0 ? 1 : 0))
}

# ── Check C: consumers unnotified ───────────────────────────────────────────

PLANNER_CROSSCHECK_CONTRACTS_RETIRE_REGEX='retires?|retired|removes?|removed|deprecat|no longer|replaces?'

# For every spec paragraph in this initiative that retires/removes/
# deprecates/replaces a structure, check every OTHER spec file (in this
# initiative or a sibling) that also mentions that structure was actually
# named (by ticket slug) in the retiring paragraph. Report every silent
# consumer as CONTRACT_CONSUMERS_UNNOTIFIED.
# Usage: planner_crosscheck_contract_consumers_unnotified <self_id> <specs_dir> <repos_root>
# Returns: 0 if clean, 1 if any finding was reported.
planner_crosscheck_contract_consumers_unnotified() {
  local self_id="$1" specs_dir="$2" repos_root="$3"
  local failures=0
  [ -d "$specs_dir" ] || return 0

  local initiatives_root="${repos_root}/.ticket-auto/initiatives"

  local -a all_slugs
  mapfile -t all_slugs < <(_planner_crosscheck_known_slugs "$specs_dir")

  local -a other_spec_dirs=("$specs_dir")
  if [ -d "$initiatives_root" ]; then
    local sib_id sib_specs
    while IFS= read -r sib_id; do
      [ -z "$sib_id" ] && continue
      sib_specs="${initiatives_root}/${sib_id}/artifacts/specs"
      other_spec_dirs+=("$sib_specs")
      local -a sib_slugs
      mapfile -t sib_slugs < <(_planner_crosscheck_known_slugs "$sib_specs")
      all_slugs+=("${sib_slugs[@]}")
    done < <(_planner_crosscheck_contracts_sibling_ids "$initiatives_root" "$self_id")
  fi

  local spec_file
  for spec_file in "$specs_dir"/*.md; do
    [ -f "$spec_file" ] || continue
    [ "$(basename "$spec_file")" = "INDEX.md" ] && continue

    local block
    while IFS= read -r -d '' block; do
      [ -z "$block" ] && continue
      echo "$block" | grep -qiE "$PLANNER_CROSSCHECK_CONTRACTS_RETIRE_REGEX" || continue

      local -a structures
      mapfile -t structures < <(echo "$block" | grep -oE '`[^`]+`' | sed -e 's/^`//' -e 's/`$//' | sort -u)
      [ "${#structures[@]}" -eq 0 ] && continue

      local -a acknowledged
      mapfile -t acknowledged < <(_planner_crosscheck_slugs_in_text "$block" "${all_slugs[@]}")

      local s
      for s in "${structures[@]}"; do
        echo "$s" | grep -qE "$PLANNER_CROSSCHECK_CONTRACTS_STRUCTURE_REGEX" || continue

        local dir
        for dir in "${other_spec_dirs[@]}"; do
          local consumer_file
          while IFS= read -r consumer_file; do
            [ -z "$consumer_file" ] && continue
            [ "$consumer_file" = "$spec_file" ] && continue

            local consumer_slug
            consumer_slug="$(basename "$consumer_file" .md)"
            _planner_crosscheck_contracts_array_has "$consumer_slug" "${acknowledged[@]}" && continue

            echo "planner-crosscheck-contracts: CONTRACT_CONSUMERS_UNNOTIFIED \`${s}\` retired in $(basename "$spec_file") without notifying consumer ${consumer_slug} (${consumer_file})"
            failures=$((failures + 1))
          done < <(_planner_crosscheck_contracts_files_with_structure "$dir" "$s")
        done
      done
    done < <(_planner_crosscheck_bypass_blocks "$spec_file")
  done

  return $((failures > 0 ? 1 : 0))
}

# ── Public entry point ───────────────────────────────────────────────────────

# Run all three contract checks for an initiative.
# Usage: planner_crosscheck_contracts <initiative_id>
# Returns: 0 if all clean, 1 if any check reported a finding.
planner_crosscheck_contracts() {
  local initiative_id="$1"
  local repos_root="${REPOS_ROOT:-${HOME}/repos}"
  local artifacts_dir="${repos_root}/.ticket-auto/initiatives/${initiative_id}/artifacts"

  if [ ! -d "$artifacts_dir" ]; then
    echo "planner-crosscheck-contracts: artifacts directory not found: $artifacts_dir" >&2
    return 1
  fi

  local specs_dir="${artifacts_dir}/specs"
  local failures=0

  planner_crosscheck_contract_undefined "$specs_dir" || failures=$((failures + 1))
  planner_crosscheck_contract_mismatch "$initiative_id" "$specs_dir" "$repos_root" || failures=$((failures + 1))
  planner_crosscheck_contract_consumers_unnotified "$initiative_id" "$specs_dir" "$repos_root" || failures=$((failures + 1))

  return $((failures > 0 ? 1 : 0))
}
