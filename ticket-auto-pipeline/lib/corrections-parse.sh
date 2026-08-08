#!/usr/bin/env bash
# corrections-parse.sh — deterministic CORRECTIONS block parser for notes.md.
# Provides atomic append (write) and structured parse (read) for the
# <!-- CORRECTIONS --> … <!-- /CORRECTIONS --> block format.
# -u intentionally omitted: Claude Code shell snapshots inject ZSH_VERSION
# references that trigger false-positive "unbound variable" errors.
set -eo pipefail

# ── append_correction ──────────────────────────────────────────────────────────
# Atomically appends a single CORRECTIONS block to notes.md.
# Usage: append_correction <notes-path> <fact> <source> <corrected>
#
# Exit codes: 0 appended, 1 write/rename failed, 2 invalid args
append_correction() {
  local notes="$1" fact="$2" source="$3" corrected="$4"

  if [ -z "$notes" ] || [ -z "$fact" ] || [ -z "$source" ] || [ -z "$corrected" ]; then
    echo "append_correction: all four arguments required" >&2
    return 2
  fi

  case "$source" in
  appraise | exec | prescan | wiki | inspector | postmortem) ;;
  *)
    echo "append_correction: source must be one of: appraise, exec, prescan, wiki, inspector, postmortem" >&2
    return 2
    ;;
  esac

  local notes_tmp="${notes}.tmp.$$"
  local lockfile="${notes}.lock"

  # Critical section: flock prevents concurrent append_correction calls
  # from reading the same notes.md state and silently overwriting each
  # other's writes. Mirrors flow.sh's existing flock pattern.
  exec 9>"$lockfile"
  flock 9 || {
    echo "append_correction: failed to acquire lock on $notes" >&2
    return 1
  }

  if [ -f "$notes" ]; then
    cat "$notes" >"$notes_tmp" 2>/dev/null || {
      echo "append_correction: failed to read $notes" >&2
      rm -f "$notes_tmp"
      return 1
    }
  else
    : >"$notes_tmp" 2>/dev/null || {
      echo "append_correction: failed to create temp file" >&2
      return 1
    }
  fi

  cat >>"$notes_tmp" <<EOF
<!-- CORRECTIONS -->
- fact: $fact
- source: $source
- corrected: $corrected
<!-- /CORRECTIONS -->
EOF

  mv "$notes_tmp" "$notes" 2>/dev/null || {
    echo "append_correction: atomic rename failed for $notes" >&2
    rm -f "$notes_tmp"
    return 1
  }

  return 0
}

# ── get_corrections ────────────────────────────────────────────────────────────
# Parses all CORRECTIONS blocks from notes.md and emits numbered shell variables.
# Usage: get_corrections <notes-path>
#
# Emits KEY=value lines suitable for 'eval' or 'source'.
# Values are printf '%q' quoted for shell safety.
#
# Torn-block tolerance: if <!-- CORRECTIONS --> is found but <!-- /CORRECTIONS -->
# is not encountered before EOF, the unclosed block is silently ignored.
#
# Last-match-wins: if two entries share the same fact text (case-sensitive),
# the later one replaces the earlier one.
#
# Exit codes: 0 (may be count 0), 1 = file unreadable, 2 = parse error (degraded)
get_corrections() {
  local notes="$1"

  if [ ! -f "$notes" ]; then
    echo "get_corrections: file not found: $notes" >&2
    printf 'CORRECTION_COUNT=%d\n' 0
    return 1
  fi

  if [ ! -r "$notes" ]; then
    echo "get_corrections: file unreadable: $notes" >&2
    printf 'CORRECTION_COUNT=%d\n' 0
    return 1
  fi

  local count=0 in_marker=0 block_text line fact source corrected i j found

  while IFS= read -r line; do
    case "$line" in
    '<!-- CORRECTIONS -->')
      in_marker=1
      block_text=""
      ;;
    '<!-- /CORRECTIONS -->')
      if [ "$in_marker" -eq 1 ] && [ -n "$block_text" ]; then
        fact=""
        source=""
        corrected=""
        fact=$(echo "$block_text" | sed -n 's/^- fact: //p' | head -1)
        source=$(echo "$block_text" | sed -n 's/^- source: //p' | head -1)
        corrected=$(echo "$block_text" | sed -n 's/^- corrected: //p' | head -1)

        if [ -n "$fact" ] && [ -n "$source" ] && [ -n "$corrected" ]; then
          # Last-match-wins: linear scan for duplicate fact
          found=-1
          for i in $(seq 0 $((count - 1))); do
            local ef_var="CORRECTION_${i}_FACT"
            if [ "${!ef_var}" = "$fact" ]; then
              found=$i
              break
            fi
          done

          if [ "$found" -ge 0 ]; then
            printf -v "CORRECTION_${found}_FACT" '%s' "$fact"
            printf -v "CORRECTION_${found}_SOURCE" '%s' "$source"
            printf -v "CORRECTION_${found}_CORRECTED" '%s' "$corrected"
          else
            printf -v "CORRECTION_${count}_FACT" '%s' "$fact"
            printf -v "CORRECTION_${count}_SOURCE" '%s' "$source"
            printf -v "CORRECTION_${count}_CORRECTED" '%s' "$corrected"
            count=$((count + 1))
          fi
        fi
      fi
      in_marker=0
      block_text=""
      ;;
    *)
      if [ "$in_marker" -eq 1 ]; then
        block_text="${block_text}${line}
"
      fi
      ;;
    esac
  done <"$notes"

  # Torn block at EOF (in_marker=1, no close): silently ignored

  printf 'CORRECTION_COUNT=%d\n' "$count"
  for j in $(seq 0 $((count - 1))); do
    local f_var="CORRECTION_${j}_FACT"
    local s_var="CORRECTION_${j}_SOURCE"
    local c_var="CORRECTION_${j}_CORRECTED"
    printf 'CORRECTION_%d_FACT=%q\n' "$j" "${!f_var}"
    printf 'CORRECTION_%d_SOURCE=%q\n' "$j" "${!s_var}"
    printf 'CORRECTION_%d_CORRECTED=%q\n' "$j" "${!c_var}"
  done

  return 0
}

# ── get_corrections_by_source ─────────────────────────────────────────────────
# Same as get_corrections but filters to a single source (case-insensitive).
# Usage: get_corrections_by_source <notes-path> <source>
get_corrections_by_source() {
  local notes="$1" filter_source="$2"

  if [ -z "$filter_source" ]; then
    echo "get_corrections_by_source: source filter required" >&2
    printf 'CORRECTION_COUNT=%d\n' 0
    return 2
  fi

  local _all_out _all_count i filtered_count
  _all_out=$(get_corrections "$notes" 2>/dev/null) || true
  eval "$_all_out" 2>/dev/null || true

  _all_count="${CORRECTION_COUNT:-0}"
  filtered_count=0

  for i in $(seq 0 $((_all_count - 1))); do
    local fact_var="CORRECTION_${i}_FACT"
    local src_var="CORRECTION_${i}_SOURCE"
    local corr_var="CORRECTION_${i}_CORRECTED"
    local entry_fact="${!fact_var}"
    local entry_source="${!src_var}"
    local entry_corrected="${!corr_var}"

    if [ "$(echo "$entry_source" | tr '[:upper:]' '[:lower:]')" = "$(echo "$filter_source" | tr '[:upper:]' '[:lower:]')" ]; then
      printf -v "CORRECTION_${filtered_count}_FACT" '%s' "$entry_fact"
      printf -v "CORRECTION_${filtered_count}_SOURCE" '%s' "$entry_source"
      printf -v "CORRECTION_${filtered_count}_CORRECTED" '%s' "$entry_corrected"
      filtered_count=$((filtered_count + 1))
    fi
  done

  printf 'CORRECTION_COUNT=%d\n' "$filtered_count"
  for i in $(seq 0 $((filtered_count - 1))); do
    local f_var="CORRECTION_${i}_FACT"
    local s_var="CORRECTION_${i}_SOURCE"
    local c_var="CORRECTION_${i}_CORRECTED"
    printf 'CORRECTION_%d_FACT=%q\n' "$i" "${!f_var}"
    printf 'CORRECTION_%d_SOURCE=%q\n' "$i" "${!s_var}"
    printf 'CORRECTION_%d_CORRECTED=%q\n' "$i" "${!c_var}"
  done
}

# ── Main dispatch ──────────────────────────────────────────────────────────────

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  CMD="${1:-}"
  shift || true

  case "$CMD" in
  append)
    append_correction "$@"
    ;;
  get)
    get_corrections "$@"
    ;;
  get-by-source)
    get_corrections_by_source "$@"
    ;;
  --help | -h | "")
    cat >&2 <<'EOF'
Usage: corrections-parse.sh <command> [args...]

Commands:
  append <notes-path> <fact> <source> <corrected>
  get <notes-path>
  get-by-source <notes-path> <source>
EOF
    exit 1
    ;;
  *)
    echo "Unknown command: $CMD" >&2
    exit 1
    ;;
  esac
fi
