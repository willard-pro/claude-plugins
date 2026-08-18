#!/usr/bin/env bash
# fleet-reconcile.sh — fleetd startup orphan reconciliation.
# Sourceable bash library. Does NOT set -euo pipefail (caller controls error
# handling).
#
# When fleetd itself was down while a worker died, the worker's run-registry
# entry is deleted as stale on the next startup scan and nothing re-queues
# it. This library closes that gap: it classifies every ticket with a
# pipeline log using only that log (cheap, read-only, no Linear/gh calls)
# and re-enqueues the genuinely-orphaned ones onto the spawn queue. The
# consume-and-spawn path then re-invokes ticket-auto, which self-resumes
# from its own pipeline log exactly as for any other re-invocation.
#
# Dependencies: fleet-detect.sh (_last_field/_last_msg), fleet-intervene.sh
# (_count_restarts/fleet_can_restart/_log_pipeline), fleet-dispatch.sh
# (_fleet_queue_append/_queue_has_ticket), fleet-config.sh, jq

_RECONCILE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -f "$_RECONCILE_DIR/fleet-config.sh" ]; then
  source "$_RECONCILE_DIR/fleet-config.sh"
fi

if ! declare -f _last_msg >/dev/null 2>&1; then
  [ -f "$_RECONCILE_DIR/fleet-detect.sh" ] && source "$_RECONCILE_DIR/fleet-detect.sh"
fi
if ! declare -f fleet_can_restart >/dev/null 2>&1; then
  [ -f "$_RECONCILE_DIR/fleet-intervene.sh" ] && source "$_RECONCILE_DIR/fleet-intervene.sh"
fi
if ! declare -f _fleet_queue_append >/dev/null 2>&1; then
  [ -f "$_RECONCILE_DIR/fleet-dispatch.sh" ] && source "$_RECONCILE_DIR/fleet-dispatch.sh"
fi

# _fleet_tid_live <tid>
# Returns 0 if a worker process for the ticket appears to be running — its
# command line contains the /ticket-auto invocation. Best-effort, cheap:
# covers the fork→registry-write crash window and PID=0 sentinel registry
# entries (monitor-spawned workers are invisible to scan_registry adoption)
# so a ticket that is actually running is never re-enqueued. Two claude
# processes appending one pipeline log is worse than a missed re-enqueue.
_fleet_tid_live() {
  local tid="$1"
  command -v pgrep >/dev/null 2>&1 || return 1
  pgrep -f "ticket-auto ${tid}" >/dev/null 2>&1
}

# fleet_ticket_terminal_state <TICKET_ID> <pipeline_log_path>
# Classifies a ticket's state from its pipeline log alone. Cheap and
# read-only: no Linear, no gh, no log mutation.
#
# Emits exactly one of:
#   done       — a terminal completion or failure marker is present
#   gate-held  — held for human approval with no later resolving event
#   incomplete — neither: the pipeline was interrupted mid-flight
#
# Exit code is always 0 (classification is a value, not a failure signal);
# a missing/empty log classifies as incomplete so the caller decides.
fleet_ticket_terminal_state() {
  local tid="$1"
  local log_file="$2"

  if [ ! -f "$log_file" ] || [ ! -s "$log_file" ]; then
    echo "incomplete"
    return 0
  fi

  local last_step last_status last_msg
  last_step=$(_last_field "$log_file" 3)
  last_status=$(_last_field "$log_file" 4)
  last_msg=$(_last_msg "$log_file")

  # A run that finalized writes META|outcome as its last substantive line
  # (pipeline-finalize.sh tail-check guarantee). A gate-held run's outcome
  # summary is "held: gate" — still waiting on the human, not terminal.
  if [ "$last_step" = "outcome" ]; then
    case "$last_msg" in
    *"held: gate"*)
      echo "gate-held"
      return 0
      ;;
    *)
      echo "done"
      return 0
      ;;
    esac
  fi

  # Crash between gate-held write and finalize: the held marker itself is
  # the last line. Still gate-held — the human gate stands.
  if [ "$last_step" = "gate-held" ]; then
    echo "gate-held"
    return 0
  fi

  # A gate-stop anywhere in the log is a terminal structural failure
  # (pipeline halts, no fallback) — restarting would hit the same gate.
  if command grep -q '|META|gate-stop|fail|' "$log_file" 2>/dev/null; then
    echo "done"
    return 0
  fi

  # A dead-letter marker as the last line is terminal: the ticket was
  # surfaced for a human rather than lost. Classifying it done keeps
  # reconciliation idempotent across restarts (no duplicate dead-letter
  # entries, no re-enqueue of a permanently-stuck ticket).
  if [ "$last_step" = "dead-letter" ]; then
    echo "done"
    return 0
  fi

  echo "incomplete"
  return 0
}

# _reconcile_entry <tid> <reason> [state_dir]
# Builds a spawn-queue entry identical in shape to a normal initial-dispatch
# entry — no branch, base, integration, or epic fields; the re-spawned worker
# resolves or rehydrates its own branch context.
#
# Generation continuity: the entry's generation must exceed any fenced
# predecessor. fleetd re-derives generations itself, but the bash
# monitor/consume path trusts the entry — a re-queued ticket whose old
# generation was fenced would spawn at generation 1 and be rejected by
# flow.sh's fence guard as a superseded zombie. Read the fence marker and
# the preserved last-generation side record and continue from there.
_reconcile_entry() {
  local tid="$1"
  local reason="$2"
  local state_dir="${3:-}"
  local generation=1

  if [ -n "$state_dir" ] && declare -f fence_read >/dev/null 2>&1; then
    local fenced last_gen base=0
    fenced=$(fence_read "$tid" "$state_dir" 2>/dev/null || echo "0")
    last_gen=$(cat "${state_dir}/${tid}-last-generation" 2>/dev/null || echo "0")
    [ "$fenced" -gt "$base" ] 2>/dev/null && base=$fenced
    [ "$last_gen" -gt "$base" ] 2>/dev/null && base=$last_gen
    generation=$((base + 1))
  fi

  jq -nc \
    --arg tid "$tid" \
    --arg reason "$reason" \
    --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --argjson restarts 0 \
    --argjson generation "$generation" \
    --arg dispatch_type "initial" \
    '{tid: $tid, reason: $reason, timestamp: $timestamp, restarts: $restarts, dispatch_type: $dispatch_type, generation: $generation}'
}

# fleet_reconcile_orphans <state_dir> <queue_file> [live_tids]
# Startup reconciliation: glob {state_dir}/*-pipeline.log, skip tickets that
# are adopted-live (space-separated TID list in $3) or already queued,
# classify the rest, and re-enqueue `incomplete` tickets via the shared
# queue-append function.
#
# The restart cap uses the EXISTING fleet_can_restart/_count_restarts/
# FLEET_MAX_RESTARTS mechanism — orphan restarts and live-reap restarts share
# one counter and one cap. At the cap, the ticket is dead-lettered with
# reason `orphaned-after-max-restarts` and not re-enqueued. A ticket
# ineligible for another reason (auto-restart disabled, flow.sh mutex held)
# is skipped without dead-lettering — it is not exhausted, just not
# restartable right now.
#
# Emits one `reconciled <tid> <state>` line per classified ticket for
# greppability. Never exits non-zero for classification outcomes.
fleet_reconcile_orphans() {
  local state_dir="$1"
  local queue_file="$2"
  local live_tids="${3:-}"
  local pinned_tids="${4:-}"

  [ -d "$state_dir" ] || return 0

  local log_file tid state
  for log_file in "$state_dir"/*-pipeline.log; do
    [ -f "$log_file" ] || continue
    tid=$(basename "$log_file" | sed 's/-pipeline.log$//')
    [ -z "$tid" ] && continue

    # Skip tickets whose worker was adopted live by scan_workers.
    case " $live_tids " in
    *" $tid "*) continue ;;
    esac

    # Skip tickets pinned by any stop-file — reconciliation has no epic
    # context of its own, so the pinned tid list is what makes a stop
    # survive a fleetd restart.
    case " $pinned_tids " in
    *" $tid "*)
      echo "fleet_reconcile: ${tid} — pinned by stop-file, left alone"
      continue
      ;;
    esac

    # Skip tickets whose worker process is still alive — see _fleet_tid_live.
    if _fleet_tid_live "$tid"; then
      echo "fleet_reconcile: ${tid} — worker live, left alone"
      continue
    fi

    # Skip tickets with an unconsumed queue entry — no double-enqueue.
    if _queue_has_ticket "$tid" "$queue_file"; then
      continue
    fi

    state=$(fleet_ticket_terminal_state "$tid" "$log_file")
    if [ "$state" != "incomplete" ]; then
      echo "fleet_reconcile: ${tid} — ${state}, left alone"
      continue
    fi

    # Cap via the existing restart mechanism — no second counting scheme.
    # The reason string is captured and surfaced: a silent skip is how a
    # disabled auto-restart gate goes unnoticed in production.
    local not_restartable_reason
    if ! not_restartable_reason=$(fleet_can_restart "$tid" "$state_dir" 2>&1); then
      local restarts max_restarts
      restarts=$(_count_restarts "$log_file")
      max_restarts="${FLEET_MAX_RESTARTS:-2}"
      if [ "${restarts:-0}" -ge "$max_restarts" ]; then
        local dead_letter_file entry
        dead_letter_file="${queue_file%.jsonl}-dead-letter.jsonl"
        entry=$(_reconcile_entry "$tid" "orphaned-after-max-restarts" "$state_dir")
        echo "$entry" >>"$dead_letter_file"
        # Terminal marker on the ticket's own log (also keeps classification
        # idempotent) + structured notification line.
        _log_pipeline "$log_file" "META" "dead-letter" "warn" "reason=orphaned-after-max-restarts"
        echo "fleet-dead-letter|tid=${tid}|reason=orphaned-after-max-restarts"
        echo "fleet_reconcile: ${tid} — restart cap reached (${restarts}/${max_restarts}), dead-lettered as orphaned-after-max-restarts"
        continue
      fi
      echo "fleet_reconcile: ${tid} — not restartable now (${not_restartable_reason}), left alone"
      continue
    fi

    # Append first, THEN write the restart marker. A crash between the two
    # leaves the entry queued with the marker missing — the restart count
    # under-counts by one (a bounded extra attempt) instead of the old
    # order's over-count: a marker with no entry burned a restart credit on
    # a ticket that was never actually restarted.
    local entry
    entry=$(_reconcile_entry "$tid" "orphan-reconciliation" "$state_dir")
    if _fleet_queue_append "$entry" "$queue_file"; then
      # Restart marker on the ticket's own pipeline log — same marker the
      # live-reap path writes, so both count toward the same cap.
      _log_pipeline "$log_file" "META" "fleet-restart" "info" "restart orphan-reconciliation"
      echo "fleet_reconcile: ${tid} — incomplete, re-enqueued"
    else
      echo "fleet_reconcile: ${tid} — re-enqueue failed, dead-lettered by queue append"
    fi
  done

  return 0
}
