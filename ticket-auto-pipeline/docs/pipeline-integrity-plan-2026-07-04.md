# Pipeline Integrity & Handover — Consolidated Plan

**Date:** 2026-07-04
**Status:** Planned (approved direction, not started)
**Supersedes/reconciles:** `handoff-block-spec.md`, `agent-return-contract-spec.md`, and the
OKF idea (memory `prescan-okf-adoption-idea`). Where those specs disagree with this
document, **this document wins** — see §Retractions.
**Basis:** Two independent adversarial reviews (skeptic / builder lenses), both grounded in
the real code. They converged; this plan is their reconciliation.

---

## The through-line: one live hole

Everything here orbits a single confirmed defect:

> **A phase is marked `done` on the agent's own say-so, with zero independent check.**
> The agent self-writes `…|IMPLEMENT|implement|done|…` inside its own run
> (`skills/ticket-implement/SKILL.md:306`); the router's `RESULT=done|fail` decision is the
> router LLM reading the agent's prose `$AGENT_RESULT` (`spawn-helper.sh:294`, router
> `SKILL.md:297-303`); `spawn_agent_post` only tail-checks for duplicate log lines
> (`spawn-helper.sh:397-401`) — it never validates the work happened. Routing then greps
> those self-written lines (`detect-resume.sh:142`). A false `done` propagates straight
> through verify → PR-review → merge.

This is the `prescan-artifacts-assessment` #5 failure mode (`|done|` written, work skipped),
generalized. **The plan's priority is to close this hole in the codebase's own proven idiom
(observable-state bash gate), and nothing else until it's closed and measured.**

---

## Decisions (what we're building, what we're dropping)

| # | Item | Decision |
|---|---|---|
| 1 | `tasks.md` completeness gate (P2 Piece 1) | **BUILD FIRST**, warn-only → enforce |
| 2 | `CORRECTIONS:` back-feed (P1 sliver) | **BUILD** (append-only, degrade-on-truncation) |
| 3 | Prescan title fix (P3) | **BUILD SMALL** via `meta.json`, not YAML frontmatter |
| 4 | EXEC→IMPLEMENT handoff block (P1) | **PILOT, gated on a measured token win** — else drop |
| 5 | Full agent return contract (P2 Piece 2) | **DEFER** — only if telemetry shows lying `done`s |
| 6 | OKF frontmatter adoption (P3) | **DEFER** behind a concrete trigger |
| 7 | Generalized 6-transition handoff scheme (P1) | **DROP** unless #4 proves out |
| 8 | OKF `timestamp:` freshness (P3) | **DROP for now** — redundant under en-masse regen |
| 9 | "One object" unification of return+handoff | **RETRACT** — see §Retractions |
| 10 | AC-relatedness heuristic as a gate | **DROP as a gate** — flag-not-fail only |

---

## Build order

Each phase is independently shippable and ordered by value-per-cost. **Do not start a phase
until the "Decide first" items for it are answered.**

### Phase 1 — `tasks.md` completeness gate (warn-only, openspec-scoped)

**What:** A new deterministic bash gate that runs after an implement agent returns and
before the router commits the phase as `done`. It counts unchecked boxes in the openspec
`tasks.md`; any `- [ ]` remaining ⇒ the agent did not finish ⇒ the gate objects.

**Why:** The single highest-value intervention — it directly closes the false-done hole for
the most common failure ("wrote done, skipped a task"). Pure bash, ~40 lines, no LLM, no new
format. On-grain with every existing gate.

**Where it slots:** the existing 3-step spawn pattern gains a 4th step —
`spawn_agent_pre → agent → spawn_capture → [return-completeness-check] → spawn_agent_post`
(router STEP_4 → new STEP_4.5). Mirror the `gate-check.sh` idiom exactly: exit `0` pass /
`1` incomplete / `2` error; emit `_plog … |META|gate-stop|fail|CODE` + `hb_gate`.

**Warn-only first (mandatory):** on first rollout the gate only *logs* a mismatch; it does
**not** flip `done`→`fail`. Collect false-positive rate before it can halt anything. This is
non-negotiable — a validator bug that fails a genuinely-complete phase halts a good pipeline.

**⚠️ Warn channel must NOT be `gate-stop` (second-pass finding G1).** `fleet-detect.sh:99-116`
classifies *any* `|META|gate-stop|fail|` line, and **unknown codes default to severity 1
("human must resolve")** — so a warn-only gate logging through the gate-stop channel would
summon the fleet controller on every warning, the exact false-halt warn-only exists to avoid.
Warn mode emits `|META|gate-warn|info|RETURN_INCOMPLETE — {detail}` instead — a channel
fleet-detect ignores. And because `retro.sh:236` only counts `gate-stop|fail`, retro must
gain a `gate-warn` counter in the same change — **otherwise Phase 2's "measure false-positive
rate" has no collector.** The measurement mechanism is a Phase 1 deliverable, not an
afterthought.

**Decide first:**
- **D1 — simple-fix path has no checklist.** `tasks.md` boxes only exist for openspec
  tickets; `simple-fix.md` is prose (appraise-exec emits one *or* the other). The majority of
  auto-mode *simple* tickets would be **ungated**. Decision: **scope Phase 1 to openspec
  explicitly and ship**. Then dissolve D1 with a template tweak (second-pass finding E1):
  `appraise-exec` generates a `## Completion Checklist` (derived from the ACs) inside
  `simple-fix.md`, and the *same* gate greps `- [ ]` in whichever plan artifact exists — one
  gate, both modes, majority path covered. No parallel design needed. Do not block Phase 1 on
  this — ship openspec-scoped first, add the template checklist as a fast follow.
- **D3 — router authority.** The gate is only as strong as the router honoring it. Add an
  explicit branch to the router: *"on return-completeness-check exit 2/1, you MUST call
  `spawn_agent_post RESULT=fail`"* — documented as hard as the `gate-check.sh` contract.

**Deliverables:** `lib/return-completeness-check.sh`; router STEP_4.5 wiring; the `gate-warn`
channel + retro `gate-warn` counter (G1); a retro template (`RETURN_INCOMPLETE`);
`lib/tests/test-return-completeness.sh` (round-trip + each mismatch fires) mirroring
`prescan-verify.sh` test style.

**Honest framing (G4):** `tasks.md` checkboxes are written by the *same agent* that claims
`done` — so this gate is not truly independent observation; it **raises the cost** of a false
done (the agent must actively falsify boxes rather than merely skip work). That is the right
trade: the observed failure mode (`prescan-artifacts-assessment` #5) was *skipping*, not
active deception. The commit cross-check in Phase 2 closes the remaining "checked boxes, did
nothing" hole.

**Risk/rollback:** warn-only mode is the rollback. `FLEET_DRY_RUN`-style flag stays available
after enforce is flipped.

### Phase 2 — measure, then flip warn → enforce

**What:** After Phase 1 has run warm long enough to observe real tickets, review the
false-positive log. If clean, flip the gate to enforce (`done`→`fail` on mismatch).

**Decide first:**
- **D2 — git base ref.** Any git-based check (used more in later phases, but pin it now) must
  diff against a named base (`develop`) and handle the already-merged/pushed-branch case,
  where `git diff` is empty and every claim would falsely read "missing." Unspecified base =
  false `gate-stop` on good pipelines.

**Enforce-mode wiring (second-pass findings G2/G3) — part of this phase, not optional:**
- **Fleet classification:** add `RETURN_INCOMPLETE` to `fleet-detect.sh`'s gate-stop case as
  **retryable** (like `PR_REVIEW_VERDICT_UNPARSEABLE` → 3). Without this, the unknown-code
  default (severity 1, human-must-resolve) turns every enforce-mode catch into a human stop —
  even though an incomplete implement is the *most retryable* failure in the pipeline: the
  unchecked boxes in `tasks.md` are literally the resume state.
- **Bounded router retry:** on `RETURN_INCOMPLETE`, the router re-dispatches implement (fresh
  agent continues from unchecked tasks — openspec's natural resume) with a new
  `IMPLEMENT_RETRY` counter, **max 2**, mirroring the existing `VERIFY_ATTEMPTS`/`ITERATION`
  pattern. Exhausted → gate-stop for human.
- **Resume semantics:** `detect-resume.sh` currently special-cases only `EXEC_NO_ARTIFACT`
  (`:148`). Define explicitly what `RESUME_STEP` returns after a `RETURN_INCOMPLETE` fail
  (re-dispatch implement, `IMPLEMENT_FROM` preserved) so crash-resume through the new gate is
  deliberate, not accidental.
- **Commit cross-check (G4 hardening):** all boxes checked AND zero new commits on branch vs.
  base (`git rev-list develop..{BRANCH} --count` = 0) ⇒ mismatch. One git call; closes the
  "checked the boxes, did nothing" hole and makes the gate genuinely two-source.

**Deliverable:** enforce-mode flip + base-ref handling + the four wiring items above.

### Phase 3 — `CORRECTIONS:` back-feed (the one real capability from P1)

**What:** implement (and verify) may append a `CORRECTIONS:` note to `notes.md` recording
where the appraisal / prescan / wiki was *wrong* ("notes.md said reconcile() lives in
debt-collection; it's actually in platform"). `ticket-document` / `wiki-maintenance` /
`ticket-prescan` consume corrections so the same wrong appraisal stops recurring.

**Why:** The only part of the handoff-block spec that is a genuinely *new capability* (a
within-ticket feedback loop), not a token optimization. Severable from the block apparatus.

**How (corrected from original spec):** **append-only** at the tail of `notes.md` (mirror the
REMEDIATION_BRIEF / log idiom), atomic `.tmp`→`mv`. On a torn/truncated block, **degrade to
ignoring it — never halt.** No in-place mutation.

**Deliverables:** a `CORRECTIONS:` append helper; consumer reads in document/wiki/prescan; a
test asserting append + last-wins + tolerant-of-truncation.

### Phase 4 — prescan title fix via `meta.json` (P3, smallest scope)

**What:** Fix the fragile `_write_index` title scrape (`prescan-docs.sh:220`,
`head -1 | sed 's/^# //'`) by storing each doc's display title in the already-structured,
already-parsed `meta.json` — **not** by adding YAML frontmatter.

**Why:** Both reviewers converged here. The scrape already has a basename fallback (it
degrades, doesn't break), so this is low-severity. Adding YAML frontmatter instead would
break `prescan-verify.sh` (its `head -5 … WARNING` check and `MIN_LINES`/heading counts,
`:113`) and `prescan-route.sh` (INDEX table parsing) in lockstep, require a YAML parser
(`yq` absent; only `python3`+`pyyaml`), and touch LLM-written docs (`overview.md`,
`security-surfaces.md` come from fan-out agents, not the distiller) — all for a cosmetic gain.
`meta.json` sidesteps every one of those.

**Deliverables:** distiller writes `title` into `meta.json` per doc; `_write_index` reads it
with the basename scrape kept only as fallback.

### Phase 5 — EXEC→IMPLEMENT handoff pilot (gated on a MEASURED token win)

**What:** Build the structured handoff block for **one** transition (EXEC→IMPLEMENT) and
**measure the token delta** against the current prose-only baseline on real tickets.

**Kill-switch:** if there is no meaningful, repeatable token saving, **stop and drop the
entire generalized handoff scheme.** This is the reconciliation between "drop it" and "try
it": we try exactly one transition, cheaply, and let the measurement decide. The block's own
spec admits block-first reading is unenforceable, so the burden of proof is on the number.

**How (corrected):** append-only, last-match-wins; **degrade-to-prose on truncation, never
halt** (the block is an optional index; the prose is the correctness path). knowledge-plane
fields only — no `RESULT`/routing counters.

**Deliverables (only if the pilot pays):** the block writer in exec, reader in implement, a
token-delta measurement note, and only *then* a decision on further transitions.

### Phase 6 — full agent return contract (P2 Piece 2), last

**What:** The full standardized `<!-- RETURN:PHASE -->` block across all agents + broader
`validate-return` checks (files-touched ⊆ diff, branches exist, label present).

**Gate to start:** only if Phase 1/2 warn-only telemetry shows agents actually emitting false
`done`s on paths the `tasks.md` gate can't see (e.g., simple-fix, verify). Otherwise this is
format surface for checks already covered by `outcome-label-check.sh` and branch-existence.

**Verify false-done gap (second-pass finding G5) — candidate for this phase:** verify has the
same structural hole as implement did: its pass evidence is an append to `notes.md` written by
the verify agent itself (`ticket-verify/SKILL.md` Step 6) — nothing observable proves
Playwright ever ran. Candidate cheap check: require a playwright session artifact
(screenshot / session log) with mtime newer than the phase-start log entry. Explicitly on the
roadmap here so it isn't lost; explicitly NOT Phase 1 scope.

**Decide first:**
- **D4 — `partial` routing.** A `RESULT: partial` + honest `UNADDRESSED:` must route somewhere
  deliberate (retry / hold / human). Wrong routing loops forever or silently drops work.
- Build as **"shared idiom, separate block"** — never merged with the handoff block (see
  §Retractions).

---

## Retractions & corrections from the original specs

These were caught by both reviews and are now authoritative:

1. **RETRACT "write once, one object" (return contract ⇄ handoff block).** They share a
   *grammar*, not an *object*. Merging breaks four ways: (a) disjoint field sets → union =
   block bloat that fights the token-budget goal; (b) `RESULT` is **control-plane** data —
   putting it in a knowledge-plane `notes.md` block is the exact drift/boundary violation both
   specs swear off; (c) opposite integrity policies — handoff truncation must **fail-open
   (degrade)**, return mismatch must **fail-closed (halt)**; one artifact can't be both; (d)
   different lifecycle — handoff persists for the next agent, return is transient for the
   router *now*. **Adopt: shared delimited `KEY: value` + closing-marker + atomic-write idiom;
   two separate blocks.**

2. **CORRECT handoff-block truncation policy: degrade-to-prose + warn, NOT halt.** The
   original `HANDOFF_BLOCK_TRUNCATED` halt contradicts the "block is an index, prose is the
   fallback" model. Halting a good pipeline because an *optional optimization artifact* tore is
   strictly worse than not having the block. (The **return** gate still halts — that's
   validating required completion, a different contract.)

3. **CORRECT handoff mutation: append-only + last-match-wins**, not in-place mid-file
   replacement. REMEDIATION_BRIEF's proven integrity comes from tail-append + atomic rename;
   in-place block replacement in `notes.md` is a different, more fragile operation that does
   not inherit that safety.

4. **Prescan title fix goes in `meta.json`, not YAML frontmatter.** OKF adoption is deferred
   (see below).

---

## Explicitly NOT doing now (and the trigger that would revive each)

- **Generalized 6-transition handoff scheme** — revive only if the Phase 5 pilot shows a real
  token win.
- **OKF YAML frontmatter adoption** — revive only when there's a concrete external OKF
  consumer of `.ticket-auto` docs. "Fix a title scrape that has a fallback" is not a
  sufficient reason.
- **OKF `timestamp:` per-doc freshness** — revive only after incremental scans actually run
  (`incremental_scan_count` is 0 everywhere; `prescan-artifacts-assessment` caveat #3 must be
  *exercised* first — the dependency in the original note was backwards). Under today's
  en-masse regen every doc gets the same timestamp, adding no signal `meta.json`'s repo SHA
  lacks.
- **Merging return + handoff into one object** — retracted, see above.
- **AC-relatedness / AC-id coverage as a hard gate** — flag-not-fail telemetry only.

---

## Open decisions to settle before coding (consolidated)

| ID | Decision | Blocks | Recommendation |
|---|---|---|---|
| D1 | simple-fix completeness signal | Phase 1 scope, Phase 6 | Scope Phase 1 to openspec; then dissolve via E1 template checklist (same gate covers both) |
| D2 | git diff base ref + already-merged handling | Phase 2, Phase 6 | Base = `develop`; treat empty-diff-because-merged as pass |
| D3 | Router hard-honor of gate exit code | Phase 1 | Document "exit≠0 ⇒ MUST RESULT=fail" as hard as `gate-check.sh` |
| D4 | `partial` return routing | Phase 6 | Decide retry vs hold vs human before wiring |

## Second-pass review findings (2026-07-04, post-reconciliation)

A third pass over the reconciled plan against the reacting machinery (fleet controller,
retro, resume) — areas neither adversarial review covered — found:

| ID | Finding | Folded into |
|---|---|---|
| G1 | Warn-only via `gate-stop|fail` would trigger fleet severity-1 on every warning (unknown-code default, `fleet-detect.sh:99-116`); retro has no warn collector (`retro.sh:236`) | Phase 1 (gate-warn channel + retro counter) |
| G2 | `RETURN_INCOMPLETE` unclassified → human-must-resolve, though incomplete-implement is the most retryable failure (unchecked boxes = resume state) | Phase 2 (fleet retryable class + `IMPLEMENT_RETRY` max 2) |
| G3 | `detect-resume.sh` special-cases only `EXEC_NO_ARTIFACT`; resume semantics after the new code were undefined | Phase 2 |
| G4 | Checkboxes are agent-authored — gate raises the cost of lying, isn't independent observation; over-claimed as "observable state" | Phase 1 framing + Phase 2 commit cross-check |
| G5 | Verify has the same false-done hole (pass evidence is self-authored notes.md append; nothing proves Playwright ran) | Phase 6 candidate check |
| E1 | D1 dissolves via generated `## Completion Checklist` in `simple-fix.md` — same gate covers both artifact modes | Phase 1 D1 + table above |

---

## Blast radius (for scheduling)

- **Phase 1:** `lib/return-completeness-check.sh` (new), `skills/ticket-auto/SKILL.md` (STEP_4.5
  wiring), retro template, `lib/tests/test-return-completeness.sh`. Small.
- **Phase 3:** `notes.md` append helper + reads in `ticket-document`/`wiki-maintenance`/
  `ticket-prescan`. Small–medium.
- **Phase 4:** `lib/prescan-docs.sh` only. Tiny.
- **Phase 5:** exec + implement SKILL.md pair + measurement. Medium; may be discarded.
- **Phase 6:** every agent's final-report step + `lib/validate-return.sh` + router wiring +
  tests. Large; deferred and conditional.

**Bottom line:** Phases 1–4 are the committed, high-confidence work — they close the live
false-done hole and add one real feedback loop for a small, on-grain footprint. Phases 5–6 are
measurement-gated experiments that may be dropped. The two speculative file-format schemes
(generalized handoff, OKF frontmatter) are explicitly parked behind concrete triggers.
