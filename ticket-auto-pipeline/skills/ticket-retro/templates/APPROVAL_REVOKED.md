# APPROVAL_REVOKED — Gate-Stop Analysis Template

## Pattern

The pipeline halted because the `approved` label was removed from the Linear ticket between the PR iteration phase and the re-implement phase. The orchestrator's live Linear check (Step 5d) detected that either the state was not `Ready` or the `approved` label was missing.

## What to Look For

In `~/.claude/skills/ticket-auto/SKILL.md` Step 5d:

1. **Re-approval gate logic**: The check reads live Linear state and asserts both `state=Ready` and `approved` label present. Is this check happening before every re-implement spawn?
2. **Label lifecycle**: What removes the `approved` label? Check `ticket-pr-iterate` — does it strip labels? Does `ticket-flow`'s state transitions clear labels unexpectedly?
3. **Race condition**: Between `ticket-pr-iterate` posting findings and `ticket-auto` re-spawning implement, could a concurrent action (manual Linear edit, webhook) remove the label?

In `~/.claude/skills/ticket-pr-iterate/SKILL.md`:

4. **State transition**: After posting findings, does the skill move the ticket to `Ready` AND ensure `approved` is still present?

## Minimal Fix Pattern

The fix typically adds a label-verification step in `ticket-pr-iterate` after the Linear update:

```bash
# Verify approved label survived the state transition
LABELS=$(linear_api "query { issue(id: \"$TICKET_ID\") { labels { nodes { name } } } }")
echo "$LABELS" | jq -e '.data.issue.labels.nodes[].name | select(. == "approved")' || {
  echo "FATAL: approved label lost during pr-iterate"
  exit 1
}
```

## Related

- See `ticket-auto/SKILL.md` Step 5d for the re-approval gate logic.
- See `ticket-flow/state-machine.json` for label-to-state mappings.
