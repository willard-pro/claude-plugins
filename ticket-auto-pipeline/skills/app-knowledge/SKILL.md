---
name: app-knowledge
description: Reference knowledge base for Credit Network app business rules, user roles, UI behaviour, and system conventions. Use this as a lookup when browsing the site via Playwright or when reasoning about role-based behaviour. Not an interactive skill — read this file directly when you need context about how the app works. Companion: /nav-hints for click-by-click navigation paths.
---

# Credit Network App — Business & System Knowledge

This file is a living reference. Append new learnings at the bottom of each section as they are discovered during Playwright sessions or ticket work.

---

## Environments

| Name | URL | Notes |
|---|---|---|
| Local (dev) | http://localhost:9000 | Runs against local microservices |
| UAT | https://uat.credit-network.biz | Staging environment |

---

## User Roles & Profiles

Roles are encoded in the JWT and decoded client-side by the Angular app. The UI adapts dynamically — labels, available actions, and visible states differ per profile.

| Profile | Example User | Organisation type | Notes |
|---|---|---|---|
| Attorney | sandra@sdtlaw.co.za | Law firm (e.g. SDT INCORPORATED) | Sees LEGAL state handovers as "Active"; limited action set |
| Collection Agency | — | Debt collection agency | Sees full handover lifecycle |

### Attorney-specific behaviour
- **"Active" filter on /handover = LEGAL state** for Attorney users. The JWT profile causes the Angular app to label LEGAL-state handovers as "Active" in the UI. This is decoded from the JWT by the frontend JS — it is not a separate API filter.
- Attorneys can only see/interact with handovers assigned to their organisation.
- Some action buttons in the handover list are access-restricted for attorneys (e.g. clicking the view/detail icon may redirect to `/accessdenied`).

---

## Handover States

Internal state names (used in code/enums) vs UI labels:

| Internal state (HandoverState enum) | UI label for Attorney | UI label for Agency |
|---|---|---|
| LEGAL | Active | Legal |
| OPEN | — (not visible) | Open / Pre-legal |
| CLOSED | Closed | Closed |

> **Source:** Confirmed during CRE-39 verification (2026-04-10). Attorney JWT causes Angular to present LEGAL state as "Active".

---

## Navigation Patterns

### Handover list
- **Path:** `/handover`
- **Default filter:** Active (which = LEGAL for attorneys)
- **Action icons per row (left to right, confirmed CRE-45):**
  1. Book → Documents (`/handover-document/{id}`)
  2. Comments
  3. Receipt → Payments (`/handover-payment/{id}`)
  4. Toolbox dropdown — contains: Correspondents, Fees, Defendant, Reference
- **Note:** The **Book/Documents** (1st) button may return `/accessdenied` for attorney users — attorneys should use the correct icon for their feature. For correspondents, use the toolbox dropdown (4th icon), not a direct icon.

### Handover Correspondents
- **How to reach:** From `/handover` list, click the **toolbox dropdown** (4th icon on row) → **Correspondents**
- **Attorney access:** Enabled for LEGAL state handovers (post CRE-39 fix)
- **Add Correspondent button:** Split button — main action + dropdown arrow to select correspondent type

### Handover Payments
- **How to reach:** From `/handover` list, click the **receipt icon** (3rd icon on row)
- **URL pattern:** `/handover-payment/{id}`
- **Learned from:** CRE-45
- **Date:** 2026-05-05

### Handover Documents
- **How to reach:** From `/handover` list, click the **book icon** (1st icon on row)
- **URL pattern:** `/handover-document/{id}`
- **Learned from:** CRE-45
- **Date:** 2026-05-05

---

## Role-Based UI Rules (confirmed)

| Feature | Attorney behaviour | Agency behaviour |
|---|---|---|
| Add Correspondent button | Enabled in LEGAL state (CRE-39 fix) | Enabled when not in LEGAL state |
| Correspondent types available | Plaintiff, Defendant, Attorney (same org) | Collection Agency types |
| Payment creation | Not permitted (CRE-36) | Permitted |
| Set Preferred correspondent | Disabled (CRE-41) | Enabled |
| Delete Correspondent | Disabled (CRE-42) | Enabled |

---

## Known Quirks

- Page title on `/handover` shows `translation-not-found[gatewayApp.Handover.home.title]` — missing i18n key, pre-existing cosmetic issue unrelated to attorney functionality.
- The nav bar shows the organisation name (e.g. "S DU TOIT") when logged in — use this to confirm authentication.
- **Intermittent: nav bar fails to update after first login.** Authentication succeeds but the Account dropdown still shows "Sign in" and Handovers/Administration links are absent. Root cause: Angular doesn't re-render nav after POST /api/represent completes. **Diagnostic:** Check network requests after login — `POST /api/represent` must return 200 for nav to render. Post-login call chain: authenticate → account → body-groups/trade → represent → creditreport/*. If represent is missing or pending, nav stays broken. **Workaround:** Sign out, sign in again — second login always fires represent and nav loads correctly. Observed Apr 11 (CRE-39) and May 5 (CRE-43).

---

## Append new learnings below this line

<!-- Format: ### YYYY-MM-DD — {TICKET-ID or "Session"}: {one-line summary of what was learned} -->
