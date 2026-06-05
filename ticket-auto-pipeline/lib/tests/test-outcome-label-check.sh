#!/usr/bin/env bash
# test-outcome-label-check.sh — unit tests for lib/outcome-label-check.sh
# Usage: bash test-outcome-label-check.sh [test_name_filter]
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

# ── Mock framework ──────────────────────────────────────────────────────────────

_ws=""       # workspace dir
_tid=""      # ticket ID
_flow_log="" # tracks flow.sh calls
_fake_issue="null"

_setup() {
  _ws=$(mktemp -d)
  _tid="CRE-47"
  _flow_log="${_ws}/flow-calls.log"
  touch "$_flow_log"
  _fake_issue="null"

  LOG_FILE="${_ws}/${_tid}-pipeline.log"
  TICKET_ID="$_tid"

  _install_mocks
}

_teardown() {
  rm -rf "$_ws" 2>/dev/null || true
}

_install_mocks() {
  get_issue() { echo "$_fake_issue"; }
  _resolve_flow_sh() { echo "${_ws}/mock-flow.sh"; }
  FLOW_SH="${_ws}/mock-flow.sh"

  cat >"${_ws}/mock-flow.sh" <<FLOWEOF
#!/usr/bin/env bash
echo "flow-sh-called|\$*" >> "${_ws}/flow-calls.log"
exit 0
FLOWEOF
  chmod +x "${_ws}/mock-flow.sh"
}

# ── Scaffold ───────────────────────────────────────────────────────────────────

_plog_raw() {
  local phase="$1" step="$2" status="$3" msg="$4"
  local iso="${5:-2026-06-05T10:00:00Z}"
  echo "${iso}|${phase}|${step}|${status}|${msg}" >>"$LOG_FILE"
}

# ── Source outcome-label-check.sh ──────────────────────────────────────────────

source "$LIB_DIR/outcome-label-check.sh"

# ═══════════════════════════════════════════════════════════════════════════════
# Tests (5)
# ═══════════════════════════════════════════════════════════════════════════════

# 1. Smooth label already present → exit 0, no flow.sh call
test_outcome_smooth_present_exits_0() {
  _setup
  _plog_raw "IMPLEMENT" "implement" "done" "Smooth"
  _fake_issue='{"id":"CRE-47","title":"Test","labels":{"nodes":[{"name":"Smooth"},{"name":"bug"}]}}'

  _outcome_label_check
  local rc=$?
  local flow_calls
  flow_calls=$(cat "$_flow_log" 2>/dev/null || true)

  _teardown
  [ "$rc" -eq 0 ] || {
    echo "expected exit 0, got $rc"
    return 1
  }
  [ -z "$flow_calls" ] || {
    echo "flow.sh should not be called"
    return 1
  }
}

# 2. Rough label already present → exit 0, no flow.sh call
test_outcome_rough_present_exits_0() {
  _setup
  _plog_raw "IMPLEMENT" "implement" "done" "Rough"
  _fake_issue='{"id":"CRE-47","title":"Test","labels":{"nodes":[{"name":"Rough"}]}}'

  _outcome_label_check
  local rc=$?

  _teardown
  [ "$rc" -eq 0 ] || {
    echo "expected exit 0, got $rc"
    return 1
  }
}

# 3. Hard label already present → exit 0, no flow.sh call
test_outcome_hard_present_exits_0() {
  _setup
  _plog_raw "IMPLEMENT" "implement" "done" "Hard"
  _fake_issue='{"id":"CRE-47","title":"Test","labels":{"nodes":[{"name":"Hard"}]}}'

  _outcome_label_check
  local rc=$?

  _teardown
  [ "$rc" -eq 0 ] || {
    echo "expected exit 0, got $rc"
    return 1
  }
}

# 4. Label missing → calls flow.sh implement-outcome
test_outcome_label_missing_calls_flow() {
  _setup
  _plog_raw "IMPLEMENT" "implement" "done" "Rough"
  _fake_issue='{"id":"CRE-47","title":"Test","labels":{"nodes":[{"name":"bug"}]}}'

  _outcome_label_check
  local rc=$?
  local flow_calls
  flow_calls=$(cat "$_flow_log" 2>/dev/null || true)

  _teardown
  [ "$rc" -eq 0 ] || {
    echo "expected exit 0, got $rc"
    return 1
  }
  echo "$flow_calls" | grep -q "implement-outcome" || {
    echo "flow.sh implement-outcome not called"
    return 1
  }
  echo "$flow_calls" | grep -q "outcome=Rough" || {
    echo "outcome=Rough not found in flow.sh args"
    return 1
  }
}

# 5. Outcome read from pipeline log
test_outcome_read_from_pipeline_log() {
  _setup
  _plog_raw "IMPLEMENT" "implement" "done" "Smooth"
  _fake_issue='{"id":"CRE-47","title":"Test","labels":{"nodes":[{"name":"bug"}]}}'

  _outcome_label_check
  local rc=$?
  local flow_calls
  flow_calls=$(cat "$_flow_log" 2>/dev/null || true)

  _teardown
  [ "$rc" -eq 0 ] || {
    echo "expected exit 0, got $rc"
    return 1
  }
  echo "$flow_calls" | grep -q "outcome=Smooth" || {
    echo "outcome=Smooth not found in flow.sh args"
    return 1
  }
}

# ═══════════════════════════════════════════════════════════════════════════════
# Dispatcher
# ═══════════════════════════════════════════════════════════════════════════════

FILTER="${1:-}"

for fn in \
  test_outcome_smooth_present_exits_0 \
  test_outcome_rough_present_exits_0 \
  test_outcome_hard_present_exits_0 \
  test_outcome_label_missing_calls_flow \
  test_outcome_read_from_pipeline_log; do
  [ -z "$FILTER" ] || [[ "$fn" == *"$FILTER"* ]] || continue
  _run "$fn" "$fn"
done

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
