#!/usr/bin/env bash
# validate-env.sh — check required env vars and CLAUDE.md values for ticket workflow
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_MD="${1:-./CLAUDE.md}"

RED=$(tput setaf 1 2>/dev/null || echo "")
GREEN=$(tput setaf 2 2>/dev/null || echo "")
YELLOW=$(tput setaf 3 2>/dev/null || echo "")
BOLD=$(tput bold 2>/dev/null || echo "")
RESET=$(tput sgr0 2>/dev/null || echo "")

failures=0

say()   { echo "${BOLD}${1}${RESET}: ${2}"; }
pass()  { echo "  ${GREEN}ok${RESET}  ${1}"; }
fail()  { echo "  ${RED}MISS${RESET} ${1} — ${2}"; failures=$((failures + 1)); }
warn()  { echo "  ${YELLOW}warn${RESET} ${1} — ${2}"; }

echo ""
say "check" "shell environment variables"

# -- LINEAR_API_KEY -----------------------------------------------------------
if [ -n "${LINEAR_API_KEY:-}" ]; then
  pass "LINEAR_API_KEY"
else
  fail "LINEAR_API_KEY" "add to .claude/settings.local.json env block — required by lib/linear-api.sh"
fi

# -- LINEAR_API_URL (optional, has default) -----------------------------------
if [ -n "${LINEAR_API_URL:-}" ]; then
  pass "LINEAR_API_URL (override)"
else
  pass "LINEAR_API_URL (default: https://api.linear.app/graphql)"
fi

# -- GITHUB_PERSONAL_ACCESS_TOKEN ---------------------------------------------
if [ -n "${GITHUB_PERSONAL_ACCESS_TOKEN:-}" ]; then
  pass "GITHUB_PERSONAL_ACCESS_TOKEN"
else
  fail "GITHUB_PERSONAL_ACCESS_TOKEN" "add to ~/.claude/settings.json env block — required by GitHub MCP"
fi

echo ""
say "check" "CLAUDE.md values ($CLAUDE_MD)"

if [ ! -f "$CLAUDE_MD" ]; then
  fail "CLAUDE.md not found at $CLAUDE_MD" "ticket-auto guard should have already verified working directory"
  echo ""
  echo "${RED}${BOLD}Validation failed: ${failures} missing${RESET}"
  exit 1
fi

# -- REPOS_ROOT ---------------------------------------------------------------
if grep -q 'microservices/gateway/' "$CLAUDE_MD" && grep -q 'Codebase Projects' "$CLAUDE_MD"; then
  pass "REPOS_ROOT (codebase table present)"
else
  fail "REPOS_ROOT" "CLAUDE.md missing Codebase Projects table — skills can't resolve repo paths"
fi

# -- LOCAL_URL ----------------------------------------------------------------
if grep -q 'LOCAL_URL.*http' "$CLAUDE_MD" 2>/dev/null; then
  pass "LOCAL_URL ($(grep 'LOCAL_URL' "$CLAUDE_MD" | head -1 | sed 's/.*`//;s/`.*//'))"
else
  fail "LOCAL_URL" "add 'LOCAL_URL = {LOCAL_URL}' to CLAUDE.md"
fi

# -- UAT_URL ------------------------------------------------------------------
if grep -q 'UAT_URL.*https\?://' "$CLAUDE_MD" 2>/dev/null; then
  pass "UAT_URL ($(grep 'UAT_URL' "$CLAUDE_MD" | head -1 | sed 's/.*`//;s/`.*//'))"
else
  fail "UAT_URL" "add 'UAT_URL = {UAT_URL}' to CLAUDE.md"
fi

# -- BE_TEST_CMD (optional) ---------------------------------------------------
if grep -q 'BE_TEST_CMD' "$CLAUDE_MD" 2>/dev/null; then
  pass "BE_TEST_CMD ($(grep 'BE_TEST_CMD' "$CLAUDE_MD" | head -1 | sed 's/.*`//;s/`.*//'))"
else
  warn "BE_TEST_CMD" "missing — ticket-implement will skip BE tests"
fi

# -- SLACK_CHANNEL (optional) -------------------------------------------------
if grep -q 'SLACK_CHANNEL' "$CLAUDE_MD" 2>/dev/null; then
  pass "SLACK_CHANNEL ($(grep 'SLACK_CHANNEL' "$CLAUDE_MD" | head -1 | sed 's/.*`//;s/`.*//'))"
else
  warn "SLACK_CHANNEL" "missing — ticket-overseer will print to stdout only"
fi

# -- WIKI_ROOT (optional) -----------------------------------------------------
if grep -q 'WIKI_ROOT\|wiki/' "$CLAUDE_MD" 2>/dev/null; then
  pass "WIKI_ROOT (wiki path present)"
else
  warn "WIKI_ROOT" "missing — appraise will skip wiki bootstrapping"
fi

echo ""

if [ "$failures" -eq 0 ]; then
  echo "${GREEN}${BOLD}All required values present.${RESET}"
  exit 0
else
  echo "${RED}${BOLD}${failures} required value(s) missing. Fix above and re-run.${RESET}"
  exit 1
fi
