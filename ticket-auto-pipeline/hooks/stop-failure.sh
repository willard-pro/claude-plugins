#!/bin/bash
# StopFailure hook — appends META|worker-api-error| when a fleetd-spawned
# worker's turn ends due to an API error.
#
# Fires after retries are exhausted; per-attempt causes live in
# system/api_retry (stream-json, out of scope for this change) or OTel's
# claude_code.api_error (deferred — see worker-reap-recovery design.md).
# This hook only records that a turn ended this way, not why each retry
# failed.
#
# Same session_id -> tid resolution as stop-capture.sh: the fleet state
# store's `workers` table (fleet-store.sh) when fleetd is co-installed and
# has a store for this workspace, falling back to scanning
# `{FLEET_STATE_DIR}/*-run.json` when the store is unavailable. Silently
# exits 0 when unresolvable — must never affect non-fleet Claude Code usage.
set -eo pipefail

# Discover and source fleet-store.sh for the store-backed resolution path.
# Same discovery order as stop-capture.sh / lib/spawn-helper.sh.
_sf_store_sh=""
for _f_cand in \
  "$(dirname "${BASH_SOURCE[0]}")/../../fleet-controller/lib/fleet-store.sh" \
  "$HOME/.claude/skills/fleet-controller/lib/fleet-store.sh" \
  "$HOME/.claude/plugins/fleet-controller/lib/fleet-store.sh"; do
  [ -f "$_f_cand" ] && {
    source "$_f_cand"
    _sf_store_sh="$_f_cand"
    break
  }
done

read -r hook_json

SESSION_ID=$(echo "$hook_json" | python3 -c "import json,sys; print(json.load(sys.stdin).get('session_id',''))" 2>/dev/null || echo "")

[ -z "$SESSION_ID" ] && exit 0
[ -z "${FLEET_STATE_DIR:-}" ] && exit 0
[ -d "$FLEET_STATE_DIR" ] || exit 0

TID=""

if [ -n "$_sf_store_sh" ] && declare -f fleet_store_worker_by_session >/dev/null 2>&1; then
  found=$(fleet_store_worker_by_session "$SESSION_ID" "$FLEET_STATE_DIR" 2>/dev/null || echo "")
  [ -n "$found" ] && TID="${found%%|*}"
fi

if [ -z "$TID" ]; then
  for run_file in "$FLEET_STATE_DIR"/*-run.json; do
    [ -f "$run_file" ] || continue
    found_session=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('session_id',''))" "$run_file" 2>/dev/null || echo "")
    if [ "$found_session" = "$SESSION_ID" ]; then
      TID=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('tid',''))" "$run_file" 2>/dev/null || echo "")
      break
    fi
  done
fi

[ -z "$TID" ] && exit 0

case "$TID" in
*..* | */* | *[[:space:]]*) exit 0 ;;
'') exit 0 ;;
esac

LOG_FILE="${FLEET_STATE_DIR}/${TID}-pipeline.log"
[ -f "$LOG_FILE" ] || exit 0

echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|META|worker-api-error|warn|turn ended on API error (session=${SESSION_ID})" >>"$LOG_FILE"

exit 0
