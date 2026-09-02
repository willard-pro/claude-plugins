#!/bin/bash
# SessionStart hook — age-based sweep of the pipeline's /tmp scratch files.
#
# spawn_agent_pre writes three per-ticket scratch files (ctx, spawn-meta, env)
# and token-tracker-start.sh writes one start-timestamp file per subagent
# spawn. None of them can be deleted at spawn_agent_post time:
#   - env.sh is sourced by every later phase of the same ticket,
#   - spawn-meta is re-read by duplicate spawn_agent_post calls (idempotency
#     tail-check) and by tool-error-capture.sh,
#   - ctx.txt is read by tool-error-capture.sh for the whole run.
# So their lifetime is bounded by age instead: a ticket's whole file group is
# removed once *none* of its files has been touched for TTL minutes. Grouping
# by ticket rather than pruning file-by-file is what keeps a long-running
# ticket's env.sh alive — its mtime is from run start, while spawn_agent_pre
# keeps rewriting ctx/spawn-meta on every phase.
#
# Only the four file types this pipeline writes per spawn are considered.
# Progress files, stop files and flow locks share the /tmp/ticket-auto-*
# namespace and are deliberately left alone.
#
# Overrides (both used by the unit tests, and TTL by operators):
#   TICKET_TMP_DIR      — directory to sweep (default /tmp)
#   TICKET_TMP_TTL_MIN  — TTL in minutes (default 1440 = 24h)
#
# -u (nounset) intentionally omitted: Claude Code shell snapshots inject
# ZSH_VERSION references that trigger false-positive "unbound variable"
# errors in this bash version when nounset is active.
set -eo pipefail

TMP_DIR="${TICKET_TMP_DIR:-/tmp}"
TTL_MIN="${TICKET_TMP_TTL_MIN:-1440}"
# Non-numeric or empty TTL falls back to the default rather than producing a
# garbage cutoff that would sweep live files.
case "$TTL_MIN" in
'' | *[!0-9]*) TTL_MIN=1440 ;;
esac

[ -d "$TMP_DIR" ] || exit 0

# Map a scratch-file basename to the ticket it belongs to. Returns 1 for any
# name that is not one of the four managed types, so unrelated
# ticket-auto-* files are never touched.
_sweep_ticket_id() {
  local b="${1#ticket-auto-}"
  case "$b" in
  *-ctx.txt) b="${b%-ctx.txt}" ;;
  *-spawn-meta.txt) b="${b%-spawn-meta.txt}" ;;
  *-env.sh) b="${b%-env.sh}" ;;
  *-start-*.ts) b="${b%-start-*}" ;;
  *) return 1 ;;
  esac
  [ -n "$b" ] || return 1
  printf '%s' "$b"
}

_sweep_mtime() {
  stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo 0
}

CUTOFF=$(($(date +%s) - TTL_MIN * 60))

declare -A NEWEST=()
FILES=()
IDS=()

shopt -s nullglob
for f in "$TMP_DIR"/ticket-auto-*; do
  [ -f "$f" ] || continue
  id=$(_sweep_ticket_id "$(basename "$f")") || continue
  mtime=$(_sweep_mtime "$f")
  FILES+=("$f")
  IDS+=("$id")
  if [ -z "${NEWEST[$id]}" ] || [ "$mtime" -gt "${NEWEST[$id]}" ]; then
    NEWEST["$id"]=$mtime
  fi
done

removed=0
i=0
while [ "$i" -lt "${#FILES[@]}" ]; do
  id="${IDS[$i]}"
  if [ "${NEWEST[$id]}" -lt "$CUTOFF" ]; then
    rm -f -- "${FILES[$i]}" 2>/dev/null && removed=$((removed + 1)) || true
  fi
  i=$((i + 1))
done

# stderr only — SessionStart hook stdout is injected into the session context.
[ "$removed" -gt 0 ] && echo "ticket-auto: swept $removed stale scratch file(s) from $TMP_DIR" >&2

# Best-effort housekeeping — never block session start.
exit 0
