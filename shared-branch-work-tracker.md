# Shared epic branches — work tracker

Progress tracker for the four-phase shared-branch programme. **This file is the driver.** The authoritative
task detail lives in `openspec/changes/<change>/tasks.md`; this file records position and order.

Plan index: `~/.claude/plans/at-the-moment-each-sparkling-dolphin.md`

---

## Resume protocol

When the user says **"continue to next"** (or similar), do exactly this:

1. Read this file. Find the **first unit whose status is not `done`** in the Work queue below, scanning top to
   bottom. That is the unit to work on.
2. Open `openspec/changes/<change>/tasks.md` and read that unit's numbered section in full.
3. Mark the unit `wip` here, with today's date in Started.
4. Implement every `- [ ]` item in that section, ticking each to `- [x]` in `tasks.md` as it completes.
5. Run the phase's relevant checks. At minimum `make lint && make fmt-check && make test` before any commit.
6. Mark the unit `done` here, fill in Finished, and add a one-line note (what landed, or what was deferred and
   why).
7. Report what was done and what the next unit is. **Stop there** — do not roll into the next unit unasked.

**Rules**
- Never skip ahead. Dependencies between phases are real; §Dependencies below states them.
- A unit that turns out to be blocked gets status `blocked` with the reason, and the scan moves to the next
  unit **within the same phase only**. Never start a later phase to route around a block.
- If a unit is partially done, leave it `wip` with a note naming the exact remaining task numbers.
- Verification units (the last unit of each phase) include the version bump. Do not skip them.

---

## Status legend

| Status | Meaning |
|---|---|
| `todo` | Not started |
| `wip` | In progress — see Note for where it stands |
| `blocked` | Cannot proceed — Note states why |
| `done` | All tasks ticked in `tasks.md`, checks green |

---

## Dependencies

```
Phase 1  shared-branch-resolution   ← no dependencies, ships zero behavior change
   ├──→ Phase 2  ticket-worktree-isolation
   │        └──→ Phase 3  epic-branch-lifecycle  (also needs Phase 1)
   └──→ Phase 4  planner-branch-directive
```

Phase 4 depends only on Phase 1 and could run in parallel with 2–3, but the queue below keeps it last so the
producing side is built against a proven consuming side.

---

## Progress

| Phase | Change | Units | Tasks | Done |
|---|---|---:|---:|---:|
| 1 | `shared-branch-resolution` | 12 | 60 | 0 |
| 2 | `ticket-worktree-isolation` | 11 | 55 | 0 |
| 3 | `epic-branch-lifecycle` | 9 | 58 | 0 |
| 4 | `planner-branch-directive` | 10 | 56 | 0 |
| | **Total** | **42** | **229** | **0** |

---

## Work queue

### Phase 1 — `shared-branch-resolution`

Makes branch selection deterministic; adds the `## Branch Directive` block and the `--branch` override.
Ships **no behavior change** for tickets without a directive.

| # | Unit | Tasks | Status | Started | Finished | Note |
|---|---|---:|---|---|---|---|
| 1.1 | Shared markdown section extractor | 3 | todo | | | Behavior-neutral refactor — existing suites must pass byte-identically |
| 1.2 | `docs/branch-directive-schema.md` (new) | 4 | todo | | | |
| 1.3 | `lib/branch-directive-check.sh` (new) | 9 | todo | | | Includes the injection-case suite |
| 1.4 | `lib/linear-api.sh` — parent selection | 3 | todo | | | |
| 1.5 | `lib/branch-resolve.sh` (new) | 8 | todo | | | The single branch decision point |
| 1.6 | `lib/spawn-helper.sh` — env file transport | 4 | todo | | | |
| 1.7 | Pipeline log — `META\|branch-context` | 3 | todo | | | |
| 1.8 | `detect-resume.sh` — recover the decision | 5 | todo | | | |
| 1.9 | `skills/ticket-auto/SKILL.md` — router wiring | 5 | todo | | | |
| 1.10 | Remove branch prose from skill files | 6 | todo | | | Deletes `**BASE BRANCH:** Always develop` |
| 1.11 | Documentation | 4 | todo | | | |
| 1.12 | Verification | 6 | todo | | | Includes crash-resume test + version bump |

### Phase 2 — `ticket-worktree-isolation`

Fixes the shared-clone race. **Highest risk in the programme** — touches the repo-path assumption in five skill
files. Exercise on ordinary single-ticket runs before Phase 3 depends on it.

| # | Unit | Tasks | Status | Started | Finished | Note |
|---|---|---:|---|---|---|---|
| 2.1 | `lib/worktree.sh` (new) | 8 | todo | | | |
| 2.2 | `lib/tests/test-worktree.sh` (new) | 10 | todo | | | |
| 2.3 | `lib/spawn-helper.sh` — `WORKTREE_ROOT` transport | 3 | todo | | | |
| 2.4 | `ticket-implement` — create instead of checkout | 6 | todo | | | |
| 2.5 | `ticket-verify` — worktree-relative operations | 3 | todo | | | |
| 2.6 | `ticket-document` — worktree-relative diffs | 3 | todo | | | |
| 2.7 | `ticket-pr-review` and `ticket-pr-iterate` | 4 | todo | | | |
| 2.8 | Release wiring | 2 | todo | | | |
| 2.9 | Audit — no shared-clone git sites remain | 4 | todo | | | **Do not skip** — one missed site silently reintroduces the defect |
| 2.10 | Documentation | 5 | todo | | | |
| 2.11 | Verification | 7 | todo | | | Includes the two-concurrent-tickets test + version bump |

### Phase 3 — `epic-branch-lifecycle`

Creates, syncs, and integrates the epic branch. Writes to shared git history — dry-run coverage matters.

| # | Unit | Tasks | Status | Started | Finished | Note |
|---|---|---:|---|---|---|---|
| 3.1 | `lib/epic-branch.sh` (new) | 8 | todo | | | Sync refuses rather than force-pushes |
| 3.2 | `lib/tests/test-epic-branch.sh` (new) | 12 | todo | | | |
| 3.3 | `fleet-dispatch.sh` — branch precondition | 7 | todo | | | |
| 3.4 | `fleet-detect.sh` — 12th detector | 6 | todo | | | |
| 3.5 | Worktree GC wiring | 3 | todo | | | Closes the trigger left open by Phase 2 |
| 3.6 | Auto-merge guard | 3 | todo | | | Integration PR must never auto-merge |
| 3.7 | Configuration | 3 | todo | | | |
| 3.8 | Documentation | 6 | todo | | | |
| 3.9 | Verification | 10 | todo | | | Includes conflict-sync test + version bumps (two plugins) |

### Phase 4 — `planner-branch-directive`

Makes the planner produce directives instead of an operator hand-writing them.

| # | Unit | Tasks | Status | Started | Finished | Note |
|---|---|---:|---|---|---|---|
| 4.1 | `planner_branch_directive_recommend` | 6 | todo | | | Thresholds are provisional — document as such |
| 4.2 | `lib/branch-directive-gen.sh` (new) | 6 | todo | | | Generate against the validator, not the schema doc |
| 4.3 | Deterministic branch naming | 4 | todo | | | |
| 4.4 | `planner_prompt_epicgen` — append the directive | 6 | todo | | | |
| 4.5 | State log | 4 | todo | | | |
| 4.6 | Operator overrides | 4 | todo | | | |
| 4.7 | Tests | 7 | todo | | | Round-trip generator → validator |
| 4.8 | Cross-plugin dependency | 4 | todo | | | No bundled validator copy — anti-drift |
| 4.9 | Documentation | 6 | todo | | | |
| 4.10 | Verification | 9 | todo | | | Includes full end-to-end across all four phases + version bump |

---

## Cross-cutting conventions

Apply to every unit — do not re-derive these each time.

- `make lint && make fmt-check && make test` green before any commit or PR.
- Conventional commits (`type(scope): description`). **No `Co-Authored-By` trailer** — the auto-mode Content
  Integrity classifier rejects it.
- Each phase bumps affected plugin versions in **three** places: `plugin.json`, root `README.md`,
  `marketplace.json`.
- New tests need declare-guard stubs for `heartbeat.sh` / `linear-api.sh` — SessionStart hooks don't run in CI.
- Pipeline-log message fields contain no `|`; parse field 5+ with an awk join, never `cut -f5`.
- New `lib/` scripts: `mktemp` paired with `trap` cleanup; JSON via `jq -n --arg`, never string concatenation.

## Decision log

Decisions already settled. Reopen only with reason — do not re-litigate mid-implementation.

| Decision | Rationale |
|---|---|
| Integration branch + per-ticket sub-branches | Preserves per-ticket PR review; standard pattern for "several tickets, one deliverable" |
| Directive in the epic **body**, no marker label | Labels can't hold `/` and carry one string; a label plus a block is a drift surface with no arbiter |
| Directive **never** copied into child tickets | An epic edit would silently desync every child, undetectably; forces no schema bump |
| Malformed directive gate-stops, absent directive doesn't | A typo'd branch name must never silently merge epic work into the trunk |
| Real worktrees rather than serialising epics | Fixes a pre-existing race affecting all tickets, not just shared-branch ones |
| Sync policy is a required field | Long-lived branches rot: conflict probability ~10% at two days, >80% at two weeks |
| Sync refuses rather than force-pushes | In-flight worktrees are based on the published epic branch |
| Integration PR never auto-merged | A single reviewable unit is the whole point; guarded twice |
| Shared-branch decision is bash, not agent judgement | Merge topology must not depend on sampling variance |
| Planner heuristic is conservative and asymmetric | Under-recommending costs one flag; over-recommending silently changes merge topology |

## Session log

Append one line per working session — date, units touched, outcome.

<!-- e.g. 2026-07-26 — 1.1, 1.2 done. Extractor refactor byte-identical, both suites green. -->
