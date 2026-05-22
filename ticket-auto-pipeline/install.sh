#!/bin/bash
# install.sh — Post-install migration helper for ticket-auto-pipeline plugin.
# Detects host-side ticket-* skill directories and prompts to archive them.
# Non-destructive: never deletes, only moves to an archive location.

set -euo pipefail

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
  exit 0
fi

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
