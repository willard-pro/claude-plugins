#!/usr/bin/env bash
# prescan-sweep.sh — deterministic, zero-LLM repo-wide prescan freshness sweep.
#
# Answers "does anything under REPOS_ROOT need a prescan refresh?" without
# spawning a Claude session. Meant to be the cheap pre-check a cron job or
# the `schedule` skill runs before invoking the (expensive, multi-agent)
# `/ticket-prescan` maintenance run — so proactive refresh can be scheduled
# independent of any single ticket's dispatch loop, instead of relying on
# the router's per-ticket safety-net enumeration to happen to cover it.
# -u (nounset) intentionally omitted: Claude Code shell snapshots inject
# ZSH_VERSION references that trigger false-positive "unbound variable"
# errors in this bash version when nounset is active.
set -eo pipefail

if ! command -v jq &>/dev/null; then
  echo "ERROR: jq is required but not installed. Install jq and retry." >&2
  exit 3
fi

_SWEEP_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PRESCAN_CHECK="$_SWEEP_SCRIPT_DIR/prescan-check.sh"

# ── Usage ─────────────────────────────────────────────────────────────────────

usage() {
  cat >&2 <<'EOF'
Usage: prescan-sweep.sh --repos-root <path> [--format text|json]

Enumerates every git repo under REPOS_ROOT (maxdepth 3) and runs the
deterministic freshness gate (prescan-check.sh) on each. Reports counts by
status and the list of repos needing refresh — no LLM/Agent invocation.

Output (--format text, default): one line per status count, then a
NEEDS_REFRESH= line listing repo paths (space-separated) that are
stale, decayed, or missing.

Output (--format json): a single JSON object:
  {"total":N,"fresh":N,"stale":N,"decayed":N,"missing":N,
   "needs_refresh":["<repo-path>", ...]}

Exit codes: 0 all fresh (nothing to do), 1 one or more repos need refresh,
2 on error (bad/missing REPOS_ROOT).
EOF
  exit 2
}

# ── Repo enumeration ──────────────────────────────────────────────────────────
# Mirrors prescan-route.sh --mode repos / ticket-auto's safety-net enumeration:
# -type d excludes git-worktree ".git" *files* (worktree pointer files), which
# would otherwise resolve to bogus ancestor paths via dirname.

_enumerate_repos() {
  local repos_root="$1"
  find "$repos_root" -maxdepth 3 -name ".git" -type d -printf '%h\0' 2>/dev/null || true
}

# ── Main sweep ────────────────────────────────────────────────────────────────

_sweep() {
  local repos_root="$1" format="$2"
  local total=0 fresh=0 stale=0 decayed=0 missing=0
  local needs_refresh=()

  local repo
  while IFS= read -r -d '' repo; do
    total=$((total + 1))
    local out status
    out=$(bash "$PRESCAN_CHECK" "$repo" --repos-root "$repos_root" 2>/dev/null) || true
    status=$(echo "$out" | grep '^PRESCAN_STATUS=' | cut -d= -f2- | tr -d "'\"")

    case "$status" in
    fresh)
      fresh=$((fresh + 1))
      ;;
    stale)
      stale=$((stale + 1))
      needs_refresh+=("$repo")
      ;;
    decayed)
      decayed=$((decayed + 1))
      needs_refresh+=("$repo")
      ;;
    missing | *)
      missing=$((missing + 1))
      needs_refresh+=("$repo")
      ;;
    esac
  done < <(_enumerate_repos "$repos_root")

  if [ "$format" = "json" ]; then
    local needs_json
    needs_json=$(printf '%s\n' "${needs_refresh[@]}" | jq -R . | jq -s .)
    jq -n \
      --argjson total "$total" \
      --argjson fresh "$fresh" \
      --argjson stale "$stale" \
      --argjson decayed "$decayed" \
      --argjson missing "$missing" \
      --argjson needs_refresh "$needs_json" \
      '{total: $total, fresh: $fresh, stale: $stale, decayed: $decayed, missing: $missing, needs_refresh: $needs_refresh}'
  else
    echo "TOTAL=$total"
    echo "FRESH=$fresh"
    echo "STALE=$stale"
    echo "DECAYED=$decayed"
    echo "MISSING=$missing"
    printf 'NEEDS_REFRESH=%s\n' "${needs_refresh[*]}"
  fi

  [ ${#needs_refresh[@]} -eq 0 ]
}

# ── Main dispatch ─────────────────────────────────────────────────────────────

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  REPOS_ROOT_ARG="${REPOS_ROOT:-}"
  FORMAT="text"

  while [[ $# -gt 0 ]]; do
    case "$1" in
    --repos-root)
      REPOS_ROOT_ARG="${2:-}"
      shift 2
      ;;
    --format)
      FORMAT="${2:-text}"
      shift 2
      ;;
    --help | -h) usage ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      ;;
    esac
  done

  [ -z "$REPOS_ROOT_ARG" ] && {
    echo "ERROR: --repos-root is required (or set REPOS_ROOT env var)" >&2
    exit 2
  }

  if [ ! -d "$REPOS_ROOT_ARG" ]; then
    echo "ERROR: REPOS_ROOT does not exist: $REPOS_ROOT_ARG" >&2
    exit 2
  fi

  case "$FORMAT" in
  text | json) ;;
  *)
    echo "ERROR: --format must be 'text' or 'json'" >&2
    exit 2
    ;;
  esac

  set +e
  _sweep "$REPOS_ROOT_ARG" "$FORMAT"
  rc=$?
  set -e
  [ $rc -eq 0 ] && exit 0
  exit 1
fi
