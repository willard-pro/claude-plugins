---
name: ticket-env-check
description: Validates all environment variables and CLAUDE.md fields required by the ticket-auto-pipeline. Run after first install, or when pipeline commands fail with auth/configuration errors.
---

# Ticket Environment Check

Validates everything the pipeline needs: API keys, tokens, and project-specific CLAUDE.md fields.

## Usage

```
/ticket-env-check
```

No arguments. Run from the project directory containing `CLAUDE.md`.

## Execution

### Step 1 — Run the check

Run `env-check.sh` and capture its output. Tries the synced `~/.claude/skills/lib/` path first (available after the plugin's SessionStart hook fires), falling back to the plugin cache.

```bash
ENV_CHECK=""
if [ -f ~/.claude/skills/lib/env-check.sh ]; then
  ENV_CHECK=~/.claude/skills/lib/env-check.sh
else
  ENV_CHECK="$(ls ~/.claude/plugins/cache/willard-pro-claude-plugins/ticket-auto-pipeline/*/lib/env-check.sh 2>/dev/null | sort -V | tail -1)"
fi
if [ -n "$ENV_CHECK" ]; then
  bash "$ENV_CHECK"
else
  echo "env-check.sh not found — reinstall the plugin"
fi
```

### Step 2 — Display the generated summary

Extract the block between `---BEGIN_SUMMARY---` and `---END_SUMMARY---` from the script output. Display it verbatim to the user — no edits, no filtering, no "helpful" trimming. The script has already generated the complete inventory correctly.

**DO NOT write any files.** This skill is read-only. The user decides what to set and where. If the user asks you to write values, only then proceed.

### Step 3 — Done

The check is complete. Every variable is listed — nothing can be missed because the script generated it, not the AI.
