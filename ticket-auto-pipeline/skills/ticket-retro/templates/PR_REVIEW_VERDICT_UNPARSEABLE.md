# PR_REVIEW_VERDICT_UNPARSEABLE — Gate-Stop Analysis Template

## Pattern

The pipeline halted because the PR review agent's output did not contain exactly one parseable `**Verdict:** ✅/⚠️` line. The orchestrator's verdict-line integrity gate (ticket-auto Step 5a) counted 0 or >1 verdict lines.

## What to Look For

In `~/.claude/skills/ticket-pr-review/SKILL.md`:

1. **Output format contract**: The skill must emit exactly one `**Verdict:** ✅` or `**Verdict:** ⚠️` line. Look for the verdict section in the skill's output template.
2. **Multiple verdict lines**: Does the skill ever emit a verdict in both the PR comment body AND a separate handoff? That produces 2 lines.
3. **Missing verdict**: Does the skill have an error path that exits without a verdict line? Partial agent failures may produce a handoff without the verdict block.
4. **Alternative delimiters**: Is the verdict line formatted differently in edge cases (e.g., `**Verdict: ✅**` with bold wrapping the icon)?

## Minimal Fix Pattern

The fix typically standardizes the verdict output to a single, unambiguous line:

```markdown
**Verdict:** ✅ all requirements addressed
```

Or:

```markdown
**Verdict:** ⚠️ gaps found — see findings above
```

And in the orchestrator, the integrity gate pattern:
```bash
VERDICT_COUNT=$(echo "$OUTPUT" | grep -cP '^\*\*Verdict:\*\* [✅⚠️]' || true)
[ "$VERDICT_COUNT" -eq 1 ] || { echo "FATAL: verdict count = $VERDICT_COUNT"; exit 1; }
```

## Related

- See `ticket-auto/SKILL.md` Step 5a for the verdict-line integrity gate.
- See `ticket-pr-review/SKILL.md` for the PR review output format.
