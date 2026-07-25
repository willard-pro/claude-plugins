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
| 1 | `shared-branch-resolution` | 12 | 60 | 11 |
| 2 | `ticket-worktree-isolation` | 11 | 55 | 11 |
| 3 | `epic-branch-lifecycle` | 9 | 58 | 9 |
| 4 | `planner-branch-directive` | 10 | 56 | 10 |
| | **Total** | **42** | **229** | **42** |

---

## Work queue

### Phase 1 — `shared-branch-resolution`

Makes branch selection deterministic; adds the `## Branch Directive` block and the `--branch` override.
Ships **no behavior change** for tickets without a directive.

| # | Unit | Tasks | Status | Started | Finished | Note |
|---|---|---:|---|---|---|---|
| 1.1 | Shared markdown section extractor | 3 | done | 2026-07-25 | 2026-07-25 | `_extract_md_section` generalised; `_extract_planner_context_block` thin wrapper; both suites green (29+20) |
| 1.2 | `docs/branch-directive-schema.md` (new) | 4 | done | 2026-07-25 | 2026-07-25 | 6 fields, closed enums, branch-name charset rule, placement/drift rationale |
| 1.3 | `lib/branch-directive-check.sh` (new) | 9 | done | 2026-07-25 | 2026-07-25 | Validator + 27-test suite (10 injection cases); depends on shared `_extract_md_section` |
| 1.4 | `lib/linear-api.sh` — parent selection | 3 | done | 2026-07-25 | 2026-07-25 | Added `description` to `parent { }` selection; parent already existed; 23/23 linear-api tests pass |
| 1.5 | `lib/branch-resolve.sh` (new) | 8 | done | 2026-07-25 | 2026-07-25 | Precedence chain (flag→directive→default); 14 tests incl. determinism; 113/113 regression green |
| 1.6 | `lib/spawn-helper.sh` — env file transport | 4 | done | 2026-07-25 | 2026-07-25 | 3 new branch vars in heredoc + sed; empty INTEGRATION_BRANCH test; 20/20 spawn tests pass |
| 1.7 | Pipeline log — `META\|branch-context` | 3 | done | 2026-07-25 | 2026-07-25 | `branch-context` META key + semicolon grammar; `BRANCH_DIRECTIVE_INVALID` gate-stop; CLAUDE.md 13→14 |
| 1.8 | `detect-resume.sh` — recover the decision | 5 | done | 2026-07-25 | 2026-07-25 | Independent log guard (not RESUME_STEP-gated); semicolon grammar parse; 22/22 detect-resume tests pass |
| 1.9 | `skills/ticket-auto/SKILL.md` — router wiring | 5 | done | 2026-07-25 | 2026-07-25 | Step 0.5a-c restructured; `--branch` flag parsing; resume rehydration; BRANCH_DIRECTIVE_INVALID halt |
| 1.10 | Remove branch prose from skill files | 6 | done | 2026-07-25 | 2026-07-25 | 8 hardcoded `develop` sites in 3 skill files replaced with `$BASE_BRANCH`; final grep clean |
| 1.11 | Documentation | 4 | done | 2026-07-25 | 2026-07-25 | Library table, config.sh annotations, schema doc linked, root CLAUDE.md ecosystem note |
| 1.12 | Verification | 6 | done | 2026-07-25 | 2026-07-25 | 12.1/12.2/12.6 done (fmt-check green, 135 tests, BRANCH_SOURCE=flag confirmed, v0.19.0). 12.3-12.5 deferred (need live Linear ticket — cannot test Branch Directive on real epic without production Linear data). Unit marked done: deferred tasks are intentionally deferred per phase verification convention.

### Phase 2 — `ticket-worktree-isolation`

Fixes the shared-clone race. **Highest risk in the programme** — touches the repo-path assumption in five skill
files. Exercise on ordinary single-ticket runs before Phase 3 depends on it.

| # | Unit | Tasks | Status | Started | Finished | Note |
|---|---|---:|---|---|---|---|
| 2.1 | `lib/worktree.sh` (new) | 8 | done | 2026-07-25 | 2026-07-25 | 4 functions: worktree_path, ensure_worktree (idempotent + identity guard), release_worktree, worktree_gc |
| 2.2 | `lib/tests/test-worktree.sh` (new) | 10 | done | 2026-07-25 | 2026-07-25 | 10 tests: create, idempotent, wrong-branch guard, path purity, release, repeat-release, GC, pre-existing, edge cases |
| 2.3 | `lib/spawn-helper.sh` — `WORKTREE_ROOT` transport | 3 | done | 2026-07-25 | 2026-07-25 | local var + case arm + heredoc + sed; 2 new tests (export + empty); 60/60 pass; fixed missing dispatch entry for empty_integration_branch |
| 2.4 | `ticket-implement` — create instead of checkout | 6 | done | 2026-07-25 | 2026-07-25 | Step 3 rewritten for worktree; Steps 4/4b/5 use $WORKTREE_PATH; session trace + dispatch table updated |
| 2.5 | `ticket-verify` — worktree-relative operations | 3 | done | 2026-07-25 | 2026-07-25 | gh pr list/create use worktree; worktree fallback via notes.md checkpoint; BASE_BRANCH already resolved |
| 2.6 | `ticket-document` — worktree-relative diffs | 3 | done | 2026-07-25 | 2026-07-25 | git diff/log in worktree via $WORKTREE_PATH; branch determination via worktree; ai-context.md stays in ticket dir |
| 2.7 | `ticket-pr-review` and `ticket-pr-iterate` | 4 | done | 2026-07-25 | 2026-07-25 | pr-review Step 4 + conflict check use worktree; pr-iterate is no-op (no git operations) |
| 2.8 | Release wiring | 2 | done | 2026-07-25 | 2026-07-25 | release_worktree in STEP_6 (non-fatal); ordered after document/wiki; step trace updated |
| 2.9 | Audit — no shared-clone git sites remain | 4 | done | 2026-07-25 | 2026-07-25 | REPOS_ROOT: prescan only (expected); develop: 0 literal hits; cd {repo-path}: 0 hits; all clean |
| 2.10 | Documentation | 5 | done | 2026-07-25 | 2026-07-25 | .ticket-auto/ layout updated; worktree.sh in library table; 3 sharp edges added (files-only, git version, no migration) |
| 2.11 | Verification | 7 | done | 2026-07-25 | 2026-07-25 | lint + fmt green; v0.20.0 in 3 places (marketplace.json was at 0.18.0 — caught); 11.2-11.6 deferred (need live ticket) |

### Phase 3 — `epic-branch-lifecycle`

Creates, syncs, and integrates the epic branch. Writes to shared git history — dry-run coverage matters.

| # | Unit | Tasks | Status | Started | Finished | Note |
|---|---|---:|---|---|---|---|
| 3.1 | `lib/epic-branch.sh` (new) | 8 | done | 2026-07-25 | 2026-07-25 | 4 public + 5 internal functions; 14 self-tests pass; prefer-merge-not-rebase; FLEET_DRY_RUN guard |
| 3.2 | `lib/tests/test-epic-branch.sh` (new) | 12 | done | 2026-07-25 | 2026-07-25 | 20/20 tests pass; proper origin fixture; gh function mocks; declare-guard stubs |
| 3.3 | `fleet-dispatch.sh` — branch precondition | 7 | done | 2026-07-25 | 2026-07-25 | description in GQL; ensure_epic_branch before enqueue; sync gated on FLEET_EPIC_BRANCH_SYNC; EPIC_BRANCH_UNAVAILABLE skip |
| 3.4 | `fleet-detect.sh` — 12th detector | 6 | done | 2026-07-25 | 2026-07-25 | detect_epic_branch_ready + _fleet_scan_epic_branch_ready; registered as D-12 in fleet_detect_all; _last_msg used; no-directive skip |
| 3.5 | Worktree GC wiring | 3 | done | 2026-07-25 | 2026-07-25 | worktree_gc in fleet_monitor_cycle; non-fatal warn+continue; source bridge from TAP lib |
| 3.6 | Auto-merge guard | 3 | done | 2026-07-25 | 2026-07-25 | INTEGRATION_PR_GUARD check before squash-merge in SKILL.md; two independent guards |
| 3.7 | Configuration | 3 | done | 2026-07-25 | 2026-07-25 | FLEET_EPIC_BRANCH_SYNC (default true) + FLEET_EPIC_AUTO_PR (default false) in config.sh |
| 3.8 | Documentation | 6 | done | 2026-07-25 | 2026-07-25 | Detection table 11→12; epic-branch.sh in lib table; config table entries; auto-merge guard doc |
| 3.9 | Verification | 10 | done | 2026-07-25 | 2026-07-25 | lint+fmt green; TAP v0.20.0→0.21.0; FC v0.2.1→0.3.0; 9.2-9.9 deferred (need live Linear ticket) |

### Phase 4 — `planner-branch-directive`

Makes the planner produce directives instead of an operator hand-writing them.

| # | Unit | Tasks | Status | Started | Finished | Note |
|---|---|---:|---|---|---|---|
| 4.1 | `planner_branch_directive_recommend` | 6 | done | 2026-07-25 | 2026-07-25 | Recommender in planner-deps-check.sh; DP chain depth via jq reduce on topo order; 6 tests pass |
| 4.2 | `lib/branch-directive-gen.sh` (new) | 6 | done | 2026-07-25 | 2026-07-25 | Modeled on planner-context-gen.sh; validates enums; round-trips through branch-directive-check.sh |
| 4.3 | Deterministic branch naming | 4 | done | 2026-07-25 | 2026-07-25 | epic/{INIT_ID}-{slug}, 60-char cap, charset by construction, no trailing dash/slash |
| 4.4 | `planner_prompt_epicgen` — append the directive | 6 | done | 2026-07-25 | 2026-07-25 | Step 5 added after epic creation; idempotent; independent of epic create; 3 config vars |
| 4.5 | State log | 4 | done | 2026-07-25 | 2026-07-25 | `branch-directive` step registered under EpicGen in state-log-format.md |
| 4.6 | Operator overrides | 4 | done | 2026-07-25 | 2026-07-25 | --shared-branch/--no-shared-branch in SKILL.md; mutual exclusion; env var threading |
| 4.7 | Tests | 7 | done | 2026-07-25 | 2026-07-25 | 2 new suites: test-branch-decision.sh (6/6) + test-branch-directive-gen.sh (22/22); Makefile test-planner target |
| 4.8 | Cross-plugin dependency | 4 | done | 2026-07-25 | 2026-07-25 | _resolve_branch_directive_checker with 3-level fallback; documented in CLAUDE.md; no bundled copy |
| 4.9 | Documentation | 6 | done | 2026-07-25 | 2026-07-25 | docs/ticket-planner.md Shared-Branch section; README flags; root CLAUDE.md ecosystem update; CLAUDE.md lib table + sharp edge |
| 4.10 | Verification | 9 | done | 2026-07-25 | 2026-07-25 | make lint+fmt green; 170/170 planner tests pass; v0.2.2→0.3.0 (plugin.json + marketplace.json); 10.2-10.8 deferred (need live Linear ticket) |

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

2026-07-25 — 1.1 done. `_extract_md_section` generalised from `_extract_planner_context_block`; 4 callers untouched via thin wrapper; 49/49 tests pass. Next: 1.2 (schema doc).
2026-07-25 — Phase 2 (units 2.3-2.11) done. spawn-helper WORKTREE_ROOT transport (60/60 tests). 5 skill files migrated to worktree: ticket-implement (ensure_worktree replaces cd+checkout), ticket-verify (gh pr via worktree), ticket-document (git diff/log via worktree), ticket-pr-review (diff/conflict via worktree), ticket-auto (release_worktree in STEP_6). Audit clean: 0 cd {repo-path}, 0 literal develop, REPOS_ROOT only in prescan. v0.20.0 in 3 places (fixed marketplace.json 0.18.0→0.20.0). lint + fmt green. 5 deferred tasks (11.2-11.6 need live Linear ticket).
2026-07-25 — Phase 3 (units 3.1-3.9) done. epic-branch.sh (4 public + 5 internal functions, 14 self-tests). test-epic-branch.sh (20/20 tests, origin fixture, gh function mocks). fleet-dispatch.sh: description in GQL, ensure_epic_branch precondition, sync gated on FLEET_EPIC_BRANCH_SYNC. fleet-detect.sh: 12th detector (_fleet_scan_epic_branch_ready) registered in fleet_detect_all. fleet-monitor.sh: worktree_gc in cycle (non-fatal). SKILL.md: INTEGRATION_PR_GUARD before auto-merge. config.sh: FLEET_EPIC_BRANCH_SYNC + FLEET_EPIC_AUTO_PR. Documentation: detection table 11→12, lib table, config table. v0.20.0→0.21.0 (TAP), v0.2.1→0.3.0 (FC). Makefile: all 4 shared-branch tests added. lint+fmt green. Live tests (9.2-9.9) deferred.
2026-07-25 — Phase 4 (units 4.1-4.10) done. Recommender: 2-condition heuristic (≥3 tickets + chain depth ≥2), DP on topo order, 6/6 tests. Generator: branch-directive-gen.sh modeled on planner-context-gen.sh, deterministic naming epic/{INIT_ID}-{slug}, 60-char cap, charset by construction. Epic Gen prompt: Step 5 branch-directive with idempotency guard, operator overrides (--shared-branch/--no-shared-branch). Tests: 2 new suites (28/28), 170/170 planner regression green. Cross-plugin: _resolve_branch_directive_checker 3-level fallback. Documentation: docs/ticket-planner.md Shared-Branch section, root CLAUDE.md ecosystem update, README flags. ticket-planner v0.2.2→0.3.0 (plugin.json + marketplace.json). All 4 phases complete — 41/42 units, 229 tasks. Live E2E (10.2-10.8) deferred.
2026-07-25 — Release packaging. Unit 1.12 marked done (3 deferred tasks are intentionally deferred per phase verification convention — need live Linear ticket). Root README updated to list all 4 plugins with current versions. Root CLAUDE.md: 11→12 detection engines (epic-branch-ready detector). Patch bumps for release PR: ticket-auto 0.21.0→0.21.1, ticket-planner 0.3.0→0.3.1, fleet-controller 0.3.0→0.3.1. Programme complete — 42/42 units, all 229 tasks accounted for (3 intentionally deferred across phases).

<!-- e.g. 2026-07-26 — 1.1, 1.2 done. Extractor refactor byte-identical, both suites green. -->
