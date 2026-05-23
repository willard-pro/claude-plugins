# ticket-overseer

> Pipeline observability dashboard — generates standup summaries of completed work and real-time status reports of in-flight tickets, including stall detection.

## What it does

`ticket-overseer` gives you a window into what the pipeline is doing (or has done). Run it in **standup** mode to get a summary of every ticket that completed, failed, or stalled yesterday (or on a given date). Run it in **status** mode to see which tickets are currently in-flight, which phase each one is in, and whether any phase has been running suspiciously long. It reads only pipeline logs and session traces — it never modifies any state.

## Trigger

**Slash command:**
- `/ticket-overseer standup [--date YYYY-MM-DD]`
- `/ticket-overseer status [--stale-minutes N]`

**Natural language:** "standup report", "what's the pipeline status", "overseer status"

## Inputs

| Input | Source | Required |
|-------|--------|----------|
| Mode (`standup` / `status`) | CLI argument | Yes |
| `--date` | CLI flag | No (standup mode; default: yesterday) |
| `--stale-minutes` | CLI flag | No (status mode; default: 15) |
| Pipeline logs | `tickets/*/logs/*.log` | Yes |
| Session traces | `tickets/**/auto-session.md` | Yes |
| Complexity notes | `tickets/**/notes.md` | No |

## Outputs / Artifacts

| Artifact | Location | Description |
|----------|----------|-------------|
| Standup report | Stdout | Yesterday's completed tickets, failures, and time-per-phase |
| Status report | Stdout | In-flight tickets with current phase and stall warnings |

## How it works

```mermaid
flowchart TD
    A([Start]) --> B{Mode?}
    B -- standup --> C[Read logs for target date\nfilter completed entries]
    B -- status --> D[Read all active logs\nfind in-progress phases]
    C --> E[Aggregate by ticket\nphase durations + outcome]
    D --> F[Flag stale phases\nover --stale-minutes]
    E --> G[Format standup report\nmarkdown table]
    F --> H[Format status report\nwith stall warnings]
    G --> I([Print report])
    H --> I
```

## Related skills

- [`/ticket-auto`](ticket-auto.md) — generates the pipeline logs this skill reads
- [`/ticket-retro`](ticket-retro.md) — retrospective fix proposals (complements standup view)
