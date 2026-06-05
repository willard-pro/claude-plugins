#!/bin/bash
# install.sh — Post-install migration helper for ticket-auto-pipeline plugin.
# Detects host-side ticket-* skill directories and prompts to archive them.
# Non-destructive: never deletes, only moves to an archive location.

# -u (nounset) intentionally omitted: Claude Code shell snapshots inject
# ZSH_VERSION references that trigger false-positive "unbound variable"
# errors in this bash version when nounset is active.
set -eo pipefail

HOST_SKILLS="$HOME/.claude/skills"
ARCHIVE_DIR="$HOME/.claude/skills-archived-$(date +%Y%m%d-%H%M%S)"

TICKET_SKILLS=(
  ticket-appraise ticket-appraise-exec ticket-auto
  ticket-batch-appraise ticket-batch-verify ticket-critique
  ticket-detect-resume ticket-flow ticket-implement
  ticket-overseer ticket-pr-iterate ticket-pr-review
  ticket-reproduce ticket-setup ticket-verify
  ticket-retro
)

# Find which ticket-* skills exist on the host
EXISTING=()
for skill in "${TICKET_SKILLS[@]}"; do
  if [ -d "$HOST_SKILLS/$skill" ]; then
    EXISTING+=("$skill")
  fi
done

# Also check support skills
SUPPORT_SKILLS=(wiki-maintenance nav-hints app-knowledge)
for skill in "${SUPPORT_SKILLS[@]}"; do
  if [ -d "$HOST_SKILLS/$skill" ]; then
    EXISTING+=("$skill")
  fi
done

if [ ${#EXISTING[@]} -eq 0 ]; then
  echo "No host-side ticket-* skills found. Nothing to migrate."
else
  echo "The following host-side skill directories were found:"
  for skill in "${EXISTING[@]}"; do
    echo "  $HOST_SKILLS/$skill"
  done
  echo ""
  echo "These are now provided by the ticket-auto-pipeline plugin and can be archived."
  echo "Archive location: $ARCHIVE_DIR"
  echo ""
  read -rp "Archive these directories? [y/N] " answer

  case "$answer" in
  [yY] | [yY][eE][sS])
    mkdir -p "$ARCHIVE_DIR"
    for skill in "${EXISTING[@]}"; do
      mv "$HOST_SKILLS/$skill" "$ARCHIVE_DIR/"
      echo "  archived $skill"
    done
    echo ""
    echo "Done. Skills archived to $ARCHIVE_DIR"
    echo "To restore: mv $ARCHIVE_DIR/* $HOST_SKILLS/"
    ;;
  *)
    echo "Skipped. Host skills left in place."
    ;;
  esac
fi

# ── Permissions injection ──────────────────────────────────────────────────
# Adds Bash allow rules for spawn-helper.sh and heartbeat.sh (sourced by the
# thin router to bracket phase agent spawns), plus a Write rule for the
# pipeline logs directory.  Idempotent — running install.sh twice will not
# duplicate rules.

echo ""
echo "Checking spawn-helper and heartbeat permissions..."

# Resolve target settings file — project-level preferred, user-level fallback
SETTINGS_FILE=""
if [ -f "$PWD/.claude/settings.json" ]; then
  SETTINGS_FILE="$PWD/.claude/settings.json"
elif [ -f "$HOME/.claude/settings.json" ]; then
  SETTINGS_FILE="$HOME/.claude/settings.json"
else
  SETTINGS_FILE="$HOME/.claude/settings.json"
  echo '{"permissions": {"allow": []}}' > "$SETTINGS_FILE"
  echo "Created $SETTINGS_FILE with minimal permissions skeleton"
fi

ADDED=0
SKIPPED=0
RULES=()

add_rule() {
  local rule="$1"
  if jq -e --arg rule "$rule" '.permissions.allow // [] | map(select(. == $rule)) | length > 0' "$SETTINGS_FILE" >/dev/null 2>&1; then
    SKIPPED=$((SKIPPED + 1))
    RULES+=("  - $rule (already present)")
    return 0
  fi
  local tmp="${SETTINGS_FILE}.tmp.$$"
  if jq --arg rule "$rule" '.permissions.allow = (.permissions.allow // []) + [$rule]' "$SETTINGS_FILE" > "$tmp" 2>/dev/null; then
    mv "$tmp" "$SETTINGS_FILE"
    ADDED=$((ADDED + 1))
    RULES+=("  - $rule")
  else
    echo "WARNING: failed to add permission rule — jq error (settings.json may be hand-edited)" >&2
    rm -f "$tmp"
  fi
}

add_rule "Bash(source ${HOME}/.claude/skills/lib/spawn-helper.sh *)"
add_rule "Bash(source ${HOME}/.claude/skills/lib/heartbeat.sh *)"
add_rule "Write(${PWD}/logs/**)"

echo "ticket-auto-pipeline: added $ADDED permission rule(s) to $SETTINGS_FILE"
for rule_line in "${RULES[@]}"; do
  echo "$rule_line"
done
if [ "$ADDED" -eq 0 ] && [ "$SKIPPED" -gt 0 ]; then
  echo "  (all rules already present — nothing to add)"
fi
