#!/usr/bin/env bash
# ticket-env-check — validates all env vars and config required by ticket-auto-pipeline.
# Derives sensible defaults where possible (git config, filesystem walk for REPOS_ROOT).
#
# Output:
#   Human-readable section (for standalone use)
#   ---BEGIN_VARS--- / ---END_VARS--- block (for skill consumption)
#   Format: STATUS|NAME|VALUE|DERIVABLE|LOCATION|MESSAGE
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

# Structured output for skill consumption: STATUS|NAME|VALUE|DERIVABLE|LOCATION|MESSAGE
declare -a VAR_LINES
_var() { VAR_LINES+=("$1|$2|$3|$4|$5|$6"); }

# Derive git config values from the project directory
GIT_NAME="$(cd "$PROJECT_DIR" && git config user.name 2>/dev/null || true)"
GIT_EMAIL="$(cd "$PROJECT_DIR" && git config user.email 2>/dev/null || true)"

echo ""
echo "=== ticket-auto-pipeline v0.3.2 ==="
echo ""

# ── API keys ────────────────────────────────────────────────────────────────

echo "API keys:"

# LINEAR_API_KEY
if [ -n "${LINEAR_API_KEY:-}" ]; then
  found "LINEAR_API_KEY" "set"
  _var "ok" "LINEAR_API_KEY" "set" "no" "env" ""
else
  miss "LINEAR_API_KEY" "required - add to ~/.claude/settings.local.json env"
  _var "miss" "LINEAR_API_KEY" "" "no" "env" "Linear API key (from Linear → Settings → API)"
fi

# ANTHROPIC_AUTH_TOKEN
if [ -n "${ANTHROPIC_AUTH_TOKEN:-}" ]; then
  found "ANTHROPIC_AUTH_TOKEN" "set"
  _var "ok" "ANTHROPIC_AUTH_TOKEN" "set" "no" "env" ""
else
  miss "ANTHROPIC_AUTH_TOKEN" "required - add to ~/.claude/settings.local.json env"
  _var "miss" "ANTHROPIC_AUTH_TOKEN" "" "no" "env" "Anthropic API key"
fi

# GitHub token
if [ -n "${GITHUB_PERSONAL_ACCESS_TOKEN:-}" ]; then
  found "GITHUB_PERSONAL_ACCESS_TOKEN" "set"
  _var "ok" "GITHUB_PERSONAL_ACCESS_TOKEN" "set" "no" "env" ""
  if [ -z "${GH_TOKEN:-}" ]; then
    warn "GH_TOKEN" "not set - add to env as copy of GITHUB_PERSONAL_ACCESS_TOKEN"
    PROPOSED["GH_TOKEN"]="(same as GITHUB_PERSONAL_ACCESS_TOKEN)"
    _var "warn" "GH_TOKEN" "(copy of GITHUB_PERSONAL_ACCESS_TOKEN)" "yes" "env" "avoids gh auth issues"
  else
    found "GH_TOKEN" "set"
    _var "ok" "GH_TOKEN" "set" "no" "env" ""
  fi
else
  miss "GITHUB_PERSONAL_ACCESS_TOKEN" "required - add to ~/.claude/settings.local.json env"
  _var "miss" "GITHUB_PERSONAL_ACCESS_TOKEN" "" "no" "env" "GitHub personal access token"
  if [ -z "${GH_TOKEN:-}" ]; then
    warn "GH_TOKEN" "also not set"
    _var "warn" "GH_TOKEN" "" "no" "env" "also not set"
  fi
fi

# ── Optional env ────────────────────────────────────────────────────────────

echo ""
echo "Optional env:"

# ANTHROPIC_BASE_URL
if [ -n "${ANTHROPIC_BASE_URL:-}" ]; then
  found "ANTHROPIC_BASE_URL" "set"
  _var "ok" "ANTHROPIC_BASE_URL" "set" "no" "env" ""
else
  warn "ANTHROPIC_BASE_URL" "not set (using default)"
  _var "warn" "ANTHROPIC_BASE_URL" "" "no" "env" "override Anthropic API base URL"
fi

# ANTHROPIC_MODEL
if [ -n "${ANTHROPIC_MODEL:-}" ]; then
  found "ANTHROPIC_MODEL" "set"
  _var "ok" "ANTHROPIC_MODEL" "set" "no" "env" ""
else
  warn "ANTHROPIC_MODEL" "not set (using default)"
  _var "warn" "ANTHROPIC_MODEL" "" "no" "env" "override default model"
fi

# GIT_AUTHOR_NAME
if [ -n "${GIT_AUTHOR_NAME:-}" ]; then
  found "GIT_AUTHOR_NAME" "set"
  _var "ok" "GIT_AUTHOR_NAME" "set" "no" "env" ""
else
  if [ -n "$GIT_NAME" ]; then
    warn "GIT_AUTHOR_NAME" "not set, propose: $GIT_NAME"
    PROPOSED["GIT_AUTHOR_NAME"]="$GIT_NAME"
    _var "warn" "GIT_AUTHOR_NAME" "$GIT_NAME" "yes" "env" "git config user.name"
  else
    warn "GIT_AUTHOR_NAME" "not set - run: git config user.name"
    _var "warn" "GIT_AUTHOR_NAME" "" "no" "env" "run: git config user.name"
  fi
fi

# GIT_AUTHOR_EMAIL
if [ -n "${GIT_AUTHOR_EMAIL:-}" ]; then
  found "GIT_AUTHOR_EMAIL" "set"
  _var "ok" "GIT_AUTHOR_EMAIL" "set" "no" "env" ""
else
  if [ -n "$GIT_EMAIL" ]; then
    warn "GIT_AUTHOR_EMAIL" "not set, propose: $GIT_EMAIL"
    PROPOSED["GIT_AUTHOR_EMAIL"]="$GIT_EMAIL"
    _var "warn" "GIT_AUTHOR_EMAIL" "$GIT_EMAIL" "yes" "env" "git config user.email"
  else
    warn "GIT_AUTHOR_EMAIL" "not set - run: git config user.email"
    _var "warn" "GIT_AUTHOR_EMAIL" "" "no" "env" "run: git config user.email"
  fi
fi

# TICKET_AUTONOMY
if [ -n "${TICKET_AUTONOMY:-}" ]; then
  found "TICKET_AUTONOMY" "set to '$TICKET_AUTONOMY'"
  _var "ok" "TICKET_AUTONOMY" "$TICKET_AUTONOMY" "no" "env" ""
else
  DOTENV_VAL=$(grep -oP '^TICKET_AUTONOMY=\K.*' "$PROJECT_DIR/.env" 2>/dev/null || true)
  if [ -n "$DOTENV_VAL" ]; then
    warn "TICKET_AUTONOMY" "not in env (found in .env: $DOTENV_VAL) - copy to settings.local.json env"
    PROPOSED["TICKET_AUTONOMY"]="$DOTENV_VAL"
    _var "warn" "TICKET_AUTONOMY" "$DOTENV_VAL" "yes" "env" "found in .env, copy to settings.local.json"
  else
    warn "TICKET_AUTONOMY" "not set (defaults to manual)"
    _var "warn" "TICKET_AUTONOMY" "manual" "no" "env" "auto | semi-auto | manual (default)"
  fi
fi

# UAT_URL — required by ticket-verify (aborts if absent), no derivation
if [ -n "${UAT_URL:-}" ]; then
  found "UAT_URL" "set in env"
  _var "ok" "UAT_URL" "$UAT_URL" "no" "either" ""
elif grep -qi 'UAT_URL.*https\?://' "$PROJECT_DIR/CLAUDE.md" 2>/dev/null; then
  UAT_CLAUDE=$(grep -oP '^UAT_URL[=:]\s*\K.*' "$PROJECT_DIR/CLAUDE.md" | head -1 | tr -d ' ' || true)
  found "UAT_URL" "$UAT_CLAUDE (from CLAUDE.md)"
  _var "ok" "UAT_URL" "$UAT_CLAUDE" "no" "claude" ""
else
  miss "UAT_URL" "not set — required by ticket-verify for UAT environment checks"
  _var "miss" "UAT_URL" "" "no" "either" "UAT environment URL (e.g. https://uat.example.com)"
fi

# ── CLAUDE.md fields ────────────────────────────────────────────────────────

echo ""
echo "CLAUDE.md:"

if [ ! -f "$PROJECT_DIR/CLAUDE.md" ]; then
  printf "  ❌ %-35s %s\n" "CLAUDE.md" "not found at $PROJECT_DIR/CLAUDE.md"
  _var "miss" "CLAUDE.md" "" "no" "claude" "file not found"
  issues=$((issues + 1))
else
  # REPOS_ROOT — walk up looking for directory with multiple repos (git dirs or CLAUDE.md files)
  if grep -q '^REPOS_ROOT[=:]\s*.' "$PROJECT_DIR/CLAUDE.md" 2>/dev/null; then
    VAL=$(grep -oP '^REPOS_ROOT[=:]\s*\K.*' "$PROJECT_DIR/CLAUDE.md" | head -1 | tr -d ' ')
    found "REPOS_ROOT" "$VAL"
    _var "ok" "REPOS_ROOT" "$VAL" "no" "claude" ""
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
      _var "miss" "REPOS_ROOT" "$DERIVED" "yes" "claude" "parent directory of all project repos"
    else
      printf "  ❌ %-35s %s\n" "REPOS_ROOT" "not in CLAUDE.md — add REPOS_ROOT = /path/to/repos"
      CMD_FIXES+="  REPOS_ROOT = /path/to/your/repos"$'\n'
      _var "miss" "REPOS_ROOT" "" "no" "claude" "parent directory of all project repos"
    fi
    issues=$((issues + 1))
  fi

  # LOCAL_URL — required by ticket-verify (aborts if absent)
  if [ -n "${LOCAL_URL:-}" ]; then
    found "LOCAL_URL" "$LOCAL_URL (from env)"
    _var "ok" "LOCAL_URL" "$LOCAL_URL" "no" "either" ""
  elif grep -qi 'LOCAL_URL.*https\?://' "$PROJECT_DIR/CLAUDE.md" 2>/dev/null; then
    VAL=$(grep -oP 'LOCAL_URL[=:]\s*\K.*' "$PROJECT_DIR/CLAUDE.md" | head -1 | tr -d ' ')
    found "LOCAL_URL" "$VAL"
    _var "ok" "LOCAL_URL" "$VAL" "no" "claude" ""
  else
    miss "LOCAL_URL" "not set — required by ticket-verify for local dev server checks"
    _var "miss" "LOCAL_URL" "" "no" "either" "local dev server URL (e.g. http://localhost:3000)"
  fi

  # BE_TEST_CMD
  if grep -q 'BE_TEST_CMD' "$PROJECT_DIR/CLAUDE.md" 2>/dev/null; then
    found "BE_TEST_CMD" "present"
    _var "ok" "BE_TEST_CMD" "present" "no" "claude" ""
  else
    warn "BE_TEST_CMD" "not in CLAUDE.md - ticket-implement skips BE tests"
    _var "warn" "BE_TEST_CMD" "" "no" "claude" "backend test command (e.g. npm test)"
  fi

  # SLACK_CHANNEL
  if grep -q 'SLACK_CHANNEL' "$PROJECT_DIR/CLAUDE.md" 2>/dev/null; then
    found "SLACK_CHANNEL" "present"
    _var "ok" "SLACK_CHANNEL" "present" "no" "claude" ""
  else
    warn "SLACK_CHANNEL" "not in CLAUDE.md - ticket-overseer prints to stdout only"
    _var "warn" "SLACK_CHANNEL" "" "no" "claude" "Slack channel for notifications (e.g. #tickets)"
  fi

  # WIKI_ROOT
  if grep -qi 'WIKI_ROOT\|wiki/' "$PROJECT_DIR/CLAUDE.md" 2>/dev/null; then
    found "WIKI_ROOT" "present"
    _var "ok" "WIKI_ROOT" "present" "no" "claude" ""
  else
    warn "WIKI_ROOT" "not in CLAUDE.md - appraise skips wiki bootstrapping"
    _var "warn" "WIKI_ROOT" "" "no" "claude" "wiki directory path for documentation"
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

# ── Structured output for skill consumption ─────────────────────────────────

echo ""
echo "---BEGIN_VARS---"
for line in "${VAR_LINES[@]}"; do
  echo "$line"
done
echo "---END_VARS---"

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
