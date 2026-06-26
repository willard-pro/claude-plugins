---
name: React Frontend Specialist
extends: frontend-developer
detect:
  - react or react-dom in package.json dependencies
  - next.config.js or next.config.mjs (Next.js)
version: 1
last-reviewed: 2026-06-26
---

# React Frontend

## Stack Idioms & Conventions

- **Hooks** for state and side effects. `useState` for local state, `useReducer` for complex state machines, `useContext` for shared state. Custom hooks for reusable logic.
- **Composition over inheritance**. Components as functions. Children, render props, or slots pattern for flexibility.
- **Virtual DOM**: let React batch updates. Don't mix direct DOM manipulation unless escaping into a `useRef` portal.
- **Code splitting**: `React.lazy` + `Suspense` for route-level splitting. Dynamic `import()` for heavy dependencies.

## Test Framework

- **Jest** + **React Testing Library** for component tests. Query by role/label/text over test IDs.
- `msw` (Mock Service Worker) for API mocking at the network level.
- **Playwright** for E2E and visual regression.

## Common Pitfalls

- **Stale closures** in `useEffect`/`useCallback` — ensure dependency arrays are complete. Use `eslint-plugin-react-hooks` `exhaustive-deps` rule.
- **Unnecessary re-renders** — `React.memo` for pure presentational components. `useMemo`/`useCallback` only when profiling shows a bottleneck.
- **State colocation** — keep state as close to where it's used as possible. Don't lift state to a global store prematurely.
- **Hook ordering** — hooks must be called unconditionally and in the same order every render. Never inside conditions or loops.

## What "Done Right" Looks Like

- TypeScript compiles cleanly. Props interfaces defined for every component.
- No `any` types except at external API boundaries (with explicit casts).
- Components are accessible: semantic HTML, `aria-*` attributes, focus management for modals/popovers.
- Bundle analyzed with `webpack-bundle-analyzer` or `vite-plugin-visualizer` — no accidental heavy imports.
