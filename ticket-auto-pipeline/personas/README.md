# Persona System

Self-contained role guidance for ticket-auto-pipeline skills. Plain markdown reference files — no skill activation dependency.

## How it works

1. A pipeline skill calls `lib/persona-select.sh --repo <path> [--layer FE|BE|infra] [--phase appraise|implement|review|audit]`
2. The helper emits `PERSONA_BASE`, `PERSONA_SPECIALIZER`, and `PERSONA_AUTO_INCLUDE` as `KEY=value` lines
3. The skill reads the persona files at those paths and injects their content as role context

## Selection logic

### Base persona (from Layer/phase)

| Variable | Base persona |
|----------|-------------|
| Layer = FE (implement) | `frontend-developer` |
| Layer = BE / infra (implement) | `backend-developer` |
| phase = appraise | `analyzer` |
| phase = review | `analyzer` |
| phase = audit | `product-owner` |

### Specializer (from stack signals)

| Signal | Specializer |
|--------|------------|
| `pyproject.toml` / `requirements.txt` / `pyenv`/`pipenv` in BE_TEST_RUNNER | `backend/python` |
| `pom.xml` / `build.gradle` | `backend/java` |
| `pom.xml` / `build.gradle` + ticket has upgrade/migration keywords | `backend/java-migration` |
| `pom.xml` / `build.gradle` + ticket has refactor/restructure keywords | `backend/java-refactor` |
| `pyproject.toml` / `requirements.txt` + ticket has refactor/restructure keywords | `backend/python-refactor` |
| `package.json` (Node backend) + ticket has refactor/restructure keywords | `backend/node-refactor` |
| `package.json` w/o FE framework markers | `backend/node` |
| `angular.json` | `frontend/angular` |
| `react`/`react-dom` in `package.json` | `frontend/react` |
| `vue` in `package.json` | `frontend/vue` |
| QA phase + UAT_URL present | `qa/playwright-web` |
| QA phase + no UAT_URL | `qa/api-testing` |
| Multi-service repo structure | `architect/microservices` |
| Single-service repo structure | `architect/monolith` |

### Auto-include (keyword triggers)

When ticket title/description contains: auth, authentication, login, password, credential, token, payment, billing, PII, personal data, encryption, vulnerability → auto-include `security`.

## Composition rule

Read `base/<role>.md`, then read the matching `specializers/<group>/<stack>.md`. The specializer **refines, never contradicts** the base. No match → specializer empty; base persona alone is sufficient.

## File inventory

### Base roles (8)

| File | Role | What it covers | Used by |
|------|------|----------------|---------|
| `base/architect.md` | Systems architecture specialist | System-wide impact analysis, coupling assessment, pattern consistency, scalability planning, architecture decision records | appraise, implement, pr-review |
| `base/backend-developer.md` | API and server-side specialist | API contract design, data integrity, error handling, performance optimization, idempotency, observability | implement (BE), audit |
| `base/frontend-developer.md` | UI/UX and accessibility specialist | Component architecture, UX consistency, responsive design, accessibility (WCAG 2.1 AA), bundle impact, cross-browser compatibility | implement (FE), audit |
| `base/qa-engineer.md` | Quality advocate and testing specialist | Coverage analysis, reproduction steps, regression risk, test quality, accessibility validation, performance regression detection | verify, implement, pr-review |
| `base/analyzer.md` | Root cause specialist and systematic investigator | Complexity assessment, risk surface mapping, dependency analysis, appraisal quality, PR review depth, pattern recognition | appraise, pr-review, critique |
| `base/product-owner.md` | Product requirement specialist | Business value assessment, requirement clarity, duplicate detection, merge opportunities, goal alignment, scope assessment | audit, appraise |
| `base/security.md` | Threat modeler and vulnerability specialist | Threat surface analysis, input validation, authn/authz checks, data handling, secrets management, dependency audit. Auto-includes on auth/payment/credential/PII keywords. | implement, pr-review, audit (auto-include) |
| `base/technical-writer.md` | Documentation and technical writing specialist | Changelog quality, API documentation, README updates, commit message conventions, retro documentation, wiki maintenance | document, retro, wiki-maintenance |

### Specializers (14)

| Group | Stack | Extends | What it adds | Triggers |
|-------|-------|---------|--------------|----------|
| `backend` | `python.md` | backend-developer | Type hints (mypy), async/await patterns, pytest, virtual environments (pyenv/poetry), PEP 8/ruff formatting | `pyproject.toml`, `requirements.txt`, `pyenv`/`pipenv` in BE_TEST_RUNNER |
| `backend` | `python-refactor.md` | backend/python | Behavior-preserving restructure: extract function/class, replace conditional with polymorphism, context managers, generators. Safety: test suite as contract, mypy baseline, no new deps | Python stack + ticket has refactor/restructure keywords |
| `backend` | `node.md` | backend-developer | TypeScript strict mode, ESM vs CommonJS, Zod/Joi validation, Jest/Vitest, supertest, nock mocking, event loop awareness | `package.json` without FE framework markers |
| `backend` | `node-refactor.md` | backend/node | Guard clauses, async/await over callbacks, extract function/module, eliminate dead code (ts-prune). Safety: tsc --noEmit baseline, no new deps | Node stack + ticket has refactor/restructure keywords |
| `backend` | `java.md` | backend-developer | Spring Boot conventions, constructor injection, Maven/Gradle lifecycle, JUnit 5 + Mockito, TestContainers, Flyway/Liquibase migrations | `pom.xml`, `build.gradle` |
| `backend` | `java-migration.md` | backend/java | JDK version upgrade: deprecated API scan (jdeps/jdeprscan), library compatibility matrix, javax→jakarta, module system, incremental strategy, rollback safety | Java stack + ticket has upgrade/migration keywords |
| `backend` | `java-refactor.md` | backend/java | Extract method/class, replace conditional with polymorphism, interface segregation, dependency inversion. Safety: test suite as contract, Checkstyle/SpotBugs baseline, Lombok awareness | Java stack + ticket has refactor/restructure keywords |
| `frontend` | `angular.md` | frontend-developer | Standalone components, RxJS + async pipe, OnPush change detection, lazy loading, Karma/Jasmine or Jest, SCSS conventions | `angular.json` |
| `frontend` | `react.md` | frontend-developer | Hooks (useState/useReducer/useContext), React.memo, code splitting (lazy+Suspense), Jest + RTL + msw, stale closure awareness | `react`/`react-dom` in `package.json` |
| `frontend` | `vue.md` | frontend-developer | Composition API (<script setup>), Pinia stores, ref/reactive/computed, Vitest + @vue/test-utils, scoped styles, SSR hydration (Nuxt) | `vue` in `package.json` |
| `qa` | `playwright-web.md` | qa-engineer | Page Object Model, accessibility snapshots, user-flow-first verification, getByRole/getByLabel selectors, waitFor assertions, multi-viewport testing | UAT_URL present (web flow) |
| `qa` | `api-testing.md` | qa-engineer | Contract testing (OpenAPI/JSON Schema), status code assertions, auth token handling (valid/expired/malformed), idempotency verification, error message leakage detection | No UAT_URL (API-only) |
| `architect` | `microservices.md` | architect | Bounded contexts, event-driven communication, API Gateway, Saga pattern, distributed tracing (OpenTelemetry), independent deployability | Multi-service directory structure |
| `architect` | `monolith.md` | architect | Modular monolith patterns, layered architecture, feature-based packaging, module boundary enforcement (ArchUnit/dep-cruiser), extraction-ready design | Single-service structure |
