# ticket-auto Router Hardening — Findings & Incremental Plan

**Date:** 2026-07-04
**Status:** Planned (not started)
**Scope:** Full read-through of `skills/ticket-auto/SKILL.md` (the thin router) and
`skills/ticket-detect-resume/detect-resume.sh` (the routing brain), with every suspect
grep-verified against the phase skills that write the log lines the router consumes.
**Companion plan:** `pipeline-integrity-plan-2026-07-04.md` (false-done gate, CORRECTIONS,
prescan title). This plan is the router-side sibling — independent, can proceed in parallel.
**Excluded:** already-known sharp edges (pipeline-log `cut -f5` fragility, zombie steps,
dashboard dead zone, version sync) and everything the integrity plan already covers.

---

## Root pattern

Most findings are one disease: **the router's deterministic greps consume log lines whose
format is decided by LLM free text.** `spawn_agent_post` writes `done|${MSG}` where MSG is
whatever the router LLM typed (`spawn-helper.sh:394-401`); phase skills write their own
sub-step lines. Every place a grep couples to unspecified message wording is a latent
routing bug. Three of the four P0s below are instances.

---

## Findings catalog

Severity: **P0** silent feature death / wrong behavior on clean runs · **P1** routing &
counting integrity · **P2** hygiene.

### P0-R1 — Auto-merge has never fired (dead code)

`ticket-auto/SKILL.md:634-643`: auto-merge extracts `OUTCOME` from the implement terminal
line and tests `[ "$OUTCOME" = "Smooth" ]`. But implement's terminal line is
`|IMPLEMENT|implement|done|{N} files changed` (`ticket-implement/SKILL.md:306`) — it is
never `Smooth`. The Smooth/Rough/Hard outcome lives on the **Linear label**
(`outcome-label-check.sh`), not in that log line. `gh pr merge … || true` swallows any
residue. **Net: the auto-merge feature is dead code and always has been.**

Also suspicious: it fires only for `semi-auto`, not `auto` — full-auto mode never merges,
which inverts the modes' meaning. Needs a deliberate decision (see D-R1).

**Fix:** read the outcome from the authoritative source — have `outcome-label-check.sh`
emit a `META|outcome-label|info|Smooth` line when it confirms the label, and grep that.
Decide mode scope explicitly (recommend: `auto` AND `semi-auto`, simple+Smooth only).

### P0-R2 — Retro agent spawns on every clean run (tautological trigger)

`ticket-auto/SKILL.md:683`: retro condition 2 is `! grep 'META|outcome|info|completed:'` —
but the **only writer** of that line is Step 6 itself at `:700-701`, *after* the retro
check (grep-verified: no other writer in skills/ or lib/; CLAUDE.md 0.7.11 confirms outcome
is deliberately deferred to last). On every first pass, condition 2 is true → `NEEDS_RETRO`
→ a retro agent spawns on every run, including perfect ones. Silent token burn per ticket.

**Fix:** condition 2 must test positive success markers instead (VERIFY PASS + PR-review ✅
present), or compute outcome *before* the retro check and write it after. Keep conditions
1 (gate-stop) and 3 (hb fallback) as-is.

### P0-R3 — `implement-complete` transition silently skipped on plugin-cache installs

`ticket-auto/SKILL.md:571`: `flow_sh=$(find "$HOME/.claude/skills" …)` — no plugin-cache
fallback, unlike every other flow.sh resolution in the same file (`:79`, `:474` both fall
back to `~/.claude/plugins/cache`). Then `[ -n "$flow_sh" ] && bash … || true` swallows the
miss. On a plugin-cache-only install, the Ready→Review transition **silently never
happens** — Linear state drifts from pipeline state, and every downstream flow.sh
assertion inherits the skew.

**Fix:** same fallback resolution as `:474` + `hb_retry` on failure instead of `|| true`.

### P0-R4 — Whole-file done-dedup suppresses loop-phase log entries

`spawn-helper.sh:397`: the done-path idempotency guard greps the **entire log** for
`|PHASE|step|done|` and skips the write if any match exists. Correct for linear phases;
wrong for loop phases: in a PR iteration cycle (`pr-review` → iterate → `pr-review`), the
second review's `done|Verdict …` line is **never written** — the log forever shows the
first ⚠️ verdict. Consequences: `ITERATION` (counted from ⚠️ done lines,
`detect-resume.sh:271`) can't advance past 1, and crash-resume reads a stale verdict.
Same applies to re-verify after a verify-retry. Note `spawn_agent_pre`'s guard (`:224-231`)
is correctly **tail-scoped** — only the post-guard is whole-file.

**Fix:** tail-scope the done/fail dedup exactly like the pre-guard (compare last line
only). Add a loop-phase test: two full pr-review brackets must produce two done lines.

### P1-R5 — Terminal-MSG contracts are unspecified LLM free text

Two deterministic consumers depend on message wording nothing specifies:
- `detect-resume.sh:138` routes STEP_4_6 only on `|VERIFY|verify|done|PASS` (prefix
  match). But ticket-verify writes **no terminal line itself** (grep-verified — only
  sub-steps like `load-context`, `pre-flight`); the terminal line is `spawn_agent_post`'s
  free-text MSG. If the router types "✅ PASS" or "Verified", resume re-runs verify on
  passing code.
- `detect-resume.sh:271` counts ITERATION via `Verdict.*⚠️` — byte-exact emoji coupling
  (U+26A0 with/without U+FE0F variation selector breaks it).

**Fix:** canonical result tokens, written deterministically: give `spawn_agent_post` an
optional `VERDICT=` param (`PASS|FAIL|OK|WARN|BLOCK`) that it prepends to MSG itself —
`done|PASS — {free text}`. Greps match the token, never prose/emoji. Document the token
set in `pipeline-log-format.md` (additive; schema stays 1). This is the deterministic
router-side cousin of the integrity plan's return contract — and should land **before**
integrity Phase 1 wiring so both consume the same tokens.

### P1-R6 — `VERIFY_ATTEMPTS` overcounts (sub-step fails counted as attempts)

`detect-resume.sh:268` counts `|VERIFY|[^|]*|fail|` — *any* VERIFY-phase fail line. Verify
demonstrably writes sub-step fails: `|VERIFY|pre-flight|fail|No test user found`
(`ticket-verify/SKILL.md:212`). One attempt with a pre-flight hiccup = 2 counted attempts →
`VERIFY_EXHAUSTED` after 2 real attempts, or 1. The router's own inline loop check greps
terminal-only (`ticket-auto/SKILL.md:591`) — the two counters disagree today.

**Fix:** terminal-only pattern `|VERIFY|verify|fail|` in detect-resume (one-line change) +
a fixture test with a pre-flight fail proving the count stays 1.

### P1-R7 — `MAINTENANCE_FROM` contaminated by the prescan gate

The prescan gate writes `|MAINTENANCE|prescan|done|…` (`ticket-auto/SKILL.md:417`, plus the
spawn bracket). `detect-resume.sh:205-208` extracts `MAINTENANCE_FROM` from any
`|MAINTENANCE|*|done|` excluding only `maintenance` and `document` — so after any prescan,
`MAINTENANCE_FROM=prescan`, and STEP_5 spawns wiki-maintenance with `FROM_STEP=prescan`, a
step that doesn't exist in that skill.

**Fix:** add `grep -v '|MAINTENANCE|prescan|'` to the extraction (one line) + fixture test.

### P1-R8 — Crash-resume after a verify fail re-verifies unfixed code

`detect-resume.sh:140`: any `|VERIFY|verify|` line → STEP_4_5, and the router's STEP_4_5
entry action is "spawn verify." If the pipeline crashed *after* a terminal verify fail but
*before* the re-implement, resume re-runs verify against the same broken code — burning an
attempt (compounded by R6's overcount). The remediation loop then gets fewer real fix
rounds than designed.

**Fix:** in detect-resume, if the last terminal VERIFY event is `fail` with no later
`|IMPLEMENT|implement|done|`, emit a distinct resume hint (e.g. `VERIFY_LAST=fail`) and
have STEP_4_5 dispatch re-implement first. Depends on R5's deterministic tokens.

### P1-R9 — Prescan agent outcome judged by `spawn_capture`'s exit code

`ticket-auto/SKILL.md:412-414`: `spawn_capture …` then `if [ $? -eq 0 ]` — that tests
whether *spawn_capture* (a log write) succeeded, which it essentially always does, not
whether the prescan agent succeeded. Failed prescans are logged
`done|$slug prescan complete: … → fresh`. Non-blocking path, so impact is log integrity +
a false "fresh" claim until the next freshness gate run — but it's exactly the
false-done pattern the integrity plan exists to kill.

**Fix:** branch on the agent result content (e.g. grep the captured result for the skill's
completion marker), not on `$?` of the capture step.

### P2 — hygiene

- **R10** — `PR_FEEDBACK_CYCLE` has no cap: STEP_5_5 can cycle indefinitely on new human
  comments; every other loop caps at 3. Add a cap (3) or document unboundedness as intended.
- **R11** — the prescan gate runs even when resuming at ≥ STEP_4; prescan only benefits
  appraise. Skip it when `RESUME_STEP` ≥ STEP_4 — faster crash recovery.
- **R12** — `META|autonomy` is appended unguarded on every (re)start
  (`ticket-auto/SKILL.md:257`); last-wins means a resume with a different flag silently
  switches mode mid-pipeline, after gate decisions were made under the old mode. Add the
  same idempotency guard as the heartbeat inits, or log an explicit `mode-change` event.
- **R13** — tmux dashboard pane spawns unconditionally per run (`:246-248`); every resume
  adds another pane. Check for an existing dashboard first.
- **R14** — preflight team resolution: if the teams query fails, `team_count` is empty and
  the error misleadingly says "Multiple Linear teams — set LINEAR_TEAM_ID" (`:170-171`).
  Distinguish query failure from genuine multi-team.

---

## Incremental rollout

Ordered so each increment is small, independently testable, and shippable alone.
**Increment A is pure one-liner fixes in existing bash — start there.**

| Increment | Items | Character |
|---|---|---|
| **A — detect-resume one-liners** | R6, R7, R14 | grep-pattern fixes + fixture tests; zero behavior risk |
| **B — silent-skip & false-done fixes** | R3, R9, R2 | path fallback; result-content check; retro condition rewrite |
| **C — dedup scoping** | R4 | tail-scope the post-guard; loop-phase regression test (two brackets → two done lines) |
| **D — canonical verdict tokens** | R5, then R8 | `VERDICT=` param in `spawn_agent_post` + `pipeline-log-format.md` token table; then the verify-fail resume hint |
| **E — feature repair (needs decision D-R1)** | R1 | outcome-label log line + corrected mode scope |
| **F — hygiene batch** | R10–R13 | caps, guards, skip-on-late-resume, dashboard idempotency |

Per-increment definition of done: fix + fixture test in `lib/tests/` (mirror
`test-spawn-helper.sh` style, golden-log fixtures for detect-resume) + shfmt/shellcheck
clean + version bump per branch convention.

**Decision required (D-R1):** should full-`auto` mode auto-merge? Current code says
semi-auto only (and never works anyway, per R1). Recommendation: `auto` and `semi-auto`
both merge when simple+Smooth+PR ✅; `manual` never. Confirm before Increment E.

---

## Interaction with the integrity plan

- R5's canonical tokens should land **before** integrity Phase 1 gate wiring — the gate's
  log emissions and detect-resume's consumption should speak tokens, not prose, from day one.
- R4's tail-scoped dedup is a precondition for trustworthy retry accounting, which the
  integrity plan's `IMPLEMENT_RETRY` counter (its G2) will read from the log.
- R9 is the same false-done disease the integrity plan targets — fixing it here keeps the
  prescan path honest without waiting for the full return contract.

## Verification method note

Every P0/P1 finding was verified against the writing side, not just the reading side:
implement's terminal line (`ticket-implement/SKILL.md:306`), verify's sub-step-only writes
(`ticket-verify/SKILL.md:123-246`, no terminal line), checkout-pr's bare PR number
(`ticket-pr-review/SKILL.md:106` — this one is *correct*, cleared during review),
outcome's single writer (grep across skills/ + lib/), and `spawn_agent_post`'s free-text
MSG + whole-file dedup (`spawn-helper.sh:394-401`).
