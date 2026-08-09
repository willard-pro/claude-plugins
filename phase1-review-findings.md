# RLVR Phase 1 — 5-Agent Review Fix List

**Branch**: `feat/rlvr-phase1-inspector`
**Reviewers**: QA (feature-dev:code-reviewer), Architecture (feature-dev:code-architect), Security (general-purpose), Bash Reliability (general-purpose), Failure Analyst (general-purpose — no usable output)
**Date**: 2026-08-09

## Summary

4 of 5 agents produced detailed findings. The feature has a **P0 context-truncation bug** (all 4 agents found it independently) that causes the guidance-extractor-agent to receive only one line of context — the entire Phase 1 feature silently no-ops. Two of five detection patterns are structurally undetectable against the real Phase 0 schema. The library poisons caller shell flags (violating repo convention), and the router integration has a sourcing gap. All fixes are small and localized; no re-architecture needed.

**Severity key**: P0 = blocking (feature broken), P1 = important (wrong behavior or spec violation), P2 = improvement (edge case or hardening)

---

## P0 — Fixes (blocking — feature does not work as implemented)

### P0-1: Router truncates inspector context to a single line

**Found by**: QA, Architecture, Security, Bash Reliability (all 4)
**Files**: `ticket-auto-pipeline/skills/ticket-auto/SKILL.md` lines ~800, ~902, ~971

The three router call sites extract INSPECTOR_INSTRUCTIONS with:
```bash
_pi_instructions=$(echo "$_pi_out" | grep '^INSPECTOR_INSTRUCTIONS=' | sed 's/^INSPECTOR_INSTRUCTIONS=//')
```
`grep '^INSPECTOR_INSTRUCTIONS='` matches only the first line of the ~40-line context block. The verifier JSON array, gate warnings, RETURN_INCOMPLETE flag, and all five pattern instructions are dropped. `_pi_instructions` = `## Phase Inspector Context` (4 words). The agent inspects nothing — RLVR Phase 1 silently ships empty inspections on every pipeline run.

**Fix**: Use the multi-line awk extraction that the test harness already uses (test-phase-inspector.sh `_extract_instructions`):
```bash
_pi_instructions=$(echo "$_pi_out" | awk '/^INSPECTOR_INSTRUCTIONS=/{sub(/^INSPECTOR_INSTRUCTIONS=/,""); found=1; print; next} found{print}')
```
Replace at all three sites (post-IMPLEMENT, post-VERIFY, post-PR-REVIEW).

**Test**: Add a router-consumer test that replays the exact extraction expression from SKILL.md against a fixture context block and asserts the full JSON array survives. Currently no test covers the SKILL.md extraction seam.

---

### P0-2: Library poisons caller shell flags (`set -eo pipefail` at source time)

**Found by**: Bash Reliability
**Files**: `ticket-auto-pipeline/lib/phase-inspector.sh` line 20

`set -eo pipefail` executes at source time. A caller with no `-e` becomes `-e` + `pipefail` after sourcing. Any later unguarded failure aborts the router mid-phase, producing zombie `|waiting|` steps. Repo convention explicitly forbids this (heartbeat.sh: "Shell flags intentionally NOT set here — this is a sourceable library. Setting -e, -u, or -o pipefail would poison every consumer").

**Fix**: Delete the top-level `set -eo pipefail`. Every failure path already carries `|| true`; internal behavior is unchanged without it. Optionally set-and-restore flags inside `assemble_inspector_context`.

**Test**: Add a sourcing-poison test: capture shell flags before and after `source phase-inspector.sh`, assert no change.

---

### P0-3: Unquoted heredoc executes log-derived content (shell injection)

**Found by**: Bash Reliability
**Files**: `ticket-auto-pipeline/lib/phase-inspector.sh` lines 81-118

```bash
_ctx_block=$(cat <<PHASEINSPECT
**Verifier Results** (JSON array):
```json
${_vr_json_array}
```
...
PHASEINSPECT
)
```

The heredoc delimiter is unquoted, so `$(...)`, backticks, and `$var` inside `$_vr_json_array` and `$_gate_warns` (both log-derived, attacker-adjacent) are **executed by the shell**. Gate-warn MSGs embed ticket text — one `$(...)` in a log line becomes shell execution at inspection time. This is also the only unguarded statement under `set -e` — if the command substitution fails, the function aborts non-zero, violating the "all failure paths return 0" promise.

**Fix**: Quote the heredoc delimiter (`<<'PHASEINSPECT'`) to suppress all expansion, then pipe the two data sections via `printf '%s'` into the block. Also add `|| _ctx_block="<context assembly failed>"` guard.

**Test**: Write a verifier-result with a `$(echo pwned)` payload in a field, assert the context block contains the literal string (not the executed result).

---

## P1 — Fixes (important — wrong behavior or spec violation)

### P1-1: flaky_tests pattern is structurally undetectable

**Found by**: QA, Architecture
**Files**: `guidance-extractor/SKILL.md`, `phase-inspector.sh`

The canonical case (design.md D5-1: implement_tests PASS + playwright_uat FAIL) requires cross-phase data, but `assemble_inspector_context` filters strictly by the single PHASE param. IMPLEMENT inspection never sees VERIFY entries and vice versa. The SKILL.md degradation ("check for PASS+FAIL pairs within the available results") makes it a duplicate of `verdict_disagreement` — flaky_tests is dead code or redundant.

**Fix**: Give the post-VERIFY inspector IMPLEMENT+VERIFY entries. Add a `CONTEXT_PHASES` param to `assemble_inspector_context` or pass "IMPLEMENT VERIFY" for post-VERIFY and "IMPLEMENT VERIFY PR-REVIEW" for post-PR-REVIEW. This makes flaky_tests real with a ~5-line bash change to the grep filter.

**Test**: Synthetic log with implement_tests PASS (phase=IMPLEMENT) + playwright_uat FAIL (phase=VERIFY), call assemble_inspector_context with PHASES="IMPLEMENT VERIFY", assert both entries appear and flaky_tests detection would fire.

---

### P1-2: missing_requirement pattern is structurally undetectable

**Found by**: QA, Architecture
**Files**: `guidance-extractor/SKILL.md`, `phase-inspector.sh`

The PR-REVIEW inspector sees only `pr_review` (phase=PR-REVIEW). `critique` and `audit` verifiers are tagged phase=APPRAISE (ticket-critique/SKILL.md:311, ticket-audit/SKILL.md:305) and are filtered out. The spec scenario "PR review OK + critique found gaps in the same phase" cannot occur.

**Fix (choose one)**:
A. Include APPRAISE-phase critique/audit entries in the PR-REVIEW inspection context (they exist in the log by then) — simplest, same CONTEXT_PHASES mechanism as P1-1.
B. Move critique/audit phase tags to PR-REVIEW at the writer sites.
C. Re-spec missing_requirement as an APPRAISE-phase pattern and add an APPRAISE inspector.

Recommendation: Option A (least churn).

**Test**: Synthetic log with critique WARN (phase=APPRAISE) + pr_review PASS (phase=PR-REVIEW), call assemble_inspector_context with PHASES="APPRAISE PR-REVIEW", assert both entries appear.

---

### P1-3: trivial_pass fires on nearly every IMPLEMENT run (false positive factory)

**Found by**: QA, Architecture
**Files**: `guidance-extractor/SKILL.md`, `verifier-result.sh`

`gate_check` and `return_completeness` are single-criterion verifiers by design (criteria_total=1). `implement_tests` PASS is written with no criteria fields (ticket-implement/SKILL.md:393), so criteria_total defaults to 0 (verifier-result.sh:36). Both `0 ≤ 1` and `1 ≤ 1` → trivial_pass fires on every IMPLEMENT regardless of quality, making the "PASS if 0 patterns" verdict unreachable for IMPLEMENT and inflating WARN counts for Phase 2's guidance store.

**Fix**: Do not flag PASS entries with criteria_total=0 (outcome-scored, no criterion basis). Exclude known deterministic single-criterion gates (gate_check, return_completeness) from the pattern by verifier ID prefix. Document the exclusion list.

**Test**: Feed fixture with implement_tests PASS criteria_total=0, gate_check PASS criteria_total=1, assert trivial_pass is NOT emitted. Feed fixture with playwright_uat PASS criteria_total=1, assert trivial_pass IS emitted (UAT with 1 criterion is genuinely shallow).

---

### P1-4: Spec/implementation drift — `spawn_phase_inspector` does not exist

**Found by**: QA, Architecture
**Files**: `phase-inspector.sh`, `openspec/changes/ticket-auto-phase-inspector/specs/phase-inspector-router-integration/spec.md`

The spec requires `spawn_phase_inspector(PHASE, TICKET_ID, LOG_FILE, HB_LOG_FILE)` to assemble context AND invoke the 3-step spawn. The implementation provides `assemble_inspector_context(PHASE, TICKET_ID, LOG_FILE)` (3 params, no HB_LOG_FILE, does not spawn). The spec's function name, signature, and behavior don't exist in code. Phase 2/3 consumers reading the spec will look for the wrong function.

**Fix**: Either implement `spawn_phase_inspector` as specced (moving the inline router spawn into the lib, collapsing 6 lines per site to ~3) OR amend the spec to match the assembly+router-spawn split. Recommendation: move spawn into the lib — the spec's design is cleaner and eliminates the duplicated 6-line spawn template at all 3 sites.

**Test**: If keeping the split: add spec-compliance test verifying function name and signature match spec. If implementing spawn_phase_inspector: test that it prints AGENT_PROMPT (matching spawn_agent_pre contract).

---

### P1-5: Determinism boundary — inspector verdict is unvalidated agent output

**Found by**: Architecture, Security
**Files**: `guidance-extractor/SKILL.md`, `ticket-auto/SKILL.md`

RLVR invariant: "RLVR signals are bash-generated or bash-validated; agents never self-report their own scores." The phase-inspector verdict is pure LLM classification written straight to the log with zero validation. `spawn_agent_post` writes done regardless. The SKILL.md "Deterministic: same input → same verdict" is an unenforceable prompt promise. Phases 2-4 consume these verdicts as reward signals.

**Fix**: Add a ~15-line deterministic bash validator that runs after agent return. jq-checks the schema, recomputes `verdict = worst(patterns[].severity)`, and adds a `"bash_validated":true` field. If the agent output is unparseable, write a WARN skip entry instead. This preserves the determinism boundary with negligible cost.

**Test**: Feed golden JSON fixtures (known verifier arrays) through the validator, assert verdict computation matches expected (PASS/WARN/FAIL). Test agent-output-unparseable path.

---

### P1-6: RETURN_INCOMPLETE gate-warn is not phase-scoped (false positives across phases)

**Found by**: Bash Reliability, Security
**Files**: `phase-inspector.sh` lines 68-77

`_gate_warns` is `grep '|META|gate-warn|'` over the WHOLE log, `tail -3`, then a global `RETURN_INCOMPLETE` grep. A RETURN_INCOMPLETE from IMPLEMENT persists in the tail -3 window and makes the VERIFY inspection (and PR-REVIEW inspection) report `**RETURN_INCOMPLETE present**: true` → spurious `incomplete_implementation` pattern against wrong phases. The `tail -3` also pushes older gate-warns out of window (false negative).

**Fix**: Scope gate-warn collection to the inspected phase's time window — collect gate-warns with ISO timestamps between the phase's first verifier-result and its last. Since gate-warn entries carry no phase field, timestamp-bounded selection is the only correct scoping. Drop the blind `tail -3`.

**Test**: Synthetic log with RETURN_INCOMPLETE in IMPLEMENT section + VERIFY verifier results. Call assemble_inspector_context for VERIFY, assert RETURN_INCOMPLETE flag is false.

---

### P1-7: Library is never sourced in the executing shells at call sites

**Found by**: Architecture
**Files**: `ticket-auto/SKILL.md`

`phase-inspector.sh` is sourced exactly once at line 285 (Step 0.5c). All three call sites (lines ~798, ~900, ~969) invoke `assemble_inspector_context` in later, separate bash blocks with no re-source. In the fresh-shell-per-Bash-tool-call model, all three invocations hit "command not found", `|| true` swallows it, and `PHASE_INSPECTOR_READY=skip` is emitted silently. The fail-soft wrapper converts a wiring bug into a silent no-op.

**Fix**: Add `source ~/.claude/skills/lib/phase-inspector.sh` to each of the three call-site bash blocks (matching the spawn-helper.sh re-source-per-block convention at lines 381, 467). If P1-4 is implemented (spawn_phase_inspector in lib), this fixes itself since the spawn_agent_pre call brings in spawn-helper which is already re-sourced.

**Test**: Hard to test at the unit level — this is an integration concern. Add a note to the SKILL.md preamble requiring re-source.

---

## P2 — Fixes (improvement — edge case or hardening)

### P2-1: jq absence untested and mislabels skip reason

**Found by**: Bash Reliability, QA
**Files**: `phase-inspector.sh` lines 44, 54

jq missing → every `.phase` extraction fails → `_vr_entries` empty → SKIP, exit 0. Fail-soft works, but the skip entry claims "No verifier results available" when results exist and jq is absent — misleading for post-mortem consumers. Tests lack any jq-absence case.

**Fix**: Check `command -v jq` once up front. On absence, emit detail `"jq not available"` instead of "No verifier results available". Add PATH-stubbed test (`PATH="$ws/bin"`).

**Test**: `PATH=/tmp/nonexistent assemble_inspector_context "IMPLEMENT" "CRE-123" "$_log"` → assert skip entry has reason "jq not available".

---

### P2-2: Corrupted/torn verifier-result lines vanish silently

**Found by**: Bash Reliability
**Files**: `phase-inspector.sh` line 44

A torn/truncated verifier-result line (concurrent agents append directly to the log) fails jq and disappears with zero trace. If it was a FAIL verdict, the inspector misses it and reports cleaner-than-reality.

**Fix**: Count jq failures per line and surface `"skipped_lines":N` in the context block (and skip detail), so the agent knows the view is incomplete.

**Test**: Write a malformed JSON line amid good entries, assert skipped_lines count is non-zero.

---

### P2-3: O(N) jq process spawns — performance

**Found by**: Bash Reliability
**Files**: `phase-inspector.sh` line 44

Each matching verifier-result line spawns a jq process. 500 entries → ~1.2s. The per-line design is deliberately corruption-tolerant (a broken JSON line is dropped while neighbors survive — keep that). But the second pass (line 65: `echo "$_vr_entries" | jq -s '.'`) re-processes all entries again.

**Fix**: Batch extraction: `grep ... | awk ... | jq -s --arg phase "$PHASE" 'map(select((.phase // "") == $phase))'` — one jq call that both filters AND builds the array, eliminating the while-read loop and second jq pass. Keep per-line resilience by catching the slurp failure and degrading gracefully.

**Test**: Synthetic log with 100 verifier-result entries, measure extraction time < 500ms.

---

### P2-4: Skip entry appended without jq validation

**Found by**: Bash Reliability
**Files**: `phase-inspector.sh` lines 53-58

verifier-result.sh validates every payload with `jq -e .` before appending (house style). phase-inspector's skip JSON is written raw — a `"` or `\` in PHASE (currently router constants, low risk) corrupts the pipe-delimited format.

**Fix**: jq-validate `_skip_json` before append. Reject `|` in PHASE (mirror `_plog`'s pipe guard in heartbeat.sh).

**Test**: Not easily testable with current constants — PHASE is always a fixed enum. Add validation that crafted-phase input doesn't produce unparseable JSON.

---

### P2-5: No idempotency guard on phase-inspector entries (duplicate on resume/rerun)

**Found by**: QA
**Files**: `phase-inspector.sh` lines 56-57

The skip entry write and agent verdict write have no tail-check idempotency guard, unlike bracket entries in this codebase ("Resolved" section of CLAUDE.md). A resume/rerun of a phase can produce two `META|phase-inspector` entries for the same phase.

**Fix**: Add a tail-check guard before writing phase-inspector entries — if the last log line already contains `|META|phase-inspector|`, skip the duplicate write.

**Test**: Write a phase-inspector entry, call assemble_inspector_context again with same phase, assert only one entry exists in log.

---

### P2-6: install.sh missing allow rule for phase-inspector.sh source

**Found by**: Bash Reliability
**Files**: `ticket-auto-pipeline/install.sh`

install.sh adds `Bash(source ...)` allow rules for spawn-helper.sh and heartbeat.sh (lines 112-113). The new `source ~/.claude/skills/lib/phase-inspector.sh` in the router has no allow rule. In auto mode this hits the permission classifier unprompted.

**Fix**: Add `add_rule "Bash(source ${HOME}/.claude/skills/lib/phase-inspector.sh *)"` to install.sh.

**Test**: Verify install.sh output includes the new allow rule.

---

### P2-7: Corrupted entry jq failures produce no diagnostic

**Found by**: QA
**Files**: `phase-inspector.sh` line 44

When jq fails on a line (torn JSON, malformed), the error goes to `/dev/null`. The skip entry claims "No verifier results available" even when results exist but are unparseable. Different failure modes (no results vs. corrupted results) produce identical skip entries.

**Fix**: Distinguish "no entries found" from "entries found but unparseable" in the skip detail. Track jq failure count separately from empty-result count.

**Test**: Log with one valid and one malformed verifier-result line, assert skip entry indicates partial data.

---

### P2-8: Large-input/concurrency tests missing

**Found by**: QA, Bash Reliability
**Files**: `test-phase-inspector.sh`

No test with 100+ verifier entries (context size under load), no test reading a log while being appended (torn-line behavior), no test for concurrent pipeline runs (separate log files per ticket — safe by design, but unverified).

**Fix**: Add a 100-entry synthetic log test. Add a concurrent-append test (background writer appending while inspector reads).

---

### P2-9: gate-warn grep unanchored — could match inside JSON detail

**Found by**: Bash Reliability
**Files**: `phase-inspector.sh` lines 41, 70

`grep '|META|verifier-result|info|'` and `grep '|META|gate-warn|'` could match the token string inside another line's JSON detail field. Verifier-result JSON could theoretically contain `META|verifier-result` in a detail field.

**Fix**: Anchor with `^` to match only at line start: `grep '^[^|]*|META|verifier-result|info|'`.

**Test**: Write a verifier-result with `META|gate-warn` in its evidence field, assert it's not picked up by gate-warn grep.

---

### P2-10: Agent tool set over-privileged for declared scope

**Found by**: Security
**Files**: `plugin.json` lines 126-134

`guidance-extractor-agent` has `tools: ["Bash","Read"]` but its SKILL.md says "No tool calls: you receive all context in the prompt. Do not read files or call APIs" and "Write exactly ONE line." The agent doesn't need Read at all, and Bash is only needed for one log append. An agent that ignores its instructions has unnecessary tool access in a `LINEAR_API_KEY`-bearing env.

**Fix**: Remove `Read` from tools. If H1 fix (router-side append) is implemented, remove `Bash` too and have the agent return JSON that the router jq-validates and appends deterministically.

**Test**: Verify plugin.json validates, agent spawns with reduced tool set.

---

## Fix ordering (recommended implementation sequence)

1. **P0-2** (set -e removal) — trivial, unblocks safe testing
2. **P0-3** (unquoted heredoc) — shell injection, must fix before P0-1
3. **P0-1** (context truncation) — fixes the feature, unblocks all pattern testing
4. **P1-6** (RETURN_INCOMPLETE scoping) — fixes false positives leaking across phases
5. **P1-1 + P1-2** (cross-phase context window) — makes flaky_tests + missing_requirement detectable
6. **P1-3** (trivial_pass criteria_total=0 exclusion) — stops false-positive flood
7. **P1-4 + P1-7** (spec/impl alignment + library sourcing) — fixes spec drift and silent no-op
8. **P1-5** (bash verdict validator) — closes determinism boundary gap
9. **P2-1 through P2-10** — hardening sweep

Each P0/P1 fix must include a test. Each P2 fix should include a test where feasible.

## Agent reports (raw findings)

- **QA**: P0 context truncation, P1 dead patterns ×2, P1 spec drift, P1 determinism boundary, P2 fail-soft gaps ×4, P2 test quality ×2
- **Architecture**: F1 pattern/schema mismatch, F2 library never sourced, F3 spec/impl divergence, F4 detect-resume coupling, F5 unvalidated agent output, F6 Phase 2 positioning gaps, F7 schema extensibility gaps, F8 doc drift
- **Security**: H1 prompt injection chain, H2 truncation, M1 JSON injection in Phase 0 writer, M2 unscoped RETURN_INCOMPLETE, M3 pipe/quote propagation, L1-L4 minor
- **Bash Reliability**: P1-1 truncation, P1-2 set -e poisoning, P1-3 unscoped gate-warn, P2-1 through P2-6 various, P3 minor ×4
- **Failure Analyst**: No usable output (agent returned empty — likely hook interference)
