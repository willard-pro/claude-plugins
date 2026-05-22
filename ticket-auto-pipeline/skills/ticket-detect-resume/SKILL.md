---
name: ticket-detect-resume
description: Private helper — called inline by ticket-auto only. Reads the pipeline log for a ticket, determines where the last run got to, and emits a DETECT_RESUME_RESULT block with RESUME_STEP (which ticket-auto step to jump to) and per-sub-skill --from-step values. All *_FROM fields default to empty string when no prior progress exists, meaning the sub-skill starts from its first step.
---

# ticket-detect-resume

**Private helper skill.** Do not invoke directly — called inline by `ticket-auto` Step 0.7. No sub-agent spawn needed.

## Usage

```
/ticket-detect-resume <TICKET-ID>
```

## Execution

This skill is a thin wrapper around `detect-resume.sh`. All log parsing, resume point detection, and context restoration are handled deterministically by the script.

```bash
bash ~/.claude/skills/ticket-detect-resume/detect-resume.sh "<TICKET-ID>"
```

The script emits a `DETECT_RESUME_RESULT` block with 18 fields: `RESUME_STEP`, `APPRAISE_FROM`, `REPRODUCE_FROM`, `EXEC_FROM`, `IMPLEMENT_FROM`, `MAINTENANCE_FROM`, `DOCUMENT_FROM`, `VERIFY_FROM`, `PR_REVIEW_FROM`, `PR_ITERATE_FROM`, `TICKET_DIR`, `COMPLEXITY`, `ARTIFACT_TYPE`, `BRANCH`, `TICKET_TITLE`, `VERIFY_ATTEMPTS`, `ITERATION`, `RECONCILE_CYCLE`, `PR_FEEDBACK_CYCLE`.
