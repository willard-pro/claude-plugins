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
| `Created` | ISO 8601 | Yes | When the directive was created. Example: `2026-07-25T10:00:00Z`. |

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
