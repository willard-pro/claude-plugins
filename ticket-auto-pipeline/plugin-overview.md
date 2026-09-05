# plugin-overview.md — ticket-auto-pipeline

Maintainer-facing overview of the ticket-auto-pipeline plugin. Read this before adding features, modifying the state machine, or debugging pipeline failures.

## Design philosophy

**Determinism at the boundary.** AI handles reasoning (appraisal, implementation, review). Bash handles mutation (state transitions, API calls, log writes). The boundary is absolute — skills never call Linear mutation endpoints or write log entries directly. This gives reproducible failure modes: if a state transition is wrong, it's in `flow.sh`, not in an untraceable agent decision.

**Logs as checkpoints.** The pipeline log is the single source of truth for pipeline progress. Crash recovery reads it. Retro analysis reads it. Dashboard reads it. Every meaningful action writes to it. No in-memory state survives agent spawn boundaries.

**Safety over speed.** 11 structural gate-stop codes halt the pipeline when invariants are violated. This is deliberate — a halted pipeline that requires human attention is better than a silent merge of broken code.

## Component inventory

### State management
| Component | File | Role |
|-----------|------|------|
| State machine definition | `skills/ticket-flow/state-machine.json` | Declares triggers, states, labels, transitions |
| State machine executor | `skills/ticket-flow/flow.sh` | Reads JSON, executes transitions with idempotency |
| State diagram generator | `skills/ticket-flow/gen-mermaid.sh` | Generates mermaid from state machine JSON |
| Interactive diagram | `docs/ticket-auto-pipeline-diagram.html` | Visual state diagram with drill-down (GitHub Pages) |
| Linear config validator | `validate-linear-config.sh` | Asserts team states/labels match state machine |

### Core pipeline (thin router dispatch)

The orchestrator (`ticket-auto`) is a **thin stateless dispatch router** — it reads pipeline log state via `detect-resume.sh`, dispatches to the correct phase agent or bash gate, and re-reads state. Zero inline LLM reasoning between phases.

| Step | Phase | Dispatches | Type |
|------|-------|------------|------|
| 0 | Prescan | `ticket-prescan-agent` | Named agent — auto-invoke before Step 1. Runs `prescan-check.sh` per repo; if stale/missing, spawns prescan to refresh `.ticket-auto/` docs. Non-blocking — failure/skip falls through to appraise Path B. |
| 1 | Appraise | `ticket-appraise-agent` | Named agent — investigates ticket, scores complexity. Step 3a loads prescan docs (Tier 1: INDEX.md routing via `prescan-route.sh`, Tier 2: claude-mem corpus, Tier 3: wiki fallback). |
| 1.5 | Reproduce | `ticket-appraise-agent` | Named agent — bug reproduction (bug tickets only) |
| 2 | Exec | `ticket-appraise-agent` | Named agent — creates artifact, regression guard, adversarial review (complex), verification plan derivation (complex, Step 3.7), verification-readiness gate (Step 3.8) |
| 2.5 | Gate | `bash gate-check.sh --mode entry` | **Bash only** — artifact existence, complexity coherence, verification readiness (reads derived plan + artifact fallback), autonomy routing |
| 3.5 | Reconcile | `ticket-gate-reconcile-agent` | Named agent — post-gate-hold comment reconciliation (only when held ticket re-approved) |
| 4 | Implement | `ticket-implement-agent` | Named agent — code changes, then `bash outcome-label-check.sh` |
| 4.5 | Verify | `ticket-verify-agent` | Named agent — Playwright UAT, router-managed retry loop (max 3 attempts) |
| 4.6 | PR Review | `ticket-pr-review-agent` | Named agent — code review pass, router-managed iteration loop (max 3 cycles) |
| 5 | Maintenance | `ticket-maintenance-agent` | Named agent — document (ai-context.md) + wiki-maintenance (errata) |
| 5.5 | PR Reconcile | `ticket-pr-review-agent` | Named agent — PR comment cross-reference |
| 6 | Report | `bash` + optional `ticket-retro` skill | Bash check (gate-stop / fallback detection) + optional retro agent |

### Support systems
| System | Components | Purpose |
|--------|-----------|---------|
| Logging | `pipeline-log-format.md`, `pipeline-heartbeat-format.md`, `lib/heartbeat.sh` | Dual-stream progress + operational logging |
| Bash gates | `lib/gate-check.sh`, `lib/outcome-label-check.sh` | Deterministic gate decisions (no Claude agent) — artifact, complexity, autonomy, outcome labels |
| Crash recovery | `lib/detect-resume.sh`, pipeline log | Direct bash invocation by router — reads last completed step, outputs routing variables |
| Comment reconciliation | `ticket-gate-reconcile` | Isolated agent for post-gate-hold comment reconciliation |
| Failure analysis | `ticket-retro`, retro templates | Post-mortem classification + fix proposals |
| Monitoring | `ticket-overseer`, `dashboard.py`, `report.py` | Queue status, stall detection (human-facing) |
| Fleet control | `ticket-fleet-controller`, `lib/fleet-detect.sh`, `lib/fleet-intervene.sh`, `lib/fleet-dashboard.sh` | Automated intervention — detect, kill, restart pipelines |
| Validation | `ticket-env-check`, `validate-linear-config.sh` | Pre-flight checks |
| Batch ops | `ticket-batch-appraise`, `ticket-batch-verify` | Bulk ticket processing |
| Audit | `ticket-audit`, `ticket-audit-exec`, `lib/audit-size-check.sh`, `lib/audit-drift-check.sh`, `lib/audit-title-similarity.sh`, `lib/audit-scope-check.sh`, `lib/audit-repro-check.sh`, `lib/audit-ac-testability.sh`, `lib/audit-test-data-check.sh`, `lib/audit-overlap-check.sh`, `lib/audit-comment-guard.sh`, `lib/ticket-audit-exec.sh` | Cross-ticket audit within milestone/parent — detects duplicates, overlaps, empty tickets, goal misalignment, stale tickets, split candidates, wiki misalignment. Two-phase apply agent delegates needs-info to ticket-critique, posts structural comments. |
| Prescan | `ticket-prescan`, `lib/prescan-check.sh`, `lib/prescan-docs.sh`, `lib/prescan-route.sh`, `lib/prescan-verify.sh`, `lib/prescan-wire-claude-md.sh` | Repo knowledge building — deterministic freshness gate, graph-to-markdown distiller, INDEX.md keyword router, post-scan quality assertions, managed block injection. Produces `.ticket-auto/` docs consumed by appraise Step 3a to skip per-ticket codebase rediscovery. |

## Architecture: Thin Router Dispatch

```
ticket-auto (thin stateless dispatch router)
  │
  ├─ Pre-pipeline bash gate (no Claude agent):
  │   └─ lib/prescan-check.sh       ── freshness gate per repo (before Step 1)
  │       └─ if stale/missing: flock → spawn ticket-prescan-agent (non-blocking)
  │
  ├─ Bash gates (no Claude agent):
  │   ├─ lib/gate-check.sh          ── entry mode (artifact, complexity, verification readiness, autonomy)
  │   │   └─ ticket-flow (state mutations)
  │   ├─ lib/outcome-label-check.sh  ── post-implement outcome label guard
  │   │   └─ ticket-flow
  │   └─ lib/detect-resume.sh       ── direct bash invocation (not skill spawn)
  │
  ├─ Named agent spawns (3-step pattern: pre → spawn → capture → post):
  │   ├─ ticket-prescan-agent        ── Step 0 (pre-pipeline: repo knowledge refresh)
  │   ├─ ticket-appraise-agent       ── Step 1 (appraise) + Step 1.5 (reproduce) + Step 2 (exec: artifact + regression + adversarial + verification plan derivation + readiness gate)
  │   ├─ ticket-gate-reconcile-agent ── Step 3.5 (post-hold comment reconciliation)
  │   ├─ ticket-implement-agent      ── Step 4 (code changes)
  │   ├─ ticket-verify-agent         ── Step 4.5 (Playwright UAT, consumes derived verification plan, router-managed retry)
  │   ├─ ticket-pr-review-agent      ── Step 4.6 (code review, router-managed iteration)
  │   └─ ticket-maintenance-agent    ── Step 5 (document + wiki)
  │
  └─ Router-managed loops (counters from pipeline log):
      ├─ Verify retry: FAIL → re-implement → outcome-check → re-verify (max 3)
      └─ PR iteration: ⚠️ → reapprove-check → pr-iterate → re-implement → verify → pr-review (max 3)

Support (invoked independently):
  ticket-prescan ── manual prescan slash command (also auto-invoked by router)
  ticket-detect-resume ── reads pipeline log (also called as bash by router)
  ticket-retro ── reads pipeline + heartbeat logs
  ticket-overseer ── reads pipeline logs
  ticket-fleet-controller ── reads pipeline + heartbeat logs, writes interventions
  ticket-env-check ── validates environment
  ticket-flow ── all Linear state/label mutations (deterministic bash)
```

All pipeline agents use `lib/skill-preamble-auto.md` (thin router variant). All bash operations source from `lib/*.sh` (synced to `~/.claude/skills/lib/` by the SessionStart hook).

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
    │ Phase Agents│  │ Gate      │  │ flow.sh   │
    │ (appraise,  │  │ Reconcile │  │ (idempotent
    │  implement, │  │ PR Review │  │  mutations)│
    │  verify,    │  │ Retro     │  └───────────┘
    │  maintenance│  └───────────┘
    └──────┬──────┘
           │
           ▼
    ┌──────────────┐     ┌─────────────────┐
    │ Pipeline Log │◄────│ Bash Gates      │
    │ Heartbeat Log│     │ gate-check.sh   │
    └──────┬───────┘     │ outcome-label-  │
           │             │ check.sh        │
    ┌──────┴───────┐     └─────────────────┘
    │              │
    ▼              ▼
├────────┐  ┌──────────┐
│detect- │  │ Retro    │
│resume  │  │ (post-   │
│(bash — │  │ mortem)  │
│no agent│  │          │
│spawn)  │  │          │
├────────┘  └──────────┘
│              │
▼              ▼
┌──────────────┐  ┌──────────────┐
│ Fleet        │  │ Overseer     │
│ Controller   │  │ (human       │
│ (automated   │  │  dashboard)  │
│  intervention│  │              │
└──────┬───────┘  └──────────────┘
       │
       ▼
┌──────────────┐
│ Stop files,  │
│ pipeline log │
│ intervention │
│ entries      │
└──────────────┘
```

## How to add a new pipeline phase

1. Create skill directory: `skills/ticket-<name>/SKILL.md`
2. Add slash command definition in SKILL.md frontmatter
3. Reference `lib/skill-preamble-auto.md` for shared parameter patterns (thin router variant)
4. If the phase needs a restricted tool allowlist or its own system prompt, add a plugin-defined subagent: create `agents/<name>-agent.md` (YAML frontmatter: `name`, `description`, `tools`; body is the system prompt), then set `spawn.agent` (or `sequence[].agent`) to `ticket-auto-pipeline:<name>-agent` on the step's entry in `skills/ticket-flow/dispatch-table.json`. Otherwise leave `agent` unset/`null` — the step falls back to `general-purpose`. Regenerate the dispatch table (below) so SKILL.md's "Agent types" table picks up the mapping; fleetd's phase-dispatch path reads the same JSON field automatically.
5. Add dispatch case to `ticket-auto/SKILL.md` dispatch table (new RESUME_STEP)
6. Add any new state transitions to `skills/ticket-flow/state-machine.json`
7. Add corresponding trigger to `flow.sh` if needed
8. Add phase to `pipeline-log-format.md` if it writes log entries
9. Regenerate state diagram: `bash skills/ticket-flow/gen-mermaid.sh`
10. Regenerate skill docs: run `/skill-docs`
11. Update this document (plugin-overview.md) with the new phase

## How to modify the state machine

1. Edit `skills/ticket-flow/state-machine.json` — add/modify triggers, states, labels
2. Run `skills/ticket-flow/validate-linear-config.sh` to verify the Linear team has the required states/labels
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

- `ticket-auto-thin-router` — Thin stateless dispatch router with bash gates (active, tasks 0–12 complete)
- `pr-comment-reconciliation` — PR comment cross-referencing (active)
- `reproduce-pipeline-integration` — Bug reproduction phase (active)
- `ticket-pipeline-cleanup` — Code quality and safety (active)
- `token-optimization` — Prompt and template externalization (active)
- `skill-preamble-dedup` — Shared preamble extraction (archived)
- `transcript-capture-for-retro` — Agent output persistence (archived)
- `gate-comment-reconciliation` — Approval comment handling (archived)
- `pipeline-heartbeat-log` — Heartbeat log system (archived)
- `env-check-unification` — Dual-mode env validation (archived)
