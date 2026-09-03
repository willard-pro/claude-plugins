#!/bin/bash
# PostToolUse hook — records one activity line per tool call for the pipeline
# phase that is currently running, giving the fleet stall engine a liveness
# signal that comes from the *agent* rather than from the orchestrator.
#
# Why this exists: the orchestrator's watchdog heartbeat proves the router is
# alive, not that the agent it is waiting on is doing anything. A hung agent
# inside a healthy router is invisible to detect_stalls today. This log's
# last-modified age is that missing second dimension.
#
# Identity resolution mirrors token-tracker.sh exactly: every hook payload
# carries the invoking session's session_id, and spawn_agent_pre stamps that
# same value (via $CLAUDE_CODE_SESSION_ID) into SESSION_ID= in the spawn-meta
# file it writes for every live pipeline spawn. Only the spawn-meta file whose
# SESSION_ID matches the payload's is considered — never the globally newest
# file across /tmp.
#
# Fail-soft contract (mirrors stop-capture.sh): this hook fires on EVERY tool
# call in EVERY Claude Code session with this plugin installed, including
# manual /ticket-auto runs and wholly unrelated sessions. It must exit 0 with
# zero side effects whenever a ticket identity cannot be resolved, and must
# never block or measurably slow a tool call. `set -e` is deliberately NOT
# used: a failed write must not abort the hook with a non-zero status.
set -o pipefail

# ── Fast path: no live pipeline spawn anywhere on this host ────────────────
# A single glob, evaluated before any parsing. This is the branch taken by
# virtually every tool call on a machine that is not running the pipeline.
_has_meta=0
for _f in /tmp/ticket-auto-*-spawn-meta.txt; do
  [ -e "$_f" ] && _has_meta=1
  break
done
[ "$_has_meta" -eq 0 ] && exit 0

read -r hook_json || exit 0
[ -z "$hook_json" ] && exit 0

# ── Parse the payload without forking ──────────────────────────────────────
# python3/jq would cost a process spawn per tool call. Tool names and session
# ids are plain identifiers, so a bash regex over the raw JSON is sufficient
# and ~100x cheaper. Anything that fails to match resolves to empty and the
# hook exits silently below.
SESSION_ID=""
TOOL_NAME=""
if [[ $hook_json =~ \"session_id\"[[:space:]]*:[[:space:]]*\"([^\"]*)\" ]]; then
  SESSION_ID="${BASH_REMATCH[1]}"
fi
if [[ $hook_json =~ \"tool_name\"[[:space:]]*:[[:space:]]*\"([^\"]*)\" ]]; then
  TOOL_NAME="${BASH_REMATCH[1]}"
fi

[ -z "$SESSION_ID" ] && exit 0

# ── Resolve PHASE / LOG_FILE / TICKET_ID from the one spawn-meta file whose
# SESSION_ID matches this hook's own session. ls -t sorts newest-first so a
# stale spawn-meta from an earlier phase in the same session never wins over
# the current one. ────────────────────────────────────────────────────────
PHASE=""
LOG_FILE=""
TICKET_ID=""
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
  if [ "$_sid" = "$SESSION_ID" ]; then
    PHASE="$_phase"
    LOG_FILE="$_log"
    TICKET_ID=$(basename "$f" | sed 's/ticket-auto-\(.*\)-spawn-meta\.txt/\1/')
    break
  fi
done

# No matching live pipeline spawn for this session — nothing to record.
[ -z "$TICKET_ID" ] && exit 0
[ -z "$LOG_FILE" ] && exit 0

# ── Security: sanitize TICKET_ID — reject traversal attempts ──────────────
case "$TICKET_ID" in
*..* | */* | *[[:space:]]*) exit 0 ;;
'') exit 0 ;;
esac

# The activity log lives beside the pipeline log so fleet-detect.sh finds it
# with the same ${workspace}/${tid}-*.log convention every other engine uses.
LOG_DIR=$(dirname "$LOG_FILE")
[ -d "$LOG_DIR" ] || exit 0
ACTIVITY_LOG="${LOG_DIR}/${TICKET_ID}-activity.log"

# Field separators and newlines in a tool name would forge log lines.
TOOL_NAME="${TOOL_NAME//|/_}"
TOOL_NAME="${TOOL_NAME//$'\n'/ }"
PHASE="${PHASE//|/_}"

# printf's %(...)T builtin formats the current time with no fork, which
# matters when this runs once per tool call.
NOW=""
printf -v NOW '%(%Y-%m-%dT%H:%M:%SZ)T' -1 2>/dev/null
if [ -z "$NOW" ]; then
  NOW=$(TZ=UTC date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null) || exit 0
fi

echo "${NOW}|${PHASE:-UNKNOWN}|${TOOL_NAME:-unknown}" >>"$ACTIVITY_LOG" 2>/dev/null || exit 0

# ── Ring-cap ───────────────────────────────────────────────────────────────
# The stall engine only ever reads the last line's timestamp and the current
# bracket's line count, so old lines have no consumer. Cap keeps a long
# implement phase from growing an unbounded file.
CAP="${FLEET_ACTIVITY_LOG_MAX_LINES:-500}"
case "$CAP" in
'' | *[!0-9]*) CAP=500 ;;
esac
if [ "$CAP" -gt 0 ]; then
  _lines=$(wc -l <"$ACTIVITY_LOG" 2>/dev/null || echo 0)
  _lines="${_lines//[^0-9]/}"
  if [ -n "$_lines" ] && [ "$_lines" -gt "$CAP" ]; then
    _tmp="${ACTIVITY_LOG}.tmp.$$"
    if tail -n "$CAP" "$ACTIVITY_LOG" >"$_tmp" 2>/dev/null; then
      mv -f "$_tmp" "$ACTIVITY_LOG" 2>/dev/null || rm -f "$_tmp" 2>/dev/null
    else
      rm -f "$_tmp" 2>/dev/null
    fi
  fi
fi

# Best-effort telemetry — never block the tool call that triggered this hook.
exit 0
