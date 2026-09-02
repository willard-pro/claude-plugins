#!/usr/bin/env bash
# planner-lib-sync.sh — SessionStart hook for ticket-planner (#234).
#
# Why this exists
# ───────────────
# The hook this replaces was a one-liner:
#
#   mkdir -p ~/.claude/skills/lib && cp "${CLAUDE_PLUGIN_ROOT}/lib/"*.sh ~/.claude/skills/lib/
#
# It only ever propagated the *installed* copy — the marketplace cache under
# ~/.claude/plugins/cache/{marketplace}/ticket-planner/{version}/. A fix a
# developer applies in the source checkout reaches neither the cache nor
# ~/.claude/skills/lib until the marketplace is re-installed, so every session
# that touched planner internals had to hand-sync the same file into several
# places. A fix living in the cache and skills-lib but only *uncommitted* in the
# checkout is one `git checkout .` away from vanishing everywhere at once,
# because neither copy is independently version-controlled.
#
# What this does instead
# ──────────────────────
# 1. Baseline (always): cache lib/*.sh → ~/.claude/skills/lib/, exactly the old
#    behaviour, so a plain marketplace install is unchanged.
# 2. Dev overlay (when a source checkout is detected): that checkout's
#    working-tree lib/*.sh → both the cache lib/ and ~/.claude/skills/lib/.
#    The checkout becomes the one place a developer edits.
#
# Detection precedence (deterministic, first hit wins):
#   1. $PLANNER_DEV_ROOT          — explicit override; repo root or plugin dir.
#   2. $CLAUDE_PROJECT_DIR / $PWD — the session's project dir, walked upwards.
#   3. The pointer recorded by a previous run (see _PLANNER_DEV_POINTER), so a
#      checkout detected once keeps feeding sessions started elsewhere.
#
# Only a repository's *main* worktree is ever recorded as that pointer. A linked
# worktree still syncs for sessions started inside it, but a throwaway
# issue-branch worktree must not become what every other session syncs from.
#
# Guards:
#   - A candidate must carry both lib/planner-state.sh and a
#     .claude-plugin/plugin.json naming ticket-planner.
#   - The checkout's version must be >= the installed version, so a stale clone
#     cannot silently downgrade the installed plugin.
#   - Files are copied only when they differ, so mtimes stay stable.
#   - Set PLANNER_DEV_SYNC=0 to disable the overlay entirely.
#
# Only lib/*.sh is synced — the same file set the old hook managed. Skill
# markdown and this hook script itself still update via marketplace install.
#
# Fail-open: never breaks session start. Always exits 0.

set -uo pipefail

SKILLS_LIB="${HOME}/.claude/skills/lib"
_PLANNER_DEV_POINTER="${SKILLS_LIB}/.ticket-planner-dev-root"
_PLANNER_LIB_MARKER="planner-state.sh"

mkdir -p "$SKILLS_LIB" 2>/dev/null || exit 0

# Copy src → dst only when the contents differ. Echoes nothing; returns 0 when
# a copy happened, 1 when the files already matched or the copy failed.
_sync_file() {
  local src="$1" dst="$2"
  [ -f "$src" ] || return 1
  if [ -f "$dst" ] && cmp -s "$src" "$dst"; then
    return 1
  fi
  cp -p "$src" "$dst" 2>/dev/null || return 1
  return 0
}

# Copy every *.sh from one lib dir into another. Echoes the number copied.
_sync_lib_dir() {
  local src_dir="$1" dst_dir="$2" f copied=0
  [ -d "$src_dir" ] || {
    echo 0
    return 0
  }
  [ -d "$dst_dir" ] && [ -w "$dst_dir" ] || {
    echo 0
    return 0
  }
  # Same directory (dev install pointed straight at the checkout) — nothing to do.
  if [ "$(cd "$src_dir" && pwd -P)" = "$(cd "$dst_dir" && pwd -P)" ]; then
    echo 0
    return 0
  fi
  for f in "$src_dir"/*.sh; do
    [ -f "$f" ] || continue
    if _sync_file "$f" "${dst_dir}/$(basename "$f")"; then
      copied=$((copied + 1))
    fi
  done
  echo "$copied"
}

# Read "version" out of a plugin manifest. Echoes empty when absent.
_manifest_version() {
  local manifest="$1"
  [ -f "$manifest" ] || return 0
  sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$manifest" | head -1
}

# Return 0 when version $1 is >= version $2. Missing versions compare as equal
# so an unparseable manifest never blocks the sync on its own.
_version_ge() {
  local a="$1" b="$2" i av bv
  [ -n "$a" ] && [ -n "$b" ] || return 0
  local -a af bf
  IFS='.' read -r -a af <<<"$a"
  IFS='.' read -r -a bf <<<"$b"
  for i in 0 1 2; do
    av="${af[$i]:-0}"
    bv="${bf[$i]:-0}"
    # Strip any pre-release suffix (0.9.0-rc1 → 0) and non-digits.
    av="${av%%[!0-9]*}"
    bv="${bv%%[!0-9]*}"
    av="${av:-0}"
    bv="${bv:-0}"
    if [ "$av" -gt "$bv" ]; then return 0; fi
    if [ "$av" -lt "$bv" ]; then return 1; fi
  done
  return 0
}

# Normalize a candidate path to a ticket-planner plugin directory, or echo
# nothing. Accepts either the plugin dir itself or a repo root containing it.
_planner_plugin_dir() {
  local cand="$1" dir
  [ -n "$cand" ] || return 0
  for dir in "$cand" "${cand}/ticket-planner"; do
    [ -f "${dir}/lib/${_PLANNER_LIB_MARKER}" ] || continue
    grep -q '"name"[[:space:]]*:[[:space:]]*"ticket-planner"' \
      "${dir}/.claude-plugin/plugin.json" 2>/dev/null || continue
    (cd "$dir" && pwd -P)
    return 0
  done
  return 0
}

# Walk a directory and its ancestors looking for a planner checkout.
_planner_walk_up() {
  local dir="$1" found
  [ -n "$dir" ] && [ -d "$dir" ] || return 0
  dir="$(cd "$dir" && pwd -P)"
  while :; do
    found="$(_planner_plugin_dir "$dir")"
    if [ -n "$found" ]; then
      echo "$found"
      return 0
    fi
    [ "$dir" = "/" ] && break
    dir="$(dirname "$dir")"
  done
  return 0
}

# True when $1 sits in a git repository's main worktree. A linked worktree's
# --git-dir points inside <main>/.git/worktrees/, while --git-common-dir points
# at <main>/.git; in the main worktree the two resolve to the same path.
_is_main_worktree() {
  local dir="$1" gd cd_
  gd="$(git -C "$dir" rev-parse --absolute-git-dir 2>/dev/null)" || return 1
  cd_="$(git -C "$dir" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || return 1
  [ -n "$gd" ] && [ "$gd" = "$cd_" ]
}

# Resolve the source checkout to sync from, honouring the precedence chain.
_resolve_dev_plugin_dir() {
  local found

  found="$(_planner_plugin_dir "${PLANNER_DEV_ROOT:-}")"
  if [ -n "$found" ]; then
    echo "$found"
    return 0
  fi

  found="$(_planner_walk_up "${CLAUDE_PROJECT_DIR:-$PWD}")"
  if [ -n "$found" ]; then
    echo "$found"
    return 0
  fi

  if [ -f "$_PLANNER_DEV_POINTER" ]; then
    found="$(_planner_plugin_dir "$(head -1 "$_PLANNER_DEV_POINTER")")"
    if [ -n "$found" ]; then
      echo "$found"
      return 0
    fi
    # Pointer went stale (worktree removed, plugin dir renamed) — drop it
    # rather than retrying a dead path on every session.
    rm -f "$_PLANNER_DEV_POINTER" 2>/dev/null || true
  fi

  return 0
}

CACHE_LIB=""
if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -d "${CLAUDE_PLUGIN_ROOT}/lib" ]; then
  CACHE_LIB="${CLAUDE_PLUGIN_ROOT}/lib"
fi

# ── 1. Baseline: installed cache → skills lib (the pre-#234 behaviour) ──────────
if [ -n "$CACHE_LIB" ]; then
  _sync_lib_dir "$CACHE_LIB" "$SKILLS_LIB" >/dev/null
fi

# ── 2. Dev overlay: source checkout → cache lib + skills lib ────────────────────
[ "${PLANNER_DEV_SYNC:-1}" = "0" ] && exit 0

DEV_DIR="$(_resolve_dev_plugin_dir)"
[ -n "$DEV_DIR" ] || exit 0

if [ -n "$CACHE_LIB" ]; then
  if ! _version_ge \
    "$(_manifest_version "${DEV_DIR}/.claude-plugin/plugin.json")" \
    "$(_manifest_version "${CLAUDE_PLUGIN_ROOT}/.claude-plugin/plugin.json")"; then
    # Older checkout than what is installed — syncing it would be a downgrade.
    exit 0
  fi
fi

# Remember the checkout so sessions started outside it sync from it too — but
# only when it is the repository's main worktree (see header).
if _is_main_worktree "$DEV_DIR"; then
  printf '%s\n' "$DEV_DIR" >"$_PLANNER_DEV_POINTER" 2>/dev/null || true
fi

copied=0
if [ -n "$CACHE_LIB" ]; then
  copied=$((copied + $(_sync_lib_dir "${DEV_DIR}/lib" "$CACHE_LIB")))
fi
copied=$((copied + $(_sync_lib_dir "${DEV_DIR}/lib" "$SKILLS_LIB")))

if [ "$copied" -gt 0 ]; then
  echo "ticket-planner: synced ${copied} lib file(s) from the source checkout at ${DEV_DIR} — this session runs that working tree, not the installed release."
fi

exit 0
