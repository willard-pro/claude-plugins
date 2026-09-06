#!/usr/bin/env bash
# Fleet controller configuration — env-var defaults with `${VAR:-default}` pattern.
# Sourceable library — no set flags. Intended to be sourced by fleet-*.sh scripts.

# ── Durable state directory ─────────────────────────────────────────────────────
# All fleet-controller persistent state (spawn queue, stop files, run registry,
# fence markers) lives under this directory rather than /tmp so a host reboot
# does not silently drop queued dispatches or in-flight decisions.
# Default: {workspace} as resolved by each script's caller.
FLEET_STATE_DIR="${FLEET_STATE_DIR:-}"

# ── Kill escalation thresholds ──────────────────────────────────────────────────
# How long to wait for cooperative shutdown (after touching stop-files) before
# sending SIGTERM, and again after SIGTERM before sending SIGKILL.
FLEET_KILL_GRACE_SECS="${FLEET_KILL_GRACE_SECS:-10}"

# When true, fleet_kill_pipeline verifies PID termination before finalizing.
# Set to false to fall back to stop-file-only behaviour (pre-verified-escalation).
FLEET_KILL_VERIFY="${FLEET_KILL_VERIFY:-true}"

# ── Generation fencing ──────────────────────────────────────────────────────────
# When true, flow.sh refuses Linear mutations from a superseded (fenced) generation.
# Set to false for emergency rollback — unfenced tickets are always unrestricted.
FLEET_FENCE_ENFORCE="${FLEET_FENCE_ENFORCE:-true}"

# ── Spawn queue lock timeout ────────────────────────────────────────────────────
# Seconds to wait for the spawn queue flock per attempt.
FLEET_QUEUE_LOCK_TIMEOUT="${FLEET_QUEUE_LOCK_TIMEOUT:-5}"

# Maximum retry attempts for contended queue appends. After exhausting retries,
# the entry is dead-lettered rather than silently dropped.
FLEET_QUEUE_MAX_RETRIES="${FLEET_QUEUE_MAX_RETRIES:-3}"

# Base backoff seconds between queue append retries. Doubles on each attempt.
FLEET_QUEUE_RETRY_BACKOFF_SECS="${FLEET_QUEUE_RETRY_BACKOFF_SECS:-2}"

# ── Epic branch lifecycle ────────────────────────────────────────────────────────
# When true, sync base changes into the epic branch on each dispatch cycle.
# Sync is the safety mechanism that prevents long-lived branch rot — disabling it
# means choosing to accept accumulating merge conflicts.
FLEET_EPIC_BRANCH_SYNC="${FLEET_EPIC_BRANCH_SYNC:-true}"

# When true, automatically open integration PRs from epic branches when all
# children are Done. Off by default — detection reports, actuation is opt-in.
# The integration PR is NEVER auto-merged regardless of this setting.
FLEET_EPIC_AUTO_PR="${FLEET_EPIC_AUTO_PR:-false}"

# ── OTel exporter ───────────────────────────────────────────────────────────────
# fleetd supervises an OpenTelemetry exporter (fleetd/otel.py) that derives
# GenAI-convention spans by tailing the pipeline and agent-activity logs and
# ships them to an OTLP collector. Off by default: a telemetry exporter that
# started unasked would have every install opening connections to a collector
# nobody configured.
#
# The exporter is strictly downstream. Nothing in the pipeline reads its output
# or waits on it — stopping it, or an unreachable collector, costs traces and
# nothing else. It is also the only component that needs the opentelemetry
# Python packages; without them it starts, says so once, and emits nothing.
FLEET_OTEL_ENABLE="${FLEET_OTEL_ENABLE:-false}"

# OTLP collector base URL. `/v1/traces` is appended for the HTTP exporter.
FLEET_OTEL_ENDPOINT="${FLEET_OTEL_ENDPOINT:-http://localhost:4318}"

# service.name resource attribute on every emitted span.
FLEET_OTEL_SERVICE_NAME="${FLEET_OTEL_SERVICE_NAME:-ticket-auto-pipeline}"

# Seconds between tail passes over the log directory.
FLEET_OTEL_POLL_SECS="${FLEET_OTEL_POLL_SECS:-5}"

# How long a completed span waits before emission so late enrichment can still
# attach to it. `META|tokens|info|` is written by the SubagentStop hook a moment
# *after* the router writes the phase terminal, so a span emitted the instant
# its bracket closes always loses its token counts. A ticket reaching its
# outcome flushes its spans immediately regardless — nothing more can arrive.
FLEET_OTEL_SPAN_GRACE_SECS="${FLEET_OTEL_SPAN_GRACE_SECS:-30}"

# Cap on per-span tool-call events derived from the agent-activity log. The
# count is always recorded as an attribute; only the individual events are
# capped, with pipeline.tool_calls_truncated set when the cap bites.
FLEET_OTEL_MAX_TOOL_EVENTS="${FLEET_OTEL_MAX_TOOL_EVENTS:-100}"

# ── Agent Observer ───────────────────────────────────────────────────────────────
# When false (the default), fleetd is byte-identical to today: phase-level workers
# still spawn with --output-format json, and no fleetd/observer.py sidecar runs.
# When true, phase-level workers (Supervisor.spawn_phase only — never ticket-level
# /ticket-auto workers) spawn with --output-format stream-json --verbose instead,
# and fleetd supervises an observer.py sidecar that tails the resulting NDJSON,
# producing a normalized event record and deterministic findings. The observer is
# non-authoritative under any configuration: it can never gate, fail, or delay a
# ticket, and a crashed or misbehaving observer costs only its own findings.
FLEET_OBSERVER_ENABLE="${FLEET_OBSERVER_ENABLE:-false}"

# Seconds between the observer's poll passes over each phase's NDJSON file.
FLEET_OBSERVER_POLL_SECS="${FLEET_OBSERVER_POLL_SECS:-5}"

# Seconds a logical observer keeps draining after it sees the terminal `result`
# frame (or the worker's exit-record file) before releasing — late-arriving lines
# (a trailing hook_response, design.md E5) still get consumed.
FLEET_OBSERVER_GRACE_SECS="${FLEET_OBSERVER_GRACE_SECS:-30}"

# Byte cap on any single field written into events.jsonl/findings.jsonl. Stream
# volume on a real phase is unmeasured beyond a toy run (design.md Risk) — a Read
# result embedding a whole file could be orders of magnitude larger than probed.
FLEET_OBSERVER_MAX_FIELD="${FLEET_OBSERVER_MAX_FIELD:-512}"

# Generations of the phase-slugged {tid}-{phase}-gen{N}.json/.ndjson/.stderr
# worker-stdio files kept per ticket, swept the same way FLEET_WORKER_LOG_RETENTION
# already sweeps the ticket-level files — a separate knob because a .ndjson
# capture can be far larger than the .json it replaces (design.md D8), so an
# operator may want it aged out faster. {tid}-{phase}-events.jsonl and
# -findings.jsonl are NOT generation-scoped (one file accumulates across a
# phase's generations) and are unaffected by this var.
FLEET_OBSERVER_LOG_RETENTION="${FLEET_OBSERVER_LOG_RETENTION:-3}"

# Cumulative assistant-frame `usage`-derived cost (USD) within one phase
# generation above which the RUNAWAY_COST finding fires. WARN-only — never
# gates a ticket, same as every other observer finding.
FLEET_OBSERVER_COST_WARN_USD="${FLEET_OBSERVER_COST_WARN_USD:-2.00}"

# Seconds between a tool_call and its matching tool_result above which the
# LONG_TOOL_CALL finding fires. A single slow tool (a long test run, a large
# clone) is normal; this exists to catch a tool that never seems to return
# relative to the phase's other calls, not to police individual tool latency.
FLEET_OBSERVER_LONG_TOOL_SECS="${FLEET_OBSERVER_LONG_TOOL_SECS:-120}"

# ── Dispatch ─────────────────────────────────────────────────────────────────────
# When false (the default), fleetd sits idle — detection runs and health/status
# are served, but no epic is auto-enqueued; dispatch happens only when explicitly
# triggered (the /fleet-controller dispatch skill or the fleetd HTTP POST /dispatch
# endpoint). When true, the global sweep behaviour is unchanged: every
# state:execution-labelled epic found in the workspace is dispatched automatically.
FLEET_AUTO_DISPATCH="${FLEET_AUTO_DISPATCH:-false}"

# Seconds to wait for the epic-scoped dispatch flock per attempt. Serializes
# fleet_dispatch_initiative / fleet_stop_initiative per epic across processes
# (skill session vs. fleetd HTTP handler vs. auto-sweep).
FLEET_DISPATCH_LOCK_TIMEOUT="${FLEET_DISPATCH_LOCK_TIMEOUT:-5}"

# ── Instance namespace ──────────────────────────────────────────────────────────
# Namespace for spawn queue, stop files, run registry, and fence markers.
# Prevents collisions between multiple fleet controller instances on the same host.
FLEET_INSTANCE_ID="${FLEET_INSTANCE_ID:-default}"

# ── State directory resolver ────────────────────────────────────────────────────
# Resolves the durable-state directory from FLEET_STATE_DIR env var, falling back
# to the provided workspace path. Callers pass their workspace as $1.
# Usage: _fleet_state_dir <workspace>
_fleet_state_dir() {
  local workspace="${1:-./logs}"
  if [ -n "${FLEET_STATE_DIR:-}" ]; then
    echo "$FLEET_STATE_DIR"
  else
    echo "$workspace"
  fi
}

# ── State path constructors ─────────────────────────────────────────────────────
# Every consumer that reads or writes fleet state (stop-files, queue, registry,
# fence markers) MUST derive paths through these functions. Independent path
# derivation duplicates the resolution rule — that is how the same bug recurs.
#
# All constructors accept an optional workspace argument forwarded to
# _fleet_state_dir. The caller's responsibility is to pass a consistent workspace;
# the resolver's responsibility is to derive a consistent directory from it.

# Stop-file paths — written by fleet-intervene.sh (kill), watched by spawn-helper.sh (worker).
# Usage: _fleet_stop_file <tid> <type> [workspace]
#   type: pinger | watchdog
_fleet_stop_file() {
  local tid="$1" type="$2" workspace="${3:-./logs}"
  echo "$(_fleet_state_dir "$workspace")/ticket-auto-${tid}-${type}-stop"
}

# Spawn queue path — written by fleet-dispatch.sh, consumed by fleet-monitor.sh.
# Usage: _fleet_queue_file [workspace]
_fleet_queue_file() {
  local workspace="${1:-./logs}"
  local instance_id="${FLEET_INSTANCE_ID:-default}"
  echo "$(_fleet_state_dir "$workspace")/fleet-${instance_id}-spawn-queue.jsonl"
}

# Queue lock file path — serializes queue read+write across dispatch and monitor.
# Usage: _fleet_queue_lock [workspace]
_fleet_queue_lock() {
  local workspace="${1:-./logs}"
  echo "$(_fleet_queue_file "$workspace").lock"
}

# Run registry path — written at spawn (monitor/daemon), read at kill/restart.
# Usage: _fleet_run_file <tid> [workspace]
_fleet_run_file() {
  local tid="$1" workspace="${2:-./logs}"
  echo "$(_fleet_state_dir "$workspace")/${tid}-run.json"
}

# Epic stop-file path — gates every dispatch trigger path for that epic until
# an explicit resume clears it (fleet-epic-stop). Distinct from the worker
# stop-file constructor above (that one is for pinger/watchdog stop files).
# Usage: _fleet_epic_stop_file <workspace> <epic_id>
_fleet_epic_stop_file() {
  local workspace="$1" epic_id="$2"
  echo "$(_fleet_state_dir "$workspace")/stop-${epic_id}.json"
}

# Fence marker path — written at kill, read by flow.sh pre-mutation guard.
# Usage: _fleet_fence_file <tid> [workspace]
_fleet_fence_file() {
  local tid="$1" workspace="${2:-./logs}"
  echo "$(_fleet_state_dir "$workspace")/${tid}-fence"
}
