---
name: ticket-env-check
description: Validates all environment variables and CLAUDE.md fields required by the ticket-auto-pipeline. Run after first install, or when pipeline commands fail with auth/configuration errors.
---

# Ticket Environment Check

Validates everything the pipeline needs: API keys, tokens, and project-specific CLAUDE.md fields.

## Usage

```
/ticket-env-check
```

No arguments. Run from the project directory containing `CLAUDE.md`.

## Execution

### Step 1 — Run the check

Write `env-check.sh` output to a temp file (avoids bash stdout truncation). Tries the synced `~/.claude/skills/lib/` path first, falling back to the plugin cache.

```bash
rm -f /tmp/env-check-output.txt
ENV_CHECK=""
if [ -f ~/.claude/skills/lib/env-check.sh ]; then
  ENV_CHECK=~/.claude/skills/lib/env-check.sh
else
  ENV_CHECK="$(ls ~/.claude/plugins/cache/willard-pro-claude-plugins/ticket-auto-pipeline/*/lib/env-check.sh 2>/dev/null | sort -V | tail -1)"
fi
if [ -n "$ENV_CHECK" ]; then
  bash "$ENV_CHECK" --summary-file /tmp/env-check-output.txt || true
else
  echo "env-check.sh not found — reinstall the plugin"
fi
```

```bash
[ -f /tmp/env-check-output.txt ] && cat /tmp/env-check-output.txt || echo "OUTPUT_FILE_MISSING"
```

### Step 2 — Display as table

Parse the `---BEGIN_VARS---` / `---END_VARS---` block from the output above.

- First pipe-delimited row is the header — use as column names, do NOT render it as a data row.
- `ROWCOUNT=N` line is metadata — parse N, do NOT render it as a data row.
- Render ALL remaining data rows as a markdown table with columns: **Name**, **Status**, **Value**, **Location**, **Note**.

After rendering, count the data rows you rendered:
- If count equals N: state "Rendered N of N rows." below the table.
- If count does not equal N: immediately re-render the table including ALL rows regardless of status, then re-count.
  - If re-rendered count equals N: state "Rendered N of N rows."
  - If re-rendered count still does not equal N: print the raw file content verbatim and state "WARNING: rendered X of N rows — raw output above."

If `ROWCOUNT=` line is absent from the file, treat this as truncation and print the raw file content verbatim.

**DO NOT write any files.** This skill is read-only. The user decides what to set and where.
