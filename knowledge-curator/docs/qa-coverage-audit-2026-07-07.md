# QA Coverage Audit — knowledge-curator

**Date**: 2026-07-07
**Tests**: 53 (all passing)
**Source files**: 4 (`kc-item.sh`, `kc-index.sh`, `kc-resurface.sh`, `kc-prompt-match.sh`)
**Verdict**: Unit-level coverage sufficient for happy paths + key guards. Three real risks found.

---

## Risk 1 (🔴 High): `claim` allows reclaiming `done`/`dormant` items

**File**: `lib/kc-item.sh:120`
**Code**: `if [ "$CURRENT_STATUS" = "in_progress" ]; then`
**Problem**: The guard only blocks re-claiming `in_progress` items. A `done` or `dormant` item can be claimed back to `in_progress`, re-entering the stack. A completed item silently resurrects.
**Fix**: Either make this intentional (add test) or tighten the guard to `!= "active"`.
**Test needed**: `claim` from `done` status, `claim` from `dormant` status, `claim` from `obsolete` status.

---

## Risk 2 (🔴 High): `sed` injection in `edit` subcommand

**File**: `lib/kc-item.sh:267`
**Code**: `sed -i "s/^${field}:.*/${field}: ${value}/" "$ITEM_FILE"`
**Problem**: Uses `/` as sed delimiter. If `$value` contains `/` (e.g., title "Fix foo/bar parsing"), sed produces a malformed command or wrong substitution.
**Fix**: Use a delimiter not found in typical values (e.g., `#` or `|`), or escape `/` in `$value`.
**Test needed**: `edit` with title containing `/`, `edit` with title containing `&` (sed special char), `edit` with tags containing `/`.

---

## Risk 3 (🟡 Medium): Silent disappearance of deleted item files

**File**: `lib/kc-index.sh:65`
**Problem**: If an item file is manually deleted while `in_progress`, the glob simply won't match it — item vanishes from INDEX with no warning. `kc-item.sh status` returns "Item not found". The sweep's abandoned-`in_progress` check (24h) never fires because the file is gone.
**Fix**: Could track item ids across runs and warn on disappearance. Or accept as "manual deletion = intent."
**Test needed**: Delete item file while `in_progress`, confirm index rebuild excludes it, confirm `status` fails gracefully.

---

## Remaining gaps (by priority)

### 🟡 Medium

| # | Gap | File |
|---|-----|------|
| 4 | `add` path traversal guard untested (`../../etc/passwd`) | `kc-item.sh:186` |
| 5 | `add` duplicate id rejection untested | `kc-item.sh:205-207` |
| 6 | `edit` on `title`/`tags`/`relates`/`project` untested | `kc-item.sh:239` |
| 7 | `edit` rejecting `type`/`created`/`updated`/`source` untested | `kc-item.sh:244-246` |
| 8 | `validate_id` with path traversal inputs untested | `kc-item.sh:35-37` |
| 9 | Full lifecycle sequence untested (claim→release→claim→complete) | Cross-component |
| 10 | `item_count` accuracy with mixed statuses (done + active + corrupt) | `kc-index.sh:61-62` |

### 🟢 Low

| # | Gap | File |
|---|-----|------|
| 11 | `obsolete` status exclusion (same path as `done`, but no explicit test) | `kc-index.sh:87` |
| 12 | Same-priority secondary sort by `updated` timestamp | `kc-index.sh:138` |
| 13 | Unknown priority sort key fallback (sort_key=9) | `kc-index.sh:94` |
| 14 | `extract_field` with missing closing `---` in frontmatter | `kc-index.sh:34` |
| 15 | Multi-line `relates` extraction (non-empty list) | `kc-index.sh:78` |
| 16 | Top-5 limit in resurface hook (6+ items) | `kc-resurface.sh:57` |
| 17 | `extract_summary_col` with renamed/missing column headers | `kc-resurface.sh:32` |
| 18 | Max 5 total match limit in prompt-match | `kc-prompt-match.sh:44` |
| 19 | Per-term head -3 limit | `kc-prompt-match.sh:41` |
| 20 | Duplicate match dedup logic | `kc-prompt-match.sh:38` |
| 21 | Substring false positive (`grep -i "base"` matches "database") | `kc-prompt-match.sh:41` |
| 22 | Special characters in prompt (`!@#$%`) | `kc-prompt-match.sh:27` |

---

## Coverage by component

### `kc-item.sh` (279 lines)

| Subcommand | Happy path | Guard reject | Invalid input | Exit codes |
|-----------|-----------|-------------|--------------|-----------|
| `claim` | ✓ | ✓ double-claim | ✓ nonexistent | — |
| `complete` | ✓ | ✓ without-claim | — | — |
| `release` | ✓ | ✓ without-claim | — | — |
| `add` | ✓ | ✓ missing-fields | — | — |
| `edit` | ✓ priority | ✓ status, id, bad-enum | — | — |
| `status` | ✓ active | — | — | — |

### `kc-index.sh` (158 lines)

| Scenario | Covered |
|----------|---------|
| Empty dir | ✓ |
| Items present | ✓ |
| Priority sort | ✓ p1<p2 |
| Status filtering | ✓ active, dormant, done |
| Orphaned files | ✓ |
| Corrupt items | ✓ |
| Fail-open | ✓ |
| Relates column | ✓ empty |
| Timestamp sort | — |
| Multi-line relates | — |
| Obsolete exclusion | — |

### `kc-resurface.sh` (78 lines)

| Scenario | Covered |
|----------|---------|
| No knowledge dir | ✓ |
| Empty INDEX | ✓ |
| P1 items | ✓ |
| P2 items | ✓ |
| In-progress count | ✓ |
| Top-N limit | — |
| Column header drift | — |

### `kc-prompt-match.sh` (58 lines)

| Scenario | Covered |
|----------|---------|
| No knowledge dir | ✓ |
| Tag match | ✓ |
| Title match | ✓ |
| No match | ✓ |
| Stopwords | ✓ |
| Empty prompt | ✓ |
| 2-char terms | ✓ |
| Max limits | — |
| Dedup logic | — |
| Substring false positive | — |
