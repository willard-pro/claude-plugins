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
`'gate'` maps to `run_entry_gate` below, unchanged. Any other kind —
`'human'`, until `human-hold-protocol` registers its own predicate —
resolves to `UNAVAILABLE`.

Stdlib only.
"""

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

DEFAULT_RECONCILE_INTERVAL_SECS = 300

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
                   lib_dir=None, entry_gate=None):
    """Decide the fate of one held ticket, dispatched by its `hold_kind`.

    An unregistered kind resolves to `UNAVAILABLE` rather than a guess —
    never a `release` (a premise nothing evaluated) and never a `gate-stop`
    (killing a ticket over a missing feature). This is what lets this change
    and `human-hold-protocol` ship in either review order without a window
    where a `'human'` row is mishandled (design.md D6).

    `entry_gate` is the probe callable for the `'gate'` predicate, injected
    so a test can drive every branch without a Linear account; it defaults
    to `run_entry_gate`.
    """
    kind = (ticket_row or {}).get('hold_kind') or ''
    hold_id = (ticket_row or {}).get('hold_id') or ''
    hold_generation = int((ticket_row or {}).get('hold_generation') or 0)
    cycle = int((ticket_row or {}).get('reconcile_cycle') or 0)
    position = (ticket_row or {}).get('position') or ''

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
        entry_gate=entry_gate)


def _reconcile_gate_hold(table, tid, cycle, position, hold_id,
                         hold_generation, log_file, hb_log_file='',
                         lib_dir=None, entry_gate=None):
    """The `'gate'` release predicate: today's `run_entry_gate`, unchanged.

    `gate-check.sh` remains the only authority on "is this approved" — this
    still runs `--mode entry` (never `--mode reapprove`, which writes
    `APPROVAL_REVOKED` on any non-pass and would gate-stop a ticket whose
    human simply has not looked yet) against a scratch log, appending its
    lines to the real pipeline log only when the answer changed.
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


_RELEASE_PREDICATES = {
    'gate': _reconcile_gate_hold,
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
