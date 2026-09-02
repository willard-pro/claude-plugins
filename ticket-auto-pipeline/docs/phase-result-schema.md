# Phase Result Block Schema

**Schema-Version: 1**
**Defined by:** `openspec/changes/rlvr-phase-result-contract/specs/phase-result-contract/spec.md`
**Parser:** `lib/phase-result-parse.sh`
**Emitted by:** `lib/skill-preamble-auto.md` § Phase result emission

## Overview

The `=== PHASE_RESULT ===` block is a terminal section a **loop-bearing phase agent**
appends to its return text. It makes the phase's own verdict machine-readable, so a
consumer that is code rather than an LLM — fleet-controller, a workflow script, a future
Python/SDK supervisor — can see what the phase did without inferring it from prose.

The loop-bearing phases are **IMPLEMENT**, **VERIFY**, and **PR-REVIEW**: exactly the
phases whose outcome is otherwise recoverable only by reading an agent's prose.
`APPRAISE`, `EXEC` and `GATE` do not emit — `gate-check.sh` already computes their
outcome deterministically and the router already writes `META|gate-result` and
`META|artifact`. `MAINTENANCE` does not emit — prescan returns its own per-repo
`PRESCAN_RESULT` block.

**This file is the source of truth.** Prompts, `SKILL.md` files and preamble sections
supply *parameters*; none of them restates the field set or the grammar. A schema change
is an edit here plus one edit in `lib/skill-preamble-auto.md`.

## The field set is the contract; the marker envelope is transport

The durable machine contract is the **field set** below and the canonical JSON the parser
produces from it. The `=== PHASE_RESULT ===` / `=== END PHASE_RESULT ===` marker envelope
and its `KEY: value` body are **transport** — the encoding chosen because nothing in the
bash path offers constrained decoding, and because the return text crosses a boundary
where a model composes a shell command.

When SDK-native structured output (`output_schema`) is available, the envelope is dropped
and the same canonical JSON reaches the same consumers. That is a **parser swap, not a
contract renegotiation**: no consumer changes, and this document does not change except
to delete the transport section.

## Format

### Schema-Version 1

```
=== PHASE_RESULT ===
SCHEMA_VERSION: 1
PHASE: VERIFY
VERIFIER: playwright_uat
VERDICT: PASS
CRITERIA_MET: 5
CRITERIA_TOTAL: 5
ATTEMPT: 1
EVIDENCE: All 5 acceptance criteria exercised against UAT; screenshots in ./logs/
UNADDRESSED:
=== END PHASE_RESULT ===
```

The block is the **last content of the return**. Anything after the closing marker is
ignored; anything before the opening marker is the agent's ordinary prose and is left
alone.

## Key syntax

- Keys match `[A-Z][A-Z0-9_]*` — uppercase, digits, underscore; no lowercase, no dashes.
- One `KEY: value` pair per line. Values are **single-line**.
- Values are **plain text**. No nested JSON, no quoting, no escaping — not for JSON, not
  for the shell. A value may contain `"`, `$`, backticks, `$(...)`, `&&`, `;`,
  backslashes, or Unicode; the parser treats every value as data and never evaluates it.
- A value may be empty (`UNADDRESSED:` with nothing after the colon).
- The first `:` separates key from value. A value may therefore contain further colons.

## Field Reference

| Field | Type | Required | Description |
|---|---|---|---|
| `SCHEMA_VERSION` | integer | Yes | Schema version for forward-compatible parsing. Current version: `1`. |
| `PHASE` | enum | Yes | The emitting phase. One of `IMPLEMENT`, `VERIFY`, `PR-REVIEW`. Carried into the canonical JSON as a first-class field so a consumer reading a whole log can attribute every record without positional inference. |
| `VERIFIER` | enum | Yes | Which verifier produced the verdict. One of the 14 established ids (see below). |
| `VERDICT` | enum | Yes | The phase's own claimed verdict. One of `PASS`, `FAIL`, `WARN`, `BLOCK` — the Phase 0 enum, reused unchanged. |
| `CRITERIA_MET` | integer | No | How many acceptance criteria the phase considers met. Defaults to `0`. |
| `CRITERIA_TOTAL` | integer | No | How many acceptance criteria exist. Defaults to `0`. |
| `ATTEMPT` | integer | No | 1-based attempt number within the phase's retry/iteration loop. Defaults to `1`. Lets a consumer distinguish a first-attempt failure from a final one. |
| `EVIDENCE` | string | No | One line naming what was actually observed — a command run, a URL exercised, a file written. Not a summary of intent. |
| `UNADDRESSED` | string | No | One line naming what the phase did **not** cover. Empty means nothing was knowingly left out. |

`SUMMARY` and `NEXT_ACTION` are deliberately **absent**. A return says what happened; a
handoff says what the next phase needs. Those are two objects, and this is the first one.

### VERDICT enum

| Value | Meaning |
|---|---|
| `PASS` | The phase met its criteria. |
| `FAIL` | The phase did not meet its criteria and the loop may retry. |
| `WARN` | The phase completed with findings that do not block, but that a consumer may act on. |
| `BLOCK` | The phase found something that must stop forward progress. |

### VERIFIER enum

The 14 verifier ids established by `lib/verifier-result.sh` call sites. Counted from the
call sites on 2026-09-02; earlier documents claiming 11 or 16 were never verified.

| Id | Established at |
|---|---|
| `adversarial_review` | `skills/ticket-appraise-exec/SKILL.md` |
| `audit` | `skills/ticket-audit/SKILL.md` |
| `build_only` | `skills/ticket-verify/SKILL.md` |
| `critique` | `skills/ticket-critique/SKILL.md` |
| `gate_check` | `lib/gate-check.sh` |
| `implement_tests` | `skills/ticket-implement/SKILL.md` |
| `live_backend` | `skills/ticket-verify/SKILL.md` |
| `playwright_uat` | `skills/ticket-verify/SKILL.md` |
| `pr_review` | `skills/ticket-pr-review/SKILL.md` |
| `prescan_verify` | `skills/ticket-prescan/SKILL.md` |
| `regression_guard` | `skills/ticket-appraise-exec/SKILL.md` |
| `return_completeness` | `lib/return-completeness-check.sh` |
| `ticket_document` | `skills/ticket-document/SKILL.md` |
| `ticket_retro` | `skills/ticket-retro/SKILL.md` |

Only four of these are reachable from a loop-bearing phase in practice:
`implement_tests` (IMPLEMENT), `playwright_uat` / `build_only` / `live_backend` (VERIFY,
whichever mode the run used), and `pr_review` (PR-REVIEW). The full enum is accepted so
the contract does not have to be renegotiated when emission widens.

## Tolerant transport, strict contract

The two boundaries are deliberately asymmetric.

**Tolerated at the transport boundary** — accepted silently, producing the same canonical
JSON as the canonical form would:

- Leading and trailing whitespace on markers, keys and values.
- CRLF line endings.
- Blank lines inside the block.
- Fields in any order.
- Unknown fields. They are recorded under `extra` and are **not** a contract violation —
  a future emitter adding a field must not break a current parser.
- More than one block in the capture file. The **last** block wins, because
  `capture_agent_result` appends retried attempts to a single file.

**Rejected at the contract boundary** — every one of these degrades the claim to
`UNKNOWN`:

- A line inside the block that is not `KEY: value`.
- A key outside `[A-Z][A-Z0-9_]*`.
- A missing required field.
- A non-integer value in an integer field.
- A value outside a closed enum (`VERDICT: SUCCESS`, `PHASE: APPRAISE`).
- A missing `=== END PHASE_RESULT ===` closing marker.
- A truncated block.

A rejection is **never** a pipeline halt and **never** a fabricated success. An
unverifiable claim is itself a signal.

## Canonical JSON

The parser emits exactly one object on stdout and appends it to the pipeline log as
`META|phase-result|info|{json}`. JSON is built by `jq` with `--arg`/`--argjson` argument
binding — never by bash string interpolation.

```json
{
  "schema_version": 1,
  "phase": "VERIFY",
  "verifier": "playwright_uat",
  "claimed_verdict": "PASS",
  "criteria_met": 5,
  "criteria_total": 5,
  "attempt": 1,
  "evidence": "All 5 acceptance criteria exercised against UAT",
  "unaddressed": "",
  "extra": {},
  "parse_status": "ok",
  "parse_error": ""
}
```

`phase` is always populated, including on rejection, because the caller passes it
explicitly. Everything else on a rejected record is defaulted:

```json
{
  "schema_version": 0,
  "phase": "VERIFY",
  "verifier": "",
  "claimed_verdict": "UNKNOWN",
  "criteria_met": 0,
  "criteria_total": 0,
  "attempt": 0,
  "evidence": "",
  "unaddressed": "",
  "extra": {},
  "parse_status": "invalid",
  "parse_error": "missing closing marker"
}
```

`parse_status` is one of `ok`, `invalid` (a block was present but failed the contract) or
`absent` (no block at all).

## Capture — who writes the file the parser reads

The parser reads a **file**. An agent cannot write its own return to a file, because the
return is not complete until the agent stops. Capture is therefore always the **caller's**
responsibility, and the caller differs by invocation model. The parser accepts all three
shapes below without being told which one it holds.

| Invocation | Who captures | What lands in the file |
|---|---|---|
| Router + sub-agent (today) | The router, via `spawn_capture … RESULT_FILE=<path>` → `capture_agent_result` → `./logs/{TID}-{phase}-agent.log` | Plain return text, one block appended per attempt |
| One-shot `claude -p` per phase (target) | The **caller** redirects the worker's stdout to a file | Plain text, or a `--output-format json` / `stream-json` envelope |
| Any other consumer | Whatever wrote the file | Any of the above |

For the one-shot model the caller does exactly this, and nothing more:

```bash
claude -p "/ticket-verify {TID} …" --output-format json > "logs/{TID}-verify-agent.log"
bash "$CLAUDE_SKILLS_LIB/phase-result-parse.sh" --phase VERIFY \
  --return-file "logs/{TID}-verify-agent.log" --log-file "$LOG_FILE" || true
```

`--output-format json` wraps the return in a JSON object whose `.result` is a *string*, so
every newline the block depends on becomes a literal `\n` escape. Line-oriented extraction
would report `absent` on a perfectly valid emission. The parser unwraps a `.result` string
itself (`_pr_unwrap`) — for the single-object `json` form and for the last `.result` in the
`stream-json` line stream — so **no caller needs to know which output mode produced the
file**. Plain text passes through untouched; a JSON file that is not a claude envelope is
treated as plain text rather than rejected.

Two channels in this repo **cannot** carry the block and must not be used for capture:

- `hooks/stop-capture.sh`'s `last_assistant_message` head-truncates to 4000 characters,
  which is exactly the tail the block occupies.
- Any consumer that reads only the pipeline log's own `MSG` column — the block lives in the
  agent's return, not in the log, until this parser puts a record there.

## What the field set does not carry

The intended end state is a deterministic supervisor that reproduces the ticket-auto
router's decisions in code, invoking each phase as its own `claude -p` process. Audited
against every post-agent branch the router takes, this field set is **not sufficient on its
own**. A code supervisor needs the records below *plus* the channels named here:

| Router decision | Where the input actually lives | Why it is not a phase-result field |
|---|---|---|
| Smooth / Rough / Hard outcome label | `IMPLEMENT\|implement-outcome\|info\|`, read by `lib/outcome-label-check.sh` | Difficulty is orthogonal to pass/fail. A phase can succeed roughly; `VERDICT` cannot express that. |
| Auto-merge eligibility | `META\|outcome-label`, `PR-REVIEW\|checkout-pr\|done\|` (PR number), `AUTONOMY`, `COMPLEXITY`, and a live `gh pr view` | The highest-stakes decision in the pipeline deliberately depends on live repo state, not on a claim the agent wrote about itself. |
| Implement completeness | `lib/return-completeness-check.sh` counting unchecked boxes | `CRITERIA_MET`/`CRITERIA_TOTAL` is the agent's *claim* about the same quantity. An independently computed number must never be replaced by a self-reported one. |
| Mid-run crash resume | `VERIFY\|checkpoint\|done\|criterion-{N}-pass` | The block is terminal-only. An agent that crashes never emits one, which is exactly when resume matters. |
| Retry / iteration caps | `VERIFY_ATTEMPTS`, `ITERATION`, `RECONCILE_CYCLE`, `PR_FEEDBACK_CYCLE` from `detect-resume.sh` | Counters are caller-owned state. `ATTEMPT` echoes the caller's number back for correlation; it is not the source of truth for it. |

This is a deliberate boundary, not an oversight: everything above is either independently
verifiable or caller-owned, and a self-reported field would be strictly weaker. The
contract's job is to make the *agent's verdict* machine-readable, not to become the single
source for decisions that already have better sources.

## Consumer fallback

A consumer that routes on phase results and meets an absent or `UNKNOWN` claim **SHALL**
fall back to the whole-run classification produced by `fleet_ticket_terminal_state`
(`fleet-controller/lib/fleet-reconcile.sh`), and **SHALL NOT** synthesize a verdict,
infer one from adjacent log lines, or read a missing claim as either success or failure.

Emission depends on an agent following a prompt instruction, and no deterministic check
can observe whether it did. Per-phase data is an enhancement over whole-run data, never a
replacement that fails closed. See `pipeline-log-format.md` § `phase-result`.

## Exit Codes

`lib/phase-result-parse.sh` follows the `return-completeness-check.sh` idiom:

| Code | Meaning |
|---|---|
| 0 | A valid block was parsed. `parse_status` is `ok`. |
| 1 | The claim is unverifiable — no block, or a block that failed the contract. An `UNKNOWN` record is still emitted and still logged. |
| 2 | The parser could not run: bad usage, unreadable capture file, `jq` unavailable. Nothing is logged. |

Exit 1 is a normal outcome, not an error. Callers invoke the parser with `|| true`.

## Determinism

Identical input produces identical output. The parser performs no network calls, spawns
no agents, and reads only the paths given to it on the command line.

## Examples

### Valid — VERIFY pass (exit 0)

```
=== PHASE_RESULT ===
SCHEMA_VERSION: 1
PHASE: VERIFY
VERIFIER: playwright_uat
VERDICT: PASS
CRITERIA_MET: 3
CRITERIA_TOTAL: 3
ATTEMPT: 1
EVIDENCE: Logged in as test user, exercised AC1-AC3 against UAT
UNADDRESSED:
=== END PHASE_RESULT ===
```

### Valid — PR-REVIEW block, reordered fields and an unknown key (exit 0)

Field order is free and `REVIEWER_MODEL` is recorded under `extra` rather than rejected.

```
=== PHASE_RESULT ===
VERDICT: BLOCK
PHASE: PR-REVIEW
REVIEWER_MODEL: claude-opus-5
SCHEMA_VERSION: 1
VERIFIER: pr_review
UNADDRESSED: Performance of the new query under load
EVIDENCE: Reviewed 4 changed files; found an unguarded null deref in auth.ts:88
=== END PHASE_RESULT ===
```

### Valid — values carry shell metacharacters (exit 0)

Round-tripped verbatim. Nothing is expanded and nothing is executed.

```
=== PHASE_RESULT ===
SCHEMA_VERSION: 1
PHASE: IMPLEMENT
VERIFIER: implement_tests
VERDICT: FAIL
EVIDENCE: `make test` failed: expected "a $b" && got `c`; see $(pwd)/logs/out.txt
=== END PHASE_RESULT ===
```

### Invalid — missing closing marker (exit 1, `UNKNOWN`)

```
=== PHASE_RESULT ===
SCHEMA_VERSION: 1
PHASE: VERIFY
VERIFIER: playwright_uat
VERDICT: PASS
```

### Invalid — verdict outside the enum (exit 1, `UNKNOWN`)

`SUCCESS` is not coerced to `PASS`. Coercion is how a false claim reaches a merge.

```
=== PHASE_RESULT ===
SCHEMA_VERSION: 1
PHASE: VERIFY
VERIFIER: playwright_uat
VERDICT: SUCCESS
=== END PHASE_RESULT ===
```

### Invalid — lowercase key (exit 1, `UNKNOWN`)

```
=== PHASE_RESULT ===
SCHEMA_VERSION: 1
phase: VERIFY
VERIFIER: playwright_uat
VERDICT: PASS
=== END PHASE_RESULT ===
```

### Absent — no block at all (exit 1, `UNKNOWN`)

The agent returned prose only. The record is `parse_status: absent`, the pipeline
continues unchanged, and any consumer falls back to whole-run classification.

## Related

- [Pipeline log format](../pipeline-log-format.md) — the `phase-result` META channel
- [Branch Directive schema](branch-directive-schema.md) — the structural precedent
- [Planner Context schema](planner-context-schema.md) — the other block contract
