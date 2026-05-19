## 1. State Machine — re-claim trigger

- [x] 1.1 Add `re-claim` trigger to `ticket-auto-pipeline/skills/ticket-flow/state-machine.json` with `"to": null, "adds": [], "removes": ["approved"]`
- [x] 1.2 Apply the identical change to `ticket-auto-pipeline/state-machine.json` (repo-root copy)
- [x] 1.3 Verify both files are identical after the change (`diff` the two copies)

## 2. detect-resume.sh — routing and output

- [x] 2.1 Change line 109 from `RESUME_STEP="STEP_4"` to `RESUME_STEP="STEP_3_5"` in `ticket-auto-pipeline/skills/ticket-detect-resume/detect-resume.sh`
- [x] 2.2 Update the `hb_gate` message on line 110 to reference `STEP_3_5 (comment reconciliation)`
- [x] 2.3 Add `RECONCILE_CYCLE` extraction after line 154 (end of PR_ITERATE_FROM block): `grep -c '^[^|]*|GATE|reconcile|done|cycle#'` pattern
- [x] 2.4 Add `RECONCILE_CYCLE: ${RECONCILE_CYCLE}` to the output block (after ITERATION line)

## 3. ticket-auto SKILL.md — dispatch table and skip guard

- [x] 3.1 Add `STEP_3_5 | Step 3.5 (Comment Reconciliation)` row to the entry-point dispatch table (between STEP_3 and STEP_4 rows, lines 258–268)
- [x] 3.2 Update the Step 2.5 skip guard from `RESUME_STEP >= STEP_4` to `RESUME_STEP >= STEP_3_5` (line 368)

## 4. ticket-auto SKILL.md — Step 3.5 section

- [x] 4.1 Insert the `## Step 3.5 — Comment Reconciliation` heading and cycle counter init (`RECONCILE_N`) between Step 3 and Step 4
- [x] 4.2 Write Step 3.5a — fetch all comments via Linear access strategy (bash `get_comments` / MCP fallback)
- [x] 4.3 Write Step 3.5b — identify appraisal comment (`**Ticket appraised**` prefix) and last amendment comment (`**Amendment cycle #` prefix) to compute `LAST_RECONCILE_AT` and `UNPROCESSED_COMMENTS`
- [x] 4.4 Write Step 3.5c — read `## Open Questions` from notes.md into `OPEN_QUESTIONS_LIST`
- [x] 4.5 Write Step 3.5d — evaluate hold conditions: unanswered questions (semantic judgment) and unprocessed comments
- [x] 4.6 Write Step 3.5e — amendment logic: resolve `PLAN_PATH` from log, amend plan artifact, update notes.md Open Questions (mark resolved, append new)
- [x] 4.7 Write Step 3.5f — post `**Amendment cycle #N**` Linear comment, call `flow.sh re-claim`, write `|GATE|reconcile|done|cycle#N|held:` log entry, stop with user-facing report
- [x] 4.8 Write Step 3.5g — clean pass: write `|GATE|reconcile|done|clean` log entry, hb calls, continue to Step 4

## 5. Verification

- [x] 5.1 Run `diff ticket-auto-pipeline/state-machine.json ticket-auto-pipeline/skills/ticket-flow/state-machine.json` — expect no output
- [x] 5.2 Grep detect-resume.sh for `STEP_3_5` — expect matches on lines 109 and 110
- [x] 5.3 Grep detect-resume.sh for `RECONCILE_CYCLE` — expect extraction and output lines both present
- [x] 5.4 Grep ticket-auto SKILL.md for `STEP_3_5` — expect matches in dispatch table, Step 2.5 guard, and Step 3.5 body
- [x] 5.5 Grep ticket-auto SKILL.md for `reconcile|done|clean` — expect match in Step 3.5g
- [x] 5.6 Grep state-machine.json for `re-claim` — expect match in both copies

## 6. Code extraction — de-duplicate and centralize

- [x] 6.1 Add `normalize_comments()` to `lib/linear-api.sh` — normalize comment JSON from bash `get_comments` or MCP fallback to flat array
- [x] 6.2 Add `resolve_plan_path()` to `lib/ticket-dir.sh` — consolidate log grep → find simple-fix.md → ls openspec fallback chain
- [x] 6.3 Create `lib/reconcile-comments.sh` — extract comment boundary detection from Step 3.5b into standalone testable script
- [x] 6.4 Update SKILL.md Step 3.5a to call `normalize_comments` instead of inline jq
- [x] 6.5 Update SKILL.md Step 3.5b to call `reconcile-comments.sh` instead of inline boundary detection
- [x] 6.6 Update SKILL.md Step 2.5 to call `resolve_plan_path` instead of duplicated grep/find/ls
- [x] 6.7 Update SKILL.md Step 3.5e to call `resolve_plan_path` instead of duplicated grep
- [x] 6.8 Verify no leftover duplicated patterns in SKILL.md (old grep, old jq normalization)
- [x] 6.9 Run functional tests on reconcile-comments.sh (first cycle, multi-cycle, clean pass)
- [x] 6.10 Run functional tests on normalize_comments (array, .data.issue.comments.nodes, .data.comments wrappers)
