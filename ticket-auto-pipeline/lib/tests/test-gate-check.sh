#!/usr/bin/env bash
# test-gate-check.sh — unit tests for lib/gate-check.sh
# Usage: bash test-gate-check.sh [test_name_filter]
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
_fake_complexity="simple"

_setup() {
  _ws=$(mktemp -d)
  _tid="CRE-47"
  _flow_log="${_ws}/flow-calls.log"
  touch "$_flow_log"
  _fake_issue="null"
  _fake_complexity="simple"

  LOG_FILE="${_ws}/${_tid}-pipeline.log"
  HB_LOG_FILE="${_ws}/${_tid}-heartbeat.log"
  TICKET_ID="$_tid"

  # Reset mocked functions after sourcing
  _install_mocks
}

_teardown() {
  rm -rf "$_ws" 2>/dev/null || true
}

# ── Scaffold pipeline log ──────────────────────────────────────────────────────

_plog_raw() {
  local phase="$1" step="$2" status="$3" msg="$4"
  local iso="${5:-2026-06-05T10:00:00Z}"
  echo "${iso}|${phase}|${step}|${status}|${msg}" >>"$LOG_FILE"
}

# ── Mock overrides (installed AFTER sourcing gate-check.sh) ─────────────────────

_install_mocks() {
  # Override get_issue to return configured fake response
  get_issue() { echo "$_fake_issue"; }

  # Override get_complexity to return configured fake value
  get_complexity() { echo "$_fake_complexity"; }

  # Override flow.sh resolution — never find real flow.sh
  _resolve_flow_sh() { echo "${_ws}/mock-flow.sh"; }
  FLOW_SH="${_ws}/mock-flow.sh"

  # Create a stub flow.sh that records calls
  cat >"${_ws}/mock-flow.sh" <<FLOWEOF
#!/usr/bin/env bash
echo "flow-sh-called|\$*" >> "${_ws}/flow-calls.log"
exit 0
FLOWEOF
  chmod +x "${_ws}/mock-flow.sh"

  # Override resolve_ticket_dir
  resolve_ticket_dir() { echo "${_ws}/${1}--test"; }
}

# Scaffold exec-done pipeline log with configurable params
_scaffold_exec_done() {
  local complexity="${1:-simple}"
  local autonomy="${2:-auto}"
  local artifact_type="${3:-simple-fix}"
  local artifact_path="${4:-${_ws}/simple-fix.md}"

  _fake_complexity="$complexity"

  # Schema header
  _plog_raw "META" "schema" "info" "1"
  # Title
  _plog_raw "META" "title" "info" "ID:${_tid} -- Test Ticket"
  # Autonomy
  _plog_raw "META" "autonomy" "info" "${autonomy}"
  # Appraise done
  _plog_raw "APPRAISE" "appraise" "done" "complexity=${complexity}"
  # Artifact path
  if [ -n "$artifact_path" ]; then
    _plog_raw "META" "artifact" "info" "plan:${artifact_path}"
  fi
  # Exec done with artifact type hint
  _plog_raw "EXEC" "exec" "done" "plan:${artifact_type}:${artifact_path}"

  # Create artifact file if path is set and not "none"
  if [ -n "$artifact_path" ] && [ "$artifact_path" != "none" ]; then
    mkdir -p "$(dirname "$artifact_path")" 2>/dev/null || true
    touch "$artifact_path" 2>/dev/null || true
  fi
}

# Like _scaffold_exec_done but omits META|artifact|info|plan: and writes
# EXEC|create-artifact|done| instead of EXEC|exec|done| — matching the actual
# ticket-appraise-exec log format. Exercises the fallback path in _get_artifact_path.
_scaffold_no_meta_artifact() {
  local complexity="${1:-simple}"
  local autonomy="${2:-auto}"
  local artifact_type="${3:-simple-fix}"

  _fake_complexity="$complexity"

  _plog_raw "META" "schema" "info" "1"
  _plog_raw "META" "title" "info" "ID:${_tid} -- Test Ticket"
  _plog_raw "META" "autonomy" "info" "${autonomy}"
  _plog_raw "APPRAISE" "appraise" "done" "complexity=${complexity}"
  # No META|artifact|info|plan: — forces fallback to EXEC|create-artifact|done|
  _plog_raw "EXEC" "create-artifact" "done" "${artifact_type}"
}

# ── Source gate-check.sh (its main is guarded, functions load into this shell) ──

# Ensure gate-check.sh sources its dependencies from the local dev lib,
# not from ~/.claude/skills/lib (which may lack newer functions).
export CLAUDE_SKILLS_LIB="$LIB_DIR"

source "$LIB_DIR/gate-check.sh"

# ═══════════════════════════════════════════════════════════════════════════════
# Entry mode tests (11)
# ═══════════════════════════════════════════════════════════════════════════════

# 1. Artifact file missing → gate-stop EXEC_NO_ARTIFACT (exit 2)
test_entry_artifact_missing_gate_stop() {
  _setup
  _scaffold_exec_done "simple" "auto" "simple-fix" "${_ws}/nonexistent.md"
  # Remove the scaffolded file (scaffolding creates it)
  rm -f "${_ws}/nonexistent.md" 2>/dev/null || true

  _gate_entry
  local rc=$?

  _teardown
  [ "$rc" -eq 2 ] || {
    echo "expected exit 2, got $rc"
    return 1
  }
}

# 2. Complexity mismatch (complex complexity + simple-fix artifact) → gate-stop
test_entry_complexity_artifact_mismatch() {
  _setup
  _scaffold_exec_done "complex" "auto" "simple-fix" "${_ws}/simple-fix.md"

  _gate_entry
  local rc=$?

  _teardown
  [ "$rc" -eq 2 ] || {
    echo "expected exit 2, got $rc"
    return 1
  }
}

# 3. Simple + auto mode → calls flow.sh human-approve (exit 0)
test_entry_simple_auto_calls_flow_human_approve() {
  _setup
  _scaffold_exec_done "simple" "auto" "simple-fix" "${_ws}/simple-fix.md"

  _gate_entry
  local rc=$?

  local flow_calls
  flow_calls=$(cat "$_flow_log" 2>/dev/null || true)

  _teardown
  [ "$rc" -eq 0 ] || {
    echo "expected exit 0, got $rc"
    return 1
  }
  echo "$flow_calls" | grep -q "human-approve" || {
    echo "flow.sh human-approve not called"
    return 1
  }
}

# 4. Simple + semi-auto mode → calls flow.sh human-approve (exit 0)
test_entry_simple_semi_auto_calls_flow_human_approve() {
  _setup
  _scaffold_exec_done "simple" "semi-auto" "simple-fix" "${_ws}/simple-fix.md"

  _gate_entry
  local rc=$?

  local flow_calls
  flow_calls=$(cat "$_flow_log" 2>/dev/null || true)

  _teardown
  [ "$rc" -eq 0 ] || {
    echo "expected exit 0, got $rc"
    return 1
  }
  echo "$flow_calls" | grep -q "human-approve" || {
    echo "flow.sh human-approve not called"
    return 1
  }
}

# 5. Simple + manual → held (exit 1)
test_entry_simple_manual_held() {
  _setup
  _scaffold_exec_done "simple" "manual" "simple-fix" "${_ws}/simple-fix.md"

  _gate_entry
  local rc=$?

  _teardown
  [ "$rc" -eq 1 ] || {
    echo "expected exit 1, got $rc"
    return 1
  }
}

# 6. Complex → held regardless of autonomy (exit 1)
test_entry_complex_held() {
  _setup
  _scaffold_exec_done "complex" "auto" "openspec" "${_ws}/openspec-change.md"

  _gate_entry
  local rc=$?

  _teardown
  [ "$rc" -eq 1 ] || {
    echo "expected exit 1, got $rc"
    return 1
  }
}

# 7. Gate start event written
test_entry_gate_start_event_written() {
  _setup
  _scaffold_exec_done "simple" "auto" "simple-fix" "${_ws}/simple-fix.md"

  _gate_entry

  local has_start
  has_start=$(grep -c '|GATE|gate|start|' "$LOG_FILE" 2>/dev/null || true)

  _teardown
  [ "${has_start:-0}" -ge 1 ] || {
    echo "gate start event not found"
    return 1
  }
}

# 8. Autonomy from pipeline log (crash recovery — detects auto correctly)
test_entry_autonomy_from_log() {
  _setup
  _scaffold_exec_done "simple" "auto" "simple-fix" "${_ws}/simple-fix.md"

  _gate_entry
  local rc=$?

  _teardown
  [ "$rc" -eq 0 ] || {
    echo "expected exit 0 for auto mode, got $rc"
    return 1
  }
}

# 9. Complexity from notes.md
test_entry_complexity_from_notes() {
  _setup
  _scaffold_exec_done "simple" "auto" "simple-fix" "${_ws}/simple-fix.md"

  _gate_entry
  local rc=$?

  _teardown
  [ "$rc" -eq 0 ] || {
    echo "expected exit 0 for simple, got $rc"
    return 1
  }
}

# 10. Artifact path from log
test_entry_artifact_path_from_log() {
  _setup
  _scaffold_exec_done "simple" "auto" "simple-fix" "${_ws}/simple-fix.md"

  # Artifact file exists → check passes
  [ -f "${_ws}/simple-fix.md" ] || {
    echo "artifact file not scaffolded"
    _teardown
    return 1
  }

  _gate_entry
  local rc=$?

  _teardown
  [ "$rc" -eq 0 ] || {
    echo "expected exit 0, got $rc"
    return 1
  }
}

# 10b. Artifact path fallback — only EXEC|create-artifact|done|, no META|artifact
test_entry_artifact_path_fallback_from_create_artifact() {
  _setup
  # Scaffold WITHOUT the META|artifact entry — only EXEC|create-artifact|done|
  _scaffold_no_meta_artifact "simple" "auto" "simple-fix"

  # Create the artifact file at the ticket dir path that resolve_ticket_dir returns
  local td
  td=$(resolve_ticket_dir "$TICKET_ID" "." 2>/dev/null || echo "$_ws")
  mkdir -p "$td" 2>/dev/null || true
  touch "$td/simple-fix.md"

  _gate_entry
  local rc=$?

  _teardown
  [ "$rc" -eq 0 ] || {
    echo "expected exit 0, got $rc"
    return 1
  }
}

# 11. Fleet-detect format: held log entry matches |GATE|gate|fail|held:
test_entry_fleet_detect_format() {
  _setup
  _scaffold_exec_done "complex" "auto" "openspec" "${_ws}/openspec-change.md"

  _gate_entry

  local held_line
  held_line=$(grep '|GATE|gate|fail|held:' "$LOG_FILE" 2>/dev/null || true)

  _teardown
  [ -n "$held_line" ] || {
    echo "no gate-held line with held: prefix"
    return 1
  }
}

# ═══════════════════════════════════════════════════════════════════════════════
# Reapprove mode tests (4)
# ═══════════════════════════════════════════════════════════════════════════════

# 12. Approved + Ready → passes (exit 0)
test_reapprove_approved_and_ready_passes() {
  _setup
  _fake_issue='{"id":"CRE-47","title":"Test","state":{"name":"Ready"},"labels":{"nodes":[{"name":"approved"},{"name":"bug"}]}}'

  _gate_reapprove
  local rc=$?

  _teardown
  [ "$rc" -eq 0 ] || {
    echo "expected exit 0, got $rc"
    return 1
  }
}

# 13. Label missing → APPROVAL_REVOKED (exit 2)
test_reapprove_label_missing_gate_stop() {
  _setup
  _fake_issue='{"id":"CRE-47","title":"Test","state":{"name":"Ready"},"labels":{"nodes":[{"name":"bug"}]}}'

  _gate_reapprove
  local rc=$?

  _teardown
  [ "$rc" -eq 2 ] || {
    echo "expected exit 2, got $rc"
    return 1
  }
}

# 14. Wrong state → APPROVAL_REVOKED (exit 2)
test_reapprove_wrong_state_gate_stop() {
  _setup
  _fake_issue='{"id":"CRE-47","title":"Test","state":{"name":"In Progress"},"labels":{"nodes":[{"name":"approved"},{"name":"bug"}]}}'

  _gate_reapprove
  local rc=$?

  _teardown
  [ "$rc" -eq 2 ] || {
    echo "expected exit 2, got $rc"
    return 1
  }
}

# 15. Both state and label wrong — single gate-stop entry
test_reapprove_both_wrong_single_gate_stop() {
  _setup
  _fake_issue='{"id":"CRE-47","title":"Test","state":{"name":"Backlog"},"labels":{"nodes":[{"name":"bug"}]}}'

  _gate_reapprove
  local rc=$?

  local gate_stop_count
  gate_stop_count=$(grep -c 'APPROVAL_REVOKED' "$LOG_FILE" 2>/dev/null || true)

  _teardown
  [ "$rc" -eq 2 ] || {
    echo "expected exit 2, got $rc"
    return 1
  }
  [ "${gate_stop_count:-0}" -eq 1 ] || {
    echo "expected 1 APPROVAL_REVOKED, got ${gate_stop_count:-0}"
    return 1
  }
}

# ═══════════════════════════════════════════════════════════════════════════════
# Verification plan extraction tests (Check 2.6) — exercises the new
# ## Verification Plan → per-criterion table → fallback chain
# ═══════════════════════════════════════════════════════════════════════════════

# Helper: scaffold notes.md with critique section (unlocks Check 2.6)
_scaffold_critique() {
  local score="${1:-75}"
  local status="${2:-PASS}"
  local td
  td=$(resolve_ticket_dir "$TICKET_ID" "." 2>/dev/null || echo "$_ws")
  mkdir -p "$td" 2>/dev/null || true
  cat >"${td}/notes.md" <<NOTESEOF
## Complexity
**Score:** simple

## Readiness Critique
**Score:** ${score}
**Status:** ${status}
NOTESEOF
}

# Helper: append a verification plan with a populated per-criterion table to notes.md
_scaffold_verify_plan_full() {
  local td
  td=$(resolve_ticket_dir "$TICKET_ID" "." 2>/dev/null || echo "$_ws")
  mkdir -p "$td" 2>/dev/null || true
  # Ensure critique section exists first
  if ! grep -q '## Readiness Critique' "${td}/notes.md" 2>/dev/null; then
    _scaffold_critique 75 PASS
  fi
  cat >>"${td}/notes.md" <<'PLANEOF'

## Verification Plan
**Date:** 2026-06-24
**Derived by:** ticket-appraise-exec Step 3.7
**Overall role scope:** global

### Role Scope Assessment

| Feature area | Affected roles | Scope type | Confidence | Basis |
|-------------|---------------|-----------|-----------|-------|
| handover | all | global | low | heuristic |

### Per-Criterion Verification

| # | Criterion | Role scope | Navigation path | Test data needed | Expected behavior | Verifiable |
|---|----------|-----------|----------------|-----------------|-------------------|-----------|
| 1 | Attorney clicks Send to create handover | global | /handover/ | none | Handover created and visible in list | ✓ |
| 2 | Admin views all handovers | role: admin | /admin/ | seed data: 3 handovers | All handovers displayed in admin table | ✓ |
PLANEOF
}

# Helper: append a verification plan with an empty per-criterion table (all columns blank)
_scaffold_verify_plan_empty() {
  local td
  td=$(resolve_ticket_dir "$TICKET_ID" "." 2>/dev/null || echo "$_ws")
  mkdir -p "$td" 2>/dev/null || true
  if ! grep -q '## Readiness Critique' "${td}/notes.md" 2>/dev/null; then
    _scaffold_critique 75 PASS
  fi
  cat >>"${td}/notes.md" <<'PLANEOF'

## Verification Plan
**Date:** 2026-06-24
**Derived by:** ticket-appraise-exec Step 3.7
**Overall role scope:** unknown

### Per-Criterion Verification

| # | Criterion | Role scope | Navigation path | Test data needed | Expected behavior | Verifiable |
|---|----------|-----------|----------------|-----------------|-------------------|-----------|
| 1 | Vague criterion |  |  |  |  | ✗ |
PLANEOF
}

# Helper: append a verification plan heading WITHOUT the per-criterion subsection
_scaffold_verify_plan_no_table() {
  local td
  td=$(resolve_ticket_dir "$TICKET_ID" "." 2>/dev/null || echo "$_ws")
  mkdir -p "$td" 2>/dev/null || true
  if ! grep -q '## Readiness Critique' "${td}/notes.md" 2>/dev/null; then
    _scaffold_critique 75 PASS
  fi
  cat >>"${td}/notes.md" <<'PLANEOF'

## Verification Plan
**Date:** 2026-06-24
**Derived by:** ticket-appraise-exec Step 3.7
**Overall role scope:** global
PLANEOF
}

# Helper: create an artifact file with verification prerequisites
_scaffold_artifact_with_prereqs() {
  local path="${1:-${_ws}/simple-fix.md}"
  cat >"$path" <<'ARTEOF'
# Simple Fix — Test

## Summary
Test fix with verification prerequisites.

**User:** test@example.com

## How to implement
1. Navigate to /handover/
2. Click Send button
3. Verify handover created

## Expected Behavior
- Handover appears in list after creation
- Admin can view all handovers at /admin/

## Setup
- Seed data: 3 test handovers
ARTEOF
}

# Helper: create a bare artifact file with NO verification prerequisites
_scaffold_artifact_bare() {
  local path="${1:-${_ws}/simple-fix.md}"
  cat >"$path" <<'ARTEOF'
# Simple Fix — Test

## Summary
Fix the thing.

## How to implement
Change line 42 of foo.js.
ARTEOF
}

# 16. Verification plan with populated table → all 4 prereqs found → auto-approve
test_verify_plan_full_table_auto_approves() {
  _setup
  _scaffold_exec_done "simple" "auto" "simple-fix" "${_ws}/simple-fix.md"
  _scaffold_critique 75 PASS
  _scaffold_verify_plan_full

  _gate_entry
  local rc=$?

  local held_line
  held_line=$(grep 'held: plan missing' "$LOG_FILE" 2>/dev/null || true)

  _teardown
  [ "$rc" -eq 0 ] || {
    echo "expected exit 0 (auto-approve), got $rc"
    return 1
  }
  [ -z "$held_line" ] || {
    echo "unexpected Check 2.6 hold with full verification plan table"
    return 1
  }
}

# 17. Empty verification plan table → falls back to artifact scan → prereqs found in artifact → auto-approve
test_verify_plan_empty_table_falls_back_to_artifact() {
  _setup
  _scaffold_exec_done "simple" "auto" "simple-fix" "${_ws}/simple-fix.md"
  _scaffold_critique 75 PASS
  _scaffold_verify_plan_empty
  _scaffold_artifact_with_prereqs "${_ws}/simple-fix.md"

  _gate_entry
  local rc=$?

  local held_line
  held_line=$(grep 'held: plan missing' "$LOG_FILE" 2>/dev/null || true)

  _teardown
  [ "$rc" -eq 0 ] || {
    echo "expected exit 0 (auto-approve via artifact fallback), got $rc"
    return 1
  }
  [ -z "$held_line" ] || {
    echo "unexpected Check 2.6 hold: artifact should have had prereqs"
    return 1
  }
}

# 18. Empty table AND bare artifact → Check 2.6 holds with 2+ missing
test_verify_plan_empty_table_and_bare_artifact_holds() {
  _setup
  _scaffold_exec_done "simple" "auto" "simple-fix" "${_ws}/simple-fix.md"
  _scaffold_critique 75 PASS
  _scaffold_verify_plan_empty
  _scaffold_artifact_bare "${_ws}/simple-fix.md"

  _gate_entry
  local rc=$?

  local held_line
  held_line=$(grep 'held: plan missing' "$LOG_FILE" 2>/dev/null || true)

  _teardown
  [ "$rc" -eq 1 ] || {
    echo "expected exit 1 (held), got $rc"
    return 1
  }
  [ -n "$held_line" ] || {
    echo "expected Check 2.6 hold, but no 'held: plan missing' in log"
    return 1
  }
}

# 19. No verification plan section → falls back to artifact (backward compat)
test_no_verify_plan_falls_back_to_artifact() {
  _setup
  _scaffold_exec_done "simple" "auto" "simple-fix" "${_ws}/simple-fix.md"
  _scaffold_critique 75 PASS
  # No _scaffold_verify_plan — notes.md has critique but no verification plan
  _scaffold_artifact_with_prereqs "${_ws}/simple-fix.md"

  _gate_entry
  local rc=$?

  local held_line
  held_line=$(grep 'held: plan missing' "$LOG_FILE" 2>/dev/null || true)

  _teardown
  [ "$rc" -eq 0 ] || {
    echo "expected exit 0 (auto-approve), got $rc"
    return 1
  }
  [ -z "$held_line" ] || {
    echo "unexpected Check 2.6 hold: artifact had prereqs via fallback"
    return 1
  }
}

# 20. Verification plan heading without per-criterion table → falls back
test_verify_plan_heading_without_table_falls_back() {
  _setup
  _scaffold_exec_done "simple" "auto" "simple-fix" "${_ws}/simple-fix.md"
  _scaffold_critique 75 PASS
  _scaffold_verify_plan_no_table
  _scaffold_artifact_with_prereqs "${_ws}/simple-fix.md"

  _gate_entry
  local rc=$?

  local held_line
  held_line=$(grep 'held: plan missing' "$LOG_FILE" 2>/dev/null || true)

  _teardown
  [ "$rc" -eq 0 ] || {
    echo "expected exit 0 (auto-approve via fallback), got $rc"
    return 1
  }
  [ -z "$held_line" ] || {
    echo "unexpected Check 2.6 hold: should have fallen back to artifact"
    return 1
  }
}

# 21. No critique section → Check 2.6 skipped entirely (old ticket backward compat)
test_no_critique_skips_readiness_check() {
  _setup
  _scaffold_exec_done "simple" "auto" "simple-fix" "${_ws}/simple-fix.md"
  # No critique section — old ticket without critique. Write notes.md directly
  # to avoid _scaffold_verify_plan_empty's auto-critique behavior.
  local td
  td=$(resolve_ticket_dir "$TICKET_ID" "." 2>/dev/null || echo "$_ws")
  mkdir -p "$td" 2>/dev/null || true
  cat >"${td}/notes.md" <<'NOTESEOF'
## Complexity
**Score:** simple

## Verification Plan
stuff but no per-criterion table
NOTESEOF
  _scaffold_artifact_bare "${_ws}/simple-fix.md"

  _gate_entry
  local rc=$?

  local held_line
  held_line=$(grep 'held: plan missing' "$LOG_FILE" 2>/dev/null || true)

  _teardown
  [ "$rc" -eq 0 ] || {
    echo "expected exit 0 (auto-approve, check skipped), got $rc"
    return 1
  }
  [ -z "$held_line" ] || {
    echo "unexpected Check 2.6 hold: should have been skipped (no critique)"
    return 1
  }
}

# 22. Verification plan with partial data — one column populated, three empty → fallback
test_verify_plan_partial_data_falls_back() {
  _setup
  _scaffold_exec_done "simple" "auto" "simple-fix" "${_ws}/simple-fix.md"
  _scaffold_critique 75 PASS

  # Create a verification plan where only the nav path column has content
  local td
  td=$(resolve_ticket_dir "$TICKET_ID" "." 2>/dev/null || echo "$_ws")
  mkdir -p "$td" 2>/dev/null || true
  cat >>"${td}/notes.md" <<'PLANEOF'

## Verification Plan
**Date:** 2026-06-24

### Per-Criterion Verification

| # | Criterion | Role scope | Navigation path | Test data needed | Expected behavior | Verifiable |
|---|----------|-----------|----------------|-----------------|-------------------|-----------|
| 1 | Some criterion |  | /handover/ |  |  | ✗ |
PLANEOF

  # Artifact also bare — so fallback should still fail
  _scaffold_artifact_bare "${_ws}/simple-fix.md"

  _gate_entry
  local rc=$?

  local held_line
  held_line=$(grep 'held: plan missing' "$LOG_FILE" 2>/dev/null || true)

  _teardown
  # nav_path=1, but test_user=0 → OR fallback triggers → artifact scan
  # artifact is bare → 0 prereqs found → Check 2.6 holds (2+ missing)
  [ "$rc" -eq 1 ] || {
    echo "expected exit 1 (held — fallback to bare artifact), got $rc"
    return 1
  }
  [ -n "$held_line" ] || {
    echo "expected Check 2.6 hold after fallback to bare artifact"
    return 1
  }
}

# ═══════════════════════════════════════════════════════════════════════════════
# Dispatcher
# ═══════════════════════════════════════════════════════════════════════════════

FILTER="${1:-}"

for fn in \
  test_entry_artifact_missing_gate_stop \
  test_entry_complexity_artifact_mismatch \
  test_entry_simple_auto_calls_flow_human_approve \
  test_entry_simple_semi_auto_calls_flow_human_approve \
  test_entry_simple_manual_held \
  test_entry_complex_held \
  test_entry_gate_start_event_written \
  test_entry_autonomy_from_log \
  test_entry_complexity_from_notes \
  test_entry_artifact_path_from_log \
  test_entry_artifact_path_fallback_from_create_artifact \
  test_entry_fleet_detect_format \
  test_reapprove_approved_and_ready_passes \
  test_reapprove_label_missing_gate_stop \
  test_reapprove_wrong_state_gate_stop \
  test_reapprove_both_wrong_single_gate_stop \
  test_verify_plan_full_table_auto_approves \
  test_verify_plan_empty_table_falls_back_to_artifact \
  test_verify_plan_empty_table_and_bare_artifact_holds \
  test_no_verify_plan_falls_back_to_artifact \
  test_verify_plan_heading_without_table_falls_back \
  test_no_critique_skips_readiness_check \
  test_verify_plan_partial_data_falls_back; do
  [ -z "$FILTER" ] || [[ "$fn" == *"$FILTER"* ]] || continue
  _run "$fn" "$fn"
done

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
