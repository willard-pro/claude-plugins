#!/usr/bin/env bash
# test-pipeline-finalize.sh — unit tests for lib/pipeline-finalize.sh's
# post-outcome evidence sequence (Commercial Evidence MVP, Branch B).
# Sandboxes $HOME so the postmortem script's plugin-cache lookup never
# escapes the test, and stubs `gh`/linear-api.sh where needed.
# Usage: bash test-pipeline-finalize.sh [test_name_filter]
# -u (nounset) intentionally omitted: Claude Code shell snapshots inject
# ZSH_VERSION references that trigger false-positive "unbound variable"
# errors in this bash version when nounset is active.
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

_ws=""
_setup() {
  _ws=$(mktemp -d)
  mkdir -p "$_ws/logs" "$_ws/home/.claude/plugins/cache" "$_ws/bin"
}
_teardown() { rm -rf "$_ws" 2>/dev/null || true; }

# grep -c prints "0" AND exits 1 on zero matches — `x=$(grep -c ... || echo 0)`
# double-counts that case ("0\n0"). This helper trusts grep's own count line
# and never appends a second one.
_count_kind() {
  local pattern="$1" file="$2" n
  n=$(grep -c "$pattern" "$file" 2>/dev/null || true)
  echo "${n:-0}"
}

_finalize() {
  local tid="$1" exit_code="$2" log="$3"
  PATH="$_ws/bin:$PATH" HOME="$_ws/home" bash "$LIB_DIR/pipeline-finalize.sh" "$tid" "$exit_code" "$log"
}

# ── Outcome ordering ─────────────────────────────────────────────────────────

test_outcome_remains_last_line() {
  _setup
  local log="$_ws/logs/CRE-1-pipeline.log"
  cat >"$log" <<'EOF'
2026-09-01T00:00:00Z|META|schema|info|1
2026-09-01T00:00:01Z|META|run-id|info|{"run_id":"CRE-1-a","gen":null,"trigger":"manual","pid":1}
EOF
  unset LINEAR_API_KEY
  _finalize "CRE-1" 0 "$log" >/dev/null 2>&1
  local last
  last=$(tail -1 "$log")
  local runs_lines
  runs_lines=$(wc -l <"$_ws/logs/runs.jsonl" 2>/dev/null || echo 0)
  _teardown
  echo "$last" | grep -q '|META|outcome|info|' && [ "$runs_lines" -ge 1 ]
}

test_exactly_one_run_line() {
  _setup
  local log="$_ws/logs/CRE-2-pipeline.log"
  cat >"$log" <<'EOF'
2026-09-01T00:00:00Z|META|schema|info|1
2026-09-01T00:00:01Z|META|run-id|info|{"run_id":"CRE-2-a","gen":null,"trigger":"manual","pid":1}
EOF
  unset LINEAR_API_KEY
  _finalize "CRE-2" 0 "$log" >/dev/null 2>&1
  local count
  count=$(_count_kind '"kind":"run"' "$_ws/logs/runs.jsonl")
  _teardown
  [ "$count" -eq 1 ]
}

test_idempotent_rerun_does_not_duplicate_run_event() {
  _setup
  local log="$_ws/logs/CRE-3-pipeline.log"
  cat >"$log" <<'EOF'
2026-09-01T00:00:00Z|META|schema|info|1
2026-09-01T00:00:01Z|META|run-id|info|{"run_id":"CRE-3-a","gen":null,"trigger":"manual","pid":1}
EOF
  unset LINEAR_API_KEY
  _finalize "CRE-3" 0 "$log" >/dev/null 2>&1
  _finalize "CRE-3" 0 "$log" >/dev/null 2>&1
  local count
  count=$(_count_kind '"kind":"run"' "$_ws/logs/runs.jsonl")
  _teardown
  [ "$count" -eq 1 ] || {
    echo "expected exactly 1 run event after two finalize calls, got $count"
    return 1
  }
}

test_no_linear_key_skips_human_event_only() {
  _setup
  local log="$_ws/logs/CRE-4-pipeline.log"
  cat >"$log" <<'EOF'
2026-09-01T00:00:00Z|META|schema|info|1
2026-09-01T00:00:01Z|META|run-id|info|{"run_id":"CRE-4-a","gen":null,"trigger":"manual","pid":1}
EOF
  unset LINEAR_API_KEY
  _finalize "CRE-4" 0 "$log" >/dev/null 2>&1
  local run_count human_count
  run_count=$(_count_kind '"kind":"run"' "$_ws/logs/runs.jsonl")
  human_count=$(_count_kind '"kind":"human"' "$_ws/logs/runs.jsonl")
  _teardown
  [ "$run_count" -eq 1 ] && [ "$human_count" -eq 0 ]
}

test_no_gh_skips_merge_sweep_only() {
  _setup
  # No pr in the run window at all → merge_poll_sweep must not even be
  # attempted (has_pr guard), regardless of gh availability.
  local log="$_ws/logs/CRE-5-pipeline.log"
  cat >"$log" <<'EOF'
2026-09-01T00:00:00Z|META|schema|info|1
2026-09-01T00:00:01Z|META|run-id|info|{"run_id":"CRE-5-a","gen":null,"trigger":"manual","pid":1}
EOF
  unset LINEAR_API_KEY
  _finalize "CRE-5" 0 "$log" >/dev/null 2>&1
  local merge_count
  merge_count=$(_count_kind '"kind":"merge"' "$_ws/logs/runs.jsonl")
  _teardown
  [ "$merge_count" -eq 0 ]
}

test_exit_code_preserved_nonzero() {
  _setup
  local log="$_ws/logs/CRE-6-pipeline.log"
  cat >"$log" <<'EOF'
2026-09-01T00:00:00Z|META|schema|info|1
2026-09-01T00:00:01Z|META|run-id|info|{"run_id":"CRE-6-a","gen":null,"trigger":"manual","pid":1}
2026-09-01T00:00:02Z|META|gate-stop|fail|EXEC_NO_ARTIFACT
EOF
  unset LINEAR_API_KEY
  local rc=0
  _finalize "CRE-6" 2 "$log" >/dev/null 2>&1 || rc=$?
  local outcome
  outcome=$(tail -1 "$log")
  _teardown
  [ "$rc" -eq 2 ] && echo "$outcome" | grep -q 'gate-stop EXEC_NO_ARTIFACT'
}

test_full_sequence_with_pr_and_linear_key() {
  _setup
  cat >"$_ws/bin/gh" <<'EOF'
#!/usr/bin/env bash
echo '{"state":"MERGED","mergedAt":"2026-09-02T00:00:00Z","mergeCommit":{"oid":"deadbeef"}}'
EOF
  chmod +x "$_ws/bin/gh"

  cat >"$_ws/linear-api.sh" <<'EOF'
get_issue_history() { echo '[{"id":"h1","createdAt":"2026-09-01T00:00:05Z","actor":{"id":"human-1","name":"Jane"},"botActor":null,"addedLabels":[{"name":"approved"}]}]'; }
get_comments() { echo '[]'; }
get_me() { echo '{"id":"bot-1","name":"pipeline-bot"}'; }
EOF
  local workdir="$_ws/work"
  mkdir -p "$workdir/logs"
  cp "$LIB_DIR/pipeline-finalize.sh" "$LIB_DIR/run-summary.sh" "$LIB_DIR/merge-poll.sh" "$workdir/"
  cp "$_ws/linear-api.sh" "$workdir/linear-api.sh"

  local log="$workdir/logs/CRE-7-pipeline.log"
  cat >"$log" <<'EOF'
2026-09-01T00:00:00Z|META|schema|info|1
2026-09-01T00:00:01Z|META|run-id|info|{"run_id":"CRE-7-a","gen":null,"trigger":"manual","pid":1}
2026-09-01T00:00:02Z|META|pr-created|info|{"pr":42,"url":"https://github.com/acme/repo/pull/42","repo":"acme/repo"}
EOF
  LINEAR_API_KEY=fake PATH="$_ws/bin:$PATH" HOME="$_ws/home" bash "$workdir/pipeline-finalize.sh" "CRE-7" 0 "$log" >/dev/null 2>&1
  local run_count merge_count human_count
  run_count=$(_count_kind '"kind":"run"' "$workdir/logs/runs.jsonl")
  merge_count=$(_count_kind '"kind":"merge"' "$workdir/logs/runs.jsonl")
  human_count=$(_count_kind '"kind":"human"' "$workdir/logs/runs.jsonl")
  _teardown
  [ "$run_count" -eq 1 ] && [ "$merge_count" -eq 1 ] && [ "$human_count" -eq 1 ]
}

# ═══════════════════════════════════════════════════════════════════════════════
# Dispatcher
# ═══════════════════════════════════════════════════════════════════════════════

FILTER="${1:-}"

for fn in \
  test_outcome_remains_last_line \
  test_exactly_one_run_line \
  test_idempotent_rerun_does_not_duplicate_run_event \
  test_no_linear_key_skips_human_event_only \
  test_no_gh_skips_merge_sweep_only \
  test_exit_code_preserved_nonzero \
  test_full_sequence_with_pr_and_linear_key; do
  [ -z "$FILTER" ] || [[ "$fn" == *"$FILTER"* ]] || continue
  _run "$fn" "$fn"
done

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
