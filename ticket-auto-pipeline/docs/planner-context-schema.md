# Planner Context Block Schema

**Schema-Version: 2**
**Defined by:** `openspec/changes/ticket-planner-enrichment/specs/planner-context-block/spec.md`
**Extended by:** `openspec/changes/ticket-planner-exploration` (Schema-Version 2 exploration fields)
**Validator:** `lib/planned-ticket-check.sh`

## Overview

The `## Planner Context` block is a structured markdown section appended to Linear ticket descriptions by ticket-planner. It carries planning metadata that ticket-auto can consume for accelerated appraisal, confidence-gated auto-approval, and execution feedback.

## Format

### Schema-Version 2 (all Version 1 fields + 5 optional exploration fields)

```
## Planner Context
**Schema-Version:** 2
**Initiative:** <initiative-id>
**Epic:** <epic-id>
**Confidence:** <float 0.0-1.0>
**Strategy:** Conservative | Balanced | Innovative
**Decision:** <one-sentence architectural decision summary>
**Affected Services:** <comma-separated service names>
**Target Symbols:** <semicolon-separated symbol:file:line references>
**Pre-approved:** true | false
**Generated:** <ISO 8601 timestamp>
**Regenerate:** true | false
**Exploration Depth:** quick-scan | standard | deep
**Code Paths Traced:** <semicolon-separated symbol:file references>
**API Contracts Analyzed:** <comma-separated service/endpoint identifiers>
**Alternative Approaches:** <semicolon-separated brief summaries>
**Open Questions:** <semicolon-separated unresolved items>
```

### Schema-Version 1 (legacy, still valid)

```
## Planner Context
**Schema-Version:** 1
**Initiative:** <initiative-id>
**Epic:** <epic-id>
**Confidence:** <float 0.0-1.0>
**Strategy:** Conservative | Balanced | Innovative
**Decision:** <one-sentence architectural decision summary>
**Affected Services:** <comma-separated service names>
**Target Symbols:** <semicolon-separated symbol:file:line references>
**Pre-approved:** true | false
**Generated:** <ISO 8601 timestamp>
**Regenerate:** true | false
```

## Field Reference

| Field | Type | Required | Description |
|---|---|---|---|
| `Schema-Version` | integer | Yes | Schema version for forward-compatible parsing. Initial version: `1`. |
| `Initiative` | string | Yes | Initiative identifier (e.g., `INIT-42`). Links ticket to its planning initiative. |
| `Epic` | string | Yes | Epic identifier (e.g., `CRE-100`). Parent epic for this ticket. |
| `Confidence` | float (0.0-1.0) | Yes | Planner's confidence in ticket correctness and completeness. Gates auto-approval at ≥ 0.85 (configurable via `PLANNER_CONFIDENCE_THRESHOLD`). |
| `Strategy` | enum | Yes | `Conservative` (minimal change, low risk), `Balanced` (moderate change, standard risk), `Innovative` (significant change, higher risk). |
| `Decision` | string | Yes | One-sentence summary of the key architectural or implementation decision. |
| `Affected Services` | CSV | Yes | Comma-separated service names this ticket touches. Used by appraise to scope prescan routing. |
| `Target Symbols` | semicolon-list | Yes | `symbol:file:line` references serving as investigation starting points. Example: `DebtCollector.collect:src/collector.ts:42; PaymentGateway.charge:src/gateway.ts:128` |
| `Pre-approved` | boolean | Yes | `true` if planner declares this ticket is ready for accelerated appraisal (must have Confidence ≥ 0.85). Makes the ticket eligible for fast-path in ticket-appraise — skips full codebase investigation. Does NOT bypass the human approval gate; standard gate rules still apply. `false` otherwise. |
| `Generated` | ISO 8601 | Yes | When the Planner Context was created or last regenerated. Example: `2026-07-07T18:00:00Z`. |
| `Regenerate` | boolean | Yes | `true` if the planner recommends re-generating this ticket's plan. Used by feedback loop to flag stale plans. |

### Schema-Version 2 Exploration Fields (optional)

| Field | Type | Required | Description |
|---|---|---|---|
| `Exploration Depth` | enum | No | `quick-scan` (surface symbols, 1 approach), `standard` (traced call chains 3-5 deep, API contracts, 2-3 approaches), `deep` (full dependency graph, API diffs, 3+ approaches with tradeoffs, risk register). Defaults to `standard` if absent. |
| `Code Paths Traced` | semicolon-list | No | `symbol:file` references representing call chains followed during exploration. Example: `DebtCollector.collect:src/collector.ts; PaymentGateway.charge:src/gateway.ts` |
| `API Contracts Analyzed` | CSV | No | Comma-separated service/endpoint identifiers whose API contracts were reviewed. Example: `debt-collection:POST /collect, notification-service:POST /send` |
| `Alternative Approaches` | semicolon-list | No | Brief summaries of approaches considered and rejected during exploration. Example: `Extend existing collector (rejected: too coupled); Inline fix with feature flag (selected)` |
| `Open Questions` | semicolon-list | No | Investigation items exploration could not resolve. Non-empty signals need for human architectural input. Example: `Should collector retry on 429?; Is the payment gateway idempotent for duplicate charges?` |

## Validation Rules

1. **Block presence**: The ticket description must contain a `## Planner Context` heading followed by `**field:** value` lines.
2. **Required fields**: All 11 fields (Schema-Version + 10 content fields) must be present for all schema versions.
3. **Confidence**: Float between 0.0 and 1.0 inclusive.
4. **Strategy**: Must be exactly `Conservative`, `Balanced`, or `Innovative`.
5. **Pre-approved**: Must be exactly `true` or `false`.
6. **Generated**: Must parse as ISO 8601 timestamp.
7. **Schema-Version tolerance**: Future versions (3+) that are higher than known versions produce a stderr warning but exit 0. Schema-Version 2 is the current known maximum.
8. **Exploration Depth** (V2, optional): If present, must be exactly `quick-scan`, `standard`, or `deep`. Invalid values → exit 1.
9. **Code Paths Traced** (V2, optional): If present, each entry must match `symbol:file` format (at least one `:`). Invalid entries → exit 1.
10. **Version 1 backward compatibility**: Schema-Version 1 blocks remain valid. Exploration fields are only validated when Schema-Version ≥ 2.

## Exit Codes

| Code | Meaning |
|---|---|
| 0 | Valid — block present, all required fields valid. |
| 1 | Missing/malformed — no block found, missing required fields, invalid field values. |
| 2 | Low confidence, not pre-approved — Confidence < threshold AND Pre-approved is false. Flags ticket for human review. |

Threshold is configurable via `PLANNER_CONFIDENCE_THRESHOLD` env var (default: 0.5).

## Determinism

All validation is pure bash (grep, awk, jq). No LLM calls, no fuzzy matching. Field names must match exactly (case-sensitive). The only external dependency is `get_issue` (Linear API via `linear-api.sh`) to fetch the ticket description — the validator itself is deterministic given the same input.

Schema-Version tolerance ensures forward compatibility: if the planner advances to Version 2 with new optional fields, the Version 1 validator accepts the block (exit 0 with stderr warning).

## Examples

### Valid Schema-Version 2 block with exploration fields (exit 0)
```
## Planner Context
**Schema-Version:** 2
**Initiative:** INIT-42
**Epic:** CRE-100
**Confidence:** 0.92
**Strategy:** Balanced
**Decision:** Extend DebtCollector with new payment method enum rather than new service
**Affected Services:** debt-collection, payment-gateway
**Target Symbols:** DebtCollector.collect:src/collector.ts:42; PaymentMethod.parse:src/payment.ts:88
**Pre-approved:** true
**Generated:** 2026-07-24T18:00:00Z
**Regenerate:** false
**Exploration Depth:** standard
**Code Paths Traced:** DebtCollector.collect:src/collector.ts; PaymentGateway.charge:src/gateway.ts; PaymentMethod.parse:src/payment.ts
**API Contracts Analyzed:** debt-collection:POST /collect, payment-gateway:POST /charge
**Alternative Approaches:** New microservice for payment routing (rejected: overkill for scope); Inline enum extension with feature flag (selected)
**Open Questions:** Should collector retry on 429 from payment gateway?
```

### Valid Schema-Version 2 block without exploration fields (exit 0)
Same as above but without the last 5 fields — all are optional.

### Valid block (exit 0)
```
## Planner Context
**Schema-Version:** 1
**Initiative:** INIT-42
**Epic:** CRE-100
**Confidence:** 0.92
**Strategy:** Balanced
**Decision:** Extend DebtCollector with new payment method enum rather than new service
**Affected Services:** debt-collection
**Target Symbols:** DebtCollector.collect:src/collector.ts:42; PaymentMethod.parse:src/payment.ts:88
**Pre-approved:** true
**Generated:** 2026-07-07T18:00:00Z
**Regenerate:** false
```

### Valid block with low confidence, not pre-approved (exit 2)
Same as above but:
```
**Confidence:** 0.35
**Pre-approved:** false
```

### Malformed — missing fields (exit 1)
Missing `Strategy` and `Decision` fields.
