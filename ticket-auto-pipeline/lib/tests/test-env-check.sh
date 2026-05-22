#!/usr/bin/env bash
# test-env-check.sh — unit tests for lib/env-check.sh
# Targets env-check.sh directly (validate-env.sh is just a thin wrapper).
# Usage: bash test-env-check.sh [test_name_filter]
set -euo pipefail

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

# Create a minimal valid project dir with CLAUDE.md and settings.json
_mk_project_dir() {
  local dir="$1"
  mkdir -p "$dir/.claude"
  cat >"$dir/CLAUDE.md" <<'EOF'
REPOS_ROOT=/tmp/test-repos
LOCAL_URL=http://localhost:3000
UAT_URL=http://uat.example.com
EOF
  cat >"$dir/.claude/settings.json" <<'EOF'
{
  "hooks": {
    "SubagentStart": [{"hooks": [{"command": "token-tracker-start.sh"}]}],
    "SubagentStop":  [{"hooks": [{"command": "token-tracker.sh"}]}]
  }
}
EOF
}

# ── validate mode tests ───────────────────────────────────────────────────────

test_validate_passes_all_required() {
  local tmpdir
  tmpdir=$(mktemp -d)
  _mk_project_dir "$tmpdir"
  local exit_code=0
  (LINEAR_API_KEY=test GITHUB_PERSONAL_ACCESS_TOKEN=test \
    bash "$LIB_DIR/env-check.sh" --mode=validate "$tmpdir") >/dev/null 2>&1 || exit_code=$?
  rm -rf "$tmpdir"
  [ "$exit_code" -eq 0 ]
}

test_validate_fails_missing_linear_key() {
  local tmpdir
  tmpdir=$(mktemp -d)
  _mk_project_dir "$tmpdir"
  local exit_code=0
  (
    unset LINEAR_API_KEY
    GITHUB_PERSONAL_ACCESS_TOKEN=test \
      bash "$LIB_DIR/env-check.sh" --mode=validate "$tmpdir"
  ) >/dev/null 2>&1 || exit_code=$?
  rm -rf "$tmpdir"
  [ "$exit_code" -ne 0 ]
}

test_validate_fails_missing_github_token() {
  local tmpdir
  tmpdir=$(mktemp -d)
  _mk_project_dir "$tmpdir"
  local exit_code=0
  (
    unset GITHUB_PERSONAL_ACCESS_TOKEN
    LINEAR_API_KEY=test \
      bash "$LIB_DIR/env-check.sh" --mode=validate "$tmpdir"
  ) >/dev/null 2>&1 || exit_code=$?
  rm -rf "$tmpdir"
  [ "$exit_code" -ne 0 ]
}

test_validate_warns_missing_optional() {
  # SLACK_CHANNEL absent — should warn but still exit 0
  local tmpdir
  tmpdir=$(mktemp -d)
  _mk_project_dir "$tmpdir"
  # No SLACK_CHANNEL in CLAUDE.md (default _mk_project_dir doesn't add it)
  local exit_code=0
  (LINEAR_API_KEY=test GITHUB_PERSONAL_ACCESS_TOKEN=test \
    bash "$LIB_DIR/env-check.sh" --mode=validate "$tmpdir") >/dev/null 2>&1 || exit_code=$?
  rm -rf "$tmpdir"
  [ "$exit_code" -eq 0 ]
}

# ── full mode tests ───────────────────────────────────────────────────────────

test_full_mode_emits_begin_end_sentinels() {
  local tmpdir
  tmpdir=$(mktemp -d)
  _mk_project_dir "$tmpdir"
  local output
  output=$(LINEAR_API_KEY=test GITHUB_PERSONAL_ACCESS_TOKEN=test \
    bash "$LIB_DIR/env-check.sh" --mode=full "$tmpdir" 2>/dev/null || true)
  rm -rf "$tmpdir"
  echo "$output" | grep -q -e '---BEGIN_VARS---' && echo "$output" | grep -q -e '---END_VARS---'
}

test_full_mode_rowcount_matches_var_lines() {
  local tmpdir
  tmpdir=$(mktemp -d)
  _mk_project_dir "$tmpdir"
  local output
  output=$(LINEAR_API_KEY=test GITHUB_PERSONAL_ACCESS_TOKEN=test \
    bash "$LIB_DIR/env-check.sh" --mode=full "$tmpdir" 2>/dev/null || true)
  rm -rf "$tmpdir"

  local rowcount
  rowcount=$(echo "$output" | grep '^ROWCOUNT=' | sed 's/ROWCOUNT=//')
  local var_count
  var_count=$(echo "$output" |
    awk '/---BEGIN_VARS---/{p=1;next}/---END_VARS---/{p=0}p' |
    grep -v '^NAME|' |
    grep -v '^ROWCOUNT=' |
    grep -c '|' || true)

  [ -n "$rowcount" ] && [ "$rowcount" -eq "$var_count" ]
}

test_full_mode_gh_token_derived() {
  local tmpdir
  tmpdir=$(mktemp -d)
  _mk_project_dir "$tmpdir"
  local output
  output=$(
    unset GH_TOKEN 2>/dev/null || true
    LINEAR_API_KEY=test GITHUB_PERSONAL_ACCESS_TOKEN=test \
      bash "$LIB_DIR/env-check.sh" --mode=full "$tmpdir" 2>/dev/null || true
  )
  rm -rf "$tmpdir"
  echo "$output" | grep 'GH_TOKEN' | grep -q 'auto'
}

test_full_mode_local_url_env_priority() {
  local tmpdir
  tmpdir=$(mktemp -d)
  _mk_project_dir "$tmpdir"
  local output
  output=$(LINEAR_API_KEY=test GITHUB_PERSONAL_ACCESS_TOKEN=test LOCAL_URL=http://env-priority.test \
    bash "$LIB_DIR/env-check.sh" --mode=full "$tmpdir" 2>/dev/null || true)
  rm -rf "$tmpdir"
  echo "$output" | grep 'LOCAL_URL' | grep -q 'http://env-priority.test'
}

test_full_mode_ticket_autonomy_warn() {
  local tmpdir
  tmpdir=$(mktemp -d)
  _mk_project_dir "$tmpdir"
  local output
  output=$(
    unset TICKET_AUTONOMY 2>/dev/null || true
    LINEAR_API_KEY=test GITHUB_PERSONAL_ACCESS_TOKEN=test \
      bash "$LIB_DIR/env-check.sh" --mode=full "$tmpdir" 2>/dev/null || true
  )
  rm -rf "$tmpdir"
  echo "$output" | grep 'TICKET_AUTONOMY' | grep -q 'warn'
}

# ── argument parsing edge cases ───────────────────────────────────────────────

test_unknown_mode_exits_1() {
  local exit_code=0
  bash "$LIB_DIR/env-check.sh" --mode=garbage >/dev/null 2>&1 || exit_code=$?
  [ "$exit_code" -eq 1 ]
}

test_summary_file_flag_writes_to_path() {
  local tmpdir
  tmpdir=$(mktemp -d)
  _mk_project_dir "$tmpdir"
  local summary_file="$tmpdir/summary.txt"
  local stdout_output
  stdout_output=$(LINEAR_API_KEY=test GITHUB_PERSONAL_ACCESS_TOKEN=test \
    bash "$LIB_DIR/env-check.sh" --mode=full --summary-file="$summary_file" "$tmpdir" 2>/dev/null || true)
  local ok=0
  [ -f "$summary_file" ] && echo "$stdout_output" | grep -q "Summary written to" || ok=1
  rm -rf "$tmpdir"
  [ "$ok" -eq 0 ]
}

# ── dispatch ──────────────────────────────────────────────────────────────────

FILTER="${1:-}"

for fn in \
  test_validate_passes_all_required \
  test_validate_fails_missing_linear_key \
  test_validate_fails_missing_github_token \
  test_validate_warns_missing_optional \
  test_full_mode_emits_begin_end_sentinels \
  test_full_mode_rowcount_matches_var_lines \
  test_full_mode_gh_token_derived \
  test_full_mode_local_url_env_priority \
  test_full_mode_ticket_autonomy_warn \
  test_unknown_mode_exits_1 \
  test_summary_file_flag_writes_to_path; do
  [ -z "$FILTER" ] || [[ "$fn" == *"$FILTER"* ]] || continue
  _run "$fn" "$fn"
done

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
