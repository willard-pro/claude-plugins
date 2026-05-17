#!/usr/bin/env bash
# ticket-env-check — validates all env vars and config required by ticket-auto-pipeline.
# Delegates to validate-env.sh for core checks, adds extras it doesn't cover.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo ""
echo "=== ticket-auto-pipeline Environment Check ==="

# ── Extra env vars validate-env.sh doesn't check ───────────────────────────

extra_fail=0
check_var() {
  local name="$1" purpose="$2"
  if [ -n "${!name:-}" ]; then
    printf "  ✅ %-35s set (%s)\n" "$name" "$purpose"
  else
    printf "  ❌ %-35s MISSING (%s)\n" "$name" "$purpose"
    extra_fail=1
  fi
}

echo ""
echo "Additional env vars:"
check_var "ANTHROPIC_AUTH_TOKEN"   "Claude API key"
check_var "GH_TOKEN"               "GitHub CLI (fallback for GITHUB_PERSONAL_ACCESS_TOKEN)"

echo ""
echo "Optional:"
check_var "ANTHROPIC_BASE_URL"     "Custom API endpoint"
check_var "ANTHROPIC_MODEL"        "Model override"
check_var "GIT_AUTHOR_NAME"        "Commit authorship"
check_var "GIT_AUTHOR_EMAIL"       "Commit email"
check_var "TICKET_AUTONOMY"        "Autonomy mode (manual/auto/semi-auto)"

# ── Delegate core checks ───────────────────────────────────────────────────

bash "$SCRIPT_DIR/validate-env.sh"

# ── Summary ────────────────────────────────────────────────────────────────

echo ""
if [ $extra_fail -eq 0 ]; then
  echo "Additional env vars: all present"
else
  echo "Additional env vars: missing — add to ~/.claude/settings.local.json under env:"
  echo ""
  echo '  {'
  echo '    "env": {'
  echo '      "ANTHROPIC_AUTH_TOKEN": "sk-ant-...",'
  echo '      "GH_TOKEN": "ghp_..."'
  echo '    }'
  echo '  }'
fi
