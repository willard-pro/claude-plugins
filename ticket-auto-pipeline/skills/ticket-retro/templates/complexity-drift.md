# complexity-drift — Pattern Analysis Template

## Pattern

Systematic misprediction of ticket complexity. Over multiple runs, the appraisal phase consistently declares tickets as `simple` when they turn out `Rough` or `Hard`, or declares `complex` when they turn out `Smooth`. This indicates the appraisal heuristics need tuning.

## What to Look For

In `~/.claude/skills/ticket-appraise/SKILL.md`:

1. **Complexity sweep logic**: The skill's "Complexity Sweep" step (typically Step 1) inspects the ticket description and codebase to classify complexity. What signals does it weigh?
2. **Scoring criteria**: What makes a ticket `simple` vs `complex`? Look for keywords like "multi-service", "cross-layer", "new API", "schema change", "migration".
3. **False negatives** (declared simple, actual Rough/Hard): These hurt the most — the pipeline auto-approves a ticket that needed human review. What signals were missed?
4. **False positives** (declared complex, actual Smooth): These add friction — the pipeline holds a ticket that could have auto-completed. Are the criteria too aggressive?

## Minimal Fix Pattern

Tuning the classification heuristics:

```markdown
## Complexity Sweep

**Simple** if ALL of:
- Changes confined to a single service
- No new API endpoints
- No database schema changes
- No new dependencies

**Complex** if ANY of:
- Changes span 2+ services
- New API endpoint or route
- Database migration required
- New external dependency
- Changes to auth/authz logic
```

## Related

- See `ticket-appraise/SKILL.md` for the complexity sweep implementation.
- Accuracy metric is tracked in `retro.sh` output as `complexity_accuracy`.
