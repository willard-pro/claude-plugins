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

# The structure regex's allowance for a dot (to admit dotted identifiers
# like `ClassificationResult.confidence`) also admits the planner's own
# artifact filenames (`intent.md`, `proposal.md`, `review.md`) and any
# source filename a spec backtick-cites for reference (`classify.py`,
# `test_triage_flow.py`) — neither is a code structure, and treating either
# as one produced live CONTRACT_MISMATCH false positives. Filter every
# common source/doc extension out wherever a candidate is accepted.
PLANNER_CROSSCHECK_CONTRACTS_NON_STRUCTURE_EXT_REGEX='\.(md|txt|py|ts|tsx|js|jsx|sh|json|yaml|yml|sql)$'

# Common builtin/exception/base-type names across this repo's languages — no
# spec ever introduces or contracts over `ValueError`, `Exception`,
# `Promise`, etc.; a backtick mention is always incidental prose, never a
# structure this initiative or a sibling defines the shape of.
PLANNER_CROSSCHECK_CONTRACTS_BUILTIN_DENYLIST=(
  ValueError TypeError KeyError AttributeError IndexError RuntimeError
  ImportError NotImplementedError StopIteration Exception BaseException
  FileNotFoundError PermissionError OSError IOError NotImplemented
  Error Promise Array Object Map Set String Number Boolean
  None True False null undefined
  console.log console.error console.warn console.info console.debug
)

# Usage: _planner_crosscheck_contracts_is_builtin <token>
# Returns: 0 (true) if <token> (parens stripped) is a known builtin/exception.
_planner_crosscheck_contracts_is_builtin() {
  local token="${1%()}"
  local d
  for d in "${PLANNER_CROSSCHECK_CONTRACTS_BUILTIN_DENYLIST[@]}"; do
    [ "$token" = "$d" ] && return 0
  done
  return 1
}

# A bare word with no dot, underscore, camelCase hump (lowercase directly
# followed by uppercase), or call-parens suffix, under 8 characters, reads as
# an ordinary English/DB-type word co-opted into backticks for emphasis
# ("source", "jsonb", "path") rather than a code structure. Anything
# carrying real identifier shape (`update_document_pg`, `getCurrentUser()`,
# `ClassificationResult.confidence`) passes through untouched.
# Usage: _planner_crosscheck_contracts_is_generic_word <token>
_planner_crosscheck_contracts_is_generic_word() {
  local token="$1"
  local bare="${token%()}"
  case "$bare" in
  *.* | *_*) return 1 ;;
  esac
  printf '%s' "$bare" | grep -qE '[a-z][A-Z]' && return 1
  [ "${#bare}" -lt 8 ]
}

# Directories excluded from the repo-definition search — same convention as
# planner-crosscheck-citations.sh's PLANNER_CROSSCHECK_EXCLUDE_DIRS.
PLANNER_CROSSCHECK_CONTRACTS_EXCLUDE_DIRS=("node_modules" ".venv" ".git" ".ticket-auto" ".claude" "ledgerly" "tickets")

# True if <symbol> already resolves to a real definition somewhere under
# <repos_root> — i.e. it's an existing structure this initiative's specs are
# referencing/reusing, not one they're newly defining. CONTRACT_MISMATCH
# exists to police a structure's shape as two sibling initiatives' specs
# each DEFINE it; a pre-existing shared helper multiple tickets merely CALL
# (`getCurrentUser()`, `update_document_pg`) will legitimately have
# different backtick terms co-mentioned at each call site — that's normal
# call-context variation, not a contract disagreement.
# Usage: _planner_crosscheck_contracts_exists_in_repo <repos_root> <symbol>
_planner_crosscheck_contracts_exists_in_repo() {
  local repos_root="$1" symbol="$2"
  local bare="${symbol%()}"
  local esc exclude_args=() dir
  esc=$(printf '%s' "$bare" | sed 's/[.[\*^$/]/\\&/g')
  for dir in "${PLANNER_CROSSCHECK_CONTRACTS_EXCLUDE_DIRS[@]}"; do
    exclude_args+=(--exclude-dir="$dir")
  done
  # Two shapes: a keyworded definition (function/def/const/class NAME), or a
  # bare top-level assignment (NAME = ...) — the latter is how Python module
  # globals and FastAPI dependency aliases are conventionally defined
  # (`require_service_token = Depends(_verify_service_token)`), and has no
  # keyword to anchor on. Exclude `==` so an equality check in an unrelated
  # line doesn't false-match.
  grep -rlE "${exclude_args[@]}" \
    "^[[:space:]]*(export[[:space:]]+)?(async[[:space:]]+)?(function|def|const|class)[[:space:]]+${esc}\\b|^[[:space:]]*${esc}[[:space:]]*=[^=]" \
    "$repos_root" >/dev/null 2>&1
}

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
  local f t
  [ -d "$specs_dir" ] || return 0
  for f in "$specs_dir"/*.md; do
    [ -f "$f" ] || continue
    [ "$(basename "$f")" = "INDEX.md" ] && continue
    grep -ohE '`[^`]+`' "$f" 2>/dev/null | sed -e 's/^`//' -e 's/`$//'
  done | grep -E "$PLANNER_CROSSCHECK_CONTRACTS_STRUCTURE_REGEX" |
    grep -viE "$PLANNER_CROSSCHECK_CONTRACTS_NON_STRUCTURE_EXT_REGEX" | sort -u |
    while IFS= read -r t; do
      [ -z "$t" ] && continue
      _planner_crosscheck_contracts_is_builtin "$t" && continue
      _planner_crosscheck_contracts_is_generic_word "$t" && continue
      echo "$t"
    done
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

# True if ANY paragraph in <file> mentioning literal backtick <structure> —
# not just the first one `_first_block_with_structure` compares shapes
# against — reads as deferential (see `_is_deferential` above). A spec
# often first mentions a shared structure while describing today's
# behavior (no deference language yet — that paragraph looks like a
# competing definition) and only states "left untouched"/"not by this
# ticket's own X" in a later paragraph. Confirmed live on VS-3:
# vs-3c's `documents.status` mention at the top of its Description reads
# as a plain description of existing behavior; the actual ownership
# disclaimer is in a paragraph further down.
# Usage: _planner_crosscheck_contracts_any_block_deferential <file> <structure>
_planner_crosscheck_contracts_any_block_deferential() {
  local file="$1" structure="$2" block
  while IFS= read -r -d '' block; do
    [ -z "$block" ] && continue
    if echo "$block" | grep -qF "\`${structure}\`" && _planner_crosscheck_contracts_is_deferential "$block"; then
      return 0
    fi
  done < <(_planner_crosscheck_bypass_blocks "$file")
  return 1
}

# ── Commodity-entity guard ───────────────────────────────────────────────────
#
# CONTRACT_MISMATCH and CONTRACT_CONSUMERS_UNNOTIFIED both treat "structure
# S is backtick-quoted in two spec files" as evidence those two files are
# bilateral contract partners over S. That assumption breaks for a widely-
# shared foundational entity (a DB table like `documents`, a cross-cutting
# log like `audit_log`): dozens of otherwise-unrelated tickets across many
# epics legitimately mention it, each about a different column or aspect,
# so "the other things mentioned nearby are disjoint" is the expected case,
# not evidence of a contradiction — a live run across 7 sibling initiatives
# produced 38 CONTRACT_MISMATCH findings on `documents`/`audit_log`/
# `entity_id`-class identifiers alone, none a real defect. A structure named
# in only a handful of files is far more likely to be an actual narrow,
# bilateral contract (e.g. `parent_document_id` between two specific
# tickets) worth comparing pairwise. Skip the pairwise checks once a
# structure's spread exceeds this threshold; CONTRACT_UNDEFINED (warn-level,
# no cross-initiative view) still runs over it regardless.
PLANNER_CROSSCHECK_CONTRACTS_COMMODITY_FILE_THRESHOLD=4

# Count distinct spec files (INDEX.md excluded), across every initiative
# under <initiatives_root>, that backtick-mention <structure>.
# Usage: _planner_crosscheck_contracts_structure_spread <initiatives_root> <structure>
_planner_crosscheck_contracts_structure_spread() {
  local initiatives_root="$1" structure="$2"
  local init_dir
  local -a hits=()
  for init_dir in "$initiatives_root"/*/; do
    [ -d "${init_dir}artifacts/specs" ] || continue
    while IFS= read -r f; do
      [ -n "$f" ] && hits+=("$f")
    done < <(_planner_crosscheck_contracts_files_with_structure "${init_dir}artifacts/specs" "$structure")
  done
  echo "${#hits[@]}"
}

# Usage: _planner_crosscheck_contracts_is_commodity <initiatives_root> <structure>
# Returns: 0 (true) if <structure>'s spread exceeds the commodity threshold.
_planner_crosscheck_contracts_is_commodity() {
  local initiatives_root="$1" structure="$2"
  local spread
  spread=$(_planner_crosscheck_contracts_structure_spread "$initiatives_root" "$structure")
  [ "$spread" -gt "$PLANNER_CROSSCHECK_CONTRACTS_COMMODITY_FILE_THRESHOLD" ]
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

# True if <block> reads as deferring to / crediting another spec's existing
# shape of a structure rather than independently (re)defining it — e.g. "not
# by this ticket's own field_reconciliation table", "modeled on ... 's
# conventions", "left completely untouched". Observed live on VS-3: a block
# that only credits or explicitly disclaims ownership of a structure still
# got compared against the defining spec's co-mentioned terms as if it were
# a second, competing definition, producing CONTRACT_MISMATCH on structures
# no spec actually contests the shape of (`console.log`, `documents.status`,
# `ClassificationResult.confidence`, `entity_required_artifacts`).
# Usage: _planner_crosscheck_contracts_is_deferential <block>
_planner_crosscheck_contracts_is_deferential() {
  local block="$1"
  printf '%s' "$block" | grep -qiE \
    "modeled on|'s conventions|not by this ticket|left (completely )?(untouched|unchanged)|leaves? .{0,40}(untouched|unchanged)"
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
      _planner_crosscheck_contracts_is_commodity "$initiatives_root" "$s" && continue
      _planner_crosscheck_contracts_exists_in_repo "$repos_root" "$s" && continue

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

          _planner_crosscheck_contracts_is_deferential "$blockA" && continue
          _planner_crosscheck_contracts_is_deferential "$blockB" && continue
          _planner_crosscheck_contracts_any_block_deferential "$fileA" "$s" && continue
          _planner_crosscheck_contracts_any_block_deferential "$fileB" "$s" && continue

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

# Words that, appearing shortly before a retire-phrase match, flip it from
# an assertion that something IS being retired to a guard/invariant
# asserting the opposite ("it is not silently replaced by ...", "no new
# entity-level dedupe is introduced" — a preservation guarantee, not a
# retirement). Observed live: this exact pattern produced false
# CONTRACT_CONSUMERS_UNNOTIFIED findings against `audit_log`/`entity_id`
# guard sentences that were reasserting an existing contract, not retiring
# one.
PLANNER_CROSSCHECK_CONTRACTS_NEGATION_REGEX='\b(not|never|isn.t|aren.t|doesn.t|won.t|without|continue(s)? to|unchanged|excludes? changing|no changes? to|preserved|existing.{0,20}treatment)\b'

# A structure re-mentioned this many times or more OUTSIDE the retiring
# block, elsewhere in the same spec, is being actively read/reused — the
# retire-phrase in this block is either about a different aspect of it or a
# neighboring guard sentence the block-level negation check can't see.
# Observed live: `preparation_metadata`/`unpreparable` referenced 7+ times
# each while a nearby retire-word misfired CONTRACT_CONSUMERS_UNNOTIFIED.
PLANNER_CROSSCHECK_CONTRACTS_REUSE_MENTION_THRESHOLD=3

# True if <text> contains at least one retire-phrase match that is NOT
# preceded within 5 words by a negator/preservation phrase — i.e. a genuine
# retirement claim, not a negated guard/invariant sentence. Factored out of
# _planner_crosscheck_contracts_genuine_retirement so the same windowed check
# can be applied at line granularity (see its caller below) as well as at
# whole-block granularity.
# Usage: _planner_crosscheck_contracts_text_has_genuine_retire_phrase <text>
_planner_crosscheck_contracts_text_has_genuine_retire_phrase() {
  local text="$1" flat ctx
  flat=$(echo "$text" | tr '\n' ' ')
  while IFS= read -r ctx; do
    [ -z "$ctx" ] && continue
    if ! echo "$ctx" | grep -qiE "$PLANNER_CROSSCHECK_CONTRACTS_NEGATION_REGEX"; then
      return 0
    fi
  done < <(echo "$flat" | grep -oiE "([A-Za-z0-9_']+[[:space:]]+){0,5}(${PLANNER_CROSSCHECK_CONTRACTS_RETIRE_REGEX})")
  return 1
}

# True if <block> contains at least one retire-phrase match that is NOT
# preceded within 5 words by a negator/preservation phrase — i.e. a genuine
# retirement claim, not a negated guard/invariant sentence — AND (when
# <file>/<structure> are given) <structure> isn't heavily re-referenced
# elsewhere in <file>, which is itself strong evidence of ongoing reuse
# rather than retirement.
# Usage: _planner_crosscheck_contracts_genuine_retirement <block> [<file> <structure>]
_planner_crosscheck_contracts_genuine_retirement() {
  local block="$1" file="${2:-}" structure="${3:-}"

  _planner_crosscheck_contracts_text_has_genuine_retire_phrase "$block" || return 1

  if [ -n "$file" ] && [ -n "$structure" ] && [ -f "$file" ]; then
    local total in_block outside
    total=$(grep -oF "\`${structure}\`" "$file" 2>/dev/null | wc -l | tr -d ' ')
    in_block=$(echo "$block" | grep -oF "\`${structure}\`" 2>/dev/null | wc -l | tr -d ' ')
    outside=$((total - in_block))
    [ "$outside" -ge "$PLANNER_CROSSCHECK_CONTRACTS_REUSE_MENTION_THRESHOLD" ] && return 1
  fi

  return 0
}

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

      # Candidate structures are drawn only from lines that themselves carry
      # a genuine retire-phrase — not every backtick-quoted name anywhere in
      # the paragraph. A block is a blank-line-delimited paragraph, which can
      # span several unrelated sentences (e.g. one bullet retiring stale copy
      # on `FORMAT_BADGES`, a neighboring bullet preserving `RecentCard`
      # unchanged); pulling structures from the whole block conflates the two
      # and flags the untouched one as silently retired. Observed live: this
      # over-association produced false CONTRACT_CONSUMERS_UNNOTIFIED on
      # `RecentCard`/`preparation_metadata` from a retirement claim that was
      # actually only about `FORMAT_BADGES`' copy text three lines away.
      local -a structures=()
      local block_line
      while IFS= read -r block_line; do
        _planner_crosscheck_contracts_text_has_genuine_retire_phrase "$block_line" || continue
        while IFS= read -r s; do
          [ -n "$s" ] && structures+=("$s")
        done < <(echo "$block_line" | grep -oE '`[^`]+`' | sed -e 's/^`//' -e 's/`$//')
      done <<<"$block"
      if [ "${#structures[@]}" -gt 0 ]; then
        mapfile -t structures < <(printf '%s\n' "${structures[@]}" | sort -u)
      fi
      [ "${#structures[@]}" -eq 0 ] && continue

      local -a acknowledged
      mapfile -t acknowledged < <(_planner_crosscheck_slugs_in_text "$block" "${all_slugs[@]}")

      local s
      for s in "${structures[@]}"; do
        echo "$s" | grep -qE "$PLANNER_CROSSCHECK_CONTRACTS_STRUCTURE_REGEX" || continue
        echo "$s" | grep -qiE "$PLANNER_CROSSCHECK_CONTRACTS_NON_STRUCTURE_EXT_REGEX" && continue
        _planner_crosscheck_contracts_is_builtin "$s" && continue
        _planner_crosscheck_contracts_is_generic_word "$s" && continue
        _planner_crosscheck_contracts_is_commodity "$initiatives_root" "$s" && continue
        _planner_crosscheck_contracts_genuine_retirement "$block" "$spec_file" "$s" || continue

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
