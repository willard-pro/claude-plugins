#!/bin/bash
# PostToolUseFailure hook — intercepts Bash tool errors and writes structured
# entries to per-pipeline tool-error logs for fleet controller detection.
#
# Ticket resolution follows the same pattern as token-tracker.sh:
# spawn-meta file (stable per-spawn snapshot) → ctx file (legacy) → bail.
# When no ticket-auto pipeline is active, exits silently.
#
# Error classification maps error text to a short type token for dedup.
# Dedup: same TICKET_ID+TOOL_NAME+ERROR_TYPE within TOOL_ERROR_DEDUP_WINDOW
# seconds produces at most one log entry.
#
# Log format: ISO|TOOL_NAME|ERROR_TYPE|PHASE|SAFE_MSG
# Pipes in MSG are escaped to \x7c to avoid field corruption.
set -eo pipefail

read -r hook_json

# ── Extract hook fields ──────────────────────────────────────────────────────
TOOL_NAME=$(echo "$hook_json" | python3 -c "import json,sys; print(json.load(sys.stdin).get('tool_name','UNKNOWN'))" 2>/dev/null || echo "UNKNOWN")
ERROR_MSG=$(echo "$hook_json" | python3 -c "import json,sys; print(json.load(sys.stdin).get('error',''))" 2>/dev/null || echo "")

# Bail on empty error — nothing to log
[ -z "$ERROR_MSG" ] && exit 0

# ── Resolve TICKET_ID, PHASE, LOG_FILE ───────────────────────────────────────
# Priority 1: spawn-meta file (stable per-spawn snapshot, not overwritten until
# the next spawn_agent_pre call)
PHASE=""
LOG_FILE=""
TICKET_ID=""

META_FILE=$(ls -t /tmp/ticket-auto-*-spawn-meta.txt 2>/dev/null | head -1 || true)
if [ -n "$META_FILE" ]; then
  TICKET_ID=$(basename "$META_FILE" | sed 's/ticket-auto-\(.*\)-spawn-meta\.txt/\1/')
  while IFS='=' read -r key val; do
    case "$key" in
    PHASE) PHASE="$val" ;;
    LOG_FILE) LOG_FILE="$val" ;;
    esac
  done <"$META_FILE"
fi

# Priority 2: legacy ctx file fallback
if [ -z "$PHASE" ] || [ -z "$LOG_FILE" ]; then
  CTX_FILE=$(ls -t /tmp/ticket-auto-*-ctx.txt 2>/dev/null | head -1 || true)
  if [ -n "$CTX_FILE" ]; then
    IFS='|' read -r CTX_PHASE CTX_LOG_FILE <"$CTX_FILE"
    [ -z "$PHASE" ] && PHASE="$CTX_PHASE"
    [ -z "$LOG_FILE" ] && LOG_FILE="$CTX_LOG_FILE"
    [ -z "$TICKET_ID" ] && TICKET_ID=$(basename "$CTX_FILE" | sed 's/ticket-auto-\(.*\)-ctx\.txt/\1/')
  fi
fi

# No active ticket-auto pipeline — nothing to log
[ -z "$TICKET_ID" ] && exit 0
[ -z "$LOG_FILE" ] && exit 0

# ── Security: sanitize TICKET_ID — reject traversal attempts ─────────────────
case "$TICKET_ID" in
*..* | */* | *[[:space:]]*) exit 0 ;; # path traversal or whitespace — reject
'' | *-) exit 0 ;;                    # empty or trailing dash — reject
esac

# ── Security: verify spawn-meta file ownership ───────────────────────────────
if [ -n "$META_FILE" ] && [ -f "$META_FILE" ]; then
  _meta_owner=$(stat -c %u "$META_FILE" 2>/dev/null || echo "")
  [ -n "$_meta_owner" ] && [ "$_meta_owner" != "$(id -u)" ] && exit 0
fi

# ── Security: validate LOG_DIR is within an allowed base ─────────────────────
LOG_DIR=$(dirname "$LOG_FILE")
# Resolve to canonical absolute path; bail if the directory doesn't exist
LOG_DIR=$(cd "$LOG_DIR" 2>/dev/null && pwd || echo "")
# Sanity: must be an absolute path under an allowed prefix
case "$LOG_DIR" in
/home/* | /tmp/*) ;; # allowed: under /home or /tmp
*) exit 0 ;;         # outside allowed roots — reject
esac

[ -z "$PHASE" ] && PHASE="UNKNOWN"

# ── Classify error type ──────────────────────────────────────────────────────
ERROR_LOWER=$(echo "$ERROR_MSG" | tr '[:upper:]' '[:lower:]')
ERROR_TYPE="unknown"

case "$ERROR_LOWER" in
*"command not found"* | *"no such file"* | *"not found"*)
  ERROR_TYPE="command_not_found"
  ;;
*"timed out"* | *"timeout"* | *"timed-out"*)
  ERROR_TYPE="timeout"
  ;;
*"sandbox"* | *"sandboxed"*)
  ERROR_TYPE="sandbox_violation"
  ;;
*"exit status"* | *"exit code"* | *"exited with"*)
  ERROR_TYPE="exit_nonzero"
  ;;
*"permission denied"* | *"not permitted"* | *"not allowed"*)
  ERROR_TYPE="permission_denied"
  ;;
*"permission"* | *"forbidden"* | *"denied"*)
  ERROR_TYPE="permission_denied"
  ;;
esac

# ── Dedup: same ticket+tool+type within window → skip ────────────────────────
DEDUP_KEY="tool-err-${TICKET_ID}-${TOOL_NAME}-${ERROR_TYPE}"
DEDUP_FILE="/tmp/${DEDUP_KEY}"
DEDUP_WINDOW="${TOOL_ERROR_DEDUP_WINDOW:-300}"

if [ -f "$DEDUP_FILE" ]; then
  LAST_TIME=$(cat "$DEDUP_FILE" 2>/dev/null || echo "0")
  NOW=$(date +%s)
  if [ $((NOW - LAST_TIME)) -lt "$DEDUP_WINDOW" ]; then
    exit 0
  fi
fi

date +%s >"$DEDUP_FILE"

# ── Write structured error entry ─────────────────────────────────────────────
LOG_DIR=$(dirname "$LOG_FILE")
ERROR_LOG="${LOG_DIR}/${TICKET_ID}-tool-errors.log"
mkdir -p "$LOG_DIR"

# Escape pipes in error message, collapse whitespace, truncate to 250 chars
SAFE_MSG=$(echo "$ERROR_MSG" | tr '\n' ' ' | sed 's/|/<pipe>/g' | tr -s ' ' | head -c 250)
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|${TOOL_NAME}|${ERROR_TYPE}|${PHASE}|${SAFE_MSG}" >>"$ERROR_LOG"
