#!/usr/bin/env bash
# verdict-recompute.sh — independently recomputes a phase's verdict from
# observable state and compares it against the agent's own claim.
#
# `phase-result-parse.sh` gives a consumer the agent's claim. This script gives
# it the other half: bash derives the verdict itself, from evidence a claim
# cannot fabricate, and the two are compared. The delta — never used to change
# routing in this increment — is the RLVR reward signal `rlvr-verdict-recompute`
# exists to produce.
#
# VERIFY only. `{ticket-dir}/verify-session.md` must exist and postdate the
# phase's own `|VERIFY|verify|waiting|` bracket-open line; verified criteria
# counts come from counting `- [x]` against `- [ ]` in its `## Step trace`
# section, via the section-scoped counter already in
# return-completeness-check.sh — never a second checkbox parser.
#
# Exit-code idiom follows return-completeness-check.sh, not phase-result-parse.sh:
#   0 — recomputation ran and the claim is aligned with the verified result
#   1 — recomputation ran and the claim is NOT aligned (optimistic, pessimistic,
#       or the claim itself was UNKNOWN). A claim-delta entry is still emitted.
#       This is a normal outcome, not an error.
#   2 — the script could not run (usage, unreadable file, jq missing). Nothing
#       logged.
#
# Observe-only: nothing routes on this channel's exit code or its output.
#
# Usable as a sourceable lib (`verdict_recompute`) and as a standalone CLI.
#
# -u (nounset) intentionally omitted: Claude Code shell snapshots inject
# ZSH_VERSION references that trigger false-positive "unbound variable"
# errors in this bash version when nounset is active. Repo convention.
set -eo pipefail

_VR_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_VR_LIB_DIR="${CLAUDE_SKILLS_LIB:-$HOME/.claude/skills/lib}"

# phase-result-parse.sh supplies the claim (parse_phase_result). Sourcing it
# rather than re-reading the log's META|phase-result JSON reuses the exact
# extraction/validation the router already ran, and needs no second `|`-aware
# log parser. Sourcing is side-effect-free: its own CLI dispatch is guarded by
# `[ "${BASH_SOURCE[0]}" = "${0}" ]`, which is false while sourced.
if [ -f "$_VR_LIB_DIR/phase-result-parse.sh" ]; then
  source "$_VR_LIB_DIR/phase-result-parse.sh"
elif [ -f "$_VR_SCRIPT_DIR/phase-result-parse.sh" ]; then
  source "$_VR_SCRIPT_DIR/phase-result-parse.sh"
else
  echo "[verdict-recompute] ERROR: phase-result-parse.sh not found" >&2
  exit 2
fi

# return-completeness-check.sh supplies _count_checklist_boxes — the
# section-scoped `- [x]`/`- [ ]` counter. Sourcing it defines the function
# without running its CLI dispatch block for the same reason as above.
if [ -f "$_VR_LIB_DIR/return-completeness-check.sh" ]; then
  source "$_VR_LIB_DIR/return-completeness-check.sh"
elif [ -f "$_VR_SCRIPT_DIR/return-completeness-check.sh" ]; then
  source "$_VR_SCRIPT_DIR/return-completeness-check.sh"
else
  echo "[verdict-recompute] ERROR: return-completeness-check.sh not found" >&2
  exit 2
fi

_VR_STEP_HEADING="## Step trace"
_VR_BRACKET_PATTERN='|VERIFY|verify|waiting|'

_vr_usage() {
  cat >&2 <<'EOF'
Usage: verdict-recompute.sh --phase VERIFY --return-file <path> --ticket-dir <path>
                            [--log-file <path>]

  --phase <PHASE>        Phase to recompute. Only VERIFY is implemented —
                         IMPLEMENT and PR-REVIEW rules are deferred. Required.
  --return-file <path>   The phase agent's captured return text, passed through
                         to phase-result-parse.sh unchanged. Required.
  --ticket-dir <path>    Ticket workspace. Resolves a relative --return-file
                         and locates verify-session.md. Required.
  --log-file <path>      Pipeline log to read the phase-start bracket from and
                         append META|claim-delta to. Falls back to the
                         LOG_FILE env var. Omit to skip both.

Exit: 0 aligned, 1 mismatch (optimistic/pessimistic/unknown claim), 2 error.
EOF
}

# Last `|VERIFY|verify|waiting|` line's ISO timestamp, or empty if the log is
# absent or carries no such line. A retried VERIFY re-opens its bracket, so the
# LAST such line is the current attempt's phase-start, not the first ever.
_vr_phase_start_iso() {
  local log_file="$1"
  [ -n "$log_file" ] && [ -f "$log_file" ] || return 1
  local line
  line=$(command grep -F "$_VR_BRACKET_PATTERN" "$log_file" 2>/dev/null | tail -1) || true
  [ -z "$line" ] && return 1
  printf '%s' "${line%%|*}"
}

# verdict_recompute --phase <P> --return-file <f> --ticket-dir <d> [--log-file <l>]
verdict_recompute() {
  local phase="" return_file="" ticket_dir="" log_file="${LOG_FILE:-}"

  while [ $# -gt 0 ]; do
    case "$1" in
    --phase)
      phase="${2:-}"
      shift 2
      ;;
    --return-file)
      return_file="${2:-}"
      shift 2
      ;;
    --ticket-dir)
      ticket_dir="${2:-}"
      shift 2
      ;;
    --log-file)
      log_file="${2:-}"
      shift 2
      ;;
    -h | --help)
      _vr_usage
      return 2
      ;;
    *)
      echo "[verdict-recompute] ERROR: unknown argument '$1'" >&2
      _vr_usage
      return 2
      ;;
    esac
  done

  if [ -z "$phase" ] || [ -z "$return_file" ] || [ -z "$ticket_dir" ]; then
    echo "[verdict-recompute] ERROR: --phase, --return-file and --ticket-dir are required" >&2
    _vr_usage
    return 2
  fi

  if [ "$phase" != "VERIFY" ]; then
    echo "[verdict-recompute] ERROR: recompute for phase '$phase' is not implemented (VERIFY only)" >&2
    return 2
  fi

  if ! command -v jq >/dev/null 2>&1; then
    echo "[verdict-recompute] ERROR: jq not available" >&2
    return 2
  fi

  if [ ! -d "$ticket_dir" ]; then
    echo "[verdict-recompute] ERROR: ticket dir not found: $ticket_dir" >&2
    return 2
  fi

  # ── claim ──────────────────────────────────────────────────────────────────
  # No --log-file passed: this is a second, log-free parse of the same return
  # file the router already parsed once (with --log-file) to write its own
  # META|phase-result entry. Re-running the pure extraction has no side effect
  # and avoids re-reading a `|`-delimited log line to recover the claim.
  local claim_json
  claim_json=$(parse_phase_result --phase VERIFY --return-file "$return_file" --ticket-dir "$ticket_dir" 2>/dev/null) || true

  if [ -z "$claim_json" ] || ! printf '%s' "$claim_json" | jq -e . >/dev/null 2>&1; then
    echo "[verdict-recompute] ERROR: could not obtain a claim from --return-file" >&2
    return 2
  fi

  local claimed_verdict claimed_met claimed_total attempt
  claimed_verdict=$(printf '%s' "$claim_json" | jq -r '.claimed_verdict')
  claimed_met=$(printf '%s' "$claim_json" | jq -r '.criteria_met')
  claimed_total=$(printf '%s' "$claim_json" | jq -r '.criteria_total')
  attempt=$(printf '%s' "$claim_json" | jq -r '.attempt')

  # ── evidence ───────────────────────────────────────────────────────────────
  local evidence_file="${ticket_dir%/}/verify-session.md"
  local evidence_state verified_met=0 verified_total=0

  local phase_start_iso phase_start_epoch=""
  phase_start_iso=$(_vr_phase_start_iso "$log_file") || true
  if [ -n "$phase_start_iso" ]; then
    phase_start_epoch=$(date -u -d "$phase_start_iso" +%s 2>/dev/null || echo "")
  fi

  if [ ! -f "$evidence_file" ]; then
    evidence_state="missing"
  else
    local evidence_epoch
    evidence_epoch=$(stat -c %Y "$evidence_file" 2>/dev/null || echo "0")

    if [ -n "$phase_start_epoch" ] && [ "$evidence_epoch" -le "$phase_start_epoch" ]; then
      # Left over from an earlier attempt — this attempt never wrote it.
      evidence_state="stale"
    else
      # Either provably fresh (mtime after the phase-start bracket), or the
      # bracket could not be resolved (no --log-file, or the log carries no
      # matching line) — the latter is recorded distinctly rather than
      # silently treated as proven-fresh, so a standalone caller's output is
      # honest about what it could and could not check.
      if [ -n "$phase_start_epoch" ]; then
        evidence_state="fresh"
      else
        evidence_state="fresh-unverified-phase-start"
      fi

      UNCHECKED_COUNT=0
      TOTAL_COUNT=0
      _count_checklist_boxes "$evidence_file" "$_VR_STEP_HEADING"
      verified_total="$TOTAL_COUNT"
      verified_met=$((TOTAL_COUNT - UNCHECKED_COUNT))
    fi
  fi

  local verified_verdict="FAIL"
  if [ "$verified_total" -gt 0 ] && [ "$verified_met" -eq "$verified_total" ]; then
    verified_verdict="PASS"
  fi

  # ── direction ──────────────────────────────────────────────────────────────
  local direction
  if [ "$claimed_verdict" = "UNKNOWN" ]; then
    direction="unknown"
  elif [ "$claimed_verdict" = "PASS" ] && [ "$verified_verdict" = "PASS" ]; then
    direction="aligned"
  elif [ "$claimed_verdict" != "PASS" ] && [ "$verified_verdict" = "FAIL" ]; then
    direction="aligned"
  elif [ "$claimed_verdict" = "PASS" ] && [ "$verified_verdict" = "FAIL" ]; then
    direction="optimistic"
  else
    direction="pessimistic"
  fi

  local delta=$((claimed_met - verified_met))

  # ── emit ───────────────────────────────────────────────────────────────────
  local json
  json=$(jq -nc \
    --arg phase "$phase" \
    --arg claimed_verdict "$claimed_verdict" \
    --argjson claimed_met "$claimed_met" \
    --argjson claimed_total "$claimed_total" \
    --arg verified_verdict "$verified_verdict" \
    --argjson verified_met "$verified_met" \
    --argjson criteria_total "$verified_total" \
    --argjson delta "$delta" \
    --arg direction "$direction" \
    --arg evidence "$evidence_file" \
    --arg evidence_state "$evidence_state" \
    --argjson attempt "$attempt" \
    '{phase: $phase, claimed_verdict: $claimed_verdict, claimed_met: $claimed_met,
      claimed_total: $claimed_total, verified_verdict: $verified_verdict,
      verified_met: $verified_met, criteria_total: $criteria_total,
      delta: $delta, direction: $direction, evidence: $evidence,
      evidence_state: $evidence_state, attempt: $attempt}' \
    2>/dev/null) || json=""

  if [ -z "$json" ] || ! printf '%s' "$json" | jq -e . >/dev/null 2>&1; then
    echo "[verdict-recompute] WARN: jq serialization failed, nothing emitted" >&2
    return 2
  fi

  printf '%s\n' "$json"

  if [ -n "$log_file" ]; then
    local iso
    iso=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    echo "${iso}|META|claim-delta|info|${json}" >>"$log_file" || {
      echo "[verdict-recompute] WARN: log write failed (LOG_FILE=${log_file})" >&2
    }
  fi

  [ "$direction" = "aligned" ] && return 0
  return 1
}

# Standalone CLI. Sourcing the file defines the function without running it.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  verdict_recompute "$@"
  exit $?
fi
