#!/usr/bin/env bash
# prescan-verify.sh — deterministic post-scan content quality assertions.
# Runs after doc generation to verify every expected file meets minimum
# quality standards. Prevents "agent wrote a file that's technically
# non-empty but useless" scenarios.
# Modeled on gate-check.sh: zero LLM tokens, pure bash.
set -eo pipefail

# ── Usage ─────────────────────────────────────────────────────────────────────

usage() {
  cat >&2 <<'EOF'
Usage: prescan-verify.sh --docs-dir <path> [--cadence full|incremental]

Verifies every expected prescan doc file meets minimum quality standards.

Checks per file:
  - Exists and is non-empty
  - Has at least MIN_LINES lines (default 3)
  - Has at least MIN_HEADINGS ## sections (default 1)
  - Is not a placeholder-only file (no "No * data available" pattern)
  - For security-surfaces.md: has warning header
  - For INDEX.md: has both Lookup by Topic and Lookup by Service tables
  - services/ dir has at least one .md file

Exit: 0 all pass, 1 quality violations found, 2 missing docs
EOF
  exit 2
}

# ── Defaults ──────────────────────────────────────────────────────────────────

MIN_LINES="${PRESCAN_VERIFY_MIN_LINES:-3}"
MIN_HEADINGS="${PRESCAN_VERIFY_MIN_HEADINGS:-1}"

# Full fan-out docs — all of these must exist and pass quality checks
FULL_DOCS=(
  "overview.md"
  "processes.md"
  "security-surfaces.md"
  "INDEX.md"
)

# Incremental scan docs — same set (docs are regenerated on incremental too)
INCREMENTAL_DOCS=(
  "overview.md"
  "processes.md"
  "security-surfaces.md"
  "INDEX.md"
)

# ── Checks ────────────────────────────────────────────────────────────────────

VIOLATIONS=0

_violation() {
  local file="$1" reason="$2"
  echo "PRESCAN_VERIFY_VIOLATION=$file: $reason"
  ((VIOLATIONS++)) || true
}

# Check: file exists, non-empty, minimum lines
_check_file_basics() {
  local path="$1" label="$2"
  if [ ! -f "$path" ]; then
    _violation "$label" "missing"
    return 1
  fi
  if [ ! -s "$path" ]; then
    _violation "$label" "empty"
    return 1
  fi
  local lines
  lines=$(wc -l < "$path" 2>/dev/null || echo "0")
  lines=$(echo "$lines" | tr -d ' ')
  if [ "$lines" -lt "$MIN_LINES" ] 2>/dev/null; then
    _violation "$label" "too few lines ($lines < $MIN_LINES)"
    return 1
  fi
  return 0
}

# Check: has at least N ## headings
_check_headings() {
  local path="$1" label="$2"
  local heading_count
  heading_count=$(grep -c '^## ' "$path" 2>/dev/null || echo "0")
  if [ "$heading_count" -lt "$MIN_HEADINGS" ] 2>/dev/null; then
    _violation "$label" "no ## headings (need $MIN_HEADINGS+)"
    return 1
  fi
  return 0
}

# Check: not a placeholder-only file
_check_not_placeholder() {
  local path="$1" label="$2"
  if grep -qiE 'no .* data available|no .* data extracted|will be populated|will be generated' "$path" 2>/dev/null; then
    local line_count
    line_count=$(wc -l < "$path" 2>/dev/null | tr -d ' ')
    # If the file is short AND contains placeholder language, it's a placeholder
    if [ "${line_count:-0}" -lt 8 ] 2>/dev/null; then
      _violation "$label" "appears to be placeholder-only"
      return 1
    fi
  fi
  return 0
}

# Check: security-surfaces.md has warning header
_check_security_warning() {
  local path="$1"
  if ! head -5 "$path" 2>/dev/null | grep -q 'WARNING.*security\|Do not commit\|SECURITY WARNING' 2>/dev/null; then
    _violation "security-surfaces.md" "missing security warning header"
    return 1
  fi
  return 0
}

# Check: INDEX.md has both required tables
_check_index_tables() {
  local path="$1"
  local has_topic has_service
  has_topic=$(grep -c '## Lookup by Topic' "$path" 2>/dev/null || echo "0")
  has_service=$(grep -c '## Lookup by Service' "$path" 2>/dev/null || echo "0")
  if [ "$has_topic" = "0" ]; then
    _violation "INDEX.md" "missing Lookup by Topic table"
    return 1
  fi
  if [ "$has_service" = "0" ]; then
    _violation "INDEX.md" "missing Lookup by Service table"
    return 1
  fi
  return 0
}

# Check: services/ dir has at least one .md file
_check_services_dir() {
  local docs_dir="$1"
  if [ ! -d "$docs_dir/services" ]; then
    _violation "services/" "directory missing"
    return 1
  fi
  local md_count
  md_count=$(ls -1 "$docs_dir/services"/*.md 2>/dev/null | wc -l || echo "0")
  if [ "$md_count" = "0" ]; then
    _violation "services/" "no .md files found"
    return 1
  fi
  return 0
}

# ── Main ───────────────────────────────────────────────────────────────────────

main() {
  local docs_dir="" cadence="full"

  while [[ $# -gt 0 ]]; do
    case "$1" in
    --docs-dir) docs_dir="${2:-}"; shift 2 ;;
    --cadence)  cadence="${2:-}"; shift 2 ;;
    --help|-h)  usage ;;
    *) echo "Unknown flag: $1" >&2; usage ;;
    esac
  done

  [ -z "$docs_dir" ] && { echo "ERROR: --docs-dir is required" >&2; usage; }
  [ ! -d "$docs_dir" ] && { echo "ERROR: docs dir not found: $docs_dir" >&2; exit 2; }

  local expected_docs
  case "$cadence" in
  full|decayed|missing|forced)
    expected_docs=("${FULL_DOCS[@]}") ;;
  incremental|stale)
    expected_docs=("${INCREMENTAL_DOCS[@]}") ;;
  *)
    echo "ERROR: invalid cadence '$cadence'. Use 'full' or 'incremental'." >&2
    exit 2
    ;;
  esac

  echo "PRESCAN_VERIFY_STATUS=start"
  echo "PRESCAN_VERIFY_DOCS_DIR=$docs_dir"
  echo "PRESCAN_VERIFY_CADENCE=$cadence"

  # Run all checks
  for doc in "${expected_docs[@]}"; do
    local path="$docs_dir/$doc"
    _check_file_basics "$path" "$doc" || continue
    _check_headings "$path" "$doc"
    _check_not_placeholder "$path" "$doc"

    # Specialized checks
    case "$doc" in
    "security-surfaces.md") _check_security_warning "$path" ;;
    "INDEX.md")             _check_index_tables "$path" ;;
    esac
  done

  _check_services_dir "$docs_dir"

  # Emit result
  if [ "$VIOLATIONS" -eq 0 ]; then
    echo "PRESCAN_VERIFY_STATUS=pass"
    echo "PRESCAN_VERIFY_VIOLATIONS=0"
    return 0
  else
    echo "PRESCAN_VERIFY_STATUS=fail"
    echo "PRESCAN_VERIFY_VIOLATIONS=$VIOLATIONS"
    return 1
  fi
}

# ── Dispatch ───────────────────────────────────────────────────────────────────

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
