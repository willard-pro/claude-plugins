#!/usr/bin/env bash
# epic-precondition.sh — the epic discriminator and precondition evaluator.
#
# Sourceable bash library. Does NOT set -euo pipefail (caller controls error
# handling). flow.sh sources this file and calls into it, so tests that source
# it exercise the executor's real evaluation rather than re-implementing the
# condition inline — the failure mode that let the previous, always-true
# discriminator survive with a green suite.
#
# Dependencies (optional): branch-directive-check.sh, for the directive arm of
# the discriminator. Absent, only the marker-label arm applies.

# Marker label identifying an epic issue. Overridable for workspaces that use a
# different convention.
EPIC_MARKER_LABEL="${EPIC_MARKER_LABEL:-epic}"

# is_epic_issue <issue_json>
# Returns 0 when the issue is an epic, 1 otherwise.
#
# Discriminates on two properties that exist in this workspace and are already
# present in the payload the executor fetches, so neither costs a request:
#   1. the epic marker label
#   2. a valid Branch Directive in the description
#
# It deliberately does NOT read .issueType.name: that field is undefined in this
# workspace, so a check against it evaluates as "not an epic" for every issue.
is_epic_issue() {
  local issue_json="$1"
  local marker="${EPIC_MARKER_LABEL:-epic}"

  local labels
  labels=$(echo "$issue_json" | jq -r '[.labels.nodes[]?.name] | join(",")' 2>/dev/null || true)
  if [ -n "$labels" ] && echo "$labels" | tr ',' '\n' | grep -qix "$marker"; then
    return 0
  fi

  local desc
  desc=$(echo "$issue_json" | jq -r '.description // ""' 2>/dev/null || true)
  if [ -n "$desc" ] && declare -f check_branch_directive_description >/dev/null 2>&1; then
    if check_branch_directive_description "$desc" >/dev/null 2>&1; then
      return 0
    fi
  fi

  return 1
}

# check_precondition <precondition> <subject> <issue_json>
# Evaluates a precondition declared on a trigger or a label.
#
# Exit codes: 0 satisfied, 8 rejected, 9 unknown precondition.
# <subject> names the trigger or label, for the operator-facing message.
check_precondition() {
  local pre="$1"
  local subject="$2"
  local issue_json="$3"

  case "$pre" in
  must_be_epic)
    if is_epic_issue "$issue_json"; then
      return 0
    fi
    echo "precondition failed — '${subject}' applies only to epic issues (no '${EPIC_MARKER_LABEL:-epic}' label and no valid Branch Directive)" >&2
    return 8
    ;;
  must_not_be_epic)
    if is_epic_issue "$issue_json"; then
      echo "precondition failed — '${subject}' is a child lifecycle transition and cannot be applied to an epic issue" >&2
      return 8
    fi
    return 0
    ;;
  "" | null)
    return 0
    ;;
  *)
    echo "unknown precondition '${pre}' declared for '${subject}'" >&2
    return 9
    ;;
  esac
}
