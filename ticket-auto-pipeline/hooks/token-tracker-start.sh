#!/bin/bash
# SubagentStart hook — writes nanosecond timestamp for phase duration tracking.
# Requires /tmp/ticket-auto-{TICKET_ID}-ctx.txt with format: PHASE|LOG_FILE
# -u (nounset) intentionally omitted: Claude Code shell snapshots inject
# ZSH_VERSION references that trigger false-positive "unbound variable"
# errors in this bash version when nounset is active.
set -eo pipefail

read -r hook_json

# Only track ticket-auto pipelines — ctx file is written exclusively by the ticket-auto orchestrator
CTX_FILE=$(ls -t /tmp/ticket-auto-*-ctx.txt 2>/dev/null | head -1 || true)
if [ -z "$CTX_FILE" ]; then
  exit 0
fi

IFS='|' read -r PHASE LOG_FILE <"$CTX_FILE"
if [ -z "$PHASE" ]; then
  exit 0
fi

TICKET_ID=$(basename "$CTX_FILE" | sed 's/ticket-auto-\(.*\)-ctx\.txt/\1/')
# Unique suffix prevents sub-sub-agent spawns from overwriting the parent agent's
# start timestamp. A second SubagentStart within the same phase writes a distinct
# file so both elapsed_ms values survive to SubagentStop.
date +%s%N >"/tmp/ticket-auto-${TICKET_ID}-start-${PHASE}-$(date +%s%N).ts"

# Best-effort telemetry — never block the agent that triggered this hook.
exit 0
