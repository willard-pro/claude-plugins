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

# Get current active pipeline count by counting non-completed pipeline logs.
# Args: workspace
_active_pipeline_count() {
  local workspace="${1:-${FLEET_PIPELINE_LOG_DIR:-./logs}}"
  local count=0
  if [ -d "$workspace" ]; then
    for log_file in "$workspace"/*-pipeline.log; do
      [ -f "$log_file" ] || continue
      command grep -q '|META|outcome|' "$log_file" 2>/dev/null && continue
      count=$((count + 1))
    done
  fi
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

# ── fleet_dispatch_initiative ────────────────────────────────────────────────────
# Main entry point: dispatch planned child tickets from an initiative epic.
# Usage: fleet_dispatch_initiative <initiative_id> [workspace]
fleet_dispatch_initiative() {
  local initiative_id="$1"
  local workspace="${2:-${FLEET_PIPELINE_LOG_DIR:-./logs}}"
  local queue_file
  queue_file=$(_fleet_queue_file "$workspace")
  local max_concurrent="${FLEET_MAX_CONCURRENT:-3}"
  local dry_run="${FLEET_DRY_RUN:-false}"

  if [ -z "$initiative_id" ]; then
    echo "ERROR: initiative_id required" >&2
    echo "Usage: fleet_dispatch_initiative <INITIATIVE_ID> [workspace]" >&2
    return 1
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

    [ "$is_blocked" = "true" ] && continue

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
    echo "no dispatchable tickets for ${initiative_id}"
    return 0
  fi

  # Step 4: Enforce FLEET_MAX_CONCURRENT
  local active_count max_to_enqueue
  active_count=$(_active_pipeline_count "$workspace")
  max_to_enqueue=$((max_concurrent - active_count))
  [ "$max_to_enqueue" -le 0 ] && echo "fleet_dispatch: at capacity (${active_count}/${max_concurrent} active)" && return 0

  echo "fleet_dispatch: ${active_count}/${max_concurrent} active, can enqueue up to ${max_to_enqueue}"

  # Step 5: Write spawn queue
  local enqueued=0
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

  if [ "$dry_run" = "true" ]; then
    echo "[DRY-RUN] would enqueue ${enqueued} ticket(s) for ${initiative_id}"
  else
    echo "fleet_dispatch: enqueued ${enqueued} ticket(s) for ${initiative_id} → ${queue_file}"
  fi

  return 0
}

# ── Sourceable/executable guard ──────────────────────────────────────────────────
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  INITIATIVE_ID="${1:-}"
  WORKSPACE="${2:-${FLEET_PIPELINE_LOG_DIR:-./logs}}"
  fleet_dispatch_initiative "$INITIATIVE_ID" "$WORKSPACE"
fi
