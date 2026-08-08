# RLVR Phase 3 — 5-Agent Review Findings Checklist

22 findings from Architect, Analyzer, Backend Dev, QA Engineer, Security Engineer review.
Ordered by severity. Each fix must include a test where applicable.

---

## P0 — Must Fix Before Merge (3 items)

- [ ] **F01. EXIT trap fires at registration, not pipeline end**
  File: `skills/ticket-auto/SKILL.md:361-397`
  Harness runs each ```bash block as fresh shell. Trap fires when Step 0.65 bash block ends — before dispatch loop. Every run gets premature "completed" outcome + no postmortem analysis.
  **Fix**: Replace bash trap with explicit postmortem invocation at every exit point. Postmortem must be the LAST action before session end on all paths (gate-stop, exhaustion, STEP_6, router-error, gate-held). Add integration test.

- [ ] **F02. RCE via sed injection in `_render_issue_body`**
  File: `pipeline-postmortem.sh:522-535`
  Signature contains `|` by construction. `sed "s|{SIGNATURE}|${signature}|g"` — pipe in replacement breaks delimiter. Crafted input enables `e` command (arbitrary shell execution). Same for multi-line evidence fields.
  **Fix**: Replace sed templating with awk variable passing or pure-bash `${var//search/replace}`. Never interpolate untrusted text into sed scripts. Add test with pipe-containing signature.

- [ ] **F03. Severity mapping always returns P0 (ternary precedence bug)**
  File: `pipeline-postmortem.sh:291-306`
  `$((1 + _bump > 0 ? _bump : 1))` parses as `(1 + _bump > 0) ? _bump : 1` → always `_bump`. Every non-mislabeled issue = P0, every mislabeled = P1.
  **Fix**: Replace with proper case table: exit_path → base severity, then `base + bump`. Add test for full severity matrix (5 paths × bump on/off).

---

## P1 — Pipeline-Critical (8 items)

- [ ] **F04. No `timeout` on gh calls — EXIT trap wedges**
  Files: `pipeline-postmortem.sh:111,431`, `SKILL.md:372`, `fleet-intervene.sh:98`
  Design D2 requires timeout 30 around every gh call. Zero implemented. Hung gh blocks router exit indefinitely.
  **Fix**: Wrap postmortem invocation in `timeout 60`, wrap `github_issue_create` in `timeout 30`. Add fail-soft test.

- [ ] **F05. `_fleet_postmortem` never passes LOG_FILE/HB_FILE/TICKET_DIR**
  File: `fleet-intervene.sh:83-100`
  Workspace param accepted but unused. Postmortem defaults to `./logs/` relative to fleetd cwd. Non-default workspace → silent no-op.
  **Fix**: Export `LOG_FILE="$log_file" HB_FILE="$hb_file" TICKET_DIR=""` before invoking.

- [ ] **F06. Concurrent state file races — signatures.json wipe risk**
  File: `pipeline-postmortem.sh:356-423`
  `_signature_record` does read→jq→write with no flock. `jq ... || echo '{}'` wipes entire dedup store on failure. Concurrent double-file, mass re-file on corruption.
  **Fix**: flock per-repo state dir. Write signatures.json via `.tmp`+`mv`. Never overwrite on jq failure — back up and skip.

- [ ] **F07. Gate-held tickets recorded as "completed: STEP_6"**
  File: `skills/ticket-auto/SKILL.md:379-380`
  Any `exit 0` (including gate-held) → "completed: STEP_6". Complex tickets held at approve gate incorrectly recorded as completed.
  **Fix**: Derive outcome from log evidence, not exit code alone. Gate-held path must emit "held" outcome.

- [ ] **F08. Trap registered after preflight/branch exits — no postmortem coverage**
  File: `skills/ticket-auto/SKILL.md` (Step 0.65 placement)
  Preflight/validation exits happen BEFORE trap registration. BRANCH_DIRECTIVE_INVALID gate-stop gets zero postmortem + no outcome.
  **Fix**: Move postmortem invocation to be explicitly called on every exit path, not dependent on trap position.

- [ ] **F09. LOG_FILE/HB_FILE/TICKET_DIR never reach postmortem in trap path**
  File: `skills/ticket-auto/SKILL.md:372`
  These are router shell vars, never exported. Postmortem runs with `./logs/` defaults. CORRECTIONS append is dead code.
  **Fix**: Pass `LOG_FILE=... HB_FILE=... TICKET_DIR=...` explicitly in postmortem invocation.

- [ ] **F10. Stale outcome on crash-resume**
  File: `skills/ticket-auto/SKILL.md:377`
  Idempotency guard `grep -q '|META|outcome|'` finds old outcome from crashed run. Gate-stop→re-run→success leaves stale "stopped" outcome.
  **Fix**: Tail-check guard (only skip if outcome IS the last substantive line), or append fresh outcome unconditionally.

- [ ] **F11. Filing path is dead code — extractor always returns "unknown"**
  File: `pipeline-postmortem.sh:544-558`
  `_invoke_extractor_agent` always echoes `"unknown"` → filing gate skips. Rate limiter, dedup, template rendering all inert.
  **Fix**: Add `POSTMORTEM_CLASSIFY` env var for manual override. When extractor returns unknown, fall back to conservative classification based on signal type (gate-stop→lib-script, verifier-fail→agent-prompt). Document Phase 2 replacement path.

---

## P2 — Quality / Correctness (11 items)

- [ ] **F12. jq missing from fail-soft front gate**
  File: `pipeline-postmortem.sh:107-121`
  Script uses jq in 15+ places but only checks gh. jq failure → state file wipe, garbage summary.
  **Fix**: Add `command -v jq` check alongside gh check.

- [ ] **F13. Template resolution broken at runtime**
  File: `pipeline-postmortem.sh:451-457`
  `$HOME/.claude/skills/lib/../skills/...` = nonexistent `$HOME/.claude/skills/skills/...`. Runtime fallback also wrong. Inline heredoc always renders.
  **Fix**: Resolve templates relative to script dir for dev, `$HOME/.claude/skills/ticket-retro/templates/` for runtime. Remove inline duplicate.

- [ ] **F14. UNKNOWN verifier verdicts counted as FAIL**
  File: `pipeline-postmortem.sh:160-164`
  `_verdict != "PASS"` flags malformed entries as failures. Design says "absent or malformed entries degrade to no signal."
  **Fix**: Only FAIL and BLOCK count as failures. UNKNOWN/missing verdicts silently skipped.

- [ ] **F15. `verify-exhausted`/`pr-feedback-exhausted` dead branches**
  File: `pipeline-postmortem.sh:220-229, 641`
  Production writes exhaustion as `META|gate-stop|fail|VERIFY_EXHAUSTED`. Gate-stop check always wins → bare-string branches unreachable. Verifier-fail signals never file.
  **Fix**: In `_derive_exit_path`, match gate-stop codes containing VERIFY_EXHAUSTED/PR_FEEDBACK_EXHAUSTED. In filing criteria, also match gate-stop: prefix.

- [ ] **F16. Empty/null details produce degenerate hash**
  File: `pipeline-postmortem.sh:296-310`
  Empty/whitespace-only details → constant hash `e3b0c44298fc`. Distinct defects with empty normalization collapse to one signature.
  **Fix**: Include the raw type+phase as salt when normalized details are empty.

- [ ] **F17. Multi-line sed crash in `_render_issue_body`**
  File: `pipeline-postmortem.sh:522-535`
  ≥2 evidence entries → multi-line value → `sed: unknown option to 's'`. Script dies mid-render, idempotency guard blocks re-analysis.
  **Fix**: Resolved by F02 (switch from sed to awk-based rendering).

- [ ] **F18. Restarted runs never get postmortem**
  File: `pipeline-postmortem.sh:94-101`
  Same first-line ISO across restarts → same run_id → idempotency guard skips. Restarted runs get no analysis.
  **Fix**: Use (TICKET_ID + ISO-of-last-META|postmortem-started + count) as run_id. Or clear prior started markers on resume.

- [ ] **F19. META|outcome rule-1 violation on fleet-kill path**
  File: `fleet-intervene.sh` (all kill paths)
  Postmortem appends AFTER outcome. pipeline-log-format.md rule 1 broken.
  **Fix**: Run postmortem BEFORE outcome write on fleet-kill paths. Or document postmortem entries as sanctioned epilogue.

- [ ] **F20. Dashboard AUTO-RETRO counts per-run only, not cumulative**
  File: `fleet-dashboard.sh` (`_postmortem_issue_count`)
  Reads latest `META|postmortem` summary — shows THIS run's filed count, not total open issues.
  **Fix**: Read from `~/.claude/state/ticket-auto/postmortem/<repo>/signatures.json` for cumulative open count. Fall back to log summary.

- [ ] **F21. Missing signal sources in `_collect_signals`**
  File: `pipeline-postmortem.sh:152-203`
  Not collected: `flow-error`, `preflight|fail`, phase `|fail|` (non-MAINTENANCE), `drift|warn`, `mode-change|warn`, `corrections-error|warn`. Model/from-planned collected but unconsumed.
  **Fix**: Add flow-error, preflight, phase-fail, drift-warn, mode-change to signal collection. Consume model/from-planned in summary.

- [ ] **F22. run_id collision on same-second log recreation**
  File: `pipeline-postmortem.sh:94-95`
  Same ticket, log deleted + recreated within same UTC second → identical run_id → skip analysis. Low probability, fail-safe direction.
  **Fix**: Add `$$` (PID) or incremental counter to run_id for uniqueness within same second.

---

## Test Gaps

- [ ] **T01.** Test with `POSTMORTEM_FILE_ISSUES=true` — entire filing path
- [ ] **T02.** `test_signature_determinism` compares exit_path, not actual signature hash
- [ ] **T03.** Test concurrent postmortem (flock coverage)
- [ ] **T04.** Test corrupted state file recovery
- [ ] **T05.** Test rate-limit boundary (6th signature in same hour)
- [ ] **T06.** Test full severity matrix (5 exit paths × bump on/off)
- [ ] **T07.** Test sed/awk rendering with pipe-containing signature
- [ ] **T08.** Test rendering with multi-line evidence (≥2 entries)
- [ ] **T09.** Test postmortem with all new signal sources (flow-error, preflight, drift)
- [ ] **T10.** Test restart idempotency (same log, different run)
