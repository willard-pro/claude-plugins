# [auto-retro] {SIGNATURE}: {ONE_LINE_SUMMARY}

<!--
  Template for pipeline-postmortem.sh auto-filed GitHub issues.
  Labels: auto-retro, severity:{SEVERITY}
  See: openspec/changes/ticket-auto-phase-3-pipeline-postmortem/
-->

## What Failed

{DESCRIPTION}

## Evidence

| Field | Value |
|-------|-------|
| Signature | `{SIGNATURE}` |
| Exit Path | `{EXIT_PATH}` |
| Ticket | `{TICKET_ID}` |
| Run ID | `{RUN_ID}` |
| Severity | `{SEVERITY}` |
| Mislabeled Outcome | `{MISLABELED}` |

### Verifier Results (non-PASS)

```
{VERIFIER_FAILURES}
```

### Phase Inspector Warnings

```
{INSPECTOR_WARNINGS}
```

### Gate-Stop Details

```
{GATE_STOP_DETAILS}
```

## Affected Component

- **Classification**: `{CLASSIFICATION}`
- **Phase**: `{PHASE}`

## Suggested Fix

{SUGGESTED_FIX}

## Resolution

- [ ] Root cause confirmed
- [ ] Fix implemented
- [ ] Fix verified (issue closed by post-mortem on next run with same signature)

---
*Filed by [ticket-auto-pipeline post-mortem](https://github.com/willard-pro/claude-plugins/blob/main/ticket-auto-pipeline/lib/pipeline-postmortem.sh) — RLVR Phase 3*
