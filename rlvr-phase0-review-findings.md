# RLVR Phase 0 — Review Findings Checklist

5-agent multi-persona review of `feat/rlvr-program`. 25 Aug 2026.

**Reviewers**: Architect (32 tools), Security (23), Backend Dev (19), QA Engineer (46), Analyzer (65).

---

## 🔴 P0 — Release Blocking

- [ ] **F1. trajectory.sh grep patterns broken — cross-contaminates trajectory data**
  File: `ticket-auto-pipeline/lib/trajectory.sh:95,107`
  Problem: `grep '\|META\|verifier-result\|'` is a BRE alternation with empty branches that matches EVERY line. Model entries tagged as verifier-result, verifier-result tagged as model. Tests pass because they assert presence (grep -q), never counts.
  Fix: `grep -F '|META|verifier-result|'` and `grep -F '|META|model|'`. Also anchor phase-transition grep at line 83 to field positions. Add count-based test assertions.
  Found by: Architect, Security, Backend, QA, Analyzer

- [ ] **F2. New lib files have zero deployment path — gate step dies on fresh install**
  File: `ticket-auto-pipeline/lib/gate-check.sh:13` (unguarded `source "$LIB_DIR/verifier-result.sh"`), `install.sh`, `Makefile`
  Problem: `verifier-result.sh` and `trajectory.sh` don't exist in `~/.claude/skills/lib/` (the runtime path). `gate-check.sh` does unguarded source; `return-completeness-check.sh` correctly guards its source. On any fresh install, first gate decision hits `command not found` → exit 127 → pipeline stops.
  Fix: (a) Add `[ -f ] && source || :` guard to gate-check.sh:13 matching return-completeness pattern; (b) add lib sync to install.sh or Makefile
  Found by: Architect, Backend, QA

---

## 🟡 P1 — Pipeline-Critical

- [ ] **F3. `set -euo pipefail` in sourced library re-enables nounset in callers**
  File: `ticket-auto-pipeline/lib/verifier-result.sh:16`, `ticket-auto-pipeline/lib/trajectory.sh:17`
  Problem: gate-check.sh and return-completeness-check.sh deliberately omit `-u` (Claude Code shell snapshots inject ZSH_VERSION references causing false-positive "unbound variable"). Sourcing `verifier-result.sh` silently re-enables the documented failure mode. Also forced into every agent shell via SKILL.md call sites.
  Fix: Remove `set -euo pipefail` from both sourced libraries. Repo convention across 10+ lib files omits `-u` for this reason.
  Found by: Security, Backend, QA

- [ ] **F4. `write_verifier_result` NOT fail-open on the final log append**
  File: `ticket-auto-pipeline/lib/verifier-result.sh:140`
  Problem: All 6 pre-write validation paths return 0 gracefully, but `echo ... >>"$LOG_FILE"` is unguarded. Disk full or unwritable LOG_FILE → return 1 → under set -e the caller aborts before reaching `|| true` wrapper. The 7 SKILL.md call sites are bare calls with no `|| true` — an agent's phase script aborts mid-skill.
  Fix: `echo ... >>"$LOG_FILE" || { echo "[verifier-result] WARN: log write failed" >&2; return 0; }`
  Found by: Security, QA

- [ ] **F5. trajectory.sh aborts under pipefail when grep matches nothing — orphans tmp file**
  File: `ticket-auto-pipeline/lib/trajectory.sh:83,95,107,120`
  Problem: Each `grep ... | while` runs under `set -o pipefail`. grep exits 1 on no match → pipeline fails → set -e kills traj_generate mid-run, leaving orphaned `${output}.tmp.$$` and no output file. Empty heartbeat log is normal (`touch` at init). Pipeline log without start/done/waiting lines also triggers.
  Fix: Guard each stage (`grep ... || true | while ...`), add trap cleanup for tmp file on exit.
  Found by: Security, QA

- [ ] **F6. MODEL append to spawn-meta unguarded while sibling (6b) is guarded**
  File: `ticket-auto-pipeline/lib/spawn-helper.sh:369`
  Problem: `echo "MODEL=${model}" >>"$meta_file"` has no `|| true`. Comment at line 371 claims set -e safety but only 6b (line 374) has it. /tmp full or unwritable meta file → `spawn_agent_pre` dies → router spawn fails.
  Fix: Add `|| true`
  Found by: Security, Backend

---

## 🟢 P2 — Should Fix Before Merge

- [ ] **F7. Model JSON written unvalidated — log injection possible**
  File: `ticket-auto-pipeline/lib/spawn-helper.sh:373-374`
  Problem: `printf '{"phase":"%s","model":"%s"}' "$PHASE" "$model"` appended to pipeline log with no jq validation. Newline in ANTHROPIC_MODEL injects forged log lines structurally identical to real entries. Quote in value → permanently malformed log line.
  Fix: Validate with jq before append (same pattern as verifier-result.sh) or escape via `jq -Rs`
  Found by: Security, Backend

- [ ] **F8. Score not clamped to [0,1]; gate PASS writes contradictory criteria**
  File: `ticket-auto-pipeline/lib/verifier-result.sh:411`, `ticket-auto-pipeline/lib/gate-check.sh:19-24`
  Problem: criteria_met > criteria_total → score > 1.0 (e.g. 5/3 → 1.667). Gate PASS defaults to criteria_met=0, criteria_total=1 with score=1.0 — "0 of 1 criteria met, score 1.0" is contradictory. Phase 1 inspector reading criteria will trip.
  Fix: Clamp score to [0,1]; `_write_gate_verdict` pass 1/1 on PASS; document that score is comparable only within a verifier
  Found by: Architect, Backend

- [ ] **F9. `_compute_actual_confidence` copy-pasted — will drift**
  File: `ticket-auto-pipeline/lib/verifier-result.sh:332-351` vs `ticket-auto-pipeline/lib/planned-feedback-write.sh:227-247`
  Problem: Byte-identical today, but design D2 allowed "re-implement" — copy-paste IS the drift mechanism. Phase 4 makes this load-bearing.
  Fix: Extract to `lib/confidence.sh` sourced by both; add parity test sweeping (outcome × corrections)
  Found by: Architect

- [ ] **F10. `attempt` field agent-guessed — RL episode key unreliable**
  File: `ticket-auto-pipeline/skills/ticket-verify/SKILL.md:580-581`, `ticket-auto-pipeline/skills/ticket-implement/SKILL.md:383`
  Problem: Router owns VERIFY_ATTEMPTS counter but doesn't inject it into spawn context. Skills tell agents to write `attempt=<A>` with no source for A. Phase 1 flaky-pattern detection and Phase 4 episode rewards depend on this.
  Fix: Router supply attempt via spawn_agent_pre param appended to spawn-meta (same channel MODEL uses); or skill reads VERIFY_ATTEMPTS from detect-resume.sh
  Found by: Architect, QA

- [ ] **F11. sort key is accidental — not sorting by ISO**
  File: `ticket-auto-pipeline/lib/trajectory.sh:134`
  Problem: `sort -t'"' -k4,4` with quote delimiter: field 4 is `,type:` (constant), so every key is equal → sorts by full-line tiebreak. Chronological only because ISO is leading differing bytes. Any future line-shape change silently degrades ordering.
  Fix: `sort -t'"' -k4,4` → `sort -k3,3` (the ISO field)
  Found by: Architect, Backend, Security

- [ ] **F12. trajectory msg carries spurious trailing newline**
  File: `ticket-auto-pipeline/lib/trajectory.sh:479-487`
  Problem: `jq -Rs '.'` appends newline. Empty MSG → `"msg":"\n"` instead of `""`. Exact-match consumers will miss.
  Fix: Strip in command substitution or use `rtrimstr("\n")`
  Found by: Architect

- [ ] **F13. `2>/dev/null` on `_write_gate_verdict` suppresses diagnostics**
  File: `ticket-auto-pipeline/lib/gate-check.sh:32`
  Problem: In a jq-less environment, every gate verdict silently dropped with zero trace in gate output.
  Fix: Remove `2>/dev/null` or redirect stderr to heartbeat log
  Found by: Security

- [ ] **F14. Named-param parser: values with `=` silently truncated**
  File: `ticket-auto-pipeline/lib/verifier-result.sh:47-54`
  Problem: `${arg#verifier=}` strips only the first `=`. Value containing `=` (e.g. `verifier=foo=bar`) would parse as `foo=bar`, then `${arg#verdict=}` would match against the remainder incorrectly. Low practical risk (verifier names are constants).
  Fix: Document verifier name constraint (no `=` allowed) or use `${arg#*=}` pattern
  Found by: Backend

---

## 🔵 P3 — Improvements

- [ ] **F15. Path traversal via unvalidated ticket_id**
  File: `ticket-auto-pipeline/lib/trajectory.sh:59,63-65`
  Problem: ticket_id interpolated unvalidated into file paths. `../../etc` resolves outside logs dir. Writes bounded by `[ -f ]` check. Low practical exposure (router passes Linear IDs).
  Fix: Validate against `^[A-Za-z0-9-]+$`
  Found by: Security

- [ ] **F16. sed fallback in `_json_escape` escapes only `"`, not backslashes or newlines**
  File: `ticket-auto-pipeline/lib/trajectory.sh:33`
  Problem: When neither jq nor python3 available, multiline MSG produces malformed JSONL. All target environments have jq.
  Fix: Low priority — add `\|\\` to sed pattern for robustness
  Found by: Security

- [ ] **F17. `$((TOTAL_COUNT - UNCHECKED_COUNT))` latent nounset trip**
  File: `ticket-auto-pipeline/lib/return-completeness-check.sh:152`
  Problem: Safe today (count functions always run first), but if execution order changes this trips nounset. Subsumed by F3 fix.
  Fix: Subsumed by F3 fix (removing nounset from sourced library)
  Found by: Security

---

## 📋 Gap Analysis (from Analyzer)

- [ ] **G1. 3 of 11 pipeline verifiers produce no verifier-result**
  Missing call sites: `ticket-retro` verdicts, `ticket-document` quality checks, `ticket-prescan` verification. These verifiers exist in the pipeline but weren't wired.
  Fix: Add write_verifier_result instructions to ticket-retro/SKILL.md, ticket-document/SKILL.md, ticket-prescan/SKILL.md

- [ ] **G2. Zero enforcement mechanism for SKILL.md call sites**
  All SKILL.md sites are agent instructions with no bash backstop. Agents can forget to call write_verifier_result and the log is silently sparse with zero detection.
  Fix: Phase 1 task — post-phase bash validator that counts expected vs actual verifier-result entries and warns

- [ ] **G3. `META|from-planned` has zero writers**
  Design doc D4 calls it "existing entry" that consumers should check before confidence-weighting verifier results. Nothing in the codebase writes it.
  Fix: Add `META|from-planned|info|true` write in the planned-ticket fast-path

- [ ] **G4. Model fallback chain not implemented as documented**
  `pipeline-log-format.md` says "ANTHROPIC_MODEL env → router context → unknown"; code has only `ANTHROPIC_MODEL:-unknown`. The "router context" branch is fictional.
  Fix: Either implement the chain or correct the doc

- [ ] **G5. RLVR program doc is already stale**
  `ticket-auto-rlvr-program.md` says "verify retry (3×)" — router hard-caps at 2. Program doc should match reality.
  Fix: Update program doc: 3× → 2× verify retry

---

## 📊 Test Coverage Gaps (from QA)

- [ ] **T1. No count-based trajectory assertions** — presence checks (`grep -q`) mask duplication bugs
- [ ] **T2. No empty-log pipefail abort test** — normal condition (empty heartbeat log) not covered
- [ ] **T3. No LOG_FILE write-failure test** — the unguarded echo path (F4) has zero coverage
- [ ] **T4. No concurrent trajectory generation test** — race between tmp+mv and reader
- [ ] **T5. No test for `criteria_met > criteria_total`** — unclamped score path uncovered
- [ ] **T6. No test for `ANTHROPIC_MODEL` with special characters** — injection path uncovered

---

## Fix Priority Order

```
1. F1  (trajectory grep)     ── data corruption, blocks Phase 1/3
2. F2  (deployment path)     ── gate dies on fresh install
3. F3  (nounset re-enable)   ── silent abort in gate-check
4. F4  (fail-open on write)  ── violates RLVR invariant #3
5. F5  (pipefail abort)      ── orphans files, data loss
6. F6  (unguarded MODEL)     ── blocks router spawn
7. F7  (model injection)     ── forged log entries
8. F8  (score clamp)         ── data quality
9. F9  (shared confidence)   ── prevents drift
10. F10 (attempt from router) ── RL episode integrity
11. F11-F17 (P2/P3 quality)  ── sort key, newline, etc.
12. G1-G5 (gaps)             ── coverage completeness
13. T1-T6 (test coverage)    ── regression prevention
```
