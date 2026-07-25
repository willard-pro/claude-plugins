# ticket-planner

Autonomous 9-phase planner that turns business ideas into dependency-ordered planned tickets. Sits upstream of `ticket-auto-pipeline` and `fleet-controller` — plans, then hands off.

## Install

```bash
# Add the marketplace first (one-time)
claude plugin marketplace add willard-pro/claude-plugins

# Install the plugin
claude plugin install ticket-planner@willard-pro-claude-plugins
```

## Quickstart

**1. Set environment variables** in `~/.claude/settings.local.json`:

```json
{
  "env": {
    "LINEAR_API_KEY": "lin_api_...",
    "REPOS_ROOT": "/home/you/repos"
  }
}
```

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `LINEAR_API_KEY` | Yes | — | Linear API authentication token |
| `REPOS_ROOT` | No | `~/repos` | Root directory for source repositories and initiative state |

**2. Set project fields** in your working directory's `CLAUDE.md`:

```markdown
# CLAUDE.md
REPOS_ROOT: /home/you/repos
```

**3. Verify the downstream pipeline** is installed:

```bash
claude plugin install ticket-auto-pipeline@willard-pro-claude-plugins
```

The planner depends on `planned-ticket-check.sh` from `ticket-auto-pipeline` for ticket validation.

## Usage

From within Claude Code:

```
/ticket-planner plan "Add real-time collaboration to the document editor"
```

### Modes

| Command | Purpose |
|---------|---------|
| `/ticket-planner plan "<idea>"` | Start a new initiative from a business idea |
| `/ticket-planner resume <INIT_ID>` | Resume a crashed or paused initiative |
| `/ticket-planner status <INIT_ID>` | Show current phase and recent log entries |
| `/ticket-planner replan <INIT_ID>` | Re-plan from feedback (requires `Regenerate` flag) |

### Plan flags

Both `plan` and `resume` accept optional branch-directive override flags:

| Flag | Effect |
|------|--------|
| `--shared-branch` | Force a shared-branch directive on the epic regardless of the heuristic |
| `--no-shared-branch` | Suppress the shared-branch directive regardless of the heuristic |

Supplying both together is an error. When neither is supplied, a deterministic bash heuristic
decides: ≥ 3 planned tickets **and** dependency chain depth ≥ 2. The thresholds are provisional
and conservative by design — under-recommending costs one flag, over-recommending silently
changes merge topology.

### What happens

1. The planner initializes a state directory under `$REPOS_ROOT/.ticket-auto/initiatives/{ID}/`
2. Each of the 9 phases runs as an isolated Claude agent: Appraisal → Discovery → Architecture → Specify → Review → Consensus → EpicGen → TicketGen → Completed
3. TicketGen creates planned Linear tickets with `## Planner Context` blocks, `planned`/`pre-approved`/`Type` labels, and validated acyclic dependencies
4. The epic gets `state:execution` — fleet-controller auto-dispatches when `FLEET_AUTO_DISPATCH=true`
5. `ticket-auto-pipeline` consumes the planned tickets via its fast-path (skips full investigation for `planned` + `pre-approved` tickets)

### Resume after interruption

If the run is interrupted (crash, timeout, manual stop):

```
/ticket-planner resume INIT-42
```

The router re-derives position from the state log and continues from where it left off. Every phase is idempotent — safe to re-enter.

## Documentation

| Document | Audience | Content |
|----------|----------|---------|
| [CLAUDE.md](CLAUDE.md) | Claude Code | Plugin architecture, lib reference, known sharp edges |
| [docs/ticket-planner.md](docs/ticket-planner.md) | Maintainers | Full architecture: state machine, contracts, confidence derivation, re-planning |
| [state-log-format.md](state-log-format.md) | Developers | Log schema: format, phases, steps, statuses, integrity guarantees |
| [docs/README.md](docs/README.md) | Everyone | Documentation index |
| [skills/ticket-planner/SKILL.md](skills/ticket-planner/SKILL.md) | Claude Code | Skill procedure: modes, phases, implementation steps |

## Ecosystem

```
Business idea → [ticket-planner] → initiative epic + planned tickets
                                       ↓
                                 [fleet-controller] → dispatch
                                       ↓
                                 [ticket-auto-pipeline] → implement → verify → merge
```

## License

UNLICENSED — proprietary.
