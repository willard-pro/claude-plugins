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

Run `env-check.sh` and capture output. Tries the synced `~/.claude/skills/lib/` path first, falling back to the plugin cache.

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

### Step 2 — Display as table

Parse the `---BEGIN_VARS---` / `---END_VARS---` block from the output. Skip the header row. Render the rows as a markdown table with columns: **Name**, **Status**, **Value**, **Location**, **Note**.

**DO NOT write any files.** This skill is read-only. The user decides what to set and where.
