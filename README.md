# willard-pro/claude-plugins

Claude Code plugin marketplace — ticket automation pipelines and development tooling.

## What's Here

A marketplace of installable Claude Code plugins. Add this marketplace to Claude Code to install any plugin below.

| Plugin | Version | Description |
|--------|---------|-------------|
| `ticket-auto-pipeline` | 0.2.0 | Fully autonomous Linear ticket pipeline — appraise, implement, verify, and merge with zero user input. 20+ slash commands, state-machine-driven flow control, pipeline safety gates, and retrospective analysis. |

## Add This Marketplace

```bash
claude plugin marketplace add willard-pro/claude-plugins
```

Then install any plugin:

```bash
claude plugin install ticket-auto-pipeline@willard-pro-claude-plugins
```

### Verify Environment

From within Claude Code, run the env check slash command:

```
/ticket-env-check
```

This validates all required env vars (`LINEAR_API_KEY`, `GITHUB_PERSONAL_ACCESS_TOKEN`/`GH_TOKEN`, `ANTHROPIC_AUTH_TOKEN`) plus CLAUDE.md fields (`REPOS_ROOT`, `LOCAL_URL`, `UAT_URL`). Fix any failures before running pipeline commands.

## Plugin Structure

Each plugin is a directory at the repo root containing:

```
ticket-auto-pipeline/
  .claude-plugin/plugin.json    # Plugin manifest (name, version, description)
  skills/                       # Slash-command skill .md files
  lib/                          # Shared bash libraries (sourced by skill scripts)
  state-machine.json            # State/label transition definitions
  pipeline-log-format.md        # Shared pipeline log schema
  install.sh                    # Post-install migration from host-side skills
```

Plugins are discovered at marketplace add time — Claude Code reads each `.claude-plugin/plugin.json` under the repo root to build the catalog.

## Environment

Plugin skills that interact with Linear require these env vars:

| Variable | Purpose |
|----------|---------|
| `LINEAR_API_KEY` | Linear API authentication |
| `GITHUB_PERSONAL_ACCESS_TOKEN` (or `GH_TOKEN`) | GitHub CLI + PR operations |
| `ANTHROPIC_AUTH_TOKEN` | Claude API key |

Set in `~/.claude/settings.local.json` under `env`.

The `validate-linear-config.sh` script also checks for project-specific values in the working directory's `CLAUDE.md`: `REPOS_ROOT`, `LOCAL_URL`, `UAT_URL`, and optional `BE_TEST_CMD`, `SLACK_CHANNEL`, `WIKI_ROOT`.

