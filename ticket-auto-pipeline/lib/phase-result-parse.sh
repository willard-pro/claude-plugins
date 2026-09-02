#!/usr/bin/env bash
# phase-result-parse.sh — deterministic parser for the `=== PHASE_RESULT ===` block
# a loop-bearing phase agent appends to its return text.
#
# Extracts the block from a captured-return file, parses its `KEY: value` body,
# validates it against docs/phase-result-schema.md, serializes canonical JSON with
# jq, and appends `META|phase-result|info|{json}` to the pipeline log.
#
# Tolerant at the transport boundary (whitespace, CRLF, blank lines, field order,
# unknown fields), strict at the contract boundary (enums, required fields, types,
# closing marker). A rejection degrades the claim to `claimed_verdict=UNKNOWN`; it
# never halts the pipeline and never emits a success object.
#
# Exit-code idiom follows return-completeness-check.sh:
#   0 — a valid block was parsed (parse_status=ok)
#   1 — the claim is unverifiable (parse_status=invalid|absent); an UNKNOWN record
#       is still emitted and still logged. This is a normal outcome, not an error.
#   2 — the parser could not run (usage, unreadable file, jq missing). Nothing logged.
#
# Usable as a sourceable lib (`parse_phase_result`) and as a standalone CLI, so a
# consumer outside the router — a workflow script, a Python supervisor — can call the
# exact same logic instead of reimplementing it.
#
# -u (nounset) intentionally omitted: Claude Code shell snapshots inject
# ZSH_VERSION references that trigger false-positive "unbound variable"
# errors in this bash version when nounset is active. Repo convention.
set -eo pipefail

PHASE_RESULT_SCHEMA_VERSION=1

# Closed enums. Reused, not re-invented: VERDICT is the Phase 0 enum, VERIFIER is
# the 14 ids established by lib/verifier-result.sh call sites.
_PR_VERDICTS="PASS FAIL WARN BLOCK"
_PR_PHASES="IMPLEMENT VERIFY PR-REVIEW"
_PR_VERIFIERS="adversarial_review audit build_only critique gate_check implement_tests live_backend playwright_uat pr_review prescan_verify regression_guard return_completeness ticket_document ticket_retro"

_PR_REQUIRED="SCHEMA_VERSION PHASE VERIFIER VERDICT"
_PR_INT_FIELDS="SCHEMA_VERSION CRITERIA_MET CRITERIA_TOTAL ATTEMPT"
_PR_KNOWN="SCHEMA_VERSION PHASE VERIFIER VERDICT CRITERIA_MET CRITERIA_TOTAL ATTEMPT EVIDENCE UNADDRESSED"

_PR_OPEN_MARKER="=== PHASE_RESULT ==="
_PR_CLOSE_MARKER="=== END PHASE_RESULT ==="

_pr_usage() {
  cat >&2 <<'EOF'
Usage: phase-result-parse.sh --phase <PHASE> --return-file <path>
                             [--log-file <path>] [--ticket-dir <path>]

  --phase <PHASE>        Emitting phase: IMPLEMENT | VERIFY | PR-REVIEW. Required.
                         Always carried into the record, including on rejection,
                         so every entry is attributable without positional inference.
  --return-file <path>   Captured agent return text, normally
                         <ticket-dir>/logs/{TID}-{phase}-agent.log. Required.
  --log-file <path>      Pipeline log to append META|phase-result to. Falls back to
                         the LOG_FILE env var. Omit both to skip the log write.
  --ticket-dir <path>    Ticket workspace. Only used to resolve a relative
                         --return-file. Falls back to the current directory.

Exit: 0 valid block, 1 unverifiable claim (UNKNOWN), 2 parser could not run.
EOF
}

_pr_in_list() {
  # _pr_in_list <needle> <space-separated haystack>
  case " $2 " in *" $1 "*) return 0 ;; *) return 1 ;; esac
}

# Key charset check, forced to C collation.
#
# bash's [[ =~ ]] bracket expressions are locale-sensitive: under en_US.UTF-8
# (or any UTF-8 locale an operator's shell happens to carry) `[A-Z]` also
# matches accented uppercase letters, so `WEIRD` with an accented E would be
# accepted as a well-formed key on a workstation and rejected in CI, which runs
# under C. A contract rule that only fires in CI is not a contract rule.
#
# `local LC_ALL` is function-scoped and bash re-runs setlocale() both on the
# assignment and on return, so the caller's locale is untouched.
_pr_key_ok() {
  local LC_ALL=C
  [[ "$1" =~ ^[A-Z][A-Z0-9_]*$ ]]
}

# Reduce a capture file to the agent's return text, whatever envelope carries it.
#
# `claude -p --output-format json` — which is what fleetd already spawns workers
# with (fleet-controller/fleetd/supervisor.py:1375) — wraps the return in a JSON
# object whose `.result` is a *string*. Every newline the block depends on is
# then a literal \n escape, so line-oriented extraction sees one long line and
# reports `absent` on a perfectly valid emission. Unwrapping here rather than in
# each caller is what keeps the parser usable unchanged from the router, from
# fleet-controller, and from a bare `claude -p > file` redirect — none of them
# has to know which output mode produced the file it holds.
#
# Plain text is the common case and passes through untouched; anything jq cannot
# read as an envelope is treated as plain text rather than rejected.
_pr_unwrap() {
  local file="$1" out
  # `--output-format json`: one object, `.result` holds the return.
  out=$(jq -r 'if type == "object" and (.result | type) == "string"
               then .result else empty end' <"$file" 2>/dev/null) || out=""
  if [ -n "$out" ]; then
    printf '%s\n' "$out"
    return 0
  fi
  # `--output-format stream-json`: one object per line, the terminal one carries
  # `.result`. Take the last, matching the "last block wins" rule below.
  out=$(jq -sr '[.[] | select(type == "object" and (.result | type) == "string")
                | .result] | last // empty' <"$file" 2>/dev/null) || out=""
  if [ -n "$out" ]; then
    printf '%s\n' "$out"
    return 0
  fi
  cat -- "$file"
}

# Emit the canonical JSON record and append it to the pipeline log.
# All values are bound as jq arguments — never interpolated into a JSON string.
_pr_emit() {
  local status="$1" err="$2" phase="$3" verifier="$4" verdict="$5"
  local sver="$6" met="$7" total="$8" attempt="$9"
  local evidence="${10}" unaddressed="${11}" extra_json="${12}"
  local log_file="${13}"

  local json
  json=$(jq -nc \
    --argjson schema_version "$sver" \
    --arg phase "$phase" \
    --arg verifier "$verifier" \
    --arg claimed_verdict "$verdict" \
    --argjson criteria_met "$met" \
    --argjson criteria_total "$total" \
    --argjson attempt "$attempt" \
    --arg evidence "$evidence" \
    --arg unaddressed "$unaddressed" \
    --argjson extra "$extra_json" \
    --arg parse_status "$status" \
    --arg parse_error "$err" \
    '{schema_version: $schema_version, phase: $phase, verifier: $verifier,
      claimed_verdict: $claimed_verdict, criteria_met: $criteria_met,
      criteria_total: $criteria_total, attempt: $attempt, evidence: $evidence,
      unaddressed: $unaddressed, extra: $extra, parse_status: $parse_status,
      parse_error: $parse_error}' 2>/dev/null) || json=""

  if [ -z "$json" ] || ! printf '%s' "$json" | jq -e . >/dev/null 2>&1; then
    echo "[phase-result] WARN: jq serialization failed, nothing emitted" >&2
    return 2
  fi

  printf '%s\n' "$json"

  # F4 guard, copied from verifier-result.sh: an unwritable log degrades, it never
  # aborts the caller.
  if [ -n "$log_file" ]; then
    local iso
    iso=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    echo "${iso}|META|phase-result|info|${json}" >>"$log_file" || {
      echo "[phase-result] WARN: log write failed (LOG_FILE=${log_file})" >&2
    }
  fi
  return 0
}

# parse_phase_result --phase <P> --return-file <f> [--log-file <l>] [--ticket-dir <d>]
parse_phase_result() {
  local phase="" return_file="" log_file="${LOG_FILE:-}" ticket_dir=""

  while [ $# -gt 0 ]; do
    case "$1" in
    --phase)
      phase="${2:-}"
      shift 2
      ;;
    --return-file)
      return_file="${2:-}"
      shift 2
      ;;
    --log-file)
      log_file="${2:-}"
      shift 2
      ;;
    --ticket-dir)
      ticket_dir="${2:-}"
      shift 2
      ;;
    -h | --help)
      _pr_usage
      return 2
      ;;
    *)
      echo "[phase-result] ERROR: unknown argument '$1'" >&2
      _pr_usage
      return 2
      ;;
    esac
  done

  if [ -z "$phase" ] || [ -z "$return_file" ]; then
    echo "[phase-result] ERROR: --phase and --return-file are required" >&2
    _pr_usage
    return 2
  fi

  if ! command -v jq >/dev/null 2>&1; then
    echo "[phase-result] ERROR: jq not available" >&2
    return 2
  fi

  # --phase names the record's owner, so it must itself be a real phase. A typo
  # here would put an unattributable row on the log.
  if ! _pr_in_list "$phase" "$_PR_PHASES"; then
    echo "[phase-result] ERROR: --phase '$phase' is not a loop-bearing phase ($_PR_PHASES)" >&2
    return 2
  fi

  case "$return_file" in
  /*) ;;
  *) [ -n "$ticket_dir" ] && return_file="${ticket_dir%/}/$return_file" ;;
  esac

  if [ ! -f "$return_file" ]; then
    echo "[phase-result] ERROR: return file not found: $return_file" >&2
    return 2
  fi

  local body status="ok" err=""

  # ── extract ────────────────────────────────────────────────────────────────
  # Strip CR so CRLF input is indistinguishable from LF input, then take the LAST
  # block: capture_agent_result appends retried attempts to one file, and the
  # current attempt is the one at the end.
  local _extract_rc=0
  body=$(_pr_unwrap "$return_file" | tr -d '\r' | awk -v mopen="$_PR_OPEN_MARKER" -v mclose="$_PR_CLOSE_MARKER" '
    function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
    trim($0) == mopen  { collecting = 1; buf = ""; next }
    collecting && trim($0) == mclose { collecting = 0; closed = 1; last = buf; next }
    collecting { buf = buf $0 "\n"; next }
    END {
      # Order matters: a truncated LAST block must be reported as truncated, not
      # silently answered with an earlier complete one. A stale claim read as
      # current is worse than no claim.
      if (collecting) { exit 3 }   # opened but never closed
      if (closed)     { printf "%s", last; exit 0 }
      exit 4                        # no opening marker at all
    }
  ') || _extract_rc=$?

  case "$_extract_rc" in
  0) ;;
  3)
    status="invalid"
    err="missing closing marker"
    ;;
  4)
    status="absent"
    err="no PHASE_RESULT block in return"
    ;;
  *)
    status="invalid"
    err="block extraction failed (awk exit ${_extract_rc})"
    ;;
  esac

  # An opened-and-closed but empty block carries no claim.
  if [ "$status" = "ok" ] && [ -z "${body//[[:space:]]/}" ]; then
    status="invalid"
    err="empty block"
  fi

  local sver=0 verifier="" verdict="UNKNOWN" met=0 total=0 attempt=0
  local evidence="" unaddressed="" extra_json="{}"

  if [ "$status" = "ok" ]; then
    # ── parse ────────────────────────────────────────────────────────────────
    local -A fields=()
    local -a extra_keys=() extra_vals=()
    local seen_keys=""
    local line key value

    while IFS= read -r line; do
      # Blank lines inside the block are cosmetic.
      [ -z "${line//[[:space:]]/}" ] && continue

      if [[ "$line" != *:* ]]; then
        status="invalid"
        err="malformed line (no ':'): ${line}"
        break
      fi

      key="${line%%:*}"
      value="${line#*:}"
      # Trim surrounding whitespace on both halves. The value keeps any interior
      # colons, quotes, `$`, backticks — it is data, never re-parsed, never eval'd.
      key="${key#"${key%%[![:space:]]*}"}"
      key="${key%"${key##*[![:space:]]}"}"
      value="${value#"${value%%[![:space:]]*}"}"
      value="${value%"${value##*[![:space:]]}"}"

      if ! _pr_key_ok "$key"; then
        status="invalid"
        err="key '${key}' does not match [A-Z][A-Z0-9_]*"
        break
      fi

      # A repeated key is ambiguity about the claim, not a transport quirk, so
      # it is rejected rather than tolerated. Last-write-wins here would let
      # `VERDICT: FAIL` followed by `VERDICT: PASS` log a clean PASS — the exact
      # coercion the closed VERDICT enum exists to prevent, arriving through two
      # individually well-formed lines instead of one malformed one.
      if _pr_in_list "$key" "$seen_keys"; then
        status="invalid"
        err="duplicate field: ${key}"
        break
      fi
      seen_keys="$seen_keys $key"

      if _pr_in_list "$key" "$_PR_KNOWN"; then
        fields["$key"]="$value"
      else
        # Unknown fields are recorded, never fatal — a future emitter adding a
        # field must not break a current parser.
        extra_keys+=("$key")
        extra_vals+=("$value")
      fi
    done <<<"$body"
  fi

  # ── validate ───────────────────────────────────────────────────────────────
  if [ "$status" = "ok" ]; then
    local f
    for f in $_PR_REQUIRED; do
      if [ -z "${fields[$f]+set}" ]; then
        status="invalid"
        err="missing required field: ${f}"
        break
      fi
    done
  fi

  if [ "$status" = "ok" ]; then
    local f
    for f in $_PR_INT_FIELDS; do
      if [ -n "${fields[$f]+set}" ] && ! [[ "${fields[$f]}" =~ ^[0-9]+$ ]]; then
        status="invalid"
        err="field ${f} is not an integer: ${fields[$f]}"
        break
      fi
    done
  fi

  if [ "$status" = "ok" ] && [ "${fields[SCHEMA_VERSION]}" != "$PHASE_RESULT_SCHEMA_VERSION" ]; then
    status="invalid"
    err="unsupported SCHEMA_VERSION: ${fields[SCHEMA_VERSION]} (parser supports ${PHASE_RESULT_SCHEMA_VERSION})"
  fi

  if [ "$status" = "ok" ] && ! _pr_in_list "${fields[VERDICT]}" "$_PR_VERDICTS"; then
    status="invalid"
    err="VERDICT '${fields[VERDICT]}' is not in the enum ($_PR_VERDICTS)"
  fi

  if [ "$status" = "ok" ] && ! _pr_in_list "${fields[PHASE]}" "$_PR_PHASES"; then
    status="invalid"
    err="PHASE '${fields[PHASE]}' is not in the enum ($_PR_PHASES)"
  fi

  if [ "$status" = "ok" ] && ! _pr_in_list "${fields[VERIFIER]}" "$_PR_VERIFIERS"; then
    status="invalid"
    err="VERIFIER '${fields[VERIFIER]}' is not an established verifier id"
  fi

  if [ "$status" = "ok" ] && [ "${fields[PHASE]}" != "$phase" ]; then
    status="invalid"
    err="block PHASE '${fields[PHASE]}' does not match the invoking phase '${phase}'"
  fi

  if [ "$status" = "ok" ]; then
    sver="${fields[SCHEMA_VERSION]}"
    verifier="${fields[VERIFIER]}"
    verdict="${fields[VERDICT]}"
    met="${fields[CRITERIA_MET]:-0}"
    total="${fields[CRITERIA_TOTAL]:-0}"
    attempt="${fields[ATTEMPT]:-1}"
    evidence="${fields[EVIDENCE]:-}"
    unaddressed="${fields[UNADDRESSED]:-}"

    if [ "${#extra_keys[@]}" -gt 0 ]; then
      local i args=()
      for i in "${!extra_keys[@]}"; do
        args+=(--arg "k$i" "${extra_keys[$i]}" --arg "v$i" "${extra_vals[$i]}")
      done
      local filter="{"
      for i in "${!extra_keys[@]}"; do
        [ "$i" -gt 0 ] && filter="$filter,"
        filter="$filter(\$k$i): \$v$i"
      done
      filter="$filter}"
      extra_json=$(jq -nc "${args[@]}" "$filter" 2>/dev/null) || extra_json="{}"
    fi
  else
    # Rejection: every claim field stays at its default and the verdict is UNKNOWN.
    # Never a partially-populated record — a half-read claim reads as a real one.
    echo "[phase-result] ${status}: ${err} (phase=${phase}, file=${return_file})" >&2
  fi

  _pr_emit "$status" "$err" "$phase" "$verifier" "$verdict" \
    "$sver" "$met" "$total" "$attempt" \
    "$evidence" "$unaddressed" "$extra_json" "$log_file" || return 2

  [ "$status" = "ok" ] && return 0
  return 1
}

# Standalone CLI. Sourcing the file defines the function without running it.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  parse_phase_result "$@"
  exit $?
fi
