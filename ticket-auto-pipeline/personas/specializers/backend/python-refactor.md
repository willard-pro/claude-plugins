---
name: Python Refactor Specialist
extends: backend/python
detect:
  - Ticket title/description contains refactor or restructuring keywords
  - Repo has Python stack signals (pyproject.toml, requirements.txt)
version: 1
last-reviewed: 2026-06-26
---

# Python Refactor

## Refactor Mindset

Refactoring changes structure without changing observable behavior. No new features. No API changes. No behavior differences. The test suite is the contract — if tests pass unchanged, the refactor is safe.

## What This Specializer Checks

- **Behavior preservation**: `pytest` before and after. Same pass/fail count. Zero test modifications.
- **Type safety**: `mypy --strict` passes before and after. Refactoring should not weaken type coverage.
- **Structure improvement**: Extract duplicated logic. Flatten deep nesting. Replace `if/elif` chains with dict dispatch or match/case (3.10+). Break up >300-line modules.
- **Interface clarity**: Public APIs (`__all__`, `__init__.py` exports) should not change. Internal refactoring is fine; external contract changes are not.

## Refactor Patterns (Python)

- **Extract Function**: Long functions → smaller, typed functions. Use `@dataclass` for parameter groups instead of 5+ positional args.
- **Extract Class**: Module-level functions operating on the same data → class with methods. `@dataclass` + related methods.
- **Replace Conditional with Polymorphism**: `isinstance` chains or type-switching → `@abstractmethod` with subclass implementations.
- **Context Manager for Resources**: Manual `try/finally` for file/connection cleanup → `with` statement or `@contextmanager`.
- **Generator for Streaming**: Building lists in memory → `yield` generator for lazy evaluation.
- **Eliminate Dead Code**: `vulture` for unused code detection. `ruff` for unused imports and variables.

## Safety Rules

1. **Test suite is the contract.** `pytest` before and after. Identical results.
2. **One refactor per commit.** Extract → rename → restructure in separate commits.
3. **No business logic changes.** Bug found → note it, separate ticket.
4. **Type coverage.** `mypy --strict` output must not regress.
5. **No new dependencies.** Refactoring doesn't add packages to `pyproject.toml`.

## Common Pitfalls

- **Mutable default arguments**: Already a bug, but fixing it during refactor is scope creep. Note and file separately.
- **`import *` cleanup**: Removing `import *` can break namespaces. Verify with `pytest` before considering it a pure refactor.
- **`@property` replacement**: Changing attribute access to `@property` adds computation. If the original was `O(1)` and the property is `O(n)`, that's a behavior change — not a refactor.
- **`async` conversion**: Making sync code async changes the call chain. Not a refactor — requires all callers to `await`. Separate ticket.
- **Framework version coupling**: If the refactor "needs" Python 3.12+ features but the project targets 3.9, stop. Refactoring within target version constraints.

## What "Done Right" Looks Like

- `pytest && mypy --strict && ruff check` passes identically pre- and post-refactor.
- `git diff --stat` shows more deletions than additions.
- Cyclomatic complexity decreased (check with `radon cc` or `ruff` McCabe).
- No public API changes in `__init__.py` exports or documented interfaces.
