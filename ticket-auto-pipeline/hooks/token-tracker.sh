#!/bin/bash
# SubagentStop hook — parses agent transcript, sums token usage, appends to pipeline log.
# Resolves PHASE from spawn-meta file (/tmp/ticket-auto-{ID}-spawn-meta.txt) which is
# a stable per-spawn snapshot — avoids the race where the ctx file is overwritten by
# the next phase's spawn_agent_pre before this async hook fires.
# Reads start timestamp written by token-tracker-start.sh to compute elapsed_ms.
# -u (nounset) intentionally omitted: Claude Code shell snapshots inject
# ZSH_VERSION references that trigger false-positive "unbound variable"
# errors in this bash version when nounset is active.
set -eo pipefail

read -r hook_json
AGENT_TRANSCRIPT=$(echo "$hook_json" | python3 -c "import json,sys; print(json.load(sys.stdin).get('agent_transcript_path',''))")

# ── Resolve PHASE and LOG_FILE ───────────────────────────────────────────────
# Priority: spawn-meta file (stable per-spawn snapshot) → ctx file (legacy) → UNKNOWN
PHASE=""
LOG_FILE=""
TICKET_ID=""

# Try spawn-meta files first (written atomically by spawn_agent_pre, not overwritten
# until the NEXT spawn_agent_pre — avoids the race where ctx file already shows next phase)
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

# Fallback: try legacy ctx file
if [ -z "$PHASE" ] || [ -z "$LOG_FILE" ]; then
  CTX_FILE=$(ls -t /tmp/ticket-auto-*-ctx.txt 2>/dev/null | head -1 || true)
  if [ -n "$CTX_FILE" ]; then
    IFS='|' read -r CTX_PHASE CTX_LOG_FILE <"$CTX_FILE"
    [ -z "$PHASE" ] && PHASE="$CTX_PHASE"
    [ -z "$LOG_FILE" ] && LOG_FILE="$CTX_LOG_FILE"
    [ -z "$TICKET_ID" ] && TICKET_ID=$(basename "$CTX_FILE" | sed 's/ticket-auto-\(.*\)-ctx\.txt/\1/')
  fi
fi

# Default: if still unresolved, use UNKNOWN
[ -z "$PHASE" ] && PHASE="UNKNOWN"

if [ -z "$LOG_FILE" ]; then
  exit 0
fi

[ -z "$TICKET_ID" ] && TICKET_ID="unknown"
START_FILE="/tmp/ticket-auto-${TICKET_ID}-start-${PHASE}.ts"

if [ -n "$AGENT_TRANSCRIPT" ] && [ -f "$AGENT_TRANSCRIPT" ]; then
  TOKENS=$(python3 -c "
import json, sys
input_t = output_t = cache_read = cache_create = 0
with open('$AGENT_TRANSCRIPT') as f:
    for line in f:
        try:
            msg = json.loads(line)
        except:
            continue
        if msg.get('type') == 'assistant':
            u = msg.get('message', {}).get('usage', {})
            input_t += u.get('input_tokens', 0)
            output_t += u.get('output_tokens', 0)
            cache_read += u.get('cache_read_input_tokens', 0)
            cache_create += u.get('cache_creation_input_tokens', 0)
print(f'{input_t}/{output_t}/{cache_read + cache_create}')
" 2>/dev/null)
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
