#!/usr/bin/env bash
# Fleet dashboard renderer — health table (terminal) and markdown report (file).
#
# NOTE: Does NOT set -euo pipefail — this is a sourceable library.
# Callers are responsible for shell flags.

_DASH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source fleet-detect.sh for fleet_detect_all if not already loaded
if ! declare -f fleet_detect_all >/dev/null 2>&1; then
  [ -f "$_DASH_DIR/fleet-detect.sh" ] && source "$_DASH_DIR/fleet-detect.sh"
fi

# ── Severity label helper ────────────────────────────────────────────────────────
# When FLEET_AUTO_RESTART=false, severity 3 (RESTART) is capped to 2 (KILL).
# The label reflects the effective action so dashboard shows what WILL happen,
# not what was detected (which already appears in the anomalies field).
_severity_label() {
  local sev="$1"
  case "$sev" in
  0) echo "OK" ;;
  1) echo "WARN" ;;
  2) echo "KILL" ;;
  3)
    if [ "${FLEET_AUTO_RESTART:-false}" != "true" ]; then
      echo "KILL (auto-restart off)"
    else
      echo "RESTART"
    fi
    ;;
  *) echo "??" ;;
  esac
}

_severity_icon() {
  local sev="$1"
  case "$sev" in
  0) echo "🟢" ;;
  1) echo "🟡" ;;
  2) echo "🔴" ;;
  3)
    if [ "${FLEET_AUTO_RESTART:-false}" != "true" ]; then
      echo "🔴"
    else
      echo "💀"
    fi
    ;;
  *) echo "❓" ;;
  esac
}

# ── fleet_render_dashboard ──────────────────────────────────────────────────────
# Render a formatted health table to stdout.
# Usage: fleet_render_dashboard [workspace]
fleet_render_dashboard() {
  local workspace="${1:-./logs}"
  local data

  if ! data=$(fleet_detect_all "$workspace" 2>/dev/null); then
    echo "=== Fleet Controller Dashboard ==="
    echo "Time: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "Workspace: ${workspace}"
    echo ""
    echo "Error: fleet_detect_all failed"
    return 1
  fi

  local total healthy warn kill restart
  total=$(echo "$data" | jq -r '.summary.total // 0')
  healthy=$(echo "$data" | jq -r '.summary.healthy // 0')
  warn=$(echo "$data" | jq -r '.summary.warn // 0')
  kill=$(echo "$data" | jq -r '.summary.kill // 0')
  restart=$(echo "$data" | jq -r '.summary.restart // 0')

  echo "=== Fleet Controller Dashboard ==="
  echo "Time: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "Workspace: ${workspace}"
  echo ""

  if [ "$total" -eq 0 ]; then
    echo "No active pipelines"
    return 0
  fi

  # Header
  printf "%-12s %-12s %-6s %-8s %s\n" "TICKET" "PHASE" "STALL" "SEV" "ANOMALIES"
  printf "%-12s %-12s %-6s %-8s %s\n" "------" "------" "----" "--" "--------"

  # Sort by severity descending, then by ticket ID
  echo "$data" | jq -r '.pipelines | sort_by([-.severity, .tid]) | .[] | "\(.tid)|\(.phase)|\(.hb_age_secs)|\(.severity)|\(.anomalies)"' | while IFS='|' read -r tid phase hb_age sev anomalies; do
    local icon
    icon=$(_severity_icon "${sev:-0}")
    local sev_label
    sev_label=$(_severity_label "${sev:-0}")

    # Format stall as human-readable
    local stall_str="${hb_age}s"
    if [ "${hb_age:-0}" -ge 3600 ]; then
      stall_str="$((hb_age / 3600))h$(((hb_age % 3600) / 60))m"
    elif [ "${hb_age:-0}" -ge 60 ]; then
      stall_str="$((hb_age / 60))m$((hb_age % 60))s"
    fi

    printf "%-12s %-12s %-6s %s %s\n" "${tid}" "${phase}" "${stall_str}" "${icon}${sev_label}" "${anomalies}"
  done

  echo ""
  echo "Summary: ${total} active — ${healthy} healthy, ${warn} warn, ${kill} kill, ${restart} restart"
}

# ── fleet_write_report ──────────────────────────────────────────────────────────
# Write health dashboard as markdown to logs/reports/fleet-dashboard.md.
# Overwrites on each invocation.
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
      echo "**Time:** $(date -u +%Y-%m-%dT%H:%M:%SZ)"
      echo ""
      echo "⚠️  Error: fleet_detect_all failed"
    } >"$report_file"
    return 1
  fi

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
    echo "**Time:** $(date -u +%Y-%m-%dT%H:%M:%SZ)"
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

    # Alert detail section — one subsection per pipeline with severity ≥ WARN
    local alerts
    alerts=$(echo "$data" | jq -r '[.pipelines[] | select(.severity >= 1)] | length')

    if [ "${alerts:-0}" -gt 0 ]; then
      echo ""
      echo "## Alerts"
      echo ""

      echo "$data" | jq -r '.pipelines[] | select(.severity >= 1) | "\(.tid)|\(.severity)|\(.anomalies)|\(.phase)"' | while IFS='|' read -r tid sev anomalies phase; do
        local sev_icon sev_label
        sev_icon=$(_severity_icon "${sev:-1}")
        sev_label=$(_severity_label "${sev:-1}")

        echo "### ${sev_icon} ${tid} — ${sev_label}"
        echo ""
        echo "- **Phase:** ${phase}"
        echo "- **Severity:** ${sev_label} (${sev})"
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

  echo "fleet_write_report: wrote ${report_file}"
}
