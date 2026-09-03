#!/bin/bash
# Stop hook — captures last_assistant_message for a fleetd-spawned worker so
# it can be merged into the worker's exit record at reap time.
#
# This is the only channel a headless `claude -p` worker's question can
# travel through: AskUserQuestion is absent from the -p tool list (see
# worker-reap-recovery design.md Decision 8), so a worker that "asks
# something" is really the model ending its turn with the question as
# last_assistant_message and exiting 0 — text this hook is the sole capture
# point for. Does NOT fire on SIGINT or SIGKILL; exit capture (fleetd's own
# reaper) covers those cases, with this field simply absent.
#
# Resolution: the hook payload carries session_id, not a ticket id. Resolved
# via the fleet state store's `workers` table (fleet-store.sh,
# fleet_store_worker_by_session) when fleetd is co-installed and has a store
# for this workspace — the store is the authoritative source for a phase
# worker's tid+generation now that several worker rows can coexist per
# ticket. Falls back to scanning `{FLEET_STATE_DIR}/*-run.json` for the
# matching session_id when the store is unavailable (no fleet-controller
# installed, sqlite3 missing, or the store not yet initialized) — that file
# convention remains the ticket-level path's registry until task 11.4's
# store migration is complete fleet-wide. Silently exits 0 when unresolvable
# (not a fleet-managed worker, e.g. an interactive session) — this hook must
# never affect non-fleet Claude Code usage.
set -eo pipefail

# Discover and source fleet-store.sh for the store-backed resolution path.
# Look relative to this script (monorepo), then installed plugin paths —
# same discovery order lib/spawn-helper.sh uses for fleet-config.sh.
_stop_store_sh=""
for _s_cand in \
  "$(dirname "${BASH_SOURCE[0]}")/../../fleet-controller/lib/fleet-store.sh" \
  "$HOME/.claude/skills/fleet-controller/lib/fleet-store.sh" \
  "$HOME/.claude/plugins/fleet-controller/lib/fleet-store.sh"; do
  [ -f "$_s_cand" ] && {
    source "$_s_cand"
    _stop_store_sh="$_s_cand"
    break
  }
done

read -r hook_json

SESSION_ID=$(echo "$hook_json" | python3 -c "import json,sys; print(json.load(sys.stdin).get('session_id',''))" 2>/dev/null || echo "")
LAST_MSG=$(echo "$hook_json" | python3 -c "import json,sys; print(json.load(sys.stdin).get('last_assistant_message',''))" 2>/dev/null || echo "")

[ -z "$SESSION_ID" ] && exit 0
[ -z "${FLEET_STATE_DIR:-}" ] && exit 0
[ -d "$FLEET_STATE_DIR" ] || exit 0

# ── Resolve TID + generation by session_id ───────────────────────────────────
TID=""
GENERATION=""

if [ -n "$_stop_store_sh" ] && declare -f fleet_store_worker_by_session >/dev/null 2>&1; then
  found=$(fleet_store_worker_by_session "$SESSION_ID" "$FLEET_STATE_DIR" 2>/dev/null || echo "")
  if [ -n "$found" ]; then
    TID="${found%%|*}"
    GENERATION="${found#*|}"
  fi
fi

if [ -z "$TID" ]; then
  for run_file in "$FLEET_STATE_DIR"/*-run.json; do
    [ -f "$run_file" ] || continue
    found_session=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('session_id',''))" "$run_file" 2>/dev/null || echo "")
    if [ "$found_session" = "$SESSION_ID" ]; then
      TID=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('tid',''))" "$run_file" 2>/dev/null || echo "")
      GENERATION=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('generation',''))" "$run_file" 2>/dev/null || echo "")
      break
    fi
  done
fi

[ -z "$TID" ] && exit 0
[ -z "$GENERATION" ] && exit 0

# ── Security: sanitize TID — reject traversal attempts ────────────────────
case "$TID" in
*..* | */* | *[[:space:]]*) exit 0 ;;
'') exit 0 ;;
esac

[ -z "$LAST_MSG" ] && exit 0

HOOK_FILE="${FLEET_STATE_DIR}/${TID}-gen${GENERATION}-hook.json"
python3 -c "
import json, sys
msg = sys.argv[1]
path = sys.argv[2]
# Truncate defensively — this is a diagnostic breadcrumb, not a transcript.
msg = msg[:4000]
try:
    with open(path) as f:
        data = json.load(f)
except (OSError, json.JSONDecodeError):
    data = {}
data['last_assistant_message'] = msg
with open(path, 'w') as f:
    json.dump(data, f)
" "$LAST_MSG" "$HOOK_FILE" 2>/dev/null || true

exit 0
