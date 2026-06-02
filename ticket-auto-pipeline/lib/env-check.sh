#!/usr/bin/env bash
# ticket-env-check — validates env vars and config required by ticket-auto-pipeline.
#
# Output: pipe-delimited rows between ---BEGIN_VARS--- / ---END_VARS---
# Format: NAME|STATUS|VALUE|LOCATION|NOTE
#   STATUS  ok=present  missing=required+absent  auto=derivable  warn=optional+absent
#   LOCATION  settings.local.json | CLAUDE.md | either
#
# Usage: env-check.sh [PROJECT_DIR] [--mode full|validate] [--summary-file PATH] [--show]
#   --mode full|validate  Output mode: full=pipe-delimited (default), validate=colored pass/fail
#   --summary-file PATH   Write delimited block to PATH; print only "Written to PATH"
#   --show                Also print a human-readable table to stdout
set -euo pipefail

SUMMARY_FILE=""
SHOW=""
PROJECT_DIR=""
_MODE="full"
_EXPECTING_SUMMARY_PATH=false
for arg in "${@}"; do
  if $_EXPECTING_SUMMARY_PATH; then
    if [[ "$arg" == --* ]]; then
      echo "env-check: --summary-file requires a path argument (got flag: $arg)" >&2
      exit 1
    fi
    SUMMARY_FILE="$arg"
    _EXPECTING_SUMMARY_PATH=false
    continue
  fi
  case "$arg" in
  --mode) _MODE="" ;;
  --mode=*) _MODE="${arg#*=}" ;;
  --summary-file) _EXPECTING_SUMMARY_PATH=true ;;
  --summary-file=*) SUMMARY_FILE="${arg#*=}" ;;
  --show) SHOW="1" ;;
  *)
    if [ "$_MODE" = "" ]; then
      _MODE="$arg"
    elif [ -z "$PROJECT_DIR" ]; then
      PROJECT_DIR="$arg"
    else
      echo "env-check: unexpected argument: $arg" >&2
      exit 1
    fi
    ;;
  esac
done

if $_EXPECTING_SUMMARY_PATH; then
  echo "env-check: --summary-file requires a path argument" >&2
  exit 1
fi
PROJECT_DIR="${PROJECT_DIR:-$(pwd)}"

# Reject unknown --mode values
case "${_MODE:-full}" in
full | validate) ;;
*)
  echo "ERROR: unknown --mode '${_MODE:-}'. Valid modes: full, validate" >&2
  exit 1
  ;;
esac
# ── Color helpers (used by validate mode) ─────────────────────────────────────
RED=$(tput setaf 1 2>/dev/null || echo "")
GREEN=$(tput setaf 2 2>/dev/null || echo "")
YELLOW=$(tput setaf 3 2>/dev/null || echo "")
BOLD=$(tput bold 2>/dev/null || echo "")
RESET=$(tput sgr0 2>/dev/null || echo "")

say() { echo "${BOLD}${1}${RESET}: ${2}"; }
pass() { echo "  ${GREEN}ok${RESET}  ${1}"; }
fail() { echo "  ${RED}MISS${RESET} ${1} — ${2}"; }
warn() { echo "  ${YELLOW}warn${RESET} ${1} — ${2}"; }

# Walk ancestors from start_dir; emit the first dir with ≥2 child repos on stdout.
# Returns empty string (exit 0) when no qualifying ancestor is found.
_derive_repos_root() {
  local walk_dir="$1"
  while [ "$walk_dir" != "/" ] && [ "$walk_dir" != "." ]; do
    local count=0
    for child in "$walk_dir"/*/; do
      [ -d "$child" ] || continue
      if [ -d "$child/.git" ] || [ -f "$child/CLAUDE.md" ]; then
        count=$((count + 1))
      fi
    done
    if [ "$count" -ge 2 ]; then
      echo "$walk_dir"
      return 0
    fi
    walk_dir="$(dirname "$walk_dir")"
  done
}

# ── Validate mode ─────────────────────────────────────────────────────────────
if [ "${_MODE:-full}" = "validate" ]; then
  # Resolve CLAUDE.md path: if PROJECT_DIR points to a file, it IS the CLAUDE.md
  if [ -f "$PROJECT_DIR" ]; then
    CLAUDE_MD="$PROJECT_DIR"
    PROJECT_DIR="$(dirname "$PROJECT_DIR")"
  else
    CLAUDE_MD="$PROJECT_DIR/CLAUDE.md"
  fi
  cd "$PROJECT_DIR"

  failures=0

  echo ""
  say "check" "shell environment variables"

  # LINEAR_API_KEY
  if [ -n "${LINEAR_API_KEY:-}" ]; then
    pass "LINEAR_API_KEY"
  elif [ -f "$PROJECT_DIR/.env" ] && grep -q '^LINEAR_API_KEY=' "$PROJECT_DIR/.env" 2>/dev/null; then
    pass "LINEAR_API_KEY (in .env)"
  else
    fail "LINEAR_API_KEY" "add to .claude/settings.local.json env block — required by lib/linear-api.sh"
    failures=$((failures + 1))
  fi

  # LINEAR_API_URL (optional, has default)
  if [ -n "${LINEAR_API_URL:-}" ]; then
    pass "LINEAR_API_URL (override)"
  else
    pass "LINEAR_API_URL (default: https://api.linear.app/graphql)"
  fi

  # GITHUB_PERSONAL_ACCESS_TOKEN
  if [ -n "${GITHUB_PERSONAL_ACCESS_TOKEN:-}" ]; then
    pass "GITHUB_PERSONAL_ACCESS_TOKEN"
  else
    fail "GITHUB_PERSONAL_ACCESS_TOKEN" "add to ~/.claude/settings.json env block — required by GitHub MCP"
    failures=$((failures + 1))
  fi

  echo ""
  say "check" "CLAUDE.md values ($CLAUDE_MD)"

  if [ ! -f "$CLAUDE_MD" ]; then
    fail "CLAUDE.md not found at $CLAUDE_MD" "ticket-auto guard should have already verified working directory"
    echo ""
    echo "${RED}${BOLD}Validation failed: ${failures} missing${RESET}"
    exit 1
  fi

  # REPOS_ROOT
  if grep -qE '^REPOS_ROOT\s*[=:]\s*.' "$CLAUDE_MD" 2>/dev/null; then
    val=$(grep -oP '^REPOS_ROOT[=:]\s*\K.*' "$CLAUDE_MD" | head -1 | tr -d ' ')
    pass "REPOS_ROOT ($val)"
  else
    DERIVED="$(_derive_repos_root "$(dirname "$CLAUDE_MD")")"
    if [ -n "$DERIVED" ]; then
      fail "REPOS_ROOT" "not in CLAUDE.md — propose: REPOS_ROOT = $DERIVED"
    else
      fail "REPOS_ROOT" "CLAUDE.md missing REPOS_ROOT = /path/to/repos — skills can't resolve repo paths"
    fi
    failures=$((failures + 1))
  fi

  # LOCAL_URL
  if [ -n "${LOCAL_URL:-}" ]; then
    pass "LOCAL_URL ($LOCAL_URL via env)"
  elif grep -qi 'LOCAL_URL.*https\?://' "$CLAUDE_MD" 2>/dev/null; then
    val=$(grep -oP 'LOCAL_URL[=:]\s*\K.*' "$CLAUDE_MD" | head -1 | tr -d ' ')
    pass "LOCAL_URL ($val)"
  else
    fail "LOCAL_URL" "required by ticket-verify — add to env or CLAUDE.md"
    failures=$((failures + 1))
  fi

  # UAT_URL
  if [ -n "${UAT_URL:-}" ]; then
    pass "UAT_URL ($UAT_URL via env)"
  elif grep -qi 'UAT_URL.*https\?://' "$CLAUDE_MD" 2>/dev/null; then
    val=$(grep -oP 'UAT_URL[=:]\s*\K.*' "$CLAUDE_MD" | head -1 | tr -d ' ')
    pass "UAT_URL ($val)"
  else
    fail "UAT_URL" "required by ticket-verify — add to env or CLAUDE.md"
    failures=$((failures + 1))
  fi

  # BE_TEST_CMD (optional)
  if grep -q 'BE_TEST_CMD' "$CLAUDE_MD" 2>/dev/null; then
    pass "BE_TEST_CMD (present)"
  else
    warn "BE_TEST_CMD" "missing — ticket-implement will skip BE tests"
  fi

  # SLACK_CHANNEL (optional)
  if grep -q 'SLACK_CHANNEL' "$CLAUDE_MD" 2>/dev/null; then
    pass "SLACK_CHANNEL (present)"
  else
    warn "SLACK_CHANNEL" "missing — ticket-overseer will print to stdout only"
  fi

  # WIKI_ROOT (optional)
  if grep -q 'WIKI_ROOT\|wiki/' "$CLAUDE_MD" 2>/dev/null; then
    pass "WIKI_ROOT (wiki path present)"
  else
    warn "WIKI_ROOT" "missing — appraise will skip wiki bootstrapping"
  fi

  echo ""
  say "check" "token tracker hooks"

  # Check project-level settings first (preferred — scoped to this repo), then user-level
  HOOKS_FOUND=false
  HOOKS_LEVEL=""
  for SETTINGS_FILE in "$PROJECT_DIR/.claude/settings.json" "$HOME/.claude/settings.json"; do
    [ -f "$SETTINGS_FILE" ] || continue
    START_OK=false
    STOP_OK=false
    jq -e '.hooks.SubagentStart // [] | [.[].hooks[]? | select(.command | test("token-tracker-start"))] | length > 0' "$SETTINGS_FILE" >/dev/null 2>&1 && START_OK=true
    jq -e '.hooks.SubagentStop // [] | [.[].hooks[]? | select(.command | test("token-tracker\\.sh"))] | length > 0' "$SETTINGS_FILE" >/dev/null 2>&1 && STOP_OK=true
    if $START_OK && $STOP_OK; then
      HOOKS_FOUND=true
      HOOKS_LEVEL="$SETTINGS_FILE"
      break
    fi
  done

  if $HOOKS_FOUND; then
    if [[ "$HOOKS_LEVEL" == "$PROJECT_DIR/.claude/settings.json" ]]; then
      pass "SubagentStart → token-tracker-start.sh + SubagentStop → token-tracker.sh (project-level — scoped to this repo)"
    else
      warn "SubagentStart → token-tracker-start.sh + SubagentStop → token-tracker.sh (user-level — fires globally, consider moving to project .claude/settings.json)"
    fi
  else
    fail "token tracker hooks not wired" "add SubagentStart→token-tracker-start.sh + SubagentStop→token-tracker.sh to project .claude/settings.json"
    failures=$((failures + 1))
  fi

  echo ""
  if [ "$failures" -eq 0 ]; then
    echo "${GREEN}${BOLD}All required values present.${RESET}"
    exit 0
  else
    echo "${RED}${BOLD}${failures} required value(s) missing. Fix above and re-run.${RESET}"
    exit 1
  fi
fi

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
elif DOTENV_LINEAR_KEY=$(grep -oP '^LINEAR_API_KEY=\K.*' "$PROJECT_DIR/.env" 2>/dev/null || true) && [ -n "$DOTENV_LINEAR_KEY" ]; then
  _var "LINEAR_API_KEY" "auto" "(in .env)" ".env" "key found in project .env"
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
    DERIVED="$(_derive_repos_root "$PROJECT_DIR")"
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

# ── Hooks ───────────────────────────────────────────────────────────────────

START_OK=false
STOP_OK=false
HOOKS_LEVEL=""
for SETTINGS_FILE in "$PROJECT_DIR/.claude/settings.json" "$HOME/.claude/settings.json"; do
  [ -f "$SETTINGS_FILE" ] || continue
  jq -e '.hooks.SubagentStart // [] | [.[].hooks[]? | select(.command | test("token-tracker-start"))] | length > 0' "$SETTINGS_FILE" >/dev/null 2>&1 && START_OK=true
  jq -e '.hooks.SubagentStop // [] | [.[].hooks[]? | select(.command | test("token-tracker\\.sh"))] | length > 0' "$SETTINGS_FILE" >/dev/null 2>&1 && STOP_OK=true
  if $START_OK && $STOP_OK; then
    HOOKS_LEVEL="$SETTINGS_FILE"
    break
  fi
done

if $START_OK && $STOP_OK; then
  if [[ "$HOOKS_LEVEL" == "$PROJECT_DIR/.claude/settings.json" ]]; then
    _var "HOOKS_CONFIGURED" "ok" "SubagentStart + SubagentStop" "project .claude/settings.json" "token tracker hooks scoped to this repo"
  else
    _var "HOOKS_CONFIGURED" "warn" "SubagentStart + SubagentStop" "~/.claude/settings.json" "hooks fire globally — consider moving to project .claude/settings.json"
  fi
elif $START_OK && ! $STOP_OK; then
  _var "HOOKS_CONFIGURED" "warn" "SubagentStart only" "settings.json" "missing SubagentStop → token-tracker.sh"
  issues=$((issues + 1))
elif ! $START_OK && $STOP_OK; then
  _var "HOOKS_CONFIGURED" "warn" "SubagentStop only" "settings.json" "missing SubagentStart → token-tracker-start.sh"
  issues=$((issues + 1))
else
  _var "HOOKS_CONFIGURED" "missing" "" "project .claude/settings.json" "add SubagentStart→token-tracker-start.sh + SubagentStop→token-tracker.sh"
  issues=$((issues + 1))
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
    IFS='|' read -r name status value location note <<<"$line"
    [ -z "$value" ] && value="-"
    printf '%-35s %-8s %-45s %-22s %s\n' "$name" "$status" "$value" "$location" "$note"
  done
}

if [ -n "${SUMMARY_FILE:-}" ]; then
  emit_vars >"$SUMMARY_FILE"
  echo "Summary written to ${SUMMARY_FILE}"
  [ -n "${SHOW:-}" ] && show_table
else
  emit_vars
  [ -n "${SHOW:-}" ] && echo "" && show_table
fi

exit $issues
