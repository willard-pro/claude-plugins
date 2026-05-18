#!/usr/bin/env bash
# ticket-env-check — validates env vars and config required by ticket-auto-pipeline.
#
# Output: pipe-delimited rows between ---BEGIN_VARS--- / ---END_VARS---
# Format: NAME|STATUS|VALUE|LOCATION|NOTE
#   STATUS  ok=present  missing=required+absent  auto=derivable  warn=optional+absent
#   LOCATION  settings.local.json | CLAUDE.md | either
#
# Usage: env-check.sh [PROJECT_DIR] [--summary-file PATH] [--show]
#   --summary-file PATH  Write delimited block to PATH; print only "Written to PATH"
#   --show               Also print a human-readable table to stdout
set -euo pipefail

SUMMARY_FILE=""
SHOW=""
PROJECT_DIR=""
for arg in "${@}"; do
  case "$arg" in
    --summary-file) SUMMARY_FILE="1" ;;
    --summary-file=*) SUMMARY_FILE="${arg#*=}" ;;
    --show) SHOW="1" ;;
    *)
      if [ "$SUMMARY_FILE" = "1" ]; then
        SUMMARY_FILE="$arg"
      elif [ -z "$PROJECT_DIR" ]; then
        PROJECT_DIR="$arg"
      fi
      ;;
  esac
done
PROJECT_DIR="${PROJECT_DIR:-$(pwd)}"
cd "$PROJECT_DIR"

issues=0
declare -a VAR_LINES
_var() { VAR_LINES+=("$1|$2|$3|$4|$5"); }

# Returns "filepath:value" if varname found in env block of either settings.local.json.
# Checks project-local first, then global ~/.claude.
find_in_settings() {
  local varname="$1"
  local files=(
    "$PROJECT_DIR/.claude/settings.local.json"
    "$HOME/.claude/settings.local.json"
  )
  for f in "${files[@]}"; do
    [ -f "$f" ] || continue
    local val=""
    if command -v jq &>/dev/null; then
      val=$(jq -r --arg k "$varname" '.env[$k] // empty' "$f" 2>/dev/null || true)
    else
      val=$(grep -oP "\"$varname\"\s*:\s*\"\K[^\"]+" "$f" 2>/dev/null | head -1 || true)
    fi
    [ -n "$val" ] && echo "${f}:${val}" && return 0
  done
  return 1
}

# Returns value if varname found as KEY = value or KEY: value in CLAUDE.md.
find_in_claude_md() {
  local varname="$1"
  local pat='^`?'"$varname"'`?\s*[=:]\s*`?\K[^`\s]+'
  grep -oP "$pat" "$PROJECT_DIR/CLAUDE.md" 2>/dev/null | head -1 | tr -d ' ' || true
}

GIT_NAME="$(git config user.name 2>/dev/null || true)"
GIT_EMAIL="$(git config user.email 2>/dev/null || true)"

# ── API keys ────────────────────────────────────────────────────────────────

if [ -n "${LINEAR_API_KEY:-}" ]; then
  _var "LINEAR_API_KEY" "ok" "${LINEAR_API_KEY}" "settings.local.json" ""
elif result=$(find_in_settings "LINEAR_API_KEY"); then
  _var "LINEAR_API_KEY" "warn" "(in ${result%%:*} — restart session)" "settings.local.json" "found in file but not loaded"
else
  _var "LINEAR_API_KEY" "missing" "" "settings.local.json" "Linear API key (Linear → Settings → API)"
  issues=$((issues + 1))
fi

if [ -n "${ANTHROPIC_AUTH_TOKEN:-}" ]; then
  _var "ANTHROPIC_AUTH_TOKEN" "ok" "${ANTHROPIC_AUTH_TOKEN}" "settings.local.json" ""
elif result=$(find_in_settings "ANTHROPIC_AUTH_TOKEN"); then
  _var "ANTHROPIC_AUTH_TOKEN" "warn" "(in ${result%%:*} — restart session)" "settings.local.json" "found in file but not loaded"
else
  _var "ANTHROPIC_AUTH_TOKEN" "missing" "" "settings.local.json" "Anthropic API key"
  issues=$((issues + 1))
fi

if [ -n "${GITHUB_PERSONAL_ACCESS_TOKEN:-}" ]; then
  _var "GITHUB_PERSONAL_ACCESS_TOKEN" "ok" "${GITHUB_PERSONAL_ACCESS_TOKEN}" "settings.local.json" ""
  if [ -z "${GH_TOKEN:-}" ]; then
    _var "GH_TOKEN" "auto" "(copy of GITHUB_PERSONAL_ACCESS_TOKEN)" "settings.local.json" "set same as GITHUB_PERSONAL_ACCESS_TOKEN"
  else
    _var "GH_TOKEN" "ok" "${GH_TOKEN}" "settings.local.json" ""
  fi
elif result=$(find_in_settings "GITHUB_PERSONAL_ACCESS_TOKEN"); then
  _var "GITHUB_PERSONAL_ACCESS_TOKEN" "warn" "(in ${result%%:*} — restart session)" "settings.local.json" "found in file but not loaded"
  issues=$((issues + 1))
else
  _var "GITHUB_PERSONAL_ACCESS_TOKEN" "missing" "" "settings.local.json" "GitHub personal access token"
  issues=$((issues + 1))
  if [ -z "${GH_TOKEN:-}" ]; then
    _var "GH_TOKEN" "missing" "" "settings.local.json" "set same as GITHUB_PERSONAL_ACCESS_TOKEN"
    issues=$((issues + 1))
  fi
fi

# ── Optional env ────────────────────────────────────────────────────────────

if [ -n "${ANTHROPIC_BASE_URL:-}" ]; then
  _var "ANTHROPIC_BASE_URL" "ok" "${ANTHROPIC_BASE_URL}" "settings.local.json" ""
elif result=$(find_in_settings "ANTHROPIC_BASE_URL"); then
  _var "ANTHROPIC_BASE_URL" "warn" "(in ${result%%:*} — restart session)" "settings.local.json" "found in file but not loaded"
else
  _var "ANTHROPIC_BASE_URL" "warn" "" "settings.local.json" "override Anthropic API base URL"
fi

if [ -n "${ANTHROPIC_MODEL:-}" ]; then
  _var "ANTHROPIC_MODEL" "ok" "${ANTHROPIC_MODEL}" "settings.local.json" ""
elif result=$(find_in_settings "ANTHROPIC_MODEL"); then
  _var "ANTHROPIC_MODEL" "warn" "(in ${result%%:*} — restart session)" "settings.local.json" "found in file but not loaded"
else
  _var "ANTHROPIC_MODEL" "warn" "" "settings.local.json" "override default model"
fi

if [ -n "${GIT_AUTHOR_NAME:-}" ]; then
  _var "GIT_AUTHOR_NAME" "ok" "${GIT_AUTHOR_NAME}" "settings.local.json" ""
elif [ -n "$GIT_NAME" ]; then
  _var "GIT_AUTHOR_NAME" "auto" "$GIT_NAME" "settings.local.json" "from git config user.name"
else
  _var "GIT_AUTHOR_NAME" "warn" "" "settings.local.json" "run: git config user.name"
fi

if [ -n "${GIT_AUTHOR_EMAIL:-}" ]; then
  _var "GIT_AUTHOR_EMAIL" "ok" "${GIT_AUTHOR_EMAIL}" "settings.local.json" ""
elif [ -n "$GIT_EMAIL" ]; then
  _var "GIT_AUTHOR_EMAIL" "auto" "$GIT_EMAIL" "settings.local.json" "from git config user.email"
else
  _var "GIT_AUTHOR_EMAIL" "warn" "" "settings.local.json" "run: git config user.email"
fi

if [ -n "${TICKET_AUTONOMY:-}" ]; then
  _var "TICKET_AUTONOMY" "ok" "${TICKET_AUTONOMY}" "settings.local.json" ""
else
  DOTENV_VAL=$(grep -oP '^TICKET_AUTONOMY=\K.*' "$PROJECT_DIR/.env" 2>/dev/null || true)
  if [ -n "$DOTENV_VAL" ]; then
    _var "TICKET_AUTONOMY" "auto" "$DOTENV_VAL" "settings.local.json" "found in .env — copy to settings.local.json"
  elif result=$(find_in_settings "TICKET_AUTONOMY"); then
    _var "TICKET_AUTONOMY" "warn" "(in ${result%%:*} — restart session)" "settings.local.json" "found in file but not loaded"
  else
    _var "TICKET_AUTONOMY" "warn" "manual" "settings.local.json" "auto | semi-auto | manual (default)"
  fi
fi

if grep -qiE '`?UAT_URL`?\s*[=:]\s*`?https?://' "$PROJECT_DIR/CLAUDE.md" 2>/dev/null; then
  UAT_CLAUDE=$(grep -oP '^`?UAT_URL`?\s*[=:]\s*`?\K[^`\s]+' "$PROJECT_DIR/CLAUDE.md" | head -1 | tr -d ' ' || true)
  _var "UAT_URL" "ok" "$UAT_CLAUDE" "CLAUDE.md" ""
else
  _var "UAT_URL" "missing" "" "CLAUDE.md" "UAT environment URL (e.g. https://uat.example.com)"
  issues=$((issues + 1))
fi

# ── CLAUDE.md fields ────────────────────────────────────────────────────────

if [ ! -f "$PROJECT_DIR/CLAUDE.md" ]; then
  _var "CLAUDE.md" "missing" "" "CLAUDE.md" "file not found at $PROJECT_DIR/CLAUDE.md"
  issues=$((issues + 1))
else
  if grep -qE '^`?REPOS_ROOT`?\s*[=:]\s*.' "$PROJECT_DIR/CLAUDE.md" 2>/dev/null; then
    VAL=$(grep -oP '^`?REPOS_ROOT`?\s*[=:]\s*`?\K[^`\s]+' "$PROJECT_DIR/CLAUDE.md" | head -1 | tr -d ' ' || true)
    _var "REPOS_ROOT" "ok" "$VAL" "CLAUDE.md" ""
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
      if [ "$COUNT" -ge 2 ]; then DERIVED="$WALK_DIR"; break; fi
      WALK_DIR="$(dirname "$WALK_DIR")"
    done
    if [ -n "$DERIVED" ]; then
      _var "REPOS_ROOT" "auto" "$DERIVED" "CLAUDE.md" "add REPOS_ROOT = $DERIVED to CLAUDE.md"
    else
      _var "REPOS_ROOT" "missing" "" "CLAUDE.md" "parent directory of all project repos"
    fi
    issues=$((issues + 1))
  fi

  if [ -n "${LOCAL_URL:-}" ]; then
    _var "LOCAL_URL" "ok" "$LOCAL_URL" "settings.local.json" ""
  elif grep -qiE '`?LOCAL_URL`?\s*[=:]\s*`?https?://' "$PROJECT_DIR/CLAUDE.md" 2>/dev/null; then
    VAL=$(grep -oP '^`?LOCAL_URL`?\s*[=:]\s*`?\K[^`\s]+' "$PROJECT_DIR/CLAUDE.md" | head -1 | tr -d ' ' || true)
    _var "LOCAL_URL" "ok" "$VAL" "CLAUDE.md" ""
  elif result=$(find_in_settings "LOCAL_URL"); then
    _var "LOCAL_URL" "warn" "(in ${result%%:*} — restart session)" "settings.local.json" "found in file but not loaded"
  else
    _var "LOCAL_URL" "missing" "" "settings.local.json or CLAUDE.md" "local dev server URL (e.g. http://localhost:3000)"
    issues=$((issues + 1))
  fi

  if grep -q 'BE_TEST_CMD' "$PROJECT_DIR/CLAUDE.md" 2>/dev/null; then
    _var "BE_TEST_CMD" "ok" "present" "CLAUDE.md" ""
  else
    _var "BE_TEST_CMD" "warn" "" "CLAUDE.md" "backend test command — ticket-implement skips BE tests if absent"
  fi

  if grep -q 'SLACK_CHANNEL' "$PROJECT_DIR/CLAUDE.md" 2>/dev/null; then
    _var "SLACK_CHANNEL" "ok" "present" "CLAUDE.md" ""
  else
    _var "SLACK_CHANNEL" "warn" "" "CLAUDE.md" "Slack channel — ticket-overseer prints to stdout only if absent"
  fi

  if grep -qi 'WIKI_ROOT\|wiki/' "$PROJECT_DIR/CLAUDE.md" 2>/dev/null; then
    _var "WIKI_ROOT" "ok" "present" "CLAUDE.md" ""
  else
    _var "WIKI_ROOT" "warn" "" "CLAUDE.md" "wiki directory path — appraise skips wiki bootstrapping if absent"
  fi
fi

# ── Emit ────────────────────────────────────────────────────────────────────

emit_vars() {
  echo "---BEGIN_VARS---"
  printf 'NAME|STATUS|VALUE|LOCATION|NOTE\n'
  for line in "${VAR_LINES[@]}"; do echo "$line"; done
  echo "ROWCOUNT=${#VAR_LINES[@]}"
  echo "---END_VARS---"
}

show_table() {
  printf '%-35s %-8s %-45s %-22s %s\n' "NAME" "STATUS" "VALUE" "LOCATION" "NOTE"
  printf '%-35s %-8s %-45s %-22s %s\n' "----" "------" "-----" "--------" "----"
  for line in "${VAR_LINES[@]}"; do
    IFS='|' read -r name status value location note <<< "$line"
    [ -z "$value" ] && value="-"
    printf '%-35s %-8s %-45s %-22s %s\n' "$name" "$status" "$value" "$location" "$note"
  done
}

if [ -n "${SUMMARY_FILE:-}" ]; then
  emit_vars > "$SUMMARY_FILE"
  echo "Summary written to ${SUMMARY_FILE}"
  [ -n "${SHOW:-}" ] && show_table
else
  emit_vars
  [ -n "${SHOW:-}" ] && echo "" && show_table
fi

exit $issues
