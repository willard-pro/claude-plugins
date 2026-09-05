#!/usr/bin/env bash
# epic-branch.sh — epic branch lifecycle management for ticket-auto-pipeline.
# Sourceable bash library. Does NOT set -euo pipefail (caller controls error
# handling). Creates, syncs, and opens integration PRs for epic branches declared
# via the `## Branch Directive` block on initiative epics.
#
# Dependencies: config.sh (for REPOS_ROOT), linear-api.sh (for get_issue,
#               get_parent_with_children), branch-directive-check.sh (for
#               check_branch_directive_description)
#
# Usage:
#   source lib/epic-branch.sh
#   ensure_epic_branch "CRE-100" "/path/to/repo"
#   epic_branch_sync "CRE-100" "/path/to/repo"
#   epic_branch_children_done "CRE-100"
#   epic_branch_open_pr "CRE-100" "/path/to/repo"

# ── Helpers ───────────────────────────────────────────────────────────────────

# _resolve_repo <repo_path>
# Resolves the repo path for epic branch operations. Falls back to current
# directory when not provided. Exits with error if the resolved path is not
# a git repository.
_resolve_repo() {
  local repo_path="${1:-.}"
  if [ ! -d "$repo_path/.git" ] && ! git -C "$repo_path" rev-parse --git-dir >/dev/null 2>&1; then
    echo "epic-branch: $repo_path is not a git repository" >&2
    return 1
  fi
  echo "$repo_path"
}

# _parse_directive <description>
# Parses the Branch Directive from an epic description and sets:
#   _DIRECTIVE_BRANCH, _DIRECTIVE_BASE, _DIRECTIVE_MERGE_POLICY, _DIRECTIVE_SYNC_POLICY,
#   _DIRECTIVE_UAT_POLICY (normalised — 'per-ticket' when the field is absent)
# Returns 0 when a valid directive is present, 1 when absent, 2 when malformed.
_parse_directive() {
  local description="$1"

  _DIRECTIVE_BRANCH=""
  _DIRECTIVE_BASE=""
  _DIRECTIVE_MERGE_POLICY=""
  _DIRECTIVE_SYNC_POLICY=""
  _DIRECTIVE_UAT_POLICY=""

  local directive_output
  directive_output=$(check_branch_directive_description "$description" 2>/dev/null) || {
    local directive_exit=$?
    return "$directive_exit"
  }

  # Extract parsed values via targeted sed — no eval, no sourcing untrusted input.
  # check_branch_directive_description emits: KEY='value' with single-quoted, validated values.
  _DIRECTIVE_BRANCH=$(echo "$directive_output" | sed -n "s/^BRANCH_DIRECTIVE_BRANCH='\\(.*\\)'$/\\1/p")
  _DIRECTIVE_BASE=$(echo "$directive_output" | sed -n "s/^BRANCH_DIRECTIVE_BASE='\\(.*\\)'$/\\1/p")
  _DIRECTIVE_MERGE_POLICY=$(echo "$directive_output" | sed -n "s/^BRANCH_DIRECTIVE_MERGE_POLICY='\\(.*\\)'$/\\1/p")
  _DIRECTIVE_SYNC_POLICY=$(echo "$directive_output" | sed -n "s/^BRANCH_DIRECTIVE_SYNC_POLICY='\\(.*\\)'$/\\1/p")
  _DIRECTIVE_UAT_POLICY=$(echo "$directive_output" | sed -n "s/^BRANCH_DIRECTIVE_UAT_POLICY='\\(.*\\)'$/\\1/p")

  return 0
}

# _get_epic_description <EPIC_ID>
# Fetches the epic's description from Linear. Emits the description string.
_get_epic_description() {
  local epic_id="$1"
  local issue_json
  issue_json=$(get_issue "$epic_id" 2>/dev/null) || {
    echo "epic-branch: failed to fetch epic $epic_id" >&2
    return 1
  }
  # get_issue already unwraps .data.issue — read the description directly.
  echo "$issue_json" | jq -r '.description // ""'
}

# _resolve_ref <repo_path> <branch>
# Echoes a resolvable ref for a branch — the local ref when present, otherwise
# the origin-tracking ref. Returns 1 when neither exists.
_resolve_ref() {
  local repo_path="$1"
  local branch="$2"

  if git -C "$repo_path" rev-parse --verify --quiet "refs/heads/$branch" >/dev/null 2>&1; then
    echo "$branch"
    return 0
  fi
  if git -C "$repo_path" rev-parse --verify --quiet "refs/remotes/origin/$branch" >/dev/null 2>&1; then
    echo "origin/$branch"
    return 0
  fi
  return 1
}

# _epic_branch_has_commits <repo_path> <branch> <base>
# Returns 0 when the epic branch carries at least one commit beyond base.
#
# Returns 1 when it carries none, and also when either ref cannot be resolved.
# The repo set enumerated for an epic is every repo under REPOS_ROOT, which
# includes repos the epic never touched; attempting a PR for those fails on
# every detector cycle, forever. "Nothing to integrate" is the correct reading
# of both cases, so both skip rather than error.
_epic_branch_has_commits() {
  local repo_path="$1"
  local branch="$2"
  local base="$3"

  local branch_ref base_ref count
  branch_ref=$(_resolve_ref "$repo_path" "$branch") || return 1
  base_ref=$(_resolve_ref "$repo_path" "$base") || return 1

  count=$(git -C "$repo_path" rev-list --count "$base_ref..$branch_ref" 2>/dev/null) || return 1
  [ "${count:-0}" -gt 0 ]
}

# _branch_exists <repo_path> <branch_name>
# Returns 0 if the branch exists locally or on origin.
_branch_exists() {
  local repo_path="$1"
  local branch="$2"

  # Check local
  if git -C "$repo_path" rev-parse --verify "$branch" >/dev/null 2>&1; then
    return 0
  fi

  # Check remote
  if git -C "$repo_path" rev-parse --verify "origin/$branch" >/dev/null 2>&1; then
    return 0
  fi

  return 1
}

# _base_advanced <repo_path> <epic_branch> <base_branch>
# Returns 0 if the base branch has commits that are not yet in the epic branch.
# Fetch must have been called before this check.
_base_advanced() {
  local repo_path="$1"
  local epic_branch="$2"
  local base_branch="$3"

  # Ensure both refs exist
  git -C "$repo_path" rev-parse --verify "$epic_branch" >/dev/null 2>&1 || return 1
  git -C "$repo_path" rev-parse --verify "origin/$base_branch" >/dev/null 2>&1 || return 1

  # merge-base of epic and origin/base
  local merge_base
  merge_base=$(git -C "$repo_path" merge-base "$epic_branch" "origin/$base_branch" 2>/dev/null) || return 1

  # Base HEAD
  local base_head
  base_head=$(git -C "$repo_path" rev-parse "origin/$base_branch" 2>/dev/null) || return 1

  # Advanced if base HEAD differs from merge-base
  [ "$base_head" != "$merge_base" ]
}

# ── Public API ────────────────────────────────────────────────────────────────

# ensure_epic_branch <EPIC_ID> [repo_path]
# Ensures the epic branch declared by the epic's Branch Directive exists and is
# pushed to origin. Idempotent — safe to call on every dispatch cycle.
# Exit codes:
#   0 — branch exists (created or pre-existing) OR no directive present
#   1 — error (fetch failure, git failure, malformed directive)
ensure_epic_branch() {
  local epic_id="$1"
  local repo_path="${2:-.}"
  local dry_run="${FLEET_DRY_RUN:-false}"

  # Resolve repo
  repo_path=$(_resolve_repo "$repo_path") || return 1

  # Fetch epic description
  local description
  description=$(_get_epic_description "$epic_id") || return 1

  # Parse directive
  _parse_directive "$description" || {
    local parse_exit=$?
    case "$parse_exit" in
    1) return 0 ;; # No directive — no-op
    2)
      echo "epic-branch: epic $epic_id has a malformed Branch Directive" >&2
      return 1
      ;;
    esac
  }

  # Shouldn't happen but guard against empty branch/base
  if [ -z "$_DIRECTIVE_BRANCH" ] || [ -z "$_DIRECTIVE_BASE" ]; then
    return 0
  fi

  local branch="$_DIRECTIVE_BRANCH"
  local base="$_DIRECTIVE_BASE"

  # Fetch origin to get latest refs
  git -C "$repo_path" fetch origin 2>/dev/null || true

  # Already exists?
  if _branch_exists "$repo_path" "$branch"; then
    return 0
  fi

  # Create and push
  if [ "$dry_run" = "true" ]; then
    echo "[DRY-RUN] would create branch '$branch' from '$base' for epic $epic_id"
    return 0
  fi

  # Create the branch as a plain ref — no checkout. The shared clone may be
  # used concurrently by other processes; branch creation must never move
  # its checked-out HEAD or touch its working tree.
  if ! git -C "$repo_path" branch "$branch" "origin/$base" >/dev/null 2>&1; then
    echo "epic-branch: failed to create branch '$branch' from '$base'" >&2
    return 1
  fi

  # Push to origin. On failure, delete the local ref: leaving it behind makes
  # _branch_exists short-circuit every later cycle, so the remote branch would
  # never be (re)created — the epic wedges until manual cleanup. Deleting lets
  # the next dispatch cycle retry creation from scratch.
  if ! git -C "$repo_path" push origin "$branch" >/dev/null 2>&1; then
    git -C "$repo_path" branch -D "$branch" >/dev/null 2>&1 || true
    echo "epic-branch: failed to push branch '$branch' to origin" >&2
    return 1
  fi

  echo "epic-branch: created and pushed '$branch' (from '$base') for epic $epic_id"
  return 0
}

# epic_branch_sync <EPIC_ID> [repo_path]
# Integrates the base branch into the epic branch when the directive's sync
# policy is "rebase-on-base-change". No-op for policy "none" or unadvanced base.
#
# Prefers merge-from-base over rebase: the epic branch is published and in-flight
# worktrees are based on it, so history must never be rewritten.
#
# On conflict: leaves the branch untouched, reports, and exits non-zero.
# Never force-pushes.
#
# Exit codes:
#   0 — sync complete or no-op (no directive, policy=none, base unadvanced)
#   1 — error (conflict, git failure)
epic_branch_sync() {
  local epic_id="$1"
  local repo_path="${2:-.}"
  local dry_run="${FLEET_DRY_RUN:-false}"

  # Resolve repo
  repo_path=$(_resolve_repo "$repo_path") || return 1

  # Fetch epic description
  local description
  description=$(_get_epic_description "$epic_id") || return 1

  # Parse directive
  _parse_directive "$description" || {
    local parse_exit=$?
    case "$parse_exit" in
    1) return 0 ;; # No directive
    2)
      echo "epic-branch: epic $epic_id has a malformed Branch Directive" >&2
      return 1
      ;;
    esac
  }

  # No-op for "none" sync policy
  if [ "$_DIRECTIVE_SYNC_POLICY" = "none" ]; then
    return 0
  fi

  # Only "rebase-on-base-change" triggers sync
  if [ "$_DIRECTIVE_SYNC_POLICY" != "rebase-on-base-change" ]; then
    return 0
  fi

  local branch="$_DIRECTIVE_BRANCH"
  local base="$_DIRECTIVE_BASE"

  # Fetch latest from origin
  git -C "$repo_path" fetch origin 2>/dev/null || {
    echo "epic-branch: fetch failed for $epic_id" >&2
    return 1
  }

  # Ensure the epic branch exists
  if ! _branch_exists "$repo_path" "$branch"; then
    echo "epic-branch: epic branch '$branch' does not exist — run ensure_epic_branch first" >&2
    return 1
  fi

  # Check if base has advanced
  if ! _base_advanced "$repo_path" "$branch" "$base"; then
    # Base hasn't advanced — no-op
    return 0
  fi

  if [ "$dry_run" = "true" ]; then
    echo "[DRY-RUN] would merge 'origin/$base' into '$branch' for epic $epic_id"
    return 0
  fi

  # Checkout the epic branch in the main repo (not a worktree)
  local original_branch
  original_branch=$(git -C "$repo_path" rev-parse --abbrev-ref HEAD 2>/dev/null)

  # Switch to epic branch, merge base, push result
  git -C "$repo_path" checkout "$branch" >/dev/null 2>&1 || {
    echo "epic-branch: failed to checkout '$branch' for sync" >&2
    return 1
  }

  # Merge origin/base into the epic branch. Never rebase — this is a published
  # branch that worktrees are based on.
  local merge_output
  merge_output=$(git -C "$repo_path" merge "origin/$base" 2>&1) || {
    # Conflict — abort merge, leave branch untouched
    echo "epic-branch: merge conflict syncing '$branch' with 'origin/$base': $merge_output" >&2
    git -C "$repo_path" merge --abort 2>/dev/null || true
    # Return to original branch if possible
    git -C "$repo_path" checkout "$original_branch" >/dev/null 2>&1 || true
    return 1
  }

  # Push the merged result (NOT force-pushed)
  if ! git -C "$repo_path" push origin "$branch" >/dev/null 2>&1; then
    echo "epic-branch: failed to push merged '$branch'" >&2
    # Return to original branch
    git -C "$repo_path" checkout "$original_branch" >/dev/null 2>&1 || true
    return 1
  fi

  # Return to original branch
  git -C "$repo_path" checkout "$original_branch" >/dev/null 2>&1 || true

  echo "epic-branch: synced '$branch' with 'origin/$base' for epic $epic_id"
  return 0
}

# epic_branch_children_done <EPIC_ID> [children_json]
# Checks whether every planned child of the epic is in the Done state.
# Pure bash — no LLM involvement.
#
# When children_json is provided (JSON array from get_parent_with_children),
# uses it directly for testing. Otherwise fetches from Linear via
# get_parent_with_children.
#
# Exit codes:
#   0 — all children are Done
#   1 — not ready (some children not Done OR zero children)
epic_branch_children_done() {
  local epic_id="$1"
  local children_json

  # Distinguish "no argument" from "explicitly empty": $2 unset → fetch;
  # $2 set (even to empty string) → use as-is (empty means zero children).
  if [ $# -ge 2 ]; then
    children_json="$2"
  else
    children_json=""
  fi

  # Fetch if not provided as argument
  if [ $# -lt 2 ]; then
    if declare -f get_parent_with_children >/dev/null 2>&1; then
      local parent_data
      parent_data=$(get_parent_with_children "$epic_id" 2>/dev/null) || {
        echo "epic-branch: failed to fetch children for epic $epic_id" >&2
        return 1
      }
      children_json=$(echo "$parent_data" | jq -c '.children[] // empty' 2>/dev/null)
    else
      # Fallback: direct GraphQL query for children
      local query resp
      query=$(jq -n --arg id "$epic_id" '{
        query: "query($id: String!) { issue(id: $id) { children { nodes { id identifier state { name } labels { nodes { name } } } } } }",
        variables: {id: $id}
      }')
      resp=$(curl -s -X POST "${LINEAR_API_URL:-https://api.linear.app/graphql}" \
        -H "Content-Type: application/json" \
        -H "Authorization: ${LINEAR_API_KEY}" \
        -d "$query" 2>/dev/null) || {
        echo "epic-branch: failed to fetch children for epic $epic_id" >&2
        return 1
      }
      children_json=$(echo "$resp" | jq -c '.data.issue.children.nodes[] // empty' 2>/dev/null)
    fi
  fi

  # Zero children — not ready
  if [ -z "$children_json" ]; then
    return 1
  fi

  local child_count=0
  local done_count=0

  while IFS= read -r child; do
    [ -z "$child" ] && continue
    local child_state child_labels
    child_state=$(echo "$child" | jq -r '.state.name // empty')
    child_labels=$(echo "$child" | jq -r '.labels.nodes[]?.name // empty' 2>/dev/null)
    # Readiness contract: the epic's PLANNED children must all be Done.
    # Non-planned children (future work not yet planned) are out of scope —
    # counting them blocked readiness forever.
    if ! echo "$child_labels" | grep -q "planned" 2>/dev/null; then
      continue
    fi
    child_count=$((child_count + 1))
    if [ "$child_state" = "Done" ]; then
      done_count=$((done_count + 1))
    fi
  done <<<"$children_json"

  # Zero children after parsing — not ready
  [ "$child_count" -eq 0 ] && return 1

  # All children must be Done
  [ "$done_count" -eq "$child_count" ]
}

# epic_branch_open_pr <EPIC_ID> [repo_path] [children_json] [epic_description]
# Opens a pull request from the epic branch to its declared base when the epic
# is ready (all children Done) and no integration PR already exists.
#
# Idempotent — second call finds the existing PR and exits 0.
# NEVER merges the PR, regardless of FLEET_EPIC_AUTO_PR or any other setting.
# FLEET_EPIC_AUTO_PR (default false) gates whether the PR is opened automatically.
#
# children_json and epic_description are optional. When a caller has already
# fetched them for the epic (a scan iterating many repositories, for instance),
# passing them in avoids re-fetching per repository — otherwise Linear requests
# multiply by the repo count on every cycle.
#
# Exit codes:
#   0 — PR exists or was opened, OR nothing to do (not ready, disabled, skipped)
#   1 — error
#
# Because exit 0 covers both "a PR is open" and "nothing was opened", loop
# completion is NOT evidence that any PR exists. Callers that need to know read
# EPIC_BRANCH_PR_STATE, set on every return path:
#   open — an integration PR exists for this repo (pre-existing or just opened)
#   none — no PR was opened and none exists
EPIC_BRANCH_PR_STATE="none"

epic_branch_open_pr() {
  local epic_id="$1"
  local repo_path="${2:-.}"
  local children_json="${3:-}"
  local cached_description="${4:-}"
  local dry_run="${FLEET_DRY_RUN:-false}"
  local auto_pr="${FLEET_EPIC_AUTO_PR:-false}"

  EPIC_BRANCH_PR_STATE="none"

  # Resolve repo
  repo_path=$(_resolve_repo "$repo_path") || return 1

  # Check readiness — reuse the caller's children when supplied.
  #
  # Forward by arity, not by value: epic_branch_children_done treats "no second
  # argument" as "fetch them" and "second argument present but empty" as "this
  # epic has zero children". Passing "$children_json" unconditionally would turn
  # an empty cache into the latter.
  local _ready=0
  if [ -n "$children_json" ]; then
    epic_branch_children_done "$epic_id" "$children_json" || _ready=$?
  else
    epic_branch_children_done "$epic_id" || _ready=$?
  fi
  if [ "$_ready" -ne 0 ]; then
    # Not ready — nothing to do
    return 0
  fi

  # Epic description — reuse the caller's when supplied.
  local description
  if [ -n "$cached_description" ]; then
    description="$cached_description"
  else
    description=$(_get_epic_description "$epic_id") || return 1
  fi

  _parse_directive "$description" || {
    local parse_exit=$?
    case "$parse_exit" in
    1) return 0 ;; # No directive
    2)
      echo "epic-branch: epic $epic_id has a malformed Branch Directive" >&2
      return 1
      ;;
    esac
  }

  local branch="$_DIRECTIVE_BRANCH"
  local base="$_DIRECTIVE_BASE"

  # Skip repos the epic never touched. They are enumerated alongside the ones
  # it did, and without this every cycle attempts — and fails — a PR for each.
  if ! _epic_branch_has_commits "$repo_path" "$branch" "$base"; then
    return 0
  fi

  # Check if a PR already exists for this branch→base pair
  local remote_url repo_slug existing_pr
  remote_url=$(git -C "$repo_path" remote get-url origin 2>/dev/null || echo "")
  repo_slug=$(echo "$remote_url" | sed 's|.*[:/]\([^/]*/[^/]*\)\.git.*|\1|')
  existing_pr=$(gh pr list --repo "$repo_slug" \
    --head "$branch" --base "$base" --json number --jq '.[0].number // empty' 2>/dev/null)

  if [ -n "$existing_pr" ]; then
    # PR already exists — idempotent, never merge
    EPIC_BRANCH_PR_STATE="open"
    return 0
  fi

  # Ready, no PR exists — open one if enabled
  if [ "$dry_run" = "true" ]; then
    echo "[DRY-RUN] would open integration PR from '$branch' into '$base' for epic $epic_id"
    return 0
  fi

  if [ "$auto_pr" != "true" ]; then
    echo "epic-branch: epic $epic_id ready but FLEET_EPIC_AUTO_PR is not enabled — PR not opened"
    return 0
  fi

  # Open the PR — NEVER merge it
  local pr_title pr_body
  pr_title="Integration: $epic_id to $base"
  pr_body=$(
    cat <<EOF
## Epic Integration PR — $epic_id

This PR integrates all completed child tickets from the \`$branch\` epic branch into \`$base\`.

**IMPORTANT: This PR must never be auto-merged.** Review and merge manually.

### Branch Directive
- **Branch:** \`$branch\`
- **Base:** \`$base\`
- **Merge Policy:** \`$_DIRECTIVE_MERGE_POLICY\`
- **Sync Policy:** \`$_DIRECTIVE_SYNC_POLICY\`
EOF
  )

  local _pr_url
  if ! _pr_url=$(gh pr create --repo "$repo_slug" \
    --head "$branch" --base "$base" \
    --title "$pr_title" --body "$pr_body" 2>/dev/null); then
    echo "epic-branch: failed to open integration PR for epic $epic_id" >&2
    return 1
  fi

  EPIC_BRANCH_PR_STATE="open"
  echo "epic-branch: opened integration PR from '$branch' to '$base' for epic $epic_id"

  # Commercial Evidence MVP (Branch B): pr-created capture for epic
  # integration PRs, only when the caller has a pipeline log open — epic
  # branch sync can run outside any single ticket's pipeline run.
  if [ -n "${LOG_FILE:-}" ] && [ -n "$_pr_url" ]; then
    local _pr_num _pr_created_json
    _pr_num=$(echo "$_pr_url" | grep -oE '[0-9]+$')
    _pr_created_json=$(jq -nc --argjson pr "${_pr_num:-null}" --arg url "$_pr_url" --arg repo "$repo_slug" \
      '{pr: $pr, url: $url, repo: $repo, epic: true}' 2>/dev/null) || true
    if [ -n "$_pr_created_json" ]; then
      echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|META|pr-created|info|${_pr_created_json}" >>"$LOG_FILE"
    fi
  fi

  return 0
}

# ── Self-test mode ────────────────────────────────────────────────────────────

if [ "${1:-}" = "--self-test" ]; then
  set -- ""
  echo "Running self-tests..."

  # Source deps
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  source "$SCRIPT_DIR/config.sh" 2>/dev/null || true
  # planned-ticket-check.sh for _extract_md_section, _extract_field, _validate_enum, _validate_iso8601
  source "$SCRIPT_DIR/planned-ticket-check.sh" 2>/dev/null || true
  source "$SCRIPT_DIR/branch-directive-check.sh" 2>/dev/null || true

  # ── _parse_directive smoke tests ───────────────────────────────────────────

  valid_desc=$(
    cat <<'EODESC'
## Branch Directive
**Schema-Version:** 1
**Branch:** epic/test-branch
**Base:** develop
**Merge Policy:** on-all-children-done
**Sync Policy:** rebase-on-base-change
**Created:** 2026-07-25T10:00:00Z
EODESC
  )
  _parse_directive "$valid_desc" && echo "PASS: parse valid directive" || echo "FAIL: parse valid directive"
  [ "$_DIRECTIVE_BRANCH" = "epic/test-branch" ] && echo "PASS: branch parsed" || echo "FAIL: branch: got '$_DIRECTIVE_BRANCH'"
  [ "$_DIRECTIVE_BASE" = "develop" ] && echo "PASS: base parsed" || echo "FAIL: base: got '$_DIRECTIVE_BASE'"
  [ "$_DIRECTIVE_MERGE_POLICY" = "on-all-children-done" ] && echo "PASS: merge policy parsed" || echo "FAIL: merge policy: got '$_DIRECTIVE_MERGE_POLICY'"
  [ "$_DIRECTIVE_SYNC_POLICY" = "rebase-on-base-change" ] && echo "PASS: sync policy parsed" || echo "FAIL: sync policy: got '$_DIRECTIVE_SYNC_POLICY'"

  # Absent directive
  _parse_directive "No directive here" && echo "FAIL: absent directive should return non-zero" || echo "PASS: absent directive returns non-zero"

  # Malformed directive — missing required fields
  bad_desc=$(
    cat <<'EODESC'
## Branch Directive
**Schema-Version:** 1
**Branch:** epic/bad
**Base:** develop
EODESC
  )
  _parse_directive "$bad_desc" && echo "FAIL: malformed directive should return non-zero" || echo "PASS: malformed directive returns non-zero"

  # Sync policy "none"
  none_desc=$(
    cat <<'EODESC'
## Branch Directive
**Schema-Version:** 1
**Branch:** epic/syncless
**Base:** main
**Merge Policy:** manual
**Sync Policy:** none
**Created:** 2026-07-25T10:00:00Z
EODESC
  )
  _parse_directive "$none_desc" && echo "PASS: parse sync=none directive" || echo "FAIL: parse sync=none directive"
  [ "$_DIRECTIVE_SYNC_POLICY" = "none" ] && echo "PASS: sync policy none" || echo "FAIL: sync policy: got '$_DIRECTIVE_SYNC_POLICY'"

  # ── _branch_exists tests ──────────────────────────────────────────────────

  test_repo=$(mktemp -d)
  git -C "$test_repo" init -b main 2>/dev/null || git -C "$test_repo" init
  git -C "$test_repo" config user.email "test@test.com"
  git -C "$test_repo" config user.name "Test"
  echo "hello" >"$test_repo/README.md"
  git -C "$test_repo" add -A
  git -C "$test_repo" commit -m "initial" --no-gpg-sign

  # Create a branch
  git -C "$test_repo" checkout -b "feat/exists" 2>/dev/null
  git -C "$test_repo" checkout main 2>/dev/null

  _branch_exists "$test_repo" "feat/exists" && echo "PASS: branch_exists finds local branch" || echo "FAIL: branch_exists missed local branch"
  _branch_exists "$test_repo" "main" && echo "PASS: branch_exists finds main" || echo "FAIL: branch_exists missed main"
  ! _branch_exists "$test_repo" "no/such-branch" && echo "PASS: branch_exists rejects nonexistent" || echo "FAIL: branch_exists should reject nonexistent"

  # ── _base_advanced tests ──────────────────────────────────────────────────

  git -C "$test_repo" checkout main 2>/dev/null
  epic_branch="feat/epic-test"
  git -C "$test_repo" checkout -b "$epic_branch" 2>/dev/null

  # Create an "origin/main" proper remote ref by using git update-ref
  git -C "$test_repo" checkout main 2>/dev/null
  echo "advance" >"$test_repo/advance.txt"
  git -C "$test_repo" add advance.txt
  git -C "$test_repo" commit -m "advance base" --no-gpg-sign
  # Create a proper refs/remotes/origin/main pointing to the advanced main
  git -C "$test_repo" update-ref refs/remotes/origin/main HEAD 2>/dev/null

  _base_advanced "$test_repo" "$epic_branch" "main" && echo "PASS: base_advanced detects advancement" || echo "FAIL: base_advanced should detect advancement"

  # Make them equal: merge the advanced base into epic branch, update origin/main
  git -C "$test_repo" checkout "$epic_branch" 2>/dev/null
  git -C "$test_repo" merge main -m "merge" --no-gpg-sign 2>/dev/null || true
  git -C "$test_repo" update-ref refs/remotes/origin/main HEAD 2>/dev/null

  ! _base_advanced "$test_repo" "$epic_branch" "main" && echo "PASS: base_advanced no-op when equal" || echo "FAIL: base_advanced should report no advancement"

  # Cleanup
  rm -rf "$test_repo"

  # ── _resolve_repo tests ───────────────────────────────────────────────────

  good_repo=$(mktemp -d)
  git -C "$good_repo" init 2>/dev/null
  _resolve_repo "$good_repo" >/dev/null 2>&1 && echo "PASS: resolve_repo accepts git repo" || echo "FAIL: resolve_repo should accept git repo"
  rm -rf "$good_repo"

  bad_repo=$(mktemp -d)
  ! _resolve_repo "$bad_repo" >/dev/null 2>&1 && echo "PASS: resolve_repo rejects non-git dir" || echo "FAIL: resolve_repo should reject non-git dir"
  rm -rf "$bad_repo"

  echo "Self-tests complete."
  exit 0
fi
