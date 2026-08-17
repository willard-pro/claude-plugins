#!/usr/bin/env bash
# test-plugin-structure.sh — plugin-structure invariants for fleet-controller.
# Usage: bash test-plugin-structure.sh [test_name_filter]
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPO_DIR="$(cd "$PLUGIN_DIR/.." && pwd)"
TAP_PLUGIN_DIR="$REPO_DIR/ticket-auto-pipeline"

PASS=0
FAIL=0

_run() {
  local name="$1"
  shift
  if "$@" 2>/dev/null; then
    echo "PASS: $name"
    ((PASS++)) || true
  else
    echo "FAIL: $name"
    ((FAIL++)) || true
  fi
}

# ── Tests ───────────────────────────────────────────────────────────────────────

# List the .sh files a plugin's SessionStart hook would copy: parse the hook
# command's cp glob relative to ${CLAUDE_PLUGIN_ROOT}/lib.
_sessionstart_copied_filenames() {
  local plugin_dir="$1"
  local manifest="${plugin_dir}/.claude-plugin/plugin.json"
  [ -f "$manifest" ] || {
    echo "manifest missing: $manifest" >&2
    return 1
  }
  # Extract every SessionStart command line, then every source pattern it cp's.
  local patterns
  patterns=$(jq -r '.hooks.SessionStart[]?.hooks[]?.command // empty' "$manifest" 2>/dev/null |
    grep -o '/lib/"\?\*\.sh\|/lib/\*\.sh' | sort -u)
  [ -n "$patterns" ] || {
    echo "no lib/*.sh copy pattern found in SessionStart hooks of $plugin_dir" >&2
    return 1
  }
  # The hook copies every *.sh in lib/ — enumerate the actual files.
  ls "$plugin_dir"/lib/*.sh 2>/dev/null | xargs -n1 basename | sort -u
}

test_sessionstart_hook_exists() {
  local manifest="${PLUGIN_DIR}/.claude-plugin/plugin.json"
  [ -f "$manifest" ] || {
    echo "manifest missing" >&2
    return 1
  }
  jq -e '.hooks.SessionStart | length > 0' "$manifest" >/dev/null 2>&1 || {
    echo "no SessionStart hook registered" >&2
    return 1
  }
  jq -e '.hooks.SessionStart[].hooks[].command | contains(".sh")' "$manifest" >/dev/null 2>&1 || {
    echo "SessionStart hook does not copy .sh files" >&2
    return 1
  }
  return 0
}

test_no_lib_filename_collides_with_ticket_auto_pipeline() {
  # fleet-controller and ticket-auto-pipeline both copy lib/*.sh into the
  # shared ~/.claude/skills/lib/ on SessionStart. Filename collisions mean
  # whichever hook runs last silently clobbers the other plugin's file.
  local fleet_files tap_files collisions
  fleet_files=$(_sessionstart_copied_filenames "$PLUGIN_DIR") || return 1
  tap_files=$(_sessionstart_copied_filenames "$TAP_PLUGIN_DIR") || return 1

  collisions=$(comm -12 \
    <(echo "$fleet_files") \
    <(echo "$tap_files"))
  [ -z "$collisions" ] || {
    echo "colliding lib filenames between fleet-controller and ticket-auto-pipeline SessionStart hooks: $collisions" >&2
    return 1
  }
  return 0
}

test_fleet_config_is_namespaced() {
  # The old generic config.sh must not exist under fleet-controller — the
  # renamed fleet-config.sh is the namespaced replacement.
  [ ! -f "${PLUGIN_DIR}/lib/config.sh" ] || {
    echo "fleet-controller/lib/config.sh still exists — rename incomplete" >&2
    return 1
  }
  [ -f "${PLUGIN_DIR}/lib/fleet-config.sh" ] || {
    echo "fleet-controller/lib/fleet-config.sh missing" >&2
    return 1
  }
  return 0
}

# ── Run all tests ────────────────────────────────────────────────────────────────

_run "sessionstart_hook_exists" test_sessionstart_hook_exists
_run "no_lib_filename_collides_with_tap" test_no_lib_filename_collides_with_ticket_auto_pipeline
_run "fleet_config_is_namespaced" test_fleet_config_is_namespaced

echo ""
echo "=== Results ==="
echo "PASS: $PASS | FAIL: $FAIL"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
