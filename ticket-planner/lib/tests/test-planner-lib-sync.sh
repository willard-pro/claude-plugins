#!/usr/bin/env bash
# test-planner-lib-sync.sh — Tests for the SessionStart lib sync hook (#234).
#
# The hook is exercised as a subprocess with HOME, CLAUDE_PLUGIN_ROOT and
# CLAUDE_PROJECT_DIR pointed at a scratch tree, so nothing touches the real
# ~/.claude. CLAUDE_PROJECT_DIR is always set explicitly — left unset the hook
# falls back to $PWD, which during a test run is this very checkout.
#
# Run: bash ticket-planner/lib/tests/test-planner-lib-sync.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="${SCRIPT_DIR}/../../hooks/planner-lib-sync.sh"

TMPROOT=$(mktemp -d)
trap 'rm -rf "$TMPROOT"' EXIT

PASS=0
FAIL=0
pass() {
  echo "  PASS $1"
  PASS=$((PASS + 1))
}
fail() {
  echo "  FAIL $1: $2"
  FAIL=$((FAIL + 1))
}

# Build a fake source checkout: <root>/ticket-planner/{lib,.claude-plugin}.
make_checkout() {
  local root="$1" version="$2" body="$3"
  mkdir -p "${root}/ticket-planner/lib" "${root}/ticket-planner/.claude-plugin"
  printf '%s\n' "$body" >"${root}/ticket-planner/lib/planner-state.sh"
  cat >"${root}/ticket-planner/.claude-plugin/plugin.json" <<JSON
{ "name": "ticket-planner", "version": "${version}" }
JSON
}

# Build a fake marketplace cache install and echo its versioned root.
make_cache() {
  local home="$1" version="$2" body="$3"
  local root="${home}/.claude/plugins/cache/willard-pro-claude-plugins/ticket-planner/${version}"
  mkdir -p "${root}/lib" "${root}/.claude-plugin" "${home}/.claude/skills/lib"
  printf '%s\n' "$body" >"${root}/lib/planner-state.sh"
  cat >"${root}/.claude-plugin/plugin.json" <<JSON
{ "name": "ticket-planner", "version": "${version}" }
JSON
  echo "$root"
}

# Run the hook with an isolated HOME. Echoes stdout; env via leading VAR=VAL args.
run_hook() {
  local home="$1" plugin_root="$2" project_dir="$3"
  shift 3
  env HOME="$home" CLAUDE_PLUGIN_ROOT="$plugin_root" CLAUDE_PROJECT_DIR="$project_dir" \
    "$@" bash "$HOOK" 2>/dev/null
}

echo "=== planner-lib-sync.sh tests ==="

# ── Test 1: baseline — installed cache still populates ~/.claude/skills/lib ─────

echo "--- Test 1: baseline cache → skills lib ---"
H="${TMPROOT}/t1/home"
NEUTRAL="${TMPROOT}/t1/elsewhere"
mkdir -p "$NEUTRAL"
CACHE=$(make_cache "$H" 0.8.18 "# installed")
run_hook "$H" "$CACHE" "$NEUTRAL" >/dev/null
if grep -q '^# installed$' "${H}/.claude/skills/lib/planner-state.sh" 2>/dev/null; then
  pass "cache lib/*.sh is copied into ~/.claude/skills/lib"
else
  fail "baseline copy" "skills lib does not hold the cache copy"
fi

# ── Test 2: an explicit PLANNER_DEV_ROOT overlays cache and skills lib ──────────

echo "--- Test 2: PLANNER_DEV_ROOT overlays both destinations ---"
H="${TMPROOT}/t2/home"
NEUTRAL="${TMPROOT}/t2/elsewhere"
mkdir -p "$NEUTRAL"
CACHE=$(make_cache "$H" 0.8.18 "# installed")
make_checkout "${TMPROOT}/t2/src" 0.8.18 "# working tree"
out=$(run_hook "$H" "$CACHE" "$NEUTRAL" PLANNER_DEV_ROOT="${TMPROOT}/t2/src")
if grep -q '^# working tree$' "${CACHE}/lib/planner-state.sh" 2>/dev/null; then
  pass "the checkout's working tree overwrites the plugin cache lib"
else
  fail "dev → cache" "cache lib still holds the installed copy"
fi
if grep -q '^# working tree$' "${H}/.claude/skills/lib/planner-state.sh" 2>/dev/null; then
  pass "the checkout's working tree overwrites ~/.claude/skills/lib"
else
  fail "dev → skills lib" "skills lib still holds the installed copy"
fi
if echo "$out" | grep -q "source checkout"; then
  pass "a dev sync announces itself on stdout"
else
  fail "dev sync notice" "no notice emitted, got '$out'"
fi

# ── Test 3: the checkout is found by walking up from the project dir ────────────

echo "--- Test 3: detection by ancestor walk from CLAUDE_PROJECT_DIR ---"
H="${TMPROOT}/t3/home"
CACHE=$(make_cache "$H" 0.8.18 "# installed")
make_checkout "${TMPROOT}/t3/src" 0.8.18 "# working tree"
mkdir -p "${TMPROOT}/t3/src/ticket-planner/lib/tests"
run_hook "$H" "$CACHE" "${TMPROOT}/t3/src/ticket-planner/lib/tests" >/dev/null
if grep -q '^# working tree$' "${CACHE}/lib/planner-state.sh" 2>/dev/null; then
  pass "a project dir nested inside the checkout resolves it"
else
  fail "ancestor walk" "cache lib was not overlaid"
fi

# ── Test 4: a main worktree is recorded and reused from an unrelated session ────

echo "--- Test 4: main-worktree pointer persists across sessions ---"
H="${TMPROOT}/t4/home"
NEUTRAL="${TMPROOT}/t4/elsewhere"
mkdir -p "$NEUTRAL"
CACHE=$(make_cache "$H" 0.8.18 "# installed")
make_checkout "${TMPROOT}/t4/src" 0.8.18 "# working tree"
git -C "${TMPROOT}/t4/src" init -q 2>/dev/null
git -C "${TMPROOT}/t4/src" -c user.email=t@t -c user.name=t add -A >/dev/null 2>&1
git -C "${TMPROOT}/t4/src" -c user.email=t@t -c user.name=t commit -qm init >/dev/null 2>&1
run_hook "$H" "$CACHE" "${TMPROOT}/t4/src" >/dev/null
POINTER="${H}/.claude/skills/lib/.ticket-planner-dev-root"
if [ -f "$POINTER" ] && grep -q "t4/src/ticket-planner" "$POINTER"; then
  pass "the main worktree is recorded as the dev root"
else
  fail "pointer written" "pointer missing or wrong: $(cat "$POINTER" 2>/dev/null)"
fi
# A later session started outside the checkout still syncs from it.
printf '%s\n' "# second edit" >"${TMPROOT}/t4/src/ticket-planner/lib/planner-state.sh"
run_hook "$H" "$CACHE" "$NEUTRAL" >/dev/null
if grep -q '^# second edit$' "${CACHE}/lib/planner-state.sh" 2>/dev/null; then
  pass "a session started elsewhere syncs from the recorded checkout"
else
  fail "pointer reuse" "cache lib was not refreshed from the recorded checkout"
fi

# ── Test 5: a linked worktree syncs but is never recorded ───────────────────────

echo "--- Test 5: a linked worktree is not recorded as the dev root ---"
H="${TMPROOT}/t5/home"
CACHE=$(make_cache "$H" 0.8.18 "# installed")
make_checkout "${TMPROOT}/t5/src" 0.8.18 "# working tree"
git -C "${TMPROOT}/t5/src" init -q 2>/dev/null
git -C "${TMPROOT}/t5/src" -c user.email=t@t -c user.name=t add -A >/dev/null 2>&1
git -C "${TMPROOT}/t5/src" -c user.email=t@t -c user.name=t commit -qm init >/dev/null 2>&1
git -C "${TMPROOT}/t5/src" worktree add -q -b throwaway "${TMPROOT}/t5/wt" >/dev/null 2>&1
printf '%s\n' "# throwaway branch" >"${TMPROOT}/t5/wt/ticket-planner/lib/planner-state.sh"
run_hook "$H" "$CACHE" "${TMPROOT}/t5/wt" >/dev/null
POINTER="${H}/.claude/skills/lib/.ticket-planner-dev-root"
if grep -q '^# throwaway branch$' "${CACHE}/lib/planner-state.sh" 2>/dev/null; then
  pass "a session inside a linked worktree still syncs from it"
else
  fail "worktree sync" "cache lib was not overlaid from the linked worktree"
fi
if [ ! -f "$POINTER" ]; then
  pass "a linked worktree is not recorded as the global dev root"
else
  fail "worktree pointer" "pointer written: $(cat "$POINTER")"
fi

# ── Test 6: a stale pointer is dropped rather than retried forever ──────────────

echo "--- Test 6: stale pointer is dropped ---"
H="${TMPROOT}/t6/home"
NEUTRAL="${TMPROOT}/t6/elsewhere"
mkdir -p "$NEUTRAL"
CACHE=$(make_cache "$H" 0.8.18 "# installed")
POINTER="${H}/.claude/skills/lib/.ticket-planner-dev-root"
printf '%s\n' "${TMPROOT}/t6/removed-worktree/ticket-planner" >"$POINTER"
run_hook "$H" "$CACHE" "$NEUTRAL" >/dev/null
if [ ! -f "$POINTER" ]; then
  pass "a pointer to a vanished checkout is removed"
else
  fail "stale pointer" "pointer survived: $(cat "$POINTER")"
fi

# ── Test 7: an older checkout must not downgrade the installed plugin ───────────

echo "--- Test 7: version guard blocks a downgrade ---"
H="${TMPROOT}/t7/home"
NEUTRAL="${TMPROOT}/t7/elsewhere"
mkdir -p "$NEUTRAL"
CACHE=$(make_cache "$H" 0.9.0 "# installed")
make_checkout "${TMPROOT}/t7/src" 0.8.1 "# stale clone"
run_hook "$H" "$CACHE" "$NEUTRAL" PLANNER_DEV_ROOT="${TMPROOT}/t7/src" >/dev/null
if grep -q '^# installed$' "${CACHE}/lib/planner-state.sh" 2>/dev/null; then
  pass "a checkout older than the installed version is ignored"
else
  fail "version guard" "the stale clone overwrote the cache"
fi
# Equal versions are the normal case — a fix applied before the version bump.
make_checkout "${TMPROOT}/t7/same" 0.9.0 "# same version fix"
run_hook "$H" "$CACHE" "$NEUTRAL" PLANNER_DEV_ROOT="${TMPROOT}/t7/same" >/dev/null
if grep -q '^# same version fix$' "${CACHE}/lib/planner-state.sh" 2>/dev/null; then
  pass "a checkout at the installed version still syncs"
else
  fail "equal version" "an equal-version checkout was skipped"
fi

# ── Test 8: PLANNER_DEV_SYNC=0 disables the overlay, baseline survives ──────────

echo "--- Test 8: PLANNER_DEV_SYNC=0 opt-out ---"
H="${TMPROOT}/t8/home"
CACHE=$(make_cache "$H" 0.8.18 "# installed")
make_checkout "${TMPROOT}/t8/src" 0.8.18 "# working tree"
run_hook "$H" "$CACHE" "${TMPROOT}/t8/src" PLANNER_DEV_SYNC=0 >/dev/null
if grep -q '^# installed$' "${CACHE}/lib/planner-state.sh" 2>/dev/null; then
  pass "the overlay is skipped when PLANNER_DEV_SYNC=0"
else
  fail "opt-out" "the cache was overlaid despite the opt-out"
fi
if grep -q '^# installed$' "${H}/.claude/skills/lib/planner-state.sh" 2>/dev/null; then
  pass "the baseline cache → skills lib copy still runs under the opt-out"
else
  fail "opt-out baseline" "skills lib was not populated"
fi

# ── Test 9: a no-op run is silent and leaves mtimes alone ───────────────────────

echo "--- Test 9: identical trees are a silent no-op ---"
H="${TMPROOT}/t9/home"
CACHE=$(make_cache "$H" 0.8.18 "# working tree")
make_checkout "${TMPROOT}/t9/src" 0.8.18 "# working tree"
run_hook "$H" "$CACHE" "${TMPROOT}/t9/src" >/dev/null
before=$(stat -c %Y "${CACHE}/lib/planner-state.sh" 2>/dev/null)
out=$(run_hook "$H" "$CACHE" "${TMPROOT}/t9/src")
after=$(stat -c %Y "${CACHE}/lib/planner-state.sh" 2>/dev/null)
if [ -z "$out" ]; then
  pass "nothing is injected into session context when nothing changed"
else
  fail "silent no-op" "hook printed '$out'"
fi
if [ "$before" = "$after" ]; then
  pass "an unchanged file is not rewritten"
else
  fail "mtime churn" "file was rewritten ($before → $after)"
fi

# ── Test 10: an unrelated project dir does not resolve a checkout ───────────────

echo "--- Test 10: unrelated project dirs are ignored ---"
H="${TMPROOT}/t10/home"
NEUTRAL="${TMPROOT}/t10/some-app/src"
mkdir -p "$NEUTRAL" "${TMPROOT}/t10/some-app/ticket-planner/lib"
CACHE=$(make_cache "$H" 0.8.18 "# installed")
# A directory named ticket-planner without the marker + manifest is not a checkout.
run_hook "$H" "$CACHE" "$NEUTRAL" >/dev/null
if grep -q '^# installed$' "${CACHE}/lib/planner-state.sh" 2>/dev/null; then
  pass "a lookalike directory without a planner manifest is rejected"
else
  fail "lookalike" "cache lib was overwritten from a non-plugin directory"
fi

echo ""
echo "=== Results ==="
echo "PASS: $PASS | FAIL: $FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
