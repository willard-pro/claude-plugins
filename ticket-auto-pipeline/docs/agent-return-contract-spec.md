# Agent Return Contract & Completion Validator — Design Note

> **Superseded by:** `openspec/changes/pipeline-integrity/design.md` (2026-07-05).
> The tasks.md completeness gate (Phase 1, shipped 2026-07-05) and simple-fix
> Completion Checklist gate (Section 2, shipped 2026-07-05) close the most
> critical false-done hole first — agent self-reported done is now independently
> verified before the router commits the phase.
> Full return contract (per-agent-type validators, verify pass-evidence check,
> `RESULT: partial` routing) deferred to Phase 6 — conditional on Phase 1/2
> telemetry showing false dones on paths the completeness gate cannot see.
> See `pipeline-integrity-consolidated-plan` memory for full roadmap.

**Date:** 2026-07-04
**Status:** Superseded (2026-07-05)
**Related:** `handoff-block-spec.md` (converges on one structured object — see §Relationship),
`prescan-artifacts-assessment` (memory) #5 (self-report failure mode),
`lib/spawn-helper.sh` (`spawn_capture` / `capture_agent_result`),
`lib/gate-check.sh`, `lib/outcome-label-check.sh`, `lib/prescan-verify.sh` (existing
observable-state validators)

## Problem

The router captures each agent's return text but never validates it. Confirmed:
`spawn_capture` persists `AGENT_RESULT` to `-{phase}-agent.log`, but the router is
**stateless** — every routing decision comes from `detect-resume.sh` reading the pipeline
log, and the terminal `done`/`fail` status is written by the agent *itself*. So:

- The return is free-form prose — no uniform shape for router/retro/fleet-controller.
- Nothing checks that the agent actually **addressed everything requested**. A phase can
  write `|done|` to the log while silently skipping requirements (the fan-out bypass in
  `prescan-artifacts-assessment` #5 is exactly this: `|done|` written, work not done).

## The trap (read before designing)

The whole codebase already made this call and landed on one rule: **validate observable
state, never the agent's self-report.** Every existing gate proves it —
`gate-check.sh` checks artifacts on disk, `outcome-label-check.sh` checks the Linear
label, `prescan-verify.sh` checks the doc files, the REMEDIATION_BRIEF check greps for the
closing marker. None reads an agent's "I did it" claim.

A validator that trusts a self-reported "✅ addressed AC1, AC2, AC3" block reintroduces the
exact failure mode this codebase already got burned by. So the return block's value is
**not** the claim. Its value is giving a bash validator a *machine-readable claim to diff
against reality*. Mismatch is the signal.

## Proposal

Two coupled pieces.

### 1. Return contract (standardized format)

Make `AGENT_RESULT` a structured completion block instead of prose — same delimited/keyed
idiom as REMEDIATION_BRIEF and the handoff block:

```
<!-- RETURN:IMPLEMENT -->
PHASE: implement
RESULT: done                 # done | fail | partial
ADDRESSED_ACS: AC1, AC2, AC3
FILES_TOUCHED: debt-collection/.../OrdersController.java, ...-fe/.../orders.component.ts
BRANCHES: feat/ROB-123-reconcile
COMMITS: 3
TASKS_TOTAL: 7
TASKS_DONE: 7
UNADDRESSED: none            # or list of AC/task ids the agent knowingly skipped + why
<!-- /RETURN:IMPLEMENT -->
```

`RESULT: partial` + a populated `UNADDRESSED:` is a first-class outcome — an honest
"couldn't finish X" is more useful than a false `done`, and the validator treats it
differently from a claim-vs-reality mismatch.

### 2. Completion validator (a gate, not trust)

A bash gate that slots into the existing 3-step spawn pattern as a 4th step:

```
spawn_agent_pre → agent → spawn_capture → [validate-return] → spawn_agent_post
```

`validate-return` parses the RETURN block and **independently cross-checks each claim
against observable state**, then downgrades `spawn_agent_post RESULT=done` → `fail` (emit
`|META|gate-stop|fail|RETURN_CONTRACT_MISMATCH`) when a claim doesn't hold.

Checks ranked by robustness (do the pure-bash ones first):

| Check | Source of truth | Pure bash? |
|---|---|---|
| No unchecked tasks | count `- [ ]` vs `- [x]` in openspec `tasks.md` | **yes** |
| Claimed files were touched | `git diff --name-only {BRANCH}` ⊇ `FILES_TOUCHED` | **yes** |
| Branch/commits exist | `git rev-parse` / `git log` on `BRANCHES` | **yes** |
| Outcome label present | reuse `outcome-label-check.sh` | **yes** |
| Every ticket AC id appears in `ADDRESSED_ACS` | ticket AC list ∖ block | mostly (needs AC-id extraction) |
| Each addressed AC has a *plausibly-related* file in the diff | AC↔path heuristic | partial — best-effort only |

The pure-bash rows are the backbone. The AC-relatedness heuristic is best-effort (a weak
signal, flag-not-fail) — don't gate hard on it.

### Strongest single instance to build first

**Implement completeness = zero `- [ ]` left in `tasks.md`.** Countable, zero LLM, catches
the most common "wrote done but skipped a task" failure directly. Ship this one alone
first; it delivers value before the full contract exists.

## Relationship to the handoff-block spec

They converge on **one structured object**. The handoff block (persisted in `notes.md`,
read by the *next phase*) and the return contract (handed up to the *router* at exit) are
the same block with two consumers. Write once. The `validate-return` gate and the
handoff-block integrity check become the same gate reading the same block. Recommend
designing them together even though the return contract may ship first (it has the
higher-value validator).

Boundary discipline is identical: knowledge-plane facts only. Do **not** put routing
counters (`ITERATION`, `VERIFY_ATTEMPTS`) in the return block — those stay in the log,
owned by `detect-resume.sh`. Adding a third store is the drift trap.

## Rollout

1. **Ship the `tasks.md` unchecked-box gate standalone** — no format change needed, pure
   bash, immediate value. Add to the implement→verify transition.
2. Define the RETURN block format (align with handoff-block format — ideally one object).
3. Add `validate-return` with the pure-bash checks; wire between `spawn_capture` and
   `spawn_agent_post`.
4. Add the `RETURN_CONTRACT_MISMATCH` retro template + a `test-return-contract.sh`
   (round-trip parse + each mismatch case fires the gate). Mirror `prescan-verify.sh`
   test style.
5. Backfill per-phase blocks (verify, pr-review, appraise) once the implement contract is
   proven.

## Open questions

- **`partial` semantics** — does a `partial` return with honest `UNADDRESSED:` route to a
  retry, a hold, or a human? Distinct from a mismatch (dishonest/buggy done). Decide the
  routing before wiring the gate.
- **AC-id extraction** — is there a reliable AC-id convention in the tickets to diff
  against, or does AC completeness stay best-effort? Audit real tickets first.
- **One object vs two** — commit to unifying return contract + handoff block, or keep them
  separate formats that happen to share an idiom? Unify unless a concrete reason emerges.
- **Cost of a false gate-stop** — a validator bug that fails a genuinely-complete phase
  halts the pipeline. Every check needs a tight failure scenario and a
  `FLEET_DRY_RUN`-style escape hatch during rollout.
