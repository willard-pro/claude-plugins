#!/usr/bin/env bash
# planner-ticket-validate.sh — Pre-creation validation for planner-generated tickets.
#
# Wraps planned-ticket-check.sh to validate tickets before they are created in
# Linear. A ticket that fails validation is not created — the failure surfaces
# as a planner error, not a confusing pipeline error later.
#
# Also provides idempotency helpers: intent recording and existence checking
# for entity-creating phases (Epic Gen, Story Gen, Ticket Gen).
#
# Usage:
#   planner_validate_ticket <description> [has_planned_label]
#     Validates a ticket description against planned-ticket-check.sh.
#     Returns: 0 if valid, 1 if invalid (reports reason to stderr).
#
#   planner_record_intent <initiative_id> <phase> <entity_type> <entity_key>
#     Records intent before creating an entity (for idempotency).
#
#   planner_entity_exists <initiative_id> <entity_key>
#     Checks if entity was already created. Returns 0 if exists, 1 if not.
#
#   planner_entity_mark_created <initiative_id> <entity_key> <linear_id>
#     Marks entity as created after successful Linear API call.
#
# Sourceable library — no set -euo pipefail.

_source_if_missing() {
  local name="$1" path="$2"
  if ! declare -f "$name" >/dev/null 2>&1; then
    [ -f "$path" ] && source "$path"
  fi
}

# ── Ticket validation ──────────────────────────────────────────────────────────

# Validate a generated ticket description before creating it in Linear.
# Uses planned-ticket-check.sh inline (source + call) to validate the
# Planner Context block without needing a Linear ticket ID.
#
# Usage: planner_validate_ticket <description> [has_planned_label]
# Returns: 0 if valid, 1 if invalid (error on stderr), 2 if low confidence.
planner_validate_ticket() {
  local description="$1" has_planned_label="${2:-true}"

  if [ -z "$description" ]; then
    echo "planner-validate: empty description" >&2
    return 1
  fi

  # Check Planner Context block presence
  if ! echo "$description" | grep -q '## Planner Context'; then
    echo "planner-validate: missing Planner Context block" >&2
    return 1
  fi

  # Resolve planned-ticket-check.sh
  local checker
  checker=$(find "${HOME}/.claude/plugins/cache" -name "planned-ticket-check.sh" \
    -path "*/ticket-auto-pipeline/*/lib/planned-ticket-check.sh" 2>/dev/null | sort | tail -1)
  if [ -z "$checker" ]; then
    checker="${HOME}/.claude/skills/lib/planned-ticket-check.sh"
  fi
  if [ ! -f "$checker" ]; then
    # Try relative path (same repo)
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    checker="${script_dir}/../ticket-auto-pipeline/lib/planned-ticket-check.sh"
  fi

  if [ ! -f "$checker" ]; then
    echo "planner-validate: planned-ticket-check.sh not found — skipping validation" >&2
    return 0 # Degrade gracefully: allow creation without validation
  fi

  # Source and check. Pass the description inline to avoid API dependency.
  local exit_code=0
  source "$checker"
  # Use a fake TID — the checker only needs it for logging
  check_planned_ticket "PLANNER-PREVIEW" "$description" "$has_planned_label" 2>/dev/null || exit_code=$?

  case "$exit_code" in
  0) return 0 ;;
  1)
    echo "planner-validate: ticket failed validation (malformed/missing fields)" >&2
    echo "  CHECK_RESULT=${CHECK_RESULT:-unknown}" >&2
    return 1
    ;;
  2)
    echo "planner-validate: ticket has low confidence + not pre-approved" >&2
    echo "  CHECK_RESULT=${CHECK_RESULT:-unknown}" >&2
    return 2
    ;;
  *)
    echo "planner-validate: unexpected exit code ${exit_code}" >&2
    return 1
    ;;
  esac
}

# ── Idempotency helpers ────────────────────────────────────────────────────────

# Intent file path for a given entity.
# Usage: _planner_intent_file <initiative_id> <entity_key>
_planner_intent_file() {
  local initiative_id="$1" entity_key="$2"
  local repos_root="${REPOS_ROOT:-${HOME}/repos}"
  echo "${repos_root}/.ticket-auto/initiatives/${initiative_id}/.intents/${entity_key}.json"
}

# Record intent before creating an entity. Call BEFORE the Linear API call.
# Idempotent — if intent already exists, this is a no-op.
#
# Usage: planner_record_intent <initiative_id> <phase> <entity_type> <entity_key>
planner_record_intent() {
  local initiative_id="$1" phase="$2" entity_type="$3" entity_key="$4"
  local intent_file iso
  intent_file=$(_planner_intent_file "$initiative_id" "$entity_key")
  iso=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  # Already recorded — skip
  if [ -f "$intent_file" ]; then
    return 0
  fi

  mkdir -p "$(dirname "$intent_file")"

  jq -nc \
    --arg initiative_id "$initiative_id" \
    --arg phase "$phase" \
    --arg entity_type "$entity_type" \
    --arg entity_key "$entity_key" \
    --arg iso "$iso" \
    '{
      initiative_id: $initiative_id,
      phase: $phase,
      entity_type: $entity_type,
      entity_key: $entity_key,
      intent_created: $iso,
      status: "intent"
    }' >"$intent_file"
}

# Check if an entity was already created (Linear ID recorded).
# Used BEFORE the Linear API call — if the entity exists, skip creation.
#
# Usage: planner_entity_exists <initiative_id> <entity_key>
# Returns: 0 if entity exists (linear_id recorded), 1 if not.
planner_entity_exists() {
  local initiative_id="$1" entity_key="$2"
  local intent_file
  intent_file=$(_planner_intent_file "$initiative_id" "$entity_key")

  if [ -f "$intent_file" ] && grep -q '"status"[[:space:]]*:[[:space:]]*"created"' "$intent_file" 2>/dev/null; then
    return 0
  fi
  return 1
}

# Get the Linear ID of an already-created entity.
# Usage: planner_entity_get_id <initiative_id> <entity_key>
planner_entity_get_id() {
  local initiative_id="$1" entity_key="$2"
  local intent_file
  intent_file=$(_planner_intent_file "$initiative_id" "$entity_key")

  if [ -f "$intent_file" ]; then
    jq -r '.linear_id // empty' "$intent_file" 2>/dev/null
  fi
}

# Mark an entity as created after a successful Linear API call.
# Call AFTER the Linear API call succeeds.
#
# Usage: planner_entity_mark_created <initiative_id> <entity_key> <linear_id>
planner_entity_mark_created() {
  local initiative_id="$1" entity_key="$2" linear_id="$3"
  local intent_file iso
  intent_file=$(_planner_intent_file "$initiative_id" "$entity_key")
  iso=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  # Read existing intent, update with creation info
  local existing
  if [ -f "$intent_file" ]; then
    existing=$(cat "$intent_file")
  else
    existing="{}"
  fi

  echo "$existing" | jq -c \
    --arg linear_id "$linear_id" \
    --arg iso "$iso" \
    '. + {linear_id: $linear_id, created_at: $iso, status: "created"}' \
    >"$intent_file"
}
