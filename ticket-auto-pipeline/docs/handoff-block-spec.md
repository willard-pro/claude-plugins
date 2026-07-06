# Phase Handoff Block — Design Note

> **Superseded by:** `openspec/changes/pipeline-integrity/design.md` (2026-07-05).
> Retraction 1: "write once, one object" (return ⇄ handoff) is RETRACTED — shared idiom, TWO blocks.
> Retraction 2: handoff truncation must DEGRADE-to-prose, not halt.
> Retraction 3: handoff is append-only + last-match-wins, not in-place replace.
> Phase 3 (CORRECTIONS back-feed, shipped 2026-07-06) captures the within-ticket feedback loop.
> Generalized handoff block deferred to Phase 5 (measurement-gated pilot). See
> `pipeline-integrity-consolidated-plan` memory for full roadmap.

**Date:** 2026-07-04
**Status:** Superseded (2026-07-05)
**Related:** `prescan-okf-adoption-idea` (memory), `pipeline-log-format.md`, `skills/ticket-verify/SKILL.md` §7c (REMEDIATION_BRIEF — the prototype this generalizes)

## Problem

The pipeline is already handover-driven. Each phase writes markdown artifacts the next
phase reads:

| Artifact | Written by | Read by | Structured? |
|---|---|---|---|
| `context.md` | setup | ~12 skills | prose |
| `notes.md` | appraise | 15+ skills | semi (parseable `## Complexity` only) |
| plan artifact (`simple-fix.md` / openspec `tasks.md`) | exec | implement | prose |
| `reproduce.md` | reproduce | implement, verify | prose |
| **REMEDIATION_BRIEF** | verify (on fail) | implement | **yes — delimited, keyed, integrity-checked** |
| `ai-context.md` | document | future appraise, wiki | prose |

Five of six are free-form prose. A fresh, isolated agent re-reads and re-interprets the
**full** artifact each phase to extract the handful of facts it actually needs (affected
repos, branch names, files touched, decisions made). Clean-context isolation is good for
correctness; re-parsing prose every phase is the efficiency tax.

Only `REMEDIATION_BRIEF` (verify → implement) is built the right way: a canonical
delimited block with keyed fields, atomic write, and a closing-marker integrity check
that halts the pipeline on truncation (`REMEDIATION_BRIEF_TRUNCATED`). It works. The idea
here is to **generalize that one proven pattern to every phase transition.**

## Non-goal (what NOT to do)

**Do not add a parallel `state.json` ledger.** That creates a third state store
(pipeline log + notes.md + json) that drifts — the same overlap failure mode flagged for
wiki-vs-prescan in the `prescan-artifacts-assessment` memory. Keep truth in two planes:

- **Control plane** — the pipeline log (`ISO|PHASE|STEP|STATUS|MSG`), parsed by
  `detect-resume.sh` into routing variables (`COMPLEXITY`, `AUTONOMY`, `VERIFY_ATTEMPTS`,
  `ITERATION`, …). Authoritative for *where we are* and *how to route*. Machine state.
- **Knowledge plane** — the markdown artifact chain. Authoritative for *what the work is*.

The handoff block lives in the **knowledge plane only**. It must carry semantic facts the
next agent needs to *do the work* — never routing counters that already live in the log.
Duplicating `ITERATION`/`VERIFY_ATTEMPTS` into a handoff block is the drift trap; don't.

## Proposal

A single `## Handoff` section in **`notes.md`** (the existing universal read target),
holding one delimited sub-block per phase transition. Each phase appends its block on
completion; the next phase reads its block *first* and falls back to full prose only when
it needs depth.

### Format

Reuse the REMEDIATION_BRIEF idiom verbatim — delimiter lines, `KEY: value` fields,
closing marker for integrity:

```
<!-- HANDOFF:EXEC→IMPLEMENT -->
FROM_PHASE: exec
TO_PHASE: implement
WRITTEN_AT: 2026-07-04T14:30:00Z
COMPLEXITY: simple
PLAN_ARTIFACT: <ticket-dir>/simple-fix.md
AFFECTED_REPOS: debt-collection, credit-network-fe
KEY_SYMBOLS: OrdersController.reconcile (debt-collection/.../OrdersController.java:88)
DECISIONS: reuse existing reconcile() path; no new endpoint
OPEN_QUESTIONS: none
<!-- /HANDOFF:EXEC→IMPLEMENT -->
```

Rules (inherited from REMEDIATION_BRIEF):
- Written to a `.tmp` file then atomically renamed — partial writes never visible.
- Closing marker `<!-- /HANDOFF:{FROM}→{TO} -->` is mandatory. A downstream integrity
  check greps for it; if the tail marker is missing, emit
  `|META|gate-stop|fail|HANDOFF_BLOCK_TRUNCATED` and halt (copy the
  `REMEDIATION_BRIEF_TRUNCATED` retro template).
- Field names and delimiters are canonical — never reformatted.
- Idempotent: a re-run (resume/retry) tail-checks for an existing block of the same
  transition and replaces rather than appends a duplicate.

### Key set per transition (draft)

| Transition | Keys the next phase actually needs |
|---|---|
| `SETUP→APPRAISE` | `TICKET_TYPE` (bug/feature), `REPRO_PRESENT`, `PRIMARY_REPO` |
| `APPRAISE→EXEC` | `COMPLEXITY`, `AFFECTED_REPOS`, `KEY_SYMBOLS`, `PRIOR_ART`, `PRESCAN_HITS` (files matched by prescan-route, so exec doesn't re-route) |
| `EXEC→IMPLEMENT` | `PLAN_ARTIFACT`, `PLAN_MODE` (simple/openspec), `AFFECTED_REPOS`, `BRANCHES`, `DECISIONS` |
| `IMPLEMENT→VERIFY` | `BRANCHES`, `FILES_TOUCHED`, `PR_URLS`, `BEHAVIOUR_CHANGED` (what to test), `NAV_PATH` (if known) |
| `VERIFY→IMPLEMENT` | **already exists** = REMEDIATION_BRIEF (the special case that predates this) |
| `IMPLEMENT→DOCUMENT` | `FILES_TOUCHED`, `DECISIONS`, `CORRECTIONS` (see below) |

### Corrections back-feed (couples with prescan/OKF work)

Add a `CORRECTIONS:` key where implement records where the appraisal/prescan/wiki was
**wrong** ("notes.md said reconcile() was in debt-collection; it's actually in
platform"). `ticket-document` / `wiki-maintenance` / `ticket-prescan` consume corrections
to stop the same wrong appraisal recurring. This is the within-ticket feedback loop that
currently only reaches the wiki via errata. Natural companion to the OKF `timestamp`
freshness work — a correction is a per-fact staleness signal.

## Consumption model

Each phase agent, on spawn:
1. Read its inbound `## Handoff` block from `notes.md` (cheap, structured).
2. Run the integrity check (closing marker present).
3. Use keyed facts directly; open the full prose artifact only for depth it lacks.

The block is an **index into** the prose, not a replacement for it. Correctness path
(full re-read) stays available; the block just removes the *routine* re-derivation.

## Rollout

Incremental — the format is additive and each transition is independent:
1. **Start with `EXEC→IMPLEMENT`** (highest-traffic, clearest key set, plan artifact
   already the handoff medium). Prove the write/read/integrity loop end to end.
2. Add `IMPLEMENT→VERIFY` next (unlocks `BEHAVIOUR_CHANGED` → tighter verify plans).
3. Backfill the rest. Optionally migrate REMEDIATION_BRIEF to the `HANDOFF:` namespace
   for uniformity (low priority — it already works).

Each step: add block-write to the producing skill, block-read + integrity check to the
consuming skill, a retro template for the truncation code, and a `test-handoff-block.sh`
asserting round-trip + truncation detection (mirror `prescan-verify.sh` test style).

## Open questions

- **Home: `notes.md` vs plan artifact?** notes.md is the universal reader (favours it);
  REMEDIATION_BRIEF chose the plan artifact. Leaning notes.md `## Handoff` as canonical,
  with REMEDIATION_BRIEF grandfathered where it is. Decide before step 1.
- **Overlap with `detect-resume.sh` variables** — enumerate which facts are control-plane
  (stay in log) vs knowledge-plane (go in block) so nothing is written twice. Draft the
  boundary table before implementing.
- **Token budget** — cap block size (REMEDIATION_BRIEF caps SNAPSHOT_EXCERPT at 10–20
  lines); a block that grows unbounded defeats the efficiency goal.
- **Block-first read is unenforceable** — the efficiency win only lands if agents read
  the small keyed block *first* and open full prose only for depth. That's LLM-instruction
  behaviour, not a bash-enforceable gate; nothing stops an agent defaulting to the full
  re-parse. Same limitation that bit the prescan multi-persona fan-out (memory
  `prescan-artifacts-assessment` #5 — "no bash script can observe whether the orchestrating
  LLM called the tool"). The integrity check catches truncation but cannot observe read
  order. Best available mitigation is instruction hardening (name the block explicitly in
  each consuming skill's Step 2, make block-read the documented first action) plus, if
  measurable, a token-delta signal in retro to spot phases that skipped the block. Decide
  how hard to lean on instruction vs. accept it as best-effort before rollout.
