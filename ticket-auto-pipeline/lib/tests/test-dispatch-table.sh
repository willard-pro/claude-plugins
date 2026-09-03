#!/usr/bin/env bash
# test-dispatch-table.sh — unit tests for skills/ticket-flow/dispatch-table.json
# and its generator, gen-dispatch-table.py.
#
# The generator is the drift gate between the canonical JSON and SKILL.md's
# rendered table. These tests prove the gate actually fires: a JSON edit that is
# not regenerated MUST fail --check, and --write MUST propagate it.
#
# Usage: bash test-dispatch-table.sh [test_name_filter]
set -eo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
FLOW_DIR="$REPO_ROOT/ticket-auto-pipeline/skills/ticket-flow"
GEN="$FLOW_DIR/gen-dispatch-table.py"
TABLE="$FLOW_DIR/dispatch-table.json"
SKILL="$REPO_ROOT/ticket-auto-pipeline/skills/ticket-auto/SKILL.md"

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

# ── sandbox ───────────────────────────────────────────────────────────────────
# Every mutating test runs against copies in a temp dir, never the real files,
# so a failed assertion can never leave the repo's SKILL.md rewritten.
_sandbox=""
_mksandbox() {
  _sandbox=$(mktemp -d "${TMPDIR:-/tmp}/test-dispatch-table.XXXXXX")
  cp "$TABLE" "$_sandbox/dispatch-table.json"
  cp "$SKILL" "$_sandbox/SKILL.md"
}
_cleanup() { [ -n "$_sandbox" ] && rm -rf "$_sandbox"; }
trap _cleanup EXIT

_gen() { python3 "$GEN" --table "$_sandbox/dispatch-table.json" --skill "$_sandbox/SKILL.md" "$@"; }

# ── tests ─────────────────────────────────────────────────────────────────────

test_json_is_valid_and_has_required_fields() {
  python3 - "$TABLE" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
steps = data["steps"]
assert steps, "no steps"
for i, s in enumerate(steps):
    for f in ("step_id", "table_label", "table_action", "table_type", "action"):
        assert f in s, f"steps[{i}] missing {f}"
ids = [s["step_id"] for s in steps]
assert len(ids) == len(set(ids)), f"duplicate step_id in {ids}"
PY
}

test_every_router_managed_loop_cap_is_recorded() {
  # Task 1.2: there are four router-managed cycle caps, not two. A regression
  # that drops one from the JSON silently drops it from fleetd's dispatch.
  python3 - "$TABLE" <<'PY'
import json, sys
steps = json.load(open(sys.argv[1]))["steps"]
loops = {s["step_id"]: s["loop"] for s in steps if "loop" in s}
expected = {
    "STEP_3_5": ("RECONCILE_CYCLE", 3, "RECONCILE_EXHAUSTED"),
    "STEP_4_5": ("VERIFY_ATTEMPTS", 2, "VERIFY_EXHAUSTED"),
    "STEP_4_6": ("ITERATION", 3, "PR_REVIEW_EXHAUSTED"),
    "STEP_5_5": ("PR_FEEDBACK_CYCLE", 3, "PR_FEEDBACK_EXHAUSTED"),
}
assert set(loops) == set(expected), f"loop steps drifted: {sorted(loops)}"
for sid, (counter, cap, code) in expected.items():
    got = loops[sid]
    assert got["counter"] == counter, f"{sid} counter {got['counter']} != {counter}"
    assert got["max_iterations"] == cap, f"{sid} cap {got['max_iterations']} != {cap}"
    assert got["gate_stop_code"] == code, f"{sid} code {got['gate_stop_code']!r} != {code!r}"

# STEP_4_6 shipped with a null code; fleetd-phase-supervisor task 4.6 named it.
# An unnamed cap makes pipeline-finalize.sh write "stopped: gate-stop " — a run
# that stopped without recording why — so the invariant is now that every
# router-managed cap names its exhaustion.
for sid, got in loops.items():
    assert got.get("gate_stop_code"), f"{sid} exhausts with no named gate-stop code"
PY
}

test_step_3_is_recorded_as_an_alias_of_step_2_5() {
  python3 - "$TABLE" <<'PY'
import json, sys
steps = {s["step_id"]: s for s in json.load(open(sys.argv[1]))["steps"]}
assert steps["STEP_3"]["action"] == "alias"
assert steps["STEP_3"]["alias_of"] == "STEP_2_5"
assert "STEP_3" in steps["STEP_2_5"]["aliases"]
PY
}

test_verify_last_precondition_is_captured() {
  # Task 1.3: the VERIFY_LAST=fail crash-resume branch is dispatch-relevant
  # control flow a step->action table cannot express.
  python3 - "$TABLE" <<'PY'
import json, sys
steps = {s["step_id"]: s for s in json.load(open(sys.argv[1]))["steps"]}
pre = steps["STEP_4_5"]["precondition"]
assert pre["variable"] == "VERIFY_LAST"
assert pre["equals"] == "fail"
assert pre["then_dispatch_first"] == "STEP_4"
PY
}

test_check_passes_against_committed_skill_md() {
  python3 "$GEN" --check >/dev/null
}

test_generated_block_matches_skill_md_byte_for_byte() {
  local expected actual
  expected=$(python3 "$GEN")
  actual=$(awk '/GENERATED:dispatch-table START/,/GENERATED:dispatch-table END/' "$SKILL")
  [ "$expected" = "$actual" ]
}

test_check_fails_when_json_changes_without_regeneration() {
  _mksandbox
  python3 - "$_sandbox/dispatch-table.json" <<'PY'
import json, sys
p = sys.argv[1]
data = json.load(open(p))
data["steps"].append({
    "step_id": "STEP_TEST_ONLY", "table_label": "`STEP_TEST_ONLY`",
    "table_action": "Throwaway row", "table_type": "Agent", "action": "agent",
})
json.dump(data, open(p, "w"), indent=2)
PY
  # Must fail with exit 1 (drift), not 2 (structural).
  local rc=0
  _gen --check >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 1 ]
}

test_write_propagates_a_new_step_into_skill_md() {
  # Sandbox already carries the throwaway step from the previous test's setup;
  # rebuild it here so the test stands alone.
  _mksandbox
  python3 - "$_sandbox/dispatch-table.json" <<'PY'
import json, sys
p = sys.argv[1]
data = json.load(open(p))
data["steps"].append({
    "step_id": "STEP_TEST_ONLY", "table_label": "`STEP_TEST_ONLY`",
    "table_action": "Throwaway row", "table_type": "Agent", "action": "agent",
})
json.dump(data, open(p, "w"), indent=2)
PY
  _gen --write >/dev/null
  grep -q '^| `STEP_TEST_ONLY` | Throwaway row | Agent |$' "$_sandbox/SKILL.md" || return 1
  # And the gate is green again once regenerated.
  _gen --check >/dev/null || return 1
  # A write that actually rewrites the file must still leave every byte outside
  # the markers alone. test_write_touches_nothing_outside_the_markers cannot
  # cover this: with no drift, --write short-circuits and never writes at all.
  _head_of() { awk '/GENERATED:dispatch-table START/{exit} {print}' "$1"; }
  _tail_of() { awk 'f{print} /GENERATED:dispatch-table END/{f=1}' "$1"; }
  [ "$(_head_of "$SKILL")" = "$(_head_of "$_sandbox/SKILL.md")" ] || return 1
  [ "$(_tail_of "$SKILL")" = "$(_tail_of "$_sandbox/SKILL.md")" ] || return 1
}

test_write_touches_nothing_outside_the_markers() {
  _mksandbox
  _gen --write >/dev/null
  diff -q "$SKILL" "$_sandbox/SKILL.md"
}

test_missing_markers_is_a_structural_error_not_drift() {
  _mksandbox
  grep -v 'GENERATED:dispatch-table' "$SKILL" >"$_sandbox/SKILL.md"
  local rc=0
  _gen --check >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 2 ]
}

test_malformed_json_is_a_structural_error() {
  _mksandbox
  echo '{ not json' >"$_sandbox/dispatch-table.json"
  local rc=0
  _gen --check >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 2 ]
}

test_missing_required_field_is_rejected() {
  _mksandbox
  python3 - "$_sandbox/dispatch-table.json" <<'PY'
import json, sys
p = sys.argv[1]
data = json.load(open(p))
del data["steps"][0]["table_type"]
json.dump(data, open(p, "w"), indent=2)
PY
  local rc=0
  _gen --check >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 2 ]
}

test_render_is_deterministic() {
  local a b
  a=$(python3 "$GEN")
  b=$(python3 "$GEN")
  [ "$a" = "$b" ]
}

test_check_and_write_are_mutually_exclusive() {
  _mksandbox
  local rc=0
  _gen --check --write >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 2 ]
}

# ── runner ────────────────────────────────────────────────────────────────────
FILTER="${1:-}"
for t in $(declare -F | awk '{print $3}' | grep '^test_'); do
  if [ -z "$FILTER" ] || [[ $t == *"$FILTER"* ]]; then
    _run "$t" "$t"
  fi
done

echo
echo "=== test-dispatch-table.sh: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
