#!/usr/bin/env bash
# Shared heartbeat log helpers. Source this file from skill scripts.
# All functions return 0 silently if HB_LOG_FILE is unset.
set -euo pipefail

# Valid category enum values
_HB_CATEGORIES="decision fallback heartbeat api gate retry source"
# Valid status enum values
_HB_STATUSES="ok warn fail info fired"
# Schema version
_HB_SCHEMA_VERSION="1"

# Write a heartbeat log entry.
# Args: category event status msg [detail]
# detail defaults to empty ({}). Must be flat JSON or empty.
hb_write() {
  [ -z "${HB_LOG_FILE:-}" ] && return 0

  local category="$1"
  local event="$2"
  local status="$3"
  local msg="$4"
  local detail="${5:-}"

  # Validate category enum
  local found=0
  for c in $_HB_CATEGORIES; do
    [ "$c" = "$category" ] && found=1 && break
  done
  if [ "$found" -eq 0 ]; then
    echo "hb_write: bad category '$category' (valid: $_HB_CATEGORIES)" >&2
    return 1
  fi

  # Validate status enum
  found=0
  for s in $_HB_STATUSES; do
    [ "$s" = "$status" ] && found=1 && break
  done
  if [ "$found" -eq 0 ]; then
    echo "hb_write: bad status '$status' (valid: $_HB_STATUSES)" >&2
    return 1
  fi

  # Validate event is kebab-case (non-empty, only lowercase, digits, hyphens)
  if ! [[ "$event" =~ ^[a-z][a-z0-9-]*$ ]]; then
    echo "hb_write: bad event name '$event' (must be kebab-case)" >&2
    return 1
  fi

  # Validate and normalize detail
  if [ -n "$detail" ] && [ "$detail" != "{}" ]; then
    local validated
    if ! validated=$(echo "$detail" | jq -c '.' 2>&1); then
      echo "hb_write: invalid JSON in DETAIL field '$detail' — entry skipped" >&2
      return 1
    fi
    # Reject if not a flat object (nested objects/arrays)
    local depth
    depth=$(echo "$validated" | jq '[.. | select(type=="object" or type=="array")] | length' 2>/dev/null || echo "0")
    if [ "$depth" -gt 1 ] 2>/dev/null; then
      echo "hb_write: DETAIL must be a flat JSON object (no nesting) — entry skipped" >&2
      return 1
    fi
    detail="$validated"
  elif [ -z "$detail" ] || [ "$detail" = "{}" ]; then
    detail="{}"
  fi

  # Ensure directory exists
  local dir
  dir=$(dirname "$HB_LOG_FILE")
  mkdir -p "$dir"

  local iso
  iso=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  echo "$iso|$category|$event|$status|$msg|$detail" >> "$HB_LOG_FILE"
}

# Semantic helpers — each delegates to hb_write with a fixed category
hb_decision() {
  [ -z "${HB_LOG_FILE:-}" ] && return 0
  hb_write "decision" "$@"
}

hb_fallback() {
  [ -z "${HB_LOG_FILE:-}" ] && return 0
  hb_write "fallback" "$@"
}

hb_heartbeat() {
  [ -z "${HB_LOG_FILE:-}" ] && return 0
  local event="$1"
  local msg="$2"
  hb_write "heartbeat" "$event" "ok" "$msg"
}

hb_api() {
  [ -z "${HB_LOG_FILE:-}" ] && return 0
  hb_write "api" "$@"
}

hb_retry() {
  [ -z "${HB_LOG_FILE:-}" ] && return 0
  hb_write "retry" "$@"
}

hb_gate() {
  [ -z "${HB_LOG_FILE:-}" ] && return 0
  hb_write "gate" "$@"
}

hb_source() {
  [ -z "${HB_LOG_FILE:-}" ] && return 0
  hb_write "source" "$@"
}

# Validate a single heartbeat log line. Returns 0 if valid, non-zero otherwise.
# Handles both the schema header line (META) and regular entries.
hb_validate_line() {
  local line="$1"

  # Schema header line
  if echo "$line" | grep -q '|META|schema|'; then
    local fields
    fields=$(echo "$line" | awk -F'|' '{print NF}')
    if [ "$fields" -lt 5 ]; then
      echo "hb_validate_line: expected 5-6 fields, got $fields" >&2
      return 1
    fi
    return 0
  fi

  # Check field count (5 or 6)
  local fields
  fields=$(echo "$line" | awk -F'|' '{print NF}')
  if [ "$fields" -lt 5 ] || [ "$fields" -gt 6 ]; then
    echo "hb_validate_line: expected 5-6 fields, got $fields" >&2
    return 1
  fi

  local iso category event status
  iso=$(echo "$line" | cut -d'|' -f1)
  category=$(echo "$line" | cut -d'|' -f2)
  event=$(echo "$line" | cut -d'|' -f3)
  status=$(echo "$line" | cut -d'|' -f4)

  # Validate ISO timestamp
  if ! [[ "$iso" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]; then
    echo "hb_validate_line: bad ISO timestamp '$iso'" >&2
    return 1
  fi

  # Validate category enum (META is valid for schema header only)
  local found=0
  for c in $_HB_CATEGORIES META; do
    [ "$c" = "$category" ] && found=1 && break
  done
  if [ "$found" -eq 0 ]; then
    echo "hb_validate_line: bad category '$category'" >&2
    return 1
  fi

  # Validate event is kebab-case
  if ! [[ "$event" =~ ^[a-z][a-z0-9-]*$ ]]; then
    echo "hb_validate_line: bad event name '$event'" >&2
    return 1
  fi

  # Validate status enum
  found=0
  for s in $_HB_STATUSES; do
    [ "$s" = "$status" ] && found=1 && break
  done
  if [ "$found" -eq 0 ]; then
    echo "hb_validate_line: bad status '$status'" >&2
    return 1
  fi

  return 0
}

# Validate an entire heartbeat log file. Returns 0 if valid, non-zero error count.
# Validates: file exists, schema header is first line, all lines pass validation.
hb_validate_file() {
  local file="$1"

  if [ ! -f "$file" ]; then
    echo "hb_validate_file: file not found: $file" >&2
    return 1
  fi

  if [ ! -s "$file" ]; then
    echo "hb_validate_file: file is empty: $file" >&2
    return 1
  fi

  local first_line
  first_line=$(head -1 "$file")

  # Check schema header
  if ! echo "$first_line" | grep -q '|META|schema|'; then
    echo "hb_validate_file: missing schema header" >&2
    return 1
  fi

  local errors=0
  local line_num=0

  while IFS= read -r line; do
    ((line_num++)) || true
    if ! hb_validate_line "$line" 2>/dev/null; then
      echo "hb_validate_file: line $line_num invalid: $line" >&2
      ((errors++)) || true
    fi
  done < "$file"

  if [ "$errors" -gt 0 ]; then
    echo "hb_validate_file: $errors validation error(s)" >&2
    return "$errors"
  fi

  return 0
}

# Initialize a heartbeat log file. Idempotent — only writes schema header if
# the file is empty or doesn't exist.
hb_init() {
  [ -z "${HB_LOG_FILE:-}" ] && return 0

  local dir
  dir=$(dirname "$HB_LOG_FILE")
  mkdir -p "$dir"

  if [ ! -f "$HB_LOG_FILE" ] || [ ! -s "$HB_LOG_FILE" ]; then
    local iso
    iso=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    echo "$iso|META|schema|info|$_HB_SCHEMA_VERSION|{}" > "$HB_LOG_FILE"
  fi
}
