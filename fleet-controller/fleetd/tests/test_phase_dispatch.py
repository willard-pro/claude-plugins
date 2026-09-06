"""
Tests for fleetd's phase-dispatch module (fleetd/phase_dispatch.py).

Run:
    python3 -m pytest fleet-controller/fleetd/tests/test_phase_dispatch.py -v

What is under test is the part of the design that is easy to get subtly wrong
and expensive to notice:

- The dispatch table is *loaded*, so the real file is what these tests load.
  A test against a hand-written fixture would pass while the shipped table
  drifted, which is the exact failure the canonical file exists to prevent.
- Classification precedence (design.md D12). Each rung is tested where it wins
  AND where a lower rung must not override it, because a precedence bug shows
  up as an occasional wrong verdict, not as a crash.
- The two places the vocabularies diverge: a PR-REVIEW `PASS` becoming the
  router's `OK`, and a `WARN` being a *successful* review that wants another
  iteration rather than a failure.
- That exit 0 is never read as positive evidence — a SIGINT'd headless worker
  exits 0, so trusting it would mark killed phases as passed.
- That the terminal marker really goes through the shared bash writer, in the
  grammar `detect-resume.sh` keys on.
"""

import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent))

from fleetd import phase_dispatch  # noqa: E402
from fleetd.phase_dispatch import (  # noqa: E402
    DispatchTable,
    DispatchTableError,
    LOOP_BEARING_PHASES,
    PhaseOutcome,
    TerminalWriteError,
    apply_verifier_overrides,
    classify_phase,
    missing_phase_result,
    phase_terminal_write,
    route_exit_code,
    router_token,
    PhaseSpawnError,
    build_phase_spawn,
    evaluate_loop,
    LOOP_DISPATCH,
    LOOP_GATE_STOP,
    LOOP_NOT_LOOPED,
    write_spawn_meta,
    write_phase_start_marker,
    DEFAULT_PHASE_FLAGS,
    EXIT_ROUTE_CONTINUE,
    EXIT_ROUTE_GATE_STOP,
    EXIT_ROUTE_RETRY,
    FLOW_STATE_ASSERTION_EXIT,
    GATE_HOLD_RESUME_STEPS,
    ResumeAdoptError,
    adopt_position_via_detect_resume,
    detect_resume_script_path,
    last_verify_checkpoint,
    parse_detect_resume_block,
    resolve_dispatch_position,
)

REPO_ROOT = Path(__file__).resolve().parent.parent.parent.parent
TABLE_PATH = (
    REPO_ROOT / 'ticket-auto-pipeline' / 'skills' / 'ticket-flow'
    / 'dispatch-table.json'
)
TICKET_AUTO_LIB = REPO_ROOT / 'ticket-auto-pipeline' / 'lib'
DETECT_RESUME_SCRIPT = (
    REPO_ROOT / 'ticket-auto-pipeline' / 'skills' / 'ticket-detect-resume'
    / 'detect-resume.sh'
)


def _phase_result_line(phase='VERIFY', verdict='PASS', parse_status='ok',
                       **extra):
    payload = {
        'schema_version': 1,
        'phase': phase,
        'verifier': 'playwright_uat',
        'claimed_verdict': verdict,
        'parse_status': parse_status,
        'parse_error': '',
    }
    payload.update(extra)
    return f'2026-09-03T10:00:00Z|META|phase-result|info|{json.dumps(payload)}'


class TestDispatchTableLoading(unittest.TestCase):
    """The table is the shipped file, not a fixture."""

    def setUp(self):
        self.table = DispatchTable.load(TABLE_PATH)

    def test_loads_the_shipped_table(self):
        self.assertGreater(len(self.table), 0)
        self.assertIn('STEP_1', self.table)
        self.assertIn('STEP_4_5', self.table)

    def test_alias_step_resolves_to_its_target(self):
        # detect-resume.sh emits either STEP_2_5 or STEP_3 for the gate; both
        # must dispatch identically, and the table says so in two places at
        # once (STEP_2_5.aliases and STEP_3.alias_of). Resolution belongs here,
        # not at every call site.
        self.assertEqual(self.table.get('STEP_3')['step_id'], 'STEP_2_5')

    def test_loop_steps_match_the_declared_counters(self):
        # Every loop-bearing step must name a counter the table also declares.
        # A loop whose counter is not in cycle_counters cannot be resumed,
        # because nothing derives its value from the log.
        for step_id in self.table.loop_steps():
            counter = self.table.loop(step_id).get('counter')
            self.assertIn(counter, self.table.cycle_counters,
                          f'{step_id} loops on undeclared counter {counter!r}')

    def test_unknown_step_is_an_error_not_a_silent_none(self):
        with self.assertRaises(DispatchTableError):
            self.table.get('STEP_NOPE')

    def test_rejects_unsupported_schema_version(self):
        # A supervisor that misreads its own sequencing table is worse than one
        # that refuses to start.
        with self.assertRaises(DispatchTableError):
            DispatchTable({'schema_version': 99, 'steps': [{'step_id': 'X'}]})

    def test_rejects_an_empty_table(self):
        with self.assertRaises(DispatchTableError):
            DispatchTable({'schema_version': 1, 'steps': []})

    def test_missing_file_is_reported_with_its_path(self):
        with tempfile.TemporaryDirectory() as tmp:
            with self.assertRaises(DispatchTableError) as ctx:
                DispatchTable.load(Path(tmp) / 'nope.json')
            self.assertIn('nope.json', str(ctx.exception))


class TestClassificationPrecedence(unittest.TestCase):
    """design.md D12, rung by rung."""

    def test_gate_stop_wins_outright(self):
        lines = [
            _phase_result_line('VERIFY', 'PASS'),
            '2026-09-03T10:01:00Z|META|gate-stop|fail|VERIFY_EXHAUSTED',
        ]
        outcome = classify_phase('VERIFY', lines, exit_code=0)
        self.assertEqual(outcome.result, 'fail')
        self.assertEqual(outcome.source, 'gate-stop')
        self.assertIn('VERIFY_EXHAUSTED', outcome.detail)

    def test_gate_stop_beats_a_passing_claim_regardless_of_order(self):
        # The gate-stop is evidence about the run, not about which line came
        # last. A phase-result written after it must not resurrect the phase.
        lines = [
            '2026-09-03T10:00:00Z|META|gate-stop|fail|APPROVAL_REVOKED',
            _phase_result_line('VERIFY', 'PASS'),
        ]
        self.assertEqual(classify_phase('VERIFY', lines).result, 'fail')

    def test_phase_result_decides_when_parseable(self):
        outcome = classify_phase('VERIFY', [_phase_result_line('VERIFY', 'PASS')])
        self.assertEqual(outcome.result, 'done')
        self.assertEqual(outcome.verdict, 'PASS')
        self.assertEqual(outcome.source, 'phase-result')

    def test_verify_fail_is_a_failure(self):
        outcome = classify_phase('VERIFY', [_phase_result_line('VERIFY', 'FAIL')])
        self.assertEqual(outcome.result, 'fail')
        self.assertEqual(outcome.verdict, 'FAIL')

    def test_pr_review_pass_becomes_the_router_token_ok(self):
        # The one place the agent's and the router's vocabularies diverge.
        # detect-resume.sh counts OK; emitting PASS here would freeze the
        # PR-review iteration counter.
        outcome = classify_phase(
            'PR-REVIEW', [_phase_result_line('PR-REVIEW', 'PASS')])
        self.assertEqual(outcome.verdict, 'OK')
        self.assertEqual(outcome.result, 'done')

    def test_pr_review_warn_is_success_that_wants_another_iteration(self):
        outcome = classify_phase(
            'PR-REVIEW', [_phase_result_line('PR-REVIEW', 'WARN')])
        self.assertEqual(outcome.result, 'done')
        self.assertEqual(outcome.verdict, 'WARN')

    def test_pr_review_block_is_a_failure(self):
        outcome = classify_phase(
            'PR-REVIEW', [_phase_result_line('PR-REVIEW', 'BLOCK')])
        self.assertEqual(outcome.result, 'fail')

    def test_router_token_mapping_is_identity_everywhere_else(self):
        self.assertEqual(router_token('VERIFY', 'PASS'), 'PASS')
        self.assertEqual(router_token('PR-REVIEW', 'WARN'), 'WARN')
        self.assertEqual(router_token('PR-REVIEW', 'PASS'), 'OK')

    def test_unparseable_claim_falls_through_rather_than_guessing(self):
        lines = ['2026-09-03T10:00:00Z|META|phase-result|info|{not json']
        outcome = classify_phase('VERIFY', lines, exit_code=0,
                                 terminal_state='done')
        self.assertEqual(outcome.source, 'terminal-state')

    def test_invalid_parse_status_is_not_read_as_a_verdict(self):
        # phase-result-parse.sh degrades a rejected block to UNKNOWN rather
        # than dropping it. That record must not be mistaken for a claim.
        lines = [_phase_result_line('VERIFY', 'UNKNOWN', parse_status='invalid')]
        outcome = classify_phase('VERIFY', lines, terminal_state='done')
        self.assertEqual(outcome.source, 'terminal-state')

    def test_terminal_state_fallback_maps_gate_stopped_to_fail(self):
        outcome = classify_phase('VERIFY', [], terminal_state='gate-stopped')
        self.assertEqual(outcome.result, 'fail')
        self.assertEqual(outcome.source, 'terminal-state')

    def test_terminal_state_gate_held_is_not_a_failure(self):
        # A ticket parked for human approval has not failed; it is waiting.
        outcome = classify_phase('VERIFY', [], terminal_state='gate-held')
        self.assertEqual(outcome.result, 'done')

    def test_nonzero_exit_fails_only_when_nothing_authoritative_exists(self):
        outcome = classify_phase('VERIFY', [], exit_code=1)
        self.assertEqual(outcome.result, 'fail')
        self.assertEqual(outcome.source, 'exit-code')

    def test_nonzero_exit_does_not_override_a_passing_claim(self):
        # The agent said it passed and said so in the grammar; a messy exit
        # code is not counter-evidence to that.
        outcome = classify_phase(
            'VERIFY', [_phase_result_line('VERIFY', 'PASS')], exit_code=1)
        self.assertEqual(outcome.result, 'done')

    def test_exit_zero_is_never_positive_evidence(self):
        # A SIGINT'd headless `-p` worker exits 0. The classification is only
        # 'done' here because nothing says otherwise — and the source records
        # that it rested on nothing, which is what makes the weakness visible
        # rather than silent.
        outcome = classify_phase('VERIFY', [], exit_code=0)
        self.assertEqual(outcome.source, 'exit-code')
        self.assertIn('no authoritative result', outcome.detail)

    def test_non_loop_phase_gets_no_verdict_token(self):
        # APPRAISE has no verdict vocabulary; stamping one on its log line
        # would invent a judgment nobody made.
        self.assertNotIn('APPRAISE', LOOP_BEARING_PHASES)
        outcome = classify_phase(
            'APPRAISE', [_phase_result_line('APPRAISE', 'PASS')])
        self.assertEqual(outcome.verdict, '')


class TestVerifierOverrides(unittest.TestCase):
    """Rung 5: an independent verifier beats the agent's own claim."""

    def test_failed_verifier_overrides_a_passing_claim(self):
        outcome = classify_phase(
            'IMPLEMENT', [_phase_result_line('IMPLEMENT', 'PASS')])
        self.assertEqual(outcome.result, 'done')
        overridden = apply_verifier_overrides(
            outcome, {'return_completeness': False})
        self.assertEqual(overridden.result, 'fail')
        self.assertEqual(overridden.source, 'verifier-override')
        self.assertIn('return_completeness', overridden.detail)

    def test_passing_verifiers_leave_the_outcome_alone(self):
        outcome = PhaseOutcome('done', 'PASS', 'phase-result', 'ok')
        self.assertIs(
            apply_verifier_overrides(outcome, {'return_completeness': True}),
            outcome)

    def test_no_overrides_is_a_no_op(self):
        outcome = PhaseOutcome('done', 'PASS', 'phase-result', 'ok')
        self.assertIs(apply_verifier_overrides(outcome, None), outcome)


class TestMissingPhaseResultInstrumentation(unittest.TestCase):
    """The fallback is quiet; the miss is still counted."""

    def test_absent_block_on_a_loop_phase_is_a_miss(self):
        self.assertTrue(missing_phase_result('VERIFY', []))

    def test_unknown_verdict_is_a_miss(self):
        lines = [_phase_result_line('VERIFY', 'UNKNOWN', parse_status='invalid')]
        self.assertTrue(missing_phase_result('VERIFY', lines))

    def test_valid_block_is_not_a_miss(self):
        self.assertFalse(
            missing_phase_result('VERIFY', [_phase_result_line('VERIFY', 'PASS')]))

    def test_non_loop_phase_can_never_miss(self):
        # APPRAISE is not asked for a phase-result, so counting its absence
        # would make the miss-rate metric meaningless.
        self.assertFalse(missing_phase_result('APPRAISE', []))


class TestExitCodeRouting(unittest.TestCase):

    def test_flow_state_assertion_always_gate_stops(self):
        # flow.sh exit 7 is a state-integrity failure. Re-running the phase on
        # top of a diverged Linear state would compound it.
        outcome = PhaseOutcome('done', 'PASS', 'phase-result', 'ok')
        route, detail = route_exit_code(FLOW_STATE_ASSERTION_EXIT, outcome)
        self.assertEqual(route, EXIT_ROUTE_GATE_STOP)
        self.assertEqual(detail, 'STATE_ASSERTION_FAILED')

    def test_done_continues(self):
        outcome = PhaseOutcome('done', 'PASS', 'phase-result', 'ok')
        self.assertEqual(route_exit_code(0, outcome)[0], EXIT_ROUTE_CONTINUE)

    def test_failed_loop_phase_retries(self):
        outcome = PhaseOutcome('fail', 'FAIL', 'phase-result', 'uat failed')
        route, _ = route_exit_code(0, outcome, loop_bearing=True)
        self.assertEqual(route, EXIT_ROUTE_RETRY)

    def test_failed_non_loop_phase_gate_stops(self):
        outcome = PhaseOutcome('fail', '', 'exit-code', 'exit 1')
        route, _ = route_exit_code(1, outcome, loop_bearing=False)
        self.assertEqual(route, EXIT_ROUTE_GATE_STOP)


class TestTerminalWrite(unittest.TestCase):
    """design.md D13 — one writer of the line grammar, two callers."""

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.log = Path(self._tmp.name) / 'CRE-1-pipeline.log'
        self.log.write_text('2026-09-03T09:00:00Z|META|schema|info|2\n')

    def tearDown(self):
        self._tmp.cleanup()

    def test_writes_the_grammar_detect_resume_keys_on(self):
        outcome = PhaseOutcome('done', 'PASS', 'phase-result', '3/3 criteria')
        phase_terminal_write('VERIFY', 'verify', outcome, self.log,
                             lib_dir=TICKET_AUTO_LIB)
        written = self.log.read_text()
        self.assertIn('|VERIFY|verify|done|PASS — 3/3 criteria', written)

    def test_fail_outcome_writes_a_fail_terminal(self):
        outcome = PhaseOutcome('fail', '', 'gate-stop', 'VERIFY_EXHAUSTED')
        phase_terminal_write('VERIFY', 'verify', outcome, self.log,
                             lib_dir=TICKET_AUTO_LIB)
        self.assertIn('|VERIFY|verify|fail|VERIFY_EXHAUSTED',
                      self.log.read_text())

    def test_missing_helper_is_reported_not_swallowed(self):
        # Silently skipping the write would leave the bracket open forever and
        # look identical to fleetd having died mid-phase.
        outcome = PhaseOutcome('done', '', 'phase-result', 'ok')
        with tempfile.TemporaryDirectory() as empty:
            with self.assertRaises(TerminalWriteError):
                phase_terminal_write('VERIFY', 'verify', outcome, self.log,
                                     lib_dir=empty)


if __name__ == '__main__':
    unittest.main()


class TestForeignRunInterlock(unittest.TestCase):
    """Task 4.19 — staying out of a session fleetd does not own.

    The line these tests defend is between a *foreign run* and an *orphan*.
    Both look like an open bracket with no fleetd worker; only the activity
    log tells them apart, and getting it wrong in one direction interleaves
    two orchestrators on one Linear issue while getting it wrong in the other
    stops fleetd recovering from any crash at all.
    """

    NOW = 1_760_000_000.0

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.activity = Path(self._tmp.name) / 'CRE-5-activity.log'

    def tearDown(self):
        self._tmp.cleanup()

    def _activity(self, seconds_ago):
        from datetime import datetime, timezone
        stamp = datetime.fromtimestamp(self.NOW - seconds_ago, timezone.utc)
        self.activity.write_text(
            stamp.strftime('%Y-%m-%dT%H:%M:%SZ') + '|IMPLEMENT|Edit\n')
        return self.activity

    OPEN = ['2026-09-03T09:00:00Z|IMPLEMENT|implement|waiting|Agent launched']
    CLOSED = OPEN + ['2026-09-03T09:20:00Z|IMPLEMENT|implement|done|ok']

    def test_a_live_foreign_session_is_detected(self):
        found = phase_dispatch.detect_foreign_run(
            'CRE-5', self.OPEN, self._activity(30), False, now=self.NOW)
        self.assertTrue(found.detected)
        self.assertEqual(found.reason, phase_dispatch.FOREIGN_ACTIVE_RUN)
        self.assertEqual(found.age_secs, 30)

    def test_a_stale_activity_log_is_an_orphan_not_a_foreign_run(self):
        # The distinction the whole design rests on. Treating this as foreign
        # would stop reconciliation recovering from any crash.
        found = phase_dispatch.detect_foreign_run(
            'CRE-5', self.OPEN, self._activity(4000), False, now=self.NOW)
        self.assertFalse(found.detected)
        self.assertIn('stale', found.detail)

    def test_fleetds_own_worker_is_never_foreign(self):
        found = phase_dispatch.detect_foreign_run(
            'CRE-5', self.OPEN, self._activity(5), True, now=self.NOW)
        self.assertFalse(found.detected)

    def test_a_resolved_bracket_is_not_a_run_in_progress(self):
        found = phase_dispatch.detect_foreign_run(
            'CRE-5', self.CLOSED, self._activity(5), False, now=self.NOW)
        self.assertFalse(found.detected)
        self.assertIn('no open bracket', found.detail)

    def test_a_missing_activity_log_does_not_block_dispatch(self):
        # A ticket a human started before the activity hook existed, or on a
        # host where it never fired, must not be permanently undispatchable.
        found = phase_dispatch.detect_foreign_run(
            'CRE-5', self.OPEN, '/nonexistent/CRE-5-activity.log', False,
            now=self.NOW)
        self.assertFalse(found.detected)

    def test_open_bracket_is_read_from_the_last_bracket_line_only(self):
        # A log carrying an older unresolved bracket followed by a resolved
        # one is not open. Counting waiting-vs-terminal totals would say it is,
        # and legacy zombie brackets make that common.
        lines = [
            '2026-09-03T08:00:00Z|APPRAISE|appraise|waiting|zombie',
            '2026-09-03T09:00:00Z|IMPLEMENT|implement|waiting|Agent launched',
            '2026-09-03T09:20:00Z|IMPLEMENT|implement|done|ok',
        ]
        self.assertFalse(phase_dispatch.has_open_bracket(lines))
        self.assertTrue(phase_dispatch.has_open_bracket(lines[:2]))

    def test_a_skip_terminal_also_closes_a_bracket(self):
        lines = self.OPEN + [
            '2026-09-03T09:20:00Z|IMPLEMENT|implement|skip|nothing to do']
        self.assertFalse(phase_dispatch.has_open_bracket(lines))

    def test_the_window_is_configurable(self):
        os.environ['FLEET_FOREIGN_ACTIVITY_SECS'] = '60'
        try:
            self.assertEqual(phase_dispatch.foreign_activity_window_secs(), 60)
            found = phase_dispatch.detect_foreign_run(
                'CRE-5', self.OPEN, self._activity(120), False, now=self.NOW)
            self.assertFalse(found.detected)
        finally:
            os.environ.pop('FLEET_FOREIGN_ACTIVITY_SECS', None)

    def test_a_nonsense_window_falls_back_to_the_default(self):
        os.environ['FLEET_FOREIGN_ACTIVITY_SECS'] = 'soon'
        try:
            self.assertEqual(
                phase_dispatch.foreign_activity_window_secs(),
                phase_dispatch.DEFAULT_FOREIGN_ACTIVITY_SECS)
        finally:
            os.environ.pop('FLEET_FOREIGN_ACTIVITY_SECS', None)


class TestBracketOpen(unittest.TestCase):
    """Task 4.12 — the opening half, through the same shared bash writer."""

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.log = Path(self._tmp.name) / 'CRE-7-pipeline.log'
        self.log.write_text('2026-09-03T09:00:00Z|META|schema|info|1\n')

    def tearDown(self):
        self._tmp.cleanup()

    def test_opens_the_bracket_and_names_the_model(self):
        model = phase_dispatch.phase_bracket_open(
            'verify', 'Verify', 'CRE-7', self.log,
            description='verify agent', model='claude-opus-5',
            lib_dir=TICKET_AUTO_LIB)
        written = self.log.read_text()
        self.assertEqual(model, 'claude-opus-5')
        self.assertIn('|VERIFY|verify|waiting|Agent launched — verify agent',
                      written)
        self.assertIn('"model":"claude-opus-5"', written)

    def test_a_second_open_of_the_same_bracket_is_suppressed(self):
        for _ in range(2):
            phase_dispatch.phase_bracket_open('VERIFY', 'verify', 'CRE-7',
                                              self.log,
                                              lib_dir=TICKET_AUTO_LIB)
        self.assertEqual(self.log.read_text().count('|VERIFY|verify|waiting|'),
                         1)

    def test_missing_helper_is_reported_not_swallowed(self):
        # A silently unopened bracket looks exactly like a phase that never
        # started, which is what the zombie detector and resume both read.
        with tempfile.TemporaryDirectory() as empty:
            with self.assertRaises(phase_dispatch.BracketOpenError):
                phase_dispatch.phase_bracket_open('VERIFY', 'verify', 'CRE-7',
                                                  self.log, lib_dir=empty)


class TestLivenessHeartbeat(unittest.TestCase):
    """The watchdog replacement — a checked fact, not a scheduled assertion."""

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.hb = Path(self._tmp.name) / 'CRE-8-heartbeat.log'
        self.hb.write_text('2026-09-03T09:00:00Z|META|schema|info|2|{}\n')

    def tearDown(self):
        self._tmp.cleanup()

    def test_writes_the_line_fleet_detect_reads_for_a_live_worker(self):
        wrote = phase_dispatch.phase_liveness_heartbeat(
            'CRE-8', 'verify', self.hb, os.getpid())
        self.assertTrue(wrote)
        # fleet-detect.sh:411 greps exactly this shape for its heartbeat
        # liveness dimension; a phase-dispatched ticket emitting nothing at
        # all would cross FLEET_STALL_WARN_SECS while running perfectly.
        self.assertIn('|watchdog|alive|', self.hb.read_text())

    def test_a_dead_worker_produces_no_line(self):
        # Emitting liveness on a schedule rather than on a check would assert
        # the very thing the line is supposed to measure.
        dead = 2 ** 22 - 1
        wrote = phase_dispatch.phase_liveness_heartbeat(
            'CRE-8', 'verify', self.hb, dead)
        self.assertFalse(wrote)
        self.assertNotIn('|watchdog|alive|', self.hb.read_text())

    def test_a_recycled_pid_is_not_alive(self):
        # Same start-ticks guard spawn-helper.sh and detect-resume.sh use: the
        # pid exists, but it is not the process that was forked.
        wrote = phase_dispatch.phase_liveness_heartbeat(
            'CRE-8', 'verify', self.hb, os.getpid(), start_ticks='1')
        self.assertFalse(wrote)

    def test_no_heartbeat_file_is_not_an_error(self):
        self.assertFalse(
            phase_dispatch.phase_liveness_heartbeat('CRE-8', 'verify', '',
                                                    os.getpid()))


class TestReturnCapture(unittest.TestCase):
    """The phase-result channel's input on the automated path."""

    def test_json_envelope_is_unwrapped_to_the_result_text(self):
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / 'CRE-9-verify-gen1.json'
            out.write_text(json.dumps({
                'type': 'result', 'is_error': False,
                'result': '=== PHASE_RESULT ===\nVERDICT: PASS\n',
            }))
            self.assertIn('VERDICT: PASS',
                          phase_dispatch.worker_return_text(out))
            self.assertNotIn('"is_error"',
                             phase_dispatch.worker_return_text(out))

    def test_a_non_json_capture_falls_back_to_its_raw_text(self):
        # A truncated capture still carries a readable tail, and a
        # phase-result block that survives there beats none.
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / 'CRE-9-verify-gen1.json'
            out.write_text('{"result": "half a jso')
            self.assertIn('half a jso', phase_dispatch.worker_return_text(out))

    def test_a_missing_capture_is_empty_not_an_error(self):
        self.assertEqual(
            phase_dispatch.worker_return_text('/nonexistent/x.json'), '')

    def test_capture_writes_the_file_phase_result_parse_reads(self):
        with tempfile.TemporaryDirectory() as tmp:
            cwd = os.getcwd()
            os.chdir(tmp)
            try:
                ok = phase_dispatch.capture_phase_return(
                    'CRE-9', 'VERIFY', 'the agent said this',
                    lib_dir=TICKET_AUTO_LIB)
                self.assertTrue(ok)
                captured = Path(tmp) / 'logs' / 'CRE-9-verify-agent.log'
                self.assertTrue(captured.is_file())
                self.assertIn('the agent said this', captured.read_text())
            finally:
                os.chdir(cwd)


FIXTURES_DIR = Path(__file__).resolve().parent / 'fixtures'


class TestNdjsonReturnCapture(unittest.TestCase):
    """Inc 0 (agent-observer): `worker_return_text` on stream-json NDJSON.

    Fixtures are real `claude -p --output-format stream-json --verbose`
    captures (see `fixtures/README.md`) — not hand-written — so a change to
    the CLI's actual frame shape would show up here rather than only in a
    synthetic fixture that quietly drifted from reality.
    """

    def test_ndjson_fixture_extracts_the_same_result_as_single_object_json(self):
        ndjson_path = FIXTURES_DIR / 'stream-json-bash-exit3.ndjson'
        ndjson_result = phase_dispatch.worker_return_text(ndjson_path)

        with tempfile.TemporaryDirectory() as tmp:
            single = Path(tmp) / 'equivalent.json'
            single.write_text(json.dumps({'type': 'result', 'result': 'DONE'}))
            single_result = phase_dispatch.worker_return_text(single)

        self.assertEqual(ndjson_result, 'DONE')
        self.assertEqual(ndjson_result, single_result)

    def test_a_trailing_non_result_line_after_result_does_not_break_extraction(self):
        # This fixture's `result` frame is followed by a `hook_response`-class
        # line (design.md E5) — `result` is not always the last line.
        ndjson_path = FIXTURES_DIR / 'stream-json-bash-ok-with-hook-events.ndjson'
        self.assertEqual(
            phase_dispatch.worker_return_text(ndjson_path), 'DONE')

    def test_last_result_line_wins_when_multiple_are_present(self):
        raw = '\n'.join([
            json.dumps({'type': 'result', 'result': 'FIRST'}),
            json.dumps({'type': 'system'}),
            json.dumps({'type': 'result', 'result': 'LAST'}),
        ])
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / 'CRE-9-verify-gen1.ndjson'
            out.write_text(raw)
            self.assertEqual(phase_dispatch.worker_return_text(out), 'LAST')

    def test_unparseable_line_is_skipped_not_fatal(self):
        raw = '\n'.join([
            'not json at all',
            json.dumps({'type': 'result', 'result': 'DONE'}),
        ])
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / 'CRE-9-verify-gen1.ndjson'
            out.write_text(raw)
            self.assertEqual(phase_dispatch.worker_return_text(out), 'DONE')

    def test_no_result_line_falls_back_to_raw_text(self):
        raw = '\n'.join([
            json.dumps({'type': 'assistant', 'result': None}),
            json.dumps({'type': 'system'}),
        ])
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / 'CRE-9-verify-gen1.ndjson'
            out.write_text(raw)
            self.assertEqual(phase_dispatch.worker_return_text(out), raw)


class TestWorkerCostUsd(unittest.TestCase):
    """fleet-cost-events: cost extraction from a worker's stdout envelope."""

    def test_a_valid_envelope_yields_a_float(self):
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / 'CRE-9-gen1.json'
            out.write_text(json.dumps({
                'type': 'result', 'total_cost_usd': 0.4321,
            }))
            self.assertEqual(phase_dispatch.worker_cost_usd(out), 0.4321)

    def test_non_json_content_yields_none(self):
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / 'CRE-9-gen1.json'
            out.write_text('not json at all')
            self.assertIsNone(phase_dispatch.worker_cost_usd(out))

    def test_missing_field_yields_none(self):
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / 'CRE-9-gen1.json'
            out.write_text(json.dumps({'type': 'result'}))
            self.assertIsNone(phase_dispatch.worker_cost_usd(out))

    def test_missing_file_yields_none(self):
        self.assertIsNone(
            phase_dispatch.worker_cost_usd('/nonexistent/CRE-9-gen1.json'))

    def test_ndjson_envelope_yields_the_terminal_frames_cost(self):
        # Agent Observer: a phase worker spawned under FLEET_OBSERVER_ENABLE
        # writes stream-json, so this must not silently regress to None.
        raw = '\n'.join([
            json.dumps({'type': 'assistant'}),
            json.dumps({'type': 'result', 'total_cost_usd': 0.99}),
        ])
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / 'CRE-9-verify-gen1.ndjson'
            out.write_text(raw)
            self.assertEqual(phase_dispatch.worker_cost_usd(out), 0.99)

    def test_ndjson_with_no_result_line_yields_none(self):
        raw = json.dumps({'type': 'assistant'})
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / 'CRE-9-verify-gen1.ndjson'
            out.write_text(raw + '\n' + json.dumps({'type': 'system'}))
            self.assertIsNone(phase_dispatch.worker_cost_usd(out))

    def test_non_numeric_value_yields_none(self):
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / 'CRE-9-gen1.json'
            out.write_text(json.dumps({'total_cost_usd': 'oops'}))
            self.assertIsNone(phase_dispatch.worker_cost_usd(out))

    def test_capture_is_fail_soft_when_the_helper_is_absent(self):
        with tempfile.TemporaryDirectory() as empty:
            self.assertFalse(phase_dispatch.capture_phase_return(
                'CRE-9', 'VERIFY', 'x', lib_dir=empty))


class TestPhaseSpawnConstruction(unittest.TestCase):
    """Task 4.4 — turning a table row into a `claude -p` invocation.

    The prompt is asserted against the real table rather than a fixture for
    the same reason as the loading tests: a fixture would keep passing while
    the shipped `instructions` changed underneath it.
    """

    def setUp(self):
        self.table = DispatchTable.load(TABLE_PATH)

    def test_prompt_is_a_slash_command_for_the_step_s_skill(self):
        spawn = build_phase_spawn(self.table, 'STEP_1', 'CRE-9', '/w/log')
        self.assertTrue(spawn.prompt.startswith('/ticket-appraise CRE-9 '))
        self.assertEqual(spawn.phase, 'APPRAISE')
        self.assertEqual(spawn.step, 'appraise')

    def test_agent_is_carried_from_the_table(self):
        spawn = build_phase_spawn(self.table, 'STEP_1', 'CRE-9', '/w/log')
        self.assertEqual(spawn.agent,
                          'ticket-auto-pipeline:ticket-appraise-agent')

    def test_agent_is_none_for_a_step_with_no_dedicated_type(self):
        spawn = build_phase_spawn(self.table, 'STEP_5_5', 'CRE-9', '/w/log')
        self.assertIsNone(spawn.agent)

    def test_extra_flags_from_the_table_are_used_verbatim(self):
        spawn = build_phase_spawn(self.table, 'STEP_4', 'CRE-9', '/w/log')
        self.assertIn('--from-auto --mode extract', spawn.prompt)

    def test_steps_without_extra_flags_get_the_router_default(self):
        spawn = build_phase_spawn(self.table, 'STEP_1', 'CRE-9', '/w/log')
        self.assertIn(f'CRE-9 {DEFAULT_PHASE_FLAGS}', spawn.prompt)

    def test_from_step_is_appended_as_the_router_appends_it(self):
        spawn = build_phase_spawn(self.table, 'STEP_1', 'CRE-9', '/w/log',
                                  from_step='step-3')
        self.assertIn('--from-step step-3', spawn.prompt)

    def test_no_from_step_means_no_flag(self):
        spawn = build_phase_spawn(self.table, 'STEP_1', 'CRE-9', '/w/log')
        self.assertNotIn('--from-step', spawn.prompt)

    def test_attempt_expression_is_resolved_to_a_literal(self):
        """The agent must never receive an unevaluated `$((… + 1))`."""
        spawn = build_phase_spawn(
            self.table, 'STEP_4_5', 'CRE-9', '/w/log',
            counters={'VERIFY_ATTEMPTS': 1})
        self.assertIn('PHASE_RESULT_ATTEMPT=2', spawn.prompt)
        self.assertNotIn('$((', spawn.prompt)
        self.assertNotIn('{VERIFY_ATTEMPTS}', spawn.prompt)

    def test_iteration_counter_is_resolved_for_pr_review(self):
        spawn = build_phase_spawn(
            self.table, 'STEP_4_6', 'CRE-9', '/w/log',
            counters={'ITERATION': 2})
        self.assertIn('PHASE_RESULT_ATTEMPT=3', spawn.prompt)
        self.assertNotIn('$((', spawn.prompt)

    def test_log_paths_become_real_environment_not_prompt_exports(self):
        """Task 4.16 — a value fleetd owns is configured, not requested.

        The router has to ask the agent to `export LOG_FILE=…` because it
        cannot set another process's environment. fleetd forks the phase, so
        it can — and a real env var cannot be half-applied the way a sourced
        env file swallowed by `|| true` can.
        """
        spawn = build_phase_spawn(
            self.table, 'STEP_1', 'CRE-9', '/w/logs/CRE-9-pipeline.log',
            hb_log_file='/w/logs/CRE-9-hb.log',
            claude_log_file='/tmp/CRE-9-claude.log')
        self.assertEqual(spawn.env['LOG_FILE'], '/w/logs/CRE-9-pipeline.log')
        self.assertEqual(spawn.env['HB_LOG_FILE'], '/w/logs/CRE-9-hb.log')
        self.assertEqual(spawn.env['CLAUDE_LOG_FILE'], '/tmp/CRE-9-claude.log')
        self.assertEqual(spawn.env['HUSKY'], '0')
        self.assertNotIn('export LOG_FILE', spawn.prompt)

    def test_phase_identity_is_in_the_environment(self):
        spawn = build_phase_spawn(self.table, 'STEP_4_5', 'CRE-9', '/w/log')
        self.assertEqual(spawn.env['FLEET_PHASE'], 'VERIFY')
        self.assertEqual(spawn.env['FLEET_STEP'], 'verify')
        self.assertEqual(spawn.env['FLEET_DISPATCH_STEP_ID'], 'STEP_4_5')
        self.assertEqual(spawn.env['FLEET_TICKET_ID'], 'CRE-9')

    def test_attempt_is_stamped_into_the_environment(self):
        spawn = build_phase_spawn(self.table, 'STEP_4_5', 'CRE-9', '/w/log',
                                  attempt=2)
        self.assertEqual(spawn.env['PHASE_RESULT_ATTEMPT'], '2')

    def test_no_attempt_means_no_variable(self):
        spawn = build_phase_spawn(self.table, 'STEP_4_5', 'CRE-9', '/w/log')
        self.assertNotIn('PHASE_RESULT_ATTEMPT', spawn.env)

    def test_extra_env_overrides_defaults(self):
        spawn = build_phase_spawn(self.table, 'STEP_1', 'CRE-9', '/w/log',
                                  extra_env={'REPOS_ROOT': '/repos'})
        self.assertEqual(spawn.env['REPOS_ROOT'], '/repos')

    def test_loop_bearing_flag_comes_from_the_table(self):
        self.assertTrue(
            build_phase_spawn(self.table, 'STEP_4_5', 'C-1', '/l').loop_bearing)
        self.assertFalse(
            build_phase_spawn(self.table, 'STEP_1', 'C-1', '/l').loop_bearing)

    def test_the_gate_alias_is_not_spawnable(self):
        """STEP_3 resolves to a bash gate, which has no agent to spawn."""
        with self.assertRaises(PhaseSpawnError):
            build_phase_spawn(self.table, 'STEP_3', 'CRE-9', '/w/log')

    def test_every_agent_step_in_the_table_can_be_built(self):
        """Drift guard: a new agent step must not need new code here."""
        built = 0
        for step_id in self.table.step_ids():
            step = self.table.get(step_id)
            if not (step.get('spawn') or {}).get('skill'):
                continue
            spawn = build_phase_spawn(self.table, step_id, 'CRE-1', '/w/log')
            self.assertTrue(spawn.prompt.startswith('/'))
            self.assertTrue(spawn.phase, f'{step_id} has no phase')
            built += 1
        self.assertGreaterEqual(built, 6)


class TestHookIdentityFiles(unittest.TestCase):
    """Task 4.13 / D15 — the files every identity-resolving hook reads.

    Under the router these are written by `spawn_agent_pre` and
    `token-tracker-start.sh`. Neither runs for a fleetd-dispatched phase, so
    fleetd writes them — in the same shape, so the hooks need no change.
    """

    def setUp(self):
        self.table = DispatchTable.load(TABLE_PATH)
        self.tmp = tempfile.mkdtemp()
        self.spawn = build_phase_spawn(
            self.table, 'STEP_4_5', 'CRE-9', '/w/logs/CRE-9-pipeline.log',
            hb_log_file='/w/logs/CRE-9-hb.log', attempt=2)

    def _meta(self, **kw):
        path = write_spawn_meta('CRE-9', self.spawn, 'sess-abc',
                                meta_dir=self.tmp, **kw)
        return dict(
            line.split('=', 1)
            for line in path.read_text().splitlines() if '=' in line
        )

    def test_session_id_is_the_field_hooks_match_on(self):
        self.assertEqual(self._meta()['SESSION_ID'], 'sess-abc')

    def test_phase_and_log_file_come_from_the_spawn(self):
        fields = self._meta()
        self.assertEqual(fields['PHASE'], 'VERIFY')
        self.assertEqual(fields['STEP'], 'verify')
        self.assertEqual(fields['TICKET_ID'], 'CRE-9')
        self.assertEqual(fields['LOG_FILE'], '/w/logs/CRE-9-pipeline.log')
        self.assertEqual(fields['HB_LOG_FILE'], '/w/logs/CRE-9-hb.log')

    def test_spawned_by_marks_the_file_as_fleetd_written(self):
        """The discriminator that keeps a phase from being counted twice.

        Without it both SubagentStop (the phase agent's own subagents) and
        Stop (the phase session itself) match this file.
        """
        self.assertEqual(self._meta()['SPAWNED_BY'], 'fleetd')

    def test_attempt_is_carried_for_the_agent_to_read(self):
        self.assertEqual(self._meta()['ATTEMPT'], '2')

    def test_model_defaults_to_the_environment(self):
        fields = self._meta(model='claude-test-model')
        self.assertEqual(fields['MODEL'], 'claude-test-model')

    def test_filename_matches_what_the_hooks_glob(self):
        path = write_spawn_meta('CRE-9', self.spawn, 's', meta_dir=self.tmp)
        self.assertEqual(path.name, 'ticket-auto-CRE-9-spawn-meta.txt')

    def test_start_marker_matches_the_hook_s_find_pattern(self):
        """`token-tracker.sh` finds this by name; the shape is the contract."""
        path = write_phase_start_marker('CRE-9', 'VERIFY', meta_dir=self.tmp)
        self.assertTrue(path.name.startswith('ticket-auto-CRE-9-start-VERIFY-'))
        self.assertTrue(path.name.endswith('.ts'))
        self.assertGreater(int(path.read_text()), 0)


class TestLoopCaps(unittest.TestCase):
    """Task 4.6 — the four router-managed cycle caps.

    Every value comes from the table. These tests read the caps from the same
    file the code does rather than asserting literals, so raising a cap in the
    JSON does not require editing a test — the thing being asserted is the
    rule, not the number.
    """

    def setUp(self):
        self.table = DispatchTable.load(TABLE_PATH)

    def _loop(self, step_id):
        return self.table.loop(step_id)

    def test_the_table_declares_exactly_four_loops(self):
        self.assertEqual(len(self.table.loop_steps()), 4)

    def test_a_non_loop_step_is_reported_as_such(self):
        d = evaluate_loop(self.table, 'STEP_1', {})
        self.assertEqual(d.action, LOOP_NOT_LOOPED)

    def test_under_the_cap_dispatches(self):
        for step_id in self.table.loop_steps():
            loop = self._loop(step_id)
            counters = {loop['counter']: loop['max_iterations'] - 1}
            d = evaluate_loop(self.table, step_id, counters)
            self.assertEqual(d.action, LOOP_DISPATCH, step_id)

    def test_at_the_cap_gate_stops(self):
        for step_id in self.table.loop_steps():
            loop = self._loop(step_id)
            counters = {loop['counter']: loop['max_iterations']}
            d = evaluate_loop(self.table, step_id, counters)
            self.assertEqual(d.action, LOOP_GATE_STOP, step_id)

    def test_exhaustion_uses_the_table_s_named_code(self):
        """Never an invented one: these names are the log contract."""
        for step_id in self.table.loop_steps():
            loop = self._loop(step_id)
            d = evaluate_loop(self.table, step_id,
                              {loop['counter']: loop['max_iterations']})
            self.assertEqual(d.gate_stop_code, loop['gate_stop_code'], step_id)
            self.assertTrue(d.gate_stop_code,
                            f'{step_id} exhausts without a named code')

    def test_every_loop_names_a_gate_stop_code(self):
        """STEP_4_6 shipped with `null` here; task 4.6 named it."""
        for step_id in self.table.loop_steps():
            self.assertTrue(self._loop(step_id).get('gate_stop_code'),
                            f'{step_id} has no gate_stop_code')

    def test_the_pr_review_cap_is_the_code_the_router_also_writes(self):
        d = evaluate_loop(self.table, 'STEP_4_6', {'ITERATION': 3})
        self.assertEqual(d.gate_stop_code, 'PR_REVIEW_EXHAUSTED')

    def test_a_cap_asked_about_at_the_wrong_moment_does_not_apply(self):
        """A post-dispatch cap must not refuse the attempt it is counting.

        Verify's cap is checked after the phase runs. Applying it before would
        cost a ticket its final allowed attempt.
        """
        d = evaluate_loop(self.table, 'STEP_4_5', {'VERIFY_ATTEMPTS': 99},
                          when='pre_dispatch')
        self.assertEqual(d.action, LOOP_DISPATCH)
        self.assertIn('post_dispatch', d.detail)

    def test_a_cap_asked_about_at_its_own_moment_applies(self):
        d = evaluate_loop(self.table, 'STEP_4_5', {'VERIFY_ATTEMPTS': 99},
                          when='post_dispatch')
        self.assertEqual(d.action, LOOP_GATE_STOP)

    def test_a_missing_counter_reads_as_zero_not_as_exhausted(self):
        """A fresh ticket has written no counter yet."""
        d = evaluate_loop(self.table, 'STEP_4_5', {})
        self.assertEqual(d.action, LOOP_DISPATCH)
        self.assertEqual(d.value, 0)

    def test_an_unparseable_counter_reads_as_zero(self):
        d = evaluate_loop(self.table, 'STEP_4_5', {'VERIFY_ATTEMPTS': 'x'})
        self.assertEqual(d.action, LOOP_DISPATCH)

    def test_caps_are_not_duplicated_as_python_constants(self):
        """The limit reported is the table's, whatever the table says."""
        import fleetd.phase_dispatch as mod
        src = Path(mod.__file__).read_text()
        for step_id in self.table.loop_steps():
            loop = self._loop(step_id)
            self.assertNotIn(f"max_iterations = {loop['max_iterations']}", src)
            self.assertNotIn(f"'{loop['gate_stop_code']}'", src,
                             f"{loop['gate_stop_code']} is defined in Python as "
                             f"well as in the table — two authorities on one "
                             f"log-contract string")



class TestDetectResumeBlockParsing(unittest.TestCase):
    """Pure parse of the `DETECT_RESUME_RESULT` block (task 4.3, D7)."""

    def test_parses_the_shipped_grammar(self):
        text = (
            'some stderr noise before the block\n'
            'DETECT_RESUME_RESULT\n'
            '  RESUME_STEP:        STEP_2\n'
            '  COMPLEXITY:         simple\n'
            '  AUTONOMY:           auto\n'
            'END_DETECT_RESUME_RESULT\n'
            'trailing noise after\n'
        )
        fields = parse_detect_resume_block(text)
        self.assertEqual(fields['RESUME_STEP'], 'STEP_2')
        self.assertEqual(fields['COMPLEXITY'], 'simple')
        self.assertEqual(fields['AUTONOMY'], 'auto')
        self.assertNotIn('trailing noise after', fields)

    def test_no_block_yields_empty_fields(self):
        self.assertEqual(parse_detect_resume_block('nothing here'), {})

    def test_empty_value_is_kept_as_empty_string(self):
        text = 'DETECT_RESUME_RESULT\n  BRANCH:             \nEND_DETECT_RESUME_RESULT\n'
        self.assertEqual(parse_detect_resume_block(text)['BRANCH'], '')


class TestAdoptPositionAgainstTheRealScript(unittest.TestCase):
    """`detect-resume.sh` is invoked at most once per ticket (D7) — these run
    the shipped script for real rather than a hand-written fixture, so a
    change to its `RESUME_STEP` vocabulary is caught here, not in production.
    """

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.project_dir = Path(self._tmp.name)
        (self.project_dir / 'logs').mkdir()

    def tearDown(self):
        self._tmp.cleanup()

    def _env(self):
        env = dict(os.environ)
        env['CLAUDE_SKILLS_LIB'] = str(TICKET_AUTO_LIB)
        return env

    def test_no_prior_log_adopts_step_1(self):
        step, fields = adopt_position_via_detect_resume(
            'CRE-4301', project_dir=self.project_dir,
            script=DETECT_RESUME_SCRIPT)
        self.assertEqual(step, 'STEP_1')
        self.assertEqual(fields['RESUME_STEP'], 'STEP_1')

    def test_appraise_done_adopts_step_2(self):
        log = self.project_dir / 'logs' / 'CRE-4302-pipeline.log'
        log.write_text(
            '2026-01-01T00:00:00Z|META|schema|info|2\n'
            '2026-01-01T00:00:01Z|APPRAISE|appraise|done|ok\n'
        )
        step, fields = adopt_position_via_detect_resume(
            'CRE-4302', project_dir=self.project_dir,
            script=DETECT_RESUME_SCRIPT)
        self.assertEqual(step, 'STEP_2')

    def test_completed_pipeline_adopts_done(self):
        log = self.project_dir / 'logs' / 'CRE-4303-pipeline.log'
        log.write_text(
            '2026-01-01T00:00:00Z|META|schema|info|2\n'
            '2026-01-01T00:00:01Z|META|outcome|info|completed: STEP_6\n'
        )
        step, _fields = adopt_position_via_detect_resume(
            'CRE-4303', project_dir=self.project_dir,
            script=DETECT_RESUME_SCRIPT)
        self.assertEqual(step, 'done')

    def test_schema_mismatch_raises_rather_than_returning_a_bogus_step(self):
        log = self.project_dir / 'logs' / 'CRE-4304-pipeline.log'
        log.write_text('2026-01-01T00:00:00Z|META|schema|info|99\n')
        with self.assertRaises(ResumeAdoptError):
            adopt_position_via_detect_resume(
                'CRE-4304', project_dir=self.project_dir,
                script=DETECT_RESUME_SCRIPT)

    def test_missing_script_is_reported_not_swallowed(self):
        with tempfile.TemporaryDirectory() as empty:
            with self.assertRaises(ResumeAdoptError):
                adopt_position_via_detect_resume(
                    'CRE-4305', project_dir=self.project_dir,
                    script=Path(empty) / 'no-such-script.sh')

    def test_default_script_path_resolves_under_the_repo_checkout(self):
        # No CLAUDE_SKILLS_LIB, no installed skills dir override — falls
        # back to the checkout, matching dispatch_table_path's own fallback.
        self.assertEqual(detect_resume_script_path(lib_dir=TICKET_AUTO_LIB),
                         DETECT_RESUME_SCRIPT)


class _FakePositionStore:
    """The two `FleetStore` methods `resolve_dispatch_position` calls."""

    def __init__(self, position=None):
        self._position = position
        self.recorded = []

    def get_position(self, tid):
        return self._position

    def record_position(self, tid, position, source='dispatch'):
        self.recorded.append((tid, position, source))
        self._position = {'position': position, 'source': source}


class TestResolveDispatchPosition(unittest.TestCase):
    """design.md D7 — a store-recorded position wins; adoption runs once."""

    def test_recorded_position_is_returned_without_adopting(self):
        store = _FakePositionStore(
            position={'position': 'STEP_4', 'source': 'dispatch'})
        step, source, fields = resolve_dispatch_position(
            store, 'CRE-1', script=Path('/does/not/exist.sh'))
        self.assertEqual((step, source, fields), ('STEP_4', 'dispatch', {}))
        self.assertEqual(store.recorded, [])  # no second write

    def test_no_recorded_position_adopts_and_records_it(self):
        store = _FakePositionStore(position=None)
        with tempfile.TemporaryDirectory() as tmp:
            (Path(tmp) / 'logs').mkdir()
            step, source, fields = resolve_dispatch_position(
                store, 'CRE-2', project_dir=tmp,
                script=DETECT_RESUME_SCRIPT)
        self.assertEqual(step, 'STEP_1')
        self.assertEqual(source, 'adopted')
        self.assertEqual(fields.get('RESUME_STEP'), 'STEP_1')
        self.assertEqual(store.recorded, [('CRE-2', 'STEP_1', 'adopted')])

    def test_a_gate_hold_resume_step_is_not_a_dispatch_table_step_id(self):
        # Confirms the vocabulary a caller must branch on before treating an
        # adopted position as spawnable — gate_hold.py (D14) owns these.
        self.assertEqual(GATE_HOLD_RESUME_STEPS,
                         frozenset({'GATE_HELD', 'GATE_STILL_HELD'}))


if __name__ == '__main__':
    unittest.main()


class TestVerifyCheckpointResume(unittest.TestCase):
    """task 4.7's fourth channel — mid-run VERIFY crash resume."""

    def test_resumes_at_the_last_checkpoint_step_name(self):
        lines = [
            '2026-01-01T00:00:01Z|VERIFY|build-plan|done|ok',
            '2026-01-01T00:00:02Z|VERIFY|checkpoint|done|criterion-1-pass',
            '2026-01-01T00:00:03Z|VERIFY|checkpoint|done|criterion-2-pass',
        ]
        # Matches detect-resume.sh's own (slightly surprising) behaviour: the
        # literal step name of the last `|done|` entry, unmodified — verified
        # against the real script in TestVerifyCheckpointParity below.
        self.assertEqual(last_verify_checkpoint(lines), 'checkpoint')

    def test_browser_state_cannot_be_resumed_so_falls_back_to_build_plan(self):
        for substep in ('browser-session', 'navigate', 'execute-steps'):
            lines = [f'2026-01-01T00:00:01Z|VERIFY|{substep}|done|ok']
            self.assertEqual(last_verify_checkpoint(lines), 'build-plan',
                             f'substep={substep}')

    def test_no_completed_substep_returns_empty(self):
        self.assertEqual(last_verify_checkpoint([]), '')
        self.assertEqual(
            last_verify_checkpoint(['2026-01-01T00:00:01Z|VERIFY|verify|waiting|']),
            '')

    def test_the_verify_terminal_and_inspector_lines_are_excluded(self):
        lines = [
            '2026-01-01T00:00:01Z|VERIFY|checkpoint|done|criterion-1-pass',
            '2026-01-01T00:00:02Z|VERIFY|phase-inspector-verify|done|ok',
            '2026-01-01T00:00:03Z|VERIFY|verify|done|PASS',
        ]
        self.assertEqual(last_verify_checkpoint(lines), 'checkpoint')

    def test_a_different_phases_done_line_is_ignored(self):
        lines = ['2026-01-01T00:00:01Z|IMPLEMENT|implement|done|ok']
        self.assertEqual(last_verify_checkpoint(lines), '')


class TestVerifyCheckpointParity(unittest.TestCase):
    """The Python reconstruction must match the real script's VERIFY_FROM —
    not a hand-picked "sensible" answer, the one production actually uses,
    since a divergence here would resume a retried worker from the wrong
    sub-step silently.
    """

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.project_dir = Path(self._tmp.name)
        (self.project_dir / 'logs').mkdir()

    def tearDown(self):
        self._tmp.cleanup()

    def _real_verify_from(self, tid, log_lines):
        log = self.project_dir / 'logs' / f'{tid}-pipeline.log'
        log.write_text(
            '2026-01-01T00:00:00Z|META|schema|info|2\n'
            + '\n'.join(log_lines) + ('\n' if log_lines else '')
        )
        env = dict(os.environ)
        env['CLAUDE_SKILLS_LIB'] = str(TICKET_AUTO_LIB)
        proc = subprocess.run(
            ['bash', str(DETECT_RESUME_SCRIPT), tid],
            capture_output=True, text=True, timeout=60,
            cwd=str(self.project_dir), env=env,
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)
        fields = parse_detect_resume_block(proc.stdout)
        return fields.get('VERIFY_FROM', '')

    def test_parity_across_fixtures(self):
        fixtures = [
            ('CRE-P1', [
                '2026-01-01T00:00:01Z|VERIFY|build-plan|done|ok',
                '2026-01-01T00:00:02Z|VERIFY|checkpoint|done|criterion-1-pass',
                '2026-01-01T00:00:03Z|VERIFY|checkpoint|done|criterion-2-pass',
            ]),
            ('CRE-P2', [
                '2026-01-01T00:00:01Z|VERIFY|build-plan|done|ok',
                '2026-01-01T00:00:02Z|VERIFY|checkpoint|done|criterion-1-pass',
                '2026-01-01T00:00:03Z|VERIFY|navigate|done|ok',
            ]),
            ('CRE-P3', []),
            ('CRE-P4', [
                '2026-01-01T00:00:01Z|VERIFY|browser-session|done|ok',
            ]),
        ]
        for tid, lines in fixtures:
            with self.subTest(tid=tid):
                real = self._real_verify_from(tid, lines)
                mine = last_verify_checkpoint(lines)
                self.assertEqual(mine, real, f'{tid}: {lines}')


class TestDriftPreventionCoverage(unittest.TestCase):
    """Group 5 — the table is canonical (design.md D3); a Python map that
    silently falls out of step with it is exactly the failure the canonical
    file exists to prevent.

    Coverage here is narrower than "every step_id has code": `DispatchTable`
    loads the JSON directly rather than transcribing it (task 4.2), and
    `evaluate_loop` reads `max_iterations`/`gate_stop_code` straight off the
    table rather than a Python copy (task 4.6, asserted from the other
    direction by `TestLoopCaps.test_caps_are_not_duplicated_as_python_constants`)
    — for those, nothing can drift because there is only one copy.

    A loop-bearing step and a verdict-bearing phase are *not* the same thing
    — this was the first thing the coverage test actually caught while being
    written: STEP_3_5 (GATE-reconcile) declares a `loop` in the table, but
    `LOOP_BEARING_PHASES` deliberately excludes GATE (design.md D12 — it is
    classified on deterministic evidence, the same checks `gate-check.sh`
    performs, not on a PASS/FAIL/OK/WARN vocabulary it never emits), so
    `table.loop_steps()` is not a usable reference set for verdict coverage.
    The real, table-independent risk is `LOOP_BEARING_PHASES` and
    `_FAILING_VERDICTS` (task 4.9's rung-2 pair) drifting from *each other* —
    both gate the same "does this phase have a verdict, and what counts as a
    failure" decision in `classify_phase`, and a phase added to one without
    the other degrades silently rather than raising: added to
    `LOOP_BEARING_PHASES` alone, `_FAILING_VERDICTS.get(phase, frozenset())`
    returns an empty failing set and every claimed verdict reads as `done`.

    Task 5.2's other half — that `max_iterations`/`gate_stop_code` values
    actually used at cap match the table's — is already asserted for all
    four loop-bearing steps by `TestLoopCaps.test_at_the_cap_gate_stops` and
    `.test_exhaustion_uses_the_table_s_named_code`; cited per task 5.4 rather
    than re-asserted here.

    Task 5.3's regression guard was verified by hand, not committed as a
    meta-test (no other test in this suite tests a test): temporarily
    dropping 'VERIFY' from `LOOP_BEARING_PHASES` failed
    `test_loop_bearing_phases_and_failing_verdicts_name_the_same_phases`
    with exactly the asymmetry it describes, confirming the guard watches
    the thing it claims to; restored immediately after.

    Task 5.4's scope acknowledgement: this guards ~19 lines of dispatch
    sequencing, not the ~650 lines of per-step orchestration logic at
    `SKILL.md:664-1310` that actually encode pipeline behaviour. Tasks
    4.10-4.12 (preamble, between-phase orchestration, spawn bracket) are what
    keep *that* from drifting — via table generation and the `orchestration.py`
    executor holding no step list of its own (D20) — not this test.
    """

    def setUp(self):
        self.table = DispatchTable.load(TABLE_PATH)

    def test_every_real_step_id_resolves_without_raising(self):
        # The entry point every other assertion here builds on: a step_id
        # the table declares must be dispatchable, not just enumerable.
        for step_id in self.table.step_ids():
            with self.subTest(step_id=step_id):
                self.table.get(step_id)  # raises DispatchTableError on drift

    def test_every_step_with_a_spawn_block_builds_a_phase_spawn(self):
        # A step declaring `spawn.skill` must actually build — a gap here is
        # a step the table thinks dispatches an agent and the module cannot
        # turn into one.
        for step_id in self.table.step_ids():
            step = self.table.get(step_id)
            if not (step.get('spawn') or {}).get('skill'):
                continue
            with self.subTest(step_id=step_id):
                spawn = build_phase_spawn(
                    self.table, step_id, 'CRE-COVERAGE',
                    '/w/logs/CRE-COVERAGE-pipeline.log')
                self.assertTrue(spawn.skill)
                self.assertTrue(spawn.prompt)

    def test_loop_bearing_phases_and_failing_verdicts_name_the_same_phases(self):
        # The pair task 4.9's rung 2 actually reads together — see the class
        # docstring for why `table.loop_steps()` is not the reference set.
        self.assertEqual(LOOP_BEARING_PHASES,
                         frozenset(phase_dispatch._FAILING_VERDICTS))

    def test_gate_reconcile_is_loop_bearing_but_not_verdict_bearing(self):
        # Documents the exact asymmetry the class docstring explains, so a
        # future reader does not "fix" LOOP_BEARING_PHASES by adding GATE.
        self.assertIn('STEP_3_5', self.table.loop_steps())
        self.assertEqual(self.table.phase_of('STEP_3_5'), 'GATE')
        self.assertNotIn('GATE', LOOP_BEARING_PHASES)


class TestPhaseContract(unittest.TestCase):
    """agent-observer Inc 3 (design.md D4/D7): build_phase_contract.

    Uses an injected `ticket_auto_root`/env file rather than ambient machine
    state — a real, observed staleness (the installed plugin cache missing a
    newly-added agent .md) surfaced during this change's own development and
    must not make these tests flaky depending on what happens to be
    installed on the machine running them.
    """

    def setUp(self):
        self.table = DispatchTable.load(TABLE_PATH)
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name)
        (self.root / 'agents').mkdir(parents=True)
        self.repos_root = self.root / 'repos'
        self.repos_root.mkdir()
        self.env_file = self.root / 'env.sh'

    def tearDown(self):
        self._tmp.cleanup()

    def _write_agent_md(self, name, tools):
        (self.root / 'agents' / f'{name}.md').write_text(
            f'---\nname: {name}\ntools: {tools}\n---\nbody\n')

    def _write_env(self, **kv):
        lines = [f'export {k}="{v}"' for k, v in kv.items()]
        self.env_file.write_text('\n'.join(lines) + '\n')

    def _ticket_dir(self, tid, slug='fix-thing'):
        d = self.repos_root / f'{tid}--{slug}'
        d.mkdir(parents=True, exist_ok=True)
        return d

    def _contract(self, step_id, tid='CRE-9', env_file=None):
        return phase_dispatch.build_phase_contract(
            self.table, step_id, tid,
            env_file=str(env_file) if env_file else None,
            ticket_auto_root=self.root)

    def test_objective_and_expected_behaviour_come_from_the_table(self):
        c = self._contract('STEP_1')
        self.assertEqual(c['objective'],
                         'Investigate the ticket and produce complexity score')
        self.assertEqual(c['expected_behaviour'], 'Follow the skill exactly.')

    def test_allowed_tools_read_from_agent_frontmatter(self):
        self._write_agent_md('ticket-appraise-agent', 'Bash, Read, Grep')
        c = self._contract('STEP_1')
        self.assertEqual(c['allowed_tools'], ['Bash', 'Read', 'Grep'])

    def test_allowed_tools_is_none_when_agent_md_is_missing(self):
        c = self._contract('STEP_1')  # no agent .md written
        self.assertIsNone(c['allowed_tools'])

    def test_success_and_failure_criteria_for_a_loop_bearing_phase(self):
        # Per _VERDICT_TOKENS minus _FAILING_VERDICTS['VERIFY'] — the
        # universal phase-result-schema.md VERDICT enum is not phase-
        # restricted (classify_phase itself checks `verdict in failing`
        # against the full enum, not a phase-specific subset), so this
        # matches classify_phase's actual behavior rather than VERIFY's
        # own "normally only PASS/FAIL" convention.
        c = self._contract('STEP_4_5')  # VERIFY
        self.assertEqual(c['success_criteria']['claimed_verdict_in'],
                         ['BLOCK', 'PASS', 'WARN'])
        self.assertEqual(c['failure_conditions']['claimed_verdict_in'], ['FAIL'])
        self.assertEqual(c['failure_conditions']['gate_stop_code'], 'VERIFY_EXHAUSTED')

    def test_non_loop_bearing_phase_has_no_verdict_vocabulary(self):
        c = self._contract('STEP_1')  # APPRAISE
        self.assertEqual(c['success_criteria'], {})
        self.assertEqual(c['failure_conditions']['claimed_verdict_in'], [])
        self.assertIsNone(c['failure_conditions']['gate_stop_code'])

    def test_allowed_paths_resolves_ticket_dir_for_appraise(self):
        self._ticket_dir('CRE-9')
        self._write_env(REPOS_ROOT=str(self.repos_root))
        c = self._contract('STEP_1', env_file=self.env_file)
        self.assertEqual(c['allowed_paths'], [str(self.repos_root / 'CRE-9--fix-thing')])
        self.assertIsNone(c['allowed_paths_disabled_reason'])

    def test_allowed_paths_disabled_when_ticket_dir_does_not_exist(self):
        self._write_env(REPOS_ROOT=str(self.repos_root))
        c = self._contract('STEP_1', env_file=self.env_file)
        self.assertIsNone(c['allowed_paths'])
        self.assertIn('unresolved', c['allowed_paths_disabled_reason'])

    def test_allowed_paths_disabled_when_repos_root_unavailable(self):
        c = self._contract('STEP_1')  # no env file at all
        self.assertIsNone(c['allowed_paths'])
        self.assertIn('REPOS_ROOT', c['allowed_paths_disabled_reason'])

    def test_allowed_paths_disabled_when_ticket_dir_is_ambiguous(self):
        self._ticket_dir('CRE-9', slug='fix-thing')
        self._ticket_dir('CRE-9', slug='alt-slug')
        self._write_env(REPOS_ROOT=str(self.repos_root))
        c = self._contract('STEP_1', env_file=self.env_file)
        self.assertIsNone(c['allowed_paths'])

    def test_implement_resolves_ticket_dir_and_worktree_when_both_exist(self):
        self._ticket_dir('CRE-9')
        self._write_env(REPOS_ROOT=str(self.repos_root))
        wt = self.repos_root / '.ticket-auto' / 'worktrees' / 'CRE-9' / 'my-repo'
        wt.mkdir(parents=True)
        c = self._contract('STEP_4', env_file=self.env_file)
        self.assertEqual(set(c['allowed_paths']),
                         {str(self.repos_root / 'CRE-9--fix-thing'), str(wt)})

    def test_implement_disabled_when_no_worktree_exists_yet(self):
        # The common case for a first IMPLEMENT attempt (design.md task 3.3
        # note) — ensure_worktree creates the directory *during* the phase
        # this contract is built before, not before it.
        self._ticket_dir('CRE-9')
        self._write_env(REPOS_ROOT=str(self.repos_root))
        c = self._contract('STEP_4', env_file=self.env_file)
        self.assertIsNone(c['allowed_paths'])
        self.assertIn('WORKTREE', c['allowed_paths_disabled_reason'])

    def test_claim_predicates_include_project_test_commands_from_env(self):
        self._write_env(REPOS_ROOT=str(self.repos_root), BE_TEST_CMD='./gradlew test')
        c = self._contract('STEP_4_5', env_file=self.env_file)  # VERIFY
        self.assertIn('./gradlew test', c['claim_predicates']['command_substrings'])
        self.assertIn('pytest', c['claim_predicates']['command_substrings'])

    def test_verify_claim_predicates_include_playwright_tool_prefix(self):
        c = self._contract('STEP_4_5')  # VERIFY
        self.assertEqual(c['claim_predicates']['tool_name_prefixes'],
                         ['mcp__plugin_playwright_'])

    def test_non_verify_phase_has_no_playwright_predicate(self):
        c = self._contract('STEP_1')
        self.assertNotIn('tool_name_prefixes', c['claim_predicates'])

    def test_write_phase_contract_writes_the_expected_file(self):
        with tempfile.TemporaryDirectory() as state_dir:
            contract = phase_dispatch.write_phase_contract(
                state_dir, self.table, 'STEP_1', 'CRE-9',
                ticket_auto_root=self.root)
            expected = Path(state_dir) / 'CRE-9-appraise-contract.json'
            self.assertTrue(expected.is_file())
            on_disk = json.loads(expected.read_text())
            self.assertEqual(on_disk, contract)

    def test_write_phase_contract_never_raises_on_unwritable_dir(self):
        # Fail-soft: a write failure costs the observer's contract-dependent
        # rules for this generation, not the spawn itself.
        contract = phase_dispatch.write_phase_contract(
            '/nonexistent/deeply/nested/dir', self.table, 'STEP_1', 'CRE-9',
            ticket_auto_root=self.root)
        self.assertEqual(contract['phase'], 'APPRAISE')

    def test_parse_env_file_reads_export_lines(self):
        self._write_env(REPOS_ROOT='/x/y', BE_TEST_CMD='pytest -x')
        env = phase_dispatch._parse_env_file(str(self.env_file))
        self.assertEqual(env['REPOS_ROOT'], '/x/y')
        self.assertEqual(env['BE_TEST_CMD'], 'pytest -x')

    def test_parse_env_file_missing_file_returns_empty_dict(self):
        self.assertEqual(phase_dispatch._parse_env_file('/nonexistent'), {})

    def test_parse_env_file_none_returns_empty_dict(self):
        self.assertEqual(phase_dispatch._parse_env_file(None), {})


if __name__ == '__main__':
    unittest.main()
