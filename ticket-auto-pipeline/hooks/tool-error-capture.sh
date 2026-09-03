#!/bin/bash
# PostToolUseFailure hook — intercepts tool errors and writes structured entries
# to per-pipeline tool-error logs for fleet controller detection.
#
# Registered without a matcher, so it sees every failing tool, not only Bash.
# The pipeline's two most failure-prone surfaces are not Bash at all: the verify
# phase drives Playwright through MCP, and every phase reaches Linear the same
# way. A Bash-only matcher meant an entire verify run could fail on browser and
# MCP errors while the tool-error log stayed empty.
#
# Ticket resolution matches the invoking session against the spawn-meta file's
# SESSION_ID, exactly as token-tracker.sh and agent-activity.sh do. It is not the
# globally newest /tmp file: with the matcher widened this hook now fires for
# failures in unrelated sessions, where a newest-file scan would attribute
# another session's error to whichever ticket happened to spawn last.
#
# Error classification maps tool identity plus error text to a short type token
# for dedup. Playwright and MCP failures classify distinctly from Bash ones —
# `playwright_timeout` and `timeout` are different operational problems with
# different responses, and collapsing them loses the distinction.
# Dedup: same TICKET_ID+TOOL_NAME+ERROR_TYPE within TOOL_ERROR_DEDUP_WINDOW
# seconds produces at most one log entry.
#
# Log format: ISO|TOOL_NAME|ERROR_TYPE|PHASE|SAFE_MSG
# Pipes in MSG are escaped to \x7c to avoid field corruption.
set -eo pipefail

# ── Fast path: no live pipeline spawn anywhere on this host ──────────────────
# A single glob before any parsing. With the matcher widened past Bash this hook
# runs in every session, and this is the branch nearly all of them take.
_has_meta=0
for _f in /tmp/ticket-auto-*-spawn-meta.txt; do
  [ -e "$_f" ] && _has_meta=1
  break
done
[ "$_has_meta" -eq 0 ] && exit 0

read -r hook_json

# ── Extract hook fields ──────────────────────────────────────────────────────
# One python3 fork for all three fields rather than one per field. The error
# text needs a real JSON parser (it carries escapes and newlines that a bash
# regex would truncate at the first embedded quote), so this is the one hook
# path where the fork is unavoidable — it is at least paid once.
_hook_fields=$(echo "$hook_json" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
err = (d.get('error') or '').replace('\r', ' ').replace('\n', ' ')
print(d.get('tool_name') or 'UNKNOWN')
print(d.get('session_id') or '')
print(err)
" 2>/dev/null || true)

TOOL_NAME=$(printf '%s\n' "$_hook_fields" | sed -n '1p')
HOOK_SESSION_ID=$(printf '%s\n' "$_hook_fields" | sed -n '2p')
ERROR_MSG=$(printf '%s\n' "$_hook_fields" | sed -n '3p')
TOOL_NAME="${TOOL_NAME:-UNKNOWN}"

# Bail on empty error — nothing to log
[ -z "$ERROR_MSG" ] && exit 0

# ── Resolve TICKET_ID, PHASE, LOG_FILE ───────────────────────────────────────
# The spawn-meta file is a stable per-spawn snapshot, not overwritten until the
# next spawn_agent_pre call. There is deliberately no ctx-file fallback: the ctx
# file carries no session id, so falling back to it would reintroduce exactly the
# cross-session misattribution the session match exists to prevent.
PHASE=""
LOG_FILE=""
TICKET_ID=""

# Only the spawn-meta file whose SESSION_ID matches this hook's own session is
# considered. ls -t sorts newest-first so a stale spawn-meta from an earlier
# phase of the same session never wins over the current one.
META_FILE=""
if [ -n "$HOOK_SESSION_ID" ]; then
  for f in $(ls -t /tmp/ticket-auto-*-spawn-meta.txt 2>/dev/null || true); do
    [ -f "$f" ] || continue
    _phase="" _log="" _sid=""
    while IFS='=' read -r key val; do
      case "$key" in
      PHASE) _phase="$val" ;;
      LOG_FILE) _log="$val" ;;
      SESSION_ID) _sid="$val" ;;
      esac
    done <"$f"
    if [ -n "$_sid" ] && [ "$_sid" = "$HOOK_SESSION_ID" ]; then
      META_FILE="$f"
      PHASE="$_phase"
      LOG_FILE="$_log"
      TICKET_ID=$(basename "$f" | sed 's/ticket-auto-\(.*\)-spawn-meta\.txt/\1/')
      break
    fi
  done
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
# Two-stage: the tool's identity decides which vocabulary applies, then the
# message shape picks a token from it. Classifying on message text alone would
# fold a Playwright navigation timeout and a shell command timeout into one
# bucket, and they call for opposite responses (retry the browser vs. the command
# is genuinely hung).
ERROR_LOWER=$(echo "$ERROR_MSG" | tr '[:upper:]' '[:lower:]')
ERROR_TYPE="unknown"

TOOL_CLASS="tool"
case "$TOOL_NAME" in
*playwright*) TOOL_CLASS="playwright" ;;
mcp__*) TOOL_CLASS="mcp" ;;
Bash) TOOL_CLASS="bash" ;;
esac

if [ "$TOOL_CLASS" = "playwright" ]; then
  case "$ERROR_LOWER" in
  *"timeout"* | *"timed out"*)
    ERROR_TYPE="playwright_timeout"
    ;;
  *"strict mode violation"* | *"waiting for locator"* | *"no element"* | *"resolved to 0 elements"* | *"selector"*)
    ERROR_TYPE="playwright_selector"
    ;;
  *"net::err"* | *"navigating to"* | *"page.goto"* | *"err_connection"* | *"err_name_not_resolved"*)
    ERROR_TYPE="playwright_navigation"
    ;;
  *"has been closed"* | *"target closed"* | *"browser has been closed"*)
    ERROR_TYPE="playwright_target_closed"
    ;;
  *"browsertype.launch"* | *"executable doesn't exist"* | *"please run the following command to download"*)
    ERROR_TYPE="playwright_browser_launch"
    ;;
  *)
    ERROR_TYPE="playwright_error"
    ;;
  esac
elif [ "$TOOL_CLASS" = "mcp" ]; then
  case "$ERROR_LOWER" in
  *"connection closed"* | *"disconnected"* | *"server closed"* | *"broken pipe"*)
    ERROR_TYPE="mcp_connection_closed"
    ;;
  *"unauthorized"* | *"401"* | *"authentication failed"* | *"invalid token"* | *"forbidden"* | *"403"*)
    ERROR_TYPE="mcp_unauthorized"
    ;;
  *"rate limit"* | *"429"* | *"too many requests"*)
    ERROR_TYPE="mcp_rate_limited"
    ;;
  *"tool not found"* | *"unknown tool"* | *"no such tool"* | *"method not found"*)
    ERROR_TYPE="mcp_tool_not_found"
    ;;
  *"timeout"* | *"timed out"*)
    ERROR_TYPE="mcp_timeout"
    ;;
  *)
    ERROR_TYPE="mcp_error"
    ;;
  esac
fi

# Bash and any other tool keep the original vocabulary unchanged. Playwright and
# MCP fall through only when the stage above left the type unresolved, which it
# never does — the branches above are exhaustive by construction.
[ "$ERROR_TYPE" != "unknown" ] && ERROR_LOWER=""

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
