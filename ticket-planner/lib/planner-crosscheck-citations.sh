#!/usr/bin/env bash
# planner-crosscheck-citations.sh — Deterministic citation + precedent linter.
#
# Part of the Crosscheck check family (see docs/github issue #178). This is
# Check A only: does NOT require an LLM, a network call, or a Linear API call.
#
# Specs (and proposal.md / consensus.md) cite `path:line` references and claim
# code "already exists" or "mirrors" some other symbol. Nothing before this
# script verified either claim against the live repo — the planner's other
# gates (planner-spec-validate.sh) check structure, not truth.
#
# Two checks:
#
#   Check A — citation resolution. Every `path:line` / `path:line-line` token,
#   plus every `symbol:path:line` entry in a spec's Signals.TargetSymbols
#   field, must resolve: the file must exist under REPOS_ROOT, the cited
#   line(s) must be within the file's length, and — for TargetSymbols entries,
#   which carry a symbol name — the symbol must appear within
#   PLANNER_CROSSCHECK_SYMBOL_PROXIMITY lines of the cited line.
#
#   Check B — precedent grep. Prose claims of the form "mirrors the existing
#   `X`", "the existing `X`", "reuses `X`", "following the `X` pattern" name a
#   symbol that must actually exist somewhere in REPOS_ROOT. Zero matches is a
#   defect — the audit's canonical example (`needsEdit`) had zero matches
#   repo-wide.
#
# Usage:
#   planner_crosscheck_citations <initiative_id>
#     Checks every artifacts/specs/*.md file plus proposal.md and
#     consensus.md. Returns 0 if all pass, 1 if any check fails.
#
#   planner_crosscheck_citations_one <file>
#     Checks a single file. Returns 0 if clean, 1 if it has findings.
#     Findings are printed to stdout as:
#       planner-crosscheck-citations: <CODE> <file>:<line> → <detail>
#
# Sourceable library — no set -euo pipefail.

# ── Config ──────────────────────────────────────────────────────────────────

# Extensions treated as citable source — a `path:line` token only counts as a
# citation if the path ends in one of these. Keeps timestamps ("10:30") and
# URLs ("http://host:8080") from ever matching.
PLANNER_CROSSCHECK_CITE_EXT_LIST=(ts tsx js jsx py sql json sh go rb java md yml yaml)

# Same list, pre-joined as a regex alternation for grep -E citation scanning.
PLANNER_CROSSCHECK_CITE_EXTENSIONS=$(
  IFS='|'
  echo "${PLANNER_CROSSCHECK_CITE_EXT_LIST[*]}"
)

# Directory components excluded from both file resolution and precedent grep.
# .ticket-auto is the planner's own working directory (specs, proposals) —
# searching it back would let a spec's own prose "resolve" its own claim.
# .claude is excluded for the same reason planner-crosscheck-bypass.sh
# excludes it: sibling repos under REPOS_ROOT (e.g. dotfiles) keep raw
# Claude Code session transcripts under .claude/projects/**/tool-results/,
# which can quote real code and false-positive-resolve a citation or
# precedent search against cached prose instead of the actual codebase.
PLANNER_CROSSCHECK_EXCLUDE_DIRS=("node_modules" ".venv" ".git" ".ticket-auto" ".claude" "tickets")

# How many lines on either side of a cited line a TargetSymbols symbol name
# may appear in and still count as resolved (issue #172 suggests N=5).
PLANNER_CROSSCHECK_SYMBOL_PROXIMITY=5

_PLANNER_CROSSCHECK_CITATIONS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Resolving against a Discovery-pinned ref (#217) is optional — a bare
# planner_crosscheck_citations_one call (e.g. from a test, or a caller that
# only has a file + repos_root) still works with no repo-ref lib available.
if ! declare -f planner_crosscheck_repo_ref_setup >/dev/null 2>&1; then
  [ -f "${_PLANNER_CROSSCHECK_CITATIONS_LIB_DIR}/planner-crosscheck-repo-ref.sh" ] &&
    source "${_PLANNER_CROSSCHECK_CITATIONS_LIB_DIR}/planner-crosscheck-repo-ref.sh"
fi

# ── Internal helpers ────────────────────────────────────────────────────────

# Build the `find`/`grep` prune arguments for PLANNER_CROSSCHECK_EXCLUDE_DIRS.
# Usage: eval "$(_planner_crosscheck_find_prune_args)"; find "$root" "${PRUNE_ARGS[@]}" ...
_planner_crosscheck_find_prune_expr() {
  local dir first=1
  printf '('
  for dir in "${PLANNER_CROSSCHECK_EXCLUDE_DIRS[@]}"; do
    if [ "$first" -eq 1 ]; then
      first=0
    else
      printf ' -o'
    fi
    printf ' -path */%s/*' "$dir"
  done
  printf ' )'
}

# Resolve a cited relative path under REPOS_ROOT.
# Usage: _planner_crosscheck_resolve_path <repos_root> <relative_path>
# Output: absolute path on stdout, or empty if not found.
_planner_crosscheck_resolve_path() {
  local repos_root="$1" rel_path="$2"
  local prune_expr
  prune_expr=$(_planner_crosscheck_find_prune_expr)

  # A citation is sometimes written with a leading slash (e.g.
  # "/upload/UploadPageClient.tsx", shorthand for an app-router path).
  # Left in place, "*/${rel_path}" requires a literal double slash in the
  # real path, which never occurs — every such citation fails to resolve
  # even when the file exists. Strip leading slashes so the glob degrades
  # to the same single-slash match a repo-relative citation gets.
  rel_path="${rel_path#"${rel_path%%[!/]*}"}"

  # `find -path` treats `[` `]` as a glob character class, not literal
  # brackets — a genuinely-existing Next.js dynamic-route file like
  # `app/api/account/entities/[entityId]/route.ts` then never matches its
  # own real path (the class `[entityId]` matches one of e/n/t/i/y/d, not
  # the six-character literal). Escape them so the glob treats the segment
  # as literal text, same as any other path component.
  local escaped_rel_path
  escaped_rel_path=$(printf '%s' "$rel_path" | sed 's/\[/\\[/g; s/\]/\\]/g')

  # shellcheck disable=SC2086
  find "$repos_root" $prune_expr -prune -o -type f -path "*/${escaped_rel_path}" -print 2>/dev/null | head -1
}

# Search REPOS_ROOT for a whole-word occurrence of an identifier, excluding
# the planner's own working directory.
# Usage: _planner_crosscheck_precedent_search <repos_root> <identifier>
# Returns: 0 if found at least once, 1 if zero matches.
_planner_crosscheck_precedent_search() {
  local repos_root="$1" identifier="$2"
  local exclude_args=() include_args=()
  local dir ext

  for dir in "${PLANNER_CROSSCHECK_EXCLUDE_DIRS[@]}"; do
    exclude_args+=(--exclude-dir="$dir")
  done
  for ext in "${PLANNER_CROSSCHECK_CITE_EXT_LIST[@]}"; do
    include_args+=(--include="*.${ext}")
  done

  grep -rlIE "${exclude_args[@]}" "${include_args[@]}" \
    "\\<${identifier}\\>" "$repos_root" >/dev/null 2>&1
}

# Split a `path:line`, `path:line-line2`, or `path:~line` (approximate,
# author-flagged-uncertain) token into path/start/end/approximate.
# Usage: _planner_crosscheck_split_token <token>
# Output (stdout, 4 lines): path, start_line, end_line, approximate (0/1)
_planner_crosscheck_split_token() {
  local token="$1"
  local line_part path_part start_line end_line approximate=0

  line_part=$(echo "$token" | grep -oE ':~?[0-9]+(-[0-9]+)?$')
  path_part="${token%"$line_part"}"
  line_part="${line_part#:}"

  if [[ "$line_part" == \~* ]]; then
    approximate=1
    line_part="${line_part#\~}"
  fi

  if [[ "$line_part" == *-* ]]; then
    start_line="${line_part%%-*}"
    end_line="${line_part#*-}"
  else
    start_line="$line_part"
    end_line="$line_part"
  fi

  printf '%s\n%s\n%s\n%s\n' "$path_part" "$start_line" "$end_line" "$approximate"
}

# A TargetSymbols entry's name half sometimes carries a human-readable
# annotation the spec author appended for clarity — "update_document_pg
# (call site)", "batch-upload page (new)", "Sidebar nav entry" (no real
# identifier at all). Literal-matching that whole string against source
# text can never succeed; only the bare identifier can. `(new)` gets
# special handling in the caller (it marks a file this ticket will create,
# not one that should already exist) — strip it along with any other
# parenthetical here so what remains is just the identifier to search for.
# Usage: _planner_crosscheck_strip_symbol_annotation <symbol>
_planner_crosscheck_strip_symbol_annotation() {
  echo "$1" | sed -E 's/[[:space:]]*\([^)]*\)[[:space:]]*$//'
}

# True if <symbol>'s annotation marks it as a file/route/endpoint this ticket
# will create, not one that should already exist under REPOS_ROOT. Covers the
# exact "(new)" suffix as well as looser author phrasing carrying the same
# intent — "(new column, from 5.1)", "new route: POST /split/confirm".
# Usage: _planner_crosscheck_symbol_marked_new <symbol>
_planner_crosscheck_symbol_marked_new() {
  local symbol="$1"
  echo "$symbol" | grep -qiE '\([[:space:]]*new\b[^)]*\)[[:space:]]*$' && return 0
  # By the time this is called, the caller has already split the TargetSymbols
  # entry on its first ':' into symbol/token — the "new route: <path>" prefix's
  # own colon is gone from $symbol, so the trailing ':' this regex used to
  # require can never match. Anchor on the end of string instead.
  echo "$symbol" | grep -qiE '^[[:space:]]*new[[:space:]]+(route|endpoint|file)[[:space:]]*$' && return 0
  return 1
}

# Definition-line patterns tried, in order, against the whole resolved file
# when the symbol isn't found within PLANNER_CROSSCHECK_SYMBOL_PROXIMITY
# lines of the cited range. A citation naming a function and a range deep
# inside its body (e.g. "uploadFile:UploadPageClient.tsx:363-374" where
# `uploadFile` is defined at line 304) is a valid, common citation shape
# the proximity check alone can't validate — it only looks near the cited
# line, not back to the enclosing definition. Confirmed live against three
# false positives (`uploadFile` x2, `POST`) before adding this.
# Usage: _planner_crosscheck_find_definition_line <file> <symbol>
# Output: the 1-based line number of the first match, or empty.
# True if <symbol> is literally one of <path>'s `/`-delimited directory
# segments (case-insensitive) — a route file named by its own feature/
# report-type folder (`app/api/professional/vat/route.ts`,
# `.../offshore/route.ts`, `.../cosec/route.ts`) has no top-level export
# matching that name (the real export is `GET`/`POST`/etc), so a
# TargetSymbols entry using the folder name as the "symbol" is a route
# label, not a code identifier, the same class of false positive as a
# hyphenated label — just single-worded so `[[ "$symbol" != *-* ]]` alone
# doesn't catch it. Confirmed live on VS-3 (`vat`, `offshore`, `cosec`):
# each citation's line is generic boilerplate shared across all these
# routes, not a definition site for the label.
# Usage: _planner_crosscheck_symbol_is_own_path_segment <symbol> <path>
_planner_crosscheck_symbol_is_own_path_segment() {
  local symbol_lc path="$2" seg
  symbol_lc=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  IFS='/' read -ra segs <<<"$path"
  for seg in "${segs[@]}"; do
    [ "$(printf '%s' "$seg" | tr '[:upper:]' '[:lower:]')" = "$symbol_lc" ] && return 0
  done
  return 1
}

_planner_crosscheck_find_definition_line() {
  local file="$1" symbol="$2"
  local esc
  # A symbol cited with call-parens ("check_llm_allowed()") must have them
  # stripped before building the regex below: a definition line never has a
  # trailing "()" for the closing `\b` anchor to land on (there's a space or
  # `->` after the real ")"), so leaving them in either no-ops past an empty
  # regex group (GNU grep) or errors outright ("empty (sub)expression" —
  # this environment's `grep` shells out to `ugrep -G -E`, confirmed live)
  # — either way, every compound multi-range citation naming a "foo()"-style
  # symbol false-flagged CITATION_SYMBOL_MISMATCH. Confirmed live on VS-6
  # (`check_llm_allowed()/record_llm_usage():worker/llm/guard.py:58-87,89-115`).
  symbol="${symbol%%(*}"
  esc=$(printf '%s' "$symbol" | sed 's/[.[\*^$/]/\\&/g')
  # `export default function X` — React's standard component-export form —
  # doesn't match without the optional `default` here. Confirmed live on
  # VS-3: every "component cited N lines into its own body" false positive
  # (DocumentPreviewPanel, ProvisionalTaxView, …) was this, not a bad
  # citation — each file genuinely defines the symbol via `export default
  # function`, just further above the cited line than the plain
  # `export function` form this regex originally only recognized.
  grep -nE "^[[:space:]]*(export[[:space:]]+)?(default[[:space:]]+)?(async[[:space:]]+)?(function|def|const|class)[[:space:]]+${esc}\\b" "$file" 2>/dev/null |
    head -1 | cut -d: -f1
}

# Resolve + range-check one citation, optionally checking a symbol's
# proximity to the cited line. Prints a finding line on failure.
# Usage: _planner_crosscheck_check_citation <repos_root> <spec_file> <spec_line> <token> [<symbol>]
# Returns: 0 if resolved cleanly, 1 otherwise.
_planner_crosscheck_check_citation() {
  local repos_root="$1" spec_file="$2" spec_line="$3" token="$4" symbol="${5:-}"
  local path_part start_line end_line resolved total_lines approximate
  local -a token_parts
  local marked_new=0

  if [ -n "$symbol" ] && _planner_crosscheck_symbol_marked_new "$symbol"; then
    marked_new=1
    symbol=$(_planner_crosscheck_strip_symbol_annotation "$symbol")
  fi

  mapfile -t token_parts < <(_planner_crosscheck_split_token "$token")
  path_part="${token_parts[0]}"
  start_line="${token_parts[1]}"
  end_line="${token_parts[2]}"
  approximate="${token_parts[3]:-0}"

  # A bare `path:line` TargetSymbols entry (no `Name:` prefix — see the
  # caller) sometimes glues the HTTP method directly onto the path instead
  # of using it as a separate Name field ("PATCH /api/upload/[doc_id]/
  # route.ts:11-120" rather than "PATCH:/api/upload/...:11-120"). Left in
  # place, that space-separated verb makes the whole path_part unresolvable
  # even though the file exists. Strip it — it carries no information
  # `resolve_path` needs. Confirmed live on VS-4 (exc-2/exc-5/exc-7).
  path_part=$(echo "$path_part" | sed -E 's/^(GET|POST|PUT|PATCH|DELETE)[[:space:]]+//')

  resolved=$(_planner_crosscheck_resolve_path "$repos_root" "$path_part")
  if [ -z "$resolved" ]; then
    [ "$marked_new" -eq 1 ] && return 0
    echo "planner-crosscheck-citations: CITATION_UNRESOLVED ${spec_file}:${spec_line} → ${token} (no file under REPOS_ROOT matches '${path_part}')"
    return 1
  fi

  # The file already exists even though the spec called it "(new)" — no
  # longer an unresolved-path question, fall through to the normal checks
  # (a stale "(new)" tag on a file the ticket ended up not creating fresh
  # is not this check's concern).

  # An approximate ("~line") citation is the author's own flag that the line
  # number is unverified — file/symbol existence still matters, but the
  # precise line it points at does not, so both the range check and the
  # proximity check below are skipped for it.
  total_lines=$(wc -l <"$resolved" | tr -d ' ')
  if [ "$approximate" -ne 1 ] && [ -n "$end_line" ] && [ "$end_line" -gt "$total_lines" ] 2>/dev/null; then
    echo "planner-crosscheck-citations: CITATION_LINE_OUT_OF_RANGE ${spec_file}:${spec_line} → ${token} (${resolved} has ${total_lines} lines)"
    return 1
  fi

  # No line number in the citation at all (a bare `Name:path` entry) — there
  # is nothing to anchor a proximity check to; a blank start/end previously
  # defaulted to lines 1-5, which fails for any real symbol. File existence
  # is all such a citation actually claims.
  # A hyphenated TargetSymbols name (`afs-export`, `tax-pack-export`) is a
  # human route/feature label, not a code identifier — JS/TS/Python
  # identifiers never contain `-`, so it can never literally appear in the
  # cited source regardless of how the file is written. Confirmed live on
  # VS-3: seven such labels for API route files whose real exports are
  # `GET`/`POST`/etc, not the label. File existence and the line-range
  # check above already validated the citation; skip the symbol-proximity
  # check rather than flag a mismatch no fix to the source or the spec's
  # wording could ever resolve.
  # A Name field of the form "POST /triage" or "PATCH /api/upload" is an
  # HTTP-method-plus-route annotation, not a literal source-code identifier
  # — FastAPI/Next.js routes are declared via decorators/exports (`@app.
  # post("/triage")`, `export function POST`), so the literal string
  # "POST /triage" never appears verbatim in the file. Confirmed live on
  # VS-4: exc-2's "POST /triage:worker/main.py:1444" false-flagged as
  # CITATION_SYMBOL_MISMATCH. Same class of false positive as the
  # hyphenated-label and own-path-segment guards just above.
  if [ "$approximate" -ne 1 ] && [ -n "$symbol" ] && [ -n "$start_line" ] && [[ "$symbol" != *-* ]] &&
    ! [[ "$symbol" =~ ^(GET|POST|PUT|PATCH|DELETE)[[:space:]]+/ ]] &&
    ! _planner_crosscheck_symbol_is_own_path_segment "$symbol" "$path_part"; then
    symbol=$(_planner_crosscheck_strip_symbol_annotation "$symbol")
    local lo hi
    lo=$((start_line - PLANNER_CROSSCHECK_SYMBOL_PROXIMITY))
    [ "$lo" -lt 1 ] && lo=1
    hi=$((end_line + PLANNER_CROSSCHECK_SYMBOL_PROXIMITY))

    # A TargetSymbols name sometimes bundles two-or-more real, distinct
    # identifiers the spec author considers related enough to cite together
    # ("SessionUser/getCurrentUser", "can/requireRole") rather than writing
    # one TargetSymbols entry per symbol. Treating the whole "X/Y" string as
    # a single literal to grep for can never match real source — `/` isn't
    # valid inside a JS/TS/Python identifier — so every such compound
    # citation false-flagged even when both named symbols genuinely exist.
    # Check each `/`-separated name independently (a bare symbol with no
    # `/` is just a one-element list, so this subsumes the prior behavior);
    # the citation only fails if at least one of them can't be found.
    # Confirmed live on VS-5 (both examples above).
    local -a subsymbols
    IFS='/' read -ra subsymbols <<<"$symbol"
    local subsym missing=""
    for subsym in "${subsymbols[@]}"; do
      [ -z "$subsym" ] && continue
      sed -n "${lo},${hi}p" "$resolved" | grep -qF "$subsym" && continue
      local def_line
      def_line=$(_planner_crosscheck_find_definition_line "$resolved" "$subsym")
      [ -n "$def_line" ] && [ "$def_line" -le "$start_line" ] && continue
      missing="${missing:+${missing}, }${subsym}"
    done

    if [ -n "$missing" ]; then
      echo "planner-crosscheck-citations: CITATION_SYMBOL_MISMATCH ${spec_file}:${spec_line} → ${token} (symbol '${missing}' not found within ${PLANNER_CROSSCHECK_SYMBOL_PROXIMITY} lines in ${resolved})"
      return 1
    fi
  fi

  return 0
}

# ── Check A: citation resolution ────────────────────────────────────────────

# Scan a file's prose for `path:line` / `path:line-line2` tokens and check
# each resolves. Prints findings; returns count of failures.
_planner_crosscheck_scan_prose_citations() {
  local repos_root="$1" spec_file="$2"
  local failures=0
  # Character class must admit `[` `]` (Next.js dynamic route segments like
  # `[entityId]`) and `(` `)` (route groups like `app/(app)/...`) or grep
  # truncates the match to whatever remains after the disallowed character,
  # e.g. "app/api/account/entities/[entityId]/route.ts:11-126" collapses to
  # "/route.ts:11-126" — a citation that then resolves to the wrong file
  # entirely (first `route.ts` match anywhere in the repo) instead of
  # failing loudly. `]` must sit immediately after the opening `[` to be
  # read as a literal member of the bracket expression rather than closing
  # it early.
  local citation_regex="[]A-Za-z0-9_./()[-]+\.(${PLANNER_CROSSCHECK_CITE_EXTENSIONS}):[0-9]+(-[0-9]+)?"
  local hit spec_line token

  while IFS= read -r hit; do
    [ -z "$hit" ] && continue
    spec_line="${hit%%:*}"
    token="${hit#*:}"
    if ! _planner_crosscheck_check_citation "$repos_root" "$spec_file" "$spec_line" "$token"; then
      failures=$((failures + 1))
    fi
  done < <(grep -noE "$citation_regex" "$spec_file" 2>/dev/null)

  return "$failures"
}

# Extract the Signals JSON block's TargetSymbols field (if present) and check
# each `symbol:path:line` entry. Prints findings; returns count of failures.
_planner_crosscheck_scan_target_symbols() {
  local repos_root="$1" spec_file="$2"
  local failures=0
  local signals_json target_symbols entry
  local symbol token symbol_line

  signals_json=$(sed -n '/```json/,/```/p' "$spec_file" | sed '1d;$d' 2>/dev/null)
  [ -z "$signals_json" ] && return 0

  target_symbols=$(echo "$signals_json" | jq -r '.TargetSymbols // empty' 2>/dev/null)
  [ -z "$target_symbols" ] && return 0

  # Line the Signals block starts at, for reporting.
  symbol_line=$(grep -n '```json' "$spec_file" 2>/dev/null | head -1 | cut -d: -f1)
  [ -z "$symbol_line" ] && symbol_line=1

  IFS=';' read -ra entries <<<"$target_symbols"
  for entry in "${entries[@]}"; do
    entry=$(echo "$entry" | sed -e 's/^ *//' -e 's/ *$//')
    [ -z "$entry" ] && continue

    # A bare `path:line` entry (no `Name:` prefix) is easy to misparse if
    # the split is done on the first colon unconditionally: for
    # "worker/main.py:2267-2269" that reads symbol="worker/main.py",
    # token="2267-2269" — a bare number then gets resolved as if it were
    # a path, always failing ("no file under REPOS_ROOT matches
    # '2267-2269'"). Confirmed live on VS-4 (exc-1/exc-2/exc-3/exc-5/exc-6):
    # ~15 entries this shape, all false CITATION_UNRESOLVED/OUT_OF_RANGE.
    # Strip the trailing `:line`/`:line-line2` suffix first — it is always
    # unambiguous — then only treat what remains before it as a Name if a
    # colon still separates it from a path.
    local line_suffix rest
    line_suffix=$(echo "$entry" | grep -oE ':~?[0-9]+(-[0-9]+)?$')
    rest="${entry%"$line_suffix"}"
    if [[ "$rest" == *:* ]]; then
      symbol="${rest%%:*}"
      token="${rest#*:}${line_suffix}"
    else
      symbol=""
      token="$entry"
    fi

    # A symbol can legitimately cite several supporting locations,
    # comma-separated ("documents.status (existing, unchanged):worker/main.py:474,
    # app/api/upload/route.ts:35, UploadPageClient.tsx:74") — check each
    # path:line independently rather than passing the whole joined string to
    # the single-citation checker, which can only ever resolve one path.
    #
    # But a comma-separated part with no '/' is not a second path — it's a
    # second line number in the SAME file ("worker/main.py:1830,2022"),
    # naming two illustrative call sites. Reattach any such bare-number part
    # to the last real path seen so it's checked against that file instead
    # of being treated as an unresolvable path named "2022".
    local -a subtokens
    IFS=',' read -ra subtokens <<<"$token"
    local subtoken last_path=""
    for subtoken in "${subtokens[@]}"; do
      subtoken=$(echo "$subtoken" | sed -e 's/^ *//' -e 's/ *$//')
      [ -z "$subtoken" ] && continue
      if [[ "$subtoken" != */* && "$subtoken" =~ ^[0-9]+(-[0-9]+)?$ ]] && [ -n "$last_path" ]; then
        subtoken="${last_path}:${subtoken}"
      else
        last_path="${subtoken%%:*}"
      fi
      if ! _planner_crosscheck_check_citation "$repos_root" "$spec_file" "$symbol_line" "$subtoken" "$symbol"; then
        failures=$((failures + 1))
      fi
    done
  done

  return "$failures"
}

# ── Check B: precedent grep ─────────────────────────────────────────────────

# Trigger phrases that assert a symbol already exists elsewhere in the repo.
# Each entry is a sed extended-regex substitution: match the phrase plus a
# backtick-quoted identifier, replace with just the identifier.
_PLANNER_CROSSCHECK_PRECEDENT_PATTERNS=(
  's/.*mirrors the existing `([A-Za-z_][A-Za-z0-9_]*)`.*/\1/p'
  's/.*the existing `([A-Za-z_][A-Za-z0-9_]*)`.*/\1/p'
  's/.*reuses `([A-Za-z_][A-Za-z0-9_]*)`.*/\1/p'
  's/.*following the `([A-Za-z_][A-Za-z0-9_]*)` pattern.*/\1/p'
)

# Scan a file's prose for precedent claims and check each identifier is
# actually found somewhere in REPOS_ROOT. Prints findings; returns count of
# failures.
_planner_crosscheck_scan_precedent() {
  local repos_root="$1" spec_file="$2"
  local failures=0
  local pattern line_num line identifier already_checked=""

  while IFS= read -r line_num_and_line; do
    [ -z "$line_num_and_line" ] && continue
    line_num="${line_num_and_line%%:*}"
    line="${line_num_and_line#*:}"

    for pattern in "${_PLANNER_CROSSCHECK_PRECEDENT_PATTERNS[@]}"; do
      identifier=$(echo "$line" | sed -nE "$pattern")
      [ -z "$identifier" ] && continue

      # A single line can only report once per identifier — the patterns
      # overlap (e.g. "the existing `X`" is a substring match of others).
      case "$already_checked" in
      *"|${line_num}:${identifier}|"*) continue ;;
      esac
      already_checked="${already_checked}|${line_num}:${identifier}|"

      if ! _planner_crosscheck_precedent_search "$repos_root" "$identifier"; then
        echo "planner-crosscheck-citations: PRECEDENT_NOT_FOUND ${spec_file}:${line_num} → identifier '${identifier}' has zero matches under REPOS_ROOT"
        failures=$((failures + 1))
      fi
    done
  done < <(grep -noE '.*' "$spec_file" 2>/dev/null | grep -E ':.*(mirrors the existing|the existing|reuses|following the) `')

  return "$failures"
}

# ── Public entry points ──────────────────────────────────────────────────────

# Run both checks against a single file.
# Usage: planner_crosscheck_citations_one <file> [<repos_root>]
# Returns: 0 if clean, 1 if any finding was reported.
planner_crosscheck_citations_one() {
  local spec_file="$1"
  local repos_root="${2:-${REPOS_ROOT:-${HOME}/repos}}"
  local failures=0

  if [ ! -f "$spec_file" ]; then
    echo "planner-crosscheck-citations: file not found: $spec_file" >&2
    return 1
  fi

  _planner_crosscheck_scan_prose_citations "$repos_root" "$spec_file"
  failures=$((failures + $?))

  _planner_crosscheck_scan_target_symbols "$repos_root" "$spec_file"
  failures=$((failures + $?))

  _planner_crosscheck_scan_precedent "$repos_root" "$spec_file"
  failures=$((failures + $?))

  return $((failures > 0 ? 1 : 0))
}

# Run both checks across every spec file plus proposal.md / consensus.md for
# an initiative.
# Usage: planner_crosscheck_citations <initiative_id>
# Returns: 0 if all files are clean, 1 if any file has a finding.
planner_crosscheck_citations() {
  local initiative_id="$1"
  local repos_root="${REPOS_ROOT:-${HOME}/repos}"
  local artifacts_dir="${repos_root}/.ticket-auto/initiatives/${initiative_id}/artifacts"

  if [ ! -d "$artifacts_dir" ]; then
    echo "planner-crosscheck-citations: artifacts directory not found: $artifacts_dir" >&2
    return 1
  fi

  # #217: resolve against the ref Discovery actually explored, not whatever
  # the live REPOS_ROOT checkout happens to be on right now. A no-op when
  # Discovery recorded no repo-ref, or the live checkout already matches.
  local -a _pcc_orig_exclude_dirs=("${PLANNER_CROSSCHECK_EXCLUDE_DIRS[@]}")
  if declare -f planner_crosscheck_repo_ref_setup >/dev/null 2>&1; then
    local _pcc_overrides _pcc_excl
    _pcc_overrides=$(planner_crosscheck_repo_ref_setup "$initiative_id" "$repos_root")
    for _pcc_excl in $_pcc_overrides; do
      PLANNER_CROSSCHECK_EXCLUDE_DIRS+=("$_pcc_excl")
    done
  fi

  local total=0 passed=0 failed=0
  local target_file

  for target_file in "${artifacts_dir}/proposal.md" "${artifacts_dir}/consensus.md"; do
    [ -f "$target_file" ] || continue
    total=$((total + 1))
    if planner_crosscheck_citations_one "$target_file" "$repos_root"; then
      passed=$((passed + 1))
    else
      failed=$((failed + 1))
    fi
  done

  if [ -d "${artifacts_dir}/specs" ]; then
    for target_file in "${artifacts_dir}/specs"/*.md; do
      [ -f "$target_file" ] || continue
      [ "$(basename "$target_file")" = "INDEX.md" ] && continue

      total=$((total + 1))
      if planner_crosscheck_citations_one "$target_file" "$repos_root"; then
        passed=$((passed + 1))
      else
        failed=$((failed + 1))
      fi
    done
  fi

  PLANNER_CROSSCHECK_EXCLUDE_DIRS=("${_pcc_orig_exclude_dirs[@]}")

  echo "planner-crosscheck-citations: $passed passed, $failed failed out of $total files"
  return $((failed > 0 ? 1 : 0))
}
