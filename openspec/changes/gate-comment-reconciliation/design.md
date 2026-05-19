## Context

The `ticket-auto` orchestrator gates complex tickets at Step 3, halts, and writes `|GATE|gate|fail|held` to the pipeline log. When the user adds `approved` in Linear and re-runs the pipeline, `detect-resume.sh` detects `GATE_HELD` + approved label and currently jumps straight to `STEP_4` (implement). No comment re-fetch occurs between gate-stop and implement-spawn. Two silent failures result: (a) open questions the pipeline posted go unanswered and are never checked; (b) user guidance comments added during the hold window are discarded.

The pipeline currently identifies open questions via `## Open Questions` in `notes.md`, written during appraise and reflected in the appraisal Linear comment. The appraisal comment is identifiable by its `**Ticket appraised**` prefix. Linear's comment API does not expose a bot/human author flag — only the `user.id`/`user.name` tied to the API key.

The two `state-machine.json` files (repo root and `skills/ticket-flow/`) are identical copies. Both must stay in sync.

## Goals / Non-Goals

**Goals:**
- Re-read all Linear comments every time the pipeline resumes from gate-hold
- Block on unanswered open questions, even if `approved` label is present
- Incorporate unprocessed user comments into the plan artifact before implementation
- Loop: each held iteration removes `approved`, posts an amendment comment, requires re-approval
- Track cycle number in detect-resume output for log context

**Non-Goals:**
- No changes to the appraise, exec, or implement sub-skills
- No changes to `flow.sh` internals — the new `re-claim` trigger is handled by existing trigger-dispatch logic
- No bot-vs-human comment detection beyond content prefix matching
- No changes to how auto-approved simple tickets are handled (auto-approved path never enters Step 3.5). Simple tickets in manual mode DO pass through Step 3.5 — the manual-mode gate writes `|GATE|gate|fail|held: manual mode`, which routes through GATE_HELD → STEP_3_5, giving manual-mode users the same comment reconciliation as complex tickets.

## Decisions

### D1: Resume point is `STEP_3_5`, not patching within GATE_HELD handler

**Decision:** detect-resume.sh emits `RESUME_STEP="STEP_3_5"` when gate was held and `approved` label is found. The orchestrator's Step 3.5 then runs, and if clean, falls through to Step 4.

**Alternative considered:** Inline the reconciliation logic inside the GATE_HELD handler in detect-resume.sh (bash). Rejected — detect-resume.sh is deterministic bash; semantic judgment over comment content requires LLM reasoning, which only the orchestrator (SKILL.md) can provide.

**Alternative considered:** Add a `STEP_3_5` entry to the Level 1 if-elif chain by detecting `|GATE|reconcile|` log entries. Rejected — the GATE_HELD post-handler already does a live label check, and routing through a new Level 1 pattern would duplicate that check. The GATE_HELD handler is the right owner.

### D2: `re-claim` uses `"to": null` (label-only trigger)

**Decision:** The `re-claim` trigger is defined with `"to": null` in `state-machine.json`, making it a pure label mutation (removes `approved`, no state change). This matches the existing `implement-outcome` and `needs-info` patterns.

**Alternative considered:** `"to": "Approve"` (same-state transition). Rejected — flow.sh's behavior for same-state transitions is untested; `"to": null` is an established pattern that avoids any state-resolution edge cases and is explicitly supported.

### D3: Pipeline comments identified by content prefix, not author

**Decision:** Appraisal comment = first comment starting with `**Ticket appraised**`. Reconciliation comments = comments starting with `**Amendment cycle #`. All other post-boundary comments are treated as user comments.

**Alternative considered:** Filter by Linear user ID matching the API key owner. Rejected — the user ID corresponding to `LINEAR_API_KEY` would require an extra `get_me` call and adds fragility if the key changes. Content-prefix matching is deterministic and visible.

### D4: Clean-pass after crash is handled by re-running Step 3.5 (idempotent)

**Decision:** If a crash happens after a clean reconcile but before implement starts, detect-resume routes back to STEP_3_5. The reconciliation re-runs, finds no new comments or unanswered questions, and falls through to Step 4. No Level 1 log pattern for `reconcile|done|clean` is needed.

**Alternative considered:** Add `grep '^[^|]*|GATE|reconcile|done|clean'` as a Level 1 pattern → `STEP_4`. Rejected — this adds complexity for a rare crash window. The idempotent re-run costs one extra `get_comments` call, which is acceptable.

### D5: Semantic judgment for "answered" vs "unanswered" questions

**Decision:** The orchestrator (LLM) reads each open question bullet and scans post-appraisal comments for concrete resolution. A clear answer, decision, or explicit dismissal = answered. Vague replies = unanswered.

**Alternative considered:** Keyword/pattern matching (e.g., comment contains the question text + a reply). Rejected — open questions are natural language; semantic matching is more robust and aligns with how the rest of the pipeline uses LLM judgment.

## Risks / Trade-offs

- **Timestamp comparison for comment boundaries** → Mitigation: ISO 8601 timestamps are lexicographically sortable; string comparison is sufficient. Edge case: two comments at the same second — the `LAST_RECONCILE_AT` check uses "strictly after," so same-second comments are re-processed (conservative, not a bug).

- **Potential for extended loops if the pipeline keeps generating new questions** → Mitigation: New questions only arise if the LLM finds unresolvable issues in user comments. In practice this is bounded by the quality of user feedback. No hard loop cap is imposed — the user controls the cycle by approving or not.

- **`re-claim` called when `approved` is already absent (double-halt)** → Mitigation: flow.sh's idempotency check exits 0 with no mutation when labels wouldn't change. The orchestrator should not reach `re-claim` without a preceding `approved` label, but the idempotency guard makes it safe regardless.

- **Both state-machine.json copies must stay in sync** → Mitigation: Plan explicitly calls out both paths. If install.sh copies the file, only the source file needs changing and install propagates it. Both are listed in the task checklist.

## Migration Plan

No migration required. The change is backward-compatible with in-flight tickets:

- Tickets already past GATE_HELD (in implement or later phases) are unaffected — their `RESUME_STEP` will resolve to `STEP_4` or later via existing Level 1 patterns, never reaching STEP_3_5.
- Tickets currently halted at GATE_HELD with `approved` label will route through Step 3.5 on next resume. If no comments were added since the appraisal comment and no open questions exist, the reconcile is immediately clean and proceed to implement.
- The sentinel invalidation from editing `state-machine.json` triggers a config re-validation on next run — expected behavior.

## Open Questions

None — all design decisions are resolved.
