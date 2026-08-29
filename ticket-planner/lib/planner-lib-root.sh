#!/usr/bin/env bash
# planner-lib-root.sh — Resolve the ticket-planner plugin root that holds lib/.
#
# Why this exists
# ───────────────
# Phase agents are spawned via the Agent tool with subagent_type general-purpose.
# CLAUDE_PLUGIN_ROOT is set by Claude Code for the invoking skill but is not
# guaranteed to propagate into a spawned subagent's shell. Every prompt therefore
# carried a hardcoded fallback pointing at a marketplace-less plugin-cache
# directory with a "current" symlink. Neither exists — the real layout is
# ~/.claude/plugins/cache/{marketplace}/{plugin}/{version}/ — so the fallback
# could never resolve and every source in the agent died with a bare
# "No such file or directory".
#
# Search order (same three-level shape as _resolve_grill_seal in
# planner-intent-gate.sh and _resolve_branch_directive_checker in
# branch-directive-gen.sh):
#
#   1. Plugin cache, versioned — ~/.claude/plugins/cache/*/ticket-planner/*/lib/
#      Globbed across marketplace and version directories, newest by sort.
#   2. Skills lib — ~/.claude/skills, whose lib/ is populated on every session
#      by this plugin's SessionStart hook (see .claude-plugin/plugin.json).
#   3. Relative to this file — ../ from lib/, i.e. the repo checkout.
#
# The returned value is the *plugin root*, so callers keep using the familiar
# "${root}/lib/planner-state.sh" form and CLAUDE_PLUGIN_ROOT stays meaningful.
#
# Sourceable library — no set -euo pipefail.

# Marker file used to identify a real planner lib directory.
_PLANNER_LIB_MARKER="planner-state.sh"

# Resolve the ticket-planner plugin root.
# Usage: planner_resolve_lib_root
# Output: plugin root path on stdout (no trailing slash), or empty string.
# Returns: 0 if found, 1 if not.
planner_resolve_lib_root() {
  local candidate script_dir

  # Level 0: an already-set CLAUDE_PLUGIN_ROOT wins, but only if it actually
  # holds the libs. An inherited-but-wrong value must not shadow a good one.
  if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "${CLAUDE_PLUGIN_ROOT}/lib/${_PLANNER_LIB_MARKER}" ]; then
    echo "${CLAUDE_PLUGIN_ROOT%/}"
    return 0
  fi

  # Level 1: Plugin cache (versioned — .../{marketplace}/ticket-planner/{version}/lib/)
  candidate=$(find "${HOME}/.claude/plugins/cache" \
    -path "*/ticket-planner/*/lib/${_PLANNER_LIB_MARKER}" 2>/dev/null | sort | tail -1)
  if [ -n "$candidate" ] && [ -f "$candidate" ]; then
    # .../{version}/lib/planner-state.sh → .../{version}
    echo "$(cd "$(dirname "$candidate")/.." && pwd)"
    return 0
  fi

  # Level 2: Skills lib (SessionStart hook copies lib/*.sh to ~/.claude/skills/lib/)
  candidate="${HOME}/.claude/skills"
  if [ -f "${candidate}/lib/${_PLANNER_LIB_MARKER}" ]; then
    echo "$candidate"
    return 0
  fi

  # Level 3: Relative to this file — lib/ → plugin root
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  candidate="$(cd "${script_dir}/.." && pwd)"
  if [ -f "${candidate}/lib/${_PLANNER_LIB_MARKER}" ]; then
    echo "$candidate"
    return 0
  fi

  echo ""
  return 1
}

# Resolve the plugin root or hard-stop with a named path and install guidance.
# Sourcing failure must never surface as a bare shell error — the operator needs
# to know which path was tried and how to fix it.
#
# Usage: root=$(planner_require_lib_root) || exit $?
# Returns: 0 on success; 5 when no candidate resolved.
planner_require_lib_root() {
  local root
  root=$(planner_resolve_lib_root)
  if [ -z "$root" ]; then
    cat >&2 <<'MSG'
ticket-planner: could not locate the planner lib directory.

Searched, in order:
  1. $CLAUDE_PLUGIN_ROOT/lib/planner-state.sh          (if CLAUDE_PLUGIN_ROOT set)
  2. ~/.claude/plugins/cache/*/ticket-planner/*/lib/   (marketplace install)
  3. ~/.claude/skills/lib/                             (SessionStart hook copy)
  4. <repo>/ticket-planner/lib/                        (source checkout)

Install the plugin from the marketplace:

  claude plugin install ticket-planner@willard-pro-claude-plugins

or start a new session so the SessionStart hook can populate ~/.claude/skills/lib/.
MSG
    return 5
  fi
  echo "$root"
}
