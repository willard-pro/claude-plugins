#!/usr/bin/env bash
# validate-env.sh — thin wrapper around env-check.sh --mode=validate
# Preserves the exact CLI contract: accepts optional CLAUDE.md path argument.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$SCRIPT_DIR/env-check.sh" --mode=validate "$@"
