# COMPLEXITY_ARTIFACT_MISMATCH — Gate-Stop Analysis Template

## Pattern

The pipeline detected a mismatch between the declared complexity label and the artifact type produced. For example, a ticket declared `simple` but the Exec phase created an `openspec` change (which implies complex), or vice versa.

## What to Look For

In `~/.claude/skills/ticket-appraise-exec/SKILL.md`:

1. **Complexity decision logic**: Where does the skill branch on `simple` vs `complex`? Is the complexity read from `notes.md` before the branch?
2. **Artifact type selection**: The skill should produce `simple-fix.md` for simple tickets and `openspec/changes/<id>/` for complex tickets. Is there a code path where this can invert?
3. **Resume vs fresh**: In resume mode, does the skill re-evaluate complexity or trust the prior `notes.md`? A stale read could cause mismatch.
4. **Handoff inconsistency**: If the handoff reports a different artifact type than what was actually written, the orchestrator will note it.

## Minimal Fix Pattern

The fix typically ensures the complexity read happens before the artifact branch, with a guard:

```bash
COMPLEXITY=$(get_complexity "$TICKET_DIR")
case "$COMPLEXITY" in
  simple) create_simple_fix ;;
  complex) create_openspec_change ;;
  *) echo "FATAL: unknown complexity: $COMPLEXITY"; exit 1 ;;
esac
```

## Related

- See `ticket-auto/SKILL.md` Step 2 (Exec) for the agent spawn that invokes this skill.
- See `lib/notes-parse.sh` for the `get_complexity` helper.
