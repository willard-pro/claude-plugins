#!/usr/bin/env bash
# planned-feedback-write.sh — Post-implement hook that emits META|planner-feedback
# entries to the pipeline log for planned tickets.
#
# Conditional on the planned label or FROM_PLANNED=true — no behavior change
# for unplanned tickets. fleet-feedback.sh aggregates these entries by initiative.
#
# Usage: planned_feedback_write <TICKET_ID> <LOG_FILE>
# Returns: 0 on success (or no-op skip), non-zero on error.
#
# Sourceable library — no set -euo pipefail.

# ── Main entry point ────────────────────────────────────────────────────────────

planned_feedback_write() {
	local tid="$1" log_file="$2"

	# Gate: only emit feedback for planned tickets
	if [ "${FROM_PLANNED:-false}" != "true" ]; then
		# Check if the ticket has the planned label via Linear API
		local has_planned=false
		if declare -f get_issue >/dev/null 2>&1; then
			local labels
			labels=$(get_issue "$tid" 2>/dev/null | jq -r '.labels.nodes[]?.name // empty' 2>/dev/null || true)
			if echo "$labels" | grep -qw 'planned'; then
				has_planned=true
			fi
		fi
		if [ "$has_planned" != "true" ]; then
			return 0 # Not a planned ticket — silent no-op
		fi
	fi

	# Ensure log file exists
	if [ ! -f "$log_file" ]; then
		echo "planned-feedback-write: log file not found: $log_file" >&2
		return 1
	fi

	# ── Gather data from pipeline log ────────────────────────────────────────────

	# Outcome label (Smooth/Rough/Hard)
	local outcome
	outcome=$(grep '^[^|]*|META|outcome-label|info|' "$log_file" 2>/dev/null | tail -1 | awk -F'|' '{for(i=5;i<=NF;i++) printf "%s%s", $i, (i<NF?"|":"")}')

	# Corrections count (from CORRECTIONS blocks in notes.md, or pipeline log)
	local corrections_count=0
	if grep -q '^[^|]*|META|corrections|' "$log_file" 2>/dev/null; then
		corrections_count=$(grep -c '^[^|]*|META|corrections|' "$log_file" 2>/dev/null || echo 0)
	fi

	# Files changed — from IMPLEMENT phase log entries, or git diff
	local files_changed="[]"
	local branch
	branch=$(grep '^[^|]*|META|branch|info|' "$log_file" 2>/dev/null | tail -1 | awk -F'|' '{for(i=5;i<=NF;i++) printf "%s%s", $i, (i<NF?"|":"")}')
	if [ -n "$branch" ] && [ -d "$PWD/.git" ]; then
		# Sanitize branch name: strip shell metacharacters ($, backticks, semicolons,
		# pipes, newlines). Branch comes from our own pipeline log and should only
		# contain git-ref-safe characters, but defense in depth.
		local safe_branch="${branch//[;\`\$|]/\ }"
		safe_branch="${safe_branch//$'\n'/ }"
		# Try to get files changed on the branch vs main
		if git rev-parse "$safe_branch" >/dev/null 2>&1; then
			files_changed=$(git diff --name-only "origin/main...${safe_branch}" 2>/dev/null | jq -R -s 'split("\n") | map(select(length > 0))' 2>/dev/null || echo "[]")
		fi
	fi
	# Fallback: log any files referenced in implement step
	if [ "$files_changed" = "[]" ] || [ "$files_changed" = "" ]; then
		files_changed=$(grep '^[^|]*|IMPLEMENT|' "$log_file" 2>/dev/null | awk -F'|' '{for(i=5;i<=NF;i++) printf "%s%s", $i, (i<NF?"|":"")}' | grep -oP '/?[a-zA-Z0-9_/.-]+\.[a-zA-Z]+' 2>/dev/null | sort -u | jq -R -s 'split("\n") | map(select(length > 0))' 2>/dev/null || echo "[]")
	fi

	# ── Confidence ───────────────────────────────────────────────────────────────

	# Predicted confidence — extracted from Planner Context block in ticket description
	local confidence_predicted=0
	if declare -f get_issue >/dev/null 2>&1; then
		local description
		description=$(get_issue "$tid" 2>/dev/null | jq -r '.description // ""' 2>/dev/null || true)
		if [ -n "$description" ]; then
			# Extract Confidence field from Planner Context block
			local conf_line
			conf_line=$(echo "$description" | sed -n '/## Planner Context/,/^## /p' | grep -i '^\s*-\s*Confidence:' | head -1)
			if [ -n "$conf_line" ]; then
				confidence_predicted=$(echo "$conf_line" | grep -oP '[\d.]+' | head -1 || echo 0)
			fi
		fi
	fi

	# Actual confidence — derived from outcome signals
	local confidence_actual
	confidence_actual=$(_compute_actual_confidence "$outcome" "$corrections_count")

	# ── Services touched ─────────────────────────────────────────────────────────

	local services_touched="[]"
	# Extract from Planner Context block
	if [ -n "$description" ]; then
		services_touched=$(echo "$description" | sed -n '/## Planner Context/,/^## /p' | grep -i '^\s*-\s*Affected Services:' | head -1 | sed 's/.*Affected Services:\s*//' | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | grep -v '^$' | jq -R -s 'split("\n") | map(select(length > 0))' 2>/dev/null || echo "[]")
	fi

	# ── Decision drift ───────────────────────────────────────────────────────────

	local decision_drift
	decision_drift=$(_compute_decision_drift "$confidence_predicted" "$confidence_actual")

	# ── Exploration accuracy ─────────────────────────────────────────────────────

	local exploration_depth_declared="" exploration_depth_actual="" missed_symbols="[]" false_traces="[]" code_paths_traced=""

	# Extract exploration fields from Planner Context block
	if [ -n "$description" ]; then
		exploration_depth_declared=$(echo "$description" | sed -n '/## Planner Context/,/^## /p' | grep -i '^\s*\*\*Exploration Depth:\*\*' | head -1 | sed 's/.*\*\*Exploration Depth:\*\*\s*//' || true)
		code_paths_traced=$(echo "$description" | sed -n '/## Planner Context/,/^## /p' | grep -i '^\s*\*\*Code Paths Traced:\*\*' | head -1 | sed 's/.*\*\*Code Paths Traced:\*\*\s*//' || true)
	fi

	# Compute exploration accuracy when the ticket was planned with exploration data
	if [ -n "$exploration_depth_declared" ]; then
		# Parse declared code paths into a clean list for comparison
		local traced_list="[]"
		if [ -n "$code_paths_traced" ]; then
			traced_list=$(echo "$code_paths_traced" | tr ';' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | grep -v '^$' | jq -R -s 'split("\n") | map(select(length > 0))' 2>/dev/null || echo "[]")
		fi

		# Compare actual files changed vs. traced code paths
		# missed_symbols: files in the diff whose symbols were NOT in Code Paths Traced
		# false_traces: symbols in Code Paths Traced whose files were NOT in the diff
		if [ "$files_changed" != "[]" ] && [ -n "$files_changed" ]; then
			local changed_files_list
			changed_files_list=$(echo "$files_changed" | jq -r '.[]' 2>/dev/null || true)

			if [ "$traced_list" != "[]" ] && [ -n "$changed_files_list" ]; then
				# Extract file paths from traced symbols (symbol:file → file)
				local traced_files
				traced_files=$(echo "$code_paths_traced" | tr ';' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | grep -v '^$' | sed 's/^[^:]*://' | sort -u)

				# missed_symbols: changed files not in traced files
				local missed_list=""
				while IFS= read -r f; do
					[ -z "$f" ] && continue
					if ! echo "$traced_files" | grep -qF "$f"; then
						missed_list="${missed_list}${missed_list:+,}\"${f}\""
					fi
				done <<<"$changed_files_list"
				missed_symbols="[${missed_list}]"

				# false_traces: traced symbols whose file wasn't changed
				local false_list=""
				while IFS= read -r entry; do
					[ -z "$entry" ] && continue
					local sym_file
					sym_file=$(echo "$entry" | sed 's/^[^:]*://') # extract file from symbol:file
					if ! echo "$changed_files_list" | grep -qF "$sym_file"; then
						false_list="${false_list}${false_list:+,}\"${entry}\""
					fi
				done <<<"$(echo "$code_paths_traced" | tr ';' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | grep -v '^$')"
				false_traces="[${false_list}]"
			elif [ -z "$changed_files_list" ] || [ "$changed_files_list" = "[]" ]; then
				# No files changed — all traced paths are false traces
				false_traces="$traced_list"
			fi
		fi

		# Determine exploration_depth_actual
		# sufficient: no missed symbols, no false traces
		# insufficient: missed symbols found
		# over: false traces found but no missed symbols
		local missed_count false_count
		missed_count=$(echo "$missed_symbols" | jq 'length' 2>/dev/null || echo 0)
		false_count=$(echo "$false_traces" | jq 'length' 2>/dev/null || echo 0)

		if [ "$missed_count" -gt 0 ] 2>/dev/null; then
			exploration_depth_actual="insufficient"
		elif [ "$false_count" -gt 0 ] 2>/dev/null; then
			exploration_depth_actual="$exploration_depth_declared" # over-traced but depth was sufficient
		else
			exploration_depth_actual="$exploration_depth_declared"
		fi
	fi

	# ── Emit feedback entry ──────────────────────────────────────────────────────

	local payload iso
	payload=$(jq -nc \
		--argjson confidence_predicted "$confidence_predicted" \
		--argjson confidence_actual "$confidence_actual" \
		--arg outcome "$outcome" \
		--argjson corrections_count "$corrections_count" \
		--argjson files_changed "$files_changed" \
		--argjson services_touched "$services_touched" \
		--arg decision_drift "$decision_drift" \
		--arg exploration_depth_declared "$exploration_depth_declared" \
		--arg exploration_depth_actual "$exploration_depth_actual" \
		--argjson missed_symbols "$missed_symbols" \
		--argjson false_traces "$false_traces" \
		'{
      confidence_predicted: $confidence_predicted,
      confidence_actual: $confidence_actual,
      outcome: $outcome,
      corrections_count: $corrections_count,
      files_changed: $files_changed,
      services_touched: $services_touched,
      decision_drift: $decision_drift
    }
    + if $exploration_depth_declared != "" then {
      exploration_depth_declared: $exploration_depth_declared,
      exploration_depth_actual: $exploration_depth_actual,
      missed_symbols: $missed_symbols,
      false_traces: $false_traces
    } else {} end' 2>/dev/null)

	if [ -z "$payload" ]; then
		echo "planned-feedback-write: jq payload construction failed" >&2
		return 1
	fi

	iso=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
	echo "${iso}|META|planner-feedback|info|${payload}" >>"$log_file"

	return 0
}

# ── Helpers ─────────────────────────────────────────────────────────────────────

# Compute actual confidence from outcome and corrections.
# Smooth → 0.85+, Rough → 0.50–0.84, Hard → <0.50
# Corrections subtract 0.05 each.
_compute_actual_confidence() {
	local outcome="$1" corrections="${2:-0}"
	local base

	case "$outcome" in
	Smooth) base=90 ;;
	Rough) base=65 ;;
	Hard) base=40 ;;
	*) base=70 ;; # Unknown outcome — neutral
	esac

	# Subtract corrections
	local penalty=$((corrections * 5))
	local score=$((base - penalty))

	# Floor at 10
	[ "$score" -lt 10 ] && score=10

	# Convert to 0-1 scale (divide by 100)
	echo "0.${score}"
}

# Compute decision drift label from predicted vs actual confidence.
# none: ≤0.10, minor: 0.11–0.25, major: >0.25
_compute_decision_drift() {
	local predicted="$1" actual="$2"

	# Handle missing/zero values
	[ -z "$predicted" ] && predicted=0
	[ -z "$actual" ] && actual=0

	# Scale to integer hundredths for bash arithmetic
	local p_int a_int diff
	p_int=$(echo "$predicted * 100" | bc 2>/dev/null | cut -d'.' -f1 || echo 0)
	a_int=$(echo "$actual * 100" | bc 2>/dev/null | cut -d'.' -f1 || echo 0)

	diff=$((p_int - a_int))
	[ "$diff" -lt 0 ] && diff=$((-diff))

	if [ "$diff" -le 10 ]; then
		echo "none"
	elif [ "$diff" -le 25 ]; then
		echo "minor"
	else
		echo "major"
	fi
}
