---
name: ticket-persona-refresh
description: Refreshes persona guidance files against current best practices. Researches current library/framework docs, identifies outdated guidance, proposes changes, waits for approval, then applies updates. Covers base roles and stack specializers.
---

# ticket-persona-refresh

Checks persona guidance files against current best practices from documentation and the web. Proposes changes, waits for approval, then applies them.

## Parameters

- `persona` — which persona to refresh. Examples: `backend/python`, `frontend/react`, `base/security`, `all`
- `--auto-apply` — skip approval for non-content changes (version bump only, no content edits)

## Pipeline Preamble

This skill runs standalone (not inside a pipeline phase). No pipeline log writes, no heartbeat. It is only invoked manually by a maintainer.

---

## Step 1 — Resolve target personas

If `persona=all`, enumerate all persona files:

```bash
find personas/base -name "*.md" -not -name "README.md" personas/specializers -name "*.md"
```

If a specific name like `backend/python`, resolve to:
- `personas/specializers/backend/python.md` (or `personas/base/<name>.md`)

**Skip persona if** `last-reviewed` is within 30 days (unless `persona` was explicitly named — always refresh explicit targets). Show: "Skipping <name> — last reviewed <date> (< N days ago). Use explicit persona name to force refresh."

---

## Step 2 — Read and analyze persona

For each target persona file:

1. **Read the persona file.** Understand:
   - What role it defines (from `name` and `role` in frontmatter)
   - What tech stack it covers (from `extends`, `detect`, content references)
   - What specific tools, libraries, frameworks, and versions it mentions
   - What conventions, pitfalls, and "done right" criteria it specifies

2. **Extract the research targets.** Scan the persona body for:
   - Named libraries/frameworks (e.g., pytest, Spring Boot, React, FastAPI, JUnit)
   - Version references (e.g., "React 18", "JUnit 5", "Python 3.11")
   - Tool references (e.g., "mypy", "ruff", "Playwright", "TestContainers")
   - Standard/pattern references (e.g., "WCAG 2.1 AA", "PEP 8", "ESM vs CommonJS")

3. **Summarize for the user.** Show what you found:
   ```
   ## Persona: backend/python (v1, last reviewed 2026-06-26)
   Extends: backend-developer
   Tech stack detected: Python, pytest, mypy, ruff, FastAPI, aiohttp, alembic, pyenv, poetry
   Version references: pytest (no specific version), mypy --strict, black line length 88
   ```

---

## Step 3 — Research current best practices

For each identified tool/library/framework, fetch current recommendations:

### 3a. Context7 documentation (primary source)

Use `mcp__plugin_context7_context7__resolve-library-id` then `mcp__plugin_context7_context7__query-docs` for each major library.

Example queries:
- For `backend/python`: resolve and query `pytest`, `mypy`, `ruff`, `fastapi`
- For `frontend/react`: resolve and query `react`, `react-testing-library`, `jest`
- For `backend/java`: resolve and query `spring-boot`, `junit`

Focus queries on:
- Latest stable version and its breaking changes
- Current recommended testing patterns
- New language/framework features that change conventions
- Deprecated APIs or patterns the persona might still reference

### 3b. Web search (supplementary)

Use `WebSearch` for broader best-practices research:

- `"<library> best practices <current year>"`
- `"<library> common pitfalls <current year>"`
- `"<library> testing patterns <current year>"`

Focus on authoritative sources: official docs, library maintainer blogs, widely-referenced guides.

### 3c. GitHub ecosystem (supplementary)

Search GitHub for similar persona/role guidance files to cross-reference patterns:

- `"backend developer" persona markdown`
- `"python developer" role guidelines`
- `"{stack}" AI coding guidelines`

Look for conventions or checks that are widely adopted but missing from our personas.

---

## Step 4 — Compare and generate proposal

Compare persona content against research findings. For each finding, classify:

| Classification | Meaning |
|----------------|---------|
| **OUTDATED** | Persona references superseded versions, deprecated APIs, or obsolete patterns |
| **MISSING** | Important convention, tool, pitfall, or check not covered by the persona |
| **INCORRECT** | Persona guidance contradicts current best practice |
| **CONFIRMED** | Persona guidance matches current best practice (no change needed) |

Generate a structured proposal:

```markdown
## Refresh proposal: backend/python (v1 → v2)

### OUTDATED
- **Line 18**: `black (line length 88)` — Black's default is now 88 and widely accepted, but `ruff format` has largely replaced `black` in new projects. Recommend: mention `ruff format` as primary, `black` as fallback.

### MISSING
- **New tool**: `uv` (Python package manager) is rapidly replacing `pipenv`/`poetry` for new projects. Should be mentioned alongside pyenv/poetry.
- **Pattern**: `pyproject.toml` is now the standard config file for pytest, mypy, ruff (replaces setup.cfg/pytest.ini). Persona doesn't mention this consolidation.

### INCORRECT
(none)

### CONFIRMED
- `pytest` with `pytest-cov` for coverage — still standard
- `mypy --strict` — still the gold standard for type checking
- `FastAPI` + `aiohttp` for async Python — still current
- Context managers for connections — still best practice
- `.env` in `.gitignore` — still essential
- Alembic migrations — still the standard migration tool

### Summary
- 2 outdated items
- 2 missing items
- 0 incorrect items
- 6 confirmed (no change)
```

Show this to the user. **Do not apply changes yet.**

---

## Step 5 — User approval

Present the proposal and wait for the user's response. The user may:

- **Approve all**: Apply every change
- **Approve specific items**: "Apply the ruff one but skip uv for now"
- **Reject**: No changes applied, skill ends
- **Request edits**: "Add more detail about uv before applying"

If the user is non-responsive, assume `--auto-apply` behavior: apply only CONFIRMED status items (which means no content changes — just bump `last-reviewed`).

---

## Step 6 — Apply approved changes

For each approved change:

1. **Edit the persona file** with the approved content changes using the Edit tool.

2. **Bump version and update last-reviewed**:
   ```bash
   bash lib/persona-refresh.sh bump personas/specializers/backend/python.md
   ```

3. **Append to CHANGELOG**:
   ```bash
   bash lib/persona-refresh.sh changelog Changed "python.md (v1→v2): Updated formatter guidance (ruff format primary, black fallback). Added uv package manager. Added pyproject.toml config consolidation note."
   ```

4. **Commit**:
   ```bash
   git add personas/specializers/backend/python.md personas/CHANGELOG.md
   git commit -m "feat(personas): refresh backend/python (v1→v2)

   Updated: ruff format as primary, black as fallback
   Added: uv package manager, pyproject.toml config consolidation

   Co-Authored-By: Claude <noreply@anthropic.com>"
   ```

If multiple personas were refreshed, commit them together with a summary message:

```
feat(personas): refresh python, react, java personas

backend/python (v1→v2): ruff format, uv, pyproject.toml
frontend/react (v1→v2): React 19 conventions, Server Components
backend/java (v1→v2): JUnit 5.11 ParameterizedTest, Spring Boot 3.4

Co-Authored-By: Claude <noreply@anthropic.com>
```

---

## Step 7 — Report

Summary of what was done:

```
## Refresh complete

| Persona | Version | Changes |
|---------|---------|---------|
| backend/python | v1 → v2 | 2 outdated fixed, 2 missing added |
| frontend/react | v1 → v2 | 1 outdated fixed, 3 missing added |
| base/security | v1 → v1 | No changes (still current, last-reviewed bumped) |
```

---

## Notes

- **Idempotency**: Running this skill twice in quick succession should report "still current" on the second run (all findings already applied).
- **Scope**: This skill only refreshes persona CONTENT. It does not modify `persona-select.sh` selection logic. If a new specializer is needed (e.g., `backend/kotlin`), that's a separate task.
- **Version bumps**: Always integer increment. `persona-refresh.sh bump` handles this deterministically.
- **No pipeline integration**: This skill is for maintainers only. It writes no pipeline logs and triggers no state transitions.
