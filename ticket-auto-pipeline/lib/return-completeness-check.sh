#!/usr/bin/env bash
# return-completeness-check.sh — deterministic bash gate that counts unchecked
# `- [ ]` boxes in a ticket's plan artifact (openspec tasks.md or simple-fix.md's
# ## Completion Checklist). Modeled on gate-check.sh's exit-code idiom:
# 0 complete, 1 incomplete, 2 error. Zero LLM tokens.
# -u (nounset) intentionally omitted: Claude Code shell snapshots inject
# ZSH_VERSION references that trigger false-positive "unbound variable"
# errors in this bash version when nounset is active.
set -eo pipefail

_RCC_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_RCC_LIB_DIR="${CLAUDE_SKILLS_LIB:-$HOME/.claude/skills/lib}"
# heartbeat.sh is optional — source if available, degrade gracefully if not
if [ -f "$_RCC_LIB_DIR/heartbeat.sh" ]; then
  source "$_RCC_LIB_DIR/heartbeat.sh"
elif [ -f "$_RCC_SCRIPT_DIR/heartbeat.sh" ]; then
  source "$_RCC_SCRIPT_DIR/heartbeat.sh"
fi
# Phase 0 RLVR — verifier-result recording
if [ -f "$_RCC_LIB_DIR/verifier-result.sh" ]; then
  source "$_RCC_LIB_DIR/verifier-result.sh"
elif [ -f "$_RCC_SCRIPT_DIR/verifier-result.sh" ]; then
  source "$_RCC_SCRIPT_DIR/verifier-result.sh"
fi

usage() {
  cat >&2 <<'EOF'
Usage: return-completeness-check.sh <TICKET-ID> [--repos-root <path>]
                                     [--tasks-file <path>] [--simple-fix-file <path>]

Counts unchecked `- [ ]` boxes in the ticket's plan artifact — openspec
tasks.md (whole-file count) or simple-fix.md's ## Completion Checklist
(section-scoped count). Tasks.md is tried first; simple-fix.md is the
fallback when no openspec change directory matches.

  --tasks-file <path>       Use this tasks.md directly, skip repo search.
  --simple-fix-file <path>  Use this simple-fix.md directly, skip repo search.
  --repos-root <path>       Root under which to search for the ticket's openspec
                             change directory or ticket workspace directory.
                             Falls back to the REPOS_ROOT env var.

Emits KEY=value lines:
  RETURN_COMPLETENESS_STATUS   complete | incomplete | error
  UNCHECKED_COUNT              integer
  TOTAL_COUNT                  integer
  TASKS_FILE                   resolved path (empty on error)
  UNCHECKED_ITEMS              first few unchecked lines, ; -separated
  REASON                       reason code
  ARTIFACT_TYPE                openspec | simple-fix | (empty on error)

Exit codes: 0 complete, 1 incomplete, 2 error (no plan artifact found/unresolvable)
EOF
  exit 1
}

# ── Resolution ────────────────────────────────────────────────────────────────

# Search REPOS_ROOT for an openspec change directory matching TICKET-ID.
# Mirrors the CHANGE_DIR pattern used inline by ticket-appraise-exec, but
# generalized across every repo under REPOS_ROOT since this script runs
# router-side (bash-only, no per-repo cwd).
_find_tasks_file() {
  local ticket_id="$1" repos_root="$2"
  local ticket_lower repo change_dir
  ticket_lower=$(echo "$ticket_id" | tr '[:upper:]' '[:lower:]')

  while IFS= read -r -d '' repo; do
    for change_dir in "$repo"/openspec/changes/*/; do
      [ -d "$change_dir" ] || continue
      case "$(basename "$change_dir" | tr '[:upper:]' '[:lower:]')" in
      *"$ticket_lower"*)
        if [ -f "${change_dir}tasks.md" ]; then
          echo "${change_dir}tasks.md"
          return 0
        fi
        ;;
      esac
    done
  done < <(find "$repos_root" -maxdepth 3 -name ".git" -printf '%h\0' 2>/dev/null || true)

  return 1
}

# Search REPOS_ROOT for a simple-fix.md in a ticket workspace directory
# matching TICKET-ID. Workspace dirs follow the pattern {TICKET-ID}--{slug}.
_find_simple_fix_file() {
  local ticket_id="$1" repos_root="$2"
  local ticket_lower
  ticket_lower=$(echo "$ticket_id" | tr '[:upper:]' '[:lower:]')

  while IFS= read -r -d '' sf; do
    local parent_dir
    parent_dir=$(basename "$(dirname "$sf")" | tr '[:upper:]' '[:lower:]')
    case "$parent_dir" in
    *"$ticket_lower"*)
      echo "$sf"
      return 0
      ;;
    esac
  done < <(find "$repos_root" -maxdepth 4 -name "simple-fix.md" -print0 2>/dev/null || true)

  return 1
}

# ── Counting ──────────────────────────────────────────────────────────────────

_count_boxes() {
  local tasks_file="$1"
  UNCHECKED_COUNT=$(grep -c '^- \[ \]' "$tasks_file" 2>/dev/null || true)
  UNCHECKED_COUNT="${UNCHECKED_COUNT:-0}"
  local checked_count
  checked_count=$(grep -c '^- \[x\]' "$tasks_file" 2>/dev/null || true)
  checked_count="${checked_count:-0}"
  TOTAL_COUNT=$((UNCHECKED_COUNT + checked_count))
  UNCHECKED_ITEMS=$(grep '^- \[ \]' "$tasks_file" 2>/dev/null | head -5 | sed 's/^- \[ \] //' | paste -sd';' - || true)
}

# Count - [ ] and - [x] boxes within a named markdown section of a file.
# Only counts items inside the section body between the heading and the next
# ## heading or EOF. Sets: UNCHECKED_COUNT, TOTAL_COUNT, UNCHECKED_ITEMS.
_count_checklist_boxes() {
  local file="$1" section_heading="$2"
  local section_content
  # Extract between the section heading and the next ## heading or EOF.
  # The sed range /^## Heading/,/^## / captures everything from the target
  # heading to the next ## heading inclusive; we delete the boundary lines.
  section_content=$(sed -n "/^${section_heading}/,/^## /{ /^${section_heading}/d; /^## /d; p; }" "$file" 2>/dev/null || true)
  UNCHECKED_COUNT=$(echo "$section_content" | grep -c '^- \[ \]' 2>/dev/null || true)
  UNCHECKED_COUNT="${UNCHECKED_COUNT:-0}"
  local checked_count
  checked_count=$(echo "$section_content" | grep -c '^- \[x\]' 2>/dev/null || true)
  checked_count="${checked_count:-0}"
  TOTAL_COUNT=$((UNCHECKED_COUNT + checked_count))
  UNCHECKED_ITEMS=$(echo "$section_content" | grep '^- \[ \]' 2>/dev/null | head -5 | sed 's/^- \[ \] //' | paste -sd';' - || true)
}

# ── Emit results ──────────────────────────────────────────────────────────────

_emit() {
  printf 'RETURN_COMPLETENESS_STATUS=%s\n' "${RETURN_COMPLETENESS_STATUS:-error}"
  printf 'UNCHECKED_COUNT=%s\n' "${UNCHECKED_COUNT:-0}"
  printf 'TOTAL_COUNT=%s\n' "${TOTAL_COUNT:-0}"
  printf 'TASKS_FILE=%q\n' "${TASKS_FILE:-}"
  printf 'UNCHECKED_ITEMS=%q\n' "${UNCHECKED_ITEMS:-}"
  printf 'REASON=%s\n' "${REASON:-unknown}"
  printf 'ARTIFACT_TYPE=%s\n' "${ARTIFACT_TYPE:-}"

  # Phase 0 RLVR — record verifier result after return-completeness check
  local verdict="PASS" criteria_met=1 criteria_total=1
  if [ "${RETURN_COMPLETENESS_STATUS:-error}" = "incomplete" ]; then
    verdict="FAIL"
    criteria_met=$((TOTAL_COUNT - UNCHECKED_COUNT))
    criteria_total="$TOTAL_COUNT"
    [ "$criteria_total" -eq 0 ] && criteria_total=1
  elif [ "${RETURN_COMPLETENESS_STATUS:-error}" = "error" ]; then
    verdict="BLOCK"
    criteria_met=0
  fi
  write_verifier_result \
    verifier=return_completeness verdict="$verdict" \
    criteria_met="$criteria_met" criteria_total="$criteria_total" \
    attempt=1 phase=IMPLEMENT 2>/dev/null || true
}

# ── Main dispatch (only when executed directly, not when sourced for testing) ─

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  TICKET_ID=""
  REPOS_ROOT="${REPOS_ROOT:-}"
  TASKS_FILE_ARG=""
  SIMPLE_FIX_FILE_ARG=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
    --repos-root)
      REPOS_ROOT="${2:-}"
      shift 2
      ;;
    --tasks-file)
      TASKS_FILE_ARG="${2:-}"
      shift 2
      ;;
    --simple-fix-file)
      SIMPLE_FIX_FILE_ARG="${2:-}"
      shift 2
      ;;
    --help | -h)
      usage
      ;;
    -*)
      echo "Unknown flag: $1" >&2
      usage
      ;;
    *)
      if [ -z "$TICKET_ID" ]; then
        TICKET_ID="$1"
        shift
      else
        echo "Unexpected argument: $1" >&2
        usage
      fi
      ;;
    esac
  done

  [ -z "$TICKET_ID" ] && usage

  TASKS_FILE=""
  SIMPLE_FIX_FILE=""
  ARTIFACT_TYPE=""

  # Explicit flags take priority over repo search
  if [ -n "$TASKS_FILE_ARG" ]; then
    TASKS_FILE="$TASKS_FILE_ARG"
    ARTIFACT_TYPE="openspec"
  elif [ -n "$SIMPLE_FIX_FILE_ARG" ]; then
    SIMPLE_FIX_FILE="$SIMPLE_FIX_FILE_ARG"
    ARTIFACT_TYPE="simple-fix"
  elif [ -n "$REPOS_ROOT" ]; then
    # Dual-mode search: tasks.md first (openspec), then simple-fix.md fallback
    TASKS_FILE=$(_find_tasks_file "$TICKET_ID" "$REPOS_ROOT" || true)
    if [ -n "$TASKS_FILE" ] && [ -f "$TASKS_FILE" ]; then
      ARTIFACT_TYPE="openspec"
    else
      SIMPLE_FIX_FILE=$(_find_simple_fix_file "$TICKET_ID" "$REPOS_ROOT" || true)
      if [ -n "$SIMPLE_FIX_FILE" ] && [ -f "$SIMPLE_FIX_FILE" ]; then
        ARTIFACT_TYPE="simple-fix"
      fi
    fi
  fi

  # ── openspec path (tasks.md, whole-file count) ──
  if [ "$ARTIFACT_TYPE" = "openspec" ]; then
    _count_boxes "$TASKS_FILE"

    if [ "$UNCHECKED_COUNT" -gt 0 ] 2>/dev/null; then
      RETURN_COMPLETENESS_STATUS="incomplete"
      REASON="UNCHECKED_BOXES"
      _emit
      hb_gate "return-completeness" "warn" "$UNCHECKED_COUNT unchecked box(es)" \
        "{\"ticket\":\"$TICKET_ID\",\"unchecked\":\"$UNCHECKED_COUNT\",\"total\":\"$TOTAL_COUNT\",\"artifact\":\"openspec\"}" 2>/dev/null || true
      exit 1
    fi

    RETURN_COMPLETENESS_STATUS="complete"
    REASON="ALL_CHECKED"
    _emit
    hb_gate "return-completeness" "ok" "all boxes checked" \
      "{\"ticket\":\"$TICKET_ID\",\"total\":\"$TOTAL_COUNT\",\"artifact\":\"openspec\"}" 2>/dev/null || true
    exit 0
  fi

  # ── simple-fix path (Completion Checklist section, section-scoped count) ──
  if [ "$ARTIFACT_TYPE" = "simple-fix" ]; then
    # Verify the Completion Checklist section exists
    if ! grep -q '^## Completion Checklist' "$SIMPLE_FIX_FILE" 2>/dev/null; then
      RETURN_COMPLETENESS_STATUS="error"
      REASON="COMPLETION_CHECKLIST_MISSING"
      _emit
      hb_gate "return-completeness" "fail" "simple-fix.md lacks ## Completion Checklist" \
        "{\"ticket\":\"$TICKET_ID\",\"artifact\":\"simple-fix\"}" 2>/dev/null || true
      exit 2
    fi

    _count_checklist_boxes "$SIMPLE_FIX_FILE" "## Completion Checklist"

    if [ "$UNCHECKED_COUNT" -gt 0 ] 2>/dev/null; then
      RETURN_COMPLETENESS_STATUS="incomplete"
      REASON="UNCHECKED_BOXES"
      _emit
      hb_gate "return-completeness" "warn" "$UNCHECKED_COUNT unchecked box(es)" \
        "{\"ticket\":\"$TICKET_ID\",\"unchecked\":\"$UNCHECKED_COUNT\",\"total\":\"$TOTAL_COUNT\",\"artifact\":\"simple-fix\"}" 2>/dev/null || true
      exit 1
    fi

    RETURN_COMPLETENESS_STATUS="complete"
    REASON="ALL_CHECKED"
    _emit
    hb_gate "return-completeness" "ok" "all checklist items checked" \
      "{\"ticket\":\"$TICKET_ID\",\"total\":\"$TOTAL_COUNT\",\"artifact\":\"simple-fix\"}" 2>/dev/null || true
    exit 0
  fi

  # ── Neither artifact found ──
  RETURN_COMPLETENESS_STATUS="error"
  REASON="NO_PLAN_ARTIFACT_FOUND"
  _emit
  hb_gate "return-completeness" "fail" "no plan artifact found" \
    "{\"ticket\":\"$TICKET_ID\"}" 2>/dev/null || true
  exit 2
fi
