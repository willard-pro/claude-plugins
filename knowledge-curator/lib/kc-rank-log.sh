#!/usr/bin/env bash
# kc-rank-log.sh — Ranking telemetry for the knowledge stack.
#
# Dual-purpose: source it for the append helpers, or run it for the report.
#
#   source kc-rank-log.sh          # provides kc_rank_log
#   kc-rank-log.sh stats [dir]     # prints the agreement report
#
# Why this exists: the `/kc` rank score (see lib/kc-render.sh) is a judgement
# call about weights that can only be validated against real behaviour. The
# question it answers is not "is the score correct" — unanswerable in the
# abstract — but "when the stack is rendered, does the human work on what the
# NEXT box picked?" That is a join between two events the plugin already owns:
# what kc-render.sh displayed, and what kc-item.sh claimed.
#
# Log format — pipe-delimited, append-only, mirrors the pipeline-log-format
# convention used across this repo:
#
#   ISO|EVENT|ITEM|RANKED|DETAIL
#
#   EVENT   render | claim | complete | release
#   ITEM    KC-NNNN, or `-` (render where every item was blocked)
#   RANKED  render only: display-order ids, NEXT first, capped at 10.
#           A `!` prefix marks an item that was demoted as blocked
#           (e.g. `KC-0003,!KC-0005,KC-0001`). `-` for non-render events.
#   DETAIL  render only: `total=N blocked=M`. `-` for non-render events.
#
# Writers are deliberately dumb — append one line, never fail. All
# classification lives in the reader, so telemetry can never break a render
# or a mutation. Every function returns 0; callers run `set -euo pipefail`
# and a non-zero return would abort them mid-work.
#
# Opt out entirely with KC_RANK_LOG=0.

KC_RANK_LOG_MAX="${KC_RANK_LOG_MAX:-1000}"

kc_rank_log_path() {
  local dir="${1:-${KNOWLEDGE_DIR:-knowledge}}"
  echo "${dir}/.kc-rank-log"
}

# Trim to the last KC_RANK_LOG_MAX lines once it drifts 200 over, so the
# rewrite is amortised rather than per-append.
kc_rank_log_trim() {
  local log="$1"
  local lines tmp
  lines=$(wc -l <"$log" 2>/dev/null) || return 0
  [ "$lines" -gt $((KC_RANK_LOG_MAX + 200)) ] || return 0
  tmp="${log}.tmp.$$"
  if tail -n "$KC_RANK_LOG_MAX" "$log" >"$tmp" 2>/dev/null; then
    mv -f "$tmp" "$log" 2>/dev/null || true
  fi
  rm -f "$tmp" 2>/dev/null || true
  return 0
}

# kc_rank_log <dir> <event> [item] [ranked] [detail]
kc_rank_log() {
  [ "${KC_RANK_LOG:-1}" = "0" ] && return 0

  local dir="${1:-}" event="${2:-}" item="${3:--}" ranked="${4:--}" detail="${5:--}"
  [ -z "$dir" ] || [ -z "$event" ] && return 0
  [ -d "$dir" ] || return 0

  # Strip the field delimiter and any newlines so one event is always one line.
  item=$(printf '%s' "$item" | tr -d '|\n')
  ranked=$(printf '%s' "$ranked" | tr -d '|\n')
  detail=$(printf '%s' "$detail" | tr -d '|\n')

  local log ts
  log=$(kc_rank_log_path "$dir")
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  printf '%s|%s|%s|%s|%s\n' \
    "$ts" "$event" "${item:--}" "${ranked:--}" "${detail:--}" \
    >>"$log" 2>/dev/null || return 0

  kc_rank_log_trim "$log"
  return 0
}

# ── Report ───────────────────────────────────────────────────────────
#
# Classifies every claim against the most recent preceding render:
#   pos 1      → the NEXT box was claimed (the formula agreed with you)
#   pos 2-3    → claimed from the top of the stack
#   pos 4+     → claimed further down (records average depth)
#   not shown  → item was off-screen or created after the render
#   no render  → claimed without looking at the stack at all
#
# Reports facts only. Whether 60% NEXT-agreement is good is your call, not
# the script's — there is no threshold worth hard-coding here.

kc_rank_log_stats() {
  local dir="${1:-${KNOWLEDGE_DIR:-knowledge}}"
  local log
  log=$(kc_rank_log_path "$dir")

  if [ ! -f "$log" ]; then
    echo "No ranking telemetry yet at ${log}."
    echo "It accumulates as you run /kc and claim items — check back after a week of use."
    return 0
  fi

  awk -F'|' '
    BEGIN { renders=0; claims=0; hit=0; top3=0; deeper=0; unranked=0; cold=0
            blocked_claims=0; sumpos=0; have_render=0; first_ts=""; last_ts="" }
    NF < 5 { next }
    { if (first_ts == "") first_ts=$1; last_ts=$1 }

    $2 == "render" {
      renders++
      have_render=1
      next_id=$3
      ranked=$4
      nranked=split(ranked, arr, ",")
      delete pos_of
      delete was_blocked
      for (i = 1; i <= nranked; i++) {
        id = arr[i]
        if (substr(id, 1, 1) == "!") { id = substr(id, 2); was_blocked[id]=1 }
        if (!(id in pos_of)) pos_of[id] = i
      }
      next
    }

    $2 == "claim" {
      claims++
      id=$3
      if (!have_render) { cold++; next }
      if (id in was_blocked) blocked_claims++
      p = (id in pos_of) ? pos_of[id] : 0
      if (p == 1)      hit++
      else if (p <= 3 && p > 0) top3++
      else if (p > 3)  { deeper++; sumpos += p }
      else             unranked++
      next
    }

    END {
      pct = (claims > 0) ? 100 / claims : 0
      printf "RANKING TELEMETRY"
      if (first_ts != "") printf "     %s → %s", substr(first_ts,1,10), substr(last_ts,1,10)
      printf "\n\n"
      printf "  %d renders · %d claims\n\n", renders, claims

      if (claims == 0) {
        print "  No claims logged yet — nothing to compare the ranking against."
        exit 0
      }

      printf "  NEXT box claimed         %4d  (%3.0f%%)\n", hit, hit*pct
      printf "  claimed from top 3       %4d  (%3.0f%%)\n", top3, top3*pct
      if (deeper > 0)
        printf "  claimed further down     %4d  (%3.0f%%)   avg position %.1f\n", deeper, deeper*pct, sumpos/deeper
      else
        printf "  claimed further down     %4d  (%3.0f%%)\n", deeper, deeper*pct
      printf "  not on screen            %4d  (%3.0f%%)\n", unranked, unranked*pct
      printf "  claimed without a render %4d  (%3.0f%%)\n", cold, cold*pct
      printf "\n"
      printf "  claims of blocked items  %4d\n", blocked_claims
      printf "\n"
      print  "  Reading it: high NEXT agreement means the score matches how you actually"
      print  "  work. Lots of \"further down\" means the weights are off — check the avg"
      print  "  position. Blocked-item claims mean the blocked penalty is too harsh."
      print  ""
      print  "  Formula (lib/kc-render.sh):"
      print  "    score = priority(p1=200 p2=100 p3=20) + min(age_days,60) - 60*blocked"
    }
  ' "$log"

  return 0
}

# ── Dispatch (only when executed, not sourced) ───────────────────────

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  set -euo pipefail
  case "${1:-stats}" in
  stats) kc_rank_log_stats "${2:-knowledge}" ;;
  path) kc_rank_log_path "${2:-knowledge}" ;;
  *)
    echo "Usage: kc-rank-log.sh [stats|path] [knowledge_dir]" >&2
    exit 1
    ;;
  esac
fi
