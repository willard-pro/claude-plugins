# ticket-auto-pipeline docs

Deep-dive reference documentation for maintainers and advanced users.

## Format specs

- [Pipeline log format](../pipeline-log-format.md) — `ISO|PHASE|STEP|STATUS|MSG` schema
- [Heartbeat log format](../pipeline-heartbeat-format.md) — `ISO|CATEGORY|EVENT|STATUS|MSG|DETAIL` schema

## Ticket templates

- [Templates overview](../templates/README.md) — field-to-pipeline-phase mapping; why each field matters
- [bug.md](../templates/bug.md) — Steps to Reproduce, Expected/Actual Behaviour, atomic acceptance criteria
- [feature.md](../templates/feature.md) — Background, Proposed Behaviour, Out of Scope, atomic acceptance criteria
- [improvement.md](../templates/improvement.md) — Current/Desired Behaviour, Motivation, atomic acceptance criteria
- [security.md](../templates/security.md) — Attack Scenario, Severity, security-observable acceptance criteria

## Design & planning

- [LLM integration idea](llm-integration-idea.md) — Local LLM (ollama + qwen2.5) for pipeline classification tasks
- [Documentation audit (2026-05-18)](documentation-audit-2026-05-18.md) — Prior doc gap analysis and remediation plan

