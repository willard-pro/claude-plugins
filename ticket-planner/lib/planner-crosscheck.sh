#!/usr/bin/env bash
# planner-crosscheck.sh — Crosscheck phase orchestrator (issue #178).
#
# Crosscheck is the phase between Consensus and EpicGen: the last artifact-only
# phase, and the first point where any script compares the artifacts against
# each other and against the live repo rather than validating one file in
# isolation. It is deterministic bash, not an agent — nothing here reasons
# about content, it runs the existing linters and records what they found.
#
# Wires in the check families that exist today:
#   - planner-crosscheck-citations.sh   (#172 — citation + precedent grep)
#   - planner-crosscheck-propagation.sh (#173 — cross-ticket propagation)
#   - planner-crosscheck-bypass.sh      (#174 — bypass sweep + discovery gap)
#   - planner-crosscheck-contracts.sh   (#175 — cross-initiative contract shape)
#
# Adding a check later means adding one more call in planner_crosscheck_run
# and, if it can emit a non-blocking finding, adding its codes to
# PLANNER_CROSSCHECK_WARN_CODES below.
#
# Every finding is written to state.log as its own line, in the format #176
# specifies:
#
#   {ISO8601}|META|crosscheck|fail|{CODE} {message}
#
# `META|<step>|fail` with the code as the first whitespace-delimited token of
# the message is exactly the shape ticket-retro's failure-histogram parser
# already reads (see #177) — no retro-side change needed once it is pointed
# at planner state logs.
#
# The phase's own progress marker is a normal Crosscheck|check|{start,done,
# fail} triplet, so planner_position_derive, planner_phase_fail_count and the
# rest of the state machine handle it exactly like every other phase — no
# special-casing needed there. What IS special-cased is the dispatch loop in
# SKILL.md: Crosscheck has no agent prompt (see planner_prompt_for_phase),
# so the loop calls planner_crosscheck_run directly instead of spawning an
# Agent, and treats a nonzero return as an immediate stop (not a retry) —
# retrying a deterministic check against unchanged artifacts cannot produce a
# different answer; only editing the artifacts and resuming can.
#
# Sourceable library — no set -euo pipefail.

_PLANNER_CROSSCHECK_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

_planner_crosscheck_source_if_missing() {
  local name="$1" path="$2"
  if ! declare -f "$name" >/dev/null 2>&1; then
    [ -f "$path" ] && source "$path"
  fi
}

_planner_crosscheck_source_if_missing "planner_crosscheck_citations" \
  "${_PLANNER_CROSSCHECK_LIB_DIR}/planner-crosscheck-citations.sh"
_planner_crosscheck_source_if_missing "planner_crosscheck_propagation" \
  "${_PLANNER_CROSSCHECK_LIB_DIR}/planner-crosscheck-propagation.sh"
_planner_crosscheck_source_if_missing "planner_crosscheck_bypass" \
  "${_PLANNER_CROSSCHECK_LIB_DIR}/planner-crosscheck-bypass.sh"
_planner_crosscheck_source_if_missing "planner_crosscheck_contracts" \
  "${_PLANNER_CROSSCHECK_LIB_DIR}/planner-crosscheck-contracts.sh"
_planner_crosscheck_source_if_missing "planner_state_write" \
  "${_PLANNER_CROSSCHECK_LIB_DIR}/planner-state.sh"

# Codes that must NOT halt the run — logged as META|crosscheck|warn|info
# instead of META|crosscheck|fail|<code> (#176 AC4). Every code the
# citation/propagation families emit (CITATION_UNRESOLVED,
# CITATION_LINE_OUT_OF_RANGE, CITATION_SYMBOL_MISMATCH, PRECEDENT_NOT_FOUND,
# RESOLUTION_NOT_PROPAGATED, FORWARD_REF_UNFULFILLED, CARVE_SCOPE_LOST),
# #174's BYPASS_PATH_UNADDRESSED, and #175's CONTRACT_MISMATCH /
# CONTRACT_CONSUMERS_UNNOTIFIED block EpicGen per #176's table.
# DISCOVERY_GAP_UNRESOLVED and CONTRACT_UNDEFINED are warn-level: a declared
# exploration gap or an ambiguous upstream shape is a prompt for human
# judgment, not by itself proof of a defect.
PLANNER_CROSSCHECK_WARN_CODES="DISCOVERY_GAP_UNRESOLVED CONTRACT_UNDEFINED"

# Is <code> a warn-level code?
# Usage: _planner_crosscheck_is_warn_code <code>
_planner_crosscheck_is_warn_code() {
  case " ${PLANNER_CROSSCHECK_WARN_CODES} " in
  *" $1 "*) return 0 ;;
  *) return 1 ;;
  esac
}

# Parse one finding line from a check family's stdout and write it to
# state.log in #176's format. The check families print:
#   planner-crosscheck-<family>: <CODE> <rest of message...>
# but also print non-finding summary lines in the same "prefix: text" shape
# (e.g. "planner-crosscheck-citations: 3 passed, 2 failed out of 5 files") —
# a real code is always upper-snake-case, which no summary line's first word
# is, so that's the discriminator.
# Usage: _planner_crosscheck_emit_finding <initiative_id> <finding_line>
# Returns: 0 if the finding was blocking, 1 if warn, 2 if not a finding line.
_planner_crosscheck_emit_finding() {
  local initiative_id="$1" finding_line="$2"
  local body code message

  case "$finding_line" in
  *": "*) body="${finding_line#*: }" ;;
  *) return 2 ;;
  esac

  code=$(echo "$body" | awk '{print $1}')
  [[ "$code" =~ ^[A-Z][A-Z0-9_]*$ ]] || return 2
  message="${body#"$code" }"

  if _planner_crosscheck_is_warn_code "$code"; then
    planner_state_write "$initiative_id" "META" "crosscheck" "warn" "info ${code} ${message}"
    return 1
  fi

  planner_state_write "$initiative_id" "META" "crosscheck" "fail" "${code} ${message}"
  return 0
}

# Run one check family, emitting a state-log event for every finding line it
# printed to stdout.
# Usage: _planner_crosscheck_run_family <initiative_id> <check_fn> [<check_fn_args...>]
# Output (stdout): "<blocking_count> <warn_count>"
_planner_crosscheck_run_family() {
  local initiative_id="$1"
  shift
  local blocking=0 warn=0
  local line rc

  while IFS= read -r line; do
    [ -z "$line" ] && continue
    _planner_crosscheck_emit_finding "$initiative_id" "$line"
    rc=$?
    case "$rc" in
    0) blocking=$((blocking + 1)) ;;
    1) warn=$((warn + 1)) ;;
    esac
  done < <("$@" 2>/dev/null)

  echo "$blocking $warn"
}

# Run the full Crosscheck phase for an initiative: both wired check families,
# emitting findings and the phase's own progress markers.
#
# Usage: planner_crosscheck_run <initiative_id>
# Returns: 0 if clean (or warn-only), 1 if any blocking finding was reported.
planner_crosscheck_run() {
  local initiative_id="$1"
  local total_blocking=0 total_warn=0
  local b w

  planner_state_write "$initiative_id" "Crosscheck" "check" "start" "running citation + propagation + bypass + contracts checks"

  read -r b w < <(_planner_crosscheck_run_family "$initiative_id" planner_crosscheck_citations "$initiative_id")
  total_blocking=$((total_blocking + b))
  total_warn=$((total_warn + w))

  read -r b w < <(_planner_crosscheck_run_family "$initiative_id" planner_crosscheck_propagation "$initiative_id")
  total_blocking=$((total_blocking + b))
  total_warn=$((total_warn + w))

  read -r b w < <(_planner_crosscheck_run_family "$initiative_id" planner_crosscheck_bypass "$initiative_id")
  total_blocking=$((total_blocking + b))
  total_warn=$((total_warn + w))

  read -r b w < <(_planner_crosscheck_run_family "$initiative_id" planner_crosscheck_contracts "$initiative_id")
  total_blocking=$((total_blocking + b))
  total_warn=$((total_warn + w))

  if [ "$total_blocking" -gt 0 ]; then
    planner_state_write "$initiative_id" "Crosscheck" "check" "fail" \
      "${total_blocking} blocking finding(s), ${total_warn} warn — see META|crosscheck entries"
    echo "planner-crosscheck: ${total_blocking} blocking finding(s), ${total_warn} warn" >&2
    return 1
  fi

  planner_state_write "$initiative_id" "Crosscheck" "check" "done" \
    "clean (${total_warn} warn)"
  echo "planner-crosscheck: clean (${total_warn} warn)"
  return 0
}

# Summarize recorded Crosscheck findings for status reporting (#176 AC5).
# Scoped to the most recent Crosscheck attempt only (everything at or after
# the last "Crosscheck|check|start" marker) — resume re-runs the phase after
# the operator edits artifacts, and a fixed finding from an earlier attempt
# must not keep reporting as outstanding forever just because state.log is
# append-only. Reads directly from state.log; does not re-run the checks.
#
# Usage: planner_crosscheck_findings_summary <initiative_id>
# Output (stdout): one "<count> <blocking|warn> <CODE>" line per distinct
# code, sorted by count descending, followed by a "TOTAL: <n> blocking, <n>
# warn" line. No output at all if Crosscheck has not run yet, or its most
# recent run recorded no findings.
planner_crosscheck_findings_summary() {
  local initiative_id="$1"
  local log
  log=$(planner_state_log "$initiative_id")
  [ -f "$log" ] || return 0

  local start_line
  start_line=$(grep -n '|Crosscheck|check|start|' "$log" | tail -1 | cut -d: -f1)
  [ -z "$start_line" ] && return 0

  local blocking_total=0 warn_total=0
  declare -A _cc_counts=()
  declare -A _cc_kind=()
  local line phase step status msg code

  while IFS= read -r line; do
    [ -z "$line" ] && continue
    IFS='|' read -r _ts phase step status msg <<<"$line"
    [ "$phase" = "META" ] || continue
    [ "$step" = "crosscheck" ] || continue

    case "$status" in
    fail)
      code=$(echo "$msg" | awk '{print $1}')
      [ -z "$code" ] && continue
      _cc_counts["$code"]=$((${_cc_counts["$code"]:-0} + 1))
      _cc_kind["$code"]="blocking"
      blocking_total=$((blocking_total + 1))
      ;;
    warn)
      # Warn findings are written as "info <CODE> <message>" — see
      # _planner_crosscheck_emit_finding.
      code=$(echo "$msg" | awk '{print $2}')
      [ -z "$code" ] && continue
      _cc_counts["$code"]=$((${_cc_counts["$code"]:-0} + 1))
      _cc_kind["$code"]="warn"
      warn_total=$((warn_total + 1))
      ;;
    esac
  done < <(tail -n "+$((start_line + 1))" "$log")

  if [ "$blocking_total" -eq 0 ] && [ "$warn_total" -eq 0 ]; then
    return 0
  fi

  for code in "${!_cc_counts[@]}"; do
    echo "${_cc_counts[$code]} ${_cc_kind[$code]} ${code}"
  done | sort -rn

  echo "TOTAL: ${blocking_total} blocking, ${warn_total} warn"
}
