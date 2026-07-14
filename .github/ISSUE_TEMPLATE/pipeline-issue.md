---
name: Pipeline Issue
description: Bug, regression, or improvement for the ticket-auto-pipeline
labels: []
body:
  - type: markdown
    attributes:
      value: |
        > This template is designed for **agent handoff** — another Claude Code agent should be able to pick this up from the information provided and implement a fix without additional context.
        > Remove sections that don't apply. No ticket IDs or user data in any field.

  - type: dropdown
    id: severity
    attributes:
      label: Severity
      description: How badly does this affect the pipeline?
      options:
        - P0 — breaks every run
        - P1 — blocks or delays pipeline
        - P2 — causes silent failures or degraded behavior
        - P3 — quality / hygiene
    validations:
      required: true

  - type: dropdown
    id: component
    attributes:
      label: Affected Component
      description: Which part of the pipeline is affected?
      options:
        - lib/ — shared library script
        - ticket-auto — orchestrator
        - ticket-appraise — investigation phase
        - ticket-appraise-exec — artifact creation
        - ticket-flow — state machine
        - ticket-implement — implementation phase
        - ticket-verify — UAT verification
        - ticket-pr-review — PR review & merge
        - ticket-setup — workspace creation
        - ticket-env-check — environment validation
        - ticket-prescan — repo pre-scanning
        - ticket-retro — retrospection
        - gate-check — gate logic
        - Multiple components
    validations:
      required: true

  - type: textarea
    id: current-behavior
    attributes:
      label: Current Behavior (Actual)
      description: What actually happens? Include sanitized log excerpts (no ticket IDs, no user data, no timestamps with identifiable info).
      render: shell
      placeholder: |
        api|linear-request|fail|GraphQL call failed|{"elapsed_ms":"389","http_code":"200"}
        retry|classify|info|transient: HTTP 200
    validations:
      required: true

  - type: textarea
    id: expected-behavior
    attributes:
      label: Expected Behavior
      description: What should happen instead?
      placeholder: |
        HTTP 200 with GraphQL errors in body → classified as terminal, no retry, error message surfaced.
        HTTP 503 / connection refused → classified as transient, retried with backoff.
    validations:
      required: true

  - type: textarea
    id: steps-to-reproduce
    attributes:
      label: Steps to Reproduce
      description: Numbered, atomic steps. Include exact commands where applicable. Someone unfamiliar with the pipeline should be able to follow these.
      placeholder: |
        1. Run ticket-auto-pipeline against a ticket in Backlog state
        2. Observe the heartbeat log during linear-api calls
        3. When a GraphQL call returns HTTP 200 with errors in body, note the retry classification
    validations:
      required: true

  - type: textarea
    id: root-cause
    attributes:
      label: Root Cause
      description: Which code path causes this? What's the mechanism? Be specific about the logic error.
    validations:
      required: true

  - type: textarea
    id: handover
    attributes:
      label: Handover Package
      description: |
        Everything an agent needs to implement the fix:
        - Exact file paths relative to repo root
        - Functions or line ranges to modify
        - Suggested fix approach (pseudocode or diff acceptable)
        - Constraints or invariants to preserve
      placeholder: |
        **Files to modify:**
        - `ticket-auto-pipeline/lib/linear-api.sh` — `linear_graphql()` function (~L40-L80)

        **Approach:**
        1. Parse response body for GraphQL errors before classifying as transient
        2. HTTP 200 with `{"errors":[...]}` → terminal failure, extract messages, exit non-zero
        3. Only retry on actual network failures (timeout, 5xx, connection refused)

        **Constraints:**
        - Must preserve idempotency of retry for genuine network blips
        - GraphQL error format: `{"errors":[{"message":"...","extensions":{"code":"..."}}]}`
    validations:
      required: true

  - type: textarea
    id: verification
    attributes:
      label: Verification Checklist
      description: Observable, testable criteria. Check each off to confirm the fix is complete.
      placeholder: |
        - [ ] Run existing test suite — all pass
        - [ ] Mock: HTTP 200 + GraphQL errors → exits non-zero, no retry loop
        - [ ] Mock: HTTP 503 → retries with backoff, eventually fails
        - [ ] Mock: valid response → succeeds as before (no regression)
    validations:
      required: true

  - type: textarea
    id: related
    attributes:
      label: Related
      description: Links to other issues, docs, or code paths that inform this fix. Use `#N` for issue references.
