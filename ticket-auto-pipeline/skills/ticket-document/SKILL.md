---
name: ticket-document
description: Generates ai-context.md after successful implementation. Diffs the branch against develop, reads notes.md for context, classifies significance, and writes structured AI-optimized context to the ticket directory. Called by ticket-auto orchestrator after implement completes.
---

# Ticket Document — Post-Implement Context Generator

You are documenting a completed implementation for future AI agents. Your input is the ticket's `notes.md` and the git history of the implemented branch. Your output is `ai-context.md` in the ticket directory — a terse, structured file optimized for AI consumption.

## Logging (--from-auto)

If `$LOG_FILE` is set (passed by the `ticket-auto` orchestrator): read `~/.claude/skills/pipeline-log-format.md`. Write progress entries at step boundaries. Phase is `MAINTENANCE`.

## Heartbeat (--from-auto)

If `$HB_LOG_FILE` is set (passed by the orchestrator): call `source ~/.claude/skills/lib/heartbeat.sh` then write heartbeat entries at these points:
- **Classification decision**: after significance classification, write `hb_decision "significance-classification" "fired" "{trivial|non-trivial}" '{"reason":"{summary}"}'`
- **Document written**: after ai-context.md is written, write `hb_decision "document-written" "fired" "ai-context.md generated" '{"patterns":"{N}","decisions":"{N}","significance":"{trivial|non-trivial}"}'`
- **Document failed**: if generation fails, write `hb_decision "document-failed" "warn" "ai-context.md generation failed" '{"error":"{reason}"}'`

---

## Step 0 — Resolve context

The orchestrator passes the ticket directory path in the spawn instruction. Identify it from the instruction text. If ambiguous, derive it from the ticket ID (passed alongside the spawn instruction or derivable from the branch name).

Read `notes.md` from the ticket directory. Extract:
- `{COMPLEXITY}` — from the `## Complexity` section (simple or complex)
- `{AFFECTED_REPOS}` — from `## Initial Investigation` (which services were touched)
- `{KEY_FINDINGS}` — the main bullet points from Initial Investigation
- `{PLAN_PATH}` — from `## Next Steps` or `## Plan` (path to simple-fix.md or openspec change directory)

```bash
[ -n "$LOG_FILE" ] && echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|MAINTENANCE|document|start|Reading notes.md for context" >> "$LOG_FILE"
```

---

## Step 1 — Determine the branch

The ticket directory name follows the pattern `{ID}--{slug}`. Derive the branch name from:
1. The spawn instruction (orchestrator passes the branch)
2. If not in the instruction, run `git branch --show-current` from the repo root
3. If that fails, search for branches matching the ticket ID: `git branch -a | grep "{TICKET-ID}"`

---

## Step 2 — Gather git history

Run both commands from the repository root (derive from the ticket directory or CLAUDE.md `{REPOS_ROOT}`):

```bash
git diff develop...{branch}
```

This gives the full change set — all commits on the branch that are not on develop.

```bash
git log develop..{branch} --oneline
```

This gives the commit messages for context on what each commit intended.

---

## Step 3 — Classify significance

Inspect the diff output. Classify the change as **trivial** or **non-trivial**:

**Trivial** (all changes fall into these categories only):
- Config file changes (properties files, env vars, YAML config values)
- Typo fixes (no logic change, only text corrections)
- Version bumps (package.json, pom.xml, build.gradle version numbers only)
- Whitespace or formatting-only changes
- Comment-only changes

**Non-trivial** (any other change):
- Any logic change in source code
- New files added (beyond config or version bumps)
- Test additions or modifications
- Database migration changes
- API contract changes
- Dependency additions or upgrades

**Classification audit log entry** — write to the pipeline log regardless of classification:

```bash
[ -n "$LOG_FILE" ] && echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|MAINTENANCE|document|info|significance={trivial|non-trivial} reason={one-sentence summary of what the diff contains}" >> "$LOG_FILE"
```

---

## Step 4 — Generate ai-context.md

### Step 4a — Non-trivial changes (full context)

Write `ai-context.md` to the ticket directory with this structure:

```markdown
# AI Context — {ISSUE-ID}

**Date:** {today's date — ISO 8601 format: YYYY-MM-DD}
**Branch:** {branch name}
**Complexity:** {simple|complex}
**Outcome:** {Smooth|Rough|Hard}

## What changed
{for each changed file: `- {file}: {one-line summary of change and purpose}`}

## Patterns used
{concrete coding conventions applied — error handling patterns, repeated code structures, why a specific convention is followed. Each entry anchored with a file path. Skip if no notable patterns.}

## Key files for future agents
- {entry point or core logic file}: {one-line role description}
- {config or infrastructure file}: {one-line role description}

## Watch out for
{non-obvious gotchas a future AI agent would miss — hidden coupling between modules, undocumented invariants, standards governing how things work that aren't obvious from reading the code, struggle areas encountered. Skip if none.}

## Decisions
{non-trivial choices made during implementation with one-line rationale. Only include when a real trade-off was evaluated. Skip if none.}
```

**Content guidelines:**
- **What changed**: Derive from `git diff` and `git log`. Group related file changes. Each entry is one file + one line.
- **Patterns used**: Pull from `notes.md` Key findings and your own read of the diff. Look for repeated structures — error handling conventions, null checks, transaction boundaries, logging patterns. Not abstract GoF patterns; concrete, file-anchored conventions.
- **Key files**: Entry points (controllers, main service classes), core logic files (where the actual fix lives), config files touched. Each with a one-line role description.
- **Watch out for**: Extract from notes.md struggle areas, your own read of the diff for hidden coupling (e.g., "changing X affects Y because they share Z"), undocumented invariants the code assumes. This is the highest-signal section for future agents — prioritize it.
- **Decisions**: Only include if a real trade-off was evaluated during implementation. Format: `- {decision}: {one-line rationale}`. Skip if all choices were straightforward.

### Step 4b — Trivial changes (minimal context)

Write `ai-context.md` to the ticket directory with only:

```markdown
# AI Context — {ISSUE-ID}

**Date:** {today's date — ISO 8601 format: YYYY-MM-DD}
**Branch:** {branch name}
**Complexity:** {simple|complex}
**Outcome:** {Smooth|Rough|Hard}

Trivial change — no architectural impact.
```

---

## Step 5 — Update notes.md session log

Append to the ticket's `notes.md` session log:

```markdown
- ai-context.md written ({N} patterns, {N} decisions)
```

Count N as: number of entries in Patterns used section (0 if skipped), number of entries in Decisions section (0 if skipped).

---

## Step 6 — Handoff output

Emit a `DOCUMENT_RESULT` block at the end of your output:

```
=== DOCUMENT_RESULT ===
file={ticket-dir}/ai-context.md
patterns={N}
decisions={N}
significance={trivial|non-trivial}
=== END DOCUMENT_RESULT ===
```

If generation failed for any reason, emit:

```
=== DOCUMENT_RESULT ===
file=none
patterns=0
decisions=0
significance=none
error={reason}
=== END DOCUMENT_RESULT ===
```

```bash
[ -n "$LOG_FILE" ] && echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|MAINTENANCE|document|done|ai-context.md written ({N} patterns, {N} decisions)" >> "$LOG_FILE"
```
