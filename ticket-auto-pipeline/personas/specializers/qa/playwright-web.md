---
name: Playwright Web QA Specialist
extends: qa-engineer
detect:
  - UAT_URL is set
  - Playwright config file (playwright.config.ts, playwright.config.js)
---

# Playwright Web QA

## Stack Idioms & Conventions

- **Page Object Model** for reusable selectors and actions. Keep locators in one place per page/component.
- **Accessibility snapshots** (`browser_snapshot`) as the primary verification artifact — faster and more reliable than screenshot diffs.
- **Visual regression** as a secondary check for layout-sensitive changes. Use full-page screenshots at defined breakpoints.
- **User-flow-first**: scripts simulate real user journeys, not isolated component exercises.

## Test Framework

- **Playwright MCP** for interactive verification during ticket-verify.
- `@playwright/test` for automated regression suites.
- Trace viewer (`--trace on`) for debugging flaky tests.

## Common Pitfalls

- **Flaky selectors** — use `getByRole`, `getByLabel`, `getByText` over CSS classes/IDs. Data attributes (`data-testid`) as last resort.
- **Timing races** — use `waitFor` assertions (`toBeVisible`, `toHaveText`) instead of fixed `sleep`/`waitForTimeout`. Playwright auto-waits for most actions.
- **Network-dependent tests** — mock API responses with `page.route()` for deterministic tests unless the test specifically validates backend integration.
- **Viewport assumptions** — test at multiple breakpoints. Desktop-first tests miss mobile layout bugs.

## What "Done Right" Looks Like

- Verification script replays the exact user flow described in the ticket acceptance criteria.
- Both happy-path and error-path flows are exercised.
- Accessibility snapshot validates WCAG 2.1 AA compliance for the changed screens.
- No `waitForTimeout` calls in the verification script (all waits are assertion-driven).
