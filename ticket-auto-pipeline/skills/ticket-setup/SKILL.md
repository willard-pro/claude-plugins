---
name: ticket-setup
description: Creates the local workspace for a Linear ticket — fetches issue data, derives the directory path, creates the directory structure, and writes context.md and a minimal notes.md. Returns the ticket dir path and key issue fields for the calling skill to continue. Used internally by ticket-appraise and ticket-reproduce. Also callable directly if you just want to scaffold a ticket workspace.
---

# Ticket Setup

Creates the local workspace for a Linear ticket — fetches issue data, derives the directory path, creates the directory structure, and writes `context.md` and a minimal `notes.md`.

## Usage

```
/ticket-setup <TICKET-ID>
```

## Pipeline Preamble

Follow the pipeline preamble in `~/.claude/skills/lib/skill-preamble.md` with parameters: TICKET_ID=<from args>, PHASE=none, FROM_FLAG=none, HAS_LINEAR_ACCESS=false, HAS_GUARD=false, HAS_PROJECT_CONTEXT=false, HAS_LOGGING=false, HAS_HEARTBEAT=false, HAS_STEP_DISPATCH=false, HAS_TASK_TRACKER=false

## Execution

This skill is a thin wrapper around `setup.sh`. All Linear API calls, directory creation, and file generation are handled deterministically by the script.

```bash
bash ~/.claude/skills/ticket-setup/setup.sh "<TICKET-ID>"
```

The script emits a JSON summary to stdout with keys: `ticket_dir`, `url`, `title`, `status`, `project`, `epic`, `existing`.

Callers read the JSON output to determine the ticket directory path and whether the workspace already existed.
