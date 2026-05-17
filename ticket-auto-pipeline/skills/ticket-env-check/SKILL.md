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

Runs `env-check.sh` (synced to `~/.claude/skills/lib/` by the plugin startup hook), which checks additional env vars then delegates to `validate-env.sh` for core validation.

```bash
bash ~/.claude/skills/lib/env-check.sh
```

Checks performed:
- **Required**: `LINEAR_API_KEY`, `GITHUB_PERSONAL_ACCESS_TOKEN` (or `GH_TOKEN`), `ANTHROPIC_AUTH_TOKEN`
- **Optional**: `ANTHROPIC_BASE_URL`, `ANTHROPIC_MODEL`, `GIT_AUTHOR_NAME`, `GIT_AUTHOR_EMAIL`, `TICKET_AUTONOMY`
- **CLAUDE.md**: `REPOS_ROOT`, `LOCAL_URL`, `UAT_URL`, `BE_TEST_CMD`, `SLACK_CHANNEL`, `WIKI_ROOT`

On failure, prints the exact JSON snippet to add to `~/.claude/settings.local.json`.
