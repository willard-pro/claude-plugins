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
# Same session_id -> tid/generation resolution as stop-capture.sh. Silently
# exits 0 when unresolvable — must never affect non-fleet Claude Code usage.
set -eo pipefail

read -r hook_json

SESSION_ID=$(echo "$hook_json" | python3 -c "import json,sys; print(json.load(sys.stdin).get('session_id',''))" 2>/dev/null || echo "")

[ -z "$SESSION_ID" ] && exit 0
[ -z "${FLEET_STATE_DIR:-}" ] && exit 0
[ -d "$FLEET_STATE_DIR" ] || exit 0

TID=""
for run_file in "$FLEET_STATE_DIR"/*-run.json; do
  [ -f "$run_file" ] || continue
  found_session=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('session_id',''))" "$run_file" 2>/dev/null || echo "")
  if [ "$found_session" = "$SESSION_ID" ]; then
    TID=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('tid',''))" "$run_file" 2>/dev/null || echo "")
    break
  fi
done

[ -z "$TID" ] && exit 0

case "$TID" in
*..* | */* | *[[:space:]]*) exit 0 ;;
'') exit 0 ;;
esac

LOG_FILE="${FLEET_STATE_DIR}/${TID}-pipeline.log"
[ -f "$LOG_FILE" ] || exit 0

echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|META|worker-api-error|warn|turn ended on API error (session=${SESSION_ID})" >>"$LOG_FILE"

exit 0
