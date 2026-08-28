# Branch Directive Block Schema

**Schema-Version: 1**
**Defined by:** `openspec/changes/shared-branch-resolution/specs/branch-directive/spec.md`
**Validator:** `lib/branch-directive-check.sh`

## Overview

The `## Branch Directive` block is a structured markdown section placed in the **parent epic's description** (never in child tickets). It declares a shared integration branch that child tickets under the epic should target. ticket-auto reads this block at pipeline start to determine which branches to create, base work on, and merge into.

The directive is **advisory by absence, binding by presence**. A parent without a directive behaves identically to pre-change behavior (branches target the default base). A parent with a malformed directive gate-stops — a typo'd branch name must never silently merge epic work into the trunk.

## Format

### Schema-Version 1

```
## Branch Directive
**Schema-Version:** 1
**Branch:** <branch-name>
**Base:** <branch-name>
**Merge Policy:** manual | on-all-children-done
**Sync Policy:** rebase-on-base-change | none
**UAT Policy:** per-ticket | epic        # optional
**Created:** <ISO 8601 timestamp>
```

## Field Reference

| Field | Type | Required | Description |
|---|---|---|---|
| `Schema-Version` | integer | Yes | Schema version for forward-compatible parsing. Initial version: `1`. |
| `Branch` | string | Yes | The integration branch name. Must match the branch-name charset rule (see below). This is the branch child tickets target for merge. Example: `epic/debt-collection-v2`. |
| `Base` | string | Yes | The base branch the integration branch was created from. Must match the same branch-name charset rule. Example: `develop`. |
| `Merge Policy` | enum | Yes | `manual` — PRs must be merged by a human. `on-all-children-done` — integration PR is created when all child tickets reach Done; merge is still manual (auto-merge is never permitted for integration branches). |
| `Sync Policy` | enum | Yes | `rebase-on-base-change` — the integration branch is rebased onto Base when Base advances. `none` — no automatic sync; conflicts surface at PR time. |
| `UAT Policy` | enum | **No** | Where acceptance happens. `per-ticket` (default when the field is absent) — each child is accepted individually, so a passing PR review routes `Review → UAT`. `epic` — acceptance happens once, on the epic itself, so a passing PR review routes `Review → Done`. See below. |
| `Created` | ISO 8601 | Yes | When the directive was created. Example: `2026-07-25T10:00:00Z`. |

## UAT Policy

An epic that accumulates all its children's commits on one shared branch is not observable in a
UAT environment until that branch integrates into its Base and deploys. For such an epic,
per-ticket acceptance is not merely inconvenient — it is undefined, because there is no
environment in which a single child can be seen.

Worse, it deadlocks. `blocked-by:{ID}` resolves strictly on the blocker reaching `Done`, so a
child parked in `UAT` never releases its dependents, the dependents never complete, the epic
never integrates, and the epic-level UAT that would release the original child never happens.

Declaring `**UAT Policy:** epic` moves acceptance to the epic issue:

- A child whose PR review passes transitions `Review → Done` rather than `Review → UAT`, so the
  dependency chain keeps moving. `Done` here means *code-complete, reviewed, merged to the epic
  branch* — which is precisely everything that can be verified about one child of such an epic.
- `ticket-verify --env uat` **refuses** for such a child: the epic branch is not deployed to that
  environment, so any result would be meaningless. `--env local` is unaffected.
- The epic itself carries acceptance via `epic-integration-open` (→ `Review`), `epic-uat-start`
  (`Review` → `UAT`), and `epic-uat-pass` (`UAT` → `Done`).

**Parsing rules:**

- The field is **optional**. When absent, the resolved policy is `per-ticket` and behaviour is
  exactly as it was before the field existed. No existing epic changes behaviour.
- The field is parsed and enum-validated **at any declared Schema-Version**. It is deliberately
  *not* version-gated: an operator who hand-adds the line without also bumping `Schema-Version`
  must still get the behaviour, otherwise the field is a silent no-op — the precise failure this
  field exists to fix.
- An unrecognised value is **malformed** (exit 2), not a silent fallback to the default.

**Behavioural divergence worth knowing:** a child reaching `Done` under `epic` policy keeps its
`reviewed` label, whereas a `per-ticket` child sheds it via `uat-pass`. Nothing consumes this
today, but a future "is this in flight?" heuristic keyed on `reviewed` would be wrong for
epic-policy tickets.

**Rollback** is a description edit: removing the `UAT Policy` line restores `per-ticket` routing
for that epic's children immediately, with no code change.

## Branch Name Rules

Branch names must match: `^[a-z0-9][a-z0-9._/-]{0,98}$`

Explicit rejection list:
- `..` (path traversal)
- Leading `/` (absolute path)
- Trailing `/` (directory ambiguity)
- Whitespace characters (space, tab, newline)
- Shell metacharacters: `` ; ` $ ( ) { } < > | & ! # ~ \ ' " * ? ``

Violations gate-stop the pipeline with `BRANCH_DIRECTIVE_INVALID`.

## Exit Codes

| Code | Meaning |
|---|---|
| 0 | Valid — block present, all required fields valid. Parsed values emitted to stdout. |
| 1 | Section absent — no `## Branch Directive` heading found. Caller should use default branch resolution. |
| 2 | Present but malformed — missing required fields, invalid enum values, non-integer Schema-Version, invalid branch name. Gate-stop. |

## Determinism

All validation is pure bash. No LLM calls, no fuzzy matching. Field names must match exactly (case-sensitive). The validator itself is deterministic given the same input.

Schema-Version tolerance ensures forward compatibility: a future version higher than the known max produces a stderr warning but exits 0 (valid). A non-integer Schema-Version exits 2 (malformed).

## Directive Placement

The `## Branch Directive` block lives **only on the parent epic**. It is never copied into child ticket bodies. This prevents silent desynchronization: if the directive were copied and the epic later edited, every child would carry a stale copy with no arbiter to detect the drift. Children resolve the directive at pipeline start by reading the parent's current description, so an epic edit takes effect immediately.

## Examples

### Valid directive (exit 0)
```
## Branch Directive
**Schema-Version:** 1
**Branch:** epic/debt-collection-v2
**Base:** develop
**Merge Policy:** manual
**Sync Policy:** rebase-on-base-change
**Created:** 2026-07-25T10:00:00Z
```

### Section absent (exit 1)
No `## Branch Directive` heading in the parent description. Caller falls back to default branch resolution.

### Malformed — missing field (exit 2)
```
## Branch Directive
**Schema-Version:** 1
**Branch:** epic/my-feature
**Base:** develop
**Merge Policy:** manual
```
Missing `Sync Policy` and `Created` — exits 2.

### Malformed — bad branch name (exit 2)
```
## Branch Directive
**Schema-Version:** 1
**Branch:** ../escape/develop
**Base:** develop
**Merge Policy:** manual
**Sync Policy:** rebase-on-base-change
**Created:** 2026-07-25T10:00:00Z
```
`Branch` contains `..` — exits 2.

### Malformed — invalid enum (exit 2)
```
## Branch Directive
**Schema-Version:** 1
**Branch:** epic/my-feature
**Base:** develop
**Merge Policy:** auto
**Sync Policy:** rebase-on-base-change
**Created:** 2026-07-25T10:00:00Z
```
`Merge Policy` is `auto`, not `manual` or `on-all-children-done` — exits 2.
