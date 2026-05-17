#!/usr/bin/env bash
# ticket-env-check — validates all env vars and config required by ticket-auto-pipeline.
# Derives sensible defaults where possible (git config, GH_TOKEN = GITHUB_PERSONAL_ACCESS_TOKEN).
#
# Usage: env-check.sh [PROJECT_DIR]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="${1:-$(pwd)}"
cd "$PROJECT_DIR"

issues=0
warns=0
declare -A PROPOSED
ENV_FIXES=""
CMD_FIXES=""

# ── Helpers ────────────────────────────────────────────────────────────────

found() { printf "  ✅ %-35s %s\n" "$1" "$2"; }
miss()  {
  local var="$1" detail="$2" proposed="${3:-}"
  printf "  ❌ %-35s %s\n" "$var" "$detail"
  if [ -n "$proposed" ]; then
    PROPOSED["$var"]="$proposed"
    ENV_FIXES+="    \"$var\": \"$proposed\","$'\n'
  else
    ENV_FIXES+="    \"$var\": \"<your-value>\","$'\n'
  fi
  issues=$((issues + 1))
}
warn()  { printf "  ⚠️  %-35s %s\n" "$1" "$2"; warns=$((warns + 1)); }

# Derive git config values from the project directory
GIT_NAME="$(cd "$PROJECT_DIR" && git config user.name 2>/dev/null || true)"
GIT_EMAIL="$(cd "$PROJECT_DIR" && git config user.email 2>/dev/null || true)"

echo ""
echo "=== ticket-auto-pipeline v0.2.3 ==="
echo ""

# ── API keys ────────────────────────────────────────────────────────────────

echo "API keys:"
[ -n "${LINEAR_API_KEY:-}" ]       && found "LINEAR_API_KEY" "set" \
                                   || miss "LINEAR_API_KEY" "required - add to ~/.claude/settings.local.json env"
[ -n "${ANTHROPIC_AUTH_TOKEN:-}" ] && found "ANTHROPIC_AUTH_TOKEN" "set" \
                                   || miss "ANTHROPIC_AUTH_TOKEN" "required - add to ~/.claude/settings.local.json env"

# GitHub token
if [ -n "${GITHUB_PERSONAL_ACCESS_TOKEN:-}" ]; then
  found "GITHUB_PERSONAL_ACCESS_TOKEN" "set"
  if [ -z "${GH_TOKEN:-}" ]; then
    warn "GH_TOKEN" "not set - add to env as copy of GITHUB_PERSONAL_ACCESS_TOKEN"; PROPOSED["GH_TOKEN"]="(same as GITHUB_PERSONAL_ACCESS_TOKEN)"
  else
    found "GH_TOKEN" "set"
  fi
else
  miss "GITHUB_PERSONAL_ACCESS_TOKEN" "required - add to ~/.claude/settings.local.json env"
  [ -z "${GH_TOKEN:-}" ] && warn "GH_TOKEN" "also not set"
fi

# ── Optional env ────────────────────────────────────────────────────────────

echo ""
echo "Optional env:"
[ -n "${ANTHROPIC_BASE_URL:-}" ]   && found "ANTHROPIC_BASE_URL" "set" \
                                   || warn "ANTHROPIC_BASE_URL" "not set (using default)"
[ -n "${ANTHROPIC_MODEL:-}" ]      && found "ANTHROPIC_MODEL" "set" \
                                   || warn "ANTHROPIC_MODEL" "not set (using default)"

# Git author
if [ -n "${GIT_AUTHOR_NAME:-}" ]; then
  found "GIT_AUTHOR_NAME" "set"
else
  if [ -n "$GIT_NAME" ]; then
    warn "GIT_AUTHOR_NAME" "not set, propose: $GIT_NAME"
    PROPOSED["GIT_AUTHOR_NAME"]="$GIT_NAME"
  else
    warn "GIT_AUTHOR_NAME" "not set - run: git config user.name"
  fi
fi

if [ -n "${GIT_AUTHOR_EMAIL:-}" ]; then
  found "GIT_AUTHOR_EMAIL" "set"
else
  if [ -n "$GIT_EMAIL" ]; then
    warn "GIT_AUTHOR_EMAIL" "not set, propose: $GIT_EMAIL"
    PROPOSED["GIT_AUTHOR_EMAIL"]="$GIT_EMAIL"
  else
    warn "GIT_AUTHOR_EMAIL" "not set - run: git config user.email"
  fi
fi

# TICKET_AUTONOMY
if [ -n "${TICKET_AUTONOMY:-}" ]; then
  found "TICKET_AUTONOMY" "set to '$TICKET_AUTONOMY'"
else
  DOTENV_VAL=$(grep -oP '^TICKET_AUTONOMY=\K.*' "$PROJECT_DIR/.env" 2>/dev/null || true)
  if [ -n "$DOTENV_VAL" ]; then
    warn "TICKET_AUTONOMY" "not in env (found in .env: $DOTENV_VAL) - copy to settings.local.json env"
    PROPOSED["TICKET_AUTONOMY"]="$DOTENV_VAL"
  else
    warn "TICKET_AUTONOMY" "not set (defaults to manual)"
  fi
fi

# UAT_URL — required by ticket-verify (aborts if absent), no derivation
if [ -n "${UAT_URL:-}" ]; then
  found "UAT_URL" "set in env"
elif grep -qi 'UAT_URL.*https\?://' "$PROJECT_DIR/CLAUDE.md" 2>/dev/null; then
  UAT_CLAUDE=$(grep -oP '^UAT_URL[=:]\s*\K.*' "$PROJECT_DIR/CLAUDE.md" | head -1 | tr -d ' ' || true)
  found "UAT_URL" "$UAT_CLAUDE (from CLAUDE.md)"
else
  miss "UAT_URL" "not set — required by ticket-verify for UAT environment checks"
fi

# ── CLAUDE.md fields ────────────────────────────────────────────────────────

echo ""
echo "CLAUDE.md:"

if [ ! -f "$PROJECT_DIR/CLAUDE.md" ]; then
  printf "  ❌ %-35s %s\n" "CLAUDE.md" "not found at $PROJECT_DIR/CLAUDE.md"
  issues=$((issues + 1))
else
  # REPOS_ROOT — walk up looking for directory with multiple repos (git dirs or CLAUDE.md files)
  if grep -q '^REPOS_ROOT[=:]\s*.' "$PROJECT_DIR/CLAUDE.md" 2>/dev/null; then
    VAL=$(grep -oP '^REPOS_ROOT[=:]\s*\K.*' "$PROJECT_DIR/CLAUDE.md" | head -1 | tr -d ' ')
    found "REPOS_ROOT" "$VAL"
  else
    DERIVED=""
    WALK_DIR="$PROJECT_DIR"
    while [ "$WALK_DIR" != "/" ] && [ "$WALK_DIR" != "." ]; do
      COUNT=0
      for child in "$WALK_DIR"/*/; do
        [ -d "$child" ] || continue
        if [ -d "$child/.git" ] || [ -f "$child/CLAUDE.md" ]; then
          COUNT=$((COUNT + 1))
        fi
      done
      if [ "$COUNT" -ge 2 ]; then
        DERIVED="$WALK_DIR"
        break
      fi
      WALK_DIR="$(dirname "$WALK_DIR")"
    done
    if [ -n "$DERIVED" ]; then
      printf "  ❌ %-35s %s\n" "REPOS_ROOT" "not in CLAUDE.md, propose: $DERIVED"
      CMD_FIXES+="  REPOS_ROOT = $DERIVED"$'\n'
    else
      printf "  ❌ %-35s %s\n" "REPOS_ROOT" "not in CLAUDE.md — add REPOS_ROOT = /path/to/repos"
      CMD_FIXES+="  REPOS_ROOT = /path/to/your/repos"$'\n'
    fi
    issues=$((issues + 1))
  fi

  # LOCAL_URL — required by ticket-verify (aborts if absent)
  if [ -n "${LOCAL_URL:-}" ]; then
    found "LOCAL_URL" "$LOCAL_URL (from env)"
  elif grep -qi 'LOCAL_URL.*https\?://' "$PROJECT_DIR/CLAUDE.md" 2>/dev/null; then
    VAL=$(grep -oP 'LOCAL_URL[=:]\s*\K.*' "$PROJECT_DIR/CLAUDE.md" | head -1 | tr -d ' ')
    found "LOCAL_URL" "$VAL"
  else
    miss "LOCAL_URL" "not set — required by ticket-verify for local dev server checks"
  fi

  # BE_TEST_CMD
  if grep -q 'BE_TEST_CMD' "$PROJECT_DIR/CLAUDE.md" 2>/dev/null; then
    found "BE_TEST_CMD" "present"
  else
    warn "BE_TEST_CMD" "not in CLAUDE.md - ticket-implement skips BE tests"
  fi

  # SLACK_CHANNEL
  if grep -q 'SLACK_CHANNEL' "$PROJECT_DIR/CLAUDE.md" 2>/dev/null; then
    found "SLACK_CHANNEL" "present"
  else
    warn "SLACK_CHANNEL" "not in CLAUDE.md - ticket-overseer prints to stdout only"
  fi

  # WIKI_ROOT
  if grep -qi 'WIKI_ROOT\|wiki/' "$PROJECT_DIR/CLAUDE.md" 2>/dev/null; then
    found "WIKI_ROOT" "present"
  else
    warn "WIKI_ROOT" "not in CLAUDE.md - appraise skips wiki bootstrapping"
  fi
fi

# ── Proposed fixes ─────────────────────────────────────────────────────────

if [ -n "$ENV_FIXES" ]; then
  echo ""
  echo "--- Missing env vars: add to ~/.claude/settings.local.json ---"
  echo '{'
  echo '  "env": {'
  printf '%s' "$ENV_FIXES"
  echo '  }'
  echo '}'
fi

if [ -n "$CMD_FIXES" ]; then
  echo ""
  echo "--- Missing CLAUDE.md fields ---"
  printf '%s' "$CMD_FIXES"
fi

if [ ${#PROPOSED[@]} -gt 0 ]; then
  echo ""
  echo "--- Suggested values for optional vars ---"
  for var in "${!PROPOSED[@]}"; do
    printf "  %-30s = %s\n" "$var" "${PROPOSED[$var]}"
  done
fi

# ── Summary ────────────────────────────────────────────────────────────────

echo ""
echo "---"
if [ $issues -eq 0 ] && [ $warns -eq 0 ]; then
  echo "All checks passed."
elif [ $issues -gt 0 ]; then
  echo "$issues required, $warns warnings. Fixes proposed above."
else
  echo "All required values present ($warns warnings)."
fi

exit $issues
