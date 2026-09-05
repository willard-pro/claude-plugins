#!/usr/bin/env bash
# test-run-identity.sh — tests for lib/run-identity.sh (Branch A, Commercial
# Evidence MVP).
#
# The open-run guard is the interesting behaviour: a second stamp within one
# open run must be a no-op, an outcome must close the run, and --new must
# force a fresh one regardless. Ticket-meta's Linear dependency is stubbed by
# file (replacing lib/linear-api.sh in a sandbox copy), the same convention
# test-ticket-preamble.sh uses for branch-resolve.sh — run-identity.sh
# resolves the library by path relative to itself, so the sandbox's stub is
# picked up exactly as the real file would be.
# -u (nounset) intentionally omitted — see test-detect-resume.sh.
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

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

# Sandbox: a copy of lib/, so a stubbed linear-api.sh is resolved by
# run-identity.sh's own path-relative lookup instead of the real file.
_sandbox_new() {
  _SANDBOX="$(mktemp -d)"
  mkdir -p "$_SANDBOX/lib" "$_SANDBOX/logs"
  cp "$LIB_DIR"/*.sh "$_SANDBOX/lib/"
}

_sandbox_rm() {
  [ -n "$_SANDBOX" ] && rm -rf "$_SANDBOX"
  _SANDBOX=""
}

_stub_get_issue() {
  cat >"$_SANDBOX/lib/linear-api.sh" <<STUB
#!/usr/bin/env bash
get_issue() {
$1
}
STUB
}

_ri() {
  bash -c "source '$_SANDBOX/lib/run-identity.sh'; $1"
}

# ── run-id + version ───────────────────────────────────────────────────────────

test_stamp_writes_run_id_then_version() {
  _sandbox_new
  local log="$_SANDBOX/logs/T.log"
  : >"$log"
  _ri "run_identity_stamp T-1 '$log'" >/dev/null
  local ok
  [ "$(sed -n '1p' "$log" | cut -d'|' -f2-4)" = "META|run-id|info" ] &&
    [ "$(sed -n '2p' "$log" | cut -d'|' -f2-4)" = "META|version|info" ]
  ok=$?
  _sandbox_rm
  return $ok
}

test_run_id_line_has_expected_fields() {
  _sandbox_new
  local log="$_SANDBOX/logs/T.log"
  : >"$log"
  _ri "run_identity_stamp T-2 '$log'" >/dev/null
  local json
  json=$(grep '|META|run-id|info|' "$log" | cut -d'|' -f5-)
  local ok
  echo "$json" | jq -e '.run_id | test("^T-2-")' >/dev/null &&
    [ "$(echo "$json" | jq -r '.trigger')" = "manual" ] &&
    [ "$(echo "$json" | jq -r '.gen')" = "null" ] &&
    echo "$json" | jq -e '.pid | type == "number"' >/dev/null
  ok=$?
  _sandbox_rm
  return $ok
}

test_second_stamp_in_open_run_is_a_no_op() {
  _sandbox_new
  local log="$_SANDBOX/logs/T.log"
  : >"$log"
  _ri "run_identity_stamp T-3 '$log'" >/dev/null
  _ri "run_identity_stamp T-3 '$log'" >/dev/null
  local ok
  [ "$(grep -c '|META|run-id|info|' "$log")" -eq 1 ]
  ok=$?
  _sandbox_rm
  return $ok
}

test_new_run_after_an_outcome() {
  _sandbox_new
  local log="$_SANDBOX/logs/T.log"
  : >"$log"
  _ri "run_identity_stamp T-4 '$log'" >/dev/null
  echo '2026-01-01T00:00:00Z|META|outcome|info|{"status":"done"}' >>"$log"
  _ri "run_identity_stamp T-4 '$log'" >/dev/null
  local ok
  [ "$(grep -c '|META|run-id|info|' "$log")" -eq 2 ]
  ok=$?
  _sandbox_rm
  return $ok
}

test_new_flag_forces_a_fresh_run_id_inside_an_open_run() {
  _sandbox_new
  local log="$_SANDBOX/logs/T.log"
  : >"$log"
  _ri "run_identity_stamp T-5 '$log'" >/dev/null
  _ri "run_identity_stamp T-5 '$log' --new" >/dev/null
  local ok
  [ "$(grep -c '|META|run-id|info|' "$log")" -eq 2 ] &&
    [ "$(grep '|META|run-id|info|' "$log" | sed -n '1p' | cut -d'|' -f5- | jq -r '.run_id')" != \
      "$(grep '|META|run-id|info|' "$log" | sed -n '2p' | cut -d'|' -f5- | jq -r '.run_id')" ]
  ok=$?
  _sandbox_rm
  return $ok
}

test_trigger_is_fleetd_from_worker_pid() {
  _sandbox_new
  local log="$_SANDBOX/logs/T.log"
  : >"$log"
  FLEET_WORKER_PID=999 bash -c "source '$_SANDBOX/lib/run-identity.sh'; run_identity_stamp T-6 '$log'" >/dev/null
  local ok
  [ "$(grep '|META|run-id|info|' "$log" | cut -d'|' -f5- | jq -r '.trigger')" = "fleetd" ]
  ok=$?
  _sandbox_rm
  return $ok
}

test_gen_is_null_without_fleet_generation() {
  _sandbox_new
  local log="$_SANDBOX/logs/T.log"
  : >"$log"
  _ri "run_identity_stamp T-7 '$log'" >/dev/null
  local ok
  [ "$(grep '|META|run-id|info|' "$log" | cut -d'|' -f5- | jq -r '.gen')" = "null" ]
  ok=$?
  _sandbox_rm
  return $ok
}

test_gen_carries_fleet_generation_when_set() {
  _sandbox_new
  local log="$_SANDBOX/logs/T.log"
  : >"$log"
  FLEET_GENERATION=3 bash -c "source '$_SANDBOX/lib/run-identity.sh'; run_identity_stamp T-8 '$log'" >/dev/null
  local ok
  [ "$(grep '|META|run-id|info|' "$log" | cut -d'|' -f5- | jq -r '.gen')" = "3" ]
  ok=$?
  _sandbox_rm
  return $ok
}

test_version_fields_null_without_their_sources() {
  _sandbox_new
  local log="$_SANDBOX/logs/T.log"
  : >"$log"
  local json
  json=$(env -u FLEET_VERSION -u ANTHROPIC_MODEL \
    bash -c "source '$_SANDBOX/lib/run-identity.sh'; run_identity_stamp T-9 '$log' >/dev/null; grep '|META|version|info|' '$log' | cut -d'|' -f5-")
  local ok
  [ "$(echo "$json" | jq -r '.fleet')" = "null" ] &&
    [ "$(echo "$json" | jq -r '.model_default')" = "null" ]
  ok=$?
  _sandbox_rm
  return $ok
}

test_version_carries_ticket_auto_plugin_version() {
  # Run against the real lib dir (not the sandbox): plugin-root resolution is
  # relative to run-identity.sh's own location, and the sandbox has no
  # .claude-plugin/plugin.json to resolve against.
  local tmp log
  tmp="$(mktemp -d)"
  log="$tmp/T.log"
  : >"$log"
  bash -c "source '$LIB_DIR/run-identity.sh'; run_identity_stamp T-10 '$log'" >/dev/null
  local expected
  expected=$(jq -r '.version' "$LIB_DIR/../.claude-plugin/plugin.json")
  local ok
  [ "$(grep '|META|version|info|' "$log" | cut -d'|' -f5- | jq -r '.ticket_auto')" = "$expected" ]
  ok=$?
  rm -rf "$tmp"
  return $ok
}

# ── run_identity_current ───────────────────────────────────────────────────────

test_current_is_empty_with_no_run_id_line() {
  _sandbox_new
  local log="$_SANDBOX/logs/T.log"
  : >"$log"
  local out
  out=$(_ri "run_identity_current '$log'")
  local ok
  [ -z "$out" ]
  ok=$?
  _sandbox_rm
  return $ok
}

test_current_returns_the_open_run_id() {
  _sandbox_new
  local log="$_SANDBOX/logs/T.log"
  : >"$log"
  _ri "run_identity_stamp T-11 '$log'" >/dev/null
  local out expected
  expected=$(grep '|META|run-id|info|' "$log" | cut -d'|' -f5- | jq -r '.run_id')
  out=$(_ri "run_identity_current '$log'")
  local ok
  [ "$out" = "$expected" ]
  ok=$?
  _sandbox_rm
  return $ok
}

# ── ticket-meta ────────────────────────────────────────────────────────────────

test_ticket_meta_no_ops_without_linear_api_key() {
  _sandbox_new
  _stub_get_issue 'cat <<J
{"labels":{"nodes":[]}}
J'
  local log="$_SANDBOX/logs/T.log"
  : >"$log"
  env -u LINEAR_API_KEY bash -c "source '$_SANDBOX/lib/run-identity.sh'; run_identity_ticket_meta T-12 '$log'"
  local ok
  ! grep -q '|META|ticket-meta|' "$log"
  ok=$?
  _sandbox_rm
  return $ok
}

test_ticket_meta_written_once() {
  _sandbox_new
  _stub_get_issue 'cat <<J
{"createdAt":"2026-01-01T00:00:00Z","startedAt":null,"estimate":3,"priority":2,"labels":{"nodes":[{"name":"bug"}]}}
J'
  local log="$_SANDBOX/logs/T.log"
  : >"$log"
  LINEAR_API_KEY=x bash -c "source '$_SANDBOX/lib/run-identity.sh'; run_identity_ticket_meta T-13 '$log'"
  LINEAR_API_KEY=x bash -c "source '$_SANDBOX/lib/run-identity.sh'; run_identity_ticket_meta T-13 '$log'"
  local ok
  [ "$(grep -c '|META|ticket-meta|' "$log")" -eq 1 ]
  ok=$?
  _sandbox_rm
  return $ok
}

test_ticket_meta_type_derived_from_labels() {
  _sandbox_new
  _stub_get_issue 'cat <<J
{"createdAt":null,"startedAt":null,"estimate":null,"priority":null,"labels":{"nodes":[{"name":"security"},{"name":"planned"}]}}
J'
  local log="$_SANDBOX/logs/T.log"
  : >"$log"
  LINEAR_API_KEY=x bash -c "source '$_SANDBOX/lib/run-identity.sh'; run_identity_ticket_meta T-14 '$log'"
  local json ok
  json=$(grep '|META|ticket-meta|' "$log" | cut -d'|' -f5-)
  [ "$(echo "$json" | jq -r '.type')" = "security" ] &&
    [ "$(echo "$json" | jq -r '.planned')" = "true" ]
  ok=$?
  _sandbox_rm
  return $ok
}

test_ticket_meta_type_null_when_no_label_matches() {
  _sandbox_new
  _stub_get_issue 'cat <<J
{"createdAt":null,"startedAt":null,"estimate":null,"priority":null,"labels":{"nodes":[{"name":"unrelated"}]}}
J'
  local log="$_SANDBOX/logs/T.log"
  : >"$log"
  LINEAR_API_KEY=x bash -c "source '$_SANDBOX/lib/run-identity.sh'; run_identity_ticket_meta T-15 '$log'"
  local ok
  [ "$(grep '|META|ticket-meta|' "$log" | cut -d'|' -f5- | jq -r '.type')" = "null" ]
  ok=$?
  _sandbox_rm
  return $ok
}

# ── CLI entrypoint ─────────────────────────────────────────────────────────────

test_cli_stamp_writes_run_id() {
  _sandbox_new
  local log="$_SANDBOX/logs/T.log"
  : >"$log"
  bash "$_SANDBOX/lib/run-identity.sh" stamp T-16 "$log" >/dev/null
  local ok
  grep -q '|META|run-id|info|' "$log"
  ok=$?
  _sandbox_rm
  return $ok
}

_run "stamp writes run-id then version" test_stamp_writes_run_id_then_version
_run "run-id line has expected fields" test_run_id_line_has_expected_fields
_run "second stamp in open run is a no-op" test_second_stamp_in_open_run_is_a_no_op
_run "new run after an outcome" test_new_run_after_an_outcome
_run "--new forces a fresh run-id inside an open run" test_new_flag_forces_a_fresh_run_id_inside_an_open_run
_run "trigger is fleetd from FLEET_WORKER_PID" test_trigger_is_fleetd_from_worker_pid
_run "gen is null without FLEET_GENERATION" test_gen_is_null_without_fleet_generation
_run "gen carries FLEET_GENERATION when set" test_gen_carries_fleet_generation_when_set
_run "version fields null without their sources" test_version_fields_null_without_their_sources
_run "version carries ticket_auto plugin version" test_version_carries_ticket_auto_plugin_version
_run "current is empty with no run-id line" test_current_is_empty_with_no_run_id_line
_run "current returns the open run id" test_current_returns_the_open_run_id
_run "ticket-meta no-ops without LINEAR_API_KEY" test_ticket_meta_no_ops_without_linear_api_key
_run "ticket-meta written once" test_ticket_meta_written_once
_run "ticket-meta type derived from labels" test_ticket_meta_type_derived_from_labels
_run "ticket-meta type null when no label matches" test_ticket_meta_type_null_when_no_label_matches
_run "CLI stamp writes run-id" test_cli_stamp_writes_run_id

echo ""
echo "run-identity: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
