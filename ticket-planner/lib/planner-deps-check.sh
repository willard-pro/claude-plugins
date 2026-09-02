#!/usr/bin/env bash
# planner-deps-check.sh — Dependency acyclicity validation for planned tickets.
#
# Validates that a set of blocked-by dependencies forms a DAG before any tickets
# are created. A cycle would produce tickets that can never dispatch — a deadlock
# the pipeline cannot diagnose.
#
# Usage:
#   planner_deps_check_acyclic <deps_json>
#     deps_json: JSON object mapping ticket-id → [list of blocked-by IDs]
#     Returns: 0 if acyclic, 1 if cyclic (reports cycle to stderr).
#
#   planner_deps_topological_sort <deps_json>
#     Returns topological order as JSON array. Empty array if cyclic.
#
# Sourceable library — no set -euo pipefail.

# ── Cycle detection (DFS-based) ────────────────────────────────────────────────

# Check whether a dependency graph is acyclic.
# Input: JSON object {"TICKET-1": ["TICKET-2"], "TICKET-2": []}
# Output: exit 0 if acyclic, exit 1 if cyclic (writes cycle path to stderr).
planner_deps_check_acyclic() {
  local deps_json="$1"

  if [ -z "$deps_json" ] || [ "$deps_json" = "{}" ]; then
    return 0 # Empty graph is trivially acyclic
  fi

  # Use tsort (standard Unix utility) for topological sort.
  # tsort reads pairs (A B) meaning A → B (A depends on B, so B must come first).
  # We write pairs as "blocker ticket" (ticket depends on blocker, so blocker first).
  local pairs
  pairs=$(echo "$deps_json" | jq -r '
    to_entries[] |
    .key as $ticket |
    .value[]? |
    "\(. ) \($ticket)"
  ' 2>/dev/null)

  if [ -z "$pairs" ]; then
    return 0 # No edges — trivially acyclic
  fi

  # Run tsort with timeout to prevent unbounded hang on malformed graphs.
  # POSIX specifies no upper bound on tsort runtime.
  local tsort_timeout="${PLANNER_TSORT_TIMEOUT:-30}"
  if echo "$pairs" | timeout "$tsort_timeout" tsort >/dev/null 2>&1; then
    return 0
  else
    local tsort_rc=$?
    if [ "$tsort_rc" -eq 124 ]; then
      echo "planner-deps-check: tsort timed out after ${tsort_timeout}s — dependency graph may be malformed" >&2
    else
      echo "planner-deps-check: cycle detected in dependency graph" >&2
    fi
    # Try to identify the cycle for diagnostics
    local cycle_info
    cycle_info=$(echo "$pairs" | timeout "$tsort_timeout" tsort 2>&1 || true)
    echo "planner-deps-check: tsort output: $cycle_info" >&2
    return 1
  fi
}

# ── Topological sort ───────────────────────────────────────────────────────────

# Return topological order as a JSON array. Empty array if cyclic.
# Usage: planner_deps_topological_sort <deps_json>
planner_deps_topological_sort() {
  local deps_json="$1"

  if [ -z "$deps_json" ] || [ "$deps_json" = "{}" ]; then
    echo "[]"
    return 0
  fi

  local pairs
  pairs=$(echo "$deps_json" | jq -r '
    to_entries[] |
    .key as $ticket |
    .value[]? |
    "\(. ) \($ticket)"
  ' 2>/dev/null)

  if [ -z "$pairs" ]; then
    echo "[]"
    return 0
  fi

  local sorted
  if sorted=$(echo "$pairs" | tsort 2>/dev/null); then
    echo "$sorted" | jq -R -s 'split("\n") | map(select(length > 0))' 2>/dev/null
    return 0
  else
    echo "[]"
    return 1
  fi
}

# ── Dependency helpers ─────────────────────────────────────────────────────────

# Extract blocked-by dependencies from a set of planned tickets.
# Input: JSON array of ticket objects with "id" and "blocked_by" fields.
# Output: JSON object mapping ticket-id → [blocked-by IDs].
# Usage: planner_deps_from_tickets <tickets_json>
planner_deps_from_tickets() {
  local tickets_json="$1"
  echo "$tickets_json" | jq '[
    .[] | select(.blocked_by != null and (.blocked_by | length) > 0) |
    {key: .id, value: .blocked_by}
  ] | from_entries' 2>/dev/null || echo "{}"
}

# Validate that all blocked-by targets exist in the ticket set.
# A ticket depending on a non-existent ticket is an error — it can never dispatch.
# Usage: planner_deps_validate_targets <deps_json> <ticket_ids_json>
# Returns: 0 if all targets exist, 1 with missing IDs on stderr.
planner_deps_validate_targets() {
  local deps_json="$1" ticket_ids_json="$2"

  local missing
  missing=$(echo "$deps_json" | jq -r --argjson ids "$ticket_ids_json" '
    to_entries[] | .value[]? |
    select(. as $dep | $ids | index($dep) | not)
  ' 2>/dev/null | sort -u)

  if [ -n "$missing" ]; then
    echo "planner-deps-check: blocked-by targets not in ticket set:" >&2
    echo "$missing" | while read -r id; do
      echo "  - $id" >&2
    done
    return 1
  fi
  return 0
}

# ── Shared-branch recommendation ──────────────────────────────────────────────

# Decide whether an initiative warrants a shared (epic) integration branch.
#
# The recommendation is pure bash over the dependency graph. Two conditions must
# both be met: ≥ 3 planned tickets, AND a dependency chain of depth ≥ 2.
#
# Thresholds are PROVISIONAL and unvalidated against real usage data. The
# asymmetry is deliberate: under-recommending costs one operator flag;
# over-recommending silently changes the merge topology of ordinary work.
#
# Usage: planner_branch_directive_recommend <initiative_id>
# Output: JSON object with recommend, reason, ticket_count, chain_depth.
# Returns: 0 if decision computed, 1 if error (initiative dir missing, etc.).
planner_branch_directive_recommend() {
  local initiative_id="$1"
  local repos_root="${REPOS_ROOT:-${HOME}/repos}"
  local specs_dir="${repos_root}/.ticket-auto/initiatives/${initiative_id}/artifacts/specs"

  if [ ! -d "$specs_dir" ]; then
    echo "planner-deps-check: specs directory not found: $specs_dir" >&2
    echo '{"recommend":false,"reason":"specs directory not found","ticket_count":0,"chain_depth":0}'
    return 1
  fi

  # ── Build ticket JSON array from spec files ─────────────────────────────────
  local tickets_json="["
  local count=0
  local spec_file slug signals blocked_by

  for spec_file in "$specs_dir"/*.md; do
    [ -f "$spec_file" ] || continue
    [ "$(basename "$spec_file")" = "INDEX.md" ] && continue

    # Derive ticket slug from filename (strip .md)
    slug=$(basename "$spec_file" .md)
    count=$((count + 1))

    # Extract Signals JSON block (```json ... ```)
    signals=$(sed -n '/```json/,/```/p' "$spec_file" 2>/dev/null | sed '1d;$d' | jq -e . 2>/dev/null || echo "{}")

    # Extract blocked_by, defaulting to empty array. No Specify-phase output
    # observed in practice ever populates Signals.blocked_by — the canonical,
    # actually-authored dependency format is the spec's `## Labels` line, a
    # comma-separated list including zero or more `blocked-by:<sibling-slug>`
    # entries (the same format Ticket Gen reads to set the real Linear
    # `blocked-by:{ID}` label). Falling back to that line when Signals is
    # empty means this recommender sees the same dependency graph Ticket Gen
    # will actually create — instead of a chain depth of 0 on every real
    # initiative and a shared-branch directive that never fires.
    blocked_by=$(echo "$signals" | jq -r '.blocked_by // []' 2>/dev/null)
    if [ "$blocked_by" = "[]" ] || [ -z "$blocked_by" ]; then
      # The Labels line's own formatting is not consistent across initiatives
      # — some wrap every entry in backticks (`` `blocked-by:vs-1a-...` ``),
      # others don't (`blocked-by:5-1-...`) — so match the first non-empty
      # line after the "## Labels" heading and strip optional backticks
      # around each blocked-by token, rather than anchoring on either style.
      local labels_line
      labels_line=$(awk '/^## Labels/{f=1;next} f && NF{print; exit}' "$spec_file" 2>/dev/null)
      # grep legitimately exits 1 when the Labels line has no blocked-by token
      # (the common case). Under a caller's `set -o pipefail` (inherited via
      # source), that non-zero exit would make the *whole* pipeline below
      # report failure even though jq -sc already produced a valid "[]" —
      # which would then also run `|| echo "[]"`, appending a second "[]"
      # line and leaving $blocked_by as two concatenated JSON documents
      # (invalid input to --argjson below). Neutralize grep's exit status so
      # only a genuine jq failure triggers the fallback.
      blocked_by=$(echo "$labels_line" | { grep -oE 'blocked-by:`?[A-Za-z0-9_-]+`?' || true; } |
        sed -E 's/blocked-by:`?([A-Za-z0-9_-]+)`?/\1/' |
        jq -R . | jq -sc . 2>/dev/null || echo "[]")
    fi

    # Build JSON entry: {"id": "slug", "blocked_by": [...]}
    if [ "$count" -gt 1 ]; then
      tickets_json+=","
    fi
    tickets_json+=$(jq -n --arg id "$slug" --argjson deps "$blocked_by" '{id: $id, blocked_by: $deps}')
  done
  tickets_json+="]"

  # A ticket's `blocked-by` reference isn't always the full spec-filename
  # slug the way `id` above always is — VS-1/2/3 always wrote the full slug
  # ("blocked-by:vs-3a-schema-driven-type-classification-and-field-
  # extraction"), but VS-4's Specify phase wrote short-form references
  # ("blocked-by:exc-1") instead. Left as-is, every such entry silently
  # fails to match any `id` in the DP lookup below, capping every ticket's
  # computed depth at 1 regardless of how deep the real chain is — VS-4's
  # real depth-2 chain (exc-1 → exc-3 → exc-4) came back as 1, just under
  # the ≥2 threshold, when a shared branch was actually warranted.
  # Resolve each unmatched token against the known id set by unambiguous
  # `-`-bounded prefix match; anything still unresolved is left as-is
  # (matches prior — silently non-matching — behavior, not worse).
  tickets_json=$(echo "$tickets_json" | jq '
    ( [ .[].id ] ) as $ids
    | map(.blocked_by |= map(
        . as $tok
        | if ($ids | index($tok)) then $tok
          else ( [ $ids[] | select(. == $tok or startswith($tok + "-")) ] ) as $matches
          | if ($matches | length) == 1 then $matches[0] else $tok end
          end
      ))
  ' 2>/dev/null || echo "$tickets_json")

  # ── Condition 1: ticket count ─────────────────────────────────────────────
  if [ "$count" -lt 3 ]; then
    echo "{\"recommend\":false,\"reason\":\"insufficient ticket count: ${count} < 3\",\"ticket_count\":${count},\"chain_depth\":0}"
    return 0
  fi

  # ── Build dependency graph and compute chain depth ─────────────────────────
  local deps_json
  deps_json=$(planner_deps_from_tickets "$tickets_json")

  # If no dependencies, chain depth is trivially 0
  if [ "$deps_json" = "{}" ] || [ -z "$deps_json" ]; then
    echo "{\"recommend\":false,\"reason\":\"no dependencies among ${count} tickets\",\"ticket_count\":${count},\"chain_depth\":0}"
    return 0
  fi

  # Compute chain depth from topological ordering (DP on sorted nodes)
  local sorted depth_json chain_depth
  sorted=$(planner_deps_topological_sort "$deps_json" 2>/dev/null || echo "[]")

  if [ "$sorted" = "[]" ]; then
    echo "{\"recommend\":false,\"reason\":\"dependency graph is cyclic — cannot compute chain depth\",\"ticket_count\":${count},\"chain_depth\":0}"
    return 0
  fi

  # DP: longest path (in edges) ending at each node
  # For each node u in topological order:
  #   longest[u] = max(0, 1 + max_{v where u blocked_by v} longest[v])
  # The `reduce` uses `. as $acc` to capture the accumulator before pipe iteration
  # rebinds `.` to the string value from [$deps[$u][]]. $acc[.] then reads the
  # predecessor's stored depth.
  depth_json=$(echo "$sorted" | jq --argjson deps "$deps_json" '
    reduce .[] as $u ({};
      . as $acc | .[$u] = (
        [ ($deps[$u] // [])[] | 1 + ($acc[.] // 0) ] | max // 0
      )
    )
  ' 2>/dev/null || echo "{}")

  # Chain depth = max edge count across all nodes
  chain_depth=$(echo "$depth_json" | jq '[.[]] | max // 0' 2>/dev/null || echo "0")

  # ── Condition 2: chain depth ≥ 2 ──────────────────────────────────────────
  if [ "$chain_depth" -ge 2 ] 2>/dev/null; then
    echo "{\"recommend\":true,\"reason\":\"${count} tickets with dependency chain depth ${chain_depth}\",\"ticket_count\":${count},\"chain_depth\":${chain_depth}}"
  else
    echo "{\"recommend\":false,\"reason\":\"chain depth ${chain_depth} below threshold 2 (${count} tickets)\",\"ticket_count\":${count},\"chain_depth\":${chain_depth}}"
  fi
  return 0
}
