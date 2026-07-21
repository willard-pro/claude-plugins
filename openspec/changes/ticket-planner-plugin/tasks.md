## 1. Reconcile the tracker before planning implementation

- [x] 1.1 Audit `ticket-planner-implementation.md` (dated 2026-07-09) against the code as it actually stands; Parts 4 and part of 5 are marked TODO but shipped 2026-07-15
- [x] 1.2 Rewrite the tracker to reflect the filesystem, and record that the filesystem is authoritative where the two disagree
- [x] 1.3 Confirm which consumption-side specs are already satisfied so this change does not rebuild working code

## 2. Plugin scaffold

- [x] 2.1 Create the `ticket-planner` plugin: manifest, marketplace entry, directory layout following the fleet-controller precedent
- [x] 2.2 Implement the entry point accepting either an idea or an existing initiative identifier, reporting which it received
- [x] 2.3 Define the append-only state log format and the initiative state directory layout under `${REPOS_ROOT}/.ticket-auto/initiatives/{ID}/`
- [x] 2.4 Implement the phase router: reads the state log to derive position, dispatches phases, records outcomes, performs no reasoning of its own
- [x] 2.5 Implement resume: derive position from the log alone, ignoring an incomplete trailing entry
- [x] 2.6 Add tests: position derivable from log by a cold process; partial trailing write ignored; unknown initiative identifier reported rather than silently created

## 3. Close the integration gaps (small, independently valuable — do before the state machine)

- [x] 3.1 Implement the feedback writer per the existing `planner-feedback-write` spec in `ticket-planner-feedback-loop`: a post-implement hook emitting `META|planner-feedback` lines to the pipeline log
- [x] 3.2 Verify `fleet-feedback.sh:99-271` aggregates the emitted lines into per-initiative feedback JSON — this is the feedback loop's first real input
- [x] 3.3 Add the `--from-planned` flag to ticket-auto per the `fleet-controller-dispatch` proposal, and have dispatch pass it in spawn-queue entries
- [x] 3.4 Wire `_fleet_scan_initiative_dispatch` at `fleet-detect.sh:620-624` to invoke `fleet_dispatch_initiative` instead of warning only
- [x] 3.5 Ensure auto-dispatch respects `FLEET_MAX_CONCURRENT` and `FLEET_DRY_RUN`, and does not duplicate already-queued entries across cycles
- [x] 3.6 Verify the human approval gate still stops every auto-dispatched ticket — automating dispatch must not automate approval
- [x] 3.7 Confirm `planned-entry-gate` remains dormant and unimplemented by decision; record that as an explicit choice, not an oversight
- [x] 3.8 Add tests: dispatch failure for one initiative does not abort the detection cycle; repeated cycles do not double-enqueue

## 4. Generation phases (build the output end first, so it can be proven against the real pipeline)

- [ ] 4.1 Implement Epic Generation: create the initiative epic with its execution-state label, recording intent before creation
- [ ] 4.2 Implement Story Generation as a distinct phase (collapse into Ticket Generation later if the distinction proves empty — see design open question)
- [ ] 4.3 Implement Ticket Generation producing child tickets in backlog with the planned label, initiative label, and type label where determined
- [ ] 4.4 Derive per-ticket confidence from concrete generation signals — services identified, symbols resolved, prior art found — never a uniform constant
- [ ] 4.5 Emit dependencies as blocked-by labels and validate the dependency set is acyclic before creating any ticket
- [ ] 4.6 Write per-ticket artifacts where the existing artifact resolver locates them
- [ ] 4.7 Validate every generated ticket with `planned-ticket-check.sh` before creation; do not create a ticket that fails
- [ ] 4.8 Implement idempotent creation: record intent before side effects, check existence by deterministic identifier before creating
- [ ] 4.9 Add interruption tests at every entity-creating phase: interrupt between intent and creation, and between creation and completion — exactly one entity must exist after resume
- [ ] 4.10 Add tests: cyclic dependency set creates nothing and reports the cycle; confidence varies across tickets with differing evidence

## 5. First real end-to-end proof (before building upstream phases)

- [ ] 5.1 Generate one initiative from hand-supplied input, bypassing the not-yet-built reasoning phases
- [ ] 5.2 Verify its tickets pass `planned-ticket-check.sh`, take the appraise fast path, and pass the planner gate checks without a gate-stop
- [ ] 5.3 Run one generated ticket through the real pipeline to completion
- [ ] 5.4 Correct any place the frozen contracts turned out to encode an assumption that real output violates

## 6. Upstream reasoning phases

- [ ] 6.1 Implement Appraisal: interpret the idea and establish initiative scope
- [ ] 6.2 Implement Discovery: explore the affected repositories and gather context
- [ ] 6.3 Implement Architecture: determine the technical approach
- [ ] 6.4 Implement Proposal: produce the initiative proposal artifact
- [ ] 6.5 Implement Review: critique the proposal (internal by default, configurable hold — see design open question)
- [ ] 6.6 Implement Consensus: resolve review findings into a settled plan
- [ ] 6.7 Implement OpenSpec: emit the specification artifacts the generation phases consume
- [ ] 6.8 Add tests: out-of-order transitions refused; phase failure halts the run recoverably and resumes at the failed phase

## 7. Execution and completion

- [ ] 7.1 Implement Execution: label the epic for execution and hand off to auto-dispatch from group 3
- [ ] 7.2 Monitor progress through the feedback the writer now produces
- [ ] 7.3 Implement Completed as a terminal phase permitting no further transition

## 8. Re-planning

- [ ] 8.1 Implement Regenerate-flag detection; read feedback only when the flag is present
- [ ] 8.2 Ingest aggregated feedback runs and apply drift to regenerated confidence
- [ ] 8.3 Distinguish absent feedback from unreadable feedback rather than treating both as none
- [ ] 8.4 Restrict regeneration to undispatched backlog tickets; leave dispatched, in-progress, and completed tickets unchanged and report them as such
- [ ] 8.5 Verify the dependency set remains acyclic and resolvable when regeneration touches only part of an initiative
- [ ] 8.6 Record the triggering flag and the feedback runs considered in the state log
- [ ] 8.7 Add tests: unflagged run reads no feedback; regeneration does not modify an in-flight ticket; systematic overconfidence lowers regenerated confidence

## 9. Full end-to-end verification (requires fleetd)

- [ ] 9.1 Confirm `fleetd-supervisor-daemon` has landed — headless spawn is required for auto-dispatch to produce running workers
- [ ] 9.2 Run one business idea through all twelve phases to a Linear epic with dependency-ordered children
- [ ] 9.3 Verify auto-dispatch enqueues eligible children in dependency and priority order, and that blocked children wait
- [ ] 9.4 Verify each dispatched ticket stops at the human approval gate
- [ ] 9.5 Carry one child through to merged code and verify feedback is emitted, aggregated, and readable
- [ ] 9.6 Verify the dexter Initiatives tab reflects each step against real planner output rather than fixtures

## 10. Documentation

- [ ] 10.1 Write plugin documentation covering the twelve phases, state representation, resume semantics, and the contracts the planner produces against
- [ ] 10.2 Document the operator-facing idea-to-tickets flow, including what auto-dispatch does and what the approval gate still holds
- [ ] 10.3 Record the decision that `planned-entry-gate` stays dormant, and what would have to be true to revisit it
