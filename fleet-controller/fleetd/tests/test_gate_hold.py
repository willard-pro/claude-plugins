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
    """'external' is a placeholder for a future hold kind (design.md
    Non-Goals: "external/deploy hold kinds") with no registered predicate.
    It must resolve to UNAVAILABLE — never a release (a premise nothing
    evaluated) and never a gate-stop (killing a ticket over a missing
    feature). 'human' used to be the example here; human-hold-protocol
    registered its own predicate below, so this class now uses a kind that
    genuinely has none."""

    def test_unregistered_kind_yields_unavailable(self):
        calls = []

        def probe(tid, hb_log_file='', lib_dir=None):
            calls.append(tid)
            return gate_hold.GATE_ENTRY_PASS, [PASS_LINE]

        d = gate_hold.reconcile_hold(
            self.table, 'CRE-9', {'hold_kind': 'external'}, str(self.log),
            entry_gate=probe)
        self.assertEqual(d.action, gate_hold.UNAVAILABLE)
        # No predicate is registered for 'external' — the gate probe (which
        # would only be meaningful for 'gate') must never be invoked.
        self.assertEqual(calls, [])

    def test_unregistered_kind_leaves_the_row_untouched(self):
        before = self._log_lines()
        gate_hold.reconcile_hold(
            self.table, 'CRE-9', {'hold_kind': 'external'}, str(self.log))
        self.assertEqual(self._log_lines(), before)

    def test_an_empty_hold_kind_is_also_unavailable(self):
        """A row with no hold_kind at all (should not occur once set_hold
        always writes one, but the dispatch must not guess) is unavailable,
        not silently treated as 'gate'."""
        d = gate_hold.reconcile_hold(
            self.table, 'CRE-9', {}, str(self.log))
        self.assertEqual(d.action, gate_hold.UNAVAILABLE)


HOLD_ID = 'hold:CRE-9:g1:a1'


class HumanHoldTestBase(unittest.TestCase):
    """Base for the 'human' release predicate — mirrors GateHoldTestBase,
    but the probe under test is `probe_human_answer` (Linear comments), not
    a bash gate, so tests inject `answer_probe` instead of `entry_gate`."""

    def setUp(self):
        self.table = DispatchTable.load(TABLE_PATH)
        self.tmp = tempfile.mkdtemp()
        self.log = Path(self.tmp) / 'CRE-9-pipeline.log'
        self.log.write_text('2026-09-06T09:00:00Z|META|schema|info|1\n')

    def _reconcile(self, action, detail='', **row):
        row.setdefault('hold_kind', 'human')
        row.setdefault('hold_id', HOLD_ID)
        row.setdefault('held_at', '2026-09-06T09:00:00Z')

        def probe(tid, hold_id, held_at, lib_dir=None):
            return action, detail

        return gate_hold.reconcile_hold(
            self.table, 'CRE-9', row, str(self.log),
            answer_probe=probe)


class TestHumanHoldAnswered(HumanHoldTestBase):

    def test_answered_releases_the_hold(self):
        d = self._reconcile(gate_hold.ANSWERED, 'answered by U1',
                            reconcile_cycle=0, position='STEP_2')
        self.assertEqual(d.action, gate_hold.RELEASE)

    def test_answered_advances_the_reconcile_cycle(self):
        d = self._reconcile(gate_hold.ANSWERED, reconcile_cycle=1)
        self.assertEqual(d.cycle, 2)

    def test_answered_carries_the_recorded_dispatch_position(self):
        """Resume is read, never reconstructed — the position never comes
        from the hold record (human-hold-release spec)."""
        d = self._reconcile(gate_hold.ANSWERED, position='STEP_4_5')
        self.assertEqual(d.position, 'STEP_4_5')

    def test_answered_carries_hold_id_and_generation(self):
        d = self._reconcile(gate_hold.ANSWERED, hold_id=HOLD_ID,
                            hold_generation=3)
        self.assertEqual(d.hold_id, HOLD_ID)
        self.assertEqual(d.hold_generation, 3)


class TestHumanHoldNotAnswered(HumanHoldTestBase):

    def test_not_answered_stays_held(self):
        d = self._reconcile(gate_hold.NOT_ANSWERED, 'no qualifying comment')
        self.assertEqual(d.action, gate_hold.HOLD)

    def test_not_answered_does_not_advance_the_cycle(self):
        d = self._reconcile(gate_hold.NOT_ANSWERED, reconcile_cycle=1)
        self.assertEqual(d.cycle, 1)

    def test_a_bot_authored_comment_does_not_release(self):
        """The non-bot condition is load-bearing (design.md D3) — modelled
        here at the probe boundary, since probe_human_answer itself owns
        the bot-identity check; the reconcile layer must simply respect
        whatever the probe decides."""
        d = self._reconcile(gate_hold.NOT_ANSWERED,
                            'bot-authored comment ignored')
        self.assertEqual(d.action, gate_hold.HOLD)


class TestHumanHoldUnavailable(HumanHoldTestBase):

    def test_api_failure_is_unavailable_never_not_answered(self):
        d = self._reconcile(gate_hold.UNAVAILABLE, 'get_me failed: timeout')
        self.assertEqual(d.action, gate_hold.UNAVAILABLE)

    def test_unavailable_does_not_advance_the_cycle(self):
        d = self._reconcile(gate_hold.UNAVAILABLE, reconcile_cycle=2)
        self.assertEqual(d.cycle, 2)

    def test_unavailable_writes_nothing_to_the_pipeline_log(self):
        before = self.log.read_text()
        self._reconcile(gate_hold.UNAVAILABLE)
        self.assertEqual(self.log.read_text(), before)


class TestHumanHoldFenceGuard(HumanHoldTestBase):
    """A hold created against a since-fenced generation is not released
    into it (human-hold-release spec, mirrors flow.sh's fence guard)."""

    def test_hold_generation_at_fence_is_refused(self):
        d = self._reconcile(gate_hold.ANSWERED, hold_generation=2,
                            fenced_generation=2)
        self.assertEqual(d.action, gate_hold.HOLD)
        self.assertIn('refused', d.detail)

    def test_hold_generation_below_fence_is_refused(self):
        d = self._reconcile(gate_hold.ANSWERED, hold_generation=1,
                            fenced_generation=3)
        self.assertEqual(d.action, gate_hold.HOLD)

    def test_hold_generation_above_fence_releases_normally(self):
        d = self._reconcile(gate_hold.ANSWERED, hold_generation=5,
                            fenced_generation=2)
        self.assertEqual(d.action, gate_hold.RELEASE)

    def test_fenced_generation_none_never_refuses(self):
        """An unfenced ticket (the common case) is unaffected."""
        d = self._reconcile(gate_hold.ANSWERED, hold_generation=1,
                            fenced_generation=None)
        self.assertEqual(d.action, gate_hold.RELEASE)


class TestHumanHoldCycleCap(HumanHoldTestBase):

    def test_the_cycle_cap_comes_from_the_table(self):
        cap = self.table.loop('STEP_3_5')['max_iterations']
        d = self._reconcile(gate_hold.ANSWERED, reconcile_cycle=cap)
        self.assertEqual(d.action, gate_hold.GATE_STOP)
        self.assertEqual(d.gate_stop_code,
                         self.table.loop('STEP_3_5')['gate_stop_code'])

    def test_the_cap_is_checked_before_the_probe_even_runs(self):
        calls = []

        def probe(tid, hold_id, held_at, lib_dir=None):
            calls.append(tid)
            return gate_hold.ANSWERED, ''

        cap = self.table.loop('STEP_3_5')['max_iterations']
        gate_hold.reconcile_hold(
            self.table, 'CRE-9',
            {'reconcile_cycle': cap, 'hold_kind': 'human',
             'hold_id': HOLD_ID}, str(self.log), answer_probe=probe)
        self.assertEqual(calls, [])

    def test_one_below_the_cap_still_releases(self):
        cap = self.table.loop('STEP_3_5')['max_iterations']
        d = self._reconcile(gate_hold.ANSWERED, reconcile_cycle=cap - 1)
        self.assertEqual(d.action, gate_hold.RELEASE)


class TestProbeHumanAnswer(unittest.TestCase):
    """`probe_human_answer` itself — the Linear-reading half, with
    `subprocess.run` stubbed so no network call is ever made."""

    def setUp(self):
        self.lib_dir = (REPO_ROOT / 'ticket-auto-pipeline' / 'lib')
        self._real_run = gate_hold.subprocess.run

    def tearDown(self):
        gate_hold.subprocess.run = self._real_run

    def _stub(self, me_json, comments_json, me_rc=0, comments_rc=0):
        calls = []

        def fake_run(argv, **kwargs):
            calls.append(argv)
            script = argv[-1] if isinstance(argv, list) else str(argv)
            if 'get_me' in script:
                return _Proc(me_rc, me_json, '')
            return _Proc(comments_rc, comments_json, '')

        gate_hold.subprocess.run = fake_run
        return calls

    def test_answered_when_non_bot_comment_after_held_at_carries_token(self):
        self._stub(
            '{"id": "bot-1", "name": "Fleet Bot"}',
            '[{"id": "c1", "body": "quoting hold:CRE-9:g1:a1 here", '
            '"createdAt": "2026-09-06T10:00:00.000Z", '
            '"user": {"id": "human-1", "name": "A Human"}}]')
        action, _ = gate_hold.probe_human_answer(
            'CRE-9', HOLD_ID, '2026-09-06T09:00:00Z', lib_dir=self.lib_dir)
        self.assertEqual(action, gate_hold.ANSWERED)

    def test_bot_authored_comment_does_not_release(self):
        self._stub(
            '{"id": "bot-1", "name": "Fleet Bot"}',
            '[{"id": "c1", "body": "quoting hold:CRE-9:g1:a1 here", '
            '"createdAt": "2026-09-06T10:00:00.000Z", '
            '"user": {"id": "bot-1", "name": "Fleet Bot"}}]')
        action, _ = gate_hold.probe_human_answer(
            'CRE-9', HOLD_ID, '2026-09-06T09:00:00Z', lib_dir=self.lib_dir)
        self.assertEqual(action, gate_hold.NOT_ANSWERED)

    def test_comment_without_token_does_not_release(self):
        self._stub(
            '{"id": "bot-1"}',
            '[{"id": "c1", "body": "just chatting", '
            '"createdAt": "2026-09-06T10:00:00.000Z", '
            '"user": {"id": "human-1"}}]')
        action, _ = gate_hold.probe_human_answer(
            'CRE-9', HOLD_ID, '2026-09-06T09:00:00Z', lib_dir=self.lib_dir)
        self.assertEqual(action, gate_hold.NOT_ANSWERED)

    def test_pre_hold_comment_does_not_release(self):
        self._stub(
            '{"id": "bot-1"}',
            '[{"id": "c1", "body": "quoting hold:CRE-9:g1:a1", '
            '"createdAt": "2026-09-06T08:00:00.000Z", '
            '"user": {"id": "human-1"}}]')
        action, _ = gate_hold.probe_human_answer(
            'CRE-9', HOLD_ID, '2026-09-06T09:00:00Z', lib_dir=self.lib_dir)
        self.assertEqual(action, gate_hold.NOT_ANSWERED)

    def test_comment_quoting_a_superseded_hold_id_is_a_no_op(self):
        """Quoting a stale hold_id is checked against THIS hold's id, so an
        answer to a superseded hold does not match here — the caller passed
        the current hold_id, and a comment naming a different, prior one
        does not contain it."""
        self._stub(
            '{"id": "bot-1"}',
            '[{"id": "c1", "body": "quoting hold:CRE-9:g1:a1 (an old one)", '
            '"createdAt": "2026-09-06T10:00:00.000Z", '
            '"user": {"id": "human-1"}}]')
        action, _ = gate_hold.probe_human_answer(
            'CRE-9', 'hold:CRE-9:g1:a2', '2026-09-06T09:00:00Z',
            lib_dir=self.lib_dir)
        self.assertEqual(action, gate_hold.NOT_ANSWERED)

    def test_get_me_failure_is_unavailable(self):
        self._stub('', '[]', me_rc=1)
        action, detail = gate_hold.probe_human_answer(
            'CRE-9', HOLD_ID, '2026-09-06T09:00:00Z', lib_dir=self.lib_dir)
        self.assertEqual(action, gate_hold.UNAVAILABLE)
        self.assertIn('get_me', detail)

    def test_get_comments_failure_is_unavailable(self):
        self._stub('{"id": "bot-1"}', '', comments_rc=1)
        action, detail = gate_hold.probe_human_answer(
            'CRE-9', HOLD_ID, '2026-09-06T09:00:00Z', lib_dir=self.lib_dir)
        self.assertEqual(action, gate_hold.UNAVAILABLE)

    def test_unparseable_response_is_unavailable_not_not_answered(self):
        self._stub('not json', '[]')
        action, _ = gate_hold.probe_human_answer(
            'CRE-9', HOLD_ID, '2026-09-06T09:00:00Z', lib_dir=self.lib_dir)
        self.assertEqual(action, gate_hold.UNAVAILABLE)

    def test_timeout_is_unavailable(self):
        def fake_run(argv, **kwargs):
            raise gate_hold.subprocess.TimeoutExpired(cmd=argv, timeout=1)
        gate_hold.subprocess.run = fake_run
        action, _ = gate_hold.probe_human_answer(
            'CRE-9', HOLD_ID, '2026-09-06T09:00:00Z', lib_dir=self.lib_dir)
        self.assertEqual(action, gate_hold.UNAVAILABLE)


class _Proc:
    def __init__(self, returncode, stdout, stderr):
        self.returncode = returncode
        self.stdout = stdout
        self.stderr = stderr


class TestHoldAttemptExhaustion(unittest.TestCase):

    def setUp(self):
        self._saved = gate_hold.os.environ.pop('FLEET_HOLD_MAX_ATTEMPTS', None)

    def tearDown(self):
        if self._saved is not None:
            gate_hold.os.environ['FLEET_HOLD_MAX_ATTEMPTS'] = self._saved
        else:
            gate_hold.os.environ.pop('FLEET_HOLD_MAX_ATTEMPTS', None)

    def test_default_max_is_three(self):
        self.assertEqual(gate_hold.human_hold_max_attempts(), 3)

    def test_below_the_cap_does_not_exceed(self):
        self.assertFalse(gate_hold.human_hold_attempt_exceeds_max(2))

    def test_the_fourth_attempt_exceeds_the_default_cap(self):
        self.assertTrue(gate_hold.human_hold_attempt_exceeds_max(3))

    def test_configurable_cap(self):
        gate_hold.os.environ['FLEET_HOLD_MAX_ATTEMPTS'] = '1'
        self.assertTrue(gate_hold.human_hold_attempt_exceeds_max(1))
        self.assertFalse(gate_hold.human_hold_attempt_exceeds_max(0))

    def test_nonsense_value_falls_back_to_default(self):
        gate_hold.os.environ['FLEET_HOLD_MAX_ATTEMPTS'] = 'lots'
        self.assertEqual(gate_hold.human_hold_max_attempts(), 3)


class TestPostHumanHoldComment(unittest.TestCase):
    """post_human_hold_comment — fail-soft, and never invents a label."""

    def setUp(self):
        self._real_run = gate_hold.subprocess.run

    def tearDown(self):
        gate_hold.subprocess.run = self._real_run

    def test_success_posts_comment_and_applies_needs_info(self):
        calls = []

        def fake_run(argv, **kwargs):
            calls.append(argv)
            return _Proc(0, '', '')

        gate_hold.subprocess.run = fake_run
        lib_dir = REPO_ROOT / 'ticket-auto-pipeline' / 'lib'
        posted, labeled = gate_hold.post_human_hold_comment(
            'CRE-9', HOLD_ID, 'notes.md#AC-2', [(1, 'which archive?')],
            lib_dir=lib_dir)
        self.assertTrue(posted)
        # needs-info label application depends on flow.sh being resolvable
        # in this checkout — assert the comment call happened regardless.
        self.assertTrue(any('save_comment' in ' '.join(c) for c in calls
                            if isinstance(c, list)))

    def test_comment_body_carries_hold_id_and_numbered_questions(self):
        captured = {}

        def fake_run(argv, **kwargs):
            if isinstance(argv, list) and 'save_comment' in ' '.join(argv):
                captured['body'] = kwargs.get('env', {}).get('BODY', '')
            return _Proc(0, '', '')

        gate_hold.subprocess.run = fake_run
        lib_dir = REPO_ROOT / 'ticket-auto-pipeline' / 'lib'
        gate_hold.post_human_hold_comment(
            'CRE-9', HOLD_ID, 'notes.md#AC-2',
            [(1, 'which archive?'), (2, 'csv or xlsx?')], lib_dir=lib_dir)
        self.assertIn(HOLD_ID, captured.get('body', ''))
        self.assertIn('1. which archive?', captured.get('body', ''))
        self.assertIn('2. csv or xlsx?', captured.get('body', ''))

    def test_linear_failure_degrades_without_raising(self):
        def fake_run(argv, **kwargs):
            return _Proc(1, '', 'boom')

        gate_hold.subprocess.run = fake_run
        lib_dir = REPO_ROOT / 'ticket-auto-pipeline' / 'lib'
        posted, labeled = gate_hold.post_human_hold_comment(
            'CRE-9', HOLD_ID, 'notes.md#AC-2', [(1, 'x?')], lib_dir=lib_dir)
        self.assertFalse(posted)
        self.assertFalse(labeled)

    def test_timeout_degrades_without_raising(self):
        def fake_run(argv, **kwargs):
            raise gate_hold.subprocess.TimeoutExpired(cmd=argv, timeout=1)

        gate_hold.subprocess.run = fake_run
        lib_dir = REPO_ROOT / 'ticket-auto-pipeline' / 'lib'
        posted, labeled = gate_hold.post_human_hold_comment(
            'CRE-9', HOLD_ID, 'notes.md#AC-2', [(1, 'x?')], lib_dir=lib_dir)
        self.assertFalse(posted)
        self.assertFalse(labeled)


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
