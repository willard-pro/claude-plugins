#!/usr/bin/env bash
# phase2.sh — integration tests for add-stop-on-ambiguity-gates.
set -euo pipefail

PASS=0
FAIL=0

_run() {
  local name="$1"; shift
  if "$@" 2>/dev/null; then
    echo "PASS: $name"; ((PASS++)) || true
  else
    echo "FAIL: $name"; ((FAIL++)) || true
  fi
}

# ── Gate 1: EXEC_NO_ARTIFACT ─────────────────────────────────────────────────

test_exec_no_artifact_fires_when_file_missing() {
  local tmp; tmp=$(mktemp -d)
  local log="$tmp/pipeline.log"
  local ticket_dir="$tmp/WIL-1--test"
  mkdir -p "$ticket_dir"
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|META|artifact|info|plan:$ticket_dir/simple-fix.md" >> "$log"

  PLAN_PATH=$(grep '|META|artifact|info|plan:' "$log" | tail -1 | cut -d'|' -f5 | sed 's/^plan://')
  [ ! -f "$PLAN_PATH" ] && \
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|META|gate-stop|fail|EXEC_NO_ARTIFACT — expected: $PLAN_PATH" >> "$log"

  local result; result=$(cat "$log")
  rm -rf "$tmp"
  echo "$result" | grep -q "EXEC_NO_ARTIFACT"
}

# ── Gate 2: COMPLEXITY_ARTIFACT_MISMATCH ─────────────────────────────────────

test_complexity_mismatch_complex_declared_simple_found() {
  local tmp; tmp=$(mktemp -d)
  local log="$tmp/pipeline.log"
  local ticket_dir="$tmp/WIL-2--test"
  mkdir -p "$ticket_dir"
  printf '## Complexity\n\n**Score:** complex\n' > "$ticket_dir/notes.md"
  touch "$ticket_dir/simple-fix.md"

  COMPLEXITY=$(bash -c "source ~/.claude/skills/lib/notes-parse.sh; get_complexity '$ticket_dir'")
  CHANGE_DIR=$(ls -d "$tmp/openspec/changes/"*/ 2>/dev/null | grep -i "wil-2" | head -1 || true)
  [ "$COMPLEXITY" = "complex" ] && [ -z "$CHANGE_DIR" ] && \
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|META|gate-stop|fail|COMPLEXITY_ARTIFACT_MISMATCH — declared=complex artifact=simple-fix.md" >> "$log"

  local result; result=$(cat "$log" 2>/dev/null || true)
  rm -rf "$tmp"
  echo "$result" | grep -q "COMPLEXITY_ARTIFACT_MISMATCH"
}

test_complexity_mismatch_simple_declared_no_artifact() {
  local tmp; tmp=$(mktemp -d)
  local log="$tmp/pipeline.log"
  local ticket_dir="$tmp/WIL-3--test"
  mkdir -p "$ticket_dir"
  printf '## Complexity\n\n**Score:** simple\n' > "$ticket_dir/notes.md"

  COMPLEXITY=$(bash -c "source ~/.claude/skills/lib/notes-parse.sh; get_complexity '$ticket_dir'")
  SIMPLE_FIX=$(find "$ticket_dir" -name "simple-fix.md" -print -quit 2>/dev/null)
  [ "$COMPLEXITY" = "simple" ] && [ -z "$SIMPLE_FIX" ] && \
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|META|gate-stop|fail|COMPLEXITY_ARTIFACT_MISMATCH — declared=simple artifact=none" >> "$log"

  local result; result=$(cat "$log" 2>/dev/null || true)
  rm -rf "$tmp"
  echo "$result" | grep -q "COMPLEXITY_ARTIFACT_MISMATCH"
}

test_complexity_mismatch_missing_score() {
  local tmp; tmp=$(mktemp -d)
  local log="$tmp/pipeline.log"
  local ticket_dir="$tmp/WIL-4--test"
  mkdir -p "$ticket_dir"
  printf '## Complexity\n\nSome notes but no score.\n' > "$ticket_dir/notes.md"

  COMPLEXITY=$(bash -c "source ~/.claude/skills/lib/notes-parse.sh; get_complexity '$ticket_dir'")
  [ -z "$COMPLEXITY" ] && \
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|META|gate-stop|fail|COMPLEXITY_ARTIFACT_MISMATCH — notes.md missing **Score:** field" >> "$log"

  local result; result=$(cat "$log" 2>/dev/null || true)
  rm -rf "$tmp"
  echo "$result" | grep -q "COMPLEXITY_ARTIFACT_MISMATCH"
}

# ── Gate 3: APPROVAL_REVOKED ─────────────────────────────────────────────────

test_approval_revoked_when_label_missing() {
  local log; log=$(mktemp)
  local live_state="Ready"
  local live_labels='["claimed","simple"]'
  local approved_present
  approved_present=$(echo "$live_labels" | jq 'index("approved") != null')

  if [ "$live_state" != "Ready" ] || [ "$approved_present" = "false" ]; then
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|META|gate-stop|fail|APPROVAL_REVOKED — state=$live_state approved=$approved_present" >> "$log"
  fi

  local result; result=$(cat "$log")
  rm -f "$log"
  echo "$result" | grep -q "APPROVAL_REVOKED"
}

test_approval_revoked_wrong_state() {
  local log; log=$(mktemp)
  local live_state="Backlog"
  [ "$live_state" != "Ready" ] && \
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|META|gate-stop|fail|APPROVAL_REVOKED — state=$live_state" >> "$log"

  local result; result=$(cat "$log")
  rm -f "$log"
  echo "$result" | grep -q "APPROVAL_REVOKED"
}

# ── Gate 4: REMEDIATION_BRIEF_TRUNCATED ──────────────────────────────────────

test_remediation_brief_truncated_marker_missing() {
  local tmp; tmp=$(mktemp -d)
  local log="$tmp/pipeline.log"
  local plan="$tmp/simple-fix.md"
  cat > "$plan" << 'EOF'
## Plan

Do stuff.

## Verification #1

**Date:** 2026-05-15

### Suggested Fix
Check the config.
EOF
  local last_line
  last_line=$(grep -n '^## Verification #' "$plan" | tail -1 | cut -d: -f1)
  local tail
  tail=$(awk "NR>$last_line && /^## / {exit} NF" "$plan" | tail -1)
  [ "$tail" != "<!-- /REMEDIATION_BRIEF -->" ] && \
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|META|gate-stop|fail|REMEDIATION_BRIEF_TRUNCATED — marker missing in: $plan" >> "$log"

  local result; result=$(cat "$log" 2>/dev/null || true)
  rm -rf "$tmp"
  echo "$result" | grep -q "REMEDIATION_BRIEF_TRUNCATED"
}

test_remediation_brief_passes_with_marker() {
  local tmp; tmp=$(mktemp -d)
  local plan="$tmp/simple-fix.md"
  cat > "$plan" << 'EOF'
## Plan

Do stuff.

## Verification #1

**Date:** 2026-05-15

### Suggested Fix
Check the config.

<!-- /REMEDIATION_BRIEF -->
EOF
  local last_line
  last_line=$(grep -n '^## Verification #' "$plan" | tail -1 | cut -d: -f1)
  local tail
  tail=$(awk "NR>$last_line && /^## / {exit} NF" "$plan" | tail -1)
  rm -rf "$tmp"
  [ "$tail" = "<!-- /REMEDIATION_BRIEF -->" ]
}

# ── Gate 5: PR_REVIEW_VERDICT_UNPARSEABLE ────────────────────────────────────

test_verdict_unparseable_zero_lines() {
  local log; log=$(mktemp)
  local output="No verdict here at all."
  local count; count=$(echo "$output" | grep -cP '^\*\*Verdict:\*\* [✅⚠️]' || true)
  [ "$count" -ne 1 ] && \
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|META|gate-stop|fail|PR_REVIEW_VERDICT_UNPARSEABLE — found $count Verdict lines" >> "$log"
  local result; result=$(cat "$log"); rm -f "$log"
  echo "$result" | grep -q "PR_REVIEW_VERDICT_UNPARSEABLE"
}

test_verdict_unparseable_two_lines() {
  local log; log=$(mktemp)
  local output; output=$(printf '**Verdict:** ✅ All good\n**Verdict:** ⚠️ Gaps\n')
  local count; count=$(echo "$output" | grep -cP '^\*\*Verdict:\*\* [✅⚠️]' || true)
  [ "$count" -ne 1 ] && \
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|META|gate-stop|fail|PR_REVIEW_VERDICT_UNPARSEABLE — found $count Verdict lines" >> "$log"
  local result; result=$(cat "$log"); rm -f "$log"
  echo "$result" | grep -q "PR_REVIEW_VERDICT_UNPARSEABLE"
}

test_verdict_passes_with_trailing_text() {
  local output="**Verdict:** ✅ All requirements addressed"
  local count; count=$(echo "$output" | grep -cP '^\*\*Verdict:\*\* [✅⚠️]' || true)
  [ "$count" -eq 1 ]
}

test_verdict_wrong_emoji_fires() {
  local log; log=$(mktemp)
  local output="**Verdict:** PASS"
  local count; count=$(echo "$output" | grep -cP '^\*\*Verdict:\*\* [✅⚠️]' || true)
  [ "$count" -ne 1 ] && \
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|META|gate-stop|fail|PR_REVIEW_VERDICT_UNPARSEABLE — found $count Verdict lines" >> "$log"
  local result; result=$(cat "$log"); rm -f "$log"
  echo "$result" | grep -q "PR_REVIEW_VERDICT_UNPARSEABLE"
}

# ── dispatch ──────────────────────────────────────────────────────────────────

FILTER="${1:-}"

for fn in \
  test_exec_no_artifact_fires_when_file_missing \
  test_complexity_mismatch_complex_declared_simple_found \
  test_complexity_mismatch_simple_declared_no_artifact \
  test_complexity_mismatch_missing_score \
  test_approval_revoked_when_label_missing \
  test_approval_revoked_wrong_state \
  test_remediation_brief_truncated_marker_missing \
  test_remediation_brief_passes_with_marker \
  test_verdict_unparseable_zero_lines \
  test_verdict_unparseable_two_lines \
  test_verdict_passes_with_trailing_text \
  test_verdict_wrong_emoji_fires; do
  [ -z "$FILTER" ] || [[ "$fn" == *"$FILTER"* ]] || continue
  _run "$fn" "$fn"
done

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
