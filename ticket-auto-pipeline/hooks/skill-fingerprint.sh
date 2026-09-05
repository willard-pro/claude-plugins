#!/bin/bash
# SessionStart hook — content fingerprint of the prompt material each spawnable
# skill actually runs on.
#
# META|version already names the plugin version, but a plugin version is far
# coarser than a skill edit: dozens of SKILL.md revisions ship under one version,
# so "did that edit to ticket-implement help or hurt?" is unanswerable. This hook
# writes a per-skill sha256 over exactly the bytes that reach the model, which
# lib/run-identity.sh stamps onto META|version and lib/run-summary.sh carries
# into runs.jsonl — making "group outcomes by skill revision" a jq query.
#
# Why a hook and not spawn time: CLAUDE_PLUGIN_ROOT is unset in Bash-tool
# context, so the router cannot resolve which plugin version's SKILL.md is live.
# There is no other caller that can. Registered AFTER the lib-sync hook so the
# lib:/home: labels below resolve against freshly synced destination files.
#
# Three resolution roots, deliberately different:
#   plugin: -> $CLAUDE_PLUGIN_ROOT/...   files reached through skill resolution
#   lib:    -> $HOME/.claude/skills/lib/ the *destination* skills read by
#   home:   -> $HOME/.claude/skills/     absolute path, which a dev-mode sync can
#                                        make differ from the plugin cache
# Hashing the plugin-cache source for a lib:/home: entry would name material that
# did not run. That is the single most important correctness property here.
#
# Fail-open is absolute: any unreadable manifest entry makes that skill's sha256
# the literal string "unresolved" with the offending labels listed in `missing`.
# A hash over the readable subset would let two genuinely different programs
# collide under one id, which is worse than admitting ignorance. The hook exits 0
# on every path and can never block a session or a spawn.
#
# Overrides (used by the unit tests):
#   HOME                  — relocates the lib:/home: roots and the output path
#   CLAUDE_PLUGIN_ROOT    — relocates the plugin: root and the dispatch table
#
# -u (nounset) intentionally omitted: Claude Code shell snapshots inject
# ZSH_VERSION references that trigger false-positive "unbound variable"
# errors in this bash version when nounset is active.
set -eo pipefail

# Guarantee exit 0 on every path, including a set -e abort, and never leave a
# half-written artifact behind: the consumer reads this file with jq and a
# truncated object would be a malformed input, not a missing one.
_FP_TMP=""
_fp_finish() {
  [ -n "$_FP_TMP" ] && rm -f -- "$_FP_TMP" 2>/dev/null
  exit 0
}
trap _fp_finish EXIT

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-}"
LIB_ROOT="$HOME/.claude/skills/lib"
HOME_ROOT="$HOME/.claude/skills"
OUT_FILE="$LIB_ROOT/skill-fingerprints.json"
TABLE="$PLUGIN_ROOT/skills/ticket-flow/dispatch-table.json"

# Every precondition below is a reason to write nothing at all rather than to
# write something partial. A absent artifact is the pre-change state, which
# lib/skill-version.sh already degrades to cleanly.
[ -n "$PLUGIN_ROOT" ] || exit 0
[ -f "$TABLE" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0
command -v sha256sum >/dev/null 2>&1 || exit 0
jq -e . "$TABLE" >/dev/null 2>&1 || exit 0
jq -e 'has("prompt_manifests")' "$TABLE" >/dev/null 2>&1 || exit 0

# Map one manifest label to an absolute path. An unknown prefix returns 1 and is
# treated exactly like a missing file — a typo must not silently drop material
# from the hash.
_fp_resolve() {
  case "$1" in
  plugin:*) printf '%s/%s' "$PLUGIN_ROOT" "${1#plugin:}" ;;
  lib:*) printf '%s/%s' "$LIB_ROOT" "${1#lib:}" ;;
  home:*) printf '%s/%s' "$HOME_ROOT" "${1#home:}" ;;
  *) return 1 ;;
  esac
}

# The hashed stream: for each entry in manifest order, the path label then the
# file's raw bytes, NUL-separated; then the compact JSON of every dispatch-table
# spawn block naming this skill. Including the label makes a rename or a reorder
# move the hash. Including the spawn blocks is required because skill,
# extra_flags and instructions are concatenated into AGENT_PROMPT by
# spawn_agent_pre — they are prompt material that happens to live in JSON.
_fp_stream() {
  local labels="$1" spawns="$2" label path
  while IFS= read -r label; do
    [ -n "$label" ] || continue
    path=$(_fp_resolve "$label") || return 1
    printf '%s\0' "$label"
    cat -- "$path" || return 1
    printf '\0'
  done <<<"$labels"
  printf '%s\0' "$spawns"
}

ENTRIES=$(mktemp) || exit 0
_FP_TMP="$ENTRIES"

PLUGIN_VERSION=$(jq -r '.version // ""' "$PLUGIN_ROOT/.claude-plugin/plugin.json" 2>/dev/null || echo "")
GENERATED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)

while IFS= read -r skill; do
  [ -n "$skill" ] || continue

  labels=$(jq -r --arg k "$skill" '.prompt_manifests[$k].files[]? // empty' "$TABLE" 2>/dev/null || echo "")
  manifest_n=0
  [ -n "$labels" ] && manifest_n=$(printf '%s\n' "$labels" | grep -c . || true)

  # Every spawn-shaped block naming this skill, in document order. Deliberately
  # not just .steps[].spawn: post_dispatch, sub_steps and sequence entries carry
  # their own instructions and reach the model identically.
  spawns=$(jq -c --arg s "/$skill" \
    '[.. | objects | select(has("skill")) | select(.skill == $s)]' \
    "$TABLE" 2>/dev/null || echo "[]")

  # Resolve every label before hashing anything — never a hash over a subset.
  missing=()
  while IFS= read -r label; do
    [ -n "$label" ] || continue
    path=$(_fp_resolve "$label") || {
      missing+=("$label")
      continue
    }
    [ -r "$path" ] || missing+=("$label")
  done <<<"$labels"

  if [ ${#missing[@]} -eq 0 ] && [ "$manifest_n" -gt 0 ]; then
    sha=$(_fp_stream "$labels" "$spawns" | sha256sum 2>/dev/null | cut -d' ' -f1) || sha=""
    [ -n "$sha" ] || sha="unresolved"
  else
    sha="unresolved"
  fi

  missing_json=$(printf '%s\n' "${missing[@]}" | jq -Rc 'select(length > 0)' | jq -sc . 2>/dev/null || echo "[]")

  jq -nc --arg skill "$skill" --arg sha "$sha" \
    --argjson n "$manifest_n" --argjson missing "$missing_json" \
    '{skill: $skill, sha256: $sha, manifest_n: $n, missing: $missing}' >>"$ENTRIES"
done < <(jq -r '.prompt_manifests | keys[]' "$TABLE" 2>/dev/null || true)

# A spawnable skill with no manifest is a report, never an error: a newly added
# spawn step becomes an observable fact in the artifact instead of a silent hole.
UNMANIFESTED=$(jq -c '
  ([.. | objects | select(has("skill")) | .skill | ltrimstr("/")] | unique)
  - (.prompt_manifests | keys)' "$TABLE" 2>/dev/null || echo "[]")

OUT_TMP="${OUT_FILE}.tmp.$$"
mkdir -p "$LIB_ROOT" 2>/dev/null || exit 0

if jq -s \
  --arg gen "$GENERATED_AT" \
  --arg pv "$PLUGIN_VERSION" \
  --argjson unmanifested "$UNMANIFESTED" \
  '{
     schema: 1,
     generated_at: $gen,
     plugin_version: $pv,
     skills: (reduce .[] as $e ({};
       .[$e.skill] = ({sha256: $e.sha256, manifest_n: $e.manifest_n}
         + (if ($e.missing | length) > 0 then {missing: $e.missing} else {} end)))),
     unmanifested: $unmanifested
   }' "$ENTRIES" >"$OUT_TMP" 2>/dev/null; then
  mv -f -- "$OUT_TMP" "$OUT_FILE" 2>/dev/null || rm -f -- "$OUT_TMP" 2>/dev/null
else
  rm -f -- "$OUT_TMP" 2>/dev/null
fi

exit 0
