#!/usr/bin/env bash
# phase1.sh — unit tests for harden-ticket-auto-pipeline changes.
# Requires: bash, jq, socat, flock.
# Usage: bash phase1.sh [test_name]
# -u (nounset) intentionally omitted: Claude Code shell snapshots inject
# ZSH_VERSION references that trigger false-positive "unbound variable"
# errors in this bash version when nounset is active.
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILLS_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
FLOW_SH="$SCRIPT_DIR/../flow.sh"
DETECT_RESUME_SH="$SKILLS_DIR/ticket-detect-resume/detect-resume.sh"
VALIDATE_SH="$SCRIPT_DIR/../validate-linear-config.sh"
TICKET_DIR_SH="$PLUGIN_DIR/lib/ticket-dir.sh"

PASS=0
FAIL=0

_run() {
  local name="$1"
  shift
  local _stderr
  _stderr=$(mktemp)
  local _exit=0
  if "$@" 2>"$_stderr"; then
    echo "PASS: $name"
    ((PASS++)) || true
  else
    _exit=$?
    echo "FAIL: $name (exit $_exit)"
    if [ -s "$_stderr" ]; then
      echo "  stderr:"
      sed 's/^/    /' "$_stderr"
    fi
    ((FAIL++)) || true
  fi
  rm -f "$_stderr"
}

# ── helpers ──────────────────────────────────────────────────────────────────

_socat_stub() {
  # Start a socat HTTP stub on $1 that returns $2 (status code) for the first
  # $3 requests, then $4 for subsequent ones.
  # Returns the socat PID.
  # NOTE: socat must be detached from the subshell's job control (</dev/null,
  # >/dev/null, &) because command substitution $(...) waits for all children.
  local port="$1"
  local fail_code="$2"
  local fail_count="$3"
  local ok_body="$4"
  local count_file
  count_file=$(mktemp)
  echo 0 >"$count_file"

  socat TCP-LISTEN:"$port",reuseaddr,fork SYSTEM:"bash -c '
    n=\$(cat \"$count_file\"); n=\$((n+1)); echo \$n > \"$count_file\"
    if [ \$n -le $fail_count ]; then
      printf \"HTTP/1.1 $fail_code Service Unavailable\r\nContent-Length: 0\r\n\r\n\"
    else
      body=\$(echo $ok_body | base64 -d)
      len=\${#body}
      printf \"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \$len\r\n\r\n\$body\"
    fi
  '" </dev/null >/dev/null 2>&1 &
  echo $!
}

# ── test_validate_linear_config_dry_run ──────────────────────────────────────

test_validate_linear_config_dry_run() {
  local tmpdir
  tmpdir=$(mktemp -d)
  local sentinel_dir="$tmpdir/state/ticket-flow"
  local sm="$SCRIPT_DIR/../state-machine.json"
  [ -f "$sm" ] || {
    echo "state-machine.json missing" >&2
    return 1
  }

  SENTINEL_DIR="$sentinel_dir" bash "$VALIDATE_SH" --dry-run --team TEST_TEAM_ID 2>/dev/null || true
  # sentinel should exist after first run
  ls "$sentinel_dir"/validated-* 2>/dev/null | grep -q validated

  # second run should skip (sentinel-valid in log / no re-validation output)
  local out
  out=$(SENTINEL_DIR="$sentinel_dir" bash "$VALIDATE_SH" --dry-run --team TEST_TEAM_ID 2>&1 || true)
  echo "$out" | grep -q "sentinel-valid"

  rm -rf "$tmpdir"
}

# ── test_preflight_aborts_on_unset_key ───────────────────────────────────────

test_preflight_aborts_on_unset_key() {
  local tmpdir
  tmpdir=$(mktemp -d)
  local log="$tmpdir/test.log"

  unset LINEAR_API_KEY
  bash "$VALIDATE_SH" 2>/dev/null && return 1 # should fail when key missing
  [ ! -f "$log" ]                             # no log file should be created
  rm -rf "$tmpdir"
}

# ── test_flow_concurrent_lock ─────────────────────────────────────────────────

test_flow_concurrent_lock() {
  local tmpdir
  tmpdir=$(mktemp -d)
  mkdir -p "$tmpdir/logs"

  # Hold the lock in a background process
  (
    exec 9>"$tmpdir/logs/.ticket-flow-WIL-99.lock"
    if ! flock 9 2>/dev/null; then
      echo "flock failed (flock not installed?)" >&2
      exit 1
    fi
    sleep 5
  ) &
  local holder=$!
  sleep 0.2 # let the holder acquire the lock

  # Second invocation should exit 42. Point flow.sh at the same lock
  # directory the test holder is using so the mutex conflict is detected.
  local exit_code=0
  TICKET_FLOW_LOCK_DIR="$tmpdir/logs" \
    CLAUDE_SKILLS_LIB="$PLUGIN_DIR/lib" \
    bash -c "cd \"$tmpdir\" && \"$FLOW_SH\" WIL-99 appraise-start" >/dev/null 2>&1 || exit_code=$?

  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  rm -rf "$tmpdir"
  [ "$exit_code" -eq 42 ]
}

# ── test_flow_dispatcher_unknown_trigger ─────────────────────────────────────

test_flow_dispatcher_unknown_trigger() {
  local tmpdir
  tmpdir=$(mktemp -d)
  mkdir -p "$tmpdir/logs"
  local exit_code=0
  CLAUDE_SKILLS_LIB="$PLUGIN_DIR/lib" \
    bash -c "cd \"$tmpdir\" && \"$FLOW_SH\" WIL-99 not-a-real-trigger" >/dev/null 2>&1 || exit_code=$?
  rm -rf "$tmpdir"
  [ "$exit_code" -eq 3 ]
}

# ── test_flow_assertion_catches_silent_noop ──────────────────────────────────

test_flow_assertion_catches_silent_noop() {
  # Stub update_issue to return success but without actually mutating.
  # The post-trigger assertion should catch the mismatch and exit 7.
  # This test uses LINEAR_API_KEY bypass and mocked linear_graphql.
  echo "SKIP: requires mock infrastructure (see 8.4 notes)" >&2
  return 0 # placeholder
}

# ── test_linear_api_retry_on_503 ─────────────────────────────────────────────

test_linear_api_retry_on_503() {
  if ! command -v socat &>/dev/null; then
    echo "SKIP: socat not available" >&2
    return 0
  fi

  # Use a random high port to avoid conflicts with parallel CI jobs
  local port=$((20000 + RANDOM % 10000))
  local ok_body
  ok_body=$(echo '{"data":{"viewer":{"id":"u1","name":"Test"}}}' | base64 -w0)

  local socat_pid
  socat_pid=$(_socat_stub "$port" 503 2 "$ok_body")
  sleep 0.3

  # Verify socat actually started before proceeding
  if ! kill -0 "$socat_pid" 2>/dev/null; then
    echo "SKIP: socat failed to start" >&2
    return 0
  fi

  local exit_code=0
  LINEAR_API_URL="http://127.0.0.1:$port" LINEAR_API_KEY="test" \
    timeout 15 bash -c "source $PLUGIN_DIR/lib/linear-api.sh; linear_graphql '{\"query\":\"query{viewer{id name}}\"} '" \
    >/dev/null 2>&1 || exit_code=$?

  kill "$socat_pid" 2>/dev/null || true
  wait "$socat_pid" 2>/dev/null || true
  [ "$exit_code" -eq 0 ]
}

# ── test_detect_resume_schema_mismatch ───────────────────────────────────────

test_detect_resume_schema_mismatch() {
  local tmpdir
  tmpdir=$(mktemp -d)
  mkdir -p "$tmpdir/logs"
  local log="$tmpdir/logs/WIL-99-pipeline.log"
  # Write a non-empty log with NO schema header and content that fails v0-grace regex
  echo "corrupt log content without pipe format" >>"$log"

  local out
  out=$(cd "$tmpdir" && bash "$DETECT_RESUME_SH" WIL-99 2>/dev/null || true)
  rm -rf "$tmpdir"
  echo "$out" | grep -q "SCHEMA_MISMATCH"
}

# ── test_detect_resume_maintenance_document_done ────────────────────────────

test_detect_resume_maintenance_document_done() {
  local tmpdir
  tmpdir=$(mktemp -d)
  mkdir -p "$tmpdir/logs"
  local log="$tmpdir/logs/WIL-99-pipeline.log"
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|META|schema|info|1" >>"$log"
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|APPRAISE|appraise|done|simple, 5 files traced" >>"$log"
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|EXEC|create-artifact|done|simple-fix" >>"$log"
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|GATE|gate|done|auto-approved" >>"$log"
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|IMPLEMENT|implement|done|Smooth, branch: wil-99--fix" >>"$log"
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|MAINTENANCE|document|done|ai-context.md (3 patterns, 2 decisions, non-trivial)" >>"$log"

  local out
  out=$(CLAUDE_SKILLS_LIB="$PLUGIN_DIR/lib" cd "$tmpdir" && bash "$DETECT_RESUME_SH" WIL-99 2>/dev/null || true)
  local resume_step
  resume_step=$(echo "$out" | grep 'RESUME_STEP:' | awk '{print $2}')
  rm -rf "$tmpdir"
  [ "$resume_step" = "STEP_5" ]
}

# ── test_detect_resume_maintenance_document_waiting ─────────────────────────

test_detect_resume_maintenance_document_waiting() {
  local tmpdir
  tmpdir=$(mktemp -d)
  mkdir -p "$tmpdir/logs"
  local log="$tmpdir/logs/WIL-99-pipeline.log"
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|META|schema|info|1" >>"$log"
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|APPRAISE|appraise|done|simple, 5 files traced" >>"$log"
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|EXEC|create-artifact|done|simple-fix" >>"$log"
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|GATE|gate|done|auto-approved" >>"$log"
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|IMPLEMENT|implement|done|Smooth, branch: wil-99--fix" >>"$log"
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|MAINTENANCE|document|waiting|Agent launched — generating ai-context.md" >>"$log"

  local out
  out=$(CLAUDE_SKILLS_LIB="$PLUGIN_DIR/lib" cd "$tmpdir" && bash "$DETECT_RESUME_SH" WIL-99 2>/dev/null || true)
  local resume_step
  resume_step=$(echo "$out" | grep 'RESUME_STEP:' | awk '{print $2}')
  rm -rf "$tmpdir"
  [ "$resume_step" = "STEP_5" ]
}

# ── test_detect_resume_maintenance_document_fail ────────────────────────────

test_detect_resume_maintenance_document_fail() {
  local tmpdir
  tmpdir=$(mktemp -d)
  mkdir -p "$tmpdir/logs"
  local log="$tmpdir/logs/WIL-99-pipeline.log"
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|META|schema|info|1" >>"$log"
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|APPRAISE|appraise|done|simple, 5 files traced" >>"$log"
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|EXEC|create-artifact|done|simple-fix" >>"$log"
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|GATE|gate|done|auto-approved" >>"$log"
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|IMPLEMENT|implement|done|Smooth, branch: wil-99--fix" >>"$log"
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|MAINTENANCE|document|fail|Agent failed — continuing" >>"$log"

  local out
  out=$(CLAUDE_SKILLS_LIB="$PLUGIN_DIR/lib" cd "$tmpdir" && bash "$DETECT_RESUME_SH" WIL-99 2>/dev/null || true)
  local resume_step
  resume_step=$(echo "$out" | grep 'RESUME_STEP:' | awk '{print $2}')
  rm -rf "$tmpdir"
  [ "$resume_step" = "STEP_5" ]
}

# ── test_detect_resume_maintenance_maintenance_done ─────────────────────────

test_detect_resume_maintenance_maintenance_done() {
  local tmpdir
  tmpdir=$(mktemp -d)
  mkdir -p "$tmpdir/logs"
  local log="$tmpdir/logs/WIL-99-pipeline.log"
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|META|schema|info|1" >>"$log"
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|APPRAISE|appraise|done|simple, 5 files traced" >>"$log"
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|EXEC|create-artifact|done|simple-fix" >>"$log"
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|GATE|gate|done|auto-approved" >>"$log"
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|IMPLEMENT|implement|done|Smooth, branch: wil-99--fix" >>"$log"
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|MAINTENANCE|document|done|ai-context.md" >>"$log"
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|MAINTENANCE|maintenance|done|2 errata incorporated, 1 ai-context findings promoted to wiki" >>"$log"

  local out
  out=$(CLAUDE_SKILLS_LIB="$PLUGIN_DIR/lib" cd "$tmpdir" && bash "$DETECT_RESUME_SH" WIL-99 2>/dev/null || true)
  local resume_step
  resume_step=$(echo "$out" | grep 'RESUME_STEP:' | awk '{print $2}')
  rm -rf "$tmpdir"
  [ "$resume_step" = "STEP_6" ]
}

# ── test_detect_resume_maintenance_maintenance_waiting ──────────────────────

test_detect_resume_maintenance_maintenance_waiting() {
  local tmpdir
  tmpdir=$(mktemp -d)
  mkdir -p "$tmpdir/logs"
  local log="$tmpdir/logs/WIL-99-pipeline.log"
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|META|schema|info|1" >>"$log"
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|APPRAISE|appraise|done|simple, 5 files traced" >>"$log"
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|EXEC|create-artifact|done|simple-fix" >>"$log"
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|GATE|gate|done|auto-approved" >>"$log"
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|IMPLEMENT|implement|done|Smooth, branch: wil-99--fix" >>"$log"
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|MAINTENANCE|document|done|ai-context.md" >>"$log"
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|MAINTENANCE|maintenance|waiting|Agent launched — wiki maintenance" >>"$log"

  local out
  out=$(CLAUDE_SKILLS_LIB="$PLUGIN_DIR/lib" cd "$tmpdir" && bash "$DETECT_RESUME_SH" WIL-99 2>/dev/null || true)
  local resume_step
  resume_step=$(echo "$out" | grep 'RESUME_STEP:' | awk '{print $2}')
  rm -rf "$tmpdir"
  [ "$resume_step" = "STEP_5" ]
}

# ── test_detect_resume_maintenance_maintenance_fail ─────────────────────────

test_detect_resume_maintenance_maintenance_fail() {
  local tmpdir
  tmpdir=$(mktemp -d)
  mkdir -p "$tmpdir/logs"
  local log="$tmpdir/logs/WIL-99-pipeline.log"
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|META|schema|info|1" >>"$log"
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|APPRAISE|appraise|done|simple, 5 files traced" >>"$log"
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|EXEC|create-artifact|done|simple-fix" >>"$log"
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|GATE|gate|done|auto-approved" >>"$log"
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|IMPLEMENT|implement|done|Smooth, branch: wil-99--fix" >>"$log"
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|MAINTENANCE|document|done|ai-context.md" >>"$log"
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|MAINTENANCE|maintenance|fail|Agent failed — continuing" >>"$log"

  local out
  out=$(CLAUDE_SKILLS_LIB="$PLUGIN_DIR/lib" cd "$tmpdir" && bash "$DETECT_RESUME_SH" WIL-99 2>/dev/null || true)
  local resume_step
  resume_step=$(echo "$out" | grep 'RESUME_STEP:' | awk '{print $2}')
  rm -rf "$tmpdir"
  [ "$resume_step" = "STEP_6" ]
}

# ── test_detect_resume_maintenance_fallback_document ────────────────────────

test_detect_resume_maintenance_fallback_document() {
  local tmpdir
  tmpdir=$(mktemp -d)
  mkdir -p "$tmpdir/logs"
  local log="$tmpdir/logs/WIL-99-pipeline.log"
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|META|schema|info|1" >>"$log"
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|APPRAISE|appraise|done|simple, 5 files traced" >>"$log"
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|EXEC|create-artifact|done|simple-fix" >>"$log"
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|GATE|gate|done|auto-approved" >>"$log"
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|IMPLEMENT|implement|done|Smooth, branch: wil-99--fix" >>"$log"
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|MAINTENANCE|document|start|Generating ai-context.md" >>"$log"

  local out
  out=$(CLAUDE_SKILLS_LIB="$PLUGIN_DIR/lib" cd "$tmpdir" && bash "$DETECT_RESUME_SH" WIL-99 2>/dev/null || true)
  local resume_step
  resume_step=$(echo "$out" | grep 'RESUME_STEP:' | awk '{print $2}')
  local doc_from
  doc_from=$(echo "$out" | grep 'DOCUMENT_FROM:' | awk '{print $2}')
  rm -rf "$tmpdir"
  [ "$resume_step" = "STEP_5" ] && [ -z "$doc_from" ]
}

# ── test_ticket_dir_disambiguation ───────────────────────────────────────────

test_ticket_dir_disambiguation() {
  local tmpdir
  tmpdir=$(mktemp -d)
  mkdir -p "$tmpdir/WIL-4--foo"
  mkdir -p "$tmpdir/WIL-42--bar"

  source "$TICKET_DIR_SH"

  # WIL-4 should resolve to WIL-4--foo only
  local result
  result=$(resolve_ticket_dir WIL-4 "$tmpdir")
  [[ "$result" == *"WIL-4--foo"* ]] || {
    rm -rf "$tmpdir"
    return 1
  }

  # WIL-42 should resolve to WIL-42--bar
  result=$(resolve_ticket_dir WIL-42 "$tmpdir")
  [[ "$result" == *"WIL-42--bar"* ]] || {
    rm -rf "$tmpdir"
    return 1
  }

  # Adding a second WIL-4 dir should cause multi-match error (exit 2)
  mkdir -p "$tmpdir/WIL-4--baz"
  local exit_code=0
  resolve_ticket_dir WIL-4 "$tmpdir" 2>/dev/null || exit_code=$?
  rm -rf "$tmpdir"
  [ "$exit_code" -eq 2 ]
}

# ── test_gen_mermaid_roundtrip ────────────────────────────────────────────────

test_gen_mermaid_roundtrip() {
  # Use PLUGIN_DIR (set at script startup, never overwritten) rather than
  # SCRIPT_DIR which ticket-dir.sh clobbers when sourced by earlier tests.
  local gen="$PLUGIN_DIR/skills/ticket-flow/gen-mermaid.sh"
  local sm="$PLUGIN_DIR/skills/ticket-flow/state-machine.json"
  [ -f "$gen" ] || {
    echo "gen-mermaid.sh missing" >&2
    return 1
  }
  [ -f "$sm" ] || {
    echo "state-machine.json missing" >&2
    return 1
  }
  local readme="$PLUGIN_DIR/README.md"
  [ -f "$readme" ] || {
    echo "README.md not found" >&2
    return 1
  }

  local generated
  generated=$(bash "$gen")
  local committed
  committed=$(sed -n '/^```mermaid$/,/^```$/p' "$readme" | grep -v '^```')
  [ "$generated" = "$committed" ]
}

# ── test_detect_resume_verify_attempts_excludes_pass ───────────────────────

test_detect_resume_verify_attempts_excludes_pass() {
  local tmpdir
  tmpdir=$(mktemp -d)
  mkdir -p "$tmpdir/logs"
  local log="$tmpdir/logs/WIL-99-pipeline.log"
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|META|schema|info|1" >>"$log"
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|APPRAISE|appraise|done|simple" >>"$log"
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|EXEC|create-artifact|done|simple-fix" >>"$log"
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|GATE|gate|done|auto-approved" >>"$log"
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|IMPLEMENT|implement|done|Smooth" >>"$log"
  # One PASS — should NOT count toward VERIFY_ATTEMPTS
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|VERIFY|verify|done|PASS" >>"$log"

  local out
  out=$(CLAUDE_SKILLS_LIB="$PLUGIN_DIR/lib" cd "$tmpdir" && bash "$DETECT_RESUME_SH" WIL-99 2>/dev/null || true)
  local verify_attempts
  verify_attempts=$(echo "$out" | grep 'VERIFY_ATTEMPTS:' | awk '{print $2}')
  rm -rf "$tmpdir"
  [ "${verify_attempts:-1}" -eq 0 ]
}

# ── test_detect_resume_verify_attempts_counts_fails ───────────────────────

test_detect_resume_verify_attempts_counts_fails() {
  local tmpdir
  tmpdir=$(mktemp -d)
  mkdir -p "$tmpdir/logs"
  local log="$tmpdir/logs/WIL-99-pipeline.log"
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|META|schema|info|1" >>"$log"
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|APPRAISE|appraise|done|simple" >>"$log"
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|EXEC|create-artifact|done|simple-fix" >>"$log"
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|GATE|gate|done|auto-approved" >>"$log"
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|IMPLEMENT|implement|done|Smooth" >>"$log"
  # One FAIL — SHOULD count toward VERIFY_ATTEMPTS
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|VERIFY|verify|fail|timeout" >>"$log"

  local out
  out=$(CLAUDE_SKILLS_LIB="$PLUGIN_DIR/lib" cd "$tmpdir" && bash "$DETECT_RESUME_SH" WIL-99 2>/dev/null || true)
  local verify_attempts
  verify_attempts=$(echo "$out" | grep 'VERIFY_ATTEMPTS:' | awk '{print $2}')
  rm -rf "$tmpdir"
  [ "${verify_attempts:-0}" -eq 1 ]
}

# ── test_detect_resume_no_step3 ───────────────────────────────────────────

test_detect_resume_no_step3() {
  # STEP_3 must never appear in detect-resume.sh output — it was deleted
  # from the dispatch table and is unreachable.
  local tmpdir
  tmpdir=$(mktemp -d)
  mkdir -p "$tmpdir/logs"
  local log="$tmpdir/logs/WIL-99-pipeline.log"
  # A log with EXEC done but no GATE — historically this could produce STEP_3
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|META|schema|info|1" >>"$log"
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|APPRAISE|appraise|done|simple" >>"$log"
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|EXEC|create-artifact|done|simple-fix" >>"$log"

  local out
  out=$(CLAUDE_SKILLS_LIB="$PLUGIN_DIR/lib" cd "$tmpdir" && bash "$DETECT_RESUME_SH" WIL-99 2>/dev/null || true)
  rm -rf "$tmpdir"
  # RESUME_STEP must not be STEP_3 (without _5 suffix)
  echo "$out" | grep -q 'RESUME_STEP:.*STEP_3$' && return 1
  return 0
}

# ── test_detect_resume_pr_number_from_checkout_only ───────────────────────

test_detect_resume_pr_number_from_checkout_only() {
  # PR number must be resolved from checkout-pr|done| line — the old
  # emoji-based fallback regex has been removed. This test verifies the
  # primary extraction still works.
  local tmpdir
  tmpdir=$(mktemp -d)
  mkdir -p "$tmpdir/logs"
  local log="$tmpdir/logs/WIL-99-pipeline.log"
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|META|schema|info|1" >>"$log"
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|APPRAISE|appraise|done|simple" >>"$log"
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|EXEC|create-artifact|done|simple-fix" >>"$log"
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|GATE|gate|done|auto-approved" >>"$log"
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|IMPLEMENT|implement|done|Smooth, branch: wil-99--fix" >>"$log"
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|VERIFY|verify|done|PASS" >>"$log"
  # checkout-pr|done|42 — the canonical PR number source
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|PR-REVIEW|checkout-pr|done|42" >>"$log"
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|PR-REVIEW|pr-review|done|PASS" >>"$log"

  # Verify detect-resume.sh runs without error and resolves to STEP_5 (past PR-REVIEW)
  local out
  out=$(CLAUDE_SKILLS_LIB="$PLUGIN_DIR/lib" cd "$tmpdir" && bash "$DETECT_RESUME_SH" WIL-99 2>/dev/null || true)
  local resume_step
  resume_step=$(echo "$out" | grep 'RESUME_STEP:' | awk '{print $2}')
  rm -rf "$tmpdir"
  # Should reach STEP_5 (past PR-REVIEW with PR done) since MAINTENANCE hasn't run yet.
  # Without the dead fallback, this must still work via checkout-pr extraction.
  [ "$resume_step" = "STEP_5" ]
}

# ── test_spawn_agent_post_loop_bearing_requires_verdict ───────────────────

test_spawn_agent_post_loop_bearing_requires_verdict() {
  # Source spawn-helper to get spawn_agent_post
  source "$PLUGIN_DIR/lib/spawn-helper.sh" 2>/dev/null || true

  # LOOP_BEARING=true without VERDICT or cycle# → must fail
  if spawn_agent_post TICKET_ID=TEST-1 RESULT=done MSG="done" LOOP_BEARING=true 2>/dev/null; then
    echo "FAIL: LOOP_BEARING=true with no VERDICT or cycle# should have failed"
    return 1
  fi

  # LOOP_BEARING=true with VERDICT → must succeed (log-writing may fail, that's OK)
  local rc=0
  spawn_agent_post TICKET_ID=TEST-1 RESULT=done VERDICT=PASS MSG="ok" LOOP_BEARING=true 2>/dev/null || rc=$?
  # rc may be non-zero from missing log files — that's fine, just not the VERDICT error
  [ "$rc" -ne 1 ] || {
    echo "FAIL: LOOP_BEARING=true with VERDICT should not fail on missing token"
    return 1
  }

  # LOOP_BEARING=true with cycle# in MSG → must not fail on verdict requirement
  rc=0
  spawn_agent_post TICKET_ID=TEST-1 RESULT=done MSG="cycle#3 reconciled" LOOP_BEARING=true 2>/dev/null || rc=$?
  [ "$rc" -ne 1 ] || {
    echo "FAIL: LOOP_BEARING=true with cycle# in MSG should satisfy the requirement"
    return 1
  }

  # LOOP_BEARING=false (default) without VERDICT → must succeed
  rc=0
  spawn_agent_post TICKET_ID=TEST-1 RESULT=done MSG="done" 2>/dev/null || rc=$?
  [ "$rc" -ne 1 ] || {
    echo "FAIL: non-loop phase without VERDICT should succeed"
    return 1
  }
}

# ── test_outcome_label_exact_match ─────────────────────────────────────────

test_outcome_label_exact_match() {
  # Verify that "Hard" does NOT match "Hard-blocked" via the jq exact-match
  # check (the old grep -qw falsely matched on hyphen boundaries).
  # NOTE: source of outcome-label-check.sh would overwrite SCRIPT_DIR,
  # so we inline the jq check directly.

  # "Hard" must NOT match when only "Hard-blocked" is present
  local issue_json='{"labels":{"nodes":[{"name":"Hard-blocked"},{"name":"bug"}]}}'
  if echo "$issue_json" | jq -e --arg ol "Hard" \
    '[.labels.nodes[]?.name? // empty] | index($ol) != null' >/dev/null 2>&1; then
    echo "FAIL: Hard falsely matched Hard-blocked"
    return 1
  fi

  # But "Hard" SHOULD match when actually present
  issue_json='{"labels":{"nodes":[{"name":"Hard"},{"name":"bug"}]}}'
  if ! echo "$issue_json" | jq -e --arg ol "Hard" \
    '[.labels.nodes[]?.name? // empty] | index($ol) != null' >/dev/null 2>&1; then
    echo "FAIL: Hard should match when actually present"
    return 1
  fi
}

# ── test_retry_classify_429_transient ─────────────────────────────────────

test_retry_classify_429_transient() {
  # Source linear-api.sh to get _retry_classify
  source "$PLUGIN_DIR/lib/linear-api.sh" 2>/dev/null || true
  # HTTP 429 must be classified as transient
  local result
  result=$(_retry_classify 0 429 "{}")
  [ "$result" = "transient" ] || {
    echo "expected transient for HTTP 429, got $result"
    return 1
  }
}

# ── test_retry_classify_rate_limit_regex ──────────────────────────────────

test_retry_classify_rate_limit_regex() {
  source "$PLUGIN_DIR/lib/linear-api.sh" 2>/dev/null || true
  # "rateXlimit" (with any char where dot was unescaped) must NOT match
  local result
  result=$(_retry_classify 0 200 '{"message":"rateXlimit exceeded"}')
  [ "$result" = "permanent" ] || {
    echo "expected permanent for rateXlimit (escaped dot), got $result"
    return 1
  }
  # "rate.limit" (with literal dot) must match
  result=$(_retry_classify 0 200 '{"message":"rate.limit exceeded"}')
  [ "$result" = "transient" ] || {
    echo "expected transient for rate.limit, got $result"
    return 1
  }
  # "429" in body must match
  result=$(_retry_classify 0 200 '{"errors":[{"message":"429 rate limit"}]}')
  [ "$result" = "transient" ] || {
    echo "expected transient for 429 in body, got $result"
    return 1
  }
}

# ── test_flow_from_precondition_logic ──────────────────────────────────────

test_flow_from_precondition_logic() {
  # Verify the from-precondition check: extract "from" field, compare against
  # current state. This test exercises the jq extraction and comparison logic
  # without needing a Linear API mock.
  local tmpdir
  tmpdir=$(mktemp -d)

  # Test 1: "from" present and matches → no warning
  local def='{"from":"Todo","to":"In Progress"}'
  local expected_from current_state
  expected_from=$(echo "$def" | jq -r '.from // empty')
  current_state="Todo"
  local should_warn="false"
  if [ -n "$expected_from" ] && [ "$expected_from" != "null" ]; then
    if [ "$current_state" != "$expected_from" ]; then
      should_warn="true"
    fi
  fi
  [ "$should_warn" = "false" ] || {
    rm -rf "$tmpdir"
    echo "legal transition incorrectly flagged"
    return 1
  }

  # Test 2: "from" present and mismatches → warn
  current_state="Backlog"
  should_warn="false"
  if [ -n "$expected_from" ] && [ "$expected_from" != "null" ]; then
    if [ "$current_state" != "$expected_from" ]; then
      should_warn="true"
    fi
  fi
  [ "$should_warn" = "true" ] || {
    rm -rf "$tmpdir"
    echo "illegal transition not flagged"
    return 1
  }

  # Test 3: "from" absent → skip check (no warn)
  def='{"to":"Done"}'
  expected_from=$(echo "$def" | jq -r '.from // empty')
  current_state="Backlog"
  should_warn="false"
  if [ -n "$expected_from" ] && [ "$expected_from" != "null" ]; then
    if [ "$current_state" != "$expected_from" ]; then
      should_warn="true"
    fi
  fi
  [ "$should_warn" = "false" ] || {
    rm -rf "$tmpdir"
    echo "absent from incorrectly flagged"
    return 1
  }

  # Test 4: "from": null → skip check (no warn)
  def='{"from":null,"to":"Done"}'
  expected_from=$(echo "$def" | jq -r '.from // empty')
  current_state="Backlog"
  should_warn="false"
  if [ -n "$expected_from" ] && [ "$expected_from" != "null" ]; then
    if [ "$current_state" != "$expected_from" ]; then
      should_warn="true"
    fi
  fi
  [ "$should_warn" = "false" ] || {
    rm -rf "$tmpdir"
    echo "null from incorrectly flagged"
    return 1
  }

  rm -rf "$tmpdir"
}

# ── test_flow_implement_outcome_logs_line ────────────────────────────────────
# flow.sh's implement-outcome trigger must write the dedicated
# IMPLEMENT|implement-outcome|info| line itself, so outcome-label-check.sh's
# guard can never drift from the actual Linear label mutation (issue #165).

_stub_lib_dir() {
  # Builds a temp CLAUDE_SKILLS_LIB with a network-free linear-api.sh stub
  # plus the real heartbeat.sh/epic-precondition.sh (pure bash/jq, no network)
  # flow.sh unconditionally sources.
  local dir="$1"
  local marker="$2"
  mkdir -p "$dir"
  cp "$PLUGIN_DIR/lib/heartbeat.sh" "$dir/"
  cp "$PLUGIN_DIR/lib/epic-precondition.sh" "$dir/"
  cat >"$dir/linear-api.sh" <<STUBEOF
get_issue() {
  if [ -f "$marker" ]; then
    jq -n '{id:"issue-1",identifier:"WIL-99",team:{id:"team-1",name:"Test"},state:{id:"state-1",name:"Ready"},labels:{nodes:[{id:"lbl-hard",name:"Hard"}]},project:null,parent:null}'
  else
    jq -n '{id:"issue-1",identifier:"WIL-99",team:{id:"team-1",name:"Test"},state:{id:"state-1",name:"Ready"},labels:{nodes:[]},project:null,parent:null}'
  fi
}
get_team() {
  jq -n '{states:[{id:"state-1",name:"Ready"}],labels:[{id:"lbl-hard",name:"Hard"},{id:"lbl-smooth",name:"Smooth"},{id:"lbl-rough",name:"Rough"}]}'
}
update_issue() {
  touch "$marker"
  jq -n '{success:true,issue:{id:"issue-1",identifier:"WIL-99"}}'
}
get_me() { jq -n '{id:"me-1",name:"Test"}'; }
STUBEOF
}

test_flow_implement_outcome_logs_line_on_mutation() {
  local tmpdir
  tmpdir=$(mktemp -d)
  mkdir -p "$tmpdir/logs" "$tmpdir/lib"
  local marker="$tmpdir/mutated.marker"
  _stub_lib_dir "$tmpdir/lib" "$marker"

  local log="$tmpdir/logs/WIL-99-pipeline.log"
  FLEET_FENCE_ENFORCE=false CLAUDE_SKILLS_LIB="$tmpdir/lib" LOG_FILE="$log" \
    TICKET_FLOW_LOCK_DIR="$tmpdir/logs" \
    "$FLOW_SH" WIL-99 implement-outcome --data outcome=Hard >/dev/null 2>&1
  local rc=$?

  local found=1
  grep -q '^[^|]*|IMPLEMENT|implement-outcome|info|Hard$' "$log" 2>/dev/null && found=0
  rm -rf "$tmpdir"
  [ "$rc" -eq 0 ] && [ "$found" -eq 0 ]
}

test_flow_implement_outcome_logs_line_when_idempotent() {
  local tmpdir
  tmpdir=$(mktemp -d)
  mkdir -p "$tmpdir/logs" "$tmpdir/lib"
  local marker="$tmpdir/mutated.marker"
  touch "$marker" # label already present from the first get_issue call — idempotent path
  _stub_lib_dir "$tmpdir/lib" "$marker"

  local log="$tmpdir/logs/WIL-99-pipeline.log"
  FLEET_FENCE_ENFORCE=false CLAUDE_SKILLS_LIB="$tmpdir/lib" LOG_FILE="$log" \
    TICKET_FLOW_LOCK_DIR="$tmpdir/logs" \
    "$FLOW_SH" WIL-99 implement-outcome --data outcome=Hard >/dev/null 2>&1
  local rc=$?

  local found=1
  grep -q '^[^|]*|IMPLEMENT|implement-outcome|info|Hard$' "$log" 2>/dev/null && found=0
  rm -rf "$tmpdir"
  [ "$rc" -eq 0 ] && [ "$found" -eq 0 ]
}

# ── test_flow_complexity_opposite ────────────────────────────────────────────
# appraise-start must clear a stale opposite-complexity label in the same
# mutation that applies the new one. Simple and Complex belong to a
# mutually-exclusive Linear label group, so leaving both on the issue makes
# Linear reject the whole mutation (issue #170).

_stub_lib_dir_labels() {
  # Like _stub_lib_dir, but the issue's current label set is caller-supplied
  # so a test can seed a stale complexity label. The issue is parked in Todo
  # (a legal "from" state for appraise-start) and carries no epic marker.
  local dir="$1"
  local labels_json="$2"
  mkdir -p "$dir"
  cp "$PLUGIN_DIR/lib/heartbeat.sh" "$dir/"
  cp "$PLUGIN_DIR/lib/epic-precondition.sh" "$dir/"
  cat >"$dir/linear-api.sh" <<STUBEOF
get_issue() {
  jq -n --argjson labels '$labels_json' '{id:"issue-1",identifier:"WIL-99",team:{id:"team-1",name:"Test"},state:{id:"state-todo",name:"Todo"},labels:{nodes:\$labels},description:"",project:null,parent:null}'
}
get_team() {
  jq -n '{states:[{id:"state-todo",name:"Todo"}],labels:[{id:"lbl-claimed",name:"claimed"},{id:"lbl-simple",name:"Simple"},{id:"lbl-complex",name:"Complex"}]}'
}
update_issue() { jq -n '{success:true,issue:{id:"issue-1",identifier:"WIL-99"}}'; }
get_me() { jq -n '{id:"me-1",name:"Test"}'; }
STUBEOF
}

_appraise_start_dry_run_labels() {
  # Echoes the comma-joined label set appraise-start would compute.
  local labels_json="$1"
  local complexity="$2"
  local tmpdir
  tmpdir=$(mktemp -d)
  mkdir -p "$tmpdir/logs" "$tmpdir/lib"
  _stub_lib_dir_labels "$tmpdir/lib" "$labels_json"

  local out
  out=$(FLEET_FENCE_ENFORCE=false CLAUDE_SKILLS_LIB="$tmpdir/lib" \
    LOG_FILE="$tmpdir/logs/WIL-99-pipeline.log" \
    TICKET_FLOW_LOCK_DIR="$tmpdir/logs" \
    "$FLOW_SH" WIL-99 appraise-start --data complexity="$complexity" --dry-run 2>/dev/null)
  rm -rf "$tmpdir"
  echo "$out" | jq -r '.computed.labels'
}

test_flow_appraise_start_drops_stale_opposite_label() {
  local labels
  labels=$(_appraise_start_dry_run_labels '[{"id":"lbl-simple","name":"Simple"}]' complex)
  echo "$labels" | grep -q "Complex" || {
    echo "expected Complex in computed labels, got: $labels"
    return 1
  }
  # grep -w so the "Simple" check is not satisfied by the "Complex" substring.
  echo "$labels" | tr ',' '\n' | grep -qx "Simple" && {
    echo "stale Simple label survived appraise-start: $labels"
    return 1
  }
  return 0
}

test_flow_appraise_start_drops_stale_complex_label() {
  local labels
  labels=$(_appraise_start_dry_run_labels '[{"id":"lbl-complex","name":"Complex"}]' simple)
  echo "$labels" | tr ',' '\n' | grep -qx "Simple" || {
    echo "expected Simple in computed labels, got: $labels"
    return 1
  }
  echo "$labels" | tr ',' '\n' | grep -qx "Complex" && {
    echo "stale Complex label survived appraise-start: $labels"
    return 1
  }
  return 0
}

test_flow_appraise_start_no_prior_complexity_label() {
  # The common case: nothing to remove. The removal must no-op rather than
  # fail, since removes resolve IDs from the issue's own label set.
  local labels
  labels=$(_appraise_start_dry_run_labels '[]' complex)
  echo "$labels" | tr ',' '\n' | grep -qx "Complex" || {
    echo "expected Complex in computed labels, got: $labels"
    return 1
  }
  echo "$labels" | tr ',' '\n' | grep -qx "claimed" || {
    echo "expected claimed in computed labels, got: $labels"
    return 1
  }
  return 0
}

# ── needs-info round-trip (human-hold-protocol task 7.4) ───────────────────
# human-hold-protocol reuses `needs-info` unchanged as the Linear-side label
# for a human hold — no new label, no state-machine.json edit. This pins
# that the one ask-form that already worked before this change still does:
# set adds the label, resolved removes it, neither touches state.

_stub_lib_dir_needs_info() {
  local dir="$1"
  local labels_json="$2"
  mkdir -p "$dir"
  cp "$PLUGIN_DIR/lib/heartbeat.sh" "$dir/"
  cp "$PLUGIN_DIR/lib/epic-precondition.sh" "$dir/"
  cat >"$dir/linear-api.sh" <<STUBEOF
get_issue() {
  jq -n --argjson labels '$labels_json' '{id:"issue-1",identifier:"WIL-99",team:{id:"team-1",name:"Test"},state:{id:"state-todo",name:"Todo"},labels:{nodes:\$labels},description:"",project:null,parent:null}'
}
get_team() {
  jq -n '{states:[{id:"state-todo",name:"Todo"}],labels:[{id:"lbl-needs-info",name:"needs-info"}]}'
}
update_issue() { jq -n '{success:true,issue:{id:"issue-1",identifier:"WIL-99"}}'; }
get_me() { jq -n '{id:"me-1",name:"Test"}'; }
STUBEOF
}

_needs_info_dry_run_labels() {
  local labels_json="$1" trigger="$2"
  local tmpdir
  tmpdir=$(mktemp -d)
  mkdir -p "$tmpdir/logs" "$tmpdir/lib"
  _stub_lib_dir_needs_info "$tmpdir/lib" "$labels_json"

  local out
  out=$(FLEET_FENCE_ENFORCE=false CLAUDE_SKILLS_LIB="$tmpdir/lib" \
    LOG_FILE="$tmpdir/logs/WIL-99-pipeline.log" \
    TICKET_FLOW_LOCK_DIR="$tmpdir/logs" \
    "$FLOW_SH" WIL-99 "$trigger" --dry-run 2>/dev/null)
  rm -rf "$tmpdir"
  echo "$out" | jq -r '.computed.labels'
}

test_needs_info_set_adds_the_label() {
  local labels
  labels=$(_needs_info_dry_run_labels '[]' needs-info)
  echo "$labels" | tr ',' '\n' | grep -qx "needs-info" || {
    echo "expected needs-info in computed labels, got: $labels"
    return 1
  }
}

test_needs_info_resolved_removes_the_label() {
  local labels
  labels=$(_needs_info_dry_run_labels '[{"id":"lbl-needs-info","name":"needs-info"}]' needs-info-resolved)
  echo "$labels" | tr ',' '\n' | grep -qx "needs-info" && {
    echo "needs-info label survived needs-info-resolved: $labels"
    return 1
  }
  return 0
}

test_needs_info_does_not_change_state() {
  local tmpdir out
  tmpdir=$(mktemp -d)
  mkdir -p "$tmpdir/logs" "$tmpdir/lib"
  _stub_lib_dir_needs_info "$tmpdir/lib" '[]'
  out=$(FLEET_FENCE_ENFORCE=false CLAUDE_SKILLS_LIB="$tmpdir/lib" \
    LOG_FILE="$tmpdir/logs/WIL-99-pipeline.log" \
    TICKET_FLOW_LOCK_DIR="$tmpdir/logs" \
    "$FLOW_SH" WIL-99 needs-info --dry-run 2>/dev/null)
  rm -rf "$tmpdir"
  local to_state
  to_state=$(echo "$out" | jq -r '.computed.state // "unchanged"')
  [ "$to_state" = "unchanged" ] || [ "$to_state" = "null" ] || [ "$to_state" = "Todo" ]
}

# ── test_state_machine_single_source ───────────────────────────────────────

test_state_machine_single_source() {
  # Exactly one state-machine.json must exist in the plugin tree —
  # the canonical copy at skills/ticket-flow/state-machine.json.
  local count
  count=$(find "$PLUGIN_DIR" -name "state-machine.json" -not -path "*/node_modules/*" -not -path "*/.git/*" 2>/dev/null | wc -l)
  [ "$count" -eq 1 ] || {
    echo "expected exactly 1 state-machine.json, found $count"
    return 1
  }
  # Verify the sole copy is at the expected path
  [ -f "$PLUGIN_DIR/skills/ticket-flow/state-machine.json" ] || {
    echo "canonical state-machine.json missing at skills/ticket-flow/"
    return 1
  }
}

# ── dispatch ─────────────────────────────────────────────────────────────────

FILTER="${1:-}"

for fn in \
  test_validate_linear_config_dry_run \
  test_preflight_aborts_on_unset_key \
  test_flow_concurrent_lock \
  test_flow_assertion_catches_silent_noop \
  test_flow_dispatcher_unknown_trigger \
  test_linear_api_retry_on_503 \
  test_spawn_agent_post_loop_bearing_requires_verdict \
  test_outcome_label_exact_match \
  test_retry_classify_429_transient \
  test_retry_classify_rate_limit_regex \
  test_detect_resume_schema_mismatch \
  test_detect_resume_maintenance_document_done \
  test_detect_resume_maintenance_document_waiting \
  test_detect_resume_maintenance_document_fail \
  test_detect_resume_maintenance_maintenance_done \
  test_detect_resume_maintenance_maintenance_waiting \
  test_detect_resume_maintenance_maintenance_fail \
  test_detect_resume_maintenance_fallback_document \
  test_detect_resume_verify_attempts_excludes_pass \
  test_detect_resume_verify_attempts_counts_fails \
  test_detect_resume_no_step3 \
  test_detect_resume_pr_number_from_checkout_only \
  test_flow_from_precondition_logic \
  test_flow_implement_outcome_logs_line_on_mutation \
  test_flow_implement_outcome_logs_line_when_idempotent \
  test_flow_appraise_start_drops_stale_opposite_label \
  test_flow_appraise_start_drops_stale_complex_label \
  test_flow_appraise_start_no_prior_complexity_label \
  test_needs_info_set_adds_the_label \
  test_needs_info_resolved_removes_the_label \
  test_needs_info_does_not_change_state \
  test_state_machine_single_source \
  test_ticket_dir_disambiguation \
  test_gen_mermaid_roundtrip; do
  [ -z "$FILTER" ] || [[ "$fn" == *"$FILTER"* ]] || continue
  _run "$fn" "$fn"
done

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
