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

### Step 1 — Run the check and write summary to file

Run `env-check.sh` with `--summary-file /tmp/ticket-env-summary.md`. Tries the synced `~/.claude/skills/lib/` path first, falling back to the plugin cache. The script writes a complete inventory to the file — no human-readable stdout, just a single confirmation line.

```bash
ENV_CHECK=""
if [ -f ~/.claude/skills/lib/env-check.sh ]; then
  ENV_CHECK=~/.claude/skills/lib/env-check.sh
else
  ENV_CHECK="$(ls ~/.claude/plugins/cache/willard-pro-claude-plugins/ticket-auto-pipeline/*/lib/env-check.sh 2>/dev/null | sort -V | tail -1)"
fi
if [ -n "$ENV_CHECK" ]; then
  bash "$ENV_CHECK" --summary-file /tmp/ticket-env-summary.md
else
  echo "env-check.sh not found — reinstall the plugin"
fi
```

### Step 2 — Display the results

Read the summary file using the `Read` tool. It will be shown to the user verbatim — every variable, every count, no filtering possible.

```
Read /tmp/ticket-env-summary.md
```

**DO NOT write any files.** This skill is read-only. The user decides what to set and where. If the user asks you to write values, only then proceed.
