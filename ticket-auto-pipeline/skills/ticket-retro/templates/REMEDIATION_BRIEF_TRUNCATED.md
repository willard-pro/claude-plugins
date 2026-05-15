# REMEDIATION_BRIEF_TRUNCATED — Gate-Stop Analysis Template

## Pattern

The REMEDIATION_BRIEF written by `ticket-verify` exceeded the length limit or was truncated during the write/rename operation, causing `ticket-implement` Step 2.5 to fail when reading it back.

## What to Look For

In `~/.claude/skills/ticket-verify/SKILL.md`:

1. **Write path**: Where does the skill write the REMEDIATION_BRIEF? Look for the `REMEDIATION_BRIEF` section in the output format.
2. **Atomic write pattern**: Does the skill use a temp-file + rename pattern, or does it write directly? Direct writes can produce partial files if the skill is interrupted.
3. **Size limits**: The pipeline log format says MSG should be under 60 chars, but REMEDIATION_BRIEF can be longer. Is there a buffer or truncation issue?

In `~/.claude/skills/ticket-implement/SKILL.md`:

4. **Read path**: Step 2.5 reads the REMEDIATION_BRIEF from `notes.md`. Does it check for completeness (e.g., verify the section ends with a known sentinel)?

## Minimal Fix Pattern

The fix typically involves an atomic write in `ticket-verify`:

```bash
# Write REMEDIATION_BRIEF atomically
cat > "$TICKET_DIR/notes.tmp" << BRIEF
$(cat "$TICKET_DIR/notes.md")
## REMEDIATION_BRIEF
- [ ] Fix 1
- [ ] Fix 2
BRIEF
mv "$TICKET_DIR/notes.tmp" "$TICKET_DIR/notes.md"
```

And a completeness check in `ticket-implement`:

```bash
grep -q '^## REMEDIATION_BRIEF' "$TICKET_DIR/notes.md" || {
  echo "REMEDIATION_BRIEF not found or truncated"
  exit 1
}
```

## Related

- See `ticket-verify/SKILL.md` for the REMEDIATION_BRIEF output format.
- See `ticket-implement/SKILL.md` Step 2.5 for the read/check logic.
