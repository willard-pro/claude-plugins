"""
Integration tests for the 'human' hold kind end-to-end through the real
state store (fleetd/store.py) plus gate_hold.reconcile_hold's decisions —
human-hold-protocol tasks 7.1-7.4.

Not a full table-driven walk of every arc the task describes (that many
combinations, each requiring its own store fixture, would mostly re-test
store.py's own CAS guarantees, already covered by test_store.py). This
instead exercises the load-bearing property directly: across a run that
reconciles the same hold multiple times — restarts, duplicate passes, a
stale response, an outage in the middle — the row transitions exactly once
and every other pass is a safe no-op, using the REAL sqlite store rather
than a mock so the CAS guarantee under test is the one that actually ships.

Run:
    python3 -m pytest fleet-controller/fleetd/tests/test_human_hold_integration.py -v
"""

import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent))

from fleetd import gate_hold, store  # noqa: E402
from fleetd.phase_dispatch import DispatchTable  # noqa: E402

REPO_ROOT = Path(__file__).resolve().parent.parent.parent.parent
TABLE_PATH = (
    REPO_ROOT / 'ticket-auto-pipeline' / 'skills' / 'ticket-flow'
    / 'dispatch-table.json'
)


def _probe(sequence):
    """A fake answer_probe that returns one (action, detail) per call, from
    a fixed sequence — the last entry repeats once exhausted."""
    calls = {'n': 0}

    def fn(tid, hold_id, held_at, lib_dir=None):
        idx = min(calls['n'], len(sequence) - 1)
        calls['n'] += 1
        return sequence[idx]
    fn.calls = calls
    return fn


class HumanHoldIntegrationBase(unittest.TestCase):
    def setUp(self):
        self.table = DispatchTable.load(TABLE_PATH)
        self.tmp = tempfile.mkdtemp()
        self.db_path = Path(self.tmp) / 'fleet-state.db'
        self.st = store.FleetStore(self.db_path).open()
        self.log = Path(self.tmp) / 'CRE-9-pipeline.log'
        self.log.write_text('2026-09-06T09:00:00Z|META|schema|info|1\n')

    def tearDown(self):
        self.st.close()

    def _create_hold(self, generation=1, attempt=1, position='STEP_2'):
        hold_id = self.st.mint_hold_id('CRE-9', generation, attempt)
        rc = self.st.set_hold('CRE-9', 'human', hold_id, reason='ask',
                              generation=generation)
        self.assertEqual(rc, 1, 'set_hold must perform the transition once')
        self.st.record_position('CRE-9', position)
        return hold_id

    def _row(self):
        return self.st.get_ticket('CRE-9')

    def _reconcile(self, answer_probe):
        return gate_hold.reconcile_hold(
            self.table, 'CRE-9', self._row(), str(self.log),
            answer_probe=answer_probe)


class TestThreePassReconcile(HumanHoldIntegrationBase):
    """The load-bearing case (task 7.2): across a run that reconciles three
    times, released_at is stamped exactly once and exactly one release
    (spawn-equivalent) decision is made."""

    def test_released_exactly_once_across_three_passes(self):
        hold_id = self._create_hold()
        probe = _probe([
            (gate_hold.NOT_ANSWERED, 'no comment yet'),
            (gate_hold.NOT_ANSWERED, 'still nothing'),
            (gate_hold.ANSWERED, 'answered by human-1'),
        ])

        release_decisions = 0
        for _ in range(3):
            decision = self._reconcile(probe)
            if decision.action == gate_hold.RELEASE:
                release_decisions += 1
                rc = self.st.release_hold('CRE-9', decision.hold_id)
                self.assertEqual(rc, 1)

        self.assertEqual(release_decisions, 1)
        row = self._row()
        self.assertEqual(row['held'], 0)
        self.assertNotEqual(row['released_at'], '')

    def test_a_fourth_redundant_release_call_is_a_no_op(self):
        """Simulates a duplicate reconcile pass racing the first release —
        store.release_hold's CAS makes the second call a no-op."""
        hold_id = self._create_hold()
        self.st.release_hold('CRE-9', hold_id)
        rc = self.st.release_hold('CRE-9', hold_id)
        self.assertEqual(rc, 0)


class TestRestartWhileHeld(HumanHoldIntegrationBase):

    def test_restart_reads_the_same_row_and_stays_held(self):
        self._create_hold()
        probe = _probe([(gate_hold.NOT_ANSWERED, 'still waiting')])
        d1 = self._reconcile(probe)
        self.assertEqual(d1.action, gate_hold.HOLD)
        # "Restart": open a fresh store handle onto the same file.
        st2 = store.FleetStore(self.db_path).open()
        try:
            row = st2.get_ticket('CRE-9')
            self.assertEqual(row['held'], 1)
        finally:
            st2.close()


class TestStaleResponseToSupersededHold(HumanHoldIntegrationBase):

    def test_release_naming_a_superseded_hold_id_does_not_clear_the_current_hold(self):
        stale_hold_id = self._create_hold(generation=1, attempt=1)
        # A partial answer re-holds at attempt 2 — the current hold_id moves.
        self.st.release_hold('CRE-9', stale_hold_id)
        current_hold_id = self._create_hold(generation=1, attempt=2)
        self.assertNotEqual(stale_hold_id, current_hold_id)

        rc = self.st.release_hold('CRE-9', stale_hold_id)
        self.assertEqual(rc, 0)
        row = self._row()
        self.assertEqual(row['held'], 1)
        self.assertEqual(row['hold_id'], current_hold_id)


class TestWorkerCrashWhileHeld(HumanHoldIntegrationBase):
    """A held ticket has no process to crash — there is nothing running on
    its behalf once the hold row exists. This pins that the row alone,
    with no worker entry at all, is a complete and stable held state."""

    def test_no_worker_row_is_required_for_a_hold_to_stand(self):
        self._create_hold()
        self.assertEqual(self.st.running_workers('CRE-9'), [])
        row = self._row()
        self.assertEqual(row['held'], 1)


class TestMultipleQuestionsOneHold(HumanHoldIntegrationBase):

    def test_one_hold_row_regardless_of_question_count(self):
        # The row itself carries no question text (that lives in the log);
        # this pins that set_hold is called once per hold, not once per
        # question — the caller's responsibility, verified structurally.
        hold_id = self._create_hold()
        rc = self.st.set_hold('CRE-9', 'human', hold_id, reason='ask',
                              generation=1)
        self.assertEqual(rc, 0, 'set_hold must be a no-op while already held')


class TestAttemptsExhaustedThenGateStop(HumanHoldIntegrationBase):

    def test_fourth_attempt_would_exceed_the_default_cap(self):
        for attempt in (1, 2, 3):
            hold_id = self._create_hold(attempt=attempt)
            self.st.release_hold('CRE-9', hold_id)
        row = self._row()
        self.assertEqual(row['hold_attempts'], 3)
        self.assertTrue(
            gate_hold.human_hold_attempt_exceeds_max(row['hold_attempts']))


class TestFaultInjection(HumanHoldIntegrationBase):
    """task 7.3: Linear failures leave the hold standing, never gate-stop,
    never release — same store, same row, only the probe's answer changes."""

    def test_linear_500_leaves_hold_standing_no_gate_stop(self):
        self._create_hold()
        probe = _probe([(gate_hold.UNAVAILABLE, 'HTTP 500')])
        d = self._reconcile(probe)
        self.assertEqual(d.action, gate_hold.UNAVAILABLE)
        row = self._row()
        self.assertEqual(row['held'], 1)
        self.assertEqual(row['hold_attempts'], 1)

    def test_linear_timeout_leaves_hold_standing(self):
        self._create_hold()
        probe = _probe([(gate_hold.UNAVAILABLE, 'timeout')])
        d = self._reconcile(probe)
        self.assertEqual(d.action, gate_hold.UNAVAILABLE)

    def test_linear_auth_failure_leaves_hold_standing(self):
        self._create_hold()
        probe = _probe([(gate_hold.UNAVAILABLE, 'auth failure: 401')])
        d = self._reconcile(probe)
        self.assertEqual(d.action, gate_hold.UNAVAILABLE)

    def test_repeated_unavailable_never_exhausts_or_gate_stops(self):
        self._create_hold()
        probe = _probe([(gate_hold.UNAVAILABLE, 'HTTP 500')])
        for _ in range(10):
            d = self._reconcile(probe)
            self.assertEqual(d.action, gate_hold.UNAVAILABLE)
        row = self._row()
        self.assertEqual(row['held'], 1)


if __name__ == '__main__':
    unittest.main()
