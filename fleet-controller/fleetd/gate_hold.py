"""Gate-hold reconciliation for fleetd (design.md D14, task 4.14).

A ticket that fails its approval gate is **parked as a row**, not as a
process. `tickets.held` is set, dispatch stops, and nothing stays alive.
That is what makes an indefinite wait for a human survivable across a fleetd
restart — and it is the property that ruled out execution engines which cannot
pause. D1 rejects native dynamic workflows on exactly this ground, so the pause
has to actually be a row for the rejection to be consistent.

Three things here are decisions rather than mechanics:

* **`gate-check.sh` stays the only authority on "is this approved".**
  This module re-runs `--mode entry`, the same check that set the hold, and
  reads its exit code. It never inspects a label itself. A second evaluator is
  a second thing that can disagree about whether a ticket is approved, and the
  disagreement would be invisible — both would look right in isolation.

* **`--mode entry`, not `--mode reapprove`.** They sound interchangeable and
  are not. `reapprove` writes `META|gate-stop|fail|APPROVAL_REVOKED` on any
  non-pass (`gate-check.sh:641`), so polling a held ticket with it would
  gate-stop a ticket whose human simply has not looked at it yet. `entry`
  returns 1 for "still held" — a non-event — and is also the check that knows
  how a hold is legitimately cleared: an `approved` label on a complex ticket
  (`gate-check.sh:522-536`).

* **A poll that changes nothing writes nothing.** `entry` logs a
  `GATE|gate|fail|held: …` line every time it holds. Run on its own cadence
  against a ticket waiting over a weekend, that is a few hundred identical
  lines in the pipeline log — and the pipeline log is what `detect-resume.sh`,
  the detectors and the OTel exporter all read. So the check runs against a
  scratch log, and its lines are appended to the real one only when the answer
  changed: released, or gate-stopped.

* **A gate that could not run is not a gate that held.** `UNAVAILABLE` is a
  fourth result alongside `release`/`hold`/`gate-stop`, returned for a probe
  timeout, an undocumented exit code, or a `hold_kind` with no registered
  predicate. It leaves the row untouched and is never collapsed into `hold`:
  a genuine hold is evidence a human has not acted and may legitimately feed
  an escalation clock, while `UNAVAILABLE` is evidence of nothing — an hour
  of API downtime must not look like an hour of human silence. It is also
  never a `release` (resuming on a premise nothing evaluated) or a
  `gate-stop` (killing a ticket over a missing feature rather than an unmet
  condition).

The release predicate is selected by the row's `hold_kind` (design.md D6).
`'gate'` maps to `run_entry_gate` below, unchanged; `'human'`
(human-hold-protocol) maps to `_reconcile_human_hold`, which reads Linear
comments instead of re-running a bash gate. Any other kind resolves to
`UNAVAILABLE` — reserved for a future kind (`external`/`deploy`) with no
predicate registered yet.

Stdlib only.
"""

import json
import os
import subprocess
import tempfile
import time
from collections import namedtuple
from pathlib import Path

from fleetd import phase_dispatch

# Exit codes of `gate-check.sh --mode entry`, per the dispatch table's
# `STEP_2_5.bash.exit_codes`.
GATE_ENTRY_PASS = 0
GATE_ENTRY_HELD = 1
GATE_ENTRY_STOP = 2

# The step a released hold dispatches: gate reconcile, which is also where the
# `RECONCILE_CYCLE` cap lives.
GATE_RECONCILE_STEP = 'STEP_3_5'

RELEASE = 'release'
HOLD = 'hold'
GATE_STOP = 'gate-stop'
UNAVAILABLE = 'unavailable'

# The 'human' predicate's own two extra results, folded into the four above
# by _reconcile_human_hold: ANSWERED -> RELEASE, NOT_ANSWERED -> HOLD,
# UNAVAILABLE is shared.
ANSWERED = 'answered'
NOT_ANSWERED = 'not_answered'

DEFAULT_RECONCILE_INTERVAL_SECS = 300
DEFAULT_HOLD_MAX_ATTEMPTS = 3

GateHoldDecision = namedtuple(
    'GateHoldDecision',
    'action tid cycle exit_code gate_stop_code position detail '
    'hold_id hold_generation',
    defaults=('', 0),
)
GateHoldDecision.__doc__ = """What to do with one held ticket, right now.

action   — 'release' (clear the hold, dispatch GATE_RECONCILE_STEP, resume
           from `position`), 'hold' (nothing changed, evidence a human has
           not yet acted), 'gate-stop', or 'unavailable' (the release
           predicate could not run or did not answer — evidence of nothing,
           and never collapsed into 'hold': see the module docstring on
           UNAVAILABLE).
cycle    — the reconcile cycle this decision belongs to.
position — where dispatch had reached when the hold was set; what a release
           resumes from. fleetd recorded it as dispatch happened, so it is
           known rather than reconstructed (design.md D7).
hold_id / hold_generation — carried from the row so the caller can release
           with store.release_hold's compare-and-swap guard.
"""


def reconcile_interval_secs():
    """Seconds between gate-hold reconciliation passes.

    Deliberately its own cadence rather than a step of the detection sweep.
    Detection reads local logs and runs often; a held-ticket re-check is a
    Linear round trip per held ticket. Tying them together would scale API
    traffic with the detection interval to no purpose — a human attaching an
    `approved` label is not a sub-minute-latency event.
    """
    raw = os.environ.get('FLEET_GATE_RECONCILE_INTERVAL',
                         str(DEFAULT_RECONCILE_INTERVAL_SECS))
    try:
        value = int(raw)
    except (TypeError, ValueError):
        return DEFAULT_RECONCILE_INTERVAL_SECS
    return value if value > 0 else DEFAULT_RECONCILE_INTERVAL_SECS


def is_due(last_run_epoch, now=None, interval=None):
    """Whether a reconciliation pass is due. `None` means never run."""
    if last_run_epoch is None:
        return True
    now = time.time() if now is None else now
    interval = reconcile_interval_secs() if interval is None else interval
    return (now - last_run_epoch) >= interval


def run_entry_gate(tid, hb_log_file='', lib_dir=None, timeout=120):
    """Run `gate-check.sh --mode entry` against a scratch log.

    Returns `(exit_code, log_lines)` — the lines the gate wanted to write. The
    caller decides whether they reach the real pipeline log; see the module
    docstring on why a no-change poll must stay silent.

    An exit code that is not one of the gate's three documented values is
    reported as-is rather than coerced: a gate that could not run at all is a
    different fact from a gate that held, and collapsing them would strand a
    ticket in a hold no re-check could ever clear.
    """
    lib = Path(lib_dir) if lib_dir else phase_dispatch.ticket_auto_lib_dir()
    script = lib / 'gate-check.sh'
    if not script.is_file():
        raise FileNotFoundError(f'gate-check.sh not found at {script}')

    with tempfile.TemporaryDirectory(prefix='fleetd-gate-') as tmp:
        scratch = Path(tmp) / f'{tid}-gate-probe.log'
        scratch.write_text('')
        try:
            proc = subprocess.run(
                ['bash', str(script), tid, str(scratch), str(hb_log_file),
                 '--mode', 'entry'],
                capture_output=True, text=True, timeout=timeout,
            )
            code = proc.returncode
        except subprocess.TimeoutExpired:
            return None, []
        lines = [ln for ln in scratch.read_text().splitlines() if ln.strip()]
    return code, lines


def reconcile_hold(table, tid, ticket_row, log_file, hb_log_file='',
                   lib_dir=None, entry_gate=None, answer_probe=None):
    """Decide the fate of one held ticket, dispatched by its `hold_kind`.

    An unregistered kind resolves to `UNAVAILABLE` rather than a guess —
    never a `release` (a premise nothing evaluated) and never a `gate-stop`
    (killing a ticket over a missing feature). This is what let this
    module and `human-hold-protocol` ship in either review order without a
    window where a `'human'` row was mishandled (design.md D6) — `'human'`
    is registered now, but any future kind gets the same protection.

    `entry_gate` is the probe callable for the `'gate'` predicate;
    `answer_probe` is the probe callable for the `'human'` predicate. Both
    are injected so a test can drive every branch without a live gate or a
    Linear account, and both default to their real implementation
    (`run_entry_gate` / `probe_human_answer`) — every predicate receives
    both kwargs regardless of which one it actually uses.
    """
    kind = (ticket_row or {}).get('hold_kind') or ''
    hold_id = (ticket_row or {}).get('hold_id') or ''
    hold_generation = int((ticket_row or {}).get('hold_generation') or 0)
    cycle = int((ticket_row or {}).get('reconcile_cycle') or 0)
    position = (ticket_row or {}).get('position') or ''
    held_at = (ticket_row or {}).get('held_at') or ''
    fenced_generation = (ticket_row or {}).get('fenced_generation')

    predicate = _RELEASE_PREDICATES.get(kind)
    if predicate is None:
        return GateHoldDecision(
            UNAVAILABLE, tid, cycle, None, '', position,
            f'no release predicate registered for hold_kind {kind!r}',
            hold_id, hold_generation)

    return predicate(
        table=table, tid=tid, cycle=cycle, position=position,
        hold_id=hold_id, hold_generation=hold_generation,
        log_file=log_file, hb_log_file=hb_log_file, lib_dir=lib_dir,
        entry_gate=entry_gate, held_at=held_at,
        fenced_generation=fenced_generation, answer_probe=answer_probe)


def _reconcile_gate_hold(table, tid, cycle, position, hold_id,
                         hold_generation, log_file, hb_log_file='',
                         lib_dir=None, entry_gate=None, held_at='',
                         fenced_generation=None, answer_probe=None):
    """The `'gate'` release predicate: today's `run_entry_gate`, unchanged.

    `gate-check.sh` remains the only authority on "is this approved" — this
    still runs `--mode entry` (never `--mode reapprove`, which writes
    `APPROVAL_REVOKED` on any non-pass and would gate-stop a ticket whose
    human simply has not looked yet) against a scratch log, appending its
    lines to the real pipeline log only when the answer changed.

    `held_at`/`fenced_generation`/`answer_probe` are accepted but unused —
    signature symmetry with every predicate `reconcile_hold` dispatches to
    (human-hold-protocol added all three for the `'human'` kind). This
    kind's own hold-release integrity is entirely `gate-check.sh`'s; the
    fence guard `fenced_generation` would express is already enforced at
    the `flow.sh` mutation layer.
    """
    # The cap is `STEP_3_5`'s, read from the table, and it is a pre-dispatch
    # cap: it refuses to dispatch reconcile again, rather than interrupting a
    # reconcile already under way.
    loop = phase_dispatch.evaluate_loop(
        table, GATE_RECONCILE_STEP, {'RECONCILE_CYCLE': cycle},
        when='pre_dispatch')
    if loop.action == phase_dispatch.LOOP_GATE_STOP:
        return GateHoldDecision(GATE_STOP, tid, cycle, None,
                                loop.gate_stop_code, position, loop.detail,
                                hold_id, hold_generation)

    probe = entry_gate or run_entry_gate
    exit_code, lines = probe(tid, hb_log_file=hb_log_file, lib_dir=lib_dir)

    if exit_code == GATE_ENTRY_PASS:
        _append(log_file, lines)
        return GateHoldDecision(
            RELEASE, tid, cycle + 1, exit_code, '', position,
            f'gate passed on re-check; resuming from '
            f'{position or "the start"}', hold_id, hold_generation)

    if exit_code == GATE_ENTRY_STOP:
        # The gate wrote its own reason; those lines are the record.
        _append(log_file, lines)
        return GateHoldDecision(GATE_STOP, tid, cycle, exit_code, '', position,
                                'entry gate returned a structural failure',
                                hold_id, hold_generation)

    if exit_code == GATE_ENTRY_HELD:
        # Nothing changed. Deliberately silent — see the module docstring.
        return GateHoldDecision(HOLD, tid, cycle, exit_code, '', position,
                                'still held', hold_id, hold_generation)

    # Timed out (None), or an exit code the gate does not document. Not a
    # hold decision at all — a gate that could not run is a different fact
    # from a gate that held (design.md D7) — so leave the row exactly as it
    # is and try again next pass.
    return GateHoldDecision(
        UNAVAILABLE, tid, cycle, exit_code, '', position,
        f'entry gate did not answer (exit {exit_code!r})',
        hold_id, hold_generation)


def human_hold_max_attempts():
    """`FLEET_HOLD_MAX_ATTEMPTS` — the bound on the ask -> partial-answer ->
    re-ask loop (human-hold-release spec "Repeated asking is bounded").
    Same env-var-with-fallback shape as `reconcile_interval_secs`.
    """
    raw = os.environ.get('FLEET_HOLD_MAX_ATTEMPTS',
                         str(DEFAULT_HOLD_MAX_ATTEMPTS))
    try:
        value = int(raw)
    except (TypeError, ValueError):
        return DEFAULT_HOLD_MAX_ATTEMPTS
    return value if value > 0 else DEFAULT_HOLD_MAX_ATTEMPTS


def human_hold_attempt_exceeds_max(hold_attempts):
    """Whether creating one more human hold (`hold_attempts + 1`) would push
    the ticket past `FLEET_HOLD_MAX_ATTEMPTS`.

    The caller that would create a fresh `hold_kind='human'` row (on a first
    ask, or on a `SUPERSEDES` re-hold after a partial answer) checks this
    before calling `store.set_hold` — a `True` result means writing
    `META|gate-stop|fail|HUMAN_HOLD_EXHAUSTED` instead, matching
    `RECONCILE_EXHAUSTED`'s shape. `hold_attempts` is the row's count
    *before* this attempt — `store.set_hold` itself increments it, and never
    resets it on release (human-hold-store-foundation's open question,
    settled here: "how many times have we asked this person" does not
    become untrue when they answer partially).
    """
    return (int(hold_attempts) + 1) > human_hold_max_attempts()


def probe_human_answer(tid, hold_id, held_at, lib_dir=None, timeout=30):
    """The `'human'` release predicate's probe (design.md D3/D4).

    `ANSWERED` requires all three: a Linear comment created strictly after
    `held_at`, authored by a user that is not the bot identity (`get_me`),
    whose body contains `hold_id`. The non-bot condition is load-bearing —
    without it a predicate of "any comment newer than held_at" would let
    `flow.sh`'s and `ticket-appraise-exec`'s own comments release the hold
    within one poll interval (human-hold-release spec D3).

    Any API error, auth failure, timeout, or unparseable response is
    `UNAVAILABLE` — never `NOT_ANSWERED`. An unreachable Linear is evidence
    of nothing, and treating it as "not yet answered" would eventually
    exhaust attempts and gate-stop a ticket over an outage rather than a
    silence (design.md D4).

    Returns `(action, detail)` where action is one of `ANSWERED`,
    `NOT_ANSWERED`, `UNAVAILABLE`.
    """
    lib = Path(lib_dir) if lib_dir else phase_dispatch.ticket_auto_lib_dir()
    linear_api = lib / 'linear-api.sh'
    if not linear_api.is_file():
        return UNAVAILABLE, f'linear-api.sh not found at {linear_api}'

    def _call(fn_call):
        try:
            proc = subprocess.run(
                ['bash', '-c', f"source '{linear_api}'; {fn_call}"],
                capture_output=True, text=True, timeout=timeout,
            )
        except (subprocess.TimeoutExpired, OSError) as exc:
            return None, str(exc)
        if proc.returncode != 0:
            stderr_tail = (proc.stderr or '').strip()[-200:]
            return None, f'exit {proc.returncode}: {stderr_tail}'
        return proc.stdout, None

    me_out, err = _call('get_me')
    if me_out is None:
        return UNAVAILABLE, f'get_me failed: {err}'
    try:
        me = json.loads(me_out)
    except (ValueError, TypeError):
        return UNAVAILABLE, 'get_me returned unparseable JSON'
    bot_id = me.get('id') if isinstance(me, dict) else None
    if not bot_id:
        return UNAVAILABLE, 'get_me returned no id'

    comments_out, err = _call(f"get_comments '{tid}'")
    if comments_out is None:
        return UNAVAILABLE, f'get_comments failed: {err}'
    try:
        comments = json.loads(comments_out)
    except (ValueError, TypeError):
        return UNAVAILABLE, 'get_comments returned unparseable JSON'
    if not isinstance(comments, list):
        return UNAVAILABLE, 'get_comments did not return an array'

    for c in comments:
        if not isinstance(c, dict):
            continue
        created_at = c.get('createdAt') or ''
        author_id = (c.get('user') or {}).get('id')
        body = c.get('body') or ''
        # ISO-8601 UTC timestamps compare correctly as strings; held_at
        # (fleetd-stamped, no millis) and createdAt (Linear, with millis)
        # share the same zero-padded, 'Z'-suffixed shape.
        if held_at and created_at <= held_at:
            continue
        if author_id == bot_id:
            continue
        if not hold_id or hold_id not in body:
            continue
        return ANSWERED, f'answered by {author_id!r} at {created_at}'
    return NOT_ANSWERED, 'no qualifying comment found'


def _reconcile_human_hold(table, tid, cycle, position, hold_id,
                          hold_generation, log_file, hb_log_file='',
                          lib_dir=None, entry_gate=None, held_at='',
                          fenced_generation=None, answer_probe=None):
    """The `'human'` release predicate (human-hold-protocol).

    Mirrors `_reconcile_gate_hold`'s shape for the cap and the resume
    position: the `RECONCILE_CYCLE` cap is checked first and pre-dispatch,
    and a release resumes through the same `STEP_3_5` gate-reconcile step
    regardless of which kind released it (design.md D9) — no bespoke resume
    path. What differs is the probe: `probe_human_answer` reads Linear
    comments rather than re-running a bash gate.

    `entry_gate` is accepted but unused — it is only meaningful for the
    `'gate'` kind's probe; `reconcile_hold` passes it to every predicate
    uniformly. `answer_probe` is this predicate's own injection point for
    tests, defaulting to `probe_human_answer`.
    """
    loop = phase_dispatch.evaluate_loop(
        table, GATE_RECONCILE_STEP, {'RECONCILE_CYCLE': cycle},
        when='pre_dispatch')
    if loop.action == phase_dispatch.LOOP_GATE_STOP:
        return GateHoldDecision(GATE_STOP, tid, cycle, None,
                                loop.gate_stop_code, position, loop.detail,
                                hold_id, hold_generation)

    # A hold created against a since-fenced generation is not released into
    # it (human-hold-release spec, matches flow.sh's own fence guard). The
    # refusal is recorded via HOLD's own detail, not silently dropped.
    if fenced_generation is not None and hold_generation <= int(fenced_generation):
        return GateHoldDecision(
            HOLD, tid, cycle, None, '', position,
            f'release refused: hold_generation {hold_generation} <= '
            f'fenced_generation {fenced_generation}', hold_id, hold_generation)

    probe = answer_probe or probe_human_answer
    action, detail = probe(tid, hold_id, held_at, lib_dir=lib_dir)

    if action == ANSWERED:
        return GateHoldDecision(
            RELEASE, tid, cycle + 1, None, '', position, detail,
            hold_id, hold_generation)
    if action == NOT_ANSWERED:
        return GateHoldDecision(HOLD, tid, cycle, None, '', position, detail,
                                hold_id, hold_generation)
    # UNAVAILABLE — never collapsed into HOLD (design.md D7): evidence of
    # nothing, not evidence of silence.
    return GateHoldDecision(UNAVAILABLE, tid, cycle, None, '', position,
                            detail, hold_id, hold_generation)


def post_human_hold_comment(tid, hold_id, blocks, questions, lib_dir=None,
                            timeout=30):
    """Post fleetd's one Linear comment for a newly created human hold
    (human-hold-release spec, design.md D8) and apply `needs-info` through
    its existing `state-machine.json` trigger — no new label defined.

    `questions` is an iterable of `(id, text)` pairs, already
    secret-redacted by `human-hold-parse.sh` before the record ever reached
    fleetd. Fail-soft throughout, like every other Linear-adjacent call in
    this module: a comment or label that could not be applied must not stop
    the hold from existing — the row is what actually protects the ticket
    from respawn, and it exists regardless of whether this call succeeds.

    Returns `(comment_posted, label_applied)`, both bool, so a caller can
    log exactly what happened rather than one collapsed success flag.
    """
    lib = Path(lib_dir) if lib_dir else phase_dispatch.ticket_auto_lib_dir()
    linear_api = lib / 'linear-api.sh'

    lines = [
        f'🔒 **Pipeline held — waiting on you** · `{hold_id}`',
        '',
        f'**Blocks:** {blocks}',
        '',
    ]
    for qid, text in questions:
        lines.append(f'{qid}. {text}')
    lines += [
        '',
        f'Reply in a comment **quoting `{hold_id}`** to release the pipeline.',
        'Answer by number; unanswered questions will be asked again.',
    ]
    body = '\n'.join(lines)

    comment_posted = False
    if linear_api.is_file():
        try:
            proc = subprocess.run(
                ['bash', '-c',
                 "source \"$LINEAR_API\"; save_comment \"$TID\" \"$BODY\""],
                env={**os.environ, 'LINEAR_API': str(linear_api),
                    'TID': tid, 'BODY': body},
                capture_output=True, text=True, timeout=timeout,
            )
            comment_posted = proc.returncode == 0
        except (subprocess.TimeoutExpired, OSError):
            comment_posted = False

    label_applied = False
    flow = None
    for cand in ((lib / '..' / 'skills' / 'ticket-flow' / 'flow.sh'),
                Path.home() / '.claude' / 'skills' / 'ticket-flow' / 'flow.sh'):
        if cand.is_file():
            flow = cand.resolve()
            break
    if flow is not None:
        try:
            proc = subprocess.run(
                ['bash', str(flow), tid, 'needs-info'],
                capture_output=True, text=True, timeout=timeout,
                env={**os.environ},
            )
            label_applied = proc.returncode == 0
        except (subprocess.TimeoutExpired, OSError):
            label_applied = False

    return comment_posted, label_applied


_RELEASE_PREDICATES = {
    'gate': _reconcile_gate_hold,
    'human': _reconcile_human_hold,
}


def _append(log_file, lines):
    """Append the gate's lines to the real pipeline log. Fail-soft."""
    if not log_file or not lines:
        return
    try:
        with open(log_file, 'a') as fh:
            fh.write('\n'.join(lines) + '\n')
    except OSError:
        pass
