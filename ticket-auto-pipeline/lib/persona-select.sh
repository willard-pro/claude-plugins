#!/usr/bin/env bash
# persona-select.sh — deterministic base+specializer persona selector.
# Given a repo path, layer classification, and pipeline phase, emits the
# correct persona file paths. Zero LLM involvement. Follows the gate-check.sh
# philosophy: if a decision can be made deterministically, bash is the answer.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Resolve personas dir relative to plugin root (available in agent spawns), with
# fallback to script-relative for local dev/testing. Follows the same pattern as
# gate-check.sh and notes-parse.sh which use ${CLAUDE_PLUGIN_ROOT:-<fallback>}.
PERSONAS_DIR="${CLAUDE_PLUGIN_ROOT:-$SCRIPT_DIR/..}/personas"

# ── Usage ──────────────────────────────────────────────────────────────────────

usage() {
  cat >&2 <<'EOF'
Usage: persona-select.sh --repo <path> [--layer FE|BE|infra] [--phase appraise|implement|review|audit|prescan] [--with-qa]

Emits persona file paths as KEY=value lines:
  PERSONA_BASE=personas/base/<role>.md
  PERSONA_SPECIALIZER=personas/specializers/<group>/<stack>.md   (empty if none matches)
  PERSONA_AUTO_INCLUDE=personas/base/security.md                (empty if no trigger)
  PERSONA_SET=<newline-separated paths>                          (prescan phase only)

Options:
  --repo <path>      Path to the affected repository (required)
  --layer <value>    Layer classification: FE, BE, infra (optional)
  --phase <value>    Pipeline phase: appraise, implement, review, audit, prescan (optional)
  --with-qa          Include qa-engineer in prescan persona set (prescan phase only)
EOF
  exit 1
}

# ── Flag parsing ───────────────────────────────────────────────────────────────

REPO=""
LAYER=""
PHASE=""
WITH_QA="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
  --repo)
    REPO="${2:-}"
    shift 2
    ;;
  --layer)
    LAYER="${2:-}"
    shift 2
    ;;
  --phase)
    PHASE="${2:-}"
    shift 2
    ;;
  --with-qa)
    WITH_QA="true"
    shift
    ;;
  --help | -h)
    usage
    ;;
  *)
    echo "Unknown flag: $1" >&2
    usage
    ;;
  esac
done

# ── Validation ─────────────────────────────────────────────────────────────────

if [ -z "$REPO" ]; then
  echo "ERROR: --repo is required" >&2
  usage
fi

# Validate --layer if provided
if [ -n "$LAYER" ]; then
  case "$LAYER" in
  FE | BE | infra) ;;
  *)
    echo "ERROR: Invalid --layer value '$LAYER'. Must be FE, BE, or infra." >&2
    exit 1
    ;;
  esac
fi

# Validate --phase if provided
if [ -n "$PHASE" ]; then
  case "$PHASE" in
  appraise | implement | review | audit | prescan) ;;
  *)
    echo "ERROR: Invalid --phase value '$PHASE'. Must be appraise, implement, review, audit, or prescan." >&2
    exit 1
    ;;
  esac
fi

# ── Helper: resolve persona path relative to plugin root ───────────────────────

_persona_path() {
  # Given a relative path like "base/analyzer.md", output the full path
  # relative to the personas directory. If the file doesn't exist, output empty.
  local rel="$1"
  if [ -f "$PERSONAS_DIR/$rel" ]; then
    echo "$PERSONAS_DIR/$rel"
  else
    echo ""
  fi
}

# ── Base persona selection ─────────────────────────────────────────────────────

select_base() {
  # Phase takes priority over layer for base selection.
  # If no phase and no layer, default to analyzer (safest universal role).
  case "${PHASE:-}" in
  appraise | review)
    echo "analyzer"
    return
    ;;
  audit)
    echo "product-owner"
    return
    ;;
  implement)
    case "${LAYER:-}" in
    FE)
      echo "frontend-developer"
      return
      ;;
    BE | infra)
      echo "backend-developer"
      return
      ;;
    *)
      # implement phase without layer — default to backend-developer
      echo "backend-developer"
      return
      ;;
    esac
    ;;
  *)
    # No phase — use layer if available
    case "${LAYER:-}" in
    FE)
      echo "frontend-developer"
      return
      ;;
    BE | infra)
      echo "backend-developer"
      return
      ;;
    *)
      echo "analyzer"
      return
      ;;
    esac
    ;;
  esac
}

# ── Specializer detection ──────────────────────────────────────────────────────

probe_file() { [ -f "$REPO/$1" ] && return 0 || return 1; }
probe_dep() { [ -f "$REPO/package.json" ] && grep -q "\"$1\"" "$REPO/package.json" 2>/dev/null && return 0 || return 1; }

# Detect migration/upgrade intent from ticket text (explicit user signal).
# The user must state they are upgrading/migrating — this is NOT heuristic version detection.
has_migration_keywords() {
  local haystack=""
  if [ -n "${TICKET_TITLE:-}" ]; then haystack="$haystack $TICKET_TITLE"; fi
  if [ -n "${TICKET_DESCRIPTION:-}" ]; then haystack="$haystack $TICKET_DESCRIPTION"; fi
  if [ -n "${TICKET_TEXT_FILE:-}" ] && [ -f "$TICKET_TEXT_FILE" ]; then
    haystack="$haystack $(cat "$TICKET_TEXT_FILE" 2>/dev/null || true)"
  fi
  if [ -z "$haystack" ]; then return 1; fi
  echo "$haystack" | grep -qiE '\b(upgrade|migration|migrate|bump.*version|version.*bump|java\s*[0-9]+\s*→|java\s*[0-9]+\s*->|java\s*[0-9]+\s*to)\b' && return 0 || return 1
}

# Detect refactor/restructuring intent from ticket text (explicit user signal).
# The user must state they are refactoring with NO business logic changes.
has_refactor_keywords() {
  local haystack=""
  if [ -n "${TICKET_TITLE:-}" ]; then haystack="$haystack $TICKET_TITLE"; fi
  if [ -n "${TICKET_DESCRIPTION:-}" ]; then haystack="$haystack $TICKET_DESCRIPTION"; fi
  if [ -n "${TICKET_TEXT_FILE:-}" ] && [ -f "$TICKET_TEXT_FILE" ]; then
    haystack="$haystack $(cat "$TICKET_TEXT_FILE" 2>/dev/null || true)"
  fi
  if [ -z "$haystack" ]; then return 1; fi
  echo "$haystack" | grep -qiE '\b(refactor|refactoring|restructur\w*|clean\s*up|improve\s+structure|code\s+quality|technical\s+debt|pay\s+down\s+debt)\b' && return 0 || return 1
}

select_specializer() {
  local layer="${LAYER:-}"
  local phase="${PHASE:-}"

  # Backend stack signals
  if [ "$layer" = "BE" ] || [ "$layer" = "infra" ]; then
    # Python detection
    if probe_file "pyproject.toml" || probe_file "requirements.txt" || probe_file "poetry.lock"; then
      if has_refactor_keywords; then
        echo "specializers/backend/python-refactor.md"
        return
      fi
      echo "specializers/backend/python.md"
      return
    fi
    # Check BE_TEST_RUNNER for pyenv/pipenv signals
    if [ -n "${BE_TEST_RUNNER:-}" ]; then
      if echo "$BE_TEST_RUNNER" | grep -qiE "pyenv|pipenv|poetry"; then
        if has_refactor_keywords; then
          echo "specializers/backend/python-refactor.md"
          return
        fi
        echo "specializers/backend/python.md"
        return
      fi
    fi

    # Java detection — migration > refactor > standard priority
    if probe_file "pom.xml" || probe_file "build.gradle" || probe_file "build.gradle.kts" || probe_file "settings.gradle"; then
      if has_migration_keywords; then
        echo "specializers/backend/java-migration.md"
        return
      fi
      if has_refactor_keywords; then
        echo "specializers/backend/java-refactor.md"
        return
      fi
      echo "specializers/backend/java.md"
      return
    fi

    # Node.js detection (package.json without FE framework markers)
    if probe_file "package.json"; then
      if ! probe_dep "angular" && ! probe_dep "react" && ! probe_dep "vue" && ! probe_file "angular.json"; then
        if has_refactor_keywords; then
          echo "specializers/backend/node-refactor.md"
          return
        fi
        echo "specializers/backend/node.md"
        return
      fi
    fi
  fi

  # Frontend stack signals
  if [ "$layer" = "FE" ]; then
    # Angular detection (strongest signal — dedicated config file)
    if probe_file "angular.json"; then
      echo "specializers/frontend/angular.md"
      return
    fi

    # React detection
    if probe_file "package.json"; then
      if grep -qE '"react"|"react-dom"' "$REPO/package.json" 2>/dev/null; then
        echo "specializers/frontend/react.md"
        return
      fi
    fi

    # Vue detection
    if probe_file "package.json"; then
      if grep -q '"vue"' "$REPO/package.json" 2>/dev/null; then
        echo "specializers/frontend/vue.md"
        return
      fi
    fi
  fi

  # Architect specializers — only when explicit multi-service signals detected
  if [ "$layer" = "infra" ] || { [ "$layer" = "BE" ] && [ "$phase" = "implement" ]; }; then
    # Check for multi-service structure
    local svc_dirs
    svc_dirs=$(find "$REPO" -maxdepth 2 -type d -name "services" -o -name "apps" -o -name "packages" 2>/dev/null | head -1 || true)
    if [ -n "$svc_dirs" ]; then
      echo "specializers/architect/microservices.md"
      return
    fi
    # Check for docker-compose with multiple services
    if [ -f "$REPO/docker-compose.yml" ] || [ -f "$REPO/docker-compose.yaml" ]; then
      local svc_count
      svc_count=$(grep -cE '^\s{2}\w+:' "$REPO/docker-compose.yml" 2>/dev/null || echo "0")
      if [ "${svc_count:-0}" -gt 2 ] 2>/dev/null; then
        echo "specializers/architect/microservices.md"
        return
      fi
    fi
    # Single service with architect context → monolith
    if [ -f "$REPO/Dockerfile" ] || [ -f "$REPO/Makefile" ] || [ "$layer" = "infra" ]; then
      echo "specializers/architect/monolith.md"
      return
    fi
  fi

  # No specializer matched
  echo ""
}

# ── Auto-include detection ─────────────────────────────────────────────────────

select_auto_include() {
  # Check if security keywords appear in ticket context.
  # We probe: TICKET_TITLE, TICKET_DESCRIPTION env vars, or a temp file.
  local haystack=""

  if [ -n "${TICKET_TITLE:-}" ]; then
    haystack="$haystack $TICKET_TITLE"
  fi
  if [ -n "${TICKET_DESCRIPTION:-}" ]; then
    haystack="$haystack $TICKET_DESCRIPTION"
  fi
  # Also check a temp file if TICKET_TEXT_FILE is set
  if [ -n "${TICKET_TEXT_FILE:-}" ] && [ -f "$TICKET_TEXT_FILE" ]; then
    haystack="$haystack $(cat "$TICKET_TEXT_FILE" 2>/dev/null || true)"
  fi

  if [ -z "$haystack" ]; then
    echo ""
    return
  fi

  # Case-insensitive keyword match for security-sensitive terms
  if echo "$haystack" | grep -qiE '\b(auth|authentication|authorization|login|password|credential|token|payment|billing|PII|personal.data|encryption|vulnerability)\b'; then
    echo "base/security.md"
    return
  fi

  echo ""
}

# ── Prescan persona set ────────────────────────────────────────────────────────

# For prescan, we fan out multiple agents in parallel — each with a different
# persona lens. This function emits the complete set of persona file paths.
select_prescan_set() {
  local layer="${LAYER:-}"
  local prescan_personas=()

  # Always include these four lenses
  prescan_personas+=("architect")
  prescan_personas+=("analyzer")
  prescan_personas+=("security")
  prescan_personas+=("technical-writer")

  # Layer-driven developer persona
  case "$layer" in
  FE)
    prescan_personas+=("frontend-developer")
    ;;
  BE | infra)
    prescan_personas+=("backend-developer")
    ;;
  *)
    # Unknown layer — include both frontend and backend
    prescan_personas+=("backend-developer")
    prescan_personas+=("frontend-developer")
    ;;
  esac

  # Optional QA engineer
  if [ "$WITH_QA" = "true" ]; then
    prescan_personas+=("qa-engineer")
  fi

  # Emit each persona as a base path, with specializer if available
  local first=true
  local persona_set=""
  for role in "${prescan_personas[@]}"; do
    local base_path specializer_path persona_entry
    base_path=$(_persona_path "base/${role}.md")
    if [ -z "$base_path" ]; then
      continue  # skip missing persona files
    fi

    persona_entry="$base_path"

    # Attach specializer only for developer personas (backend/frontend)
    case "$role" in
    backend-developer | frontend-developer)
      # Temporarily set LAYER for specializer detection
      local saved_layer="$LAYER"
      LAYER="${role%*-developer}"  # "backend" or "frontend"
      # Upper-case for the LAYER variable check in select_specializer
      if [ "$LAYER" = "backend" ]; then LAYER="BE"; fi
      if [ "$LAYER" = "frontend" ]; then LAYER="FE"; fi
      specializer_path=$(_persona_path "$(select_specializer)")
      LAYER="$saved_layer"
      if [ -n "$specializer_path" ]; then
        persona_entry="${persona_entry}|${specializer_path}"
      fi
      ;;
    esac

    if [ "$first" = "true" ]; then
      persona_set="$persona_entry"
      first=false
    else
      persona_set="${persona_set}
${persona_entry}"
    fi
  done

  echo "$persona_set"
}

# ── Main ───────────────────────────────────────────────────────────────────────

main() {
  local base_role base_path specializer specializer_path auto_include auto_path

  # ── Prescan phase: emit persona set for multi-agent fan-out ────────────────
  if [ "$PHASE" = "prescan" ]; then
    local persona_set
    persona_set=$(select_prescan_set)
    if [ -z "$persona_set" ]; then
      echo "ERROR: No persona files found for prescan phase" >&2
      exit 2
    fi
    echo "PERSONA_SET=$persona_set"
    echo "PERSONA_BASE="
    echo "PERSONA_SPECIALIZER="
    echo "PERSONA_AUTO_INCLUDE="
    return
  fi

  base_role=$(select_base)
  base_path=$(_persona_path "base/${base_role}.md")

  if [ -z "$base_path" ]; then
    echo "ERROR: Base persona file not found: personas/base/${base_role}.md" >&2
    exit 2
  fi

  specializer=$(select_specializer)
  specializer_path=""
  if [ -n "$specializer" ]; then
    specializer_path=$(_persona_path "$specializer")
    # If the specializer file doesn't exist, silently fall back to empty
  fi

  auto_include=$(select_auto_include)
  auto_path=""
  if [ -n "$auto_include" ]; then
    auto_path=$(_persona_path "$auto_include")
  fi

  # Emit results as KEY=value — the stable contract for consuming skills
  echo "PERSONA_BASE=$base_path"
  echo "PERSONA_SPECIALIZER=${specializer_path:-}"
  echo "PERSONA_AUTO_INCLUDE=${auto_path:-}"
}

main
