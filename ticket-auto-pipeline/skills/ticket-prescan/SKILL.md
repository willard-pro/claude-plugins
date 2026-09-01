---
name: ticket-prescan
description: Pre-scan a repository to build durable agent-knowledge artifacts under REPOS_ROOT/.ticket-auto/. Runs freshness gate, gitnexus indexing, multi-persona fan-out or incremental refresh, and corpus building. Produces per-repo docs (services, routes, processes, security surfaces, INDEX.md) consumed by ticket-appraise Step 3a. Use when the user says "/ticket-prescan", "/ticket-prescan <repo-path>", "/ticket-prescan --force", or "prescan the repos".
---

# Ticket Prescan — Agent Knowledge Builder

Orchestrates repository prescan to build durable, freshness-tracked agent-knowledge docs at `REPOS_ROOT/.ticket-auto/<repo-slug>/`. Multiple persona agents produce distilled docs once; subsequent runs verify freshness deterministically and only re-scan what changed.

## Pipeline Preamble

If `--from-auto` is present in the arguments, follow the auto-pipeline preamble in `~/.claude/skills/lib/skill-preamble-auto.md` with parameters: TICKET_ID=none, PHASE=PRESCAN, HAS_LINEAR_ACCESS=false, HAS_LOGGING=true, HAS_HEARTBEAT=true. Before starting, source the project context: `source /tmp/ticket-auto-env.sh 2>/dev/null || true`. Otherwise, follow the full pipeline preamble in `~/.claude/skills/lib/skill-preamble.md` with parameters: TICKET_ID=none, PHASE=PRESCAN, FROM_FLAG=none, HAS_LINEAR_ACCESS=false, HAS_GUARD=false, HAS_PROJECT_CONTEXT=true, PROJECT_CONTEXT_FIELDS=REPOS_ROOT, HAS_LOGGING=true, HAS_HEARTBEAT=true, HAS_STEP_DISPATCH=false, HAS_TASK_TRACKER=false

## Logging

Prescan uses its own repo-scoped log at `~/.claude/logs/prescan-<repo-slug>.log`. This is NOT a pipeline phase log — `detect-resume.sh` does not recognize a PRESCAN phase. Crash recovery: idempotent re-run (freshness gate re-evaluates).

```bash
mkdir -p "$HOME/.claude/logs"
PRESCAN_LOG="$HOME/.claude/logs/prescan-<repo-slug>.log"
_plog() { echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|$1|$2|$3|$4" >> "$PRESCAN_LOG"; }
```

Run the `mkdir -p` once, before the first `_plog` call. Without it, `_plog`'s `>>` redirect fails silently against a missing directory and every log line is lost.

## Heartbeat

- **Freshness gate**: `hb-wrap.sh decision "prescan-gate" "fired" "<status>:<reason>" '{"status":"...","reason":"..."}'`
- **Fallback**: if gitnexus unavailable, `hb-wrap.sh fallback "gitnexus" "fired" "gitnexus MCP unavailable" '{"section":"..."}'`
- **Corpus build**: if corpus build fails, `hb-wrap.sh fallback "corpus-build" "fired" "corpus unavailable" '{"repo":"<slug>"}'`
- **Scaffold verify**: `hb-wrap.sh gate "prescan-scaffold" "<ok|fail>" "<msg>" '{"docs_dir":"..."}'`

---

## Step 0 — Environment check and repo enumeration

Validate environment via `env-check.sh --mode=validate` from lib. Resolve `REPOS_ROOT` using `_derive_repos_root` (from ticket-setup Step 0.2). If the user provided a specific repo path as argument, use that single repo. Otherwise, enumerate all repos under `REPOS_ROOT`:

```bash
source "$HOME/.claude/skills/lib/env-check.sh"
if ! env_check_validate; then
  _plog "PRESCAN" "env-check" "fail" "Environment validation failed"
  exit 1
fi

# Resolve REPOS_ROOT from CLAUDE.md
REPOS_ROOT="${REPOS_ROOT:-$(grep 'REPOS_ROOT:' "$HOME/.claude/CLAUDE.md" 2>/dev/null | head -1 | sed 's/.*REPOS_ROOT: *//' || true)}"
if [ -z "$REPOS_ROOT" ]; then
  _plog "PRESCAN" "env-check" "fail" "REPOS_ROOT not set"
  exit 1
fi

# Enumerate repos: if user passed a path, use it; otherwise find all repos
if [ -n "${1:-}" ] && [ -d "$1" ]; then
  REPOS=("$1")
else
  REPOS=()
  while IFS= read -r -d '' dir; do
    [ -d "$dir/.git" ] && REPOS+=("$dir")
  done < <(find "$REPOS_ROOT" -maxdepth 3 -name ".git" -printf '%h\0' 2>/dev/null || true)
fi
```

For each repo, derive the slug:
```bash
_derive_slug() { basename "$1" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g'; }
```

---

## Step 1 — Freshness gate per repo

For each repo, run the deterministic freshness gate:

```bash
source "$HOME/.claude/skills/lib/prescan-check.sh"

for repo in "${REPOS[@]}"; do
  slug=$(_derive_slug "$repo")
  _plog "PRESCAN" "freshness-gate" "start" "$slug"

  eval $(bash "$HOME/.claude/skills/lib/prescan-check.sh" "$repo" --repos-root "$REPOS_ROOT")

  hb-wrap.sh decision "prescan-gate" "fired" "$PRESCAN_STATUS:$PRESCAN_REASON" \
    "{\"status\":\"$PRESCAN_STATUS\",\"reason\":\"$PRESCAN_REASON\"}"

  case "$PRESCAN_STATUS" in
  fresh)
    _plog "PRESCAN" "freshness-gate" "skip" "$slug: fresh ($PRESCAN_REASON)"
    PRESCAN_RESULTS["$slug"]="skipped-fresh"
    continue
    ;;
  stale)
    _plog "PRESCAN" "freshness-gate" "done" "$slug: stale — incremental refresh"
    CADENCE="$PRESCAN_STATUS"
    ;;
  decayed)
    _plog "PRESCAN" "freshness-gate" "done" "$slug: decayed — full re-dive"
    CADENCE="decayed"
    ;;
  missing)
    _plog "PRESCAN" "freshness-gate" "done" "$slug: missing — first-time scan"
    CADENCE="missing"
    ;;
  esac

  # Continue to Steps 2-6 for this repo...
done
```

If the `--force` flag was passed, set `CADENCE=forced` for all repos (bypass freshness gate).

---

## Step 2 — CLAUDE.md readiness

For each non-fresh repo, ensure `CLAUDE.md` exists:

- If `CLAUDE.md` exists and is populated → leave untouched, proceed.
- If `CLAUDE.md` is missing or empty → create via `/claude-md-management:claude-md-improver` or `claude init`.
- If gitnexus data is available, seed with context; otherwise use codebase scan.

Existing hand-written `CLAUDE.md` content MUST NOT be modified. Only managed blocks (e.g., `<!-- ticket-auto:agent-knowledge -->`) may be inserted.

---

## Step 3 — GitNexus index and refresh

**First, load the gitnexus tool schemas**: `ToolSearch(query="select:mcp__gitnexus__list_repos,mcp__gitnexus__detect_changes")`. `mcp__gitnexus__*` tools are harness-deferred — calling one before its schema is loaded via `ToolSearch` fails with `InputValidationError`. That failure means "schema not loaded yet," not "gitnexus MCP unavailable" — do not treat it as the unavailable-fallback case below. Only fall back if the MCP server itself is unreachable (e.g., `list_repos` still errors after `ToolSearch` succeeded).

For each non-fresh repo, ensure gitnexus is indexed and current:

1. Check if repo is indexed: `mcp__gitnexus__list_repos` → look for repo name/path match. If found, note `stats.nodes` (symbol count) and `staleness.commitsBehind`.
2. If not indexed: run `npx gitnexus analyze` on the repo. Set `GITNEXUS_INDEXED=true`.
3. If indexed but `staleness.commitsBehind > 0`: run `npx gitnexus analyze` again to refresh the index — `mcp__gitnexus__detect_changes` only *reports* staleness, it does not refresh anything, so it must not be the only action taken here. Set `GITNEXUS_INDEXED=true` after the refresh completes.
4. If indexed and fresh (`commitsBehind == 0`): `GITNEXUS_INDEXED=true`, no action needed.
5. If `--wiki` flag: generate wiki prose (optional, not required for prescan).

Record `GITNEXUS_INDEXED` (true/false) and `GITNEXUS_SYMBOL_COUNT` (from `list_repos` `stats.nodes`, or 0 if not indexed) — Step 6 writes both into `meta.json`.

If the MCP server is genuinely unreachable (not just a not-yet-loaded schema), log `hb-wrap.sh fallback "gitnexus"`, set `GITNEXUS_INDEXED=false`, and continue with partial docs (structural data from local file scan only).

---

## Step 4 — Doc generation (cadence-dependent)

Branch on cadence:

### Path A: Full fan-out (missing, decayed, or forced)

For a first-time scan or decay-prompted re-dive, spawn multiple agents in parallel, each producing one persona-specific doc file.

**You (the orchestrating session) MUST NOT write `overview.md`, `processes.md`, `security-surfaces.md`, `backend.md`, `frontend.md`, `services/*.md`, or `INDEX.md` yourself with a direct `Write`/`Edit` call.** Each of those files is produced by a spawned `Agent`, never by you directly. If you find yourself about to `Write` one of them without having spawned its persona agent first in this run, stop — spawn the agent instead. This is a hard rule, not a suggestion: skipping the fan-out defeats the reason the docs exist (persona-isolated context) and this has silently happened before.

1. **Resolve persona set** — required before any agent spawn, and log it so the run is auditable:
   ```bash
   eval $(bash "$HOME/.claude/skills/lib/persona-select.sh" \
     --repo "$repo" --phase prescan ${WITH_QA:+--with-qa})
   # PERSONA_SET contains newline-separated persona paths
   _plog "PRESCAN" "persona-select" "done" "$slug: $PERSONA_SET"
   ```

### Step 4.0 — Collect prescan corrections

Before spawning persona agents, scan recent ticket workspaces for corrections with `source=prescan`. These corrections were written by `ticket-implement` Step 4c Part 4 when a pre-scan doc contributed to a complexity mismatch — they tell persona agents what the docs got wrong last time.

```bash
source "$HOME/.claude/skills/lib/corrections-parse.sh"

_corrections_summary=""
for _ticket_dir in $(find . -maxdepth 3 -type d -name "*--*" -path "*/tickets/*" 2>/dev/null | head -20); do
  _notes_file="$_ticket_dir/notes.md"
  [ -f "$_notes_file" ] || continue
  eval $(get_corrections_by_source "$_notes_file" "prescan" 2>/dev/null) || true
  if [ "${CORRECTION_COUNT:-0}" -gt 0 ]; then
    for _i in $(seq 0 $((CORRECTION_COUNT - 1))); do
      _f_var="CORRECTION_${_i}_FACT"
      _c_var="CORRECTION_${_i}_CORRECTED"
      _corrections_summary="${_corrections_summary}  - ${!_f_var}: ${!_c_var}
"
    done
  fi
done

if [ -n "$_corrections_summary" ]; then
  _plog "PRESCAN" "corrections-collect" "done" "$slug: $(echo "$_corrections_summary" | wc -l) prescan corrections found"
else
  _plog "PRESCAN" "corrections-collect" "done" "$slug: no prescan corrections found"
fi
```

Pass `_corrections_summary` as "Known corrections" context to each persona agent in wave 1. The prompt for each agent should include:

```
**Known corrections (from prior ticket runs):**
{_corrections_summary or "None — prior prescan docs were accurate."}

Use these to avoid repeating documented mistakes. If a correction says a service list was incomplete,
verify the full service set. If it says a call chain was wrong, trace it fresh rather than trusting
the prior doc.
```

2. **Spawn content agents in parallel** (wave 1 — each writes exactly one file):
   - **Architect agent** → `overview.md`: Architecture overview, layer map, component diagram, key design decisions.
   - **Analyzer agent** → `processes.md`: Execution flows, call chains, entry points, data flow narratives.
   - **Security agent** → `security-surfaces.md`: Auth surfaces, PII locations, security-relevant endpoints, threat notes. MUST include warning header: `<!-- WARNING: This file describes security-relevant code locations. Do not commit to public repositories. -->`
   - **Backend/Frontend developer agent** → `backend.md` / `frontend.md`: Layer-specific patterns, idioms, test conventions, build structure.

   Each agent prompt includes: persona file path, repo path, assigned output file (absolute path), existing CLAUDE.md context, gitnexus data if available. Agents MUST NOT modify source, create branches, or commit.

   After dispatching wave 1, log the count so a skipped fan-out is visible in the log rather than silent: `_plog "PRESCAN" "fanout-wave1" "done" "$slug: N agents spawned"` (N must equal the number of persona docs owed for this repo — if N is lower because a persona doesn't apply, e.g. no `frontend.md` for a backend-only repo, that's fine; N being 0 is not).

3. **Wait for all wave 1 agents** to complete.

4. **Spawn technical-writer agent** (wave 2 — runs solo after all content exists):
   - **Technical writer agent** → reads all wave 1 output files, synthesizes `INDEX.md` with Lookup by Topic and Lookup by Service tables. This MUST run after wave 1 completes — it reads the other agents' files to build the index.

   Log the spawn: `_plog "PRESCAN" "fanout-wave2" "done" "$slug: technical-writer agent spawned"`.

### Path B: Incremental (stale)

For a repo where HEAD moved with source changes (but not decayed):

1. Run `prescan-docs.sh` for deterministic structure dump:
   ```bash
   bash "$HOME/.claude/skills/lib/prescan-docs.sh" \
     --repos-root "$REPOS_ROOT" --repo-slug "$slug" \
     --clusters /tmp/gitnexus-clusters.json \
     --routes /tmp/gitnexus-routes.json \
     --processes /tmp/gitnexus-processes.json \
     --update-meta
   ```

2. Spawn a single targeted agent to re-scan only the clusters affected by `CHANGED_FILES` (from freshness gate). The agent updates only the persona files whose owned clusters changed.

### Scaffold-verify gate

After doc generation (either path), run deterministic quality assertions via `prescan-verify.sh`:

```bash
bash "$HOME/.claude/skills/lib/prescan-verify.sh" \
  --docs-dir "$REPOS_ROOT/.ticket-auto/$slug/docs" \
  --cadence "$CADENCE"
_rc=$?
if [ $_rc -ne 0 ]; then
  _plog "META" "gate-stop" "fail" "PRESCAN_NO_DOCS — quality violations: $(grep PRESCAN_VERIFY_VIOLATION | wc -l)"
  hb-wrap.sh gate "prescan-scaffold" "fail" "quality violations" \
    "{\"cadence\":\"$CADENCE\",\"violations\":\"$PRESCAN_VERIFY_VIOLATIONS\"}"
  exit 1
fi
hb-wrap.sh gate "prescan-scaffold" "ok" "all docs present and valid" \
  "{\"cadence\":\"$CADENCE\"}"
```

---

## Step 5 — Build claude-mem corpus

**Mandatory for every repo scanned in this run — do not skip.** After scaffold-verify passes, build a queryable knowledge corpus for Tier 2 semantic search:

```bash
# Collect all generated doc files
DOC_FILES=$(find "$REPOS_ROOT/.ticket-auto/$slug/docs" -type f -name "*.md" | tr '\n' ',' | sed 's/,$//')

mcp__plugin_claude-mem_mcp-search__build_corpus \
  name="prescan-$slug" \
  description="Prescan knowledge for $slug: architecture, services, processes, security surfaces" \
  files="$DOC_FILES"
```

**Then verify it actually landed** — a call that doesn't error is not proof the corpus exists:

```bash
mcp__plugin_claude-mem_mcp-search__list_corpora
# confirm "prescan-$slug" is present in the result
```

Log the outcome **unconditionally** — this `_plog` call must run regardless of whether `HB_LOG_FILE` is set, because `hb_fallback` is a silent no-op outside `--from-auto` runs and is not sufficient on its own to record a skip or failure:

- Corpus confirmed present: `_plog "PRESCAN" "corpus" "done" "$slug: corpus built and verified"`
- Corpus missing after the build call, or the build call itself failed: `_plog "PRESCAN" "corpus" "fail" "$slug: corpus build failed or unverified"`, plus `hb-wrap.sh fallback "corpus-build" "fired" "corpus unavailable" '{"repo":"$slug"}'` for `--from-auto` runs.

If claude-mem MCP is genuinely unavailable, this is a degraded (not fatal) path — Tier 1 INDEX.md routing in `ticket-appraise` still works — but the degradation MUST be logged via the `_plog "fail"` line above, never silently skipped.

---

## Step 5.5 — Build cross-repo system.md index

After all repos in this scan pass complete, rebuild the cross-repo contract map at `REPOS_ROOT/.ticket-auto/system.md`. This enables appraise Step 3a.4 to resolve FE→BE API contracts for multi-repo tickets.

```bash
# Collect all per-repo INDEX.md files
INDEX_FILES=$(find "$REPOS_ROOT/.ticket-auto" -maxdepth 3 -name "INDEX.md" -path "*/docs/INDEX.md" 2>/dev/null || true)

# Build system.md
cat > "$REPOS_ROOT/.ticket-auto/system.md" <<SYSEOF
# Cross-Repo System Map

Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)

## Indexed Repos

$(for idx in $INDEX_FILES; do
  repo_slug=$(basename "$(dirname "$(dirname "$idx")")")
  echo "| $repo_slug | $idx |"
done)

## FE → BE Contract Map

<!-- Populated by automated contract detection during multi-repo scans.
     Maps frontend API calls to backend endpoint handlers across repos. -->

| Frontend (Repo) | API Call | Backend Endpoint (Repo) | Handler |
|-----------------|----------|------------------------|---------|

## Shared Types

<!-- Cross-repo type definitions and DTOs. -->

| Type | Defined In (Repo) | Consumed By (Repos) |
|------|-------------------|---------------------|
SYSEOF

_plog "PRESCAN" "system-index" "done" "system.md rebuilt from $(echo "$INDEX_FILES" | wc -l) repos"
hb-wrap.sh decision "system-index" "fired" "system.md rebuilt" "{\"repo_count\":\"$(echo "$INDEX_FILES" | wc -l)\"}"
```

The contract map table is populated by the prescan agent when it detects cross-repo API calls during fan-out. On incremental scans, only new contracts are added — existing rows are preserved.

---

## Step 6 — Write marker and wire CLAUDE.md

After successful scan:

### Write meta.json marker

**Full fan-out (missing, decayed, or forced):** update all fields including full-dive:

```bash
HEAD_SHA=$(git -C "$repo" rev-parse HEAD)
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)

cat > "$REPOS_ROOT/.ticket-auto/$slug/meta.json" <<METAEOF
{
  "schema_version": "1",
  "last_scanned_sha": "$HEAD_SHA",
  "last_scanned_at": "$NOW",
  "last_full_dive_sha": "$HEAD_SHA",
  "last_full_dive_ts": "$NOW",
  "incremental_scan_count": 0,
  "gitnexus_indexed": ${GITNEXUS_INDEXED:-false},
  "gitnexus_symbol_count": ${GITNEXUS_SYMBOL_COUNT:-0},
  "doc_count": $(find "$REPOS_ROOT/.ticket-auto/$slug/docs" -name "*.md" | wc -l)
}
METAEOF
```

**Incremental (stale):** update scanned SHA only, increment counter, preserve full-dive fields:

```bash
HEAD_SHA=$(git -C "$repo" rev-parse HEAD)
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
META_PATH="$REPOS_ROOT/.ticket-auto/$slug/meta.json"

jq --arg sha "$HEAD_SHA" --arg now "$NOW" \
  '.last_scanned_sha = $sha | .last_scanned_at = $now | .incremental_scan_count = ((.incremental_scan_count // 0) + 1)' \
  "$META_PATH" > "${META_PATH}.tmp" && mv "${META_PATH}.tmp" "$META_PATH"
```

### Wire CLAUDE.md managed block

Use the deterministic `prescan-wire-claude-md.sh` script — no LLM-written sed commands:

```bash
bash "$HOME/.claude/skills/lib/prescan-wire-claude-md.sh" \
  --claude-md "$repo/CLAUDE.md" \
  --prescan-index "$REPOS_ROOT/.ticket-auto/$slug/docs/INDEX.md" \
  --repo-slug "$slug"

_plog "PRESCAN" "wire" "done" "$slug: CLAUDE.md wired"
```

The script handles both first-time insertion (appends block) and replacement (content between START/END markers). Idempotent — running twice produces identical output. Existing surrounding content is preserved.

---

## Step 7 — Handoff

Emit the PRESCAN_RESULT block:

```
=== PRESCAN_RESULT ===
Repos processed: {N}
Results:
  {slug}: scanned — {doc_count} docs → {docs_dir}
  {slug}: skipped-fresh — head unchanged
  {slug}: failed — {error_reason}
Overall: {scanned}/{total} scanned, {skipped}/{total} skipped, {failed}/{total} failed
=== END PRESCAN_RESULT ===
```

Partial multi-repo failure is non-fatal. A failed repo scan emits `failed` and leaves that repo's appraise to degrade to Path B from-scratch tracing. Exit code is non-zero if any repo failed.

---

## Standalone maintenance sweep (proactive, ticket-independent)

Running `/ticket-prescan` with **no repo argument** already enumerates every
repo under `REPOS_ROOT` (Step 0) and, for each `stale`/`decayed`/`missing`
one, runs full cadence-dependent doc generation (Step 4) — it is not
scoped to any single ticket. That makes it the correct mechanism for
proactively refreshing repos a ticket never happens to touch. The gap is
that nothing invokes it this way: the only caller in the pipeline is
`ticket-auto`'s per-ticket "Prescan gate" (Phase 2), which runs the same
enumeration but does so once per ticket dispatch — competing with that
ticket's own budget and priorities, not on a standing schedule. In
practice most repos under `REPOS_ROOT` sit `decayed`/`missing`
indefinitely unless a ticket happens to name them directly.

To close that gap, schedule `/ticket-prescan` (bare) to run periodically,
decoupled from ticket dispatch — e.g. via the `schedule` skill or a cron
entry, at a cadence matched to `PRESCAN_DECAY_AGE_DAYS` (default 30 days).
Because a bare run always fans out a full multi-persona `Agent` spawn per
non-fresh repo, gate the (expensive) Claude invocation behind the
zero-token `prescan-sweep.sh` pre-check so a scheduled run that finds
nothing stale costs nothing beyond a few bash calls:

```bash
# Cheap, deterministic, no Agent/Claude session spawned:
bash lib/prescan-sweep.sh --repos-root "$REPOS_ROOT"
# exit 0 → everything fresh, nothing to do
# exit 1 → NEEDS_REFRESH lists repos needing a scan; only then invoke:
#   claude -p "/ticket-prescan"
```

`prescan-sweep.sh` enumerates repos the same way Step 0 does and calls
`prescan-check.sh` per repo (see that script's own freshness rules) —
it performs no doc generation itself, so it never contends for the
per-repo `.lock` used by an actual scan. `--format json` emits
`{total, fresh, stale, decayed, missing, needs_refresh}` for programmatic
callers (e.g. a fleet-controller detection engine deciding whether a
maintenance dispatch is worth spawning).

---

## Concurrency

Before writing to `REPOS_ROOT/.ticket-auto/<repo-slug>/`, acquire an exclusive lock:

```bash
LOCK_FILE="$REPOS_ROOT/.ticket-auto/$slug/.lock"
mkdir -p "$(dirname "$LOCK_FILE")"
exec {lock_fd}>"$LOCK_FILE"
if ! flock -n "$lock_fd"; then
  _plog "PRESCAN" "lock" "skip" "$slug: locked by another process"
  PRESCAN_RESULTS["$slug"]="skipped-locked"
  continue  # skip this repo, next one still runs
fi
# ... scan work ...
flock -u "$lock_fd"  # release
```

Non-blocking: skip on contention with `PRESCAN_STATUS=skipped-locked`.

**Compatibility:** `exec {lock_fd}>` (auto-allocated fd) requires bash 4.1+. macOS shipped bash 3.2 until recently — if running on an older system, replace `{lock_fd}` with a static fd number (e.g., `exec 9>"$LOCK_FILE"` and `flock -n 9`).

## RLVR Phase 0 — Verifier Result

After the prescan scaffold verification completes, record a verifier-result:
```bash
source ~/.claude/skills/lib/verifier-result.sh
# Verdict: PASS if all docs verified fresh, WARN if some stale but re-scanned,
# BLOCK if scaffold verification found structural failures
write_verifier_result \
  verifier=prescan_verify verdict=<PASS|WARN|BLOCK> \
  criteria_met=<repos-passed> criteria_total=<total-repos> \
  phase=PRESCAN
```
Called after `prescan-verify.sh` emits its scaffold check results, before the final handoff.
