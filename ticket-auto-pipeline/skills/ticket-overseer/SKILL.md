# Ticket Overseer — Bot Standup & Status Reports

Observability layer for the ticket-auto pipeline. Reads pipeline logs and session traces to produce two report types: daily standup (retrospective) and periodic status (in-flight progress).

## When to Use

| Trigger | Mode |
|---------|------|
| `/ticket-overseer standup` | Generate yesterday's standup report |
| `/ticket-overseer status` | Generate current in-flight status report |
| `/ticket-overseer standup --date 2026-05-05` | Standup for a specific date |
| `/ticket-overseer status --stale-minutes 15` | Status with tighter stall detection |

## Data Sources

- `./logs/*.log` — pipeline event streams (real-time phase transitions)
- `./**/auto-session.md` — completed session traces per ticket
- `./**/notes.md` — complexity scores

## Report Formats

### Standup (`standup`)

Classic scrum-bot format:
- **Yesterday** — what was completed, what was stopped/held
- **Today** — what's active or queued, complexity predictions
- **Blockers** — held at gate, max retries reached, stalled tickets

Saved to `./logs/reports/standup-{date}.md`.

### Status (`status`)

Real-time progress snapshot:
- **Active** — current ticket, phase, progress bar, elapsed time
- **Recent** — completions in the last 24h
- **Alerts** — stalled tickets, held gates, failures needing intervention

Saved to `./logs/reports/status-{timestamp}.md`.

## Scheduling (Sandbox)

For autonomous operation, schedule the overseer via cron or the `/schedule` skill:

```
# Daily standup at 8:57 AM
/schedule "Run /ticket-overseer standup" --cron "57 8 * * 1-5"

# Status every 2 hours during workday
/schedule "Run /ticket-overseer status" --cron "7 */2 * * 1-5"
```

Reports accumulate in `./logs/reports/` and can be read by any observer.

## Output Channels

By default, reports print to stdout (for the invoking agent to capture) and write to `./logs/reports/`.

To post reports to Linear, pass `--post linear:{ISSUE-ID}` — the report is saved as a comment on the specified tracking issue.

### Slack

The skill reads `SLACK_CHANNEL` from the project's `CLAUDE.md`. For this workspace the channel is `credit-network-biz-bot`.

When Slack is configured, the skill posts the generated report to that channel via `slack_send_message`. If the channel is not found by name (e.g., it hasn't been created yet), the skill falls back to stdout-only and warns the user.

To look up the channel ID at runtime:
1. Call `slack_search_channels` with the channel name from `SLACK_CHANNEL`
2. If found, use the returned channel ID with `slack_send_message`
3. If not found, warn and skip Slack posting

## Implementation

The heavy lifting is in `report.py` — a standalone Python script with no external dependencies. The skill is a thin orchestrator that calls it and handles output routing (Slack, Linear, or stdout).

```
python3 ~/.claude/skills/ticket-overseer/report.py standup [--date YYYY-MM-DD]
python3 ~/.claude/skills/ticket-overseer/report.py status [--stale-minutes N]
```
