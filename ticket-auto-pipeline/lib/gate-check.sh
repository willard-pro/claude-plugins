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

	# Both state=Ready AND approved label present → pass
	if [ "$state" = "Ready" ] && [ "$has_approved" = "true" ]; then
		_plog "$LOG_FILE" "GATE" "reapprove" "done" ""
		hb_gate "reapprove-gate" "ok" "re-approval confirmed" "{\"state\":\"$state\"}"
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
