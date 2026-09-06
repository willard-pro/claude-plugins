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
import re
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

# docs/phase-result-schema.md's VERDICT enum, reused unchanged (agent-observer
# Inc 3's build_phase_contract derives success/failure sets from this plus
# _FAILING_VERDICTS rather than re-parsing the markdown doc at runtime).
_VERDICT_TOKENS = frozenset({'PASS', 'FAIL', 'WARN', 'BLOCK'})


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

    fleetd spawns workers with `--output-format json` by default, so the
    captured stdout is a single JSON envelope, not the prose the router's
    `spawn_capture` receives from an Agent return. The `result` field is the
    equivalent text; handing the envelope to `phase-result-parse.sh` verbatim
    would work by accident (the marker block survives JSON string escaping
    unevenly) and fail silently when it did not.

    Under `FLEET_OBSERVER_ENABLE=true` (Agent Observer), phase-level workers
    instead spawn with `--output-format stream-json`, writing one JSON object
    per line to the same file (`.ndjson` extension — see `_build_worker_cmd`).
    A whole-file `json.loads()` fails on that shape, so this falls through to
    `_worker_return_text_ndjson`, which mirrors `lib/phase-result-parse.sh`'s
    `_pr_unwrap`: scan every line to EOF and take the *last* `type: "result"`
    frame's `.result` field — never the first, since a `hook_response` line
    can follow the terminal `result` frame (design.md E5).

    Falls back to the raw text when neither shape yields a result — a
    truncated or non-JSON capture still carries a readable tail, and a
    phase-result block that does survive there is better than none.
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
        frame = _last_ndjson_result_frame(raw)
        if frame is not None and isinstance(frame.get('result'), str):
            return frame['result']
        return raw
    if isinstance(payload, dict):
        return str(payload.get('result') or raw)
    return raw


def _last_ndjson_result_frame(raw):
    """The last `type: "result"` line's full object in NDJSON `raw`, or None.

    Shared by `worker_return_text` and `worker_cost_usd` — both read the same
    stdout envelope and both need the same object (`.result` text for one,
    `.total_cost_usd` for the other), not just one field of it, so they scan
    once through the same helper rather than duplicating the scan twice.
    Unparseable lines are skipped rather than raising — a stream-json capture
    routinely interleaves noise (hook lines, a mid-write partial line) that
    must not abort extraction of the one line that matters. Takes the *last*
    matching line, never the first, since a `hook_response` line can follow
    the terminal `result` frame (design.md E5).
    """
    last = None
    for line in raw.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            obj = json.loads(line)
        except (ValueError, TypeError):
            continue
        if isinstance(obj, dict) and obj.get('type') == 'result':
            last = obj
    return last


def worker_cost_usd(stdout_path):
    """Extract `total_cost_usd` from a worker's captured stdout envelope.

    Returns a float when the envelope yields a numeric `total_cost_usd`
    field, `None` on any anomaly (missing file, unparseable content, missing
    field, non-numeric value) — never raises. Cost extraction must not be
    able to fail a reap or a fleet-kill (design.md Decision 2), the two paths
    that guarantee tickets don't get stuck as phantom-owned.

    NDJSON-safe on the same terms as `worker_return_text` (agent-observer
    Inc 0/1): a phase worker spawned under `FLEET_OBSERVER_ENABLE=true` writes
    stream-json instead of a single JSON object, and this must still find the
    terminal frame's cost rather than silently returning None for every
    phase-level worker once the flag is on.
    """
    try:
        raw = Path(stdout_path).read_text()
    except OSError:
        return None
    stripped = raw.strip()
    if not stripped:
        return None
    try:
        payload = json.loads(stripped)
    except (ValueError, TypeError):
        payload = _last_ndjson_result_frame(raw)
        if payload is None:
            return None
    if not isinstance(payload, dict):
        return None
    cost = payload.get('total_cost_usd')
    if isinstance(cost, bool) or not isinstance(cost, (int, float)):
        return None
    return float(cost)


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
        'CLAUDE_SKILLS_LIB': os.environ.get('CLAUDE_SKILLS_LIB', str(lib)),
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
    'step_id step phase skill prompt env attempt loop_bearing next_phase agent',
)
PhaseSpawn.__doc__ = """Everything needed to fork one phase worker.

prompt — the `-p` argument: a slash-command line plus the table's per-phase
         instructions, matching what `spawn_agent_pre` prints as
         AGENT_PROMPT so the automated and manual paths give an agent the
         same words.
env    — variables to merge into the worker's process environment.
agent  — the plugin-scoped subagent type (`spawn.agent` in the dispatch
         table, e.g. `ticket-auto-pipeline:ticket-implement-agent`) to pass
         as `claude`'s `--agent` flag, or None when the step has no
         dedicated agent type yet (the worker runs unrestricted, same as
         today). Mirrors the manual router's AGENT_TYPE (spawn_agent_pre).
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
        agent=spawn.get('agent') or None,
    )


# ── Phase contract (agent-observer Inc 3, design.md D4/D7) ─────────────────
# What a phase worker is contractually allowed and expected to do, assembled
# from sources that already exist elsewhere in this codebase rather than a
# new authoring surface — the one new thing is `allowed_paths` templating.

_PLUGIN_CACHE_ROOT = Path.home() / '.claude' / 'plugins' / 'cache'


def _newest_installed_ticket_auto_pipeline_root():
    """Newest versioned `ticket-auto-pipeline` plugin-cache install, or None.

    Mirrors `grill-seal.sh`'s "Level 1: newest version in a versioned plugin
    cache" resolution for the same class of problem: an agent `.md`'s tools
    allowlist must reflect what a real `--agent` spawn actually binds, which
    is whatever the CLI resolves from its plugin cache — not necessarily
    this git checkout, which may be a stale or in-progress working tree.
    """
    try:
        candidates = list(_PLUGIN_CACHE_ROOT.glob('*/ticket-auto-pipeline/*'))
    except OSError:
        return None
    versioned = []
    for path in candidates:
        if not path.is_dir():
            continue
        parts = path.name.split('.')
        if not parts or not all(p.isdigit() for p in parts):
            continue
        versioned.append((tuple(int(p) for p in parts), path))
    if not versioned:
        return None
    return max(versioned, key=lambda pair: pair[0])[1]


def _agent_md_path(agent_ref, ticket_auto_root=None):
    """`ticket-auto-pipeline:ticket-appraise-agent` -> its `agents/*.md` path.

    None for a step with no dedicated agent type (the worker runs
    unrestricted — same as `PhaseSpawn.agent`'s own None case).

    `ticket_auto_root` overrides ambient plugin-cache resolution — tests
    inject a controlled directory rather than depending on whatever happens
    to be installed on the machine running them, which (a stale plugin
    cache missing a newly-added agent file, observed during this change's
    own development) is real, environment-dependent state a unit test must
    not depend on.
    """
    name = (agent_ref or '').split(':', 1)[-1]
    if not name:
        return None
    root = ticket_auto_root
    if root is None:
        root = _newest_installed_ticket_auto_pipeline_root()
    if root is None:
        root = _PLUGIN_ROOT / 'ticket-auto-pipeline'
    return Path(root) / 'agents' / f'{name}.md'


_FRONTMATTER_TOOLS_RE = re.compile(r'^tools:\s*(.+)$', re.MULTILINE)


def _parse_agent_frontmatter_tools(path):
    """The `tools:` line of an agent `.md`'s YAML frontmatter, as a list.

    None when the file is missing, unreadable, has no frontmatter, or the
    frontmatter has no `tools:` line — the caller treats None as "no
    allowlist known", never as "allow everything" or "allow nothing".
    """
    try:
        text = path.read_text()
    except (OSError, TypeError):
        return None
    if not text.startswith('---'):
        return None
    end = text.find('\n---', 3)
    if end == -1:
        return None
    match = _FRONTMATTER_TOOLS_RE.search(text[3:end])
    if not match:
        return None
    return [t.strip() for t in match.group(1).split(',') if t.strip()]


_ENV_EXPORT_RE = re.compile(r'^export\s+(\w+)="(.*)"\s*$', re.MULTILINE)


def _parse_env_file(env_file):
    """`export NAME="value"` lines from a `spawn_write_env`-shaped file.

    Returns {} on any read failure — the caller's job is to disable
    (never guess) whatever depended on a value this couldn't find, not to
    raise. Values are the literal quoted text; `spawn_write_env` writes
    plain strings without embedded double quotes in every field it defines.
    """
    if not env_file:
        return {}
    try:
        text = Path(env_file).read_text()
    except (OSError, TypeError):
        return {}
    return dict(_ENV_EXPORT_RE.findall(text))


def _resolve_ticket_dir(tid, repos_root):
    """Mirrors `lib/ticket-dir.sh`'s `resolve_ticket_dir`: the one directory
    under `repos_root` (depth <= 2) matching `{tid}--[a-z0-9-]+`.

    None (unresolved) when zero or more-than-one match — a ticket directory
    is either found uniquely or it isn't; ambiguity is not this caller's to
    guess at, same as the bash original refusing on `count -eq 2`.
    """
    if not repos_root:
        return None
    root = Path(repos_root)
    if not root.is_dir():
        return None
    pattern = re.compile(rf'^{re.escape(tid)}--[a-z0-9-]+$', re.IGNORECASE)
    matches = []
    for depth_glob in ('*', '*/*'):
        for candidate in root.glob(depth_glob):
            if candidate.is_dir() and pattern.match(candidate.name):
                matches.append(candidate)
    matches = sorted(set(matches))
    if len(matches) == 1:
        return str(matches[0])
    return None


def _resolve_worktrees(tid, repos_root):
    """Every existing git worktree for `tid`, per `lib/worktree.sh`'s formula
    `$REPOS_ROOT/.ticket-auto/worktrees/{TICKET_ID}/{repo-slug}`.

    Globs rather than requiring a specific repo slug, since IMPLEMENT may
    touch more than one repo. Returns [] (unresolved) when none exist yet —
    the common case for a first IMPLEMENT attempt, since `ensure_worktree`
    creates the directory *during* the phase this contract is built before,
    not before it. A retry attempt, whose worktree already exists from the
    first, resolves normally.
    """
    if not repos_root:
        return []
    base = Path(repos_root) / '.ticket-auto' / 'worktrees' / tid
    if not base.is_dir():
        return []
    return sorted(str(p) for p in base.iterdir() if p.is_dir())


def _resolve_allowed_paths(templates, tid, env_vars):
    """Resolve each `{TEMPLATE}` in `templates` against `env_vars`.

    Returns `(resolved_paths, disabled_reason)` — exactly one is truthy.
    Design.md D4: an unresolvable template disables the rule for that phase
    rather than guessing a default, because a wrong default produces
    confident false SCOPE_VIOLATION findings, the fastest way to get the
    whole subsystem ignored.
    """
    if not templates:
        return [], 'no allowed_paths declared for this step'
    repos_root = env_vars.get('REPOS_ROOT')
    if not repos_root:
        return [], 'REPOS_ROOT unavailable (env file missing or unreadable)'

    resolved = []
    for template in templates:
        if template == '{TICKET_DIR}':
            path = _resolve_ticket_dir(tid, repos_root)
            if path is None:
                return [], f'{{TICKET_DIR}} unresolved for {tid!r} under {repos_root!r}'
            resolved.append(path)
        elif template == '{WORKTREE}':
            paths = _resolve_worktrees(tid, repos_root)
            if not paths:
                return [], f'{{WORKTREE}} unresolved for {tid!r} (no worktree created yet)'
            resolved.extend(paths)
        else:
            return [], f'unknown allowed_paths template {template!r}'
    return resolved, None


def _claim_predicates(phase, env_vars):
    """Test-class command patterns whose exit code is evidence for
    CLAIM_CONTRADICTION (design.md D3) — a phase's claimed PASS is
    contradicted when the *last* observed run of one of these has
    `is_error=true` and no later passing run of the same command follows.

    Project-specific test commands (`BE_TEST_CMD`/`BE_TEST_RUNNER`/
    `FE_TEST_CMD`) come from the env file when available; generic ones
    (`pytest`, `npm test`, `mvn test`) are substring patterns matched
    against a tool_call's command regardless of project config, since a
    phase agent may run them directly even when a project-specific wrapper
    also exists. VERIFY additionally treats any `mcp__plugin_playwright_*`
    tool call as test-class evidence — its "test" is a browser action, not
    a shell command.
    """
    patterns = ['pytest', 'npm test', 'npm run test', 'mvn test']
    for key in ('BE_TEST_CMD', 'BE_TEST_RUNNER', 'FE_TEST_CMD'):
        value = env_vars.get(key)
        if value and value not in patterns:
            patterns.append(value)
    predicates = {'command_substrings': patterns}
    if phase == 'VERIFY':
        predicates['tool_name_prefixes'] = ['mcp__plugin_playwright_']
    return predicates


def build_phase_contract(table, step_id, tid, env_file=None, ticket_auto_root=None):
    """The phase contract observer.py's deterministic rules compare against.

    Assembled entirely from sources that already exist — `dispatch-table.json`
    step descriptions, the step's agent `.md` frontmatter, the existing
    `LOOP_BEARING_PHASES`/`_FAILING_VERDICTS` constants (phase-result-schema.md's
    VERDICT enum, already encoded in this module) and the step's own `loop`
    dict's `gate_stop_code` when present. `allowed_paths` is the one templated
    field, resolved here from `FLEET_TICKET_ENV_FILE`'s contents.

    Never raises: every field that cannot be resolved records why instead of
    a guessed value (design.md D4), because a rule computed from a wrong
    default is worse than a rule that stays disabled.
    """
    step, spawn = _spawn_spec(table, step_id)
    phase = (spawn.get('phase') or '').upper()
    env_vars = _parse_env_file(env_file)

    agent_ref = spawn.get('agent')
    agent_md = _agent_md_path(agent_ref, ticket_auto_root=ticket_auto_root)
    allowed_tools = _parse_agent_frontmatter_tools(agent_md) if agent_md else None

    failing = sorted(_FAILING_VERDICTS.get(phase, frozenset()))
    passing = (sorted(_VERDICT_TOKENS - set(failing))
              if phase in LOOP_BEARING_PHASES else [])

    allowed_paths, disabled_reason = _resolve_allowed_paths(
        spawn.get('allowed_paths'), tid, env_vars)

    return {
        'tid': tid,
        'phase': phase,
        'step_id': step_id,
        'objective': spawn.get('description') or step.get('description') or '',
        'expected_behaviour': spawn.get('instructions') or '',
        'allowed_tools': allowed_tools,
        'success_criteria': {'claimed_verdict_in': passing} if passing else {},
        'failure_conditions': {
            'claimed_verdict_in': failing,
            'gate_stop_code': (step.get('loop') or {}).get('gate_stop_code') or None,
        },
        'allowed_paths': allowed_paths or None,
        'allowed_paths_disabled_reason': disabled_reason,
        'claim_predicates': _claim_predicates(phase, env_vars),
    }


def contract_path(state_dir, tid, phase):
    """`{tid}-{phase}-contract.json` — mirrors `spawn_worker`'s own slug."""
    return Path(state_dir) / f'{tid}-{phase.lower()}-contract.json'


def write_phase_contract(state_dir, table, step_id, tid, env_file=None,
                         ticket_auto_root=None):
    """Write the phase contract at spawn. Never raises — a write failure
    costs the observer's contract-dependent rules for this generation, not
    the spawn itself (same fail-soft posture as `_phase_write_identity`)."""
    contract = build_phase_contract(table, step_id, tid, env_file=env_file,
                                    ticket_auto_root=ticket_auto_root)
    try:
        contract_path(state_dir, tid, contract['phase']).write_text(
            json.dumps(contract))
    except OSError:
        pass
    return contract


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


# ── Ticket type resolution (task 10.1.2, design.md D22) ─────────────────────
#
# STEP_1_5's table `condition` ("bug tickets only") needs the ticket's type
# label. Shells out to `linear-api.sh`'s own `get_issue` rather than
# reimplementing the GraphQL query or the labels field shape (same
# discipline as `preamble.py`'s D13/D17 calls) — resolve once at first
# dispatch and cache the result; a ticket's type label is fixed at creation
# and never toggled mid-run (`state-machine.json`'s `planner_labels` table).

_TICKET_TYPE_LABELS = ('bug', 'feature', 'improvement', 'security', 'chore')


def resolve_ticket_type(tid, lib_dir=None, timeout=30):
    """The ticket's type label (`bug`/`feature`/...), or `None` if unresolvable.

    A missing/unresolvable label degrades to `None` (treated as "not a bug"
    by every caller) rather than raising — the same fail-soft posture
    `_agent_md_path`/`_parse_env_file` already take for optional context this
    module cannot get without a live Linear read.
    """
    lib_dir = lib_dir or os.environ.get(
        'CLAUDE_SKILLS_LIB', os.path.expanduser('~/.claude/skills/lib'))
    script = f'source "{lib_dir}/linear-api.sh" >/dev/null 2>&1 && get_issue "$1"'
    try:
        proc = subprocess.run(
            ['bash', '-c', script, 'bash', tid],
            capture_output=True, text=True, timeout=timeout)
        issue = json.loads(proc.stdout)
    except (OSError, subprocess.SubprocessError, ValueError):
        return None
    nodes = ((issue.get('labels') or {}).get('nodes')) or []
    labels = {(n.get('name') or '').lower() for n in nodes}
    for label in _TICKET_TYPE_LABELS:
        if label in labels:
            return label
    return None


# ── Step transitions (task 10.1, design.md D22) ─────────────────────────────
#
# Groups 1-9/11 give fleetd every primitive to run ONE phase. Nothing decided
# which step_id comes next once a phase finishes — this is that function.
# It plays the role `detect-resume.sh`'s backward log scan plays for the
# manual router, but computes forward from "the step that just finished plus
# its classified outcome" (already available from `classify_phase`/
# `evaluate_loop`) rather than re-deriving position from scratch each time,
# per D7's decision not to shell out to `detect-resume.sh` on the normal path.
#
# `PR_ITERATE` is a synthetic step_id, not present in `dispatch-table.json`.
# SKILL.md's own PR-REVIEW/WARN loop body spawns `/ticket-pr-iterate` as a
# hardcoded exception, never a table-declared step — the same is true here;
# see `build_pr_iterate_spawn` below rather than `build_phase_spawn`, which
# requires a real table entry.
PR_ITERATE = 'PR_ITERATE'

NEXT_ADVANCE = 'advance'
NEXT_TERMINAL = 'terminal'
NEXT_HOLD = 'hold'

NextStep = namedtuple(
    'NextStep',
    'kind step_id exit_code gate_stop_code hold_kind resume_step_id detail',
)
NextStep.__doc__ = """Where dispatch goes after one step finishes.

kind           — 'advance' (dispatch `step_id` next), 'terminal' (write the
                 finalize record and stop dispatching this ticket) or 'hold'
                 (create a `gate`-kind hold row and stop dispatching — the
                 already-live `Supervisor._hold_reconcile_pass`
                 (human-hold-store-foundation) does the release probe; this
                 function only ever creates the row).
step_id        — the next step to dispatch, kind='advance' only. May be
                 `PR_ITERATE`, which is not a real dispatch-table step_id —
                 see `build_pr_iterate_spawn`.
exit_code      — the code `pipeline-finalize.sh`'s equivalent should use,
                 kind='terminal' only (0 success, 1 gate-stop/exhaustion).
gate_stop_code — the named gate-stop code to record, kind='terminal' only,
                 '' when the terminal is a clean success (STEP_6 done).
hold_kind      — always 'gate' today (kind='hold' only) — `human` holds are
                 created by `human-hold-parse.sh`/`gate_hold.py`'s own path,
                 never by a step transition.
resume_step_id — always `STEP_3_5` today (kind='hold' only). `_hold_reconcile_pass`
                 clears the hold row but never touches `position` (design.md
                 D5 — it must stay a thin, generic reconciler, not a second
                 phase-dispatch authority). The caller must record this as
                 the ticket's position *at hold-creation time*, alongside
                 `store.set_hold`, so the position a plain release leaves
                 behind is already correct — mirrors `detect-resume.sh`'s own
                 `GATE_HELD` + approved-label → `STEP_3_5` transition, the
                 manual router's parity requirement (both hold sites, the
                 first hold from `STEP_2_5` and a re-hold from `STEP_3_5`
                 itself, resume at the same place — the reconcile agent,
                 never straight back to the bash gate).
detail         — human-readable reason, for logging only.
"""


def _advance(step_id, detail=''):
    return NextStep(NEXT_ADVANCE, step_id, None, '', '', '', detail)


def _terminal(exit_code, gate_stop_code='', detail=''):
    return NextStep(NEXT_TERMINAL, '', exit_code, gate_stop_code, '', '', detail)


def _hold(kind, detail=''):
    return NextStep(NEXT_HOLD, '', None, '', kind, 'STEP_3_5', detail)


def _gate_reconcile_held(log_lines):
    """Did the most recent GATE-reconcile completion hold again?

    Mirrors `detect-resume.sh`'s own distinction exactly: `GATE|reconcile|
    done|clean` advances the pipeline, `GATE|reconcile|done|cycle#N|held:
    ...` does not, even though both are `done` (GATE is not loop-bearing/
    phase-result-bearing, so `classify_phase` cannot tell them apart — this
    is intentionally a GATE-specific check, not a generalizable one).
    """
    for line in reversed(log_lines):
        fields = line.split('|', 4)
        if len(fields) == 5 and fields[1] == 'GATE' \
                and fields[2] == 'reconcile' and fields[3] == 'done':
            return 'held:' in fields[4]
    return False


def next_step(table, step_id, result, counters, log_lines=(), is_bug=False):
    """Given the step that just finished and its result, what happens next.

    `result` is a `PhaseOutcome` (from `classify_phase`) for every agent-
    spawning step, or a plain `int` exit code for a bash-only step
    (`STEP_2_5`/`STEP_3` — `gate-check.sh`, already run by
    `orchestration.run_bash_item`, which owns the exit-code semantics; this
    function only routes on the number). `log_lines` must be scoped to the
    step's own bracket, same contract as `classify_phase`. `counters` is the
    same dict `evaluate_loop` already takes. `is_bug` resolves STEP_1_5's
    table `condition` — see the caller-side note on caching it per ticket,
    not re-fetching per step.

    Ported step by step from `SKILL.md`'s Dispatch Loop / `detect-resume.sh`
    — see design.md D22 for the full transition table and the two things
    deliberately not ported (STEP_5_5 PR-comment reconciliation, phase
    inspectors).
    """
    counters = counters or {}

    if step_id == 'STEP_1':
        return _advance('STEP_1_5' if is_bug else 'STEP_2', 'appraise done')

    if step_id == 'STEP_1_5':
        return _advance('STEP_2', 'reproduce done')

    if step_id == 'STEP_2':
        return _advance('STEP_2_5', 'exec done')

    if step_id in ('STEP_2_5', 'STEP_3'):
        exit_code = int(result)
        if exit_code == 0:
            return _advance('STEP_4', 'gate auto-approved')
        if exit_code == 1:
            return _hold('gate', 'gate held for approval')
        return _terminal(1, '', 'gate-check structural failure (exit 2)')

    if step_id == 'STEP_3_5':
        loop_decision = evaluate_loop(
            table, step_id, counters, when='pre_dispatch')
        if loop_decision.action == LOOP_GATE_STOP:
            return _terminal(
                1, loop_decision.gate_stop_code, loop_decision.detail)
        if _gate_reconcile_held(log_lines):
            return _hold('gate', 'gate reconcile held again')
        return _advance('STEP_4', 'gate reconcile clean')

    if step_id == 'STEP_4':
        return _advance('STEP_4_5', 'implement done')

    if step_id == 'STEP_4_5':
        if result.result == 'done':
            return _advance('STEP_4_6', 'verify passed')
        loop_decision = evaluate_loop(
            table, step_id, counters, when='post_dispatch')
        if loop_decision.action == LOOP_GATE_STOP:
            return _terminal(
                1, loop_decision.gate_stop_code, loop_decision.detail)
        return _advance('STEP_4', 'verify failed, retry implement')

    if step_id == 'STEP_4_6':
        verdict = result.verdict
        if verdict == 'OK':
            return _advance('STEP_5', 'pr-review passed')
        if verdict == 'WARN':
            loop_decision = evaluate_loop(
                table, step_id, counters, when='post_dispatch')
            if loop_decision.action == LOOP_GATE_STOP:
                return _terminal(
                    1, loop_decision.gate_stop_code, loop_decision.detail)
            return _advance(PR_ITERATE, 'pr-review warn, iterate')
        return _terminal(1, '', f'pr-review blocked (verdict={verdict!r})')

    if step_id == PR_ITERATE:
        return _advance('STEP_4', 'pr-iterate done, re-implement')

    if step_id == 'STEP_5':
        # STEP_5_5 (PR comment reconciliation) is deliberately not ported —
        # design.md D22.
        return _advance('STEP_6', 'document/wiki-maintenance done')

    if step_id == 'STEP_6':
        return _terminal(0, '', 'pipeline complete')

    raise DispatchTableError(f'next_step: unknown step_id {step_id!r}')


def build_pr_iterate_spawn(tid, log_file, hb_log_file='', env_file='',
                          extra_env=None):
    """The one spawn `next_step` can return with no dispatch-table entry.

    Mirrors `build_phase_spawn`'s `PhaseSpawn` shape exactly, so a caller
    never has to special-case the return type — only the source of the
    values differs (hardcoded here, table-driven there), matching
    SKILL.md's own treatment of this exact loop body as inline prose rather
    than a table row.
    """
    env = {
        'LOG_FILE': str(log_file or ''),
        'HB_LOG_FILE': str(hb_log_file or ''),
        'HUSKY': '0',
        'FLEET_TICKET_ID': str(tid),
        'FLEET_PHASE': 'PR-REVIEW',
        'FLEET_STEP': 'pr-iterate',
        'FLEET_DISPATCH_STEP_ID': PR_ITERATE,
    }
    if env_file:
        env['FLEET_TICKET_ENV_FILE'] = str(env_file)
    if extra_env:
        env.update({k: str(v) for k, v in extra_env.items()})

    return PhaseSpawn(
        step_id=PR_ITERATE,
        step='pr-iterate',
        phase='PR-REVIEW',
        skill='/ticket-pr-iterate',
        prompt=f'/ticket-pr-iterate {tid}. '
               f'Apply the requested changes from the PR review.',
        env=env,
        attempt=None,
        loop_bearing=True,
        next_phase='PR-REVIEW',
        agent=None,
    )


# ── STEP_6 retro auto-trigger (task 10.1.6, design.md D22) ─────────────────
#
# STEP_6's table `spawn` (the `/ticket-retro` agent) is `conditional_on:
# "NEEDS_RETRO"` — `build_phase_spawn(table, 'STEP_6', ...)` already builds
# that spawn correctly (it does not interpret `conditional_on`, same as every
# other extra table field it ignores), so the only missing piece is this
# decision: whether to call it at all.

RETRO_REASON_GATE_STOP = 'gate-stop fired'
RETRO_REASON_NO_SUCCESS = 'no VERIFY PASS + PR-REVIEW OK'
RETRO_REASON_FALLBACK = 'heartbeat fallback event'
# Deliberately not the bare gate-stop code as a quoted literal — that string
# belongs to STEP_4_5's table entry alone (see `needs_retro`, which reads it
# via `table.loop`), and `TestLoopCaps.test_caps_are_not_duplicated_as_
# python_constants` fails loudly if a second Python literal ever claims it.
RETRO_REASON_VERIFY_EXHAUSTED = 'VERIFY exhaustion code present'
RETRO_REASON_VERIFY_FAIL = 'VERIFY fail'

RetroDecision = namedtuple('RetroDecision', 'needed reasons drift_detected')
RetroDecision.__doc__ = """Whether STEP_6 should auto-trigger `/ticket-retro`.

needed         — True if any condition fired.
reasons        — tuple of the condition names that fired, in check order.
drift_detected — condition 3 (a heartbeat `|fallback|` event) specifically.
                 SKILL.md's own check writes `META|drift|warn|...` to the
                 pipeline log as part of this same condition; that write is
                 the caller's job here (matching every other log-writing
                 side effect in this module — an evaluator reports, the
                 dispatch wiring or `orchestration.finalize_terminal` acts),
                 not this function's, so a test can call this read-only.
"""


def _retro_anchored(line, literal):
    """Field-anchored match: `^[^|]*|<literal>` in the bash checks this
    ports — the first field (the ISO timestamp) is any run of non-pipe
    chars, and `literal` must follow it exactly."""
    parts = line.split('|', 1)
    return len(parts) == 2 and parts[1].startswith(literal)


def needs_retro(table, log_file, hb_log_file=''):
    """Should STEP_6 auto-trigger a `/ticket-retro` agent?

    Ports SKILL.md's 5-condition retro-trigger check verbatim: a gate-stop
    fired anywhere in the log; the run lacks a *positive* success marker —
    both a `VERIFY|verify|done|PASS` line AND a `PR-REVIEW|pr-review|done|OK`
    line — tested as their absence, never as the absence of the STEP_6
    outcome line itself (that line is written by this same step, so testing
    for it was tautologically true on every run — GitHub #149); a heartbeat
    `|fallback|` event fired; STEP_4_5's own gate-stop code (`VERIFY_
    EXHAUSTED` in the shipped table, read via `table.loop` rather than
    hardcoded — see the constant's own comment above) appears anywhere (a
    safety net for condition 1 — gate-stop lines written inside an agent
    sub-shell may not be visible to the router's own file descriptor); or an
    explicit `VERIFY|verify|fail|` line appears (same sub-shell concern).
    Conditions 4/5 duplicate condition 1 in the common case; kept because
    the manual router keeps them.

    A missing `log_file` or `hb_log_file` (or an empty `hb_log_file`, the
    common case when heartbeat logging is off) reads as no lines — matching
    bash's own `2>/dev/null`-suppressed grep failure, never an error.
    """
    try:
        lines = Path(log_file).read_text().splitlines()
    except OSError:
        lines = []

    reasons = []
    if any('|META|gate-stop|fail|' in line for line in lines):
        reasons.append(RETRO_REASON_GATE_STOP)

    has_verify_pass = any(
        _retro_anchored(line, 'VERIFY|verify|done|PASS') for line in lines)
    has_pr_review_ok = any(
        _retro_anchored(line, 'PR-REVIEW|pr-review|done|OK')
        for line in lines)
    if not (has_verify_pass and has_pr_review_ok):
        reasons.append(RETRO_REASON_NO_SUCCESS)

    try:
        hb_lines = (Path(hb_log_file).read_text().splitlines()
                   if hb_log_file else [])
    except OSError:
        hb_lines = []
    drift_detected = any('|fallback|' in line for line in hb_lines)
    if drift_detected:
        reasons.append(RETRO_REASON_FALLBACK)

    verify_exhausted_code = str((table.loop('STEP_4_5') or {})
                                .get('gate_stop_code') or '')
    if verify_exhausted_code and any(
            verify_exhausted_code in line for line in lines):
        reasons.append(RETRO_REASON_VERIFY_EXHAUSTED)

    if any(_retro_anchored(line, 'VERIFY|verify|fail|') for line in lines):
        reasons.append(RETRO_REASON_VERIFY_FAIL)

    return RetroDecision(bool(reasons), tuple(reasons), drift_detected)
