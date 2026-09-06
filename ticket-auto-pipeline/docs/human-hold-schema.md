# Human Hold Block Schema

**Schema-Version: 1**
**Defined by:** `openspec/changes/human-hold-protocol/specs/human-hold-request/spec.md`
**Parser:** `lib/human-hold-parse.sh`
**Emitted by:** `lib/skill-preamble-auto.md` § Human hold

## Overview

The `=== HUMAN_HOLD ===` block is a section an agent appends to its return when it
cannot proceed without human input. `AskUserQuestion` is absent from the `claude -p`
tool list, so a headless worker cannot ask interactively — prose plus a clean exit is
its only channel today, and that exit is indistinguishable from success. This block
makes the exit legible: a structured request instead of silence.

Any phase may emit it — the asks observed in production come mostly from **APPRAISE**
and **EXEC**, which deliberately do not emit `=== PHASE_RESULT ===` blocks, so that
channel is the wrong carrier and is not reused here.

**This file is the source of truth.** Prompts, `SKILL.md` files and preamble sections
supply *parameters*; none of them restates the field set or the grammar.

## The field set is the contract; the marker envelope is transport

Same framing as [phase-result-schema.md](phase-result-schema.md): the durable machine
contract is the **field set** below and the canonical JSON the parser produces from it.
The `=== HUMAN_HOLD ===` / `=== END HUMAN_HOLD ===` marker envelope and its `KEY: value`
body are transport, chosen for the same reason — nothing in the bash path offers
constrained decoding, and the return text crosses a boundary where a model composes a
shell command. An SDK-native structured-output swap would replace the envelope without
renegotiating the contract.

## Format

### Schema-Version 1

```
=== HUMAN_HOLD ===
SCHEMA_VERSION: 1
PHASE: APPRAISE
REASON: SCOPE_UNDEFINED
BLOCKS: notes.md#Acceptance-Criteria AC-2
QUESTION_1: Should the export include archived records?
QUESTION_2: Is a CSV format acceptable, or is XLSX required?
=== END HUMAN_HOLD ===
```

The block is the **last content of the return** — write ordinary prose first, then
append the block. Anything after the closing marker is ignored.

## Key syntax

Identical to `phase-result-schema.md`: keys match `[A-Z][A-Z0-9_]*`, one `KEY: value`
pair per line, values are single-line plain text (no nested JSON, no quoting, no
escaping), a value may contain `"`, `$`, backticks, `$(...)`, `&&`, `;` — the parser
treats every value as data and never evaluates it — and the first `:` separates key
from value, so a value may contain further colons.

## Field Reference

| Field | Required | Type | Description |
|---|---|---|---|
| `SCHEMA_VERSION` | Yes | integer | Current version: `1`. |
| `PHASE` | Yes | enum | The emitting phase. One of `APPRAISE`, `REPRODUCE`, `EXEC`, `GATE`, `IMPLEMENT`, `VERIFY`, `PR-REVIEW`, `MAINTENANCE` — not restricted to the loop-bearing three `=== PHASE_RESULT ===` covers. |
| `REASON` | Yes | enum | Closed enum, see below. |
| `BLOCKS` | Yes | string | The artifact path plus the section or acceptance-criterion id the answer would change (e.g. `notes.md#Acceptance-Criteria AC-2`). Mandatory and non-empty — see § BLOCKS below. |
| `QUESTION_n` | ≥1 | string | `n` is a stable 1-based question id within this hold. One line each; any number of them, in any order. |
| `SUPERSEDES` | No | string | The prior `hold_id` (as posted in fleetd's Linear comment), when re-holding after a partial answer. |

### REASON enum

| Value | Meaning |
|---|---|
| `AC_CONFLICT` | Two acceptance criteria (or an AC and the ticket description) contradict each other. |
| `SCOPE_UNDEFINED` | The ticket does not specify behavior the implementation now depends on. |
| `ARCH_COMMITMENT` | The answer commits the codebase to an architectural direction with no clearly-correct default. |
| `CREDENTIALS_MISSING` | A credential, API key, or access grant the phase needs is absent. |
| `EXTERNAL_DEPENDENCY` | Progress depends on a person or system outside the pipeline (a third-party vendor, another team). |
| `APPROVAL_REQUIRED` | An action needs explicit human sign-off beyond the ordinary gate (e.g. a destructive or irreversible step). |

## BLOCKS is the park-versus-assume test

`BLOCKS` is the **structural enforcement** of "park only for contract-changing
questions". The rule is not enforced by prose in the preamble alone — that would be an
unverifiable LLM judgement no bash gate can observe. An agent that can name the
artifact path plus the section or AC id the answer would change has demonstrated the
question is contract-changing; an agent that cannot has demonstrated it is not, and
the correct action is to record `META|assumption` and continue rather than hold.

The parser rejects a block whose `BLOCKS` is missing or empty. This is a rejection at
the contract boundary, exactly like a missing `VERDICT` in the phase-result schema.

## What the field set does not carry

The following fields are **refused outright** — the parser rejects a block that
carries any of them, rather than silently dropping them under a tolerant-unknown-field
rule. Each would be a defect if accepted:

| Field shape | Why it is refused |
|---|---|
| A resume position or step (`POSITION`, `STEP`, `RESUME_STEP`, `RESUME_POSITION`) | Position is owned by `store.record_position`. A fourth competing source would contradict the recorded rule that position is inferred at dispatch time, never recorded by an agent. |
| A held-at timestamp (`HELD_AT`) | The agent's clock is not authoritative — fleetd stamps `held_at` at the transition it performs. |
| A hold id (`HOLD_ID`) | fleetd mints `hold_id` (`hold:{tid}:g{gen}:a{attempt}`) from state it alone owns; an agent-chosen id would not be unique across generations. |
| A severity or priority (`SEVERITY`, `PRIORITY`) | Orchestration's call, derived from hold age — not something the requester declares about itself. |

The block also never carries a `hold_id`. This is deliberate, not an oversight: since
an agent cannot mint one and the parser never invents one, an **invalid** record can
never be mistaken for a releasable hold — there is nothing in it a release predicate
could match against.

## Tolerant transport, strict contract

Tolerated silently: leading/trailing whitespace, CRLF line endings, blank lines inside
the block, fields in any order, question ids in any order (the parser sorts them by id
in the canonical record), and any well-formed key outside the known set (recorded
nowhere — this block carries no `extra` bag, since an unknown key here is never
load-bearing).

Rejected at the contract boundary (`parse_status: invalid`):

- A line inside the block that is not `KEY: value`.
- A key outside `[A-Z][A-Z0-9_]*`.
- A duplicate field, including a duplicate `QUESTION_n`.
- A missing or empty required field (`SCHEMA_VERSION`, `PHASE`, `REASON`, `BLOCKS`).
- Zero `QUESTION_n` fields.
- `REASON` or `PHASE` outside their enums.
- A block's `PHASE` that does not match the invoking phase.
- Any of the four refused fields (`POSITION`/`STEP`/`RESUME_STEP`/`RESUME_POSITION`,
  `HELD_AT`, `HOLD_ID`, `SEVERITY`/`PRIORITY`).
- A missing `=== END HUMAN_HOLD ===` closing marker (truncated block — reported as
  `invalid`, never as `absent`).

**No block at all is different from every rejection above**: it is `parse_status:
absent`, nothing is written to the pipeline log, and the parser exits 0. This is the
one case that is a non-event rather than a defect — most returns carry no hold
request, and that must cost nothing.

## Rejection degrades visibly; it never vanishes

An `invalid` record is still written to the pipeline log as
`META|human-hold|waiting|{json}` with `parse_status: "invalid"` and the error — a
swallowed ask is the exact defect this capability exists to fix. It creates no hold
and is **never** eligible for automatic release; it is visible to `detect_human_hold`
(fleet-controller) at severity 1, and a human resolves it directly.

## Redaction

Every question value and `BLOCKS` are passed through a secret-redaction pass
(`_hh_redact` in `lib/human-hold-parse.sh`) **before** the record is built. Question
text reaches two external systems once a hold is created — the Linear comment and the
Slack notification — so redaction happens once, at the point agent text first becomes
a structured record, rather than being re-implemented (and inevitably missed once) at
each publication site. `lib/human-hold-parse.sh` reimplements the masking shape
`fleet-controller/lib/fleet-notify.sh`'s `_notify_mask` targets rather than sourcing
it — ticket-auto-pipeline does not depend on fleet-controller, and the dependency
direction must stay that way.

## Canonical JSON

```json
{
  "schema_version": 1,
  "phase": "APPRAISE",
  "reason": "SCOPE_UNDEFINED",
  "blocks": "notes.md#Acceptance-Criteria AC-2",
  "supersedes": "",
  "questions": [
    {"id": 1, "text": "Should the export include archived records?"},
    {"id": 2, "text": "Is a CSV format acceptable, or is XLSX required?"}
  ],
  "parse_status": "ok",
  "parse_error": ""
}
```

`phase` is always populated, including on rejection, because the caller passes it
explicitly (mirroring `phase-result-schema.md`). On an `invalid` record every other
field defaults to empty/`[]` — never a partially-populated record, since a half-read
request reads as a real one.

Note there is no `hold_id` key anywhere in this JSON, on any `parse_status` — see
§ "What the field set does not carry" above.

## What creates the row, and what does not

This parser writes **only** the pipeline-log projection
(`META|human-hold|waiting|{json}`). It never opens the fleet state store and never
mints a `hold_id` — `human-hold-request` spec, "the agent SHALL NOT write to the fleet
state store". Converting a valid, unreleased record into an authoritative
`tickets.held = 1` row, minting its `hold_id`, posting the Linear comment, and sending
the first notification are fleetd's job (`fleet-controller/fleetd/gate_hold.py`), not
this parser's.

## Exit Codes

| Code | Meaning |
|---|---|
| 0 | A valid block was parsed (`parse_status: ok`), or no block was present at all (`parse_status: absent`, nothing logged). |
| 1 | A block was present but failed the contract (`parse_status: invalid`). A record is still emitted and logged. Not an error — callers invoke with `\|\| true`. |
| 2 | The parser could not run: bad usage, unreadable capture file, `jq` unavailable. Nothing is logged. |

## Determinism

Identical input produces identical output. The parser performs no network calls,
spawns no agents, and reads only the paths given to it on the command line.

## Examples

### Valid — two questions (exit 0)

```
=== HUMAN_HOLD ===
SCHEMA_VERSION: 1
PHASE: EXEC
REASON: AC_CONFLICT
BLOCKS: simple-fix.md#Acceptance Criteria
QUESTION_1: AC-1 says "archive silently"; AC-3 says "notify the owner". Which wins?
=== END HUMAN_HOLD ===
```

### Invalid — empty BLOCKS (exit 1, logged as invalid)

```
=== HUMAN_HOLD ===
SCHEMA_VERSION: 1
PHASE: APPRAISE
REASON: SCOPE_UNDEFINED
BLOCKS:
QUESTION_1: What should happen here?
=== END HUMAN_HOLD ===
```

### Invalid — a resume position is refused (exit 1)

```
=== HUMAN_HOLD ===
SCHEMA_VERSION: 1
PHASE: IMPLEMENT
REASON: CREDENTIALS_MISSING
BLOCKS: notes.md#AC-4
POSITION: STEP_4
QUESTION_1: Where is the staging API key?
=== END HUMAN_HOLD ===
```

### Absent — no block at all (exit 0, nothing logged)

The agent returned prose only. This is the common case and costs nothing.

## Related

- [Pipeline log format](../pipeline-log-format.md) — the `human-hold` / `human-hold-released` / `assumption` META channels
- [Phase Result schema](phase-result-schema.md) — the sibling contract, and why this one is not that one
- `fleet-controller/CLAUDE.md` — `detect_human_hold`, `fleet_notify_hold`, and the `human` release predicate that consume this record
