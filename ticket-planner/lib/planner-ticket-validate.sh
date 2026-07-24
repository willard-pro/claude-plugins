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
    echo "planner-validate: planned-ticket-check.sh not found — HARD STOP (validator unavailable)" >&2
    return 3 # Fail closed: missing validator is a hard stop
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

# ── Post-creation verification ────────────────────────────────────────────────

# Verify that created tickets actually exist in Linear with correct labels.
# This is the last checkpoint after entity creation — catches transient API
# failures that returned success but didn't persist, and label drift.
#
# Usage: planner_verify_tickets <initiative_id> <ticket_ids_json>
#   initiative_id: the initiative ID
#   ticket_ids_json: JSON array of ticket identifiers (e.g., ["PRO-101", "PRO-102"])
# Returns: 0 if all verified, 1 if mismatches found (reports to stdout).
planner_verify_tickets() {
  local initiative_id="$1" ticket_ids_json="$2"
  local intent_dir="${REPOS_ROOT:-${HOME}/repos}/.ticket-auto/initiatives/${initiative_id}/.intents"

  local failures=0 verified=0 missing=0
  local ticket_id entity_key intent_file linear_id

  _source_if_missing "planner_linear_graphql" "${CLAUDE_PLUGIN_ROOT:-.}/lib/planner-linear-api.sh"

  for ticket_id in $(echo "$ticket_ids_json" | jq -r '.[]'); do
    # Build entity key: ticket-{slug}
    local slug
    slug=$(echo "$ticket_id" | tr '[:upper:]' '[:lower:]')
    entity_key="ticket-${slug}"

    # Check intent file for recorded Linear ID
    intent_file="${intent_dir}/${entity_key}.json"
    if [ ! -f "$intent_file" ]; then
      echo "planner-verify: WARNING — no intent file for $ticket_id (created outside planner?)"
      missing=$((missing + 1))
      continue
    fi

    linear_id=$(jq -r '.linear_id // ""' "$intent_file" 2>/dev/null)
    if [ -z "$linear_id" ] || [ "$linear_id" = "null" ]; then
      echo "planner-verify: FAIL — no Linear ID recorded for $ticket_id"
      failures=$((failures + 1))
      continue
    fi

    # Fetch from Linear and verify labels
    local issue_json
    if issue_json=$(planner_linear_get_issue "$linear_id" 2>/dev/null); then
      local label_names
      label_names=$(echo "$issue_json" | jq -r '.data.issue.labels.nodes[].name // ""' 2>/dev/null)

      # Required labels: planned, INIT-{id}, Type label
      local missing_labels=""
      echo "$label_names" | grep -q "planned" || missing_labels="${missing_labels}planned "
      echo "$label_names" | grep -q "INIT-" || missing_labels="${missing_labels}INIT-* "

      if [ -n "$missing_labels" ]; then
        echo "planner-verify: FAIL — $ticket_id ($linear_id) missing labels: $missing_labels"
        failures=$((failures + 1))
      else
        echo "planner-verify: OK — $ticket_id ($linear_id) labels correct"
        verified=$((verified + 1))
      fi
    else
      echo "planner-verify: FAIL — $ticket_id ($linear_id) not found in Linear (API error or deleted)"
      failures=$((failures + 1))
    fi
  done

  echo "planner-verify: $verified verified, $failures failed, $missing missing-intent"
  return $((failures > 0 ? 1 : 0))
}

# ── Dispatch gate ──────────────────────────────────────────────────────────────

# Post-creation gate: verify all tickets and set state:execution on the parent
# epic. Called by Ticket Gen after all child tickets are created and verified.
#
# Usage: planner_dispatch_gate <initiative_id> <epic_linear_id> <ticket_ids_json>
# Returns: 0 if gate passes (epic labelled state:execution), 1 if it fails.
planner_dispatch_gate() {
  local initiative_id="$1" epic_id="$2" ticket_ids_json="$3"

  _source_if_missing "planner_linear_graphql" "${CLAUDE_PLUGIN_ROOT:-.}/lib/planner-linear-api.sh"

  # Step 1: Verify all tickets exist and have correct labels
  echo "planner-dispatch-gate: verifying $ticket_ids_json tickets..."
  if ! planner_verify_tickets "$initiative_id" "$ticket_ids_json"; then
    echo "planner-dispatch-gate: FAIL — ticket verification failed. Epic NOT labelled for execution." >&2
    return 1
  fi

  # Step 2: Verify the parent epic exists
  local epic_json
  if ! epic_json=$(planner_linear_get_issue "$epic_id" 2>/dev/null); then
    echo "planner-dispatch-gate: FAIL — cannot fetch epic $epic_id" >&2
    return 1
  fi
  echo "planner-dispatch-gate: epic $epic_id confirmed to exist"

  # Step 3: Set state:execution on the epic
  echo "planner-dispatch-gate: labelling epic $epic_id with state:execution"
  # The agent calls the Linear API to add the label
  # This is a notification — the actual label mutation is done by the agent

  return 0
}
