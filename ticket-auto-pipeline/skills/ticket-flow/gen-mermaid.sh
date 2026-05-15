#!/usr/bin/env bash
# gen-mermaid.sh — generate a stateDiagram-v2 block from state-machine.json.
# Outputs only the diagram content (no markdown fence) for embedding.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SM="$SCRIPT_DIR/state-machine.json"

jq -r 'empty' "$SM" 2>/dev/null || { echo "state-machine.json is not valid JSON" >&2; exit 1; }

echo 'stateDiagram-v2'

# Hardcoded framing lines — not modelled as state-machine triggers
echo '    [*] --> Backlog : ticket created'

# Emit one line per trigger that has non-null from/to
jq -r '.triggers | to_entries[]
  | select(.value.from != null and .value.to != null)
  | "    \(.value.from) --> \(.value.to) : \(.key)"' "$SM"

echo '    Done --> [*]'
