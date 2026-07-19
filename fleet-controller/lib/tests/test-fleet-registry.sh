#!/usr/bin/env bash
# test-fleet-registry.sh — unit tests for lib/fleet-registry.sh
# Usage: bash test-fleet-registry.sh [test_name_filter]
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$LIB_DIR/fleet-registry.sh"

PASS=0
FAIL=0

_run() {
  local name="$1"
  shift
  if "$@" 2>/dev/null; then
    echo "PASS: $name"
    ((PASS++)) || true
  else
    echo "FAIL: $name"
    ((FAIL++)) || true
  fi
}

_setup_state_dir() {
  mktemp -d
}

# ── Registry tests ────────────────────────────────────────────────────────────────

test_registry_write_and_read() {
  local sd
  sd=$(_setup_state_dir)
  registry_write "CRE-101" "12345" "1" "test-spawn" "$sd"
  local json
  json=$(registry_read "CRE-101" "$sd")
  local tid pid gen
  tid=$(echo "$json" | jq -r '.tid')
  pid=$(echo "$json" | jq -r '.pid')
  gen=$(echo "$json" | jq -r '.generation')
  rm -rf "$sd"
  [ "$tid" = "CRE-101" ] && [ "$pid" = "12345" ] && [ "$gen" = "1" ]
}

test_registry_pid() {
  local sd
  sd=$(_setup_state_dir)
  registry_write "CRE-102" "54321" "2" "test-spawn" "$sd"
  local pid
  pid=$(registry_pid "CRE-102" "$sd")
  rm -rf "$sd"
  [ "$pid" = "54321" ]
}

test_registry_generation() {
  local sd
  sd=$(_setup_state_dir)
  registry_write "CRE-103" "11111" "3" "test-spawn" "$sd"
  local gen
  gen=$(registry_generation "CRE-103" "$sd")
  rm -rf "$sd"
  [ "$gen" = "3" ]
}

test_registry_generation_increments() {
  local sd
  sd=$(_setup_state_dir)
  registry_write "CRE-104" "11111" "2" "initial" "$sd"
  local gen1
  gen1=$(registry_generation "CRE-104" "$sd")
  # Simulate restart: write new generation
  registry_write "CRE-104" "22222" "3" "restart" "$sd"
  local gen2
  gen2=$(registry_generation "CRE-104" "$sd")
  rm -rf "$sd"
  [ "$gen1" = "2" ] && [ "$gen2" = "3" ]
}

test_registry_absent_means_no_worker() {
  local sd
  sd=$(_setup_state_dir)
  # No registry written — registry_generation should return 0
  local gen
  gen=$(registry_generation "NOEXIST-99" "$sd")
  rm -rf "$sd"
  [ "$gen" = "0" ]
}

test_registry_exists() {
  local sd
  sd=$(_setup_state_dir)
  registry_write "CRE-105" "12345" "1" "test" "$sd"
  registry_exists "CRE-105" "$sd" && local exists=0 || exists=1
  registry_exists "NOEXIST-99" "$sd" && local noexist=0 || noexist=1
  rm -rf "$sd"
  [ "$exists" -eq 0 ] && [ "$noexist" -eq 1 ]
}

test_registry_clear() {
  local sd
  sd=$(_setup_state_dir)
  registry_write "CRE-106" "12345" "1" "test" "$sd"
  registry_clear "CRE-106" "$sd"
  if registry_exists "CRE-106" "$sd"; then
    rm -rf "$sd"
    return 1
  fi
  rm -rf "$sd"
  return 0
}

# ── Fence tests ────────────────────────────────────────────────────────────────────

test_fence_write_and_read() {
  local sd
  sd=$(_setup_state_dir)
  fence_write "CRE-201" "2" "$sd"
  local json
  json=$(fence_read "CRE-201" "$sd")
  local fenced_gen
  fenced_gen=$(echo "$json" | jq -r '.fenced_generation')
  rm -rf "$sd"
  [ "$fenced_gen" = "2" ]
}

test_fence_superseded_generation_blocked() {
  local sd
  sd=$(_setup_state_dir)
  fence_write "CRE-202" "2" "$sd"
  # generation 2 (equal to fenced) → superseded
  if fence_is_superseded "CRE-202" "2" "$sd"; then
    rm -rf "$sd"
    return 0
  else
    echo "generation 2 should be blocked by fence at gen 2" >&2
    rm -rf "$sd"
    return 1
  fi
}

test_fence_current_generation_permitted() {
  local sd
  sd=$(_setup_state_dir)
  fence_write "CRE-203" "2" "$sd"
  # generation 3 > fenced 2 → allowed
  if fence_is_superseded "CRE-203" "3" "$sd"; then
    echo "generation 3 > fenced 2 should be allowed" >&2
    rm -rf "$sd"
    return 1
  else
    rm -rf "$sd"
    return 0
  fi
}

test_fence_no_fence_unrestricted() {
  local sd
  sd=$(_setup_state_dir)
  # No fence file → not superseded
  if fence_is_superseded "CRE-204" "1" "$sd"; then
    echo "no fence should mean unrestricted" >&2
    rm -rf "$sd"
    return 1
  else
    rm -rf "$sd"
    return 0
  fi
}

test_fence_clear() {
  local sd
  sd=$(_setup_state_dir)
  fence_write "CRE-205" "1" "$sd"
  fence_clear "CRE-205" "$sd"
  if [ -f "${sd}/CRE-205-fence" ]; then
    echo "fence file should be removed" >&2
    rm -rf "$sd"
    return 1
  fi
  rm -rf "$sd"
  return 0
}

# ── Integration: fence blocks lower generation, allows higher ──────────────────────

test_fence_generation_lower_blocked() {
  local sd
  sd=$(_setup_state_dir)
  fence_write "CRE-206" "5" "$sd"
  # generation 1 < fenced 5 → superseded
  if fence_is_superseded "CRE-206" "1" "$sd"; then
    rm -rf "$sd"
    return 0
  else
    echo "gen 1 should be superseded by fence at gen 5" >&2
    rm -rf "$sd"
    return 1
  fi
}

# ── Run all tests ──────────────────────────────────────────────────────────────────

FILTER="${1:-}"

for fn in \
  test_registry_write_and_read \
  test_registry_pid \
  test_registry_generation \
  test_registry_generation_increments \
  test_registry_absent_means_no_worker \
  test_registry_exists \
  test_registry_clear \
  test_fence_write_and_read \
  test_fence_superseded_generation_blocked \
  test_fence_current_generation_permitted \
  test_fence_no_fence_unrestricted \
  test_fence_clear \
  test_fence_generation_lower_blocked; do
  [ -z "$FILTER" ] || [[ "$fn" == *"$FILTER"* ]] || continue
  _run "$fn" "$fn"
done

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
