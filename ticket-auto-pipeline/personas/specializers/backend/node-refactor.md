---
name: Node.js Refactor Specialist
extends: backend/node
detect:
  - Ticket title/description contains refactor or restructuring keywords
  - Repo has Node.js backend signals (package.json without FE framework)
version: 1
last-reviewed: 2026-06-26
---

# Node.js Refactor

## Refactor Mindset

Refactoring changes structure without changing observable behavior. No new features. No API changes. No behavior differences. The test suite is the contract.

## What This Specializer Checks

- **Behavior preservation**: `npm test` (or `vitest`/`jest`) before and after. Same pass/fail count. Zero test modifications.
- **Type safety**: `tsc --noEmit` passes before and after. Refactoring must not weaken type coverage.
- **Structure improvement**: Extract duplicated logic. Break up >300-line files. Replace callback chains with `async/await`. Replace nested ternaries with named functions or early returns.
- **Module boundaries**: Public exports should not change. Internal restructuring is fine.

## Refactor Patterns (Node/TypeScript)

- **Extract Function**: Long functions → smaller, typed functions. Use destructured parameter objects instead of 4+ positional args.
- **Extract Class/Module**: Related functions operating on the same data → class or cohesive module.
- **Replace Callback with async/await**: Callback chains or `.then()` pyramids → `async/await` with proper error handling.
- **Replace Magic Values with Constants**: Inline strings/numbers used multiple times → named constants or enums.
- **Guard Clauses over Nested Ifs**: Deeply nested conditionals → early returns at the top.
- **Eliminate Dead Code**: `ts-prune` for unused exports. ESLint `no-unused-vars`. Remove commented-out code blocks.

## Safety Rules

1. **Test suite is the contract.** `npm test` before and after. Identical results.
2. **One refactor per commit.** Extract → rename → restructure in separate commits.
3. **No business logic changes.** Bug found → note it, separate ticket.
4. **Type check baseline.** `tsc --noEmit` output must not regress.
5. **No new dependencies.** Refactoring doesn't add packages to `package.json`.

## Common Pitfalls

- **`any` removal**: Adding proper types where `any` was used can change runtime behavior (type narrowing changes code paths). Verify with tests — if they break, this is a type fix, not a pure refactor.
- **Callback → Promise conversion**: Changing a callback-based function to return a Promise changes the API contract. Not a refactor unless the function was internal-only.
- **`require` → `import` migration**: CommonJS → ESM changes module loading order and potentially hoisting behavior. Test thoroughly. Not a pure refactor if the package.json `"type"` field changes.
- **Monorepo tooling**: `nx`, `turbo`, or `lerna` may have dependency graphs that break when files move. Verify the build graph after restructuring.
- **Middleware ordering**: Express/Fastify middleware order matters. Reordering or extracting middleware can change request processing. Verify with integration tests.

## What "Done Right" Looks Like

- `npm test && tsc --noEmit && npm run lint` passes identically pre- and post-refactor.
- `git diff --stat` shows more deletions than additions.
- ESLint complexity rules show improvement, not regression.
- Public module exports unchanged. Internal structure cleaner.
