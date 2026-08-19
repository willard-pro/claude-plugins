#!/usr/bin/env bash
# test-fleet-reconcile.sh — unit tests for fleet-reconcile.sh
# (fleetd startup orphan reconciliation).
# Usage: bash test-fleet-reconcile.sh [test_name_filter]
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

# ── CI-safe declare guards ─────────────────────────────────────────────────────
if ! declare -f _plog >/dev/null 2>&1; then
  _plog() {
    # file phase step status msg — deterministic append
    local file="$1" phase="$2" step="$3" status="$4" msg="$5"
    mkdir -p "$(dirname "$file")"
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|${phase}|${step}|${status}|${msg}" >>"$file"
  }
fi
if ! declare -f hb_decision >/dev/null 2>&1; then
  hb_decision() { :; }
fi

source "$LIB_DIR/fleet-reconcile.sh"

# ── Helpers ─────────────────────────────────────────────────────────────────────

_setup_workspace() {
  mktemp -d
}

# Write one pipeline log line: _plog_line <log_file> <phase> <step> <status> <msg>
_plog_line() {
  local file="$1" phase="$2" step="$3" status="$4" msg="$5"
  mkdir -p "$(dirname "$file")"
  echo "2026-08-17T10:00:00Z|${phase}|${step}|${status}|${msg}" >>"$file"
}

# Derive the queue file the same way the dispatch/reconcile paths do.
_reconcile_queue_file() {
  local ws="$1"
  FLEET_INSTANCE_ID="${FLEET_INSTANCE_ID:-test-reconcile}" _fleet_queue_file "$ws"
}

# Env every reconciliation test runs under: auto-restart on (fleet_can_restart
# gate), mutex dir pointed at a nonexistent path (no false defer).
_reconcile_env() {
  local ws="$1"
  export FLEET_AUTO_RESTART=true
  export TICKET_FLOW_LOCK_DIR="$ws/no-flow-locks"
  export FLEET_PIPELINE_LOG_DIR="$ws"
}

# ── Classification tests (fleet_ticket_terminal_state) ─────────────────────────

test_classify_done() {
  local ws
  ws=$(_setup_workspace)
  local log_file="${ws}/CRE-9-pipeline.log"
  _plog_line "$log_file" "APPRAISE" "appraise" "start" "investigating"
  _plog_line "$log_file" "META" "outcome" "info" "completed: STEP_6"

  local state
  state=$(fleet_ticket_terminal_state "CRE-9" "$log_file")
  [ "$state" = "done" ] || {
    echo "expected done, got $state" >&2
    return 1
  }
}

test_classify_gate_stop() {
  local ws
  ws=$(_setup_workspace)
  local log_file="${ws}/CRE-8-pipeline.log"
  _plog_line "$log_file" "GATE" "gate" "start" "checking"
  _plog_line "$log_file" "META" "gate-stop" "fail" "EXEC_NO_ARTIFACT"

  local state
  state=$(fleet_ticket_terminal_state "CRE-8" "$log_file")
  [ "$state" = "done" ] || {
    echo "expected done (gate-stop is terminal), got $state" >&2
    return 1
  }
}

test_classify_gate_held() {
  local ws
  ws=$(_setup_workspace)
  local log_file="${ws}/CRE-11-pipeline.log"
  _plog_line "$log_file" "GATE" "gate" "start" "checking"
  _plog_line "$log_file" "META" "gate-held" "info" "held"
  _plog_line "$log_file" "META" "outcome" "info" "held: gate"

  local state
  state=$(fleet_ticket_terminal_state "CRE-11" "$log_file")
  [ "$state" = "gate-held" ] || {
    echo "expected gate-held, got $state" >&2
    return 1
  }
}

test_classify_gate_held_crash_before_finalize() {
  local ws
  ws=$(_setup_workspace)
  local log_file="${ws}/CRE-10-pipeline.log"
  _plog_line "$log_file" "GATE" "gate" "start" "checking"
  # Crash between the held marker and the finalize call — last line is the
  # held marker itself, no outcome yet.
  _plog_line "$log_file" "META" "gate-held" "info" "held"

  local state
  state=$(fleet_ticket_terminal_state "CRE-10" "$log_file")
  [ "$state" = "gate-held" ] || {
    echo "expected gate-held, got $state" >&2
    return 1
  }
}

test_classify_incomplete() {
  local ws
  ws=$(_setup_workspace)
  local log_file="${ws}/CRE-14-pipeline.log"
  _plog_line "$log_file" "APPRAISE" "appraise" "start" "investigating"
  _plog_line "$log_file" "IMPLEMENT" "implement" "start" "mid-flight"

  local state
  state=$(fleet_ticket_terminal_state "CRE-14" "$log_file")
  [ "$state" = "incomplete" ] || {
    echo "expected incomplete, got $state" >&2
    return 1
  }
}

test_classify_dead_letter_terminal() {
  local ws
  ws=$(_setup_workspace)
  local log_file="${ws}/CRE-18-pipeline.log"
  _plog_line "$log_file" "APPRAISE" "appraise" "start" "investigating"
  _plog_line "$log_file" "META" "dead-letter" "warn" "reason=orphaned-after-max-restarts"

  local state
  state=$(fleet_ticket_terminal_state "CRE-18" "$log_file")
  [ "$state" = "done" ] || {
    echo "expected done (dead-letter is terminal), got $state" >&2
    return 1
  }
}

test_classify_missing_log() {
  local ws
  ws=$(_setup_workspace)
  local state
  state=$(fleet_ticket_terminal_state "CRE-0" "${ws}/CRE-0-pipeline.log")
  [ "$state" = "incomplete" ] || {
    echo "expected incomplete for missing log, got $state" >&2
    return 1
  }
}

# ── Reconciliation tests (fleet_reconcile_orphans) ─────────────────────────────

test_orphan_reenqueued_exactly_once() {
  local ws
  ws=$(_setup_workspace)
  _reconcile_env "$ws"
  local queue_file
  queue_file=$(_reconcile_queue_file "$ws")
  rm -f "$queue_file" "${queue_file%.jsonl}-dead-letter.jsonl"

  _plog_line "${ws}/CRE-14-pipeline.log" "APPRAISE" "appraise" "start" "investigating"

  fleet_reconcile_orphans "$ws" "$queue_file" "" >/dev/null

  [ -f "$queue_file" ] || {
    echo "queue file not created" >&2
    return 1
  }
  local count
  count=$(grep -c '"tid":"CRE-14"' "$queue_file" 2>/dev/null || true)
  [ "$count" = "1" ] || {
    echo "expected exactly one queue entry for CRE-14, got ${count}" >&2
    return 1
  }
  # Entry schema: identical to a normal initial-dispatch entry — no branch/
  # epic fields.
  local entry
  entry=$(grep '"tid":"CRE-14"' "$queue_file" | head -1)
  echo "$entry" | jq -e 'has("branch") or has("epic") or has("base")' >/dev/null 2>&1 && {
    echo "re-enqueue entry carries branch/epic fields: $entry" >&2
    return 1
  }
  echo "$entry" | jq -e '.dispatch_type == "initial" and (.generation >= 1) and (.restarts == 0)' >/dev/null 2>&1 || {
    echo "re-enqueue entry schema mismatch: $entry" >&2
    return 1
  }
  # Restart marker written to the ticket's own log.
  grep -q '|META|fleet-restart|' "${ws}/CRE-14-pipeline.log" || {
    echo "META|fleet-restart| marker missing from pipeline log" >&2
    return 1
  }

  # Run again — already queued now, must not double-enqueue.
  fleet_reconcile_orphans "$ws" "$queue_file" "" >/dev/null
  count=$(grep -c '"tid":"CRE-14"' "$queue_file" 2>/dev/null || true)
  [ "$count" = "1" ] || {
    echo "expected still one queue entry after second pass, got ${count}" >&2
    return 1
  }
  return 0
}

test_done_and_gate_held_left_alone() {
  local ws
  ws=$(_setup_workspace)
  _reconcile_env "$ws"
  local queue_file
  queue_file=$(_reconcile_queue_file "$ws")
  rm -f "$queue_file" "${queue_file%.jsonl}-dead-letter.jsonl"

  _plog_line "${ws}/CRE-9-pipeline.log" "META" "outcome" "info" "completed: STEP_6"
  _plog_line "${ws}/CRE-11-pipeline.log" "META" "gate-held" "info" "held"
  _plog_line "${ws}/CRE-11-pipeline.log" "META" "outcome" "info" "held: gate"

  fleet_reconcile_orphans "$ws" "$queue_file" "" >/dev/null

  if [ -f "$queue_file" ]; then
    ! grep -q '"tid":"CRE-9"' "$queue_file" 2>/dev/null || {
      echo "completed ticket CRE-9 was re-enqueued" >&2
      return 1
    }
    ! grep -q '"tid":"CRE-11"' "$queue_file" 2>/dev/null || {
      echo "gate-held ticket CRE-11 was re-enqueued" >&2
      return 1
    }
  fi
  return 0
}

test_adopted_live_skipped() {
  local ws
  ws=$(_setup_workspace)
  _reconcile_env "$ws"
  local queue_file
  queue_file=$(_reconcile_queue_file "$ws")
  rm -f "$queue_file" "${queue_file%.jsonl}-dead-letter.jsonl"

  _plog_line "${ws}/CRE-12-pipeline.log" "IMPLEMENT" "implement" "start" "mid-flight"
  _plog_line "${ws}/CRE-15-pipeline.log" "IMPLEMENT" "implement" "start" "mid-flight"

  # CRE-12 was adopted live by scan_workers.
  fleet_reconcile_orphans "$ws" "$queue_file" "CRE-12" >/dev/null

  if [ -f "$queue_file" ]; then
    ! grep -q '"tid":"CRE-12"' "$queue_file" 2>/dev/null || {
      echo "adopted-live ticket CRE-12 was re-enqueued" >&2
      return 1
    }
  fi
  # The non-adopted orphan must still be re-enqueued.
  [ -f "$queue_file" ] && grep -q '"tid":"CRE-15"' "$queue_file" || {
    echo "non-adopted orphan CRE-15 was not re-enqueued" >&2
    return 1
  }
  return 0
}

# A live worker process (cmdline contains the /ticket-auto invocation) must
# never be re-enqueued — the fork→registry crash window and PID=0 sentinel
# registry entries used to make reconciliation spawn a second worker onto an
# already-running ticket.
test_live_worker_process_skipped() {
  local ws
  ws=$(_setup_workspace)
  _reconcile_env "$ws"
  local queue_file
  queue_file=$(_reconcile_queue_file "$ws")
  rm -f "$queue_file" "${queue_file%.jsonl}-dead-letter.jsonl"

  _plog_line "${ws}/CRE-21-pipeline.log" "IMPLEMENT" "implement" "start" "mid-flight"
  _plog_line "${ws}/CRE-22-pipeline.log" "IMPLEMENT" "implement" "start" "mid-flight"

  # Simulate a live worker for CRE-21: pgrep matches its ticket-auto
  # invocation. Function scope is global in bash, so unset at the end.
  pgrep() {
    case "$2" in
    *CRE-21*) return 0 ;;
    *) return 1 ;;
    esac
  }

  fleet_reconcile_orphans "$ws" "$queue_file" "" >/dev/null

  [ ! -f "$queue_file" ] || ! grep -q '"tid":"CRE-21"' "$queue_file" 2>/dev/null || {
    echo "live-worker ticket CRE-21 was re-enqueued" >&2
    unset -f pgrep
    return 1
  }
  # The genuinely orphaned ticket must still be re-enqueued.
  [ -f "$queue_file" ] && grep -q '"tid":"CRE-22"' "$queue_file" || {
    echo "non-live orphan CRE-22 was not re-enqueued" >&2
    unset -f pgrep
    return 1
  }
  unset -f pgrep
  return 0
}

# Default config: FLEET_AUTO_RESTART unset must still re-enqueue orphans —
# resume-on-failure is the feature; it may not require an undocumented env
# var to work at all.
test_auto_restart_default_enabled() {
  local ws
  ws=$(_setup_workspace)
  unset FLEET_AUTO_RESTART
  export TICKET_FLOW_LOCK_DIR="$ws/no-flow-locks"
  export FLEET_PIPELINE_LOG_DIR="$ws"
  local queue_file
  queue_file=$(_reconcile_queue_file "$ws")
  rm -f "$queue_file" "${queue_file%.jsonl}-dead-letter.jsonl"

  _plog_line "${ws}/CRE-19-pipeline.log" "IMPLEMENT" "implement" "start" "mid-flight"

  fleet_reconcile_orphans "$ws" "$queue_file" "" >/dev/null

  [ -f "$queue_file" ] && grep -q '"tid":"CRE-19"' "$queue_file" || {
    echo "orphan not re-enqueued under default (unset) FLEET_AUTO_RESTART" >&2
    return 1
  }
  return 0
}

# Explicit opt-out must skip re-enqueue AND say why — a silent skip is how
# a misconfigured gate goes unnoticed.
test_auto_restart_disabled_skipped_with_reason() {
  local ws
  ws=$(_setup_workspace)
  export FLEET_AUTO_RESTART=false
  export TICKET_FLOW_LOCK_DIR="$ws/no-flow-locks"
  export FLEET_PIPELINE_LOG_DIR="$ws"
  local queue_file
  queue_file=$(_reconcile_queue_file "$ws")
  rm -f "$queue_file" "${queue_file%.jsonl}-dead-letter.jsonl"

  _plog_line "${ws}/CRE-20-pipeline.log" "IMPLEMENT" "implement" "start" "mid-flight"

  local out
  out=$(fleet_reconcile_orphans "$ws" "$queue_file" "" 2>&1)

  [ ! -f "$queue_file" ] || ! grep -q '"tid":"CRE-20"' "$queue_file" 2>/dev/null || {
    echo "ticket re-enqueued despite FLEET_AUTO_RESTART=false" >&2
    return 1
  }
  echo "$out" | grep -q "auto-restart disabled" || {
    echo "expected disabled-reason in output, got: $out" >&2
    return 1
  }
  return 0
}

test_at_cap_dead_lettered_not_reenqueued() {
  local ws
  ws=$(_setup_workspace)
  _reconcile_env "$ws"
  FLEET_MAX_RESTARTS=2
  local queue_file
  queue_file=$(_reconcile_queue_file "$ws")
  rm -f "$queue_file" "${queue_file%.jsonl}-dead-letter.jsonl"

  local log_file="${ws}/CRE-16-pipeline.log"
  _plog_line "$log_file" "APPRAISE" "appraise" "start" "investigating"
  # Two prior restarts — already at the cap.
  _plog_line "$log_file" "META" "fleet-restart" "info" "restart stall-kill"
  _plog_line "$log_file" "META" "fleet-restart" "info" "restart zombie-kill"

  local out
  out=$(fleet_reconcile_orphans "$ws" "$queue_file" "" 2>&1)

  [ ! -f "$queue_file" ] || ! grep -q '"tid":"CRE-16"' "$queue_file" 2>/dev/null || {
    echo "capped ticket CRE-16 was re-enqueued" >&2
    return 1
  }
  local dead_letter_file="${queue_file%.jsonl}-dead-letter.jsonl"
  [ -f "$dead_letter_file" ] && grep -q '"tid":"CRE-16"' "$dead_letter_file" 2>/dev/null || {
    echo "capped ticket CRE-16 missing from dead-letter file" >&2
    return 1
  }
  grep -q 'orphaned-after-max-restarts' "$dead_letter_file" || {
    echo "dead-letter reason missing: $(cat "$dead_letter_file" 2>/dev/null)" >&2
    return 1
  }
  # Structured notification line naming ticket + reason.
  echo "$out" | grep -q "fleet-dead-letter|tid=CRE-16|reason=orphaned-after-max-restarts" || {
    echo "expected structured fleet-dead-letter line, got: $out" >&2
    return 1
  }
  # Terminal marker on the ticket's own pipeline log (overseer-scannable).
  grep -q '|META|dead-letter|warn|reason=orphaned-after-max-restarts' "$log_file" || {
    echo "META|dead-letter marker missing from pipeline log" >&2
    return 1
  }
  # Idempotency: a second reconciliation must not duplicate the dead-letter.
  local dl_count_before
  dl_count_before=$(grep -c '"tid":"CRE-16"' "$dead_letter_file" 2>/dev/null || true)
  fleet_reconcile_orphans "$ws" "$queue_file" "" >/dev/null
  local dl_count_after
  dl_count_after=$(grep -c '"tid":"CRE-16"' "$dead_letter_file" 2>/dev/null || true)
  [ "$dl_count_before" = "$dl_count_after" ] || {
    echo "duplicate dead-letter entries across reconciliation passes: before=${dl_count_before} after=${dl_count_after}" >&2
    return 1
  }
  return 0
}

# Generation continuity: a reconcile entry must exceed any fenced
# predecessor, or the bash monitor/consume path would spawn the resumed
# worker at generation 1 and flow.sh's fence guard would reject it as a
# superseded zombie (fleetd re-derives generations itself; the bash path
# trusts the entry).
test_reconcile_entry_continues_fenced_generation() {
  local ws
  ws=$(_setup_workspace)
  _reconcile_env "$ws"
  local queue_file
  queue_file=$(_reconcile_queue_file "$ws")
  rm -f "$queue_file" "${queue_file%.jsonl}-dead-letter.jsonl"

  # Fenced at generation 3; preserved last-generation side record says 2.
  echo "3" >"${ws}/CRE-24-fence"
  echo '{"generation":2}' >"${ws}/CRE-24-last-generation"

  _plog_line "${ws}/CRE-24-pipeline.log" "IMPLEMENT" "implement" "start" "mid-flight"
  fleet_reconcile_orphans "$ws" "$queue_file" "" >/dev/null

  local entry_gen
  entry_gen=$(grep '"tid":"CRE-24"' "$queue_file" | head -1 | jq -r '.generation // 0')
  [ "$entry_gen" -gt 3 ] || {
    echo "reconcile entry generation ${entry_gen} does not exceed fence (3)" >&2
    return 1
  }
  return 0
}

# Full crash-resume chain at bash level: worker crashes mid-IMPLEMENT →
# restart reconcile re-enqueues (marker #1) → worker consumes, crashes again
# → reconcile re-enqueues (marker #2) → worker consumes, crashes again → at
# cap → dead-lettered, never re-enqueued. The chain terminates at the cap
# instead of looping forever.
test_chained_crash_resume_reaches_cap() {
  local ws
  ws=$(_setup_workspace)
  _reconcile_env "$ws"
  FLEET_MAX_RESTARTS=2
  local queue_file
  queue_file=$(_reconcile_queue_file "$ws")
  rm -f "$queue_file" "${queue_file%.jsonl}-dead-letter.jsonl"

  local log_file="${ws}/CRE-23-pipeline.log"
  _plog_line "$log_file" "APPRAISE" "appraise" "start" "investigating"
  _plog_line "$log_file" "IMPLEMENT" "implement" "waiting" "mid-flight"

  # Restart #1: reconcile re-enqueues with exactly one restart marker.
  fleet_reconcile_orphans "$ws" "$queue_file" "" >/dev/null
  [ -f "$queue_file" ] && grep -q '"tid":"CRE-23"' "$queue_file" || {
    echo "chained: first reconcile did not re-enqueue" >&2
    return 1
  }
  [ "$(grep -c '|META|fleet-restart|' "$log_file" 2>/dev/null || true)" = "1" ] || {
    echo "chained: expected exactly one restart marker after first re-enqueue" >&2
    return 1
  }

  # Worker consumes (queue rewritten without the entry), spawns, crashes again.
  rm -f "$queue_file"

  # Restart #2: count 1 < cap 2 → re-enqueued again.
  fleet_reconcile_orphans "$ws" "$queue_file" "" >/dev/null
  [ -f "$queue_file" ] && grep -q '"tid":"CRE-23"' "$queue_file" || {
    echo "chained: second reconcile did not re-enqueue (count 1/2)" >&2
    return 1
  }
  [ "$(grep -c '|META|fleet-restart|' "$log_file" 2>/dev/null || true)" = "2" ] || {
    echo "chained: expected two restart markers after second re-enqueue" >&2
    return 1
  }

  # Worker consumes again, crashes again → count 2 = cap → dead-lettered.
  rm -f "$queue_file"
  fleet_reconcile_orphans "$ws" "$queue_file" "" >/dev/null
  [ ! -f "$queue_file" ] || ! grep -q '"tid":"CRE-23"' "$queue_file" 2>/dev/null || {
    echo "chained: ticket re-enqueued past the restart cap" >&2
    return 1
  }
  local dead_letter_file="${queue_file%.jsonl}-dead-letter.jsonl"
  grep -q '"tid":"CRE-23"' "$dead_letter_file" 2>/dev/null &&
    grep -q 'orphaned-after-max-restarts' "$dead_letter_file" || {
    echo "chained: capped ticket not dead-lettered" >&2
    return 1
  }
  return 0
}

test_live_reap_and_reconcile_share_one_cap() {
  local ws
  ws=$(_setup_workspace)
  _reconcile_env "$ws"
  FLEET_MAX_RESTARTS=2
  local queue_file
  queue_file=$(_reconcile_queue_file "$ws")
  rm -f "$queue_file" "${queue_file%.jsonl}-dead-letter.jsonl"

  local log_file="${ws}/CRE-17-pipeline.log"
  _plog_line "$log_file" "APPRAISE" "appraise" "start" "investigating"
  # One restart already recorded via the live-reap path.
  _plog_line "$log_file" "META" "fleet-restart" "info" "restart stall-kill"

  # First reconciliation: count 1 < cap 2 → re-enqueued.
  fleet_reconcile_orphans "$ws" "$queue_file" "" >/dev/null
  local count
  count=$(grep -c '"tid":"CRE-17"' "$queue_file" 2>/dev/null || true)
  [ "$count" = "1" ] || {
    echo "first reconciliation should re-enqueue (count 1/2), queue has ${count}" >&2
    return 1
  }

  # Remove the queue entry to simulate consumption, then reconcile again:
  # combined count is now 2 (live-reap 1 + reconcile 1) → dead-lettered,
  # NOT re-enqueued. Two independent counters would re-enqueue here.
  rm -f "$queue_file"
  fleet_reconcile_orphans "$ws" "$queue_file" "" >/dev/null
  [ ! -f "$queue_file" ] || ! grep -q '"tid":"CRE-17"' "$queue_file" 2>/dev/null || {
    echo "ticket at combined cap was re-enqueued on second reconciliation" >&2
    return 1
  }
  local dead_letter_file="${queue_file%.jsonl}-dead-letter.jsonl"
  [ -f "$dead_letter_file" ] && grep -q '"tid":"CRE-17"' "$dead_letter_file" 2>/dev/null || {
    echo "ticket at combined cap missing from dead-letter file" >&2
    return 1
  }
  return 0
}

# ── Run all tests ────────────────────────────────────────────────────────────────

_run "classify done" test_classify_done
_run "classify gate-stop as done" test_classify_gate_stop
_run "classify gate-held" test_classify_gate_held
_run "classify gate-held crash before finalize" test_classify_gate_held_crash_before_finalize
_run "classify incomplete" test_classify_incomplete
_run "classify missing log" test_classify_missing_log
_run "classify dead-letter terminal" test_classify_dead_letter_terminal
_run "orphan re-enqueued exactly once" test_orphan_reenqueued_exactly_once
_run "done and gate-held left alone" test_done_and_gate_held_left_alone
_run "adopted-live skipped" test_adopted_live_skipped
_run "live worker process skipped" test_live_worker_process_skipped
_run "auto-restart default enabled" test_auto_restart_default_enabled
_run "auto-restart disabled skipped with reason" test_auto_restart_disabled_skipped_with_reason
_run "at cap dead-lettered not re-enqueued" test_at_cap_dead_lettered_not_reenqueued
_run "reconcile entry continues fenced generation" test_reconcile_entry_continues_fenced_generation
_run "chained crash-resume reaches cap then dead-letters" test_chained_crash_resume_reaches_cap
_run "live-reap and reconcile share one cap" test_live_reap_and_reconcile_share_one_cap

# ── Stop-file pins (fleet-epic-stop) ─────────────────────────────────────────────

test_pinned_tid_not_reenqueued() {
  local ws
  ws=$(_setup_workspace)
  _reconcile_env "$ws"
  local queue_file
  queue_file=$(_reconcile_queue_file "$ws")
  rm -f "$queue_file" "${queue_file%.jsonl}-dead-letter.jsonl"

  # Both tickets are incomplete orphans; CRE-14 is pinned by a stop-file.
  _plog_line "${ws}/CRE-14-pipeline.log" "APPRAISE" "appraise" "start" "investigating"
  _plog_line "${ws}/CRE-15-pipeline.log" "APPRAISE" "appraise" "start" "investigating"
  echo '{"initiative_id":"INIT-42","tickets":["CRE-14"]}' >"$ws/stop-INIT-42.json"

  fleet_reconcile_orphans "$ws" "$queue_file" "" "CRE-14" >/dev/null

  if grep -q '"tid":"CRE-14"' "$queue_file" 2>/dev/null; then
    echo "pinned tid was re-enqueued" >&2
    rm -rf "$ws"
    return 1
  fi
  grep -q '"tid":"CRE-15"' "$queue_file" 2>/dev/null || {
    echo "unpinned tid was not re-enqueued" >&2
    rm -rf "$ws"
    return 1
  }
  rm -rf "$ws"
  return 0
}

_run "pinned tid not re-enqueued" test_pinned_tid_not_reenqueued

echo ""
echo "=== Results ==="
echo "PASS: $PASS | FAIL: $FAIL"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
