---
name: Angular Frontend Specialist
extends: frontend-developer
detect:
  - angular.json
  - angular.json + package.json
version: 1
last-reviewed: 2026-06-26
---

# Angular Frontend

## Stack Idioms & Conventions

- **NgModules** or **standalone components** (v14+). Prefer standalone for new components unless a shared module is warranted.
- **RxJS** for async data. `async` pipe in templates over manual subscription. Use `takeUntilDestroyed` (v16+) for cleanup.
- **Dependency injection** via constructor. Services provided at the appropriate level (`root`, module, or component).
- **TypeScript** strict mode (`strict: true` in `tsconfig.json`). Leverage Angular's typed forms (`FormControl<string>`).

## Test Framework

- **Karma + Jasmine** (default) or **Jest** with `jest-preset-angular` (newer projects).
- `TestBed.configureTestingModule` for component tests. `HttpClientTestingModule` for HTTP mocking.
- **Playwright** for E2E (preferred over Protractor which is EOL).

## Common Pitfalls

- **Change detection performance** — use `OnPush` strategy for presentational components. Avoid function calls in templates (they re-execute on every CD cycle).
- **Session state quirks** — Angular's `APP_INITIALIZER` can leave stale state on hot reload. Check `app-knowledge` for repo-specific session quirks.
- **Memory leaks** — unsubscribe from long-lived observables. Use `async` pipe or `takeUntilDestroyed`.
- **Bundle size** — lazy-load feature modules. Don't import heavy libraries (moment.js, lodash all) when tree-shakeable alternatives exist (`date-fns`, lodash-es single imports).

## What "Done Right" Looks Like

- `ng lint` and `ng test` pass with no warnings.
- Components use `OnPush` change detection unless there's a documented reason not to.
- Shared behavior extracted into services or directives, not duplicated across components.
- SCSS variables/ mixins used consistently; no hardcoded colors or spacing values.
