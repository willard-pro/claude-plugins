#!/usr/bin/env bash
# fleet-env-check — validates env vars, CLAUDE.md fields, and CLI tools required
# by fleet-controller (fleetd + fleet-detect/dispatch/intervene/feedback).
#
# Deliberately smaller than ticket-auto-pipeline/lib/env-check.sh — fleet-controller
# is bash-only with no Claude agents, so hooks/spawn-permission/UAT_URL/LOCAL_URL
# checks (ticket-auto concerns) do not apply here.
#
# Output: pipe-delimited rows between ---BEGIN_VARS--- / ---END_VARS---
# Format: NAME|STATUS|VALUE|LOCATION|NOTE
#   STATUS  ok=present  missing=required+absent  auto=derivable  warn=optional+absent  info=fyi
#
# Usage: fleet-env-check.sh [PROJECT_DIR] [--summary-file PATH] [--show]
#   --summary-file PATH   Write delimited block to PATH; print only "Written to PATH"
#   --show                Also print a human-readable table to stdout
# -u (nounset) intentionally omitted — see ticket-auto-pipeline/lib/env-check.sh
# for the harness shell-snapshot rationale.
set -eo pipefail

SUMMARY_FILE=""
SHOW=""
PROJECT_DIR=""
_EXPECTING_SUMMARY_PATH=false
for arg in "${@}"; do
  if $_EXPECTING_SUMMARY_PATH; then
    if [[ "$arg" == --* ]]; then
      echo "fleet-env-check: --summary-file requires a path argument (got flag: $arg)" >&2
      exit 12
    fi
    SUMMARY_FILE="$arg"
    _EXPECTING_SUMMARY_PATH=false
    continue
  fi
  case "$arg" in
  --summary-file) _EXPECTING_SUMMARY_PATH=true ;;
  --summary-file=*) SUMMARY_FILE="${arg#*=}" ;;
  --show) SHOW="1" ;;
  *)
    if [ -z "$PROJECT_DIR" ]; then
      PROJECT_DIR="$arg"
    else
      echo "fleet-env-check: unexpected argument: $arg" >&2
      exit 12
    fi
    ;;
  esac
done

if $_EXPECTING_SUMMARY_PATH; then
  echo "fleet-env-check: --summary-file requires a path argument" >&2
  exit 12
fi
PROJECT_DIR="${PROJECT_DIR:-$(pwd)}"
[ -f "$PROJECT_DIR" ] && PROJECT_DIR="$(dirname "$PROJECT_DIR")"
cd "$PROJECT_DIR"

issues=0
declare -a VAR_LINES
_var() { VAR_LINES+=("$1|$2|$3|$4|$5"); }

# Walk ancestors from start_dir; emit the first dir with ≥2 child repos on stdout.
_derive_repos_root() {
  local walk_dir="$1"
  while [ "$walk_dir" != "/" ] && [ "$walk_dir" != "." ]; do
    local count=0
    for child in "$walk_dir"/*/; do
      [ -d "$child" ] || continue
      if [ -d "$child/.git" ] || [ -f "$child/CLAUDE.md" ]; then
        count=$((count + 1))
      fi
    done
    if [ "$count" -ge 2 ]; then
      echo "$walk_dir"
      return 0
    fi
    walk_dir="$(dirname "$walk_dir")"
  done
}

# Masks a secret value to presence + last 4 chars (e.g. "****yw3D") so a
# terminal/CI transcript never carries the full credential.
_mask() {
  local val="$1"
  local len=${#val}
  if [ "$len" -le 4 ]; then
    printf '****'
  else
    printf '****%s' "${val: -4}"
  fi
}

# Returns "filepath:value" if varname found in env block of either settings.local.json.
find_in_settings() {
  local varname="$1"
  local files=(
    "$PROJECT_DIR/.claude/settings.local.json"
    "$HOME/.claude/settings.local.json"
  )
  for f in "${files[@]}"; do
    [ -f "$f" ] || continue
    local val=""
    if command -v jq &>/dev/null; then
      val=$(jq -r --arg k "$varname" '.env[$k] // empty' "$f" 2>/dev/null || true)
    else
      val=$(grep -oP "\"$varname\"\s*:\s*\"\K[^\"]+" "$f" 2>/dev/null | head -1 || true)
    fi
    [ -n "$val" ] && echo "${f}:${val}" && return 0
  done
  return 1
}

# ── API keys ────────────────────────────────────────────────────────────────

if [ -n "${LINEAR_API_KEY:-}" ]; then
  _var "LINEAR_API_KEY" "ok" "$(_mask "${LINEAR_API_KEY}")" "settings.local.json" "used by fleet-detect.sh + fleet-dispatch.sh"
elif DOTENV_LINEAR_KEY=$(grep -oP '^LINEAR_API_KEY=\K.*' "$PROJECT_DIR/.env" 2>/dev/null || true) && [ -n "$DOTENV_LINEAR_KEY" ]; then
  _var "LINEAR_API_KEY" "auto" "(in .env)" ".env" "key found in project .env"
elif result=$(find_in_settings "LINEAR_API_KEY"); then
  _var "LINEAR_API_KEY" "warn" "(in ${result%%:*} — restart session)" "settings.local.json" "found in file but not loaded"
  issues=$((issues + 1))
else
  _var "LINEAR_API_KEY" "missing" "" "settings.local.json" "required — Linear → Settings → API"
  issues=$((issues + 1))
fi

# GITHUB_PERSONAL_ACCESS_TOKEN / GH_TOKEN — only required when FLEET_EPIC_AUTO_PR=true
# (epic_branch_open_pr shells out to `gh pr create`); otherwise fleet-controller
# never touches GitHub.
_epic_auto_pr="${FLEET_EPIC_AUTO_PR:-false}"
if [ -n "${GITHUB_PERSONAL_ACCESS_TOKEN:-}" ]; then
  _var "GITHUB_PERSONAL_ACCESS_TOKEN" "ok" "$(_mask "${GITHUB_PERSONAL_ACCESS_TOKEN}")" "settings.local.json" ""
  if [ -z "${GH_TOKEN:-}" ]; then
    _var "GH_TOKEN" "auto" "(copy of GITHUB_PERSONAL_ACCESS_TOKEN)" "settings.local.json" "set same as GITHUB_PERSONAL_ACCESS_TOKEN"
  else
    _var "GH_TOKEN" "ok" "$(_mask "${GH_TOKEN}")" "settings.local.json" ""
  fi
elif [ "$_epic_auto_pr" = "true" ]; then
  _var "GITHUB_PERSONAL_ACCESS_TOKEN" "missing" "" "settings.local.json" "FLEET_EPIC_AUTO_PR=true — required for epic_branch_open_pr"
  issues=$((issues + 1))
else
  _var "GITHUB_PERSONAL_ACCESS_TOKEN" "warn" "" "settings.local.json" "only needed when FLEET_EPIC_AUTO_PR=true"
fi

# SLACK_BOT_TOKEN — optional. Powers fleet-notify.sh's chat.postMessage calls
# (worker-reap-recovery task 7). Without it, and without SLACK_CHANNEL,
# fleet_slack_post degrades to a log-only line — never a hard failure.
if [ -n "${SLACK_BOT_TOKEN:-}" ]; then
  _var "SLACK_BOT_TOKEN" "ok" "$(_mask "${SLACK_BOT_TOKEN}")" "settings.local.json" "used by fleet-notify.sh"
else
  _var "SLACK_BOT_TOKEN" "warn" "" "settings.local.json" "optional — worker-exit/dead-letter Slack alerts degrade to log-only without it"
fi

# ── CLAUDE.md fields ────────────────────────────────────────────────────────

if [ ! -f "$PROJECT_DIR/CLAUDE.md" ]; then
  _var "CLAUDE.md" "missing" "" "CLAUDE.md" "file not found at $PROJECT_DIR/CLAUDE.md"
  issues=$((issues + 1))
else
  if grep -qE '^`?REPOS_ROOT`?\s*[=:]\s*.' "$PROJECT_DIR/CLAUDE.md" 2>/dev/null; then
    VAL=$(grep -oP '^`?REPOS_ROOT`?\s*[=:]\s*`?\K[^`\s]+' "$PROJECT_DIR/CLAUDE.md" | head -1 | tr -d ' ' || true)
    _var "REPOS_ROOT" "ok" "$VAL" "CLAUDE.md" "used by fleet-dispatch.sh + fleet-feedback.sh"
  else
    DERIVED="$(_derive_repos_root "$PROJECT_DIR")"
    if [ -n "$DERIVED" ]; then
      _var "REPOS_ROOT" "auto" "$DERIVED" "CLAUDE.md" "add REPOS_ROOT = $DERIVED to CLAUDE.md"
    else
      _var "REPOS_ROOT" "missing" "" "CLAUDE.md" "parent directory of all project repos"
    fi
    issues=$((issues + 1))
  fi
fi

# ── fleetd worker spawn command ──────────────────────────────────────────────
# CLAUDE_CMD (if set) takes precedence over CLAUDE_BIN — see supervisor.py
# _build_worker_cmd. Validate whichever one is actually in effect resolves to
# a real binary, so a typo surfaces here instead of as a silent per-spawn
# OSError deep in fleetd's queue consumer.

if [ -n "${CLAUDE_CMD:-}" ]; then
  # shellcheck disable=SC2206 # intentional word-splitting to mirror shlex.split
  _cmd_words=(${CLAUDE_CMD})
  _cmd_bin="${_cmd_words[0]}"
  if command -v "$_cmd_bin" &>/dev/null; then
    _var "CLAUDE_CMD" "ok" "$CLAUDE_CMD" "env" "overrides CLAUDE_BIN — worker spawn command"
  else
    _var "CLAUDE_CMD" "missing" "$CLAUDE_CMD" "env" "'$_cmd_bin' not found in PATH — fleetd spawns will fail"
    issues=$((issues + 1))
  fi
else
  _bin="${CLAUDE_BIN:-claude}"
  if command -v "$_bin" &>/dev/null; then
    _var "CLAUDE_BIN" "ok" "$_bin" "env (default: claude)" ""
  else
    _var "CLAUDE_BIN" "missing" "$_bin" "env" "not found in PATH — fleetd worker spawns will fail"
    issues=$((issues + 1))
  fi
fi

# ── fleetd state + spawn gating (informational — no default is wrong) ───────

if [ -n "${FLEET_STATE_DIR:-}" ]; then
  if [ -d "${FLEET_STATE_DIR}" ] && [ -w "${FLEET_STATE_DIR}" ]; then
    _var "FLEET_STATE_DIR" "ok" "$FLEET_STATE_DIR" "env" ""
  else
    _var "FLEET_STATE_DIR" "warn" "$FLEET_STATE_DIR" "env" "not an existing writable directory"
  fi
else
  _var "FLEET_STATE_DIR" "info" "" "env" "unset — fleetd falls back to FLEETD_WORKSPACE or ."
fi

_var "FLEETD_SPAWN_ENABLED" "info" "${FLEETD_SPAWN_ENABLED:-0}" "env" "must be 1 to enable worker spawning (default: observe-only)"
_var "FLEET_EPIC_AUTO_PR" "info" "$_epic_auto_pr" "env" "gh + GITHUB_PERSONAL_ACCESS_TOKEN only required when true"

# ── Worker permission mode (worker-reap-recovery) ────────────────────────────
# fleetd itself always emits an explicit --permission-mode unless CLAUDE_CMD
# already supplies one (see supervisor.py _cmd_already_sets_permission_mode) —
# so "missing" here means the operator's CLAUDE_CMD has NOT opted out and
# nothing further to configure, "ok" means CLAUDE_CMD has explicitly taken
# over the decision. Either way, `--restricted` and root both silently defeat
# bypassPermissions, so both are checked regardless.

_cmd_for_mode_check="${CLAUDE_CMD:-}"
if [ -n "$_cmd_for_mode_check" ] && { [[ "$_cmd_for_mode_check" == *"--permission-mode"* ]] || [[ "$_cmd_for_mode_check" == *"--dangerously-skip-permissions"* ]] || [[ "$_cmd_for_mode_check" == *"--bypass"* ]]; }; then
  _var "FLEET_WORKER_PERMISSION_MODE" "ok" "(from CLAUDE_CMD)" "env" "CLAUDE_CMD already specifies a permission mode — fleetd will not double-specify"
else
  _var "FLEET_WORKER_PERMISSION_MODE" "missing" "${FLEET_WORKER_PERMISSION_MODE:-bypassPermissions}" "env" "no explicit mode configured — fleetd defaults to bypassPermissions; run the preflight probe below to confirm"
  issues=$((issues + 1))
fi

if [ "$(id -u)" = "0" ]; then
  _var "FLEETD_NOT_ROOT" "missing" "uid=0" "process" "--dangerously-skip-permissions (bypassPermissions) refuses to run as root — fleetd worker spawns will fail"
  issues=$((issues + 1))
else
  _var "FLEETD_NOT_ROOT" "ok" "uid=$(id -u)" "process" ""
fi

if [ "${CLAUDE_CODE_SIMPLE:-}" = "1" ] || [ "${CLAUDE_CODE_SIMPLE:-}" = "true" ]; then
  _var "CLAUDE_CODE_SIMPLE" "missing" "$CLAUDE_CODE_SIMPLE" "env" "--bare mode is active — drops the entire plugin, all skills, MCP, CLAUDE.md and OAuth credentials; fleetd would lose the whole pipeline"
  issues=$((issues + 1))
else
  _var "CLAUDE_CODE_SIMPLE" "ok" "(unset)" "env" "--bare mode not active"
fi

if [ "${CLAUDE_CODE_RESTRICTED:-}" = "1" ] || [ "${CLAUDE_CODE_RESTRICTED:-}" = "true" ]; then
  _var "CLAUDE_CODE_RESTRICTED" "missing" "$CLAUDE_CODE_RESTRICTED" "env" "--restricted refuses bypassPermissions — worker spawns will silently downgrade to Manual mode"
  issues=$((issues + 1))
else
  _var "CLAUDE_CODE_RESTRICTED" "ok" "(unset)" "env" "--restricted not active"
fi

# Preflight probe: run a trivial worker turn and assert permission_denials
# is empty — a Manual-mode (or otherwise misconfigured) run exits 0 with
# subtype "success" and is_error false having written nothing, so the
# denial array is the only reliable tell. Opt-in (costs one real worker
# turn — a network call and, on a paid plan, tokens) rather than run on
# every check invocation, matching the FLEET_POSTMORTEM_ON_KILL opt-in
# convention elsewhere in this file's sibling libs. Also what keeps
# fleet-env-check safe to run inside `make test`, where CLAUDE_CMD is
# frequently set to an arbitrary test stub whose argv this probe must not
# execute unasked.
if [ "${FLEET_ENV_CHECK_LIVE_PROBE:-false}" = "true" ]; then
  _probe_bin="${CLAUDE_CMD:-${CLAUDE_BIN:-claude}}"
  # shellcheck disable=SC2206
  _probe_words=(${_probe_bin})
  if command -v "${_probe_words[0]}" &>/dev/null; then
    _probe_dir=$(mktemp -d 2>/dev/null || echo "")
    if [ -n "$_probe_dir" ]; then
      _probe_out=$(cd "$_probe_dir" && timeout 60 "${_probe_words[@]}" -p \
        "Write a file named probe.txt containing the word ok, then stop." \
        --output-format json --permission-mode bypassPermissions 2>/dev/null || true)
      _denials="null"
      if [ -n "$_probe_out" ] && command -v jq &>/dev/null; then
        _denials=$(echo "$_probe_out" | jq -c '.result.permission_denials // .permission_denials // null' 2>/dev/null || echo "null")
      fi
      if [ "$_denials" = "[]" ]; then
        _var "FLEET_WORKER_PERMISSION_PROBE" "ok" "permission_denials=[]" "probe" "bypassPermissions confirmed by a live trivial-write run"
      elif [ -n "$_probe_out" ]; then
        _var "FLEET_WORKER_PERMISSION_PROBE" "warn" "$_denials" "probe" "worker ran but did not report an empty permission_denials array — inspect manually"
      else
        _var "FLEET_WORKER_PERMISSION_PROBE" "warn" "(no output)" "probe" "probe run produced no output within 60s — could not verify permission mode live"
      fi
      rm -rf "$_probe_dir" 2>/dev/null || true
    fi
  else
    _var "FLEET_WORKER_PERMISSION_PROBE" "warn" "" "probe" "worker binary not resolvable — skipped live probe"
  fi
else
  _var "FLEET_WORKER_PERMISSION_PROBE" "info" "" "probe" "set FLEET_ENV_CHECK_LIVE_PROBE=true to run a live trivial-write probe (costs one worker turn)"
fi

# ── CLI tools ────────────────────────────────────────────────────────────────

for _tool in jq git python3; do
  if command -v "$_tool" &>/dev/null; then
    _var "$_tool" "ok" "$(command -v "$_tool")" "PATH" ""
  else
    _var "$_tool" "missing" "" "PATH" "required — jq: detection engines, git: worktree/epic-branch ops, python3: fleetd"
    issues=$((issues + 1))
  fi
done

if [ "$_epic_auto_pr" = "true" ]; then
  if command -v gh &>/dev/null; then
    _var "gh" "ok" "$(command -v gh)" "PATH" "required — FLEET_EPIC_AUTO_PR=true"
  else
    _var "gh" "missing" "" "PATH" "FLEET_EPIC_AUTO_PR=true — required for epic_branch_open_pr"
    issues=$((issues + 1))
  fi
elif command -v gh &>/dev/null; then
  _var "gh" "ok" "$(command -v gh)" "PATH" "only needed when FLEET_EPIC_AUTO_PR=true"
else
  _var "gh" "warn" "" "PATH" "only needed when FLEET_EPIC_AUTO_PR=true"
fi

# ── Emit ────────────────────────────────────────────────────────────────────

emit_vars() {
  echo "---BEGIN_VARS---"
  printf 'NAME|STATUS|VALUE|LOCATION|NOTE\n'
  for line in "${VAR_LINES[@]}"; do echo "$line"; done
  echo "ROWCOUNT=${#VAR_LINES[@]}"
  echo "---END_VARS---"
}

show_table() {
  printf '%-30s %-8s %-40s %-22s %s\n' "NAME" "STATUS" "VALUE" "LOCATION" "NOTE"
  printf '%-30s %-8s %-40s %-22s %s\n' "----" "------" "-----" "--------" "----"
  for line in "${VAR_LINES[@]}"; do
    IFS='|' read -r name status value location note <<<"$line"
    [ -z "$value" ] && value="-"
    printf '%-30s %-8s %-40s %-22s %s\n' "$name" "$status" "$value" "$location" "$note"
  done
}

if [ -n "${SUMMARY_FILE:-}" ]; then
  emit_vars >"$SUMMARY_FILE"
  echo "Summary written to ${SUMMARY_FILE}"
  [ -n "${SHOW:-}" ] && show_table
else
  emit_vars
  [ -n "${SHOW:-}" ] && echo "" && show_table
fi

exit $issues
