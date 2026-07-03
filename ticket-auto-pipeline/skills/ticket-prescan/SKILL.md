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
PRESCAN_LOG="$HOME/.claude/logs/prescan-<repo-slug>.log"
_plog() { echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|$1|$2|$3|$4" >> "$PRESCAN_LOG"; }
```

## Heartbeat

- **Freshness gate**: `hb_decision "prescan-gate" "fired" "<status>:<reason>" '{"status":"...","reason":"..."}'`
- **Fallback**: if gitnexus unavailable, `hb_fallback "gitnexus" "fired" "gitnexus MCP unavailable" '{"section":"..."}'`
- **Corpus build**: if corpus build fails, `hb_fallback "corpus-build" "fired" "corpus unavailable" '{"repo":"<slug>"}'`
- **Scaffold verify**: `hb_gate "prescan-scaffold" "<ok|fail>" "<msg>" '{"docs_dir":"..."}'`

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

  hb_decision "prescan-gate" "fired" "$PRESCAN_STATUS:$PRESCAN_REASON" \
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

For each non-fresh repo, ensure gitnexus is indexed:

1. Check if repo is indexed: `mcp__gitnexus__list_repos` → look for repo name.
2. If not indexed: run `npx gitnexus analyze` on the repo.
3. If indexed but stale: `mcp__gitnexus__detect_changes` to confirm freshness.
4. If `--wiki` flag: generate wiki prose (optional, not required for prescan).

If gitnexus MCP is unavailable, log `hb_fallback "gitnexus"` and continue with partial docs (structural data from local file scan only).

---

## Step 4 — Doc generation (cadence-dependent)

Branch on cadence:

### Path A: Full fan-out (missing, decayed, or forced)

For a first-time scan or decay-prompted re-dive, spawn multiple agents in parallel, each producing one persona-specific doc file.

1. **Resolve persona set**:
   ```bash
   eval $(bash "$HOME/.claude/skills/lib/persona-select.sh" \
     --repo "$repo" --phase prescan ${WITH_QA:+--with-qa})
   # PERSONA_SET contains newline-separated persona paths
   ```

2. **Spawn content agents in parallel** (wave 1 — each writes exactly one file):
   - **Architect agent** → `overview.md`: Architecture overview, layer map, component diagram, key design decisions.
   - **Analyzer agent** → `processes.md`: Execution flows, call chains, entry points, data flow narratives.
   - **Security agent** → `security-surfaces.md`: Auth surfaces, PII locations, security-relevant endpoints, threat notes. MUST include warning header: `<!-- WARNING: This file describes security-relevant code locations. Do not commit to public repositories. -->`
   - **Backend/Frontend developer agent** → `backend.md` / `frontend.md`: Layer-specific patterns, idioms, test conventions, build structure.

   Each agent prompt includes: persona file path, repo path, assigned output file (absolute path), existing CLAUDE.md context, gitnexus data if available. Agents MUST NOT modify source, create branches, or commit.

3. **Wait for all wave 1 agents** to complete.

4. **Spawn technical-writer agent** (wave 2 — runs solo after all content exists):
   - **Technical writer agent** → reads all wave 1 output files, synthesizes `INDEX.md` with Lookup by Topic and Lookup by Service tables. This MUST run after wave 1 completes — it reads the other agents' files to build the index.

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
  hb_gate "prescan-scaffold" "fail" "quality violations" \
    "{\"cadence\":\"$CADENCE\",\"violations\":\"$PRESCAN_VERIFY_VIOLATIONS\"}"
  exit 1
fi
hb_gate "prescan-scaffold" "ok" "all docs present and valid" \
  "{\"cadence\":\"$CADENCE\"}"
```

---

## Step 5 — Build claude-mem corpus

After scaffold-verify passes, build a queryable knowledge corpus for Tier 2 semantic search:

```bash
# Collect all generated doc files
DOC_FILES=$(find "$REPOS_ROOT/.ticket-auto/$slug/docs" -type f -name "*.md" | tr '\n' ',' | sed 's/,$//')

# Build corpus (non-blocking)
mcp__plugin_claude-mem_mcp-search__build_corpus \
  name="prescan-$slug" \
  description="Prescan knowledge for $slug: architecture, services, processes, security surfaces" \
  files="$DOC_FILES" \
  || hb_fallback "corpus-build" "fired" "corpus build failed, Tier 2 search unavailable" \
       "{\"repo\":\"$slug\"}"

_plog "PRESCAN" "corpus" "done" "$slug: corpus built"
```

If claude-mem MCP is unavailable, log `hb_fallback` and continue — Tier 1 INDEX.md routing still works.

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
hb_decision "system-index" "fired" "system.md rebuilt" "{\"repo_count\":\"$(echo "$INDEX_FILES" | wc -l)\"}"
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
  "gitnexus_indexed": true,
  "gitnexus_symbol_count": 0,
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
