"""Once-per-ticket preamble for fleetd (design.md D17, task 4.10).

Every phase skill assumes an operating environment it never builds itself: an
env file to source, a pipeline log carrying a schema line, a resolved branch
decision, a validated Linear team. On the manual path the router's Steps
0.1–0.6 establish all of it before the first agent runs. fleetd dispatches
individual phases, so on the automated path nothing did.

This module is deliberately thin. The work is in
`ticket-auto-pipeline/lib/ticket-preamble.sh`, for the reason D13 gave for the
terminal marker: a Python reimplementation would be a second authority on the
env-file grammar, the branch precedence chain and the pipeline-log format,
and the two would drift silently because both would look correct in
isolation. What lives here is the call, the result parse, and the routing
decision each failure implies.

**Idempotent by design, because fleetd re-enters it.** The preamble is not
"run once at the start of a ticket" — fleetd runs it before every dispatch.
After the first call it is a handful of greps and one file rewrite, and it
returns the same block. That is what makes a fleetd restart mid-ticket a
non-event: the restarted daemon calls it exactly as it would have anyway.

Stdlib only.
"""

import os
import subprocess
from collections import namedtuple
from pathlib import Path

from fleetd import phase_dispatch

# Exit codes, mirroring `ticket-preamble.sh`'s TP_* constants. Each one is a
# different action for the caller, which is why the script does not collapse
# them into a single failure code.
PREAMBLE_OK = 0
PREAMBLE_USAGE = 1
PREAMBLE_BRANCH_DIRECTIVE_INVALID = 2
PREAMBLE_BRANCH_RESOLVE_FAILED = 3
PREAMBLE_LINEAR_CONFIG_INVALID = 4
PREAMBLE_LINEAR_AUTH_FAILED = 5
PREAMBLE_ENV_WRITE_FAILED = 6

# What fleetd does about each.
#
# Exactly one failure is a gate-stop, and it is the one that is *about this
# ticket*: a malformed `## Branch Directive` on its parent epic. No retry
# clears it, and the code is already in this ticket's log because the script
# wrote it.
#
# Exit 1 is the code bash hands out for a script called wrong, and it is
# pointedly not the gate-stop: a caller passing a bad argument must never be
# recorded on a real ticket as a malformed branch directive. Nor is a failed
# env-file write, which is a host fault — but it does stop the dispatch, since
# a phase started without that file runs with no `REPOS_ROOT` and no
# `LINEAR_API_KEY` and reports nothing about it.
#
# The preflight failures are deliberately not gate-stops even though they are
# equally unclearable by retry. A rejected API key or a team whose states no
# longer match the state machine is a **fleet-wide** fault: every ticket fails
# it identically. Gate-stopping on it would write a per-ticket verdict for a
# global condition — a queue of tickets each individually marked halted, each
# needing individual un-halting once the operator fixes one setting. Held off
# instead, they simply resume. Fleet health detection is the right place for
# that signal to become loud, and it already watches for it.
ACTION_PROCEED = 'proceed'
ACTION_GATE_STOP = 'gate-stop'
ACTION_RETRY_LATER = 'retry-later'

_ACTIONS = {
    PREAMBLE_OK: ACTION_PROCEED,
    PREAMBLE_USAGE: ACTION_RETRY_LATER,
    PREAMBLE_BRANCH_DIRECTIVE_INVALID: ACTION_GATE_STOP,
    PREAMBLE_BRANCH_RESOLVE_FAILED: ACTION_RETRY_LATER,
    PREAMBLE_LINEAR_CONFIG_INVALID: ACTION_RETRY_LATER,
    PREAMBLE_LINEAR_AUTH_FAILED: ACTION_RETRY_LATER,
    PREAMBLE_ENV_WRITE_FAILED: ACTION_RETRY_LATER,
}

# No new gate-stop codes are minted here — the one code used is the existing
# `BRANCH_DIRECTIVE_INVALID`, and the script is its writer.
_GATE_STOP_CODES = {
    PREAMBLE_BRANCH_DIRECTIVE_INVALID: 'BRANCH_DIRECTIVE_INVALID',
}

_RESULT_FIELDS = (
    'TICKET_ID', 'ENV_FILE', 'LOG_FILE', 'HB_LOG_FILE', 'CLAUDE_LOG_FILE',
    'AUTONOMY', 'FROM_PLANNED', 'BASE_BRANCH', 'INTEGRATION_BRANCH',
    'TICKET_BRANCH', 'BRANCH_SOURCE', 'BRANCH_ORIGIN', 'UAT_POLICY',
    'MERGE_POLICY', 'REPOS_ROOT',
)

PreambleResult = namedtuple(
    'PreambleResult',
    'ok action exit_code gate_stop_code fields detail',
)
PreambleResult.__doc__ = """The outcome of one preamble call.

fields — the parsed TICKET_PREAMBLE_RESULT block, empty on failure. Its
         `ENV_FILE` is what `build_phase_spawn`'s `env_file` argument takes,
         and `LOG_FILE`/`HB_LOG_FILE` are what every phase and every terminal
         marker write to.
action — 'proceed', 'gate-stop' or 'retry-later'. Routing is on the exit
         code, never on stderr text.
"""


class PreambleError(RuntimeError):
    """The preamble could not be run at all (script missing, timed out)."""


def preamble_script(lib_dir=None):
    lib = Path(lib_dir) if lib_dir else phase_dispatch.ticket_auto_lib_dir()
    return lib / 'ticket-preamble.sh'


def parse_result_block(text):
    """Parse the `TICKET_PREAMBLE_RESULT` block into a dict.

    Unknown keys are ignored rather than rejected: the block is append-only
    by the same convention as `META|branch-context`, so a newer script paired
    with an older fleetd must degrade to "that field is not there yet" and
    not to a crash.
    """
    fields = {}
    in_block = False
    for line in (text or '').splitlines():
        if line.startswith('TICKET_PREAMBLE_RESULT:'):
            in_block = True
            continue
        if not in_block:
            continue
        if not line.startswith('  '):
            break
        key, sep, value = line.strip().partition(':')
        if not sep:
            continue
        if key in _RESULT_FIELDS:
            fields[key] = value.strip()
    return fields


def run_preamble(tid, project_dir=None, logs_dir=None, autonomy='',
                 from_planned=False, branch_flag='', skip_preflight=False,
                 lib_dir=None, timeout=180):
    """Establish (or re-confirm) one ticket's operating environment.

    Call before every phase dispatch, not only the first. On a ticket already
    under way this is cheap and returns the identical block; on a ticket whose
    branch decision is already recorded it never touches Linear for it again.

    `skip_preflight` exists for the second and later calls within one fleetd
    lifetime: the Linear config check is sentinel-cached anyway, but the
    `get_me` call is not, and paying one round trip per phase per ticket buys
    nothing a per-daemon check does not.
    """
    script = preamble_script(lib_dir)
    if not script.is_file():
        raise PreambleError(f'ticket-preamble.sh not found at {script}')

    args = [
        'bash', str(script),
        f'TICKET_ID={tid}',
        f'PROJECT_DIR={project_dir or os.getcwd()}',
        f'FROM_PLANNED={"true" if from_planned else "false"}',
    ]
    if logs_dir:
        args.append(f'LOGS_DIR={logs_dir}')
    if autonomy:
        args.append(f'AUTONOMY={autonomy}')
    if branch_flag:
        args.append(f'BRANCH_FLAG={branch_flag}')
    if skip_preflight:
        args.append('SKIP_PREFLIGHT=true')

    try:
        proc = subprocess.run(args, capture_output=True, text=True,
                              timeout=timeout)
    except (subprocess.TimeoutExpired, OSError) as exc:
        raise PreambleError(f'preamble failed for {tid}: {exc}') from exc

    code = proc.returncode
    fields = parse_result_block(proc.stdout) if code == PREAMBLE_OK else {}
    detail = (proc.stderr or '').strip().splitlines()[-1:] or ['']

    # An exit code the script does not define is not proceedable. Treating an
    # unknown failure as retryable would loop; treating it as a gate-stop
    # would strand a ticket on a bug in this file. Retry-later is the reading
    # that neither loses the ticket nor writes a verdict we cannot justify.
    action = _ACTIONS.get(code, ACTION_RETRY_LATER)

    if code == PREAMBLE_OK and not fields.get('ENV_FILE'):
        # Exit 0 with no block means the script ran but produced nothing to
        # spawn against — never promote that to success. Same rule as D12's:
        # a zero exit is not positive evidence.
        return PreambleResult(False, ACTION_RETRY_LATER, code, '', {},
                              'preamble exited 0 without a result block')

    return PreambleResult(
        code == PREAMBLE_OK, action, code,
        _GATE_STOP_CODES.get(code, ''), fields, detail[0],
    )
