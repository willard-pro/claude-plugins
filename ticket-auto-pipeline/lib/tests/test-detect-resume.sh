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
  test_zombie_detection_triggers_on_old_waiting \
  test_zombie_detection_skips_non_phase_waiting \
  test_msg_field_preserves_embedded_pipes \
  test_schema_v1_accepted_with_warning \
  test_schema_v2_accepted \
  test_gate_reconcile_done_advances_past_gate_held \
  test_gate_gate_done_still_advances_past_gate_held \
  test_prescan_zombie_does_not_force_step5_on_fresh_ticket \
  test_maintenance_document_zombie_still_routes_to_step5 \
  test_branch_context_survives_resume \
  test_branch_context_carries_uat_policy \
  test_uat_policy_defaults_on_log_without_field \
  test_branch_context_empty_on_legacy_log; do
  [ -z "$FILTER" ] || [[ "$fn" == *"$FILTER"* ]] || continue
  _run "$fn" "$fn"
done

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
