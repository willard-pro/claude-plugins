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

Write `env-check.sh` output to a temp file (avoids bash stdout truncation). Tries the plugin cache first (picks latest by version), falling back to the synced `~/.claude/skills/lib/` path.

```bash
rm -f /tmp/env-check-output.txt
ENV_CHECK="$(ls ~/.claude/plugins/cache/willard-pro-claude-plugins/ticket-auto-pipeline/*/lib/env-check.sh 2>/dev/null | sort -V | tail -1)"
if [ -z "$ENV_CHECK" ] && [ -f ~/.claude/skills/lib/env-check.sh ]; then
  ENV_CHECK=~/.claude/skills/lib/env-check.sh
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

### Step 3 — Offer discovery for missing/warn values

Count vars with status `missing` or `warn` from the parsed table. If none, skip this step.

If any exist, tell the user: **"N variable(s) need attention. I can try to discover values for some of them. Attempt discovery?"**

Vars that are **discoverable** (can search for candidate values):

| Status | Var | Discovery method |
|--------|-----|------------------|
| missing | `UAT_URL` | Search sibling CLAUDE.md files under `$REPOS_ROOT` for `UAT_URL` |
| missing/warn | `LOCAL_URL` | Check common dev ports (`ss -tlnp` for :3000, :5173, :8080, :4200) and `package.json` dev/start scripts |
| warn | `SLACK_CHANNEL` | Search sibling CLAUDE.md files under `$REPOS_ROOT` for `SLACK_CHANNEL` |
| warn | `WIKI_ROOT` | Find directories named `wiki` under `$REPOS_ROOT` and search CLAUDE.md files for `WIKI_ROOT` |
| warn | `BE_TEST_CMD` | Check `package.json` test script and `Makefile`/`justfile` test targets |

Vars that require **manual setup** (secrets — cannot discover):

| Status | Var | Where to get it |
|--------|-----|-----------------|
| missing | `LINEAR_API_KEY` | Linear → Settings → API → Create personal API key |
| missing | `ANTHROPIC_AUTH_TOKEN` | Your LLM provider's API key page |
| missing | `GITHUB_PERSONAL_ACCESS_TOKEN` | GitHub → Settings → Developer settings → Personal access tokens |
| warn | `TICKET_AUTONOMY` | Set to `auto`, `semi-auto`, or `manual` in `settings.local.json` |

If the user agrees to discovery, run the relevant discovery commands for each discoverable var. Present each candidate value and ask the user to confirm before applying. **Do NOT write to files** — the user handles the actual edits.

**DO NOT write any files.** This skill is read-only. The user decides what to set and where.
