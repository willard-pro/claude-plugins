# ticket-auto-pipeline

Fully autonomous Linear ticket pipeline as a Claude Code plugin. Appraise, implement, verify, and merge — zero user input required.

## Install

```bash
claude plugin install ticket-auto-pipeline@willard-pro-claude-plugins
```

Or add the marketplace first:

```bash
claude plugin marketplace add willard-pro-claude-plugins https://github.com/willard-pro/claude-plugins.git
claude plugin install ticket-auto-pipeline@willard-pro-claude-plugins
```

## Required Environment

| Variable | Purpose |
|----------|---------|
| `LINEAR_API_KEY` | Linear API authentication |
| `GITHUB_PERSONAL_ACCESS_TOKEN` (or `GH_TOKEN`) | GitHub CLI + PR operations |
| `ANTHROPIC_AUTH_TOKEN` | Claude API key |

Optional:

| Variable | Purpose |
|----------|---------|
| `ANTHROPIC_BASE_URL` | Custom API endpoint |
| `ANTHROPIC_MODEL` / `ANTHROPIC_DEFAULT_OPUS_MODEL` etc. | Model overrides |
| `GIT_AUTHOR_NAME` / `GIT_AUTHOR_EMAIL` | Commit authorship |
| `UAT_URL` | UAT environment URL for verification |
| `REPOS_ROOT` | Workspace root (default: `~/repos`) |

## Required MCP Servers

The pipeline requires these MCP servers configured in `.claude.json`:

- **linear-server** — Linear ticket operations
- **playwright** — Browser automation for UAT
- **github** — PR management and code review

## Dexter vs Bare Claude Code

**With Dexter:** The container pre-seeds this plugin — it's installed and enabled on first boot. No manual steps.

**Without Dexter:** Install manually as shown above. The pipeline writes state to `~/.claude/state/ticket-flow/` and `~/.claude/state/ticket-retro/`. Ensure env vars and MCP servers are configured before running.

## Slash Commands

| Command | What it does |
|---------|-------------|
| `/ticket-auto <id>` | Full autonomous pipeline |
| `/ticket-appraise <id>` | Investigation + complexity analysis |
| `/ticket-implement <id>` | Implementation workflow |
| `/ticket-verify <id>` | Post-implementation verification |
| `/ticket-retro [id]` | Pipeline failure analysis |
| `/ticket-flow` | Pipeline state visualization |
| `/ticket-setup <id>` | Ticket workspace setup |
| `/ticket-pr-review <id>` | PR review pass |
| `/ticket-overseer` | Pipeline queue dashboard |

Plus supporting commands: `ticket-appraise-exec`, `ticket-batch-appraise`, `ticket-batch-verify`, `ticket-critique`, `ticket-detect-resume`, `ticket-pr-iterate`, `ticket-reproduce`, `wiki-maintenance`, `nav-hints`, `app-knowledge`.

## Migration from Host Skills

If you have existing `~/.claude/skills/ticket-*` directories from a pre-plugin setup, run:

```bash
bash ~/.claude/plugins/cache/willard-pro-claude-plugins/ticket-auto-pipeline/*/install.sh
```

This detects old host-side skill directories and prompts to archive them.
