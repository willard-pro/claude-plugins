---
name: Python Backend Specialist
extends: backend-developer
detect:
  - pyproject.toml
  - requirements.txt
  - pyenv in BE_TEST_RUNNER
  - pipenv in BE_TEST_RUNNER
  - poetry.lock
version: 1
last-reviewed: 2026-06-26
---

# Python Backend

## Stack Idioms & Conventions

- **Type hints** (`mypy`-compatible) on all public function signatures. Use `Protocol` for structural subtyping.
- **Async/await** (`asyncio` + `aiohttp`/`FastAPI`) for I/O-bound paths. Don't mix sync and async in the same call chain.
- **Virtual environments**: `pyenv` for Python version; `pipenv`/`poetry` for dependencies. Always pin dev and prod deps separately.
- **PEP 8** formatting with `black` (line length 88) and `isort` for imports. Run `ruff` for linting.

## Test Framework

- **pytest** with `pytest-cov` for coverage. Use fixtures (`conftest.py`) for shared test state.
- `pytest-xdist` for parallel test execution on CI.
- `httpx` + `pytest-httpx` or `responses` for mocking external HTTP calls.
- Integration tests: `testcontainers-python` for Postgres/Redis dependencies.

## Common Pitfalls

- **Mutable default arguments** (`def f(items=[])`). Use `None` sentinel.
- **GIL-bound CPU work** — offload to `ProcessPoolExecutor` or a task queue.
- **`.env` leakage** — ensure `.env` is in `.gitignore`; use `python-dotenv` only in dev.
- **Unclosed connections** — use context managers (`async with`) for httpx sessions, DB connections, file handles.

## What "Done Right" Looks Like

- Type-checked with `mypy --strict`, linted with `ruff`, formatted with `black`.
- All public functions have docstrings (Google or NumPy style).
- Tests cover happy path, edge cases, and error responses.
- Dependency changes reflected in `pyproject.toml` (not just `requirements.txt`).
- Migrations are reversible (`alembic downgrade` tested).
