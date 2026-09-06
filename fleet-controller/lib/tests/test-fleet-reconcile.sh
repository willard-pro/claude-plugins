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

# A bare gate-stop marker with no outcome line: the process died before
# pipeline-finalize.sh could finalize (the CRE-9 incident shape). The gate is
# structural, but its condition may since have been fixed by a human — so it
# classifies gate-stopped, distinct from done, and a scoped resume may retry it.
test_classify_gate_stop() {
  local ws
  ws=$(_setup_workspace)
  local log_file="${ws}/CRE-8-pipeline.log"
  _plog_line "$log_file" "GATE" "gate" "start" "checking"
  _plog_line "$log_file" "META" "gate-stop" "fail" "EXEC_NO_ARTIFACT"

  local state
  state=$(fleet_ticket_terminal_state "CRE-8" "$log_file")
  [ "$state" = "gate-stopped" ] || {
    echo "expected gate-stopped (condition may be fixable), got $state" >&2
    return 1
  }
}

# The NORMAL gate-stop shape, and the one that matters for real traffic:
# pipeline-finalize.sh runs at every gate-stop exit and writes the log's last
# line as META|outcome|info|stopped: gate-stop <CODE>. That lands in the
# outcome branch, which returns before the bare-marker grep above is ever
# reached — so this case is NOT covered by test_classify_gate_stop, and a fix
# to the grep alone would leave it silently classifying done.
test_classify_gate_stop_clean_exit_outcome_message() {
  local ws
  ws=$(_setup_workspace)
  local log_file="${ws}/CRE-9-pipeline.log"
  _plog_line "$log_file" "GATE" "gate" "start" "checking"
  _plog_line "$log_file" "META" "gate-stop" "fail" "ZERO_AC"
  _plog_line "$log_file" "META" "outcome" "info" \
    "stopped: gate-stop ZERO_AC — ticket has zero acceptance criteria; nothing verifiable exists"

  local state
  state=$(fleet_ticket_terminal_state "CRE-9" "$log_file")
  [ "$state" = "gate-stopped" ] || {
    echo "expected gate-stopped (clean-exit outcome message), got $state" >&2
    return 1
  }
}

# VERIFY_EXHAUSTED is a gate-stop code like any other and classifies the same
# way. Retrying it can never actually succeed (its attempt counter is derived
# from append-only log history), but that is a resume-eligibility concern —
# classification deliberately does not special-case it (design Decision 4).
test_classify_verify_exhausted_is_gate_stopped() {
  local ws
  ws=$(_setup_workspace)
  local log_file="${ws}/CRE-12-pipeline.log"
  _plog_line "$log_file" "VERIFY" "verify" "fail" "attempt 2"
  _plog_line "$log_file" "META" "gate-stop" "fail" "VERIFY_EXHAUSTED"
  _plog_line "$log_file" "META" "outcome" "info" "stopped: gate-stop VERIFY_EXHAUSTED"

  local state
  state=$(fleet_ticket_terminal_state "CRE-12" "$log_file")
  [ "$state" = "gate-stopped" ] || {
    echo "expected gate-stopped (no per-code special-casing), got $state" >&2
    return 1
  }
}

# A dead-letter last line wins over a gate-stop marker earlier in the log.
# A ticket that gate-stopped, was retried to the cap and then dead-lettered
# carries BOTH markers; if the gate-stop grep won, the ticket would become
# retry-eligible again under scope and loop past its own restart cap.
test_classify_dead_letter_beats_gate_stop_marker() {
  local ws
  ws=$(_setup_workspace)
  local log_file="${ws}/CRE-13-pipeline.log"
  _plog_line "$log_file" "GATE" "gate" "start" "checking"
  _plog_line "$log_file" "META" "gate-stop" "fail" "ZERO_AC"
  _plog_line "$log_file" "META" "dead-letter" "warn" "reason=orphaned-after-max-restarts"

  local state
  state=$(fleet_ticket_terminal_state "CRE-13" "$log_file")
  [ "$state" = "done" ] || {
    echo "expected done (dead-letter is terminal even with a gate-stop), got $state" >&2
    return 1
  }
}

# A verified fleet-kill writes META|outcome|...|stopped: fleet-kill (...) — the
# pipeline is resumable (kill = pause, stop-file pin = stop), so it classifies
# incomplete unless a gate-stop marker exists in the log.
test_classify_fleet_kill_resumable() {
  local ws
  ws=$(_setup_workspace)
  local log_file="${ws}/CRE-9-pipeline.log"
  _plog_line "$log_file" "EXEC" "exec" "start" "mid-flight"
  _plog_line "$log_file" "META" "outcome" "info" "stopped: fleet-kill (SIGTERM); auto-kill"

  local state
  state=$(fleet_ticket_terminal_state "CRE-9" "$log_file")
  [ "$state" = "incomplete" ] || {
    echo "expected incomplete (kill is resumable), got $state" >&2
    return 1
  }
}

test_classify_fleet_kill_after_gate_stop_done() {
  local ws
  ws=$(_setup_workspace)
  local log_file="${ws}/CRE-8-pipeline.log"
  _plog_line "$log_file" "GATE" "gate" "start" "checking"
  # Gate-stopped, then killed while cleaning up. Not incomplete (the gate is
  # real and a plain resume would hit it again) and not done (the condition
  # may since have been fixed) — the third route to gate-stopped.
  _plog_line "$log_file" "META" "gate-stop" "fail" "EXEC_NO_ARTIFACT"
  _plog_line "$log_file" "META" "outcome" "info" "stopped: fleet-kill (SIGKILL); operator-stop"

  local state
  state=$(fleet_ticket_terminal_state "CRE-8" "$log_file")
  [ "$state" = "gate-stopped" ] || {
    echo "expected gate-stopped (kill over a gate-stopped log), got $state" >&2
    return 1
  }
}

# kill-unverified means the worker may still be running — the kill path itself
# falls through to incomplete; pin it with a test.
test_classify_kill_unverified_incomplete() {
  local ws
  ws=$(_setup_workspace)
  local log_file="${ws}/CRE-7-pipeline.log"
  _plog_line "$log_file" "EXEC" "exec" "start" "mid-flight"
  _plog_line "$log_file" "META" "kill-unverified" "warn" "still alive after SIGKILL"

  local state
  state=$(fleet_ticket_terminal_state "CRE-7" "$log_file")
  [ "$state" = "incomplete" ] || {
    echo "expected incomplete (kill-unverified), got $state" >&2
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

test_classify_unrecognised_hold_kind_still_gate_held() {
  # Every hold kind means the same thing to this classifier — "parked, not
  # dispatchable" — so an unrecognised future kind must still classify as
  # gate-held via the `held: ` prefix match, never fall through to `done`
  # (which is documented as permanent and never reconsidered).
  local ws
  ws=$(_setup_workspace)
  local log_file="${ws}/CRE-12-pipeline.log"
  _plog_line "$log_file" "GATE" "gate" "start" "checking"
  _plog_line "$log_file" "META" "outcome" "info" "held: some-future-kind"

  local state
  state=$(fleet_ticket_terminal_state "CRE-12" "$log_file")
  [ "$state" = "gate-held" ] || {
    echo "expected gate-held for an unrecognised hold kind, got $state" >&2
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

# ── Campaign-scope reconciliation (FLEET_RECONCILE_TIDS/EPIC/DRY_RUN) ──────────

test_scoped_tids_only_resume_listed() {
  local ws
  ws=$(_setup_workspace)
  _reconcile_env "$ws"
  local queue_file
  queue_file=$(_reconcile_queue_file "$ws")
  rm -f "$queue_file" "${queue_file%.jsonl}-dead-letter.jsonl"

  _plog_line "${ws}/CRE-9-pipeline.log" "APPRAISE" "appraise" "start" "investigating"
  _plog_line "${ws}/CRE-10-pipeline.log" "APPRAISE" "appraise" "start" "investigating"
  _plog_line "${ws}/CRE-11-pipeline.log" "APPRAISE" "appraise" "start" "investigating"

  local out
  out=$(FLEET_RECONCILE_TIDS="CRE-9 CRE-10" fleet_reconcile_orphans "$ws" "$queue_file" "" 2>&1)

  grep -q '"tid":"CRE-9"' "$queue_file" 2>/dev/null &&
    grep -q '"tid":"CRE-10"' "$queue_file" 2>/dev/null || {
    echo "scoped tids CRE-9/CRE-10 missing from queue: $(cat "$queue_file" 2>/dev/null)" >&2
    return 1
  }
  [ ! -f "$queue_file" ] || ! grep -q '"tid":"CRE-11"' "$queue_file" 2>/dev/null || {
    echo "out-of-scope tid CRE-11 was enqueued" >&2
    return 1
  }
  # Real-mode resume lines — the supervisor's dispatch_epic parses these.
  echo "$out" | grep -q '^  resumed CRE-9$' || {
    echo "expected '  resumed CRE-9' line, got: $out" >&2
    return 1
  }
  echo "$out" | grep -q '^  resumed CRE-10$' || {
    echo "expected '  resumed CRE-10' line, got: $out" >&2
    return 1
  }
  return 0
}

test_dry_run_resume_writes_nothing() {
  local ws
  ws=$(_setup_workspace)
  _reconcile_env "$ws"
  local queue_file
  queue_file=$(_reconcile_queue_file "$ws")
  rm -f "$queue_file" "${queue_file%.jsonl}-dead-letter.jsonl"

  local log_file="${ws}/CRE-25-pipeline.log"
  _plog_line "$log_file" "APPRAISE" "appraise" "start" "investigating"

  local out
  out=$(FLEET_RECONCILE_DRY_RUN=1 fleet_reconcile_orphans "$ws" "$queue_file" "" 2>&1)

  echo "$out" | grep -q '\[DRY-RUN\] would resume CRE-25' || {
    echo "expected dry-run would-resume line, got: $out" >&2
    return 1
  }
  [ ! -f "$queue_file" ] || ! grep -q '"tid":"CRE-25"' "$queue_file" 2>/dev/null || {
    echo "dry-run wrote a queue entry" >&2
    return 1
  }
  grep -q '|META|fleet-restart|' "$log_file" 2>/dev/null && {
    echo "dry-run wrote a fleet-restart marker" >&2
    return 1
  }
  return 0
}

test_dry_run_cap_reports_dead_letter_without_writing() {
  local ws
  ws=$(_setup_workspace)
  _reconcile_env "$ws"
  FLEET_MAX_RESTARTS=2
  local queue_file
  queue_file=$(_reconcile_queue_file "$ws")
  rm -f "$queue_file" "${queue_file%.jsonl}-dead-letter.jsonl"

  local log_file="${ws}/CRE-26-pipeline.log"
  _plog_line "$log_file" "APPRAISE" "appraise" "start" "investigating"
  _plog_line "$log_file" "META" "fleet-restart" "info" "restart stall-kill"
  _plog_line "$log_file" "META" "fleet-restart" "info" "restart zombie-kill"

  local out
  out=$(FLEET_RECONCILE_DRY_RUN=1 fleet_reconcile_orphans "$ws" "$queue_file" "" 2>&1)

  echo "$out" | grep -q '\[DRY-RUN\] would dead-letter CRE-26 (restart cap)' || {
    echo "expected dry-run dead-letter line, got: $out" >&2
    return 1
  }
  local dead_letter_file="${queue_file%.jsonl}-dead-letter.jsonl"
  if [ -f "$dead_letter_file" ] && grep -q '"tid":"CRE-26"' "$dead_letter_file" 2>/dev/null; then
    echo "dry-run wrote a dead-letter entry" >&2
    return 1
  fi
  return 0
}

test_campaign_resume_reason() {
  local ws
  ws=$(_setup_workspace)
  _reconcile_env "$ws"
  local queue_file
  queue_file=$(_reconcile_queue_file "$ws")
  rm -f "$queue_file" "${queue_file%.jsonl}-dead-letter.jsonl"

  _plog_line "${ws}/CRE-27-pipeline.log" "APPRAISE" "appraise" "start" "investigating"

  FLEET_RECONCILE_EPIC=CRE-6 fleet_reconcile_orphans "$ws" "$queue_file" "" >/dev/null

  local reason
  reason=$(grep '"tid":"CRE-27"' "$queue_file" | head -1 | jq -r '.reason // ""')
  [ "$reason" = "campaign-resume from CRE-6" ] || {
    echo "expected reason 'campaign-resume from CRE-6', got '$reason'" >&2
    return 1
  }
  return 0
}

# The CRE-9 case this change exists for: a gate-stop whose condition a human
# has since fixed. Under an explicit epic scope it is re-enqueued; the worker's
# own gate-check re-verifies live (fleet performs no per-code re-verification).
test_scoped_resume_reenqueues_gate_stopped() {
  local ws
  ws=$(_setup_workspace)
  _reconcile_env "$ws"
  local queue_file
  queue_file=$(_reconcile_queue_file "$ws")
  rm -f "$queue_file" "${queue_file%.jsonl}-dead-letter.jsonl"

  local log_file="${ws}/CRE-9-pipeline.log"
  _plog_line "$log_file" "GATE" "gate" "start" "checking"
  _plog_line "$log_file" "META" "gate-stop" "fail" "ZERO_AC"
  _plog_line "$log_file" "META" "outcome" "info" "stopped: gate-stop ZERO_AC — no acceptance criteria"

  FLEET_RECONCILE_EPIC=CRE-6 fleet_reconcile_orphans "$ws" "$queue_file" "" >/dev/null

  local reason
  reason=$(grep '"tid":"CRE-9"' "$queue_file" 2>/dev/null | head -1 | jq -r '.reason // ""')
  [ "$reason" = "campaign-resume from CRE-6" ] || {
    echo "expected gate-stopped CRE-9 re-enqueued as campaign-resume, got '$reason'" >&2
    return 1
  }
  return 0
}

# A gate-held ticket that has since been approved. Reconcile does NOT check the
# label itself — it re-enqueues speculatively and lets detect-resume.sh make the
# live call, which is the single place that check lives.
test_scoped_resume_reenqueues_gate_held() {
  local ws
  ws=$(_setup_workspace)
  _reconcile_env "$ws"
  local queue_file
  queue_file=$(_reconcile_queue_file "$ws")
  rm -f "$queue_file" "${queue_file%.jsonl}-dead-letter.jsonl"

  local log_file="${ws}/CRE-11-pipeline.log"
  _plog_line "$log_file" "META" "gate-held" "info" "held"
  _plog_line "$log_file" "META" "outcome" "info" "held: gate"

  FLEET_RECONCILE_EPIC=CRE-6 fleet_reconcile_orphans "$ws" "$queue_file" "" >/dev/null

  local reason
  reason=$(grep '"tid":"CRE-11"' "$queue_file" 2>/dev/null | head -1 | jq -r '.reason // ""')
  [ "$reason" = "campaign-resume from CRE-6" ] || {
    echo "expected gate-held CRE-11 re-enqueued as campaign-resume, got '$reason'" >&2
    return 1
  }
  return 0
}

# Guards the scoped/unscoped split: an idle fleetd's passive startup scan must
# never spend restart credits or kick off implementation on a freshly-approved
# or freshly-fixed ticket. Only an explicit human --resume may do that.
test_unscoped_leaves_gate_stopped_and_gate_held_alone() {
  local ws
  ws=$(_setup_workspace)
  _reconcile_env "$ws"
  local queue_file
  queue_file=$(_reconcile_queue_file "$ws")
  rm -f "$queue_file" "${queue_file%.jsonl}-dead-letter.jsonl"

  _plog_line "${ws}/CRE-9-pipeline.log" "META" "gate-stop" "fail" "ZERO_AC"
  _plog_line "${ws}/CRE-9-pipeline.log" "META" "outcome" "info" "stopped: gate-stop ZERO_AC"
  _plog_line "${ws}/CRE-11-pipeline.log" "META" "gate-held" "info" "held"
  _plog_line "${ws}/CRE-11-pipeline.log" "META" "outcome" "info" "held: gate"

  local out
  out=$(fleet_reconcile_orphans "$ws" "$queue_file" "" 2>&1)

  if [ -f "$queue_file" ]; then
    ! grep -q '"tid":"CRE-9"' "$queue_file" 2>/dev/null || {
      echo "gate-stopped CRE-9 re-enqueued without epic scope" >&2
      return 1
    }
    ! grep -q '"tid":"CRE-11"' "$queue_file" 2>/dev/null || {
      echo "gate-held CRE-11 re-enqueued without epic scope" >&2
      return 1
    }
  fi
  # The skip line must name the scope reason, not read like a genuine done —
  # this is exactly how the original CRE-9 stall was diagnosed from fleetd.log.
  echo "$out" | grep -q "CRE-9 — gate-stopped, left alone (no epic scope)" || {
    echo "expected scope-qualified skip line, got: $out" >&2
    return 1
  }
  return 0
}

# A still-broken gate-stop is bounded by the existing restart cap: it retries,
# then dead-letters, and further scoped resumes leave it alone. No new counter,
# no infinite-retry surface. Also covers VERIFY_EXHAUSTED, whose retry can never
# succeed — it simply burns the same cap and dead-letters like any other.
test_scoped_resume_gate_stopped_caps_then_dead_letters() {
  local ws
  ws=$(_setup_workspace)
  _reconcile_env "$ws"
  FLEET_MAX_RESTARTS=2
  local queue_file
  queue_file=$(_reconcile_queue_file "$ws")
  rm -f "$queue_file" "${queue_file%.jsonl}-dead-letter.jsonl"

  local log_file="${ws}/CRE-17-pipeline.log"
  _plog_line "$log_file" "GATE" "gate" "start" "checking"
  _plog_line "$log_file" "META" "gate-stop" "fail" "ZERO_AC"
  _plog_line "$log_file" "META" "outcome" "info" "stopped: gate-stop ZERO_AC"
  # Already at the cap — two prior restarts.
  _plog_line "$log_file" "META" "fleet-restart" "info" "restart campaign-resume from CRE-6"
  _plog_line "$log_file" "META" "fleet-restart" "info" "restart campaign-resume from CRE-6"

  local out
  out=$(FLEET_RECONCILE_EPIC=CRE-6 fleet_reconcile_orphans "$ws" "$queue_file" "" 2>&1)

  [ ! -f "$queue_file" ] || ! grep -q '"tid":"CRE-17"' "$queue_file" 2>/dev/null || {
    echo "capped gate-stopped CRE-17 was re-enqueued" >&2
    return 1
  }
  local dead_letter_file="${queue_file%.jsonl}-dead-letter.jsonl"
  grep -q '"tid":"CRE-17"' "$dead_letter_file" 2>/dev/null || {
    echo "capped gate-stopped CRE-17 missing from dead-letter file" >&2
    return 1
  }

  # Once dead-lettered, the log's last line is the dead-letter marker — which
  # must outrank the gate-stop marker still sitting earlier in the same log.
  # If it did not, the ticket would classify gate-stopped again and loop past
  # its own cap, re-dead-lettering on every scoped resume.
  local state
  state=$(fleet_ticket_terminal_state "CRE-17" "$log_file")
  [ "$state" = "done" ] || {
    echo "expected done after dead-letter, got $state (cap would be defeated)" >&2
    return 1
  }
  local dl_before dl_after
  dl_before=$(grep -c '"tid":"CRE-17"' "$dead_letter_file" 2>/dev/null || true)
  FLEET_RECONCILE_EPIC=CRE-6 fleet_reconcile_orphans "$ws" "$queue_file" "" >/dev/null
  dl_after=$(grep -c '"tid":"CRE-17"' "$dead_letter_file" 2>/dev/null || true)
  [ "$dl_before" = "$dl_after" ] || {
    echo "scoped resume duplicated dead-letter: before=${dl_before} after=${dl_after}" >&2
    return 1
  }
  return 0
}

test_empty_tids_global_behavior_unchanged() {
  local ws
  ws=$(_setup_workspace)
  _reconcile_env "$ws"
  local queue_file
  queue_file=$(_reconcile_queue_file "$ws")
  rm -f "$queue_file" "${queue_file%.jsonl}-dead-letter.jsonl"

  _plog_line "${ws}/CRE-28-pipeline.log" "APPRAISE" "appraise" "start" "investigating"
  _plog_line "${ws}/CRE-29-pipeline.log" "APPRAISE" "appraise" "start" "investigating"

  # Explicitly unset the scope env — the startup path must stay global.
  FLEET_RECONCILE_TIDS= fleet_reconcile_orphans "$ws" "$queue_file" "" >/dev/null

  grep -q '"tid":"CRE-28"' "$queue_file" 2>/dev/null &&
    grep -q '"tid":"CRE-29"' "$queue_file" 2>/dev/null || {
    echo "global scan missed tickets when TIDS unset" >&2
    return 1
  }
  local reason
  reason=$(grep '"tid":"CRE-28"' "$queue_file" | head -1 | jq -r '.reason // ""')
  [ "$reason" = "orphan-reconciliation" ] || {
    echo "expected startup reason 'orphan-reconciliation', got '$reason'" >&2
    return 1
  }
  return 0
}

# ── Run all tests ────────────────────────────────────────────────────────────────

_run "classify done" test_classify_done
_run "classify bare gate-stop marker as gate-stopped" test_classify_gate_stop
_run "classify clean-exit gate-stop outcome as gate-stopped" test_classify_gate_stop_clean_exit_outcome_message
_run "classify VERIFY_EXHAUSTED as gate-stopped" test_classify_verify_exhausted_is_gate_stopped
_run "classify dead-letter over gate-stop marker as done" test_classify_dead_letter_beats_gate_stop_marker
_run "classify fleet-kill as resumable" test_classify_fleet_kill_resumable
_run "classify fleet-kill after gate-stop as gate-stopped" test_classify_fleet_kill_after_gate_stop_done
_run "classify kill-unverified as incomplete" test_classify_kill_unverified_incomplete
_run "classify gate-held" test_classify_gate_held
_run "classify gate-held crash before finalize" test_classify_gate_held_crash_before_finalize
_run "classify unrecognised hold kind as gate-held" test_classify_unrecognised_hold_kind_still_gate_held
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
_run "scoped tids only resume listed" test_scoped_tids_only_resume_listed
_run "dry-run resume writes nothing" test_dry_run_resume_writes_nothing
_run "dry-run cap reports dead-letter without writing" test_dry_run_cap_reports_dead_letter_without_writing
_run "campaign resume reason" test_campaign_resume_reason
_run "scoped resume re-enqueues gate-stopped" test_scoped_resume_reenqueues_gate_stopped
_run "scoped resume re-enqueues gate-held" test_scoped_resume_reenqueues_gate_held
_run "unscoped leaves gate-stopped and gate-held alone" test_unscoped_leaves_gate_stopped_and_gate_held_alone
_run "scoped resume gate-stopped caps then dead-letters" test_scoped_resume_gate_stopped_caps_then_dead_letters
_run "empty tids global behavior unchanged" test_empty_tids_global_behavior_unchanged

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

# F05: _fleet_tid_live must be anchored at the tid's right edge — a live
# CRE-70 worker must not satisfy a CRE-7 liveness check (pgrep -f is a
# substring ERE match otherwise).
test_tid_live_prefix_anchored() {
  bash -c 'exec -a "claude -p /ticket-auto CRE-70 --auto" sleep 30' &
  local wk_pid=$!
  trap 'kill "$wk_pid" 2>/dev/null || true' EXIT
  sleep 0.3

  if bash -c "
    source '$LIB_DIR/fleet-reconcile.sh'
    _fleet_tid_live 'CRE-7'
  " 2>/dev/null; then
    echo "CRE-70 worker matched CRE-7 tid — unanchored pattern" >&2
    return 1
  fi
  if ! bash -c "
    source '$LIB_DIR/fleet-reconcile.sh'
    _fleet_tid_live 'CRE-70'
  " 2>/dev/null; then
    echo "CRE-70 worker did not match its own tid" >&2
    return 1
  fi
  return 0
}

_run "tid_live_prefix_anchored" test_tid_live_prefix_anchored

echo ""
echo "=== Results ==="
echo "PASS: $PASS | FAIL: $FAIL"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
