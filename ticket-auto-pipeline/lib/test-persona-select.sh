#!/usr/bin/env bash
# test-persona-select.sh — unit tests for lib/persona-select.sh
# Tests the selection tables, specializer detection, auto-include keywords,
# graceful fallback, and error handling.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELECTOR="$SCRIPT_DIR/persona-select.sh"
PASS=0
FAIL=0

# ── Helpers ────────────────────────────────────────────────────────────────────

assert_contains() {
  local desc="$1" output="$2" key="$3" expected="$4"
  local actual
  actual=$(echo "$output" | grep "^${key}=" | cut -d'=' -f2-)
  if echo "$actual" | grep -q "$expected"; then
    PASS=$((PASS + 1))
    echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc — expected '$expected' in ${key}=${actual}" >&2
  fi
}

assert_empty() {
  local desc="$1" output="$2" key="$3"
  local actual
  actual=$(echo "$output" | grep "^${key}=" | cut -d'=' -f2-)
  if [ -z "$actual" ]; then
    PASS=$((PASS + 1))
    echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc — expected empty ${key}, got '${actual}'" >&2
  fi
}

assert_exit_code() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$actual" -eq "$expected" ]; then
    PASS=$((PASS + 1))
    echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc — expected exit $expected, got $actual" >&2
  fi
}

# ── Setup: create temp repo directories with mock files ────────────────────────

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

# Python project
mkdir -p "$TMPDIR/python-project"
touch "$TMPDIR/python-project/pyproject.toml"

# Java project
mkdir -p "$TMPDIR/java-project"
touch "$TMPDIR/java-project/pom.xml"

# Node.js backend project
mkdir -p "$TMPDIR/node-project"
cat >"$TMPDIR/node-project/package.json" <<'JSON'
{"name": "api", "dependencies": {"express": "^4.0.0"}}
JSON

# Angular project
mkdir -p "$TMPDIR/angular-project"
touch "$TMPDIR/angular-project/angular.json"
cat >"$TMPDIR/angular-project/package.json" <<'JSON'
{"name": "ng-app"}
JSON

# React project
mkdir -p "$TMPDIR/react-project"
cat >"$TMPDIR/react-project/package.json" <<'JSON'
{"name": "react-app", "dependencies": {"react": "^18.0.0", "react-dom": "^18.0.0"}}
JSON

# Vue project
mkdir -p "$TMPDIR/vue-project"
cat >"$TMPDIR/vue-project/package.json" <<'JSON'
{"name": "vue-app", "dependencies": {"vue": "^3.0.0"}}
JSON

# Unknown project (no markers)
mkdir -p "$TMPDIR/unknown-project"

# Multi-service project
mkdir -p "$TMPDIR/microservices-project/services/auth"
mkdir -p "$TMPDIR/microservices-project/services/orders"

# ── Test: Base persona selection (layer + phase combinations) ─────────────────

echo "## Base persona selection"

output=$("$SELECTOR" --repo "$TMPDIR/unknown-project" --layer FE --phase implement)
assert_contains "FE + implement → frontend-developer" "$output" "PERSONA_BASE" "frontend-developer"

output=$("$SELECTOR" --repo "$TMPDIR/unknown-project" --layer BE --phase implement)
assert_contains "BE + implement → backend-developer" "$output" "PERSONA_BASE" "backend-developer"

output=$("$SELECTOR" --repo "$TMPDIR/unknown-project" --layer infra --phase implement)
assert_contains "infra + implement → backend-developer" "$output" "PERSONA_BASE" "backend-developer"

output=$("$SELECTOR" --repo "$TMPDIR/unknown-project" --phase appraise)
assert_contains "appraise phase → analyzer" "$output" "PERSONA_BASE" "analyzer"

output=$("$SELECTOR" --repo "$TMPDIR/unknown-project" --phase review)
assert_contains "review phase → analyzer" "$output" "PERSONA_BASE" "analyzer"

output=$("$SELECTOR" --repo "$TMPDIR/unknown-project" --phase audit)
assert_contains "audit phase → product-owner" "$output" "PERSONA_BASE" "product-owner"

output=$("$SELECTOR" --repo "$TMPDIR/unknown-project" --layer FE)
assert_contains "FE layer, no phase → frontend-developer" "$output" "PERSONA_BASE" "frontend-developer"

output=$("$SELECTOR" --repo "$TMPDIR/unknown-project" --layer BE)
assert_contains "BE layer, no phase → backend-developer" "$output" "PERSONA_BASE" "backend-developer"

output=$("$SELECTOR" --repo "$TMPDIR/unknown-project")
assert_contains "no flags → analyzer (default)" "$output" "PERSONA_BASE" "analyzer"

# ── Test: Specializer detection ────────────────────────────────────────────────

echo "## Specializer detection"

output=$("$SELECTOR" --repo "$TMPDIR/python-project" --layer BE --phase implement)
assert_contains "pyproject.toml → python specializer" "$output" "PERSONA_SPECIALIZER" "backend/python"

output=$("$SELECTOR" --repo "$TMPDIR/java-project" --layer BE --phase implement)
assert_contains "pom.xml → java specializer" "$output" "PERSONA_SPECIALIZER" "backend/java"

# Migration keyword in ticket overrides standard java specializer
output=$(TICKET_TITLE="Upgrade Java from 8 to 25" "$SELECTOR" --repo "$TMPDIR/java-project" --layer BE --phase implement)
assert_contains "Java + upgrade keyword → migration specializer" "$output" "PERSONA_SPECIALIZER" "backend/java-migration"

output=$(TICKET_DESCRIPTION="Migrate all services to Java 21 LTS" "$SELECTOR" --repo "$TMPDIR/java-project" --layer BE --phase implement)
assert_contains "Java + migrate keyword → migration specializer" "$output" "PERSONA_SPECIALIZER" "backend/java-migration"

# No migration keywords → still gets standard java specializer (not migration)
output=$(TICKET_TITLE="Add new REST endpoint for orders" "$SELECTOR" --repo "$TMPDIR/java-project" --layer BE --phase implement)
assert_contains "Java + no migration keyword → standard java" "$output" "PERSONA_SPECIALIZER" "backend/java"

# Refactor keyword overrides standard specializer (Java)
output=$(TICKET_TITLE="Refactor order service to use repository pattern" "$SELECTOR" --repo "$TMPDIR/java-project" --layer BE --phase implement)
assert_contains "Java + refactor keyword → refactor specializer" "$output" "PERSONA_SPECIALIZER" "backend/java-refactor"

output=$(TICKET_DESCRIPTION="Code quality cleanup of the payment module" "$SELECTOR" --repo "$TMPDIR/java-project" --layer BE --phase implement)
assert_contains "Java + code quality cleanup keyword → refactor" "$output" "PERSONA_SPECIALIZER" "backend/java-refactor"

# Refactor keyword overrides standard (Python)
output=$(TICKET_TITLE="Refactor auth middleware for clarity" "$SELECTOR" --repo "$TMPDIR/python-project" --layer BE --phase implement)
assert_contains "Python + refactor keyword → refactor specializer" "$output" "PERSONA_SPECIALIZER" "backend/python-refactor"

# Refactor keyword (Node)
output=$(TICKET_TITLE="Restructure Express routes for consistency" "$SELECTOR" --repo "$TMPDIR/node-project" --layer BE --phase implement)
assert_contains "Node + restructure keyword → refactor specializer" "$output" "PERSONA_SPECIALIZER" "backend/node-refactor"

# Refactor without language stack → no specializer (no base stack to extend)
output=$(TICKET_TITLE="Refactor configuration loading" "$SELECTOR" --repo "$TMPDIR/unknown-project" --layer BE --phase implement)
assert_empty "refactor + unknown stack → empty specializer" "$output" "PERSONA_SPECIALIZER"

# Multi-word refactor keywords
output=$(TICKET_TITLE="Clean up the authentication service" "$SELECTOR" --repo "$TMPDIR/java-project" --layer BE --phase implement)
assert_contains "clean up keyword → refactor specializer" "$output" "PERSONA_SPECIALIZER" "backend/java-refactor"

output=$(TICKET_DESCRIPTION="Pay down technical debt in the data layer" "$SELECTOR" --repo "$TMPDIR/python-project" --layer BE --phase implement)
assert_contains "technical debt keyword → refactor specializer" "$output" "PERSONA_SPECIALIZER" "backend/python-refactor"

# Migration > refactor priority (migration wins when both keywords present)
output=$(TICKET_TITLE="Upgrade and refactor Java from 8 to 25" "$SELECTOR" --repo "$TMPDIR/java-project" --layer BE --phase implement)
assert_contains "migration + refactor → migration wins" "$output" "PERSONA_SPECIALIZER" "backend/java-migration"

# Non-Java upgrade → standard, not migration (only Java has migration specializer)
output=$(TICKET_TITLE="Upgrade Python from 3.9 to 3.12" "$SELECTOR" --repo "$TMPDIR/python-project" --layer BE --phase implement)
assert_contains "Python + upgrade → standard python (no migration override)" "$output" "PERSONA_SPECIALIZER" "backend/python"

# BE_TEST_RUNNER with pyenv + refactor → python-refactor
output=$(BE_TEST_RUNNER="pyenv exec pytest" TICKET_TITLE="Refactor auth module" "$SELECTOR" --repo "$TMPDIR/unknown-project" --layer BE --phase implement)
assert_contains "BE_TEST_RUNNER pyenv + refactor → python-refactor" "$output" "PERSONA_SPECIALIZER" "backend/python-refactor"

# Java + security auto-include + refactor (three-path emission)
output=$(TICKET_TITLE="Refactor payment processing module" "$SELECTOR" --repo "$TMPDIR/java-project" --layer BE --phase implement)
assert_contains "refactor + payment → refactor specializer" "$output" "PERSONA_SPECIALIZER" "backend/java-refactor"
assert_contains "refactor + payment → security auto-include" "$output" "PERSONA_AUTO_INCLUDE" "security"

output=$("$SELECTOR" --repo "$TMPDIR/node-project" --layer BE --phase implement)
assert_contains "package.json w/o FE → node specializer" "$output" "PERSONA_SPECIALIZER" "backend/node"

output=$("$SELECTOR" --repo "$TMPDIR/angular-project" --layer FE --phase implement)
assert_contains "angular.json → angular specializer" "$output" "PERSONA_SPECIALIZER" "frontend/angular"

output=$("$SELECTOR" --repo "$TMPDIR/react-project" --layer FE --phase implement)
assert_contains "react in package.json → react specializer" "$output" "PERSONA_SPECIALIZER" "frontend/react"

output=$("$SELECTOR" --repo "$TMPDIR/vue-project" --layer FE --phase implement)
assert_contains "vue in package.json → vue specializer" "$output" "PERSONA_SPECIALIZER" "frontend/vue"

# UAT_URL does NOT override dev stack specializer — QA specializers are selected
# separately by ticket-verify, not by persona-select.sh in implement phase
output=$(UAT_URL="http://localhost:3000" "$SELECTOR" --repo "$TMPDIR/react-project" --layer FE --phase implement)
assert_contains "UAT_URL set + FE → react specializer (not qa override)" "$output" "PERSONA_SPECIALIZER" "frontend/react"

output=$(UAT_URL="http://localhost:3000" "$SELECTOR" --repo "$TMPDIR/node-project" --layer BE --phase implement)
assert_contains "UAT_URL set + implement → node specializer (not qa override)" "$output" "PERSONA_SPECIALIZER" "backend/node"

# Microservices detection
output=$("$SELECTOR" --repo "$TMPDIR/microservices-project" --layer BE --phase implement)
assert_contains "multi-service dirs → microservices specializer" "$output" "PERSONA_SPECIALIZER" "architect/microservices"

# BE_TEST_RUNNER with pyenv
output=$(BE_TEST_RUNNER="pyenv exec pytest" "$SELECTOR" --repo "$TMPDIR/unknown-project" --layer BE --phase implement)
assert_contains "BE_TEST_RUNNER with pyenv → python specializer" "$output" "PERSONA_SPECIALIZER" "backend/python"

# ── Test: Graceful fallback for unknown stacks ─────────────────────────────────

echo "## Graceful fallback"

output=$("$SELECTOR" --repo "$TMPDIR/unknown-project" --layer BE --phase implement)
assert_empty "unknown BE stack → empty specializer" "$output" "PERSONA_SPECIALIZER"

output=$("$SELECTOR" --repo "$TMPDIR/unknown-project" --layer FE --phase implement)
assert_empty "unknown FE stack → empty specializer" "$output" "PERSONA_SPECIALIZER"

# unknown stack does not cause errors
set +e
"$SELECTOR" --repo "$TMPDIR/unknown-project" --layer BE --phase implement >/dev/null 2>&1
rc=$?
set -e
assert_exit_code "unknown stack → exit 0" 0 "$rc"

# ── Test: Auto-include security keywords ───────────────────────────────────────

echo "## Auto-include security"

output=$(TICKET_TITLE="Add user authentication system" "$SELECTOR" --repo "$TMPDIR/unknown-project")
assert_contains "auth keyword → security auto-include" "$output" "PERSONA_AUTO_INCLUDE" "security"

output=$(TICKET_DESCRIPTION="Implement payment processing for checkout" "$SELECTOR" --repo "$TMPDIR/unknown-project")
assert_contains "payment keyword → security auto-include" "$output" "PERSONA_AUTO_INCLUDE" "security"

output=$(TICKET_TITLE="Fix login redirect loop" "$SELECTOR" --repo "$TMPDIR/unknown-project")
assert_contains "login keyword → security auto-include" "$output" "PERSONA_AUTO_INCLUDE" "security"

output=$(TICKET_TITLE="Add PII data masking" "$SELECTOR" --repo "$TMPDIR/unknown-project")
assert_contains "PII keyword → security auto-include" "$output" "PERSONA_AUTO_INCLUDE" "security"

output=$(TICKET_TITLE="Update user profile page" "$SELECTOR" --repo "$TMPDIR/unknown-project")
assert_empty "no security keywords → empty auto-include" "$output" "PERSONA_AUTO_INCLUDE"

output=$(TICKET_TITLE="Optimize database queries" "$SELECTOR" --repo "$TMPDIR/unknown-project")
assert_empty "db optimization → empty auto-include" "$output" "PERSONA_AUTO_INCLUDE"

# Case-insensitive match
output=$(TICKET_TITLE="Refactor Authentication Middleware" "$SELECTOR" --repo "$TMPDIR/unknown-project")
assert_contains "case-insensitive auth match" "$output" "PERSONA_AUTO_INCLUDE" "security"

# ── Test: Error handling ──────────────────────────────────────────────────────

echo "## Error handling"

set +e
"$SELECTOR" --phase implement 2>&1
rc=$?
set -e
assert_exit_code "missing --repo → exit 1" 1 "$rc"

set +e
"$SELECTOR" --repo "$TMPDIR/unknown-project" --layer INVALID 2>&1
rc=$?
set -e
assert_exit_code "invalid --layer → exit 1" 1 "$rc"

set +e
"$SELECTOR" --repo "$TMPDIR/unknown-project" --phase unknown 2>&1
rc=$?
set -e
assert_exit_code "invalid --phase → exit 1" 1 "$rc"

# ── Test: All emitted paths reference existing files ───────────────────────────

echo "## Path existence"

# Test a few representative combinations
check_paths() {
  local desc="$1" output="$2"
  local base spec auto ok
  base=$(echo "$output" | grep "^PERSONA_BASE=" | cut -d'=' -f2-)
  spec=$(echo "$output" | grep "^PERSONA_SPECIALIZER=" | cut -d'=' -f2-)
  auto=$(echo "$output" | grep "^PERSONA_AUTO_INCLUDE=" | cut -d'=' -f2-)

  if [ -n "$base" ] && [ -f "$base" ]; then
    PASS=$((PASS + 1))
    echo "  PASS: $desc — base path exists"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc — base path not found: $base" >&2
  fi

  if [ -n "$spec" ]; then
    if [ -f "$spec" ]; then
      PASS=$((PASS + 1))
      echo "  PASS: $desc — specializer path exists"
    else
      FAIL=$((FAIL + 1))
      echo "  FAIL: $desc — specializer path not found: $spec" >&2
    fi
  fi

  if [ -n "$auto" ]; then
    if [ -f "$auto" ]; then
      PASS=$((PASS + 1))
      echo "  PASS: $desc — auto-include path exists"
    else
      FAIL=$((FAIL + 1))
      echo "  FAIL: $desc — auto-include path not found: $auto" >&2
    fi
  fi
}

output=$("$SELECTOR" --repo "$TMPDIR/python-project" --layer BE --phase implement)
check_paths "python+BE+implement" "$output"

output=$("$SELECTOR" --repo "$TMPDIR/angular-project" --layer FE --phase implement)
check_paths "angular+FE+implement" "$output"

output=$("$SELECTOR" --repo "$TMPDIR/unknown-project" --phase appraise)
check_paths "appraise phase" "$output"

output=$(TICKET_TITLE="Add auth endpoint" "$SELECTOR" --repo "$TMPDIR/unknown-project" --layer BE --phase implement)
check_paths "implement+security" "$output"

output=$("$SELECTOR" --repo "$TMPDIR/unknown-project" --layer BE --phase implement)
check_paths "BE unknown stack" "$output"

# Verify new specializer files exist on disk
output=$(TICKET_TITLE="Upgrade Java to 21" "$SELECTOR" --repo "$TMPDIR/java-project" --layer BE --phase implement)
check_paths "java-migration" "$output"

output=$(TICKET_TITLE="Refactor order service" "$SELECTOR" --repo "$TMPDIR/java-project" --layer BE --phase implement)
check_paths "java-refactor" "$output"

output=$(TICKET_TITLE="Refactor middleware" "$SELECTOR" --repo "$TMPDIR/python-project" --layer BE --phase implement)
check_paths "python-refactor" "$output"

output=$(TICKET_TITLE="Refactor Express routes" "$SELECTOR" --repo "$TMPDIR/node-project" --layer BE --phase implement)
check_paths "node-refactor" "$output"

# ── Results ────────────────────────────────────────────────────────────────────

echo ""
echo "========================================="
echo "Results: $PASS passed, $FAIL failed"
echo "========================================="

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
