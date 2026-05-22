#!/bin/bash
# SubagentStart hook — writes nanosecond timestamp for phase duration tracking.
# Requires /tmp/ticket-auto-{TICKET_ID}-ctx.txt with format: PHASE|LOG_FILE
set -euo pipefail

read -r hook_json

# Only track ticket-auto pipelines — ctx file is written exclusively by the ticket-auto orchestrator
CTX_FILE=$(ls -t /tmp/ticket-auto-*-ctx.txt 2>/dev/null | head -1)
if [ -z "$CTX_FILE" ]; then
  exit 0
fi

IFS='|' read -r PHASE LOG_FILE <"$CTX_FILE"
if [ -z "$PHASE" ]; then
  exit 0
fi

TICKET_ID=$(basename "$CTX_FILE" | sed 's/ticket-auto-\(.*\)-ctx\.txt/\1/')
date +%s%N >"/tmp/ticket-auto-${TICKET_ID}-start-${PHASE}.ts"
