"""
Tests for fleetd's non-agent orchestration executor (fleetd/orchestration.py).

Run:
    python3 -m pytest fleet-controller/fleetd/tests/test_orchestration.py -v

The module's whole claim is that no between-phase step is left implicit, so
the first test is the one that would catch a regression of that claim: every
`kind` the shipped table declares is either executed here or named as
deliberately-not-ours. A new kind added to the table with no runner would
otherwise reach production as a silent no-op — the table saying a step runs
and the supervisor quietly not running it.

The auto-merge tests carry the two orderings that were wrong before: the PR
number must be resolved *before* the integration guard reads it (in SKILL.md
it was assigned after, so the guard inspected an unset variable and guarded
nothing), and the outcome must come from `META|outcome-label|info|` and not
from the IMPLEMENT terminal, which does not carry Smooth/Rough/Hard at all.
"""

import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent))

from fleetd import orchestration  # noqa: E402
from fleetd.phase_dispatch import DispatchTable  # noqa: E402

REPO_ROOT = Path(__file__).resolve().parent.parent.parent.parent
TABLE_PATH = (
    REPO_ROOT / 'ticket-auto-pipeline' / 'skills' / 'ticket-flow'
    / 'dispatch-table.json'
)
TICKET_AUTO_LIB = REPO_ROOT / 'ticket-auto-pipeline' / 'lib'


class TestTableCoverage(unittest.TestCase):
    """No declared orchestration step may be implicit."""

    def setUp(self):
        self.table = DispatchTable.load(TABLE_PATH)

    def _declared_kinds(self):
        kinds = set()
        for step_id in self.table.step_ids():
            for when in ('pre_dispatch', 'post_dispatch'):
                for item in orchestration.orchestration_items(
                        self.table, step_id, when):
                    kinds.add(item.get('kind'))
        return kinds

    def test_every_declared_kind_has_a_runner(self):
        unknown = self._declared_kinds() - orchestration.KNOWN_KINDS
        self.assertEqual(unknown, set(),
                         f'dispatch-table.json declares kinds with no runner: '
                         f'{sorted(unknown)}')

    def test_the_two_unimplemented_kinds_are_the_expected_two(self):
        # Named rather than counted, so adding a third silently is a failure.
        # `inspector` is a spawn and belongs to the dispatch loop; `preflight`
        # asks about the agent session's MCP reachability, which fleetd cannot
        # answer for a process it has not started.
        gap = orchestration.KNOWN_KINDS - orchestration.IMPLEMENTED_KINDS
        self.assertEqual(gap, {'inspector', 'preflight'})

    def test_the_implement_step_still_declares_its_four_effects(self):
        # Order is significant and asserted: outcome-label-check.sh writes the
        # label the auto-merge check later reads, and must precede the flow
        # trigger that moves the ticket out of Ready.
        items = orchestration.orchestration_items(
            self.table, 'STEP_4', 'post_dispatch')
        names = [i.get('script') or i.get('trigger') or i['kind']
                 for i in items]
        self.assertEqual(names[:4], [
            'return-completeness-check.sh',
            'outcome-label-check.sh',
            'implement-complete',
            'planned-feedback-write.sh',
        ])

    def test_an_unknown_step_yields_no_items_rather_than_raising(self):
        self.assertEqual(
            orchestration.orchestration_items(self.table, 'STEP_NOPE',
                                              'post_dispatch'), [])


class TestBlockingPolicy(unittest.TestCase):
    """Escalation is read from the table, never decided in Python."""

    def test_explicit_non_blocking_fields_are_honoured(self):
        for item in ({'kind': 'bash', 'blocking': False},
                     {'kind': 'bash', 'enforcement': 'warn-only'},
                     {'kind': 'bash', 'on_failure': 'log_and_continue'}):
            with self.subTest(item=item):
                self.assertFalse(orchestration._is_blocking(item))

    def test_gate_stop_is_blocking(self):
        self.assertTrue(orchestration._is_blocking(
            {'kind': 'flow_trigger', 'on_failure': 'gate_stop'}))

    def test_an_unstated_bash_gate_defaults_to_blocking(self):
        # A bash check between phases exists to gate something; the advisory
        # ones say so explicitly, so silence has to mean blocking.
        self.assertTrue(orchestration._is_blocking({'kind': 'bash'}))
        self.assertFalse(orchestration._is_blocking({'kind': 'inspector'}))


class TestSequencing(unittest.TestCase):
    """Order, and the stop-at-the-first-blocking-failure rule."""

    def setUp(self):
        self.table = DispatchTable.load(TABLE_PATH)
        self.ran = []

    def _runner(self, status, blocking):
        def run(item, ctx, lib_dir=None):
            self.ran.append(item.get('script') or item.get('trigger')
                            or item['kind'])
            return orchestration.StepResult(item['kind'], status, '', blocking,
                                            None)
        return run

    def test_items_run_in_table_order(self):
        runners = {k: self._runner(orchestration.OK, False)
                   for k in orchestration.KNOWN_KINDS}
        orchestration.run_step_orchestration(
            self.table, 'STEP_4', 'post_dispatch', {'tid': 'CRE-1'},
            runners=runners)
        self.assertEqual(self.ran[:3], ['return-completeness-check.sh',
                                        'outcome-label-check.sh',
                                        'implement-complete'])

    def test_a_blocking_failure_stops_the_sequence(self):
        runners = {k: self._runner(orchestration.FAILED, True)
                   for k in orchestration.KNOWN_KINDS}
        results = orchestration.run_step_orchestration(
            self.table, 'STEP_4', 'post_dispatch', {'tid': 'CRE-1'},
            runners=runners)
        self.assertEqual(len(self.ran), 1)
        self.assertEqual(len(results), 1)

    def test_an_advisory_failure_does_not_stop_the_sequence(self):
        # An observation that halted a ticket would make the pipeline less
        # reliable for having been instrumented.
        runners = {k: self._runner(orchestration.FAILED, False)
                   for k in orchestration.KNOWN_KINDS}
        orchestration.run_step_orchestration(
            self.table, 'STEP_4', 'post_dispatch', {'tid': 'CRE-1'},
            runners=runners)
        self.assertEqual(len(self.ran), 5)

    def test_a_kind_with_no_runner_is_loud(self):
        results = orchestration.run_step_orchestration(
            self.table, 'STEP_4', 'post_dispatch', {'tid': 'CRE-1'},
            runners={})
        self.assertTrue(all(r.status == orchestration.UNSUPPORTED
                            for r in results))


class TestAutoMerge(unittest.TestCase):

    OUTCOME = '2026-09-03T10:00:00Z|META|outcome-label|info|Smooth'
    PR = '2026-09-03T10:05:00Z|PR-REVIEW|checkout-pr|done|412'

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.log = Path(self._tmp.name) / 'CRE-2-pipeline.log'
        self.log.write_text(self.OUTCOME + '\n' + self.PR + '\n')
        self.calls = []
        self._real_gh = orchestration._gh
        orchestration._gh = self._fake_gh
        self.gh_returns = {}

    def tearDown(self):
        orchestration._gh = self._real_gh
        self._tmp.cleanup()

    def _fake_gh(self, args, timeout):
        self.calls.append(args)
        for key, value in self.gh_returns.items():
            if key in args:
                return value
        return ''

    def _ctx(self, **over):
        ctx = {'tid': 'CRE-2', 'LOG_FILE': str(self.log), 'autonomy': 'auto',
               'complexity': 'simple', 'integration_branch': ''}
        ctx.update(over)
        return ctx

    def test_merges_when_every_condition_holds(self):
        result = orchestration.run_auto_merge({'kind': 'auto_merge'},
                                              self._ctx())
        self.assertEqual(result.status, orchestration.OK)
        self.assertIn(['pr', 'merge', '412', '--squash', '--auto'], self.calls)

    def test_wired_through_step_4_6s_own_post_dispatch(self):
        # task 10.1.7 — confirms the table-driven path (the real STEP_4_6
        # entry, not a hand-called run_auto_merge) reaches the merge, given a
        # ctx populated the way the eventual dispatch wiring will populate
        # it (autonomy/integration_branch from PreambleResult.fields,
        # complexity from resolve_ticket_complexity).
        table = DispatchTable.load(TABLE_PATH)
        results = orchestration.run_step_orchestration(
            table, 'STEP_4_6', 'post_dispatch', self._ctx())
        self.assertIn(['pr', 'merge', '412', '--squash', '--auto'], self.calls)
        self.assertTrue(any(r.kind == 'auto_merge' and r.status == orchestration.OK
                            for r in results))

    def test_manual_mode_never_merges(self):
        result = orchestration.run_auto_merge({'kind': 'auto_merge'},
                                              self._ctx(autonomy='manual'))
        self.assertEqual(result.status, orchestration.SKIPPED)
        self.assertEqual(self.calls, [])

    def test_a_complex_ticket_never_merges(self):
        result = orchestration.run_auto_merge({'kind': 'auto_merge'},
                                              self._ctx(complexity='complex'))
        self.assertEqual(result.status, orchestration.SKIPPED)

    def test_the_outcome_comes_from_the_label_line_not_the_terminal(self):
        # The IMPLEMENT terminal does not carry Smooth/Rough/Hard, so a
        # pipeline whose label line says Rough must not merge however its
        # implement phase ended.
        self.log.write_text(
            '2026-09-03T10:00:00Z|META|outcome-label|info|Rough\n'
            '2026-09-03T10:01:00Z|IMPLEMENT|implement|done|Smooth\n'
            + self.PR + '\n')
        result = orchestration.run_auto_merge({'kind': 'auto_merge'},
                                              self._ctx())
        self.assertEqual(result.status, orchestration.SKIPPED)
        self.assertIn('Rough', result.detail)

    def test_an_integration_pr_is_guarded(self):
        # The guard that was dead in SKILL.md: it read the PR number above the
        # line that assigned it, so it inspected an unset variable.
        self.gh_returns = {'headRefName': 'epic/thing'}
        result = orchestration.run_auto_merge(
            {'kind': 'auto_merge'}, self._ctx(integration_branch='epic/thing'))
        self.assertEqual(result.status, orchestration.SKIPPED)
        self.assertNotIn(['pr', 'merge', '412', '--squash', '--auto'],
                         self.calls)
        self.assertIn('INTEGRATION_PR_GUARD', self.log.read_text())

    def test_a_ticket_pr_targeting_the_epic_branch_still_merges(self):
        # The ordinary case under a shared epic branch: base is the epic
        # branch, head is the ticket branch. Guarding on the base would stop
        # every child ticket merging.
        self.gh_returns = {'headRefName': 'feat/cre-2'}
        result = orchestration.run_auto_merge(
            {'kind': 'auto_merge'}, self._ctx(integration_branch='epic/thing'))
        self.assertEqual(result.status, orchestration.OK)

    def test_an_unreadable_head_ref_refuses_to_merge(self):
        # Cannot establish it is not an integration PR. An auto-merged
        # integration PR is not undoable by the pipeline, so absence of
        # evidence has to mean no merge here.
        self.gh_returns = {'headRefName': None}
        result = orchestration.run_auto_merge(
            {'kind': 'auto_merge'}, self._ctx(integration_branch='epic/thing'))
        self.assertEqual(result.status, orchestration.SKIPPED)
        self.assertNotIn(['pr', 'merge', '412', '--squash', '--auto'],
                         self.calls)

    def test_no_pr_number_is_a_skip_not_a_failure(self):
        self.log.write_text(self.OUTCOME + '\n')
        result = orchestration.run_auto_merge({'kind': 'auto_merge'},
                                              self._ctx())
        self.assertEqual(result.status, orchestration.SKIPPED)

    def test_a_failed_merge_never_blocks(self):
        self.gh_returns = {'merge': None}
        result = orchestration.run_auto_merge({'kind': 'auto_merge'},
                                              self._ctx())
        self.assertEqual(result.status, orchestration.FAILED)
        self.assertFalse(result.blocking)


class TestLastLogMsg(unittest.TestCase):

    def test_a_message_containing_a_pipe_is_not_truncated(self):
        # The pipeline log's oldest sharp edge: `cut -f5` drops everything
        # after a pipe in the message.
        with tempfile.TemporaryDirectory() as tmp:
            log = Path(tmp) / 'x.log'
            log.write_text('2026-09-03T10:00:00Z|META|m|info|a|b|c\n')
            self.assertEqual(
                orchestration._last_log_msg(log, '|META|m|info|'), 'a|b|c')

    def test_a_missing_file_is_empty_not_an_error(self):
        self.assertEqual(orchestration._last_log_msg('/nope/x.log', 'y'), '')


class TestEnvItem(unittest.TestCase):

    def test_placeholders_resolve_into_the_spawn_context(self):
        ctx = {'tid': 'CRE-3'}
        result = orchestration.run_env(
            {'kind': 'env', 'export': 'CLAUDE_LOG_FILE',
             'value': '/tmp/ticket-auto-{TICKET-ID}-verify-$(date +%s).log'},
            ctx)
        self.assertEqual(result.status, orchestration.OK)
        value = ctx['env']['CLAUDE_LOG_FILE']
        self.assertIn('CRE-3', value)
        self.assertNotIn('$(date', value)

    def test_the_value_lands_in_ctx_not_in_fleetds_own_environment(self):
        # fleetd supervises many tickets at once; a per-ticket value in the
        # daemon's env would leak across them.
        import os
        ctx = {'tid': 'CRE-4'}
        orchestration.run_env({'kind': 'env', 'export': 'CLAUDE_LOG_FILE',
                               'value': '/tmp/x.log'}, ctx)
        self.assertEqual(ctx['env']['CLAUDE_LOG_FILE'], '/tmp/x.log')
        self.assertNotEqual(os.environ.get('CLAUDE_LOG_FILE'), '/tmp/x.log')

    def test_an_unnamed_variable_is_a_failure(self):
        self.assertEqual(
            orchestration.run_env({'kind': 'env', 'value': 'x'},
                                  {'tid': 'X'}).status,
            orchestration.FAILED)


class TestBashAndFlowItems(unittest.TestCase):

    def test_a_missing_script_is_reported_with_its_path(self):
        with tempfile.TemporaryDirectory() as empty:
            result = orchestration.run_bash_item(
                {'kind': 'bash', 'script': 'nope.sh'}, {'tid': 'CRE-5'},
                lib_dir=empty)
        self.assertEqual(result.status, orchestration.FAILED)
        self.assertIn('nope.sh', result.detail)

    def test_a_real_script_runs_against_the_real_lib(self):
        # return-completeness-check.sh over a ticket with no workspace exits
        # non-zero; what is under test is that it was reached and its code
        # captured, not the check's own verdict.
        result = orchestration.run_bash_item(
            {'kind': 'bash', 'script': 'return-completeness-check.sh',
             'enforcement': 'warn-only'},
            {'tid': 'CRE-NONEXISTENT'}, lib_dir=TICKET_AUTO_LIB)
        self.assertIsNotNone(result.exit_code)
        self.assertFalse(result.blocking)

    def test_a_flow_trigger_with_no_name_fails(self):
        result = orchestration.run_flow_trigger({'kind': 'flow_trigger'},
                                                {'tid': 'CRE-5'})
        self.assertEqual(result.status, orchestration.FAILED)

    def test_state_assertion_failure_is_blocking_whatever_the_table_says(self):
        # flow.sh exit 7 means Linear is not in the state the pipeline
        # believes; continuing compounds the divergence, so the item's own
        # non-blocking declaration does not apply.
        import subprocess as sp
        real = sp.run
        seen = {}

        def fake(args, **kw):
            seen['args'] = args
            return sp.CompletedProcess(args, 7, '', '')

        with tempfile.TemporaryDirectory() as tmp:
            flow_dir = Path(tmp) / 'skills' / 'ticket-flow'
            flow_dir.mkdir(parents=True)
            (flow_dir / 'flow.sh').write_text('#!/usr/bin/env bash\nexit 7\n')
            lib = Path(tmp) / 'lib'
            lib.mkdir()
            sp.run = fake
            try:
                result = orchestration.run_flow_trigger(
                    {'kind': 'flow_trigger', 'trigger': 'implement-complete',
                     'on_failure': 'log_and_continue'},
                    {'tid': 'CRE-5'}, lib_dir=lib)
            finally:
                sp.run = real
        self.assertTrue(result.blocking)
        self.assertIn('STATE_ASSERTION_FAILED', result.detail)


class TestFinalizeTerminal(unittest.TestCase):
    """`orchestration.finalize_terminal` — task 10.1.5, design.md D22.

    Fake `worktree`/`finalize` runners stand in for the real bash scripts:
    what is under test is the branching and ordering (gate-stop line first,
    worktree release ONLY on a clean exit, finalize called either way), not
    `pipeline-finalize.sh`'s or `worktree.sh`'s own behaviour — those have no
    dedicated coverage yet and are out of this subtask's scope.
    """

    def setUp(self):
        self.table = DispatchTable.load(TABLE_PATH)
        self.calls = []
        self.runners = {
            'worktree': self._fake_runner('worktree'),
            'finalize': self._fake_runner('finalize'),
        }

    def _fake_runner(self, kind):
        def _runner(item, ctx, lib_dir=None):
            self.calls.append((kind, dict(ctx)))
            return orchestration.StepResult(kind, orchestration.OK, kind,
                                            False, 0)
        return _runner

    def test_a_clean_exit_releases_the_worktree_before_finalizing(self):
        with tempfile.TemporaryDirectory() as tmp:
            log_file = str(Path(tmp) / 'CRE-1-pipeline.log')
            Path(log_file).write_text('')
            results = orchestration.finalize_terminal(
                self.table, 'CRE-1', 0, '', log_file, runners=self.runners)
            log_contents = Path(log_file).read_text()
        self.assertEqual([c[0] for c in self.calls], ['worktree', 'finalize'])
        self.assertEqual(len(results), 2)
        self.assertEqual(log_contents, '')

    def test_a_gate_stop_terminal_writes_the_line_and_skips_the_worktree(self):
        with tempfile.TemporaryDirectory() as tmp:
            log_file = str(Path(tmp) / 'CRE-2-pipeline.log')
            Path(log_file).write_text('')
            orchestration.finalize_terminal(
                self.table, 'CRE-2', 1, 'VERIFY_EXHAUSTED', log_file,
                runners=self.runners)
            log_contents = Path(log_file).read_text()
        self.assertEqual([c[0] for c in self.calls], ['finalize'])
        self.assertIn('|META|gate-stop|fail|VERIFY_EXHAUSTED', log_contents)

    def test_a_block_verdict_terminal_has_no_code_but_still_finalizes(self):
        # STEP_4_6's ❌ BLOCK verdict is a gate-stop with no named code
        # (SKILL.md never assigns one) — next_step returns gate_stop_code=''.
        with tempfile.TemporaryDirectory() as tmp:
            log_file = str(Path(tmp) / 'CRE-3-pipeline.log')
            Path(log_file).write_text('')
            orchestration.finalize_terminal(
                self.table, 'CRE-3', 1, '', log_file, runners=self.runners)
            log_contents = Path(log_file).read_text()
        self.assertEqual([c[0] for c in self.calls], ['finalize'])
        self.assertEqual(log_contents, '')

    def test_ctx_carries_tid_exit_code_and_log_file_to_every_runner(self):
        with tempfile.TemporaryDirectory() as tmp:
            log_file = str(Path(tmp) / 'CRE-4-pipeline.log')
            Path(log_file).write_text('')
            orchestration.finalize_terminal(
                self.table, 'CRE-4', 0, '', log_file, runners=self.runners)
        for _, ctx in self.calls:
            self.assertEqual(ctx['tid'], 'CRE-4')
            self.assertEqual(ctx['exit_code'], 0)
            self.assertEqual(ctx['LOG_FILE'], log_file)


if __name__ == '__main__':
    unittest.main()
