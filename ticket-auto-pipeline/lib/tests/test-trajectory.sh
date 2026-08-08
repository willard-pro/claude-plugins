#!/usr/bin/env bash
# test-trajectory.sh — unit tests for lib/trajectory.sh
# Usage: bash test-trajectory.sh [test_name_filter]
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

# Source the library
# shellcheck source=../trajectory.sh
source "$LIB_DIR/trajectory.sh"

# ── Helpers ────────────────────────────────────────────────────────────────────

_ws=""
_tid="CRE-99"

_setup() {
  _ws=$(mktemp -d)
  LOG_DIR="${_ws}/logs"
  mkdir -p "$LOG_DIR"
  export LOG_DIR

  # Minimal pipeline log with phase transitions and META entries
  cat >"${LOG_DIR}/${_tid}-pipeline.log" <<'EOF'
2026-08-08T10:00:00Z|APPRAISE|setup-workspace|start|
2026-08-08T10:00:01Z|APPRAISE|setup-workspace|done|workspace ready
2026-08-08T10:00:02Z|META|verifier-result|info|{"verifier":"gate_check","verdict":"PASS","score":1.0,"criteria_met":1,"criteria_total":1,"attempt":1,"phase":"GATE"}
2026-08-08T10:00:03Z|GATE|gate|start|
2026-08-08T10:00:04Z|GATE|gate|done|gate passed
2026-08-08T10:00:05Z|META|model|info|{"phase":"IMPLEMENT","model":"claude-sonnet-4"}
2026-08-08T10:00:06Z|IMPLEMENT|run-tests|start|
2026-08-08T10:00:07Z|IMPLEMENT|run-tests|done|tests passed
EOF

  # Minimal heartbeat log
  cat >"${LOG_DIR}/${_tid}-heartbeat.log" <<'EOF'
2026-08-08T10:00:01Z|decision|auto-approve|ok|simple ticket|complexity=simple
2026-08-08T10:00:04Z|gate|entry-gate|ok|gate pass|mode=entry
EOF
}

_teardown() {
  rm -rf "$_ws" 2>/dev/null || true
}

# ── Tests ──────────────────────────────────────────────────────────────────────

test_trajectory_generates_jsonl() {
  _setup
  local out="${_ws}/trajectory.jsonl"
  traj_generate "$_tid" --output "$out"
  [ -f "$out" ] || {
    _teardown
    return 1
  }
  [ -s "$out" ] || {
    _teardown
    return 1
  }
  # Every line should be valid JSON
  while IFS= read -r line; do
    echo "$line" | jq -e . >/dev/null 2>&1 || {
      _teardown
      return 1
    }
  done <"$out"
  _teardown
}

test_trajectory_includes_phase_entries() {
  _setup
  local out="${_ws}/trajectory.jsonl"
  traj_generate "$_tid" --output "$out"
  local phase_count
  phase_count=$(grep -c '"type":"phase"' "$out" || true)
  [ "$phase_count" -ge 4 ] || {
    _teardown
    return 1
  }
  _teardown
}

test_trajectory_includes_verifier_result() {
  _setup
  local out="${_ws}/trajectory.jsonl"
  traj_generate "$_tid" --output "$out"
  grep -q '"step":"verifier-result"' "$out" || {
    _teardown
    return 1
  }
  _teardown
}

test_trajectory_includes_model() {
  _setup
  local out="${_ws}/trajectory.jsonl"
  traj_generate "$_tid" --output "$out"
  grep -q '"step":"model"' "$out" || {
    _teardown
    return 1
  }
  _teardown
}

test_trajectory_includes_heartbeat() {
  _setup
  local out="${_ws}/trajectory.jsonl"
  traj_generate "$_tid" --output "$out"
  grep -q '"type":"heartbeat"' "$out" || {
    _teardown
    return 1
  }
  _teardown
}

test_trajectory_is_idempotent() {
  _setup
  local out1="${_ws}/traj1.jsonl"
  local out2="${_ws}/traj2.jsonl"
  traj_generate "$_tid" --output "$out1"
  traj_generate "$_tid" --output "$out2"
  diff "$out1" "$out2" >/dev/null 2>&1 || {
    _teardown
    return 1
  }
  _teardown
}

test_trajectory_embedded_pipe_preserved() {
  _setup
  # Add a verifier-result with an embedded pipe in the MSG
  echo '2026-08-08T10:00:08Z|META|verifier-result|info|{"verifier":"test|pipe","verdict":"PASS","score":1.0,"criteria_met":5,"criteria_total":5,"attempt":1,"phase":"TEST"}' \
    >>"${LOG_DIR}/${_tid}-pipeline.log"
  local out="${_ws}/trajectory.jsonl"
  traj_generate "$_tid" --output "$out"
  # The payload should contain the embedded pipe (not truncated)
  grep -q 'test|pipe' "$out" || {
    _teardown
    return 1
  }
  _teardown
}

test_trajectory_missing_logs_errors() {
  _setup
  # Remove both logs
  rm -f "${LOG_DIR}/${_tid}-pipeline.log" "${LOG_DIR}/${_tid}-heartbeat.log"
  local out="${_ws}/trajectory.jsonl"
  traj_generate "$_tid" --output "$out" 2>/dev/null
  local rc=$?
  # Should return non-zero
  [ "$rc" -ne 0 ] || {
    _teardown
    return 1
  }
  _teardown
}

test_trajectory_sorts_chronologically() {
  _setup
  local out="${_ws}/trajectory.jsonl"
  traj_generate "$_tid" --output "$out"
  # Extract ISO timestamps and verify they're in order
  local timestamps
  timestamps=$(jq -r '.iso' "$out" 2>/dev/null)
  local sorted
  sorted=$(echo "$timestamps" | sort)
  diff <(echo "$timestamps") <(echo "$sorted") >/dev/null 2>&1 || {
    _teardown
    return 1
  }
  _teardown
}

# ── T1: Count-based assertions (presence checks mask duplication bugs) ───────────

test_trajectory_exact_counts() {
  _setup
  local out="${_ws}/trajectory.jsonl"
  traj_generate "$_tid" --output "$out"
  # Phase entries: 2 start + 2 done = 4 total (setup-workspace start/done, gate start/done, run-tests start/done)
  local phase_count
  phase_count=$(grep -c '"type":"phase"' "$out" || true)
  [ "$phase_count" -eq 6 ] || {
    echo "expected 6 phase entries, got $phase_count" >&2
    _teardown
    return 1
  }
  # Exactly 1 verifier-result entry
  local vr_count
  vr_count=$(grep -c '"step":"verifier-result"' "$out" || true)
  [ "$vr_count" -eq 1 ] || {
    echo "expected 1 verifier-result, got $vr_count" >&2
    _teardown
    return 1
  }
  # Exactly 1 model entry
  local model_count
  model_count=$(grep -c '"step":"model"' "$out" || true)
  [ "$model_count" -eq 1 ] || {
    echo "expected 1 model, got $model_count" >&2
    _teardown
    return 1
  }
  # Exactly 2 heartbeat entries
  local hb_count
  hb_count=$(grep -c '"type":"heartbeat"' "$out" || true)
  [ "$hb_count" -eq 2 ] || {
    echo "expected 2 heartbeat entries, got $hb_count" >&2
    _teardown
    return 1
  }
  # Total line count
  local total
  total=$(wc -l <"$out")
  [ "$total" -eq 10 ] || {
    echo "expected 10 total entries, got $total" >&2
    _teardown
    return 1
  }
  _teardown
}

# ── F1: Verify grep patterns don't cross-contaminate trajectory data ────────────

test_trajectory_no_cross_contamination() {
  _setup
  local out="${_ws}/trajectory.jsonl"
  traj_generate "$_tid" --output "$out"
  # Model entries must NOT be tagged as verifier-result
  local model_as_vr
  model_as_vr=$(jq -r 'select(.type=="meta" and .step=="verifier-result") | .payload.model // empty' "$out" 2>/dev/null || true)
  [ -z "$model_as_vr" ] || {
    echo "model data leaked into verifier-result entries" >&2
    _teardown
    return 1
  }
  # Verifier-result entries must NOT be tagged as model
  local vr_as_model
  vr_as_model=$(jq -r 'select(.type=="meta" and .step=="model") | .payload.verifier // empty' "$out" 2>/dev/null || true)
  [ -z "$vr_as_model" ] || {
    echo "verifier-result data leaked into model entries" >&2
    _teardown
    return 1
  }
  # Phase entries must NOT be tagged as meta
  local phase_as_meta
  phase_as_meta=$(jq -r 'select(.type=="phase") | .payload // empty' "$out" 2>/dev/null || true)
  [ -z "$phase_as_meta" ] || {
    echo "phase entries have payload (should only be on meta)" >&2
    _teardown
    return 1
  }
  _teardown
}

# ── T2: Empty-log pipefail shouldn't abort trajectory generation ────────────────

test_trajectory_empty_heartbeat_log() {
  _setup
  # Empty the heartbeat log (normal condition — touch at init)
  : >"${LOG_DIR}/${_tid}-heartbeat.log"
  local out="${_ws}/trajectory.jsonl"
  traj_generate "$_tid" --output "$out"
  local rc=$?
  [ "$rc" -eq 0 ] || {
    echo "traj_generate failed on empty heartbeat log (rc=$rc)" >&2
    _teardown
    return 1
  }
  [ -f "$out" ] || {
    _teardown
    return 1
  }
  # Should still have pipeline log entries
  grep -q '"type":"phase"' "$out" || {
    _teardown
    return 1
  }
  _teardown
}

test_trajectory_empty_pipeline_log() {
  _setup
  # Empty the pipeline log, keep heartbeat log
  : >"${LOG_DIR}/${_tid}-pipeline.log"
  local out="${_ws}/trajectory.jsonl"
  traj_generate "$_tid" --output "$out"
  local rc=$?
  [ "$rc" -eq 0 ] || {
    echo "traj_generate failed on empty pipeline log (rc=$rc)" >&2
    _teardown
    return 1
  }
  # Should still have heartbeat entries
  grep -q '"type":"heartbeat"' "$out" || {
    _teardown
    return 1
  }
  _teardown
}

# ── F15: Path-traversal rejection ──────────────────────────────────────────────

test_trajectory_rejects_path_traversal() {
  _setup
  local out="${_ws}/trajectory.jsonl"
  traj_generate "../../etc/passwd" --output "$out" 2>/dev/null
  local rc=$?
  [ "$rc" -ne 0 ] || {
    echo "traj_generate should reject path-traversal ticket_id" >&2
    _teardown
    return 1
  }
  _teardown
}

test_trajectory_accepts_valid_ticket_ids() {
  _setup
  # Create logs for various valid ticket IDs
  for tid in "CRE-99" "ABC-123" "my-ticket" "TASK42"; do
    mkdir -p "${LOG_DIR}"
    echo "2026-08-08T10:00:00Z|META|model|info|{\"test\":true}" >"${LOG_DIR}/${tid}-pipeline.log"
  done
  # Test one valid ID
  local out="${_ws}/trajectory.jsonl"
  traj_generate "CRE-99" --output "$out" 2>/dev/null
  local rc=$?
  [ "$rc" -eq 0 ] || {
    echo "traj_generate rejected valid ticket_id CRE-99" >&2
    _teardown
    return 1
  }
  _teardown
}

# ── Run ────────────────────────────────────────────────────────────────────────

_run "trajectory generates valid JSONL" test_trajectory_generates_jsonl
_run "trajectory includes phase transition entries" test_trajectory_includes_phase_entries
_run "trajectory includes verifier-result entries" test_trajectory_includes_verifier_result
_run "trajectory includes model entries" test_trajectory_includes_model
_run "trajectory includes heartbeat entries" test_trajectory_includes_heartbeat
_run "trajectory is idempotent (byte-identical on re-run)" test_trajectory_is_idempotent
_run "trajectory preserves embedded pipes in JSON" test_trajectory_embedded_pipe_preserved
_run "trajectory errors on missing logs" test_trajectory_missing_logs_errors
_run "trajectory entries are chronologically sorted" test_trajectory_sorts_chronologically
_run "T1: exact entry counts (not just presence)" test_trajectory_exact_counts
_run "F1: no cross-contamination between entry types" test_trajectory_no_cross_contamination
_run "T2: empty heartbeat log doesn't abort" test_trajectory_empty_heartbeat_log
_run "T2: empty pipeline log doesn't abort" test_trajectory_empty_pipeline_log
_run "F15: rejects path-traversal ticket_id" test_trajectory_rejects_path_traversal
_run "F15: accepts valid ticket IDs" test_trajectory_accepts_valid_ticket_ids

echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ] || exit 1
