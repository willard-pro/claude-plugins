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
#
# The pattern is ANCHORED at the tid's right edge (`[^0-9]|$`): pgrep -f is
# an ERE substring match, so an unanchored `ticket-auto CRE-7` would also
# match a live CRE-70/CRE-700 worker and count the dead CRE-7 pipeline as
# live — permanently consuming a capacity slot and suppressing its resume.
_fleet_tid_live() {
  local tid="$1"
  command -v pgrep >/dev/null 2>&1 || return 1
  pgrep -f "ticket-auto ${tid}([^0-9]|$)" >/dev/null 2>&1
}

# fleet_ticket_terminal_state <TICKET_ID> <pipeline_log_path>
# Classifies a ticket's state from its pipeline log alone. Cheap and
# read-only: no Linear, no gh, no log mutation.
#
# Emits exactly one of:
#   done         — genuine completion, or a dead-letter (retries exhausted).
#                  Never reconsidered by any caller, in any scope.
#   gate-held    — held for human approval with no later resolving event
#   gate-stopped — halted by a structural gate whose underlying condition
#                  (acceptance criteria, Linear labels/state, a missing
#                  template, ...) may since have been fixed by a human.
#                  Distinct from done precisely so the caller can offer it
#                  another chance; whether it actually gets one is the
#                  caller's decision (see fleet_reconcile_orphans, which
#                  retries it only under an explicit epic scope).
#   incomplete   — none of the above: the pipeline was interrupted mid-flight
#
# Three independent routes reach gate-stopped, and they must agree:
#   1. An outcome message containing "stopped: gate-stop" — pipeline-finalize.sh
#      writes this as the log's last line on essentially every gate-stop exit,
#      so this is the PRIMARY real-world trigger, not the grep in route 3.
#   2. A "stopped: fleet-kill" outcome over a log that also carries a
#      gate-stop marker (gate-stopped first, killed after).
#   3. A bare |META|gate-stop|fail| marker anywhere, when no outcome line was
#      ever written — i.e. the process died before pipeline-finalize.sh ran.
#      Narrower than it looks: only crashed/killed runs land here.
#
# Exit code is always 0 (classification is a value, not a failure signal);
# a missing/empty log classifies as incomplete so the caller decides.
#
# The Python mirror _log_reached_terminal (fleetd/supervisor.py) must agree
# with this function; it has the same three routes. Change both together.
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
    *"stopped: fleet-kill"*)
      # fleet_kill_pipeline (fleet-intervene.sh) writes this outcome after a
      # verified kill. A plain kill is a pause — kill is the pause, the
      # stop-file pin is the stop — so it classifies incomplete and resumes
      # freely. A kill over a log that ALSO carries a gate-stop is a
      # different animal: the gate is real and an unscoped resume would walk
      # straight back into it, so it classifies gate-stopped instead —
      # retriable, but only under an explicit epic scope.
      # The grep must live inside this arm: the one below runs after the
      # whole outcome branch, so a gate-stopped-then-killed pipeline (log
      # ends with the kill outcome) would otherwise never reach it and would
      # resume as if nothing structural had happened.
      if command grep -q '|META|gate-stop|fail|' "$log_file" 2>/dev/null; then
        echo "gate-stopped"
        return 0
      fi
      echo "incomplete"
      return 0
      ;;
    *"stopped: gate-stop"*)
      # The normal, clean exit from any of the 14 gate-stop codes:
      # pipeline-finalize.sh derives this message from the gate-stop marker
      # and writes it as the log's last line. This arm — not the marker grep
      # below — is what fires for essentially all real gate-stop traffic,
      # because this outcome branch returns before that grep is reached.
      # The condition behind the code may since have been fixed, so this is
      # gate-stopped, not done.
      echo "gate-stopped"
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

  # A dead-letter marker as the last line is terminal: the ticket was
  # surfaced for a human rather than lost. Classifying it done keeps
  # reconciliation idempotent across restarts (no duplicate dead-letter
  # entries, no re-enqueue of a permanently-stuck ticket).
  #
  # This MUST be checked before the gate-stop marker grep below. A ticket
  # that gate-stopped, was retried to the restart cap and then dead-lettered
  # carries BOTH markers; if the grep won, it would classify gate-stopped,
  # become retry-eligible again under scope, and loop past its own cap —
  # re-dead-lettering on every scoped resume. Dead-letter is the later,
  # stronger fact: retries are already exhausted.
  if [ "$last_step" = "dead-letter" ]; then
    echo "done"
    return 0
  fi

  # A gate-stop marker with no outcome line above it: the process died
  # before pipeline-finalize.sh could finalize (killed/crashed mid-run).
  # The gate is structural, but its condition may since have been fixed —
  # gate-stopped, not done, so an explicitly-scoped resume can retry it.
  if command grep -q '|META|gate-stop|fail|' "$log_file" 2>/dev/null; then
    echo "gate-stopped"
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
# Environment controls (all optional — unset = the startup path's behavior):
#   FLEET_RECONCILE_TIDS     space-separated tid scope; non-empty limits the
#                            scan to exactly these tids (dispatch sets it to an
#                            epic's children), empty scans every pipeline log
#   FLEET_RECONCILE_EPIC     epic id for reason naming — entry reason becomes
#                            `campaign-resume from {epic}` instead of
#                            `orphan-reconciliation`
#   FLEET_RECONCILE_DRY_RUN  non-empty (and not "0"/"false") = dry run: print
#                            would-resume/would-dead-letter lines, write
#                            nothing (no queue append, no restart marker, no
#                            dead-letter entry)
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

  # Campaign-scope controls — see the header comment. Read once, up front, so
  # per-ticket evaluation never re-reads the environment. Newlines are
  # normalized to spaces: dispatch passes jq -r output (newline-separated),
  # and the word-boundary match below is space-delimited. The trim is
  # load-bearing: an empty env must stay empty (`echo "" | tr` would turn
  # the echo's own newline into a space and enable the scope filter with a
  # blank list, silently filtering everything).
  local reconcile_tids="${FLEET_RECONCILE_TIDS:-}"
  reconcile_tids=$(echo "$reconcile_tids" | tr '\n' ' ' | sed 's/^ *//;s/ *$//')
  local reconcile_epic="${FLEET_RECONCILE_EPIC:-}"
  local dry_run=0
  if [ -n "${FLEET_RECONCILE_DRY_RUN:-}" ] && [ "$FLEET_RECONCILE_DRY_RUN" != "0" ] && [ "$FLEET_RECONCILE_DRY_RUN" != "false" ]; then
    dry_run=1
  fi
  local reason="orphan-reconciliation"
  [ -n "$reconcile_epic" ] && reason="campaign-resume from ${reconcile_epic}"

  local log_file tid state
  for log_file in "$state_dir"/*-pipeline.log; do
    [ -f "$log_file" ] || continue
    tid=$(basename "$log_file" | sed 's/-pipeline.log$//')
    [ -z "$tid" ] && continue

    # Campaign-scope filter: when a tid list is given, only those tids are
    # considered (word-boundary match against the space-padded string). An
    # empty list keeps the startup path's global scan.
    if [ -n "$reconcile_tids" ]; then
      case " $reconcile_tids " in
      *" $tid "*) ;;
      *) continue ;;
      esac
    fi

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
    # Retry eligibility. `incomplete` (crashed/interrupted mid-flight) is
    # always eligible. `gate-stopped` and `gate-held` are eligible only
    # under an explicit epic scope — i.e. a human ran
    # `fleet-dispatch.sh <EPIC> --resume` — because their conditions are
    # fixed OUTSIDE the pipeline (acceptance criteria edited, the `approved`
    # label added) and only a human knows when that has happened. The
    # passive startup scan must never spend restart credits or kick off
    # implementation on its own initiative, so it keeps leaving both alone.
    #
    # `done` is never eligible in either scope: it means genuine completion
    # or an already-exhausted dead-letter. Both are permanent.
    #
    # No live re-verification happens here by design — a re-enqueued ticket
    # runs `ticket-auto`, whose own gate-check/detect-resume re-reads the
    # live condition. Fleet only decides whether to grant another attempt.
    case "$state" in
    incomplete) ;;
    gate-stopped | gate-held)
      if [ -z "$reconcile_epic" ]; then
        echo "fleet_reconcile: ${tid} — ${state}, left alone (no epic scope)"
        continue
      fi
      ;;
    *)
      echo "fleet_reconcile: ${tid} — ${state}, left alone"
      continue
      ;;
    esac

    # Cap via the existing restart mechanism — no second counting scheme.
    # The reason string is captured and surfaced: a silent skip is how a
    # disabled auto-restart gate goes unnoticed in production.
    local not_restartable_reason
    if ! not_restartable_reason=$(fleet_can_restart "$tid" "$state_dir" 2>&1); then
      local restarts max_restarts
      restarts=$(_count_restarts "$log_file")
      max_restarts="${FLEET_MAX_RESTARTS:-2}"
      if [ "${restarts:-0}" -ge "$max_restarts" ]; then
        if [ "$dry_run" = "1" ]; then
          echo "[DRY-RUN] would dead-letter ${tid} (restart cap)"
          continue
        fi
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

    # Dry run: report the intent, write nothing — no queue append, no
    # restart marker, no dead-letter entry. The queue and the restart cap
    # must be byte-identical after a dry-run pass.
    if [ "$dry_run" = "1" ]; then
      echo "[DRY-RUN] would resume ${tid}"
      continue
    fi

    # Append first, THEN write the restart marker. A crash between the two
    # leaves the entry queued with the marker missing — the restart count
    # under-counts by one (a bounded extra attempt) instead of the old
    # order's over-count: a marker with no entry burned a restart credit on
    # a ticket that was never actually restarted.
    local entry
    entry=$(_reconcile_entry "$tid" "$reason" "$state_dir")
    if _fleet_queue_append "$entry" "$queue_file"; then
      # Restart marker on the ticket's own pipeline log — same marker the
      # live-reap path writes, so both count toward the same cap.
      _log_pipeline "$log_file" "META" "fleet-restart" "info" "restart ${reason}"
      echo "  resumed ${tid}"
    else
      echo "fleet_reconcile: ${tid} — re-enqueue failed, dead-lettered by queue append"
    fi
  done

  return 0
}
