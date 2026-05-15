# EXEC_NO_ARTIFACT — Gate-Stop Analysis Template

## Pattern

The pipeline halted because the Exec phase produced no artifact file. After investigation, `ticket-appraise-exec` completed but the expected artifact (`simple-fix.md` or `openspec/changes/<id>/tasks.md`) was not found on disk.

## What to Look For

In `~/.claude/skills/ticket-appraise-exec/SKILL.md`:

1. **Path resolution logic**: Where does the skill write `simple-fix.md`? Is the directory derived correctly from the ticket ID and project structure?
2. **Write-then-verify pattern**: Does the skill write the file and verify it exists before reporting success?
3. **Openspec path**: For complex tickets, is `openspec/changes/<id>/` created before `tasks.md` is written? Check directory creation order.
4. **Handoff output**: Does the final handoff reliably report the artifact path? The orchestrator extracts `{ARTIFACT_TYPE}` from the agent result.

## Minimal Fix Pattern

The fix typically involves adding an existence check after the write step and before the handoff:

```bash
# After writing the artifact, verify it exists
if [ ! -f "$ARTIFACT_PATH" ]; then
  echo "FATAL: artifact not written at $ARTIFACT_PATH" >&2
  exit 1
fi
```

## Related

- See `ticket-auto/SKILL.md` Step 2.5 for the gate logic that detects this failure.
- See `pipeline-log-format.md` gate-stop codes section.
