# Planner Context Block Schema

**Schema-Version: 1**
**Defined by:** `openspec/changes/ticket-planner-enrichment/specs/planner-context-block/spec.md`
**Validator:** `lib/planned-ticket-check.sh`

## Overview

The `## Planner Context` block is a structured markdown section appended to Linear ticket descriptions by ticket-planner. It carries planning metadata that ticket-auto can consume for accelerated appraisal, confidence-gated auto-approval, and execution feedback.

## Format

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

## Validation Rules

1. **Block presence**: The ticket description must contain a `## Planner Context` heading followed by `**field:** value` lines.
2. **Required fields**: All 10 fields plus `Schema-Version` must be present.
3. **Confidence**: Float between 0.0 and 1.0 inclusive.
4. **Strategy**: Must be exactly `Conservative`, `Balanced`, or `Innovative`.
5. **Pre-approved**: Must be exactly `true` or `false`.
6. **Generated**: Must parse as ISO 8601 timestamp.
7. **Schema-Version tolerance**: Future versions (2+) that are higher than known versions produce a stderr warning but exit 0.

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
