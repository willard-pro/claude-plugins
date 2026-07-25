# Must-Run Tests

Deferred test items extracted from archived openspec changes. Run these
when a clean environment / live pipeline is available.

---

## ticket-auto-integrity-hardening

- [ ] **9.2** — Add baseline fixture tests for 8 untested deterministic audit pre-filter libs:
  `audit-ac-testability.sh`, `audit-comment-guard.sh`, `audit-overlap-check.sh`,
  `audit-repro-check.sh`, `audit-scope-check.sh`, `audit-size-check.sh`,
  `audit-test-data-check.sh`, `audit-title-similarity.sh`.
  *(audit libs are stable; test coverage not blocking)*

- [ ] **10.1** — Run complete `lib/tests/` and `skills/ticket-flow/tests/` suites
  end to end. Confirm all pass including false-green fixtures corrected in Increment A.
  *(requires clean environment setup)*

---

## shared-branch-resolution

- [ ] **12.3** — Manual-override: run `/ticket-auto <ID> --branch epic/test-x` on a
  scratch ticket, confirm correct branch used.

- [ ] **12.4** — Crash-resume: interrupt mid-implement, resume **without** `--branch`,
  confirm run stays on the previously-resolved branch (doesn't fall back to default).

- [ ] **12.5** — Regression: ticket with no epic directive and no `--branch` flag
  branches from and targets the default base (`develop`).

---

## observability-diagnostics-pipeline

*All require live pipeline run.*

- [ ] **2.5** — Run pipeline E2E. Verify heartbeat log contains `agent-progress`
  entries during agent execution. Verify at least one decision heartbeat entry
  written by agent via `hb-wrap.sh`.

- [ ] **4.1** — Run full pipeline on test ticket. Verify: no pipe-character corruption
  in pipeline log, heartbeat log has entries from both orchestrator and agent,
  error paths produce correct error codes.

- [ ] **4.2** — Run `detect-resume.sh` against completed pipeline log. Confirm all 19
  routing variables extracted correctly. Confirm no false zombie detections.

- [ ] **4.3** — Simulate zombie: kill agent mid-execution, wait 6 minutes, run
  `detect-resume.sh`. Confirm zombie detection triggers, resume point correct.

- [ ] **4.4** — Run `validate-linear-config.sh`. Confirm no regressions in state
  machine consistency.

---

## retro-github-issues

- [ ] **8.2** — Run `/ticket-retro --window 7d --post-to-github` on test data.
  Verify issues created for codes with count ≥ 2.

- [ ] **8.3** — Run again with same data. Verify no duplicate issues created;
  existing issues receive evidence comments.

- [ ] **8.4** — Run with `gh` logged out. Verify graceful warning, proposal still
  written, exit code 0.

- [ ] **8.5** — Verify created issue format matches manual issues #83–#88 (same
  sections, same level of detail).

- [ ] **8.6** — Run with `--post-to-linear --post-to-github` together. Verify both
  steps execute independently.

---

## ticket-planner-exploration

- [ ] **7.4** — Write `test-exploration-feedback-write.sh`. Verify `missed_symbols`
  and `false_traces` populated from diff.

### Spec cleanup (cross-reference updates)

*Note: The target openspec changes referenced below (ticket-planner-integration,
ticket-planner-enrichment, ticket-appraise-fast-path) are already archived.
The items below may need target paths adjusted to the archive or main specs.*

- [ ] **6.5** — Update determinism-full-audit spec: add exploration depth mismatch
  detection to audit scope.

- [ ] **6.6** — Update planner-context-block spec: add Schema-Version 2 fields.

- [ ] **6.7** — Update appraise-fast-path spec: add exploration depth consumption
  scenarios.

- [ ] **6.8** — Update planner-feedback-write spec: add exploration accuracy fields.

---

## ticket-worktree-isolation

- [ ] **11.2** — Single ordinary ticket E2E. Confirm worktree appears, all five
  phases run inside it, worktree released after merge.

- [ ] **11.3** — Two concurrent tickets on same repo. Confirm neither observes the
  other's branch or files, no merge conflicts.

- [ ] **11.4** — Crash-resume: kill mid-implement, resume. Confirm existing worktree
  reused (not recreated).

- [ ] **11.5** — Wrong-branch guard: manually check out different branch in worktree,
  resume. Confirm loud error, not silent wrong-branch execution.

- [ ] **11.6** — Confirm `release_worktree` runs after merge and `git worktree list`
  is clean. *(requires live pipeline run)*
