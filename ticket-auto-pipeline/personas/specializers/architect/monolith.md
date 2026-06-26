---
name: Monolith Architecture Specialist
extends: architect
detect:
  - Single service directory structure
  - No multi-service orchestration files
  - Single deployable artifact (one Dockerfile, one build output)
version: 1
last-reviewed: 2026-06-26
---

# Monolith Architecture

## Architecture Idioms & Conventions

- **Modular monolith** over big ball of mud. Clear module boundaries with explicit public APIs per module. Modules communicate through defined interfaces, not by reaching into each other's internals.
- **Layered architecture**: presentation → application → domain → infrastructure. Dependencies point inward. Domain layer has no framework imports.
- **Feature-based packaging**: `com.example.orders.{api, application, domain, infrastructure}` rather than `com.example.{controllers, services, repositories}`.
- **Single deployable** with well-defined startup order. Database migrations run before the app serves traffic.

## Common Pitfalls

- **Tight coupling** — modules importing across boundaries without going through the public API. Enforce with ArchUnit (Java) or import-linter (Python/Node).
- **Deployment coordination** — large deployable means more risk per deploy. Mitigate with feature flags and canary deployments.
- **Growing test suite time** — as the monolith grows, full test runs slow down. Use test impact analysis to run only affected tests in CI pre-merge.
- **Path to extraction** — don't lock in the monolith forever. Keep modules clean enough that a high-traffic module can be extracted to a service later.

## What "Done Right" Looks Like

- Module boundaries enforced by tooling (lint rules, ArchUnit, dep-cruiser), not convention alone.
- New features added within a single module unless they cross a well-defined bounded context.
- Database migrations run in a single transactional step; rollback tested.
- The monolith can be split into services without a rewrite — the module boundaries are the future service boundaries.
