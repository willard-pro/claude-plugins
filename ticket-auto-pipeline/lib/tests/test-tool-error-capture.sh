#!/usr/bin/env bash
# test-tool-error-capture.sh — unit tests for hooks/tool-error-capture.sh.
#
# The hook was Bash-only until Group 9 of fleetd-phase-supervisor widened it.
# The pipeline's two most failure-prone surfaces are not Bash: verify drives
# Playwright over MCP, and every phase reaches Linear the same way. These tests
# pin the two properties that widening depends on — that non-Bash failures are
# captured at all, and that they classify distinctly from Bash ones.
#
# Usage: bash test-tool-error-capture.sh [test_name_filter]
set -eo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$(cd "$TEST_DIR/../.." && pwd)/hooks/tool-error-capture.sh"

PASS=0
FAIL=0

_run() {
  local name="$1"
  shift
  set +e
  "$@"
  local rc=$?
  set -e
  if [ $rc -eq 0 ]; then
    echo "PASS: $name"
    ((PASS++)) || true
  else
    echo "FAIL: $name  (exit $rc)"
    ((FAIL++)) || true
  fi
}

# ── fixtures ─────────────────────────────────────────────────────────────────
# Each test gets a unique ticket id so the hook's /tmp dedup files (keyed on
# ticket+tool+type) never leak between tests, and a unique session id so a real
# pipeline spawn on the developer's machine can never be matched instead.
_ws=""
_tid=""
_sid=""
_meta=""
_n=0

_setup() {
  _n=$((_n + 1))
  _ws=$(mktemp -d "${TMPDIR:-/tmp}/test-tool-err.XXXXXX")
  _tid="TESTTE${_n}"
  _sid="sess-test-tool-err-$$-${_n}"
  _meta="/tmp/ticket-auto-${_tid}-spawn-meta.txt"
  cat >"$_meta" <<EOF
PHASE=VERIFY
LOG_FILE=${_ws}/${_tid}-pipeline.log
SESSION_ID=${_sid}
EOF
  : >"${_ws}/${_tid}-pipeline.log"
}

_cleanup() {
  rm -f /tmp/ticket-auto-TESTTE*-spawn-meta.txt 2>/dev/null || true
  rm -f /tmp/tool-err-TESTTE* 2>/dev/null || true
  rm -rf "${TMPDIR:-/tmp}"/test-tool-err.* 2>/dev/null || true
}
trap _cleanup EXIT

# Fire the hook with a payload and echo the resulting error-log line.
_fire() {
  local tool="$1" err="$2" sid="${3:-$_sid}"
  jq -nc --arg t "$tool" --arg e "$err" --arg s "$sid" \
    '{tool_name:$t, error:$e, session_id:$s}' | bash "$HOOK" || true
  cat "${_ws}/${_tid}-tool-errors.log" 2>/dev/null | tail -1
}

_type_of() { echo "$1" | awk -F'|' '{print $3}'; }

# ── tests ────────────────────────────────────────────────────────────────────

test_bash_errors_keep_their_original_classification() {
  _setup
  local line
  line=$(_fire "Bash" "bash: line 1: frobnicate: command not found")
  [ "$(_type_of "$line")" = "command_not_found" ] || {
    echo "  got: $line"
    return 1
  }
}

test_bash_timeout_is_plain_timeout() {
  _setup
  local line
  line=$(_fire "Bash" "Command timed out after 120s")
  [ "$(_type_of "$line")" = "timeout" ] || {
    echo "  got: $line"
    return 1
  }
}

test_playwright_timeout_is_distinct_from_bash_timeout() {
  # The core of task 9.3: same word, different operational problem. A browser
  # that timed out navigating gets retried; a shell command that timed out is
  # genuinely hung. Collapsing them loses the distinction.
  _setup
  local line
  line=$(_fire "mcp__plugin_playwright_playwright__browser_click" \
    "locator.click: Timeout 30000ms exceeded.")
  [ "$(_type_of "$line")" = "playwright_timeout" ] || {
    echo "  got: $line"
    return 1
  }
}

test_playwright_selector_failure_is_classified() {
  _setup
  local line
  line=$(_fire "mcp__plugin_playwright_playwright__browser_click" \
    "Error: strict mode violation: locator resolved to 0 elements")
  [ "$(_type_of "$line")" = "playwright_selector" ] || {
    echo "  got: $line"
    return 1
  }
}

test_playwright_navigation_failure_is_classified() {
  _setup
  local line
  line=$(_fire "mcp__plugin_playwright_playwright__browser_navigate" \
    "page.goto: net::ERR_CONNECTION_REFUSED at https://uat.example.test/")
  [ "$(_type_of "$line")" = "playwright_navigation" ] || {
    echo "  got: $line"
    return 1
  }
}

test_playwright_target_closed_is_classified() {
  _setup
  local line
  line=$(_fire "mcp__plugin_playwright_playwright__browser_snapshot" \
    "Target page, context or browser has been closed")
  [ "$(_type_of "$line")" = "playwright_target_closed" ] || {
    echo "  got: $line"
    return 1
  }
}

test_unrecognised_playwright_error_still_classifies_as_playwright() {
  # Never falls through to the Bash vocabulary: a bucket that says "something
  # in the browser" is more useful than one that says "unknown".
  _setup
  local line
  line=$(_fire "mcp__plugin_playwright_playwright__browser_evaluate" \
    "Something entirely unanticipated happened")
  [ "$(_type_of "$line")" = "playwright_error" ] || {
    echo "  got: $line"
    return 1
  }
}

test_mcp_connection_closed_is_classified() {
  _setup
  local line
  line=$(_fire "mcp__linear-server__get_issue" "MCP error: Connection closed")
  [ "$(_type_of "$line")" = "mcp_connection_closed" ] || {
    echo "  got: $line"
    return 1
  }
}

test_mcp_unauthorized_is_classified() {
  _setup
  local line
  line=$(_fire "mcp__linear-server__save_issue" \
    "HTTP 401 unauthorized: AuthenticateToken authentication failed")
  [ "$(_type_of "$line")" = "mcp_unauthorized" ] || {
    echo "  got: $line"
    return 1
  }
}

test_mcp_rate_limit_is_classified() {
  _setup
  local line
  line=$(_fire "mcp__linear-server__list_issues" "429 Too Many Requests")
  [ "$(_type_of "$line")" = "mcp_rate_limited" ] || {
    echo "  got: $line"
    return 1
  }
}

test_mcp_permission_error_does_not_borrow_the_bash_token() {
  # "forbidden" maps to permission_denied for Bash. For MCP it means the token
  # is wrong, which is a different fix — so it must not reuse that token.
  _setup
  local line
  line=$(_fire "mcp__linear-server__save_issue" "403 forbidden")
  [ "$(_type_of "$line")" = "mcp_unauthorized" ] || {
    echo "  got: $line"
    return 1
  }
}

test_non_bash_non_mcp_tool_is_captured() {
  # The widened matcher's whole purpose: a failing Read or Edit used to write
  # nothing at all.
  _setup
  local line
  line=$(_fire "Read" "File does not exist: /nope/missing.txt")
  [ -n "$line" ] || {
    echo "  nothing was logged"
    return 1
  }
  # Capture is the property under test, not the token. Task 9.3 extended the
  # vocabulary for Playwright and MCP shapes only; a Read failure lands in the
  # Bash vocabulary and may legitimately come out as "unknown". What must not
  # happen is the line going unwritten.
  [ "$(echo "$line" | awk -F'|' '{print $2}')" = "Read" ] || {
    echo "  wrong tool recorded: $line"
    return 1
  }
}

test_unrelated_session_writes_nothing() {
  # Identity is keyed on session, not on the newest /tmp file. With the matcher
  # widened past Bash, a newest-file scan would attribute an unrelated session's
  # failure to whichever ticket happened to spawn last.
  _setup
  jq -nc '{tool_name:"Bash", error:"boom", session_id:"sess-someone-else"}' | bash "$HOOK" || true
  [ ! -f "${_ws}/${_tid}-tool-errors.log" ] || {
    echo "  wrote: $(cat "${_ws}/${_tid}-tool-errors.log")"
    return 1
  }
}

test_missing_session_id_writes_nothing() {
  _setup
  jq -nc '{tool_name:"Bash", error:"boom"}' | bash "$HOOK" || true
  [ ! -f "${_ws}/${_tid}-tool-errors.log" ] || {
    echo "  wrote: $(cat "${_ws}/${_tid}-tool-errors.log")"
    return 1
  }
}

test_empty_error_writes_nothing() {
  _setup
  jq -nc --arg s "$_sid" '{tool_name:"Bash", error:"", session_id:$s}' | bash "$HOOK" || true
  [ ! -f "${_ws}/${_tid}-tool-errors.log" ] || {
    echo "  wrote: $(cat "${_ws}/${_tid}-tool-errors.log")"
    return 1
  }
}

test_multiline_error_stays_one_log_line() {
  _setup
  _fire "Bash" "first line
second line
third line" >/dev/null
  local n
  n=$(wc -l <"${_ws}/${_tid}-tool-errors.log")
  [ "$n" -eq 1 ] || {
    echo "  expected 1 line, got $n: $(cat "${_ws}/${_tid}-tool-errors.log")"
    return 1
  }
}

test_pipes_in_the_error_do_not_corrupt_fields() {
  _setup
  local line
  line=$(_fire "Bash" "grep foo | wc -l failed with exit status 2")
  # ISO|TOOL|TYPE|PHASE|MSG — exactly 5 fields, whatever the message contained.
  local n
  n=$(echo "$line" | awk -F'|' '{print NF}')
  [ "$n" -eq 5 ] || {
    echo "  expected 5 fields, got $n: $line"
    return 1
  }
}

test_distinct_types_are_not_deduped_against_each_other() {
  # Dedup is keyed on ticket+tool+type. Two different Playwright failures from
  # the same tool must both be recorded, or the classifier buys nothing.
  _setup
  _fire "mcp__plugin_playwright_playwright__browser_click" "locator.click: Timeout 30000ms exceeded." >/dev/null
  _fire "mcp__plugin_playwright_playwright__browser_click" "strict mode violation: resolved to 0 elements" >/dev/null
  local n
  n=$(wc -l <"${_ws}/${_tid}-tool-errors.log")
  [ "$n" -eq 2 ] || {
    echo "  expected 2 entries, got $n: $(cat "${_ws}/${_tid}-tool-errors.log")"
    return 1
  }
}

test_repeat_of_the_same_type_is_deduped() {
  _setup
  _fire "mcp__plugin_playwright_playwright__browser_click" "locator.click: Timeout 30000ms exceeded." >/dev/null
  _fire "mcp__plugin_playwright_playwright__browser_click" "locator.click: Timeout 30000ms exceeded." >/dev/null
  local n
  n=$(wc -l <"${_ws}/${_tid}-tool-errors.log")
  [ "$n" -eq 1 ] || {
    echo "  expected 1 entry, got $n: $(cat "${_ws}/${_tid}-tool-errors.log")"
    return 1
  }
}

FILTER="${1:-}"
for t in $(declare -F | awk '{print $3}' | grep '^test_'); do
  if [ -z "$FILTER" ] || [[ $t == *"$FILTER"* ]]; then
    _run "$t" "$t"
  fi
done

echo
echo "=== test-tool-error-capture.sh: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
