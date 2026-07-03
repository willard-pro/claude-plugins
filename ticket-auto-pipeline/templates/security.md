# Security Issue Template

> Copy everything below this line into the Linear ticket description.
> Fill in `{placeholders}`. Remove any sections that don't apply.
> Labels to set: `security`
> ⚠ Do NOT include exploit details or credentials in the Linear ticket — reference a private document or Slack thread instead.

---

{Descriptive Name}

## Summary

{One sentence: what the vulnerability is, where it exists, and the potential impact.}

## Vulnerability Type

{OWASP category or plain description — e.g. "Broken Access Control", "SQL Injection", "Sensitive Data Exposure", "Insecure Direct Object Reference"}

## Severity

- [ ] Critical — remote code execution, full data breach, auth bypass
- [ ] High — privilege escalation, significant data exposure, unauthenticated access
- [ ] Medium — authenticated attacker can access data/actions outside their role
- [ ] Low — minimal impact, defence-in-depth improvement

## Affected Component

| Layer | Service       | File / Endpoint / Area       |
| ----- | ------------- | ---------------------------- |
| FE    | gateway       | {component / API call}       |
| BE    | {service}     | {controller / endpoint}      |

## Attack Scenario

{Describe the attack path without including working exploit code or real credentials.
Example: "An authenticated user with role X can call endpoint Y with a forged ID to retrieve records belonging to another organisation."}

## Impact

{What an attacker can achieve — data accessed, actions performed, systems affected.}

## Acceptance Criteria

- [ ] {Observable security control — e.g. "Calling GET /api/handovers/{id} with a handover belonging to a different org returns 403"}
- [ ] {Observable security control — e.g. "No stack trace or internal path appears in the error response body"}
- [ ] {Observable security control}

> One criterion per line. Each must be independently verifiable via the UI or API.

## Test User

`{email or role}` — password `admin`

## Reproduction Steps

1. Log in as `{low-privilege role}`
2. Navigate via `{Menu > Submenu}` or call `{endpoint}` directly
3. {Action that demonstrates the vulnerability}
4. {Observe the unintended result}

## Test Data Prerequisites

{What must exist — e.g. "Two separate orgs each with at least one handover."}

## References

{CVE, OWASP link, internal Slack thread, or security report — no working exploits here.}

## Related Tickets

{Linear IDs, or None}
