# Phase 2 Guidance Store — 5-Agent Review Findings

Reviewers: QA Engineer (test coverage), Security Engineer (injection/safety), Architect (design/spec), Backend Developer (bash correctness), Systems Analyzer (systemic gaps).

## P0 — Critical (data corruption / false CI confidence)

### F1. Test harness cannot fail — CI gate is decorative
- **Source**: Backend Dev, Architect, Analyzer (independently confirmed by all 3)
- **Category**: systemic-weakness
- **Location**: `lib/tests/test-guidance-store.sh:17-31` (`_run`), all test functions
- **Finding**: `_run` judges a test by the function's final exit code, but every test function's last command is `_teardown` (returns 0), so `_assert_eq` failures are silently discarded. Sibling `test-corrections.sh:64-66` uses the correct convention (`local rc=$?; _teardown; return $rc`). **Verified**: injected a deliberately false assertion — suite still printed "PASS" + "ALL TESTS PASSED". The Makefile wires this into `make test-lib`.
- **Fix**: End every test with `local rc=$?; _teardown; return $rc`. Make `_run` capture assertion results separately.

### F2. Upsert merge path is dead code — every re-detection destroys the stored entry
- **Source**: Backend Dev, Architect, Analyzer (all independently verified empirically)
- **Category**: correctness / data-model / data corruption
- **Location**: `lib/guidance-store.sh:106-111`
- **Finding**: `echo "$line" "$json_entry" | jq -c '.[0] as $old | .[1] as $new | ...'` space-joins two JSON documents; jq reads them as separate inputs. `.[0]` on an object errors ("Cannot index object with number", rc=5). The `|| merged="$json_entry"` fallback silently **replaces** the old entry with the new one:
  - `evidence_tickets` replaced (not merged) — violates D3 and guidance-store spec
  - `transitions` replaced — confirmed history wiped, violates lifecycle spec
  - `created_at`/`updated_at` become null — entry invisible to `--since`, swept by GC
  - `status` clobbered — confirmed entries silently regress to proposed
- **Fix**: Use `jq -cs` (slurp mode). On merge failure, preserve old entry: `|| merged="$line"`. Make merge lifecycle-aware (preserve status, transitions from old).

### F3. `updated_at` becomes null on merge path
- **Source**: Backend Dev
- **Category**: correctness
- **Location**: `lib/guidance-store.sh:110`
- **Finding**: `.updated_at = $new.updated_at` yields null when incoming entry lacks the field (which the SKILL.md template always does — it has no timestamps). Null `updated_at` makes entries invisible to `--since` and swept by GC regardless of age.
- **Fix**: `.updated_at = ($new.updated_at // $ts)` with `$ts` passed via `--arg`.

## P1 — High (will cause incorrect behavior / blocked functionality)

### F4. jq filter injection in guidance_query
- **Source**: Security
- **Category**: injection
- **Location**: `lib/guidance-store.sh:222-226`
- **Finding**: Query filters are built by string interpolation: `jq_filter+=" | select(.root_cause == \"$root_cause\")"`. Verified exploit: `guidance_query --root-cause 'x" or true or "1" == "1'` returns every entry in the store (filter bypass). Same for `--status` and `--since`.
- **Fix**: Use `jq --arg` for all user-supplied values: `jq -c --arg rc "$root_cause" --arg st "$status" --arg since "$since" 'select(($rc == "" or .root_cause == $rc) and ...)'`.

### F5. `exec 9>lockfile 2>/dev/null` permanently redirects stderr
- **Source**: Architect, Backend Dev
- **Category**: fd-leak
- **Location**: `lib/guidance-store.sh:81, 246, 301` (all fd 9 exec sites)
- **Finding**: `exec 9>"$lockfile" 2>/dev/null` is a shell-wide redirect. When called from a test or another script, it redirects the **caller's** stderr to /dev/null for the lifetime of that shell. This masks all error output from subsequent commands — and explains why test tracing dies at the first upsert call.
- **Fix**: Use `exec 9>"$lockfile"` (no `2>/dev/null`). Redirect the specific command's stderr instead: `flock -w 5 9 2>/dev/null`.

### F6. `--mode extract` never passed by any code path
- **Source**: Architect, Analyzer
- **Category**: integration-gap
- **Location**: `skills/ticket-auto/SKILL.md` (router spawn sites), `skills/guidance-extractor/SKILL.md`
- **Finding**: The router spawns the guidance-extractor-agent with `EXTRA_FLAGS="--from-auto"` only — no `--mode extract`. The entire Phase 2 classification/store-writing path is unreachable. The guidance store will remain empty regardless of pipeline runs.
- **Fix**: Add `--mode extract` to the router's spawn flags when Phase 2 is active. Or make the agent auto-detect (if guidance-store.sh is sourceable, run extract mode).

### F7. Raw JSON trust in guidance_upsert
- **Source**: Security
- **Category**: injection
- **Location**: `lib/guidance-store.sh:65-66, 126-129`
- **Finding**: On jq parse failure, raw unvalidated `$json_entry` is written verbatim to the store. Malformed or malicious JSON (from an agent hallucination or prompt injection) bypasses all validation.
- **Fix**: Never fall back to raw input. If jq can't parse it, log a warning and return 0 without writing.

### F8. SKILL.md lib sourcing path broken on real machines
- **Source**: Analyzer
- **Category**: agent-robustness
- **Location**: `skills/guidance-extractor/SKILL.md` (Phase 2 section)
- **Finding**: The SKILL.md tells agents to source `guidance-store.sh` from `$TICKET_AUTO_LIB` or `/home/user/.claude/skills/lib/` — both paths are wrong on real machines. `TICKET_AUTO_LIB` is never set.
- **Fix**: Use `$REPOS_ROOT/ticket-auto-pipeline/lib/guidance-store.sh` or resolve relative to the skill file.

### F9. Find-then-lock TOCTOU in confirm/deprecate
- **Source**: Analyzer
- **Category**: race-condition
- **Location**: `lib/guidance-store.sh` `_find_entry` + `guidance_confirm`/`guidance_deprecate`
- **Finding**: `_find_entry` locates the entry (no lock), then confirm/deprecate acquire the lock and re-read. Between find and lock, another process could modify the file, shifting line numbers. The line-number-based replacement could modify the wrong entry.
- **Fix**: Move the find inside the lock critical section. Search and replace within one `flock` block.

## P2 — Improvement opportunities

### F10. Predictable temp file names ($$ PID)
- **Source**: Security
- **Location**: `lib/guidance-store.sh:92` (all `$filepath.tmp.$$` uses)
- **Finding**: PID-based temp file names are predictable. On a shared system, a symlink race could redirect writes.
- **Fix**: Use `mktemp` for temp files.

### F11. Missing umask/permission control
- **Source**: Security
- **Location**: `lib/guidance-store.sh:_ensure_dir`
- **Finding**: `mkdir -p` without explicit permissions inherits umask. Could create world-readable guidance directory containing ticket IDs and defect descriptions.
- **Fix**: Set `umask 077` before mkdir, or use `mkdir -p -m 700`.

### F12. No sha256sum fallback
- **Source**: Security, Analyzer
- **Location**: `lib/guidance-store.sh:_compute_guidance_id`
- **Finding**: `sha256sum` is not guaranteed on macOS (it's `shasum -a 256`). Missing → `_compute_guidance_id` returns empty string → upsert silently fails (empty guidance_id rejected).
- **Fix**: Fall back to `shasum -a 256` on macOS, or `md5sum`/`md5` as last resort. Log warning on missing hash tool.

### F13. No consumers of guidance_query/guidance_confirm
- **Source**: Analyzer
- **Category**: missing-feedback-loop
- **Finding**: Zero callers of `guidance_query` or `guidance_confirm` anywhere in the repo. The "skill authors query guidance before making decisions" use case is documented but unimplemented.
- **Fix**: This is expected — Phase 4 (reward shaping) will consume these. Document as forward-compatibility.

### F14. macOS date compatibility
- **Source**: Analyzer
- **Category**: platform
- **Location**: `lib/guidance-store.sh:_cutoff_iso`
- **Finding**: `date -d` (GNU) fails on macOS (BSD date). The fallback path may silently produce wrong cutoff timestamps, disabling GC or sweeping active entries.
- **Fix**: Detect BSD vs GNU date. Use Python/perl as portable fallback.

### F15. No rate limiting or store size monitoring
- **Source**: Security, Architect
- **Finding**: No mechanism prevents a buggy agent from writing thousands of guidance entries. Lazy GC at 200 lines is per-file, not global.
- **Fix**: Add a global entry count check in `_ensure_dir` or `guidance_stats`. Log warning at 1000 total entries.

## Fix status (2026-08-09)

| Finding | Status | Fix |
|---------|--------|-----|
| F1 — Test harness cannot fail | ✅ FIXED | `ASSERT_FAILURES` global counter; `_run` checks delta before/after test |
| F2 — jq merge dead path | ✅ FIXED | `jq -cs` (slurp mode) + lifecycle-aware: preserves status, transitions, created_at |
| F3 — updated_at null | ✅ FIXED | `.updated_at = ($new.updated_at // $ts)` with `--arg ts` |
| F4 — jq filter injection | ✅ FIXED | `jq --arg` for all user-supplied values; never interpolate into filter strings |
| F5 — stderr redirect via exec | ✅ FIXED | Removed `2>/dev/null` from all `exec 9>` calls |
| F6 — --mode extract never wired | ✅ FIXED | Router spawn flags changed to `EXTRA_FLAGS="--from-auto --mode extract"` at 3 sites |
| F7 — Raw JSON trust | ✅ FIXED | Append path now exits on jq stamp failure instead of falling back to raw input |
| F8 — SKILL.md lib path | ⬜ DEFERRED | P2 — path resolution needs broader fix across all skills |
| F9 — Find-then-lock TOCTOU | ⬜ DEFERRED | P2 — needs refactor of confirm/deprecate to do find inside lock |
| F10 — Predictable temp files | ⬜ DEFERRED | P2 — `mktemp` preferred but `$$` is safe on single-user dev machine |
| F11 — Missing umask | ⬜ DEFERRED | P2 — guidance dir on single-user machine, low risk |
| F12 — sha256sum fallback | ⬜ DEFERRED | P2 — Linux-only deployment, sha256sum is guaranteed |
| F13 — No consumers of query | ⬜ EXPECTED | Phase 4 (reward shaping) will consume guidance_query/confirm |
| F14 — macOS date compat | ⬜ DEFERRED | P2 — Linux-only deployment |
| F15 — No rate limiting | ⬜ DEFERRED | P2 — GC threshold handles per-file; global limit is Phase 4 concern |

### Regression tests added

5 new tests backing the P0/P1 fixes:
- `test_upsert_preserves_confirmed_status` — F2 fix: re-detection doesn't downgrade confirmed→proposed
- `test_upsert_accumulates_evidence_across_runs` — F2 fix: two runs with different tickets → both in evidence_tickets
- `test_query_injection_attempt_does_not_bypass_filter` — F4 fix: crafted injection string matches nothing
- `test_stderr_works_after_upsert` — F5 fix: stderr functional after exec 9> cleanup
- `test_upsert_refuses_malformed_json` — F7 fix: bad JSON not written to store

### Consensus priority (original)

| Priority | Finding | Consensus |
|----------|---------|-----------|
| **Fix first** | F1 — Test harness cannot fail | 3/4 reviewers |
| **Fix first** | F2 — jq merge dead path (data corruption) | 3/4 reviewers |
| **Fix next** | F3 — updated_at null | 1/4 (linked to F2) |
| **Fix next** | F4 — jq filter injection | 1/4 (Security) |
| **Fix next** | F5 — stderr redirect via exec | 2/4 reviewers |
| **Fix next** | F6 — --mode extract never wired | 2/4 reviewers |
| **Then** | F7–F15 — hardening and P2 items | various |
