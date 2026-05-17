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

### Phase 1 — Run the check

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

### Phase 2 — Summarize findings

Parse the output and present a clear summary to the user. Group findings into three categories:

**✅ Present** — already configured, nothing to do.

**🔧 Derivable** — missing but a sensible value was found by the filesystem walk. These can be written automatically:
- `REPOS_ROOT` — derived by walking up from the project directory to find the parent containing multiple git repos. The proposed value is shown in the output (`propose: /path/to/repos`).

**❌ Required (user must provide)** — these cannot be derived and the user must tell you:
- `LINEAR_API_KEY` — Linear API key (from Linear → Settings → API)
- `ANTHROPIC_AUTH_TOKEN` — Anthropic API key
- `GITHUB_PERSONAL_ACCESS_TOKEN` — GitHub personal access token
- `LOCAL_URL` — local dev server URL (e.g. `http://localhost:3000`)
- `UAT_URL` — UAT environment URL (e.g. `https://uat.example.com`)

**⚠️ Optional (user may provide)** — missing but not required to start:
- `BE_TEST_CMD` — backend test command (e.g. `npm test`)
- `SLACK_CHANNEL` — Slack channel for overseer notifications
- `WIKI_ROOT` — wiki path for documentation bootstrapping
- `GIT_AUTHOR_NAME` / `GIT_AUTHOR_EMAIL` — for commits
- `TICKET_AUTONOMY` — autonomy mode: `auto` / `semi-auto` / `manual`

### Phase 3 — Ask the user

Present the summary and ask:

> Here's what I found:
>
> **✅ Present:** (list what's OK)
>
> **🔧 Can derive:**
> - REPOS_ROOT → (proposed value) — I can write this to CLAUDE.md now. OK?
>
> **❌ Needs you:**
> - (list each missing required field)
>
> **⚠️ Optional (missing):**
> - (list optional fields that are missing)
>
> I can place everything in the right spot:
> - API keys → `~/.claude/settings.local.json` (env block)
> - Project fields → `./CLAUDE.md`
>
> What are the values for the missing fields? (Or say "skip" for optional ones.)

### Phase 4 — Place values

When the user provides values, write them to the correct location.

**API keys** go in `~/.claude/settings.local.json` under the `"env"` key:

```json
{
  "env": {
    "LINEAR_API_KEY": "<value>",
    "ANTHROPIC_AUTH_TOKEN": "<value>",
    "GITHUB_PERSONAL_ACCESS_TOKEN": "<value>"
  }
}
```

Use `Edit` to add each missing key to the existing `"env"` block. If the file doesn't exist or has no `"env"` block, create it with the full structure. Use `Bash` to check the current file first:
```bash
cat ~/.claude/settings.local.json 2>/dev/null || echo "{}"
```

**Project fields** go in the project's `./CLAUDE.md`. Add them as key-value lines at the end of the file (or in a `## Configuration` section if one exists):

```
REPOS_ROOT = /path/to/repos
LOCAL_URL = http://localhost:3000
UAT_URL = https://uat.example.com
BE_TEST_CMD = npm test
SLACK_CHANNEL = #tickets
WIKI_ROOT = docs/wiki
```

Use `Edit` to append these lines to `./CLAUDE.md`.

**⚠️ WARNING**: `~/.claude/settings.local.json` is a security-sensitive file. Never echo, cat, or display its contents to the user after writing. Confirm success only with "API keys written to settings.local.json."

### Phase 5 — Re-validate

After writing values, re-run Phase 1 to confirm all required fields pass. If anything still fails, report the remaining gaps.
