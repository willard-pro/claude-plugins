# ticket-auto RLVR Program

Reinforcement Learning with Verifiable Rewards — a 5-phase programme to close the
feedback loop in `ticket-auto`. Today the pipeline runs agents and moves on; RLVR
makes every agent decision traceable to a scored outcome so systemic defects are
caught, filed, and fed back into the system.

## Why RLVR for ticket-auto

The pipeline already has the raw ingredients:

- **Verifiable execution**: tests pass/fail, gate-check.sh makes deterministic
  decisions, PR review produces verdicts, Playwright UAT produces pass/fail
- **Structured logging**: pipeline log + heartbeat log capture every phase
  transition, every spawn, every gate decision
- **Retry loops**: verify retry (2×), PR iteration (3×), PR reconciliation (3×)
  — each loop is an RL episode with a terminal verdict
- **Determinism boundary**: bash orchestrates state, agents reason — the
  boundary is where RLVR signals cross from execution back to planning

What's missing: **uniform signal format**, **per-phase inspection**,
**systemic pattern detection**, **guidance accumulation**, and
**closed-loop reward shaping**. These are Phases 0–4.

## Programme Structure

```
Phase 0 ──► Phase 1 ──► Phase 2 ──► Phase 3 ──► Phase 4
(produce    (inspect    (accumulate  (file &     (shape
 signals)   signals)    guidance)    fix)        rewards)
```

Each phase ships independently and benefits the system immediately.
Later phases consume earlier phases' outputs.

---

## Phase 0 — Verifier Standardization 🟢 IN OPENSPEC

**Status**: `openspec/changes/verifier-standardization/` — proposal, design,
tasks, specs complete. Ready to implement.

**What**: Standardize all 11 verifier outputs into a single
`META|verifier-result|info|{json}` log line. Record model identity per spawn.
Make trajectory data derivable as a pure function of existing logs.

**Delivers**:
- `lib/verifier-result.sh` — single `write_verifier_result` function
- `lib/trajectory.sh` — on-demand `traj_generate` reader
- MODEL recorded in spawn-meta + pipeline log
- 8 verifier call sites wired (verify, PR review, implement, gate-check,
  return-completeness, critique, audit, appraise-exec ×2)
- awk-join MSG parsing rule (never `cut -f5`)
- Score on the existing `_compute_actual_confidence` scale

**Dependencies**: None. Ships first. Benefits retro, dashboard, fleet immediately.

**Openspec**: `openspec/changes/verifier-standardization/`

---

## Phase 1 — Phase Inspector ⚫ NOT YET IN OPENSPEC

**Status**: Design discussed, not yet spec'd.

**What**: Per-phase inspection agent that reads `META|verifier-result` entries
and produces `META|phase-inspector` verdicts (PASS/WARN/FAIL) for each phase.
The inspector is a named agent type spawned post-phase — it reads the verifier
results, checks for patterns (e.g., "implement ran tests but they were flaky",
"PR review passed but missed a requirement"), and writes structured verdicts.

**Delivers**:
- `guidance-extractor-agent` named agent type (shared with Phase 2)
- `META|phase-inspector` log entries
- Inspector verdict schema (PASS/WARN/FAIL + structured detail)
- Per-phase spawn in the router (post-IMPLEMENT, post-VERIFY, post-PR-REVIEW)

**Dependencies**: Phase 0 (reads verifier-result entries).

**Openspec**: Not yet created.

---

## Phase 2 — Guidance Store ⚫ NOT YET IN OPENSPEC

**Status**: Design discussed, not yet spec'd.

**What**: Accumulate inspector verdicts and post-mortem findings into a durable
guidance store. The `guidance-extractor-agent` (shared with Phase 3) classifies
root causes (`skill-file | lib-script | agent-prompt | network-flake`) and
updates a guidance file that skills can reference. CORRECTIONS blocks gain an
`inspector` source.

**Delivers**:
- Guidance store at `~/.claude/state/ticket-auto/guidance/`
- `guidance-extractor-agent` named agent type
- `lib/corrections-parse.sh` source enum extended with `inspector`
- Guidance confirm/deprecate lifecycle
- Skill authors can query guidance before making decisions

**Dependencies**: Phase 1 (reads inspector verdicts).

**Openspec**: Not yet created.

---

## Phase 3 — Pipeline Post-Mortem 🟢 IN OPENSPEC

**Status**: `openspec/changes/ticket-auto-phase-3-pipeline-postmortem/` —
proposal, design, tasks, specs complete. Ready to implement.

**What**: End-of-run analysis on ALL exit paths (gate-stop, VERIFY_EXHAUSTED,
PR_FEEDBACK_EXHAUSTED, fleet-kill, STEP_6) via `trap run_postmortem EXIT`.
Files GitHub issues for systemic problems with deterministic error signatures.
Reuses ticket-retro's proven GitHub machinery.

**Delivers**:
- `lib/pipeline-postmortem.sh` — fail-soft analysis + issue filing
- Trap handler in `skills/ticket-auto/SKILL.md`
- Deterministic error signatures (`{code}|{phase}|{sha256}`)
- Rate limiting (5 issues/hour/repo)
- Wrong-outcome-label detection
- Guidance store integration (confirm/deprecate)
- Fleet integration (optional post-mortem on kill, dashboard counts)
- CORRECTIONS blocks with `source=postmortem`

**Dependencies**: Phases 0, 1, 2 (reads verifier-result, phase-inspector,
guidance store, extractor agent).

**Openspec**: `openspec/changes/ticket-auto-phase-3-pipeline-postmortem/`

---

## Phase 4 — Reward Shaping ⚫ NOT YET IN OPENSPEC

**Status**: Concept only, not yet designed.

**What**: Close the RL loop. Use the trajectory data (Phase 0), inspector
verdicts (Phase 1), guidance store (Phase 2), and post-mortem findings
(Phase 3) to shape agent prompts and routing decisions. Examples:

- If guidance says a skill file consistently derails the implement agent,
  auto-inject a correction block before spawn
- If a verifier pattern shows flaky Playwright tests, reduce verify retry
  count or skip certain steps
- If post-mortem finds a gate script bug, bump the ticket to a human with
  the auto-filed issue link
- Feed outcome→prediction deltas back into the planner's confidence model

**Dependencies**: All prior phases.

**Openspec**: Not yet created.

---

## Shipping Order

```
Phase 0 (verifier-standardization)     ← IMPLEMENT NOW
Phase 3 (pipeline-postmortem)          ← IMPLEMENT NOW (depends on 0/1/2
                                          for full function; ships
                                          warn-only until deps land)
Phase 1 (phase-inspector)              ← SPEC & IMPLEMENT NEXT
Phase 2 (guidance-store)               ← SPEC & IMPLEMENT AFTER 1
Phase 4 (reward-shaping)               ← DESIGN AFTER 0–3 SHIP
```

Phase 0 and Phase 3 are spec-complete in openspec. Phase 3's post-mortem
script reads Phase 0/1/2 signals defensively — absent channels degrade to
"no signal" rather than erroring, so Phase 3 can ship in parallel with
Phase 1 and Phase 2 without blocking on them.

---

## Design Invariants

1. **Determinism boundary preserved**: bash orchestrates, agents reason.
   RLVR signals are bash-generated or bash-validated; agents never
   self-report their own scores.
2. **Additive only**: new META entries, new log lines, new readers.
   No existing pipeline logic changes behavior.
3. **Fail-soft everywhere**: a missing verifier result, an unavailable
   inspector agent, a rate-limited GitHub API — all degrade gracefully.
   The pipeline never stops because RLVR infrastructure is down.
4. **One confidence scale**: verifier scores and planner confidence use
   the same 0.0–1.0 scale (`_compute_actual_confidence`). No second scale.
5. **Independent shipping**: each phase lands, tests pass, benefits the
   system immediately without waiting for later phases.
