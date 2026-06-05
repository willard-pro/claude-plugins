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
