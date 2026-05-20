# Documentation Improvement Plan

Audit of current READMEs and documentation gaps in the claude-plugins repo.

**Date:** 2026-05-18
**Scope:** Root README, plugin README, missing docs, structural recommendations

## Issues

### 1. Stale version in root README

Table says `0.2.3`, plugin.json says `0.3.15`. Marketplace landing page shows wrong version.

### 2. No CHANGELOG

Zero version history anywhere. Users upgrading between plugin versions have no way to know what changed. `git log` is the only option.

### 3. No troubleshooting guide

Pipeline has 5 gate-stop codes, 20+ skills, 6 lib scripts, 7 heartbeat categories. When something breaks structured guidance doesn't exist. `ticket-retro` helps post-mortem but requires a pipeline run to have occurred.

### 4. MCP server config never shown

README lists required MCP servers (linear-server, playwright, github) but gives zero config examples. New users hit this wall immediately after install.

### 5. `validate-linear-config.sh` invisible to users

First thing that fails after env check passes (Linear team states/labels drift from state machine). Documented in CLAUDE.md, not surfaced to plugin users in either README.

### 6. Root README has no architecture overview

Single sentence then plugin table. Landing visitors don't understand what the pipeline does without drilling into the plugin README.

### 7. `llm-idea.md` floating at repo root

Design doc with no home. Should live under a docs directory or be linked from a docs index.

### 8. No install verification walkthrough

"Run `/ticket-env-check`" is correct but bare. No example of passing vs failing output.

### 9. No upgrade guide

`install.sh` only covers host-skill to plugin migration. Nothing about plugin version upgrades (re-install? cache clearing?).

### 10. Heartbeat log consumers reference non-existent tools

Plugin README lists `dashboard.py`, `report.py`, `retro.sh` as heartbeat log consumers. These don't exist in the repo.

## Recommendations

### Immediate fixes to existing files

| File | Changes |
|------|---------|
| Root `README.md` | Fix version to `0.3.15`. Add MCP config example block. Add state machine diagram for visual overview. Link to plugin README for deep details. |
| Plugin `README.md` | Add Quickstart section (first 5 minutes after install). Add Troubleshooting section with common errors and fixes. Reference `validate-linear-config.sh`. Fix heartbeat consumer references (remove or mark as planned). |

### New docs to create

| File | Purpose |
|------|---------|
| `CHANGELOG.md` | Version history at root level. Each entry: version, date, changes, migration notes. |
| `ticket-auto-pipeline/docs/troubleshooting.md` | Common failure modes: env check failures, state machine drift, MCP auth errors, gate-stop codes with resolution steps, crash recovery procedure. |
| `ticket-auto-pipeline/docs/mcp-config.md` | Full MCP server config examples for linear-server, playwright, github. Copy-paste ready JSON blocks. |
| `docs/llm-integration.md` | Move `llm-idea.md` here, cleaned up and linked from a docs index. |

### Structural principle

The two READMEs serve different audiences but currently overlap:

- **Root README** — marketplace storefront. Attract → install. Brief, calls to action, links to plugin docs for everything else.
- **Plugin README** — user manual. Configure → operate → debug. Comprehensive single doc for plugin users.
- **Plugin `docs/`** — deep-dive reference. Troubleshooting guides, MCP config, log format specs (already present as `pipeline-log-format.md` and `pipeline-heartbeat-format.md`).

Content appearing in both READMEs (env vars, install steps) should live in the plugin README. Root README links to it. This prevents stale-version drift where updating one doc leaves the other behind.

## Implementation order (suggested)

1. Fix stale version + add MCP config example to root README
2. Add Quickstart + Troubleshooting sections to plugin README
3. Create CHANGELOG.md
4. Create `ticket-auto-pipeline/docs/troubleshooting.md`
5. Create `ticket-auto-pipeline/docs/mcp-config.md`
6. Move `llm-idea.md` to `docs/llm-integration.md`
7. Add `validate-linear-config.sh` reference to plugin README
8. Fix or remove heartbeat consumer references
