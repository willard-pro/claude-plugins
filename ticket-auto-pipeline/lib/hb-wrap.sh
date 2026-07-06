#!/usr/bin/env bash
# hb-wrap.sh — single-command heartbeat wrapper for agent use.
# Agents call this instead of sourcing heartbeat.sh and calling hb_* directly.
# Usage: hb-wrap.sh <category> <event> <status> <msg> [detail]
#
# Categories: decision, fallback, heartbeat, api, gate, retry, source
# No-op when HB_LOG_FILE is unset.
# Shell flags intentionally NOT set — this is a sourceable library.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source heartbeat.sh for hb_* functions
if [ -f "$SCRIPT_DIR/heartbeat.sh" ]; then
  source "$SCRIPT_DIR/heartbeat.sh"
else
  echo "hb-wrap.sh: cannot find heartbeat.sh at $SCRIPT_DIR/heartbeat.sh" >&2
  exit 1
fi

# No-op when HB_LOG_FILE is unset
[ -z "${HB_LOG_FILE:-}" ] && exit 0

CATEGORY="${1:-}"
EVENT="${2:-}"
STATUS="${3:-}"
MSG="${4:-}"
DETAIL="${5:-}"

# Validate required args
if [ -z "$CATEGORY" ] || [ -z "$EVENT" ] || [ -z "$STATUS" ]; then
  echo "hb-wrap.sh: missing required argument (category, event, or status)" >&2
  echo "Usage: hb-wrap.sh <category> <event> <status> <msg> [detail]" >&2
  exit 1
fi

# Validate category enum
VALID=0
for c in $_HB_CATEGORIES; do
  [ "$c" = "$CATEGORY" ] && VALID=1 && break
done
if [ "$VALID" -eq 0 ]; then
  echo "hb-wrap.sh: invalid category '$CATEGORY' (valid: $_HB_CATEGORIES)" >&2
  exit 1
fi

# Dispatch to appropriate hb_* function
case "$CATEGORY" in
decision) hb_decision "$EVENT" "$STATUS" "$MSG" "$DETAIL" ;;
fallback) hb_fallback "$EVENT" "$STATUS" "$MSG" "$DETAIL" ;;
heartbeat) hb_heartbeat "$EVENT" "${MSG:-$STATUS}" ;;
api) hb_api "$EVENT" "$STATUS" "$MSG" "$DETAIL" ;;
gate) hb_gate "$EVENT" "$STATUS" "$MSG" "$DETAIL" ;;
retry) hb_retry "$EVENT" "$STATUS" "$MSG" "$DETAIL" ;;
source) hb_source "$EVENT" "$STATUS" "$MSG" "$DETAIL" ;;
*)
  echo "hb-wrap.sh: unhandled category '$CATEGORY'" >&2
  exit 1
  ;;
esac
