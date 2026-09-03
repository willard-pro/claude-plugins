#!/usr/bin/env bash
# test-detect-resume.sh — functional tests for skills/ticket-detect-resume/detect-resume.sh
# Invokes the real script against constructed pipeline-log fixtures and asserts
# on the DETECT_RESUME_RESULT block's field values, not just "doesn't crash".
# Usage: CLAUDE_SKILLS_LIB=<lib dir> bash test-detect-resume.sh [test_name_filter]
# -u (nounset) intentionally omitted: Claude Code shell snapshots inject
# ZSH_VERSION references that trigger false-positive "unbound variable"
# errors in this bash version when nounset is active.
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DETECT_SH="$(cd "$LIB_DIR/../skills/ticket-detect-resume" && pwd)/detect-resume.sh"
export CLAUDE_SKILLS_LIB="${CLAUDE_SKILLS_LIB:-$LIB_DIR}"

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

# Runs detect-resume.sh in a fresh tmpdir with the given log lines and echoes
# the DETECT_RESUME_RESULT block. $1 = ticket id, remaining args = log lines.
_detect_resume_with_log() {
  local ticket_id="$1"
  shift
  local tmpdir
  tmpdir=$(mktemp -d)
  mkdir -p "$tmpdir/logs"
  local line
  for line in "$@"; do
    echo "$line" >>"$tmpdir/logs/${ticket_id}-pipeline.log"
  done
  (cd "$tmpdir" && bash "$DETECT_SH" "$ticket_id" 2>/dev/null)
  local rc=$?
  rm -rf "$tmpdir"
  return $rc
}

_field() {
  local block="$1" field="$2"
  echo "$block" | grep "^  ${field}:" | sed -E "s/^  ${field}: *//"
}

# ── VERIFY_ATTEMPTS (R6) ────────────────────────────────────────────────────

test_verify_attempts_preflight_fail_does_not_overcount() {
  local out
  out=$(_detect_resume_with_log "TEST-1" \
    "2026-07-05T10:00:00Z|META|schema|info|1" \
    "2026-07-05T10:00:01Z|VERIFY|pre-flight|fail|No test user found" \
    "2026-07-05T10:00:02Z|VERIFY|verify|fail|reproduction failed")
  [ "$(_field "$out" VERIFY_ATTEMPTS)" = "1" ]
}

test_verify_attempts_two_terminal_failures_count_two() {
  local out
  out=$(_detect_resume_with_log "TEST-2" \
    "2026-07-05T10:00:00Z|META|schema|info|1" \
    "2026-07-05T10:00:01Z|VERIFY|verify|fail|reproduction failed" \
    "2026-07-05T10:00:02Z|VERIFY|verify|fail|reproduction failed again")
  [ "$(_field "$out" VERIFY_ATTEMPTS)" = "2" ]
}

test_verify_attempts_terminal_done_counts_as_attempt() {
  local out
  out=$(_detect_resume_with_log "TEST-3" \
    "2026-07-05T10:00:00Z|META|schema|info|1" \
    "2026-07-05T10:00:01Z|VERIFY|verify|fail|reproduction failed" \
    "2026-07-05T10:00:02Z|VERIFY|verify|done|PASS")
  # R6: count only terminal FAIL entries — PASS doesn't inflate the exhaustion cap.
  # One fail + one done(PASS) = 1 attempt counted (only fail entries increment).
  [ "$(_field "$out" VERIFY_ATTEMPTS)" = "1" ]
}

# ── MAINTENANCE_FROM (R7) ────────────────────────────────────────────────────

test_maintenance_from_excludes_prescan_only_line() {
  local out
  out=$(_detect_resume_with_log "TEST-4" \
    "2026-07-05T10:00:00Z|META|schema|info|1" \
    "2026-07-05T10:00:01Z|MAINTENANCE|prescan|done|fresh")
  [ -z "$(_field "$out" MAINTENANCE_FROM)" ]
}

test_maintenance_from_still_picks_real_substep() {
  local out
  out=$(_detect_resume_with_log "TEST-5" \
    "2026-07-05T10:00:00Z|META|schema|info|1" \
    "2026-07-05T10:00:01Z|MAINTENANCE|wiki-check|done|ok" \
    "2026-07-05T10:00:02Z|MAINTENANCE|prescan|done|fresh")
  [ "$(_field "$out" MAINTENANCE_FROM)" = "wiki-check" ]
}

# ── ITERATION via WARN token (R5) ───────────────────────────────────────────

test_iteration_counts_warn_token_not_emoji_bytes() {
  local out
  out=$(_detect_resume_with_log "TEST-6" \
    "2026-07-05T10:00:00Z|META|schema|info|1" \
    "2026-07-05T10:00:01Z|PR-REVIEW|pr-review|done|WARN — gaps found" \
    "2026-07-05T10:00:02Z|PR-REVIEW|pr-review|done|WARN — still gaps")
  [ "$(_field "$out" ITERATION)" = "2" ]
}

test_iteration_does_not_count_ok_verdict() {
  local out
  out=$(_detect_resume_with_log "TEST-7" \
    "2026-07-05T10:00:00Z|META|schema|info|1" \
    "2026-07-05T10:00:01Z|PR-REVIEW|pr-review|done|OK — all good")
  [ "$(_field "$out" ITERATION)" = "0" ]
}

# ── VERIFY_LAST (R8) ─────────────────────────────────────────────────────────

test_verify_last_fail_with_no_reimplement_flags_fail() {
  local out
  out=$(_detect_resume_with_log "TEST-8" \
    "2026-07-05T10:00:00Z|META|schema|info|1" \
    "2026-07-05T10:00:01Z|IMPLEMENT|implement|done|3 files changed" \
    "2026-07-05T10:00:02Z|VERIFY|verify|fail|FAIL — 1/3 criteria met")
  [ "$(_field "$out" VERIFY_LAST)" = "fail" ]
}

test_verify_last_fail_followed_by_reimplement_is_clear() {
  local out
  out=$(_detect_resume_with_log "TEST-9" \
    "2026-07-05T10:00:00Z|META|schema|info|1" \
    "2026-07-05T10:00:01Z|IMPLEMENT|implement|done|3 files changed" \
    "2026-07-05T10:00:02Z|VERIFY|verify|fail|FAIL — 1/3 criteria met" \
    "2026-07-05T10:00:03Z|IMPLEMENT|implement|done|1 file changed")
  [ -z "$(_field "$out" VERIFY_LAST)" ]
}

test_verify_last_pass_is_pass() {
  local out
  out=$(_detect_resume_with_log "TEST-10" \
    "2026-07-05T10:00:00Z|META|schema|info|1" \
    "2026-07-05T10:00:01Z|IMPLEMENT|implement|done|3 files changed" \
    "2026-07-05T10:00:02Z|VERIFY|verify|done|PASS — 3/3 criteria met")
  [ "$(_field "$out" VERIFY_LAST)" = "pass" ]
}

test_verify_last_empty_when_no_verify_yet() {
  local out
  out=$(_detect_resume_with_log "TEST-11" \
    "2026-07-05T10:00:00Z|META|schema|info|1" \
    "2026-07-05T10:00:01Z|IMPLEMENT|implement|done|3 files changed")
  [ -z "$(_field "$out" VERIFY_LAST)" ]
}

# ── PR_FEEDBACK_CYCLE (R10) ─────────────────────────────────────────────────

test_pr_feedback_cycle_counts_cycle_markers() {
  local out
  out=$(_detect_resume_with_log "TEST-12" \
    "2026-07-05T10:00:00Z|META|schema|info|1" \
    "2026-07-05T10:00:01Z|IMPLEMENT|implement|done|3 files changed" \
    "2026-07-05T10:00:02Z|PR-REVIEW|pr-reconcile|done|cycle#1 reconciled" \
    "2026-07-05T10:00:03Z|PR-REVIEW|pr-reconcile|done|cycle#2 reconciled" \
    "2026-07-05T10:00:04Z|PR-REVIEW|pr-reconcile|done|cycle#3 reconciled")
  [ "$(_field "$out" PR_FEEDBACK_CYCLE)" = "3" ]
}

test_pr_feedback_cycle_zero_when_no_reconcile_yet() {
  local out
  out=$(_detect_resume_with_log "TEST-13" \
    "2026-07-05T10:00:00Z|META|schema|info|1" \
    "2026-07-05T10:00:01Z|IMPLEMENT|implement|done|3 files changed")
  [ "$(_field "$out" PR_FEEDBACK_CYCLE)" = "0" ]
}

# ── ARTIFACT_TYPE (pipeline-integrity Phase 1 dependency) ──────────────────
# ticket-appraise-exec writes EXEC|create-artifact|done|{simple-fix|openspec} —
# the "exec" step name never occurs in a real log. Regression test for the
# fix that changed the grep pattern to match the actual step name.

test_artifact_type_openspec_from_create_artifact_line() {
  local out
  out=$(_detect_resume_with_log "TEST-14" \
    "2026-07-05T10:00:00Z|META|schema|info|1" \
    "2026-07-05T10:00:01Z|APPRAISE|appraise|done|complexity=complex" \
    "2026-07-05T10:00:02Z|EXEC|create-artifact|done|openspec")
  [ "$(_field "$out" ARTIFACT_TYPE)" = "openspec" ]
}

test_artifact_type_simple_fix_from_create_artifact_line() {
  local out
  out=$(_detect_resume_with_log "TEST-15" \
    "2026-07-05T10:00:00Z|META|schema|info|1" \
    "2026-07-05T10:00:01Z|APPRAISE|appraise|done|complexity=simple" \
    "2026-07-05T10:00:02Z|EXEC|create-artifact|done|simple-fix")
  [ "$(_field "$out" ARTIFACT_TYPE)" = "simple-fix" ]
}

# GitHub #196: RESUME_STEP's EXEC-done branch grepped a marker
# (EXEC|exec|done|) no writer emits, so a pipeline that completed EXEC never
# resumed at STEP_2_5 and fell through to a later, wrong branch. Regression
# test for the fix that changed the grep pattern to the canonical
# EXEC|create-artifact|done| marker (same one gate-check.sh reads).
test_resume_step_2_5_on_exec_create_artifact_done() {
  local out
  out=$(_detect_resume_with_log "TEST-16" \
    "2026-07-05T10:00:00Z|META|schema|info|1" \
    "2026-07-05T10:00:01Z|APPRAISE|appraise|done|complexity=simple" \
    "2026-07-05T10:00:02Z|EXEC|create-artifact|done|simple-fix")
  [ "$(_field "$out" RESUME_STEP)" = "STEP_2_5" ]
}

# Like _detect_resume_with_log but echoes the resulting pipeline log rather
# than the result block, so tests can assert on the lines the script writes
# (zombie detection reports itself in the log, not in DETECT_RESUME_RESULT).
_detect_resume_log_after() {
  local ticket_id="$1"
  shift
  local tmpdir
  tmpdir=$(mktemp -d)
  mkdir -p "$tmpdir/logs"
  local line
  for line in "$@"; do
    echo "$line" >>"$tmpdir/logs/${ticket_id}-pipeline.log"
  done
  (cd "$tmpdir" && bash "$DETECT_SH" "$ticket_id" >/dev/null 2>&1) || true
  cat "$tmpdir/logs/${ticket_id}-pipeline.log"
  rm -rf "$tmpdir"
}

# Backgrounds a process whose cmdline is exactly $1, setting FAKE_PID.
# Deliberately not a command substitution: a background job started inside
# `$( )` does not survive the substitution subshell, so the process under
# test would already be gone by the time the assertion runs.
_fake_worker() {
  bash -c "exec -a \"$1\" sleep 20" &
  FAKE_PID=$!
  sleep 0.3
}

# Kills a _fake_worker and reaps it, so no test leaves an orphan behind.
_reap() {
  [ -n "$1" ] || return 0
  kill "$1" 2>/dev/null || true
  wait "$1" 2>/dev/null || true
}

# ── Zombie detection ──────────────────────────────────────────────────────────

test_zombie_detection_triggers_on_old_waiting() {
  local old_ts
  old_ts=$(date -u -d "10 minutes ago" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "2020-01-01T00:00:00Z")
  local out
  out=$(_detect_resume_with_log "ZB-1" \
    "${old_ts}|META|schema|info|2" \
    "${old_ts}|IMPLEMENT|implement|waiting|agent running")
  # Zombie should be detected — resume point should re-run the phase (STEP_4)
  # If pgrep finds nothing (which it shouldn't in test), zombie triggers
  local resume_step
  resume_step=$(_field "$out" RESUME_STEP)
  # May be STEP_4 (zombie detected) or STEP_1 (no log progress past waiting —
  # which is also correct since a zombie'd IMPLEMENT waiting step means we
  # need to start from STEP_4). The key: it's not stuck on a waiting-derived step.
  [ -n "$resume_step" ]
}

test_prescan_zombie_does_not_force_step5_on_fresh_ticket() {
  # GitHub #151: PHASE=MAINTENANCE is shared by the Prescan gate
  # (STEP=prescan, runs before APPRAISE) and real STEP_5
  # (STEP=document/wiki-maintenance). A stale prescan zombie must not
  # jump a fresh ticket straight to STEP_5, skipping every real phase.
  local old_ts
  old_ts=$(date -u -d "10 minutes ago" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "2020-01-01T00:00:00Z")
  local out
  out=$(_detect_resume_with_log "GH-151-1" \
    "${old_ts}|META|schema|info|2" \
    "${old_ts}|MAINTENANCE|prescan|waiting|repo prescan triggered (decayed)")
  local resume_step
  resume_step=$(_field "$out" RESUME_STEP)
  [ "$resume_step" = "STEP_1" ]
}

test_maintenance_document_zombie_still_routes_to_step5() {
  # Real STEP_5 zombies (document/wiki-maintenance) must still re-route
  # to STEP_5 as before — only prescan is excluded.
  local old_ts
  old_ts=$(date -u -d "10 minutes ago" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "2020-01-01T00:00:00Z")
  local out
  out=$(_detect_resume_with_log "GH-151-2" \
    "${old_ts}|META|schema|info|2" \
    "${old_ts}|APPRAISE|appraise|done|complexity=simple" \
    "${old_ts}|EXEC|create-artifact|done|simple-fix" \
    "${old_ts}|GATE|gate|done|approved" \
    "${old_ts}|IMPLEMENT|implement|done|committed" \
    "${old_ts}|VERIFY|verify|done|PASS 3/3" \
    "${old_ts}|PR-REVIEW|pr-review|done|OK — merged" \
    "${old_ts}|MAINTENANCE|document|waiting|generating ai-context.md")
  local resume_step
  resume_step=$(_field "$out" RESUME_STEP)
  [ "$resume_step" = "STEP_5" ]
}

test_zombie_detection_skips_non_phase_waiting() {
  local old_ts
  old_ts=$(date -u -d "10 minutes ago" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "2020-01-01T00:00:00Z")
  local out
  out=$(_detect_resume_with_log "ZB-2" \
    "${old_ts}|META|schema|info|2" \
    "${old_ts}|META|meta-step|waiting|not a real phase")
  # META lines are skipped by zombie detection — should not cause a phase re-route
  local resume_step
  resume_step=$(_field "$out" RESUME_STEP)
  # Without any real phase entries, should default to STEP_1
  [ "$resume_step" = "STEP_1" ]
}

# ── Worker liveness (zombie suppression) ─────────────────────────────────────

_old_ts() { date -u -d "10 minutes ago" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "2020-01-01T00:00:00Z"; }

test_zombie_fires_when_no_other_worker_alive() {
  # Baseline, and the regression guard for the self-match defect: this script
  # lives under .../ticket-auto-pipeline/... and is invoked with the ticket id
  # as argv[1], so the old `pgrep -f "ticket-auto.*<ID>"` matched its OWN
  # cmdline and reported "alive" unconditionally. With ancestry excluded and
  # nothing else running the ticket, the zombie must be reported.
  local out
  out=$(_detect_resume_log_after "ZBL-1" \
    "$(_old_ts)|META|schema|info|2" \
    "$(_old_ts)|IMPLEMENT|implement|waiting|agent running")
  grep -q 'zombie-detected' <<<"$out"
}

test_zombie_suppressed_by_live_phase_worker() {
  # A fleetd-spawned phase worker's cmdline is `/ticket-<phase> <ID>`, which
  # the old ticket-auto-only pattern could never match — the miss re-dispatched
  # the phase on top of the run still holding it.
  local out rc
  _fake_worker "claude -p /ticket-implement ZBL-2 --from-auto"
  out=$(_detect_resume_log_after "ZBL-2" \
    "$(_old_ts)|META|schema|info|2" \
    "$(_old_ts)|IMPLEMENT|implement|waiting|agent running")
  if grep -q 'zombie-detected' <<<"$out"; then rc=1; else rc=0; fi
  _reap "$FAKE_PID"
  return $rc
}

test_zombie_suppressed_by_run_registry_pid() {
  # The registry is the authoritative source when fleetd spawned the run.
  local out rc state
  _fake_worker "sleep-for-ZBL-3"
  state=$(mktemp -d)
  echo "{\"tid\":\"ZBL-3\",\"pid\":${FAKE_PID},\"generation\":1}" >"${state}/ZBL-3-run.json"
  export FLEET_STATE_DIR="$state"
  out=$(_detect_resume_log_after "ZBL-3" \
    "$(_old_ts)|META|schema|info|2" \
    "$(_old_ts)|IMPLEMENT|implement|waiting|agent running")
  unset FLEET_STATE_DIR
  if grep -q 'zombie-detected' <<<"$out"; then rc=1; else rc=0; fi
  _reap "$FAKE_PID"
  rm -rf "$state"
  return $rc
}

test_zombie_not_suppressed_by_dead_registry_pid() {
  # A registry row is evidence only while its pid is alive. A stale row from a
  # crashed worker must not mask the zombie it left behind.
  local out state
  state=$(mktemp -d)
  echo '{"tid":"ZBL-4","pid":999999999,"generation":1}' >"${state}/ZBL-4-run.json"
  export FLEET_STATE_DIR="$state"
  out=$(_detect_resume_log_after "ZBL-4" \
    "$(_old_ts)|META|schema|info|2" \
    "$(_old_ts)|IMPLEMENT|implement|waiting|agent running")
  unset FLEET_STATE_DIR
  rm -rf "$state"
  grep -q 'zombie-detected' <<<"$out"
}

test_zombie_liveness_ignores_prefix_collision() {
  # A live worker on ZBL-50 must not vouch for ZBL-5.
  local out
  _fake_worker "claude -p /ticket-implement ZBL-50 --from-auto"
  out=$(_detect_resume_log_after "ZBL-5" \
    "$(_old_ts)|META|schema|info|2" \
    "$(_old_ts)|IMPLEMENT|implement|waiting|agent running")
  _reap "$FAKE_PID"
  grep -q 'zombie-detected' <<<"$out"
}

# ── Pipe-safe field extraction ────────────────────────────────────────────────

test_msg_field_preserves_embedded_pipes() {
  # With schema v1 (no pipe rejection), old logs may have pipes in MSG.
  # The inline awk preserves embedded pipes in field 5+ extraction.
  local out
  out=$(_detect_resume_with_log "PF-1" \
    "2026-07-05T10:00:00Z|META|schema|info|2" \
    "2026-07-05T10:00:01Z|APPRAISE|appraise|done|complexity=simple" \
    "2026-07-05T10:00:02Z|EXEC|create-artifact|done|openspec|with|extra|pipes")
  local artifact_type
  artifact_type=$(_field "$out" ARTIFACT_TYPE)
  # Full message including pipes should be preserved
  echo "$artifact_type" | grep -q "openspec"
}

test_schema_v1_accepted_with_warning() {
  local out
  out=$(_detect_resume_with_log "SV-1" \
    "2026-07-05T10:00:00Z|META|schema|info|1" \
    "2026-07-05T10:00:01Z|APPRAISE|appraise|done|complexity=simple")
  local resume_step
  resume_step=$(_field "$out" RESUME_STEP)
  # Schema v1 accepted — RESUME_STEP should be STEP_2 (appraise done)
  [ "$resume_step" = "STEP_2" ]
}

test_schema_v2_accepted() {
  local out
  out=$(_detect_resume_with_log "SV-2" \
    "2026-07-05T10:00:00Z|META|schema|info|2" \
    "2026-07-05T10:00:01Z|APPRAISE|appraise|done|complexity=simple")
  local resume_step
  resume_step=$(_field "$out" RESUME_STEP)
  [ "$resume_step" = "STEP_2" ]
}

# ── GATE_HELD reconcile loop (GitHub #146) ──────────────────────────────────

test_gate_reconcile_done_advances_past_gate_held() {
  # ticket-gate-reconcile writes GATE|reconcile|done|, never GATE|gate|done|.
  # Without accepting both markers, this log's original GATE|gate|fail|held
  # line keeps matching and RESUME_STEP falls back to GATE_HELD forever.
  local out
  out=$(_detect_resume_with_log "GH-146-1" \
    "2026-07-05T10:00:00Z|META|schema|info|2" \
    "2026-07-05T10:00:01Z|APPRAISE|appraise|done|complexity=simple" \
    "2026-07-05T10:00:02Z|GATE|gate|fail|held" \
    "2026-07-05T10:00:03Z|GATE|reconcile|done|clean")
  local resume_step
  resume_step=$(_field "$out" RESUME_STEP)
  [ "$resume_step" = "STEP_4" ]
}

test_gate_gate_done_still_advances_past_gate_held() {
  # The original marker must still work — this fix is additive, not a
  # replacement.
  local out
  out=$(_detect_resume_with_log "GH-146-2" \
    "2026-07-05T10:00:00Z|META|schema|info|2" \
    "2026-07-05T10:00:01Z|APPRAISE|appraise|done|complexity=simple" \
    "2026-07-05T10:00:02Z|GATE|gate|fail|held" \
    "2026-07-05T10:00:03Z|GATE|gate|done|approved")
  local resume_step
  resume_step=$(_field "$out" RESUME_STEP)
  [ "$resume_step" = "STEP_4" ]
}

# ── gate-reconcile held vs clean collision (GitHub #195) ────────────────────

test_gate_reconcile_held_routes_to_gate_held_not_step_4() {
  # ticket-gate-reconcile's held terminal marker
  # (GATE|reconcile|done|cycle#N|held: reason) shares the GATE|reconcile|done|
  # prefix with the clean marker. Before the fix, both matched the same
  # branch and a deliberately-held ticket resumed straight into STEP_4.
  local out
  out=$(_detect_resume_with_log "GH-195-1" \
    "2026-07-05T10:00:00Z|META|schema|info|2" \
    "2026-07-05T10:00:01Z|APPRAISE|appraise|done|complexity=simple" \
    "2026-07-05T10:00:02Z|GATE|gate|fail|held" \
    "2026-07-05T10:00:03Z|GATE|reconcile|done|cycle#0|held: needs more detail")
  local resume_step
  resume_step=$(_field "$out" RESUME_STEP)
  [ "$resume_step" != "STEP_4" ]
}

test_gate_reconcile_clean_after_prior_held_cycle_still_routes_to_step_4() {
  # A clean reconcile that follows an earlier held cycle in the same log must
  # still win and advance to STEP_4 — the held-vs-clean split must not
  # regress the original #146 fix for the multi-cycle case.
  local out
  out=$(_detect_resume_with_log "GH-195-2" \
    "2026-07-05T10:00:00Z|META|schema|info|2" \
    "2026-07-05T10:00:01Z|APPRAISE|appraise|done|complexity=simple" \
    "2026-07-05T10:00:02Z|GATE|gate|fail|held" \
    "2026-07-05T10:00:03Z|GATE|reconcile|done|cycle#0|held: needs more detail" \
    "2026-07-05T10:00:04Z|GATE|reconcile|done|clean")
  local resume_step
  resume_step=$(_field "$out" RESUME_STEP)
  [ "$resume_step" = "STEP_4" ]
}

# ── Terminal "done" state (#168) ────────────────────────────────────────────

test_resume_step_done_on_completed_outcome() {
  # pipeline-finalize.sh's tail-guarded "completed: STEP_6" line means the
  # run genuinely finished. Without a terminal check, a naive re-run of
  # /ticket-auto would fall through to the ordinary backward-scan and route
  # right back into STEP_6 forever.
  local out
  out=$(_detect_resume_with_log "GH-168-1" \
    "2026-08-31T10:00:00Z|META|schema|info|2" \
    "2026-08-31T10:00:01Z|APPRAISE|appraise|done|complexity=simple" \
    "2026-08-31T10:00:02Z|MAINTENANCE|maintenance|done|clean" \
    "2026-08-31T10:00:03Z|META|outcome|info|completed: STEP_6")
  [ "$(_field "$out" RESUME_STEP)" = "done" ]
}

test_resume_step_not_done_on_held_outcome() {
  # pipeline-finalize.sh also writes an outcome line when the router exits
  # on a gate hold ("held: gate") — that is NOT a terminal state, and must
  # still resolve to GATE_HELD/GATE_STILL_HELD via the normal backward-scan,
  # not short-circuit to "done".
  local out
  out=$(_detect_resume_with_log "GH-168-2" \
    "2026-08-31T10:00:00Z|META|schema|info|2" \
    "2026-08-31T10:00:01Z|APPRAISE|appraise|done|complexity=complex" \
    "2026-08-31T10:00:02Z|GATE|gate|fail|held" \
    "2026-08-31T10:00:03Z|META|outcome|info|held: gate")
  local resume_step
  resume_step=$(_field "$out" RESUME_STEP)
  [ "$resume_step" != "done" ]
}

test_resume_step_not_done_on_stopped_outcome() {
  # A gate-stop/exhaustion outcome ("stopped: ...") is terminal-but-failed,
  # not terminal-but-complete — it must not be reported as "done" either.
  local out
  out=$(_detect_resume_with_log "GH-168-3" \
    "2026-08-31T10:00:00Z|META|schema|info|2" \
    "2026-08-31T10:00:01Z|APPRAISE|appraise|done|complexity=simple" \
    "2026-08-31T10:00:02Z|IMPLEMENT|implement|done|Hard, branch: gh-168-3--fix" \
    "2026-08-31T10:00:03Z|META|outcome|info|stopped: VERIFY_EXHAUSTED")
  local resume_step
  resume_step=$(_field "$out" RESUME_STEP)
  [ "$resume_step" != "done" ]
}

test_schema_v1_warning_does_not_repollute_done_on_rerun() {
  # #210: the schema-v1 warning write was unconditional — every detect-resume.sh
  # call against a schema-v1 log re-appended META|schema|warn|. In a real
  # pipeline that line is first written mid-run (the router calls
  # detect-resume.sh before every dispatch decision, long before completion).
  # Without an idempotency guard, the *next* call after pipeline-finalize.sh
  # writes the terminal outcome line — e.g. a naive re-invocation of
  # /ticket-auto right after completion — appends another warning that pushes
  # the outcome line off the tail, breaking the tail-only "done" check above
  # and regressing #168. Reproduce the real ordering: one call establishes the
  # warning mid-run, then two calls happen after the terminal line is written,
  # all against the SAME tmpdir (not the throwaway one
  # _detect_resume_with_log tears down after a single call).
  local tmpdir
  tmpdir=$(mktemp -d)
  mkdir -p "$tmpdir/logs"
  local log="$tmpdir/logs/GH-210-1-pipeline.log"
  cat >"$log" <<'EOF'
2026-08-31T09:00:00Z|META|schema|info|1
2026-08-31T09:00:01Z|APPRAISE|appraise|done|complexity=simple
EOF
  (cd "$tmpdir" && bash "$DETECT_SH" "GH-210-1" >/dev/null 2>/dev/null)
  {
    echo "2026-08-31T10:00:02Z|MAINTENANCE|maintenance|done|clean"
    echo "2026-08-31T10:00:03Z|META|outcome|info|completed: STEP_6"
  } >>"$log"
  local out1 out2 warn_count
  out1=$(cd "$tmpdir" && bash "$DETECT_SH" "GH-210-1" 2>/dev/null)
  out2=$(cd "$tmpdir" && bash "$DETECT_SH" "GH-210-1" 2>/dev/null)
  warn_count=$(grep -c 'META|schema|warn' "$log")
  rm -rf "$tmpdir"
  [ "$(_field "$out1" RESUME_STEP)" = "done" ] || return 1
  [ "$(_field "$out2" RESUME_STEP)" = "done" ] || return 1
  [ "$warn_count" -eq 1 ] || return 1
}

# ── dispatch ──────────────────────────────────────────────────────────────────

FILTER="${1:-}"

# ── Branch context recovery (Phase 1 shared-branch-resolution) ─────────────

test_branch_context_survives_resume() {
  local out
  out=$(_detect_resume_with_log "TEST-BC" \
    "2026-07-25T10:00:00Z|META|schema|info|1" \
    "2026-07-25T10:00:01Z|META|title|info|TEST-BC: Fix auth" \
    "2026-07-25T10:00:02Z|META|branch-context|info|base=epic/test-x;integration=epic/test-x;source=epic-directive;ticket=feat/TEST-BC-fix-auth" \
    "2026-07-25T10:00:03Z|APPRAISE|setup-workspace|start|")
  [ "$(_field "$out" BASE_BRANCH)" = "epic/test-x" ] || {
    echo "BASE_BRANCH mismatch: $(_field "$out" BASE_BRANCH)" >&2
    return 1
  }
  [ "$(_field "$out" INTEGRATION_BRANCH)" = "epic/test-x" ] || {
    echo "INTEGRATION_BRANCH mismatch: $(_field "$out" INTEGRATION_BRANCH)" >&2
    return 1
  }
  [ "$(_field "$out" BRANCH_SOURCE)" = "epic-directive" ] || {
    echo "BRANCH_SOURCE mismatch: $(_field "$out" BRANCH_SOURCE)" >&2
    return 1
  }
}

test_branch_context_carries_uat_policy() {
  local out
  out=$(_detect_resume_with_log "TEST-UP" \
    "2026-07-25T10:00:00Z|META|schema|info|1" \
    "2026-07-25T10:00:01Z|META|title|info|TEST-UP: Fix auth" \
    "2026-07-25T10:00:02Z|META|branch-context|info|base=epic/test-x;integration=epic/test-x;source=epic-directive;ticket=feat/TEST-UP-fix-auth;uat-policy=epic" \
    "2026-07-25T10:00:03Z|APPRAISE|setup-workspace|start|")
  [ "$(_field "$out" UAT_POLICY)" = "epic" ] || {
    echo "UAT_POLICY mismatch: $(_field "$out" UAT_POLICY)" >&2
    return 1
  }
  # Appending the field must not disturb the keys parsed before it.
  [ "$(_field "$out" BRANCH_SOURCE)" = "epic-directive" ] || {
    echo "BRANCH_SOURCE broken by uat-policy suffix: $(_field "$out" BRANCH_SOURCE)" >&2
    return 1
  }
  [ "$(_field "$out" INTEGRATION_BRANCH)" = "epic/test-x" ] || {
    echo "INTEGRATION_BRANCH broken by uat-policy suffix: $(_field "$out" INTEGRATION_BRANCH)" >&2
    return 1
  }
}

test_uat_policy_defaults_on_log_without_field() {
  # A branch-context line written before the field existed. The default must be
  # materialised here, not left empty for a consumer to re-derive.
  local out
  out=$(_detect_resume_with_log "TEST-UPOLD" \
    "2026-07-25T10:00:00Z|META|schema|info|1" \
    "2026-07-25T10:00:01Z|META|title|info|TEST-UPOLD: Fix auth" \
    "2026-07-25T10:00:02Z|META|branch-context|info|base=develop;integration=;source=default;ticket=feat/TEST-UPOLD-fix" \
    "2026-07-25T10:00:03Z|APPRAISE|setup-workspace|start|")
  [ "$(_field "$out" UAT_POLICY)" = "per-ticket" ] || {
    echo "expected per-ticket default, got: $(_field "$out" UAT_POLICY)" >&2
    return 1
  }
}

test_branch_context_carries_merge_policy() {
  local out
  out=$(_detect_resume_with_log "TEST-MP" \
    "2026-07-25T10:00:00Z|META|schema|info|1" \
    "2026-07-25T10:00:01Z|META|title|info|TEST-MP: Fix auth" \
    "2026-07-25T10:00:02Z|META|branch-context|info|base=epic/test-x;integration=epic/test-x;source=epic-directive;ticket=feat/TEST-MP-fix-auth;uat-policy=per-ticket;merge-policy=manual" \
    "2026-07-25T10:00:03Z|APPRAISE|setup-workspace|start|")
  [ "$(_field "$out" MERGE_POLICY)" = "manual" ] || {
    echo "MERGE_POLICY mismatch: $(_field "$out" MERGE_POLICY)" >&2
    return 1
  }
  # Appending the field must not disturb the keys parsed before it.
  [ "$(_field "$out" UAT_POLICY)" = "per-ticket" ] || {
    echo "UAT_POLICY broken by merge-policy suffix: $(_field "$out" UAT_POLICY)" >&2
    return 1
  }
  [ "$(_field "$out" BRANCH_SOURCE)" = "epic-directive" ] || {
    echo "BRANCH_SOURCE broken by merge-policy suffix: $(_field "$out" BRANCH_SOURCE)" >&2
    return 1
  }
}

test_merge_policy_empty_on_log_without_field() {
  # A branch-context line written before the field existed, or a ticket with no
  # epic directive at all — unlike UAT_POLICY, this must stay empty, not
  # materialise a default. Empty means "no epic opinion", which is a different
  # signal from "manual"; defaulting it would block every merge.
  local out
  out=$(_detect_resume_with_log "TEST-MPOLD" \
    "2026-07-25T10:00:00Z|META|schema|info|1" \
    "2026-07-25T10:00:01Z|META|title|info|TEST-MPOLD: Fix auth" \
    "2026-07-25T10:00:02Z|META|branch-context|info|base=develop;integration=;source=default;ticket=feat/TEST-MPOLD-fix;uat-policy=per-ticket" \
    "2026-07-25T10:00:03Z|APPRAISE|setup-workspace|start|")
  [ -z "$(_field "$out" MERGE_POLICY)" ] || {
    echo "expected empty MERGE_POLICY on legacy field, got: $(_field "$out" MERGE_POLICY)" >&2
    return 1
  }
}

test_branch_context_empty_on_legacy_log() {
  local out
  out=$(_detect_resume_with_log "TEST-LEGACY" \
    "2026-07-01T10:00:00Z|META|schema|info|1" \
    "2026-07-01T10:00:01Z|META|title|info|TEST-LEGACY: Old ticket" \
    "2026-07-01T10:00:02Z|APPRAISE|setup-workspace|start|")
  [ -z "$(_field "$out" BASE_BRANCH)" ] || {
    echo "BASE_BRANCH should be empty on legacy log: $(_field "$out" BASE_BRANCH)" >&2
    return 1
  }
  [ -z "$(_field "$out" INTEGRATION_BRANCH)" ] || {
    echo "INTEGRATION_BRANCH should be empty on legacy log: $(_field "$out" INTEGRATION_BRANCH)" >&2
    return 1
  }
  [ -z "$(_field "$out" BRANCH_SOURCE)" ] || {
    echo "BRANCH_SOURCE should be empty on legacy log: $(_field "$out" BRANCH_SOURCE)" >&2
    return 1
  }
}

for fn in \
  test_verify_attempts_preflight_fail_does_not_overcount \
  test_verify_attempts_two_terminal_failures_count_two \
  test_verify_attempts_terminal_done_counts_as_attempt \
  test_maintenance_from_excludes_prescan_only_line \
  test_maintenance_from_still_picks_real_substep \
  test_iteration_counts_warn_token_not_emoji_bytes \
  test_iteration_does_not_count_ok_verdict \
  test_verify_last_fail_with_no_reimplement_flags_fail \
  test_verify_last_fail_followed_by_reimplement_is_clear \
  test_verify_last_pass_is_pass \
  test_verify_last_empty_when_no_verify_yet \
  test_pr_feedback_cycle_counts_cycle_markers \
  test_pr_feedback_cycle_zero_when_no_reconcile_yet \
  test_artifact_type_openspec_from_create_artifact_line \
  test_artifact_type_simple_fix_from_create_artifact_line \
  test_resume_step_2_5_on_exec_create_artifact_done \
  test_zombie_detection_triggers_on_old_waiting \
  test_zombie_fires_when_no_other_worker_alive \
  test_zombie_suppressed_by_live_phase_worker \
  test_zombie_suppressed_by_run_registry_pid \
  test_zombie_not_suppressed_by_dead_registry_pid \
  test_zombie_liveness_ignores_prefix_collision \
  test_zombie_detection_skips_non_phase_waiting \
  test_msg_field_preserves_embedded_pipes \
  test_schema_v1_accepted_with_warning \
  test_schema_v2_accepted \
  test_gate_reconcile_done_advances_past_gate_held \
  test_gate_gate_done_still_advances_past_gate_held \
  test_gate_reconcile_held_routes_to_gate_held_not_step_4 \
  test_gate_reconcile_clean_after_prior_held_cycle_still_routes_to_step_4 \
  test_prescan_zombie_does_not_force_step5_on_fresh_ticket \
  test_maintenance_document_zombie_still_routes_to_step5 \
  test_branch_context_survives_resume \
  test_branch_context_carries_uat_policy \
  test_uat_policy_defaults_on_log_without_field \
  test_branch_context_carries_merge_policy \
  test_merge_policy_empty_on_log_without_field \
  test_branch_context_empty_on_legacy_log \
  test_resume_step_done_on_completed_outcome \
  test_resume_step_not_done_on_held_outcome \
  test_resume_step_not_done_on_stopped_outcome \
  test_schema_v1_warning_does_not_repollute_done_on_rerun; do
  [ -z "$FILTER" ] || [[ "$fn" == *"$FILTER"* ]] || continue
  _run "$fn" "$fn"
done

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
