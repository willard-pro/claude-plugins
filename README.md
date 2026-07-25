# willard-pro/claude-plugins

Claude Code plugin marketplace — ticket automation pipelines and development tooling.

## What's Here

A marketplace of installable Claude Code plugins. Add this marketplace to Claude Code to install any plugin below.

| Plugin | Version | Description |
|--------|---------|-------------|
| `ticket-auto-pipeline` | 0.21.0 | Fully autonomous Linear ticket pipeline — appraise, implement, verify, and merge with zero user input. 20+ slash commands, state-machine-driven flow control, pipeline safety gates, and retrospective analysis. Supports shared epic branches via `## Branch Directive` block. |

See the [plugin README](ticket-auto-pipeline/README.md) for full documentation.

## How the Pipeline Works

The ticket-auto-pipeline processes Linear tickets through six phases without human intervention:

```
APPRAISE → IMPLEMENT → VERIFY → PR-REVIEW → MAINTENANCE
```

Each phase spawns an isolated agent. A state machine manages Linear state transitions (`Backlog → Todo → Approve → Ready → Review → Done`). Safety gates halt the pipeline on structural failures (missing artifacts, approval revocations, verdict parse errors). Crash recovery resumes from the last completed pipeline log entry.

## Install

```bash
# Add this marketplace (one-time)
claude plugin marketplace add willard-pro/claude-plugins

# Install the plugin
claude plugin install ticket-auto-pipeline@willard-pro-claude-plugins
```

## Configure

### 1. Environment Variables

Set in `~/.claude/settings.local.json` under `env`:

| Variable | Purpose |
|----------|---------|
| `LINEAR_API_KEY` | Linear API authentication |
| `GITHUB_PERSONAL_ACCESS_TOKEN` (or `GH_TOKEN`) | GitHub CLI + PR operations |
| `ANTHROPIC_AUTH_TOKEN` | Claude API key |

Optional env vars and CLAUDE.md fields (`REPOS_ROOT`, `LOCAL_URL`, `UAT_URL`) are documented in the [plugin README](ticket-auto-pipeline/README.md#required-environment).

### 2. MCP Servers

The pipeline requires three MCP servers in `~/.claude.json` (or `.claude.json` in your project):

```json
{
  "mcpServers": {
    "linear-server": {
      "command": "npx",
      "args": ["-y", "@linear/mcp-server"],
      "env": {
        "LINEAR_API_KEY": "${LINEAR_API_KEY}"
      }
    },
    "playwright": {
      "command": "npx",
      "args": ["-y", "@anthropic/mcp-server-playwright"]
    },
    "github": {
      "command": "npx",
      "args": ["-y", "@anthropic/github-mcp-server"],
      "env": {
        "GITHUB_PERSONAL_ACCESS_TOKEN": "${GITHUB_PERSONAL_ACCESS_TOKEN}"
      }
    }
  }
}
```

### 3. Validate

From within Claude Code, verify everything is wired up:

```
/ticket-env-check
```

Then validate your Linear team's states and labels match the state machine:

```bash
bash ticket-auto-pipeline/validate-linear-config.sh
```

Fix any failures before running pipeline commands.

## Plugin Structure

```
ticket-auto-pipeline/
  .claude-plugin/plugin.json    # Plugin manifest
  skills/                       # 20+ slash-command skill .md files
  lib/                          # Shared bash libraries
  skills/ticket-flow/state-machine.json  # State/label transition definitions
  pipeline-log-format.md        # Pipeline log schema
  pipeline-heartbeat-format.md  # Operational heartbeat log schema
  validate-linear-config.sh     # Linear team config validator
  install.sh                    # Migration from host-side skills
```

Plugins are discovered at marketplace add time — Claude Code reads each `.claude-plugin/plugin.json` under the repo root to build the catalog.

