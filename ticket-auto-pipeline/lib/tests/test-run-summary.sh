#!/usr/bin/env bash
# test-run-summary.sh — unit tests for lib/run-summary.sh
# (Commercial Evidence MVP, Branch B — runs.jsonl `run` event summarizer)
# Usage: bash test-run-summary.sh [test_name_filter]
# -u (nounset) intentionally omitted: Claude Code shell snapshots inject
# ZSH_VERSION references that trigger false-positive "unbound variable"
# errors in this bash version when nounset is active.
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$LIB_DIR/run-summary.sh"

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
_setup() { _ws=$(mktemp -d); }
_teardown() { rm -rf "$_ws" 2>/dev/null || true; }

# ── run_summary_window ───────────────────────────────────────────────────────

test_window_isolates_current_run() {
  _setup
  local log="$_ws/CRE-1-pipeline.log"
  cat >"$log" <<'EOF'
2026-09-01T00:00:00Z|META|schema|info|1
2026-09-01T00:00:01Z|META|run-id|info|{"run_id":"CRE-1-a","gen":null,"trigger":"manual","pid":1}
2026-09-01T00:00:02Z|VERIFY|verify|fail|FAIL
2026-09-01T00:00:03Z|VERIFY|verify|fail|FAIL
2026-09-01T00:00:04Z|META|outcome|info|held: gate
2026-09-01T02:00:00Z|META|run-id|info|{"run_id":"CRE-1-b","gen":null,"trigger":"manual","pid":2}
2026-09-01T02:00:01Z|VERIFY|verify|fail|FAIL
2026-09-01T02:00:02Z|META|outcome|info|completed: STEP_6
EOF
  local window
  window=$(run_summary_window "$log")
  _teardown
  local n
  n=$(echo "$window" | grep -c '|VERIFY|verify|fail|')
  [ "$n" -eq 1 ] || {
    echo "expected window to contain only the later run's 1 verify-fail, got $n"
    return 1
  }
  echo "$window" | head -1 | grep -q 'CRE-1-b'
}

test_window_falls_back_to_whole_log_without_run_id() {
  _setup
  local log="$_ws/CRE-2-pipeline.log"
  cat >"$log" <<'EOF'
2026-09-01T00:00:00Z|META|schema|info|1
2026-09-01T00:00:01Z|VERIFY|verify|fail|FAIL
EOF
  local window
  window=$(run_summary_window "$log")
  _teardown
  echo "$window" | grep -q 'schema'
}

# ── versions passthrough ─────────────────────────────────────────────────────

# run-summary.sh copies the whole META|version object into the run record's
# `versions` field rather than picking fields out of it. That is the reason the
# skill fingerprints reach runs.jsonl with no change to this file, so it is
# worth an explicit assertion: if someone ever narrows the copy to a field list,
# this fails instead of the fingerprints silently disappearing downstream.
test_json_versions_carries_skill_fingerprints_verbatim() {
  _setup
  local log="$_ws/CRE-20-pipeline.log"
  cat >"$log" <<'EOF'
2026-09-01T00:00:00Z|META|schema|info|1
2026-09-01T00:00:01Z|META|run-id|info|{"run_id":"CRE-20-a","gen":null,"trigger":"manual","pid":1}
2026-09-01T00:00:02Z|META|version|info|{"ticket_auto":"0.42.0","fleet":null,"cc":"1.0.0","model_default":null,"skills":{"ticket-implement":{"sha256":"aaa111","manifest_n":6},"ticket-verify":{"sha256":"unresolved","manifest_n":8,"missing":["lib:skill-preamble-auto.md"]}},"skills_unresolved":1}
2026-09-01T00:00:03Z|META|outcome|info|completed: STEP_6
EOF
  local json log_skills rec_skills
  json=$(run_summary_json CRE-20 "$log" 0)

  log_skills=$(grep '|META|version|info|' "$log" | cut -d'|' -f5- | jq -cS '.skills')
  rec_skills=$(echo "$json" | jq -cS '.versions.skills')
  _teardown

  [ "$log_skills" = "$rec_skills" ] || {
    echo "versions.skills does not match the log line's skills object"
    echo "  log:    $log_skills"
    echo "  record: $rec_skills"
    return 1
  }
  [ "$(echo "$json" | jq -r '.versions.skills_unresolved')" = "1" ] || {
    echo "skills_unresolved did not survive the copy"
    return 1
  }
  # The `missing` array is part of the object and must not be projected away.
  [ "$(echo "$json" | jq -r '.versions.skills["ticket-verify"].missing[0]')" = "lib:skill-preamble-auto.md" ]
}

# Two runs whose ticket-implement fingerprint differs must be separable by a
# plain jq group-by — the whole point of carrying the field.
test_json_versions_groupable_by_skill_revision() {
  _setup
  local log_a="$_ws/CRE-21-pipeline.log" log_b="$_ws/CRE-22-pipeline.log" runs="$_ws/runs.jsonl" n
  cat >"$log_a" <<'EOF'
2026-09-01T00:00:01Z|META|run-id|info|{"run_id":"CRE-21-a","gen":null,"trigger":"manual","pid":1}
2026-09-01T00:00:02Z|META|version|info|{"ticket_auto":"0.42.0","skills":{"ticket-implement":{"sha256":"aaa111","manifest_n":6}},"skills_unresolved":0}
2026-09-01T00:00:03Z|META|outcome|info|completed: STEP_6
EOF
  cat >"$log_b" <<'EOF'
2026-09-01T01:00:01Z|META|run-id|info|{"run_id":"CRE-22-a","gen":null,"trigger":"manual","pid":2}
2026-09-01T01:00:02Z|META|version|info|{"ticket_auto":"0.42.0","skills":{"ticket-implement":{"sha256":"bbb222","manifest_n":6}},"skills_unresolved":0}
2026-09-01T01:00:03Z|META|outcome|info|completed: STEP_6
EOF
  runs_append "$runs" "$(run_summary_json CRE-21 "$log_a" 0)"
  runs_append "$runs" "$(run_summary_json CRE-22 "$log_b" 0)"

  n=$(jq -s '[.[] | select(.kind == "run")]
             | group_by(.versions.skills["ticket-implement"].sha256)
             | length' "$runs")
  _teardown

  [ "$n" = "2" ] || {
    echo "expected 2 fingerprint cohorts, got $n"
    return 1
  }
}

# ── run_summary_json: window isolation of counters ──────────────────────────

test_json_verify_attempts_counts_only_later_run() {
  _setup
  local log="$_ws/CRE-3-pipeline.log"
  cat >"$log" <<'EOF'
2026-09-01T00:00:00Z|META|schema|info|1
2026-09-01T00:00:01Z|META|run-id|info|{"run_id":"CRE-3-a","gen":null,"trigger":"manual","pid":1}
2026-09-01T00:00:02Z|VERIFY|verify|fail|FAIL
2026-09-01T00:00:03Z|VERIFY|verify|fail|FAIL
2026-09-01T00:00:04Z|META|outcome|info|held: gate
2026-09-01T02:00:00Z|META|run-id|info|{"run_id":"CRE-3-b","gen":null,"trigger":"manual","pid":2}
2026-09-01T02:00:01Z|VERIFY|verify|fail|FAIL
2026-09-01T02:00:02Z|META|outcome|info|completed: STEP_6
EOF
  local json attempts
  json=$(run_summary_json "CRE-3" "$log" 0)
  attempts=$(echo "$json" | jq -r '.verify_attempts')
  _teardown
  [ "$attempts" = "1" ] || {
    echo "expected verify_attempts=1 for the resumed run, got $attempts"
    return 1
  }
}

test_json_resumed_after_hold_ms() {
  _setup
  local log="$_ws/CRE-4-pipeline.log"
  cat >"$log" <<'EOF'
2026-09-01T00:00:00Z|META|schema|info|1
2026-09-01T00:00:01Z|META|run-id|info|{"run_id":"CRE-4-a","gen":null,"trigger":"manual","pid":1}
2026-09-01T00:00:04Z|META|outcome|info|held: gate
2026-09-01T00:01:04Z|META|run-id|info|{"run_id":"CRE-4-b","gen":null,"trigger":"manual","pid":2}
2026-09-01T00:01:05Z|META|outcome|info|completed: STEP_6
EOF
  local json held resumed_ms
  json=$(run_summary_json "CRE-4" "$log" 0)
  held=$(echo "$json" | jq -r '.gate_held_at')
  resumed_ms=$(echo "$json" | jq -r '.resumed_after_hold_ms')
  _teardown
  [ "$held" = "2026-09-01T00:00:04Z" ] || {
    echo "expected gate_held_at=2026-09-01T00:00:04Z, got $held"
    return 1
  }
  [ "$resumed_ms" = "60000" ] || {
    echo "expected resumed_after_hold_ms=60000, got $resumed_ms"
    return 1
  }
}

test_json_pr_created_beats_checkout_pr() {
  _setup
  local log="$_ws/CRE-5-pipeline.log"
  cat >"$log" <<'EOF'
2026-09-01T00:00:00Z|META|schema|info|1
2026-09-01T00:00:01Z|META|run-id|info|{"run_id":"CRE-5-a","gen":null,"trigger":"manual","pid":1}
2026-09-01T00:00:02Z|PR-REVIEW|checkout-pr|done|99
2026-09-01T00:00:03Z|META|pr-created|info|{"pr":42,"url":"https://github.com/acme/repo/pull/42","repo":"acme/repo"}
2026-09-01T00:00:04Z|META|outcome|info|completed: STEP_6
EOF
  local json pr_num pr_repo
  json=$(run_summary_json "CRE-5" "$log" 0)
  pr_num=$(echo "$json" | jq -r '.pr.pr')
  pr_repo=$(echo "$json" | jq -r '.pr.repo')
  _teardown
  [ "$pr_num" = "42" ] && [ "$pr_repo" = "acme/repo" ] || {
    echo "expected pr-created (42, acme/repo) to win over checkout-pr (99), got ($pr_num, $pr_repo)"
    return 1
  }
}

test_json_token_split_summed_across_phases() {
  _setup
  local log="$_ws/CRE-6-pipeline.log"
  cat >"$log" <<'EOF'
2026-09-01T00:00:00Z|META|schema|info|1
2026-09-01T00:00:01Z|META|run-id|info|{"run_id":"CRE-6-a","gen":null,"trigger":"manual","pid":1}
2026-09-01T00:00:02Z|META|tokens|info|IMPLEMENT:100/50/10|elapsed_ms=1000
2026-09-01T00:00:03Z|META|cache-tokens|info|IMPLEMENT:8/2
2026-09-01T00:00:04Z|META|tokens|info|VERIFY:20/5/1|elapsed_ms=500
2026-09-01T00:00:05Z|META|cache-tokens|info|VERIFY:1/0
2026-09-01T00:00:06Z|META|outcome|info|completed: STEP_6
EOF
  local json
  json=$(run_summary_json "CRE-6" "$log" 0)
  _teardown
  echo "$json" | jq -e '
    .tokens.in == 120 and .tokens.out == 55 and .tokens.cache == 11
    and .tokens.cache_read == 9 and .tokens.cache_write == 2
    and .phase_elapsed_ms.IMPLEMENT == 1000 and .phase_elapsed_ms.VERIFY == 500
  ' >/dev/null
}

test_json_empty_window_is_valid_json_with_zero_counters() {
  _setup
  local log="$_ws/CRE-7-pipeline.log"
  cat >"$log" <<'EOF'
2026-09-01T00:00:00Z|META|schema|info|1
2026-09-01T00:00:01Z|META|run-id|info|{"run_id":"CRE-7-a","gen":null,"trigger":"manual","pid":1}
2026-09-01T00:00:02Z|META|outcome|info|completed: STEP_6
EOF
  local json
  json=$(run_summary_json "CRE-7" "$log" 0)
  _teardown
  echo "$json" | jq -e '
    .verify_attempts == 0 and .review_iterations == 0 and .fix_rounds == 0
    and .reconcile_cycles == 0 and .gate_stops == [] and .pr == null
    and .tokens.in == 0
  ' >/dev/null
}

test_json_detect_resume_not_sourced() {
  # run-summary.sh must never source detect-resume.sh (zombie-synthesis
  # side effects). Grep the source, not behaviour — a reliable static check.
  ! grep -q 'source.*detect-resume' "$LIB_DIR/run-summary.sh"
}

# ── runs_append ────────────────────────────────────────────────────────────────

test_runs_append_concurrent_writers_all_valid() {
  _setup
  local runs="$_ws/runs.jsonl"
  local i
  for i in $(seq 1 12); do
    (runs_append "$runs" "{\"kind\":\"run\",\"n\":$i}") &
  done
  wait
  local total bad
  total=$(wc -l <"$runs" 2>/dev/null || echo 0)
  bad=0
  while IFS= read -r line; do
    echo "$line" | jq -e . >/dev/null 2>&1 || bad=$((bad + 1))
  done <"$runs"
  _teardown
  [ "$total" -eq 12 ] && [ "$bad" -eq 0 ]
}

# ═══════════════════════════════════════════════════════════════════════════════
# Dispatcher
# ═══════════════════════════════════════════════════════════════════════════════

FILTER="${1:-}"

for fn in \
  test_window_isolates_current_run \
  test_window_falls_back_to_whole_log_without_run_id \
  test_json_verify_attempts_counts_only_later_run \
  test_json_resumed_after_hold_ms \
  test_json_pr_created_beats_checkout_pr \
  test_json_token_split_summed_across_phases \
  test_json_empty_window_is_valid_json_with_zero_counters \
  test_json_detect_resume_not_sourced \
  test_json_versions_carries_skill_fingerprints_verbatim \
  test_json_versions_groupable_by_skill_revision \
  test_runs_append_concurrent_writers_all_valid; do
  [ -z "$FILTER" ] || [[ "$fn" == *"$FILTER"* ]] || continue
  _run "$fn" "$fn"
done

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
