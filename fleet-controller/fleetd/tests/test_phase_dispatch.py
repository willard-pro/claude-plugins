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
    DEFAULT_PHASE_FLAGS,
    EXIT_ROUTE_CONTINUE,
    EXIT_ROUTE_GATE_STOP,
    EXIT_ROUTE_RETRY,
    FLOW_STATE_ASSERTION_EXIT,
)

REPO_ROOT = Path(__file__).resolve().parent.parent.parent.parent
TABLE_PATH = (
    REPO_ROOT / 'ticket-auto-pipeline' / 'skills' / 'ticket-flow'
    / 'dispatch-table.json'
)
TICKET_AUTO_LIB = REPO_ROOT / 'ticket-auto-pipeline' / 'lib'


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

