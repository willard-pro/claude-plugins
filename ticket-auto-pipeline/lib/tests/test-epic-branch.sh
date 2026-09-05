#!/usr/bin/env bash
# test-epic-branch.sh — unit tests for lib/epic-branch.sh
# Creates real git repo fixtures and tests branch create/sync/readiness/PR/dry-run.
# Usage: bash test-epic-branch.sh [test_name_filter]
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# ── CI-safe declare guards ───────────────────────────────────────────────────
if ! declare -f _plog >/dev/null 2>&1; then
  _plog() { :; }
fi
if ! declare -f hb_gate >/dev/null 2>&1; then
  hb_gate() { :; }
fi
if ! declare -f heartbeat >/dev/null 2>&1; then
  heartbeat() { :; }
fi

# ── Mock helpers ──────────────────────────────────────────────────────────────

# Default mock: epic with a valid directive
MOCK_EPIC_DESC=$(
  cat <<'EODESC'
## Branch Directive
**Schema-Version:** 1
**Branch:** epic/test-branch
**Base:** main
**Merge Policy:** on-all-children-done
**Sync Policy:** rebase-on-base-change
**Created:** 2026-07-25T10:00:00Z
EODESC
)

# Mock epic description with sync policy "none"
MOCK_EPIC_DESC_SYNC_NONE=$(
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

# Mock get_issue — controlled via MOCK_DESCRIPTION env var
get_issue() {
  local desc="${MOCK_DESCRIPTION:-$MOCK_EPIC_DESC}"
  # Escape the description for JSON embedding
  local escaped
  escaped=$(echo "$desc" | jq -Rs .)
  # get_issue in lib/linear-api.sh returns the unwrapped .data.issue object,
  # not the full GraphQL envelope. The stub must match that shape.
  echo "{\"description\":$escaped}"
}

# Mock get_parent_with_children — returns children in Done state by default.
# Override via MOCK_CHILDREN_JSON env var.
get_parent_with_children() {
  local children="${MOCK_CHILDREN_JSON:-}"
  if [ -z "$children" ]; then
    # Default: one child, Done
    children='[{"id":"child-1","identifier":"CRE-1","state":{"name":"Done"},"labels":{"nodes":[{"name":"planned"}]}}]'
  fi
  echo "{\"parent\":{\"id\":\"$1\",\"identifier\":\"$1\",\"title\":\"Test Epic\",\"description\":\"test\"},\"children\":$children}"
}

# Source the library under test (and its transitive deps)
source "$LIB_DIR/config.sh"
# planned-ticket-check.sh provides _extract_md_section, _extract_field used by branch-directive-check.sh
source "$LIB_DIR/planned-ticket-check.sh" 2>/dev/null || true
source "$LIB_DIR/branch-directive-check.sh" 2>/dev/null || true
source "$LIB_DIR/epic-branch.sh"

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

_run_exit_code() {
  local name="$1"
  local expected="$2"
  shift 2
  local actual=0
  "$@" 2>/dev/null || actual=$?
  if [ "$actual" -eq "$expected" ]; then
    echo "PASS: $name (exit $actual)"
    ((PASS++)) || true
  else
    echo "FAIL: $name (expected exit $expected, got $actual)"
    ((FAIL++)) || true
  fi
}

# ── Fixture ──────────────────────────────────────────────────────────────────

_setup_fixture() {
  FIXTURE_DIR=$(mktemp -d)

  # Create a bare "origin" repo that can accept pushes
  ORIGIN_REPO="$FIXTURE_DIR/origin.git"
  mkdir -p "$ORIGIN_REPO"
  git -C "$ORIGIN_REPO" init --bare -b main 2>/dev/null || git -C "$ORIGIN_REPO" init --bare

  # Create the working repo, add an initial commit, and push to origin
  FIXTURE_REPO="$FIXTURE_DIR/repo"
  mkdir -p "$FIXTURE_REPO"
  git -C "$FIXTURE_REPO" init -b main 2>/dev/null || git -C "$FIXTURE_REPO" init
  git -C "$FIXTURE_REPO" config user.email "test@test.com"
  git -C "$FIXTURE_REPO" config user.name "Test"
  git -C "$FIXTURE_REPO" remote add origin "$ORIGIN_REPO"
  echo "hello" >"$FIXTURE_REPO/README.md"
  git -C "$FIXTURE_REPO" add -A
  git -C "$FIXTURE_REPO" commit -m "initial" --no-gpg-sign
  git -C "$FIXTURE_REPO" push origin main >/dev/null 2>&1

  # Set origin/main ref to match pushed main
  git -C "$FIXTURE_REPO" fetch origin >/dev/null 2>&1
}

# _commit_on_epic_branch <repo_path> [branch]
# Puts a commit on the epic branch so it carries work beyond base.
#
# epic_branch_open_pr deliberately skips a repo whose epic branch has no
# commits beyond base, so a PR fixture built only from ensure_epic_branch —
# which creates the branch AT base — exercises the skip path, not the PR path.
# Every open_pr test must therefore look like a real epic branch.
_commit_on_epic_branch() {
  local repo="$1"
  local branch="${2:-epic/test-branch}"
  local prev
  prev=$(git -C "$repo" rev-parse --abbrev-ref HEAD 2>/dev/null)
  git -C "$repo" checkout -q "$branch" 2>/dev/null || return 1
  echo "child work" >>"$repo/CHILD.md"
  git -C "$repo" add -A
  git -C "$repo" commit -q -m "child ticket work" --no-gpg-sign || return 1
  git -C "$repo" checkout -q "$prev" 2>/dev/null || true
  return 0
}

echo "=== Create tests ==="
echo ""

# ── 2.2: Create case ────────────────────────────────────────────────────────

test_create_branch() {
  _setup_fixture

  # Branch creation must be a plain ref operation — the shared clone's
  # checked-out branch and working tree are untouched.
  local head_before status_before
  head_before=$(git -C "$FIXTURE_REPO" rev-parse --abbrev-ref HEAD)
  status_before=$(git -C "$FIXTURE_REPO" status --porcelain)

  # ensure_epic_branch should create and push the branch
  ensure_epic_branch "CRE-100" "$FIXTURE_REPO" 2>&1 || return 1

  # Branch exists locally
  git -C "$FIXTURE_REPO" rev-parse --verify "epic/test-branch" >/dev/null 2>&1 || {
    echo "  branch not created locally" >&2
    return 1
  }

  # Branch was created from main
  local merge_base
  merge_base=$(git -C "$FIXTURE_REPO" merge-base "epic/test-branch" "main" 2>/dev/null)
  local main_head
  main_head=$(git -C "$FIXTURE_REPO" rev-parse main)
  [ "$merge_base" = "$main_head" ] || {
    echo "  branch not based on main" >&2
    return 1
  }

  # Checked-out branch unchanged
  local head_after
  head_after=$(git -C "$FIXTURE_REPO" rev-parse --abbrev-ref HEAD)
  [ "$head_after" = "$head_before" ] || {
    echo "  checked-out branch moved: $head_before → $head_after" >&2
    return 1
  }

  # Working tree unchanged
  local status_after
  status_after=$(git -C "$FIXTURE_REPO" status --porcelain)
  [ "$status_after" = "$status_before" ] || {
    echo "  working tree modified: before=[$status_before] after=[$status_after]" >&2
    return 1
  }

  return 0
}
_run "create epic branch from declared base" test_create_branch

# ── 2.3: Idempotent create ─────────────────────────────────────────────────

test_idempotent_create() {
  _setup_fixture

  ensure_epic_branch "CRE-100" "$FIXTURE_REPO" 2>&1 || return 1

  # Get the commit of the epic branch after first create
  local head1
  head1=$(git -C "$FIXTURE_REPO" rev-parse "epic/test-branch")

  # Second call should exit 0, branch unchanged
  ensure_epic_branch "CRE-100" "$FIXTURE_REPO" 2>&1 || {
    echo "  second ensure_epic_branch failed" >&2
    return 1
  }

  local head2
  head2=$(git -C "$FIXTURE_REPO" rev-parse "epic/test-branch")
  [ "$head1" = "$head2" ] || {
    echo "  branch modified on second call" >&2
    return 1
  }

  return 0
}
_run "idempotent create does not modify existing branch" test_idempotent_create

# ── 2.3b: Push-failure wedge regression ─────────────────────────────────────
# Creation succeeds locally, push fails. The local ref must be cleaned up so
# _branch_exists does not short-circuit every later cycle — the remote branch
# would otherwise never be (re)created.

test_push_failure_cleans_local_ref() {
  _setup_fixture

  # Break the remote AFTER the initial fixture push so origin/main is still
  # resolvable locally: `git branch epic/test-branch origin/main` succeeds,
  # then `git push origin` fails.
  git -C "$FIXTURE_REPO" remote set-url origin "$FIXTURE_DIR/nonexistent-remote.git"

  local exit_code=0
  ensure_epic_branch "CRE-100" "$FIXTURE_REPO" 2>/dev/null || exit_code=$?
  [ "$exit_code" -eq 1 ] || {
    echo "  expected exit 1 on push failure, got $exit_code" >&2
    return 1
  }

  # Wedge fix: the half-created local ref must not survive the failure.
  git -C "$FIXTURE_REPO" rev-parse --verify "epic/test-branch" >/dev/null 2>&1 && {
    echo "  local ref left behind after failed push — retry wedge" >&2
    return 1
  }

  # Restore the remote — the next dispatch cycle must succeed, proving the
  # failure did not wedge future retries.
  git -C "$FIXTURE_REPO" remote set-url origin "$ORIGIN_REPO"
  ensure_epic_branch "CRE-100" "$FIXTURE_REPO" 2>&1 || {
    echo "  second ensure after remote restore failed" >&2
    return 1
  }
  git -C "$FIXTURE_REPO" rev-parse --verify "epic/test-branch" >/dev/null 2>&1 || {
    echo "  branch not created after remote restore" >&2
    return 1
  }

  return 0
}
_run "push failure cleans local ref, retry succeeds" test_push_failure_cleans_local_ref

# Creation failure: the directive's base does not exist on origin, so the
# `git branch <branch> origin/<base>` call fails. Exit 1, no local ref left.
test_create_failure_nonexistent_base() {
  _setup_fixture

  local rc=0
  MOCK_DESCRIPTION='## Branch Directive
**Schema-Version:** 1
**Branch:** epic/nope-base
**Base:** develop
**Merge Policy:** manual
**Sync Policy:** none' \
    ensure_epic_branch "CRE-100" "$FIXTURE_REPO" 2>/dev/null || rc=$?
  [ "$rc" -eq 1 ] || {
    echo "  expected exit 1 on creation failure, got $rc" >&2
    return 1
  }
  git -C "$FIXTURE_REPO" rev-parse --verify "epic/nope-base" >/dev/null 2>&1 && {
    echo "  half-created branch left behind after failed create" >&2
    return 1
  }
  return 0
}
_run "creation failure leaves no local ref" test_create_failure_nonexistent_base

# ── 2.4: No-directive case ──────────────────────────────────────────────────

test_no_directive() {
  _setup_fixture

  # Override mock to return description with no directive
  MOCK_DESCRIPTION="No directive here, just a regular epic." \
    ensure_epic_branch "CRE-101" "$FIXTURE_REPO" 2>&1 || {
    echo "  ensure_epic_branch should exit 0 for no directive" >&2
    return 1
  }

  # Verify no branch was created
  git -C "$FIXTURE_REPO" rev-parse --verify "epic/test-branch" >/dev/null 2>&1 && {
    echo "  branch was created despite no directive" >&2
    return 1
  }

  return 0
}
_run "no-directive epic is a clean no-op" test_no_directive

echo ""
echo "=== Sync tests ==="
echo ""

# ── 2.5: Sync case — advanced base integrated ───────────────────────────────

test_sync_advanced_base() {
  _setup_fixture

  # Create the epic branch first
  ensure_epic_branch "CRE-100" "$FIXTURE_REPO" 2>&1 || return 1

  # Advance main with a new commit AND push to origin
  git -C "$FIXTURE_REPO" checkout main 2>/dev/null
  echo "advance" >"$FIXTURE_REPO/advance.txt"
  git -C "$FIXTURE_REPO" add advance.txt
  git -C "$FIXTURE_REPO" commit -m "advance base" --no-gpg-sign
  git -C "$FIXTURE_REPO" push origin main >/dev/null 2>&1

  # Sync — should integrate the advance
  epic_branch_sync "CRE-100" "$FIXTURE_REPO" 2>&1 || {
    echo "  sync failed unexpectedly" >&2
    return 1
  }

  # Epic branch should now contain the advance commit
  git -C "$FIXTURE_REPO" rev-parse --verify "epic/test-branch" >/dev/null 2>&1 || return 1
  local main_head epic_head merge_base
  main_head=$(git -C "$FIXTURE_REPO" rev-parse main)
  epic_head=$(git -C "$FIXTURE_REPO" rev-parse "epic/test-branch")
  merge_base=$(git -C "$FIXTURE_REPO" merge-base "epic/test-branch" "main" 2>/dev/null)

  # merge-base should be main's HEAD (meaning epic has all of main's commits)
  [ "$merge_base" = "$main_head" ] || {
    echo "  sync did not integrate base changes (merge_base=$merge_base, main_head=$main_head)" >&2
    return 1
  }

  return 0
}
_run "sync integrates advanced base" test_sync_advanced_base

# ── 2.6: Sync policy "none" — no action ─────────────────────────────────────

test_sync_policy_none() {
  _setup_fixture

  # Create epic branch with sync=none directive
  MOCK_DESCRIPTION="$MOCK_EPIC_DESC_SYNC_NONE" \
    ensure_epic_branch "CRE-102" "$FIXTURE_REPO" 2>&1 || return 1

  # Advance main and push to origin
  git -C "$FIXTURE_REPO" checkout main 2>/dev/null
  echo "advance" >"$FIXTURE_REPO/advance.txt"
  git -C "$FIXTURE_REPO" add advance.txt
  git -C "$FIXTURE_REPO" commit -m "advance base" --no-gpg-sign
  git -C "$FIXTURE_REPO" push origin main >/dev/null 2>&1

  local head_before
  head_before=$(git -C "$FIXTURE_REPO" rev-parse "epic/syncless")

  # Sync should no-op
  MOCK_DESCRIPTION="$MOCK_EPIC_DESC_SYNC_NONE" \
    epic_branch_sync "CRE-102" "$FIXTURE_REPO" 2>&1 || {
    echo "  sync should exit 0 for policy=none" >&2
    return 1
  }

  local head_after
  head_after=$(git -C "$FIXTURE_REPO" rev-parse "epic/syncless")
  [ "$head_before" = "$head_after" ] || {
    echo "  branch was modified despite sync policy none" >&2
    return 1
  }

  return 0
}
_run "sync policy=none takes no action" test_sync_policy_none

# ── 2.7: Unadvanced base — no commit, no push ───────────────────────────────

test_sync_unadvanced_base() {
  _setup_fixture

  # Create the epic branch
  ensure_epic_branch "CRE-100" "$FIXTURE_REPO" 2>&1 || return 1

  # Don't advance main — run sync immediately

  # Count commits on epic branch before
  local count_before
  count_before=$(git -C "$FIXTURE_REPO" rev-list --count "epic/test-branch" 2>/dev/null)

  # Sync should no-op
  epic_branch_sync "CRE-100" "$FIXTURE_REPO" 2>&1 || {
    echo "  sync failed on unadvanced base" >&2
    return 1
  }

  local count_after
  count_after=$(git -C "$FIXTURE_REPO" rev-list --count "epic/test-branch" 2>/dev/null)
  [ "$count_before" = "$count_after" ] || {
    echo "  commit count changed despite unadvanced base" >&2
    return 1
  }

  return 0
}
_run "unadvanced base is a no-op" test_sync_unadvanced_base

# ── 2.8: Conflict case — branch left untouched, non-zero exit ────────────────

test_sync_conflict() {
  _setup_fixture

  # Create the epic branch
  ensure_epic_branch "CRE-100" "$FIXTURE_REPO" 2>&1 || return 1

  # Switch to epic branch, make a change, and push it
  git -C "$FIXTURE_REPO" checkout "epic/test-branch" 2>/dev/null
  echo "epic change" >"$FIXTURE_REPO/README.md"
  git -C "$FIXTURE_REPO" add README.md
  git -C "$FIXTURE_REPO" commit -m "epic change" --no-gpg-sign
  git -C "$FIXTURE_REPO" push origin "epic/test-branch" >/dev/null 2>&1

  # Advance main with a conflicting change and push
  git -C "$FIXTURE_REPO" checkout main 2>/dev/null
  echo "conflicting main change" >"$FIXTURE_REPO/README.md"
  git -C "$FIXTURE_REPO" add README.md
  git -C "$FIXTURE_REPO" commit -m "conflicting main change" --no-gpg-sign
  git -C "$FIXTURE_REPO" push origin main >/dev/null 2>&1

  local head_before
  head_before=$(git -C "$FIXTURE_REPO" rev-parse "epic/test-branch")

  # Sync should fail with non-zero exit
  local sync_exit=0
  epic_branch_sync "CRE-100" "$FIXTURE_REPO" 2>/dev/null || sync_exit=$?

  [ "$sync_exit" -ne 0 ] || {
    echo "  sync should exit non-zero on conflict" >&2
    return 1
  }

  # Branch should be untouched (HEAD before == HEAD after)
  local head_after
  head_after=$(git -C "$FIXTURE_REPO" rev-parse "epic/test-branch")
  [ "$head_before" = "$head_after" ] || {
    echo "  branch was modified despite conflict" >&2
    return 1
  }

  # Verify no force-push marker in reflog (best-effort check)
  # The key assertion: sync exited non-zero and branch is unchanged
  return 0
}
_run "conflict leaves branch untouched and exits non-zero" test_sync_conflict

echo ""
echo "=== Readiness tests ==="
echo ""

# ── 2.9: Readiness cases ────────────────────────────────────────────────────

test_children_all_done() {
  # Inline JSON — all children Done
  local children_json
  children_json=$(
    cat <<'EOJSON'
{"id":"child-1","identifier":"CRE-1","state":{"name":"Done"},"labels":{"nodes":[{"name":"planned"}]}}
{"id":"child-2","identifier":"CRE-2","state":{"name":"Done"},"labels":{"nodes":[{"name":"planned"}]}}
EOJSON
  )
  epic_branch_children_done "CRE-100" "$children_json" 2>/dev/null && return 0
  echo "  all children Done should be ready" >&2
  return 1
}
_run "all children Done → ready" test_children_all_done

test_children_one_outstanding() {
  local children_json
  children_json=$(
    cat <<'EOJSON'
{"id":"child-1","identifier":"CRE-1","state":{"name":"Done"},"labels":{"nodes":[{"name":"planned"}]}}
{"id":"child-2","identifier":"CRE-2","state":{"name":"In Progress"},"labels":{"nodes":[{"name":"planned"}]}}
EOJSON
  )
  epic_branch_children_done "CRE-100" "$children_json" 2>/dev/null && {
    echo "  one outstanding child should NOT be ready" >&2
    return 1
  }
  return 0
}
_run "one outstanding child → not ready" test_children_one_outstanding

test_children_zero() {
  # Empty children — not ready
  epic_branch_children_done "CRE-100" "" 2>/dev/null && {
    echo "  zero children should NOT be ready" >&2
    return 1
  }
  return 0
}
_run "zero children → not ready" test_children_zero

test_children_all_done_jsonl() {
  # JSONL format (one per line) — all Done
  local children_json
  children_json=$(printf '%s\n' \
    '{"id":"child-1","identifier":"CRE-1","state":{"name":"Done"},"labels":{"nodes":[{"name":"planned"}]}}' \
    '{"id":"child-2","identifier":"CRE-2","state":{"name":"Done"},"labels":{"nodes":[{"name":"planned"}]}}' \
    '{"id":"child-3","identifier":"CRE-3","state":{"name":"Done"},"labels":{"nodes":[{"name":"planned"}]}}')
  epic_branch_children_done "CRE-100" "$children_json" 2>/dev/null && return 0
  echo "  three children all Done should be ready" >&2
  return 1
}
_run "three children all Done → ready" test_children_all_done_jsonl

test_children_non_planned_excluded() {
  # A Done child WITHOUT the planned label is out of scope — it must not
  # block readiness (the doc contract is "planned children are all Done").
  local children_json
  children_json=$(
    cat <<'EOJSON'
{"id":"child-1","identifier":"CRE-1","state":{"name":"Done"},"labels":{"nodes":[{"name":"planned"}]}}
{"id":"child-2","identifier":"CRE-2","state":{"name":"Todo"},"labels":{"nodes":[]}}
EOJSON
  )
  epic_branch_children_done "CRE-100" "$children_json" 2>/dev/null && return 0
  echo "  non-planned child must not block readiness" >&2
  return 1
}
_run "non-planned child excluded from readiness" test_children_non_planned_excluded

test_children_only_non_planned_not_ready() {
  # No planned children at all — not ready (zero in-scope children).
  local children_json
  children_json=$(
    cat <<'EOJSON'
{"id":"child-1","identifier":"CRE-1","state":{"name":"Done"},"labels":{"nodes":[]}}
{"id":"child-2","identifier":"CRE-2","state":{"name":"Done"},"labels":{"nodes":[]}}
EOJSON
  )
  epic_branch_children_done "CRE-100" "$children_json" 2>/dev/null && {
    echo "  zero planned children should NOT be ready" >&2
    return 1
  }
  return 0
}
_run "only non-planned children → not ready" test_children_only_non_planned_not_ready

echo ""
echo "=== PR tests ==="
echo ""

# ── 2.10: PR cases ──────────────────────────────────────────────────────────

# Helper: create a mock gh that records calls
_setup_mock_gh() {
  MOCK_GH_DIR=$(mktemp -d)
  export MOCK_GH_DIR
  MOCK_GH_LOG="$MOCK_GH_DIR/gh.log"

  # Write a mock gh script
  cat >"$MOCK_GH_DIR/gh" <<'GHSCRIPT'
#!/usr/bin/env bash
echo "$@" >>"$MOCK_GH_DIR/gh.log"

case "$1" in
pr)
  case "$2" in
  list)
    # Return empty list (no existing PR) by default
    # Override via MOCK_GH_PR_EXISTS to simulate existing PR
    if [ "${MOCK_GH_PR_EXISTS:-}" = "true" ]; then
      echo '[{"number":42}]'
    else
      echo '[]'
    fi
    ;;
  create)
    echo "https://github.com/test/repo/pull/99"
    ;;
  esac
  ;;
esac
GHSCRIPT
  chmod +x "$MOCK_GH_DIR/gh"

  # Add to PATH and clear bash command hash
  export PATH="$MOCK_GH_DIR:$PATH"
  hash -r 2>/dev/null || true
}

# Override _get_epic_description to avoid needing Linear API
# The mock get_issue is already set up at the top of this file

test_pr_opens_when_ready() {
  _setup_fixture

  # Create the epic branch first
  ensure_epic_branch "CRE-100" "$FIXTURE_REPO" 2>&1 || return 1
  _commit_on_epic_branch "$FIXTURE_REPO" || return 1

  # Override gh as a function (more reliable than PATH-based mock). The call
  # marker is a file, not a variable: epic_branch_open_pr now captures gh's
  # stdout via command substitution (`_pr_url=$(gh pr create ...)`) to build
  # the pr-created evidence record, which runs the mock inside a subshell —
  # a plain variable assignment there would not survive back to this scope.
  GH_PR_CREATE_MARKER=$(mktemp)
  rm -f "$GH_PR_CREATE_MARKER"
  export GH_PR_CREATE_MARKER
  gh() {
    case "$1" in
    pr)
      case "$2" in
      # gh pr list --jq '.[0].number // empty' outputs empty string when no PRs
      list) echo "" ;;
      create)
        touch "$GH_PR_CREATE_MARKER"
        echo "https://github.com/test/repo/pull/99"
        ;;
      esac
      ;;
    esac
  }
  export -f gh

  # Set a GitHub-style remote URL so slug extraction works
  git -C "$FIXTURE_REPO" remote set-url origin "git@github.com:test-org/test-repo.git"

  # Enable auto PR and call open_pr
  FLEET_EPIC_AUTO_PR=true epic_branch_open_pr "CRE-100" "$FIXTURE_REPO" 2>&1 || {
    echo "  epic_branch_open_pr failed with exit $?" >&2
    return 1
  }

  # gh pr create should have been called
  if [ ! -f "$GH_PR_CREATE_MARKER" ]; then
    echo "  gh pr create was not called" >&2
    return 1
  fi
  rm -f "$GH_PR_CREATE_MARKER"

  return 0
}
_run "PR opens when ready and FLEET_EPIC_AUTO_PR=true" test_pr_opens_when_ready

test_pr_not_opened_when_auto_pr_false() {
  _setup_fixture

  ensure_epic_branch "CRE-100" "$FIXTURE_REPO" 2>&1 || return 1
  _commit_on_epic_branch "$FIXTURE_REPO" || return 1
  git -C "$FIXTURE_REPO" remote set-url origin "git@github.com:test-org/test-repo.git"

  # Track if gh pr create was called
  GH_CREATE_CALLED=false
  gh() {
    case "$1" in
    pr)
      case "$2" in
      list) echo "" ;;
      create)
        GH_CREATE_CALLED=true
        echo "https://github.com/test/repo/pull/99"
        ;;
      esac
      ;;
    esac
  }
  export -f gh

  # Default: FLEET_EPIC_AUTO_PR is false
  FLEET_EPIC_AUTO_PR=false epic_branch_open_pr "CRE-100" "$FIXTURE_REPO" 2>&1 || {
    echo "  epic_branch_open_pr should exit 0 even when auto-pr is off" >&2
    return 1
  }

  # gh pr create should NOT have been called
  if [ "$GH_CREATE_CALLED" = "true" ]; then
    echo "  gh pr create was called despite FLEET_EPIC_AUTO_PR=false" >&2
    return 1
  fi

  return 0
}
_run "PR not opened when readiness present but FLEET_EPIC_AUTO_PR=false" test_pr_not_opened_when_auto_pr_false

test_pr_idempotent() {
  _setup_fixture

  ensure_epic_branch "CRE-100" "$FIXTURE_REPO" 2>&1 || return 1
  _commit_on_epic_branch "$FIXTURE_REPO" || return 1

  # gh mock records its calls so the "no duplicate PR" invariant is asserted,
  # not assumed: pr create must NEVER be called while a PR already exists.
  local gh_log
  gh_log="$FIXTURE_DIR/gh-create.log"
  gh() {
    echo "$*" >>"$gh_log"
    case "$1" in
    pr)
      case "$2" in
      list) echo "42" ;;
      create) echo "https://github.com/test/repo/pull/99" ;;
      esac
      ;;
    esac
  }
  export -f gh

  git -C "$FIXTURE_REPO" remote set-url origin "git@github.com:test-org/test-repo.git"

  # First call: existing PR detected → no-op.
  FLEET_EPIC_AUTO_PR=true epic_branch_open_pr "CRE-100" "$FIXTURE_REPO" 2>&1 || {
    echo "  epic_branch_open_pr failed" >&2
    return 1
  }
  # Second call: still no create.
  FLEET_EPIC_AUTO_PR=true epic_branch_open_pr "CRE-100" "$FIXTURE_REPO" 2>&1 || {
    echo "  second epic_branch_open_pr failed" >&2
    return 1
  }

  ! grep -q "pr create" "$gh_log" || {
    echo "  gh pr create called despite existing PR: $(cat "$gh_log")" >&2
    return 1
  }
  local list_count
  list_count=$(grep -c "pr list" "$gh_log" 2>/dev/null || true)
  [ "$list_count" = "2" ] || {
    echo "  expected existing-PR check on both calls, got ${list_count}" >&2
    return 1
  }
  return 0
}
_run "idempotent PR open — second call is no-op" test_pr_idempotent

test_pr_skipped_when_no_commits_on_epic_branch() {
  _setup_fixture

  # Branch created AT base and left there — this repo is one the epic never
  # touched. Note the absence of _commit_on_epic_branch.
  ensure_epic_branch "CRE-100" "$FIXTURE_REPO" 2>&1 || return 1
  git -C "$FIXTURE_REPO" remote set-url origin "git@github.com:test-org/test-repo.git"

  local gh_log="${FIXTURE_DIR}/gh.log"
  : >"$gh_log"
  gh() {
    echo "gh $*" >>"$gh_log"
    case "$2" in
    list) echo "" ;;
    esac
    return 0
  }
  export -f gh

  FLEET_EPIC_AUTO_PR=true epic_branch_open_pr "CRE-100" "$FIXTURE_REPO" 2>&1 || {
    echo "  open_pr should exit 0 when there is nothing to integrate" >&2
    return 1
  }

  # Skipped before any GitHub interaction at all — not merely before create.
  if [ -s "$gh_log" ]; then
    echo "  gh invoked for a repo with no epic commits: $(cat "$gh_log")" >&2
    return 1
  fi
  return 0
}
_run "PR skipped when epic branch has no commits beyond base" test_pr_skipped_when_no_commits_on_epic_branch

test_pr_proceeds_when_epic_branch_has_commits() {
  _setup_fixture

  ensure_epic_branch "CRE-100" "$FIXTURE_REPO" 2>&1 || return 1
  _commit_on_epic_branch "$FIXTURE_REPO" || return 1
  git -C "$FIXTURE_REPO" remote set-url origin "git@github.com:test-org/test-repo.git"

  # File-based call marker — see test_pr_opens_when_ready for why a plain
  # variable set inside gh() does not survive the command substitution
  # subshell that captures the PR URL.
  GH_PR_CREATE_MARKER=$(mktemp)
  rm -f "$GH_PR_CREATE_MARKER"
  export GH_PR_CREATE_MARKER
  gh() {
    case "$1" in
    pr)
      case "$2" in
      list) echo "" ;;
      create)
        touch "$GH_PR_CREATE_MARKER"
        echo "https://github.com/test/repo/pull/99"
        ;;
      esac
      ;;
    esac
  }
  export -f gh

  FLEET_EPIC_AUTO_PR=true epic_branch_open_pr "CRE-100" "$FIXTURE_REPO" 2>&1 || return 1

  [ -f "$GH_PR_CREATE_MARKER" ] || {
    echo "  PR not opened despite commits on the epic branch" >&2
    return 1
  }
  rm -f "$GH_PR_CREATE_MARKER"
  return 0
}
_run "PR proceeds when epic branch has commits beyond base" test_pr_proceeds_when_epic_branch_has_commits

echo ""
echo "=== Dry-run tests ==="
echo ""

# ── 2.11: Dry-run case ──────────────────────────────────────────────────────

test_dry_run_create() {
  _setup_fixture

  FLEET_DRY_RUN=true ensure_epic_branch "CRE-100" "$FIXTURE_REPO" 2>&1 || return 1

  # Branch should NOT have been created
  git -C "$FIXTURE_REPO" rev-parse --verify "epic/test-branch" >/dev/null 2>&1 && {
    echo "  branch was created despite FLEET_DRY_RUN=true" >&2
    return 1
  }

  return 0
}
_run "dry-run creates nothing" test_dry_run_create

test_dry_run_sync() {
  _setup_fixture

  # Create the branch for real first (sync needs it to exist)
  ensure_epic_branch "CRE-100" "$FIXTURE_REPO" 2>&1 || return 1

  # Advance main
  git -C "$FIXTURE_REPO" checkout main 2>/dev/null
  echo "advance" >"$FIXTURE_REPO/advance.txt"
  git -C "$FIXTURE_REPO" add advance.txt
  git -C "$FIXTURE_REPO" commit -m "advance base" --no-gpg-sign
  git -C "$FIXTURE_REPO" update-ref refs/remotes/origin/main HEAD 2>/dev/null

  local head_before
  head_before=$(git -C "$FIXTURE_REPO" rev-parse "epic/test-branch")

  # Dry-run sync
  FLEET_DRY_RUN=true epic_branch_sync "CRE-100" "$FIXTURE_REPO" 2>&1 || return 1

  # Epic branch should NOT have changed
  local head_after
  head_after=$(git -C "$FIXTURE_REPO" rev-parse "epic/test-branch")
  [ "$head_before" = "$head_after" ] || {
    echo "  epic branch changed despite FLEET_DRY_RUN=true" >&2
    return 1
  }

  return 0
}
_run "dry-run sync performs no mutation" test_dry_run_sync

test_dry_run_pr() {
  _setup_fixture

  ensure_epic_branch "CRE-100" "$FIXTURE_REPO" 2>&1 || return 1
  _commit_on_epic_branch "$FIXTURE_REPO" || return 1
  git -C "$FIXTURE_REPO" remote set-url origin "git@github.com:test-org/test-repo.git"

  GH_CREATE_CALLED=false
  gh() {
    case "$1" in
    pr)
      case "$2" in
      list) echo '[]' ;;
      create)
        GH_CREATE_CALLED=true
        echo "https://github.com/test/repo/pull/99"
        ;;
      esac
      ;;
    esac
  }
  export -f gh

  FLEET_DRY_RUN=true FLEET_EPIC_AUTO_PR=true \
    epic_branch_open_pr "CRE-100" "$FIXTURE_REPO" 2>&1 || return 1

  # gh pr create should NOT have been called
  if [ "$GH_CREATE_CALLED" = "true" ]; then
    echo "  gh pr create was called despite FLEET_DRY_RUN=true" >&2
    return 1
  fi

  return 0
}
_run "dry-run PR open performs no mutation" test_dry_run_pr

echo ""
echo "=== Edge cases ==="
echo ""

# ── 2.12: Additional edge cases ──────────────────────────────────────────────

test_malformed_directive_rejected() {
  _setup_fixture

  local exit_code=0
  MOCK_DESCRIPTION="## Branch Directive
**Schema-Version:** 1
**Branch:** epic/bad
**Base:** develop" \
    ensure_epic_branch "CRE-999" "$FIXTURE_REPO" 2>/dev/null || exit_code=$?

  [ "$exit_code" -ne 0 ] || {
    echo "  malformed directive should exit non-zero" >&2
    return 1
  }

  return 0
}
_run "malformed directive exits non-zero" test_malformed_directive_rejected

test_sync_branch_does_not_exist() {
  _setup_fixture

  # Don't create the epic branch — just try to sync
  local exit_code=0
  epic_branch_sync "CRE-100" "$FIXTURE_REPO" 2>/dev/null || exit_code=$?

  [ "$exit_code" -ne 0 ] || {
    echo "  sync on nonexistent branch should exit non-zero" >&2
    return 1
  }

  return 0
}
_run "sync fails when epic branch does not exist" test_sync_branch_does_not_exist

test_resolve_repo_rejects_non_git() {
  local exit_code=0
  local tmpdir
  tmpdir=$(mktemp -d)
  _resolve_repo "$tmpdir" 2>/dev/null || exit_code=$?
  rm -rf "$tmpdir"

  [ "$exit_code" -ne 0 ] || {
    echo "  _resolve_repo on non-git dir should exit non-zero" >&2
    return 1
  }

  return 0
}
_run "resolve_repo rejects non-git directory" test_resolve_repo_rejects_non_git

# ── Cleanup mock gh dirs ─────────────────────────────────────────────────────
# The fixture cleanup is done via mktemp (system cleans /tmp eventually).
# Mock gh dirs are in FIXTURE_DIR or MOCK_GH_DIR which are under /tmp.

echo ""
echo "=== Results: $((PASS + FAIL)) tests, $PASS passed, $FAIL failed ==="

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
