---
name: Vue Frontend Specialist
extends: frontend-developer
detect:
  - vue in package.json dependencies
  - nuxt.config.js or nuxt.config.ts (Nuxt)
version: 1
last-reviewed: 2026-06-26
---

# Vue Frontend

## Stack Idioms & Conventions

- **Composition API** (`<script setup>`) preferred over Options API for new code. `ref`/`reactive` for state, `computed` for derivations, `watch` for side effects.
- **Single File Components** (`.vue`): `<template>` + `<script setup>` + `<style scoped>`. Keep components focused — one responsibility per component.
- **Reactivity system**: Vue 3 proxies are automatic. No `$set` needed. But be aware: `reactive()` on primitives doesn't work (use `ref`).
- **Pinia** for state management (replaces Vuex). Stores are composable functions.

## Test Framework

- **Vitest** (preferred) or **Jest** + `@vue/test-utils` for component tests.
- `@pinia/testing` for store mocking.
- **Playwright** for E2E. `@playwright/test` with Vue-specific locators.

## Common Pitfalls

- **Reactivity caveats** — `ref().value` in `<script>`, but auto-unwrapped in `<template>`. Destructuring `reactive()` loses reactivity (use `toRefs`).
- **Plugin conflicts** — Vue plugin install order matters. Global mixins/directives from plugins can collide.
- **Scoped styles leaking** — `:deep()` selector needed to style child components. Use sparingly; prefer prop-driven styling.
- **SSR hydration mismatch** (Nuxt) — ensure client-rendered markup matches server output. Use `<ClientOnly>` for browser-only components.

## What "Done Right" Looks Like

- TypeScript with `vue-tsc` type-checking passes.
- Components use `defineProps<T>()` with typed props interfaces.
- `v-for` always has `:key`. `v-if`/`v-for` not used on the same element.
- Pinia stores have clear actions (mutations) and getters (computed derivations).
