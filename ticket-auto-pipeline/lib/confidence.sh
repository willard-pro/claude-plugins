#!/usr/bin/env bash
# confidence.sh — Shared confidence-computation helpers.
# Phase 0 RLVR — extracted from verifier-result.sh and planned-feedback-write.sh
# to prevent drift (F9).
#
# Usage: source this file, then call _compute_actual_confidence.
#
#   _compute_actual_confidence <outcome> [corrections]
#
# Outcome → base: Smooth → 0.90, Rough → 0.65, Hard → 0.40, unknown → 0.70.
# Corrections subtract 0.05 each. Floor at 0.10.
# Emits score string on [0.00, 0.90] scale (0.xx format).

# -u (nounset) intentionally omitted: sourced by callers that also omit -u
# for Claude Code shell snapshot ZSH_VERSION compatibility.
set -eo pipefail

_compute_actual_confidence() {
  local outcome="$1" corrections="${2:-0}"
  local base

  case "$outcome" in
  Smooth) base=90 ;;
  Rough) base=65 ;;
  Hard) base=40 ;;
  *) base=70 ;; # Unknown outcome — neutral
  esac

  local penalty=$((corrections * 5))
  local score=$((base - penalty))

  # Floor at 10
  [ "$score" -lt 10 ] && score=10

  # Convert to 0-1 scale (divide by 100)
  echo "0.${score}"
}
