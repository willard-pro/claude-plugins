#!/usr/bin/env bash
# run-identity.sh — single writer for META|run-id, META|version and
# META|ticket-meta pipeline log lines (Branch A of the Commercial Evidence
# MVP, next.md Step 1 / design.md).
#
# Both entry points that establish a ticket's operating environment — the
# fleetd-driven preamble (lib/ticket-preamble.sh) and the manual router
# (skills/ticket-auto/SKILL.md) — call into this file rather than each
# maintaining their own run-identity logic, so there is exactly one writer of
# these three log-line grammars, following the same one-writer-per-grammar
# rule as spawn-helper.sh's phase_bracket_open/phase_terminal_write.
#
# An open run exists iff the last META|run-id line in the log is later (by
# line position — the log is append-only) than the last META|outcome line.
# This is a log-based guard, not an env-based one, because ticket-preamble.sh
# is re-invoked once per phase under fleetd and env.sh is rewritten on every
# entry — an env var cannot distinguish "still the same run" from "new phase,
# new process".
#
# -u (nounset) intentionally omitted, matching ticket-preamble.sh: Claude Code
# shell snapshots inject ZSH_VERSION references that trip it.
set -eo pipefail

_RI_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_RI_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$_RI_LIB_DIR/..}"

# heartbeat.sh provides _plog, _iso_now. Guarded so a test harness can
# pre-load mocks (same pattern as ticket-preamble.sh).
if ! declare -f _plog >/dev/null 2>&1; then
  [ -f "$_RI_LIB_DIR/heartbeat.sh" ] && source "$_RI_LIB_DIR/heartbeat.sh"
fi

# skill-version.sh provides skill_fingerprints_all — the per-skill prompt
# fingerprints written by hooks/skill-fingerprint.sh at session start. Same
# declare -f guard as heartbeat.sh above. Both of its functions are pure,
# fail-open reads, so a missing or malformed artifact costs one JSON field
# rather than the run's identity stamp.
if ! declare -f skill_fingerprints_all >/dev/null 2>&1; then
  [ -f "$_RI_LIB_DIR/skill-version.sh" ] && source "$_RI_LIB_DIR/skill-version.sh"
fi

# ── Open-run guard ────────────────────────────────────────────────────────────

# run_identity_current LOG_FILE
# Prints the open run's run_id on stdout, or nothing if no run is open.
run_identity_current() {
  local log_file="$1"
  [ -f "$log_file" ] || return 0

  local run_line
  run_line=$(grep -n '|META|run-id|info|' "$log_file" 2>/dev/null | tail -1 | cut -d: -f1) || true
  [ -n "$run_line" ] || return 0

  local outcome_line
  outcome_line=$(grep -n '|META|outcome|' "$log_file" 2>/dev/null | tail -1 | cut -d: -f1) || true

  # An outcome at or after the last run-id line closes that run.
  if [ -n "$outcome_line" ] && [ "$outcome_line" -ge "$run_line" ]; then
    return 0
  fi

  grep '|META|run-id|info|' "$log_file" 2>/dev/null | tail -1 |
    awk -F'|' '{for(i=5;i<=NF;i++) printf "%s%s", $i, (i==NF?"":"|")}' |
    jq -r '.run_id // empty' 2>/dev/null
}

# ── Version resolution ────────────────────────────────────────────────────────
# Each source degrades independently to empty (→ null in the emitted JSON)
# rather than failing the whole META|version line — matching the existing
# META|model precedent (model-identity-recording spec) of treating
# unknown/null as first-class, not an error.

_run_identity_ticket_auto_version() {
  local plugin_json="$_RI_PLUGIN_ROOT/.claude-plugin/plugin.json"
  [ -f "$plugin_json" ] || return 0
  jq -r '.version // empty' "$plugin_json" 2>/dev/null || true
}

_run_identity_cc_version() {
  if [ -n "${CLAUDE_CODE_VERSION:-}" ]; then
    printf '%s' "$CLAUDE_CODE_VERSION"
    return 0
  fi
  timeout 5 claude --version 2>/dev/null | head -1
  return 0
}

# ── run_identity_stamp ────────────────────────────────────────────────────────

# run_identity_stamp TID LOG_FILE [--new]
# Appends META|run-id and META|version, unless an open run already exists and
# --new was not passed (a no-op, not an error — the second and later preamble
# call within one open run is expected to skip).
run_identity_stamp() {
  local tid="$1" log_file="$2" force_new="false"
  [ "${3:-}" = "--new" ] && force_new="true"

  [ -n "$tid" ] && [ -n "$log_file" ] || {
    echo "run_identity_stamp: TID and LOG_FILE required" >&2
    return 1
  }

  if [ "$force_new" != "true" ]; then
    local _open
    _open="$(run_identity_current "$log_file")"
    [ -z "$_open" ] || return 0
  fi

  local trigger="manual"
  if [ -n "${FLEET_WORKER_PID:-}" ] || [ "${TICKET_RUN_TRIGGER:-}" = "fleetd" ]; then
    trigger="fleetd"
  fi

  local run_id="${tid}-$(_iso_now)-$$"

  local run_id_json
  if [ -n "${FLEET_GENERATION:-}" ]; then
    run_id_json=$(jq -nc --arg run_id "$run_id" --argjson gen "${FLEET_GENERATION}" \
      --arg trigger "$trigger" --argjson pid "$$" \
      '{run_id: $run_id, gen: $gen, trigger: $trigger, pid: $pid}' 2>/dev/null) || return 0
  else
    run_id_json=$(jq -nc --arg run_id "$run_id" \
      --arg trigger "$trigger" --argjson pid "$$" \
      '{run_id: $run_id, gen: null, trigger: $trigger, pid: $pid}' 2>/dev/null) || return 0
  fi
  _plog "$log_file" "META" "run-id" "info" "$run_id_json"

  local _ticket_auto _cc
  _ticket_auto="$(_run_identity_ticket_auto_version)" || true
  _cc="$(_run_identity_cc_version)" || true

  # The prompt fingerprints ride on this existing line rather than a line of
  # their own: the fingerprint set is session-scoped, so a per-phase repeat
  # would carry no information a per-run stamp does not. run-summary.sh already
  # copies this whole object into the runs.jsonl `run` record, so the field
  # reaches runs.jsonl with no change there.
  #
  # Both values are validated before they reach --argjson: invalid JSON there
  # would fail the whole jq and cost the line itself, which is exactly the
  # degradation this field is not allowed to cause.
  local _skills="{}" _skills_unresolved=0
  if declare -f skill_fingerprints_all >/dev/null 2>&1; then
    _skills="$(skill_fingerprints_all 2>/dev/null)" || _skills="{}"
  fi
  [ -n "$_skills" ] && echo "$_skills" | jq -e 'type == "object"' >/dev/null 2>&1 || _skills="{}"

  _skills_unresolved=$(echo "$_skills" |
    jq '[to_entries[] | select(.value.sha256? == "unresolved")] | length' 2>/dev/null) || _skills_unresolved=0
  case "$_skills_unresolved" in
  '' | *[!0-9]*) _skills_unresolved=0 ;;
  esac

  local version_json
  version_json=$(jq -nc \
    --arg ticket_auto "${_ticket_auto:-}" \
    --arg fleet "${FLEET_VERSION:-}" \
    --arg cc "${_cc:-}" \
    --arg model_default "${ANTHROPIC_MODEL:-}" \
    --argjson skills "$_skills" \
    --argjson skills_unresolved "$_skills_unresolved" \
    '{
      ticket_auto: (if $ticket_auto == "" then null else $ticket_auto end),
      fleet: (if $fleet == "" then null else $fleet end),
      cc: (if $cc == "" then null else $cc end),
      model_default: (if $model_default == "" then null else $model_default end),
      skills: $skills,
      skills_unresolved: $skills_unresolved
    }' 2>/dev/null) || return 0
  _plog "$log_file" "META" "version" "info" "$version_json"

  return 0
}

# ── run_identity_ticket_meta ──────────────────────────────────────────────────

# run_identity_ticket_meta TID LOG_FILE
# Fetches ticket-level metadata via get_issue and writes it once per ticket
# (guarded by a grep for its own prior output — ticket-level fields don't
# change run to run). Requires LINEAR_API_KEY; no-ops silently when unset.
# Fails soft throughout — a Linear error here must never abort the caller.
run_identity_ticket_meta() {
  local tid="$1" log_file="$2"
  [ -n "$tid" ] && [ -n "$log_file" ] || return 0
  [ -n "${LINEAR_API_KEY:-}" ] || return 0
  grep -q '|META|ticket-meta|' "$log_file" 2>/dev/null && return 0

  # get_issue is a shell function, not a binary `timeout` can exec directly,
  # so the timeout wraps a child bash that sources linear-api.sh fresh —
  # by path, the same resolution ticket-preamble.sh's preflight uses, so a
  # sandboxed test replacing lib/linear-api.sh with a stub is picked up here
  # exactly as it is by every other caller of it.
  local _linear_lib="$_RI_LIB_DIR/linear-api.sh"
  [ -f "$_linear_lib" ] || return 0

  local issue
  issue=$(timeout 20 bash -c "source '$_linear_lib'; get_issue '$tid'" 2>/dev/null) || return 0
  [ -n "$issue" ] || return 0
  echo "$issue" | jq -e . >/dev/null 2>&1 || return 0

  if ! declare -f resolve_template >/dev/null 2>&1; then
    [ -f "$_RI_LIB_DIR/template-select.sh" ] && source "$_RI_LIB_DIR/template-select.sh"
  fi

  local _type="" _labels _l
  _labels=$(echo "$issue" | jq -r '.labels.nodes[]?.name // empty' 2>/dev/null) || true
  while IFS= read -r _l; do
    [ -z "$_l" ] && continue
    if declare -f resolve_template >/dev/null 2>&1 && resolve_template "$_l" >/dev/null 2>&1; then
      _type="$_l"
      break
    fi
  done <<<"$_labels"

  local planned="false"
  echo "$_labels" | grep -qx 'planned' && planned="true"

  local meta_json
  meta_json=$(echo "$issue" | jq -c \
    --arg type "$_type" --argjson planned "$planned" \
    '{
      createdAt: (.createdAt // null),
      startedAt: (.startedAt // null),
      estimate: (.estimate // null),
      priority: (.priority // null),
      type: (if $type == "" then null else $type end),
      planned: $planned,
      labels: [.labels.nodes[]?.name // empty]
    }' 2>/dev/null) || return 0

  _plog "$log_file" "META" "ticket-meta" "info" "$meta_json"
  return 0
}

# ── CLI entrypoint ────────────────────────────────────────────────────────────

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  case "${1:-}" in
  stamp)
    shift
    run_identity_stamp "$@"
    ;;
  *)
    echo "Usage: run-identity.sh stamp TID LOG_FILE [--new]" >&2
    exit 1
    ;;
  esac
fi
