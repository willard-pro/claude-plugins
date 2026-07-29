#!/usr/bin/env bash
# kc-render.sh — Deterministic ASCII stack renderer for the knowledge store.
#
# Usage: kc-render.sh [knowledge_dir]
#        kc-render.sh --stats [knowledge_dir]
#   knowledge_dir defaults to ./knowledge
#
# Reads item files directly (not INDEX.md) so it can show the `why` field
# and full relation type — both dropped by INDEX.md's compact table format.
# Ranks active/in_progress/dormant items and renders them as a stack with
# the most actionable item highlighted. Pure bash/awk, no LLM involvement —
# the view is stable across runs, matching the "bash gates" determinism
# boundary used elsewhere in this repo.
#
# Ranking: score = priority_weight + age_bonus - blocked_penalty
#   priority_weight: p1=200, p2=100, p3=20
#   age_bonus: min(age_days, 60) — old items slowly float up so nothing rots
#     silently at the bottom of a priority tier
#   blocked_penalty: 60 if the item has an unresolved `depends` relation
#     (target exists and is not `done`) — demotes but never hides
#
# All weights are doubled relative to the natural formulation (p1=100 / age×0.5
# / penalty 30) purely to keep the arithmetic in bash integers. Ranking is
# identical; only the printed magnitudes differ. Practical effect: a p3 that has
# sat for 60 days outranks a blocked p2, and a blocked p1 still loses to an
# unblocked one but never drops below its tier.
#
# The weights are a judgement call, not a derived optimum. lib/kc-rank-log.sh
# records what this renderer picked against what actually got claimed, so they
# can be retuned from evidence — see `/kc stats`.
#
# Exit codes:
#   0 - rendered (including empty store or missing directory)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/kc-rank-log.sh"

# --stats delegates to the telemetry reader — it is the ranking's own report
# card, so it lives behind the same entry point that produces the ranking.
if [ "${1:-}" = "--stats" ]; then
  kc_rank_log_stats "${2:-knowledge}"
  exit 0
fi

KNOWLEDGE_DIR="${1:-knowledge}"

if [ ! -d "$KNOWLEDGE_DIR" ]; then
  echo "No knowledge/ directory found. Capture something first with /kc-capture."
  exit 0
fi

NOW_EPOCH=$(date -u +%s)

# ── Extract frontmatter field (mirrors kc-index.sh) ────────────────────

extract_field() {
  local file="$1"
  local field="$2"
  awk -v field="${field}" '
    BEGIN { in_fm=0; in_list=0; in_dash_list=0 }
    /^---$/ { if (in_fm==0) { in_fm=1; next } else { exit } }
    in_fm==1 && $1 == field":" {
      sub(/^[^:]+:[[:space:]]*/, "")
      if ($0 != "") {
        print
        if ($0 ~ /^\[/ && $0 !~ /\]/) { in_list=1 }
        if ($0 !~ /^\[/ || $0 ~ /\]/) { exit }
      } else {
        in_dash_list=1
      }
      next
    }
    in_list==1 {
      sub(/^[[:space:]]*/, "")
      print
      if ($0 ~ /\]/) { exit }
      next
    }
    in_dash_list==1 {
      if ($0 ~ /^[[:space:]]/ || $0 ~ /^[[:space:]]*-/) {
        sub(/^[[:space:]]*/, "")
        print
        next
      }
      if ($0 !~ /^[[:space:]]/ && $0 != "") { exit }
    }
  ' "$file" 2>/dev/null || true
}

strip_quotes() {
  sed 's/^"//;s/"$//;s/^'"'"'//;s/'"'"'$//'
}

rel_glyph() {
  case "$1" in
  depends) echo "└─" ;;
  supersedes) echo "⤳" ;;
  contradicts) echo "✗" ;;
  alternative) echo "~" ;;
  extends) echo "⊃" ;;
  refines) echo "↺" ;;
  discovered-from) echo "↳" ;;
  *) echo "·" ;;
  esac
}

priority_weight() {
  case "$1" in
  p1) echo 100 ;;
  p2) echo 50 ;;
  p3) echo 10 ;;
  *) echo 0 ;;
  esac
}

age_days() {
  local updated="$1"
  local ts
  ts=$(date -u -d "$updated" +%s 2>/dev/null) || {
    echo 0
    return
  }
  echo $(((NOW_EPOCH - ts) / 86400))
}

truncate_title() {
  local title="$1"
  local max=54
  if [ "${#title}" -gt "$max" ]; then
    echo "${title:0:$((max - 1))}…"
  else
    echo "$title"
  fi
}

# ── Pass 1: build id → title/status maps across ALL items ─────────────
# (needed to resolve relation targets and blocked status even when the
# target itself is done/obsolete and therefore not in the stack view)

declare -A TITLE_OF
declare -A STATUS_OF

for item_file in "$KNOWLEDGE_DIR"/KC-[0-9][0-9][0-9][0-9]--*.md; do
  [ -f "$item_file" ] || continue
  id=$(extract_field "$item_file" "id" | strip_quotes)
  [ -z "$id" ] && continue
  TITLE_OF["$id"]=$(extract_field "$item_file" "title" | strip_quotes)
  STATUS_OF["$id"]=$(extract_field "$item_file" "status" | strip_quotes)
done

# ── Pass 2: collect stack-visible items, compute rank ──────────────────

TAB="	"
ROWS_TMP=$(mktemp)
trap 'rm -f "$ROWS_TMP"' EXIT

total=0
p1_count=0
in_progress_count=0
blocked_count=0

for item_file in "$KNOWLEDGE_DIR"/KC-[0-9][0-9][0-9][0-9]--*.md; do
  [ -f "$item_file" ] || continue

  id=$(extract_field "$item_file" "id" | strip_quotes)
  type=$(extract_field "$item_file" "type" | strip_quotes)
  title=$(extract_field "$item_file" "title" | strip_quotes)
  status=$(extract_field "$item_file" "status" | strip_quotes)
  priority=$(extract_field "$item_file" "priority" | strip_quotes)
  updated=$(extract_field "$item_file" "updated" | strip_quotes)
  why=$(extract_field "$item_file" "why" | strip_quotes)
  relates=$(extract_field "$item_file" "relates" | tr '\n' ' ' | sed 's/  */ /g; s/^ *//; s/ *$//')

  if [ -z "$id" ] || [ -z "$type" ] || [ -z "$title" ] || [ -z "$status" ] || [ -z "$priority" ]; then
    continue
  fi
  if [ "$status" = "done" ] || [ "$status" = "obsolete" ]; then
    continue
  fi

  total=$((total + 1))
  [ "$priority" = "p1" ] && p1_count=$((p1_count + 1))
  [ "$status" = "in_progress" ] && in_progress_count=$((in_progress_count + 1))

  days=$(age_days "$updated")
  age_bonus=$((days > 60 ? 60 : days))

  # Blocked: has a `depends` relation whose target exists and isn't done
  blocked=0
  pairs=$( (echo "$relates" | grep -oE 'rel: [a-zA-Z_-]+ id: KC-[0-9]{4}') || true)
  while IFS= read -r pair; do
    [ -z "$pair" ] && continue
    rel=$(echo "$pair" | sed -E 's/rel: ([a-zA-Z_-]+).*/\1/')
    target=$(echo "$pair" | sed -E 's/.*id: (KC-[0-9]{4})/\1/')
    if [ "$rel" = "depends" ]; then
      target_status="${STATUS_OF[$target]:-}"
      if [ -n "$target_status" ] && [ "$target_status" != "done" ]; then
        blocked=1
      fi
    fi
  done <<<"$pairs"

  [ "$blocked" = "1" ] && blocked_count=$((blocked_count + 1))

  weight=$(priority_weight "$priority")
  score=$((weight * 2 + age_bonus - (blocked * 60)))

  # Sort key: score descending (store negated for ascending sort), then updated ascending
  neg_score=$((-score))

  printf '%d\t%s\t%s\t%s\t%s\t%s\t%s\t%d\t%s\t%d\t%s\n' \
    "$neg_score" "$updated" "$id" "$type" "$title" "$status" "$priority" "$days" "$why" "$blocked" "$relates" >>"$ROWS_TMP"
done

# ── Render ───────────────────────────────────────────────────────────

repo_label=$(basename "$(cd "$KNOWLEDGE_DIR/.." && pwd)" 2>/dev/null || echo "")

if [ "$total" -eq 0 ]; then
  echo "KNOWLEDGE STACK${repo_label:+ — $repo_label}"
  echo ""
  echo "No outstanding items. Capture one with /kc-capture."
  exit 0
fi

echo "KNOWLEDGE STACK${repo_label:+ — $repo_label}    ${total} items · ${p1_count} p1 · ${in_progress_count} in_progress"
echo ""

SORTED=$(sort -t"${TAB}" -k1,1n -k2,2 "$ROWS_TMP")

# Find the first unblocked row's id — that's what goes in the NEXT box.
next_id=$(echo "$SORTED" | while IFS="${TAB}" read -r _ _ id _ _ _ _ _ _ blocked _; do
  if [ "$blocked" = "0" ]; then
    echo "$id"
    break
  fi
done)

# Record what this render put on screen, in display order (NEXT first), so
# `/kc stats` can later ask whether the claimed item was the one promoted.
# `!` marks an item demoted as blocked. Capped at 10 — past that, "you claimed
# something off-screen" is the same signal regardless of exact depth.
# (`next_item`, not `next` — the latter is an awk keyword and cannot be -v assigned)
ranked_ids=$(echo "$SORTED" | awk -F"$TAB" -v next_item="$next_id" '
  {
    mark = ($10 == "1" ? "!" : "")
    if ($3 == next_item) first = mark $3
    else rest[++n] = mark $3
  }
  END {
    out = first
    cap = (first != "" ? 9 : 10)
    for (i = 1; i <= n && i <= cap; i++) out = (out == "" ? rest[i] : out "," rest[i])
    print out
  }
')

kc_rank_log "$KNOWLEDGE_DIR" render "${next_id:--}" "${ranked_ids:--}" \
  "total=${total} blocked=${blocked_count}"

render_relations() {
  local relates="$1"
  local shown=0
  local pairs
  pairs=$( (echo "$relates" | grep -oE 'rel: [a-zA-Z_-]+ id: KC-[0-9]{4}') || true)
  while IFS= read -r pair; do
    [ -z "$pair" ] && continue
    [ "$shown" -ge 2 ] && {
      echo "           …"
      return
    }
    local rel target glyph target_title target_status suffix
    rel=$(echo "$pair" | sed -E 's/rel: ([a-zA-Z_-]+).*/\1/')
    target=$(echo "$pair" | sed -E 's/.*id: (KC-[0-9]{4})/\1/')
    glyph=$(rel_glyph "$rel")
    target_title="${TITLE_OF[$target]:-}"
    target_status="${STATUS_OF[$target]:-}"
    suffix=""
    [ "$target_status" = "done" ] && suffix=" [done]"
    if [ -n "$target_title" ]; then
      echo "           ${glyph} ${rel}  ${target}  ${target_title}${suffix}"
    else
      echo "           ${glyph} ${rel}  ${target}${suffix}"
    fi
    shown=$((shown + 1))
  done <<<"$pairs"
}

compute_flags() {
  local status="$1" priority="$2" days="$3" blocked="$4"
  local flags=""
  if [ "$priority" = "p1" ] && [ "$days" -ge 14 ]; then
    flags="${flags} ⚠"
  fi
  if [ "$status" = "dormant" ] || [ "$days" -ge 60 ]; then
    flags="${flags} 💤"
  fi
  if [ "$blocked" = "1" ]; then
    flags="${flags} ▲"
  fi
  echo "$flags"
}

render_row() {
  local id="$1" type="$2" title="$3" status="$4" priority="$5" days="$6" why="$7" blocked="$8" relates="$9"
  local flags
  flags=$(compute_flags "$status" "$priority" "$days" "$blocked")

  printf '  %-8s %-10s %-54s %-3s %3sd%s\n' \
    "$id" "$type" "$(truncate_title "$title")" "$priority" "$days" "$flags"
  [ -n "$why" ] && echo "           why: ${why}"
  render_relations "$relates"
}

# Open box (no right border) — sidesteps unicode-width padding math entirely,
# since emoji/glyphs render at variable terminal-column widths regardless of
# their single-codepoint string length.
if [ -n "$next_id" ]; then
  next_row=$(echo "$SORTED" | awk -F"$TAB" -v id="$next_id" '$3==id')
  IFS="${TAB}" read -r _ _ id type title status priority days why blocked relates <<<"$next_row"
  flags=$(compute_flags "$status" "$priority" "$days" "$blocked")
  echo "┌─ NEXT ────────────────────────────────────────────────────────────"
  printf '│ %-8s %-10s %-54s %-3s %3sd%s\n' "$id" "$type" "$(truncate_title "$title")" "$priority" "$days" "$flags"
  [ -n "$why" ] && echo "│          why: ${why}"
  echo "└──────────────────────────────────────────────────────────────────"
  render_relations "$relates"
  echo ""
else
  echo "⚠ All outstanding items are blocked on something else."
  echo ""
fi

prev_priority=""
echo "$SORTED" | while IFS="${TAB}" read -r _ updated id type title status priority days why blocked relates; do
  [ "$id" = "$next_id" ] && continue
  if [ -n "$prev_priority" ] && [ "$prev_priority" != "$priority" ]; then
    echo "  ── ${priority} ──"
  fi
  render_row "$id" "$type" "$title" "$status" "$priority" "$days" "$why" "$blocked" "$relates"
  prev_priority="$priority"
done

echo ""
echo "⚠ = p1 untouched 14d+   💤 = dormant/idle 60d+   ▲ = blocked on an open dependency"

exit 0
