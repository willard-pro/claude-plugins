# Ticket-Planner Plugin — Improvement Findings

Generated 2026-07-24 from a two-agent audit (structural gaps + overlap/misalignment analysis).
Full audit examined all 7 lib scripts, SKILL.md, CLAUDE.md, docs, and 4 test files.

**OpenSpec changes created for architectural items:**
- `ticket-planner-p0-hardening` — confidence pipeline fix, phase collapse, state log hardening

---

## P0 — Breaks pipeline or violates core principles

### P0-1: Confidence pipeline is architecturally broken

**Triple failure:**
1. `planner_confidence_derive` (deterministic bash, `planner-context-gen.sh:141-193`) exists but **no phase calls it**. OpenSpec has the LLM compute confidence "using the formula in planner-context-gen.sh" — an LLM cannot execute bash.
2. The 5 "concrete signals" (`services_identified`, `symbols_resolved`, `prior_art_found`, `complexity`, `exploration_depth`) are all assigned by LLM agents with zero bash cross-validation.
3. `planner-ticket-validate.sh:70-73` returns exit 0 (pass) when `planned-ticket-check.sh` is not found on the filesystem.

**Failure scenario:** Tickets with LLM-fabricated confidence scores of 0.92 get `pre-approved` label, bypass human review, and enter the pipeline based on unverified evidence.

**Fix:** → OpenSpec change `ticket-planner-p0-hardening`

---

### P0-2: No `tsort` timeout — unbounded hang risk

**Location:** `planner-deps-check.sh:46`
```bash
if echo "$pairs" | tsort >/dev/null 2>&1; then
```

POSIX specifies no upper bound on `tsort` runtime. A malformed dependency graph from a buggy LLM could hang the pipeline forever with no kill mechanism.

**Fix (single line):**
```bash
if echo "$pairs" | timeout 30 tsort >/dev/null 2>&1; then
```
Also: add a `PLANNER_TSORT_TIMEOUT` env var defaulting to 30, and detect timeout exit code 124 to produce a clear error message.

---

### P0-3: Input sanitization has trivial bypass

**Location:** `planner-phase-prompts.sh:42-61`

`planner_sanitize_input` uses `grep -qF` for fixed-string matching after lowercasing. `"ignore  previous  instructions"` (double space) bypasses the `"ignore previous instructions"` (single space) pattern. Unicode confusables, zero-width characters, RTL overrides — all unhandled.

**Fix (in `planner_sanitize_input`):**
1. Normalize whitespace: `tr -s '[:space:]' ' '` before matching
2. Strip zero-width characters: `sed 's/\xE2\x80\x8B//g'` etc.
3. Strip RTL override: `sed 's/\xE2\x80\x8F//g'`
4. Add test file: `lib/tests/test-planner-sanitize.sh`

---

### P0-4: Validator missing = all tickets pass (fail-open)

**Location:** `planner-ticket-validate.sh:70-73`
```bash
if [ ! -f "$checker" ]; then
    echo "planner-validate: planned-ticket-check.sh not found -- skipping validation" >&2
    return 0 # Degrade gracefully: allow creation without validation
fi
```

The comment says "degrade gracefully" — this is failing OPEN. A missing validator means the pipeline's most critical safety check is silently absent.

**Fix (single character change):**
```bash
    return 1 # Fail closed: missing validator is a hard stop
```
And add a distinct error code so the caller can distinguish "validator not found" from "validation failed."

---

### P0-5: Story Gen is acknowledged dead weight

**Location:** `planner-phase-prompts.sh:620-622`
```
Note: This phase may be collapsed into TicketGen if stories are always 1:1 with
tickets. For now, produce story descriptions for each ticket spec.
```

OpenSpec already writes ticket descriptions with acceptance criteria (line 475: "What needs to change and why"). StoryGen adds a user-story format template on top of existing content. 100% duplication, self-acknowledged.

**Fix:** → OpenSpec change `ticket-planner-p0-hardening`

---

## P1 — Degrades quality or creates fragility

### P1-6: Appraisal and Discovery both explore the codebase

**Where:** `planner-phase-prompts.sh:102-103` (Appraisal scans repos), `planner-phase-prompts.sh:161-163` (Discovery re-scans same repos)

Discovery accepts Appraisal's service list without instruction to correct it. If Appraisal misses a service, it stays missed.

**Fix:** Add to Discovery prompt: "If Appraisal identified services that don't exist or omitted clearly affected services, correct the list and note the changes in your report."

---

### P1-7: Proposal → OpenSpec → TicketGen = 3 passes over same ticket definitions

Proposal writes ticket list with descriptions. OpenSpec expands each to "the actual Linear ticket body." TicketGen reads and passes through to Linear API. 3 agents for a 2-phase pipeline.

**Fix:** → OpenSpec change `ticket-planner-p0-hardening` (merge Proposal+OpenSpec into single "Specify" phase)

---

### P1-8: Epic Gen and Execution both set `state:execution`

**Where:** `planner-phase-prompts.sh:592` (EpicGen sets it), `planner-phase-prompts.sh:789` (Execution re-verifies and re-sets it)

Execution is a no-op verification of EpicGen's work. The label is set twice on the same entity.

**Fix:** EpicGen should create the epic with `INIT-{id}` + `epic` labels only. Execution should be the sole phase that sets `state:execution` — making it a real gating step. Gives Execution a purpose beyond verification.

---

### P1-9: Consensus rewrites proposal without re-review

**Where:** `planner-phase-prompts.sh:386-440`, acknowledged in `docs/ticket-planner.md:309`

Consensus can substantively rewrite the proposal to resolve blocker findings. Those changes go directly to OpenSpec with no re-review.

**Fix:** Add to Consensus prompt: "If you substantially rewrite the proposal (modify > 2 tickets in work breakdown, change strategy, or change scope), mark the consensus digest with `re-review-recommended: true`." In the router, add a check: if consensus digest has this flag and the proposal changed beyond a threshold, loop back to Review phase. Threshold check: `diff pre-consensus-proposal post-consensus-proposal | wc -l`.

---

### P1-10: Phase sequence hardcoded in two independent arrays

**Where:** `planner-state.sh:168-171` and `planner-state.sh:255-258`

Two identical arrays. Updating one but not the other → position derivation and transition validation disagree → mysterious "illegal transition" errors.

**Fix:** Extract to a single function:
```bash
planner_phase_sequence() {
  echo "Appraisal Discovery Architecture Proposal Review Consensus OpenSpec EpicGen StoryGen TicketGen Execution Completed"
}
```
Both `planner_position_derive` and `planner_phase_validate_transition` call this function and split into array. Single source of truth.

---

### P1-11: Epic ID propagation has no deterministic path

**Where:** `planner-phase-prompts.sh` — EpicGen writes epic ID to prompt output; TicketGen runs in fresh agent

TicketGen's prompt references `${EPIC_ID}` as a bash variable — it won't exist in a fresh agent spawn. The agent must re-derive the epic ID from intent files by LLM reasoning.

**Fix:** EpicGen should write `EPIC_ID=CRE-100` to the state log: `planner_state_write "$initiative_id" "EpicGen" "create" "done" "EPIC_ID=CRE-100"`. TicketGen reads it deterministically:
```bash
epic_id=$(grep '|EpicGen|.*|done|EPIC_ID=' "${state_dir}/state.log" | tail -1 | sed 's/.*EPIC_ID=//')
```

---

### P1-12: Agent prompts assume `${CLAUDE_PLUGIN_ROOT}` is set

**Where:** Every phase prompt contains `source "${CLAUDE_PLUGIN_ROOT}/lib/planner-state.sh"`

If unset, source fails silently → agent runs without state-log helpers → phase completes without writing `done`/`fail` → router retries until `PLANNER_MAX_PHASE_RETRIES` exhausted.

**Fix:** In the SKILL.md dispatch loop, before spawning the agent, export `CLAUDE_PLUGIN_ROOT` explicitly. Add a fallback in the prompt:
```bash
if [ -z "${CLAUDE_PLUGIN_ROOT}" ]; then
  CLAUDE_PLUGIN_ROOT="${HOME}/.claude/plugins/cache/ticket-planner/current"
fi
```

---

### P1-13: OpenSpec computes derived values that should be bash

**Where:** `planner-phase-prompts.sh:479-499` — OpenSpec JSON block includes Confidence, Pre-approved, Regenerate

Confidence (derived from signals), Pre-approved (confidence >= 0.85), and Regenerate (boolean) are all computed by the LLM. These are derived values, not content — should be bash-computed.

**Fix:** OpenSpec emits raw signal values only. Bash computes Confidence and Pre-approved in TicketGen (or a pre-TicketGen validation step). → Part of OpenSpec change `ticket-planner-p0-hardening`.

---

### P1-14: State log writes are not atomic

**Where:** `planner-state.sh:127`
```bash
printf '%s|%s|%s|%s|%s\n' "$iso" "$phase" "$step" "$status" "$message" >>"$log_file"
```

Append (`>>`) — concurrent writes from router + agent can interleave at byte level. Partial lines corrupt position derivation on resume.

**Fix:** Write to `.tmp` file then `mv`:
```bash
local tmp="${log_file}.tmp.$$"
cp "$log_file" "$tmp" 2>/dev/null || true
printf '%s|%s|%s|%s|%s\n' "$iso" "$phase" "$step" "$status" "$message" >>"$tmp"
mv "$tmp" "$log_file"
```
Note: this is still not fully atomic under concurrent writers. For true atomicity, use `flock`:
```bash
exec 200>"${log_file}.lock"
flock -x 200
printf ... >> "$log_file"
flock -u 200
```

---

### P1-15: No Linear API retry at bash level

**Where:** Phase agents call Linear API directly with no retry wrapper

A transient 429/503 counts against `PLANNER_MAX_PHASE_RETRIES` (default 2). After 2 API blips, the entire initiative is abandoned.

**Fix:** Create `lib/planner-linear-api.sh` wrapping `curl` with retry (3 attempts, exponential backoff: 1s, 2s, 4s). Pattern copied from ticket-auto's `lib/linear-api.sh`. All phase prompts reference this wrapper instead of calling Linear API directly.

---

### P1-16: No agent timeout

**Where:** SKILL.md dispatch loop — no timeout on agent spawns

A hung Discovery agent consumes tokens indefinitely with no kill mechanism.

**Fix:** Add `PLANNER_PHASE_TIMEOUT` env var (default 600s = 10 min). Pass timeout to agent spawn. If the phase exceeds timeout, write `fail` to state log with reason `timeout` and advance to retry logic.

---

### P1-17: Idea containing pipe characters corrupts state log

**Where:** `planner-state.sh:132-151` — `planner_state_init` writes the idea directly to the pipe-delimited log

**Fix:** Sanitize the idea before writing to the log:
```bash
local safe_idea
safe_idea=$(echo "$idea" | tr '|' ' ' | tr '\n' ' ')
planner_state_write "$initiative_id" "META" "idea" "start" "$safe_idea"
```

---

### P1-18: No corrupted state log recovery

**Where:** `planner-state.sh:106-113` — `planner_state_read` just cats the file

A line with a garbled phase field silently falls through position derivation to `Appraisal` (restart from scratch).

**Fix:** Add `planner_state_repair` function that:
1. Reads the log
2. Validates each line against the pipe-delimited format
3. Validates each phase field against known phases
4. Removes trailing malformed lines (crash mid-write)
5. Writes repaired version via atomic mv

---

### P1-19: No bash validation gate between OpenSpec and Epic Gen

**Where:** Between phases 7 and 8 — no deterministic check

This is the last checkpoint before irreversible Linear API calls. No bash validation that spec files have all required fields.

**Fix:** Create `lib/planner-spec-validate.sh` with a function that iterates `${state_dir}/artifacts/specs/*.md`, checks each for required sections (Title, Description, Planner Context fields, Labels), and returns 0 only if all pass. Call after OpenSpec completes, before dispatching EpicGen. → Part of OpenSpec change `ticket-planner-p0-hardening`.

---

### P1-20: No post-Ticket Gen entity verification

**Where:** Between phases 10 and 11

No bash check that created tickets actually exist in Linear with correct labels and valid `blocked-by` targets.

**Fix:** Create `planner_verify_tickets` function that:
1. Reads intent files for all created ticket IDs
2. Fetches each from Linear API
3. Asserts `planned` label present, `INIT-{id}` label present, `Type` label present
4. Asserts all `blocked-by:{ID}` targets resolve to valid ticket IDs
5. Reports mismatches without mutating

---

### P1-21: No integration or E2E tests

**Where:** All 4 test files under `lib/tests/` are unit tests

No test spans multiple phases or a complete `plan → crash → resume → complete` cycle.

**Fix:** Create `lib/tests/test-planner-integration.sh`:
1. `test_full_plan_run` — simulate complete 12-phase run with mock agents
2. `test_crash_resume` — simulate crash mid-OpenSpec, verify resume correctness
3. `test_idempotent_entity_creation` — create epic twice, assert only one Linear entity
4. `test_cycle_detection_rejects_all` — cyclic dependency graph → zero tickets created

---

### P1-22: Input sanitizer has zero test coverage

**Where:** `planner-phase-prompts.sh:30-65` — untested

**Fix:** Create `lib/tests/test-planner-sanitize.sh` with cases:
- Normal input passes through
- "ignore previous instructions" → blocked
- "ignore  previous  instructions" (double space) → blocked after whitespace normalization
- "IGNoRe PrEvIoUs InStRuCtIoNs" (mixed case) → blocked after lowercasing
- Unicode homoglyphs of blocked patterns
- Very long input (10K chars)
- Empty input, null bytes, control characters

---

## P2 — Missing polish, nice-to-have

### P2-23: Missing operational modes
Only `plan`/`resume`/`status`/`replan` exist. Add: `pause` (write META|pause to log), `skip-phase <phase>` (write skip to log), `force-phase <phase>` (re-run completed phase), `validate` (dry-run to OpenSpec, stop before API calls), `cancel` (terminal META|cancel entry).

### P2-24: `PLANNER_CONFIDENCE_THRESHOLD` documented but unimplemented
Appears in `docs/ticket-planner.md:277` default 0.5. Never referenced in code. Either implement it (pass to `planner_confidence_derive` for threshold gating) or remove from docs.

### P2-25: Initiative ID collision risk
`INIT-$(date +%s)` — two `plan` commands in same second collide. Fix: append random component: `INIT-$(date +%s)-$(shuf -i 1000-9999 -n 1)`.

### P2-26: No `REPOS_ROOT` validation
Trusts env var without checking it points to a real directory. Fix: validate in `planner_initiative_dir`: check `$REPOS_ROOT` exists and `$REPOS_ROOT/.ticket-auto/initiatives` is creatable.

### P2-27: No phase concurrency lock
`resume` while agent is still running spawns a second agent. Fix: create `${state_dir}/.lock` at phase start, remove at phase end, `planner_resume` refuses if lock exists.

### P2-28: No heartbeat during long phases
Only `start`/`done` per phase. Operator can't distinguish "agent is exploring" from "agent is hung." Fix: agents write periodic `progress` entries (every N files explored or every M minutes).

### P2-29: No feedback JSON size limit
`planner-replan.sh:129-146` concatenates ALL feedback files. After 50+ tickets, memory exhaustion. Fix: `PLANNER_FEEDBACK_MAX_FILES` (default 50) and per-file size cap.

### P2-30: No feedback JSON schema validation
Validates parseability but not required fields. Wrong field names silently produce zero drift. Fix: validate against known schema in `planner_feedback_read_all`.

### P2-31: Resume loses partial agent output
OpenSpec writes 8/10 specs, crashes. Re-run overwrites all 10. Fix: agent checks for existing output files before writing (`if [ -f "$spec_file" ]; then skip; fi`).

### P2-32: "Autonomous" claim ambiguous
Description says "fully autonomous" but hold phases and approval gate exist. Fix: clarify as "autonomous 12-phase planning pipeline" in SKILL.md description.

### P2-33: "Zero special-casing" claim misleading
`planned` label triggers special-casing in ticket-auto's fast-path. Fix: rephrase to "consumes via frozen contracts with zero new code in ticket-auto."

### P2-34: Appraisal strategy constrains Architecture without override path
Architecture isn't told it can override Appraisal's strategy recommendation. Fix: add to Architecture prompt: "Evaluate whether Appraisal's recommended strategy is still appropriate given Discovery findings. If not, override it and explain why."

### P2-35: No per-phase token/memory budget tracking
No metrics on cost drivers. Fix: emit `META|metrics` entries with token usage per phase after each agent completes.

### P2-36: Agent exit code not captured
Router checks state log for `done`/`fail` but not agent exit code. Fix: capture exit code AND check state log, requiring both to indicate success.

### P2-37: No confidence derivation boundary tests
Only happy-path values tested. Add tests for: null/0/negative values, values exceeding bonus caps, non-numeric inputs. In `lib/tests/test-planner-state.sh` or new test file.

### P2-38: No large dependency graph tests
Only 2-4 node graphs. Add tests for: 50-node DAG, self-loops, duplicate edges, disconnected components. In `lib/tests/test-planner-generation.sh`.

### P2-39: No concurrent state log access tests
No test verifies position derivation behavior after interleaved writes. Add test with two writers appending simultaneously.

### P2-40: No ID validation edge case tests
Missing: 1000+ char IDs, embedded `` ` `` `$` `"`, control characters. Add to `lib/tests/test-planner-state.sh`.

### P2-41: No post-Completion handoff verification
Planner completes but `FLEET_AUTO_DISPATCH` is false. Initiative sits idle. Fix: Completed phase emits warning if `FLEET_AUTO_DISPATCH != true`.

### P2-42: No dry-run mode
Cannot preview planner output without creating real Linear entities. Fix: `--dry-run` flag stops pipeline after OpenSpec (specs written, no API calls).

### P2-43: Idea length unbounded
50K-word idea bloats state log and every prompt. Fix: `PLANNER_IDEA_MAX_LENGTH` (default 2000 chars), truncate with warning.

### P2-44: State init only checks file existence, not schema line
Empty log file → init returns early → log in broken state. Fix: check for schema declaration line, not just file existence.

### P2-45: No duplicate phase entry detection
`planner_state_write` always appends. Second `done` for same phase undetected. Fix: reject `done` for a phase that already has `done` (except `fail`→`done` retry pattern).

### P2-46: Intent files not written atomically
`jq -c '...' > "$intent_file"` can leave partial JSON on crash. Fix: write to `.tmp`, then `mv`.

### P2-47: Affected Services not validated against actual repos
Phantom service names propagate through. Fix: Discovery produces validated list by checking `${REPOS_ROOT}` directory listing.

---

## Cross-Cutting Themes

1. **Confidence is the highest-leverage fix.** Three interacting failures (unused bash derivation, unverified LLM inputs, validator fail-open) undermine the planner's core architectural feature. Fixing this closes 4 P0s in one change.

2. **Three phases are candidates for collapse.** Story Gen (self-acknowledged dead weight), OpenSpec (overlaps Proposal + TicketGen), and Execution (overlaps Epic Gen). A 9-phase pipeline would eliminate all identified overlaps.

3. **The state log needs hardening.** Pipe sanitization, atomic writes, corrupted-line recovery, duplicate-entry detection, and a concurrency lock — 6 small independent bash fixes that collectively close the most fragile subsystem.

4. **The single-skill architecture is fine.** Unlike ticket-auto's 20+ skills (needed because each phase is an independent entry point), the planner's linear batch pipeline justifies one SKILL.md with 4 modes. No redesign needed.

5. **Test coverage is early-project thin but focused.** 4 test files cover the right things for unit tests. Missing: integration tests, sanitization tests, and edge-case coverage for confidence/dependency functions.

## Recommended Fix Order

| Order | Item | Effort | Impact |
|-------|------|--------|--------|
| 1 | OpenSpec: `ticket-planner-p0-hardening` (confidence + phases + state log) | Large | Closes 5 P0, 5 P1 |
| 2 | tsort timeout (P0-2) | 1 line | Prevents hang |
| 3 | Sanitizer hardening (P0-3) | 1 function | Security |
| 4 | Validator fail-closed (P0-4) | 1 line | Safety |
| 5 | Phase sequence DRY (P1-10) | Extract function | Prevents drift bugs |
| 6 | Epic ID deterministic path (P1-11) | State log grep | Reliability |
| 7 | CLAUDE_PLUGIN_ROOT export (P1-12) | Env var | Reliability |
| 8 | Pipe sanitization in idea (P1-17) | tr filter | Data integrity |
| 9 | Linear API retry wrapper (P1-15) | New lib file | Resilience |
| 10 | Agent timeout (P1-16) | Config + router | Cost control |
| 11 | Post-Ticket Gen verification (P1-20) | New function | Correctness |
| 12 | E2E tests (P1-21) | New test file | Regression safety |
| 13 | All P2 items | Various | Polish |

## Associated OpenSpec Changes

| Change | Covers |
|--------|--------|
| `ticket-planner-p0-hardening` | P0-1 (confidence), P0-5 (Story Gen collapse), P1-7 (Proposal/OpenSpec merge), P1-8 (EpicGen/Execution merge), P1-13 (derived values to bash), P1-14 (atomic state log), P1-18 (log repair), P1-19 (spec validation gate) |
