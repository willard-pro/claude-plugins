#!/usr/bin/env bash
# Fleet dashboard renderer — health table (terminal) and markdown report (file).
#
# NOTE: Does NOT set -euo pipefail — this is a sourceable library.
# Callers are responsible for shell flags.

_DASH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source heartbeat from canonical path (synced by ticket-auto-pipeline SessionStart hook)
if ! declare -f _plog >/dev/null 2>&1; then
  for _hp in "$_DASH_DIR/heartbeat.sh" "$HOME/.claude/skills/lib/heartbeat.sh"; do
    [ -f "$_hp" ] && source "$_hp" && break
  done
fi
# Source fleet-detect.sh for fleet_detect_all if not already loaded
_source_if_missing fleet_detect_all "$_DASH_DIR/fleet-detect.sh"

# ── Post-mortem issue count ──────────────────────────────────────────────────────
# Reads the pipeline log for the latest META|postmortem summary and returns the
# count of filed issues. Returns 0 if no postmortem data found.
# Usage: _postmortem_issue_count <tid> <workspace>
_postmortem_issue_count() {
  local tid="$1"
  local workspace="${2:-./logs}"
  local log_file="${workspace}/${tid}-pipeline.log"

  if [ ! -f "$log_file" ]; then
    echo "0"
    return 0
  fi

  local _filed
  _filed=$(grep '|META|postmortem|info|' "$log_file" 2>/dev/null | tail -1 |
    awk -F'|' '{for(i=5;i<=NF;i++) printf "%s%s", $i, (i==NF?"":"|")}' |
    jq -r '.filed // 0' 2>/dev/null || echo "0")
  echo "${_filed:-0}"
}

# ── Severity info helper ─────────────────────────────────────────────────────────
# Combined icon + label for a severity level.
# When FLEET_AUTO_RESTART=false, severity 3 (RESTART) is capped to 2 (KILL).
# The label reflects the effective action so dashboard shows what WILL happen,
# not what was detected (which already appears in the anomalies field).
# Output: "icon|label" — callers use IFS='|' read -r icon label.
# Usage: IFS='|' read -r icon label <<<"$(_severity_info "$sev")"
_severity_info() {
  case "${1:-0}" in
  0) echo "🟢|OK" ;;
  1) echo "🟡|WARN" ;;
  2) echo "🔴|KILL" ;;
  3) [ "${FLEET_AUTO_RESTART:-false}" != "true" ] && echo "🔴|KILL (auto-restart off)" || echo "💀|RESTART" ;;
  *) echo "❓|??" ;;
  esac
}

# ── fleet_render_dashboard ──────────────────────────────────────────────────────
# Render a formatted health table to stdout.
# Thin wrapper — runs detection then delegates to _from_data variant.
# Usage: fleet_render_dashboard [workspace]
fleet_render_dashboard() {
  local workspace="${1:-./logs}"
  local data

  if ! data=$(fleet_detect_all "$workspace" 2>/dev/null); then
    echo "=== Fleet Controller Dashboard ==="
    echo "Time: $(_iso_now)"
    echo "Workspace: ${workspace}"
    echo ""
    echo "Error: fleet_detect_all failed"
    return 1
  fi

  fleet_render_dashboard_from_data "$data" "$workspace"
}

# ── fleet_render_dashboard_from_data ─────────────────────────────────────────────
# Render dashboard from pre-computed fleet_detect_all JSON. Avoids duplicate detection.
# Usage: fleet_render_dashboard_from_data <data_json> <workspace>
fleet_render_dashboard_from_data() {
  local data="$1"
  local workspace="${2:-./logs}"

  local total healthy warn kill restart
  total=$(echo "$data" | jq -r '.summary.total // 0')
  healthy=$(echo "$data" | jq -r '.summary.healthy // 0')
  warn=$(echo "$data" | jq -r '.summary.warn // 0')
  kill=$(echo "$data" | jq -r '.summary.kill // 0')
  restart=$(echo "$data" | jq -r '.summary.restart // 0')

  echo "=== Fleet Controller Dashboard ==="
  echo "Time: $(_iso_now)"
  echo "Workspace: ${workspace}"
  echo ""

  if [ "$total" -eq 0 ]; then
    echo "No active pipelines"
    return 0
  fi

  # Header
  printf "%-12s %-12s %-6s %-8s %-9s %s\n" "TICKET" "PHASE" "STALL" "SEV" "AUTO-RETRO" "ANOMALIES"
  printf "%-12s %-12s %-6s %-8s %-9s %s\n" "------" "------" "----" "--" "----------" "--------"

  # Sort by severity descending, then by ticket ID
  echo "$data" | jq -r '.pipelines | sort_by([-.severity, .tid]) | .[] | "\(.tid)|\(.phase)|\(.hb_age_secs)|\(.severity)|\(.anomalies)"' | while IFS='|' read -r tid phase hb_age sev anomalies; do
    local icon label
    IFS='|' read -r icon label <<<"$(_severity_info "${sev:-0}")"

    # Format stall as human-readable
    local stall_str="${hb_age}s"
    if [ "${hb_age:-0}" -ge 3600 ]; then
      stall_str="$((hb_age / 3600))h$(((hb_age % 3600) / 60))m"
    elif [ "${hb_age:-0}" -ge 60 ]; then
      stall_str="$((hb_age / 60))m$((hb_age % 60))s"
    fi

    # Post-mortem auto-retro open issue count
    local pm_count
    pm_count=$(_postmortem_issue_count "$tid" "$workspace")
    local pm_str="${pm_count} open"

    printf "%-12s %-12s %-6s %s %-9s %s\n" "${tid}" "${phase}" "${stall_str}" "${icon}${label}" "${pm_str}" "${anomalies}"
  done

  echo ""
  echo "Summary: ${total} active — ${healthy} healthy, ${warn} warn, ${kill} kill, ${restart} restart"

  # Fleet-wide detectors
  local fw_count
  fw_count=$(echo "$data" | jq -r '.fleet_wide | length // 0' 2>/dev/null || echo "0")
  if [ "${fw_count:-0}" -gt 0 ]; then
    echo ""
    echo "--- Fleet-Wide Detectors ---"
    echo "$data" | jq -r '.fleet_wide[] | "\(.name)|\(.severity)|\(.findings)"' 2>/dev/null | while IFS='|' read -r dname dsev dfindings; do
      local icon label
      IFS='|' read -r icon label <<<"$(_severity_info "${dsev:-0}")"
      [ -n "$dfindings" ] && echo "  ${icon} ${dname}: ${dfindings}" || echo "  ${icon} ${dname}: clear"
    done
  fi
}

# ── fleet_write_report_from_data ─────────────────────────────────────────────────
# Write markdown report from pre-computed fleet_detect_all JSON.
# Usage: fleet_write_report_from_data <data_json> <workspace>
fleet_write_report_from_data() {
  local data="$1"
  local workspace="${2:-./logs}"
  local report_dir="${workspace}/reports"
  local report_file="${report_dir}/fleet-dashboard.md"

  mkdir -p "$report_dir"

  local total healthy warn kill restart
  total=$(echo "$data" | jq -r '.summary.total // 0')
  healthy=$(echo "$data" | jq -r '.summary.healthy // 0')
  warn=$(echo "$data" | jq -r '.summary.warn // 0')
  kill=$(echo "$data" | jq -r '.summary.kill // 0')
  restart=$(echo "$data" | jq -r '.summary.restart // 0')

  # Build the report
  {
    echo "# Fleet Controller Report"
    echo ""
    echo "**Time:** $(_iso_now)"
    echo "**Workspace:** \`${workspace}\`"
    echo ""

    if [ "$total" -eq 0 ]; then
      echo "No active pipelines"
      echo ""
      echo "**Summary:** 0 active pipelines"
      return
    fi

    echo "## Health Table"
    echo ""
    echo "| Ticket | Phase | Stall | Severity | Anomalies |"
    echo "|--------|-------|-------|----------|-----------|"

    echo "$data" | jq -r '.pipelines | sort_by([-.severity, .tid]) | .[] | "| \(.tid) | \(.phase) | \(.hb_age_secs)s | \(.severity) | \(.anomalies) |"' | while IFS= read -r row; do
      echo "$row"
    done

    echo ""
    echo "**Summary:** ${total} active — ${healthy} 🟢 healthy, ${warn} 🟡 warn, ${kill} 🔴 kill, ${restart} 💀 restart"

    # Fleet-wide detector section in markdown
    local fw_count
    fw_count=$(echo "$data" | jq -r '.fleet_wide | length // 0' 2>/dev/null || echo "0")
    if [ "${fw_count:-0}" -gt 0 ]; then
      echo "## Fleet-Wide Detectors"
      echo ""
      echo "| Detector | Severity | Findings |"
      echo "|----------|----------|----------|"

      echo "$data" | jq -r '.fleet_wide[] | "\(.name)|\(.severity)|\(.findings // \"clear\")"' 2>/dev/null | while IFS='|' read -r dname dsev dfindings; do
        local icon label
        IFS='|' read -r icon label <<<"$(_severity_info "${dsev:-0}")"
        echo "| ${dname} | ${icon} ${label} (${dsev}) | ${dfindings:-clear} |"
      done
      echo ""
    fi

    # Alert detail section — one subsection per pipeline with severity ≥ WARN
    local alerts
    alerts=$(echo "$data" | jq -r '[.pipelines[] | select(.severity >= 1)] | length')

    if [ "${alerts:-0}" -gt 0 ]; then
      echo ""
      echo "## Alerts"
      echo ""

      echo "$data" | jq -r '.pipelines[] | select(.severity >= 1) | "\(.tid)|\(.severity)|\(.anomalies)|\(.phase)"' | while IFS='|' read -r tid sev anomalies phase; do
        local icon label
        IFS='|' read -r icon label <<<"$(_severity_info "${sev:-1}")"

        echo "### ${icon} ${tid} — ${label}"
        echo ""
        echo "- **Phase:** ${phase}"
        echo "- **Severity:** ${label} (${sev})"
        echo "- **Anomalies:** ${anomalies}"
        echo ""

        # Collect diagnostic context
        echo "#### Diagnostic Context"
        echo ""
        echo '```'
        extract_diagnostics "$tid" "${phase}" "$workspace" 2>/dev/null || echo "  (diagnostics unavailable)"
        echo '```'
        echo ""
      done
    fi
  } >"$report_file"
}

# ── fleet_write_report ──────────────────────────────────────────────────────────
# Write health dashboard as markdown to logs/reports/fleet-dashboard.md.
# Thin wrapper — runs detection then delegates to _from_data variant.
# Usage: fleet_write_report [workspace]
fleet_write_report() {
  local workspace="${1:-./logs}"
  local report_dir="${workspace}/reports"
  local report_file="${report_dir}/fleet-dashboard.md"

  mkdir -p "$report_dir"

  local data
  if ! data=$(fleet_detect_all "$workspace" 2>/dev/null); then
    {
      echo "# Fleet Controller Report"
      echo ""
      echo "**Time:** $(_iso_now)"
      echo ""
      echo "⚠️  Error: fleet_detect_all failed"
    } >"$report_file"
    return 1
  fi

  fleet_write_report_from_data "$data" "$workspace"
  echo "fleet_write_report: wrote ${report_file}"
}
