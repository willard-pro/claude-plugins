#!/usr/bin/env bash
# test-skill-fingerprint.sh — unit tests for hooks/skill-fingerprint.sh (the
# SessionStart prompt-material fingerprint) and lib/skill-version.sh (its
# fail-open reader).
#
# The properties under test are the ones the fingerprint's usefulness rests on:
# it must be stable when nothing changed, sensitive to every byte that reaches
# the model (file contents, manifest order, and the spawn blocks the router
# concatenates into AGENT_PROMPT), blind to everything that does not, and it must
# degrade to "unresolved" rather than hash a subset when material goes missing.
#
# Every test runs against a sandboxed fake plugin root and a fake $HOME, so the
# real ~/.claude/skills artifact is never read or written. Neither unit under
# test sources another library, so no declare-guard stubs are needed for CI
# (where SessionStart hooks never run).
#
# Usage: bash test-skill-fingerprint.sh [test_name_filter]
# -u (nounset) intentionally omitted: Claude Code shell snapshots inject
# ZSH_VERSION references that trigger false-positive "unbound variable" errors.
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
HOOK="$(cd "$SCRIPT_DIR/../../hooks" && pwd)/skill-fingerprint.sh"
VERSION_LIB="$LIB_DIR/skill-version.sh"

PASS=0
FAIL=0
FILTER="${1:-}"

_run() {
  local name="$1"
  shift
  if [ -n "$FILTER" ] && [[ "$name" != *"$FILTER"* ]]; then
    return 0
  fi
  if "$@"; then
    echo "PASS: $name"
    ((PASS++)) || true
  else
    echo "FAIL: $name"
    ((FAIL++)) || true
  fi
}

_TEST_TMPDIRS=()
_cleanup() {
  local d
  for d in "${_TEST_TMPDIRS[@]}"; do
    rm -rf "$d" 2>/dev/null || true
  done
}
trap _cleanup EXIT

# ---------------------------------------------------------------------------
# Sandbox
# ---------------------------------------------------------------------------

# Build a fake plugin root + fake $HOME whose dispatch table exercises all three
# label roots, a skill with an agent and one without, and (for the unmanifested
# report) a spawn skill with no manifest at all.
_sandbox() {
  local sb
  sb=$(mktemp -d)
  _TEST_TMPDIRS+=("$sb")

  mkdir -p "$sb/plugin/.claude-plugin" \
    "$sb/plugin/skills/ticket-flow" \
    "$sb/plugin/skills/alpha" \
    "$sb/plugin/skills/beta" \
    "$sb/plugin/agents" \
    "$sb/home/.claude/skills/lib"

  echo '{"name":"fake","version":"9.9.9"}' >"$sb/plugin/.claude-plugin/plugin.json"
  echo 'alpha skill body' >"$sb/plugin/skills/alpha/SKILL.md"
  echo 'beta skill body' >"$sb/plugin/skills/beta/SKILL.md"
  echo 'alpha agent body' >"$sb/plugin/agents/alpha-agent.md"
  echo 'preamble body' >"$sb/home/.claude/skills/lib/preamble.md"
  echo 'shared doc body' >"$sb/home/.claude/skills/shared.md"
  # Named by no manifest — the control for the insensitivity test.
  echo 'unrelated body' >"$sb/plugin/skills/beta/NOTES.md"

  cat >"$sb/plugin/skills/ticket-flow/dispatch-table.json" <<'JSON'
{
  "schema_version": 1,
  "steps": [
    {
      "step_id": "STEP_A",
      "spawn": {
        "step": "alpha",
        "skill": "/alpha",
        "extra_flags": "--from-auto",
        "instructions": "run alpha carefully",
        "agent": "fake:alpha-agent"
      }
    },
    {
      "step_id": "STEP_B",
      "spawn": {
        "step": "beta",
        "skill": "/beta",
        "instructions": "run beta"
      }
    }
  ],
  "prompt_manifests": {
    "alpha": {
      "files": [
        "plugin:skills/alpha/SKILL.md",
        "plugin:agents/alpha-agent.md",
        "lib:preamble.md",
        "home:shared.md"
      ]
    },
    "beta": {
      "files": [
        "plugin:skills/beta/SKILL.md"
      ]
    }
  }
}
JSON
  printf '%s' "$sb"
}

_table() { printf '%s' "$1/plugin/skills/ticket-flow/dispatch-table.json"; }
_artifact() { printf '%s' "$1/home/.claude/skills/lib/skill-fingerprints.json"; }

# Run the hook against a sandbox. Returns the hook's own exit status, which every
# caller asserts is 0 — the hook may never block a session.
_hook() {
  local sb="$1"
  env HOME="$sb/home" CLAUDE_PLUGIN_ROOT="$sb/plugin" bash "$HOOK"
}

_sha() {
  jq -r --arg k "$2" '.skills[$k].sha256 // "ABSENT"' "$(_artifact "$1")" 2>/dev/null
}

# Rewrite the dispatch table in place through jq, so tests mutate structure
# rather than string-patching JSON.
_edit_table() {
  local sb="$1" prog="$2" t
  t=$(_table "$sb")
  jq "$prog" "$t" >"$t.new" && mv "$t.new" "$t"
}

# ---------------------------------------------------------------------------
# 5.2 — stability
# ---------------------------------------------------------------------------

test_identical_material_identical_fingerprint() {
  local sb a1 b1 a2 b2
  sb=$(_sandbox)

  _hook "$sb" || return 1
  a1=$(_sha "$sb" alpha)
  b1=$(_sha "$sb" beta)

  _hook "$sb" || return 1
  a2=$(_sha "$sb" alpha)
  b2=$(_sha "$sb" beta)

  [ "$a1" = "$a2" ] || {
    echo "  alpha drifted across runs: $a1 vs $a2"
    return 1
  }
  [ "$b1" = "$b2" ] || {
    echo "  beta drifted across runs: $b1 vs $b2"
    return 1
  }
  # A real hash, not the fail-open sentinel.
  [ "${#a1}" -eq 64 ] || {
    echo "  expected a 64-char sha256, got '$a1'"
    return 1
  }
  return 0
}

test_artifact_has_required_keys() {
  local sb f
  sb=$(_sandbox)
  _hook "$sb" || return 1
  f=$(_artifact "$sb")

  jq -e 'has("schema") and has("generated_at") and has("plugin_version")
         and has("skills") and has("unmanifested")' "$f" >/dev/null 2>&1 || {
    echo "  artifact missing required top-level keys"
    return 1
  }
  [ "$(jq -r '.plugin_version' "$f")" = "9.9.9" ] || {
    echo "  plugin_version not read from plugin.json"
    return 1
  }
  [ "$(jq -r '.schema' "$f")" = "1" ] || {
    echo "  schema is not 1"
    return 1
  }
  [ "$(jq -r '.skills.alpha.manifest_n' "$f")" = "4" ] || {
    echo "  alpha manifest_n should be 4"
    return 1
  }
  return 0
}

# ---------------------------------------------------------------------------
# 5.3 / 5.4 — sensitivity and insensitivity to file bytes
# ---------------------------------------------------------------------------

test_changed_manifest_file_changes_fingerprint() {
  local sb before after
  sb=$(_sandbox)
  _hook "$sb" || return 1
  before=$(_sha "$sb" alpha)

  # One byte, in a lib:-rooted file — proves the destination root is hashed too.
  printf 'x' >>"$sb/home/.claude/skills/lib/preamble.md"

  _hook "$sb" || return 1
  after=$(_sha "$sb" alpha)

  [ "$before" != "$after" ] || {
    echo "  alpha fingerprint did not move on a manifest-file edit"
    return 1
  }
  return 0
}

test_changed_non_manifest_file_leaves_fingerprints() {
  local sb a1 b1 a2 b2
  sb=$(_sandbox)
  _hook "$sb" || return 1
  a1=$(_sha "$sb" alpha)
  b1=$(_sha "$sb" beta)

  echo 'edited' >>"$sb/plugin/skills/beta/NOTES.md"

  _hook "$sb" || return 1
  a2=$(_sha "$sb" alpha)
  b2=$(_sha "$sb" beta)

  [ "$a1" = "$a2" ] && [ "$b1" = "$b2" ] || {
    echo "  a non-manifest file moved a fingerprint"
    return 1
  }
  return 0
}

# ---------------------------------------------------------------------------
# 5.5 — spawn blocks are prompt material
# ---------------------------------------------------------------------------

test_changed_spawn_instruction_changes_fingerprint() {
  local sb a1 b1 a2 b2
  sb=$(_sandbox)
  _hook "$sb" || return 1
  a1=$(_sha "$sb" alpha)
  b1=$(_sha "$sb" beta)

  _edit_table "$sb" '.steps[0].spawn.instructions = "run alpha very carefully"'

  _hook "$sb" || return 1
  a2=$(_sha "$sb" alpha)
  b2=$(_sha "$sb" beta)

  [ "$a1" != "$a2" ] || {
    echo "  alpha fingerprint did not move on a spawn-instruction edit"
    return 1
  }
  # The edit named only alpha's step; beta must be untouched.
  [ "$b1" = "$b2" ] || {
    echo "  beta fingerprint moved on an edit to alpha's spawn block"
    return 1
  }
  return 0
}

test_changed_extra_flags_changes_fingerprint() {
  local sb before after
  sb=$(_sandbox)
  _hook "$sb" || return 1
  before=$(_sha "$sb" alpha)

  _edit_table "$sb" '.steps[0].spawn.extra_flags = "--from-auto --mode extract"'

  _hook "$sb" || return 1
  after=$(_sha "$sb" alpha)

  [ "$before" != "$after" ] || {
    echo "  extra_flags is concatenated into AGENT_PROMPT but did not move the hash"
    return 1
  }
  return 0
}

# ---------------------------------------------------------------------------
# 5.6 — the label is in the hash, so order matters
# ---------------------------------------------------------------------------

test_reordered_manifest_changes_fingerprint() {
  local sb before after
  sb=$(_sandbox)
  _hook "$sb" || return 1
  before=$(_sha "$sb" alpha)

  # Swap the first two entries. Same bytes, same count — only the order differs,
  # which a naive concatenation hash would not notice.
  _edit_table "$sb" '.prompt_manifests.alpha.files =
    [.prompt_manifests.alpha.files[1], .prompt_manifests.alpha.files[0]]
    + .prompt_manifests.alpha.files[2:]'

  _hook "$sb" || return 1
  after=$(_sha "$sb" alpha)

  [ "$before" != "$after" ] || {
    echo "  reordering a manifest did not move the fingerprint"
    return 1
  }
  return 0
}

# ---------------------------------------------------------------------------
# 5.7 — fail open, never a hash over a subset
# ---------------------------------------------------------------------------

test_missing_manifest_file_is_unresolved() {
  local sb f
  sb=$(_sandbox)
  rm -f "$sb/plugin/agents/alpha-agent.md"

  _hook "$sb" || {
    echo "  hook exited non-zero on a missing manifest file"
    return 1
  }
  f=$(_artifact "$sb")

  [ "$(jq -r '.skills.alpha.sha256' "$f")" = "unresolved" ] || {
    echo "  alpha should be unresolved when a manifest file is gone"
    return 1
  }
  jq -e '.skills.alpha.missing | index("plugin:agents/alpha-agent.md")' "$f" >/dev/null 2>&1 || {
    echo "  the offending label is not listed in alpha.missing"
    return 1
  }
  # manifest_n still describes the declared manifest, not the readable subset.
  [ "$(jq -r '.skills.alpha.manifest_n' "$f")" = "4" ] || {
    echo "  manifest_n should still be 4"
    return 1
  }
  return 0
}

test_other_skills_unaffected_by_missing_file() {
  local sb f
  sb=$(_sandbox)
  rm -f "$sb/plugin/agents/alpha-agent.md"

  _hook "$sb" || return 1
  f=$(_artifact "$sb")

  [ "$(jq -r '.skills.beta.sha256 | length' "$f")" = "64" ] || {
    echo "  beta lost its fingerprint because alpha was broken"
    return 1
  }
  return 0
}

test_unknown_label_prefix_is_unresolved() {
  local sb
  sb=$(_sandbox)
  _edit_table "$sb" '.prompt_manifests.beta.files = ["bogus:skills/beta/SKILL.md"]'

  _hook "$sb" || return 1

  [ "$(_sha "$sb" beta)" = "unresolved" ] || {
    echo "  an unknown label prefix must not be silently dropped from the hash"
    return 1
  }
  return 0
}

# ---------------------------------------------------------------------------
# 5.8 — the hook can never block a session
# ---------------------------------------------------------------------------

test_unset_plugin_root_exits_clean() {
  local sb
  sb=$(_sandbox)

  env -u CLAUDE_PLUGIN_ROOT HOME="$sb/home" bash "$HOOK" || {
    echo "  hook exited non-zero with CLAUDE_PLUGIN_ROOT unset"
    return 1
  }
  [ ! -e "$(_artifact "$sb")" ] || {
    echo "  hook wrote an artifact it could not have resolved"
    return 1
  }
  return 0
}

test_malformed_table_exits_clean() {
  local sb
  sb=$(_sandbox)
  echo '{ this is not json' >"$(_table "$sb")"

  _hook "$sb" || {
    echo "  hook exited non-zero on a malformed dispatch table"
    return 1
  }
  [ ! -e "$(_artifact "$sb")" ] || {
    echo "  hook wrote an artifact from a malformed table"
    return 1
  }
  return 0
}

test_missing_table_exits_clean() {
  local sb
  sb=$(_sandbox)
  rm -f "$(_table "$sb")"

  _hook "$sb" || return 1
  [ ! -e "$(_artifact "$sb")" ] || return 1
  return 0
}

test_no_tmp_files_left_behind() {
  local sb leftovers
  sb=$(_sandbox)
  _hook "$sb" || return 1

  leftovers=$(find "$sb/home/.claude/skills/lib" -name '*.tmp.*' 2>/dev/null | wc -l)
  [ "$leftovers" -eq 0 ] || {
    echo "  hook left $leftovers temp file(s) behind"
    return 1
  }
  return 0
}

# ---------------------------------------------------------------------------
# 5.9 — unmanifested spawn skills are reported, not fatal
# ---------------------------------------------------------------------------

test_unmanifested_spawn_skill_is_reported() {
  local sb f
  sb=$(_sandbox)
  _edit_table "$sb" '.steps += [{"step_id":"STEP_G","spawn":{"skill":"/gamma"}}]'

  _hook "$sb" || {
    echo "  an unmanifested skill must not fail the hook"
    return 1
  }
  f=$(_artifact "$sb")

  jq -e '.unmanifested | index("gamma")' "$f" >/dev/null 2>&1 || {
    echo "  gamma is not listed in unmanifested"
    return 1
  }
  return 0
}

test_fully_manifested_table_reports_no_gaps() {
  local sb
  sb=$(_sandbox)
  _hook "$sb" || return 1

  [ "$(jq -c '.unmanifested' "$(_artifact "$sb")")" = "[]" ] || {
    echo "  unmanifested should be empty for a fully manifested table"
    return 1
  }
  return 0
}

test_nested_spawn_shapes_count_as_spawns() {
  local sb f
  sb=$(_sandbox)
  # post_dispatch / sub_steps / sequence entries carry their own skill and
  # instructions and reach the model identically to a top-level spawn. The real
  # table uses all three shapes, so the union must not be steps[].spawn only.
  _edit_table "$sb" '.steps[1].post_dispatch = [{"skill":"/delta","kind":"inspector"}]'

  _hook "$sb" || return 1
  f=$(_artifact "$sb")

  jq -e '.unmanifested | index("delta")' "$f" >/dev/null 2>&1 || {
    echo "  a post_dispatch skill was not counted as a spawn skill"
    return 1
  }
  return 0
}

test_spawn_block_in_nested_shape_feeds_hash() {
  local sb before after
  sb=$(_sandbox)
  _edit_table "$sb" '.steps[1].post_dispatch = [{"skill":"/alpha","instructions":"post alpha"}]'
  _hook "$sb" || return 1
  before=$(_sha "$sb" alpha)

  _edit_table "$sb" '.steps[1].post_dispatch[0].instructions = "post alpha differently"'
  _hook "$sb" || return 1
  after=$(_sha "$sb" alpha)

  [ "$before" != "$after" ] || {
    echo "  a nested spawn block naming alpha did not feed alpha's hash"
    return 1
  }
  return 0
}

# ---------------------------------------------------------------------------
# 5.10 — lookup library
# ---------------------------------------------------------------------------

test_lookup_returns_sha_and_count() {
  local sb out sha n
  sb=$(_sandbox)
  _hook "$sb" || return 1

  out=$(SKILL_FINGERPRINTS_FILE="$(_artifact "$sb")" bash "$VERSION_LIB" lookup alpha) || return 1
  sha=$(printf '%s' "$out" | cut -f1)
  n=$(printf '%s' "$out" | cut -f2)

  [ "${#sha}" -eq 64 ] || {
    echo "  expected a sha256, got '$sha'"
    return 1
  }
  [ "$n" = "4" ] || {
    echo "  expected manifest_n 4, got '$n'"
    return 1
  }
  return 0
}

test_lookup_missing_artifact_fails_open() {
  local out
  out=$(SKILL_FINGERPRINTS_FILE=/nonexistent/skill-fingerprints.json \
    bash "$VERSION_LIB" lookup ticket-implement) || {
    echo "  lookup exited non-zero on a missing artifact"
    return 1
  }
  [ "$out" = "$(printf 'unresolved\t0')" ] || {
    echo "  expected 'unresolved<TAB>0', got '$out'"
    return 1
  }
  return 0
}

test_lookup_malformed_artifact_fails_open() {
  local sb bad out
  sb=$(_sandbox)
  bad="$sb/bad.json"
  echo 'not json {' >"$bad"

  out=$(SKILL_FINGERPRINTS_FILE="$bad" bash "$VERSION_LIB" lookup alpha) || return 1
  [ "$out" = "$(printf 'unresolved\t0')" ] || return 1

  out=$(SKILL_FINGERPRINTS_FILE="$bad" bash "$VERSION_LIB" all) || return 1
  [ "$out" = "{}" ] || {
    echo "  expected '{}' from all on malformed JSON, got '$out'"
    return 1
  }
  return 0
}

test_lookup_unknown_skill_fails_open() {
  local sb out
  sb=$(_sandbox)
  _hook "$sb" || return 1

  out=$(SKILL_FINGERPRINTS_FILE="$(_artifact "$sb")" bash "$VERSION_LIB" lookup nope) || return 1
  [ "$out" = "$(printf 'unresolved\t0')" ] || {
    echo "  expected fail-open for an unknown skill, got '$out'"
    return 1
  }
  return 0
}

test_fingerprints_all_returns_skills_object() {
  local sb out
  sb=$(_sandbox)
  _hook "$sb" || return 1

  out=$(SKILL_FINGERPRINTS_FILE="$(_artifact "$sb")" bash "$VERSION_LIB" all) || return 1

  printf '%s' "$out" | jq -e 'has("alpha") and has("beta")' >/dev/null 2>&1 || {
    echo "  all did not return the skills object"
    return 1
  }
  printf '%s' "$out" | jq -e '.alpha.sha256 and .alpha.manifest_n' >/dev/null 2>&1 || {
    echo "  skills entries lack sha256/manifest_n"
    return 1
  }
  return 0
}

test_fingerprints_all_missing_artifact_fails_open() {
  local out
  out=$(SKILL_FINGERPRINTS_FILE=/nonexistent/x.json bash "$VERSION_LIB" all) || {
    echo "  all exited non-zero on a missing artifact"
    return 1
  }
  [ "$out" = "{}" ] || return 1
  return 0
}

# ---------------------------------------------------------------------------

_run "identical material yields identical fingerprints" test_identical_material_identical_fingerprint
_run "artifact carries the required keys" test_artifact_has_required_keys
_run "changed manifest file changes the fingerprint" test_changed_manifest_file_changes_fingerprint
_run "changed non-manifest file changes nothing" test_changed_non_manifest_file_leaves_fingerprints
_run "changed spawn instruction changes the fingerprint" test_changed_spawn_instruction_changes_fingerprint
_run "changed extra_flags changes the fingerprint" test_changed_extra_flags_changes_fingerprint
_run "reordered manifest changes the fingerprint" test_reordered_manifest_changes_fingerprint
_run "missing manifest file yields unresolved" test_missing_manifest_file_is_unresolved
_run "other skills unaffected by one missing file" test_other_skills_unaffected_by_missing_file
_run "unknown label prefix yields unresolved" test_unknown_label_prefix_is_unresolved
_run "unset CLAUDE_PLUGIN_ROOT exits clean" test_unset_plugin_root_exits_clean
_run "malformed dispatch table exits clean" test_malformed_table_exits_clean
_run "missing dispatch table exits clean" test_missing_table_exits_clean
_run "no temp files left behind" test_no_tmp_files_left_behind
_run "unmanifested spawn skill is reported" test_unmanifested_spawn_skill_is_reported
_run "fully manifested table reports no gaps" test_fully_manifested_table_reports_no_gaps
_run "nested spawn shapes count as spawn skills" test_nested_spawn_shapes_count_as_spawns
_run "nested spawn block feeds the hash" test_spawn_block_in_nested_shape_feeds_hash
_run "lookup returns sha and manifest count" test_lookup_returns_sha_and_count
_run "lookup missing artifact fails open" test_lookup_missing_artifact_fails_open
_run "lookup malformed artifact fails open" test_lookup_malformed_artifact_fails_open
_run "lookup unknown skill fails open" test_lookup_unknown_skill_fails_open
_run "fingerprints_all returns the skills object" test_fingerprints_all_returns_skills_object
_run "fingerprints_all missing artifact fails open" test_fingerprints_all_missing_artifact_fails_open

echo ""
echo "=== test-skill-fingerprint: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
