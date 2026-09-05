#!/bin/bash
# skill-version.sh — fail-open reads of the skill prompt fingerprints.
#
# hooks/skill-fingerprint.sh writes ~/.claude/skills/lib/skill-fingerprints.json
# once per session; this library is the only supported way to read it. Both
# functions are pure reads — no writes, no network — and both return a fail-open
# value with exit status 0 when the artifact is missing, unreadable, or not valid
# JSON. That matters because the sole consumer is lib/run-identity.sh's
# META|version line: a fingerprint that cannot be resolved must degrade one JSON
# field, never cost a run its identity stamp.
#
# "unresolved" is a deliberate sentinel rather than an empty string or a partial
# hash: two genuinely different programs must never collide under one id, so
# ignorance is reported as ignorance.
#
# Override (used by the unit tests):
#   SKILL_FINGERPRINTS_FILE — path to the artifact
#
# Usage:
#   source skill-version.sh
#   skill_version_lookup ticket-implement   # -> "<sha256>\t<manifest_n>"
#   skill_fingerprints_all                  # -> compact JSON of the skills object
#
# CLI:
#   skill-version.sh lookup <skill>
#   skill-version.sh all

_skill_fingerprints_file() {
  printf '%s' "${SKILL_FINGERPRINTS_FILE:-$HOME/.claude/skills/lib/skill-fingerprints.json}"
}

# Print "<sha256>\t<manifest_n>" for one skill. An unknown skill name is the same
# answer as an absent artifact — the caller cannot act differently on the two,
# and both mean "this run is not attributable to a known revision".
skill_version_lookup() {
  local skill="$1" f out
  f=$(_skill_fingerprints_file)

  if [ -z "$skill" ] || [ ! -r "$f" ] || ! command -v jq >/dev/null 2>&1; then
    printf 'unresolved\t0\n'
    return 0
  fi

  out=$(jq -r --arg k "$skill" '
    if (.skills[$k] | type) == "object"
    then "\(.skills[$k].sha256 // "unresolved")\t\(.skills[$k].manifest_n // 0)"
    else "unresolved\t0"
    end' "$f" 2>/dev/null) || out=""

  [ -n "$out" ] || out=$(printf 'unresolved\t0')
  printf '%s\n' "$out"
  return 0
}

# Print the artifact's whole `skills` object as compact JSON, verbatim — this is
# what run-identity.sh embeds in META|version, so any projection here would have
# to be re-explained to every downstream consumer of runs.jsonl.
skill_fingerprints_all() {
  local f out
  f=$(_skill_fingerprints_file)

  if [ ! -r "$f" ] || ! command -v jq >/dev/null 2>&1; then
    printf '{}\n'
    return 0
  fi

  out=$(jq -c 'if (.skills | type) == "object" then .skills else {} end' "$f" 2>/dev/null) || out=""
  [ -n "$out" ] || out="{}"
  printf '%s\n' "$out"
  return 0
}

# Direct invocation only — sourcing must not run the CLI.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  case "${1:-}" in
  lookup) skill_version_lookup "${2:-}" ;;
  all) skill_fingerprints_all ;;
  *)
    echo "usage: skill-version.sh {lookup <skill>|all}" >&2
    exit 1
    ;;
  esac
fi
