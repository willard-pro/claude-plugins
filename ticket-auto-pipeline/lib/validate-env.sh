#!/usr/bin/env bash
# validate-env.sh — thin wrapper around env-check.sh --mode=validate
# Preserves the exact CLI contract: accepts optional CLAUDE.md path argument.
# -u (nounset) intentionally omitted: Claude Code shell snapshots inject
# ZSH_VERSION references that trigger false-positive "unbound variable"
# errors in this bash version when nounset is active.
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$SCRIPT_DIR/env-check.sh" --mode=validate "$@"
