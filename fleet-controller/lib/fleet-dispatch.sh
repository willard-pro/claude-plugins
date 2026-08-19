#!/usr/bin/env bash
# Fleet dispatch script — enqueues planned child tickets from initiative epics.
#
# Reads an initiative epic from Linear, validates state:execution label,
# finds child tickets with planned label in Backlog state, resolves
# blocked-by dependencies, and writes to the spawn queue JSONL for
# consumption by fleet-monitor.sh.
#
# NOTE: Does NOT set -euo pipefail — this is a sourceable library.
# Callers are responsible for shell flags.

# ── GraphQL query helper (overridable for tests) ──────────────────────────────
# Wraps curl call to Linear GraphQL API. Extracted as a function so tests can
# mock it without overriding curl globally.
_fleet_linear_query() {
  local query="$1"
  curl -s -X POST "${LINEAR_API_URL:-https://api.linear.app/graphql}" \
    -H "Content-Type: application/json" \
    -H "Authorization: ${LINEAR_API_KEY}" \
    -d "$query" 2>/dev/null
}

_DISPATCH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source config for state-directory resolver (used for queue path construction)
if [ -f "$_DISPATCH_DIR/fleet-config.sh" ]; then
  source "$_DISPATCH_DIR/fleet-config.sh"
fi

# Source linear-api.sh from canonical path (synced by ticket-auto-pipeline SessionStart hook)
if ! declare -f get_issue >/dev/null 2>&1; then
  for _lp in "$HOME/.claude/skills/lib/linear-api.sh" "$_DISPATCH_DIR/../ticket-auto-pipeline/lib/linear-api.sh"; do
    [ -f "$_lp" ] && source "$_lp" && break
  done
fi

# Source epic-branch.sh and its transitive deps for epic branch lifecycle ops.
# planned-ticket-check.sh → branch-directive-check.sh → epic-branch.sh.
# Two candidate locations: the monorepo checkout (../../) and the installed
# plugin layout, where the ticket-auto-pipeline SessionStart hook syncs its
# libs to ~/.claude/skills/lib. Without the second, dispatch silently skips
# the epic branch precondition in installed deployments.
for _TAP_LIB in "$_DISPATCH_DIR/../../ticket-auto-pipeline/lib" "$HOME/.claude/skills/lib"; do
  if declare -f ensure_epic_branch >/dev/null 2>&1; then
    break
  fi
  [ -f "$_TAP_LIB/planned-ticket-check.sh" ] && source "$_TAP_LIB/planned-ticket-check.sh"
  [ -f "$_TAP_LIB/branch-directive-check.sh" ] && source "$_TAP_LIB/branch-directive-check.sh"
  [ -f "$_TAP_LIB/epic-branch.sh" ] && source "$_TAP_LIB/epic-branch.sh"
done

# Source fleet-intervene.sh for fleet_kill_pipeline (fleet_stop_initiative's
# verified escalation). Conditional — the stop path must degrade with a clear
# warning rather than fail to source in a stripped environment.
if ! declare -f fleet_kill_pipeline >/dev/null 2>&1; then
  [ -f "$_DISPATCH_DIR/fleet-intervene.sh" ] && source "$_DISPATCH_DIR/fleet-intervene.sh"
fi

# ── Helpers ──────────────────────────────────────────────────────────────────────

# Check if a ticket is already in the spawn queue.
# Args: tid, queue_file
# Line-by-line jq parse: a torn/corrupt append must NOT false-match. The old
# substring grep matched the tid inside a torn JSON line and skipped the
# ticket forever — fleetd also skips malformed lines, so a torn line meant
# the ticket was neither spawned nor re-enqueued, ever. Valid JSON only.
_queue_has_ticket() {
  local tid="$1"
  local queue_file="$2"
  [ ! -f "$queue_file" ] && return 1
  local line
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    if echo "$line" | jq -e --arg tid "$tid" '.tid == $tid' >/dev/null 2>&1; then
      return 0
    fi
  done <"$queue_file"
  return 1
}

# _registry_pid_alive <tid> <workspace>
# Returns 0 when the ticket's run-registry entry carries a PID that is
# actually alive (kill -0). Covers workers the pgrep cmdline pattern misses
# (pid-reused processes, monitor-spawned workers). Sentinel 0, empty, and
# missing entries are NOT evidence of a live worker — they are stale state.
_registry_pid_alive() {
  local tid="$1" workspace="$2"
  local run_file run_pid
  run_file=$(_fleet_run_file "$tid" "$workspace")
  [ -f "$run_file" ] || return 1
  run_pid=$(jq -r '.pid // empty' "$run_file" 2>/dev/null)
  [ -z "$run_pid" ] || [ "$run_pid" = "0" ] && return 1
  kill -0 "$run_pid" 2>/dev/null
}

# Count LIVE pipelines only: a pipeline log without an outcome line whose
# worker is pgrep-live or run-registry-alive. A dead log with no live worker
# must not consume a FLEET_MAX_CONCURRENT slot — counting every no-outcome
# log permanently jammed the campaign after a kill. Shared by dispatch's
# Step 4 and the monitor loop's consume slot math so fleetd and the monitor
# agree on capacity.
# Args: workspace
_active_pipeline_count() {
  local workspace="${1:-${FLEET_PIPELINE_LOG_DIR:-./logs}}"
  local count=0
  if [ -d "$workspace" ]; then
    local log_file tid
    for log_file in "$workspace"/*-pipeline.log; do
      [ -f "$log_file" ] || continue
      command grep -q '|META|outcome|' "$log_file" 2>/dev/null && continue
      tid=$(basename "$log_file" | sed 's/-pipeline.log$//')
      if _fleet_tid_live "$tid" || _registry_pid_alive "$tid" "$workspace"; then
        count=$((count + 1))
      fi
    done
  fi
  echo "$count"
}

# _fleet_queued_count_for_epic <workspace> <epic_id>
# Counts pending queue entries whose reason names this epic — dispatch or
# campaign-resume. Torn-line-safe (same per-line jq idiom as
# _queue_has_ticket): a corrupt append can neither false-match nor
# false-count. Dispatch's Step 4 reserves these slots so a re-dispatch does
# not over-enqueue past FLEET_MAX_CONCURRENT.
_fleet_queued_count_for_epic() {
  local workspace="$1" epic_id="$2"
  local queue_file count=0 line entry entry_reason
  queue_file=$(_fleet_queue_file "$workspace")
  [ ! -f "$queue_file" ] && {
    echo "0"
    return 0
  }
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    entry=$(echo "$line" | jq -c . 2>/dev/null) || continue
    entry_reason=$(echo "$entry" | jq -r '.reason // empty' 2>/dev/null)
    if echo "$entry_reason" | grep -qE "(planned-dispatch|campaign-resume) from ${epic_id}( |$)"; then
      count=$((count + 1))
    fi
  done <"$queue_file"
  echo "$count"
}

# _fleet_dispatch_rank <priority>
# Maps a Linear priority value to an explicit dispatch rank for ordering:
# Urgent(1)→1, High(2)→2, Medium(3)→3, Low(4)→4, No priority(0) and any
# unexpected value→5 (sorted last, never ahead of Urgent).
_fleet_dispatch_rank() {
  case "$1" in
  1) echo "1" ;;
  2) echo "2" ;;
  3) echo "3" ;;
  4) echo "4" ;;
  *) echo "5" ;;
  esac
}

# _fleet_repos_under_root [root]
# Emits one path per line: REPOS_ROOT itself when it is a git repo (single-repo
# workspace), plus every direct child directory that is a working git repo.
# Bare repositories are excluded — children build in working clones, and
# running branch creation against a stray bare repo (no origin remote, no
# working tree) would fail and gate-stop dispatch for unrelated layouts.
# Shared by dispatch's epic-branch precondition and the epic-branch-readiness
# detector so both cover the same repository set — the detector must not
# re-guess a different set than dispatch created branches in.
_fleet_repos_under_root() {
  local root="${1:-${EPIC_REPO_PATH:-${REPOS_ROOT:-.}}}"
  local _erd

  _fleet_is_worktree_repo() {
    local d="$1"
    { [ -d "$d/.git" ] || git -C "$d" rev-parse --git-dir >/dev/null 2>&1; } &&
      [ "$(git -C "$d" rev-parse --is-bare-repository 2>/dev/null)" = "false" ]
  }

  if _fleet_is_worktree_repo "$root"; then
    echo "$root"
  fi
  for _erd in "$root"/*/; do
    [ -d "$_erd" ] || continue
    if _fleet_is_worktree_repo "$_erd"; then
      echo "$_erd"
    fi
  done
}

# _fleet_queue_append <entry_json> <queue_file> [dead_letter_reason]
# Shared spawn-queue append: flock-protected write with bounded retry and
# exponential backoff; dead-letters the entry when all attempts are exhausted.
# Single canonical implementation — both the normal dispatch enqueue path and
# fleetd startup reconciliation MUST append through this function.
#
# On dead-lettering, emits a structured, greppable line
#   fleet-dead-letter|tid=<TID>|reason=<REASON>
# so a permanently-stuck ticket is surfaced rather than sitting silently on
# disk (the tickets workspace's status-reporting convention scans for it).
#
# Exit codes:
#   0 — entry appended to the queue
#   1 — entry dead-lettered (queue unavailable after all retries)
_fleet_queue_append() {
  local entry="$1"
  local queue_file="$2"
  local dead_letter_reason="${3:-queue-contention-exhausted}"

  # Bounded retry with backoff for queue append. A single flock timeout
  # does not mean the queue is permanently unavailable — the monitor may
  # be mid-rewrite. Retry with backoff; dead-letter entries that exhaust
  # all attempts so nothing is silently lost.
  local lock_file="${queue_file}.lock"
  local lock_timeout="${FLEET_QUEUE_LOCK_TIMEOUT:-5}"
  local max_retries="${FLEET_QUEUE_MAX_RETRIES:-3}"
  local backoff_secs="${FLEET_QUEUE_RETRY_BACKOFF_SECS:-2}"
  local attempt=0

  while [ "$attempt" -lt "$max_retries" ]; do
    attempt=$((attempt + 1))
    if (
      flock -w "$lock_timeout" 9 2>/dev/null || exit 1
      echo "$entry" >>"$queue_file"
    ) 9>"$lock_file"; then
      return 0
    fi
    if [ "$attempt" -lt "$max_retries" ]; then
      sleep "$backoff_secs"
      # Use bc for multiplication to support fractional backoff values
      # (bash $(( )) is integer-only). Fall back to integer arithmetic if
      # bc is unavailable in a stripped environment.
      if command -v bc >/dev/null 2>&1; then
        backoff_secs=$(echo "$backoff_secs * 2" | bc)
      else
        backoff_secs=$((backoff_secs * 2))
      fi
    fi
  done

  # Dead-letter: write to a separate file so the entry is not lost.
  # The dead-letter file is human-readable and replayable.
  local dead_letter_file="${queue_file%.jsonl}-dead-letter.jsonl"
  echo "$entry" >>"$dead_letter_file"

  # Structured notification — greppable, names the ticket and the reason.
  local _dl_tid
  _dl_tid=$(echo "$entry" | jq -r '.tid // empty' 2>/dev/null)
  echo "fleet-dead-letter|tid=${_dl_tid}|reason=${dead_letter_reason}"
  return 1
}

# Source fleet-reconcile.sh for the campaign-resume hook (Step 1.75) and its
# kill-aware terminal classifier. Deliberately placed AFTER _fleet_queue_append:
# fleet-reconcile.sh conditionally sources fleet-dispatch.sh when
# _fleet_queue_append is undefined, so sourcing it earlier (in the prologue
# source block) would re-enter this file mid-source and recurse. All of
# fleet-reconcile.sh's own sources are declare -f-guarded, so this closes the
# cycle without re-executing anything.
if ! declare -f fleet_reconcile_orphans >/dev/null 2>&1; then
  [ -f "$_DISPATCH_DIR/fleet-reconcile.sh" ] && source "$_DISPATCH_DIR/fleet-reconcile.sh"
fi

# ── Stop-file helpers (fleet-epic-stop) ──────────────────────────────────────────
# {state_dir}/stop-{epic}.json gates every dispatch trigger path for that epic
# until an explicit resume clears it. The path constructor lives in
# fleet-config.sh (_fleet_epic_stop_file) alongside every other state-path
# constructor; the read/write/clear helpers live here with their only
# consumers (dispatch and stop).

# Exit 0 when the epic has a stop-file. Usage: _fleet_is_stopped <workspace> <epic_id>
_fleet_is_stopped() {
  local workspace="$1" epic_id="$2"
  [ -f "$(_fleet_epic_stop_file "$workspace" "$epic_id")" ]
}

# Write the stop-file. Usage: _fleet_stop_write <workspace> <epic_id> <tickets_json> <reason>
_fleet_stop_write() {
  local workspace="$1" epic_id="$2" tickets_json="$3" reason="${4:-}"
  jq -nc \
    --arg initiative_id "$epic_id" \
    --arg stopped_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg reason "$reason" \
    --argjson tickets "$tickets_json" \
    '{initiative_id: $initiative_id, stopped_at: $stopped_at, reason: $reason, tickets: $tickets}' \
    >"$(_fleet_epic_stop_file "$workspace" "$epic_id")"
}

# Clear the stop-file — explicit resume only, never the auto-sweep.
# Usage: _fleet_stop_clear <workspace> <epic_id>
_fleet_stop_clear() {
  local workspace="$1" epic_id="$2"
  rm -f "$(_fleet_epic_stop_file "$workspace" "$epic_id")"
}

# ── fleet_dispatch_initiative ────────────────────────────────────────────────────
# Main entry point: dispatch planned child tickets from an initiative epic.
# Usage: fleet_dispatch_initiative <initiative_id> [workspace] [--resume]
#
# Runs under an epic-scoped flock ({queue_file}.{epic}.dispatch.lock) so the
# check-then-append sequence is atomic across processes (skill session,
# fleetd HTTP handler, auto-sweep). --resume clears the epic's stop-file
# before scanning; without it a stopped epic early-exits with a message.
fleet_dispatch_initiative() {
  local initiative_id="$1"
  local workspace="${FLEET_PIPELINE_LOG_DIR:-./logs}"
  local resume=false
  local arg
  for arg in "${@:2}"; do
    case "$arg" in
    --resume) resume=true ;;
    *) workspace="$arg" ;;
    esac
  done

  if [ -z "$initiative_id" ]; then
    echo "ERROR: initiative_id required" >&2
    echo "Usage: fleet_dispatch_initiative <INITIATIVE_ID> [workspace] [--resume]" >&2
    return 1
  fi

  local queue_file lock_file
  queue_file=$(_fleet_queue_file "$workspace")
  lock_file="${queue_file}.${initiative_id}.dispatch.lock"
  # The subshell scopes the flock fd — every exit path of the locked body
  # (including its `return`s) closes fd 9 and releases the lock.
  # `command flock` (not bare `flock`): test suites mock the flock function
  # to simulate queue-append contention; the epic lock must keep its real
  # serialization regardless.
  (
    if ! command flock -w "${FLEET_DISPATCH_LOCK_TIMEOUT:-5}" 9; then
      echo "ERROR: dispatch lock busy for ${initiative_id} after ${FLEET_DISPATCH_LOCK_TIMEOUT:-5}s" >&2
      exit 1
    fi
    _fleet_dispatch_initiative_locked "$initiative_id" "$workspace" "$resume"
  ) 9>"$lock_file"
}

_fleet_dispatch_initiative_locked() {
  local initiative_id="$1"
  local workspace="${2:-${FLEET_PIPELINE_LOG_DIR:-./logs}}"
  local resume="${3:-false}"
  local queue_file
  queue_file=$(_fleet_queue_file "$workspace")
  local max_concurrent="${FLEET_MAX_CONCURRENT:-3}"
  local dry_run="${FLEET_DRY_RUN:-false}"
  local resume_count=0 blocked_count=0 enqueued=0

  if [ -z "$initiative_id" ]; then
    echo "ERROR: initiative_id required" >&2
    echo "Usage: fleet_dispatch_initiative <INITIATIVE_ID> [workspace] [--resume]" >&2
    return 1
  fi

  # Stop-file gate: only an explicit resume clears it. The auto-sweep never
  # passes --resume, so a stopped epic stays stopped across sweep cycles.
  if [ "$resume" = "true" ]; then
    if _fleet_is_stopped "$workspace" "$initiative_id"; then
      _fleet_stop_clear "$workspace" "$initiative_id"
      echo "stop-file cleared for ${initiative_id} — resuming dispatch"
    fi
  elif _fleet_is_stopped "$workspace" "$initiative_id"; then
    echo "initiative ${initiative_id} is stopped (stop-${initiative_id}.json present) — dispatch skipped; use --resume to un-stop"
    return 0
  fi

  # The epic query uses _fleet_linear_query (direct curl, no linear-api.sh dependency).
  # Blocker resolution uses get_issue (from linear-api.sh) if available — degrades
  # gracefully when unavailable, treating all blockers as unresolved.
  if ! declare -f get_issue >/dev/null 2>&1; then
    echo "fleet_dispatch: linear-api.sh not available — blocker resolution will skip" >&2
  fi

  # Step 1: Validate initiative epic exists and has state:execution label.
  # Use a direct GraphQL query (not get_issue) to include children in one round-trip.
  echo "fleet_dispatch: validating initiative ${initiative_id}..."
  local epic_query epic_resp epic_json
  epic_query=$(jq -n --arg id "$initiative_id" '{
    query: "query($id: String!) { issue(id: $id) { id identifier title description state { name } labels { nodes { name } } children { nodes { id identifier title state { name } labels { nodes { name } } priority } } } }",
    variables: {id: $id}
  }')
  epic_resp=$(_fleet_linear_query "$epic_query") || {
    echo "ERROR: initiative ${initiative_id} query failed" >&2
    return 1
  }
  epic_json=$(echo "$epic_resp" | jq '.data.issue // empty' 2>/dev/null)
  if [ -z "$epic_json" ] || [ "$epic_json" = "null" ]; then
    echo "ERROR: initiative ${initiative_id} not found in Linear" >&2
    return 1
  fi

  local epic_labels
  epic_labels=$(echo "$epic_json" | jq -r '.labels.nodes[]?.name // empty' 2>/dev/null)
  if ! echo "$epic_labels" | grep -q "state:execution"; then
    echo "initiative ${initiative_id} not in execution state (missing state:execution label)"
    return 0
  fi

  echo "fleet_dispatch: initiative ${initiative_id} validated (state:execution)"

  # Step 1.5: Epic branch precondition — ensure the declared branch exists
  # and sync it with its base before any child ticket needs it, in every
  # repository under REPOS_ROOT. Only meaningful when the epic carries a
  # Branch Directive; no-op otherwise (ensure_epic_branch exits 0 for that).
  if ! declare -f ensure_epic_branch >/dev/null 2>&1; then
    echo "fleet_dispatch: WARNING: epic-branch.sh not sourceable — epic branch precondition skipped (children may enqueue against an uncreated branch)" >&2
  else
    # Enumerate every git repo to cover: REPOS_ROOT itself (single-repo
    # workspace) plus every direct child directory that is a git repo.
    # Deliberate over-approximation — dispatch has no structured source for
    # which repos an epic's children touch, and branch creation is idempotent.
    local _epic_repos
    _epic_repos=$(_fleet_repos_under_root)

    # Sync: integrate base changes into the epic branch per the directive's policy.
    # Sync failure warns but does not block dispatch — children still enqueue.
    local epic_sync_enabled="${FLEET_EPIC_BRANCH_SYNC:-true}"

    while IFS= read -r _epic_repo; do
      [ -z "$_epic_repo" ] && continue

      # Creation failure in any one repo gate-stops the whole initiative —
      # enqueueing children at a base that does not exist somewhere would turn
      # one clear failure into one failure per child.
      if ! ensure_epic_branch "$initiative_id" "$_epic_repo"; then
        echo "EPIC_BRANCH_UNAVAILABLE: initiative ${initiative_id} — cannot ensure epic branch in ${_epic_repo}, skipping dispatch" >&2
        return 0
      fi

      # A sync failure in one repo is reported and does not block syncing the
      # remaining repos, nor dispatch of ready children.
      if [ "$epic_sync_enabled" = "true" ]; then
        epic_branch_sync "$initiative_id" "$_epic_repo" || {
          echo "fleet_dispatch: sync warning for ${initiative_id} in ${_epic_repo} — continuing with dispatch" >&2
        }
      fi
    done <<<"$_epic_repos"
  fi

  # Step 1.75: Campaign reconcile — resume dead/incomplete child pipelines
  # before enumerating the next wave. ALL children participate (a mid-flight
  # child is not in Backlog), and classification is log-based. Runs inside
  # the epic flock: reconcile appends via _fleet_queue_append (queue lock),
  # and the epic→queue lock ordering matches fleet_stop_initiative's purge,
  # so no deadlock. The stop-file gate above guarantees a stopped epic never
  # reaches here. Scoped through FLEET_RECONCILE_TIDS/EPIC/DRY_RUN, so the
  # fleetd startup path (no envs) is untouched.
  local child_tids reconcile_out
  child_tids=$(echo "$epic_json" | jq -r '.children.nodes[]?.identifier // empty' 2>/dev/null)
  if [ -n "$child_tids" ] && declare -f fleet_reconcile_orphans >/dev/null 2>&1; then
    echo "fleet_dispatch: reconciling children of ${initiative_id}..."
    reconcile_out=$(
      FLEET_RECONCILE_TIDS="$child_tids" \
        FLEET_RECONCILE_EPIC="$initiative_id" \
        FLEET_RECONCILE_DRY_RUN="$dry_run" \
        fleet_reconcile_orphans "$workspace" "$queue_file" ""
    )
    echo "$reconcile_out"
    if [ "$dry_run" = "true" ]; then
      resume_count=$(echo "$reconcile_out" | grep -c 'would resume' || true)
    else
      resume_count=$(echo "$reconcile_out" | grep -c '^  resumed ' || true)
    fi
  elif declare -f fleet_reconcile_orphans >/dev/null 2>&1; then
    echo "fleet_dispatch: no children to reconcile for ${initiative_id}"
  fi

  # Step 2: Find child tickets with planned label + Backlog state
  echo "fleet_dispatch: enumerating child tickets..."
  local children_json
  children_json=$(echo "$epic_json" | jq -c '.children.nodes[] // empty' 2>/dev/null)
  if [ -z "$children_json" ]; then
    echo "no child tickets found for ${initiative_id}"
    return 0
  fi

  # Collect dispatchable tickets
  local dispatchable=""
  while IFS= read -r child; do
    [ -z "$child" ] && continue
    local child_id child_state child_labels
    child_id=$(echo "$child" | jq -r '.identifier // empty')
    child_state=$(echo "$child" | jq -r '.state.name // empty')
    child_labels=$(echo "$child" | jq -r '.labels.nodes[]?.name // empty' 2>/dev/null)

    # Must have planned label AND Backlog state
    if [ "$child_state" != "Backlog" ]; then
      continue
    fi
    if ! echo "$child_labels" | grep -q "planned"; then
      continue
    fi

    echo "  checking ${child_id} (planned, Backlog)..."

    # Step 3: Resolve blocked-by dependencies
    local blocked_labels
    blocked_labels=$(echo "$child_labels" | grep -oP 'blocked-by:\K[A-Z]+-\d+' || true)
    local is_blocked=false

    for blocker_id in $blocked_labels; do
      [ -z "$blocker_id" ] && continue
      local blocker_json blocker_state
      if blocker_json=$(get_issue "$blocker_id" 2>/dev/null); then
        blocker_state=$(echo "$blocker_json" | jq -r '.state.name // empty' 2>/dev/null)
        if [ "$blocker_state" != "Done" ]; then
          echo "    blocked by ${blocker_id} (state: ${blocker_state}) — skipping"
          is_blocked=true
          break
        else
          echo "    blocked-by ${blocker_id} resolved (Done)"
        fi
      fi
    done

    if [ "$is_blocked" = "true" ]; then
      blocked_count=$((blocked_count + 1))
      echo "  blocked ${child_id}"
      continue
    fi

    # Get priority and map it to an explicit dispatch rank. Raw-value sorting
    # is wrong in both directions: descending puts Low (4) before Urgent (1);
    # ascending puts No priority (0) before Urgent (1). The rank mapping
    # fixes the semantic: Urgent(1)→1, High(2)→2, Medium(3)→3, Low(4)→4,
    # No priority(0)/anything unexpected→5.
    local priority rank
    priority=$(echo "$child" | jq -r '.priority // 0' 2>/dev/null)
    [ -z "$priority" ] && priority=0
    rank=$(_fleet_dispatch_rank "$priority")

    dispatchable="${dispatchable}${rank}|${child_id}|${priority}"$'\n'
  done <<<"$children_json"

  # Sort ascending on the mapped dispatch rank (Urgent first, No priority last)
  local sorted
  sorted=$(echo "$dispatchable" | sort -t'|' -k1 -n | grep -v '^$' || true)
  if [ -z "$sorted" ]; then
    # All children were skipped by blocked-by resolution (or filtered out) —
    # the summary makes that visible instead of a silent "no dispatchable
    # tickets" when nothing was actually resumable either.
    if [ "$blocked_count" -gt 0 ] || [ "$resume_count" -gt 0 ]; then
      if [ "$dry_run" = "true" ]; then
        echo "[DRY-RUN] would resume ${resume_count} | blocked ${blocked_count} | would enqueue 0 ticket(s) for ${initiative_id}"
      else
        echo "fleet_dispatch: resumed ${resume_count} | blocked ${blocked_count} | enqueued 0 ticket(s) for ${initiative_id}"
      fi
    else
      echo "no dispatchable tickets for ${initiative_id}"
    fi
    return 0
  fi

  # Step 4: Enforce FLEET_MAX_CONCURRENT. Capacity counts live pipelines
  # only (dead logs must not jam the campaign) and reserves slots for this
  # epic's own pending queue entries — resume entries were appended first
  # (FIFO) and consume enforces the hard cap at spawn.
  local active_count queued_for_epic max_to_enqueue
  active_count=$(_active_pipeline_count "$workspace")
  queued_for_epic=$(_fleet_queued_count_for_epic "$workspace" "$initiative_id")
  max_to_enqueue=$((max_concurrent - active_count - queued_for_epic))
  [ "$max_to_enqueue" -le 0 ] && echo "fleet_dispatch: at capacity (${active_count}/${max_concurrent} active, ${queued_for_epic} queued for ${initiative_id})" && return 0

  echo "fleet_dispatch: ${active_count}/${max_concurrent} active (${queued_for_epic} queued for ${initiative_id}), can enqueue up to ${max_to_enqueue}"

  # Step 5: Write spawn queue
  while IFS='|' read -r rank child_id priority; do
    [ -z "$child_id" ] && continue
    [ "$enqueued" -ge "$max_to_enqueue" ] && break

    # Idempotency: skip if already in queue
    if _queue_has_ticket "$child_id" "$queue_file"; then
      echo "  skip ${child_id} (already queued)"
      continue
    fi

    local entry
    entry=$(jq -nc \
      --arg tid "$child_id" \
      --arg reason "planned-dispatch from ${initiative_id}" \
      --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      --argjson restarts 0 \
      --argjson generation 1 \
      --arg dispatch_type "initial" \
      '{tid: $tid, reason: $reason, timestamp: $timestamp, restarts: $restarts, dispatch_type: $dispatch_type, generation: $generation}')

    if [ "$dry_run" = "true" ]; then
      echo "[DRY-RUN] would enqueue: ${entry}"
    elif _fleet_queue_append "$entry" "$queue_file"; then
      echo "  enqueued ${child_id} (priority=${priority})"
    else
      # Dead-lettered by the shared append function — the dead-letter file
      # must be manually replayed or the dispatch re-run.
      echo "  ERROR: failed to enqueue ${child_id} — dead-lettering" >&2
      echo "  dead-lettered ${child_id} → ${queue_file%.jsonl}-dead-letter.jsonl" >&2
      continue
    fi
    enqueued=$((enqueued + 1))
  done <<<"$sorted"

  # Summary is the LAST stdout line — the supervisor's dispatch_epic keeps it
  # as `message` and parses the per-tid `  resumed`/`  blocked`/`  enqueued`
  # lines above into the response arrays.
  if [ "$dry_run" = "true" ]; then
    echo "[DRY-RUN] would resume ${resume_count} | blocked ${blocked_count} | would enqueue ${enqueued} ticket(s) for ${initiative_id}"
  else
    echo "fleet_dispatch: resumed ${resume_count} | blocked ${blocked_count} | enqueued ${enqueued} ticket(s) for ${initiative_id}"
  fi

  return 0
}

# ── fleet_stop_initiative ────────────────────────────────────────────────────────
# Epic-scoped stop: purge queue entries, escalate-kill running workers, write the
# stop-file. The SINGLE stop implementation — both the /fleet-controller stop
# skill subcommand and fleetd's POST /stop shell out here. Works with the daemon
# down: workers forked into their own process groups outlive a dead fleetd.
#
# Usage: fleet_stop_initiative <epic_id> [reason] [workspace]
# Emits a final structured line:
#   STOP_RESULT|purged=<json-array>|killed=<json-array>|pinned=<json-array>
# `killed` carries ONLY tids whose workers are verified dead; `pinned` carries
# every other tid recorded for the epic (refused/unverified kills, already-dead
# workers) — the stop-file union pins both.
fleet_stop_initiative() {
  local epic_id="$1"
  local reason="${2:-}"
  local workspace="${3:-${FLEET_PIPELINE_LOG_DIR:-./logs}}"

  if [ -z "$epic_id" ]; then
    echo "ERROR: epic_id required" >&2
    echo "Usage: fleet_stop_initiative <EPIC_ID> [reason] [workspace]" >&2
    return 1
  fi

  local queue_file lock_file
  queue_file=$(_fleet_queue_file "$workspace")
  lock_file="${queue_file}.${epic_id}.dispatch.lock"
  (
    if ! command flock -w "${FLEET_DISPATCH_LOCK_TIMEOUT:-5}" 9; then
      echo "ERROR: dispatch lock busy for ${epic_id} after ${FLEET_DISPATCH_LOCK_TIMEOUT:-5}s" >&2
      exit 1
    fi
    _fleet_stop_initiative_locked "$epic_id" "$reason" "$workspace"
  ) 9>"$lock_file"
}

_fleet_stop_initiative_locked() {
  local epic_id="$1" reason="$2" workspace="$3"
  local queue_file state_dir
  queue_file=$(_fleet_queue_file "$workspace")
  state_dir=$(_fleet_state_dir "$workspace")

  # 0. Resolve the epic's children from Linear — the child tid set makes
  # purge, kill, and pin cover children whose queue was already empty at
  # stop time (the CRE-9 gap: `tickets: []` pinned nothing). A children-query
  # failure degrades with a warning and an empty set — stop never aborts on
  # a Linear outage or a missing API key; the reason/registry-derived tid
  # list still lands in the stop-file. (The API-key guard also keeps stop
  # hermetic in offline/keyless test environments — no curl to Linear.)
  local child_set="" child_tid
  local children_query children_resp children_json
  children_query=$(jq -n --arg id "$epic_id" '{
    query: "query($id: String!) { issue(id: $id) { children { nodes { identifier } } } }",
    variables: {id: $id}
  }')
  if [ -n "${LINEAR_API_KEY:-}" ]; then
    # `|| children_resp=""`: linear-api.sh sources with `set -e`, which
    # leaks into the caller shell — a failing query (curl down, mock
    # returning 1) must degrade here, never kill the stop.
    children_resp=$(_fleet_linear_query "$children_query") || children_resp=""
  fi
  if [ -z "${children_resp:-}" ] || ! echo "${children_resp:-}" | jq -e '.data.issue.children.nodes != null' >/dev/null 2>&1; then
    echo "fleet_stop: WARNING: cannot fetch children of ${epic_id} — incomplete-pipeline children not pinned" >&2
  else
    children_json=$(echo "$children_resp" | jq -r '.data.issue.children.nodes[]?.identifier // empty' 2>/dev/null)
    while IFS= read -r child_tid; do
      [ -z "$child_tid" ] && continue
      child_set="${child_set}${child_tid}"$'\n'
    done <<<"$children_json"
  fi

  # 1. Purge queue entries whose reason names this epic. Malformed lines are
  # kept untouched. Read AND rewrite both happen under the queue flock —
  # mirroring the consume-time rewrite — so an append landing mid-purge
  # (another epic's dispatch, startup reconcile) is never clobbered. The
  # flock result is checked: a busy lock aborts the stop instead of silently
  # reporting a purge that did not happen.
  local purged="[]" purged_tmp purge_rc=0
  if [ -f "$queue_file" ]; then
    purged_tmp=$(mktemp)
    (
      flock -w "${FLEET_QUEUE_LOCK_TIMEOUT:-5}" 9 || exit 1
      local kept="" line entry tid entry_reason do_purge
      while IFS= read -r line; do
        [ -z "$line" ] && continue
        if ! entry=$(echo "$line" | jq -c . 2>/dev/null); then
          kept="${kept}${line}"$'\n'
          continue
        fi
        tid=$(echo "$entry" | jq -r '.tid // empty' 2>/dev/null)
        entry_reason=$(echo "$entry" | jq -r '.reason // empty' 2>/dev/null)
        # Purge by reason (dispatch OR campaign-resume) or by child tid —
        # a resume entry must die with the stop, and a child-tid entry with
        # some other reason still belongs to this epic.
        do_purge=false
        if echo "$entry_reason" | grep -qE "(planned-dispatch|campaign-resume) from ${epic_id}( |$)"; then
          do_purge=true
        elif [ -n "$child_set" ] && echo "$child_set" | grep -qx "$tid"; then
          do_purge=true
        fi
        if [ "$do_purge" = "true" ]; then
          printf '%s\n' "$tid" >>"$purged_tmp"
          echo "  purged ${tid} from queue"
        else
          kept="${kept}${line}"$'\n'
        fi
      done <"$queue_file"
      if [ -n "$kept" ]; then
        printf '%s' "$kept" >"$queue_file"
      else
        rm -f "$queue_file"
      fi
      # `|| purge_rc=$?` (not a plain capture): linear-api.sh sources with
      # `set -e`, so a failing subshell would kill the whole caller before
      # the rc could be checked. The || form keeps the failure in a
      # condition context while still capturing the rc.
    ) 9>"${queue_file}.lock" || purge_rc=$?
    if [ "$purge_rc" -ne 0 ]; then
      rm -f "$purged_tmp"
      echo "ERROR: queue purge failed (flock rc=${purge_rc}) — stop aborted" >&2
      return 1
    fi
    if [ -s "$purged_tmp" ]; then
      purged=$(jq -R -s -c 'split("\n") | map(select(length > 0))' "$purged_tmp" 2>/dev/null || echo "[]")
    fi
    rm -f "$purged_tmp"
  fi

  # 2. Kill running workers whose run-registry reason names this epic, via
  # fleet_kill_pipeline's verified escalation. `killed` carries ONLY tids
  # verified dead; every other tid for this epic — survivors of a refused or
  # unverified kill, and workers already dead — lands in `pinned` so the
  # stop-file union pins them regardless. Reconciliation must never
  # resurrect a ticket of a stopped epic.
  local killed="[]" killed_list="" pinned="[]" pinned_list=""
  local run_file run_data run_tid run_reason run_pid
  for run_file in "${state_dir}"/*-run.json; do
    [ -f "$run_file" ] || continue
    run_data=$(cat "$run_file" 2>/dev/null || true)
    [ -z "$run_data" ] && continue
    run_tid=$(echo "$run_data" | jq -r '.tid // empty' 2>/dev/null)
    run_reason=$(echo "$run_data" | jq -r '.reason // empty' 2>/dev/null)
    run_pid=$(echo "$run_data" | jq -r '.pid // empty' 2>/dev/null)
    [ -z "$run_tid" ] && continue
    if echo "$run_reason" | grep -qE "(planned-dispatch|campaign-resume) from ${epic_id}( |$)"; then
      # Dead worker: nothing to kill, but pin it anyway — a FIRST stop must
      # record it, or restart reconciliation resurrects the ticket.
      if [ -z "$run_pid" ] || [ "$run_pid" = "0" ] || ! kill -0 "$run_pid" 2>/dev/null; then
        pinned_list="${pinned_list}${run_tid}"$'\n'
        echo "  ${run_tid} — worker pid gone, pinned (no kill needed)"
        continue
      fi
      if declare -f fleet_kill_pipeline >/dev/null 2>&1; then
        if fleet_kill_pipeline "$run_tid" "epic-stop ${epic_id}" "$workspace" >/dev/null 2>&1; then
          # fleet_kill_pipeline returns 0 even on kill-unverified (PID-reuse
          # guard declined to signal). Verify liveness so `killed` only ever
          # reports workers actually terminated; unverified survivors are
          # pinned so reconciliation cannot resurrect them.
          if kill -0 "$run_pid" 2>/dev/null; then
            pinned_list="${pinned_list}${run_tid}"$'\n'
            echo "  ${run_tid} survived escalation (kill-unverified) — pinned"
          else
            killed_list="${killed_list}${run_tid}"$'\n'
            echo "  killed ${run_tid}"
          fi
        else
          # Refused/deferred kill (flow.sh mutex held, no pipeline log, or
          # survived SIGKILL): the worker may still be running — pin it,
          # but do NOT report it as killed. The daemon keeps supervising it.
          pinned_list="${pinned_list}${run_tid}"$'\n'
          echo "  kill refused for ${run_tid} — pinned, still supervised"
        fi
      else
        pinned_list="${pinned_list}${run_tid}"$'\n'
        echo "  WARNING: fleet_kill_pipeline not available — ${run_tid} pinned without kill" >&2
      fi
    fi
  done

  # 2b. Pin every child with an incomplete pipeline log — the missing source
  # of truth that let an orphan get re-adopted after a stop with an empty
  # queue and no live workers. Classification is log-based and kill-aware
  # (kill outcomes count as resumable), so the pin must be too. Fallback
  # when the classifier is unavailable: any log without an outcome line.
  local child_log child_state
  while IFS= read -r child_tid; do
    [ -z "$child_tid" ] && continue
    child_log="${workspace}/${child_tid}-pipeline.log"
    [ -f "$child_log" ] || continue
    if declare -f fleet_ticket_terminal_state >/dev/null 2>&1; then
      child_state=$(fleet_ticket_terminal_state "$child_tid" "$child_log")
    elif command grep -q '|META|outcome|' "$child_log" 2>/dev/null; then
      # Classifier unavailable: the conservative fallback is only to pin
      # logs without ANY outcome line — a completed pipeline stays unpinned
      # (it could not resume anyway).
      continue
    else
      child_state="incomplete"
    fi
    if [ "$child_state" = "incomplete" ]; then
      pinned_list="${pinned_list}${child_tid}"$'\n'
      echo "  pinned ${child_tid} (incomplete pipeline)"
    fi
  done <<<"$child_set"

  if [ -n "$killed_list" ]; then
    killed=$(echo "$killed_list" | grep -v '^$' | jq -R -s -c 'split("\n") | map(select(length > 0))' 2>/dev/null || echo "[]")
  fi
  if [ -n "$pinned_list" ]; then
    pinned=$(echo "$pinned_list" | grep -v '^$' | jq -R -s -c 'split("\n") | map(select(length > 0))' 2>/dev/null || echo "[]")
  fi

  # 3. Write the stop-file with the union of purged, killed, pinned, and any
  # tickets pinned by an existing stop-file — an idempotent re-stop must
  # never unpin tickets a previous stop recorded.
  local existing="[]"
  if _fleet_is_stopped "$workspace" "$epic_id"; then
    existing=$(jq -c '.tickets // []' "$(_fleet_epic_stop_file "$workspace" "$epic_id")" 2>/dev/null || echo "[]")
  fi
  local tickets
  tickets=$(jq -nc --argjson p "$purged" --argjson k "$killed" --argjson n "$pinned" --argjson e "$existing" '($p + $k + $n + $e) | unique')
  _fleet_stop_write "$workspace" "$epic_id" "$tickets" "$reason"
  echo "stop-file written: stop-${epic_id}.json ($(echo "$tickets" | jq 'length') ticket(s) pinned)"

  echo "STOP_RESULT|purged=${purged}|killed=${killed}|pinned=${pinned}"
  return 0
}

# ── Sourceable/executable guard ──────────────────────────────────────────────────
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  INITIATIVE_ID="${1:-}"
  WORKSPACE="${2:-${FLEET_PIPELINE_LOG_DIR:-./logs}}"
  fleet_dispatch_initiative "$INITIATIVE_ID" "$WORKSPACE"
fi
