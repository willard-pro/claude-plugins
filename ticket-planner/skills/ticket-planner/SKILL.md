---
name: ticket-planner
description: 10-phase autonomous planner — turns a business idea into dependency-ordered planned tickets. Phases: Appraisal → Discovery → Architecture → Specify → Review → Consensus → Crosscheck → Epic Gen → Ticket Gen → Completed. Produces against frozen Planner Context and labels contracts.
allowed-tools: Bash, Read, Agent
---

# Ticket Planner — Idea-to-Tickets Pipeline

Autonomous 10-phase planner that turns business ideas into Linear initiatives, epics, and dependency-ordered planned tickets the existing `ticket-auto` pipeline consumes without special-casing.

Sits upstream of `ticket-auto` and `fleet-controller`. Produces against frozen consumption-side contracts — does not re-specify them.

## When to Use

| Trigger | Mode |
|---------|------|
| `/ticket-planner plan "idea"` | Plan a new initiative — artifacts only, nothing in Linear |
| `/ticket-planner resume <INIT_ID>` | Resume a crashed or paused initiative |
| `/ticket-planner resume <INIT_ID> --create` | Authorize creation and run through to Linear |
| `/ticket-planner status <INIT_ID>` | Show current phase and recent log entries |
| `/ticket-planner replan <INIT_ID>` | Re-plan an initiative from feedback (requires Regenerate flag) |
| `/ticket-planner doctor` | Preflight check — REPOS_ROOT, Linear team/labels, helper scripts |
| `/ticket-planner doctor <INIT_ID>` | Preflight check, plus resume branch/sha alignment (#217) |

## Modes

### Plan (`plan`)

Start a new planning run from a business idea. The planner initializes the state directory, creates the state log, and begins at the Appraisal phase. Each phase runs as an isolated agent; the router advances sequentially through the state machine.

```
/ticket-planner plan "Add real-time collaboration to the document editor"
```

**`plan` stops after Crosscheck and creates nothing in Linear.** Phases 1–7 write only
to disk; Epic Gen (phase 8) is the first Linear write, and `plan` does not include it.
Crosscheck (phase 7) is the last of those artifact-only phases — a deterministic
citation and cross-ticket propagation linter (see `### Crosscheck` below), not an
agent — and it runs unconditionally, so a blocking finding is caught and reported
before `plan` even reaches the create gate. This is not a flag that can be forgotten
or fail to take effect — the phase sequence for `plan` simply ends at the write
boundary. The run leaves the whole ticket set reviewable on disk (`proposal.md`,
`review.md`, `consensus.md`, `specs/*.md`) and reports the command to continue.

Or, pass a grill-me validated intent file (recommended):

```
/ticket-planner plan ./intents/rt-collab.md
```

When an intent file is passed, the planner verifies the seal before creating any state. A missing seal, a tampered file, or a `do-not-proceed` verdict is a hard stop. On `ready`, the intent document is captured as `artifacts/intent.md` and the Appraisal phase treats it as authoritative.

If the run is interrupted (crash, timeout, manual stop), resume with `resume` — the router re-derives position from the state log and continues from where it left off.

### Plan flags

Flags are accepted by both `plan` and `resume`. Every one of them is **written to the
state log the moment it is parsed** and re-read from there wherever it is used — none
of them is carried in an environment variable, because the dispatch loop spans a fresh
process per phase and an `export` does not survive that (#144).

| Flag | Effect |
|------|--------|
| `--create` | **`resume` only.** Authorize Linear creation, then run Epic Gen → Ticket Gen → Completed |
| `--accept CODE:"reason"` | **`resume` only.** Mark a Crosscheck finding genuine-and-expected; non-blocking on the next Crosscheck run. Repeatable |
| `--shared-branch` | Force a shared-branch directive on the epic regardless of the heuristic |
| `--no-shared-branch` | Suppress the shared-branch directive regardless of the heuristic |
| `--until <Phase>` | Stop the dispatch loop once `<Phase>` completes; `resume` continues |
| `--dry-run` | Accepted and redundant — stopping before Linear is already the default |
| `--team <key\|name\|id>` | Linear team to create on (overrides `LINEAR_TEAM_ID`) |
| `--project <name\|id>` | Linear project for the epic and its tickets |
| `--milestone <name\|id>` | Linear project milestone (needs `--project` when given by name) |

The branch flags are optional. Supplying both together is an error. When neither is supplied,
the binary heuristic decides (≥ 3 tickets **and** dependency chain depth ≥ 2).

`--create` is rejected in `plan` mode. Authorizing creation is a separate, deliberate
invocation made *after* the artifacts exist and have been read — a single command that
both plans and creates would be the footgun this design exists to remove.

### The create gate

Phases 1–7 are pure-artifact; phase 8 (Epic Gen) is the first Linear write. The loop
stops on that boundary unless the initiative has been explicitly authorized to cross it:

```
/ticket-planner plan ./intents/rt-collab.md     # → stops after Crosscheck
# read the artifacts…
/ticket-planner resume INIT-42 --create         # → Epic Gen, Ticket Gen, Completed
```

`--create` writes `META|create-authorized|done` to the state log **before the loop
starts**. Every later check reads it back from there, so the authorization survives a
crashed router, a killed phase agent, and the process boundary between every pair of
phases — a `resume` after a crash mid-Epic-Gen proceeds without re-passing the flag,
because the decision is on disk rather than in a variable that died with the process.

A plain `resume` on an initiative sitting at the gate does not create anything. It
reports the position and the `--create` command, and stops. Epic Gen and Ticket Gen
each re-verify the authorization from the state log themselves, so an unauthorized
initiative produces no Linear entities even if something dispatches them directly.

`--until <Phase>` narrows the stop further and is persisted the same way. When both
apply the **earliest** wins — `--until TicketGen` without `--create` still stops at
Crosscheck. `--until` accepts any phase name from `planner_phase_sequence`; an unknown
phase, or one the initiative has already passed, is rejected with the valid names (or
the current position) in the message.

### Accepting a genuine Crosscheck finding (`--accept`)

Some blocking findings are correct about the artifacts but not defects — most often
`CARVE_SCOPE_LOST` when a ticket count was deliberately rescoped after Specify and the
rescope is already documented in `consensus.md` or a post-Consensus coverage-audit doc.
Before this flag existed the only way to unblock the create gate was hand-writing a
`META|crosscheck|accepted|...`-shaped line directly into `state.log` — undocumented,
easy to get wrong, and indistinguishable from an automated pass unless you already knew
to look for it (#222).

```
/ticket-planner resume INIT-42 --accept CARVE_SCOPE_LOST:"documented rescope, see consensus.md#tickets-6"
```

`--accept CODE:"reason"` is **`resume` only**, same restriction as `--create` — a
finding can only be accepted after Crosscheck has reported it. It is parsed and
persisted the same way `--create`/`--until` are: written to the state log as
`META|crosscheck|accepted|<CODE> <reason>` the moment it is parsed, before the dispatch
loop reaches Crosscheck again, so the decision survives the process boundary between
phases (the governing principle from #144 — see [Plan flags](#plan-flags) above). The
flag is repeatable — pass it once per code to accept more than one finding in the same
`resume`.

Once accepted, the code stays accepted for the life of the initiative; there is no
un-accept. On the next Crosscheck run, `planner_crosscheck_run` treats a finding whose
code was accepted as non-blocking — the create gate does not see it — but still writes
it to the state log as `META|crosscheck|accepted|<CODE> <message>` every time it
recurs, so it stays visible in `status` mode's Crosscheck findings section and in
`COMPLETED.md`'s Warnings section exactly like an automated pass or fail, with the
operator's reason attached. Only the code named survives — a new finding under a
different code still blocks normally.

### Resume (`resume`)

Continue an interrupted or paused run. The router reads the state log, finds the last incomplete phase, and resumes from there. Completed phases are skipped.

```
/ticket-planner resume INIT-42
```

`resume` is also the mode that authorizes Linear creation. Add `--create` once the
artifacts have been reviewed:

```
/ticket-planner resume INIT-42 --create
```

`--create` is checked once, at the top of the invocation, and persisted immediately —
see [The create gate](#the-create-gate). A bare `resume` never crosses the write
boundary, so recovering a crashed Discovery phase cannot silently authorize Epic Gen.

`resume` is also the only mode that accepts a genuine-but-expected Crosscheck finding —
see [Accepting a genuine Crosscheck finding](#accepting-a-genuine-crosscheck-finding---accept).

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

### Doctor (`doctor`)

Run every environment/Linear-side preflight check the planner has ever hit mid-run,
before starting or resuming a run. Deterministic bash, no Linear writes unless
`--fix` is passed:

```
/ticket-planner doctor
/ticket-planner doctor INIT-42          # also checks resume branch/sha alignment (#217)
/ticket-planner doctor --fix            # create any missing static contract label
```

Checks: `REPOS_ROOT` resolves and is a real directory; the Linear team resolves
(`--team`/`LINEAR_TEAM_ID`/the workspace's only team); the 4 static contract
labels (`planned`, `epic`, `pre-approved`, `state:execution`) exist on that team —
reported individually, and created with `--fix`; when an initiative id is given,
whether the live `REPOS_ROOT` checkout for each repo Discovery explored still
matches the ref it pinned, or an isolated worktree is available (the same
mechanism Crosscheck itself falls back to, see #217 below); and whether the
cross-plugin helper scripts the phase prompts reference
(`planned-ticket-check.sh`, `branch-directive-check.sh` from
`ticket-auto-pipeline`, `grill-seal.sh` from `grill-me`) actually resolve on
this install. Every check that has ever cost a mid-run failure and a manual
recovery step is covered here — see the `project-ticket-planner-preflight-gaps`
history in the issue this mode was added for (#232).

`doctor` never creates state and never dispatches a phase — it is safe to run
before `plan`, before `resume`, or any time something in the pipeline feels off.

## The 10 Phases

| # | Phase | What it does | Output |
|---|-------|-------------|--------|
| 1 | Appraisal | Interprets the idea, establishes initiative scope | Scope summary |
| 2 | Discovery | Explores affected repos, gathers context | Code paths, symbols, APIs |
| 3 | Architecture | Determines the technical approach | Architecture decision record |
| 4 | Specify | Synthesizes proposal + writes per-ticket specs with signals, self-lints citations | `proposal.md`, spec files |
| 5 | Review | Critiques the proposal and specs (internal by default) | Review findings |
| 6 | Consensus | Resolves review findings into a settled plan | Finalized proposal |
| 7 | Crosscheck | Deterministic bash — citation + cross-ticket propagation checks against the artifacts and the live repo | `META|crosscheck` events; gates Epic Gen on a blocking finding |
| 8 | Epic Gen | Creates the initiative epic in Linear — **first Linear write, gated on `--create`** | Linear epic with `epic` label |
| 9 | Ticket Gen | Creates planned child tickets, computes confidence, gate-dispatches | Linear tickets, `state:execution` on epic |
| 10 | Completed | Terminal phase — summarizes the run; auto-dispatched right after Ticket Gen, no operator action | `COMPLETED.md`, terminal state log entry |

### Crosscheck

Unlike every other phase, Crosscheck is not an agent — `planner_crosscheck_run` (in
`lib/planner-crosscheck.sh`) is deterministic bash, so the dispatch loop calls it
directly instead of spawning one (see step 7a below). It wires in two check families:

- **Citation + precedent linter** ([#172](https://github.com/willard-pro/claude-plugins/issues/172)) — every `path:line` citation and Signals `TargetSymbols` entry must resolve against `REPOS_ROOT`; every "mirrors the existing `X`"-style precedent claim must name a symbol that actually exists in the repo.
- **Cross-ticket propagation linter** ([#173](https://github.com/willard-pro/claude-plugins/issues/173)) — a Consensus resolution or in-spec forward reference naming 2+ tickets must actually reach all of them; a post-Specify ticket-count change is flagged for manual scope audit.

The citation + precedent linter also runs once earlier, as a self-lint at the end of
the Specify phase ([#218](https://github.com/willard-pro/claude-plugins/issues/218)) —
the Specify agent runs `planner_crosscheck_citations` against its own fresh output and
fixes findings before handing off to Review, catching the defect class in the same
context window that introduced it. This front-loads the check; it does not replace
Crosscheck, which still re-runs it as the final gate against the fully-reviewed
artifacts.

Every finding is written to state.log as `META|crosscheck|fail|<CODE> <message>` — the
shape `ticket-retro`'s failure-histogram parser already reads (see
[#176](https://github.com/willard-pro/claude-plugins/issues/176),
[#177](https://github.com/willard-pro/claude-plugins/issues/177)). A blocking finding
halts the dispatch loop immediately, before the create gate is even checked — retrying
a deterministic check against unchanged artifacts cannot produce a different answer, so
this is not folded into the phase-retry budget. Fix the cited artifact and
`/ticket-planner resume <INIT_ID>` re-runs Crosscheck; it proceeds once clean. If the
finding is genuine but expected rather than a defect (a documented rescope, say),
`/ticket-planner resume <INIT_ID> --accept CODE:"reason"` is the supported alternative
to fixing the artifact — see [Accepting a genuine Crosscheck finding](#accepting-a-genuine-crosscheck-finding---accept).

`#174` (bypass sweep for guarded fields) and `#175` (cross-initiative contract check)
are separate, not-yet-implemented check families — Crosscheck runs only the two above
today.

#### Resolving against the ref Discovery explored, not whatever REPOS_ROOT is now ([#217](https://github.com/willard-pro/claude-plugins/issues/217))

REPOS_ROOT is a shared checkout — it can move to a different branch between
Discovery and Crosscheck (another terminal, another initiative's pipeline, an
operator). Left unaddressed, the citation linter resolves against whatever the
live checkout happens to be on *right now*, which produces
`CITATION_UNRESOLVED`/`CITATION_LINE_OUT_OF_RANGE` findings indistinguishable
from a genuinely bad citation — confirmed live on two initiatives (VS-2, VS-3),
worked around both times by hand with a throwaway worktree.

The fix: Discovery records the ref it actually explored per repo —
`META|discovery|repo-ref|<repo>@<branch>@<sha>` — and `planner_crosscheck_citations`
(`lib/planner-crosscheck-citations.sh`) reads it back via
`planner_crosscheck_repo_ref_setup` (`lib/planner-crosscheck-repo-ref.sh`) before
resolving any citation. For any repo whose live checkout no longer matches the
pinned sha, it creates (or reuses) an isolated `git worktree` alongside the live
repo — `<repos_root>/<repo>-crosscheck-<ref>-<short-sha>` — and excludes the live
copy from resolution for the duration of that Crosscheck run, so citations
resolve against the worktree instead. The live checkout is never touched. This is
best-effort: a repo Discovery recorded no ref for, or one whose worktree creation
fails, silently falls back to resolving against whatever the live checkout has.

**Hard rule: the planner never runs `git checkout`, `git switch`, or `git reset`
against a REPOS_ROOT repo — anywhere, in any phase.** It may only read from a
REPOS_ROOT repo, or create a worktree alongside it. This is enforced by
convention in every phase prompt that touches REPOS_ROOT (see Discovery's
prompt in `planner-phase-prompts.sh`) since the planner's own agents are the
only thing that could violate it — there is no live checkout mutation path in
the deterministic bash libraries to guard against.

## Target Symbols Grammar

The Signals `TargetSymbols` field — and any `path:line` citation in proposal.md
or spec prose — is parsed literally by the citation linter
(`lib/planner-crosscheck-citations.sh`, [#172](https://github.com/willard-pro/claude-plugins/issues/172)),
not read as natural language. Getting the shape wrong is the single biggest
source of Crosscheck findings across every initiative to date — one
initiative's remediation round found 17 of its 22 raw findings were the same
mistake (annotation on the wrong side of the colon). This section documents
the grammar the linter actually enforces, so Specify can follow it instead of
re-deriving it from checker failures one finding at a time:

```
TargetSymbols := entry (';' entry)*
entry         := Name ':' location (',' location)*
              |  Name ':' path                      -- no line at all: checks only that the file exists
Name          := identifier ['(' annotation ')']     -- annotation goes HERE, never in `location`
              |  identifier '/' identifier ...       -- two+ related symbols sharing the SAME location
location      := [path ':'] line ['-' line2]         -- omitting `path:` reuses the previous location's path
```

- **Annotations belong on the `Name` side, never the path side.**
  `uploadFile (new):UploadPageClient.tsx:304-310` resolves cleanly.
  `uploadFile:UploadPageClient.tsx (new):304-310` does not — the parser
  treats everything up to the trailing `:line` as the path, so the
  annotation gets folded into the literal filename it searches for
  (`UploadPageClient.tsx (new)`), which never exists on disk. This single
  mistake is the majority-cause finding above.
- **`(new)` and its variants skip the unresolved-path check only.** `(new)`,
  `(new in <slug>, ...)`, or any parenthetical whose first word is `new`
  tells the linter this file doesn't exist yet — don't flag
  `CITATION_UNRESOLVED` for it. It does not skip the line-range or
  symbol-proximity checks once the file exists.
- **Don't cite two symbols against two different line ranges in one compound
  `Name1()/Name2()` entry.** The linter checks *every* `/`-separated name in
  `Name` against *every* comma-separated range in the entry (each within
  `±PLANNER_CROSSCHECK_SYMBOL_PROXIMITY` lines, or via an earlier definition
  line) — it does not pair the first name with the first range and the
  second with the second. `check_llm_allowed()/record_llm_usage():guard.py:58-87,89-115`
  happens to pass when the two symbols sit close together and fails when
  they don't, because each range is checked against both names
  independently. Write one entry per symbol instead:
  `check_llm_allowed():guard.py:58-87;record_llm_usage():guard.py:89-115`.
  A compound `Name1/Name2` sharing one *single* location is fine — the
  ambiguity only appears once a second, distinct range enters the same entry.
- **A concept with no citable source location is not a `TargetSymbols`
  entry.** A migration description, a sibling initiative's slug, or any
  other non-file concept has nothing for the linter to resolve against
  `REPOS_ROOT` — state it in prose (Summary, Technical Approach, Risk
  Register), not as a colon-path citation.

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

- **Bash side (deterministic):** State log parsing, position derivation, phase transition validation, entity idempotency checks, dependency acyclicity validation, `planned-ticket-check.sh` invocation, the Crosscheck phase itself (`planner-crosscheck.sh`).
- **Agent side (LLM):** Per-phase content — appraisal, discovery, architecture, proposal, review, consensus, spec writing, ticket body generation.

The router never reasons about content; phases never mutate state directly (they write log entries that the router reads).

## Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `PLANNER_REVIEW_HOLD` | false | When `true`, the run stops after Review. Read **once, at argument-parsing time**, and persisted as `--until Review` |
| `PLANNER_UNTIL` | *(unset)* | Phase name to stop after. Read once at parsing time, exactly as `--until` is |
| `PLANNER_MAX_PHASE_RETRIES` | 2 | Max retries per phase before failing the run |
| `PLANNER_PHASE_TIMEOUT` | 600 | Seconds before timing out a hung phase agent |
| `PLANNER_TSORT_TIMEOUT` | 30 | Seconds before timing out dependency graph sort |
| `PLANNER_CONFIDENCE_THRESHOLD` | 0.85 | Minimum confidence for `pre-approved` label |
| `PLANNER_IDEA_MAX_LENGTH` | 2000 | Maximum idea length in chars (truncated with warning) |
| `PLANNER_REQUIRE_INTENT` | false | When `true`, raw idea strings are refused — must pass a grill-me intent file |
| `LINEAR_TEAM_ID` | *(unset)* | Team key, name or id to create on, the fallback for `--team`. Unset ⇒ the workspace's only team, or an error naming the candidates |
| `LINEAR_PROJECT` | *(unset)* | Default project name or id for created epics/tickets, read once at parsing time as the fallback for `--project`. Unset ⇒ no project field is sent |
| `LINEAR_PROJECT_MILESTONE` | *(unset)* | Default project milestone name or id, the fallback for `--milestone`. Requires a project when given by name |
| `FLEET_AUTO_DISPATCH` | false | Must be true for automatic fleet-controller dispatch |

Every variable in this table is read **once, in the shell that parses arguments**, and
its effect is persisted to the state log there and then. None of them is read again
mid-run: the dispatch loop runs a fresh process per phase, so a variable exported during
parsing is gone by the next iteration. Setting one of them *after* a run has started has
no effect — re-invoke with the corresponding flag instead.

`PLANNER_CONSENSUS_HOLD` is gone. Stopping before the first Linear write is now the
default and needs no variable.

When more than one stop point applies, the **earliest** wins — `PLANNER_REVIEW_HOLD=true`
with `--until TicketGen` stops after Review, and an unauthorized run stops at Crosscheck
whatever `--until` says.

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

First argument is the mode: `plan`, `resume`, `status`, `replan`, or `doctor`. Capture it as
`MODE` — step 2a checks it when rejecting `--create` outside `resume`.

```bash
MODE="${1:-}"
shift || true
```

### 2z. Doctor mode (short-circuits before flag parsing)

`doctor` takes none of the plan/resume flags in step 2a — it has its own
optional initiative id and its own `--fix` flag — and it never touches the
state log or the create gate, so it runs and exits here rather than falling
through to steps 2a/2b.

```bash
if [ "$MODE" = "doctor" ]; then
  source "${PLUGIN_ROOT}/lib/planner-doctor.sh"
  DOCTOR_OUTPUT=$(planner_doctor_run "$@")
  DOCTOR_ISSUES=$?
  echo "$DOCTOR_OUTPUT"
fi
```

Render the `---BEGIN_VARS---`/`---END_VARS---` block the same way `/ticket-env-check`
and `/fleet-env-check` already do: first pipe-delimited row is the header, the
`ROWCOUNT=N` line is metadata, every remaining row renders as a markdown table
(**Name**, **Status**, **Value**, **Location**, **Note**). After the table, report
"N issue(s) found" (`$DOCTOR_ISSUES`) or "All checks passed." Then **stop — do not
proceed to any other mode's steps.**

### 2a. Parse override flags

Flags are accepted in both `plan` and `resume` mode. **Parse them into plain shell
variables here; do not export them.** They are persisted to the state log in step 2b,
once an initiative ID exists, and every consumer reads them back from there.

Exporting is what broke `--dry-run` (#144): the dispatch loop below spans one Bash tool
call per phase with an Agent tool call between, so each iteration is a fresh process and
an `export` from this step is simply not there when a later phase looks for it.

```bash
SHARED_BRANCH_FLAG=""
NO_SHARED_BRANCH_FLAG=""
CREATE_FLAG=""
UNTIL_PHASE=""
TEAM_REF=""
PROJECT_REF=""
MILESTONE_REF=""
ACCEPT_FLAGS=()

# Env vars are the defaults for the corresponding flags, read once, here.
UNTIL_PHASE="${PLANNER_UNTIL:-}"
[ "${PLANNER_REVIEW_HOLD:-false}" = "true" ] && UNTIL_PHASE="${UNTIL_PHASE:-Review}"
TEAM_REF="${LINEAR_TEAM_ID:-}"
PROJECT_REF="${LINEAR_PROJECT:-}"
MILESTONE_REF="${LINEAR_PROJECT_MILESTONE:-}"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --shared-branch) SHARED_BRANCH_FLAG=true ;;
    --no-shared-branch) NO_SHARED_BRANCH_FLAG=true ;;
    --create) CREATE_FLAG=true ;;
    --dry-run) ;;   # redundant: stopping before the first Linear write is the default
    --until) shift; UNTIL_PHASE="${1:-}" ;;
    --until=*) UNTIL_PHASE="${1#*=}" ;;
    --accept) shift; ACCEPT_FLAGS+=("${1:-}") ;;
    --accept=*) ACCEPT_FLAGS+=("${1#*=}") ;;
    --team) shift; TEAM_REF="${1:-}" ;;
    --team=*) TEAM_REF="${1#*=}" ;;
    --project) shift; PROJECT_REF="${1:-}" ;;
    --project=*) PROJECT_REF="${1#*=}" ;;
    --milestone) shift; MILESTONE_REF="${1:-}" ;;
    --milestone=*) MILESTONE_REF="${1#*=}" ;;
  esac
  shift
done

# Reject both branch flags together
if [ "$SHARED_BRANCH_FLAG" = "true" ] && [ "$NO_SHARED_BRANCH_FLAG" = "true" ]; then
  echo "ERROR: --shared-branch and --no-shared-branch are mutually exclusive" >&2
  exit 1
fi

# --create is a deliberate, separate gesture made after reading the artifacts.
# A single command that both plans and creates is the footgun this design removes.
if [ "$CREATE_FLAG" = "true" ] && [ "$MODE" = "plan" ]; then
  echo "ERROR: --create is not valid for 'plan'. Plan first, read the artifacts, then:" >&2
  echo "       /ticket-planner resume <INIT_ID> --create" >&2
  exit 1
fi

# --accept, like --create, is only meaningful after Crosscheck has reported the
# finding it accepts. Rejected in 'plan' for the same reason --create is (#222).
if [ "${#ACCEPT_FLAGS[@]}" -gt 0 ] && [ "$MODE" = "plan" ]; then
  echo "ERROR: --accept is not valid for 'plan'. Accept a finding only after Crosscheck reports it:" >&2
  echo "       /ticket-planner resume <INIT_ID> --accept CODE:\"reason\"" >&2
  exit 1
fi

# Validate every --accept CODE:"reason" pair up front — CODE must look like a
# real Crosscheck code (upper-snake-case, same shape _planner_crosscheck_emit_finding
# requires) and reason must be non-empty. Split on the first ':' only, so a reason
# containing ':' (a URL, a doc anchor) is preserved intact.
for _accept_arg in "${ACCEPT_FLAGS[@]}"; do
  [ -z "$_accept_arg" ] && continue
  case "$_accept_arg" in
  *:*)
    _accept_code="${_accept_arg%%:*}"
    _accept_reason="${_accept_arg#*:}"
    ;;
  *)
    echo "ERROR: --accept requires CODE:\"reason\" (got '${_accept_arg}')" >&2
    exit 1
    ;;
  esac
  if [[ ! "$_accept_code" =~ ^[A-Z][A-Z0-9_]*$ ]]; then
    echo "ERROR: --accept code '${_accept_code}' is not a valid Crosscheck code (expected upper-snake-case, e.g. CARVE_SCOPE_LOST)" >&2
    exit 1
  fi
  if [ -z "$_accept_reason" ]; then
    echo "ERROR: --accept requires a non-empty reason: CODE:\"reason\"" >&2
    exit 1
  fi
done
```

Validate `--until` against the canonical sequence before writing anything.
`planner_until_validate` prints the valid phase names (or the current position) and
returns 1 (unknown phase) or 2 (phase already passed):

```bash
if [ -n "$UNTIL_PHASE" ]; then
  planner_until_validate "$UNTIL_PHASE" "${INITIATIVE_ID:-}" || exit 1
fi
```

### 2b. Persist the invocation config

Run this **immediately after the initiative ID is known and `planner_state_init` has
run** — in `plan` mode that is step 3's item 6, in `resume` mode it is item 2, before
anything is dispatched. Nothing may be dispatched before it: the persisted config is what every
later phase reads, and `--create` must be durable *before* Epic Gen can be reached, so
that a crash in between does not lose the authorization.

```bash
# Authorization first — it is the entry that must survive a crash.
if [ "$CREATE_FLAG" = "true" ]; then
  planner_authorize_create "$INITIATIVE_ID" "operator passed --create"
  # --create with no new --until clears a stop point an earlier invocation set,
  # so `plan --until Crosscheck` does not keep stopping the authorized run.
  planner_stop_after_set "$INITIATIVE_ID" "$UNTIL_PHASE"
elif [ -n "$UNTIL_PHASE" ]; then
  planner_stop_after_set "$INITIATIVE_ID" "$UNTIL_PHASE"
fi

[ -n "$TEAM_REF" ] && planner_config_set "$INITIATIVE_ID" "linear-team" "$TEAM_REF"
[ -n "$PROJECT_REF" ] && planner_config_set "$INITIATIVE_ID" "linear-project" "$PROJECT_REF"
[ -n "$MILESTONE_REF" ] && planner_config_set "$INITIATIVE_ID" "linear-milestone" "$MILESTONE_REF"

if [ "$SHARED_BRANCH_FLAG" = "true" ]; then
  planner_config_set "$INITIATIVE_ID" "branch-override" "shared"
elif [ "$NO_SHARED_BRANCH_FLAG" = "true" ]; then
  planner_config_set "$INITIATIVE_ID" "branch-override" "no-shared"
fi

# --accept CODE:"reason" (#222): recorded via planner_crosscheck_accept_set, not
# planner_config_set — a set of accepted codes, not a single last-write-wins value.
if [ "${#ACCEPT_FLAGS[@]}" -gt 0 ]; then
  source "${CLAUDE_PLUGIN_ROOT}/lib/planner-crosscheck.sh"
  for _accept_arg in "${ACCEPT_FLAGS[@]}"; do
    [ -z "$_accept_arg" ] && continue
    planner_crosscheck_accept_set "$INITIATIVE_ID" "${_accept_arg%%:*}" "${_accept_arg#*:}"
  done
fi
```

Config is last-write-wins, so a later invocation overrides an earlier one — that is how
`resume --create` lifts the stop point `plan` recorded. `planner_config_set` rejects any
key outside `PLANNER_CONFIG_KEYS`; do not invent new ones inline. `--accept` is the one
exception to the `planner_config_set` path — accepted codes accumulate rather than
overwrite, so it goes straight to `planner_state_write` via `planner_crosscheck_accept_set`
(see [Accepting a genuine Crosscheck finding](#accepting-a-genuine-crosscheck-finding---accept)).

The team, project and milestone refs are recorded here as given. Epic Gen resolves them
to UUIDs, records the resolved ids with `planner_config_set`, and Ticket Gen reads those
ids straight back — so the epic and every child land on the same team and in the same
project, with one name lookup for the whole run.

`--team` is optional. With nothing set, `planner_linear_resolve_team_id` falls back to
the workspace's only team; when several are visible it fails naming them, because
guessing would file an entire initiative against the wrong board.

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
6. **Persist the invocation config** — run step 2b now that `$INITIATIVE_ID` exists.
7. **If an intent file was accepted:** Copy the verified file byte-identically to `${state_dir}/artifacts/intent.md` and write a `META|intent|done|${READINESS},${RECOMMENDATION},${HASH}` state log entry.
8. Run the dispatch loop (see below). It ends after Crosscheck — `plan` creates nothing in Linear.

### 4. Resume mode

When mode is `resume`:

1. Extract the initiative ID from the second argument.
2. **Persist the invocation config** — run step 2b before anything is dispatched. `--create` must be on disk before Epic Gen becomes reachable, so that a crash in between cannot lose it.
3. Call `planner_resume "$INITIATIVE_ID"` — it outputs `PLANNER_NEXT_PHASE`, `PLANNER_INITIATIVE`, `PLANNER_LAST_LOG`.
4. If `PLANNER_COMPLETE=true` is output, run the step-8 completion verification
   before reporting completion — an initiative whose Completed phase never ran also
   reports `PLANNER_COMPLETE=true` here once its log has a terminal entry.
5. Run the dispatch loop starting from the returned phase. When that phase is
   `Completed`, it is the terminal phase and still has to run — see step 7.

### 5. Status mode

When mode is `status`:

1. Extract the initiative ID from the second argument.
2. Read the state log: `planner_state_read "$INITIATIVE_ID"`
3. Run `planner_position_derive "$INITIATIVE_ID"` to get the current phase.
4. Run `planner_crosscheck_findings_summary "$INITIATIVE_ID"` (source
   `planner-crosscheck.sh` first if not already sourced). Empty output means no
   Crosscheck findings recorded — omit the section. Otherwise report it as its
   own "Crosscheck findings" section: the per-code lines and the trailing
   `TOTAL:` line, and note whether the initiative is currently halted on a
   blocking finding (blocking total > 0 and current phase is still
   `Crosscheck`) — see #176.
5. Report: current phase, initiative metadata, last 10 log entries, artifact listing.

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

1. **Check the create gate** before generating anything. Epic Gen and Ticket Gen write
   to Linear; an initiative that has not been authorized stops here instead:

   ```bash
   if ! planner_create_gate_check "$INITIATIVE_ID" "$PHASE"; then
     echo "Planning complete — nothing was created in Linear."
     echo "Artifacts:  ${STATE_DIR}/artifacts/"
     echo "Specs:      ${STATE_DIR}/artifacts/specs/"
     echo "State log:  $(planner_state_log "$INITIATIVE_ID")"
     echo "To create:  /ticket-planner resume ${INITIATIVE_ID} --create"
     exit 0
   fi
   ```

   This is a normal terminal outcome of a `plan` run, not a failure — report it as
   completion of the planning stage. Do not ask the user whether to proceed; `resume
   --create` is the continuation, and it is theirs to invoke after reading the specs.

1a. **Crosscheck is not an agent phase.** If `$PHASE` is `Crosscheck`, run the check
    directly and skip steps 2–5 entirely — there is no prompt for it in
    `planner_prompt_for_phase`:

    ```bash
    source "${CLAUDE_PLUGIN_ROOT}/lib/planner-crosscheck.sh"
    if ! planner_crosscheck_run "$INITIATIVE_ID"; then
      echo "Crosscheck found blocking findings — fix the cited artifacts and resume."
      echo "Findings:   grep 'META|crosscheck|fail' $(planner_state_log "$INITIATIVE_ID")"
      echo "Artifacts:  ${STATE_DIR}/artifacts/"
      echo "Resume:     /ticket-planner resume ${INITIATIVE_ID}"
      exit 0
    fi
    ```

    Do not fall through to step 5's retry-budget check on a Crosscheck failure — a
    blocking finding is a content defect in the artifacts, not a transient agent
    failure, and re-running the same deterministic check against unchanged artifacts
    cannot produce a different answer. Stopping here (exit 0, a normal terminal
    outcome, not an error) and waiting for `resume` after the operator edits the
    artifacts is the correct response, exactly like the create gate. On success,
    continue to step 6 (skip 2–5).

2. **Get the prompt** for the current phase:
   ```bash
   prompt=$(planner_prompt_for_phase "$PHASE" "$INITIATIVE_ID" "$IDEA" "$STATE_DIR")
   ```

   The prompt is built fresh in this process and carries the invocation config —
   project, milestone, branch override — interpolated as literals, read from the state
   log by `planner_prompt_for_phase`. Do not try to pass configuration to the agent
   through the environment; the agent does not inherit this shell.

3. **Spawn the agent** using the Agent tool with:
   - `description`: "Run planner phase: $PHASE for $INITIATIVE_ID"
   - `prompt`: the phase prompt from `planner_prompt_for_phase`
   - `subagent_type`: "general-purpose" (the agent needs Read, Bash, and Linear API access)
   - `timeout_ms`: \$((PLANNER_PHASE_TIMEOUT * 1000)) (default 600000ms = 10min)

4. **Wait for the agent** to complete. The agent writes state log entries itself.

5. **Check the result.** The retry budget is derived from `fail` entries in the state
   log, not held in memory, so it survives a crashed router:

   ```bash
   if planner_phase_retries_exhausted "$INITIATIVE_ID" "$PHASE"; then
     echo "ERROR: ${PHASE} exhausted its retry budget (PLANNER_MAX_PHASE_RETRIES=${PLANNER_MAX_PHASE_RETRIES:-2})" >&2
     exit 1
   fi
   ```

   - If the agent succeeded (state log shows `done` for this phase), continue to step 6.
   - If the agent failed (state log shows `fail`) and the budget is not exhausted, retry
     the same phase.
   - If the state log has no terminal entry for the phase (agent crashed), retry
     (phases are idempotent, so re-running is safe).

6. **Check the stop condition.** The create gate and `--until` collapse into one
   earliest-stop-phase decision, resolved entirely from the state log — the initiative
   ID is the only argument, and nothing is read from the environment:

   ```bash
   if planner_should_stop_after "$INITIATIVE_ID" "$PHASE"; then
     echo "Stopped after ${PHASE} — $(planner_stop_reason "$INITIATIVE_ID")"
     echo "Artifacts:  ${STATE_DIR}/artifacts/"
     echo "Specs:      ${STATE_DIR}/artifacts/specs/"
     echo "State log:  $(planner_state_log "$INITIATIVE_ID")"
     if planner_create_authorized "$INITIATIVE_ID"; then
       echo "Continue:   /ticket-planner resume ${INITIATIVE_ID}"
     else
       echo "To create:  /ticket-planner resume ${INITIATIVE_ID} --create"
     fi
     exit 0
   fi
   ```

   Report the initiative ID, the phase reached, the artifact directory, the spec files
   written, and the exact continuation command. Do not ask the user a question —
   stopping is a terminal outcome of this invocation, and `resume` is the continuation.

7. **Advance** by re-reading `planner_position_derive`, and read its result exactly:

   ```bash
   NEXT_PHASE=$(planner_position_derive "$INITIATIVE_ID")
   ```

   - **Any phase name — including the literal `Completed`** — means that phase has
     not run yet. Loop back to step 1 with `PHASE=$NEXT_PHASE`.
   - **The empty string is the only value that means the initiative is finished.**

   `Completed` is the terminal *phase* (10 of 10), not a terminal *state*: it writes
   `artifacts/COMPLETED.md` and the final state log entry, and it is dispatched in
   this same invocation — immediately after Ticket Gen's dispatch-gate write, never
   left for the operator to remember to `resume` into (#226). Nothing gates it:
   Completed writes only to disk, so `planner_create_gate_check` waves it through,
   and step 6 has already stopped the loop first if `--until TicketGen` asked it to.
   Use the predicate rather than comparing the string by hand:

   ```bash
   if planner_terminal_pending "$INITIATIVE_ID"; then
     : # dispatch Completed now — do NOT report the run as finished
   fi
   ```

   Ticket Gen's dispatch-gate write is the part operators watch, because it is the
   part that puts tickets in Linear. A run that stops there looks done from Linear
   while the operator's primary summary document was never written — that is exactly
   how two live initiatives ended up needing their `COMPLETED.md` written by hand.

### 8. After completion

When the dispatch loop finishes (`planner_position_derive` returns empty):

1. **Verify the terminal phase actually produced its artifacts** before reporting
   anything. This is the only check anywhere in the pipeline that looks for
   `COMPLETED.md` specifically:

   ```bash
   if ! planner_completion_verify "$INITIATIVE_ID"; then
     # Phases are idempotent — re-dispatch Completed once, then re-verify.
     ...spawn the Completed agent (steps 2-4 above with PHASE=Completed)...
     if ! planner_completion_verify "$INITIATIVE_ID"; then
       echo "ERROR: the Completed phase did not write its summary — the initiative is NOT finished." >&2
       exit 1
     fi
   fi
   ```

   Do not report the run as complete while this fails. `planner_completion_verify`
   names what is missing on stderr: no terminal state log entry means the phase never
   ran, a `done` entry with no file means it half-ran.
2. Read the completion summary from `${STATE_DIR}/artifacts/COMPLETED.md`.
3. Report to the user:
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
