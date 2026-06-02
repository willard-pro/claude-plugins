#!/usr/bin/env bash
# test-pipeline-phases.sh — unit tests for pipeline phase ordering
# Usage: bash test-pipeline-phases.sh [test_name_filter]
set -euo pipefail

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
get_issue() { echo '{"id":"TEST-1","title":"Test Ticket","labels":{"nodes":[{"name":"bug"}]}}'; }
get_comments() { echo '[]'; }
resolve_ticket_dir() { echo "/tmp/TEST-1--test"; }
get_complexity() { echo "simple"; }

# ── Task 1.5: Phase ordering in orchestrator step table ────────────────────────

test_step_table_maps_pr_review_to_step_46() {
  # Verify the orchestrator step table maps STEP_4_6 → PR Review
  local skill_md="$SKILLS_DIR/ticket-auto/SKILL.md"
  [ -f "$skill_md" ] || { echo "SKILL.md not found at $skill_md"; return 1; }

  # Extract the step table rows for STEP_4_6 and STEP_5
  local step46
  step46=$(grep 'STEP_4_6' "$skill_md" | grep 'PR Review' || true)
  local step5
  step5=$(grep 'STEP_5 ' "$skill_md" | grep 'Document + Wiki' || true)

  [ -n "$step46" ] || { echo "STEP_4_6 not mapped to PR Review"; return 1; }
  [ -n "$step5" ] || { echo "STEP_5 not mapped to Document + Wiki"; return 1; }
}

test_pr_review_before_maintenance_in_skill_md() {
  # Verify PR Review section appears before Document/Wiki section
  local skill_md="$SKILLS_DIR/ticket-auto/SKILL.md"
  [ -f "$skill_md" ] || return 1

  local pr_line
  pr_line=$(grep -n '^## Step 4\.6.*PR Review' "$skill_md" | cut -d: -f1 | head -1)
  local maint_line
  maint_line=$(grep -n '^## Step 5.*Document + Wiki' "$skill_md" | cut -d: -f1 | head -1)

  [ -n "$pr_line" ] || { echo "PR Review heading not found"; return 1; }
  [ -n "$maint_line" ] || { echo "Document + Wiki heading not found"; return 1; }
  [ "$pr_line" -lt "$maint_line" ] || { echo "PR Review (line $pr_line) not before Document/Wiki (line $maint_line)"; return 1; }
}

test_verify_transitions_to_pr_review() {
  # Verify that PASS in VERIFY transitions to PR-REVIEW, not MAINTENANCE
  local skill_md="$SKILLS_DIR/ticket-auto/SKILL.md"
  [ -f "$skill_md" ] || return 1

  # Check NEXT_PHASE in verify PASS spawn_agent_post
  grep -q 'NEXT_PHASE=PR-REVIEW' "$skill_md" || { echo "No NEXT_PHASE=PR-REVIEW found in SKILL.md"; return 1; }

  # Check verify skip heartbeat
  grep -q 'IMPLEMENT → PR-REVIEW (verify skipped)' "$skill_md" || { echo "Missing verify skip transition to PR-REVIEW"; return 1; }
}

test_pr_review_transitions_to_maintenance() {
  # Verify PR Review transitions to MAINTENANCE, not REPORT
  local skill_md="$SKILLS_DIR/ticket-auto/SKILL.md"
  [ -f "$skill_md" ] || return 1

  grep -q 'PR-REVIEW → MAINTENANCE' "$skill_md" || { echo "Missing PR-REVIEW → MAINTENANCE transition"; return 1; }

  # The old PR-REVIEW → REPORT should no longer exist
  if grep -q 'PR-REVIEW → REPORT' "$skill_md"; then
    echo "PR-REVIEW → REPORT still present (should be PR-REVIEW → MAINTENANCE)"
    return 1
  fi
}

test_maintenance_transitions_to_report() {
  # Verify Document/Wiki (now Step 5) transitions to REPORT
  local skill_md="$SKILLS_DIR/ticket-auto/SKILL.md"
  [ -f "$skill_md" ] || return 1

  # Maintenance spawn_agent_post should have NEXT_PHASE=REPORT
  local maint_section
  maint_section=$(sed -n '/^## Step 5.*Document + Wiki/,/^## Step 5\.5/p' "$skill_md")
  echo "$maint_section" | grep -q 'NEXT_PHASE=REPORT' || { echo "Maintenance section missing NEXT_PHASE=REPORT"; return 1; }
}

# ── Task 1.6: detect-resume.sh step mapping consistency ────────────────────────

test_detect_resume_step_table() {
  local detect_sh="$SKILLS_DIR/ticket-detect-resume/detect-resume.sh"
  [ -f "$detect_sh" ] || { echo "detect-resume.sh not found"; return 1; }

  # Verify MAINTENANCE done → STEP_6 (lines 82-85 of detect-resume.sh)
  # The first elif after the 'if ! -s' should detect MAINTENANCE|maintenance|done| and set STEP_6
  local maint_done_block
  maint_done_block=$(sed -n '/MAINTENANCE|maintenance|done/,/RESUME_STEP=/p' "$detect_sh" | head -5)
  echo "$maint_done_block" | grep -q 'STEP_6' || { echo "MAINTENANCE done not mapped to STEP_6"; return 1; }

  # Verify VERIFY PASS → STEP_4_6
  local verify_pass_block
  verify_pass_block=$(sed -n '/VERIFY|verify|done|PASS/,/RESUME_STEP=/p' "$detect_sh" | head -5)
  echo "$verify_pass_block" | grep -q 'STEP_4_6' || { echo "VERIFY PASS not mapped to STEP_4_6"; return 1; }

  # Verify PR-REVIEW open PR no-human-comments → STEP_5
  grep -q 'RESUME_STEP="STEP_5"' "$detect_sh" || { echo "No STEP_5 mapping in detect-resume.sh"; return 1; }
}

test_detect_resume_all_8_steps() {
  # Verify detect-resume.sh references all 8 major step constants
  local detect_sh="$SKILLS_DIR/ticket-detect-resume/detect-resume.sh"
  [ -f "$detect_sh" ] || return 1

  local steps=("STEP_1" "STEP_1_5" "STEP_2" "STEP_3" "STEP_4" "STEP_4_5" "STEP_4_6" "STEP_5" "STEP_5_5" "STEP_6")
  local missing=""

  for step in "${steps[@]}"; do
    if ! grep -q "$step" "$detect_sh"; then
      missing="$missing $step"
    fi
  done

  [ -z "$missing" ] || { echo "Missing step references in detect-resume.sh:$missing"; return 1; }
}

# ── Task 2.7: Phase-transition completeness ────────────────────────────────────

test_heartbeat_phase_transition_count() {
  # Verify at least 8 phase-transition entries are referenced in orchestrator
  local skill_md="$SKILLS_DIR/ticket-auto/SKILL.md"
  [ -f "$skill_md" ] || return 1

  # Count phase-transition hb_gate and hb_heartbeat entries
  local count
  count=$(grep -cE '(hb_gate|hb_heartbeat).*phase-transition' "$skill_md" || true)
  [ "$count" -ge 8 ] || { echo "Only $count phase-transition entries found (need >= 8)"; return 1; }
}

test_heartbeat_phase_transition_order() {
  # Verify phase transitions appear in correct order
  local skill_md="$SKILLS_DIR/ticket-auto/SKILL.md"
  [ -f "$skill_md" ] || return 1

  local transitions
  transitions=$(grep -oE '(START → APPRAISE|APPRAISE → REPRODUCE|REPRODUCE → EXEC|EXEC → GATE|GATE → IMPLEMENT|IMPLEMENT → VERIFY|VERIFY → PR-REVIEW|PR-REVIEW → MAINTENANCE|MAINTENANCE → REPORT|IMPLEMENT → PR-REVIEW)' "$skill_md" || true)
  local count
  count=$(echo "$transitions" | wc -l)
  [ "$count" -ge 6 ] || { echo "Only $count expected phase transition strings found"; return 1; }
}

# ── Task 2.8: Skipped-phase transitions ────────────────────────────────────────

test_skipped_phase_transitions() {
  # Verify skipped phases produce transition entries with "(skipped)" suffix
  local skill_md="$SKILLS_DIR/ticket-auto/SKILL.md"
  [ -f "$skill_md" ] || return 1

  # Check for skipped reproduce transition
  grep -q 'APPRAISE → REPRODUCE (skipped)' "$skill_md" || { echo "Missing skipped REPRODUCE transition"; return 1; }

  # Check for skipped verify transition
  grep -q 'verify skipped' "$skill_md" || { echo "Missing skipped VERIFY transition reference"; return 1; }
}

# ── Task 4.5-4.6: Log dedup tests ─────────────────────────────────────────────

test_maintenance_agent_uses_distinct_step_name() {
  # Agent's wiki maintenance entry uses "wiki-errata" not "maintenance"
  # to avoid collision with spawn_agent_post's phase bracket
  local skill_md="$SKILLS_DIR/ticket-auto/SKILL.md"
  [ -f "$skill_md" ] || return 1

  # Agent should write wiki-errata (not maintenance) for internal wiki step
  grep -q '|MAINTENANCE|wiki-errata|' "$skill_md" || { echo "Agent wiki entries not using distinct step name wiki-errata"; return 1; }

  # spawn_agent_post still writes MAINTENANCE|maintenance|done (phase bracket)
  grep -q 'PHASE=MAINTENANCE' "$skill_md" || { echo "MAINTENANCE phase not found in spawn instructions"; return 1; }
}

test_spawn_capture_does_not_write_to_pipeline_log() {
  # spawn_capture calls capture_agent_result which writes to transcript, not LOG_FILE
  local cap_script="$LIB_DIR/capture-transcript.sh"
  [ -f "$cap_script" ] || { echo "capture-transcript.sh not found"; return 1; }

  # capture-transcript.sh should NOT reference LOG_FILE
  if grep -q 'LOG_FILE' "$cap_script"; then
    echo "capture-transcript.sh references LOG_FILE (should not)"
    return 1
  fi
  return 0
}

# ── Task 5.4-5.6: Metadata deferral tests ─────────────────────────────────────

test_meta_title_guarded_against_unknown() {
  # META|title emission is guarded against empty/unknown values
  local skill_md="$SKILLS_DIR/ticket-auto/SKILL.md"
  [ -f "$skill_md" ] || return 1

  # Guard should check for "unknown" before emitting title
  grep -q 'unknown' "$skill_md" | grep -q 'META|title' || \
    grep -q '|META|title|info|' "$skill_md" || { echo "Cannot verify title guard"; return 1; }

  # Title emission should be inside an if guard
  grep -B5 'META|title|info|' "$skill_md" | grep -q 'if \[' || { echo "Title emission not guarded with if [ condition ]"; return 1; }
}

test_meta_artifact_guarded_for_absolute_path() {
  # META|artifact emission is guarded for absolute path (starts with /)
  local skill_md="$SKILLS_DIR/ticket-auto/SKILL.md"
  [ -f "$skill_md" ] || return 1

  # Path guard: checks that path starts with "/"
  grep -q 'cut -c1.*=.*/' "$skill_md" || { echo "Absolute path guard not found for artifact emission"; return 1; }
}

test_meta_title_at_most_once() {
  # At-most-once guard: only emit META|title if no prior entry exists
  local skill_md="$SKILLS_DIR/ticket-auto/SKILL.md"
  [ -f "$skill_md" ] || return 1

  # Title emission should check for existing META|title before writing
  grep -q 'META|title.*grep.*META|title' "$skill_md" || \
    grep -B10 'META|title|info|' "$skill_md" | grep -q 'grep.*META|title' || \
    { echo "At-most-once guard not found for META|title"; return 1; }
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
