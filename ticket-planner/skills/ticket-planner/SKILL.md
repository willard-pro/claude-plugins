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

Or, pass a grill-me validated intent file (recommended):

```
/ticket-planner plan ./intents/rt-collab.md
```

When an intent file is passed, the planner verifies the seal before creating any state. A missing seal, a tampered file, or a `do-not-proceed` verdict is a hard stop. On `ready`, the intent document is captured as `artifacts/intent.md` and the Appraisal phase treats it as authoritative.

If the run is interrupted (crash, timeout, manual stop), resume with `resume` — the router re-derives position from the state log and continues from where it left off.

### Plan flags

| Flag | Effect |
|------|--------|
| `--shared-branch` | Force a shared-branch directive on the epic regardless of the heuristic |
| `--no-shared-branch` | Suppress the shared-branch directive regardless of the heuristic |
| `--until <Phase>` | Stop the dispatch loop once `<Phase>` completes; `resume` continues |
| `--dry-run` | Alias for `--until Consensus` — everything on disk, nothing in Linear |
| `--project <name\|id>` | Linear project for the epic and its tickets (overrides `LINEAR_PROJECT`) |
| `--milestone <name\|id>` | Linear project milestone (overrides `LINEAR_PROJECT_MILESTONE`) |

The branch flags are optional. Supplying both together is an error. When neither is supplied,
the binary heuristic decides (≥ 3 tickets **and** dependency chain depth ≥ 2).

### Previewing a plan before it reaches Linear

Phases 1–6 are pure-artifact; phase 7 (Epic Gen) is the first Linear write. `--dry-run`
stops the loop exactly on that boundary:

```
/ticket-planner plan ./intents/rt-collab.md --dry-run
```

The run leaves the full ticket set on disk — `proposal.md`, `review.md`, `consensus.md`,
and one `specs/{slug}.md` per ticket — and creates no Linear entities. Review them, then:

```
/ticket-planner resume INIT-42
```

`--until` accepts any phase name from `planner_phase_sequence`. Naming an unknown phase,
or one the initiative has already passed, is rejected with the valid names (or the current
position) in the message.

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
| `PLANNER_REVIEW_HOLD` | false | When `true`, the loop stops after Review completes (env-var form of `--until Review`) |
| `PLANNER_CONSENSUS_HOLD` | false | When `true`, the loop stops after Consensus completes (env-var form of `--dry-run`) |
| `PLANNER_UNTIL` | *(unset)* | Phase name to stop after; the `--until` flag sets this |
| `PLANNER_MAX_PHASE_RETRIES` | 2 | Max retries per phase before failing the run |
| `PLANNER_PHASE_TIMEOUT` | 600 | Seconds before timing out a hung phase agent |
| `PLANNER_TSORT_TIMEOUT` | 30 | Seconds before timing out dependency graph sort |
| `PLANNER_CONFIDENCE_THRESHOLD` | 0.85 | Minimum confidence for `pre-approved` label |
| `PLANNER_IDEA_MAX_LENGTH` | 2000 | Maximum idea length in chars (truncated with warning) |
| `PLANNER_REQUIRE_INTENT` | false | When `true`, raw idea strings are refused — must pass a grill-me intent file |
| `LINEAR_PROJECT` | *(unset)* | Project name or id for created epics/tickets. Unset ⇒ no project field is sent |
| `LINEAR_PROJECT_MILESTONE` | *(unset)* | Project milestone name or id. Requires `LINEAR_PROJECT` when given by name |
| `FLEET_AUTO_DISPATCH` | false | Must be true for automatic fleet-controller dispatch |

When more than one stop point applies, the **earliest** wins — `PLANNER_REVIEW_HOLD=true`
with `--until TicketGen` stops after Review.

---

## Implementation

When invoked, follow this procedure:

### 1. Source libraries

`planner-lib-root.sh` resolves the plugin root across all install layouts
(marketplace cache → `~/.claude/skills/lib` → source checkout). Use it rather than
trusting `CLAUDE_PLUGIN_ROOT`, which is not guaranteed to be set or correct.

```bash
# Bootstrap: find the resolver itself. Try the marketplace cache first, then the
# SessionStart-hook copy in ~/.claude/skills/lib.
PLANNER_LIB_ROOT_SH=$(find "${HOME}/.claude/plugins/cache" \
  -path "*/ticket-planner/*/lib/planner-lib-root.sh" 2>/dev/null | sort | tail -1)
[ -f "$PLANNER_LIB_ROOT_SH" ] || PLANNER_LIB_ROOT_SH="${HOME}/.claude/skills/lib/planner-lib-root.sh"

if [ ! -f "$PLANNER_LIB_ROOT_SH" ]; then
  echo "FATAL: ticket-planner is not installed — no planner-lib-root.sh found." >&2
  echo "Run: claude plugin install ticket-planner@willard-pro-claude-plugins" >&2
  exit 5
fi

source "$PLANNER_LIB_ROOT_SH"
PLUGIN_ROOT=$(planner_require_lib_root) || exit $?
export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"

source "${PLUGIN_ROOT}/lib/planner-state.sh"
source "${PLUGIN_ROOT}/lib/planner-router.sh"
source "${PLUGIN_ROOT}/lib/planner-phase-prompts.sh"
```

If `planner_require_lib_root` fails it prints every path it tried plus the install
command, and exits 5. Never fall back to a hardcoded path — a wrong one makes every
spawned phase agent die at its first `source` with a bare "No such file or directory"
and no state log entry, so `resume` re-runs straight back into the same failure.

### 2. Parse mode

First argument is the mode: `plan`, `resume`, `status`, or `replan`.

### 2a. Parse override flags (plan mode only)

After extracting the idea, scan remaining arguments for override flags:

```bash
SHARED_BRANCH_FLAG=""
NO_SHARED_BRANCH_FLAG=""
UNTIL_PHASE=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --shared-branch) SHARED_BRANCH_FLAG=true ;;
    --no-shared-branch) NO_SHARED_BRANCH_FLAG=true ;;
    --dry-run) UNTIL_PHASE="$PLANNER_DRY_RUN_PHASE" ;;
    --until) shift; UNTIL_PHASE="${1:-}" ;;
    --until=*) UNTIL_PHASE="${1#*=}" ;;
    --project) shift; export LINEAR_PROJECT="${1:-}" ;;
    --project=*) export LINEAR_PROJECT="${1#*=}" ;;
    --milestone) shift; export LINEAR_PROJECT_MILESTONE="${1:-}" ;;
    --milestone=*) export LINEAR_PROJECT_MILESTONE="${1#*=}" ;;
  esac
  shift
done

# Reject both branch flags together
if [ "$SHARED_BRANCH_FLAG" = "true" ] && [ "$NO_SHARED_BRANCH_FLAG" = "true" ]; then
  echo "ERROR: --shared-branch and --no-shared-branch are mutually exclusive" >&2
  exit 1
fi

# Validate the stop phase against the canonical sequence before any state exists.
# planner_until_validate prints the valid phase names (or the current position)
# and returns 1 (unknown phase) or 2 (phase already passed).
if [ -n "$UNTIL_PHASE" ]; then
  planner_until_validate "$UNTIL_PHASE" "${INITIATIVE_ID:-}" || exit 1
  export PLANNER_UNTIL="$UNTIL_PHASE"
fi

# Export for phase agents to consume
if [ "$SHARED_BRANCH_FLAG" = "true" ]; then
  export PLANNER_SHARED_BRANCH=true
elif [ "$NO_SHARED_BRANCH_FLAG" = "true" ]; then
  export PLANNER_NO_SHARED_BRANCH=true
fi
```

`--project` and `--milestone` set the same environment variables the EpicGen and
TicketGen agents read, so a flag and an exported variable are interchangeable. Both
are optional: with neither set, no `projectId` is sent and behaviour is unchanged for
workspaces that do not use projects.

These env vars are read by the Epic Gen phase agent during the branch-directive step.
They take precedence over the heuristic: either flag beats the recommender; neither flag
defers to it.

### 3. Plan mode

When mode is `plan`:

1. Extract the idea from the second argument.
2. **PLANNER_REQUIRE_INTENT check.** If `PLANNER_REQUIRE_INTENT=true` and the argument is a raw string (not an existing file), hard stop and direct the user to `/grill-me`.
3. **Intent file gate (step 0).** If the argument resolves to an existing file:
   - Source `planner-intent-gate.sh` and run `planner_intent_gate "$path"`.
   - On hard stop (exit 1/2/3): report the reason and stop — no state created.
   - On pass (exit 0): capture `PLANNER_INTENT_READINESS`, `PLANNER_INTENT_RECOMMENDATION`, `PLANNER_INTENT_HASH`, `PLANNER_INTENT_PROFILE`.
   - Derive `IDEA` from the intent document's `## Objective` section: extract
     every line between the `## Objective` heading and the next `## ` heading,
     drop blank lines and the `_None specified_` placeholder, join with spaces,
     and truncate to `PLANNER_IDEA_MAX_LENGTH`. The full untruncated document is
     still available to phase agents via `artifacts/intent.md` — this value is
     only the durable, human-readable idea recorded in the state log.
     ```
     IDEA=$(awk '/^## Objective$/{f=1;next}/^## /{f=0}f' "$path" \
       | sed '/^[[:space:]]*$/d' | tr '\n' ' ' | sed 's/[[:space:]]*$//')
     [ "$IDEA" = "_None specified_" ] && IDEA=""
     IDEA="${IDEA:-$path}"
     IDEA="${IDEA:0:${PLANNER_IDEA_MAX_LENGTH:-2000}}"
     ```
     Do not gate the fallback on a command's exit status — `head`/`sed`/`awk`
     pipelines exit 0 even when they match nothing, so an empty-string check is
     the only reliable signal.
   - The original file path is preserved as `PLANNER_INTENT_FILE` for later artifact capture.
4. Generate an initiative ID: `INIT-$(date +%s)-$(shuf -i 1000-9999 -n 1)` to avoid collision.
5. Initialize state: `planner_state_init "$INITIATIVE_ID" "$IDEA"`
6. **If an intent file was accepted:** Copy the verified file byte-identically to `${state_dir}/artifacts/intent.md` and write a `META|intent|done|${READINESS},${RECOMMENDATION},${HASH}` state log entry.
7. Run the dispatch loop (see below).

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

`CLAUDE_PLUGIN_ROOT` was already resolved and exported in step 1. Phase prompts do not
depend on it being inherited — `planner_prompt_for_phase` resolves the plugin root at
prompt-generation time and interpolates the literal path into each prompt's preamble,
so the spawned agent never has to resolve anything.

For each phase to run:

1. **Get the prompt** for the current phase:
   ```bash
   prompt=$(planner_prompt_for_phase "$PHASE" "$INITIATIVE_ID" "$IDEA" "$STATE_DIR")
   ```

2. **Spawn the agent** using the Agent tool with:
   - `description`: "Run planner phase: $PHASE for $INITIATIVE_ID"
   - `prompt`: the phase prompt from `planner_prompt_for_phase`
   - `subagent_type`: "general-purpose" (the agent needs Read, Bash, and Linear API access)
   - `timeout_ms`: \$((PLANNER_PHASE_TIMEOUT * 1000)) (default 600000ms = 10min)

3. **Wait for the agent** to complete. The agent writes state log entries itself.

4. **Check the result.** The retry budget is derived from `fail` entries in the state
   log, not held in memory, so it survives a crashed router:

   ```bash
   if planner_phase_retries_exhausted "$INITIATIVE_ID" "$PHASE"; then
     echo "ERROR: ${PHASE} exhausted its retry budget (PLANNER_MAX_PHASE_RETRIES=${PLANNER_MAX_PHASE_RETRIES:-2})" >&2
     exit 1
   fi
   ```

   - If the agent succeeded (state log shows `done` for this phase), continue to step 5.
   - If the agent failed (state log shows `fail`) and the budget is not exhausted, retry
     the same phase.
   - If the state log has no terminal entry for the phase (agent crashed), retry
     (phases are idempotent, so re-running is safe).

5. **Check the stop condition.** `--until`, `--dry-run`, `PLANNER_REVIEW_HOLD` and
   `PLANNER_CONSENSUS_HOLD` collapse into one earliest-stop-phase decision:

   ```bash
   if planner_should_stop_after "$PHASE"; then
     echo "Stopped after ${PHASE} (stop point: $(planner_stop_phase))"
     echo "Artifacts:  ${STATE_DIR}/artifacts/"
     echo "Specs:      ${STATE_DIR}/artifacts/specs/"
     echo "State log:  $(planner_state_log "$INITIATIVE_ID")"
     echo "Continue:   /ticket-planner resume ${INITIATIVE_ID}"
     exit 0
   fi
   ```

   Report the initiative ID, the phase reached, the artifact directory, the spec files
   written, and the exact `resume` command. Do not ask the user a question — stopping is
   a terminal outcome of this invocation, and `resume` is the continuation.

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
