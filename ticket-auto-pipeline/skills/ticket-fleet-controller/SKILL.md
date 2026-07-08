---
name: ticket-fleet-controller
description: >
  DEPRECATED — fleet controller has moved to its own top-level plugin.
  Use `/fleet-controller` instead. This skill remains as a forwarder
  for one release cycle to avoid breaking existing cron jobs and scripts.
allowed-tools: Bash, Read
---

# ticket-fleet-controller — DEPRECATED

**This skill has moved.** Fleet controller is now a standalone top-level plugin at `fleet-controller/`. Use `/fleet-controller` instead.

## Migration

All existing fleet functionality is available under the new plugin:

| Old command | New command |
|-------------|-------------|
| `/ticket-fleet-controller monitor` | `/fleet-controller monitor` |
| `/ticket-fleet-controller status` | `/fleet-controller status` |
| `/ticket-fleet-controller intervene <ID>` | `/fleet-controller intervene <ID>` |
| — | `/fleet-controller dispatch <INIT_ID>` |
| — | `/fleet-controller feedback` |

## Why

Fleet controller sits architecturally above both ticket-planner and ticket-auto as the parent orchestrator. Extracting it to `fleet-controller/` makes this relationship explicit and enables the ticket-planner → ticket-auto handoff contract (dispatch, feedback aggregation, blocked-by resolution).

## When forwarding

If invoked via this deprecated skill name, forward the request to `/fleet-controller`:

- Status: run `source fleet-controller/lib/fleet-monitor.sh` and call functions
- Monitor: run `source fleet-controller/lib/fleet-monitor.sh` and call `fleet_monitor_loop`
- Intervene: run `source fleet-controller/lib/fleet-intervene.sh` and call functions
