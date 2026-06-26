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

| File | Role | Used by |
|------|------|---------|
| `base/architect.md` | Systems architecture specialist | appraise, implement, pr-review |
| `base/backend-developer.md` | API and server-side specialist | implement (BE), audit |
| `base/frontend-developer.md` | UI/UX and accessibility specialist | implement (FE), audit |
| `base/qa-engineer.md` | Quality advocate and testing specialist | verify, implement, pr-review |
| `base/analyzer.md` | Root cause specialist and systematic investigator | appraise, pr-review, critique |
| `base/product-owner.md` | Product requirement specialist | audit, appraise |
| `base/security.md` | Threat modeler and vulnerability specialist | implement, pr-review, audit (auto-include) |
| `base/technical-writer.md` | Documentation and technical writing specialist | document, retro, wiki-maintenance |

### Specializers (14)

| Group | Stack | Extends |
|-------|-------|---------|
| `backend` | `python.md` | backend-developer |
| `backend` | `python-refactor.md` | backend-developer (refactor override) |
| `backend` | `node.md` | backend-developer |
| `backend` | `node-refactor.md` | backend-developer (refactor override) |
| `backend` | `java.md` | backend-developer |
| `backend` | `java-migration.md` | backend-developer (migration override) |
| `backend` | `java-refactor.md` | backend-developer (refactor override) |
| `frontend` | `angular.md` | frontend-developer |
| `frontend` | `react.md` | frontend-developer |
| `frontend` | `vue.md` | frontend-developer |
| `qa` | `playwright-web.md` | qa-engineer |
| `qa` | `api-testing.md` | qa-engineer |
| `architect` | `microservices.md` | architect |
| `architect` | `monolith.md` | architect |
