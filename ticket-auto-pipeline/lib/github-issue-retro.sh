#!/usr/bin/env bash
# Deterministic GitHub issue state machine for ticket-retro --post-to-github.
# Handles: state file read/write, threshold check, severity mapping,
# create-vs-comment decision. Content (issue body, comment text) is
# provided by the caller via temp files — this script only handles mechanics.
#
# Usage:
#   github_retro_process <input_json_file>
#
# Input JSON format (path to file):
#   {
#     "codes": {
#       "EXEC_NO_ARTIFACT": {
#         "count": 4,
#         "title": "Fix EXEC_NO_ARTIFACT — artifact not found after exec phase",
#         "body_file": "/tmp/issue-body-EXEC_NO_ARTIFACT.md",
#         "comment_file": "/tmp/evidence-EXEC_NO_ARTIFACT.md"
#       }
#     }
#   }
#
# Output JSON on stdout:
#   {
#     "created": [{"code": "EXEC_NO_ARTIFACT", "url": "https://..."}],
#     "updated": [{"code": "APPROVAL_REVOKED", "url": "https://..."}],
#     "skipped": ["RETURN_INCOMPLETE"]
#   }
#
# -u (nounset) intentionally omitted: Claude Code shell snapshots inject
# ZSH_VERSION references that trigger false-positive "unbound variable"
# errors in this bash version when nounset is active.
set -eo pipefail

# Source github-issues.sh for API functions
_GI_LIB="$(dirname "${BASH_SOURCE[0]}")/github-issues.sh"
[ -f "$_GI_LIB" ] && source "$_GI_LIB"

# Source config for constants
_CONFIG_LIB="$(dirname "${BASH_SOURCE[0]}")/config.sh"
[ -f "$_CONFIG_LIB" ] && source "$_CONFIG_LIB"

# Source heartbeat for hb_* functions
_HB_LIB="$(dirname "${BASH_SOURCE[0]}")/heartbeat.sh"
[ -f "$_HB_LIB" ] && source "$_HB_LIB"

# ── State file paths ──────────────────────────────────────────────────────────

STATE_DIR="${HOME}/.claude/state/ticket-retro"
STATE_FILE="${STATE_DIR}/github-issues.json"

# ── Severity mapping ──────────────────────────────────────────────────────────
# Deterministic lookup — no AI interpretation, no markdown table parsing.
# Returns: "<type_label>,<severity>" (e.g. "bug,P0", "improvement,P3")
github_retro_map_severity() {
  local code="$1"

  case "$code" in
  EXEC_NO_ARTIFACT) echo "bug,P0" ;;
  APPROVAL_REVOKED) echo "bug,P0" ;;
  PR_REVIEW_VERDICT_UNPARSEABLE) echo "bug,P1" ;;
  COMPLEXITY_ARTIFACT_MISMATCH) echo "bug,P2" ;;
  REMEDIATION_BRIEF_TRUNCATED) echo "bug,P2" ;;
  RETURN_INCOMPLETE) echo "improvement,P3" ;;
  complexity-drift) echo "improvement,P3" ;;
  *) echo "bug,P2" ;; # Unknown → bug,P2
  esac
}

# ── State file helpers ────────────────────────────────────────────────────────

# Read the state file, initializing if absent.
# Outputs JSON on stdout.
github_retro_read_state() {
  mkdir -p "$STATE_DIR"
  if [ ! -f "$STATE_FILE" ]; then
    echo '{}' >"$STATE_FILE"
  fi
  cat "$STATE_FILE"
}

# Write the state file. Validates JSON before writing.
# Usage: github_retro_write_state <json_string>
github_retro_write_state() {
  local new_state="$1"

  # Validate JSON
  if ! echo "$new_state" | jq empty 2>/dev/null; then
    echo "github_retro_write_state: invalid JSON — state file NOT updated" >&2
    return 1
  fi

  mkdir -p "$STATE_DIR"
  echo "$new_state" >"$STATE_FILE"
}

# Look up an existing issue number for a failure code in the state.
# Outputs the issue number on stdout, empty string if not found.
github_retro_state_lookup() {
  local state_json="$1"
  local code="$2"
  echo "$state_json" | jq -r --arg code "$code" '.[$code].issue_number // ""'
}

# Add or update a state entry for a created issue.
# Outputs updated state JSON on stdout.
github_retro_state_record_create() {
  local state_json="$1"
  local code="$2"
  local issue_number="$3"
  local issue_url="$4"
  local count="$5"
  local date="${6:-$(date -u +%Y-%m-%d)}"

  echo "$state_json" | jq \
    --arg code "$code" \
    --arg num "$issue_number" \
    --arg url "$issue_url" \
    --arg date "$date" \
    --arg count "$count" \
    '. + {($code): {issue_number: $num, issue_url: $url, last_evidence: $date, count: ($count | tonumber)}}'
}

# Update last_evidence and count for an existing entry (comment, not create).
# Outputs updated state JSON on stdout.
github_retro_state_record_comment() {
  local state_json="$1"
  local code="$2"
  local count="$3"
  local date="${4:-$(date -u +%Y-%m-%d)}"

  echo "$state_json" | jq \
    --arg code "$code" \
    --arg date "$date" \
    --arg count "$count" \
    '.[$code].last_evidence = $date | .[$code].count = ($count | tonumber)'
}

# ── Main processing function ──────────────────────────────────────────────────

# Process a set of failure codes through the GitHub issue state machine.
# Usage: github_retro_process <input_json_file>
# Input: path to JSON file (see header for format)
# Output: JSON report on stdout
github_retro_process() {
  local input_file="$1"

  if [ -z "$input_file" ] || [ ! -f "$input_file" ]; then
    echo "github_retro_process: input file required" >&2
    echo '{"created":[],"updated":[],"skipped":[]}'
    return 1
  fi

  # Validate input JSON
  if ! jq empty "$input_file" 2>/dev/null; then
    echo "github_retro_process: input file is not valid JSON" >&2
    echo '{"created":[],"updated":[],"skipped":[]}'
    return 1
  fi

  local state_json created updated skipped code count title body_file comment_file
  local existing_num lookup_result issue_state labels issue_url new_num

  state_json=$(github_retro_read_state)
  created="[]"
  updated="[]"
  skipped="[]"

  # Iterate over each failure code in the input
  for code in $(jq -r '.codes | keys[]' "$input_file"); do
    count=$(jq -r --arg code "$code" '.codes[$code].count' "$input_file")
    title=$(jq -r --arg code "$code" '.codes[$code].title // ""' "$input_file")
    body_file=$(jq -r --arg code "$code" '.codes[$code].body_file // ""' "$input_file")
    comment_file=$(jq -r --arg code "$code" '.codes[$code].comment_file // ""' "$input_file")

    # ── Threshold gate: count ≥ 2 ──────────────────────────────────────────
    if [ "$count" -lt 2 ]; then
      skipped=$(echo "$skipped" | jq --arg code "$code" '. + [$code]')
      continue
    fi

    # ── Map severity ───────────────────────────────────────────────────────
    labels=$(github_retro_map_severity "$code")

    # ── Check state for existing issue ─────────────────────────────────────
    existing_num=$(github_retro_state_lookup "$state_json" "$code")

    if [ -n "$existing_num" ]; then
      # Check if existing issue is still open
      if lookup_result=$(github_issue_lookup "$existing_num" 2>/dev/null); then
        issue_state=$(echo "$lookup_result" | jq -r '.state // "CLOSED"')
      else
        issue_state="NOT_FOUND"
      fi

      case "$issue_state" in
      OPEN)
        # ── Comment on existing open issue ──────────────────────────────
        if [ -n "$comment_file" ] && [ -f "$comment_file" ]; then
          issue_url=$(github_issue_comment "$existing_num" "$comment_file")
          state_json=$(github_retro_state_record_comment "$state_json" "$code" "$count")
          github_retro_write_state "$state_json"
          updated=$(echo "$updated" | jq \
            --arg code "$code" \
            --arg url "$issue_url" \
            '. + [{"code": $code, "url": $url}]')
        else
          # No comment file — nothing to do, still track as "seen"
          skipped=$(echo "$skipped" | jq --arg code "$code" '. + [$code]')
        fi
        ;;
      *)
        # ── Closed or not found → create new issue ──────────────────────
        if [ -n "$body_file" ] && [ -f "$body_file" ]; then
          issue_url=$(github_issue_create "$title" "$labels" "$body_file")
          new_num=$(echo "$issue_url" | grep -oP 'issues/\K\d+' || echo "0")
          state_json=$(github_retro_state_record_create "$state_json" "$code" "$new_num" "$issue_url" "$count")
          github_retro_write_state "$state_json"
          created=$(echo "$created" | jq \
            --arg code "$code" \
            --arg url "$issue_url" \
            '. + [{"code": $code, "url": $url}]')
        else
          echo "github_retro_process: no body_file for $code — skipping" >&2
          skipped=$(echo "$skipped" | jq --arg code "$code" '. + [$code]')
        fi
        ;;
      esac
    else
      # ── No existing entry → create new issue ────────────────────────────
      if [ -n "$body_file" ] && [ -f "$body_file" ]; then
        issue_url=$(github_issue_create "$title" "$labels" "$body_file")
        new_num=$(echo "$issue_url" | grep -oP 'issues/\K\d+' || echo "0")
        state_json=$(github_retro_state_record_create "$state_json" "$code" "$new_num" "$issue_url" "$count")
        github_retro_write_state "$state_json"
        created=$(echo "$created" | jq \
          --arg code "$code" \
          --arg url "$issue_url" \
          '. + [{"code": $code, "url": $url}]')
      else
        echo "github_retro_process: no body_file for $code — skipping" >&2
        skipped=$(echo "$skipped" | jq --arg code "$code" '. + [$code]')
      fi
    fi
  done

  # ── Output report ──────────────────────────────────────────────────────────
  jq -n \
    --argjson created "$created" \
    --argjson updated "$updated" \
    --argjson skipped "$skipped" \
    '{created: $created, updated: $updated, skipped: $skipped}'
}
