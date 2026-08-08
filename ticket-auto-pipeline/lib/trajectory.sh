#!/usr/bin/env bash
# trajectory.sh — On-demand trajectory derivation for ticket-auto-pipeline.
# Phase 0 of the RLVR program.
#
# Reads the pipeline log + heartbeat log for a ticket and joins META entries
# (verifier-result, model) plus phase-transition entries (start/done/waiting)
# into a chronological JSONL file. Pure function of existing logs — never
# written during agent spawn. Backfill of any historical ticket is free.
#
# Usage:
#   source this file
#   traj_generate <TICKET_ID> [--output <path>]
#
# Output: ./logs/{TICKET-ID}-trajectory.jsonl (one JSON object per entry)
# Deterministic: byte-identical on re-run over same logs.

# -u (nounset) intentionally omitted: Claude Code shell snapshots inject
# ZSH_VERSION references that trigger false-positive "unbound variable"
# errors in this bash version when nounset is active. Repo convention
# across 10+ lib files omits -u for this reason.
set -eo pipefail

# ── Helper: join fields 5+ from a pipe-delimited line ──────────────────────────
# awk join (never cut -f5 — JSON payloads contain |)
_msg_join() {
	awk -F'|' '{s=$5; for(i=6;i<=NF;i++) s=s"|"$i; print s}'
}

# ── Helper: JSON-escape a string using jq or python3 ───────────────────────────
_json_escape() {
	if command -v jq >/dev/null 2>&1; then
		# rtrimstr("\n") prevents spurious newline in empty-MSG case (F12)
		jq -Rs 'rtrimstr("\n")' 2>/dev/null
	elif command -v python3 >/dev/null 2>&1; then
		python3 -c "import sys,json; print(json.dumps(sys.stdin.read().rstrip('\n')))" 2>/dev/null
	else
		# Fallback: escape backslashes, newlines, and quotes (F16)
		sed 's/\\/\\\\/g; s/"/\\"/g' | sed ':a;N;$!ba;s/\n/\\n/g' | sed 's/^/"/;s/$/"/'
	fi
}

# ── Primary function ────────────────────────────────────────────────────────────

traj_generate() {
	local ticket_id="$1"
	local output=""
	shift

	# Validate ticket_id against path-traversal (F15)
	if ! [[ "$ticket_id" =~ ^[A-Za-z0-9-]+$ ]]; then
		echo "[trajectory] ERROR: invalid ticket_id '${ticket_id}' — must match ^[A-Za-z0-9-]+$" >&2
		return 1
	fi

	# Parse optional --output flag
	while [ $# -gt 0 ]; do
		case "$1" in
		--output)
			output="$2"
			shift 2
			;;
		*)
			shift
			;;
		esac
	done

	# Default output path
	if [ -z "$output" ]; then
		output="./logs/${ticket_id}-trajectory.jsonl"
	fi

	# Resolve log paths
	local log_dir="${LOG_DIR:-./logs}"
	local plog="${log_dir}/${ticket_id}-pipeline.log"
	local hlog="${log_dir}/${ticket_id}-heartbeat.log"

	# Validate at least one log exists
	if [ ! -f "$plog" ] && [ ! -f "$hlog" ]; then
		echo "[trajectory] ERROR: neither pipeline log nor heartbeat log found for ${ticket_id} (looked in ${log_dir})" >&2
		return 1
	fi

	# Ensure output directory exists
	mkdir -p "$(dirname "$output")"

	# Write to temp file then atomically rename
	local tmp_out
	tmp_out="${output}.tmp.$$"
	: >"$tmp_out"

	# Trap cleanup for tmp file on unexpected exit (F5)
	trap 'rm -f "$tmp_out" "${tmp_out}.sorted" 2>/dev/null' EXIT

	# ── Phase-transition entries from pipeline log ───────────────────────────────
	if [ -f "$plog" ]; then
		# F1: anchored to field 4 (STATUS) — prevents MSG-field false matches
		# F5: { grep ... || true; } guards pipefail when grep matches nothing
		{ grep -E '^[^|]*\|[^|]*\|[^|]*\|(start|done|waiting)\|' "$plog" 2>/dev/null || true; } | while IFS= read -r line; do
			iso=$(echo "$line" | cut -d'|' -f1)
			phase=$(echo "$line" | cut -d'|' -f2)
			step=$(echo "$line" | cut -d'|' -f3)
			status=$(echo "$line" | cut -d'|' -f4)
			msg=$(echo "$line" | _msg_join)
			esc_msg=$(echo "$msg" | _json_escape)
			printf '{"iso":"%s","type":"phase","phase":"%s","step":"%s","status":"%s","msg":%s}\n' \
				"$iso" "$phase" "$step" "$status" "$esc_msg" >>"$tmp_out"
		done

		# ── META: verifier-result ──────────────────────────────────────────────────
		# F1: -F for fixed-string match (BRE \| alternation with empty branches matched every line)
		# F5: { ... || true; } guards pipefail
		{ grep -F '|META|verifier-result|' "$plog" 2>/dev/null || true; } | while IFS= read -r line; do
			iso=$(echo "$line" | cut -d'|' -f1)
			status=$(echo "$line" | cut -d'|' -f4)
			payload=$(echo "$line" | _msg_join)
			# Validate the payload is valid JSON before including it
			if echo "$payload" | jq -e . >/dev/null 2>&1; then
				printf '{"iso":"%s","type":"meta","step":"verifier-result","status":"%s","payload":%s}\n' \
					"$iso" "$status" "$payload" >>"$tmp_out"
			fi
		done

		# ── META: model ────────────────────────────────────────────────────────────
		# F1: -F for fixed-string match (same BRE alternation bug as verifier-result)
		# F5: { ... || true; } guards pipefail
		{ grep -F '|META|model|' "$plog" 2>/dev/null || true; } | while IFS= read -r line; do
			iso=$(echo "$line" | cut -d'|' -f1)
			status=$(echo "$line" | cut -d'|' -f4)
			payload=$(echo "$line" | _msg_join)
			if echo "$payload" | jq -e . >/dev/null 2>&1; then
				printf '{"iso":"%s","type":"meta","step":"model","status":"%s","payload":%s}\n' \
					"$iso" "$status" "$payload" >>"$tmp_out"
			fi
		done
	fi

	# ── Heartbeat log entries ───────────────────────────────────────────────────
	if [ -f "$hlog" ]; then
		# F5: { ... || true; } guards pipefail when heartbeat log has no timestamped lines
		{ grep -E '^[0-9]{4}-[0-9]{2}-[0-9]{2}T' "$hlog" 2>/dev/null || true; } | while IFS= read -r line; do
			iso=$(echo "$line" | cut -d'|' -f1)
			category=$(echo "$line" | cut -d'|' -f2)
			event=$(echo "$line" | cut -d'|' -f3)
			status=$(echo "$line" | cut -d'|' -f4)
			msg=$(echo "$line" | _msg_join)
			esc_msg=$(echo "$msg" | _json_escape)
			printf '{"iso":"%s","type":"heartbeat","category":"%s","event":"%s","status":"%s","msg":%s}\n' \
				"$iso" "$category" "$event" "$status" "$esc_msg" >>"$tmp_out"
		done
	fi

	# ── Sort chronologically and finalize ────────────────────────────────────────
	if [ -s "$tmp_out" ]; then
		# F11: sort by .iso field explicitly (jq) instead of -t'"' -k4,4
		# (the old delimiter-based sort was accidental — it only worked because
		# iso was always the 4th "-delimited field across all entry types)
		jq -s 'sort_by(.iso) | .[]' -c "$tmp_out" >"${tmp_out}.sorted"
		mv "${tmp_out}.sorted" "$output"
		rm -f "$tmp_out"
	else
		# Empty trajectory — still produce a valid file
		mv "$tmp_out" "$output"
	fi

	echo "[trajectory] wrote $(wc -l <"$output") entries to ${output}" >&2
	return 0
}
