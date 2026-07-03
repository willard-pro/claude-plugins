#!/usr/bin/env bash
# prescan-route.sh — deterministic INDEX.md routing for appraise consumption.
# Replaces LLM keyword-matching with bash substring matching. Given a ticket's
# text fields and a repo's INDEX.md, emits the list of prescan doc files to load.
# Zero LLM tokens, zero variance between runs.
# -u (nounset) intentionally omitted: Claude Code shell snapshots inject
# ZSH_VERSION references that trigger false-positive "unbound variable"
# errors in this bash version when nounset is active.
set -eo pipefail

_PR_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Usage ─────────────────────────────────────────────────────────────────────

usage() {
  cat >&2 <<'EOF'
Usage: prescan-route.sh --index <path> --ticket-text <string> [options]

Deterministic INDEX.md keyword→file router. Parses Lookup by Topic and
Lookup by Service tables, matches ticket text against topic keywords
(case-insensitive substring), and emits matched file paths.

Options:
  --index <path>        Path to INDEX.md (from prescan docs or wiki)
  --ticket-title <str>  Ticket title
  --ticket-labels <str> Comma-separated ticket labels
  --ticket-desc <str>   Ticket description (first 500 chars is enough)
  --ticket-text <str>   Combined ticket text (title + labels + desc)
  --repos-root <path>   REPOS_ROOT path (for repo enumeration mode)
  --mode <mode>         Route mode: "index" (default, match INDEX.md) or
                        "repos" (enumerate repos under REPOS_ROOT)

Output:
  PRESCAN_ROUTE_FILES   newline-separated list of matched doc file paths
  PRESCAN_ROUTE_COUNT   number of matched files
  PRESCAN_ROUTE_REPOS   newline-separated list of repo paths (mode=repos)

Exit: 0 if matches found, 1 if no matches, 2 on error
EOF
  exit 2
}

# ── Helpers ────────────────────────────────────────────────────────────────────

# Build a combined haystack from all ticket text fields
_build_haystack() {
  local haystack=""
  [ -n "${ARG_TITLE:-}" ] && haystack="$haystack $ARG_TITLE"
  [ -n "${ARG_LABELS:-}" ] && haystack="$haystack $ARG_LABELS"
  [ -n "${ARG_DESC:-}" ] && haystack="$haystack $ARG_DESC"
  [ -n "${ARG_TEXT:-}" ] && haystack="$haystack $ARG_TEXT"
  echo "$haystack" | tr '[:upper:]' '[:lower:]'
}

# Check if a topic keyword matches the ticket haystack
# Uses case-insensitive substring matching — deterministic, no LLM
_topic_matches() {
  local topic="$1" haystack="$2"
  local topic_lower
  topic_lower=$(echo "$topic" | tr '[:upper:]' '[:lower:]')
  # Strip leading/trailing whitespace and punctuation for cleaner matching
  topic_lower=$(echo "$topic_lower" | sed 's/^[^a-z0-9]*//;s/[^a-z0-9]*$//')
  [ -z "$topic_lower" ] && return 1
  # Require at least 3 chars to avoid spurious matches on short words
  [ ${#topic_lower} -lt 3 ] && return 1
  echo "$haystack" | grep -Fq "$topic_lower" 2>/dev/null && return 0 || return 1
}

# ── INDEX.md routing ──────────────────────────────────────────────────────────

_route_index() {
  local index_path="$1" haystack="$2"
  local docs_dir
  docs_dir=$(dirname "$index_path")

  if [ ! -f "$index_path" ]; then
    echo "ERROR: INDEX.md not found: $index_path" >&2
    return 2
  fi

  local matched_files=()
  local in_topic_table=false
  local in_service_table=false
  local route_count=0

  # Parse INDEX.md line by line. Tables have format: | Topic/Service | File |
  # Extract topic keyword from col 1, file path from col 2.
  while IFS= read -r line; do
    # Track which table we're in
    if echo "$line" | grep -q '^## Lookup by Topic'; then
      in_topic_table=true
      in_service_table=false
      continue
    fi
    if echo "$line" | grep -q '^## Lookup by Service'; then
      in_topic_table=false
      in_service_table=true
      continue
    fi
    # Next ## heading ends the table
    if echo "$line" | grep -q '^## ' && ! echo "$line" | grep -q 'Lookup by'; then
      in_topic_table=false
      in_service_table=false
      continue
    fi

    # Only process table rows (skip header and separator lines)
    if ! echo "$line" | grep -qE '^\|.*\|.*\|'; then
      continue
    fi
    # Skip separator rows like |-------|------|
    if echo "$line" | grep -qE '^\|[- ]+\|'; then
      continue
    fi

    if [ "$in_topic_table" = "true" ] || [ "$in_service_table" = "true" ]; then
      # Extract columns: | col1 | col2 |
      local topic file_path
      topic=$(echo "$line" | cut -d'|' -f2 | sed 's/^ *//;s/ *$//')
      file_path=$(echo "$line" | cut -d'|' -f3 | sed 's/^ *//;s/ *$//')

      # Skip placeholder entries
      [ "$topic" = "(no entries yet)" ] && continue
      [ -z "$file_path" ] && continue

      if _topic_matches "$topic" "$haystack"; then
        local full_path="$docs_dir/$file_path"
        if [ -f "$full_path" ]; then
          matched_files+=("$full_path")
          ((route_count++)) || true
        fi
      fi
    fi
  done <"$index_path"

  # Emit results
  if [ "$route_count" -gt 0 ]; then
    printf '%s\n' "${matched_files[@]}"
    echo "PRESCAN_ROUTE_COUNT=$route_count"
    return 0
  else
    echo "PRESCAN_ROUTE_COUNT=0"
    return 1
  fi
}

# ── Repo enumeration ──────────────────────────────────────────────────────────

_route_repos() {
  local repos_root="$1"
  if [ ! -d "$repos_root" ]; then
    echo "ERROR: REPOS_ROOT not found: $repos_root" >&2
    return 2
  fi

  local repos=()
  while IFS= read -r -d '' gitdir; do
    repos+=("$(dirname "$gitdir")")
  done < <(find "$repos_root" -maxdepth 3 -name ".git" -printf '%h\0' 2>/dev/null || true)

  if [ ${#repos[@]} -eq 0 ]; then
    echo "PRESCAN_ROUTE_COUNT=0"
    return 1
  fi

  printf '%s\n' "${repos[@]}"
  echo "PRESCAN_ROUTE_COUNT=${#repos[@]}"
  return 0
}

# ── Main ───────────────────────────────────────────────────────────────────────

main() {
  ARG_INDEX=""
  ARG_TITLE=""
  ARG_LABELS=""
  ARG_DESC=""
  ARG_TEXT=""
  ARG_REPOS_ROOT=""
  ARG_MODE="index"

  while [[ $# -gt 0 ]]; do
    case "$1" in
    --index)
      ARG_INDEX="${2:-}"
      shift 2
      ;;
    --ticket-title)
      ARG_TITLE="${2:-}"
      shift 2
      ;;
    --ticket-labels)
      ARG_LABELS="${2:-}"
      shift 2
      ;;
    --ticket-desc)
      ARG_DESC="${2:-}"
      shift 2
      ;;
    --ticket-text)
      ARG_TEXT="${2:-}"
      shift 2
      ;;
    --repos-root)
      ARG_REPOS_ROOT="${2:-}"
      shift 2
      ;;
    --mode)
      ARG_MODE="${2:-}"
      shift 2
      ;;
    --help | -h) usage ;;
    *)
      echo "Unknown flag: $1" >&2
      usage
      ;;
    esac
  done

  case "$ARG_MODE" in
  index)
    [ -z "$ARG_INDEX" ] && {
      echo "ERROR: --index is required for mode=index" >&2
      usage
    }
    local haystack
    haystack=$(_build_haystack)
    _route_index "$ARG_INDEX" "$haystack"
    return $?
    ;;
  repos)
    [ -z "$ARG_REPOS_ROOT" ] && {
      echo "ERROR: --repos-root is required for mode=repos" >&2
      usage
    }
    _route_repos "$ARG_REPOS_ROOT"
    return $?
    ;;
  *)
    echo "ERROR: invalid mode '$ARG_MODE'. Use 'index' or 'repos'." >&2
    usage
    ;;
  esac
}

# ── Dispatch ───────────────────────────────────────────────────────────────────

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
