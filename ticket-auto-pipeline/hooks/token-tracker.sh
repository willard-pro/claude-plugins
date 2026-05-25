#!/bin/bash
# SubagentStop hook — parses agent transcript, sums token usage, appends to pipeline log.
# Requires /tmp/ticket-auto-{TICKET_ID}-ctx.txt with format: PHASE|LOG_FILE
# Reads start timestamp written by token-tracker-start.sh to compute elapsed_ms.
set -euo pipefail

read -r hook_json
AGENT_TRANSCRIPT=$(echo "$hook_json" | python3 -c "import json,sys; print(json.load(sys.stdin).get('agent_transcript_path',''))")

# Only track ticket-auto pipelines — ctx file is written exclusively by the ticket-auto orchestrator
CTX_FILE=$(ls -t /tmp/ticket-auto-*-ctx.txt 2>/dev/null | head -1)
if [ -z "$CTX_FILE" ]; then
  exit 0
fi

IFS='|' read -r PHASE LOG_FILE <"$CTX_FILE"
if [ -z "$PHASE" ] || [ -z "$LOG_FILE" ]; then
  exit 0
fi

TICKET_ID=$(basename "$CTX_FILE" | sed 's/ticket-auto-\(.*\)-ctx\.txt/\1/')
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
