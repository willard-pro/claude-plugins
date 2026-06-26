---
name: Microservices Architecture Specialist
extends: architect
detect:
  - Multiple service directories (e.g., services/, apps/, packages/)
  - docker-compose.yml with multiple services
  - API gateway or service mesh configuration
  - Message broker configuration (Kafka, RabbitMQ)
---

# Microservices Architecture

## Architecture Idioms & Conventions

- **Bounded contexts** as the primary boundary. Each service owns its data — no shared databases between services.
- **Event-driven communication** for cross-service workflows. Events as the source of truth for state propagation. Event sourcing + CQRS where query patterns diverge significantly from write patterns.
- **API Gateway** for external traffic: rate limiting, auth, routing. Backend-for-frontend (BFF) pattern when mobile/web have different data shape needs.
- **Service mesh** (optional) for internal east-west traffic: retries, circuit breaking, mutual TLS.

## Common Pitfalls

- **Distributed monolith** — services that share a database or are deploy-coupled. Each service must be independently deployable.
- **Latency stacking** — a single user request fans out to 5 services synchronously. Use async messaging or aggregation layers.
- **Distributed transactions** — never use 2PC across services. Use Saga pattern (choreography or orchestration) for multi-step workflows.
- **Inconsistent observability** — each service must emit structured logs, metrics, and traces with a shared correlation ID.

## What "Done Right" Looks Like

- Service boundaries align with business domains (not technical layers).
- Inter-service contracts versioned and backward-compatible. Breaking changes use a new major version or a new event type.
- Each service has its own CI/CD pipeline. Changes to one service don't require rebuilding others.
- Distributed tracing (OpenTelemetry) propagates trace context across all service boundaries.
