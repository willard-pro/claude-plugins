#!/usr/bin/env bash
# test-return-completeness.sh — unit tests for lib/return-completeness-check.sh
# Usage: bash test-return-completeness.sh [test_name_filter]
set -eo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$TEST_DIR/.." && pwd)"
RCC="$LIB_DIR/return-completeness-check.sh"

PASS=0
FAIL=0

_run() {
  local name="$1"
  shift
  # Toggle -e off to capture test function return values correctly.
  # Test functions may legitimately return non-zero for assertion failures.
  set +e
  "$@"
  local rc=$?
  set -e
  if [ $rc -eq 0 ]; then
    echo "PASS: $name"
    ((PASS++)) || true
  else
    echo "FAIL: $name  (exit $rc)"
    ((FAIL++)) || true
  fi
}

# ── Mock environment ──────────────────────────────────────────────────────────

_ws=""   # workspace dir
_root="" # mock REPOS_ROOT
_repo="" # mock git repo under REPOS_ROOT

_setup() {
  _ws=$(mktemp -d)
  _root="$_ws/repos-root"
  _repo="$_root/test-repo"
  mkdir -p "$_repo"
  git -C "$_repo" init -q
  git -C "$_repo" config user.email "test@test.com"
  git -C "$_repo" config user.name "Test"
  echo "// test source" >"$_repo/main.ts"
  git -C "$_repo" add main.ts
  git -C "$_repo" commit -q -m "initial commit"
}

_teardown() {
  rm -rf "$_ws" 2>/dev/null || true
}

# Write a tasks.md for a ticket under the mock repo's openspec/changes dir.
# Args: ticket-id  body (heredoc-style unchecked/checked lines)
_write_tasks() {
  local ticket_id="$1" body="$2"
  local change_dir="$_repo/openspec/changes/${ticket_id,,}--fix-thing"
  mkdir -p "$change_dir"
  printf '%s\n' "$body" >"$change_dir/tasks.md"
}

# Write a simple-fix.md for a ticket under a mock ticket workspace directory.
# Args: ticket-id  body (heredoc-style, including ## Completion Checklist section)
_write_simple_fix() {
  local ticket_id="$1" body="$2"
  local ws_dir="$_repo/${ticket_id,,}--fix-thing"
  mkdir -p "$ws_dir"
  printf '%s\n' "$body" >"$ws_dir/simple-fix.md"
}

# Run return-completeness-check.sh against REPOS_ROOT and source its output.
_run_check() {
  local ticket_id="$1"
  local _tmp_out="$_ws/rcc-out.env"
  local _saved_opts="$-"
  set +e
  "$RCC" "$ticket_id" --repos-root "$_root" >"$_tmp_out" 2>/dev/null
  RCC_EXIT=$?
  case "$_saved_opts" in *e*) set -e ;; esac
  # shellcheck disable=SC1090
  source "$_tmp_out"
}

# ── Tests ──────────────────────────────────────────────────────────────────────

test_all_checked_exits_0() {
  _setup
  _write_tasks "TEST-1" "$(
    cat <<'EOF'
## 1. Section
- [x] 1.1 done thing
- [x] 1.2 also done
EOF
  )"
  _run_check "TEST-1"
  [ "$RCC_EXIT" -eq 0 ] && [ "$RETURN_COMPLETENESS_STATUS" = "complete" ] && [ "$UNCHECKED_COUNT" -eq 0 ]
  local rc=$?
  _teardown
  return $rc
}

test_unchecked_box_exits_1() {
  _setup
  _write_tasks "TEST-2" "$(
    cat <<'EOF'
## 1. Section
- [x] 1.1 done thing
- [ ] 1.2 not done
EOF
  )"
  _run_check "TEST-2"
  [ "$RCC_EXIT" -eq 1 ] && [ "$RETURN_COMPLETENESS_STATUS" = "incomplete" ] && [ "$UNCHECKED_COUNT" -eq 1 ] && [ "$REASON" = "UNCHECKED_BOXES" ]
  local rc=$?
  _teardown
  return $rc
}

test_multiple_unchecked_counted() {
  _setup
  _write_tasks "TEST-3" "$(
    cat <<'EOF'
## 1. Section
- [ ] 1.1 not done
- [ ] 1.2 also not done
- [x] 1.3 done
EOF
  )"
  _run_check "TEST-3"
  [ "$RCC_EXIT" -eq 1 ] && [ "$UNCHECKED_COUNT" -eq 2 ] && [ "$TOTAL_COUNT" -eq 3 ]
  local rc=$?
  _teardown
  return $rc
}

test_missing_tasks_file_exits_2() {
  _setup
  # No tasks.md written for this ticket at all.
  _run_check "NOPE-999"
  [ "$RCC_EXIT" -eq 2 ] && [ "$RETURN_COMPLETENESS_STATUS" = "error" ] && [ "$REASON" = "NO_PLAN_ARTIFACT_FOUND" ]
  local rc=$?
  _teardown
  return $rc
}

test_tasks_file_flag_bypasses_search() {
  _setup
  _write_tasks "TEST-4" "$(
    cat <<'EOF'
- [x] 1.1 done
EOF
  )"
  local direct_path="$_repo/openspec/changes/test-4--fix-thing/tasks.md"
  local _tmp_out="$_ws/rcc-direct-out.env"
  "$RCC" "TEST-4" --tasks-file "$direct_path" >"$_tmp_out" 2>/dev/null
  local rc=$?
  # shellcheck disable=SC1090
  source "$_tmp_out"
  [ "$rc" -eq 0 ] && [ "$TASKS_FILE" = "$direct_path" ]
  rc=$?
  _teardown
  return $rc
}

test_unchecked_items_lists_content() {
  _setup
  _write_tasks "TEST-5" "$(
    cat <<'EOF'
- [ ] 1.1 write the docs
- [x] 1.2 done
EOF
  )"
  _run_check "TEST-5"
  echo "$UNCHECKED_ITEMS" | grep -q "write the docs"
  local rc=$?
  _teardown
  return $rc
}

# ── Simple-fix path tests (Completion Checklist section) ─────────────────────

test_simple_fix_all_checked_exits_0() {
  _setup
  _write_simple_fix "TEST-SF-1" "$(
    cat <<'EOF'
# Simple Fix — TEST-SF-1
## Summary
Fix thing.
## How to implement
Do X then Y.
## Completion Checklist
- [x] AC-1: User can click button
- [x] AC-2: Modal closes on save
EOF
  )"
  _run_check "TEST-SF-1"
  [ "$RCC_EXIT" -eq 0 ] && [ "$RETURN_COMPLETENESS_STATUS" = "complete" ] && [ "$UNCHECKED_COUNT" -eq 0 ] && [ "$ARTIFACT_TYPE" = "simple-fix" ]
  local rc=$?
  _teardown
  return $rc
}

test_simple_fix_unchecked_box_exits_1() {
  _setup
  _write_simple_fix "TEST-SF-2" "$(
    cat <<'EOF'
# Simple Fix — TEST-SF-2
## Summary
Fix thing.
## Completion Checklist
- [x] AC-1: Done item
- [ ] AC-2: Not done item
EOF
  )"
  _run_check "TEST-SF-2"
  [ "$RCC_EXIT" -eq 1 ] && [ "$RETURN_COMPLETENESS_STATUS" = "incomplete" ] && [ "$UNCHECKED_COUNT" -eq 1 ] && [ "$REASON" = "UNCHECKED_BOXES" ]
  local rc=$?
  _teardown
  return $rc
}

test_simple_fix_missing_checklist_exits_2() {
  _setup
  _write_simple_fix "TEST-SF-3" "$(
    cat <<'EOF'
# Simple Fix — TEST-SF-3
## Summary
Fix thing but no checklist section.
## How to implement
Do X.
EOF
  )"
  _run_check "TEST-SF-3"
  [ "$RCC_EXIT" -eq 2 ] && [ "$RETURN_COMPLETENESS_STATUS" = "error" ] && [ "$REASON" = "COMPLETION_CHECKLIST_MISSING" ]
  local rc=$?
  _teardown
  return $rc
}

# ── Runner ─────────────────────────────────────────────────────────────────────

echo "=== return-completeness-check.sh unit tests ==="
echo ""

_run "all boxes checked → exit 0" test_all_checked_exits_0
_run "unchecked box → exit 1" test_unchecked_box_exits_1
_run "multiple unchecked boxes counted correctly" test_multiple_unchecked_counted
_run "missing tasks.md → exit 2" test_missing_tasks_file_exits_2
_run "--tasks-file flag bypasses repo search" test_tasks_file_flag_bypasses_search
_run "UNCHECKED_ITEMS lists unchecked line content" test_unchecked_items_lists_content
_run "simple-fix all checked → exit 0" test_simple_fix_all_checked_exits_0
_run "simple-fix unchecked box → exit 1" test_simple_fix_unchecked_box_exits_1
_run "simple-fix missing checklist section → exit 2" test_simple_fix_missing_checklist_exits_2

echo ""
echo "=== $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] || exit 1
