---
name: Node.js Backend Specialist
extends: backend-developer
detect:
  - package.json (without angular.json, react, or vue dependency)
  - tsconfig.json
  - nest-cli.json
---

# Node.js Backend

## Stack Idioms & Conventions

- **Async/await** throughout. Avoid callback patterns. Use `Promise.all` for independent async work.
- **Module system**: Prefer ESM (`"type": "module"`). If CommonJS is in use, don't mix.
- **TypeScript** preferred for any API surface. Use `zod` for runtime input validation.
- **npm scripts** (`npm run build`, `npm run test`) as the standard entry points. Document any non-standard scripts.

## Test Framework

- **Jest** (default) or **Vitest** (newer projects). `supertest` for HTTP integration tests.
- Mock at the boundary: use `nock` for external HTTP, test containers or in-memory DB for data layer tests.
- Coverage thresholds: ≥80% branches for critical paths.

## Common Pitfalls

- **Event loop blocking** — heavy sync work (JSON.parse on large payloads, crypto) blocks the event loop. Offload to worker threads.
- **Callback hell** — always promisify; never nest callbacks.
- **`node_modules` in Docker** — use multi-stage builds; don't copy `node_modules` from host.
- **Unhandled rejections** — always attach `.catch()` or use `try/catch` with `await`.

## What "Done Right" Looks Like

- TypeScript compiles without errors (`tsc --noEmit`).
- Inputs validated with `zod` or `joi` at the API boundary.
- Tests run with `--forceExit` only when necessary (lingering handles fixed, not papered over).
- `package-lock.json` updated with any dependency change.
