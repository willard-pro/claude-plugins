---
name: ticket-planner
description: 9-phase autonomous planner — turns a business idea into dependency-ordered planned tickets. Phases: Appraisal → Discovery → Architecture → Specify → Review → Consensus → Epic Gen → Ticket Gen → Completed. Produces against frozen Planner Context and labels contracts.
allowed-tools: Bash, Read, Agent
---

# Ticket Planner — Idea-to-Tickets Pipeline

Autonomous 9-phase planner that turns business ideas into Linear initiatives, epics, and dependency-ordered planned tickets the existing `ticket-auto` pipeline consumes without special-casing.

Sits upstream of `ticket-auto` and `fleet-controller`. Produces against frozen consumption-side contracts — does not re-specify them.

## When to Use

| Trigger | Mode |
|---------|------|
| `/ticket-planner plan "idea"` | Start a new initiative from an idea |
| `/ticket-planner resume <INIT_ID>` | Resume a crashed or paused initiative |
| `/ticket-planner status <INIT_ID>` | Show current phase and recent log entries |
| `/ticket-planner replan <INIT_ID>` | Re-plan an initiative from feedback (requires Regenerate flag) |

## Modes

### Plan (`plan`)

Start a new planning run from a business idea. The planner initializes the state directory, creates the state log, and begins at the Appraisal phase. Each phase runs as an isolated agent; the router advances sequentially through the 9-phase state machine.

```
/ticket-planner plan "Add real-time collaboration to the document editor"
```

If the run is interrupted (crash, timeout, manual stop), resume with `resume` — the router re-derives position from the state log and continues from where it left off.

### Plan flags

| Flag | Effect |
|------|--------|
| `--shared-branch` | Force a shared-branch directive on the epic regardless of the heuristic |
| `--no-shared-branch` | Suppress the shared-branch directive regardless of the heuristic |

Both flags are optional. Supplying both together is an error. When neither is supplied,
the binary heuristic decides (≥ 3 tickets **and** dependency chain depth ≥ 2).

### Resume (`resume`)

Continue an interrupted or paused run. The router reads the state log, finds the last incomplete phase, and resumes from there. Completed phases are skipped.

```
/ticket-planner resume INIT-42
```

### Status (`status`)

Show the current phase, initiative metadata, and the last few state log entries.

```
/ticket-planner status INIT-42
```

### Replan (`replan`)

Re-plan an initiative that carries the `Regenerate` flag. Ingests aggregated feedback, applies confidence drift, and regenerates undispatched Backlog tickets. Dispatched, in-progress, and completed tickets are left unchanged.

```
/ticket-planner replan INIT-42
```

## The 9 Phases

| # | Phase | What it does | Output |
|---|-------|-------------|--------|
| 1 | Appraisal | Interprets the idea, establishes initiative scope | Scope summary |
| 2 | Discovery | Explores affected repos, gathers context | Code paths, symbols, APIs |
| 3 | Architecture | Determines the technical approach | Architecture decision record |
| 4 | Specify | Synthesizes proposal + writes per-ticket specs with signals | `proposal.md`, spec files |
| 5 | Review | Critiques the proposal and specs (internal by default) | Review findings |
| 6 | Consensus | Resolves review findings into a settled plan | Finalized proposal |
| 7 | Epic Gen | Creates the initiative epic in Linear | Linear epic with `epic` label |
| 8 | Ticket Gen | Creates planned child tickets, computes confidence, gate-dispatches | Linear tickets, `state:execution` on epic |
| 9 | Completed | Terminal phase — no further transitions | Completed state |

## Contracts (frozen — the planner produces against these)

The planner does not re-specify these. They are the interface to the downstream pipeline:

- **Planner Context block** — `## Planner Context` in ticket description, validated by `planned-ticket-check.sh`
- **Labels** — `planned`, `pre-approved`, `INIT-{id}`, `Type`, `blocked-by:{ID}`
- **Artifact plane** — `planner-artifacts.sh` resolves to `${REPOS_ROOT}/.ticket-auto/initiatives/{ID}/artifacts/`
- **Feedback** — `fleet-feedback.sh` aggregates `META|planner-feedback` from pipeline logs

## State and Resume

State lives in an append-only pipe-delimited log at `${REPOS_ROOT}/.ticket-auto/initiatives/{ID}/state.log`. The router re-derives position by reading the log — no state held in memory between invocations.

If a crash occurs mid-phase, the router resumes at that phase. Each entity-creating phase is idempotent: it records intent before creating, and checks existence before creating. A crash between intent and creation produces exactly one entity on resume.

## Determinism Boundary

- **Bash side (deterministic):** State log parsing, position derivation, phase transition validation, entity idempotency checks, dependency acyclicity validation, `planned-ticket-check.sh` invocation.
- **Agent side (LLM):** Per-phase content — appraisal, discovery, architecture, proposal, review, consensus, spec writing, ticket body generation.

The router never reasons about content; phases never mutate state directly (they write log entries that the router reads).

## Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `PLANNER_REVIEW_HOLD` | false | When `true`, Review phase pauses for human input |
| `PLANNER_CONSENSUS_HOLD` | false | When `true`, Consensus phase pauses for human input |
| `PLANNER_MAX_PHASE_RETRIES` | 2 | Max retries per phase before failing the run |
| `PLANNER_PHASE_TIMEOUT` | 600 | Seconds before timing out a hung phase agent |
| `PLANNER_TSORT_TIMEOUT` | 30 | Seconds before timing out dependency graph sort |
| `PLANNER_CONFIDENCE_THRESHOLD` | 0.85 | Minimum confidence for `pre-approved` label |
| `PLANNER_IDEA_MAX_LENGTH` | 2000 | Maximum idea length in chars (truncated with warning) |
| `FLEET_AUTO_DISPATCH` | false | Must be true for automatic fleet-controller dispatch |

---

## Implementation

When invoked, follow this procedure:

### 1. Source libraries

```bash
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(dirname "$0")/../..}"
source "${PLUGIN_ROOT}/lib/planner-state.sh"
source "${PLUGIN_ROOT}/lib/planner-router.sh"
source "${PLUGIN_ROOT}/lib/planner-phase-prompts.sh"
```

### 2. Parse mode

First argument is the mode: `plan`, `resume`, `status`, or `replan`.

### 2a. Parse override flags (plan mode only)

After extracting the idea, scan remaining arguments for override flags:

```bash
SHARED_BRANCH_FLAG=""
NO_SHARED_BRANCH_FLAG=""

for arg in "$@"; do
  case "$arg" in
    --shared-branch) SHARED_BRANCH_FLAG=true ;;
    --no-shared-branch) NO_SHARED_BRANCH_FLAG=true ;;
  esac
done

# Reject both flags together
if [ "$SHARED_BRANCH_FLAG" = "true" ] && [ "$NO_SHARED_BRANCH_FLAG" = "true" ]; then
  echo "ERROR: --shared-branch and --no-shared-branch are mutually exclusive" >&2
  exit 1
fi

# Export for phase agents to consume
if [ "$SHARED_BRANCH_FLAG" = "true" ]; then
  export PLANNER_SHARED_BRANCH=true
elif [ "$NO_SHARED_BRANCH_FLAG" = "true" ]; then
  export PLANNER_NO_SHARED_BRANCH=true
fi
```

These env vars are read by the Epic Gen phase agent during the branch-directive step.
They take precedence over the heuristic: either flag beats the recommender; neither flag
defers to it.

### 3. Plan mode

When mode is `plan`:

1. Extract the idea from the second argument.
2. Generate an initiative ID: `INIT-$(date +%s)-$(shuf -i 1000-9999 -n 1)` to avoid collision.
3. Initialize state: `planner_state_init "$INITIATIVE_ID" "$IDEA"`
4. Run the dispatch loop (see below).

### 4. Resume mode

When mode is `resume`:

1. Extract the initiative ID from the second argument.
2. Call `planner_resume "$INITIATIVE_ID"` — it outputs `PLANNER_NEXT_PHASE`, `PLANNER_INITIATIVE`, `PLANNER_LAST_LOG`.
3. If `PLANNER_COMPLETE=true` is output, report completion and stop.
4. Run the dispatch loop starting from the returned phase.

### 5. Status mode

When mode is `status`:

1. Extract the initiative ID from the second argument.
2. Read the state log: `planner_state_read "$INITIATIVE_ID"`
3. Run `planner_position_derive "$INITIATIVE_ID"` to get the current phase.
4. Report: current phase, initiative metadata, last 10 log entries, artifact listing.

### 6. Replan mode

When mode is `replan`:

1. Extract the initiative ID from the second argument.
2. Verify the `Regenerate` flag is present in the state log or initiative artifacts.
3. If no Regenerate flag, report that re-planning requires the flag and stop.
4. Ingest feedback from `${state_dir}/feedback/` — read all JSON files, compute drift.
5. Identify undispatched Backlog tickets (read intent files, cross-reference with spawn queue).
6. For each eligible ticket, regenerate the Planner Context block with adjusted confidence.
7. Validate the regenerated dependency set is still acyclic.
8. Write `META|replan|done` to the state log with counts: tickets regenerated, unchanged, skipped.
9. Do NOT modify dispatched, in-progress, or completed tickets.

### 7. Dispatch loop

Before the loop, export CLAUDE_PLUGIN_ROOT so phase agents can source libraries:

```bash
export CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-${HOME}/.claude/plugins/cache/ticket-planner/current}"
```

For each phase to run:

1. **Get the prompt** for the current phase:
   ```bash
   prompt=$(planner_prompt_for_phase "$PHASE" "$INITIATIVE_ID" "$IDEA" "$STATE_DIR")
   ```

2. **Check for hold phases.** If `PLANNER_REVIEW_HOLD=true` and phase is Review, pause and ask
   the user for input before proceeding. If `PLANNER_CONSENSUS_HOLD=true` and phase is Consensus,
   pause and ask before proceeding.

3. **Spawn the agent** using the Agent tool with:
   - `description`: "Run planner phase: $PHASE for $INITIATIVE_ID"
   - `prompt`: the phase prompt from `planner_prompt_for_phase`
   - `subagent_type`: "general-purpose" (the agent needs Read, Bash, and Linear API access)
   - `timeout_ms`: \$((PLANNER_PHASE_TIMEOUT * 1000)) (default 600000ms = 10min)

4. **Wait for the agent** to complete. The agent writes state log entries itself.

5. **Check the result:**
   - If the agent succeeded (state log shows `done` for this phase), advance to the next phase.
   - If the agent failed (state log shows `fail`), check retry count. If under
     `PLANNER_MAX_PHASE_RETRIES`, retry the same phase. Otherwise, report failure and stop.
   - If the state log has no terminal entry for the phase (agent crashed), retry
     (phases are idempotent, so re-running is safe).

6. **Advance** by re-reading `planner_position_derive`. If it returns empty, we're done —
   Completed phase reached. Report the completion summary.

### 8. After completion

When the dispatch loop finishes (Completed phase done):

1. Read the completion summary from `${STATE_DIR}/artifacts/COMPLETED.md`.
2. Report to the user:
   - Initiative ID
   - Epic ID
   - Number of tickets created
   - Whether auto-dispatch will pick them up (FLEET_AUTO_DISPATCH status)
   - Path to the state log for inspection

## Re-planning details

Re-planning is gated on the `Regenerate` flag. Without it, feedback is not read — the planner's output does not depend on execution history by default. This keeps planner runs reproducible.

When `Regenerate` is true:

1. **Ingest feedback:** Read all JSON files in `${state_dir}/feedback/`. Each file is an aggregate from `fleet-feedback.sh` containing per-ticket confidence drift data.
2. **Compute drift:** For each ticket, compare `confidence_predicted` (from the Planner Context block) against `confidence_actual` (from feedback). Drift = predicted - actual.
3. **Adjust confidence:** Apply drift to the original confidence signal. If systematic overconfidence is detected (avg drift > 0.15), apply a uniform penalty to all regenerated tickets.
4. **Scope restriction:** Only regenerate tickets that are:
   - In `Backlog` state (not dispatched, not in progress)
   - Not present in the spawn queue (not already enqueued)
   - Not completed or merged
5. **Re-validate:** The regenerated dependency set must be acyclic. If regeneration removes a ticket that others depend on, the dependent tickets must be updated or the regeneration aborted.
6. **Record:** Write a `META|replan` entry to the state log with:
   - Triggering flag
   - Feedback runs considered (file paths)
   - Drift summary per ticket
   - Tickets regenerated / unchanged / skipped counts
