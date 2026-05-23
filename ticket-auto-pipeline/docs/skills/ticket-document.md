# ticket-document

> Generates ai-context.md after successful implementation. Diffs the branch, reads notes.md, classifies significance, and writes structured AI-optimized context to the ticket directory.

## What it does

`ticket-document` captures the "why" of an implementation for future AI agents. Once code is committed, it diffs the branch against `develop`, reads `notes.md` for design rationale, and classifies the change as trivial or non-trivial. The output is `ai-context.md` — a terse, structured file recording which patterns were applied, which decisions were made, and which files changed. Future agents (e.g. a second ticket touching the same code) read this file instead of re-deriving the same context from scratch.

## Trigger

**Slash command:** `/ticket-document <TICKET-ID>`

**Natural language:** "document WIL-42", "generate ai-context for WIL-42" (typically called by ticket-auto)

## Inputs

| Input | Source | Required |
|-------|--------|----------|
| Ticket ID | CLI argument | Yes |
| `notes.md` | Ticket workspace | Yes |
| Git diff | Implementation branch vs `develop` | Yes |
| `$LOG_FILE` / `$HB_LOG_FILE` | Environment (set by ticket-auto) | No (only in pipeline context) |

## Outputs / Artifacts

| Artifact | Location | Description |
|----------|----------|-------------|
| `ai-context.md` | `tickets/<ID>--slug/` | AI-optimized: patterns, decisions, significance, changed files |

## How it works

```mermaid
flowchart TD
    A([Start]) --> B[Read notes.md\ndesign rationale]
    B --> C[Git diff\nbranch vs develop]
    C --> D[Classify significance\ntrivial or non-trivial]
    D --> E[Extract patterns\nfrom changed code]
    E --> F[Write ai-context.md\nstructured AI-optimized format]
    F --> G([Done])
```

## Related skills

- [`/ticket-implement`](ticket-implement.md) — runs before this skill
- [`/ticket-verify`](ticket-verify.md) — runs after this skill
- [`/ticket-auto`](ticket-auto.md) — orchestrator that drives this skill automatically
