# Refactoring Plan: Extract Shared Library Helpers — 2026-06-04

## Completed (7/7)

### 1. ✅ `_iso_now()` — canonical ISO timestamp (heartbeat.sh)
Replaced 86 inline `date -u +%Y-%m-%dT%H:%M:%SZ` invocations across 9 non-test files:
- lib/heartbeat.sh, lib/spawn-helper.sh, lib/fleet-monitor.sh
- lib/fleet-dashboard.sh, lib/fleet-intervene.sh
- skills/ticket-detect-resume/detect-resume.sh
- skills/ticket-flow/flow.sh, skills/ticket-retro/retro.sh
- validate-linear-config.sh, skills/ticket-flow/validate-linear-config.sh

**Reverted** hooks/token-tracker.sh — hooks run standalone, no library access.

### 2. ✅ `_ensure_dir_for()` — mkdir -p guard (heartbeat.sh)
Replaced all `mkdir -p "$(dirname "$file")"` patterns in:
- hb_write(), hb_init(), cl_write(), cl_init(), fl_write(), _log_pipeline()

### 3. ✅ Dashboard wrapper dedup (fleet-dashboard.sh)
- `fleet_render_dashboard()` → thin wrapper calling `fleet_render_dashboard_from_data()`
- `fleet_write_report()` → thin wrapper calling `fleet_write_report_from_data()`
- Diagnostic context section (extract_diagnostics) moved into `_from_data` variant

### 4. ✅ Unified `_plog()` — canonical pipe-delimited log writer (heartbeat.sh)
Signature: `_plog <file> <phase> <step> <status> <msg>`
Harmonized all 4 divergent log-write paths:
- `heartbeat.sh::cl_write()` → delegates to `_plog "$CLAUDE_LOG_FILE" "$@"`
- `fleet-intervene.sh::_log_pipeline()` → delegates to `_plog "$@"`
- `flow.sh::_log()` → splits suffix via `IFS='|' read -r`, calls `_plog`
- `spawn-helper.sh` 3 inline writes → direct `_plog` calls
- `validate-linear-config.sh` (both copies) 2 inline writes each → `_plog`
- `detect-resume.sh` 3 inline writes → `_plog`

### Sourcing guard updates
Changed `declare -f hb_heartbeat` guards to `declare -f _plog` in:
- spawn-helper.sh, fleet-intervene.sh, fleet-monitor.sh, fleet-dashboard.sh
- `fleet-dashboard.sh` added heartbeat.sh sourcing block (didn't have one)

### Test fixes
- `test-spawn-helper.sh`: Added `_plog` mock in `test_heartbeat_not_sourced_when_already_defined`
- `test-spawn-helper.sh`: Added `_plog _iso_now` to unset list in `test_watchdog_emits_heartbeats`
- 52/52 tests pass

### 5. ✅ `_build_error_event()` in retro.sh
Extracted shared jq error event builder from 3 duplicated blocks (retry, api, gate). Each block was ~13 lines of identical jq construction; now each call site is a single `_build_error_event` call. The side-effect code (append to TICKET_ERROR_EVENTS, increment counters) stays at each call site where the triggering condition logic differs.

### 6. ✅ `_severity_info()` — merge _severity_label + _severity_icon (fleet-dashboard.sh)
Replaced two separate functions with a single `_severity_info()` returning `"icon|label"`. Callers use `IFS='|' read -r icon label <<<"$(_severity_info "$sev")"`.
Updated 3 call sites: terminal table rendering, printf row, and markdown alert section.
**Test update**: `test-fleet-detect.sh` merged 3 severity tests into 2 (`test_severity_info_capped_when_auto_restart_off`, `test_severity_info_shows_restart_when_auto_restart_on`).

### 7. ✅ `_source_if_missing()` — sourcing guard helper (heartbeat.sh)
Single function: `_source_if_missing() { declare -f "$1" >/dev/null 2>&1 || source "$2"; }`
Replaced 4 non-heartbeat declare-guard blocks:
- `fleet-dashboard.sh`: `fleet_detect_all` guard → `_source_if_missing fleet_detect_all`
- `fleet-monitor.sh`: `fleet_detect_all`, `fleet_kill_pipeline`, `fleet_render_dashboard_from_data` guards → `_source_if_missing` calls

**Bootstrap constraint**: heartbeat.sh sourcing guards remain inline (4 instances) — `_source_if_missing` is defined in heartbeat.sh, so the heartbeat guard itself cannot use it. Fleet files reordered to source heartbeat.sh first (inline guard), then use `_source_if_missing` for remaining dependencies.

## Files touched
- `lib/heartbeat.sh` — _iso_now, _ensure_dir_for, _plog added; cl_write, hb_write, hb_init, cl_init updated
- `lib/spawn-helper.sh` — inline writes → _plog; guard updated
- `lib/fleet-monitor.sh` — fl_write, _spawn_queue_write inline date → _iso_now; guard updated
- `lib/fleet-dashboard.sh` — wrapper dedup; date → _iso_now; added heartbeat sourcing
- `lib/fleet-intervene.sh` — _log_pipeline delegates; guard updated
- `skills/ticket-detect-resume/detect-resume.sh` — inline writes → _plog
- `skills/ticket-flow/flow.sh` — _log delegates to _plog
- `skills/ticket-retro/retro.sh` — date → _iso_now
- `validate-linear-config.sh` — date → _iso_now, inline writes → _plog
- `skills/ticket-flow/validate-linear-config.sh` — same changes
- `hooks/token-tracker.sh` — date restored to inline (hook isolation)

## Test results (before context clear)
- test-heartbeat: 29/29 ✅
- test-spawn-helper: 52/52 ✅
- test-fleet-detect: 53/53 ✅
- test-fleet-monitor: 9/9 ✅
- test-notes-parse: 5/5 ✅
- test-pipeline-phases: 15/15 ✅
- test-linear-api: 23/23 ✅
- test-fleet-intervene: NOT YET RUN ⚠️
