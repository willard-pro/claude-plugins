#!/usr/bin/env bash
# Fleet feedback aggregation — collects META|planner-feedback entries from pipeline
# logs, groups by initiative-id, computes confidence drift, and writes structured
# JSON to REPOS_ROOT/.ticket-auto/initiatives/{ID}/feedback/{rundate}.json.
#
# NOTE: Does NOT set -euo pipefail — this is a sourceable library.
# Callers are responsible for shell flags.

_FEEDBACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source linear-api.sh from canonical path for get_issue (to look up ticket labels)
if ! declare -f get_issue >/dev/null 2>&1; then
	for _lp in "$HOME/.claude/skills/lib/linear-api.sh" "$_FEEDBACK_DIR/../ticket-auto-pipeline/lib/linear-api.sh"; do
		[ -f "$_lp" ] && source "$_lp" && break
	done
fi

# ── Helpers ──────────────────────────────────────────────────────────────────────

# Extract initiative-id labels from a ticket's Linear issue.
# Uses FLEET_INITIATIVE_LABEL_PREFIX to filter (default: INIT-).
# Args: tid
# Returns: space-separated initiative IDs (e.g., "INIT-42 INIT-43")
_get_initiative_labels() {
	local tid="$1"
	local label_prefix="${FLEET_INITIATIVE_LABEL_PREFIX:-INIT-}"
	if declare -f get_issue >/dev/null 2>&1; then
		local issue_json
		if issue_json=$(get_issue "$tid" 2>/dev/null); then
			echo "$issue_json" | jq -r '.data.issue.labels.nodes[]?.name // empty' 2>/dev/null | grep "^${label_prefix}" || true
		fi
	fi
}

# Parse the planner feedback JSON payload from a pipeline log line.
# The line format is: ISO|META|planner-feedback|info|{json_payload}
# Args: line
# Returns: JSON payload string (or empty if parse fails)
_parse_feedback_payload() {
	local line="$1"
	local payload
	# Join fields 5+ (MSG field may contain pipes in the JSON)
	payload=$(echo "$line" | awk -F'|' '{for(i=5;i<=NF;i++) printf "%s%s", $i, (i<NF?"|":"")}')
	if echo "$payload" | jq -e . >/dev/null 2>&1; then
		echo "$payload"
	else
		return 1
	fi
}

# Check bc availability once on first use. Emits warning to stderr if missing.
# Without bc, drift computation degrades to 0 and labels to "none".
_BC_WARNED=false
_check_bc() {
	if ! command -v bc >/dev/null 2>&1; then
		if [ "$_BC_WARNED" = "false" ]; then
			echo "WARNING: bc not installed — drift computation degraded to 0" >&2
			_BC_WARNED=true
		fi
		return 1
	fi
	return 0
}

# Compute confidence drift between predicted and actual.
# Args: predicted (float), actual (float)
# Returns: drift value (negative = overestimated, positive = underestimated)
_compute_drift() {
	local predicted="${1:-0}"
	local actual="${2:-0}"
	if _check_bc; then
		echo "$actual - $predicted" | bc -l 2>/dev/null || echo "0"
	else
		echo "0"
	fi
}

# Determine drift severity label.
# Args: drift_value
_drift_label() {
	local drift="${1:-0}"
	drift=$(printf "%.3f" "$drift" 2>/dev/null || echo "0")
	if _check_bc; then
		if (($(echo "$drift < -0.20" | bc -l 2>/dev/null))); then
			echo "major"
		elif (($(echo "$drift < -0.10" | bc -l 2>/dev/null))); then
			echo "minor"
		else
			echo "none"
		fi
	else
		echo "none"
	fi
}

# ── fleet_aggregate_feedback ────────────────────────────────────────────────────
# Main entry point: aggregate planner feedback across all active pipeline logs.
# Usage: fleet_aggregate_feedback [workspace] [--initiative ID]
fleet_aggregate_feedback() {
	local workspace="${FLEET_PIPELINE_LOG_DIR:-./logs}"
	local filter_initiative=""
	local dry_run="${FLEET_DRY_RUN:-false}"

	# Parse optional flags. First positional arg (if not a flag) is workspace.
	while [ $# -gt 0 ]; do
		case "$1" in
		--initiative)
			filter_initiative="$2"
			shift 2
			;;
		--dry-run)
			dry_run="true"
			shift
			;;
		--*) shift ;; # skip unknown flags
		*)
			workspace="$1"
			shift
			;;
		esac
	done

	local repos_root="${REPOS_ROOT:-}"
	if [ -z "$repos_root" ]; then
		echo "WARNING: REPOS_ROOT not set — feedback output path may be incorrect" >&2
		repos_root="${HOME}/.ticket-auto"
	fi

	local rundate
	rundate=$(date +%Y-%m-%d)

	echo "fleet_feedback: scanning pipeline logs in ${workspace}..."

	if [ ! -d "$workspace" ]; then
		echo "no pipeline logs found (workspace ${workspace} does not exist)"
		return 0
	fi

	# Collect feedback entries by initiative
	declare -A FEEDBACK_SOURCES # initiative_id → JSON array of feedback entries
	local total_entries=0

	for log_file in "$workspace"/*-pipeline.log; do
		[ -f "$log_file" ] || continue

		local tid
		tid=$(basename "$log_file" | sed 's/-pipeline.log$//')
		[ -z "$tid" ] && continue

		# Find META|planner-feedback entries in this pipeline log
		local fb_lines
		fb_lines=$(command grep '|META|planner-feedback|' "$log_file" 2>/dev/null || true)
		[ -z "$fb_lines" ] && continue

		# Get initiative labels for this ticket
		local initiatives
		initiatives=$(_get_initiative_labels "$tid" 2>/dev/null || true)
		[ -z "$initiatives" ] && echo "  tid=${tid}: skipping (no initiative labels)" >&2 && continue

		# Process each feedback entry
		while IFS= read -r line; do
			[ -z "$line" ] && continue
			local payload
			if ! payload=$(_parse_feedback_payload "$line" 2>/dev/null); then
				echo "  tid=${tid}: warning — malformed JSON in planner-feedback entry, skipping" >&2
				continue
			fi

			total_entries=$((total_entries + 1))

			# Attach source ticket and timestamp to payload
			local iso
			iso=$(echo "$line" | awk -F'|' '{print $1}')
			local enriched
			enriched=$(echo "$payload" | jq -c \
				--arg tid "$tid" \
				--arg iso "$iso" \
				'. + {source_tid: $tid, source_iso: $iso}' 2>/dev/null)

			# Add to each initiative this ticket belongs to
			for init_id in $initiatives; do
				[ -n "$filter_initiative" ] && [ "$init_id" != "$filter_initiative" ] && continue
				local key="feedback_${init_id}"
				if [ -z "${FEEDBACK_SOURCES[$key]:-}" ]; then
					FEEDBACK_SOURCES[$key]="$enriched"
				else
					FEEDBACK_SOURCES[$key]="${FEEDBACK_SOURCES[$key]}"$'\n'"$enriched"
				fi
			done
		done <<<"$fb_lines"
	done

	if [ "$total_entries" -eq 0 ]; then
		echo "no feedback to aggregate"
		return 0
	fi

	echo "fleet_feedback: found ${total_entries} feedback entries across pipelines"

	# Write feedback per initiative
	local written=0
	for key in "${!FEEDBACK_SOURCES[@]}"; do
		local init_id="${key#feedback_}"
		local entries="${FEEDBACK_SOURCES[$key]}"

		# Build tickets array from entries
		local tickets_json
		tickets_json=$(echo "$entries" | jq -s '.' 2>/dev/null)

		# Compute summary statistics
		local ticket_count avg_confidence drift_count
		ticket_count=$(echo "$tickets_json" | jq -r 'length' 2>/dev/null)
		avg_confidence=$(echo "$tickets_json" | jq -r '[.[].confidence_actual // 0] | add / length' 2>/dev/null)
		[ -z "$avg_confidence" ] && avg_confidence=0

		# Count tickets with drift
		drift_count=0
		while IFS= read -r entry; do
			[ -z "$entry" ] && continue
			local predicted actual drift
			predicted=$(echo "$entry" | jq -r '.confidence_predicted // 0' 2>/dev/null)
			actual=$(echo "$entry" | jq -r '.confidence_actual // 0' 2>/dev/null)
			drift=$(_compute_drift "$predicted" "$actual")
			local label
			label=$(_drift_label "$drift")
			[ "$label" != "none" ] && drift_count=$((drift_count + 1))
		done <<<"$entries"

		# Collect services touched
		local services_json
		services_json=$(echo "$tickets_json" | jq -r '[.[].services_touched // []] | flatten | unique' 2>/dev/null)

		# ── Exploration accuracy aggregation ──────────────────────────────────────
		local exploration_insufficient_count=0 missed_symbols_total=0 false_traces_total=0
		while IFS= read -r entry; do
			[ -z "$entry" ] && continue
			local depth_actual
			depth_actual=$(echo "$entry" | jq -r '.exploration_depth_actual // ""' 2>/dev/null)
			[ "$depth_actual" = "insufficient" ] && exploration_insufficient_count=$((exploration_insufficient_count + 1))

			local missed
			missed=$(echo "$entry" | jq -r '.missed_symbols | length' 2>/dev/null || echo 0)
			[ -n "$missed" ] && [ "$missed" != "null" ] && missed_symbols_total=$((missed_symbols_total + missed))

			local false_t
			false_t=$(echo "$entry" | jq -r '.false_traces | length' 2>/dev/null || echo 0)
			[ -n "$false_t" ] && [ "$false_t" != "null" ] && false_traces_total=$((false_traces_total + false_t))
		done <<<"$entries"

		local exploration_insufficient_ratio=0
		[ "$ticket_count" -gt 0 ] 2>/dev/null && exploration_insufficient_ratio=$(echo "scale=2; $exploration_insufficient_count / $ticket_count" | bc 2>/dev/null || echo "0")

		local output_dir="${repos_root}/.ticket-auto/initiatives/${init_id}/feedback"
		local output_file="${output_dir}/${rundate}.json"

		if [ "$dry_run" = "true" ]; then
			echo "[DRY-RUN] would write ${init_id} feedback (${ticket_count} tickets) → ${output_file}"
			continue
		fi

		mkdir -p "$output_dir"

		local output_json
		output_json=$(jq -nc \
			--arg initiative_id "$init_id" \
			--arg rundate "$rundate" \
			--argjson tickets "$tickets_json" \
			--argjson total_tickets "$ticket_count" \
			--argjson avg_confidence_actual "$avg_confidence" \
			--argjson drift_count "$drift_count" \
			--argjson services_touched "$services_json" \
			--argjson exploration_insufficient_count "$exploration_insufficient_count" \
			--argjson exploration_insufficient_ratio "$exploration_insufficient_ratio" \
			--argjson missed_symbols_total "$missed_symbols_total" \
			--argjson false_traces_total "$false_traces_total" \
			'{
        initiative_id: $initiative_id,
        rundate: $rundate,
        tickets: $tickets,
        summary: {
          total_tickets: $total_tickets,
          avg_confidence_actual: $avg_confidence_actual,
          drift_count: $drift_count,
          services_touched: $services_touched,
          exploration_accuracy: {
            insufficient_count: $exploration_insufficient_count,
            insufficient_ratio: $exploration_insufficient_ratio,
            missed_symbols_total: $missed_symbols_total,
            false_traces_total: $false_traces_total
          }
        }
      }')

		echo "$output_json" | jq . >"$output_file"
		echo "  wrote ${init_id} feedback → ${output_file} (${ticket_count} tickets, drift: ${drift_count})"
		written=$((written + 1))
	done

	echo "fleet_feedback: aggregated ${total_entries} entries into ${written} initiative report(s)"
	return 0
}

# ── Sourceable/executable guard ──────────────────────────────────────────────────
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
	fleet_aggregate_feedback "$@"
fi
