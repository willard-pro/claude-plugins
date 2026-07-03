# Linear Ticket Templates

Three templates for creating well-structured Linear tickets that work cleanly with the ticket-auto pipeline.

| Template | Label to set | Use when |
| -------- | ------------ | -------- |
| `bug.md` | `bug` | Something that worked before is now broken |
| `feature.md` | `feature` | Net-new capability that doesn't exist yet |
| `improvement.md` | `improvement` | Improving or extending an existing feature |
| `security.md` | `security` + `bug` or `improvement` | Vulnerability, auth bypass, data exposure, or hardening |

## Why These Fields

Each field maps to a specific pipeline phase:

| Field | Used by |
| ----- | ------- |
| **Acceptance Criteria** (atomic checkboxes) | `ticket-verify` — each item becomes one browser assertion |
| **Test User** | `ticket-verify` pre-flight — avoids fallback guessing |
| **Navigation Path** (click-by-click) | `ticket-verify` — Angular loses session on direct URL navigation |
| **Scope table** | `ticket-appraise` — fires multi-service / cross-layer complexity axes |
| **Steps to Reproduce** | `ticket-verify` — used verbatim during reproduction runs |
| **Test Data Prerequisites** | `ticket-verify` pre-flight — gates whether the run can start |

## Key Rules

- **Acceptance criteria must be atomic** — one observable fact per line, no "and"
- **No raw URLs in Navigation Path** — always `Menu > Submenu > Page` click paths
- **Test User must be explicit** — `gerhard.steyn` / `admin`, not just "a logged-in user"
- **Scope table must list all affected layers** — FE + BE entries trigger cross-layer complexity scoring
