#!/usr/bin/env bash
# template-select.sh — deterministic type-to-template resolution.
# Sourceable bash library. Does NOT set -euo pipefail (caller controls error
# handling). Resolves a task type label to its template file path.
#
# Exit codes:
#   0 — resolved successfully
#   3 — unknown or empty type (hard failure, no fallback)
#
# Dependencies: none (pure bash lookup)
#
# Usage:
#   source lib/template-select.sh
#   resolve_template "bug"        # prints templates/bug.md, exits 0
#   resolve_template "refactor"   # prints templates/improvement.md, exits 0 (alias)
#   resolve_template "epic"       # exits 3 (unknown type, no fallback)

# ── Type-to-template map ─────────────────────────────────────────────────────

# Ordered list of known types (used for validation, not iteration)
KNOWN_TYPES=("bug" "feature" "improvement" "security" "chore" "refactor")

# ── Public API ────────────────────────────────────────────────────────────────

# resolve_template <type>
# Prints the template path under templates/ matching the given type.
# refactor is an alias for improvement.
# Unknown or empty type → exit 3, no stdout.
resolve_template() {
  local type="$1"

  # Guard: empty type
  if [ -z "$type" ]; then
    return 3
  fi

  case "$type" in
  bug) echo "templates/bug.md" ;;
  feature) echo "templates/feature.md" ;;
  improvement) echo "templates/improvement.md" ;;
  security) echo "templates/security.md" ;;
  chore) echo "templates/chore.md" ;;
  refactor) echo "templates/improvement.md" ;; # alias → improvement
  *)
    # Unknown type — hard failure, no silent fallback
    return 3
    ;;
  esac

  return 0
}

# ── Self-test mode ────────────────────────────────────────────────────────────

if [ "${1:-}" = "--self-test" ]; then
  echo "Running self-tests..."

  # Known type resolution
  test "$(resolve_template "bug")" = "templates/bug.md" &&
    echo "✓ bug → templates/bug.md" || echo "✗ bug → templates/bug.md"
  test "$(resolve_template "feature")" = "templates/feature.md" &&
    echo "✓ feature → templates/feature.md" || echo "✗ feature → templates/feature.md"
  test "$(resolve_template "improvement")" = "templates/improvement.md" &&
    echo "✓ improvement → templates/improvement.md" || echo "✗ improvement → templates/improvement.md"
  test "$(resolve_template "security")" = "templates/security.md" &&
    echo "✓ security → templates/security.md" || echo "✗ security → templates/security.md"
  test "$(resolve_template "chore")" = "templates/chore.md" &&
    echo "✓ chore → templates/chore.md" || echo "✗ chore → templates/chore.md"

  # Alias resolution
  test "$(resolve_template "refactor")" = "templates/improvement.md" &&
    echo "✓ refactor → templates/improvement.md (alias)" || echo "✗ refactor → templates/improvement.md"

  # Unknown/empty type → exit 3
  if ! resolve_template "epic" 2>/dev/null; then
    rc=$?
    [ "$rc" = "3" ] && echo "✓ epic (unknown) → exit 3" || echo "✗ epic → exit $rc (expected 3)"
  fi

  if ! resolve_template "" 2>/dev/null; then
    rc=$?
    [ "$rc" = "3" ] && echo "✓ empty → exit 3" || echo "✗ empty → exit $rc (expected 3)"
  fi

  # Determinism: repeated calls return identical result
  r1=$(resolve_template "feature")
  r2=$(resolve_template "feature")
  test "$r1" = "$r2" && echo "✓ deterministic: feature returns same path both calls" ||
    echo "✗ deterministic: feature returned '$r1' then '$r2'"

  echo "Self-tests complete — run test-template-select.sh for full coverage."
  exit 0
fi
