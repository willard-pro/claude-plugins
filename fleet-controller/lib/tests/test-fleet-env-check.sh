#!/usr/bin/env bash
# test-fleet-env-check.sh — unit tests for lib/fleet-env-check.sh
# Usage: bash test-fleet-env-check.sh [test_name_filter]
# -u (nounset) intentionally omitted — see ticket-auto-pipeline's
# test-env-check.sh for the harness shell-snapshot rationale.
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

PASS=0
FAIL=0

_run() {
  local name="$1"
  shift
  if "$@" 2>/dev/null; then
    echo "PASS: $name"
    ((PASS++)) || true
  else
    echo "FAIL: $name"
    ((FAIL++)) || true
  fi
}

_mk_project_dir() {
  local dir="$1"
  mkdir -p "$dir/child-a/.git" "$dir/child-b/.git"
  cat >"$dir/CLAUDE.md" <<EOF
REPOS_ROOT=$dir
EOF
}

_env_vars() {
  bash "$LIB_DIR/fleet-env-check.sh" "$@" 2>/dev/null
}

_row() {
  # _row OUTPUT NAME — prints the pipe-delimited row for NAME
  echo "$1" | grep "^$2|"
}

# ── LINEAR_API_KEY ────────────────────────────────────────────────────────────

test_linear_key_present_masks_value() {
  local tmpdir out
  tmpdir=$(mktemp -d)
  _mk_project_dir "$tmpdir"
  out=$(LINEAR_API_KEY=abcd1234EFGH _env_vars "$tmpdir")
  rm -rf "$tmpdir"
  local row
  row=$(_row "$out" "LINEAR_API_KEY")
  [[ "$row" == "LINEAR_API_KEY|ok|"*"|"* ]] && [[ "$row" == *"****EFGH"* ]] && [[ "$row" != *"abcd1234EFGH"* ]]
}

test_linear_key_missing_is_issue() {
  local tmpdir out exit_code=0
  tmpdir=$(mktemp -d)
  _mk_project_dir "$tmpdir"
  out=$(
    unset LINEAR_API_KEY
    bash "$LIB_DIR/fleet-env-check.sh" "$tmpdir" 2>/dev/null
  ) || exit_code=$?
  rm -rf "$tmpdir"
  [[ "$(_row "$out" "LINEAR_API_KEY")" == *"|missing|"* ]] && [ "$exit_code" -gt 0 ]
}

# ── GITHUB_PERSONAL_ACCESS_TOKEN (conditional on FLEET_EPIC_AUTO_PR) ─────────

test_github_token_optional_when_auto_pr_off() {
  local tmpdir out exit_code=0
  tmpdir=$(mktemp -d)
  _mk_project_dir "$tmpdir"
  out=$(
    unset GITHUB_PERSONAL_ACCESS_TOKEN
    LINEAR_API_KEY=x FLEET_EPIC_AUTO_PR=false bash "$LIB_DIR/fleet-env-check.sh" "$tmpdir" 2>/dev/null
  ) || exit_code=$?
  rm -rf "$tmpdir"
  [[ "$(_row "$out" "GITHUB_PERSONAL_ACCESS_TOKEN")" == *"|warn|"* ]]
}

test_github_token_required_when_auto_pr_on() {
  local tmpdir out exit_code=0
  tmpdir=$(mktemp -d)
  _mk_project_dir "$tmpdir"
  out=$(
    unset GITHUB_PERSONAL_ACCESS_TOKEN
    LINEAR_API_KEY=x FLEET_EPIC_AUTO_PR=true bash "$LIB_DIR/fleet-env-check.sh" "$tmpdir" 2>/dev/null
  ) || exit_code=$?
  rm -rf "$tmpdir"
  [[ "$(_row "$out" "GITHUB_PERSONAL_ACCESS_TOKEN")" == *"|missing|"* ]] && [ "$exit_code" -gt 0 ]
}

test_github_token_masks_value() {
  local tmpdir out
  tmpdir=$(mktemp -d)
  _mk_project_dir "$tmpdir"
  out=$(LINEAR_API_KEY=x GITHUB_PERSONAL_ACCESS_TOKEN=ghp_wxyz9999 _env_vars "$tmpdir")
  rm -rf "$tmpdir"
  [[ "$(_row "$out" "GITHUB_PERSONAL_ACCESS_TOKEN")" == *"****9999"* ]] && [[ "$out" != *"ghp_wxyz9999"* ]]
}

# ── REPOS_ROOT ────────────────────────────────────────────────────────────────

test_repos_root_ok_when_declared() {
  local tmpdir out
  tmpdir=$(mktemp -d)
  _mk_project_dir "$tmpdir"
  out=$(LINEAR_API_KEY=x _env_vars "$tmpdir")
  rm -rf "$tmpdir"
  [[ "$(_row "$out" "REPOS_ROOT")" == "REPOS_ROOT|ok|$tmpdir|"* ]]
}

test_repos_root_missing_when_no_claude_md() {
  local tmpdir out exit_code=0
  tmpdir=$(mktemp -d)
  out=$(LINEAR_API_KEY=x bash "$LIB_DIR/fleet-env-check.sh" "$tmpdir" 2>/dev/null) || exit_code=$?
  rm -rf "$tmpdir"
  [[ "$(_row "$out" "CLAUDE.md")" == *"|missing|"* ]] && [ "$exit_code" -gt 0 ]
}

# ── CLAUDE_BIN / CLAUDE_CMD ───────────────────────────────────────────────────

test_claude_bin_default_ok_when_resolvable() {
  local tmpdir out
  tmpdir=$(mktemp -d)
  _mk_project_dir "$tmpdir"
  out=$(
    unset CLAUDE_CMD CLAUDE_BIN
    LINEAR_API_KEY=x bash "$LIB_DIR/fleet-env-check.sh" "$tmpdir" 2>/dev/null | sed -n '/CLAUDE_BIN|/p'
  ) || true
  rm -rf "$tmpdir"
  # 'claude' won't be on PATH in CI — accept either ok or missing, just confirm the row exists.
  [[ -n "$out" ]]
}

test_claude_cmd_overrides_and_resolves() {
  local tmpdir out
  tmpdir=$(mktemp -d)
  _mk_project_dir "$tmpdir"
  out=$(LINEAR_API_KEY=x CLAUDE_CMD="bash 2 --bypass" _env_vars "$tmpdir")
  rm -rf "$tmpdir"
  [[ "$(_row "$out" "CLAUDE_CMD")" == "CLAUDE_CMD|ok|bash 2 --bypass|"* ]]
}

test_claude_cmd_missing_binary_is_issue() {
  local tmpdir out exit_code=0
  tmpdir=$(mktemp -d)
  _mk_project_dir "$tmpdir"
  out=$(LINEAR_API_KEY=x CLAUDE_CMD="totally-not-a-real-binary --flag" bash "$LIB_DIR/fleet-env-check.sh" "$tmpdir" 2>/dev/null) || exit_code=$?
  rm -rf "$tmpdir"
  [[ "$(_row "$out" "CLAUDE_CMD")" == *"|missing|"* ]] && [ "$exit_code" -gt 0 ]
}

# ── CLI tools ─────────────────────────────────────────────────────────────────

test_jq_ok_when_present() {
  local tmpdir out
  tmpdir=$(mktemp -d)
  _mk_project_dir "$tmpdir"
  out=$(LINEAR_API_KEY=x _env_vars "$tmpdir")
  rm -rf "$tmpdir"
  [[ "$(_row "$out" "jq")" == *"|ok|"* ]]
}

test_gh_required_only_when_auto_pr_on() {
  local tmpdir out
  tmpdir=$(mktemp -d)
  _mk_project_dir "$tmpdir"
  out=$(LINEAR_API_KEY=x FLEET_EPIC_AUTO_PR=true _env_vars "$tmpdir")
  rm -rf "$tmpdir"
  [[ "$(_row "$out" "gh")" == *"required — FLEET_EPIC_AUTO_PR=true"* ]]
}

# ── Output contract ───────────────────────────────────────────────────────────

test_rowcount_matches_emitted_rows() {
  local tmpdir out declared actual
  tmpdir=$(mktemp -d)
  _mk_project_dir "$tmpdir"
  out=$(LINEAR_API_KEY=x _env_vars "$tmpdir")
  rm -rf "$tmpdir"
  declared=$(echo "$out" | grep -oP 'ROWCOUNT=\K[0-9]+')
  actual=$(echo "$out" | sed -n '/^---BEGIN_VARS---$/,/^---END_VARS---$/p' | grep -c '|')
  # actual includes the header row (ROWCOUNT= has no '|' so it isn't counted); subtract 1.
  actual=$((actual - 1))
  [ "$declared" -eq "$actual" ]
}

test_summary_file_written() {
  local tmpdir summary
  tmpdir=$(mktemp -d)
  _mk_project_dir "$tmpdir"
  summary="$tmpdir/summary.txt"
  LINEAR_API_KEY=x bash "$LIB_DIR/fleet-env-check.sh" "$tmpdir" --summary-file "$summary" >/dev/null 2>&1 || true
  local ok=1
  [ -f "$summary" ] && grep -q '^---BEGIN_VARS---$' "$summary" && ok=0
  rm -rf "$tmpdir"
  [ "$ok" -eq 0 ]
}

# ── Worker permission mode (worker-reap-recovery, task 2.7) ─────────────────

test_permission_mode_missing_when_not_configured() {
  local tmpdir out
  tmpdir=$(mktemp -d)
  _mk_project_dir "$tmpdir"
  out=$(
    unset CLAUDE_CMD
    LINEAR_API_KEY=x _env_vars "$tmpdir"
  )
  rm -rf "$tmpdir"
  [[ "$(_row "$out" "FLEET_WORKER_PERMISSION_MODE")" == *"|missing|"* ]]
}

test_permission_mode_ok_when_claude_cmd_specifies_one() {
  local tmpdir out
  tmpdir=$(mktemp -d)
  _mk_project_dir "$tmpdir"
  out=$(LINEAR_API_KEY=x CLAUDE_CMD="bash --dangerously-skip-permissions" _env_vars "$tmpdir")
  rm -rf "$tmpdir"
  [[ "$(_row "$out" "FLEET_WORKER_PERMISSION_MODE")" == *"|ok|"* ]]
}

test_not_root_ok_for_normal_user() {
  local tmpdir out
  tmpdir=$(mktemp -d)
  _mk_project_dir "$tmpdir"
  out=$(LINEAR_API_KEY=x _env_vars "$tmpdir")
  rm -rf "$tmpdir"
  [[ "$(_row "$out" "FLEETD_NOT_ROOT")" == *"|ok|"* ]]
}

test_claude_code_simple_ok_when_unset() {
  local tmpdir out
  tmpdir=$(mktemp -d)
  _mk_project_dir "$tmpdir"
  out=$(
    unset CLAUDE_CODE_SIMPLE
    LINEAR_API_KEY=x _env_vars "$tmpdir"
  )
  rm -rf "$tmpdir"
  [[ "$(_row "$out" "CLAUDE_CODE_SIMPLE")" == *"|ok|"* ]]
}

test_claude_code_simple_missing_when_bare_active() {
  local tmpdir out exit_code=0
  tmpdir=$(mktemp -d)
  _mk_project_dir "$tmpdir"
  out=$(LINEAR_API_KEY=x CLAUDE_CODE_SIMPLE=1 bash "$LIB_DIR/fleet-env-check.sh" "$tmpdir" 2>/dev/null) || exit_code=$?
  rm -rf "$tmpdir"
  [[ "$(_row "$out" "CLAUDE_CODE_SIMPLE")" == *"|missing|"* ]] && [ "$exit_code" -gt 0 ]
}

test_restricted_missing_when_active() {
  local tmpdir out exit_code=0
  tmpdir=$(mktemp -d)
  _mk_project_dir "$tmpdir"
  out=$(LINEAR_API_KEY=x CLAUDE_CODE_RESTRICTED=true bash "$LIB_DIR/fleet-env-check.sh" "$tmpdir" 2>/dev/null) || exit_code=$?
  rm -rf "$tmpdir"
  [[ "$(_row "$out" "CLAUDE_CODE_RESTRICTED")" == *"|missing|"* ]] && [ "$exit_code" -gt 0 ]
}

test_permission_probe_skipped_by_default() {
  # The live probe must never run unless explicitly opted in — it would
  # otherwise execute CLAUDE_CMD's real argv on every env-check invocation,
  # including inside make test where CLAUDE_CMD is often a test stub.
  local tmpdir out
  tmpdir=$(mktemp -d)
  _mk_project_dir "$tmpdir"
  out=$(
    unset FLEET_ENV_CHECK_LIVE_PROBE
    LINEAR_API_KEY=x CLAUDE_CMD="bash 2 --bypass" _env_vars "$tmpdir"
  )
  rm -rf "$tmpdir"
  [[ "$(_row "$out" "FLEET_WORKER_PERMISSION_PROBE")" == *"|info|"* ]]
}

# ═══════════════════════════════════════════════════════════════════════════════
# Runner
# ═══════════════════════════════════════════════════════════════════════════════

FILTER="${1:-}"
for fn in \
  test_linear_key_present_masks_value \
  test_linear_key_missing_is_issue \
  test_github_token_optional_when_auto_pr_off \
  test_github_token_required_when_auto_pr_on \
  test_github_token_masks_value \
  test_repos_root_ok_when_declared \
  test_repos_root_missing_when_no_claude_md \
  test_claude_bin_default_ok_when_resolvable \
  test_claude_cmd_overrides_and_resolves \
  test_claude_cmd_missing_binary_is_issue \
  test_jq_ok_when_present \
  test_gh_required_only_when_auto_pr_on \
  test_rowcount_matches_emitted_rows \
  test_summary_file_written \
  test_permission_mode_missing_when_not_configured \
  test_permission_mode_ok_when_claude_cmd_specifies_one \
  test_not_root_ok_for_normal_user \
  test_claude_code_simple_ok_when_unset \
  test_claude_code_simple_missing_when_bare_active \
  test_restricted_missing_when_active \
  test_permission_probe_skipped_by_default; do
  [ -z "$FILTER" ] || [[ "$fn" == *"$FILTER"* ]] || continue
  _run "$fn" "$fn"
done

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
