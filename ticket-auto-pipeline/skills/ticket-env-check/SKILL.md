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

### Step 2 — Build checklist from structured output

Extract every line between `---BEGIN_VARS---` and `---END_VARS---`. Format:

```
STATUS|NAME|VALUE|DERIVABLE|LOCATION|MESSAGE
```

Create a task for each variable. The task action depends on STATUS and DERIVABLE:

| If | Action |
|----|--------|
| `STATUS=ok` | Mark done immediately |
| `DERIVABLE=yes` | Write VALUE to LOCATION (`env` → `~/.claude/settings.local.json`, `claude` → `./CLAUDE.md`). Ask user to confirm, then mark done. |
| `STATUS=miss, DERIVABLE=no` | Ask user for the value. MESSAGE explains what it is. Write to LOCATION. Mark done when provided. |
| `STATUS=warn, DERIVABLE=no` | Tell user what's missing (MESSAGE). Ask: "Provide a value or skip?" Write if given, skip if not. Mark done either way. |

Process tasks one at a time. After each task completes, move to the next.

### Step 3 — Verify

After all tasks are done, re-run Step 1. All variables should now be `STATUS=ok`. If any are still `miss` or `warn`, loop back to Step 2 for those remaining.

### Placement reference

- `~/.claude/settings.local.json` → `"env"` block for API keys/tokens
- `./CLAUDE.md` → key-value lines for project config

**⚠️ WARNING**: `~/.claude/settings.local.json` is a security-sensitive file. Never display its contents. Confirm writes with "API keys written."
