# ticket-planner Documentation

Architecture, contracts, and reference documentation for the ticket-planner plugin.

## Architecture

- [ticket-planner.md](ticket-planner.md) — Full architecture reference: 9-phase state machine, contracts (Planner Context block, labels, artifact plane, feedback), confidence derivation, dependency validation, re-planning, determinism boundary, configuration, and planned-entry gate dormancy rationale.

## Format Specs

- [../state-log-format.md](../state-log-format.md) — State log format spec: `ISO|PHASE|STEP|STATUS|MSG` schema, phases and steps, statuses, META pseudo-phase, integrity guarantees.

## Diagrams

- [../../docs/ticket-planner-pipeline-diagram.html](../../docs/ticket-planner-pipeline-diagram.html) — Interactive 9-phase pipeline diagram with drill-down detail panels (GitHub Pages).

## Skill Reference

- [../skills/ticket-planner/SKILL.md](../skills/ticket-planner/SKILL.md) — Skill procedure: modes (`plan`, `resume`, `status`, `replan`), phase table, contracts, determinism boundary, configuration, and implementation instructions.

## Related Plugins

- [ticket-auto-pipeline](../ticket-auto-pipeline/) — Downstream consumer of planner output
- [fleet-controller](../fleet-controller/) — Dispatch orchestrator between planner and ticket-auto
