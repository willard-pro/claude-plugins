#!/usr/bin/env bash
# gate-check.sh — deterministic bash gate logic for pipeline entry and re-approval.
# Replaces inline LLM gate reasoning in the orchestrator.
# -u (nounset) intentionally omitted: Claude Code shell snapshots inject
# ZSH_VERSION references that trigger false-positive "unbound variable"
# errors in this bash version when nounset is active.
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${CLAUDE_SKILLS_LIB:-$HOME/.claude/skills/lib}"
source "$LIB_DIR/heartbeat.sh"
source "$LIB_DIR/linear-api.sh"
source "$LIB_DIR/notes-parse.sh"

# Source ticket-dir.sh for resolve_ticket_dir — check multiple locations
if [ -f "$SCRIPT_DIR/ticket-dir.sh" ]; then
  source "$SCRIPT_DIR/ticket-dir.sh"
elif [ -f "$LIB_DIR/ticket-dir.sh" ]; then
  source "$LIB_DIR/ticket-dir.sh"
fi

usage() {
  echo "Usage: $0 <TICKET-ID> <LOG-FILE> <HB-LOG-FILE> --mode <entry|reapprove>" >&2
  exit 1
}

# ── Resolve flow.sh path dynamically ───────────────────────────────────────────
_resolve_flow_sh() {
  if [ -f "$HOME/.claude/skills/ticket-flow/flow.sh" ]; then
    echo "$HOME/.claude/skills/ticket-flow/flow.sh"
  elif command -v find &>/dev/null; then
    find "$HOME/.claude/plugins/cache" -name "flow.sh" -path "*/ticket-flow/*" 2>/dev/null | head -1 || true
  fi
}

FLOW_SH=$(_resolve_flow_sh)

# ── Helpers ────────────────────────────────────────────────────────────────────

# Extract artifact path from pipeline log
# Checks META|artifact|info|plan: first, falls back to EXEC|exec|done|
_get_artifact_path() {
  local artifact_path
  # Prefer explicit META|artifact entry
  artifact_path=$(grep '^[^|]*|META|artifact|info|plan:' "$LOG_FILE" 2>/dev/null | tail -1 | cut -d'|' -f5- | sed 's/^plan://' || true)
  if [ -z "$artifact_path" ]; then
    # Fall back to EXEC|create-artifact|done| line — the value field there may
    # be a type like "simple-fix", not a path.  Resolve it relative to the
    # ticket directory.
    local artifact_type td
    artifact_type=$(grep '^[^|]*|EXEC|create-artifact|done|' "$LOG_FILE" 2>/dev/null | tail -1 | cut -d'|' -f5- || true)
    if [ -n "$artifact_type" ] && command -v resolve_ticket_dir &>/dev/null; then
      td=$(resolve_ticket_dir "$TICKET_ID" "." 2>/dev/null || true)
      [ -n "$td" ] && artifact_path="$td/${artifact_type}.md"
    fi
  fi
  echo "$artifact_path"
}

# Extract AUTONOMY from pipeline log (defaults to manual)
_get_autonomy() {
  local autonomy
  autonomy=$(grep '^[^|]*|META|autonomy|info|' "$LOG_FILE" 2>/dev/null | tail -1 | cut -d'|' -f5- || true)
  echo "${autonomy:-manual}"
}

# Extract COMPLEXITY — uses get_complexity from notes-parse.sh which reads notes.md
# from the ticket directory. We resolve the ticket dir via ticket-dir.sh or fallback.
_get_complexity() {
  local td complexity
  if command -v resolve_ticket_dir &>/dev/null; then
    td=$(resolve_ticket_dir "$TICKET_ID" "." 2>/dev/null || true)
  fi
  if [ -z "$td" ]; then
    # Fallback: check PWD notes.md
    td="."
  fi
  complexity=$(get_complexity "$td" 2>/dev/null || true)
  echo "${complexity:-simple}"
}

# Determine artifact type from the pipeline log EXEC|exec|done| line
_get_artifact_type() {
  local artifact_line atype
  artifact_line=$(grep '^[^|]*|EXEC|exec|done|' "$LOG_FILE" 2>/dev/null | tail -1 || true)
  if echo "$artifact_line" | grep -q 'openspec'; then
    atype="openspec"
  elif echo "$artifact_line" | grep -q 'simple-fix'; then
    atype="simple-fix"
  else
    atype="simple-fix"
  fi
  echo "$atype"
}

# ── Mode: entry ────────────────────────────────────────────────────────────────

_gate_entry() {
  # Write gate start event
  _plog "$LOG_FILE" "GATE" "gate" "start" ""

  local artifact_path complexity autonomy artifact_type
  artifact_path=$(_get_artifact_path)
  complexity=$(_get_complexity)
  autonomy=$(_get_autonomy)
  artifact_type=$(_get_artifact_type)

  # Check 1: Artifact file existence
  if [ -n "$artifact_path" ] && [ ! -f "$artifact_path" ]; then
    _plog "$LOG_FILE" "META" "gate-stop" "fail" "EXEC_NO_ARTIFACT"
    hb_gate "entry-gate" "fail" "artifact missing" "{\"path\":\"$artifact_path\"}"
    return 2
  fi

  # Check 2: Complexity-artifact coherence
  if [ "$complexity" = "complex" ] && [ "$artifact_type" = "simple-fix" ]; then
    _plog "$LOG_FILE" "META" "gate-stop" "fail" "COMPLEXITY_ARTIFACT_MISMATCH"
    hb_gate "entry-gate" "fail" "complexity-artifact mismatch" "{\"complexity\":\"$complexity\",\"artifact\":\"$artifact_type\"}"
    return 2
  fi

  # Check 2.5: Content quality score (from critique in notes.md)
  # Distinguish: critique never ran (section absent → skip, backward compat) vs.
  #              critique ran but failed (section present but no score → gate-stop)
  local critique_score critique_status td has_critique
  if command -v resolve_ticket_dir &>/dev/null; then
    td=$(resolve_ticket_dir "$TICKET_ID" "." 2>/dev/null || true)
  fi
  if [ -z "$td" ]; then
    td="."
  fi
  critique_score=$(get_critique_score "$td" 2>/dev/null || true)
  critique_status=$(get_critique_status "$td" 2>/dev/null || true)
  # Check whether the Readiness Critique section exists at all
  if [ -f "$td/notes.md" ] && grep -q '## Readiness Critique' "$td/notes.md" 2>/dev/null; then
    has_critique="true"
  else
    has_critique="false"
  fi

  if [ "${has_critique}" = "true" ] && [ -z "$critique_score" ]; then
    # Critique ran but produced no score — structural failure, do not proceed
    _plog "$LOG_FILE" "META" "gate-stop" "fail" "CRITIQUE_SCORE_MISSING — ## Readiness Critique exists but **Score:** absent or unparseable"
    hb_gate "entry-gate" "fail" "critique score missing" "{\"has_critique\":\"true\"}"
    return 2
  fi

  if [ -n "$critique_score" ]; then
    # BLOCKED status is a hard stop
    if [ "$critique_status" = "BLOCKED" ]; then
      _plog "$LOG_FILE" "META" "gate-stop" "fail" "CRITIQUE_BLOCKED"
      hb_gate "entry-gate" "fail" "critique blocked" "{\"score\":\"$critique_score\",\"status\":\"$critique_status\"}"
      return 2
    fi

    # Score below 40 holds the ticket — validate integer before comparison
    if [[ "$critique_score" =~ ^[0-9]+$ ]] && [ "$critique_score" -lt 40 ]; then
      _plog "$LOG_FILE" "GATE" "gate" "fail" "held: content quality score $critique_score < 40"
      hb_gate "entry-gate" "fail" "held: content quality score below threshold" "{\"score\":\"$critique_score\",\"threshold\":40}"
      return 1
    fi

    # Score plausibility cross-check: if BLOCKERs exist, score must be ≤ 70
    # Each BLOCKER deducts at least 30 (0 AC) or 20 (no test user) or 25 (no bug repro)
    # Worst case for 1 BLOCKER = -30 → max 70. For 2 BLOCKERs = max 50.
    local critique_blocker_count
    critique_blocker_count=$(get_critique_blocker_count "$td" 2>/dev/null || echo "0")
    if [[ "$critique_blocker_count" =~ ^[0-9]+$ ]] && [[ "$critique_score" =~ ^[0-9]+$ ]]; then
      local max_score=$((100 - (critique_blocker_count * 25)))
      [ "$max_score" -lt 40 ] && max_score=40 # floor at 40 — below this is already caught
      if [ "$critique_blocker_count" -ge 2 ] && [ "$critique_score" -gt 50 ]; then
        _plog "$LOG_FILE" "META" "gate-stop" "fail" "CRITIQUE_SCORE_IMPLAUSIBLE — score $critique_score with $critique_blocker_count BLOCKERs (max plausible: 50)"
        hb_gate "entry-gate" "fail" "critique score implausible" "{\"score\":\"$critique_score\",\"blockers\":\"$critique_blocker_count\",\"max_plausible\":50}"
        return 2
      elif [ "$critique_blocker_count" -ge 1 ] && [ "$critique_score" -gt 70 ]; then
        _plog "$LOG_FILE" "META" "gate-stop" "fail" "CRITIQUE_SCORE_IMPLAUSIBLE — score $critique_score with $critique_blocker_count BLOCKER(s) (max plausible: 70)"
        hb_gate "entry-gate" "fail" "critique score implausible" "{\"score\":\"$critique_score\",\"blockers\":\"$critique_blocker_count\",\"max_plausible\":70}"
        return 2
      fi
    fi
  fi

  # Check 2.6: Verification readiness — check plan artifact for all 4 prerequisites
  # Backward compat: skip if no critique score exists (old ticket without new critique sections)
  if [ -n "$artifact_path" ] && [ -f "$artifact_path" ] && [ -n "$critique_score" ]; then
    local has_test_user has_nav_path has_expected_behavior has_env_prereqs role_pattern missing_count
    # Build role pattern from test-users.json catalog if available, fall back to known roles
    role_pattern=$(jq -r '[.[].roles[]] | unique | join("|")' "${CLAUDE_PLUGIN_ROOT:-$HOME/.claude/skills}/config/test-users.json" 2>/dev/null | sed 's/_/[-_]/g' || echo 'attorney|admin|debtor|collection[-_]?agency|correspondent')
    # Primary: check the derived verification plan in notes.md when present
    local td notes_path vplan_section
    td="."
    if command -v resolve_ticket_dir &>/dev/null; then
      td=$(resolve_ticket_dir "$TICKET_ID" "." 2>/dev/null || echo ".")
    fi
    notes_path="$td/notes.md"
    vplan_section=""

    if [ -f "$notes_path" ] && grep -q '## Verification Plan' "$notes_path" 2>/dev/null; then
      # Extract the per-criterion table between "### Per-Criterion Verification" and the next ## heading
      vplan_section=$(awk '/^### Per-Criterion Verification$/,/^## /' "$notes_path" 2>/dev/null || true)
      if [ -n "$vplan_section" ]; then
        # Test user: check the Role scope column for role mentions or "global"
        has_test_user=$(echo "$vplan_section" | grep -ciP '(\| *global|role: *\w|attorney|admin|debtor|collection|correspondent)' 2>/dev/null || true)
        # Navigation path: check the Navigation path column for URLs or paths
        has_nav_path=$(echo "$vplan_section" | grep -ciP '(\| */\w+|navigate|menu|click|path.*\|)' 2>/dev/null || true)
        # Expected behavior: check that the Expected behavior column has non-empty content
        has_expected_behavior=$(echo "$vplan_section" | grep -ciP '(\| *[^|]+\| *[^|]+\| *[^|]+\| *[^|]+)' 2>/dev/null || true)
        # Environment prerequisites: check the Test data needed column
        has_env_prereqs=$(echo "$vplan_section" | grep -ciP '(\| *(none|seed|setup|data|fixture|migration|prerequisite))' 2>/dev/null || true)
      fi
    fi

    # Fallback: scan the plan artifact directly when:
    # - no verification plan section exists, OR
    # - any prerequisite grep returned 0 (grep may have missed data the LLM wrote)
    if [ -z "$vplan_section" ] || [ "${has_test_user:-0}" = "0" ] || [ "${has_nav_path:-0}" = "0" ] || [ "${has_expected_behavior:-0}" = "0" ] || [ "${has_env_prereqs:-0}" = "0" ]; then
      # grep -c outputs "0" on no match (and exits 1) — use || true to suppress exit code
      has_test_user=$(grep -ciP '(\*\*User:\*\*|log in as|test as|email[:\s]*\S+@\S+\.\S+|role[:\s]*('"$role_pattern"'))' "$artifact_path" 2>/dev/null || true)
      has_nav_path=$(grep -ciP '(/handover/|/admin/|/user-permission/|/organisation/|navigate to|menu path|click path)' "$artifact_path" 2>/dev/null || true)
      # Expected behavior: acceptance criteria, should/must/verify statements, expected behavior headings
      has_expected_behavior=$(grep -ciP '(acceptance criteria|expected (behavi|result|outcome)|should |must |verify that|pass criter|## Expected|## Acceptance|## Verification Plan|AC[-:])' "$artifact_path" 2>/dev/null || true)
      # Environment prerequisites: data setup, seed data, migrations, dependencies
      has_env_prereqs=$(grep -ciP '(seed[- ]?data|setup|prerequisite|before (testing|running)|environment|database|migration|service.*start|dependency|data\.sql|fixture)' "$artifact_path" 2>/dev/null || true)
    fi

    # Count missing prerequisites
    missing_count=0
    [ "$has_test_user" = "0" ] && ((missing_count++))
    [ "$has_nav_path" = "0" ] && ((missing_count++))
    [ "$has_expected_behavior" = "0" ] && ((missing_count++))
    [ "$has_env_prereqs" = "0" ] && ((missing_count++))

    # Hold if 2+ missing (INCOMPLETE threshold from appraise-exec Step 3.8)
    if [ "$missing_count" -ge 2 ] 2>/dev/null; then
      _plog "$LOG_FILE" "GATE" "gate" "fail" "held: plan missing $missing_count/4 verification prerequisites (test_user=$has_test_user nav=$has_nav_path expected=$has_expected_behavior env=$has_env_prereqs)"
      hb_gate "entry-gate" "fail" "held: plan missing verification prerequisites" "{\"artifact\":\"$artifact_path\",\"missing\":\"$missing_count\",\"test_user\":\"$has_test_user\",\"nav\":\"$has_nav_path\",\"expected\":\"$has_expected_behavior\",\"env\":\"$has_env_prereqs\"}"
      return 1
    fi
  fi

  # Check 3: Complex tickets are always held
  if [ "$complexity" = "complex" ]; then
    _plog "$LOG_FILE" "GATE" "gate" "fail" "held: complex ticket"
    hb_gate "entry-gate" "fail" "held: complex ticket" "{\"complexity\":\"$complexity\"}"
    return 1
  fi

  # Check 4: Manual mode tickets are held
  if [ "$autonomy" = "manual" ]; then
    _plog "$LOG_FILE" "GATE" "gate" "fail" "held: manual mode"
    hb_gate "entry-gate" "fail" "held: manual mode" "{\"autonomy\":\"$autonomy\"}"
    return 1
  fi

  # Check 5: Simple + auto/semi-auto → auto-approve via flow.sh
  if [ "$complexity" = "simple" ] && { [ "$autonomy" = "auto" ] || [ "$autonomy" = "semi-auto" ]; }; then
    if [ -n "$FLOW_SH" ] && [ -f "$FLOW_SH" ]; then
      bash "$FLOW_SH" "$TICKET_ID" "human-approve" || true
    fi
    _plog "$LOG_FILE" "GATE" "gate" "done" "auto-approved"
    hb_gate "entry-gate" "ok" "auto-approved" "{\"complexity\":\"$complexity\",\"autonomy\":\"$autonomy\"}"
    return 0
  fi

  # Fallback: held (should not reach here given the checks above, but safety net)
  _plog "$LOG_FILE" "GATE" "gate" "fail" "held: default"
  hb_gate "entry-gate" "fail" "held: default fallback" "{}"
  return 1
}

# ── Mode: reapprove ────────────────────────────────────────────────────────────

_gate_reapprove() {
  local issue_json state has_approved
  issue_json=$(get_issue "$TICKET_ID" 2>/dev/null || echo 'null')

  # Extract state name
  state=$(echo "$issue_json" | jq -r '.state.name // empty' 2>/dev/null || true)

  # Check for approved label (case-insensitive)
  has_approved=$(echo "$issue_json" | jq -r '[.labels.nodes[]?.name? // empty | ascii_downcase] | index("approved") != null' 2>/dev/null || echo 'false')

  # Count prior verification failures in the plan artifact (informational only)
  local artifact_path verify_count
  artifact_path=$(_get_artifact_path)
  if [ -n "$artifact_path" ] && [ -f "$artifact_path" ]; then
    verify_count=$(grep -c '^## Verification #' "$artifact_path" 2>/dev/null || echo "0")
    if [ "$verify_count" -gt 0 ] 2>/dev/null; then
      _plog "$LOG_FILE" "GATE" "reapprove" "info" "plan has $verify_count prior verification failure(s)"
    fi
  fi

  # Both state=Ready AND approved label present → pass
  if [ "$state" = "Ready" ] && [ "$has_approved" = "true" ]; then
    _plog "$LOG_FILE" "GATE" "reapprove" "done" ""
    hb_gate "reapprove-gate" "ok" "re-approval confirmed" "{\"state\":\"$state\",\"prior_failures\":\"${verify_count:-0}\"}"
    return 0
  fi

  # Single gate-stop entry for any failure combination
  local reason=""
  if [ "$state" != "Ready" ] && [ "$has_approved" != "true" ]; then
    reason="state=$state AND approved label missing"
  elif [ "$state" != "Ready" ]; then
    reason="state=$state (expected Ready)"
  else
    reason="approved label missing"
  fi

  _plog "$LOG_FILE" "META" "gate-stop" "fail" "APPROVAL_REVOKED"
  hb_gate "reapprove-gate" "fail" "APPROVAL_REVOKED" "{\"reason\":\"$reason\"}"
  return 2
}

# ── Dispatch (only when executed directly, not when sourced for testing) ──────

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  TICKET_ID="${1:-}"
  LOG_FILE="${2:-}"
  HB_LOG_FILE="${3:-}"
  MODE=""

  shift 3 2>/dev/null || true
  while [ $# -gt 0 ]; do
    case "$1" in
    --mode)
      MODE="$2"
      shift 2
      ;;
    *) usage ;;
    esac
  done

  [ -z "$TICKET_ID" ] && usage
  [ -z "$LOG_FILE" ] && usage
  [ -z "$MODE" ] && usage
  [[ "$MODE" =~ ^(entry|reapprove)$ ]] || {
    echo "Invalid mode: $MODE (expected entry or reapprove)" >&2
    exit 1
  }

  hb_init

  case "$MODE" in
  entry) _gate_entry ;;
  reapprove) _gate_reapprove ;;
  *) usage ;;
  esac
fi
