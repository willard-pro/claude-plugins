"""
Tests for fleetd's gate-hold reconciliation (fleetd/gate_hold.py).

Run:
    python3 -m pytest fleet-controller/fleetd/tests/test_gate_hold.py -v

The three things worth guarding, all of them found by building D14 rather
than by reading it:

- A poll that finds no approval must change nothing AND write nothing. The
  entry gate logs a held line every time it holds; on its own cadence against
  a ticket waiting three days that is hundreds of identical lines in the file
  detect-resume.sh, the detectors and the OTel exporter all read.
- The `RECONCILE_CYCLE` cap counts hold/re-approve cycles, not polls. Counting
  polls would gate-stop every ticket held over a weekend.
- A gate that could not run is not a gate that held. Collapsing the two would
  strand a ticket in a hold no re-check could ever clear.

The gate itself is never invoked here; it is injected. What is under test is
the decision made from its exit code, not Linear.
"""

import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent))

from fleetd import gate_hold  # noqa: E402
from fleetd.phase_dispatch import DispatchTable  # noqa: E402

REPO_ROOT = Path(__file__).resolve().parent.parent.parent.parent
TABLE_PATH = (
    REPO_ROOT / 'ticket-auto-pipeline' / 'skills' / 'ticket-flow'
    / 'dispatch-table.json'
)

HELD_LINE = '2026-09-03T10:00:00Z|GATE|gate|fail|held: complex ticket'
PASS_LINE = '2026-09-03T10:00:00Z|GATE|gate|done|auto-approved'
STOP_LINE = '2026-09-03T10:00:00Z|META|gate-stop|fail|EXEC_NO_ARTIFACT'


def _gate(exit_code, lines):
    """A stand-in entry gate returning a fixed answer."""
    def probe(tid, hb_log_file='', lib_dir=None):
        return exit_code, list(lines)
    return probe


class GateHoldTestBase(unittest.TestCase):
    def setUp(self):
        self.table = DispatchTable.load(TABLE_PATH)
        self.tmp = tempfile.mkdtemp()
        self.log = Path(self.tmp) / 'CRE-9-pipeline.log'
        self.log.write_text('2026-09-03T09:00:00Z|META|schema|info|1\n')

    def _reconcile(self, exit_code, lines, **row):
        # A held ticket's row always carries a real hold_kind (set_hold
        # requires one); default to 'gate' here so every pre-existing test
        # below keeps exercising the 'gate' release predicate unchanged.
        row.setdefault('hold_kind', 'gate')
        return gate_hold.reconcile_hold(
            self.table, 'CRE-9', row, str(self.log),
            entry_gate=_gate(exit_code, lines))

    def _log_lines(self):
        return [ln for ln in self.log.read_text().splitlines() if ln.strip()]


class TestStillHeld(GateHoldTestBase):

    def test_a_still_held_ticket_stays_held(self):
        d = self._reconcile(gate_hold.GATE_ENTRY_HELD, [HELD_LINE],
                            reconcile_cycle=0, position='STEP_2_5')
        self.assertEqual(d.action, gate_hold.HOLD)

    def test_a_still_held_poll_does_not_advance_the_cycle(self):
        """Polls are not cycles. Counting them gate-stops a weekend wait."""
        d = self._reconcile(gate_hold.GATE_ENTRY_HELD, [HELD_LINE],
                            reconcile_cycle=1, position='STEP_2_5')
        self.assertEqual(d.cycle, 1)

    def test_a_still_held_poll_writes_nothing_to_the_pipeline_log(self):
        before = self._log_lines()
        self._reconcile(gate_hold.GATE_ENTRY_HELD, [HELD_LINE],
                        reconcile_cycle=0)
        self.assertEqual(self._log_lines(), before)

    def test_many_polls_leave_the_log_untouched(self):
        before = self._log_lines()
        for _ in range(50):
            self._reconcile(gate_hold.GATE_ENTRY_HELD, [HELD_LINE],
                            reconcile_cycle=0)
        self.assertEqual(self._log_lines(), before)


class TestRelease(GateHoldTestBase):

    def test_a_passing_gate_releases_the_hold(self):
        d = self._reconcile(gate_hold.GATE_ENTRY_PASS, [PASS_LINE],
                            reconcile_cycle=0, position='STEP_2_5')
        self.assertEqual(d.action, gate_hold.RELEASE)

    def test_release_advances_the_reconcile_cycle(self):
        d = self._reconcile(gate_hold.GATE_ENTRY_PASS, [PASS_LINE],
                            reconcile_cycle=1)
        self.assertEqual(d.cycle, 2)

    def test_release_carries_the_recorded_dispatch_position(self):
        """Resume is read, never reconstructed — fleetd did the dispatch."""
        d = self._reconcile(gate_hold.GATE_ENTRY_PASS, [PASS_LINE],
                            position='STEP_4_5')
        self.assertEqual(d.position, 'STEP_4_5')

    def test_release_appends_the_gate_s_own_lines(self):
        self._reconcile(gate_hold.GATE_ENTRY_PASS, [PASS_LINE])
        self.assertIn(PASS_LINE, self._log_lines())


class TestGateStop(GateHoldTestBase):

    def test_a_structural_gate_failure_stops(self):
        d = self._reconcile(gate_hold.GATE_ENTRY_STOP, [STOP_LINE])
        self.assertEqual(d.action, gate_hold.GATE_STOP)

    def test_a_structural_failure_keeps_the_gate_s_own_reason(self):
        self._reconcile(gate_hold.GATE_ENTRY_STOP, [STOP_LINE])
        self.assertIn(STOP_LINE, self._log_lines())

    def test_the_cycle_cap_comes_from_the_table(self):
        cap = self.table.loop('STEP_3_5')['max_iterations']
        d = self._reconcile(gate_hold.GATE_ENTRY_PASS, [PASS_LINE],
                            reconcile_cycle=cap)
        self.assertEqual(d.action, gate_hold.GATE_STOP)
        self.assertEqual(d.gate_stop_code,
                         self.table.loop('STEP_3_5')['gate_stop_code'])

    def test_the_cap_is_checked_before_the_gate_is_even_probed(self):
        """An exhausted ticket must not cost a Linear round trip."""
        calls = []

        def probe(tid, hb_log_file='', lib_dir=None):
            calls.append(tid)
            return gate_hold.GATE_ENTRY_PASS, [PASS_LINE]

        cap = self.table.loop('STEP_3_5')['max_iterations']
        gate_hold.reconcile_hold(
            self.table, 'CRE-9',
            {'reconcile_cycle': cap, 'hold_kind': 'gate'}, str(self.log),
            entry_gate=probe)
        self.assertEqual(calls, [])

    def test_one_below_the_cap_still_releases(self):
        cap = self.table.loop('STEP_3_5')['max_iterations']
        d = self._reconcile(gate_hold.GATE_ENTRY_PASS, [PASS_LINE],
                            reconcile_cycle=cap - 1)
        self.assertEqual(d.action, gate_hold.RELEASE)


class TestUnanswerableProbe(GateHoldTestBase):

    def test_a_timeout_is_unavailable_not_held(self):
        """A gate that could not run is a different fact from one that held
        — UNAVAILABLE is never collapsed into HOLD (design.md D7)."""
        d = self._reconcile(None, [])
        self.assertEqual(d.action, gate_hold.UNAVAILABLE)
        self.assertIn('did not answer', d.detail)

    def test_an_undocumented_exit_code_is_unavailable_not_held(self):
        d = self._reconcile(127, [])
        self.assertEqual(d.action, gate_hold.UNAVAILABLE)
        self.assertIn('did not answer', d.detail)
        self.assertNotEqual(d.detail, 'still held')

    def test_an_unanswerable_probe_writes_nothing(self):
        before = self._log_lines()
        self._reconcile(127, [STOP_LINE])
        self.assertEqual(self._log_lines(), before)


class TestUnregisteredHoldKind(GateHoldTestBase):
    """'human' is permitted by the schema's CHECK constraint but has no
    registered predicate until human-hold-protocol. It must resolve to
    UNAVAILABLE — never a release (a premise nothing evaluated) and never a
    gate-stop (killing a ticket over a missing feature)."""

    def test_human_kind_yields_unavailable(self):
        calls = []

        def probe(tid, hb_log_file='', lib_dir=None):
            calls.append(tid)
            return gate_hold.GATE_ENTRY_PASS, [PASS_LINE]

        d = gate_hold.reconcile_hold(
            self.table, 'CRE-9', {'hold_kind': 'human'}, str(self.log),
            entry_gate=probe)
        self.assertEqual(d.action, gate_hold.UNAVAILABLE)
        # No predicate is registered for 'human' — the gate probe (which
        # would only be meaningful for 'gate') must never be invoked.
        self.assertEqual(calls, [])

    def test_human_kind_leaves_the_row_untouched(self):
        before = self._log_lines()
        gate_hold.reconcile_hold(
            self.table, 'CRE-9', {'hold_kind': 'human'}, str(self.log))
        self.assertEqual(self._log_lines(), before)

    def test_an_empty_hold_kind_is_also_unavailable(self):
        """A row with no hold_kind at all (should not occur once set_hold
        always writes one, but the dispatch must not guess) is unavailable,
        not silently treated as 'gate'."""
        d = gate_hold.reconcile_hold(
            self.table, 'CRE-9', {}, str(self.log))
        self.assertEqual(d.action, gate_hold.UNAVAILABLE)


class TestHoldIdThreading(GateHoldTestBase):
    """hold_id/hold_generation are carried from the row into every decision
    so the caller can release with store.release_hold's CAS guard."""

    def test_hold_id_and_generation_are_carried_through_every_action(self):
        for exit_code, lines in (
            (gate_hold.GATE_ENTRY_HELD, [HELD_LINE]),
            (gate_hold.GATE_ENTRY_PASS, [PASS_LINE]),
            (gate_hold.GATE_ENTRY_STOP, [STOP_LINE]),
            (127, []),
        ):
            d = self._reconcile(
                exit_code, lines,
                hold_id='hold:CRE-9:g3:a1', hold_generation=3)
            self.assertEqual(d.hold_id, 'hold:CRE-9:g3:a1')
            self.assertEqual(d.hold_generation, 3)

    def test_unregistered_kind_also_carries_hold_id(self):
        d = gate_hold.reconcile_hold(
            self.table, 'CRE-9',
            {'hold_kind': 'human', 'hold_id': 'hold:CRE-9:g1:a1',
             'hold_generation': 1},
            str(self.log))
        self.assertEqual(d.hold_id, 'hold:CRE-9:g1:a1')
        self.assertEqual(d.hold_generation, 1)


class TestNeverReapprove(GateHoldTestBase):
    """--mode reapprove writes APPROVAL_REVOKED on any non-pass and would
    gate-stop a ticket whose human simply has not looked yet — the entry
    probe must never take that path."""

    def test_run_entry_gate_always_passes_mode_entry(self):
        captured = {}
        real_run = gate_hold.subprocess.run

        def _capture(argv, **kwargs):
            captured['argv'] = argv
            raise gate_hold.subprocess.TimeoutExpired(cmd=argv, timeout=1)

        gate_hold.subprocess.run = _capture
        lib_dir = REPO_ROOT / 'ticket-auto-pipeline' / 'lib'
        try:
            gate_hold.run_entry_gate('CRE-9', lib_dir=str(lib_dir))
        finally:
            gate_hold.subprocess.run = real_run

        argv = captured.get('argv', [])
        self.assertIn('entry', argv)
        self.assertNotIn('reapprove', argv)


class TestCadence(unittest.TestCase):

    def setUp(self):
        self._saved = gate_hold.os.environ.pop(
            'FLEET_GATE_RECONCILE_INTERVAL', None)

    def tearDown(self):
        if self._saved is not None:
            gate_hold.os.environ['FLEET_GATE_RECONCILE_INTERVAL'] = self._saved
        else:
            gate_hold.os.environ.pop('FLEET_GATE_RECONCILE_INTERVAL', None)

    def test_default_interval_is_five_minutes(self):
        self.assertEqual(gate_hold.reconcile_interval_secs(), 300)

    def test_interval_is_configurable(self):
        gate_hold.os.environ['FLEET_GATE_RECONCILE_INTERVAL'] = '60'
        self.assertEqual(gate_hold.reconcile_interval_secs(), 60)

    def test_a_nonsense_interval_falls_back_to_the_default(self):
        gate_hold.os.environ['FLEET_GATE_RECONCILE_INTERVAL'] = 'soon'
        self.assertEqual(gate_hold.reconcile_interval_secs(), 300)

    def test_a_zero_interval_falls_back_rather_than_spinning(self):
        gate_hold.os.environ['FLEET_GATE_RECONCILE_INTERVAL'] = '0'
        self.assertEqual(gate_hold.reconcile_interval_secs(), 300)

    def test_never_run_is_due_immediately(self):
        self.assertTrue(gate_hold.is_due(None))

    def test_a_recent_pass_is_not_due(self):
        self.assertFalse(gate_hold.is_due(1000.0, now=1100.0, interval=300))

    def test_an_elapsed_interval_is_due(self):
        self.assertTrue(gate_hold.is_due(1000.0, now=1400.0, interval=300))


if __name__ == '__main__':
    unittest.main()
