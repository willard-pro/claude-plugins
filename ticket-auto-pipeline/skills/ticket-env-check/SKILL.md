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

### Phase 2 — Parse structured output

Extract the `---BEGIN_VARS---` / `---END_VARS---` block from the script output. Each line is pipe-delimited:

```
STATUS|NAME|VALUE|DERIVABLE|LOCATION|MESSAGE
```

Fields:
- `STATUS`: `ok` (present), `miss` (required, missing), `warn` (optional, missing)
- `NAME`: variable name
- `VALUE`: current or proposed value (empty if none)
- `DERIVABLE`: `yes` if the script found/proposes a value, `no` if user must provide
- `LOCATION`: `env` (goes in `~/.claude/settings.local.json`), `claude` (goes in `./CLAUDE.md`), `either` (works in both)
- `MESSAGE`: human-readable hint (what it's for, example value)

Parse every line and group into four categories:

1. **✅ Present** — `STATUS=ok`. List the value next to each name.
2. **🔧 Can derive** — `(STATUS=miss OR STATUS=warn) AND DERIVABLE=yes`. Script found a value — offer to write it.
3. **❌ Required** — `STATUS=miss AND DERIVABLE=no`. Must ask the user.
4. **⚠️ Optional** — `STATUS=warn AND DERIVABLE=no`. Ask, but allow skip.

### Phase 3 — Present summary

Build the summary from the parsed groups. Include EVERY variable — do not omit any.

> Here's what I found:
>
> **✅ Present (N):** (list all ok vars with values)
> - NAME — value
>
> **🔧 Can derive (N):** (list all derivable vars with proposed values)
> - NAME → proposed-value — MESSAGE
>   → I can write this to [LOCATION]. OK?
>
> **❌ Needs you (N):** (list all miss+not-derivable vars with hints)
> - NAME — MESSAGE
>
> **⚠️ Optional missing (N):** (list all warn+not-derivable vars with hints)
> - NAME — MESSAGE
>
> Where to place each:
> - API keys/tokens (LOCATION=env) → `~/.claude/settings.local.json` env block
> - Project config (LOCATION=claude) → `./CLAUDE.md`
> - LOCATION=either → ask user preference
>
> What are the values for the required fields? (Or "skip" for optional ones.)

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
