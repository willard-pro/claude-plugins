# RETURN_INCOMPLETE — Gate-Warn Analysis Template

## Pattern

An implement agent returned and reported `done`, but `lib/return-completeness-check.sh`
found unchecked `- [ ]` boxes remaining in the ticket's openspec `tasks.md`. In Phase 1
this is **warn-only** — it never flips the phase result from `done` to `fail` and is
logged via `|META|gate-warn|info|` (not `gate-stop`), so it does not halt the pipeline
or summon the fleet controller.

This template exists to support two uses:
1. Investigating a specific ticket's `RETURN_INCOMPLETE` warning while Phase 1 is live.
2. Reviewing the aggregate `{GATE_WARN_TOTAL}` false-positive rate before flipping the
   gate from warn-only to enforce (Phase 2 — see `openspec/changes/pipeline-integrity`).

## What to Look For

In `~/.claude/skills/lib/return-completeness-check.sh`:

1. **Resolution accuracy**: did the script find the *correct* `tasks.md`? A false
   positive here (wrong change dir resolved, stale ticket-id substring match against
   an unrelated change directory) looks identical to a genuine incomplete return.
2. **Count correctness**: does the reported `UNCHECKED_COUNT`/`UNCHECKED_ITEMS` match
   what's actually in the file? Check for encoding issues (`- [ ]` vs `-   [ ]` vs tab
   indentation) that the `grep -c '^- \[ \]'` pattern would miss or over-match.

In `~/.claude/skills/ticket-auto/SKILL.md` (STEP_4):

3. **Scoping**: was this ticket actually an openspec ticket (`{ARTIFACT_TYPE}=openspec`)?
   A simple-fix ticket should never reach this gate in Phase 1 (decision D1) — if one
   did, the `{ARTIFACT_TYPE}` extraction in `detect-resume.sh` may be wrong.
4. **Genuine incompleteness**: separately from the gate itself, was the implement
   agent's work actually incomplete? If the boxes are genuinely unchecked and the
   underlying work is missing, this is the gate doing its job — not a bug to fix.

## Minimal Fix Pattern

If the false positive is a resolution bug (wrong tasks.md found), tighten the match
in `_find_tasks_file`:

```bash
# Prefer an exact ticket-id prefix match over a loose substring match
case "$(basename "$change_dir" | tr '[:upper:]' '[:lower:]')" in
"${ticket_lower}--"*) ...
```

If the false positive is a genuine completion the agent simply forgot to check off,
this is not a gate bug — it is exactly the signal Phase 1 exists to surface. Do not
"fix" the gate to stop reporting it; instead this data point should count toward the
Phase 2 false-positive review (a real completion with unchecked boxes is a template
adoption issue, not a detection issue).

## Related

- See `openspec/changes/pipeline-integrity/design.md` (Decisions section) for why this
  gate ships warn-only first and how the Phase 2 enforce flip is gated on this
  telemetry being clean.
- See `pipeline-log-format.md` for the `gate-warn` channel (distinct from `gate-stop`).
