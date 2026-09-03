"""Non-agent orchestration steps for fleetd (design.md D20, task 4.11).

Between two agent spawns the router runs a dozen things that are not agents:
`return-completeness-check.sh`, `outcome-label-check.sh`,
`planned-feedback-write.sh`, three advisory inspector spawns, a `flow.sh`
trigger, the auto-merge check, worktree release and the exit finalizer. Every
one of them has an effect something downstream depends on — a Linear state, a
label the auto-merge check reads, a `META` line a detector greps — and none of
them had an owner on the automated path.

**They are declared in `dispatch-table.json`, not enumerated here.** Each step
already carries `pre_dispatch` and `post_dispatch` arrays naming its
orchestration by `kind`. This module is the executor for those arrays, and
deliberately holds no list of its own: a second list would be the dual
authority D3 removed from the dispatch table itself, and the drift would be
invisible — the table would say a step runs `outcome-label-check.sh` while the
supervisor quietly did not.

So adding an orchestration step is a table edit, and a `kind` this module does
not implement is a loud `unsupported` result rather than a silent skip.

**What is deliberately not here.** Task 4.11 listed five `flow.sh` triggers;
only two are the router's. `implement-complete` is fired by the router
(`SKILL.md:897-910`) and `appraise-start` before the first spawn. The other
three — `human-approve`, `pr-review-pass-done`/`-uat`, `uat-pass` — are fired
by the phase skill that earns them (`gate-check.sh`, `ticket-pr-review`,
`ticket-verify`), as is `ensure_worktree` (`ticket-implement`). Those travel
inside the phase subprocess and need no owner in the dispatch layer; giving
them one would mean two parties triggering one transition.

**Advisory failures are recorded, never fatal.** The inspectors, the
phase-result parse and the planner-feedback writer are observations. A failed
observation that halted a ticket would make the pipeline less reliable for
having been instrumented.

Stdlib only.
"""

import os
import subprocess
import time
from collections import namedtuple
from pathlib import Path

from fleetd import phase_dispatch

# What an item's failure means. `blocking` is the table's own word for it.
FAIL_STOP = 'gate_stop'
FAIL_CONTINUE = 'log_and_continue'
FAIL_WARN = 'warn-only'

# Result statuses.
OK = 'ok'
FAILED = 'failed'
SKIPPED = 'skipped'
UNSUPPORTED = 'unsupported'

StepResult = namedtuple('StepResult', 'kind status detail blocking exit_code')
StepResult.__doc__ = """The outcome of one declared orchestration item.

blocking — whether a `failed` status should stop the pipeline. Read from the
           table's own `on_failure`/`blocking`/`enforcement` fields rather
           than decided here, so the escalation policy lives beside the step
           it governs.
"""


def _is_blocking(item):
    """Whether a failure of this item stops the pipeline.

    Three different table fields express the same idea, because they were
    added at different times for different steps. Reading all three here
    keeps that history out of every call site.
    """
    if item.get('blocking') is False:
        return False
    if item.get('enforcement') in (FAIL_WARN, 'warn-only'):
        return False
    on_failure = item.get('on_failure')
    if on_failure in (FAIL_CONTINUE, 'warn-continue'):
        return False
    if on_failure == FAIL_STOP:
        return True
    # Unstated. A bash check between phases exists to gate something; the
    # advisory ones say so explicitly, so silence means blocking.
    return item.get('kind') == 'bash'


def orchestration_items(table, step_id, when):
    """The declared items for one step, in table order.

    `when` is 'pre_dispatch' or 'post_dispatch'. Order is significant and is
    the table's: `outcome-label-check.sh` must run before the auto-merge check
    that reads the label it writes, and before `implement-complete`.
    """
    try:
        step = table.get(step_id)
    except phase_dispatch.DispatchTableError:
        return []
    return list(step.get(when) or [])


def run_bash_item(item, ctx, lib_dir=None, timeout=600):
    """Run a `kind: bash` item — one of the deterministic between-phase gates.

    The script name comes from the table and is resolved against the lib
    directory; it is never interpolated into a shell string, and its arguments
    are passed as a list.
    """
    lib = Path(lib_dir) if lib_dir else phase_dispatch.ticket_auto_lib_dir()
    script = lib / str(item.get('script') or '')
    blocking = _is_blocking(item)
    if not item.get('script') or not script.is_file():
        return StepResult('bash', FAILED, f'script not found: {script}',
                          blocking, None)

    args = ['bash', str(script), ctx['tid']] + [str(a) for a in
                                                (item.get('args') or [])]
    env = {**os.environ}
    for key in ('LOG_FILE', 'HB_LOG_FILE', 'CLAUDE_LOG_FILE', 'TICKET_DIR'):
        if ctx.get(key):
            env[key] = str(ctx[key])
    try:
        proc = subprocess.run(args, capture_output=True, text=True,
                              timeout=timeout, env=env)
    except (subprocess.TimeoutExpired, OSError) as exc:
        return StepResult('bash', FAILED, f'{script.name}: {exc}', blocking,
                          None)
    status = OK if proc.returncode == 0 else FAILED
    detail = (proc.stderr or proc.stdout or '').strip().splitlines()[-1:]
    return StepResult('bash', status, detail[0] if detail else script.name,
                      blocking, proc.returncode)


def run_flow_trigger(item, ctx, lib_dir=None, timeout=180):
    """Fire one `flow.sh` trigger.

    `flow.sh` stays the only party that mutates Linear (the repository's
    determinism boundary), so this shells out to it rather than reaching for
    the API. Exit 7 is `STATE_ASSERTION_FAILED` and is always blocking
    regardless of what the item declares: the assertion failing means Linear
    is not in the state the pipeline believes it is, and continuing compounds
    the divergence — the same rule `route_exit_code` applies after a phase.
    """
    flow = _flow_script(lib_dir)
    trigger = str(item.get('trigger') or '')
    blocking = _is_blocking(item)
    if flow is None:
        return StepResult('flow_trigger', FAILED, 'flow.sh not found',
                          blocking, None)
    if not trigger:
        return StepResult('flow_trigger', FAILED, 'no trigger named', blocking,
                          None)

    args = ['bash', str(flow), ctx['tid'], trigger]
    for key, value in (item.get('data') or {}).items():
        args.append(f'{key}={value}')
    try:
        proc = subprocess.run(args, capture_output=True, text=True,
                              timeout=timeout, env={**os.environ})
    except (subprocess.TimeoutExpired, OSError) as exc:
        return StepResult('flow_trigger', FAILED, f'{trigger}: {exc}',
                          blocking, None)
    if proc.returncode == phase_dispatch.FLOW_STATE_ASSERTION_EXIT:
        return StepResult('flow_trigger', FAILED,
                          f'{trigger}: STATE_ASSERTION_FAILED', True,
                          proc.returncode)
    status = OK if proc.returncode == 0 else FAILED
    return StepResult('flow_trigger', status, trigger, blocking,
                      proc.returncode)


AUTO_MERGE_MODES = ('auto', 'semi-auto')
SMOOTH = 'Smooth'


def _last_log_msg(log_file, needle):
    """Field 5+ of the last line containing `needle`, or ''.

    Joined rather than `cut -f5`: a message containing a pipe would otherwise
    be silently truncated, which is the pipeline log's oldest sharp edge.
    """
    try:
        lines = Path(log_file).read_text().splitlines()
    except (OSError, TypeError):
        return ''
    for line in reversed(lines):
        if needle in line:
            parts = line.split('|')
            return '|'.join(parts[4:]).strip() if len(parts) > 4 else ''
    return ''


def run_auto_merge(item, ctx, lib_dir=None, timeout=120):
    """Merge a passing PR, when every declared condition holds.

    Four conditions, all from the table: autonomy is `auto` or `semi-auto`
    (`manual` never merges), complexity is simple, the confirmed outcome label
    is `Smooth`, and the PR is not an epic integration PR.

    Two orderings are load-bearing and both were wrong somewhere before:

    * **The PR number is resolved before the integration guard, not after.**
      In `SKILL.md` the guard read `$_pr_num` above the line that assigned it,
      so it ran `gh pr view ""`, got an empty head ref, never matched, and
      guarded nothing — an integration PR could be auto-merged by the code
      written to prevent exactly that. Fixed there too.
    * **The outcome is read from `META|outcome-label|info|`, never from the
      IMPLEMENT terminal line**, which does not carry Smooth/Rough/Hard at
      all. That is why `outcome-label-check.sh` is ordered before this item in
      the table: it writes the label this reads.

    An integration PR is one whose *head* is the epic branch. A ticket PR
    merely targets it as a base, which is the ordinary case and must still
    merge.
    """
    log_file = ctx.get('LOG_FILE') or ''
    autonomy = (ctx.get('autonomy') or '').strip()
    complexity = (ctx.get('complexity') or '').strip()
    integration = (ctx.get('integration_branch') or '').strip()

    if autonomy not in AUTO_MERGE_MODES:
        return StepResult('auto_merge', SKIPPED,
                          f'autonomy={autonomy or "unset"}', False, None)
    if complexity != 'simple':
        return StepResult('auto_merge', SKIPPED,
                          f'complexity={complexity or "unset"}', False, None)

    outcome = _last_log_msg(log_file, '|META|outcome-label|info|')
    if outcome != SMOOTH:
        return StepResult('auto_merge', SKIPPED,
                          f'outcome={outcome or "unrecorded"}', False, None)

    pr_num = _last_log_msg(log_file, '|PR-REVIEW|checkout-pr|done|')
    if not pr_num:
        return StepResult('auto_merge', SKIPPED, 'no PR number recorded',
                          False, None)

    if integration:
        head = _gh(['pr', 'view', pr_num, '--json', 'headRefName', '--jq',
                    '.headRefName'], timeout)
        if head is None:
            # Cannot establish that this is not an integration PR. Refusing to
            # merge is the only safe reading: the guard exists because an
            # auto-merged integration PR is not undoable by the pipeline.
            return StepResult('auto_merge', SKIPPED,
                              f'could not read PR {pr_num} head ref', False,
                              None)
        if head == integration:
            _append(log_file, f'|META|pr-auto-merge|skip|INTEGRATION_PR_GUARD: '
                              f'{pr_num} is an integration PR, not '
                              f'auto-merging')
            return StepResult('auto_merge', SKIPPED,
                              f'{pr_num} is an integration PR', False, None)

    merged = _gh(['pr', 'merge', pr_num, '--squash', '--auto'], timeout)
    if merged is None:
        # Fail-soft, matching the router's `|| true`: an unmergeable PR is a
        # human's to look at, not a reason to fail a finished ticket.
        return StepResult('auto_merge', FAILED, f'gh pr merge {pr_num} failed',
                          False, None)
    return StepResult('auto_merge', OK, f'merged {pr_num}', False, 0)


def _gh(args, timeout):
    """Run `gh` and return its trimmed stdout, or None on any failure."""
    try:
        proc = subprocess.run(['gh'] + args, capture_output=True, text=True,
                              timeout=timeout, env={**os.environ})
    except (subprocess.TimeoutExpired, OSError):
        return None
    if proc.returncode != 0:
        return None
    return (proc.stdout or '').strip()


def _append(log_file, suffix):
    """Append one pipeline-log line, timestamped. Fail-soft."""
    if not log_file:
        return
    from datetime import datetime, timezone
    iso = datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
    try:
        with open(log_file, 'a') as fh:
            fh.write(f'{iso}{suffix}\n')
    except OSError:
        pass


def run_worktree(item, ctx, lib_dir=None, timeout=120):
    """Release the ticket's git worktree.

    Non-fatal by design and by the table: a worktree that will not remove is
    disk to reclaim later, never a reason to fail a ticket whose work is done.
    Ordered after STEP_5 so the document agents still had it for `git diff`.
    """
    lib = Path(lib_dir) if lib_dir else phase_dispatch.ticket_auto_lib_dir()
    helper = lib / 'worktree.sh'
    function = str(item.get('function') or 'release_worktree')
    if not helper.is_file():
        return StepResult('worktree', SKIPPED, 'worktree.sh not present',
                          False, None)
    bash_cmd = f'source "$WT_HELPER" && {function} "$WT_TID"'
    env = {**os.environ, 'WT_HELPER': str(helper), 'WT_TID': ctx['tid']}
    try:
        proc = subprocess.run(['bash', '-c', bash_cmd], capture_output=True,
                              text=True, timeout=timeout, env=env)
    except (subprocess.TimeoutExpired, OSError) as exc:
        return StepResult('worktree', FAILED, f'{function}: {exc}', False,
                          None)
    if proc.returncode != 0:
        _append(ctx.get('LOG_FILE'),
                f'|META|worktree-release|warn|{function} failed for '
                f'{ctx["tid"]}')
        return StepResult('worktree', FAILED, f'{function} exited '
                          f'{proc.returncode}', False, proc.returncode)
    return StepResult('worktree', OK, function, False, 0)


def run_finalize(item, ctx, lib_dir=None, timeout=120):
    """Run `pipeline-finalize.sh` — post-mortem plus the `META|outcome` write.

    Called at every exit path, not only a successful one, which is why it is
    safe to call here unconditionally: the script's own tail-check guard makes
    a repeat a no-op unless the outcome is not already the last line.
    """
    lib = Path(lib_dir) if lib_dir else phase_dispatch.ticket_auto_lib_dir()
    script = lib / str(item.get('script') or 'pipeline-finalize.sh')
    if not script.is_file():
        return StepResult('finalize', FAILED, f'not found: {script}', False,
                          None)
    args = ['bash', str(script), ctx['tid'], str(ctx.get('exit_code', 0)),
            str(ctx.get('LOG_FILE') or '')]
    try:
        proc = subprocess.run(args, capture_output=True, text=True,
                              timeout=timeout, env={**os.environ})
    except (subprocess.TimeoutExpired, OSError) as exc:
        return StepResult('finalize', FAILED, f'pipeline-finalize: {exc}',
                          False, None)
    status = OK if proc.returncode == 0 else FAILED
    return StepResult('finalize', status, script.name, False, proc.returncode)


def run_env(item, ctx, lib_dir=None, timeout=None):
    """Apply a `kind: env` item — a variable the next spawn must carry.

    The table's one use is `CLAUDE_LOG_FILE` given a per-attempt path, so a
    verify retry does not overwrite the previous attempt's transcript. The
    value is written into `ctx`, which `build_phase_spawn` reads, rather than
    into this process's environment: fleetd supervises many tickets at once,
    and a per-ticket value in the daemon's own env would leak across them.
    """
    name = str(item.get('export') or '')
    if not name:
        return StepResult('env', FAILED, 'no variable named', False, None)
    value = str(item.get('value') or '')
    # The table writes shell idioms for the router to expand. fleetd resolves
    # the two it uses rather than invoking a shell for a filename.
    value = value.replace('{TICKET-ID}', ctx['tid'])
    value = value.replace('{TICKET_ID}', ctx['tid'])
    if '$(date +%s)' in value:
        value = value.replace('$(date +%s)', str(int(time.time())))
    ctx.setdefault('env', {})[name] = value
    return StepResult('env', OK, f'{name}={value}', False, 0)


def _flow_script(lib_dir=None):
    """Locate `flow.sh` — monorepo layout, then the installed skill."""
    lib = Path(lib_dir) if lib_dir else phase_dispatch.ticket_auto_lib_dir()
    for cand in (lib / '..' / 'skills' / 'ticket-flow' / 'flow.sh',
                 Path.home() / '.claude' / 'skills' / 'ticket-flow'
                 / 'flow.sh'):
        if cand.is_file():
            return cand.resolve()
    return None


def plan_step(table, step_id, when, ctx):
    """Classify a step's declared items without running any of them.

    Returns `(runnable, unsupported)`. Separating planning from execution is
    what makes the coverage test in Group 5 possible: it can assert that every
    item every step declares is one this module implements, without spawning a
    single subprocess or touching Linear.
    """
    runnable, unsupported = [], []
    for item in orchestration_items(table, step_id, when):
        if item.get('kind') in IMPLEMENTED_KINDS:
            runnable.append(item)
        else:
            unsupported.append(item)
    return runnable, unsupported


def run_step_orchestration(table, step_id, when, ctx, lib_dir=None,
                           runners=None):
    """Run every declared item for one step, in table order.

    Stops at the first blocking failure and returns what ran; an advisory
    failure is recorded and the sequence continues. `runners` is injected so a
    test can drive the ordering and the stop-on-blocking rule without a Linear
    account or a shell.
    """
    runners = _RUNNERS if runners is None else runners
    results = []
    for item in orchestration_items(table, step_id, when):
        kind = item.get('kind')
        runner = runners.get(kind)
        if runner is None:
            # Loud, not silent. An unimplemented kind means the table declares
            # an effect nothing produces, and a downstream consumer is reading
            # a label or a state that will never be written.
            results.append(StepResult(kind, UNSUPPORTED,
                                      f'no runner for kind {kind!r}',
                                      _is_blocking(item), None))
            continue
        result = runner(item, ctx, lib_dir=lib_dir)
        results.append(result)
        if result.status == FAILED and result.blocking:
            break
    return results


def _unsupported_runner(kind):
    def _runner(item, ctx, lib_dir=None):
        return StepResult(kind, UNSUPPORTED, f'kind {kind!r} not implemented',
                          _is_blocking(item), None)
    return _runner


# Kinds this module executes. The advisory ones — `inspector`, `preflight`,
# `env`, `auto_merge`, `worktree`, `finalize` — are registered as explicitly
# unsupported rather than omitted, so `plan_step` reports them as known-absent
# instead of the coverage test reading their absence as an unknown kind. They
# are the next tranche of work, and naming them here is what keeps that
# visible.
_RUNNERS = {
    'bash': run_bash_item,
    'flow_trigger': run_flow_trigger,
    'env': run_env,
    'auto_merge': run_auto_merge,
    'worktree': run_worktree,
    'finalize': run_finalize,
    # The two that are genuinely not the dispatch layer's, each for its own
    # reason rather than as a backlog entry:
    #
    # `inspector` is a `guidance-extractor` agent spawn. It is a spawn, so it
    # belongs to the dispatch loop that owns spawning (task 4.1), not to a
    # between-phase executor — routing it here would give fleetd two places
    # that fork phase workers.
    #
    # `preflight` checks that MCP tools (`browser_navigate`, `get_issue`) are
    # reachable. Reachability is a property of the *agent's* session, not of
    # fleetd's process: fleetd answering it would answer a different question
    # and the answer would be worth nothing. The table's own `on_failure`
    # already says "log and proceed — the failure still counts as an attempt",
    # so it stays inside the phase.
    'inspector': _unsupported_runner('inspector'),
    'preflight': _unsupported_runner('preflight'),
}

# Every kind the shipped table uses today. The Group 5 coverage test asserts
# the table declares nothing outside this set — a new kind added to the table
# without a runner would otherwise reach production as a silent no-op.
KNOWN_KINDS = frozenset(_RUNNERS)

# The subset this module actually performs. Kept distinct from KNOWN_KINDS on
# purpose: "the table uses a kind we have heard of" and "the table uses a kind
# we execute" are different facts, and conflating them is how a registered
# placeholder starts reading as coverage.
IMPLEMENTED_KINDS = frozenset({
    'bash', 'flow_trigger', 'env', 'auto_merge', 'worktree', 'finalize',
})
