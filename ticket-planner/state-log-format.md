# State Log Format

Shared format spec for ticket-planner state logging. Phase agents write progress entries to the state log so the router can derive position and resume after interruption. Same pipe-delimited convention as ticket-auto's pipeline log.

## Format

```
ISO|PHASE|STEP|STATUS|MSG
```

Pipe-delimited, no escaping. `ISO` = UTC timestamp from `date -u +%Y-%m-%dT%H:%M:%SZ`.

## Usage

Phase agents write entries via `planner_state_write` from `planner-state.sh`:

```bash
source "${CLAUDE_PLUGIN_ROOT}/lib/planner-state.sh"
planner_state_write "${initiative_id}" "Appraisal" "scope" "start" "Interpreting idea"
# ... do work ...
planner_state_write "${initiative_id}" "Appraisal" "scope" "done" "Scope summary written"
```

Direct writes (without `planner_state_write`) bypass duplicate detection, atomic flock, and pipe sanitization — avoid them.

## Statuses

| Status | Meaning |
|--------|---------|
| `start` | Step began |
| `done`  | Step completed successfully |
| `fail`  | Step failed — will be re-executed on resume (not terminal) |
| `skip`  | Step skipped (not applicable, terminal) |

`fail` is explicitly non-terminal. On resume, a phase that ended with `fail` is re-executed. Only `done` and `skip` advance to the next phase.

## Phases & Steps

Each phase has one primary step. Agents may write additional `start`/`done` pairs for sub-steps.

### Appraisal
`scope` — interpret idea, establish scope, identify affected services

### Discovery
`explore` — trace code paths, resolve symbols, find prior art

### Architecture
`design` — evaluate alternatives, select approach, write ADR

### Specify
`synthesize` — write proposal, per-ticket specs, signals JSON blocks

### Review
`critique` — find gaps, risks, feasibility issues

### Consensus
`resolve` — address review findings, finalize proposal

### EpicGen
`create` — create Linear epic with idempotency guard
`branch-directive` — decide and optionally append shared-branch directive to epic description

### TicketGen
`validate` — pre-creation dependency and spec validation
`generate` — create planned child tickets with Planner Context blocks
`dispatch-gate` — post-creation verification, set `state:execution` on epic

### Completed
`summarize` — write completion summary, verify handoff readiness

## META Pseudo-Phase

`META` is a pseudo-phase for metadata entries outside the phase sequence:

| Step | Description |
|------|-------------|
| `schema` | Schema version declaration (must be first line: `META|schema|start|1`) |
| `initiative-id` | Initiative identifier |
| `idea` | The original business idea (pipes/newlines sanitized) |
| `intent` | Accepted grill-me intent: readiness, recommendation, seal hash |
| `replan` | Re-planning event: trigger, feedback runs, drift summary, counts |

### Invocation config

A second group of `META` steps records what the operator asked for at invocation
time. These are written with status `done` by `planner_config_set` and read back by
`planner_config_get`:

| Step | Description |
|------|-------------|
| `create-authorized` | The operator passed `--create`. Until this entry exists, no phase may write to Linear |
| `stop-after` | Phase to stop after (`--until`). The literal `none` clears one an earlier invocation set |
| `linear-project` / `linear-milestone` | Project and milestone as given on the command line |
| `linear-project-id` / `linear-milestone-id` | The UUIDs Epic Gen resolved them to, reused verbatim by Ticket Gen |
| `branch-override` | `shared` or `no-shared`, from the branch flags |

Config exists as log entries rather than shell variables because the dispatch loop
spans one process per phase — an `export` at argument-parsing time is gone by the next
iteration. Persisting the decision is what makes it survive both that boundary and a
crashed router.

Config steps are **last-write-wins** and are the one exception to duplicate-`done`
suppression: `resume --create` has to be able to override the stop point `plan`
recorded, and a suppressed re-write would leave the stale value in force. Read them
with `planner_config_get`, which takes the last matching entry.

## Schema

Schema version `1`. Declared as the first line of every state log:

```
2024-01-15T10:00:00Z|META|schema|start|1
```

`planner_state_init` writes this automatically. `planner_state_repair` validates it.

## Integrity

- **Duplicate detection:** `planner_state_write` rejects `done`→`done` for the same phase+step. Allows `fail`→`done` (retry pattern), and exempts the `META` invocation-config steps, which are last-write-wins.
- **State log repair:** `planner_state_repair` validates every line (ISO format, known phase, valid status), drops invalid lines, strips trailing partial writes (crash mid-write).
- **Phase ordering:** `planner_position_derive` reads the log in reverse to find the last completed phase. Incomplete trailing entries (crash mid-phase) cause resume at that phase.
- **Pipe character safety:** The message field may contain arbitrary text from agent output. `planner_state_write` does not sanitize the message parameter — callers should avoid `|` in messages. `planner_state_repair` preserves trailing fields by reconstructing with `printf` rather than `cut`.
