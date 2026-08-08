#!/usr/bin/env bash
# pipeline-postmortem.sh — end-of-run analysis for every pipeline exit path.
# RLVR Phase 3: reads standardized verifier results and phase-inspector
# verdicts, produces deterministic error signatures, files GitHub issues
# for systemic problems, and writes CORRECTIONS blocks for filed patterns.
#
# Usage: pipeline-postmortem.sh {TICKET_ID} --exit-code {CODE}
#
# Called by the router's EXIT trap on every exit path (gate-stop,
# VERIFY_EXHAUSTED, PR_FEEDBACK_EXHAUSTED, router-error, STEP_6).
# Also called by fleet-controller on fleet-kill (opt-in).
#
# Exit code: always 0 (fail-soft — analysis failures never block the trap).
#
# Design invariants (from ticket-auto-rlvr-program.md):
#   1. Determinism boundary preserved — bash orchestrates, agents reason.
#   2. Additive only — new META entries, no existing logic changed.
#   3. Fail-soft everywhere — absent channels degrade to "no signal".
#   4. One confidence scale — 0.0–1.0 _compute_actual_confidence.
#   5. Independent shipping — benefits the system immediately.
#
# -u intentionally omitted: Claude Code shell snapshots inject ZSH_VERSION
# references that trigger false-positive "unbound variable" errors.
set -eo pipefail

# ── Configuration ────────────────────────────────────────────────────────────────

POSTMORTEM_ENABLED="${POSTMORTEM_ENABLED:-true}"
POSTMORTEM_FILE_ISSUES="${POSTMORTEM_FILE_ISSUES:-false}"
POSTMORTEM_ISSUES_PER_HOUR="${POSTMORTEM_ISSUES_PER_HOUR:-5}"
GITHUB_ISSUE_REPO="${GITHUB_ISSUE_REPO:-willard-pro/claude-plugins}"
STATE_BASE="${HOME}/.claude/state/ticket-auto/postmortem"

# Resolve lib paths (runtime: ~/.claude/skills/lib/; dev: relative to this script)
_resolve_lib() {
  local lib_name="$1"
  if [ -f "$HOME/.claude/skills/lib/${lib_name}" ]; then
    echo "$HOME/.claude/skills/lib/${lib_name}"
  else
    local _script_dir
    _script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    echo "${_script_dir}/${lib_name}"
  fi
}

# ── Argument parsing ─────────────────────────────────────────────────────────────

TICKET_ID=""
EXIT_CODE=""

while [ $# -gt 0 ]; do
  case "$1" in
  --exit-code)
    EXIT_CODE="$2"
    shift 2
    ;;
  *)
    if [ -z "$TICKET_ID" ]; then
      TICKET_ID="$1"
    fi
    shift
    ;;
  esac
done

# ── Fail-soft: disabled gate ─────────────────────────────────────────────────────

if [ "${POSTMORTEM_ENABLED:-true}" != "true" ]; then
  exit 0
fi

if [ -z "$TICKET_ID" ]; then
  echo "[pipeline-postmortem] WARN: no TICKET_ID provided" >&2
  exit 0
fi

EXIT_CODE="${EXIT_CODE:-0}"

# ── Resolve log paths ────────────────────────────────────────────────────────────

LOG_FILE="${LOG_FILE:-./logs/${TICKET_ID}-pipeline.log}"
HB_FILE="${HB_FILE:-./logs/${TICKET_ID}-heartbeat.log}"
TICKET_DIR="${TICKET_DIR:-}"

if [ ! -f "$LOG_FILE" ]; then
  echo "[pipeline-postmortem] WARN: no pipeline log at ${LOG_FILE}" >&2
  exit 0
fi

# ── Run ID derivation ────────────────────────────────────────────────────────────
# Derive a deterministic run_id from the ticket ID + ISO timestamp of the
# pipeline log's first entry. Same ticket restarted on a different day gets
# a different run_id — idempotency is within a single pipeline run.
_first_iso=$(head -1 "$LOG_FILE" 2>/dev/null | cut -d'|' -f1)
_run_id="${TICKET_ID}-${_first_iso}"

# ── Idempotency guard ────────────────────────────────────────────────────────────
# If a META|postmortem entry with the same run_id already exists, skip analysis.
if grep -q "META|postmortem|info|.*\"run_id\":\"${_run_id}\"" "$LOG_FILE" 2>/dev/null; then
  exit 0
fi

# Write the "started" marker BEFORE any analysis — this is the idempotency anchor.
_iso="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "${_iso}|META|postmortem|info|{\"run_id\":\"${_run_id}\",\"status\":\"started\",\"exit_code\":${EXIT_CODE}}" >>"$LOG_FILE"

# ── Capability detection ──────────────────────────────────────────────────────
# Analysis (signal collection, exit path, summary) always runs regardless of
# tool availability. Only issue FILING requires gh+jq — absent tools degrade
# filing to warn-only, never block analysis.

_gh_available=false
_jq_available=false

if command -v gh &>/dev/null; then
  if gh auth status &>/dev/null; then
    _gh_available=true
  fi
fi

if command -v jq &>/dev/null; then
  _jq_available=true
fi

if [ "$_gh_available" != "true" ]; then
  _pm_log "warn" "gh unavailable — issue filing disabled, analysis continues"
fi

if [ "$_jq_available" != "true" ]; then
  _pm_log "warn" "jq unavailable — issue filing disabled, analysis continues"
fi

# ── Source GitHub libraries ──────────────────────────────────────────────────────

_GI_LIB="$(_resolve_lib "github-issues.sh")"
_GIR_LIB="$(_resolve_lib "github-issue-retro.sh")"
_CP_LIB="$(_resolve_lib "corrections-parse.sh")"

[ -f "$_GI_LIB" ] && source "$_GI_LIB"
[ -f "$_GIR_LIB" ] && source "$_GIR_LIB"
[ -f "$_CP_LIB" ] && source "$_CP_LIB"

# ── Helper: emit a postmortem META entry ─────────────────────────────────────────

_pm_log() {
  local level="$1" msg="$2"
  local _iso
  _iso="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "${_iso}|META|postmortem|${level}|${msg}" >>"$LOG_FILE"
}

# ── Helper: JSON-escape a string (using jq -Rs) ──────────────────────────────────

_json_escape() {
  printf '%s' "$1" | jq -Rs '.'
}

# ── Signal collection ────────────────────────────────────────────────────────────
# Collect non-PASS verifier results, phase-inspector warnings, gate-stop lines,
# heartbeat fallback/retry events, model entries, from-planned marker.

_collect_signals() {
  local tmp="$1"

  # Non-PASS verifier results
  if grep -q '|META|verifier-result|' "$LOG_FILE" 2>/dev/null; then
    grep '|META|verifier-result|' "$LOG_FILE" 2>/dev/null | while IFS= read -r line; do
      local _json
      _json=$(echo "$line" | awk -F'|' '{for(i=5;i<=NF;i++) printf "%s%s", $i, (i==NF?"":"|")}')
      local _verdict
      _verdict=$(echo "$_json" | jq -r '.verdict // "UNKNOWN"' 2>/dev/null || echo "UNKNOWN")
      # F14: Only FAIL and BLOCK count as failures. UNKNOWN/missing verdicts
      # degrade to "no signal" per design contract (absent or malformed → skip).
      if [ "$_verdict" = "FAIL" ] || [ "$_verdict" = "BLOCK" ]; then
        echo "verifier-fail|$_json" >>"$tmp/signals.txt"
      fi
    done
  fi

  # Gate-stop lines
  grep '|META|gate-stop|fail|' "$LOG_FILE" 2>/dev/null | while IFS= read -r line; do
    local _code
    _code=$(echo "$line" | awk -F'|' '{for(i=5;i<=NF;i++) printf "%s%s", $i, (i==NF?"":"|")}')
    echo "gate-stop|${_code}" >>"$tmp/signals.txt"
  done || true

  # Phase-inspector warnings (Phase 1 — absent channel degrades gracefully)
  grep '|META|phase-inspector|' "$LOG_FILE" 2>/dev/null | while IFS= read -r line; do
    local _json
    _json=$(echo "$line" | awk -F'|' '{for(i=5;i<=NF;i++) printf "%s%s", $i, (i==NF?"":"|")}')
    local _verdict
    _verdict=$(echo "$_json" | jq -r '.verdict // "UNKNOWN"' 2>/dev/null || echo "UNKNOWN")
    if [ "$_verdict" = "WARN" ] || [ "$_verdict" = "FAIL" ]; then
      echo "inspector-warn|$_json" >>"$tmp/signals.txt"
    fi
  done || true

  # Heartbeat fallback/retry events
  if [ -f "$HB_FILE" ]; then
    grep '|fallback|' "$HB_FILE" 2>/dev/null | while IFS= read -r line; do
      echo "heartbeat-fallback|$line" >>"$tmp/signals.txt"
    done || true
    grep '|retry|' "$HB_FILE" 2>/dev/null | while IFS= read -r line; do
      echo "heartbeat-retry|$line" >>"$tmp/signals.txt"
    done || true
  fi

  # F21: additional signal sources — flow errors, preflight failures,
  # phase failures (non-MAINTENANCE), drift warnings, mode changes
  grep '|META|flow-error|fail|' "$LOG_FILE" 2>/dev/null | while IFS= read -r line; do
    echo "flow-error|$line" >>"$tmp/signals.txt"
  done || true

  grep '|META|preflight|fail|' "$LOG_FILE" 2>/dev/null | while IFS= read -r line; do
    echo "preflight-fail|$line" >>"$tmp/signals.txt"
  done || true

  # Phase |fail| entries (non-MAINTENANCE — maintenance failures are non-blocking)
  grep -E '^\|?[^|]*\|(APPRAISE|EXEC|GATE|IMPLEMENT|VERIFY|PR-REVIEW)\|.*\|fail\|' "$LOG_FILE" 2>/dev/null | while IFS= read -r line; do
    echo "phase-fail|$line" >>"$tmp/signals.txt"
  done || true

  grep '|META|drift|warn|' "$LOG_FILE" 2>/dev/null | while IFS= read -r line; do
    echo "drift-warn|$line" >>"$tmp/signals.txt"
  done || true

  grep '|META|mode-change|warn|' "$LOG_FILE" 2>/dev/null | while IFS= read -r line; do
    echo "mode-change|$line" >>"$tmp/signals.txt"
  done || true

  # MODEL entries
  grep '|META|model|' "$LOG_FILE" 2>/dev/null | head -1 >"$tmp/model.txt" 2>/dev/null || true

  # from-planned marker
  if grep -q '|META|from-planned|' "$LOG_FILE" 2>/dev/null; then
    echo "true" >"$tmp/from-planned.txt"
  fi
}

# ── Exit-path derivation ─────────────────────────────────────────────────────────
# Derives the exit path from log evidence (primary) with --exit-code as hint.

_derive_exit_path() {
  local tmp="$1"

  # Gate-stop takes priority, but detect exhaustion wrapped as gate-stop
  # (F15: production writes exhaustion as META|gate-stop|fail|VERIFY_EXHAUSTED)
  if grep -q '|META|gate-stop|fail|' "$LOG_FILE" 2>/dev/null; then
    local _code
    _code=$(grep '|META|gate-stop|fail|' "$LOG_FILE" | tail -1 | awk -F'|' '{for(i=5;i<=NF;i++) printf "%s%s", $i, (i==NF?"":"|")}')
    case "$_code" in
    VERIFY_EXHAUSTED) echo "verify-exhausted" ;;
    PR_FEEDBACK_EXHAUSTED) echo "pr-feedback-exhausted" ;;
    *) echo "gate-stop:${_code}" ;;
    esac
    return
  fi

  # Router error
  if grep -q '|META|router-error|' "$LOG_FILE" 2>/dev/null; then
    echo "router-error"
    return
  fi

  # Fleet kill
  if grep -q 'stopped: fleet-kill' "$LOG_FILE" 2>/dev/null; then
    echo "fleet-kill"
    return
  fi

  # Non-zero exit code with no clear signal
  if [ "${EXIT_CODE:-0}" -ne 0 ]; then
    echo "interrupted:exit-code-${EXIT_CODE}"
    return
  fi

  # Default: reached STEP_6
  echo "completed"
}

# ── Deterministic signature builder ──────────────────────────────────────────────

_build_signature() {
  local type="$1" phase="$2" details="$3"

  # Normalize: lowercase, strip timestamps (ISO patterns), paths, ticket IDs, PIDs
  local _normalized
  _normalized=$(echo "$details" | tr '[:upper:]' '[:lower:]' |
    sed -E 's/[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z?/TIMESTAMP/g' |
    sed -E 's|/[a-zA-Z0-9_/.~-]+|PATH|g' |
    sed -E 's/'"${TICKET_ID}"'/TICKETID/g' |
    sed -E 's/pid[ =:]*[0-9]+/pid=NNN/gi' |
    tr -s '[:space:]' ' ' |
    xargs)

  # F16: Prevent degenerate hash when normalization produces empty/whitespace-only
  # details. Salt with type+phase so distinct empty-source defects don't collapse.
  if [ -z "${_normalized:-}" ] || [ "${_normalized}" = " " ]; then
    _normalized="${type}:${phase}:empty-details"
  fi

  local _hash
  _hash=$(echo -n "$_normalized" | sha256sum | cut -c1-12)

  echo "${type}|${phase}|${_hash}"
}

# ── Severity mapping for post-mortem signatures ──────────────────────────────────

_pm_map_severity() {
  local exit_path="$1" has_mislabel="$2"

  # Base severity by exit path type (0=P0, 1=P1, 2=P2, 3=P3).
  # Mislabeled outcomes get a +1 bump (D9: wrong-outcome-label detection).
  local _base

  case "$exit_path" in
  gate-stop:*)
    local _code="${exit_path#gate-stop:}"
    case "$_code" in
    EXEC_NO_ARTIFACT | APPROVAL_REVOKED | BRANCH_DIRECTIVE_INVALID)
      _base=0
      ;; # P0 — structural failures
    VERIFY_EXHAUSTED | PR_FEEDBACK_EXHAUSTED)
      _base=1
      ;; # P1 — retry exhaustion
    *)
      _base=1
      ;; # P1 — other gate-stops
    esac
    ;;
  verify-exhausted | pr-feedback-exhausted)
    _base=1
    ;; # P1 — retry exhaustion (bare-string branch)
  router-error)
    _base=2
    ;; # P2 — router errors
  fleet-kill)
    _base=2
    ;; # P2 — fleet intervention
  *)
    _base=3
    ;; # P3 — completed/unknown (improvement, not bug)
  esac

  # Apply mislabel bump (F03: previously broken ternary always evaluated to _bump)
  local _severity=$((_base))
  if [ "${has_mislabel}" = "true" ]; then
    _severity=$((_severity + 1))
  fi
  # Clamp to [0, 4]
  [ "$_severity" -gt 4 ] && _severity=4

  # Severity 0-2 = bug, 3-4 = improvement
  local _label="bug"
  [ "$_severity" -ge 3 ] && _label="improvement"

  echo "${_label},P${_severity}"
}

# ── Wrong-outcome-label detection ────────────────────────────────────────────────
# Evidence of failure (verifier FAIL, gate-stop) vs Smooth outcome = mislabeled.

_detect_mislabel() {
  local tmp="$1"

  local _outcome_label
  _outcome_label=$(grep '^[^|]*|META|outcome-label|info|' "$LOG_FILE" 2>/dev/null | tail -1 | awk -F'|' '{for(i=5;i<=NF;i++) printf "%s%s", $i, (i==NF?"":"|")}' || true)

  if [ -z "$_outcome_label" ]; then
    echo "false"
    return
  fi

  # Check for contrary evidence
  local _has_failure=false
  if grep -q '|META|verifier-result|' "$LOG_FILE" 2>/dev/null; then
    grep '|META|verifier-result|' "$LOG_FILE" 2>/dev/null | while IFS= read -r line; do
      local _json _verdict
      _json=$(echo "$line" | awk -F'|' '{for(i=5;i<=NF;i++) printf "%s%s", $i, (i==NF?"":"|")}')
      _verdict=$(echo "$_json" | jq -r '.verdict // "UNKNOWN"' 2>/dev/null || echo "UNKNOWN")
      if [ "$_verdict" = "FAIL" ] || [ "$_verdict" = "BLOCK" ]; then
        echo "true" >"$tmp/mislabel-detected.txt"
      fi
    done
  fi

  if grep -q '|META|gate-stop|fail|' "$LOG_FILE" 2>/dev/null; then
    echo "true" >"$tmp/mislabel-detected.txt"
  fi

  if [ -f "$tmp/mislabel-detected.txt" ]; then
    _has_failure=true
  fi

  # Smooth outcome + failure evidence = mislabeled
  if [ "$_has_failure" = "true" ] && echo "$_outcome_label" | grep -qi 'smooth'; then
    echo "true"
    return
  fi

  echo "false"
}

# ── Rate-limit check ─────────────────────────────────────────────────────────────
# F06: flock-protected read-modify-write to prevent concurrent double-counting.

_check_rate_limit() {
  local repo_slug="$1"
  local _state_dir="${STATE_BASE}/${repo_slug}"
  local _hour
  _hour="$(date -u +%Y%m%d-%H)"
  local _marker="${_state_dir}/issues-${_hour}.marker"
  local _lock="${_state_dir}/.rate.lock"

  mkdir -p "$_state_dir"

  (
    flock -x 9 2>/dev/null || true
    if [ -f "$_marker" ]; then
      local _count
      _count=$(cat "$_marker" 2>/dev/null || echo 0)
      if [ "$_count" -ge "${POSTMORTEM_ISSUES_PER_HOUR}" ]; then
        return 1 # Rate limited
      fi
    fi
    return 0
  ) 9>"$_lock"
}

_bump_rate_limit() {
  local repo_slug="$1"
  local _state_dir="${STATE_BASE}/${repo_slug}"
  local _hour
  _hour="$(date -u +%Y%m%d-%H)"
  local _marker="${_state_dir}/issues-${_hour}.marker"
  local _lock="${_state_dir}/.rate.lock"

  mkdir -p "$_state_dir"

  (
    flock -x 9 2>/dev/null || true
    local _count
    _count=$(cat "$_marker" 2>/dev/null || echo 0)
    echo $((_count + 1)) >"$_marker"
  ) 9>"$_lock"
}

# ── Signature state ──────────────────────────────────────────────────────────────
# Check if a signature already has an open issue.
# F06: atomic .tmp→mv writes and jq-failure protection (never wipe state on error).

_signature_known() {
  local repo_slug="$1" signature="$2"
  local _state_dir="${STATE_BASE}/${repo_slug}"
  local _sig_file="${_state_dir}/signatures.json"

  if [ -f "$_sig_file" ]; then
    if jq -e --arg sig "$signature" '.[$sig] != null' "$_sig_file" >/dev/null 2>&1; then
      return 0 # Known
    fi
  fi

  return 1 # Not known
}

_signature_record() {
  local repo_slug="$1" signature="$2" issue_num="$3"

  # Validate issue_num is a positive integer (F06/F12: prevent recording garbage)
  case "$issue_num" in
  '' | *[!0-9]*) return 1 ;; # Non-numeric or empty — skip recording
  esac
  [ "$issue_num" -le 0 ] && return 1

  local _state_dir="${STATE_BASE}/${repo_slug}"
  local _sig_file="${_state_dir}/signatures.json"
  local _sig_tmp="${_sig_file}.tmp.$$"
  local _lock="${_state_dir}/.sig.lock"

  mkdir -p "$_state_dir"

  (
    flock -x 9 2>/dev/null || true

    if [ ! -f "$_sig_file" ]; then
      echo '{}' >"$_sig_file"
    fi

    # Atomic update: read → modify → write to tmp → mv (never truncate on error)
    local _updated
    if _updated=$(jq --arg sig "$signature" --arg num "$issue_num" \
      '. + {($sig): {issue: ($num | tonumber), filed: (now | strftime("%Y-%m-%dT%H:%M:%SZ"))}}' \
      "$_sig_file" 2>/dev/null) && [ -n "$_updated" ]; then
      echo "$_updated" >"$_sig_tmp" && mv "$_sig_tmp" "$_sig_file"
    fi
    # On jq failure: leave state unchanged, don't wipe
    rm -f "$_sig_tmp"
  ) 9>"$_lock"
}

# ── Issue filing ─────────────────────────────────────────────────────────────────

_file_issue() {
  local signature="$1" title="$2" body_file="$3" labels="$4"
  local _url _num

  _url=$(github_issue_create "$title" "$labels" "$body_file" 2>/dev/null) || {
    _pm_log "warn" "issue create failed for signature ${signature}"
    return 1
  }

  _num=$(echo "$_url" | grep -oP 'issues/\K\d+' || echo "0")
  _signature_record "$GITHUB_ISSUE_REPO" "$signature" "$_num"

  echo "$_url"
}

# ── Issue body rendering ─────────────────────────────────────────────────────────
# Renders the auto-retro-finding template with actual values.

_render_issue_body() {
  local tmp="$1" signature="$2" exit_path="$3" description="$4" \
    classification="$5" severity="$6" mislabeled="$7" verifier_fails="$8" \
    inspector_warns="$9" gate_stop_details="${10}" suggested_fix="${11}" \
    phase="${12}"

  # F13: Resolve template path correctly for both dev and runtime.
  # Dev:  <repo>/ticket-auto-pipeline/skills/ticket-retro/templates/
  # Runtime: ~/.claude/skills/ticket-retro/templates/ (skills are flat under ~/.claude/skills/)
  # Plugin cache: find under installed plugin path
  local _template
  local _script_dir
  _script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  _template="${_script_dir}/../skills/ticket-retro/templates/auto-retro-finding.md"
  if [ ! -f "$_template" ]; then
    _template="$HOME/.claude/skills/ticket-retro/templates/auto-retro-finding.md"
  fi
  if [ ! -f "$_template" ]; then
    _template=$(find "$HOME/.claude/plugins/cache" -name auto-retro-finding.md -path "*/ticket-auto-pipeline/*" 2>/dev/null | sort | tail -1)
  fi

  local _body_file="${tmp}/issue-body.md"

  if [ -f "$_template" ]; then
    cp "$_template" "$_body_file"
  else
    # Fallback: inline the template structure
    cat >"$_body_file" <<'TEMPLATE_END'
# [auto-retro] {SIGNATURE}: {ONE_LINE_SUMMARY}

## What Failed

{DESCRIPTION}

## Evidence

| Field | Value |
|-------|-------|
| Signature | `{SIGNATURE}` |
| Exit Path | `{EXIT_PATH}` |
| Ticket | `{TICKET_ID}` |
| Run ID | `{RUN_ID}` |
| Severity | `{SEVERITY}` |
| Mislabeled Outcome | `{MISLABELED}` |

### Verifier Results (non-PASS)

```
{VERIFIER_FAILURES}
```

### Phase Inspector Warnings

```
{INSPECTOR_WARNINGS}
```

### Gate-Stop Details

```
{GATE_STOP_DETAILS}
```

## Affected Component

- **Classification**: `{CLASSIFICATION}`
- **Phase**: `{PHASE}`

## Suggested Fix

{SUGGESTED_FIX}

## Resolution

- [ ] Root cause confirmed
- [ ] Fix implemented
- [ ] Fix verified (issue closed by post-mortem on next run with same signature)

---
*Filed by [ticket-auto-pipeline post-mortem](https://github.com/willard-pro/claude-plugins/blob/main/ticket-auto-pipeline/lib/pipeline-postmortem.sh) — RLVR Phase 3*
TEMPLATE_END
  fi

  # Substitute placeholders using bash parameter expansion (safe: no sed injection,
  # no delimiter breakage on | or /, no RCE via e-command). F02/F17 fixes.
  local _body
  _body=$(cat "$_body_file")
  _body="${_body//\{SIGNATURE\}/$signature}"
  _body="${_body//\{ONE_LINE_SUMMARY\}/${description:0:80}}"
  _body="${_body//\{DESCRIPTION\}/$description}"
  _body="${_body//\{EXIT_PATH\}/$exit_path}"
  _body="${_body//\{TICKET_ID\}/$TICKET_ID}"
  _body="${_body//\{RUN_ID\}/$_run_id}"
  _body="${_body//\{SEVERITY\}/$severity}"
  _body="${_body//\{MISLABELED\}/$mislabeled}"
  _body="${_body//\{VERIFIER_FAILURES\}/$verifier_fails}"
  _body="${_body//\{INSPECTOR_WARNINGS\}/$inspector_warns}"
  _body="${_body//\{GATE_STOP_DETAILS\}/$gate_stop_details}"
  _body="${_body//\{CLASSIFICATION\}/$classification}"
  _body="${_body//\{PHASE\}/$phase}"
  _body="${_body//\{SUGGESTED_FIX\}/$suggested_fix}"
  echo "$_body" >"$_body_file"

  echo "$_body_file"
}

# ── Extractor-agent invocation ───────────────────────────────────────────────────
# Shared with Phase 2's guidance store. Fail-soft — agent failure skips filing.
# Classification schema: skill-file | lib-script | agent-prompt | network-flake
#
# F11: Until Phase 2's guidance-extractor-agent exists, use conservative
# deterministic classification based on signal type. Overridable via
# POSTMORTEM_CLASSIFY env var for manual classification.
#
# Phase 2 replacement: spawn guidance-extractor-agent as named agent type,
# passing signature, exit_path, and signal summary. On failure, fall back
# to this deterministic classifier.

_invoke_extractor_agent() {
  local signature="$1" exit_path="$2" signal_type="$3"

  # Manual override for testing/classification
  if [ -n "${POSTMORTEM_CLASSIFY:-}" ]; then
    echo "${POSTMORTEM_CLASSIFY}"
    return 0
  fi

  # Conservative deterministic classification based on signal type.
  # gate-stop → lib-script (the gate script that detected the problem)
  # verifier-fail → agent-prompt (the agent that produced the failure)
  # heartbeat-fallback → network-flake (external service degradation)
  # inspector-warn → agent-prompt (agent behavior pattern)
  case "$signal_type" in
  gate-stop)
    echo "lib-script"
    ;;
  verifier-fail)
    echo "agent-prompt"
    ;;
  heartbeat-fallback | heartbeat-retry)
    echo "network-flake"
    ;;
  inspector-warn)
    echo "agent-prompt"
    ;;
  *)
    # Unknown signal type — skip filing per D6 (conservative direction)
    echo "unknown"
    ;;
  esac
}

# ── Main: signal collection and analysis ─────────────────────────────────────────

_pm_tmp="$(mktemp -d)"
trap 'rm -rf "$_pm_tmp"' EXIT

_collect_signals "$_pm_tmp"

_exit_path=$(_derive_exit_path "$_pm_tmp")
_signals_count=$(wc -l <"$_pm_tmp/signals.txt" 2>/dev/null || echo 0)
_mislabeled=$(_detect_mislabel "$_pm_tmp")

# ── Fast path: clean run, nothing to analyze ─────────────────────────────────────

if [ "$_signals_count" -eq 0 ] && [ "$_exit_path" = "completed" ]; then
  _iso="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "${_iso}|META|postmortem|info|{\"run_id\":\"${_run_id}\",\"status\":\"clean\",\"exit_path\":\"${_exit_path}\",\"signals\":0}" >>"$LOG_FILE"
  exit 0
fi

# ── Filing criteria evaluation ───────────────────────────────────────────────────
# For each non-PASS verifier result and gate-stop, build a signature, check
# filing criteria, and file if qualified.

_filed_count=0
_filed_urls=""
_skipped_signatures=""
_summary_signatures=""

if [ -f "$_pm_tmp/signals.txt" ]; then
  while IFS='|' read -r _signal_type _signal_data; do
    # Determine phase from signal context
    _phase=""
    _details=""
    _type_key=""

    case "$_signal_type" in
    verifier-fail)
      _phase=$(echo "$_signal_data" | jq -r '.phase // "UNKNOWN"' 2>/dev/null || echo "UNKNOWN")
      _verdict=$(echo "$_signal_data" | jq -r '.verdict // ""' 2>/dev/null || echo "")
      _details="${_verdict}: $(echo "$_signal_data" | jq -c '.' 2>/dev/null || echo "$_signal_data")"
      _type_key="verifier"
      ;;
    gate-stop)
      _phase="GATE"
      _details="$_signal_data"
      _type_key="$_signal_data"
      ;;
    inspector-warn)
      _phase=$(echo "$_signal_data" | jq -r '.phase // "UNKNOWN"' 2>/dev/null || echo "UNKNOWN")
      _details="$(echo "$_signal_data" | jq -c '.' 2>/dev/null || echo "$_signal_data")"
      _type_key="inspector"
      ;;
    heartbeat-fallback | heartbeat-retry)
      _phase="HEARTBEAT"
      _details="$_signal_data"
      _type_key="heartbeat"
      ;;
    flow-error)
      _phase="FLOW"
      _details="$_signal_data"
      _type_key="flow"
      ;;
    preflight-fail)
      _phase="PREFLIGHT"
      _details="$_signal_data"
      _type_key="preflight"
      ;;
    phase-fail)
      _phase=$(echo "$_signal_data" | cut -d'|' -f2 2>/dev/null || echo "UNKNOWN")
      _details="$_signal_data"
      _type_key="phase-fail"
      ;;
    drift-warn | mode-change)
      _phase="META"
      _details="$_signal_data"
      _type_key="meta"
      ;;
    *)
      continue
      ;;
    esac

    # Build signature
    _sig=$(_build_signature "$_type_key" "$_phase" "$_details")
    [ -z "$_sig" ] && continue

    # Skip if already known
    if _signature_known "$GITHUB_ISSUE_REPO" "$_sig"; then
      _skipped_signatures="${_skipped_signatures} ${_sig}"
      continue
    fi

    # Filing criteria: must be gate-stop, retry exhaustion, or ≥2 inspector WARNs
    _should_file=false
    case "$_signal_type" in
    gate-stop)
      _should_file=true
      ;;
    verifier-fail)
      # File if exit path indicates retry exhaustion
      case "$_exit_path" in
      verify-exhausted | pr-feedback-exhausted) _should_file=true ;;
      *) ;;
      esac
      ;;
    inspector-warn)
      # Count inspector warns; file if ≥2
      _warn_count=$(grep -c '^inspector-warn|' "$_pm_tmp/signals.txt" 2>/dev/null || echo 0)
      if [ "$_warn_count" -ge 2 ]; then
        _should_file=true
      fi
      ;;
    esac

    if [ "$_should_file" != "true" ]; then
      _summary_signatures="${_summary_signatures} ${_sig}"
      continue
    fi

    # Skip if filing is disabled or tools unavailable
    if [ "${POSTMORTEM_FILE_ISSUES:-false}" != "true" ]; then
      _summary_signatures="${_summary_signatures} ${_sig}"
      continue
    fi
    if [ "$_gh_available" != "true" ] || [ "$_jq_available" != "true" ]; then
      _summary_signatures="${_summary_signatures} ${_sig}"
      continue
    fi

    # Rate limit check
    if ! _check_rate_limit "$GITHUB_ISSUE_REPO"; then
      _summary_signatures="${_summary_signatures} ${_sig}"
      _pm_log "warn" "rate limit hit — signature ${_sig} deferred to summary"
      continue
    fi

    # Classification via extractor agent (fail-soft)
    _classification=$(_invoke_extractor_agent "$_sig" "$_exit_path" "$_signal_data")
    if [ "$_classification" = "unknown" ] || [ "$_classification" = "network-flake" ]; then
      # unknown → can't classify, skip filing per D6
      # network-flake → exclusion list, don't file per D5
      _summary_signatures="${_summary_signatures} ${_sig}"
      continue
    fi

    # Build issue content
    _severity=$(_pm_map_severity "$_exit_path" "$_mislabeled")
    _title="[auto-retro] ${_sig}: ${_signal_type} in phase ${_phase}"

    # Collect verifier failures text
    _verifier_text=""
    if [ -f "$_pm_tmp/signals.txt" ]; then
      _verifier_text=$(grep '^verifier-fail|' "$_pm_tmp/signals.txt" 2>/dev/null | head -5 || true)
    fi

    # Collect inspector warnings text
    _inspector_text=""
    if [ -f "$_pm_tmp/signals.txt" ]; then
      _inspector_text=$(grep '^inspector-warn|' "$_pm_tmp/signals.txt" 2>/dev/null | head -5 || true)
    fi

    # Gate-stop details
    _gate_stop_text=""
    if grep -q '|META|gate-stop|fail|' "$LOG_FILE" 2>/dev/null; then
      _gate_stop_text=$(grep '|META|gate-stop|fail|' "$LOG_FILE" 2>/dev/null | head -3 || true)
    fi

    # Suggested fix (placeholder — Phase 2 extractor agent will fill this)
    _suggested_fix="Investigate the ${_phase} phase for ${_signal_type} pattern. Review pipeline log at ${LOG_FILE} for full context."

    _body_file=$(_render_issue_body \
      "$_pm_tmp" "$_sig" "$_exit_path" \
      "${_signal_type} detected in phase ${_phase}" \
      "$_classification" "$_severity" "$_mislabeled" \
      "$_verifier_text" "$_inspector_text" "$_gate_stop_text" \
      "$_suggested_fix" "$_phase")

    # File the issue
    _filed_url=$(_file_issue "$_sig" "$_title" "$_body_file" "auto-retro,severity:${_severity#*,}" 2>/dev/null) || true

    if [ -n "$_filed_url" ]; then
      _filed_count=$((_filed_count + 1))
      _filed_urls="${_filed_urls} ${_filed_url}"
      _bump_rate_limit "$GITHUB_ISSUE_REPO"

      # Write CORRECTIONS block for filed systemic patterns
      if command -v append_correction &>/dev/null && [ -n "${TICKET_DIR:-}" ] && [ -f "${TICKET_DIR}/notes.md" ]; then
        append_correction "${TICKET_DIR}/notes.md" \
          "[auto-retro ${_sig}] ${_signal_type} in ${_phase}" \
          "postmortem" \
          "See ${_filed_url}" 2>/dev/null || true
      fi
    fi

  done <"$_pm_tmp/signals.txt"
fi

# ── Summary emission ─────────────────────────────────────────────────────────────

_skipped_count=$(echo "$_skipped_signatures" | wc -w 2>/dev/null || echo 0)
_summary_count=$(echo "$_summary_signatures" | wc -w 2>/dev/null || echo 0)

_summary_json=$(jq -nc \
  --arg run_id "$_run_id" \
  --arg exit_path "$_exit_path" \
  --arg status "completed" \
  --argjson signals "$_signals_count" \
  --argjson filed "$_filed_count" \
  --argjson skipped "$_skipped_count" \
  --argjson deferred "$_summary_count" \
  --arg mislabeled "$_mislabeled" \
  '{
    run_id: $run_id,
    status: $status,
    exit_path: $exit_path,
    signals: $signals,
    filed: $filed,
    skipped_known: $skipped,
    deferred_summary: $deferred,
    mislabeled_outcome: $mislabeled
  }')

_iso="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "${_iso}|META|postmortem|info|${_summary_json}" >>"$LOG_FILE"

# ── Guidance store update ────────────────────────────────────────────────────────
# Confirm/deprecate per run outcome. Skips confirmation for mislabeled runs.
# (Phase 2 integration — currently no-op since guidance store doesn't exist yet.)
if [ "$_mislabeled" != "true" ] && [ "$_exit_path" = "completed" ]; then
  _pm_log "info" "guidance: run completed cleanly — signals=${_signals_count}"
fi

exit 0
