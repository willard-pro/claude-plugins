#!/bin/bash
# SubagentStop hook — parses agent transcript, sums token usage, appends to pipeline log.
#
# Identity resolution: every Claude Code hook payload carries the invoking
# session's session_id (a common field across all hook events). spawn_agent_pre
# stamps that same value (via $CLAUDE_CODE_SESSION_ID) into SESSION_ID= in the
# spawn-meta file it writes for every live pipeline spawn
# (/tmp/ticket-auto-{ID}-spawn-meta.txt). This hook only considers spawn-meta
# files whose SESSION_ID matches the payload's — never the globally newest
# file across /tmp, and never an UNKNOWN-phase guess. A subagent stopping with
# no live pipeline spawn for its session resolves nothing and exits 0 without
# writing anywhere. token-tracker-start.sh resolves identity the same way, so
# the two hooks can no longer disagree about which spawn they belong to.
#
# Transcript path resolution: only the primary source is trusted —
# agent_transcript_path from the hook payload. When it is absent (named
# subagent_type spawns omit it), token accounting is skipped rather than
# guessed — a missing measurement is recoverable, a wrong one silently
# corrupts every downstream aggregate.
#
# Reads start timestamp written by token-tracker-start.sh to compute elapsed_ms.
# -u (nounset) intentionally omitted: Claude Code shell snapshots inject
# ZSH_VERSION references that trigger false-positive "unbound variable"
# errors in this bash version when nounset is active.
set -eo pipefail

read -r hook_json
SESSION_ID=$(echo "$hook_json" | python3 -c "import json,sys; print(json.load(sys.stdin).get('session_id',''))" 2>/dev/null || echo "")
AGENT_TRANSCRIPT=$(echo "$hook_json" | python3 -c "import json,sys; print(json.load(sys.stdin).get('agent_transcript_path',''))" 2>/dev/null || echo "")

# No session identity on the payload — nothing to safely attribute to.
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

# No matching live pipeline spawn for this session — nothing to log.
[ -z "$TICKET_ID" ] && exit 0
[ -z "$PHASE" ] && exit 0
[ -z "$LOG_FILE" ] && exit 0

# Pick the most recent start file for this phase. Unique suffixes per spawn
# prevent sub-sub-agent overwrite races; ls -t ensures correct pairing.
# The candidate list comes from find -print0, not a bare glob, so a TICKET_ID
# or PHASE containing shell metacharacters is never re-expanded by the shell.
START_FILE=""
_start_files=()
while IFS= read -r -d '' _sf; do
  _start_files+=("$_sf")
done < <(find /tmp -maxdepth 1 -name "ticket-auto-${TICKET_ID}-start-${PHASE}-*.ts" -print0 2>/dev/null || true)
if [ "${#_start_files[@]}" -gt 0 ]; then
  START_FILE=$(ls -t -- "${_start_files[@]}" 2>/dev/null | head -1 || true)
fi

if [ -n "$AGENT_TRANSCRIPT" ] && [ -f "$AGENT_TRANSCRIPT" ]; then
  TOKENS=$(python3 -c '
import json, sys
input_t = output_t = cache_read = cache_create = 0
with open(sys.argv[1]) as f:
    for line in f:
        try:
            msg = json.loads(line)
        except Exception:
            continue
        if msg.get("type") == "assistant":
            u = msg.get("message", {}).get("usage", {})
            input_t += u.get("input_tokens", 0)
            output_t += u.get("output_tokens", 0)
            cache_read += u.get("cache_read_input_tokens", 0)
            cache_create += u.get("cache_creation_input_tokens", 0)
print(f"{input_t}/{output_t}/{cache_read + cache_create}")
' "$AGENT_TRANSCRIPT" 2>/dev/null)
  if [ -n "$TOKENS" ]; then
    ELAPSED=""
    if [ -f "$START_FILE" ]; then
      START_NS=$(cat "$START_FILE")
      NOW_NS=$(date +%s%N)
      ELAPSED="|elapsed_ms=$(((NOW_NS - START_NS) / 1000000))"
      rm -f "$START_FILE"
    fi
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|META|tokens|info|${PHASE}:${TOKENS}${ELAPSED}" >>"$LOG_FILE"
    echo "tokens logged: ${PHASE} ${TOKENS}" >&2
  fi
fi

# Clean up leftover start files (>5 min old) for this ticket and phase, from
# crashed spawns or SubagentStop hooks that never matched one. Deliberately
# outside the "start file found" branch above: the accumulation this prevents
# is worst exactly when matching keeps failing, which is when the old nested
# placement never ran. Bounded to this ticket+phase; the SessionStart sweep
# (hooks/tmp-sweep.sh) is the host-wide backstop for everything else.
find /tmp -maxdepth 1 -name "ticket-auto-${TICKET_ID}-start-${PHASE}-*.ts" -mmin +5 -delete 2>/dev/null || true

# Best-effort telemetry — never block the agent that triggered this hook.
exit 0
