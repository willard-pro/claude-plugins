#!/usr/bin/env bash
# inspect-verifiers.sh — Deterministic verifier inspection for ticket-auto-pipeline.
# Phase 1 of the RLVR program.
#
# Provides bash-side pattern detection so verdict computation is deterministic,
# not LLM-dependent. The guidance-extractor-agent still writes the final
# META|phase-inspector line, but the router can validate/correct it using
# the output of this module.
#
# Usage: source this file, then call inspect_verifiers.
#
#   inspect_verifiers '<json-array>' '<has_return_incomplete>' ['<phase>']
#
# Prints JSON to stdout:
#   {"verdict":"PASS|WARN|FAIL","signals":N,"patterns":[...],"detail":"..."}
#
# All failure paths return 0 and print a valid JSON skip object.
# Shell flags intentionally NOT set — this is a sourceable library.

# ── Primary function ───────────────────────────────────────────────────────────

inspect_verifiers() {
  local _vr_json="$1"
  local _has_return_incomplete="${2:-false}"
  local _phase="${3:-unknown}"

  # Validate input
  if [ -z "$_vr_json" ] || [ "$_vr_json" = "[]" ]; then
    printf '{"verdict":"WARN","signals":0,"detail":"No verifier results to inspect","patterns":[]}\n'
    return 0
  fi

  # Validate JSON is parseable
  if ! command -v jq >/dev/null 2>&1; then
    printf '{"verdict":"WARN","signals":0,"detail":"jq not available — cannot inspect verifiers","patterns":[]}\n'
    return 0
  fi

  if ! echo "$_vr_json" | jq -e . >/dev/null 2>&1; then
    printf '{"verdict":"WARN","signals":0,"detail":"Unparseable verifier results","patterns":[]}\n'
    return 0
  fi

  # ── Pattern detection ──────────────────────────────────────────────────
  local _patterns_json="[]"
  local _signals=0
  local _max_severity=0 # 0=PASS, 1=WARN, 2=FAIL

  # Helper: extract all verdicts
  local _verdicts
  _verdicts=$(echo "$_vr_json" | jq -r '[.[].verdict] | unique | .[]' 2>/dev/null || true)

  # Helper: extract verifiers with criteria_total
  local _verifiers_with_criteria
  _verifiers_with_criteria=$(echo "$_vr_json" | jq -r '[.[] | {id: .verifier, verdict: .verdict, criteria_total: (.criteria_total // 0)}]' 2>/dev/null || true)

  # ── Pattern 1: flaky_tests (WARN) ─────────────────────────────────────
  # PASS verifier + FAIL verifier in the same result set
  local _has_pass _has_fail
  _has_pass=$(echo "$_verdicts" | grep -q "PASS" && echo "true" || echo "false")
  _has_fail=$(echo "$_verdicts" | grep -q "FAIL" && echo "true" || echo "false")

  if [ "$_has_pass" = "true" ] && [ "$_has_fail" = "true" ]; then
    local _flaky_evidence
    _flaky_evidence=$(echo "$_vr_json" | jq -r '
      (.[] | select(.verdict == "PASS") | .verifier) as $pass_id |
      (.[] | select(.verdict == "FAIL") | .verifier) as $fail_id |
      "\($pass_id) PASS but \($fail_id) FAIL — possible flaky test"
    ' 2>/dev/null | head -1 || echo "PASS+FAIL verdict pair detected")
    _patterns_json=$(echo "$_patterns_json" | jq -c --arg evidence "$_flaky_evidence" \
      '. + [{"pattern":"flaky_tests","severity":"warn","evidence":$evidence}]' 2>/dev/null || echo "$_patterns_json")
    _signals=$((_signals + 1))
    [ "$_max_severity" -lt 1 ] && _max_severity=1
  fi

  # ── Pattern 2: missing_requirement (WARN) ─────────────────────────────
  # Review verifier PASS + critique/audit verifier WARN/FAIL
  local _has_review_pass _has_critique_warn
  _has_review_pass=$(echo "$_vr_json" | jq -r '
    [.[] | select((.verifier | test("review|pr_review")) and .verdict == "PASS")] | length
  ' 2>/dev/null || echo "0")
  _has_critique_warn=$(echo "$_vr_json" | jq -r '
    [.[] | select((.verifier | test("critique|audit")) and (.verdict == "WARN" or .verdict == "FAIL"))] | length
  ' 2>/dev/null || echo "0")

  if [ "$_has_review_pass" -gt 0 ] && [ "$_has_critique_warn" -gt 0 ]; then
    local _missing_evidence
    _missing_evidence=$(echo "$_vr_json" | jq -r '
      (.[] | select((.verifier | test("review|pr_review")) and .verdict == "PASS") | .verifier) as $rev |
      (.[] | select((.verifier | test("critique|audit")) and (.verdict == "WARN" or .verdict == "FAIL")) | "\(.verifier) \(.verdict)") as $crit |
      "\($rev) PASS but \($crit) — possible missed requirement"
    ' 2>/dev/null | head -1 || echo "Review/critique verdict mismatch detected")
    _patterns_json=$(echo "$_patterns_json" | jq -c --arg evidence "$_missing_evidence" \
      '. + [{"pattern":"missing_requirement","severity":"warn","evidence":$evidence}]' 2>/dev/null || echo "$_patterns_json")
    _signals=$((_signals + 1))
    [ "$_max_severity" -lt 1 ] && _max_severity=1
  fi

  # ── Pattern 3: trivial_pass (WARN) ────────────────────────────────────
  # Non-gate verifier PASS with criteria_total between 1 and 1 (single criterion).
  # Exclude criteria_total=0 (outcome-scored) and known gate verifiers.
  local _trivial_count
  _trivial_count=$(echo "$_vr_json" | jq -r '
    [.[] | select(
      .verdict == "PASS" and
      (.criteria_total // 0) == 1 and
      (.verifier | test("gate_check|return_completeness") | not)
    )] | length
  ' 2>/dev/null || echo "0")

  if [ "$_trivial_count" -gt 0 ]; then
    local _trivial_ids
    _trivial_ids=$(echo "$_vr_json" | jq -r '
      [.[] | select(
        .verdict == "PASS" and
        (.criteria_total // 0) == 1 and
        (.verifier | test("gate_check|return_completeness") | not)
      ) | .verifier] | join(", ")
    ' 2>/dev/null || echo "unknown")
    local _trivial_evidence="${_trivial_ids} PASS with criteria_total=1 — verification too shallow"
    _patterns_json=$(echo "$_patterns_json" | jq -c --arg evidence "$_trivial_evidence" \
      '. + [{"pattern":"trivial_pass","severity":"warn","evidence":$evidence}]' 2>/dev/null || echo "$_patterns_json")
    _signals=$((_signals + 1))
    [ "$_max_severity" -lt 1 ] && _max_severity=1
  fi

  # ── Pattern 4: verdict_disagreement (WARN) ────────────────────────────
  # At least one PASS AND at least one FAIL or BLOCK in the same set
  local _has_block
  _has_block=$(echo "$_verdicts" | grep -q "BLOCK" && echo "true" || echo "false")

  # Already detected by flaky_tests for PASS+FAIL; also check PASS+BLOCK
  if [ "$_has_pass" = "true" ] && [ "$_has_block" = "true" ]; then
    # Only emit verdict_disagreement if flaky_tests didn't already fire for PASS+FAIL
    if ! echo "$_patterns_json" | jq -e '.[] | select(.pattern == "flaky_tests")' >/dev/null 2>&1; then
      local _disagree_evidence
      _disagree_evidence=$(echo "$_vr_json" | jq -r '
        [.[] | "\(.verifier)=\(.verdict)"] | join(", ")
      ' 2>/dev/null || echo "verdicts diverge")
      _patterns_json=$(echo "$_patterns_json" | jq -c --arg evidence "$_disagree_evidence" \
        '. + [{"pattern":"verdict_disagreement","severity":"warn","evidence":$evidence}]' 2>/dev/null || echo "$_patterns_json")
      _signals=$((_signals + 1))
      [ "$_max_severity" -lt 1 ] && _max_severity=1
    fi
  fi

  # ── Pattern 5: incomplete_implementation (WARN) ───────────────────────
  # PASS verifier + RETURN_INCOMPLETE present
  if [ "$_has_pass" = "true" ] && [ "$_has_return_incomplete" = "true" ]; then
    local _incomplete_evidence
    _incomplete_evidence=$(echo "$_vr_json" | jq -r '
      [.[] | select(.verdict == "PASS") | .verifier] | join(", ")
    ' 2>/dev/null || echo "unknown")
    _incomplete_evidence="${_incomplete_evidence} PASS but RETURN_INCOMPLETE gate-warn present — unchecked boxes remain"
    _patterns_json=$(echo "$_patterns_json" | jq -c --arg evidence "$_incomplete_evidence" \
      '. + [{"pattern":"incomplete_implementation","severity":"warn","evidence":$evidence}]' 2>/dev/null || echo "$_patterns_json")
    _signals=$((_signals + 1))
    [ "$_max_severity" -lt 1 ] && _max_severity=1
  fi

  # ── Verdict computation ────────────────────────────────────────────────
  local _verdict
  case "$_max_severity" in
  0) _verdict="PASS" ;;
  1) _verdict="WARN" ;;
  *) _verdict="FAIL" ;;
  esac

  # ── Build detail string ────────────────────────────────────────────────
  local _detail
  if [ "$_signals" -eq 0 ]; then
    _detail="All verifiers clean for ${_phase}"
  elif [ "$_signals" -eq 1 ]; then
    local _pattern_name
    _pattern_name=$(echo "$_patterns_json" | jq -r '.[0].pattern' 2>/dev/null || echo "unknown")
    _detail="1 pattern detected: ${_pattern_name}"
  else
    local _pattern_names
    _pattern_names=$(echo "$_patterns_json" | jq -r '[.[].pattern] | join(", ")' 2>/dev/null || echo "multiple")
    _detail="${_signals} patterns detected: ${_pattern_names}"
  fi
  # Enforce 200-char limit
  if [ "${#_detail}" -gt 200 ]; then
    _detail="${_detail:0:197}..."
  fi

  # ── Assemble and emit result ───────────────────────────────────────────
  local _result
  _result=$(jq -n \
    --arg verdict "$_verdict" \
    --argjson signals "$_signals" \
    --arg detail "$_detail" \
    --argjson patterns "$_patterns_json" \
    '{verdict: $verdict, signals: $signals, detail: $detail, patterns: $patterns}' 2>/dev/null)

  if [ -n "$_result" ]; then
    echo "$_result"
  else
    printf '{"verdict":"WARN","signals":0,"detail":"Verdict assembly failed","patterns":[]}\n'
  fi

  return 0
}

# ── Validation helper (P1-5: router-side agent output correction) ──────────────

# validate_phase_inspector takes the agent's claimed META|phase-inspector JSON
# and the deterministic inspect_verifiers output, and returns the corrected
# verdict line (or the original if valid). This closes the determinism boundary:
# the agent can write whatever it wants, but bash has the final word.
#
# Usage: validate_phase_inspector '<agent_json>' '<inspect_json>' '<phase>'
# Prints the final (possibly corrected) JSON for the META|phase-inspector line.

validate_phase_inspector() {
  local _agent_json="$1"
  local _inspect_json="$2"
  local _phase="${3:-unknown}"

  # If agent output is unparseable, use the deterministic result
  if [ -z "$_agent_json" ] || ! echo "$_agent_json" | jq -e . >/dev/null 2>&1; then
    echo "$_inspect_json" | jq -c --arg phase "$_phase" \
      '. + {phase: $phase, verifiers_consulted: [], bash_validated: true, agent_overridden: "unparseable"}' 2>/dev/null ||
      printf '{"phase":"%s","verdict":"WARN","signals":0,"detail":"Agent output unparseable","verifiers_consulted":[],"patterns":[],"bash_validated":true}\n' "$_phase"
    return 0
  fi

  # Extract agent's claimed verdict and patterns
  local _agent_verdict _agent_signals
  _agent_verdict=$(echo "$_agent_json" | jq -r '.verdict // "WARN"' 2>/dev/null || echo "WARN")
  _agent_signals=$(echo "$_agent_json" | jq -r '.signals // 0' 2>/dev/null || echo "0")

  # Extract deterministic verdict and signals
  local _det_verdict _det_signals
  _det_verdict=$(echo "$_inspect_json" | jq -r '.verdict // "WARN"' 2>/dev/null || echo "WARN")
  _det_signals=$(echo "$_inspect_json" | jq -r '.signals // 0' 2>/dev/null || echo "0")

  # If agent and deterministic agree on verdict, trust agent's detail/patterns
  if [ "$_agent_verdict" = "$_det_verdict" ] && [ "$_agent_signals" = "$_det_signals" ]; then
    echo "$_agent_json" | jq -c --arg phase "$_phase" \
      '. + {phase: $phase, bash_validated: true}' 2>/dev/null || echo "$_inspect_json"
    return 0
  fi

  # Mismatch: use deterministic result, preserve agent's detail if compatible
  local _agent_detail
  _agent_detail=$(echo "$_agent_json" | jq -r '.detail // ""' 2>/dev/null || echo "")
  local _agent_consulted
  _agent_consulted=$(echo "$_agent_json" | jq -r '.verifiers_consulted // []' 2>/dev/null || echo "[]")

  echo "$_inspect_json" | jq -c \
    --arg phase "$_phase" \
    --arg agent_verdict "$_agent_verdict" \
    --argjson agent_signals "$_agent_signals" \
    --arg agent_detail "$_agent_detail" \
    --argjson agent_consulted "$_agent_consulted" \
    '. + {
      phase: $phase,
      verifiers_consulted: $agent_consulted,
      bash_validated: true,
      agent_overridden: true,
      agent_claim: {verdict: $agent_verdict, signals: $agent_signals, detail: $agent_detail}
    }' 2>/dev/null || echo "$_inspect_json"

  return 0
}
