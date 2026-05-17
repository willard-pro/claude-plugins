---
name: ticket-env-check
description: Validates all environment variables and CLAUDE.md fields required by the ticket-auto-pipeline. Run after first install, or when pipeline commands fail with auth/configuration errors.
---

# Ticket Environment Check

Validates everything the pipeline needs: API keys, tokens, and project-specific `CLAUDE.md` fields.

## Usage

```
/ticket-env-check
```

No arguments. Run from the project directory containing `CLAUDE.md`.

## Execution

Runs `env-check.sh`, a self-contained script that validates all env vars and CLAUDE.md fields with auto-derived proposals. Tries the synced `~/.claude/skills/lib/` path first (available after the plugin's SessionStart hook fires), falling back to the plugin cache.

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

Checks performed:
- **Required**: `LINEAR_API_KEY`, `GITHUB_PERSONAL_ACCESS_TOKEN` (or `GH_TOKEN`), `ANTHROPIC_AUTH_TOKEN`
- **Optional**: `ANTHROPIC_BASE_URL`, `ANTHROPIC_MODEL`, `GIT_AUTHOR_NAME`, `GIT_AUTHOR_EMAIL`, `TICKET_AUTONOMY`
- **CLAUDE.md**: `REPOS_ROOT`, `LOCAL_URL`, `UAT_URL`, `BE_TEST_CMD`, `SLACK_CHANNEL`, `WIKI_ROOT`

On failure, prints the exact JSON snippet to add to `~/.claude/settings.local.json`.
