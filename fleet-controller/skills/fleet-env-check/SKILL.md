---
name: fleet-env-check
description: Validates the (small) set of env vars, CLAUDE.md fields, and CLI tools fleet-controller needs — LINEAR_API_KEY, REPOS_ROOT, the fleetd worker spawn command (CLAUDE_BIN/CLAUDE_CMD), and jq/git/python3/gh. Run after first install, after changing CLAUDE_CMD, or when fleetd spawns fail silently.
allowed-tools: Bash
---

# Fleet Controller Environment Check

Validates everything fleet-controller and `fleetd` need to run: Linear API access, `REPOS_ROOT`, the worker spawn command, and required CLI tools. Deliberately smaller than `/ticket-env-check` — fleet-controller is bash-only with no Claude agents, so token-tracker hooks, spawn permissions, `UAT_URL`, `LOCAL_URL`, and `BE_TEST_CMD` (all ticket-auto concerns) don't apply here.

## Usage

```
/fleet-env-check
```

No arguments. Run from the project directory containing `CLAUDE.md`.

## Execution

### Step 1 — Run the check

Write `fleet-env-check.sh` output to a temp file (avoids bash stdout truncation). Tries the plugin cache first (picks latest by version), falling back to the repo-relative path.

```bash
rm -f /tmp/fleet-env-check-output.txt
ENV_CHECK="$(ls ~/.claude/plugins/cache/willard-pro-claude-plugins/fleet-controller/*/lib/fleet-env-check.sh 2>/dev/null | sort -V | tail -1)"
if [ -z "$ENV_CHECK" ] && [ -f "$CLAUDE_PLUGIN_ROOT/lib/fleet-env-check.sh" ]; then
  ENV_CHECK="$CLAUDE_PLUGIN_ROOT/lib/fleet-env-check.sh"
fi
if [ -n "$ENV_CHECK" ]; then
  bash "$ENV_CHECK" --summary-file /tmp/fleet-env-check-output.txt || true
else
  echo "fleet-env-check.sh not found — reinstall the plugin"
fi
```

```bash
[ -f /tmp/fleet-env-check-output.txt ] && cat /tmp/fleet-env-check-output.txt || echo "OUTPUT_FILE_MISSING"
```

### Step 2 — Display as table

Parse the `---BEGIN_VARS---` / `---END_VARS---` block from the output above.

- First pipe-delimited row is the header — use as column names, do NOT render it as a data row.
- `ROWCOUNT=N` line is metadata — parse N, do NOT render it as a data row.
- Render ALL remaining data rows as a markdown table with columns: **Name**, **Status**, **Value**, **Location**, **Note**.
- `LINEAR_API_KEY` and `GITHUB_PERSONAL_ACCESS_TOKEN`/`GH_TOKEN` values are already masked by the script (`****` + last 4 chars) — never re-derive or print the full value from your own context.

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
| missing/auto | `REPOS_ROOT` | Search sibling repos under the derived candidate directory for `.git`/`CLAUDE.md` markers (the script already proposes one when found) |
| missing | `CLAUDE_BIN` / `CLAUDE_CMD` | Run `command -v claude` and any known wrapper binary names; if `CLAUDE_CMD` is set, report which token in it failed to resolve |

Vars that require **manual setup** (secrets — cannot discover):

| Status | Var | Where to get it |
|--------|-----|-----------------|
| missing | `LINEAR_API_KEY` | Linear → Settings → API → Create personal API key |
| missing (only when `FLEET_EPIC_AUTO_PR=true`) | `GITHUB_PERSONAL_ACCESS_TOKEN` | GitHub → Settings → Developer settings → Personal access tokens |

Vars that just need a CLI tool installed:

| Status | Var | Fix |
|--------|-----|-----|
| missing | `jq` / `git` / `python3` | Install via the system package manager — all three are hard requirements (`jq` for detection engines, `git` for worktree/epic-branch ops, `python3` for `fleetd`) |
| missing (only when `FLEET_EPIC_AUTO_PR=true`) | `gh` | Install the GitHub CLI — required for `epic_branch_open_pr` |

If the user agrees to discovery, run the relevant discovery commands for each discoverable var. Present each candidate value and ask the user to confirm before applying. **Do NOT write to files** — the user handles the actual edits.

**DO NOT write any files.** This skill is read-only. The user decides what to set and where.
