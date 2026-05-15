#!/usr/bin/env bash
# Validates that all states and labels required by the ticket-flow state machine
# exist on Linear for a given team.
#
# Usage: validate-linear-config.sh [TEAM_NAME_OR_ID] [--dry-run] [--force]
#   TEAM_NAME_OR_ID  Team name or UUID. If omitted, auto-selects when only one team
#                    exists; lists available teams when there are multiple.
#   --dry-run        Exit 0 even when items are missing (useful for CI informational runs).
#   --force          Bypass the sentinel file and always re-validate.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/linear-api.sh"

SM="$SCRIPT_DIR/state-machine.json"
SENTINEL_DIR="${SENTINEL_DIR:-$HOME/.claude/state/ticket-flow}"

# ── Validate state-machine.json ──────────────────────────────────────────────

if ! jq '.' "$SM" > /dev/null 2>&1; then
  echo "ERROR: state-machine.json is not valid JSON: $SM" >&2
  exit 1
fi

# ── Derive expected states and labels from state-machine.json ────────────────

# States: union of from/to values + well_known_states
mapfile -t EXPECTED_STATES < <(jq -r '
  [
    (.triggers | to_entries[] | .value | (.from, .to) | select(. != null)),
    (.well_known_states[]? // empty)
  ] | unique | sort[]' "$SM")

# Labels: union of adds/removes with placeholder expansion + well_known_labels
mapfile -t EXPECTED_LABELS < <(jq -r '
  [
    (.triggers | to_entries[] | .value | (.adds[]?, .removes[]?) | select(. != null)),
    (.well_known_labels[]? // empty)
  ] | unique | sort[]' "$SM" | sed \
    's/{complexity}/simple\n{complexity_complex}/g; s/{complexity_complex}/complex/g;
     s/{outcome}/Smooth\n{outcome_rough}\n{outcome_hard}/g;
     s/{outcome_rough}/Rough/g; s/{outcome_hard}/Hard/g' | sort -u)

# ── Argument parsing ─────────────────────────────────────────────────────────

TEAM_ARG=""
DRY_RUN=false
FORCE=false

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
    --force)   FORCE=true ;;
    --*)       echo "Unknown flag: $arg" >&2; exit 1 ;;
    *)         TEAM_ARG="$arg" ;;
  esac
done

# ── Resolve team ──────────────────────────────────────────────────────────────

check_api_key

teams_resp=$(linear_graphql '{"query": "query { teams { nodes { id name } } }"}')
team_count=$(echo "$teams_resp" | jq '.data.teams.nodes | length')

if [ -z "$TEAM_ARG" ]; then
  if [ "$team_count" -eq 1 ]; then
    TEAM_ID=$(echo "$teams_resp" | jq -r '.data.teams.nodes[0].id')
    TEAM_NAME=$(echo "$teams_resp" | jq -r '.data.teams.nodes[0].name')
  else
    echo "Multiple teams found. Pass a team name or ID as the first argument:" >&2
    echo "$teams_resp" | jq -r '.data.teams.nodes[] | "  \(.name)  (\(.id))"' >&2
    exit 1
  fi
else
  match=$(echo "$teams_resp" | jq -r --arg n "$TEAM_ARG" \
    '.data.teams.nodes[] | select(.name == $n or .id == $n) | "\(.id)\t\(.name)"' | head -1)
  if [ -z "$match" ]; then
    echo "Team '$TEAM_ARG' not found. Available teams:" >&2
    echo "$teams_resp" | jq -r '.data.teams.nodes[] | "  \(.name)  (\(.id))"' >&2
    exit 1
  fi
  TEAM_ID=$(echo "$match" | cut -f1)
  TEAM_NAME=$(echo "$match" | cut -f2)
fi

# ── Sentinel check ────────────────────────────────────────────────────────────

SENTINEL="$SENTINEL_DIR/validated-${TEAM_ID}"
SM_HASH=$(sha256sum "$SM" | cut -d' ' -f1)

if [ -f "$SENTINEL" ] && ! $FORCE; then
  stored_hash=$(grep '^sm_hash=' "$SENTINEL" | cut -d= -f2 || true)
  if [ "$stored_hash" = "$SM_HASH" ]; then
    echo "sentinel-valid: team=$TEAM_NAME hash=$SM_HASH"
    [ -n "${LOG_FILE:-}" ] && \
      echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|META|preflight|skip|sentinel-valid" >> "$LOG_FILE"
    exit 0
  fi
fi

# ── Fetch team data ───────────────────────────────────────────────────────────

TEAM_JSON=$(get_team "$TEAM_ID")

# ── Validate states (case-sensitive exact match — mirrors flow.sh) ────────────

echo ""
echo "=== Linear Config Validation for team \"$TEAM_NAME\" ==="
echo ""
echo "States (${#EXPECTED_STATES[@]} expected):"

states_found=0
states_missing=0

for state in "${EXPECTED_STATES[@]}"; do
  sid=$(echo "$TEAM_JSON" | jq -r --arg n "$state" \
    '.states[] | select(.name == $n) | .id')
  if [ -n "$sid" ]; then
    printf "  ✅ %-20s (id: %s)\n" "$state" "$sid"
    ((states_found++)) || true
  else
    printf "  ❌ %-20s NOT FOUND\n" "$state"
    ((states_missing++)) || true
  fi
done

# ── Validate labels (case-insensitive — mirrors flow.sh ascii_downcase) ───────

echo ""
echo "Labels (${#EXPECTED_LABELS[@]} expected):"

labels_found=0
labels_missing=0

for label in "${EXPECTED_LABELS[@]}"; do
  label_lower=$(echo "$label" | tr '[:upper:]' '[:lower:]')
  match=$(echo "$TEAM_JSON" | jq -r --arg n "$label_lower" \
    '.labels[] | select(.name | ascii_downcase == $n) | "\(.id) \(.name)"' | head -1)
  if [ -n "$match" ]; then
    lid=$(echo "$match" | cut -d' ' -f1)
    actual_name=$(echo "$match" | cut -d' ' -f2-)
    if [ "$actual_name" = "$label" ]; then
      printf "  ✅ %-20s (id: %s)\n" "$label" "$lid"
    else
      printf "  ✅ %-20s (id: %s, case-insensitive match)\n" "$label → $actual_name" "$lid"
    fi
    ((labels_found++)) || true
  else
    printf "  ❌ %-20s NOT FOUND\n" "$label"
    ((labels_missing++)) || true
  fi
done

# ── Summary ───────────────────────────────────────────────────────────────────

total_states=${#EXPECTED_STATES[@]}
total_labels=${#EXPECTED_LABELS[@]}

echo ""
echo "=== Result: $states_found/$total_states states, $labels_found/$total_labels labels ==="
echo ""

if [ $states_missing -gt 0 ] || [ $labels_missing -gt 0 ]; then
  if $DRY_RUN; then
    echo "(--dry-run: exiting 0 despite missing items)"
    exit 0
  fi
  exit 1
fi

# ── Write sentinel ────────────────────────────────────────────────────────────

mkdir -p "$SENTINEL_DIR"
cat > "$SENTINEL" <<EOF
schema_version=1
team_id=${TEAM_ID}
team_name=${TEAM_NAME}
sm_hash=${SM_HASH}
validated_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
states=${states_found}
labels=${labels_found}
EOF

[ -n "${LOG_FILE:-}" ] && \
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|META|preflight|ok|${states_found}/${total_states} states, ${labels_found}/${total_labels} labels" >> "$LOG_FILE"

exit 0
