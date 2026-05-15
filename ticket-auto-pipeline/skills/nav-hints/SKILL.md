---
name: nav-hints
description: Navigation hint lookup for browser-based ticket work. Returns exact click-by-click paths to reach feature areas without direct URL navigation (which breaks Angular session state). Use when ticket-verify or ticket-reproduce needs to navigate the app, or when the user asks "how do I get to X in the app".
---

# Nav Hints

You have been given an area name as the argument (e.g. `progress`, `payments`, `correspondents`). Return the exact click-by-click navigation path to reach that area. **Never use `page.goto()` for in-app navigation** — always click through the UI because Angular loses session state on full page reload.

## Arguments

| Usage | Purpose |
|-------|---------|
| `/nav-hints <area>` | Return the click path for `<area>`. Fuzzy matches if exact not found. |
| `/nav-hints add` | Record a new hint. Prompts for area name, path, and steps. Appends to the project hints file. |
| `/nav-hints list` | Print all known areas for the current project. |

If no argument: print all known areas.

## Step 1 — Load the hints file

Read `{TICKETS_ROOT}/nav-hints.md` in the current working directory. If missing, create it from the template below.

`{TICKETS_ROOT}` is the current working directory (must be `tickets`).

## Step 2 — Match the area

If `<area>` provided:
- Exact match on the hint heading (case-insensitive) → return that hint.
- Partial/fuzzy match → list candidate headings, ask user to pick.
- No match → report "No hint for '{area}'. Known areas: {list}. Use `/nav-hints add` after successful navigation to record it."

If `add`:
- Ask: "What area did you just reach? (short label, e.g. 'Handover Progress')"
- Ask: "What is the URL path pattern? (e.g. `/handover-progress/{id}`)"
- Ask: "What click-by-click steps got you there? Start from the nav bar or handover list."
- Ask: "Which ticket was this for? (e.g. CRE-45)"
- Append the hint to `{TICKETS_ROOT}/nav-hints.md` in the format below.
- Tell the user: "Saved. Future tickets can use `/nav-hints {area}`."

If `list` or no argument:
- Print every known area heading and a one-line summary of its path.

## Step 3 — Return the path

For the matched hint, print:

```
## {Area Name}
**URL pattern:** {path}
**How to reach:**
1. {step 1}
2. {step 2}
...
**Learned from:** {ticket IDs}
```

The calling skill (verify/reproduce) uses these steps verbatim to execute Playwright clicks.

## Hints file format

`{TICKETS_ROOT}/nav-hints.md`:

```markdown
# Navigation Hints — {PROJECT_NAME}

Hints are learned during ticket verification and reproduction sessions.
Never hand-edit — use `/nav-hints add` to append.

## {Area Name}
- **Path:** {URL pattern, e.g. `/handover-payment/{id}`}
- **How to reach:** {numbered click-by-click steps}
- **Learned from:** {TICKET-ID}
- **Date:** {YYYY-MM-DD}
```

Template for new files:

```markdown
# Navigation Hints — {PROJECT_NAME}

Hints are learned during ticket verification and reproduction sessions.
Never hand-edit — use `/nav-hints add` to append.

## Handover List
- **Path:** `/handover`
- **How to reach:** Click "Handovers" in the nav bar. Default filter is "Active" (which = LEGAL state for Attorney users). If nav bar doesn't show Handovers link after login, log in again — first login sometimes fails to update nav (see app-knowledge Known Quirks).
- **Learned from:** CRE-39, CRE-43
- **Date:** 2026-05-05
```

## Rules

- **No direct URLs.** Every hint must use click-by-click instructions. Calling code must use Playwright click actions, never `page.goto()`.
- **Hints are project-scoped.** The file lives in `{TICKETS_ROOT}/nav-hints.md`, one per tickets workspace.
- **Add after successful navigation.** When a verify/reproduce session reaches a new area through the UI, save the path immediately (Step 4a in ticket-verify already does this — this skill centralizes it).
- **Date and ticket source.** Every hint records when it was learned and from which ticket, so stale hints can be identified.
