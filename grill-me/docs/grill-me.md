# grill-me — Architecture

Pre-work readiness gate. Assesses an input against a profile-driven dimension model, scores it deterministically in bash, and produces a cryptographically sealed Validated Business Intent document.

## Profile model

Profiles are JSON files in `profiles/`. Each profile declares:

- **Dimensions** — named evaluation dimensions with integer weights summing to exactly 100
- **Critical dimensions** — if any critical dimension is `missing`, the recommendation is `do-not-proceed` regardless of readiness
- **Thresholds** — `ready` and `warn` thresholds (0 < warn < ready <= 100)
- **Flags** — qualitative flags with a numeric penalty and an optional tier `cap`
- **Probes** — per-dimension evaluation criteria given to the model

v1 ships exactly one profile, `product-idea`, with 10 dimensions. Adding a consumer (e.g., `code-review`, `incident-analysis`) requires only a new profile file — no engine changes.

## Agent → bash contract

The determinism boundary is the core repo convention: bash orchestrates and decides; agents reason.

The **agent** produces an `assessment.json` containing only judgement:

```json
{
  "dimensions": [
    {"id": "objective", "status": "present", "evidence": "...", "gap": ""}
  ],
  "flags": {"overscoped": true},
  "questions": [
    {"text": "...", "dimension": "success_criteria", "impact": "high", "why": "..."}
  ]
}
```

The **bash scorer** (`grill-score.sh`) computes:

- **Readiness** = sum(weight × status_factor) − flag_penalties, clamped to 0–100
  - status_factor: present = 1.0, partial = 0.5, missing = 0.0
- **Recommendation** = critical-missing → read < warn → read < ready → flag cap
  - Precedence: critical-missing > warn threshold > ready threshold > flag cap
- **Question ranking** = weight × (1 − status_factor) descending, capped at `max_questions`

The agent SHALL NOT contain a computed score. Every scoring rule is a unit-testable assertion.

## Scoring precedence

1. **Critical override.** Any `critical: true` dimension with `status: missing` → `do-not-proceed`, regardless of readiness.
2. **Warn threshold.** Readiness < `warn` → `do-not-proceed`.
3. **Ready threshold.** Readiness < `ready` → `proceed-with-warnings`.
4. **Flag cap.** If a raised flag declares a `cap`, the recommendation is downgraded to that cap even if readiness exceeds the `ready` threshold. E.g., the `overscoped` flag caps at `proceed-with-warnings` — a well-documented but over-scoped idea can never reach `ready`.

## Question ranking

Questions are ranked by:

1. `target_dimension_weight × (1 − target_dimension_status_factor)` descending
2. `impact` tie-break: high > medium > low
3. Profile dimension order (stable tie-break)
4. Assessment order (stable tie-break)

The ranked list is truncated to `max_questions` (profile value or `GRILL_MAX_QUESTIONS` override).

## Seal

See [intent-seal-schema.md](intent-seal-schema.md) for the full canonicalization rule and exit-code contract.

Key design property: the hash covers the seal's own metadata, so editing `**Readiness:**` inside the seal breaks the hash exactly as editing the body does.

## Interactive grill loop

When the recommendation is not `ready` and `--non-interactive` is not set:

1. Rank questions (see above).
2. Present via `AskUserQuestion`, max 4 per call, preserving rank order.
3. Each question displays its `why` rationale.
4. Fold answers back into the assessment — only dimensions targeted by the round's questions are re-assessed (design D9).
5. Re-score and repeat until `ready` or `--max-rounds` is reached.

## Non-interactive mode

Agent-to-agent mode. Scores, renders, and seals without asking any question. A fleet-controller or cron caller can gate on `GRILL_RECOMMENDATION` without a human present.

## Cross-plugin integration

`ticket-planner`'s `planner-intent-gate.sh` resolves `grill-seal.sh` through a three-level fallback (plugin cache → `~/.claude/skills/lib` → relative path). No bundled copy — a drifting duplicate would silently pass invalid seals (design D7).

The gate runs before `planner_state_init`. A hard stop leaves no initiative directory, state log, or lock file behind.

## Worked examples

### Example 1: Well-defined idea (~88%, ready)

**Input:**
> Add real-time cursor presence to the document editor. Enterprise users need to see each other's cursors within 500ms when co-editing. Success criteria: two users open the same doc, cursors visible within 500ms, state consistent across clients. Must use existing WebSocket infrastructure. In scope: cursor presence, document locking. Out of scope: video chat, voice chat, offline sync.

**Assessment:**
- objective: present (clear single goal)
- users_problem: present (enterprise co-editors, identified need)
- success_criteria: present (falsifiable metrics with thresholds)
- scope: present (explicit in/out of scope)
- acceptance_criteria: partial (implied but not explicit AC)
- constraints: present (WebSocket constraint stated)
- dependencies: present (WebSocket v2 dependency)
- risks: partial (latency risk implied but not enumerated)
- edge_cases: missing (no concurrency or empty-state discussion)
- assumptions: partial (WebSocket capacity assumption unstated)

**Score:** ~88% (critical dims solid, non-critical gaps minor)
**Recommendation:** `ready`
**Questions:** 0 (ready on first round)

### Example 2: Vague idea (~22%, do-not-proceed → proceed-with-warnings after 2 rounds)

**Input:**
> We should add enterprise features to our editor.

**Round 1 assessment:**
- objective: missing (what features? why?)
- users_problem: missing (which users?)
- success_criteria: missing (what changes?)
- scope: missing (boundary unknown)
- acceptance_criteria: missing
- constraints: missing
- dependencies: missing
- risks: missing
- edge_cases: missing
- assumptions: partial (assumes "enterprise" is a well-defined category)

**Score:** ~22% (four critical dimensions missing)
**Recommendation:** `do-not-proceed`

**Round 1 questions (top 4):**
1. "What specific enterprise features? Which job do enterprise users need to accomplish that they can't today?" → objective (weight 14, missing)
2. "Which enterprise users? What roles, team sizes, or deployment profiles?" → users_problem (weight 14, missing)
3. "How will you know enterprise adoption is working? What metric moves?" → success_criteria (weight 14, missing)
4. "What is the minimum viable enterprise feature set vs. the eventual scope?" → scope (weight 12, missing)

**User answers (round 1):** "We need SSO (SAML/OIDC), role-based access control, and audit logging. Target: organizations with 50+ users using Okta or Azure AD."

**Round 2 re-assessment (answered dimensions only):**
- objective: partial (three features named, but no prioritization)
- users_problem: present (specific user segment and IdP context)
- success_criteria: missing (still no metric)
- scope: present (three features bounded)

**Score:** ~52%
**Recommendation:** `do-not-proceed` (still below warn=55)

**Round 2 questions:**
1. "What metric defines success? Time to first SSO login? Reduction in support tickets?" → success_criteria (weight 14, missing)

**User answers (round 2):** "100 enterprise orgs onboarded in Q1, SSO login under 2 seconds."

**Round 3 re-assessment:**
- success_criteria: partial (specific target, but still vague on measurement method)

**Score:** ~62%
**Recommendation:** `proceed-with-warnings`
**Remaining gaps:** edge_cases, risks, constraints

→ Sealed with `proceed-with-warnings`, planner proceeds with warning surfaced.

### Example 3: Over-scoped idea (flag fires, cap prevents ready)

**Input:**
> Rebuild our billing system to support usage-based pricing, add enterprise SSO, build a mobile app for invoice approvals, add multi-currency support, and launch a partner API. All within Q3.

**Assessment:**
- Most dimensions are reasonably well documented — the idea is specific.
- But the scope spans five independently valuable streams across three teams.
- `overscoped` flag fires (penalty 15, cap `proceed-with-warnings`).

**Base score:** 72% (well-documented)
**After penalty:** 57% (72 − 15)
**Recommendation:** `proceed-with-warnings` (flag cap, even though 57 ≥ warn=55)

**Top question:** "Which of these five deliverables is most valuable independently? Could phase 1 be just usage-based billing, with the rest in later phases?"

→ Even after grilling, the `overscoped` cap prevents `ready`. The planner proceeds with a surfaced warning.
