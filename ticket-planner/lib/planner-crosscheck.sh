#!/usr/bin/env bash
# planner-crosscheck.sh — Crosscheck phase orchestrator (issue #178).
#
# Crosscheck is the phase between Consensus and EpicGen: the last artifact-only
# phase, and the first point where any script compares the artifacts against
# each other and against the live repo rather than validating one file in
# isolation. It is deterministic bash, not an agent — nothing here reasons
# about content, it runs the existing linters and records what they found.
#
# Wires in the check families that exist today:
#   - planner-crosscheck-citations.sh   (#172 — citation + precedent grep)
#   - planner-crosscheck-propagation.sh (#173 — cross-ticket propagation)
#   - planner-crosscheck-bypass.sh      (#174 — bypass sweep + discovery gap)
#   - planner-crosscheck-contracts.sh   (#175 — cross-initiative contract shape)
#   - planner-crosscheck-signals.sh     (#220 — uniform per-ticket Signals blocks)
#   - planner-crosscheck-deps.sh        (#221 — dangling blocked-by references)
#
# Adding a check later means adding one more call in planner_crosscheck_run
# and, if it can emit a non-blocking finding, adding its codes to
# PLANNER_CROSSCHECK_WARN_CODES below.
#
# Every finding is written to state.log as its own line, in the format #176
# specifies:
#
#   {ISO8601}|META|crosscheck|fail|{CODE} {message}
#
# `META|<step>|fail` with the code as the first whitespace-delimited token of
# the message is exactly the shape ticket-retro's failure-histogram parser
# already reads (see #177) — no retro-side change needed once it is pointed
# at planner state logs.
#
# The phase's own progress marker is a normal Crosscheck|check|{start,done,
# fail} triplet, so planner_position_derive, planner_phase_fail_count and the
# rest of the state machine handle it exactly like every other phase — no
# special-casing needed there. What IS special-cased is the dispatch loop in
# SKILL.md: Crosscheck has no agent prompt (see planner_prompt_for_phase),
# so the loop calls planner_crosscheck_run directly instead of spawning an
# Agent, and treats a nonzero return as an immediate stop (not a retry) —
# retrying a deterministic check against unchanged artifacts cannot produce a
# different answer; only editing the artifacts and resuming can.
#
# A genuine-and-expected blocking finding (e.g. a documented ticket-count
# rescope already recorded in consensus.md, not a checker bug) is the one
# case retrying a deterministic check *can* legitimately change the outcome
# for — not by re-running the same linter, but by the operator recording an
# explicit override first. `resume <ID> --accept CODE:"reason"` (#222) writes
# META|crosscheck|accepted|<CODE> <reason> to state.log via
# planner_crosscheck_accept_set (SKILL.md step 2b, before the loop reaches
# Crosscheck again); _planner_crosscheck_emit_finding checks that record and
# treats a matching code as non-blocking on every subsequent run, recording
# each still-occurring instance as its own META|crosscheck|accepted entry so
# the audit trail — and the Completed phase's COMPLETED.md Warnings section,
# which reads the whole log — shows *why* it was allowed through, distinct
# from an automated pass.
#
# Sourceable library — no set -euo pipefail.

_PLANNER_CROSSCHECK_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

_planner_crosscheck_source_if_missing() {
  local name="$1" path="$2"
  if ! declare -f "$name" >/dev/null 2>&1; then
    [ -f "$path" ] && source "$path"
  fi
}

_planner_crosscheck_source_if_missing "planner_crosscheck_citations" \
  "${_PLANNER_CROSSCHECK_LIB_DIR}/planner-crosscheck-citations.sh"
_planner_crosscheck_source_if_missing "planner_crosscheck_propagation" \
  "${_PLANNER_CROSSCHECK_LIB_DIR}/planner-crosscheck-propagation.sh"
_planner_crosscheck_source_if_missing "planner_crosscheck_bypass" \
  "${_PLANNER_CROSSCHECK_LIB_DIR}/planner-crosscheck-bypass.sh"
_planner_crosscheck_source_if_missing "planner_crosscheck_contracts" \
  "${_PLANNER_CROSSCHECK_LIB_DIR}/planner-crosscheck-contracts.sh"
_planner_crosscheck_source_if_missing "planner_crosscheck_signals" \
  "${_PLANNER_CROSSCHECK_LIB_DIR}/planner-crosscheck-signals.sh"
_planner_crosscheck_source_if_missing "planner_crosscheck_deps" \
  "${_PLANNER_CROSSCHECK_LIB_DIR}/planner-crosscheck-deps.sh"
_planner_crosscheck_source_if_missing "planner_state_write" \
  "${_PLANNER_CROSSCHECK_LIB_DIR}/planner-state.sh"

# Codes that must NOT halt the run — logged as META|crosscheck|warn|info
# instead of META|crosscheck|fail|<code> (#176 AC4). Every code the
# citation/propagation families emit (CITATION_UNRESOLVED,
# CITATION_LINE_OUT_OF_RANGE, CITATION_SYMBOL_MISMATCH, PRECEDENT_NOT_FOUND,
# RESOLUTION_NOT_PROPAGATED, FORWARD_REF_UNFULFILLED, CARVE_SCOPE_LOST),
# #174's BYPASS_PATH_UNADDRESSED, #175's CONTRACT_MISMATCH /
# CONTRACT_CONSUMERS_UNNOTIFIED, #220's SIGNALS_UNIFORM, and #221's
# DANGLING_BLOCKED_BY block EpicGen per #176's table.
# DISCOVERY_GAP_UNRESOLVED and CONTRACT_UNDEFINED are warn-level: a declared
# exploration gap or an ambiguous upstream shape is a prompt for human
# judgment, not by itself proof of a defect.
PLANNER_CROSSCHECK_WARN_CODES="DISCOVERY_GAP_UNRESOLVED CONTRACT_UNDEFINED"

# Is <code> a warn-level code?
# Usage: _planner_crosscheck_is_warn_code <code>
_planner_crosscheck_is_warn_code() {
  case " ${PLANNER_CROSSCHECK_WARN_CODES} " in
  *" $1 "*) return 0 ;;
  *) return 1 ;;
  esac
}

# Codes the operator has explicitly accepted as genuine-and-expected for this
# initiative via `resume <ID> --accept CODE:"reason"` (#222) — e.g. a
# documented ticket-count rescope already recorded in consensus.md, not a
# checker bug. Persisted as META|crosscheck|accepted|<CODE> <reason> the
# moment the flag is parsed, before the dispatch loop reaches Crosscheck
# again (SKILL.md step 2b) — same disk-backed pattern as --create and
# --until, and the same governing principle from #144: nothing survives the
# dispatch loop's process boundary except what is written to the state log.
# A code accepted once stays accepted for the life of the initiative; there
# is no un-accept.
#
# Usage: planner_crosscheck_accept_set <initiative_id> <code> <reason>
planner_crosscheck_accept_set() {
  local initiative_id="$1" code="$2" reason="$3"
  planner_state_write "$initiative_id" "META" "crosscheck" "accepted" "${code} ${reason}"
}

# Usage: _planner_crosscheck_accepted_codes <initiative_id>
# Output (stdout): every accepted code, one per line, deduplicated.
_planner_crosscheck_accepted_codes() {
  local initiative_id="$1" log
  log=$(planner_state_log "$initiative_id")
  [ -f "$log" ] || return 0

  local line phase step status msg code
  while IFS='|' read -r _ts phase step status msg; do
    [ "$phase" = "META" ] || continue
    [ "$step" = "crosscheck" ] || continue
    [ "$status" = "accepted" ] || continue
    code=$(echo "$msg" | awk '{print $1}')
    [ -n "$code" ] && echo "$code"
  done <"$log" | sort -u
}

# Is <code> accepted for <initiative_id>?
# Usage: _planner_crosscheck_code_accepted <initiative_id> <code>
_planner_crosscheck_code_accepted() {
  local initiative_id="$1" code="$2" accepted
  accepted=$(_planner_crosscheck_accepted_codes "$initiative_id" | tr '\n' ' ')
  case " ${accepted}" in
  *" ${code} "*) return 0 ;;
  *) return 1 ;;
  esac
}

# Parse one finding line from a check family's stdout and write it to
# state.log in #176's format. The check families print:
#   planner-crosscheck-<family>: <CODE> <rest of message...>
# but also print non-finding summary lines in the same "prefix: text" shape
# (e.g. "planner-crosscheck-citations: 3 passed, 2 failed out of 5 files") —
# a real code is always upper-snake-case, which no summary line's first word
# is, so that's the discriminator.
# Usage: _planner_crosscheck_emit_finding <initiative_id> <finding_line>
# Returns: 0 if the finding was blocking, 1 if warn, 2 if not a finding line,
# 3 if the code was operator-accepted (#222).
_planner_crosscheck_emit_finding() {
  local initiative_id="$1" finding_line="$2"
  local body code message

  case "$finding_line" in
  *": "*) body="${finding_line#*: }" ;;
  *) return 2 ;;
  esac

  code=$(echo "$body" | awk '{print $1}')
  [[ "$code" =~ ^[A-Z][A-Z0-9_]*$ ]] || return 2
  message="${body#"$code" }"

  if _planner_crosscheck_is_warn_code "$code"; then
    planner_state_write "$initiative_id" "META" "crosscheck" "warn" "info ${code} ${message}"
    return 1
  fi

  if _planner_crosscheck_code_accepted "$initiative_id" "$code"; then
    planner_state_write "$initiative_id" "META" "crosscheck" "accepted" "${code} ${message}"
    return 3
  fi

  planner_state_write "$initiative_id" "META" "crosscheck" "fail" "${code} ${message}"
  return 0
}

# Run one check family, emitting a state-log event for every finding line it
# printed to stdout.
# Usage: _planner_crosscheck_run_family <initiative_id> <check_fn> [<check_fn_args...>]
# Output (stdout): "<blocking_count> <warn_count> <accepted_count>"
_planner_crosscheck_run_family() {
  local initiative_id="$1"
  shift
  local blocking=0 warn=0 accepted=0
  local line rc

  while IFS= read -r line; do
    [ -z "$line" ] && continue
    _planner_crosscheck_emit_finding "$initiative_id" "$line"
    rc=$?
    case "$rc" in
    0) blocking=$((blocking + 1)) ;;
    1) warn=$((warn + 1)) ;;
    3) accepted=$((accepted + 1)) ;;
    esac
  done < <("$@" 2>/dev/null)

  echo "$blocking $warn $accepted"
}

# Run the full Crosscheck phase for an initiative: both wired check families,
# emitting findings and the phase's own progress markers.
#
# Usage: planner_crosscheck_run <initiative_id>
# Returns: 0 if clean (or warn-only), 1 if any blocking finding was reported.
planner_crosscheck_run() {
  local initiative_id="$1"
  local total_blocking=0 total_warn=0 total_accepted=0
  local b w a

  planner_state_write "$initiative_id" "Crosscheck" "check" "start" "running citation + propagation + bypass + contracts + signals + deps checks"

  read -r b w a < <(_planner_crosscheck_run_family "$initiative_id" planner_crosscheck_citations "$initiative_id")
  total_blocking=$((total_blocking + b))
  total_warn=$((total_warn + w))
  total_accepted=$((total_accepted + a))

  read -r b w a < <(_planner_crosscheck_run_family "$initiative_id" planner_crosscheck_propagation "$initiative_id")
  total_blocking=$((total_blocking + b))
  total_warn=$((total_warn + w))
  total_accepted=$((total_accepted + a))

  read -r b w a < <(_planner_crosscheck_run_family "$initiative_id" planner_crosscheck_bypass "$initiative_id")
  total_blocking=$((total_blocking + b))
  total_warn=$((total_warn + w))
  total_accepted=$((total_accepted + a))

  read -r b w a < <(_planner_crosscheck_run_family "$initiative_id" planner_crosscheck_contracts "$initiative_id")
  total_blocking=$((total_blocking + b))
  total_warn=$((total_warn + w))
  total_accepted=$((total_accepted + a))

  read -r b w a < <(_planner_crosscheck_run_family "$initiative_id" planner_crosscheck_signals "$initiative_id")
  total_blocking=$((total_blocking + b))
  total_warn=$((total_warn + w))
  total_accepted=$((total_accepted + a))

  read -r b w a < <(_planner_crosscheck_run_family "$initiative_id" planner_crosscheck_deps "$initiative_id")
  total_blocking=$((total_blocking + b))
  total_warn=$((total_warn + w))
  total_accepted=$((total_accepted + a))

  if [ "$total_blocking" -gt 0 ]; then
    planner_state_write "$initiative_id" "Crosscheck" "check" "fail" \
      "${total_blocking} blocking finding(s), ${total_warn} warn, ${total_accepted} accepted — see META|crosscheck entries"
    echo "planner-crosscheck: ${total_blocking} blocking finding(s), ${total_warn} warn, ${total_accepted} accepted" >&2
    return 1
  fi

  planner_state_write "$initiative_id" "Crosscheck" "check" "done" \
    "clean (${total_warn} warn, ${total_accepted} accepted)"
  echo "planner-crosscheck: clean (${total_warn} warn, ${total_accepted} accepted)"
  return 0
}

# Summarize recorded Crosscheck findings for status reporting (#176 AC5).
# Scoped to the most recent Crosscheck attempt only (everything at or after
# the last "Crosscheck|check|start" marker) — resume re-runs the phase after
# the operator edits artifacts, and a fixed finding from an earlier attempt
# must not keep reporting as outstanding forever just because state.log is
# append-only. Reads directly from state.log; does not re-run the checks.
#
# Usage: planner_crosscheck_findings_summary <initiative_id>
# Output (stdout): one "<count> <blocking|warn|accepted> <CODE>" line per
# distinct code, sorted by count descending, followed by a "TOTAL: <n>
# blocking, <n> warn, <n> accepted" line. No output at all if Crosscheck has
# not run yet, or its most recent run recorded no findings.
planner_crosscheck_findings_summary() {
  local initiative_id="$1"
  local log
  log=$(planner_state_log "$initiative_id")
  [ -f "$log" ] || return 0

  local start_line
  start_line=$(grep -n '|Crosscheck|check|start|' "$log" | tail -1 | cut -d: -f1)
  [ -z "$start_line" ] && return 0

  local blocking_total=0 warn_total=0 accepted_total=0
  declare -A _cc_counts=()
  declare -A _cc_kind=()
  local line phase step status msg code

  while IFS= read -r line; do
    [ -z "$line" ] && continue
    IFS='|' read -r _ts phase step status msg <<<"$line"
    [ "$phase" = "META" ] || continue
    [ "$step" = "crosscheck" ] || continue

    case "$status" in
    fail)
      code=$(echo "$msg" | awk '{print $1}')
      [ -z "$code" ] && continue
      _cc_counts["$code"]=$((${_cc_counts["$code"]:-0} + 1))
      _cc_kind["$code"]="blocking"
      blocking_total=$((blocking_total + 1))
      ;;
    warn)
      # Warn findings are written as "info <CODE> <message>" — see
      # _planner_crosscheck_emit_finding.
      code=$(echo "$msg" | awk '{print $2}')
      [ -z "$code" ] && continue
      _cc_counts["$code"]=$((${_cc_counts["$code"]:-0} + 1))
      _cc_kind["$code"]="warn"
      warn_total=$((warn_total + 1))
      ;;
    accepted)
      # Operator-accepted findings (#222) are written as "<CODE> <message>",
      # same shape as `fail` — see _planner_crosscheck_emit_finding and
      # planner_crosscheck_accept_set.
      code=$(echo "$msg" | awk '{print $1}')
      [ -z "$code" ] && continue
      _cc_counts["$code"]=$((${_cc_counts["$code"]:-0} + 1))
      _cc_kind["$code"]="accepted"
      accepted_total=$((accepted_total + 1))
      ;;
    esac
  done < <(tail -n "+$((start_line + 1))" "$log")

  if [ "$blocking_total" -eq 0 ] && [ "$warn_total" -eq 0 ] && [ "$accepted_total" -eq 0 ]; then
    return 0
  fi

  for code in "${!_cc_counts[@]}"; do
    echo "${_cc_counts[$code]} ${_cc_kind[$code]} ${code}"
  done | sort -rn

  echo "TOTAL: ${blocking_total} blocking, ${warn_total} warn, ${accepted_total} accepted"
}

# ── Grouped finding report (#233) ───────────────────────────────────────────
#
# planner_crosscheck_findings_summary above answers "how many, of what code".
# That is the right shape for `status`, and the wrong shape for the thing an
# operator actually does after a blocking run: open one artifact at a time and
# fix every finding in it. Doing that from the raw log means re-reading
# `META|crosscheck|fail|CODE message` lines and re-deriving, per line, which
# file and which token they point at. planner_crosscheck_findings_report
# renders the same recorded data grouped file → code, with the offending
# citation/token kept inline and a canned one-line fix hint per code, so
# remediation cost tracks distinct defect classes rather than raw finding
# count.
#
# Presentation only. It re-reads the state log and never re-runs a check, so
# it cannot disagree with what Crosscheck actually recorded.

# Codes whose findings are inherently about a set of artifacts rather than one
# — grouping them under whichever filename happens to appear first in the
# message would point the operator at an arbitrary member of the set.
PLANNER_CROSSCHECK_CROSS_FILE_CODES="RESOLUTION_NOT_PROPAGATED CARVE_SCOPE_LOST SIGNALS_UNIFORM"

# One-line remediation hint per finding code. Deliberately canned and code-
# scoped: it says what shape the fix takes, not what the specific fix is —
# the message already carries the specifics.
# Usage: planner_crosscheck_fix_hint <code>
planner_crosscheck_fix_hint() {
  case "$1" in
  CITATION_UNRESOLVED)
    echo "path does not resolve under REPOS_ROOT — check for an annotation on the path side of \`Name:path\` (move it to the Name side), a stale path, or a file that needs a \`(new)\` marker"
    ;;
  CITATION_LINE_OUT_OF_RANGE)
    echo "the file resolved but the cited line is past its end — re-read the file and cite a real line, or drop the line number"
    ;;
  CITATION_SYMBOL_MISMATCH)
    echo "the named symbol is not within ${PLANNER_CROSSCHECK_SYMBOL_PROXIMITY:-40} lines of the cited line — cite the line the symbol is defined on, or fix the symbol name"
    ;;
  PRECEDENT_NOT_FOUND)
    echo "the identifier claimed as prior art has zero matches under REPOS_ROOT — quote an identifier that exists, or drop the precedent claim"
    ;;
  RESOLUTION_NOT_PROPAGATED)
    echo "a Consensus resolution reached some specs and not others — copy the resolved wording into the missing-it specs"
    ;;
  FORWARD_REF_UNFULFILLED)
    echo "the referenced spec never delivers the promised terms — add them there, or drop the forward reference"
    ;;
  CARVE_SCOPE_LOST)
    echo "the spec-file count no longer matches the ticket count Specify declared — record the rescope in consensus.md, or restore the missing spec"
    ;;
  BYPASS_PATH_UNADDRESSED)
    echo "a live code path matching this ticket's terms is covered by no spec — extend the spec's scope, or record the path as out of scope"
    ;;
  DISCOVERY_GAP_UNRESOLVED)
    echo "a gap Discovery declared is neither answered nor listed in proposal.md Out of Scope — resolve it, or scope it out explicitly"
    ;;
  CONTRACT_UNDEFINED)
    echo "new fields are declared without canonical names — name the structure's fields explicitly in the spec"
    ;;
  CONTRACT_MISMATCH)
    echo "two specs describe the same borrowed structure differently — align the two shapes, or rename one of them"
    ;;
  CONTRACT_CONSUMERS_UNNOTIFIED)
    echo "a structure retired here is still referenced by a consumer spec — update the consumer, or keep the field"
    ;;
  SIGNALS_UNIFORM)
    echo "these specs share a Signals block — Signals must reflect each spec's own discovery, so regenerate the duplicates"
    ;;
  DANGLING_BLOCKED_BY)
    echo "the blocked-by target matches no sibling spec (or is an ambiguous prefix) — use the exact spec slug, or an existing Linear issue ID"
    ;;
  *)
    echo "no canned hint for this code — read the finding message"
    ;;
  esac
}

# Shorten an artifact path for display: everything under the initiative's
# artifacts directory is shown relative to it (specs/vs-1.md), anything else
# is left alone.
# Usage: _planner_crosscheck_report_path <path>
_planner_crosscheck_report_path() {
  case "$1" in
  */artifacts/*) echo "${1##*/artifacts/}" ;;
  *) echo "$1" ;;
  esac
}

# Truncate a detail line so one long finding cannot swamp the report.
# Usage: _planner_crosscheck_report_trunc <text>
_planner_crosscheck_report_trunc() {
  local text="$1" width="${PLANNER_CROSSCHECK_REPORT_WIDTH:-160}"
  if [ "${#text}" -gt "$width" ]; then
    printf '%s...\n' "${text:0:width}"
  else
    printf '%s\n' "$text"
  fi
}

# Derive which artifact a finding is about, and the detail worth showing next
# to it, from the finding message with its code already stripped.
#
# The check families print two shapes. Most lead with the artifact locus —
# `<spec_file>:<line> → <token> (...)`, which is where citations, precedents,
# forward refs and discovery gaps put it. The rest name the artifact somewhere
# inside prose ("retired in vs-2.md without notifying ..."), where the first
# `.md`-suffixed token is always the file the fix belongs in. Anything with
# neither is reported ungrouped rather than guessed at.
#
# Fields are separated by \x1e (record separator) rather than a tab: the line
# number is empty for findings that name a file but no line, and a tab is an
# IFS-whitespace character, so `IFS=$'\t' read` would collapse the empty field
# and shift the detail into it.
#
# Usage: _planner_crosscheck_finding_locus <code> <message_body>
# Output (stdout): "<file><RS><line><RS><detail>"
_planner_crosscheck_finding_locus() {
  local code="$1" body="$2"
  local file="" line="" detail="$body" first tok

  case " ${PLANNER_CROSSCHECK_CROSS_FILE_CODES} " in
  *" ${code} "*)
    printf '%s\036%s\036%s\n' "(cross-file)" "" "$detail"
    return 0
    ;;
  esac

  first="${body%% *}"
  if [[ "$first" =~ ^(.+):([0-9]+)$ ]]; then
    file="${BASH_REMATCH[1]}"
    line="${BASH_REMATCH[2]}"
    detail="${body#"$first"}"
    detail="${detail# }"
    detail="${detail#→ }"
  else
    for tok in $body; do
      tok="${tok%,}"
      tok="${tok%)}"
      tok="${tok%:}"
      case "$tok" in
      *.md)
        file="$tok"
        break
        ;;
      esac
    done
  fi

  [ -n "$file" ] || file="(no file)"
  printf '%s\036%s\036%s\n' "$(_planner_crosscheck_report_path "$file")" "$line" "$detail"
}

# Render recorded Crosscheck findings grouped by artifact, then by code (#233).
# Scoped to the most recent Crosscheck attempt, exactly like
# planner_crosscheck_findings_summary — a finding fixed by an earlier resume
# must not reappear in the remediation list.
#
# Fields are peeled one at a time rather than with `IFS='|' read` because a
# finding message may legitimately contain a pipe (CONTRACT_MISMATCH separates
# its two quoted snippets with " | "), and splitting on every pipe would drop
# everything after the first one.
#
# Usage: planner_crosscheck_findings_report <initiative_id>
# Output (stdout): a header, one block per artifact, and a trailing TOTAL
# line. No output at all if Crosscheck has not run yet, or its most recent
# run recorded no findings.
planner_crosscheck_findings_report() {
  local initiative_id="$1"
  local log
  log=$(planner_state_log "$initiative_id")
  [ -f "$log" ] || return 0

  local start_line
  start_line=$(grep -n '|Crosscheck|check|start|' "$log" | tail -1 | cut -d: -f1)
  [ -z "$start_line" ] && return 0

  declare -A _ccr_blocking=()
  declare -A _ccr_warn=()
  declare -A _ccr_accepted=()
  declare -A _ccr_details=()
  declare -A _ccr_files=()
  declare -A _ccr_codes=()
  local blocking_total=0 warn_total=0 accepted_total=0
  local line rest phase step status msg code body kind key file lnum detail

  while IFS= read -r line; do
    [ -z "$line" ] && continue
    case "$line" in
    *"|"*"|"*"|"*"|"*) ;;
    *) continue ;;
    esac

    rest="${line#*|}"
    phase="${rest%%|*}"
    rest="${rest#*|}"
    step="${rest%%|*}"
    rest="${rest#*|}"
    status="${rest%%|*}"
    msg="${rest#*|}"

    [ "$phase" = "META" ] || continue
    [ "$step" = "crosscheck" ] || continue

    case "$status" in
    fail)
      kind="blocking"
      body="$msg"
      ;;
    accepted)
      kind="accepted"
      body="$msg"
      ;;
    warn)
      # Warn findings are written as "info <CODE> <message>" — see
      # _planner_crosscheck_emit_finding.
      kind="warn"
      body="${msg#info }"
      ;;
    *) continue ;;
    esac

    code="${body%% *}"
    [ -n "$code" ] || continue
    body="${body#"$code"}"
    body="${body# }"

    IFS=$'\x1e' read -r file lnum detail < <(_planner_crosscheck_finding_locus "$code" "$body")
    key="${file}"$'\x1f'"${code}"
    _ccr_files["$file"]=1
    _ccr_codes["$code"]=1
    _ccr_details["$key"]="${_ccr_details["$key"]:-}${lnum}"$'\x1e'"${detail}"$'\n'

    case "$kind" in
    blocking)
      _ccr_blocking["$key"]=$((${_ccr_blocking["$key"]:-0} + 1))
      blocking_total=$((blocking_total + 1))
      ;;
    warn)
      _ccr_warn["$key"]=$((${_ccr_warn["$key"]:-0} + 1))
      warn_total=$((warn_total + 1))
      ;;
    accepted)
      _ccr_accepted["$key"]=$((${_ccr_accepted["$key"]:-0} + 1))
      accepted_total=$((accepted_total + 1))
      ;;
    esac
  done < <(tail -n "+$((start_line + 1))" "$log")

  if [ "$blocking_total" -eq 0 ] && [ "$warn_total" -eq 0 ] && [ "$accepted_total" -eq 0 ]; then
    return 0
  fi

  echo "Crosscheck findings — ${initiative_id} (most recent attempt)"

  # Real artifacts first, alphabetically; the two pseudo-groups last, because
  # they are the findings with no single file to open.
  local -a ordered=()
  mapfile -t ordered < <(
    for file in "${!_ccr_files[@]}"; do
      case "$file" in
      "(cross-file)" | "(no file)") continue ;;
      esac
      printf '%s\n' "$file"
    done | LC_ALL=C sort
  )
  for file in "(cross-file)" "(no file)"; do
    [ -n "${_ccr_files["$file"]:-}" ] && ordered+=("$file")
  done

  local -a codes=() parts=()
  local label
  for file in "${ordered[@]}"; do
    echo ""
    echo "$file"

    mapfile -t codes < <(
      for key in "${!_ccr_details[@]}"; do
        [ "${key%%$'\x1f'*}" = "$file" ] || continue
        printf '%s\n' "${key#*$'\x1f'}"
      done | LC_ALL=C sort
    )

    for code in "${codes[@]}"; do
      key="${file}"$'\x1f'"${code}"
      parts=()
      [ "${_ccr_blocking["$key"]:-0}" -gt 0 ] && parts+=("${_ccr_blocking["$key"]} blocking")
      [ "${_ccr_warn["$key"]:-0}" -gt 0 ] && parts+=("${_ccr_warn["$key"]} warn")
      [ "${_ccr_accepted["$key"]:-0}" -gt 0 ] && parts+=("${_ccr_accepted["$key"]} accepted")
      label=$(
        IFS=,
        echo "${parts[*]}"
      )
      label="${label//,/, }"
      echo "  ${code} — ${label}"
      echo "    fix: $(planner_crosscheck_fix_hint "$code")"

      while IFS=$'\x1e' read -r lnum detail; do
        [ -z "${lnum}${detail}" ] && continue
        if [ -n "$lnum" ]; then
          _planner_crosscheck_report_trunc "    L${lnum}  ${detail}"
        else
          _planner_crosscheck_report_trunc "    ${detail}"
        fi
      done <<<"${_ccr_details["$key"]}"
    done
  done

  echo ""
  echo "TOTAL: ${blocking_total} blocking, ${warn_total} warn, ${accepted_total} accepted across ${#ordered[@]} artifact group(s), ${#_ccr_codes[@]} code(s)"
  return 0
}
