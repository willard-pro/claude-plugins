#!/usr/bin/env bash
# prescan-docs.sh — deterministic graph-to-markdown distiller.
# Reads gitnexus MCP resource JSON (pre-fetched by the skill layer) and assembles
# the .ticket-auto/docs/ tree using jq. Zero LLM tokens — pure formatting.
# -u (nounset) intentionally omitted: Claude Code shell snapshots inject
# ZSH_VERSION references that trigger false-positive "unbound variable"
# errors in this bash version when nounset is active.
set -eo pipefail

if ! command -v jq &>/dev/null; then
  echo "ERROR: jq is required but not installed. Install jq and retry." >&2
  exit 3
fi

_PD_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_PD_LIB_DIR="${CLAUDE_SKILLS_LIB:-$HOME/.claude/skills/lib}"
if [ -f "$_PD_LIB_DIR/heartbeat.sh" ]; then
  source "$_PD_LIB_DIR/heartbeat.sh"
fi

# ── Usage ─────────────────────────────────────────────────────────────────────

usage() {
  cat >&2 <<'EOF'
Usage: prescan-docs.sh --repos-root <path> --repo-slug <slug> [options]

Assembles .ticket-auto/<slug>/docs/ from gitnexus JSON inputs.

Input options (at least one required):
  --clusters <file>     JSON file with gitnexus cluster/community data
  --routes <file>       JSON file with gitnexus route_map data
  --processes <file>    JSON file with gitnexus process data
  --tools <file>        JSON file with gitnexus tool_map data

Output options:
  --repos-root <path>   Path to REPOS_ROOT (required)
  --repo-slug <slug>    Repo slug for subdirectory (required)
  --update-meta          Update meta.json gitnexus stats after writing

Flags:
  --help, -h            Show this help
EOF
  exit 1
}

# ── Helpers ────────────────────────────────────────────────────────────────────

_hb_fallback() {
  local section="$1" reason="${2:-unavailable}"
  if command -v hb_fallback &>/dev/null; then
    hb_fallback "prescan-docs" "fired" "$section: $reason" "{\"section\":\"$section\"}"
  fi
}

# Ensure a directory exists
_ensure_dir() {
  local dir="$1"
  mkdir -p "$dir"
}

# Write a file idempotently — only overwrite if content differs
_write_if_changed() {
  local path="$1" content="$2"
  local tmp="${path}.tmp.$$"
  echo "$content" > "$tmp"
  if [ -f "$path" ] && cmp -s "$tmp" "$path" 2>/dev/null; then
    rm -f "$tmp"
    return 0
  fi
  mv "$tmp" "$path"
  return 0
}

# ── Section writers ────────────────────────────────────────────────────────────

# Write services/*.md from cluster data
_write_services() {
  local docs_dir="$1" clusters_file="$2"

  if [ ! -f "$clusters_file" ] || [ ! -s "$clusters_file" ]; then
    _hb_fallback "services" "no cluster data"
    local services_dir="$docs_dir/services"
    _ensure_dir "$services_dir"
    cat > "$services_dir/.placeholder.md" <<'MD'
# Services

No gitnexus cluster data available. Services documentation will be generated
when gitnexus indexing is complete. Run `npx gitnexus analyze` on this repo.
MD
    return 0
  fi

  local services_dir="$docs_dir/services"
  _ensure_dir "$services_dir"
  rm -f "$services_dir/.placeholder.md"

  # Extract clusters from JSON — expects array of {name, description, symbols, ...}
  # Write one .md per cluster
  jq -c '.[]' "$clusters_file" 2>/dev/null | while IFS= read -r cluster; do
    local name desc symbols
    name=$(echo "$cluster" | jq -r '.name // .heuristicLabel // "unknown"' 2>/dev/null || echo "unknown")
    desc=$(echo "$cluster" | jq -r '.description // ""' 2>/dev/null || echo "")
    symbols=$(echo "$cluster" | jq -r '.symbols // [] | map(.name) | join(", ")' 2>/dev/null || echo "")

    # Sanitize name for filename
    local safe_name
    safe_name=$(echo "$name" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | sed 's/--*/-/g')

    _write_if_changed "$services_dir/${safe_name}.md" "# $name

${desc:+

$desc}

## Entry Points

${symbols:+$symbols}

## Dependencies

<!-- Populated by prescan agent during fan-out -->
"
  done
}

# Write routes.md from route_map data
_write_routes() {
  local docs_dir="$1" routes_file="$2"

  if [ ! -f "$routes_file" ] || [ ! -s "$routes_file" ]; then
    _hb_fallback "routes" "no route_map data"
    cat > "$docs_dir/routes.md" <<'MD'
# API Routes

| Route | Method | Handler | Middleware |
|-------|--------|---------|------------|

No route data available. Routes will be populated when gitnexus indexing is complete.
MD
    return 0
  fi

  local content
  content=$(jq -r '
    "# API Routes\n\n",
    "| Route | Method | Handler | Middleware |\n",
    "|-------|--------|---------|------------|\n",
    (.[]? | "| \(.route // .path // "?") | \(.methods // .method // "?") | \(.handler // "?") | \(.middleware // [] | join(", ") // "") |\n")
  ' "$routes_file" 2>/dev/null || true)

  if [ -z "$content" ] || [ "$content" = "# API Routes

| Route | Method | Handler | Middleware |
|-------|--------|---------|------------|
" ]; then
    _hb_fallback "routes" "empty route data"
    content=$(cat <<'MD'
# API Routes

| Route | Method | Handler | Middleware |
|-------|--------|---------|------------|

No route data extracted from gitnexus.
MD
)
  fi

  _write_if_changed "$docs_dir/routes.md" "$content"
}

# Write processes.md skeleton from process data
_write_processes() {
  local docs_dir="$1" processes_file="$2"

  if [ ! -f "$processes_file" ] || [ ! -s "$processes_file" ]; then
    _hb_fallback "processes" "no process data"
    cat > "$docs_dir/processes.md" <<'MD'
# Execution Processes

| Process | Steps | Entry Point |
|---------|-------|-------------|

No process data available. Processes will be populated during agent fan-out.
MD
    return 0
  fi

  local content
  content=$(jq -r '
    "# Execution Processes\n\n",
    "| Process | Steps | Entry Point |\n",
    "|---------|-------|-------------|\n",
    (.[]? | "| \(.name // .heuristicLabel // "?") | \(.symbols | length // 0) | \(.entryPoint // .symbols[0].name // "?") |\n")
  ' "$processes_file" 2>/dev/null || true)

  if [ -z "$content" ]; then
    _hb_fallback "processes" "empty process data"
    return 0
  fi

  _write_if_changed "$docs_dir/processes.md" "$content"
}

# Write INDEX.md with lookup tables
# This is the critical file: appraise Step 3a reads it for Tier 1 routing.
_write_index() {
  local docs_dir="$1"

  local services_dir="$docs_dir/services"
  local topic_entries=""
  local service_entries=""

  # Build Lookup by Topic from doc files
  if [ -d "$services_dir" ] && [ -n "$(ls -A "$services_dir" 2>/dev/null)" ]; then
    for f in "$services_dir"/*.md; do
      [ -f "$f" ] || continue
      local basename service_name
      basename=$(basename "$f" .md)
      service_name=$(head -1 "$f" 2>/dev/null | sed 's/^# //' || echo "$basename")
      topic_entries="${topic_entries}| ${service_name} | services/${basename}.md |\n"
      service_entries="${service_entries}| ${service_name} | services/${basename}.md |\n"
    done
  fi

  # Add processes
  if [ -f "$docs_dir/processes.md" ]; then
    topic_entries="${topic_entries}| Processes | processes.md |\n"
    service_entries="${service_entries}| Processes | processes.md |\n"
  fi

  # Add routes
  if [ -f "$docs_dir/routes.md" ]; then
    topic_entries="${topic_entries}| API Routes | routes.md |\n"
    service_entries="${service_entries}| API Routes | routes.md |\n"
  fi

  # Add overview
  if [ -f "$docs_dir/overview.md" ]; then
    topic_entries="${topic_entries}| Architecture Overview | overview.md |\n"
  fi

  # Add security surfaces
  if [ -f "$docs_dir/security-surfaces.md" ]; then
    topic_entries="${topic_entries}| Security | security-surfaces.md |\n"
  fi

  if [ -z "$topic_entries" ]; then
    topic_entries="| (no entries yet) | |\n"
  fi
  if [ -z "$service_entries" ]; then
    service_entries="| (no entries yet) | |\n"
  fi

  local content
  content=$(printf '%s\n' \
    "# Prescan Index — $(basename "$(dirname "$docs_dir")")" \
    "" \
    "## Lookup by Topic" \
    "" \
    "| Topic | File |" \
    "|-------|------|" \
    "$(printf '%b' "$topic_entries")" \
    "" \
    "## Lookup by Service" \
    "" \
    "| Service | File |" \
    "|---------|------|" \
    "$(printf '%b' "$service_entries")" \
  )

  _write_if_changed "$docs_dir/INDEX.md" "$content"
}

# ── Meta update ────────────────────────────────────────────────────────────────

_update_meta() {
  local meta_path="$1"
  local symbol_count="${2:-0}"
  local indexed="${3:-true}"

  if [ ! -f "$meta_path" ]; then
    return 0
  fi

  local tmp="${meta_path}.tmp.$$"
  jq --argjson sc "$symbol_count" --argjson idx "$indexed" \
    '. + {gitnexus_indexed: $idx, gitnexus_symbol_count: $sc}' \
    "$meta_path" > "$tmp" 2>/dev/null || true

  if [ -s "$tmp" ]; then
    mv "$tmp" "$meta_path"
  else
    rm -f "$tmp"
  fi
}

# ── Main ───────────────────────────────────────────────────────────────────────

main() {
  local repos_root="" repo_slug="" clusters_file="" routes_file="" processes_file="" tools_file=""
  local update_meta="false"

  while [[ $# -gt 0 ]]; do
    case "$1" in
    --repos-root)
      repos_root="${2:-}"; shift 2 ;;
    --repo-slug)
      repo_slug="${2:-}"; shift 2 ;;
    --clusters)
      clusters_file="${2:-}"; shift 2 ;;
    --routes)
      routes_file="${2:-}"; shift 2 ;;
    --processes)
      processes_file="${2:-}"; shift 2 ;;
    --tools)
      tools_file="${2:-}"; shift 2 ;;
    --update-meta)
      update_meta="true"; shift ;;
    --help | -h)
      usage ;;
    *)
      echo "Unknown flag: $1" >&2; usage ;;
    esac
  done

  if [ -z "$repos_root" ] || [ -z "$repo_slug" ]; then
    echo "ERROR: --repos-root and --repo-slug are required" >&2
    usage
  fi

  local docs_dir="$repos_root/.ticket-auto/$repo_slug/docs"
  local meta_path="$repos_root/.ticket-auto/$repo_slug/meta.json"

  _ensure_dir "$docs_dir"
  _ensure_dir "$docs_dir/services"

  # Write structural docs from available gitnexus data
  if [ -n "$clusters_file" ]; then
    _write_services "$docs_dir" "$clusters_file"
  fi

  if [ -n "$routes_file" ]; then
    _write_routes "$docs_dir" "$routes_file"
  fi

  if [ -n "$processes_file" ]; then
    _write_processes "$docs_dir" "$processes_file"
  fi

  # Always rebuild INDEX.md from what we have
  _write_index "$docs_dir"

  # Update meta if requested
  if [ "$update_meta" = "true" ]; then
    local symbol_count=0
    if [ -n "$clusters_file" ] && [ -f "$clusters_file" ]; then
      symbol_count=$(jq '[.[]?.symbols? // [] | length] | add // 0' "$clusters_file" 2>/dev/null || echo "0")
    fi
    _update_meta "$meta_path" "$symbol_count"
  fi

  printf "PRESCAN_DOCS_STATUS='%s'\n" "done"
  printf "PRESCAN_DOCS_DIR='%s'\n" "$docs_dir"
}

# ── Dispatch ───────────────────────────────────────────────────────────────────

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
