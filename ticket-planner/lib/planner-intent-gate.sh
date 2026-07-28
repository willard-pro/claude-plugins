#!/usr/bin/env bash
# ── planner-intent-gate.sh ────────────────────────────────────────────────────
# Pre-flight gate for ticket-planner that validates grill-me intent documents
# before any initiative state is created.
#
# Resolves grill-seal.sh from the grill-me plugin through a three-level
# fallback. No bundled copy — a drifting duplicate would silently pass
# invalid seals (design D7).
#
# Exports:
#   _resolve_grill_seal       → path to grill-seal.sh or empty string
#   planner_intent_gate  <path>  → exit 0 (proceed) | non-zero (hard stop)
#
# Exit codes:
#   0 — gate passed, proceed
#   1 — intent file is blocked (NO_SEAL, MISMATCH, do-not-proceed)
#   2 — intent file not found or unreadable
#   3 — grill-seal.sh could not be resolved (install grill-me plugin)
#   4 — seal verification failed with unexpected error
#
# Environment:
#   PLANNER_REQUIRE_INTENT  — if "true", raw idea strings are refused
# ───────────────────────────────────────────────────────────────────────────────

# Sourceable library — no set -euo pipefail.

# ── _resolve_grill_seal ───────────────────────────────────────────────────────
# Three-level fallback to locate grill-seal.sh from the grill-me plugin.
# Mirrors _resolve_branch_directive_checker in branch-directive-gen.sh exactly:
#   1. Plugin cache:  ~/.claude/plugins/cache/willard-pro-claude-plugins/grill-me/{version}/lib/
#      (versioned — glob across version directories, take the newest by sort)
#   2. Skills lib:    ~/.claude/skills/lib/
#   3. Relative path: ../grill-me/lib/ (from ticket-planner/lib/)
#
# Returns: path on stdout, or empty string if not found.
# ──────────────────────────────────────────────────────────────────────────────
_resolve_grill_seal() {
  local resolved script_dir

  # Level 1: Plugin cache (versioned — e.g. .../grill-me/0.1.0/lib/grill-seal.sh)
  resolved=$(find "${HOME}/.claude/plugins/cache" -name "grill-seal.sh" \
    -path "*/grill-me/*/lib/grill-seal.sh" 2>/dev/null | sort | tail -1)
  if [ -n "$resolved" ] && [ -f "$resolved" ]; then
    echo "$resolved"
    return 0
  fi

  # Level 2: Skills lib (SessionStart hook copies lib/*.sh here)
  resolved="${HOME}/.claude/skills/lib/grill-seal.sh"
  if [ -f "$resolved" ]; then
    echo "$resolved"
    return 0
  fi

  # Level 3: Relative path from ticket-planner/lib/ to grill-me/lib/
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  resolved="${script_dir}/../../grill-me/lib/grill-seal.sh"
  if [ -f "$resolved" ]; then
    echo "$resolved"
    return 0
  fi

  echo ""
  return 1
}

# ── planner_intent_gate ───────────────────────────────────────────────────────
# Usage: planner_intent_gate <path-to-intent-file>
#
# Validates the intent file's seal and recommendation. Hard stops on:
#   - Missing or unreadable file (exit 2)
#   - NO_SEAL — file has no Intent Seal block (exit 1)
#   - MISMATCH — file was edited since sealing (exit 1)
#   - do-not-proceed — under-specified, user must re-grill (exit 1)
#   - Verifier not found — grill-me plugin missing (exit 3)
#
# Proceeds on:
#   - ready — silent proceed (exit 0)
#   - proceed-with-warnings — proceed with warning message (exit 0)
#
# On success, emits KEY=value lines for:
#   PLANNER_INTENT_READINESS, PLANNER_INTENT_RECOMMENDATION,
#   PLANNER_INTENT_HASH, PLANNER_INTENT_PROFILE
# ──────────────────────────────────────────────────────────────────────────────
planner_intent_gate() {
  local intent_path="$1"

  # File must exist
  if [ ! -f "$intent_path" ]; then
    echo "planner-intent-gate: intent file not found: ${intent_path}" >&2
    return 2
  fi

  # Resolve seal verifier
  local seal_script
  seal_script=$(_resolve_grill_seal)
  if [ -z "$seal_script" ]; then
    cat >&2 <<'MSG'
planner-intent-gate: grill-seal.sh could not be resolved.

The planner requires the grill-me plugin to verify intent documents.
Install it from the marketplace:

  claude plugins install grill-me

Or clone the repository and ensure grill-me/ is present alongside ticket-planner/.
MSG
    return 3
  fi

  # Verify the seal. Save/restore errexit rather than unconditionally
  # re-enabling it — this function is called from callers with and without
  # set -e, and must not change the caller's shell options either way.
  local verify_out verify_exit errexit_was_set=0
  case $- in *e*) errexit_was_set=1 ;; esac
  set +e
  verify_out=$(bash "$seal_script" verify "$intent_path" 2>&1)
  verify_exit=$?
  [ "$errexit_was_set" -eq 1 ] && set -e

  local seal_status
  seal_status=$(echo "$verify_out" | grep "^GRILL_SEAL_STATUS=" | cut -d= -f2)

  case "$verify_exit" in
  0) ;; # VALID — continue to recommendation check
  2)
    echo "planner-intent-gate: intent file not found or unreadable: ${intent_path}" >&2
    return 2
    ;;
  3)
    echo "planner-intent-gate: file is not a grill-me intent document (no seal found)." >&2
    echo "Run /grill-me first to validate and seal your idea." >&2
    return 1
    ;;
  4)
    echo "planner-intent-gate: intent file was edited since validation (seal mismatch)." >&2
    echo "Re-run /grill-me to re-validate and re-seal the file." >&2
    return 1
    ;;
  *)
    echo "planner-intent-gate: seal verification failed with unexpected exit code ${verify_exit}" >&2
    return 4
    ;;
  esac

  # Extract metadata
  local readiness recommendation profile generated
  readiness=$(echo "$verify_out" | grep "^GRILL_READINESS=" | cut -d= -f2)
  recommendation=$(echo "$verify_out" | grep "^GRILL_RECOMMENDATION=" | cut -d= -f2)
  profile=$(echo "$verify_out" | grep "^GRILL_PROFILE=" | cut -d= -f2)

  # Extract content hash from the seal
  local content_hash
  content_hash=$(grep '^\*\*Content-Hash:\*\* sha256:' "$intent_path" | head -1 | sed 's/.*sha256://')

  # Check recommendation
  case "$recommendation" in
  ready)
    # Proceed silently
    ;;
  proceed-with-warnings)
    echo "planner-intent-gate: intent document carries warnings (readiness=${readiness})." >&2
    echo "Planning will proceed, but review the open gaps in the intent document." >&2
    ;;
  do-not-proceed)
    echo "planner-intent-gate: intent document is blocked (readiness=${readiness}, recommendation=${recommendation})." >&2
    echo "The idea is under-specified. Re-run /grill-me to close the critical gaps." >&2
    return 1
    ;;
  *)
    echo "planner-intent-gate: unknown recommendation '${recommendation}'" >&2
    return 4
    ;;
  esac

  # Emit metadata for the planner to capture
  echo "PLANNER_INTENT_READINESS=${readiness}"
  echo "PLANNER_INTENT_RECOMMENDATION=${recommendation}"
  echo "PLANNER_INTENT_HASH=${content_hash}"
  echo "PLANNER_INTENT_PROFILE=${profile}"

  return 0
}

# ── planner_intent_gate_check_require ─────────────────────────────────────────
# Checks PLANNER_REQUIRE_INTENT setting. When true and input is a raw string
# (not a file), exits non-zero.
#
# Usage: planner_intent_gate_check_require <argument>
# Returns 0 if OK to proceed with raw idea, 1 if raw ideas are blocked.
# ──────────────────────────────────────────────────────────────────────────────
planner_intent_gate_check_require() {
  local arg="$1"

  # Is it an existing file?
  if [ -f "$arg" ]; then
    return 0 # It's a file — gate runs separately
  fi

  # It's a raw string. Check PLANNER_REQUIRE_INTENT.
  if [ "${PLANNER_REQUIRE_INTENT:-false}" = "true" ]; then
    echo "planner-intent-gate: PLANNER_REQUIRE_INTENT=true — raw idea strings are not accepted." >&2
    echo "Run /grill-me \"${arg}\" first to produce a validated intent document, then pass the file:" >&2
    echo "  /ticket-planner plan ./path/to/intent.md" >&2
    return 1
  fi

  return 0
}

# If executed directly
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  if [ $# -lt 1 ]; then
    echo "Usage: planner-intent-gate.sh <path-to-intent-file>" >&2
    exit 1
  fi
  planner_intent_gate "$1"
fi
