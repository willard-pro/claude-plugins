#!/usr/bin/env bash
# test-agent-activity.sh — unit tests for hooks/agent-activity.sh (the
# PostToolUse agent-liveness signal) and spawn-helper.sh's orphan sweep.
#
# Both units exist for the same failure: the orchestrator's watchdog proves the
# router is alive, never that the agent it is blocked on is. The hook supplies
# the agent's own pulse; the sweep stops a dead router's watchdog from faking
# one.
#
# Usage: bash test-agent-activity.sh [test_name_filter]
# -u (nounset) intentionally omitted: Claude Code shell snapshots inject
# ZSH_VERSION references that trigger false-positive "unbound variable" errors.
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
HOOKS_DIR="$(cd "$SCRIPT_DIR/../../hooks" && pwd)"
HOOK="$HOOKS_DIR/agent-activity.sh"

PASS=0
FAIL=0
_run() {
  local name="$1"
  shift
  if "$@"; then
    echo "PASS: $name"
    ((PASS++)) || true
  else
    echo "FAIL: $name"
    ((FAIL++)) || true
  fi
}

_TEST_TMPDIRS=()
_mktemp_test_dir() {
  local d
  d=$(mktemp -d)
  _TEST_TMPDIRS+=("$d")
  echo "$d"
}

# Every ticket id here starts with TESTACT- so the /tmp glob below cannot reach
# a real run's spawn-meta files. The hook hardcodes /tmp (as token-tracker.sh
# does), so these fixtures are genuinely global while they exist — leaving one
# behind would make it live input to the production hook (#273).
_TEST_BG_PIDS=()
_cleanup() {
  local d p
  for d in "${_TEST_TMPDIRS[@]}"; do
    rm -rf "$d" 2>/dev/null || true
  done
  for p in "${_TEST_BG_PIDS[@]}"; do
    [ -n "$p" ] && kill -KILL "$p" 2>/dev/null || true
  done
  rm -f /tmp/ticket-auto-TESTACT-*-spawn-meta.txt 2>/dev/null || true
}
trap _cleanup EXIT

# Writes the spawn-meta file the hook resolves identity through.
# Usage: _write_meta <tid> <session_id> <phase> <log_file>
_write_meta() {
  local tid="$1" sid="$2" phase="$3" log_file="$4"
  cat >"/tmp/ticket-auto-${tid}-spawn-meta.txt" <<EOF
PHASE=$phase
STEP=implement
TICKET_ID=$tid
LOG_FILE=$log_file
SESSION_ID=$sid
EOF
}

_fire_hook() {
  local sid="$1" tool="${2:-Bash}"
  printf '{"session_id":"%s","tool_name":"%s","hook_event_name":"PostToolUse"}\n' "$sid" "$tool" |
    bash "$HOOK"
}

# ── Hook tests ───────────────────────────────────────────────────────────────────

test_hook_appends_activity_line() {
  local ws
  ws=$(_mktemp_test_dir)
  _write_meta "TESTACT-1" "sess-aaa" "IMPLEMENT" "$ws/TESTACT-1-pipeline.log"

  _fire_hook "sess-aaa" "Bash" || return 1

  local act="$ws/TESTACT-1-activity.log"
  [ -f "$act" ] || {
    echo "  activity log not created"
    return 1
  }
  grep -q '|IMPLEMENT|Bash$' "$act" || {
    echo "  unexpected content: $(cat "$act")"
    return 1
  }
  [ "$(wc -l <"$act")" = "1" ] || return 1
}

test_hook_records_non_bash_tools() {
  local ws
  ws=$(_mktemp_test_dir)
  _write_meta "TESTACT-2" "sess-bbb" "VERIFY" "$ws/TESTACT-2-pipeline.log"

  # The matcher covers every tool, not just Bash — a Playwright-driven verify
  # phase makes almost no Bash calls and would otherwise read as silent.
  _fire_hook "sess-bbb" "mcp__playwright__browser_click" || return 1

  grep -q '|VERIFY|mcp__playwright__browser_click$' "$ws/TESTACT-2-activity.log" || return 1
}

test_hook_ignores_unrelated_session() {
  local ws
  ws=$(_mktemp_test_dir)
  _write_meta "TESTACT-3" "sess-ccc" "IMPLEMENT" "$ws/TESTACT-3-pipeline.log"

  # An ordinary Claude Code session on a host that happens to be running the
  # pipeline. It resolves no identity and must write nothing anywhere.
  _fire_hook "sess-unrelated" "Read" || return 1

  [ ! -f "$ws/TESTACT-3-activity.log" ] || {
    echo "  wrote an activity log for an unrelated session"
    return 1
  }
}

test_hook_ignores_payload_without_session_id() {
  local ws
  ws=$(_mktemp_test_dir)
  _write_meta "TESTACT-4" "sess-ddd" "IMPLEMENT" "$ws/TESTACT-4-pipeline.log"

  printf '{"tool_name":"Bash"}\n' | bash "$HOOK" || return 1
  [ ! -f "$ws/TESTACT-4-activity.log" ] || return 1
}

test_hook_ring_caps_activity_log() {
  local ws
  ws=$(_mktemp_test_dir)
  _write_meta "TESTACT-5" "sess-eee" "IMPLEMENT" "$ws/TESTACT-5-pipeline.log"

  local act="$ws/TESTACT-5-activity.log"
  local i
  for i in $(seq 1 20); do
    echo "2026-01-01T00:00:00Z|IMPLEMENT|Old${i}" >>"$act"
  done

  printf '{"session_id":"sess-eee","tool_name":"Newest"}\n' |
    FLEET_ACTIVITY_LOG_MAX_LINES=5 bash "$HOOK" || return 1

  [ "$(wc -l <"$act")" = "5" ] || {
    echo "  expected 5 lines, got $(wc -l <"$act")"
    return 1
  }
  tail -1 "$act" | grep -q '|Newest$' || {
    echo "  newest line was trimmed instead of the oldest"
    return 1
  }
}

test_hook_exits_zero_when_log_dir_missing() {
  local ws
  ws=$(_mktemp_test_dir)
  _write_meta "TESTACT-6" "sess-fff" "IMPLEMENT" "$ws/gone/TESTACT-6-pipeline.log"

  # An unwritable or absent destination must never surface as a hook failure —
  # a non-zero exit here would land on the agent's tool call.
  _fire_hook "sess-fff" "Bash" || {
    echo "  hook exited non-zero"
    return 1
  }
  [ ! -e "$ws/gone" ] || return 1
}

test_hook_rejects_traversal_ticket_id() {
  local ws
  ws=$(_mktemp_test_dir)
  # A spawn-meta filename whose embedded ticket id escapes the log directory.
  cat >"/tmp/ticket-auto-TESTACT-..-evil-spawn-meta.txt" <<EOF
PHASE=IMPLEMENT
LOG_FILE=$ws/x-pipeline.log
SESSION_ID=sess-ggg
EOF
  local rc=0
  _fire_hook "sess-ggg" "Bash" || rc=$?
  rm -f "/tmp/ticket-auto-TESTACT-..-evil-spawn-meta.txt"

  [ "$rc" -eq 0 ] || return 1
  # Nothing written under the resolved directory at all.
  [ -z "$(ls -A "$ws" 2>/dev/null)" ] || {
    echo "  wrote: $(ls -A "$ws")"
    return 1
  }
}

test_hook_sanitizes_field_separator_in_tool_name() {
  local ws
  ws=$(_mktemp_test_dir)
  _write_meta "TESTACT-7" "sess-hhh" "IMPLEMENT" "$ws/TESTACT-7-pipeline.log"

  # A pipe in a tool name would forge an extra field in a pipe-delimited log.
  _fire_hook "sess-hhh" 'Ba|sh' || return 1

  local act="$ws/TESTACT-7-activity.log"
  [ "$(awk -F'|' '{print NF}' "$act")" = "3" ] || {
    echo "  expected 3 fields, got: $(cat "$act")"
    return 1
  }
}

# ── Orphan-sweep tests ───────────────────────────────────────────────────────────

_load_spawn_helper() {
  # shellcheck disable=SC1090
  source "$LIB_DIR/spawn-helper.sh"
}

test_sweep_kills_orphaned_watchdog() {
  local state
  state=$(_mktemp_test_dir)
  (
    export FLEET_STATE_DIR="$state"
    _load_spawn_helper
    sleep 300 &
    local orphan=$!
    disown
    _worker_bg_record "TESTACT-8" "watchdog" "$orphan"
    echo "$orphan" >"$state/orphan.pid"

    spawn_sweep_orphans "TESTACT-8" 2>/dev/null

    # Give the signal a moment to land before asserting.
    sleep 0.2
    if kill -0 "$orphan" 2>/dev/null; then
      kill -KILL "$orphan" 2>/dev/null || true
      echo "  orphan survived the sweep"
      exit 1
    fi
    # Ledger is cleared so a later sweep does not re-signal a recycled pid.
    local ledger="$state/ticket-auto-TESTACT-8-bgpids.txt"
    [ -f "$ledger" ] || exit 1
    [ ! -s "$ledger" ] || {
      echo "  ledger not cleared"
      exit 1
    }
  ) || return 1
  local leftover
  leftover=$(cat "$state/orphan.pid" 2>/dev/null || true)
  [ -n "$leftover" ] && _TEST_BG_PIDS+=("$leftover")
  return 0
}

test_sweep_skips_recycled_pid() {
  local state
  state=$(_mktemp_test_dir)
  local survivor
  sleep 300 &
  survivor=$!
  disown
  _TEST_BG_PIDS+=("$survivor")

  (
    export FLEET_STATE_DIR="$state"
    _load_spawn_helper
    # Start ticks that cannot match the live process — this is what a pid the
    # kernel recycled to an unrelated process looks like.
    echo "${survivor}:1:watchdog" >"$state/ticket-auto-TESTACT-9-bgpids.txt"
    spawn_sweep_orphans "TESTACT-9" 2>/dev/null
  ) || return 1

  sleep 0.2
  kill -0 "$survivor" 2>/dev/null || {
    echo "  killed a process whose start ticks did not match"
    return 1
  }
  kill -KILL "$survivor" 2>/dev/null || true
}

test_sweep_is_noop_without_ledger() {
  local state
  state=$(_mktemp_test_dir)
  (
    export FLEET_STATE_DIR="$state"
    _load_spawn_helper
    spawn_sweep_orphans "TESTACT-10" 2>/dev/null
  ) || return 1
}

test_sweep_ignores_dead_and_invalid_entries() {
  local state
  state=$(_mktemp_test_dir)
  (
    export FLEET_STATE_DIR="$state"
    _load_spawn_helper
    # A reaped pid, pid 1, and a garbage line must all be skipped silently.
    printf '999999999:123:watchdog\n1:1:pinger\nnot-a-pid::x\n' \
      >"$state/ticket-auto-TESTACT-11-bgpids.txt"
    spawn_sweep_orphans "TESTACT-11" 2>/dev/null
  ) || return 1
}

FILTER="${1:-}"
for t in \
  test_hook_appends_activity_line \
  test_hook_records_non_bash_tools \
  test_hook_ignores_unrelated_session \
  test_hook_ignores_payload_without_session_id \
  test_hook_ring_caps_activity_log \
  test_hook_exits_zero_when_log_dir_missing \
  test_hook_rejects_traversal_ticket_id \
  test_hook_sanitizes_field_separator_in_tool_name \
  test_sweep_kills_orphaned_watchdog \
  test_sweep_skips_recycled_pid \
  test_sweep_is_noop_without_ledger \
  test_sweep_ignores_dead_and_invalid_entries; do
  if [ -z "$FILTER" ] || [[ "$t" == *"$FILTER"* ]]; then
    _run "$t" "$t"
  fi
done

echo ""
echo "=== $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
