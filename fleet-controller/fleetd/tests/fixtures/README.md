# fleetd test fixtures

## `stream-json-*.ndjson`

Real `claude -p --output-format stream-json --verbose` captures (Claude Code 2.1.259,
`--permission-mode bypassPermissions`, haiku), taken 2026-09-03 for the Agent Observer
design. Hook payload bodies are redacted to `<redacted>` and home paths normalised; every
frame, its order, and its keys are as emitted.

| File | Prompt | Why it exists |
|---|---|---|
| `stream-json-bash-ok-with-hook-events.ndjson` | one Bash call, compound command exits 0; run **with** `--include-hook-events` | `system/init` is line 45, not line 1; `result` is line 84 of 85 (a `hook_response` follows it); 62/85 lines are hook noise |
| `stream-json-bash-exit3.ndjson` | one Bash call `exit 3`; run **without** the flag | failing tool: `tool_result.is_error=true`, exit code exists only as literal text `"Exit code 3"` — no numeric field anywhere; 27 SessionStart hook lines still precede `init` |

Traps these pin (see the observer plan): never index line 0 for `init`; never treat `result`
as EOF; parse exit codes from text and tolerate absence; ignore unknown frame types.
