# plugin-overview.md — ticket-auto-pipeline

Maintainer-facing overview of the ticket-auto-pipeline plugin. Read this before adding features, modifying the state machine, or debugging pipeline failures.

## Design philosophy

**Determinism at the boundary.** AI handles reasoning (appraisal, implementation, review). Bash handles mutation (state transitions, API calls, log writes). The boundary is absolute — skills never call Linear mutation endpoints or write log entries directly. This gives reproducible failure modes: if a state transition is wrong, it's in `flow.sh`, not in an untraceable agent decision.

**Logs as checkpoints.** The pipeline log is the single source of truth for pipeline progress. Crash recovery reads it. Retro analysis reads it. Dashboard reads it. Every meaningful action writes to it. No in-memory state survives agent spawn boundaries.

**Safety over speed.** Six structural gates halt the pipeline when invariants are violated. This is deliberate — a halted pipeline that requires human attention is better than a silent merge of broken code.

## Component inventory

### State management
| Component | File | Role |
|-----------|------|------|
| State machine definition | `state-machine.json` | Declares triggers, states, labels, transitions |
| State machine executor | `skills/ticket-flow/flow.sh` | Reads JSON, executes transitions with idempotency |
| State diagram generator | `skills/ticket-flow/gen-mermaid.sh` | Generates mermaid from state machine JSON |
| Interactive diagram | `docs/pipeline-diagram.html` | Visual state diagram with drill-down (GitHub Pages) |
| Linear config validator | `validate-linear-config.sh` | Asserts team states/labels match state machine |

### Core pipeline (sequential phases)
| Phase | Skill | Step | Agent spawn |
|-------|-------|------|-------------|
| Appraise | `ticket-appraise` | 1 | Yes — investigates ticket, scores complexity |
| Execute | `ticket-appraise-exec` | 2 | Yes — creates artifact, regression guard, adversarial review (complex) |
| Gate | (inline in orchestrator) | 2.5 | No — structural invariant checks |
| Reproduce | `ticket-reproduce` | 1.5 | Yes — bug reproduction (bug tickets only) |
| Implement | `ticket-implement` | 3 | Yes — code changes |
| Verify | `ticket-verify` | 4 | Yes — Playwright UAT |
| PR Review | `ticket-pr-review` | 5 | Yes — code review pass |
| PR Iterate | `ticket-pr-iterate` | 5c | Yes — iteration on feedback |
| Comment reconcile | (inline) | 5.5 | No — PR comment cross-reference |
| Maintenance | `ticket-flow` + manual | 6 | No — label/state cleanup |

### Support systems
| System | Components | Purpose |
|--------|-----------|---------|
| Logging | `pipeline-log-format.md`, `pipeline-heartbeat-format.md`, `lib/heartbeat.sh` | Dual-stream progress + operational logging |
| Crash recovery | `ticket-detect-resume`, pipeline log | Resumes from last completed step |
| Failure analysis | `ticket-retro`, retro templates | Post-mortem classification + fix proposals |
| Monitoring | `ticket-overseer`, `dashboard.py`, `report.py` | Queue status, stall detection |
| Validation | `ticket-env-check`, `validate-linear-config.sh` | Pre-flight checks |
| Batch ops | `ticket-batch-appraise`, `ticket-batch-verify` | Bulk ticket processing |

## Skill dependency graph

```
ticket-auto (orchestrator)
  ├─ ticket-setup (scaffolding)
  ├─ ticket-appraise (investigation)
  │   └─ ticket-flow (state mutations)
  ├─ ticket-appraise-exec (artifact creation)
  │   └─ ticket-flow
  ├─ ticket-reproduce (bug reproduction, Step 1.5)
  ├─ ticket-implement (code changes)
  │   └─ ticket-flow
  ├─ ticket-verify (UAT)
  │   └─ ticket-flow
  ├─ ticket-pr-review (code review)
  │   ├─ ticket-flow
  │   └─ ticket-pr-iterate (feedback loop)
  │       └─ ticket-flow
  └─ ticket-flow (maintenance cleanup)

Support (invoked independently):
  ticket-detect-resume ── reads pipeline log
  ticket-retro ── reads pipeline + heartbeat logs
  ticket-overseer ── reads pipeline logs
  ticket-env-check ── validates environment
```

All pipeline skills source their preamble from `lib/skill-preamble.md`. All bash operations source from `lib/*.sh` (synced to `~/.claude/skills/lib/` by the SessionStart hook).

## Data flow

```
                     ┌──────────────┐
                     │ Linear API   │
                     └──────┬───────┘
                            │
              ┌─────────────┼─────────────┐
              │             │             │
         get_issue     get_comments   update_issue
              │             │             │
              ▼             ▼             ▲
    ┌─────────────┐  ┌───────────┐  ┌────┴──────┐
    │ Appraise    │  │ PR Review │  │ flow.sh   │
    │ Implement   │  │ Retro     │  │ (idempotent
    │ Verify      │  │           │  │  mutations)│
    └──────┬──────┘  └───────────┘  └───────────┘
           │
           ▼
    ┌──────────────┐
    │ Pipeline Log │◄── all phases write progress
    │ Heartbeat Log│◄── all phases write decisions
    └──────┬───────┘
           │
    ┌──────┴───────┐
    │              │
    ▼              ▼
┌────────┐  ┌──────────┐
│Detect  │  │ Retro    │
│Resume  │  │ (post-   │
│(crash  │  │ mortem)  │
│recovery│  │          │
└────────┘  └──────────┘
```

## How to add a new pipeline phase

1. Create skill directory: `skills/ticket-<name>/SKILL.md`
2. Add slash command definition in SKILL.md frontmatter
3. Reference `lib/skill-preamble.md` for shared parameter patterns
4. Register the phase in `ticket-auto/SKILL.md` orchestrator step sequence
5. Add any new state transitions to `state-machine.json`
6. Add corresponding trigger to `flow.sh` if needed
7. Add phase to `pipeline-log-format.md` if it writes log entries
8. Regenerate state diagram: `bash skills/ticket-flow/gen-mermaid.sh`

## How to modify the state machine

1. Edit `state-machine.json` — add/modify triggers, states, labels
2. Run `validate-linear-config.sh` to verify the Linear team has the required states/labels
3. Run `bash skills/ticket-flow/gen-mermaid.sh` to update the diagram
4. If adding new triggers: update `flow.sh` trigger dispatch
5. Test with a real ticket in `--manual` mode first

The state machine JSON structure:
```json
{
  "triggers": {
    "<trigger-name>": {
      "from": ["<state>"],
      "to": "<state>",
      "addLabels": ["<label>"],
      "removeLabels": ["<label>"],
      "setAssignee": "<role>"
    }
  },
  "states": { "<name>": { "type": "<category>" } },
  "labels": { "<name>": { "color": "<hex>" } }
}
```

## Testing approach

- **Unit-level**: `lib/*.sh` scripts are bash — test with direct invocation
- **Integration**: Run individual skills (`/ticket-appraise <id>`, `/ticket-implement <id>`) independently before full pipeline
- **End-to-end**: Run `/ticket-auto <id> --manual` for full pipeline with human gates
- **State machine**: `validate-linear-config.sh` checks config alignment; test each trigger with `/ticket-flow <id> <trigger>`
- **Log integrity**: After any log-format change, verify `ticket-detect-resume` and `ticket-retro` can parse the new format

## Debugging tips

- **Pipeline stuck in a state**: Check the pipeline log at `tickets/{ID}--*/pipeline.log`. Look for `|waiting|` entries (agent never completed) or `|fail|` entries (agent reported failure).
- **State assertion failures (exit 7)**: flow.sh mutated state but post-trigger re-fetch didn't match expectations. Check Linear for conflicting automations or manual changes.
- **Silent agent failures**: If an agent spawn shows `|waiting|` with no matching `|done|` or `|fail|`, check the heartbeat log for the agent's last decision or fallback entry.
- **MCP auth issues**: Run `/ticket-env-check` in validate mode to isolate which server is failing. Check `~/.claude.json` MCP server env blocks.
- **Log corruption**: Schema version mismatches or manual edits can break parsing. Schema version is line 1 of every log. Delete and restart if corrupted.

## Related OpenSpec changes

Active and recently archived changes that affect this plugin:

- `pr-comment-reconciliation` — PR comment cross-referencing (active)
- `reproduce-pipeline-integration` — Bug reproduction phase (active)
- `ticket-pipeline-cleanup` — Code quality and safety (active)
- `token-optimization` — Prompt and template externalization (active)
- `skill-preamble-dedup` — Shared preamble extraction (archived)
- `transcript-capture-for-retro` — Agent output persistence (archived)
- `gate-comment-reconciliation` — Approval comment handling (archived)
- `pipeline-heartbeat-log` — Heartbeat log system (archived)
- `env-check-unification` — Dual-mode env validation (archived)
