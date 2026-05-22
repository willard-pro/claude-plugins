#!/usr/bin/env bash
# test-reconcile-comments.sh — unit tests for lib/reconcile-comments.sh
# reconcile-comments.sh is a standalone script: args <ticket_id> <log_file>, stdin = comments JSON.
# It sources linear-api.sh internally for normalize_comments.
# Usage: bash test-reconcile-comments.sh [test_name_filter]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

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

# ── tests ──────────────────────────────────────────────────────────────────────

test_finds_appraisal_comment_boundary() {
  local tmpdir; tmpdir=$(mktemp -d)
  local log_file="$tmpdir/pipeline.log"; touch "$log_file"

  local comments='[{"id":"c1","body":"**Ticket appraised** — complexity: simple","createdAt":"2024-01-01T10:00:00Z","user":{"name":"bot"}}]'
  local output
  output=$(echo "$comments" | bash "$LIB_DIR/reconcile-comments.sh" "WIL-1" "$log_file" 2>/dev/null)

  rm -rf "$tmpdir"
  echo "$output" | grep -q "APPRAISAL_COMMENT_AT: 2024-01-01T10:00:00Z"
}

test_falls_back_to_log_when_no_appraisal_comment() {
  local tmpdir; tmpdir=$(mktemp -d)
  local log_file="$tmpdir/pipeline.log"
  echo "2024-01-01T09:00:00Z|APPRAISE|appraise|done|complexity: simple" > "$log_file"

  local comments='[{"id":"c1","body":"regular user comment","createdAt":"2024-01-01T08:00:00Z","user":{"name":"alice"}}]'
  local output
  output=$(echo "$comments" | bash "$LIB_DIR/reconcile-comments.sh" "WIL-1" "$log_file" 2>/dev/null)

  rm -rf "$tmpdir"
  echo "$output" | grep -q "APPRAISAL_COMMENT_AT: 2024-01-01T09:00:00Z"
}

test_amendment_boundary_wins_when_later() {
  local tmpdir; tmpdir=$(mktemp -d)
  local log_file="$tmpdir/pipeline.log"; touch "$log_file"

  local comments='[
    {"id":"c1","body":"**Ticket appraised** — info","createdAt":"2024-01-01T10:00:00Z","user":{"name":"bot"}},
    {"id":"c2","body":"**Amendment cycle #1** — changes applied","createdAt":"2024-01-01T11:00:00Z","user":{"name":"bot"}}
  ]'
  local output
  output=$(echo "$comments" | bash "$LIB_DIR/reconcile-comments.sh" "WIL-1" "$log_file" 2>/dev/null)

  rm -rf "$tmpdir"
  echo "$output" | grep -q "LAST_RECONCILE_AT: 2024-01-01T11:00:00Z"
}

test_excludes_pipeline_authored_comments() {
  local tmpdir; tmpdir=$(mktemp -d)
  local log_file="$tmpdir/pipeline.log"; touch "$log_file"

  # Appraisal at 10:00, amendment at 11:00 — no user comments after boundary
  local comments='[
    {"id":"c1","body":"**Ticket appraised** — info","createdAt":"2024-01-01T10:00:00Z","user":{"name":"bot"}},
    {"id":"c2","body":"**Amendment cycle #1** — details","createdAt":"2024-01-01T11:00:00Z","user":{"name":"bot"}}
  ]'
  local output
  output=$(echo "$comments" | bash "$LIB_DIR/reconcile-comments.sh" "WIL-1" "$log_file" 2>/dev/null)

  rm -rf "$tmpdir"
  echo "$output" | grep -q "(none)"
}

test_returns_none_when_no_unprocessed() {
  local tmpdir; tmpdir=$(mktemp -d)
  local log_file="$tmpdir/pipeline.log"; touch "$log_file"

  # Appraisal at 10:00, user comment at 09:00 (before boundary)
  local comments='[
    {"id":"c1","body":"**Ticket appraised** — complexity: simple","createdAt":"2024-01-01T10:00:00Z","user":{"name":"bot"}},
    {"id":"c2","body":"user comment before appraisal","createdAt":"2024-01-01T09:00:00Z","user":{"name":"alice"}}
  ]'
  local output
  output=$(echo "$comments" | bash "$LIB_DIR/reconcile-comments.sh" "WIL-1" "$log_file" 2>/dev/null)

  rm -rf "$tmpdir"
  echo "$output" | grep -q "UNPROCESSED_COMMENTS:" && echo "$output" | grep -q "(none)"
}

# ── dispatch ──────────────────────────────────────────────────────────────────

FILTER="${1:-}"

for fn in \
  test_finds_appraisal_comment_boundary \
  test_falls_back_to_log_when_no_appraisal_comment \
  test_amendment_boundary_wins_when_later \
  test_excludes_pipeline_authored_comments \
  test_returns_none_when_no_unprocessed; do
  [ -z "$FILTER" ] || [[ "$fn" == *"$FILTER"* ]] || continue
  _run "$fn" "$fn"
done

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
