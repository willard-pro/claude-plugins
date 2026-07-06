---
name: ticket-flow
description: ticket-flow
---

# ticket-flow

Centralized Linear state/label executor for the ticket workflow. Every ticket skill delegates state transitions and label changes here — no skill calls Linear for state or labels directly.

## Usage

Invoke with:

```
/ticket-flow <TICKET-ID> <TRIGGER> [--data key=value] [--dry-run]
```

Where `--data` supplies trigger-specific values (e.g. `complexity=simple`, `outcome=Smooth`).

## Execution

This skill is a thin wrapper around `flow.sh`. All state machine logic, label computation, and Linear API calls are handled deterministically by the script.

`flow.sh` sources `lib/linear-api.sh` for all GraphQL operations. When `$LINEAR_API_KEY` is set, operations use direct GraphQL calls. When unset, `flow.sh` will fail with a clear error — set `$LINEAR_API_KEY` before invoking this skill.

```bash
_flow_sh="${HOME}/.claude/skills/ticket-flow/flow.sh"
[ -f "$_flow_sh" ] || _flow_sh=$(find "${HOME}/.claude/plugins/cache" -name "flow.sh" -path "*/ticket-auto-pipeline/*/skills/ticket-flow/flow.sh" 2>/dev/null | sort | tail -1)
bash "$_flow_sh" "<TICKET-ID>" "<TRIGGER>" [--data key=value] [--dry-run]
```

## Reference: State Machine

### States

| State | Meaning |
|-------|---------|
| `Backlog` | New, unclaimed |
| `Blocked` | Waiting on external dependency |
| `Todo` | Claimed, under appraisal |
| `Approve` | Appraisal done, awaiting human sign-off |
| `Ready` | Approved, implementation in progress |
| `Review` | PR(s) open, awaiting code review / QA |
| `UAT` | Code reviewed, awaiting business partner acceptance testing |
| `Done` | Verified — all acceptance criteria confirmed |

### Labels

| Label | Meaning |
|-------|---------|
| `claimed` | Actively being worked (set at appraisal start, cleared at Done) |
| `approved` | Human approved the appraisal — gates implementation |
| `rejected` | PR review found gaps OR UAT verification failed — ticket needs rework |
| `reviewed` | PR review passed — ready for QA verification |
| `simple` | Predicted simple (set by appraise) |
| `complex` | Predicted complex (set by appraise) |
| `Smooth` | Implementation went smoothly |
| `Rough` | Implementation had friction |
| `Hard` | Implementation was difficult |
| `bug` | Defect fix |
| `feature` | New capability |
| `needs-info` | Blocked waiting for clarification |
| `repro-failed` | Bug could not be reproduced |

### Transitions

| Trigger | State | Labels Added | Labels Removed | Notes |
|---------|-------|-------------|----------------|-------|
| `appraise-start` | `Todo` | `claimed`, `{simple\|complex}` | — | Also sets `assignee: "me"` |
| `appraise-complete` | `Approve` | — | — | |
| `human-approve` | `Ready` | `approved` | `rejected` | |
| `human-reject` | `Todo` | — | — | |
| `implement-outcome` | — | `{Smooth\|Rough\|Hard}` | — | No state change |
| `implement-complete` | `Review` | — | `approved` | |
| `pr-review-pass-done` | `Done` | `reviewed` | `rejected`, `claimed` | Use when no UAT_URL |
| `pr-review-pass-uat` | `UAT` | `reviewed` | `rejected` | Use when UAT_URL present |
| `pr-review-fail` | — | `rejected` | — | No state change |
| `pr-iterate` | `Ready` | `approved` | `reviewed`, `rejected` | |
| `uat-pass` | `Done` | — | `claimed`, `reviewed` | |
| `uat-fail` | `Ready` | `rejected` | `reviewed` | |
| `needs-info` | — | `needs-info` | — | No state change |
| `needs-info-resolved` | — | — | `needs-info` | No state change |
| `re-claim` | — | — | `approved` | No state change; restarts gate hold cycle |

## Preflight Sentinel

`validate-linear-config.sh` writes a sentinel file at:
```
~/.claude/state/ticket-flow/validated-{TEAM_ID}
```

The sentinel contains `schema_version`, `sm_hash` (SHA256 of `state-machine.json`), and `validated_at`. `ticket-auto` Step 0.4 reads this file — if it exists and the hash matches the current `state-machine.json`, validation is skipped (warm hit). Any edit to `state-machine.json` automatically invalidates the sentinel.

To force re-validation:
```bash
_validate_sh="${HOME}/.claude/skills/ticket-flow/validate-linear-config.sh"
[ -f "$_validate_sh" ] || _validate_sh=$(find "${HOME}/.claude/plugins/cache" -name "validate-linear-config.sh" -path "*/ticket-auto-pipeline/*/validate-linear-config.sh" 2>/dev/null | sort | tail -1)
bash "$_validate_sh" --force
```

To delete the sentinel manually:
```bash
rm ~/.claude/state/ticket-flow/validated-{TEAM_ID}
```
