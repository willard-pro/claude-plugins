#!/usr/bin/env bash
# fleet-notify.sh — deterministic outbound Slack notifier for worker-reap-recovery.
# Sourceable bash library. Does NOT set -euo pipefail (caller controls error
# handling).
#
# Uses chat.postMessage (never an incoming webhook) — webhooks do not return
# the message `ts`, and without a thread_ts there is no thread to post
# follow-ups into. The returned ts is persisted per-ticket so later calls for
# the same tid reply into the same thread instead of opening a new one.
#
# Fail-soft everywhere: a missing/misconfigured channel or a transport
# failure degrades to a log-only line on stdout and returns 0. Never allowed
# to fail reaping, reconciliation, or the daemon loop that calls it.
#
# Dependencies: curl, python3 (JSON parse of the API response).

_NOTIFY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Masks a secret to presence + last 4 chars, matching fleet-env-check.sh's
# convention — never echo a bare token into logs.
_notify_mask() {
  local val="$1"
  local len=${#val}
  if [ "$len" -le 4 ]; then
    printf '****'
  else
    printf '****%s' "${val: -4}"
  fi
}

# fleet_slack_post <tid> <state_dir> <text>
# Posts <text> to SLACK_CHANNEL via chat.postMessage, threading into the
# stored ts for <tid> if one exists. Always returns 0.
fleet_slack_post() {
  local tid="$1" state_dir="$2" text="$3"

  if [ -z "${SLACK_BOT_TOKEN:-}" ] || [ -z "${SLACK_CHANNEL:-}" ]; then
    echo "fleet-notify: SLACK_BOT_TOKEN/SLACK_CHANNEL not configured — log-only: [${tid}] ${text}"
    return 0
  fi

  local thread_file="${state_dir}/${tid}-slack-thread.json"
  local thread_ts=""
  if [ -f "$thread_file" ]; then
    thread_ts=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('ts',''))" "$thread_file" 2>/dev/null || echo "")
  fi

  local payload
  payload=$(python3 -c "
import json, sys
channel, text, thread_ts = sys.argv[1], sys.argv[2], sys.argv[3]
body = {'channel': channel, 'text': text}
if thread_ts:
    body['thread_ts'] = thread_ts
print(json.dumps(body))
" "$SLACK_CHANNEL" "$text" "$thread_ts" 2>/dev/null) || {
    echo "fleet-notify: payload construction failed — log-only: [${tid}] ${text}"
    return 0
  }

  local response
  if ! response=$(curl -sS --max-time 10 \
    -H "Authorization: Bearer ${SLACK_BOT_TOKEN}" \
    -H "Content-Type: application/json; charset=utf-8" \
    -d "$payload" \
    https://slack.com/api/chat.postMessage 2>&1); then
    echo "fleet-notify: chat.postMessage transport failure (token=$(_notify_mask "$SLACK_BOT_TOKEN")) — log-only: [${tid}] ${text}"
    return 0
  fi

  local ok ts
  ok=$(python3 -c "import json,sys; print(json.loads(sys.argv[1]).get('ok', False))" "$response" 2>/dev/null || echo "False")
  if [ "$ok" != "True" ]; then
    echo "fleet-notify: chat.postMessage rejected — log-only: [${tid}] ${text}"
    return 0
  fi

  if [ -z "$thread_ts" ]; then
    ts=$(python3 -c "import json,sys; print(json.loads(sys.argv[1]).get('ts',''))" "$response" 2>/dev/null || echo "")
    if [ -n "$ts" ]; then
      printf '{"ts": "%s"}' "$ts" >"$thread_file" 2>/dev/null || true
    fi
  fi
  return 0
}

# fleet_notify_worker_event <tid> <state_dir> <event_type> [detail]
# event_type: "non-terminal-exit" | "dead-letter". Builds the message body
# from the ticket's exit record (when present) and pipeline log — observed
# facts only (task 7.4): ticket, phase, generation, elapsed, exit
# classification, recovery decision, captured final assistant message.
# Never called for a clean completion or a fleet-initiated kill.
fleet_notify_worker_event() {
  local tid="$1" state_dir="$2" event_type="$3" detail="${4:-}"

  local log_file="${state_dir}/${tid}-pipeline.log"
  local phase="unknown"
  if [ -f "$log_file" ]; then
    phase=$(awk -F'|' '{p=$2} END {print p}' "$log_file" 2>/dev/null)
    [ -z "$phase" ] && phase="unknown"
  fi

  local generation="" pid="" exit_code="" exit_type="" action="" last_msg=""
  local exit_file
  exit_file=$(ls "${state_dir}/${tid}"-gen*-exit.json 2>/dev/null | sort -V | tail -1)
  if [ -n "$exit_file" ] && [ -f "$exit_file" ]; then
    generation=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('generation',''))" "$exit_file" 2>/dev/null || echo "")
    exit_code=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('exit_code',''))" "$exit_file" 2>/dev/null || echo "")
    exit_type=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('exit_type',''))" "$exit_file" 2>/dev/null || echo "")
    action=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('action',''))" "$exit_file" 2>/dev/null || echo "")
    last_msg=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('last_assistant_message') or '')" "$exit_file" 2>/dev/null || echo "")
  fi

  local run_file="${state_dir}/${tid}-run.json"
  local elapsed="unknown"
  if [ -f "$run_file" ]; then
    local dispatched_at
    dispatched_at=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('started_at',''))" "$run_file" 2>/dev/null || echo "")
    if [ -n "$dispatched_at" ]; then
      elapsed=$(python3 -c "
import sys
from datetime import datetime, timezone
try:
    started = datetime.fromisoformat(sys.argv[1].replace('Z', '+00:00'))
    delta = datetime.now(timezone.utc) - started
    print(f'{int(delta.total_seconds())}s')
except Exception:
    print('unknown')
" "$dispatched_at" 2>/dev/null || echo "unknown")
    fi
  fi

  local header
  case "$event_type" in
  non-terminal-exit) header=":warning: worker exited without completing" ;;
  dead-letter) header=":x: worker dead-lettered" ;;
  *) header=":grey_question: worker event ($event_type)" ;;
  esac

  local text
  text=$(
    printf '%s\nticket: %s\nphase: %s\ngeneration: %s\nelapsed: %s\nexit: code=%s type=%s\nrecovery: %s' \
      "$header" "$tid" "$phase" "$generation" "$elapsed" "$exit_code" "$exit_type" "${action:-$detail}"
  )
  if [ -n "$detail" ] && [ "$event_type" = "dead-letter" ]; then
    text="${text}
reason: ${detail}"
  fi
  if [ -n "$last_msg" ]; then
    text="${text}
last message: ${last_msg}"
  fi

  fleet_slack_post "$tid" "$state_dir" "$text"
}
