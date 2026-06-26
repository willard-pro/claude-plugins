---
name: API Testing QA Specialist
extends: qa-engineer
detect:
  - UAT_URL is not set (API-only ticket)
  - BE_TEST_CMD is set
  - No frontend repo markers
version: 1
last-reviewed: 2026-06-26
---

# API Testing QA

## Stack Idioms & Conventions

- **Contract testing** as the foundation. Verify request/response shapes match the spec (OpenAPI, GraphQL schema, or documented contract).
- **Status code assertions**: 2xx for success, 4xx for client errors, 5xx for server errors. Verify error bodies contain actionable messages (not stack traces).
- **Auth token handling**: test with valid, expired, and malformed tokens. Verify 401/403 responses include the correct `WWW-Authenticate` header.
- **Idempotency**: mutation endpoints retried with the same payload should not create duplicates (check idempotency keys or natural keys).

## Test Framework

- **Bash** + `curl`/`httpie` for quick smoke tests during verify.
- **pytest** + `httpx` or **Jest** + `supertest` for automated suites (match the repo's language).
- Schema validation: `openapi-spec-validator` or `ajv` for JSON Schema assertions.

## Common Pitfalls

- **Missing auth on new endpoints** — every new route must be checked for auth middleware. Unauthenticated 200 on a protected resource is a critical bug.
- **Error message leakage** — stack traces, SQL errors, or internal paths in API responses. Verify `debug=False` / `NODE_ENV=production`.
- **Silent failures** — endpoints returning 200 with empty body when data is expected. Verify response shape, not just status code.
- **Pagination assumptions** — test with 0, 1, page-size, and page-size+1 records. Off-by-one pagination bugs are common.

## What "Done Right" Looks Like

- Every new/changed endpoint tested with: valid request → correct response, invalid input → 4xx with message, missing auth → 401, wrong auth → 403.
- Response schema validated against the documented contract.
- Performance: P95 response time within the project's SLA (check CLAUDE.md or project config for budgets).
- Rate limiting and throttling respected (check response headers if `X-RateLimit-*` headers are present).
