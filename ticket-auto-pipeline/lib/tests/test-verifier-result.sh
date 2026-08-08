#!/usr/bin/env bash
# test-verifier-result.sh — unit tests for lib/verifier-result.sh
# Usage: bash test-verifier-result.sh [test_name_filter]
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

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

# ── Setup / teardown ───────────────────────────────────────────────────────────

_ws=""
_log=""

_setup() {
	_ws=$(mktemp -d)
	_log="${_ws}/pipeline.log"
	LOG_FILE="$_log"
	export LOG_FILE
}

_teardown() {
	rm -rf "$_ws" 2>/dev/null || true
	LOG_FILE=""
}

# Source the library once
# shellcheck source=../verifier-result.sh
source "$LIB_DIR/verifier-result.sh"

# ── Helper: count lines and extract last line's MSG ────────────────────────────

_last_msg() {
	# Join fields 5+ with awk (never cut -f5 — JSON contains pipes)
	awk -F'|' '{s=$5; for(i=6;i<=NF;i++) s=s"|"$i; print s}' "$_log" | tail -1
}

_last_json_field() {
	local field="$1"
	_last_msg | jq -r ".${field}" 2>/dev/null || echo "PARSE_ERROR"
}

# ── Basic write ────────────────────────────────────────────────────────────────

test_basic_pass() {
	_setup
	write_verifier_result verifier=unit_tests verdict=PASS criteria_met=5 criteria_total=5 attempt=1 phase=IMPLEMENT
	[ -f "$_log" ] || {
		_teardown
		return 1
	}
	local verdict
	verdict=$(_last_json_field "verdict")
	[ "$verdict" = "PASS" ] || {
		_teardown
		return 1
	}
	_teardown
}

test_score_pass_is_one() {
	_setup
	write_verifier_result verifier=uat verdict=PASS criteria_met=3 criteria_total=3 phase=VERIFY
	local score
	score=$(_last_json_field "score")
	[ "$score" = "1.0" ] || {
		_teardown
		return 1
	}
	_teardown
}

test_score_fail_ratio() {
	_setup
	write_verifier_result verifier=unit_tests verdict=FAIL criteria_met=3 criteria_total=8 phase=IMPLEMENT
	local score
	score=$(_last_json_field "score")
	# 3/8 = 0.375
	[ "$score" = "0.375" ] || {
		_teardown
		return 1
	}
	_teardown
}

test_score_fail_zero_criteria() {
	_setup
	write_verifier_result verifier=unit_tests verdict=FAIL criteria_met=0 criteria_total=0 phase=IMPLEMENT
	local score
	score=$(_last_json_field "score")
	[ "$score" = "0.0" ] || {
		_teardown
		return 1
	}
	_teardown
}

test_score_warn_is_07() {
	_setup
	write_verifier_result verifier=pr_review verdict=WARN criteria_met=2 criteria_total=5 phase=PR-REVIEW
	local score
	score=$(_last_json_field "score")
	[ "$score" = "0.7" ] || {
		_teardown
		return 1
	}
	_teardown
}

test_score_block_is_zero() {
	_setup
	write_verifier_result verifier=pr_review verdict=BLOCK criteria_met=0 criteria_total=5 phase=PR-REVIEW
	local score
	score=$(_last_json_field "score")
	[ "$score" = "0.0" ] || {
		_teardown
		return 1
	}
	_teardown
}

# ── Outcome-based scoring ──────────────────────────────────────────────────────

test_outcome_smooth() {
	_setup
	write_verifier_result verifier=implement_tests verdict=FAIL outcome=Smooth phase=IMPLEMENT
	local score
	score=$(_last_json_field "score")
	[ "$score" = "0.90" ] || {
		_teardown
		return 1
	}
	_teardown
}

test_outcome_rough_with_corrections() {
	_setup
	write_verifier_result verifier=implement_tests verdict=FAIL outcome=Rough corrections=2 phase=IMPLEMENT
	local score
	score=$(_last_json_field "score")
	# 0.65 - 0.10 = 0.55
	[ "$score" = "0.55" ] || {
		_teardown
		return 1
	}
	_teardown
}

test_outcome_hard_floor() {
	_setup
	write_verifier_result verifier=implement_tests verdict=FAIL outcome=Hard corrections=10 phase=IMPLEMENT
	local score
	score=$(_last_json_field "score")
	# 0.40 - 0.50 = -0.10 → floor 0.10
	[ "$score" = "0.10" ] || {
		_teardown
		return 1
	}
	_teardown
}

# ── Embedded pipe in MSG (round-trip test via trajectory-style awk join) ───────

test_embedded_pipe_in_json() {
	_setup
	# Write a verifier-result with a pipe character in the verifier name
	write_verifier_result verifier="unit_tests" verdict=PASS criteria_met=5 criteria_total=5 phase=IMPLEMENT
	# Now write a raw META line with a pipe in the JSON and verify awk join recovers it
	echo "2026-08-08T10:00:00Z|META|verifier-result|info|{\"verifier\":\"test|pipe\",\"verdict\":\"PASS\",\"score\":1.0}" >>"$_log"
	# Read back with awk join (fields 5+)
	local recovered
	recovered=$(awk -F'|' '{s=$5; for(i=6;i<=NF;i++) s=s"|"$i; print s}' "$_log" | tail -1)
	# The recovered JSON should contain the full "test|pipe" string
	echo "$recovered" | grep -q 'test|pipe' || {
		_teardown
		return 1
	}
	# And it should parse with jq
	echo "$recovered" | jq -e . >/dev/null 2>&1 || {
		_teardown
		return 1
	}
	_teardown
}

# ── Skip-on-failure ────────────────────────────────────────────────────────────

test_skip_missing_verifier() {
	_setup
	write_verifier_result verifier="" verdict=PASS phase=IMPLEMENT 2>/dev/null
	local rc=$?
	[ "$rc" -eq 0 ] || {
		_teardown
		return 1
	}
	# No log line should have been written
	[ ! -f "$_log" ] || [ "$(wc -l <"$_log")" -eq 0 ] || {
		_teardown
		return 1
	}
	_teardown
}

test_skip_invalid_verdict() {
	_setup
	write_verifier_result verifier=test verdict=INVALID phase=IMPLEMENT 2>/dev/null
	local rc=$?
	[ "$rc" -eq 0 ] || {
		_teardown
		return 1
	}
	[ ! -f "$_log" ] || [ "$(wc -l <"$_log")" -eq 0 ] || {
		_teardown
		return 1
	}
	_teardown
}

test_skip_missing_verdict() {
	_setup
	write_verifier_result verifier=test verdict="" phase=IMPLEMENT 2>/dev/null
	local rc=$?
	[ "$rc" -eq 0 ] || {
		_teardown
		return 1
	}
	_teardown
}

test_skip_no_log_file() {
	_setup
	LOG_FILE=""
	write_verifier_result verifier=test verdict=PASS 2>/dev/null
	local rc=$?
	[ "$rc" -eq 0 ] || {
		_teardown
		return 1
	}
	_teardown
}

# ── Non-integer fallback ───────────────────────────────────────────────────────

test_non_integer_criteria_fallback() {
	_setup
	write_verifier_result verifier=test verdict=FAIL criteria_met=abc criteria_total=xyz phase=IMPLEMENT
	local score
	score=$(_last_json_field "score")
	# criteria_total=0 default → score 0.0
	[ "$score" = "0.0" ] || {
		_teardown
		return 1
	}
	_teardown
}

# ── JSON validity ──────────────────────────────────────────────────────────────

test_json_validity() {
	_setup
	write_verifier_result verifier=gate_check verdict=PASS criteria_met=1 criteria_total=1 attempt=1 phase=GATE
	local json
	json=$(_last_msg)
	echo "$json" | jq -e . >/dev/null 2>&1 || {
		_teardown
		return 1
	}
	# Verify all fields present
	[ "$(echo "$json" | jq -r '.verifier')" = "gate_check" ] || {
		_teardown
		return 1
	}
	[ "$(echo "$json" | jq -r '.verdict')" = "PASS" ] || {
		_teardown
		return 1
	}
	[ "$(echo "$json" | jq -r '.criteria_met')" = "1" ] || {
		_teardown
		return 1
	}
	[ "$(echo "$json" | jq -r '.criteria_total')" = "1" ] || {
		_teardown
		return 1
	}
	[ "$(echo "$json" | jq -r '.attempt')" = "1" ] || {
		_teardown
		return 1
	}
	[ "$(echo "$json" | jq -r '.phase')" = "GATE" ] || {
		_teardown
		return 1
	}
	_teardown
}

# ── set -e exit-code parity ────────────────────────────────────────────────────

test_set_e_exit_code_parity() {
	_setup
	# Simulate set -e context: write_verifier_result should never cause non-zero exit
	(
		set -e
		write_verifier_result verifier=test verdict=PASS phase=TEST 2>/dev/null
		# If we reach here, set -e didn't trip
		true
	)
	local rc=$?
	[ "$rc" -eq 0 ] || {
		_teardown
		return 1
	}
	_teardown
}

# ── T5: Score clamping when criteria_met > criteria_total ────────────────────────

test_score_clamped_above_one() {
	_setup
	write_verifier_result verifier=test verdict=FAIL criteria_met=5 criteria_total=3 phase=IMPLEMENT
	local score
	score=$(_last_json_field "score")
	# 5/3 = 1.667 would be > 1.0, must be clamped to 1.0
	[ "$score" = "1.0" ] || {
		echo "expected clamped score 1.0, got $score" >&2
		_teardown
		return 1
	}
	_teardown
}

test_score_clamped_below_zero() {
	_setup
	write_verifier_result verifier=test verdict=FAIL criteria_met=-5 criteria_total=3 phase=IMPLEMENT
	local score
	score=$(_last_json_field "score")
	# Negative criteria_met would produce score < 0, must be clamped to 0.0
	# (criteria_met=-5 is non-integer so fallback to 0 → 0/3 = 0.0; this tests
	# that even if awk produces negative, it's clamped)
	case "$score" in
	0.0 | 0.000) ;;
	*)
		echo "expected clamped score 0.0, got $score" >&2
		_teardown
		return 1
		;;
	esac
	_teardown
}

# ── F8: Clamped score on PASS with default criteria ──────────────────────────────

test_pass_score_clamped() {
	_setup
	write_verifier_result verifier=test verdict=PASS criteria_met=0 criteria_total=1 phase=GATE
	local score
	score=$(_last_json_field "score")
	# PASS always scores 1.0 regardless of criteria
	[ "$score" = "1.0" ] || {
		echo "expected 1.0, got $score" >&2
		_teardown
		return 1
	}
	_teardown
}

# ── T3: LOG_FILE write-failure is fail-open ──────────────────────────────────────

test_write_failure_fail_open() {
	_setup
	# Make LOG_FILE directory unwritable
	chmod 500 "$_ws"
	write_verifier_result verifier=test verdict=PASS phase=IMPLEMENT 2>/dev/null
	local rc=$?
	chmod 755 "$_ws" 2>/dev/null || true
	[ "$rc" -eq 0 ] || {
		echo "write_verifier_result should return 0 even on write failure, got $rc" >&2
		_teardown
		return 1
	}
	_teardown
}

# ── F4: Guarded log append — write_verifier_result survives disk-full scenario ──

test_fail_open_guarded_append() {
	_setup
	# Simulate unwritable LOG_FILE by setting it to a directory
	LOG_FILE="$_ws"
	write_verifier_result verifier=test verdict=PASS phase=IMPLEMENT 2>/dev/null
	local rc=$?
	[ "$rc" -eq 0 ] || {
		echo "write_verifier_result should return 0 when LOG_FILE is a directory, got $rc" >&2
		_teardown
		return 1
	}
	_teardown
}

# ── F8: Score never exceeds 1.0 when computed from ratio ────────────────────────

test_score_never_above_one() {
	_setup
	write_verifier_result verifier=test verdict=FAIL criteria_met=10 criteria_total=3 phase=IMPLEMENT
	local score
	score=$(_last_json_field "score")
	# 10/3 = 3.333 → must be clamped to 1.0
	[ "$score" = "1.0" ] || {
		echo "F8: score $score exceeds 1.0 (should be clamped)" >&2
		_teardown
		return 1
	}
	_teardown
}

test_fail_zero_total_div_by_zero() {
	_setup
	# criteria_total=0 with FAIL verdict — score should be 0.0
	write_verifier_result verifier=test verdict=FAIL criteria_met=0 criteria_total=0 phase=IMPLEMENT
	local score
	score=$(_last_json_field "score")
	[ "$score" = "0.0" ] || {
		echo "expected 0.0, got $score" >&2
		_teardown
		return 1
	}
	_teardown
}

# ── F9: Confidence score parity — same inputs, same output ──────────────────────
# (confidence.sh is sourced by verifier-result.sh via F9 extraction)

test_confidence_parity_smooth() {
	_setup
	write_verifier_result verifier=test verdict=FAIL outcome=Smooth corrections=0 phase=IMPLEMENT
	local score
	score=$(_last_json_field "score")
	[ "$score" = "0.90" ] || {
		echo "expected 0.90, got $score" >&2
		_teardown
		return 1
	}
	_teardown
}

test_confidence_unknown_outcome() {
	_setup
	write_verifier_result verifier=test verdict=FAIL outcome=Bogus corrections=0 phase=IMPLEMENT
	local score
	score=$(_last_json_field "score")
	# Unknown outcome → base 70 → 0.70
	[ "$score" = "0.70" ] || {
		echo "expected 0.70 for unknown outcome, got $score" >&2
		_teardown
		return 1
	}
	_teardown
}

# ── Run ────────────────────────────────────────────────────────────────────────

_run "basic write appends to log" test_basic_pass
_run "PASS verdict scores 1.0" test_score_pass_is_one
_run "FAIL verdict scores criteria ratio (3/8=0.375)" test_score_fail_ratio
_run "FAIL verdict with zero criteria scores 0.0" test_score_fail_zero_criteria
_run "WARN verdict scores 0.7" test_score_warn_is_07
_run "BLOCK verdict scores 0.0" test_score_block_is_zero
_run "outcome Smooth → 0.90" test_outcome_smooth
_run "outcome Rough + 2 corrections → 0.55" test_outcome_rough_with_corrections
_run "outcome Hard + many corrections → floor 0.10" test_outcome_hard_floor
_run "embedded pipe in JSON round-trips via awk join" test_embedded_pipe_in_json
_run "skip-on-failure: missing verifier returns 0" test_skip_missing_verifier
_run "skip-on-failure: invalid verdict returns 0" test_skip_invalid_verdict
_run "skip-on-failure: missing verdict returns 0" test_skip_missing_verdict
_run "skip-on-failure: unset LOG_FILE returns 0" test_skip_no_log_file
_run "non-integer criteria fallback to defaults" test_non_integer_criteria_fallback
_run "JSON payload has all required fields" test_json_validity
_run "set -e exit-code parity preserved" test_set_e_exit_code_parity
_run "T5: score clamped above 1.0 (5/3→1.0)" test_score_clamped_above_one
_run "T5: negative criteria score clamped" test_score_clamped_below_zero
_run "F8: PASS score always 1.0 regardless of criteria" test_pass_score_clamped
_run "T3: write failure is fail-open (unwritable dir)" test_write_failure_fail_open
_run "F4: guarded append survives directory LOG_FILE" test_fail_open_guarded_append
_run "F8: score never exceeds 1.0 (10/3→1.0)" test_score_never_above_one
_run "FAIL with zero total criteria scores 0.0" test_fail_zero_total_div_by_zero
_run "F9: confidence parity — Smooth=0.90" test_confidence_parity_smooth
_run "F9: confidence parity — unknown outcome=0.70" test_confidence_unknown_outcome

echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ] || exit 1
