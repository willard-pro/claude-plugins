## ADDED Requirements

### Requirement: Pipeline re-fetches Linear comments after gate approval
After gate-hold approval is detected (`approved` label present), the pipeline SHALL fetch all current Linear comments before proceeding to implementation. This fetch happens in Step 3.5, which runs on every resume from `STEP_3_5`.

#### Scenario: Comments fetched on first approval resume
- **WHEN** detect-resume finds `GATE_HELD` and the `approved` label is present
- **THEN** RESUME_STEP is set to `STEP_3_5` and ticket-auto executes Step 3.5 before Step 4

#### Scenario: Comments fetched on each re-approval resume
- **WHEN** a previous reconciliation cycle removed `approved` and the user re-adds it and re-runs the pipeline
- **THEN** detect-resume again routes to `STEP_3_5` and a fresh comment fetch occurs

#### Scenario: Auto-approved simple tickets bypass reconciliation
- **WHEN** a ticket is auto-approved (simple + auto/semi-auto autonomy mode)
- **THEN** RESUME_STEP is `STEP_4` (via `GATE|gate|done|` log pattern) and Step 3.5 is never entered

---

### Requirement: Open questions block implementation until answered
If the pipeline posted open questions in the appraisal comment AND any of those questions remain unanswered in subsequent Linear comments, the pipeline SHALL block implementation and require re-approval.

#### Scenario: Unanswered open questions halt the pipeline
- **WHEN** `## Open Questions` in notes.md contains non-empty bullets AND no post-appraisal comment provides a concrete answer to at least one of those questions
- **THEN** Step 3.5 sets `HOLD_REASON=unanswered_questions`, posts an amendment comment listing the unanswered questions, removes the `approved` label via `re-claim`, and stops

#### Scenario: All questions answered allows proceed
- **WHEN** every bullet in `## Open Questions` has been concretely addressed in a post-appraisal comment
- **THEN** the unanswered-questions hold condition is not triggered

#### Scenario: Vague reply does not count as an answer
- **WHEN** a post-appraisal comment replies to a question with vague language ("we'll see", "TBD", "maybe")
- **THEN** the question is still considered unanswered and the hold condition applies

#### Scenario: No open questions means condition does not apply
- **WHEN** `## Open Questions` in notes.md is empty or contains only placeholder text ("None", "—")
- **THEN** the unanswered-questions hold condition is skipped entirely

---

### Requirement: New user comments are incorporated into the plan artifact
If user comments exist after the last pipeline boundary comment (appraisal comment or last amendment comment), the pipeline SHALL incorporate their content into the plan artifact before implementation and require re-approval.

#### Scenario: New comment triggers plan amendment and re-approval
- **WHEN** one or more user comments exist after `LAST_RECONCILE_AT` that are not pipeline-authored comments
- **THEN** the pipeline amends the plan artifact (simple-fix.md or openspec tasks.md), appends an `## Amendment #N` section, posts an `**Amendment cycle #N**` Linear comment, removes `approved` via `re-claim`, and stops

#### Scenario: Pipeline comments are excluded from user comment detection
- **WHEN** the only post-boundary comments start with `**Ticket appraised**` or `**Amendment cycle #`
- **THEN** they are not treated as unprocessed user comments

#### Scenario: New questions from amendment are posted and added to notes.md
- **WHEN** incorporating user comments raises an unresolvable question
- **THEN** the new question is appended to `## Open Questions` in notes.md and included in the amendment Linear comment under "New questions raised by this cycle"

---

### Requirement: Each held reconciliation cycle removes approved and requires re-approval
After a reconciliation cycle determines a hold is needed, the pipeline SHALL remove the `approved` label using the `re-claim` trigger, post a summary comment, and stop execution.

#### Scenario: `approved` label removed via re-claim trigger
- **WHEN** Step 3.5 determines a hold is required (unanswered questions or new comments)
- **THEN** `flow.sh "{TICKET-ID}" "re-claim"` is called, removing the `approved` label without changing the ticket's Linear state

#### Scenario: re-claim is idempotent when approved is already absent
- **WHEN** `re-claim` is called but the `approved` label is already absent
- **THEN** flow.sh exits 0 with no Linear mutation (existing idempotency behavior)

#### Scenario: Amendment comment posted before stopping
- **WHEN** a reconciliation cycle holds
- **THEN** a comment starting with `**Amendment cycle #N**` is posted to Linear summarizing changes incorporated and questions outstanding

---

### Requirement: Clean reconciliation passes through to implementation
When no hold conditions are active (all questions answered, no unprocessed comments), Step 3.5 SHALL log a clean pass and continue to Step 4 (implement) without posting a comment or removing labels.

#### Scenario: Clean pass on first resume with no feedback
- **WHEN** the user adds `approved` with no additional comments and no open questions exist in notes.md
- **THEN** Step 3.5 logs `|GATE|reconcile|done|clean` and continues to Step 4

#### Scenario: Clean pass after all feedback incorporated
- **WHEN** all previous user comments have been incorporated (timestamp before LAST_RECONCILE_AT) and all questions are answered
- **THEN** Step 3.5 logs `|GATE|reconcile|done|clean` and continues to Step 4

---

### Requirement: detect-resume outputs RECONCILE_CYCLE count
detect-resume.sh SHALL output a `RECONCILE_CYCLE` field counting the number of completed-and-held reconciliation cycles from the pipeline log, so the orchestrator can number amendment iterations correctly.

#### Scenario: RECONCILE_CYCLE is zero before any reconciliation
- **WHEN** no `|GATE|reconcile|done|cycle#` entries exist in the log
- **THEN** `RECONCILE_CYCLE` is output as `0`

#### Scenario: RECONCILE_CYCLE increments per held cycle
- **WHEN** two held reconciliation cycles have completed (each writing `|GATE|reconcile|done|cycle#N|...`)
- **THEN** `RECONCILE_CYCLE` is output as `2` and the next cycle is numbered `#3`

#### Scenario: Clean-pass log entry does not increment counter
- **WHEN** a clean reconcile logs `|GATE|reconcile|done|clean` and a subsequent crash re-enters Step 3.5
- **THEN** `RECONCILE_CYCLE` reflects only the held cycles, not the clean pass
