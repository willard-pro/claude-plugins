## Why

After the gate halts for complex tickets, the pipeline resumes at implement the moment the `approved` label is detected — it never re-reads Linear comments. Open questions posted in the appraisal comment are silently ignored, and user guidance added during the hold window never reaches the plan. This creates a trust gap: users believe their comments shape implementation, but the pipeline discards them.

## What Changes

- The gate-hold resume point shifts from `STEP_4` (implement) to `STEP_3_5` (reconciliation) in `detect-resume.sh`
- A new **Step 3.5 — Comment Reconciliation** is inserted in `ticket-auto` between gate and implement
- Step 3.5 blocks on unanswered open questions and incorporates new user comments into the plan artifact before proceeding
- Each blocked iteration removes the `approved` label (via new `re-claim` trigger), posts an amendment comment, and requires re-approval — looping until clean
- `detect-resume.sh` gains a `RECONCILE_CYCLE` output field to number amendment iterations
- A new `re-claim` trigger is added to `state-machine.json` (label-only, no state change) to remove `approved` without transitioning state

## Capabilities

### New Capabilities

- `comment-reconciliation`: Post-gate comment scan and plan amendment loop that checks for unanswered open questions and unprocessed user comments before implementation begins, looping with re-approval until clean

### Modified Capabilities

<!-- None — no existing spec-level requirements change -->

## Impact

- `ticket-auto-pipeline/skills/ticket-auto/SKILL.md` — new Step 3.5 section, updated dispatch table, updated Step 2.5 skip guard
- `ticket-auto-pipeline/skills/ticket-detect-resume/detect-resume.sh` — resume routing and new output field
- `ticket-auto-pipeline/skills/ticket-flow/state-machine.json` — new `re-claim` trigger
- `ticket-auto-pipeline/state-machine.json` (repo-root copy) — same change, both copies are kept in sync
- No changes to `flow.sh`, `linear-api.sh`, or any sub-skill other than `ticket-auto`
