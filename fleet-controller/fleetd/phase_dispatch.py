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
from collections import namedtuple
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
