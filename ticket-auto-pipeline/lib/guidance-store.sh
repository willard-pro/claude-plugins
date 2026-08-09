#!/usr/bin/env bash
# guidance-store.sh — durable guidance store for ticket-auto RLVR feedback loop.
# Provides CRUD operations for guidance entries accumulated across pipeline runs.
# JSONL-per-component format under ~/.claude/state/ticket-auto/guidance/.
# All operations are flock-guarded and fail-soft — the store never blocks the pipeline.
# -u intentionally omitted: Claude Code shell snapshots inject ZSH_VERSION references
# that trigger false-positive "unbound variable" errors.
set -eo pipefail

GUIDANCE_DIR="${GUIDANCE_DIR:-$HOME/.claude/state/ticket-auto/guidance}"
GC_LINE_THRESHOLD=200
GC_AGE_DAYS=90

# ── _derive_filename ─────────────────────────────────────────────────────────────
# Replaces / with - in component path, appends .jsonl.
#   lib/gate-check.sh → lib-gate-check.sh.jsonl
#   skills/ticket-implement/SKILL.md → skills-ticket-implement-SKILL.md.jsonl
_derive_filename() {
  local component="$1"
  echo "${component//\//-}.jsonl"
}

# ── _ensure_dir ──────────────────────────────────────────────────────────────────
_ensure_dir() {
  mkdir -p "$GUIDANCE_DIR" 2>/dev/null || true
}

# ── _compute_guidance_id ─────────────────────────────────────────────────────────
# Stable hash of component + root_cause + pattern. Same defect detected across
# multiple runs produces the same ID, enabling idempotent upsert.
_compute_guidance_id() {
  local component="$1" root_cause="$2" pattern="$3"
  echo "${component}|${root_cause}|${pattern}" | sha256sum | cut -c1-16
}

# ── _now_iso ─────────────────────────────────────────────────────────────────────
_now_iso() {
  date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date +%Y-%m-%dT%H:%M:%SZ
}

# ── _cutoff_iso ──────────────────────────────────────────────────────────────────
# Returns ISO timestamp for GC_AGE_DAYS ago.
_cutoff_iso() {
  local cutoff_epoch
  cutoff_epoch=$(date -d "$GC_AGE_DAYS days ago" +%s 2>/dev/null) || {
    cutoff_epoch=$(($(date +%s 2>/dev/null || echo 0) - GC_AGE_DAYS * 86400))
  }
  date -d "@$cutoff_epoch" -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || {
    # Fallback: compute manually (doesn't handle DST, good enough for GC)
    date -d "@$cutoff_epoch" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "1970-01-01T00:00:00Z"
  }
}

# ── guidance_upsert ──────────────────────────────────────────────────────────────
# Idempotent write of a guidance entry. If an entry with the same guidance_id
# already exists in the component file, the existing line is replaced (evidence_tickets
# merged, updated_at refreshed). If no match, the entry is appended.
# Usage: guidance_upsert '<json-entry>'
# Exit: 0 always (fail-soft — never blocks the pipeline)
guidance_upsert() {
  local json_entry="$1"

  # Parse required fields
  local guidance_id component
  guidance_id=$(echo "$json_entry" | jq -r '.guidance_id // empty' 2>/dev/null) || true
  component=$(echo "$json_entry" | jq -r '.component // empty' 2>/dev/null) || true

  if [[ -z "$guidance_id" || -z "$component" ]]; then
    echo "guidance_upsert: guidance_id and component required in JSON entry" >&2
    return 0
  fi

  _ensure_dir

  local filename filepath lockfile
  filename=$(_derive_filename "$component")
  filepath="$GUIDANCE_DIR/$filename"
  lockfile="$filepath.lock"

  # Acquire lock with 5s timeout
  exec 9>"$lockfile" || {
    echo "guidance_upsert: cannot create lock file for $filename" >&2
    return 0
  }

  if ! flock -w 5 9 2>/dev/null; then
    echo "guidance_upsert: lock timeout (5s) for $filename" >&2
    exec 9>&-
    return 0
  fi

  local tmpfile="$filepath.tmp.$$"
  local found=false
  local now_ts
  now_ts=$(_now_iso)

  if [[ -f "$filepath" ]]; then
    while IFS= read -r line; do
      # Skip empty lines
      [[ -z "$line" ]] && continue
      local existing_id
      existing_id=$(echo "$line" | jq -r '.guidance_id // empty' 2>/dev/null) || continue
      if [[ "$existing_id" == "$guidance_id" ]]; then
        # Merge: preserve existing fields not in new entry, merge evidence_tickets, update timestamp
        local merged
        merged=$(printf '%s\n%s\n' "$line" "$json_entry" | jq -cs --arg ts "$now_ts" '
          .[0] as $old | .[1] as $new |
          $old * $new |
          .status = $old.status |
          .transitions = $old.transitions |
          .evidence_tickets = (($old.evidence_tickets // []) + ($new.evidence_tickets // []) | unique) |
          .updated_at = ($new.updated_at // $ts) |
          .created_at = ($old.created_at // $ts)
        ' 2>/dev/null) || merged="$line"
        echo "$merged" >>"$tmpfile"
        found=true
      else
        echo "$line" >>"$tmpfile"
      fi
    done <"$filepath"
  fi

  if [[ "$found" == false ]]; then
    # Append: copy existing content, then append new entry with timestamps
    if [[ -f "$filepath" ]]; then
      cat "$filepath" >"$tmpfile" 2>/dev/null || true
    fi
    local stamped
    stamped=$(echo "$json_entry" | jq -c \
      --arg ts "$now_ts" \
      '.created_at = (.created_at // $ts) | .updated_at = (.updated_at // $ts)' 2>/dev/null) || {
      echo "guidance_upsert: failed to stamp timestamps — entry skipped for $guidance_id" >&2
      rm -f "$tmpfile"
      exec 9>&-
      return 0
    }
    echo "$stamped" >>"$tmpfile"
  fi

  # Atomic replace
  if ! mv "$tmpfile" "$filepath" 2>/dev/null; then
    echo "guidance_upsert: atomic replace failed for $filename" >&2
    rm -f "$tmpfile"
    exec 9>&-
    return 0
  fi

  # ── Lazy GC: sweep deprecated entries older than threshold ──
  local line_count
  line_count=$(wc -l <"$filepath" 2>/dev/null || echo 0)
  if [[ "$line_count" -gt "$GC_LINE_THRESHOLD" ]]; then
    local cutoff
    cutoff=$(_cutoff_iso)
    jq -c --arg cutoff "$cutoff" '
      select(.status != "deprecated" or .updated_at >= $cutoff)
    ' "$filepath" >"$tmpfile" 2>/dev/null || {
      rm -f "$tmpfile"
      exec 9>&-
      return 0
    }
    mv "$tmpfile" "$filepath" 2>/dev/null || true

    local after_count
    after_count=$(wc -l <"$filepath" 2>/dev/null || echo 0)
    if [[ "$after_count" -gt "$GC_LINE_THRESHOLD" ]]; then
      echo "guidance_upsert: WARNING — $filename has $after_count active entries after GC (threshold: $GC_LINE_THRESHOLD)" >&2
    fi
  fi

  exec 9>&-
  return 0
}

# ── guidance_query ───────────────────────────────────────────────────────────────
# Read guidance entries with optional filters. Output is line-delimited JSON.
# Usage: guidance_query [--component <name>] [--root-cause <type>] [--status <status>]
#                        [--since <ISO-date>] [--limit <N>]
# Exit: 0 (results or no results), 3 (jq missing)
guidance_query() {
  local component="" root_cause="" status="" since="" limit=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
    --component)
      component="$2"
      shift 2
      ;;
    --root-cause)
      root_cause="$2"
      shift 2
      ;;
    --status)
      status="$2"
      shift 2
      ;;
    --since)
      since="$2"
      shift 2
      ;;
    --limit)
      limit="$2"
      shift 2
      ;;
    *) shift ;;
    esac
  done

  # jq is required for query filtering
  if ! command -v jq &>/dev/null; then
    echo "guidance_query: jq required for guidance query" >&2
    return 3
  fi

  _ensure_dir

  # Build file list
  local files=()
  if [[ -n "$component" ]]; then
    local f
    f="$GUIDANCE_DIR/$(_derive_filename "$component")"
    [[ -f "$f" ]] && files=("$f")
  else
    shopt -s nullglob
    for f in "$GUIDANCE_DIR"/*.jsonl; do
      files+=("$f")
    done
    shopt -u nullglob
  fi

  # Build jq filter using --arg to prevent injection (never interpolate into filter strings)
  local jq_args=()
  local jq_filter=""
  [[ -n "$root_cause" ]] && jq_args+=(--arg rc "$root_cause") && jq_filter+='($rc == "" or .root_cause == $rc) and '
  [[ -n "$status" ]] && jq_args+=(--arg st "$status") && jq_filter+='($st == "" or .status == $st) and '
  [[ -n "$since" ]] && jq_args+=(--arg since "$since") && jq_filter+='($since == "" or .updated_at >= $since) and '
  jq_filter="select(${jq_filter}true)"

  local line_no=0
  local output_count=0

  for filepath in "${files[@]}"; do
    line_no=0
    while IFS= read -r line; do
      line_no=$((line_no + 1))
      [[ -z "$line" ]] && continue

      local result
      result=$(echo "$line" | jq -c "${jq_args[@]}" "$jq_filter" 2>/dev/null) || {
        echo "guidance_query: skipping unparseable line $line_no in $(basename "$filepath")" >&2
        continue
      }

      if [[ -n "$result" ]]; then
        echo "$result"
        output_count=$((output_count + 1))
        if [[ -n "$limit" && "$output_count" -ge "$limit" ]]; then
          return 0
        fi
      fi
    done <"$filepath"
  done

  return 0
}

# ── _find_entry ──────────────────────────────────────────────────────────────────
# Finds a guidance entry by guidance_id across all component files.
# Outputs "filepath:line_number" to stdout if found, nothing otherwise.
_find_entry() {
  local target_id="$1"
  local line_no

  shopt -s nullglob
  for filepath in "$GUIDANCE_DIR"/*.jsonl; do
    line_no=0
    while IFS= read -r line; do
      line_no=$((line_no + 1))
      [[ -z "$line" ]] && continue
      local eid
      eid=$(echo "$line" | jq -r '.guidance_id // empty' 2>/dev/null) || continue
      if [[ "$eid" == "$target_id" ]]; then
        echo "${filepath}:${line_no}"
        shopt -u nullglob
        return 0
      fi
    done <"$filepath"
  done
  shopt -u nullglob
  return 1
}

# ── guidance_confirm ─────────────────────────────────────────────────────────────
# Promote a proposed guidance entry to confirmed with an evidence ticket.
# Usage: guidance_confirm <guidance_id> <ticket>
# Exit: 0 confirmed, 1 not found, 2 already confirmed/deprecated
guidance_confirm() {
  local guidance_id="$1" ticket="$2"

  if [[ -z "$guidance_id" || -z "$ticket" ]]; then
    echo "guidance_confirm: guidance_id and ticket required" >&2
    return 2
  fi

  _ensure_dir

  local location
  location=$(_find_entry "$guidance_id") || {
    echo "guidance_confirm: guidance entry not found: $guidance_id" >&2
    return 1
  }

  local filepath="${location%%:*}"
  local target_line="${location##*:}"
  local lockfile="$filepath.lock"

  exec 9>"$lockfile" || {
    echo "guidance_confirm: cannot create lock file" >&2
    return 1
  }
  flock -w 5 9 2>/dev/null || {
    echo "guidance_confirm: lock timeout" >&2
    exec 9>&-
    return 1
  }

  local tmpfile="$filepath.tmp.$$"
  local line_no=0
  local found=false
  local now_ts
  now_ts=$(_now_iso)

  while IFS= read -r line; do
    line_no=$((line_no + 1))
    [[ -z "$line" ]] && {
      echo "" >>"$tmpfile"
      continue
    }

    if [[ "$line_no" -eq "$target_line" ]]; then
      local curr_status
      curr_status=$(echo "$line" | jq -r '.status // empty' 2>/dev/null) || true

      if [[ "$curr_status" != "proposed" ]]; then
        echo "guidance_confirm: entry is $curr_status, not proposed — cannot confirm" >&2
        rm -f "$tmpfile"
        exec 9>&-
        return 2
      fi

      # Update: status=confirmed, add ticket to evidence_tickets, append transition
      local updated
      updated=$(echo "$line" | jq -c \
        --arg ts "$now_ts" \
        --arg ticket "$ticket" \
        '.status = "confirmed" |
         .evidence_tickets = ((.evidence_tickets // []) + [$ticket] | unique) |
         .transitions += [{"status":"confirmed","at":$ts,"by":"retro","ticket":$ticket}] |
         .updated_at = $ts' 2>/dev/null) || {
        echo "guidance_confirm: failed to update entry JSON" >&2
        rm -f "$tmpfile"
        exec 9>&-
        return 1
      }
      echo "$updated" >>"$tmpfile"
      found=true
    else
      echo "$line" >>"$tmpfile"
    fi
  done <"$filepath"

  if [[ "$found" == true ]]; then
    mv "$tmpfile" "$filepath" 2>/dev/null || {
      echo "guidance_confirm: atomic replace failed" >&2
      rm -f "$tmpfile"
      exec 9>&-
      return 1
    }
  else
    rm -f "$tmpfile"
  fi

  exec 9>&-
  return 0
}

# ── guidance_deprecate ──────────────────────────────────────────────────────────
# Mark a guidance entry as deprecated (superseded or incorrect).
# Usage: guidance_deprecate <guidance_id> <reason>
# Exit: 0 deprecated, 1 not found, 2 already deprecated
guidance_deprecate() {
  local guidance_id="$1" reason="$2"

  if [[ -z "$guidance_id" || -z "$reason" ]]; then
    echo "guidance_deprecate: guidance_id and reason required" >&2
    return 2
  fi

  _ensure_dir

  local location
  location=$(_find_entry "$guidance_id") || {
    echo "guidance_deprecate: guidance entry not found: $guidance_id" >&2
    return 1
  }

  local filepath="${location%%:*}"
  local target_line="${location##*:}"
  local lockfile="$filepath.lock"

  exec 9>"$lockfile" || {
    echo "guidance_deprecate: cannot create lock file" >&2
    return 1
  }
  flock -w 5 9 2>/dev/null || {
    echo "guidance_deprecate: lock timeout" >&2
    exec 9>&-
    return 1
  }

  local tmpfile="$filepath.tmp.$$"
  local line_no=0
  local found=false
  local now_ts
  now_ts=$(_now_iso)

  while IFS= read -r line; do
    line_no=$((line_no + 1))
    [[ -z "$line" ]] && {
      echo "" >>"$tmpfile"
      continue
    }

    if [[ "$line_no" -eq "$target_line" ]]; then
      local curr_status
      curr_status=$(echo "$line" | jq -r '.status // empty' 2>/dev/null) || true

      if [[ "$curr_status" == "deprecated" ]]; then
        echo "guidance_deprecate: entry is already deprecated" >&2
        rm -f "$tmpfile"
        exec 9>&-
        return 2
      fi

      local updated
      updated=$(echo "$line" | jq -c \
        --arg ts "$now_ts" \
        --arg reason "$reason" \
        '.status = "deprecated" |
         .deprecation_reason = $reason |
         .transitions += [{"status":"deprecated","at":$ts,"by":"retro","reason":$reason}] |
         .updated_at = $ts' 2>/dev/null) || {
        echo "guidance_deprecate: failed to update entry JSON" >&2
        rm -f "$tmpfile"
        exec 9>&-
        return 1
      }
      echo "$updated" >>"$tmpfile"
      found=true
    else
      echo "$line" >>"$tmpfile"
    fi
  done <"$filepath"

  if [[ "$found" == true ]]; then
    mv "$tmpfile" "$filepath" 2>/dev/null || {
      echo "guidance_deprecate: atomic replace failed" >&2
      rm -f "$tmpfile"
      exec 9>&-
      return 1
    }
  else
    rm -f "$tmpfile"
  fi

  exec 9>&-
  return 0
}

# ── guidance_stats ───────────────────────────────────────────────────────────────
# Aggregate counts across all guidance entries.
# Output: single JSON object with total_entries, by_root_cause, by_status,
#         by_component, oldest_entry, newest_entry.
# Usage: guidance_stats
# Exit: 0 always
guidance_stats() {
  _ensure_dir

  if ! command -v jq &>/dev/null; then
    echo "guidance_stats: jq required" >&2
    echo '{"total_entries":0,"by_root_cause":{},"by_status":{},"by_component":{},"oldest_entry":null,"newest_entry":null}'
    return 0
  fi

  shopt -s nullglob
  local files=()
  for f in "$GUIDANCE_DIR"/*.jsonl; do
    files+=("$f")
  done
  shopt -u nullglob

  if [[ ${#files[@]} -eq 0 ]]; then
    echo '{"total_entries":0,"by_root_cause":{},"by_status":{},"by_component":{},"oldest_entry":null,"newest_entry":null}'
    return 0
  fi

  # Collect all valid JSON lines from all files
  local all_json=""
  for filepath in "${files[@]}"; do
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      if echo "$line" | jq -e . >/dev/null 2>&1; then
        all_json+="$line"$'\n'
      fi
    done <"$filepath"
  done

  if [[ -z "$all_json" ]]; then
    echo '{"total_entries":0,"by_root_cause":{},"by_status":{},"by_component":{},"oldest_entry":null,"newest_entry":null}'
    return 0
  fi

  # Use jq to aggregate (slurp all lines into array)
  echo "$all_json" | jq -s '
    {
      total_entries: length,
      by_root_cause: (group_by(.root_cause) | map({key: .[0].root_cause, value: length}) | from_entries),
      by_status: (group_by(.status) | map({key: .[0].status, value: length}) | from_entries),
      by_component: (group_by(.component) | map({key: .[0].component, value: length}) | from_entries),
      oldest_entry: (min_by(.created_at) | .created_at),
      newest_entry: (max_by(.updated_at) | .updated_at)
    }
  ' 2>/dev/null || {
    echo '{"total_entries":0,"by_root_cause":{},"by_status":{},"by_component":{},"oldest_entry":null,"newest_entry":null}'
  }

  return 0
}

# ── Main dispatch ────────────────────────────────────────────────────────────────

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  CMD="${1:-}"
  shift || true

  case "$CMD" in
  upsert)
    guidance_upsert "$@"
    ;;
  query)
    guidance_query "$@"
    ;;
  confirm)
    guidance_confirm "$@"
    ;;
  deprecate)
    guidance_deprecate "$@"
    ;;
  stats)
    guidance_stats "$@"
    ;;
  compute-id)
    _compute_guidance_id "$@"
    ;;
  --help | -h | "")
    cat >&2 <<'EOF'
Usage: guidance-store.sh <command> [args...]

Commands:
  upsert <json-entry>                       Write or update a guidance entry
  query [--component <name>] [--root-cause <type>] [--status <status>]
        [--since <ISO-date>] [--limit <N>]  Read entries with optional filters
  confirm <guidance_id> <ticket>            Promote entry to confirmed status
  deprecate <guidance_id> <reason>          Mark entry as deprecated
  stats                                     Aggregate counts
  compute-id <component> <root_cause> <pattern>
                                            Compute stable guidance_id hash
EOF
    exit 1
    ;;
  *)
    echo "Unknown command: $CMD" >&2
    exit 1
    ;;
  esac
fi
