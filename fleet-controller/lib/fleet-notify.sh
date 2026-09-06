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

# ── fleet_notify_hold (human-hold-protocol) ─────────────────────────────────
#
# fleet_notify_hold <tid> <state_dir> <transition>
# transition: "created" | "escalate"
#
# Built like fleet_notify_worker_event above: observed facts only — ticket,
# REASON, BLOCKS, and the numbered questions, read straight from the latest
# *valid* `META|human-hold` record in the pipeline log — never a
# classification of what the question means.
#
# Idempotency deliberately does NOT key off the fleet state store's
# `notify_state` column, even though design.md D7 names that column as the
# authoritative gate. Two things make that column unreachable from here: a
# bash library has no write access to the store (fleetd is its sole writer),
# and the store's `tickets` row carries no question/blocks text to put in
# the message anyway — this function needs the pipeline log regardless. It
# keeps its own per-ticket sidecar instead, `{tid}-hold-notify.json`,
# exactly the pattern `fleet_slack_post` above already uses for its own
# thread-ts bookkeeping. The observable guarantees the spec asks for are
# unaffected: one notification per hold, a daemon restart reads the same
# sidecar and sends nothing again, a failed send is retried on a later pass,
# and escalation fires once. The sidecar is keyed on a hash of the record's
# own payload (never a `hold_id` — neither this function nor the pipeline
# log ever carries one; the agent has none to give and fleetd mints it only
# on the row), so a genuinely new hold (a fresh `BLOCKS`/questions shape
# after a supersede) notifies again even though this function cannot see
# fleetd's minted id.
fleet_notify_hold() {
  local tid="$1" state_dir="$2" transition="$3"

  case "$transition" in
  created | escalate) ;;
  *)
    echo "fleet-notify: fleet_notify_hold: unknown transition '${transition}'" >&2
    return 1
    ;;
  esac

  local log_file="${state_dir}/${tid}-pipeline.log"
  local record_line
  record_line=$(command grep '|META|human-hold|waiting|' "$log_file" 2>/dev/null | tail -1)
  if [ -z "$record_line" ]; then
    echo "fleet-notify: fleet_notify_hold: no human-hold record for ${tid} — nothing to notify"
    return 0
  fi

  local held_at payload
  held_at=$(printf '%s' "$record_line" | cut -d'|' -f1)
  payload=$(printf '%s' "$record_line" | awk -F'|' '{s=$5; for(i=6;i<=NF;i++) s=s"|"$i; print s}')
  case "$payload" in
  *'"parse_status":"ok"'*) ;;
  *)
    echo "fleet-notify: fleet_notify_hold: latest human-hold record for ${tid} is not parse_status=ok — nothing to notify"
    return 0
    ;;
  esac

  local reason blocks questions_text
  reason=$(printf '%s' "$payload" | python3 -c "import json,sys; print(json.load(sys.stdin).get('reason',''))" 2>/dev/null) || reason=""
  blocks=$(printf '%s' "$payload" | python3 -c "import json,sys; print(json.load(sys.stdin).get('blocks',''))" 2>/dev/null) || blocks=""
  questions_text=$(printf '%s' "$payload" | python3 -c "
import json, sys
d = json.load(sys.stdin)
for q in d.get('questions', []):
    print('%s) %s' % (q.get('id'), q.get('text', '')))
" 2>/dev/null) || questions_text=""

  local hold_key
  if command -v sha256sum >/dev/null 2>&1; then
    hold_key=$(printf '%s' "$payload" | sha256sum | awk '{print $1}')
  else
    hold_key=$(printf '%s' "$payload" | shasum -a 256 | awk '{print $1}')
  fi

  local sidecar="${state_dir}/${tid}-hold-notify.json"
  local sidecar_key="" notify_state="" notified_at="" escalated_at=""
  if [ -f "$sidecar" ]; then
    sidecar_key=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('key',''))" "$sidecar" 2>/dev/null) || sidecar_key=""
    notify_state=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('notify_state',''))" "$sidecar" 2>/dev/null) || notify_state=""
    notified_at=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('notified_at') or '')" "$sidecar" 2>/dev/null) || notified_at=""
    escalated_at=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('escalated_at') or '')" "$sidecar" 2>/dev/null) || escalated_at=""
  fi
  # A different hold (superseded, or a fresh ask) resets bookkeeping — it is
  # a new thing to notify about even though no id distinguishes it here.
  if [ "$hold_key" != "$sidecar_key" ]; then
    notify_state=""
    notified_at=""
    escalated_at=""
  fi

  _notify_write_sidecar() {
    printf '{"key": "%s", "notify_state": "%s", "notified_at": "%s", "escalated_at": "%s"}' \
      "$hold_key" "$1" "$2" "$3" >"$sidecar" 2>/dev/null || true
  }

  local now
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  if [ "$transition" = "created" ]; then
    if [ "$notify_state" = "sent" ]; then
      return 0
    fi
    local text
    text=$(printf ':lock: *%s* is waiting on you\nReason: %s\nBlocks: %s\nQuestions:\n%s\n\nAnswer in a comment on the Linear ticket.' \
      "$tid" "$reason" "$blocks" "$questions_text")
    local out
    out=$(fleet_slack_post "$tid" "$state_dir" "$text" 2>&1)
    if [[ "$out" == *"log-only"* ]] || [[ "$out" == *"transport failure"* ]] || [[ "$out" == *"rejected"* ]] || [[ "$out" == *"construction failed"* ]]; then
      if [[ "$out" == *"not configured"* ]]; then
        # No Slack configuration at all degrades permanently — nothing will
        # ever succeed until an operator configures it, and retrying every
        # pass would just repeat the same log-only line forever.
        _notify_write_sidecar "sent" "$now" "$escalated_at"
      else
        _notify_write_sidecar "failed" "$notified_at" "$escalated_at"
      fi
    else
      _notify_write_sidecar "sent" "$now" "$escalated_at"
    fi
    echo "$out"
    return 0
  fi

  # transition = escalate
  if [ -n "$escalated_at" ]; then
    return 0
  fi
  local held_epoch now_epoch age_secs escalate_secs
  held_epoch=$(date -u -d "$held_at" +%s 2>/dev/null || echo "0")
  now_epoch=$(date -u +%s)
  age_secs=$((now_epoch - held_epoch))
  escalate_secs=$((${FLEET_HOLD_ESCALATE_HOURS:-24} * 3600))
  if [ "$age_secs" -lt "$escalate_secs" ]; then
    return 0
  fi
  local text
  text=$(printf ':rotating_light: *%s* has been waiting on you for %sh — still unanswered\nReason: %s\nBlocks: %s\nQuestions:\n%s\n\nAnswer in a comment on the Linear ticket.' \
    "$tid" "$((age_secs / 3600))" "$reason" "$blocks" "$questions_text")
  local out
  out=$(fleet_slack_post "$tid" "$state_dir" "$text" 2>&1)
  _notify_write_sidecar "$notify_state" "$notified_at" "$now"
  echo "$out"
  return 0
}
