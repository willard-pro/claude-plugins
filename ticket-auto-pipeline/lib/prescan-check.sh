#!/usr/bin/env bash
# prescan-check.sh — deterministic freshness gate for .ticket-auto/ prescan docs.
# Modeled on gate-check.sh: zero LLM tokens, pure bash. Emits structured status
# variables and exits with documented codes.
# -u (nounset) intentionally omitted: Claude Code shell snapshots inject
# ZSH_VERSION references that trigger false-positive "unbound variable"
# errors in this bash version when nounset is active.
set -eo pipefail

# ── Dependency guards ───────────────────────────────────────────────────────────

if ! command -v jq &>/dev/null; then
  echo "ERROR: jq is required but not installed. Install jq and retry." >&2
  exit 3
fi

_PRESCAN_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_PRESCAN_LIB_DIR="${CLAUDE_SKILLS_LIB:-$HOME/.claude/skills/lib}"
# heartbeat.sh is optional — source if available, degrade gracefully if not
if [ -f "$_PRESCAN_LIB_DIR/heartbeat.sh" ]; then
  source "$_PRESCAN_LIB_DIR/heartbeat.sh"
fi

# ── Defaults ──────────────────────────────────────────────────────────────────

SCHEMA_VERSION="1"
DECAY_CHURN_PCT="${PRESCAN_DECAY_CHURN_PCT:-25}"
DECAY_AGE_DAYS="${PRESCAN_DECAY_AGE_DAYS:-30}"
DECAY_INCREMENTAL_LIMIT="${PRESCAN_DECAY_INCREMENTAL_LIMIT:-10}"

# Conservative default source globs — used when no repo markers detected
DEFAULT_SOURCE_GLOBS=(
  "*.ts" "*.js" "*.py" "*.java" "*.go" "*.rs" "*.rb" "*.php"
  "*.html" "*.css" "*.scss" "*.vue" "*.tsx" "*.jsx"
)

# Expected doc files that must exist in docs/ for integrity check.
# Minimum viable set: overview, processes, INDEX.md, and security-surfaces.
# services/ dir is checked separately (must contain at least one .md).
EXPECTED_DOCS=(
  "overview.md"
  "processes.md"
  "INDEX.md"
  "security-surfaces.md"
)

# ── Usage ─────────────────────────────────────────────────────────────────────

usage() {
  cat >&2 <<'EOF'
Usage: prescan-check.sh <repo-path> [--force] [--repos-root <path>]

Evaluates prescan doc freshness for a repo. Emits KEY=value lines:
  PRESCAN_STATUS    fresh | stale | decayed | missing
  PRESCAN_REASON    specific reason code
  CHANGED_FILES     space-separated list (stale only)
  STALENESS_SCORE   integer 0-100 (stale/decayed only)
  DIRTY             true | false

Exit codes: 0 fresh (skip), 1 stale/decayed (rescan needed), 2 missing (full scan needed)
EOF
  exit 1
}

# ── Slug derivation ───────────────────────────────────────────────────────────

_derive_slug() {
  local repo="$1"
  # Derive slug from repo path: basename of the last component
  basename "$repo" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g'
}

# ── Source glob derivation from repo markers ───────────────────────────────────

_derive_source_globs() {
  local repo="$1"

  # Angular — strongest signal first
  if [ -f "$repo/angular.json" ]; then
    echo "*.ts *.html *.scss *.css"
    return
  fi

  # Python
  if [ -f "$repo/pyproject.toml" ] || [ -f "$repo/requirements.txt" ] || [ -f "$repo/setup.py" ] || [ -f "$repo/setup.cfg" ]; then
    echo "*.py"
    return
  fi

  # Java
  if [ -f "$repo/pom.xml" ] || [ -f "$repo/build.gradle" ] || [ -f "$repo/build.gradle.kts" ]; then
    echo "*.java *.xml *.properties"
    return
  fi

  # Node.js / TypeScript (package.json without FE framework markers like angular.json)
  if [ -f "$repo/package.json" ]; then
    echo "*.ts *.js *.tsx *.jsx *.json *.html *.css *.scss"
    return
  fi

  # Go
  if [ -f "$repo/go.mod" ]; then
    echo "*.go"
    return
  fi

  # Rust
  if [ -f "$repo/Cargo.toml" ]; then
    echo "*.rs"
    return
  fi

  # Ruby
  if [ -f "$repo/Gemfile" ]; then
    echo "*.rb"
    return
  fi

  # PHP
  if [ -f "$repo/composer.json" ]; then
    echo "*.php"
    return
  fi

  # Fallback: conservative defaults (no recognized markers)
  echo "${DEFAULT_SOURCE_GLOBS[*]}"
}

# ── Churn calculation ─────────────────────────────────────────────────────────

_calc_churn_pct() {
  local repo="$1" base_sha="$2"
  local source_globs total_files changed_files
  source_globs=$(_derive_source_globs "$repo")

  # Build glob arguments for git diff
  local glob_args=()
  for glob in $source_globs; do
    glob_args+=("--" "$glob")
  done

  # Count total tracked source files at current HEAD
  total_files=$(git -C "$repo" ls-files -- "${glob_args[@]}" 2>/dev/null | wc -l || echo "0")
  total_files=$(echo "$total_files" | tr -d ' ')

  # Count files changed since base_sha
  changed_files=$(git -C "$repo" diff --name-only "$base_sha" HEAD -- "${glob_args[@]}" 2>/dev/null | wc -l || echo "0")
  changed_files=$(echo "$changed_files" | tr -d ' ')

  if [ "$total_files" = "0" ]; then
    echo "0"
    return
  fi

  # Integer percentage: (changed * 100) / total
  echo $(( (changed_files * 100) / total_files ))
}

# ── Decay check ───────────────────────────────────────────────────────────────

_check_decay() {
  local repo="$1" meta_path="$2"
  local last_full_dive_sha last_full_dive_ts churn_pct age_days age_sec now_epoch dive_epoch
  local incremental_count

  last_full_dive_sha=$(jq -r '.last_full_dive_sha // empty' "$meta_path" 2>/dev/null || true)
  last_full_dive_ts=$(jq -r '.last_full_dive_ts // empty' "$meta_path" 2>/dev/null || true)
  incremental_count=$(jq -r '.incremental_scan_count // 0' "$meta_path" 2>/dev/null || echo "0")

  if [ -z "$last_full_dive_sha" ] || [ -z "$last_full_dive_ts" ]; then
    # No full dive recorded — first scan was likely deterministic dump only, not a full fan-out
    return 0
  fi

  # Check 1: Too many incremental scans since last full dive → decay
  # Prevents silent rot from death-by-a-thousand-cuts (many small commits each < churn%)
  if [[ "$incremental_count" =~ ^[0-9]+$ ]] && [ "$incremental_count" -ge "$DECAY_INCREMENTAL_LIMIT" ] 2>/dev/null; then
    STALENESS_SCORE="$incremental_count"
    PRESCAN_STATUS="decayed"
    PRESCAN_REASON="decay_incremental_count"
    return 1
  fi

  # Check 2: Cumulative churn since last full dive
  churn_pct=$(_calc_churn_pct "$repo" "$last_full_dive_sha")
  if [ "$churn_pct" -ge "$DECAY_CHURN_PCT" ] 2>/dev/null; then
    STALENESS_SCORE="$churn_pct"
    PRESCAN_STATUS="decayed"
    PRESCAN_REASON="decay_churn"
    return 1
  fi

  # Check 3: Age since last full dive
  now_epoch=$(date -u +%s)
  dive_epoch=$(date -u -d "$last_full_dive_ts" +%s 2>/dev/null || echo "0")
  if [ "$dive_epoch" -gt 0 ] 2>/dev/null; then
    age_sec=$(( now_epoch - dive_epoch ))
    age_days=$(( age_sec / 86400 ))
    if [ "$age_days" -ge "$DECAY_AGE_DAYS" ] 2>/dev/null; then
      STALENESS_SCORE="$age_days"
      PRESCAN_STATUS="decayed"
      PRESCAN_REASON="decay_age"
      return 1
    fi
  fi

  return 0
}

# ── Integrity check ───────────────────────────────────────────────────────────

_check_integrity() {
  local docs_dir="$1"
  local missing_file=""

  for doc in "${EXPECTED_DOCS[@]}"; do
    if [ ! -f "$docs_dir/$doc" ] || [ ! -s "$docs_dir/$doc" ]; then
      missing_file="$doc"
      break
    fi
  done

  if [ -n "$missing_file" ]; then
    PRESCAN_STATUS="stale"
    PRESCAN_REASON="integrity_fail:$missing_file"
    return 1
  fi

  # Check services/ dir: must exist and contain at least one .md file
  if [ ! -d "$docs_dir/services" ] || [ -z "$(ls -A "$docs_dir/services"/*.md 2>/dev/null)" ]; then
    PRESCAN_STATUS="stale"
    PRESCAN_REASON="integrity_fail:services/_empty_or_missing"
    return 1
  fi

  return 0
}

# ── Main evaluation ───────────────────────────────────────────────────────────

_evaluate() {
  local repo="$1" repos_root="$2" force="${3:-false}"
  repo=$(cd "$repo" 2>/dev/null && pwd || echo "$repo")
  local slug meta_path docs_dir

  slug=$(_derive_slug "$repo")
  meta_path="$repos_root/.ticket-auto/$slug/meta.json"
  docs_dir="$repos_root/.ticket-auto/$slug/docs"

  # ── Check 0: Force flag ──────────────────────────────────────────────────
  if [ "$force" = "true" ]; then
    PRESCAN_STATUS="stale"
    PRESCAN_REASON="forced"
    CHANGED_FILES=""
    STALENESS_SCORE="100"
    _check_dirty "$repo"
    return 1
  fi

  # ── Check 1: Missing marker ──────────────────────────────────────────────
  if [ ! -f "$meta_path" ]; then
    PRESCAN_STATUS="missing"
    PRESCAN_REASON="no_marker"
    CHANGED_FILES=""
    STALENESS_SCORE=""
    _check_dirty "$repo"
    return 2
  fi

  # ── Check 2: Schema version mismatch ─────────────────────────────────────
  local version_in_file
  version_in_file=$(jq -r '.schema_version // empty' "$meta_path" 2>/dev/null || true)
  if [ "$version_in_file" != "$SCHEMA_VERSION" ]; then
    PRESCAN_STATUS="missing"
    PRESCAN_REASON="schema_version_mismatch"
    CHANGED_FILES=""
    STALENESS_SCORE=""
    _check_dirty "$repo"
    return 2
  fi

  # ── Check 3: Integrity ───────────────────────────────────────────────────
  if ! _check_integrity "$docs_dir"; then
    # _check_integrity sets PRESCAN_STATUS and PRESCAN_REASON on failure
    CHANGED_FILES=""
    STALENESS_SCORE=""
    _check_dirty "$repo"
    return 1
  fi

  # ── Check 4: Non-ancestor SHA ────────────────────────────────────────────
  local last_sha
  last_sha=$(jq -r '.last_scanned_sha // empty' "$meta_path" 2>/dev/null || true)
  if [ -z "$last_sha" ]; then
    PRESCAN_STATUS="missing"
    PRESCAN_REASON="no_sha_in_marker"
    CHANGED_FILES=""
    STALENESS_SCORE=""
    _check_dirty "$repo"
    return 2
  fi

  if ! git -C "$repo" cat-file -e "$last_sha" 2>/dev/null; then
    PRESCAN_STATUS="missing"
    PRESCAN_REASON="non_ancestor_sha"
    CHANGED_FILES=""
    STALENESS_SCORE=""
    _check_dirty "$repo"
    return 2
  fi

  # ── Check 5: HEAD unchanged ──────────────────────────────────────────────
  local head_sha
  head_sha=$(git -C "$repo" rev-parse HEAD 2>/dev/null || true)
  if [ "$last_sha" = "$head_sha" ]; then
    _check_dirty "$repo"
    # Even if HEAD hasn't moved, a periodic full re-dive may be needed.
    # Check decay age before declaring fresh.
    if _check_decay "$repo" "$meta_path"; then
      PRESCAN_STATUS="fresh"
      PRESCAN_REASON="head_unchanged"
      CHANGED_FILES=""
      STALENESS_SCORE="0"
      return 0
    fi
    # _check_decay sets PRESCAN_STATUS=decayed and PRESCAN_REASON
    CHANGED_FILES=""
    STALENESS_SCORE="${STALENESS_SCORE:-0}"
    return 1
  fi

  # ── Check 6: Source changes since last scan ──────────────────────────────
  local source_globs changed_files_list
  source_globs=$(_derive_source_globs "$repo")
  local glob_args=()
  for glob in $source_globs; do
    glob_args+=("--" "$glob")
  done

  changed_files_list=$(git -C "$repo" diff --name-only "$last_sha" HEAD -- "${glob_args[@]}" 2>/dev/null || true)

  if [ -z "$changed_files_list" ]; then
    # HEAD moved but no source changes — only non-source files changed.
    # Still check decay age before declaring fresh.
    _check_dirty "$repo"
    if _check_decay "$repo" "$meta_path"; then
      PRESCAN_STATUS="fresh"
      PRESCAN_REASON="no_source_changes"
      CHANGED_FILES=""
      STALENESS_SCORE="0"
      return 0
    fi
    CHANGED_FILES=""
    STALENESS_SCORE="${STALENESS_SCORE:-0}"
    return 1
  fi

  # ── Check 7: Stale (source changes detected) ─────────────────────────────
  CHANGED_FILES=$(echo "$changed_files_list" | tr '\n' ' ')
  local churn_pct
  churn_pct=$(_calc_churn_pct "$repo" "$last_sha")
  STALENESS_SCORE="$churn_pct"

  # ── Check 8: Decay threshold ─────────────────────────────────────────────
  if _check_decay "$repo" "$meta_path"; then
    # Not decayed — plain stale
    PRESCAN_STATUS="stale"
    PRESCAN_REASON="source_changed"
  fi
  # _check_decay sets PRESCAN_STATUS=decayed and PRESCAN_REASON on threshold breach

  _check_dirty "$repo"
  return 1
}

# ── Dirty working tree check ─────────────────────────────────────────────────

_check_dirty() {
  local repo="$1"
  local porcelain
  porcelain=$(git -C "$repo" status --porcelain 2>/dev/null || true)
  if [ -n "$porcelain" ]; then
    DIRTY="true"
    # Append dirty note to reason if not already set
    if [ -n "${PRESCAN_REASON:-}" ] && ! echo "$PRESCAN_REASON" | grep -q 'dirty_tree'; then
      PRESCAN_REASON="${PRESCAN_REASON}+dirty_tree"
    fi
  else
    DIRTY="false"
  fi
}

# ── Emit results ──────────────────────────────────────────────────────────────

_emit() {
  # Single-quote values so sourcing is safe even if a value contains shell
  # metacharacters (defense-in-depth — all values are controlled inputs).
  printf "PRESCAN_STATUS='%s'\n" "${PRESCAN_STATUS:-missing}"
  printf "PRESCAN_REASON='%s'\n" "${PRESCAN_REASON:-unknown}"
  printf "CHANGED_FILES='%s'\n" "${CHANGED_FILES:-}"
  printf "STALENESS_SCORE='%s'\n" "${STALENESS_SCORE:-}"
  printf "DIRTY='%s'\n" "${DIRTY:-false}"
}

# ── Main dispatch ─────────────────────────────────────────────────────────────

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  REPO=""
  FORCE="false"
  REPOS_ROOT="${REPOS_ROOT:-}"

  while [[ $# -gt 0 ]]; do
    case "$1" in
    --force)
      FORCE="true"
      shift
      ;;
    --repos-root)
      REPOS_ROOT="${2:-}"
      shift 2
      ;;
    --help | -h)
      usage
      ;;
    -*)
      echo "Unknown flag: $1" >&2
      usage
      ;;
    *)
      if [ -z "$REPO" ]; then
        REPO="$1"
        shift
      else
        echo "Unexpected argument: $1" >&2
        usage
      fi
      ;;
    esac
  done

  [ -z "$REPO" ] && usage
  [ -z "$REPOS_ROOT" ] && { echo "ERROR: --repos-root is required (or set REPOS_ROOT env var)" >&2; exit 2; }

  if [ ! -d "$REPO" ]; then
    echo "ERROR: repo path does not exist: $REPO" >&2
    exit 2
  fi

  if ! git -C "$REPO" rev-parse --git-dir &>/dev/null; then
    echo "ERROR: not a git repository: $REPO" >&2
    exit 2
  fi

  # _evaluate returns non-zero for stale/decayed/missing — expected behaviour.
  # Toggle -e off to capture the exit code, then re-enable.
  set +e
  _evaluate "$REPO" "$REPOS_ROOT" "$FORCE"
  rc=$?
  set -e
  _emit
  exit $rc
fi
