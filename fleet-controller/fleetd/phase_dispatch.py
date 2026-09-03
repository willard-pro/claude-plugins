"""Phase-level dispatch for fleetd.

Today fleetd spawns one worker per ticket and the `ticket-auto` router — an
LLM — sequences the phases inside it. This module is the supervisor side of
that sequencing: it loads the canonical dispatch table, decides deterministically
whether a finished phase succeeded, and resolves the phase's bracket in the
pipeline log.

Three boundaries are load-bearing here, and each exists because the alternative
puts two authorities on one fact:

* **The dispatch table is loaded, never transcribed.**
  `skills/ticket-flow/dispatch-table.json` is canonical (design.md D3). The
  markdown table in `SKILL.md` is generated from it and so is this module's
  phase sequencing. A coverage test (Group 5) asserts every `step_id` in the
  JSON has a handler here, because a Python dict of steps that drifts from the
  JSON is exactly the failure the canonical file was created to prevent.

* **The supervisor reads a grammar, never prose** (design.md D12).
  Classification consumes gate-stop markers, `META|phase-result` blocks and
  terminal state — all machine-readable. It never reads the agent's returned
  text. This does not make the agent's *judgment* deterministic; whether UAT
  passed is irreducibly a judgment. What becomes deterministic is how the
  supervisor **receives** that judgment.

* **The pipeline-log line grammar has one writer** (design.md D13).
  `phase_terminal_write` shells out to the bash helper of the same name in
  `lib/spawn-helper.sh` rather than formatting the line in Python. Two writers
  of one format is the dual-authority mistake D5 rejects for OTel spans.

Stdlib only. Third-party dependencies stay quarantined in `otel.py` (D11).
"""

import json
import os
import subprocess
import tempfile
import time
from collections import namedtuple
from datetime import datetime, timezone
from pathlib import Path

# ── Paths ───────────────────────────────────────────────────────────────────

_PLUGIN_ROOT = Path(__file__).resolve().parent.parent.parent
_REPO_TICKET_AUTO_LIB = _PLUGIN_ROOT / 'ticket-auto-pipeline' / 'lib'
_REPO_TICKET_FLOW = (
    _PLUGIN_ROOT / 'ticket-auto-pipeline' / 'skills' / 'ticket-flow'
)


def ticket_auto_lib_dir():
    """Directory holding ticket-auto-pipeline's shared bash libraries.

    Honours `CLAUDE_SKILLS_LIB` — the convention every consumer in the
    pipeline already uses (`gate-check.sh`, `detect-resume.sh`, ...) — and
    falls back to the installed location. The repo checkout is tried last, so
    a developer running out of a working tree gets the tree's copy without
    needing to export anything, while an installed fleetd never silently
    prefers a stale checkout over the installed libs.
    """
    env = os.environ.get('CLAUDE_SKILLS_LIB')
    if env:
        return Path(env)
    installed = Path.home() / '.claude' / 'skills' / 'lib'
    if installed.is_dir():
        return installed
    return _REPO_TICKET_AUTO_LIB


def dispatch_table_path():
    """Location of the canonical dispatch table."""
    env = os.environ.get('FLEET_DISPATCH_TABLE')
    if env:
        return Path(env)
    lib = ticket_auto_lib_dir()
    # Installed layout: skills/ticket-flow sits beside skills/lib.
    candidate = lib.parent / 'ticket-flow' / 'dispatch-table.json'
    if candidate.is_file():
        return candidate
    return _REPO_TICKET_FLOW / 'dispatch-table.json'


# ── Dispatch table ──────────────────────────────────────────────────────────

SUPPORTED_TABLE_SCHEMA = 1

# Phases that carry a verdict vocabulary. Everything else is classified on
# deterministic evidence that already exists — artifact presence, a
# `## Complexity` section — the same checks `gate-check.sh` performs today.
# Manufacturing a verdict for a phase that never had one would invent a
# judgment where none is being made (design.md D12).
LOOP_BEARING_PHASES = frozenset({'IMPLEMENT', 'VERIFY', 'PR-REVIEW'})

# The one place the agent's vocabulary and the router's diverge
# (pipeline-log-format.md, "Relation to the phase-result VERDICT field"):
# a PR review ✅ is agent `PASS` but router `OK`. Every other token is shared.
_ROUTER_TOKEN = {
    ('PR-REVIEW', 'PASS'): 'OK',
}

# Verdicts that mean the phase failed. Note this is phase-specific: a VERIFY
# `FAIL` and a PR-REVIEW `BLOCK` are failures, but a PR-REVIEW `WARN` is a
# successful review that happens to want another iteration.
_FAILING_VERDICTS = {
    'VERIFY': frozenset({'FAIL'}),
    'PR-REVIEW': frozenset({'BLOCK'}),
    'IMPLEMENT': frozenset({'FAIL'}),
}


class DispatchTableError(RuntimeError):
    """The canonical dispatch table is missing, unreadable or unsupported."""


class DispatchTable:
    """The canonical step sequence, loaded from `dispatch-table.json`.

    Entry order is significant — it is the render order of SKILL.md's table —
    so steps are kept in a list as well as indexed by id.
    """

    def __init__(self, data, source=None):
        self.source = source
        self.schema_version = data.get('schema_version')
        if self.schema_version != SUPPORTED_TABLE_SCHEMA:
            raise DispatchTableError(
                f'dispatch-table.json schema_version '
                f'{self.schema_version!r} is not supported '
                f'(this build understands {SUPPORTED_TABLE_SCHEMA})'
            )
        self.step_variables = dict(data.get('step_variables') or {})
        self.cycle_counters = dict(data.get('cycle_counters') or {})
        self.steps = list(data.get('steps') or [])
        if not self.steps:
            raise DispatchTableError('dispatch-table.json declares no steps')

        # Real ids first, aliases second. The table declares the gate both as
        # `STEP_2_5.aliases: ["STEP_3"]` and as its own `STEP_3` alias entry,
        # so an alias name can also be a real step_id. Registering in one pass
        # would make that legitimate pairing look like a duplicate.
        self._by_id = {}
        for step in self.steps:
            step_id = step.get('step_id')
            if not step_id:
                raise DispatchTableError(
                    'dispatch-table.json contains a step with no step_id'
                )
            if step_id in self._by_id:
                raise DispatchTableError(f'duplicate step_id {step_id!r}')
            self._by_id[step_id] = step
        for step in self.steps:
            for alias in step.get('aliases') or []:
                self._by_id.setdefault(alias, step)

    @classmethod
    def load(cls, path=None):
        path = Path(path) if path else dispatch_table_path()
        try:
            data = json.loads(path.read_text())
        except FileNotFoundError as exc:
            raise DispatchTableError(
                f'canonical dispatch table not found at {path}'
            ) from exc
        except (OSError, ValueError) as exc:
            raise DispatchTableError(
                f'canonical dispatch table at {path} is unreadable: {exc}'
            ) from exc
        return cls(data, source=path)

    def __contains__(self, step_id):
        return step_id in self._by_id

    def __len__(self):
        return len(self.steps)

    def step_ids(self):
        """Every id a caller may dispatch, in table order, aliases excluded."""
        return [s['step_id'] for s in self.steps]

    def get(self, step_id):
        """The step entry for `step_id`, following an alias to its target.

        `STEP_3` is declared as an alias step (`action: alias`) rather than a
        second copy of its target, so resolution happens here rather than at
        every call site.
        """
        step = self._by_id.get(step_id)
        if step is None:
            raise DispatchTableError(f'unknown step_id {step_id!r}')
        if step.get('action') == 'alias':
            target = step.get('alias_of')
            if not target or target not in self._by_id:
                raise DispatchTableError(
                    f'step {step_id!r} aliases unknown step {target!r}'
                )
            return self._by_id[target]
        return step

    def loop(self, step_id):
        """The loop spec for a step, or None if the step is not loop-bearing."""
        return self.get(step_id).get('loop') or None

    def loop_steps(self):
        """Every step declaring a retry loop, in table order."""
        return [s['step_id'] for s in self.steps if s.get('loop')]

    def phase_of(self, step_id):
        """The pipeline-log PHASE token a step writes under, if it spawns."""
        spawn = self.get(step_id).get('spawn') or {}
        return spawn.get('phase', '')


# ── Classification (design.md D12) ──────────────────────────────────────────

PhaseOutcome = namedtuple(
    'PhaseOutcome',
    'result verdict source detail',
)
PhaseOutcome.__doc__ = """How a finished phase was classified.

result  — 'done' or 'fail'; what goes in the terminal log line.
verdict — the router token (PASS/FAIL/OK/WARN/BLOCK) for a loop-bearing
          phase, or '' when the phase has no verdict vocabulary.
source  — which precedence rung decided it, so a surprising classification
          can be traced to the evidence that produced it rather than guessed
          at: 'gate-stop', 'phase-result', 'terminal-state' or 'exit-code'.
detail  — human-readable evidence for the log message.
"""


def router_token(phase, verdict):
    """Map an agent's phase-result VERDICT to the router's token."""
    return _ROUTER_TOKEN.get((phase, verdict), verdict)


def classify_phase(phase, log_lines, exit_code=0, terminal_state=None,
                   overrides=None):
    """Decide `done`/`fail` (and a verdict) for a phase that has finished.

    The five-rung precedence of design.md D12, evaluated in order. `log_lines`
    must be only the lines written *after this phase's bracket opened* — a
    gate-stop or phase-result from an earlier bracket is not evidence about
    this one, and passing the whole log would let a stale block decide a fresh
    phase.

    `terminal_state` is the value `fleet_ticket_terminal_state` returns
    (`done` / `gate-held` / `gate-stopped` / `incomplete`); pass None when it
    has not been consulted. `overrides` carries the independent verifiers of
    rung 5 — see `apply_verifier_overrides`.
    """
    phase = (phase or '').upper()

    # 1. A gate-stop wins outright. No judgment involved.
    for line in reversed(log_lines):
        fields = line.split('|', 4)
        if len(fields) == 5 and fields[1] == 'META' \
                and fields[2] == 'gate-stop' and fields[3] == 'fail':
            return PhaseOutcome('fail', '', 'gate-stop', fields[4].strip())

    # 2. A parseable META|phase-result decides.
    claim = _last_phase_result(log_lines)
    if claim is not None:
        verdict = (claim.get('claimed_verdict')
                   or claim.get('verdict') or '').upper()
        parse_status = (claim.get('parse_status') or '').lower()
        if parse_status == 'ok' and verdict and verdict != 'UNKNOWN':
            token = router_token(phase, verdict)
            failing = _FAILING_VERDICTS.get(phase, frozenset())
            result = 'fail' if verdict in failing else 'done'
            if phase not in LOOP_BEARING_PHASES:
                # A non-loop-bearing phase has no verdict vocabulary; keep the
                # classification but do not stamp a token onto its log line.
                token = ''
            return PhaseOutcome(result, token, 'phase-result',
                                f'agent claimed {verdict}')

    # 3. Missing or UNKNOWN → the whole-run fallback. Never synthesize a
    #    verdict, never infer one from adjacent lines, never read a missing
    #    claim as either success or failure.
    if terminal_state in ('done', 'gate-held', 'gate-stopped'):
        result = 'fail' if terminal_state == 'gate-stopped' else 'done'
        return PhaseOutcome(result, '', 'terminal-state',
                            f'no phase-result; terminal state {terminal_state}')

    # 4. Exit code is a negative signal only. Exit 0 is never positive
    #    evidence — a SIGINT'd headless `-p` worker exits 0
    #    (fleet-controller/CLAUDE.md).
    if exit_code:
        return PhaseOutcome('fail', '', 'exit-code',
                            f'no authoritative result; exit {exit_code}')

    return PhaseOutcome('done', '', 'exit-code',
                        'no authoritative result; clean exit')


def apply_verifier_overrides(outcome, overrides):
    """Rung 5: an independent verifier beats the agent's own claim.

    Implement completeness comes from `return-completeness-check.sh`, never
    from the phase-result's `CRITERIA_MET`; auto-merge eligibility from
    `META|outcome-label` plus a live `gh pr view`, never from a self-report.
    `docs/phase-result-schema.md:236-254` is the enumerated list.

    `overrides` maps a verifier name to a bool (True = the phase really did
    what it claimed). Any False forces `fail`, whatever the agent claimed.
    """
    if not overrides:
        return outcome
    failed = sorted(name for name, ok in overrides.items() if ok is False)
    if not failed:
        return outcome
    return PhaseOutcome(
        'fail',
        outcome.verdict,
        'verifier-override',
        f"independent verifier disagreed: {', '.join(failed)}",
    )


def _last_phase_result(log_lines):
    """The most recent `META|phase-result` payload in `log_lines`, or None.

    fleetd ingests the canonical JSON `phase-result-parse.sh` already wrote to
    the log; it never re-parses the agent's prose. An unparseable payload is
    treated as absent, which routes to the whole-run fallback rather than to a
    guess.
    """
    for line in reversed(log_lines):
        fields = line.split('|', 4)
        if len(fields) == 5 and fields[1] == 'META' \
                and fields[2] == 'phase-result':
            try:
                payload = json.loads(fields[4])
            except ValueError:
                return None
            return payload if isinstance(payload, dict) else None
    return None


def missing_phase_result(phase, log_lines):
    """True when a loop-bearing phase produced no usable phase-result.

    The fallback for a missing block is deliberately quiet — emission depends
    on an agent following a prompt instruction, and no deterministic check can
    observe whether it did, so failing closed would halt real tickets over a
    reporting defect (design.md D12). It is instrumented instead: the
    `phase_results` table already carries `parse_status` and `claimed_verdict`,
    so the miss rate is a query. This predicate is what a caller records.
    """
    if (phase or '').upper() not in LOOP_BEARING_PHASES:
        return False
    claim = _last_phase_result(log_lines)
    if claim is None:
        return True
    if (claim.get('parse_status') or '').lower() != 'ok':
        return True
    verdict = (claim.get('claimed_verdict') or claim.get('verdict') or '')
    return verdict.upper() in ('', 'UNKNOWN')


# ── Exit-code routing (task 4.15) ───────────────────────────────────────────

# `flow.sh` exits 7 on STATE_ASSERTION_FAILED — a Linear mutation whose
# post-trigger assertion did not hold. That is a state-integrity failure, not
# a phase failure, and re-running the phase on top of it would compound the
# divergence.
FLOW_STATE_ASSERTION_EXIT = 7

EXIT_ROUTE_CONTINUE = 'continue'
EXIT_ROUTE_RETRY = 'retry'
EXIT_ROUTE_GATE_STOP = 'gate-stop'


def route_exit_code(exit_code, outcome, loop_bearing=False):
    """What fleetd does with a phase subprocess that has exited.

    Headless `-p` exit codes are not trustworthy in the success direction —
    `fleet-controller/CLAUDE.md` documents that a SIGINT'd worker exits 0 —
    so this never promotes a clean exit into success on its own. It only
    decides what happens once `classify_phase` has spoken.
    """
    if exit_code == FLOW_STATE_ASSERTION_EXIT:
        return EXIT_ROUTE_GATE_STOP, 'STATE_ASSERTION_FAILED'
    if outcome.result == 'done':
        return EXIT_ROUTE_CONTINUE, ''
    if loop_bearing:
        return EXIT_ROUTE_RETRY, outcome.detail
    return EXIT_ROUTE_GATE_STOP, outcome.detail


# ── Terminal marker (design.md D13) ─────────────────────────────────────────

class TerminalWriteError(RuntimeError):
    """The terminal pipeline-log marker could not be written."""


def phase_terminal_write(phase, step, outcome, log_file, hb_log_file='',
                         claude_log_file='', next_phase='',
                         fail_action='stop', lib_dir=None, timeout=30):
    """Resolve a phase's bracket by writing its terminal pipeline-log line.

    Delegates to the bash helper of the same name in `lib/spawn-helper.sh`
    (design.md D13) so the line grammar keeps exactly one writer, shared with
    the router's `spawn_agent_post`. fleetd is the right caller because it is
    the process that outlives the phase: a crashed, timed-out or SIGKILLed
    agent never writes anything, and those are the cases the marker exists to
    record.

    If fleetd itself dies mid-phase, nothing is written and the bracket stays
    open — which is precisely what an unresolved `|waiting|` entry means, and
    what zombie detection and resume are built to observe.
    """
    lib = Path(lib_dir) if lib_dir else ticket_auto_lib_dir()
    helper = lib / 'spawn-helper.sh'
    if not helper.is_file():
        raise TerminalWriteError(f'spawn-helper.sh not found at {helper}')

    # Values that originate outside this process are passed through the
    # environment, never interpolated into the bash source string.
    bash_cmd = (
        'source "$PTW_HELPER" && phase_terminal_write '
        'PHASE="$PTW_PHASE" STEP="$PTW_STEP" RESULT="$PTW_RESULT" '
        'MSG="$PTW_MSG" VERDICT="$PTW_VERDICT" NEXT_PHASE="$PTW_NEXT_PHASE" '
        'FAIL_ACTION="$PTW_FAIL_ACTION" LOG_FILE="$PTW_LOG_FILE" '
        'HB_LOG_FILE="$PTW_HB_LOG_FILE" '
        'CLAUDE_LOG_FILE="$PTW_CLAUDE_LOG_FILE"'
    )
    env = {
        **os.environ,
        'PTW_HELPER': str(helper),
        'PTW_PHASE': str(phase or ''),
        'PTW_STEP': str(step or ''),
        'PTW_RESULT': outcome.result,
        'PTW_MSG': outcome.detail or '',
        'PTW_VERDICT': outcome.verdict or '',
        'PTW_NEXT_PHASE': str(next_phase or ''),
        'PTW_FAIL_ACTION': str(fail_action or 'stop'),
        'PTW_LOG_FILE': str(log_file or ''),
        'PTW_HB_LOG_FILE': str(hb_log_file or ''),
        'PTW_CLAUDE_LOG_FILE': str(claude_log_file or ''),
    }
    try:
        proc = subprocess.run(
            ['bash', '-c', bash_cmd],
            capture_output=True, text=True, timeout=timeout, env=env,
        )
    except (subprocess.TimeoutExpired, OSError) as exc:
        raise TerminalWriteError(
            f'phase_terminal_write failed for {phase}/{step}: {exc}'
        ) from exc
    if proc.returncode != 0:
        stderr_tail = (proc.stderr or '').strip().splitlines()[-3:]
        raise TerminalWriteError(
            f'phase_terminal_write exited {proc.returncode} for '
            f'{phase}/{step}: {stderr_tail}'
        )
    return True


# ── Dual-invocation interlock (task 4.19) ───────────────────────────────────
#
# Nothing stops fleetd phase-dispatching a ticket a human is concurrently
# running `/ticket-auto <ID>` against. Both append to the same
# `logs/{ID}-pipeline.log`, race the same bracket guards, and can interleave
# `flow.sh` mutations against one Linear issue.
#
# The obvious design — a lock file both paths take — does not work here. The
# manual path is an LLM following SKILL.md prose, so a lock it is *asked* to
# take is a lock that is sometimes not taken, and a lock that is usually
# honoured is worse than none: it converts a visible collision into a rare one
# nobody is looking for any more.
#
# So the interlock is one fleetd can enforce alone, from evidence the other
# party emits whether or not it cooperates. A ticket is being run by someone
# else when all three hold:
#
#   1. its pipeline log has an **open bracket** — a `|waiting|` line with no
#      matching terminal, meaning some orchestrator is mid-phase;
#   2. fleetd has **no live worker** of its own for that ticket;
#   3. its activity log shows a **tool call within the freshness window** —
#      an agent is making tool calls right now.
#
# The third condition carries the whole design. Conditions 1 and 2 alone are
# the *orphan* case — a worker that died mid-phase — which startup
# reconciliation already owns and must keep owning. A stale activity log with
# an open bracket is a crash to recover; a fresh one is a session to stay out
# of. Collapsing them would make every crash recovery look like a human at the
# keyboard, and fleetd would stop recovering anything.

DEFAULT_FOREIGN_ACTIVITY_SECS = 300

FOREIGN_NONE = ''
FOREIGN_ACTIVE_RUN = 'active-foreign-run'

ForeignRun = namedtuple('ForeignRun', 'detected reason detail age_secs')


def foreign_activity_window_secs():
    """Seconds of activity-log silence after which a run is not 'in progress'.

    300s by default, matching `FLEET_ACTIVITY_WARN_SECS`'s neighbourhood
    rather than its exact value: this is not a health threshold, it is "could
    a person still be mid-phase here". A human reading output and thinking
    between tool calls is normal; five minutes of nothing is not a session
    fleetd needs to keep clear of.
    """
    raw = os.environ.get('FLEET_FOREIGN_ACTIVITY_SECS',
                         str(DEFAULT_FOREIGN_ACTIVITY_SECS))
    try:
        value = int(raw)
    except (TypeError, ValueError):
        return DEFAULT_FOREIGN_ACTIVITY_SECS
    return value if value > 0 else DEFAULT_FOREIGN_ACTIVITY_SECS


def has_open_bracket(log_lines):
    """Whether the log's last phase bracket is unresolved.

    Scans backwards for the first line that is either a `|waiting|` or a
    terminal, and answers on that one. Counting waiting-vs-terminal totals
    instead would be wrong on any log carrying a suppressed duplicate or a
    legacy zombie bracket, and both are common.
    """
    for line in reversed(list(log_lines or [])):
        parts = line.split('|')
        if len(parts) < 4:
            continue
        status = parts[3]
        if status == 'waiting':
            return True
        if status in ('done', 'fail', 'skip'):
            return False
    return False


def last_activity_epoch(activity_log):
    """Epoch seconds of the newest entry in `{tid}-activity.log`, or None.

    The file is written per tool call by `hooks/agent-activity.sh` in the
    agent's own process, so it is the one liveness signal an orchestrator
    cannot manufacture on the agent's behalf — which is exactly why it is the
    discriminator here.
    """
    try:
        lines = [ln for ln in Path(activity_log).read_text().splitlines()
                 if ln.strip()]
    except (OSError, TypeError):
        return None
    for line in reversed(lines):
        stamp = line.split('|', 1)[0].strip()
        try:
            parsed = datetime.strptime(stamp, '%Y-%m-%dT%H:%M:%SZ')
        except ValueError:
            continue
        return parsed.replace(tzinfo=timezone.utc).timestamp()
    return None


def detect_foreign_run(tid, log_lines, activity_log, fleetd_owns_worker,
                       now=None, window=None):
    """Whether someone other than fleetd is currently running this ticket.

    `fleetd_owns_worker` is the caller's answer to "do I have a live worker
    for this tid" — the store's `running_workers` row or the run registry,
    injected rather than looked up so this stays a pure decision.

    Returns a `ForeignRun`. `detected` False is the ordinary case and includes
    the orphan: an open bracket with a stale activity log is a crash to
    recover, and must not be mistaken for a session to keep clear of.
    """
    if fleetd_owns_worker:
        return ForeignRun(False, FOREIGN_NONE, 'fleetd owns this ticket', None)
    if not has_open_bracket(log_lines):
        return ForeignRun(False, FOREIGN_NONE, 'no open bracket', None)

    last = last_activity_epoch(activity_log)
    if last is None:
        return ForeignRun(False, FOREIGN_NONE,
                          'open bracket, no agent activity recorded', None)

    now = time.time() if now is None else now
    window = foreign_activity_window_secs() if window is None else window
    age = int(now - last)
    if age > window:
        # The orphan case, and deliberately not a foreign run: this is what
        # reconciliation exists for.
        return ForeignRun(False, FOREIGN_NONE,
                          f'open bracket, activity stale ({age}s)', age)

    return ForeignRun(
        True, FOREIGN_ACTIVE_RUN,
        f'{tid} has an open bracket with agent activity {age}s ago and no '
        f'fleetd worker — another orchestrator is running it', age)


# ── The spawn bracket, opening half (task 4.12) ─────────────────────────────
#
# `spawn_agent_pre` does six things. The split for fleetd is decided by what
# each one is evidence *of*, not by symmetry with the router:
#
# | What | Who | Why |
# |---|---|---|
# | `\|waiting\|` line + `META\|model` | **Delegated** to `phase_bracket_open` | The log grammar keeps one writer, as D13 requires for the closing half. An unopened bracket reads to `detect-resume.sh`, the zombie detector and the OTel exporter as "this phase never started". |
# | spawn-meta + start marker | **fleetd itself** (`write_spawn_meta`, D15) | fleetd's differs: a session id generated before `execvpe`, and `SPAWNED_BY=fleetd` so `token-tracker.sh` picks the authoritative event. |
# | Agent-return capture | **Delegated** to `capture_phase_return` | `phase-result-parse.sh --return-file` reads `logs/{tid}-{phase}-agent.log`; without it the phase-result channel has no input on the automated path. |
# | Heartbeat pinger | **Obsolete** | It exists to prove a *router* is still looping while it waits. fleetd is not waiting in a loop it might fall out of. |
# | Orchestrator watchdog | **Replaced** by `phase_liveness_heartbeat` | Same log line, better evidence: the watchdog's `alive` proves a backgrounded bash loop is looping, whereas fleetd checks the pid it forked. Emitting it is not the monitor reporting on itself — it is a fact fleetd verified, and it is written **only** when the check passes. |
# | ctx file, progress file | **Obsolete** | The progress file is read only by that watchdog. The ctx file has no reader left at all: `tool-error-capture.sh` moved to session-id resolution and dropped the ctx fallback, so today it is written and swept and nothing consumes it. |
#
# The watchdog line is the one that cannot simply be dropped.
# `fleet-detect.sh:411` reads the newest `|orchestrator-waiting|` or
# `|watchdog|alive|` entry as its heartbeat liveness dimension, so a
# phase-dispatched ticket emitting neither would cross `FLEET_STALL_WARN_SECS`
# and be reported stalled while running perfectly.

WATCHDOG_ALIVE_EVENT = 'watchdog'


class BracketOpenError(RuntimeError):
    """The opening pipeline-log marker could not be written."""


def phase_bracket_open(phase, step, tid, log_file, description='', model='',
                       lib_dir=None, timeout=30):
    """Open a phase's bracket: the `|waiting|` line and `META|model`.

    Delegates to the bash helper of the same name so the line grammar keeps
    exactly one writer, shared with the router's `spawn_agent_pre`. Returns
    the model name the helper resolved, so a caller recording model identity
    elsewhere uses that value rather than re-reading the environment.
    """
    lib = Path(lib_dir) if lib_dir else ticket_auto_lib_dir()
    helper = lib / 'spawn-helper.sh'
    if not helper.is_file():
        raise BracketOpenError(f'spawn-helper.sh not found at {helper}')

    bash_cmd = (
        'source "$PBO_HELPER" && phase_bracket_open '
        'PHASE="$PBO_PHASE" STEP="$PBO_STEP" TICKET_ID="$PBO_TID" '
        'DESCRIPTION="$PBO_DESC" LOG_FILE="$PBO_LOG_FILE" MODEL="$PBO_MODEL"'
    )
    env = {
        **os.environ,
        'PBO_HELPER': str(helper),
        'PBO_PHASE': str(phase or ''),
        'PBO_STEP': str(step or ''),
        'PBO_TID': str(tid or ''),
        'PBO_DESC': str(description or ''),
        'PBO_LOG_FILE': str(log_file or ''),
        'PBO_MODEL': str(model or ''),
    }
    try:
        proc = subprocess.run(['bash', '-c', bash_cmd], capture_output=True,
                              text=True, timeout=timeout, env=env)
    except (subprocess.TimeoutExpired, OSError) as exc:
        raise BracketOpenError(
            f'phase_bracket_open failed for {phase}/{step}: {exc}') from exc
    if proc.returncode != 0:
        stderr_tail = (proc.stderr or '').strip().splitlines()[-3:]
        raise BracketOpenError(
            f'phase_bracket_open exited {proc.returncode} for '
            f'{phase}/{step}: {stderr_tail}')
    return (proc.stdout or '').strip()


def _pid_alive(pid, start_ticks=None):
    """Whether `pid` is running, and is still the process that was forked.

    The start-ticks comparison is the PID-reuse guard `spawn-helper.sh` and
    `detect-resume.sh` both use. Without it a recycled pid reads as alive and
    the heartbeat below would assert a liveness nobody checked.
    """
    try:
        pid = int(pid)
    except (TypeError, ValueError):
        return False
    if pid <= 0:
        return False
    try:
        os.kill(pid, 0)
    except (OSError, ProcessLookupError):
        return False
    if not start_ticks:
        return True
    try:
        stat = Path(f'/proc/{pid}/stat').read_text()
    except OSError:
        # No /proc to check against. `kill -0` succeeded, and claiming the
        # process is gone on the strength of a missing file would be worse
        # than accepting the weaker evidence.
        return True
    # Field 22 is starttime; the comm field can contain spaces and
    # parentheses, so split after the closing paren, never on the whole line.
    tail = stat.rsplit(')', 1)[-1].split()
    if len(tail) < 20:
        return True
    return tail[19] == str(start_ticks)


def phase_liveness_heartbeat(tid, phase, hb_log_file, pid, start_ticks=None,
                             now=None):
    """Write one `watchdog|alive` heartbeat for a live phase worker.

    The replacement for the router's backgrounded watchdog, and deliberately
    not a translation of it. The watchdog's `alive` line means "a bash loop is
    still looping"; this one means "fleetd checked the pid it forked and the
    process is still that process". Same log line, because
    `fleet-detect.sh`'s heartbeat dimension reads it and a phase-dispatched
    ticket emitting nothing would be reported stalled while running fine.

    Returns True when a line was written. Writes **nothing** when the worker
    is not verifiably alive: a supervisor that emits liveness on a schedule
    rather than on a check is asserting what it was supposed to be measuring.
    """
    if not hb_log_file or not _pid_alive(pid, start_ticks):
        return False
    iso = (now or datetime.now(timezone.utc)).strftime('%Y-%m-%dT%H:%M:%SZ')
    phase_label = str(phase or 'UNKNOWN').upper()
    msg = f'phase {phase_label} worker alive (pid {pid})'
    try:
        with open(hb_log_file, 'a') as fh:
            fh.write(f'{iso}|heartbeat|{WATCHDOG_ALIVE_EVENT}|alive|{msg}|'
                     f'{{"ticket":"{tid}","phase":"{phase_label}"}}\n')
    except OSError:
        return False
    return True


def worker_return_text(stdout_path):
    """Extract a phase worker's final message from its captured stdout.

    fleetd spawns workers with `--output-format json`, so the captured stdout
    is a JSON envelope, not the prose the router's `spawn_capture` receives
    from an Agent return. The `result` field is the equivalent text; handing
    the envelope to `phase-result-parse.sh` verbatim would work by accident
    (the marker block survives JSON string escaping unevenly) and fail
    silently when it did not.

    Falls back to the raw text when the envelope will not parse — a truncated
    or non-JSON capture still carries a readable tail, and a phase-result
    block that does survive there is better than none.
    """
    try:
        raw = Path(stdout_path).read_text()
    except OSError:
        return ''
    stripped = raw.strip()
    if not stripped:
        return ''
    try:
        payload = json.loads(stripped)
    except (ValueError, TypeError):
        return raw
    if isinstance(payload, dict):
        return str(payload.get('result') or raw)
    return raw


def capture_phase_return(tid, phase, text, attempt=None, lib_dir=None,
                         timeout=30):
    """Persist a phase's return to `logs/{tid}-{phase}-agent.log`.

    Delegates to `spawn_capture`, which owns the file's path and its
    append-per-attempt convention. That file is `phase-result-parse.sh`'s
    `--return-file` input, so skipping it on the automated path would leave
    the phase-result channel with nothing to read — the quiet degradation the
    change's operator decision on `phase-result` explicitly asked to
    instrument rather than gate-stop.

    Fail-soft: a capture failure is a lost observation, never a lost phase.
    """
    lib = Path(lib_dir) if lib_dir else ticket_auto_lib_dir()
    helper = lib / 'spawn-helper.sh'
    if not helper.is_file():
        return False

    with tempfile.NamedTemporaryFile('w', prefix=f'fleetd-return-{tid}-',
                                     suffix='.txt', delete=False) as fh:
        fh.write(text or '')
        return_file = fh.name

    bash_cmd = (
        'source "$CPR_HELPER" && spawn_capture '
        'TICKET_ID="$CPR_TID" PHASE="$CPR_PHASE" RESULT_FILE="$CPR_FILE"'
    )
    if attempt is not None:
        bash_cmd += ' ATTEMPT="$CPR_ATTEMPT"'
    env = {
        **os.environ,
        'CPR_HELPER': str(helper),
        'CPR_TID': str(tid or ''),
        'CPR_PHASE': str(phase or ''),
        'CPR_FILE': return_file,
        'CPR_ATTEMPT': str(attempt if attempt is not None else ''),
    }
    try:
        proc = subprocess.run(['bash', '-c', bash_cmd], capture_output=True,
                              text=True, timeout=timeout, env=env)
        return proc.returncode == 0
    except (subprocess.TimeoutExpired, OSError):
        return False
    finally:
        try:
            os.unlink(return_file)
        except OSError:
            pass


# ── Phase spawn construction (tasks 4.4 / 4.16) ─────────────────────────────
#
# The router delivers a phase's operating context two ways, and fleetd has to
# split them because a top-level `claude -p` session is not a subagent:
#
# * **Values become real process environment.** `spawn_agent_pre` prefixes the
#   Agent prompt with `export LOG_FILE=…; export HB_LOG_FILE=…` because it has
#   no other channel — a subagent shares the router's process and can only be
#   told, not configured. fleetd forks the phase itself, so it sets these in
#   `execvpe`'s environment, exactly as it already does for `FLEET_WORKER_PID`
#   and `FLEET_STATE_DIR`. This is strictly stronger than the prompt form: the
#   preamble sources its env file with `|| true`, so a missing or unwritable
#   env file silently yields a phase running with no `REPOS_ROOT` and no
#   `LINEAR_API_KEY` (task 4.16). A real env var cannot be half-applied.
#
# * **Shell function definitions stay prompt-embedded.** `source
#   heartbeat.sh` defines functions inside the agent's own Bash tool
#   invocations. Functions are not inheritable through `execvpe`, so this half
#   genuinely cannot move, and the instruction is preserved verbatim.
#
# Flags stay where they already are: the phase skills parse their arguments
# out of `$ARGUMENTS` as natural language today (`SKILL.md:954,1042`), so
# promoting `--from-step` or `--mode extract` to a real CLI flag would require
# changing every skill's argument handling for no behavioural gain, and would
# leave the manual `/ticket-verify` path parsing a different grammar than the
# automated one. They remain part of the slash-command line.

# Env vars fleetd sets on a phase worker that the router instead embeds as
# `export` statements in the agent prompt.
_PROMPT_EXPORTED_VARS = ('LOG_FILE', 'HB_LOG_FILE', 'CLAUDE_LOG_FILE')

DEFAULT_PHASE_FLAGS = '--from-auto'

PhaseSpawn = namedtuple(
    'PhaseSpawn',
    'step_id step phase skill prompt env attempt loop_bearing next_phase',
)
PhaseSpawn.__doc__ = """Everything needed to fork one phase worker.

prompt — the `-p` argument: a slash-command line plus the table's per-phase
         instructions, matching what `spawn_agent_pre` prints as
         AGENT_PROMPT so the automated and manual paths give an agent the
         same words.
env    — variables to merge into the worker's process environment.
"""


class PhaseSpawnError(RuntimeError):
    """A dispatch-table step cannot be turned into a phase spawn."""


def _spawn_spec(table, step_id):
    """The `spawn` block for a step, or raise if the step does not spawn."""
    step = table.get(step_id)
    spawn = step.get('spawn') or {}
    if not spawn.get('skill'):
        raise PhaseSpawnError(
            f'step {step_id!r} (action {step.get("action")!r}) declares no '
            f'agent spawn; it is orchestration, not a phase worker'
        )
    return step, spawn


def _render_instructions(text, counters):
    """Substitute `{COUNTER}` and the table's `$((… + 1))` attempt idiom.

    The instructions carry the router's own counter syntax verbatim — e.g.
    `PHASE_RESULT_ATTEMPT=$(({VERIFY_ATTEMPTS} + 1))`. fleetd owns those
    counters (`docs/phase-result-schema.md:249` — counters are caller-owned),
    so it resolves them to a literal here rather than shipping an agent a
    shell expression it would have to evaluate against variables it does not
    have.
    """
    if not text:
        return ''
    for name, value in (counters or {}).items():
        text = text.replace('$(({%s} + 1))' % name, str(int(value) + 1))
        text = text.replace('{%s}' % name, str(value))
    return text


def build_phase_spawn(table, step_id, tid, log_file, hb_log_file='',
                      claude_log_file='', from_step='', attempt=None,
                      counters=None, env_file='', extra_env=None):
    """Build the prompt and environment for one phase worker.

    `counters` supplies the loop counters the table's instructions interpolate
    (`VERIFY_ATTEMPTS`, `ITERATION`); `attempt` is the 1-based attempt number
    stamped into the environment so the agent reads it rather than guessing —
    the same contract `spawn_agent_pre`'s `ATTEMPT` spawn-meta field carries.
    """
    step, spawn = _spawn_spec(table, step_id)
    phase = (spawn.get('phase') or '').upper()
    skill = spawn['skill']

    flags = spawn.get('extra_flags') or DEFAULT_PHASE_FLAGS
    if from_step:
        flags = f'{flags} --from-step {from_step}'

    counters = dict(counters or {})
    instructions = _render_instructions(spawn.get('instructions', ''), counters)

    prompt = f'{skill} {tid} {flags}'.strip()
    if instructions:
        prompt = f'{prompt}. {instructions}'

    env = {
        'LOG_FILE': str(log_file or ''),
        'HB_LOG_FILE': str(hb_log_file or ''),
        'CLAUDE_LOG_FILE': str(claude_log_file or ''),
        # The router exports this in its prompt prefix to keep git hooks from
        # blocking a non-interactive commit.
        'HUSKY': '0',
        'FLEET_TICKET_ID': str(tid),
        'FLEET_PHASE': phase,
        'FLEET_STEP': str(spawn.get('step') or ''),
        'FLEET_DISPATCH_STEP_ID': str(step_id),
    }
    if env_file:
        # Named explicitly so the preamble's `source` target is a value rather
        # than a path the agent reconstructs from the ticket id.
        env['FLEET_TICKET_ENV_FILE'] = str(env_file)
    if attempt is not None:
        env['PHASE_RESULT_ATTEMPT'] = str(attempt)
    if extra_env:
        env.update({k: str(v) for k, v in extra_env.items()})

    return PhaseSpawn(
        step_id=step_id,
        step=spawn.get('step') or '',
        phase=phase,
        skill=skill,
        prompt=prompt,
        env=env,
        attempt=attempt,
        loop_bearing=bool(spawn.get('loop_bearing')),
        next_phase=(spawn.get('next_phase') or phase),
    )


# ── Hook identity (design.md D15, task 4.13) ────────────────────────────────

SPAWN_META_DIR = Path('/tmp')


def spawn_meta_path(tid):
    """The spawn-meta file every identity-resolving hook reads."""
    return SPAWN_META_DIR / f'ticket-auto-{tid}-spawn-meta.txt'


def write_spawn_meta(tid, spawn, session_id, pinger_pid='', watchdog_pid='',
                     model=None, meta_dir=None):
    """Write the spawn-meta file for a fleetd-dispatched phase, before exec.

    `agent-activity.sh`, `tool-error-capture.sh` and `token-tracker.sh` all
    resolve which ticket and phase they belong to by matching their payload's
    `session_id` against `SESSION_ID` in this file. Under the router that value
    is the router's own `$CLAUDE_CODE_SESSION_ID`; here it is the `--session-id`
    fleetd generated for the phase. The hooks cannot tell the difference, which
    is what makes them work unchanged on the automated path (D15).

    `SPAWNED_BY=fleetd` is the one new field, and it is not decoration.
    A router-spawned phase is a **subagent**, so its tokens arrive on
    `SubagentStop`; a fleetd-spawned phase is a **top-level session**, so they
    arrive on `Stop`. Both hooks would otherwise match this file — the phase
    agent's own subagents stop within the phase's session id — and the phase
    would be counted twice. This field is how `token-tracker.sh` tells which
    event is the real one for this spawn.

    Written before `execvpe` so no hook can fire against a missing file.
    """
    meta_dir = Path(meta_dir) if meta_dir else SPAWN_META_DIR
    path = meta_dir / f'ticket-auto-{tid}-spawn-meta.txt'
    lines = [
        f'PHASE={spawn.phase}',
        f'STEP={spawn.step}',
        f'TICKET_ID={tid}',
        f'LOG_FILE={spawn.env.get("LOG_FILE", "")}',
        f'HB_LOG_FILE={spawn.env.get("HB_LOG_FILE", "")}',
        f'CLAUDE_LOG_FILE={spawn.env.get("CLAUDE_LOG_FILE", "")}',
        f'PINGER_PID={pinger_pid}',
        f'WATCHDOG_PID={watchdog_pid}',
        f'SESSION_ID={session_id}',
        'SPAWNED_BY=fleetd',
    ]
    if spawn.attempt is not None:
        lines.append(f'ATTEMPT={spawn.attempt}')
    if model is None:
        model = os.environ.get('ANTHROPIC_MODEL', 'unknown')
    lines.append(f'MODEL={model}')
    path.write_text('\n'.join(lines) + '\n')
    return path


def write_phase_start_marker(tid, phase, meta_dir=None):
    """Write the nanosecond start stamp `token-tracker.sh` reads for elapsed_ms.

    On the router path this is `token-tracker-start.sh`'s job, fired by
    `SubagentStart`. A fleetd-spawned phase is not a subagent, so that event
    never fires and fleetd writes the stamp itself — it knows the ticket, the
    phase and the moment, which is everything the hook was deriving.

    The filename keeps the hook's existing `-start-{PHASE}-{ns}.ts` shape so
    the reader needs no change, and the same `find -mmin +5` cleanup applies.
    """
    meta_dir = Path(meta_dir) if meta_dir else SPAWN_META_DIR
    stamp = time.time_ns()
    path = meta_dir / f'ticket-auto-{tid}-start-{phase}-{stamp}.ts'
    path.write_text(str(stamp))
    return path


# ── Retry loops (task 4.6) ──────────────────────────────────────────────────
#
# Four steps in the table declare a `loop`, and each names the counter it
# advances, its cap, when the cap is checked, and the gate-stop code to write
# on exhaustion. All four values are read from the table — a cap duplicated as
# a Python constant is the drift the canonical file exists to prevent, and
# Group 5's coverage test asserts exactly that it is not duplicated here.
#
# The counters themselves stay caller-owned. `META|phase-result`'s `ATTEMPT`
# field is explicitly not their source (`docs/phase-result-schema.md:249`):
# it is the agent's report of which attempt it believed it was on, which is
# the wrong authority for deciding whether another attempt is allowed.

LOOP_DISPATCH = 'dispatch'
LOOP_GATE_STOP = 'gate-stop'
LOOP_NOT_LOOPED = 'not-a-loop'

# STEP_4_6's cap shipped as `gate_stop_code: null` — SKILL.md routed it to a
# bare gate-stop with no name, and `pipeline-log-format.md`'s table had no
# entry. Task 4.6 named it `PR_REVIEW_EXHAUSTED`, **in the table**, alongside
# the log-format doc, `pipeline-postmortem.sh` and SKILL.md's own prose, so
# the router and fleetd write the identical code. Deliberately not defined as
# a constant here: a code named in Python as well as in the table is two
# authorities on one string, which is the drift D3 removes.
#
# The reasoning, since it is a change to the log contract: every consumer
# already has a default branch, so adding a name breaks none of them, while an
# unnamed code made `pipeline-finalize.sh` record the literal outcome
# "stopped: gate-stop " for the pipeline's most-travelled loop — a run that
# stopped without recording why.

LoopDecision = namedtuple(
    'LoopDecision',
    'action counter value limit gate_stop_code checked detail',
)


def evaluate_loop(table, step_id, counters, when=None):
    """Decide whether a loop-bearing step may run another iteration.

    `when` is `'pre_dispatch'` or `'post_dispatch'`; pass it to ask only about
    the moment this step's cap is actually checked. A pre-dispatch cap
    (reconcile, PR-feedback) refuses to spawn the next iteration; a
    post-dispatch cap (verify, PR-review) lets the iteration run and refuses
    the one after it. Asking at the wrong moment returns `dispatch` rather
    than an answer, so a caller cannot accidentally apply a post-dispatch cap
    before the phase has had its attempt.
    """
    loop = table.loop(step_id)
    if not loop:
        return LoopDecision(LOOP_NOT_LOOPED, '', 0, 0, '', '', '')

    counter = loop.get('counter') or ''
    limit = int(loop.get('max_iterations') or 0)
    checked = loop.get('checked') or ''
    code = loop.get('gate_stop_code') or ''

    if when and checked and when != checked:
        return LoopDecision(LOOP_DISPATCH, counter, 0, limit, code, checked,
                            f'cap is checked at {checked}, not {when}')

    try:
        value = int((counters or {}).get(counter, 0))
    except (TypeError, ValueError):
        value = 0

    if limit and value >= limit:
        return LoopDecision(
            LOOP_GATE_STOP, counter, value, limit, code, checked,
            f'{counter} reached {value} of {limit}',
        )
    return LoopDecision(LOOP_DISPATCH, counter, value, limit, code, checked,
                        f'{counter}={value} of {limit}')


# ── Dispatch position / resume (task 4.3, design.md D7) ─────────────────────
#
# fleetd records its own dispatch position rather than reconstructing it.
# `store.record_position`/`get_position` (Group 3B) already hold the column;
# what this section adds is the one case a supervisor cannot know first-hand
# — a ticket a human started manually, before fleetd ever dispatched it, so
# no `dispatch`-sourced position exists yet. `detect-resume.sh` is invoked
# exactly once for such a ticket, to derive its initial position, which is
# then recorded with `source='adopted'` so every later call is a store read.


class ResumeAdoptError(RuntimeError):
    """`detect-resume.sh` could not be run to adopt an initial position."""


def detect_resume_script_path(lib_dir=None):
    """Location of `detect-resume.sh`.

    It ships in the `ticket-detect-resume` skill, not in `lib/`, but the
    installed layout still puts `skills/lib` and every other skill directory
    as siblings — the same shape `dispatch_table_path` already relies on.
    """
    env = os.environ.get('FLEET_DETECT_RESUME_SCRIPT')
    if env:
        return Path(env)
    lib = Path(lib_dir) if lib_dir else ticket_auto_lib_dir()
    candidate = lib.parent / 'ticket-detect-resume' / 'detect-resume.sh'
    if candidate.is_file():
        return candidate
    return (
        _PLUGIN_ROOT / 'ticket-auto-pipeline' / 'skills'
        / 'ticket-detect-resume' / 'detect-resume.sh'
    )


def parse_detect_resume_block(text):
    """Parse the `DETECT_RESUME_RESULT` block into a dict.

    Same `key: value` grammar `parse_result_block` (preamble.py) reads for
    `TICKET_PREAMBLE_RESULT` — unknown keys pass through rather than being
    rejected, since this parser only ever consumes `RESUME_STEP`.
    """
    fields = {}
    in_block = False
    for line in (text or '').splitlines():
        stripped = line.strip()
        if stripped == 'DETECT_RESUME_RESULT':
            in_block = True
            continue
        if stripped == 'END_DETECT_RESUME_RESULT':
            break
        if not in_block:
            continue
        key, sep, value = stripped.partition(':')
        if sep:
            fields[key.strip()] = value.strip()
    return fields


# `detect-resume.sh` reports these two states for a ticket parked at a gate
# hold. Neither is a dispatch-table step_id — `gate_hold.py` (D14) owns that
# state as a row in `tickets`, not a position to resume dispatch from — so a
# caller adopting a position must route them there rather than trying to
# spawn a step named "GATE_HELD".
GATE_HOLD_RESUME_STEPS = frozenset({'GATE_HELD', 'GATE_STILL_HELD'})

# Terminal states `detect-resume.sh` can report that are not a step_id either.
_NON_STEP_RESUME_STEPS = GATE_HOLD_RESUME_STEPS | {'SCHEMA_MISMATCH'}


def adopt_position_via_detect_resume(tid, project_dir=None, script=None,
                                     timeout=60):
    """Derive `tid`'s initial dispatch position, calling `detect-resume.sh`.

    Only ever called when the store holds no recorded position for `tid` —
    see `resolve_dispatch_position`. `project_dir` is the ticket's workspace
    (the directory holding `logs/`), matching how the router invokes the
    script today; it becomes the subprocess's cwd because the script derives
    `LOG_FILE` from `$PWD`.

    Returns `(step_id, fields)`. `step_id` is one of the dispatch table's
    real step ids, `'done'`, or one of `GATE_HOLD_RESUME_STEPS` — callers
    that only want a spawnable step_id must check membership first.
    """
    script = Path(script) if script else detect_resume_script_path()
    if not script.is_file():
        raise ResumeAdoptError(f'detect-resume.sh not found at {script}')

    # Unlike `ticket-preamble.sh`, `detect-resume.sh` does not self-locate
    # its libraries from its own script path — it sources
    # `${CLAUDE_SKILLS_LIB:-$HOME/.claude/skills/lib}/heartbeat.sh` etc., the
    # convention every other pipeline consumer of that variable uses too.
    # `setdefault` respects a caller's own override (a test's fixture lib
    # dir) and otherwise supplies the same resolution `ticket_auto_lib_dir`
    # already gives every other shell-out in this module.
    env = dict(os.environ)
    env.setdefault('CLAUDE_SKILLS_LIB', str(ticket_auto_lib_dir()))

    try:
        proc = subprocess.run(
            ['bash', str(script), tid],
            capture_output=True, text=True, timeout=timeout,
            cwd=str(project_dir) if project_dir else None, env=env,
        )
    except (subprocess.TimeoutExpired, OSError) as exc:
        raise ResumeAdoptError(
            f'detect-resume.sh failed for {tid}: {exc}'
        ) from exc

    if proc.returncode != 0:
        stderr_tail = (proc.stderr or '').strip().splitlines()[-3:]
        raise ResumeAdoptError(
            f'detect-resume.sh exited {proc.returncode} for {tid}: '
            f'{stderr_tail}'
        )

    fields = parse_detect_resume_block(proc.stdout)
    step = fields.get('RESUME_STEP', '')
    if not step:
        raise ResumeAdoptError(
            f'detect-resume.sh produced no RESUME_STEP for {tid}'
        )
    if step == 'SCHEMA_MISMATCH':
        raise ResumeAdoptError(
            f'detect-resume.sh reported SCHEMA_MISMATCH for {tid} '
            f'(log version {fields.get("SCHEMA_LOG_VERSION")}, expected '
            f'{fields.get("SCHEMA_EXPECTED")})'
        )
    return step, fields


def resolve_dispatch_position(store, tid, project_dir=None, script=None,
                              timeout=60):
    """The step_id fleetd should dispatch next for `tid` (design.md D7).

    Reads the store's recorded position first — fleetd always knows where it
    left off, because it wrote the position itself at the last dispatch
    (`record_position`, called at spawn time). Only a ticket with *no*
    recorded position at all — one a human started manually, before fleetd
    ever touched it — falls through to the one-time `detect-resume.sh`
    adoption, whose result is recorded immediately so every subsequent call
    is a store read and never a second shell-out.

    Returns `(step_id, source, fields)`. `fields` is the parsed
    `DETECT_RESUME_RESULT` block on adoption, `{}` otherwise — a dispatch-
    sourced position carries no such block because fleetd already knows the
    context it recorded the position with.
    """
    existing = store.get_position(tid)
    if existing is not None:
        return existing['position'], existing['source'], {}

    step, fields = adopt_position_via_detect_resume(
        tid, project_dir=project_dir, script=script, timeout=timeout)
    store.record_position(tid, step, source='adopted')
    return step, 'adopted', fields


# ── Mid-run crash resume (task 4.7, phase-result-schema.md's fourth channel) ─
#
# `docs/phase-result-schema.md` enumerates five channels a code supervisor
# needs beyond `META|phase-result`. Four already have an owner elsewhere in
# this module: outcome label and auto-merge eligibility are read by
# `orchestration.py`'s `bash`/`auto_merge` runners (task 4.11); implement
# completeness is `return-completeness-check.sh`, run the same way, its
# `enforcement: warn-only` table field — not a hardcoded rule here — deciding
# whether a failure blocks (task 4.11's `_is_blocking`); retry/iteration caps
# are `evaluate_loop` (task 4.6). This is the fifth: the phase-result block is
# terminal-only, so an agent that crashes mid-VERIFY never emits one, which is
# exactly when resume matters.
#
# Scoped to VERIFY because it is the only phase phase-result-schema.md names
# for this channel — the only one that writes incremental per-criterion
# progress mid-attempt. The other phases' `*_FROM` sub-step values
# (`APPRAISE_FROM`, `IMPLEMENT_FROM`, ...) exist only inside
# `detect-resume.sh`'s one-time adoption reconstruction —
# `resolve_dispatch_position` already returns them via its `fields` return
# value — not as a normal-path concern: fleetd always knows which step_id it
# dispatched, so there is nothing to reconstruct for those phases between one
# fleetd dispatch and the next. VERIFY differs because the crash can happen
# *inside* the attempt fleetd is already resuming.

# `detect-resume.sh`'s own browser-state correction (`:451-453`): a checkpoint
# written mid-navigation cannot be resumed by a fresh worker with no browser
# session, so all three normalize back to the phase's start.
_VERIFY_UNRESUMABLE_SUBSTEPS = frozenset(
    {'browser-session', 'navigate', 'execute-steps'})


def last_verify_checkpoint(log_lines):
    """The `--from-step` value a retried VERIFY worker should resume from.

    Mirrors `detect-resume.sh`'s `VERIFY_FROM` derivation exactly — the last
    `|VERIFY|<step>|done|` entry's step field, with `verify` and
    `phase-inspector-*` excluded, then the same browser-state correction —
    so a Python reimplementation cannot silently diverge from the bash one.
    Read directly rather than shelled out to, per D7: this is a per-attempt
    reconstruction fleetd performs on its own dispatch path, not the one-time
    adoption `resolve_dispatch_position` owns.

    Returns `''` when no resumable sub-step has completed, matching the
    bash script's empty-string default.
    """
    last_step = ''
    for line in log_lines:
        fields = line.split('|', 4)
        if len(fields) < 5 or fields[1] != 'VERIFY' or fields[3] != 'done':
            continue
        step = fields[2]
        if step == 'verify' or step.startswith('phase-inspector-'):
            continue
        last_step = step
    if last_step in _VERIFY_UNRESUMABLE_SUBSTEPS:
        return 'build-plan'
    return last_step
