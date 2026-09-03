#!/usr/bin/env bash
# test-pipeline-phases.sh — structural tests for thin router dispatch
# Usage: bash test-pipeline-phases.sh [test_name_filter]
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SKILLS_DIR="$(cd "$LIB_DIR/../skills" && pwd)"

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

# ── mocks ──────────────────────────────────────────────────────────────────────

hb_init() { return 0; }
hb_heartbeat() { return 0; }
hb_gate() { return 0; }
hb_decision() { return 0; }
hb_retry() { return 0; }
hb_api() { return 0; }
hb_source() { return 0; }
get_issue() { echo '{"id":"TEST-1","labels":{"nodes":[{"name":"bug"}]}}'; }
get_comments() { echo '[]'; }
resolve_ticket_dir() { echo "/tmp/TEST-1--test"; }
get_complexity() { echo "simple"; }

# ── detect-resume.sh tests ─────────────────────────────────────────────────────

test_detect_resume_step_table() {
  local detect_sh="$SKILLS_DIR/ticket-detect-resume/detect-resume.sh"
  [ -f "$detect_sh" ] || {
    echo "detect-resume.sh not found"
    return 1
  }
  grep -q 'STEP_6' "$detect_sh" || {
    echo "STEP_6 not in detect-resume.sh"
    return 1
  }
  grep -q 'STEP_4_6' "$detect_sh" || {
    echo "STEP_4_6 not in detect-resume.sh"
    return 1
  }
  grep -q 'STEP_2_5' "$detect_sh" || {
    echo "STEP_2_5 not in detect-resume.sh"
    return 1
  }
  grep -q 'STEP_3_5' "$detect_sh" || {
    echo "STEP_3_5 not in detect-resume.sh"
    return 1
  }
  grep -q 'AUTONOMY' "$detect_sh" || {
    echo "AUTONOMY extraction missing"
    return 1
  }
}

test_detect_resume_all_key_steps() {
  local detect_sh="$SKILLS_DIR/ticket-detect-resume/detect-resume.sh"
  [ -f "$detect_sh" ] || return 1
  local steps=("STEP_1" "STEP_1_5" "STEP_2" "STEP_2_5" "STEP_3_5" "STEP_4" "STEP_4_5" "STEP_4_6" "STEP_5" "STEP_5_5" "STEP_6")
  local missing=""
  for step in "${steps[@]}"; do
    if ! grep -q "$step" "$detect_sh"; then missing="$missing $step"; fi
  done
  [ -z "$missing" ] || {
    echo "Missing step references:$missing"
    return 1
  }
}

# ── Router structural tests ────────────────────────────────────────────────────

test_router_gate_check_reference() {
  local skill_md="$SKILLS_DIR/ticket-auto/SKILL.md"
  [ -f "$skill_md" ] || return 1
  grep -q 'gate-check\.sh' "$skill_md" || {
    echo "gate-check.sh not referenced"
    return 1
  }
}

test_router_outcome_label_check_reference() {
  local skill_md="$SKILLS_DIR/ticket-auto/SKILL.md"
  [ -f "$skill_md" ] || return 1
  grep -q 'outcome-label-check\.sh' "$skill_md" || {
    echo "outcome-label-check.sh not referenced"
    return 1
  }
}

test_router_detect_resume_direct_bash() {
  local skill_md="$SKILLS_DIR/ticket-auto/SKILL.md"
  [ -f "$skill_md" ] || return 1
  grep -q 'detect-resume\.sh' "$skill_md" || {
    echo "detect-resume.sh not referenced"
    return 1
  }
}

test_router_verify_attempts_usage() {
  local skill_md="$SKILLS_DIR/ticket-auto/SKILL.md"
  [ -f "$skill_md" ] || return 1
  grep -q 'VERIFY_ATTEMPTS' "$skill_md" || {
    echo "VERIFY_ATTEMPTS not found"
    return 1
  }
}

test_router_iteration_usage() {
  local skill_md="$SKILLS_DIR/ticket-auto/SKILL.md"
  [ -f "$skill_md" ] || return 1
  grep -q 'ITERATION' "$skill_md" || {
    echo "ITERATION not found"
    return 1
  }
}

test_router_gate_reconcile_reference() {
  local skill_md="$SKILLS_DIR/ticket-auto/SKILL.md"
  [ -f "$skill_md" ] || return 1
  grep -q 'ticket-gate-reconcile' "$skill_md" || {
    echo "ticket-gate-reconcile not referenced"
    return 1
  }
}

test_router_auto_merge_check() {
  local skill_md="$SKILLS_DIR/ticket-auto/SKILL.md"
  [ -f "$skill_md" ] || return 1
  grep -q 'gh pr merge' "$skill_md" || {
    echo "gh pr merge not found"
    return 1
  }
}

test_router_step_2_5_is_gate() {
  local skill_md="$SKILLS_DIR/ticket-auto/SKILL.md"
  [ -f "$skill_md" ] || return 1
  local step25
  step25=$(grep 'STEP_2_5' "$skill_md" | grep -i 'gate' || true)
  [ -n "$step25" ] || {
    echo "STEP_2_5 not associated with gate"
    return 1
  }
}

test_router_step_3_5_is_reconcile() {
  local skill_md="$SKILLS_DIR/ticket-auto/SKILL.md"
  [ -f "$skill_md" ] || return 1
  grep -q 'STEP_3_5' "$skill_md" || {
    echo "STEP_3_5 not in dispatch table"
    return 1
  }
}

test_router_step_4_is_implement() {
  local skill_md="$SKILLS_DIR/ticket-auto/SKILL.md"
  [ -f "$skill_md" ] || return 1
  local section
  section=$(sed -n '/### STEP_4 —\|### STEP_4$/,/^### /p' "$skill_md" 2>/dev/null)
  echo "$section" | grep -qi 'implement' || {
    echo "STEP_4 not associated with implement"
    return 1
  }
}

test_router_step_4_6_is_pr_review() {
  local skill_md="$SKILLS_DIR/ticket-auto/SKILL.md"
  [ -f "$skill_md" ] || return 1
  local section
  section=$(sed -n '/### STEP_4_6/,/^### /p' "$skill_md" 2>/dev/null)
  echo "$section" | grep -qiE 'pr.review|PR Review' || {
    echo "STEP_4_6 not associated with PR review"
    return 1
  }
}

test_router_step_5_is_document_wiki() {
  local skill_md="$SKILLS_DIR/ticket-auto/SKILL.md"
  [ -f "$skill_md" ] || return 1
  local section
  section=$(sed -n '/### STEP_5 —\|### STEP_5$/,/^### /p' "$skill_md" 2>/dev/null)
  echo "$section" | grep -qiE 'document|wiki|maintenance' || {
    echo "STEP_5 not associated with document/wiki"
    return 1
  }
}

test_router_step_6_is_report() {
  local skill_md="$SKILLS_DIR/ticket-auto/SKILL.md"
  [ -f "$skill_md" ] || return 1
  local section
  section=$(sed -n '/### STEP_6/,/^---/p' "$skill_md" 2>/dev/null)
  echo "$section" | grep -qiE 'retro|report|outcome' || {
    echo "STEP_6 not associated with report"
    return 1
  }
}

test_router_dispatch_table_covers_all_steps() {
  local skill_md="$SKILLS_DIR/ticket-auto/SKILL.md"
  [ -f "$skill_md" ] || return 1
  local count
  count=$(grep -cE 'STEP_[0-9]' "$skill_md" || true)
  [ "$count" -ge 8 ] || {
    echo "Only $count STEP references (need >=8)"
    return 1
  }
}

test_router_spawn_pattern_documented() {
  local skill_md="$SKILLS_DIR/ticket-auto/SKILL.md"
  [ -f "$skill_md" ] || return 1
  grep -q 'spawn_agent_pre\|spawn_capture\|spawn_agent_post' "$skill_md" || {
    echo "3-step spawn pattern not documented"
    return 1
  }
}

test_router_default_case_present() {
  local skill_md="$SKILLS_DIR/ticket-auto/SKILL.md"
  [ -f "$skill_md" ] || return 1
  grep -qi 'unknown\|default\|unrecognized.*RESUME_STEP' "$skill_md" || {
    echo "Default case for unknown RESUME_STEP not found"
    return 1
  }
}

test_router_zero_inline_llm_invariant() {
  local skill_md="$SKILLS_DIR/ticket-auto/SKILL.md"
  [ -f "$skill_md" ] || return 1
  grep -q 'zero inline LLM\|no inline LLM\|No inline LLM' "$skill_md" || {
    echo "Zero inline LLM invariant not declared"
    return 1
  }
}

test_router_team_resolution_query_failure_message() {
  local skill_md="$SKILLS_DIR/ticket-auto/SKILL.md"
  [ -f "$skill_md" ] || return 1
  local preflight
  preflight=$(sed -n '/Step 0.4 — Preflight/,/^## /p' "$skill_md" 2>/dev/null)
  echo "$preflight" | grep -qE '\^\[0-9\]\+\$' || {
    echo "team_count numeric-format guard not found (query-failure detection)"
    return 1
  }
  echo "$preflight" | grep -qi 'teams query failed' || {
    echo "distinct query-failure message not found"
    return 1
  }
}

test_router_team_resolution_multi_team_message_unchanged() {
  local skill_md="$SKILLS_DIR/ticket-auto/SKILL.md"
  [ -f "$skill_md" ] || return 1
  grep -q 'Multiple Linear teams — set LINEAR_TEAM_ID' "$skill_md" || {
    echo "genuine multi-team message missing or changed"
    return 1
  }
}

# ── Gate-check.sh tests ────────────────────────────────────────────────────────

test_gate_check_has_artifact_guard() {
  local gate_check="$LIB_DIR/gate-check.sh"
  [ -f "$gate_check" ] || {
    echo "gate-check.sh not found"
    return 1
  }
  grep -q 'EXEC_NO_ARTIFACT' "$gate_check" || {
    echo "gate-check.sh missing artifact guard"
    return 1
  }
}

test_gate_check_has_entry_mode() {
  local gate_check="$LIB_DIR/gate-check.sh"
  [ -f "$gate_check" ] || return 1
  grep -q '_gate_entry' "$gate_check" || {
    echo "gate-check.sh missing entry mode"
    return 1
  }
}

test_gate_check_has_reapprove_mode() {
  local gate_check="$LIB_DIR/gate-check.sh"
  [ -f "$gate_check" ] || return 1
  grep -q '_gate_reapprove' "$gate_check" || {
    echo "gate-check.sh missing reapprove mode"
    return 1
  }
}

# ── Outcome-label-check.sh tests ────────────────────────────────────────────────

test_outcome_check_exists() {
  [ -f "$LIB_DIR/outcome-label-check.sh" ] || {
    echo "outcome-label-check.sh not found"
    return 1
  }
}

test_outcome_check_has_label_detection() {
  local oc="$LIB_DIR/outcome-label-check.sh"
  [ -f "$oc" ] || return 1
  grep -q 'Smooth\|Rough\|Hard' "$oc" || {
    echo "outcome-label-check.sh missing label detection"
    return 1
  }
}

# ── Gate reconcile ─────────────────────────────────────────────────────────────

test_gate_reconcile_skill_exists() {
  [ -f "$SKILLS_DIR/ticket-gate-reconcile/SKILL.md" ] || {
    echo "ticket-gate-reconcile skill not found"
    return 1
  }
}

test_gate_reconcile_has_context_loading() {
  local skill_md="$SKILLS_DIR/ticket-gate-reconcile/SKILL.md"
  [ -f "$skill_md" ] || return 1
  grep -q 'source /tmp/ticket-auto' "$skill_md" && grep -q 'env.sh' "$skill_md" || {
    echo "gate-reconcile missing env.sh context loading"
    return 1
  }
}

# ── Increment B — silent-skip & false-done fixes (R3, R9, R2) ─────────────────

test_router_implement_complete_has_plugin_cache_fallback() {
  local skill_md="$SKILLS_DIR/ticket-auto/SKILL.md"
  [ -f "$skill_md" ] || return 1
  local block
  block=$(sed -n '/Then transition from Ready/,/^```$/p' "$skill_md")
  echo "$block" | grep -q 'claude/plugins/cache' || {
    echo "implement-complete flow.sh resolution missing plugin-cache fallback"
    return 1
  }
  echo "$block" | grep -qE 'hb_retry|hb-wrap\.sh' || {
    echo "implement-complete flow.sh resolution no longer swallows failure with hb_retry/hb-wrap.sh"
    return 1
  }
  echo "$block" | grep -q '|| true' && {
    echo "implement-complete flow.sh resolution still swallows failure with || true"
    return 1
  }
  return 0
}

test_router_prescan_success_judged_by_content() {
  local skill_md="$SKILLS_DIR/ticket-auto/SKILL.md"
  [ -f "$skill_md" ] || return 1
  local block
  block=$(sed -n '/spawn_capture TICKET_ID={TICKET-ID} PHASE=MAINTENANCE/,/flock -u/p' "$skill_md")
  # Success must be judged by the agent's returned CONTENT, not by spawn_capture's
  # exit code. The return now arrives as a file (RESULT_FILE=, quoted heredoc) rather
  # than an interpolated "$AGENT_RESULT" argument, so the content check greps the file.
  echo "$block" | grep -q 'grep -q "\$slug: scanned" /tmp/ticket-auto-{TICKET-ID}-agent-return.txt' || {
    echo "prescan success no longer judged by the agent's returned content"
    return 1
  }
  echo "$block" | grep -qE '\bif \[ \$\? -eq 0 \]' && {
    echo "prescan success still judged by spawn_capture exit code"
    return 1
  }
  return 0
}

test_router_retro_condition_2_uses_success_markers() {
  local skill_md="$SKILLS_DIR/ticket-auto/SKILL.md"
  [ -f "$skill_md" ] || return 1
  local block
  block=$(sed -n '/Condition 2: did the ticket NOT reach/,/^fi/p' "$skill_md")
  echo "$block" | grep -q 'VERIFY|verify|done|PASS' || {
    echo "retro condition 2 does not check verify PASS marker"
    return 1
  }
  # PR-REVIEW's own Verdict tokens are OK/WARN/BLOCK, never PASS (that's
  # VERIFY-only) — GitHub #149.
  echo "$block" | grep -q 'PR-REVIEW|pr-review|done|OK' || {
    echo "retro condition 2 does not check PR-review OK marker"
    return 1
  }
  echo "$block" | grep -q 'PR-REVIEW|pr-review|done|PASS' && {
    echo "retro condition 2 still checks the non-existent PR-review PASS token"
    return 1
  }
  echo "$block" | grep -q 'META|outcome|info|completed:' && {
    echo "retro condition 2 still tests the tautological outcome marker"
    return 1
  }
  return 0
}

test_router_verify_dispatch_uses_verdict_tokens() {
  local skill_md="$SKILLS_DIR/ticket-auto/SKILL.md"
  [ -f "$skill_md" ] || return 1
  local block
  block=$(sed -n '/### STEP_4_5 —/,/### STEP_4_6 —/p' "$skill_md")
  echo "$block" | grep -q 'VERDICT=PASS' || {
    echo "STEP_4_5 does not pass VERDICT=PASS on verify success"
    return 1
  }
  echo "$block" | grep -q 'VERDICT=FAIL' || {
    echo "STEP_4_5 does not pass VERDICT=FAIL on verify failure"
    return 1
  }
}

test_router_verify_checks_verify_last_before_dispatch() {
  local skill_md="$SKILLS_DIR/ticket-auto/SKILL.md"
  [ -f "$skill_md" ] || return 1
  local block
  block=$(sed -n '/### STEP_4_5 —/,/### STEP_4_6 —/p' "$skill_md")
  echo "$block" | grep -q '{VERIFY_LAST}' || {
    echo "STEP_4_5 does not branch on VERIFY_LAST"
    return 1
  }
  echo "$block" | grep -qi 're-implement' || {
    echo "STEP_4_5 does not dispatch re-implement when VERIFY_LAST=fail"
    return 1
  }
}

test_router_pr_review_dispatch_uses_verdict_tokens() {
  local skill_md="$SKILLS_DIR/ticket-auto/SKILL.md"
  [ -f "$skill_md" ] || return 1
  local block
  block=$(sed -n '/### STEP_4_6 —/,/### Auto-merge logic/p' "$skill_md")
  echo "$block" | grep -q 'VERDICT=OK' || {
    echo "STEP_4_6 does not map ✅ to VERDICT=OK"
    return 1
  }
  echo "$block" | grep -q 'VERDICT=WARN' || {
    echo "STEP_4_6 does not map ⚠️ to VERDICT=WARN"
    return 1
  }
  echo "$block" | grep -q 'VERDICT=BLOCK' || {
    echo "STEP_4_6 does not map ❌ to VERDICT=BLOCK"
    return 1
  }
}

test_detect_resume_iteration_uses_warn_token() {
  local src="$LIB_DIR/../skills/ticket-detect-resume/detect-resume.sh"
  [ -f "$src" ] || return 1
  grep -q "PR-REVIEW|pr-review|done|WARN" "$src" || {
    echo "ITERATION no longer counts the WARN verdict token"
    return 1
  }
  grep -q 'Verdict.\*⚠️' "$src" && {
    echo "ITERATION still coupled to byte-exact emoji match"
    return 1
  }
  return 0
}

test_detect_resume_outputs_verify_last() {
  local src="$LIB_DIR/../skills/ticket-detect-resume/detect-resume.sh"
  [ -f "$src" ] || return 1
  grep -q 'VERIFY_LAST:' "$src" || {
    echo "detect-resume.sh does not emit VERIFY_LAST"
    return 1
  }
}

test_router_auto_merge_covers_auto_and_semi_auto() {
  local skill_md="$SKILLS_DIR/ticket-auto/SKILL.md"
  [ -f "$skill_md" ] || return 1
  local block
  block=$(sed -n '/### Auto-merge logic/,/^```$/p' "$skill_md")
  echo "$block" | grep -q '{AUTONOMY}" = "auto"' || {
    echo "auto-merge no longer covers AUTONOMY=auto"
    return 1
  }
  echo "$block" | grep -q '{AUTONOMY}" = "semi-auto"' || {
    echo "auto-merge no longer covers AUTONOMY=semi-auto"
    return 1
  }
}

test_router_auto_merge_reads_outcome_label_not_implement_line() {
  local skill_md="$SKILLS_DIR/ticket-auto/SKILL.md"
  [ -f "$skill_md" ] || return 1
  local block
  block=$(sed -n '/### Auto-merge logic/,/^```$/p' "$skill_md")
  echo "$block" | grep -q 'META|outcome-label|info|' || {
    echo "auto-merge does not read the authoritative outcome-label META line"
    return 1
  }
  echo "$block" | grep -q "IMPLEMENT|implement|done|" && {
    echo "auto-merge still reads OUTCOME from the implement terminal line"
    return 1
  }
  return 0
}

test_outcome_label_check_writes_meta_line() {
  local src="$LIB_DIR/outcome-label-check.sh"
  [ -f "$src" ] || return 1
  grep -q 'META" "outcome-label" "info"' "$src" || {
    echo "outcome-label-check.sh does not write META|outcome-label"
    return 1
  }
}

test_router_retro_conditions_1_and_3_unchanged() {
  local skill_md="$SKILLS_DIR/ticket-auto/SKILL.md"
  [ -f "$skill_md" ] || return 1
  grep -q "META|gate-stop|fail|" "$skill_md" || {
    echo "retro condition 1 (gate-stop) missing"
    return 1
  }
  grep -q "grep -q '|fallback|' \"{HB_LOG_FILE}\"" "$skill_md" || {
    echo "retro condition 3 (heartbeat fallback) missing or changed"
    return 1
  }
}

# ── Increment F — hygiene batch (R10, R11, R12, R13) ──────────────────────────

test_router_pr_feedback_cycle_caps_at_3() {
  local skill_md="$SKILLS_DIR/ticket-auto/SKILL.md"
  [ -f "$skill_md" ] || return 1
  local block
  block=$(sed -n '/### STEP_5_5 —/,/^### STEP_6/p' "$skill_md")
  echo "$block" | grep -q '{PR_FEEDBACK_CYCLE}" -ge 3' || {
    echo "STEP_5_5 does not cap PR_FEEDBACK_CYCLE at 3"
    return 1
  }
  echo "$block" | grep -q 'PR_FEEDBACK_EXHAUSTED' || {
    echo "STEP_5_5 does not gate-stop with PR_FEEDBACK_EXHAUSTED"
    return 1
  }
}

test_router_pr_reconcile_emits_cycle_marker() {
  local skill_md="$SKILLS_DIR/ticket-auto/SKILL.md"
  [ -f "$skill_md" ] || return 1
  local block
  block=$(sed -n '/### STEP_5_5 —/,/^### STEP_6/p' "$skill_md")
  echo "$block" | grep -q 'MSG="cycle#' || {
    echo "STEP_5_5 does not emit a cycle# marker for PR_FEEDBACK_CYCLE to count"
    return 1
  }
}

test_router_reconcile_cycle_caps_at_3() {
  local skill_md="$SKILLS_DIR/ticket-auto/SKILL.md"
  [ -f "$skill_md" ] || return 1
  local block
  block=$(sed -n '/### STEP_3_5 —/,/^### STEP_4/p' "$skill_md")
  echo "$block" | grep -q '{RECONCILE_CYCLE}" -ge 3' || {
    echo "STEP_3_5 does not cap RECONCILE_CYCLE at 3"
    return 1
  }
  echo "$block" | grep -q 'RECONCILE_EXHAUSTED' || {
    echo "STEP_3_5 does not gate-stop with RECONCILE_EXHAUSTED"
    return 1
  }
}

test_router_prescan_skipped_on_late_resume() {
  local skill_md="$SKILLS_DIR/ticket-auto/SKILL.md"
  [ -f "$skill_md" ] || return 1
  local block
  block=$(sed -n '/## Prescan gate/,/### Identify affected repos/p' "$skill_md")
  echo "$block" | grep -q 'Skip on late resume' || {
    echo "prescan gate missing late-resume skip section"
    return 1
  }
  echo "$block" | grep -qE 'STEP_4 \| STEP_4_5 \| STEP_4_6' || {
    echo "prescan gate does not skip STEP_4+ resume steps"
    return 1
  }
}

test_router_autonomy_write_is_guarded() {
  local skill_md="$SKILLS_DIR/ticket-auto/SKILL.md"
  [ -f "$skill_md" ] || return 1
  local block
  block=$(sed -n '/Log the resolved autonomy mode/,/hb-wrap.sh gate "phase-transition"/p' "$skill_md")
  echo "$block" | grep -q '_recorded_autonomy' || {
    echo "autonomy write is not guarded by a recorded-value check"
    return 1
  }
  echo "$block" | grep -q 'mode-change' || {
    echo "autonomy write does not log an explicit mode-change event"
    return 1
  }
}

# Replaces test_router_dashboard_pane_not_duplicated. The router no longer
# spawns a dashboard pane at all (fleetd-phase-supervisor task 7.4), so the
# duplicate-pane guard it used to assert on has nothing left to guard: the
# guard only existed because every resume spawned another pane. What matters
# now is that the spawn does not come back — under fleetd that was one tmux
# pane per ticket, each showing a single ticket.
test_router_does_not_spawn_a_dashboard_pane() {
  local skill_md="$SKILLS_DIR/ticket-auto/SKILL.md"
  [ -f "$skill_md" ] || return 1
  # A blunt literal search, which is why the prose above it in SKILL.md is
  # worded to avoid the command: the guard is only useful if it cannot be
  # satisfied by a passing mention.
  grep -q 'tmux split-window' "$skill_md" && {
    echo "router still spawns a tmux dashboard pane"
    return 1
  }
  # It must still tell the operator how to open one, including the fleet view.
  grep -q 'dashboard.py --fleet' "$skill_md" || {
    echo "router does not surface the --fleet dashboard command"
    return 1
  }
}

# ── dispatcher ─────────────────────────────────────────────────────────────────

filter="${1:-}"

for func in $(declare -F | grep '^declare -f test_' | sed 's/declare -f //'); do
  if [ -z "$filter" ] || echo "$func" | grep -q "$filter"; then
    _run "$func" "$func"
  fi
done

echo "---"
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
