"""
Tests for fleetd's once-per-ticket preamble caller (fleetd/preamble.py).

Run:
    python3 -m pytest fleet-controller/fleetd/tests/test_preamble.py -v

The bash side has its own suite (`lib/tests/test-ticket-preamble.sh`) covering
what gets written. What is under test here is the routing this module puts on
top of the script's exit codes, and the two readings that would be wrong:

- Exit 0 is not evidence of success on its own. The same rule D12 applies to
  a phase agent applies to the preamble: a script that exits 0 having produced
  no result block leaves fleetd with no env file to spawn against.
- A failed preflight is not a per-ticket gate-stop. It is a fleet-wide fault,
  and stopping each ticket individually for it creates a queue of separately
  halted tickets that all need un-halting after one setting is fixed.

The end-to-end test runs the real script with preflight skipped and branch
resolution stubbed — enough to prove the parse matches what the script
actually emits, which a hand-written fixture would stop proving the moment
the block gains a field.
"""

import os
import shutil
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent))

from fleetd import preamble  # noqa: E402

REPO_ROOT = Path(__file__).resolve().parent.parent.parent.parent
LIB_DIR = REPO_ROOT / 'ticket-auto-pipeline' / 'lib'

BRANCH_STUB = '''#!/usr/bin/env bash
resolve_branch_context() {
  cat <<'BLOCK'
BRANCH_CONTEXT_RESULT:
  TICKET_BRANCH: feat/py-1
  BASE_BRANCH: develop
  INTEGRATION_BRANCH: epic/py
  BRANCH_SOURCE: epic-directive
  UAT_POLICY: epic
  MERGE_POLICY: auto
BLOCK
}
'''


class TestParseResultBlock(unittest.TestCase):

    def test_parses_the_block_and_stops_at_its_end(self):
        fields = preamble.parse_result_block(
            'noise before\n'
            'TICKET_PREAMBLE_RESULT:\n'
            '  TICKET_ID: CRE-9\n'
            '  ENV_FILE: /tmp/ticket-auto-CRE-9-env.sh\n'
            '  BASE_BRANCH: develop\n'
            'trailing noise\n'
            '  TICKET_ID: WRONG\n'
        )
        self.assertEqual(fields['TICKET_ID'], 'CRE-9')
        self.assertEqual(fields['BASE_BRANCH'], 'develop')

    def test_ignores_a_field_this_version_does_not_know(self):
        # The block is append-only by the same convention as
        # META|branch-context: a newer script must degrade to a missing field,
        # never to a crash.
        fields = preamble.parse_result_block(
            'TICKET_PREAMBLE_RESULT:\n'
            '  TICKET_ID: CRE-9\n'
            '  SOME_FUTURE_FIELD: yes\n'
        )
        self.assertEqual(fields, {'TICKET_ID': 'CRE-9'})

    def test_no_block_is_an_empty_dict_not_an_error(self):
        self.assertEqual(preamble.parse_result_block('boom\n'), {})
        self.assertEqual(preamble.parse_result_block(''), {})

    def test_a_value_containing_a_colon_survives(self):
        fields = preamble.parse_result_block(
            'TICKET_PREAMBLE_RESULT:\n'
            '  REPOS_ROOT: /a:b/repos\n'
        )
        self.assertEqual(fields['REPOS_ROOT'], '/a:b/repos')


class TestRouting(unittest.TestCase):
    """Which exit code means what, driven through a stub script."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix='fleetd-preamble-')
        self.lib = Path(self.tmp) / 'lib'
        self.lib.mkdir()

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def _script(self, body):
        path = self.lib / 'ticket-preamble.sh'
        path.write_text('#!/usr/bin/env bash\n' + body)
        return path

    def test_success_proceeds_and_carries_the_env_file(self):
        self._script(
            'cat <<EOF\n'
            'TICKET_PREAMBLE_RESULT:\n'
            '  TICKET_ID: CRE-1\n'
            '  ENV_FILE: /tmp/ticket-auto-CRE-1-env.sh\n'
            '  LOG_FILE: /w/logs/CRE-1-pipeline.log\n'
            'EOF\n'
        )
        result = preamble.run_preamble('CRE-1', lib_dir=self.lib)
        self.assertTrue(result.ok)
        self.assertEqual(result.action, preamble.ACTION_PROCEED)
        self.assertEqual(result.fields['ENV_FILE'],
                         '/tmp/ticket-auto-CRE-1-env.sh')
        self.assertEqual(result.gate_stop_code, '')

    def test_branch_directive_invalid_is_the_one_gate_stop(self):
        self._script('echo "bad directive" >&2; exit 2\n')
        result = preamble.run_preamble('CRE-2', lib_dir=self.lib)
        self.assertFalse(result.ok)
        self.assertEqual(result.action, preamble.ACTION_GATE_STOP)
        self.assertEqual(result.gate_stop_code, 'BRANCH_DIRECTIVE_INVALID')

    def test_transient_branch_failure_retries_rather_than_stopping(self):
        self._script('echo "502" >&2; exit 3\n')
        result = preamble.run_preamble('CRE-3', lib_dir=self.lib)
        self.assertEqual(result.action, preamble.ACTION_RETRY_LATER)
        self.assertEqual(result.gate_stop_code, '')
        self.assertIn('502', result.detail)

    def test_preflight_failures_are_fleet_wide_not_per_ticket_gate_stops(self):
        for code in (preamble.PREAMBLE_LINEAR_CONFIG_INVALID,
                     preamble.PREAMBLE_LINEAR_AUTH_FAILED):
            with self.subTest(code=code):
                self._script(f'exit {code}\n')
                result = preamble.run_preamble('CRE-4', lib_dir=self.lib)
                self.assertEqual(result.action, preamble.ACTION_RETRY_LATER)
                self.assertEqual(result.gate_stop_code, '')

    def test_a_usage_error_is_never_recorded_on_the_ticket(self):
        # Exit 1 is what bash hands out for a script called wrong. If it also
        # meant BRANCH_DIRECTIVE_INVALID, a caller's typo would write a
        # gate-stop verdict onto a real ticket.
        self._script('echo "unknown parameter" >&2; exit 1\n')
        result = preamble.run_preamble('CRE-4b', lib_dir=self.lib)
        self.assertEqual(result.action, preamble.ACTION_RETRY_LATER)
        self.assertEqual(result.gate_stop_code, '')

    def test_an_unwritable_env_file_stops_the_dispatch(self):
        self._script(f'exit {preamble.PREAMBLE_ENV_WRITE_FAILED}\n')
        result = preamble.run_preamble('CRE-4c', lib_dir=self.lib)
        self.assertFalse(result.ok)
        self.assertEqual(result.action, preamble.ACTION_RETRY_LATER)

    def test_exit_zero_without_a_block_is_not_success(self):
        self._script('echo "all fine"\n')
        result = preamble.run_preamble('CRE-5', lib_dir=self.lib)
        self.assertFalse(result.ok)
        self.assertEqual(result.action, preamble.ACTION_RETRY_LATER)
        self.assertIn('without a result block', result.detail)

    def test_an_undocumented_exit_code_retries_rather_than_proceeding(self):
        self._script('exit 42\n')
        result = preamble.run_preamble('CRE-6', lib_dir=self.lib)
        self.assertFalse(result.ok)
        self.assertEqual(result.action, preamble.ACTION_RETRY_LATER)

    def test_ticket_run_trigger_reaches_the_subprocess_env(self):
        # run-identity.sh reads TICKET_RUN_TRIGGER to tell a fleetd-driven run
        # from a manual one when FLEET_WORKER_PID isn't set (e.g. the
        # ticket-level dispatch path, which forks the router itself rather
        # than a bare phase worker).
        self._script('echo "unused"\n')
        with patch('subprocess.run') as mock_run:
            mock_run.return_value.returncode = 0
            mock_run.return_value.stdout = ''
            mock_run.return_value.stderr = ''
            preamble.run_preamble('CRE-9', lib_dir=self.lib)
        _, kwargs = mock_run.call_args
        self.assertEqual(kwargs['env']['TICKET_RUN_TRIGGER'], 'fleetd')
        # The rest of the caller's environment must still be present —
        # this passes the whole environment through, not a replacement.
        self.assertEqual(kwargs['env']['PATH'], os.environ['PATH'])

    def test_a_missing_script_raises_rather_than_failing_quietly(self):
        with self.assertRaises(preamble.PreambleError):
            preamble.run_preamble('CRE-7', lib_dir=Path(self.tmp) / 'nope')

    def test_flags_reach_the_script(self):
        self._script('printf "%s\\n" "$@" > "$ARGS_OUT"\n')
        os.environ['ARGS_OUT'] = str(Path(self.tmp) / 'args.txt')
        try:
            preamble.run_preamble('CRE-8', lib_dir=self.lib, autonomy='auto',
                                  from_planned=True, branch_flag='epic/x',
                                  skip_preflight=True, logs_dir='/w/logs')
        finally:
            os.environ.pop('ARGS_OUT', None)
        args = (Path(self.tmp) / 'args.txt').read_text().split('\n')
        self.assertIn('TICKET_ID=CRE-8', args)
        self.assertIn('AUTONOMY=auto', args)
        self.assertIn('FROM_PLANNED=true', args)
        self.assertIn('BRANCH_FLAG=epic/x', args)
        self.assertIn('SKIP_PREFLIGHT=true', args)
        self.assertIn('LOGS_DIR=/w/logs', args)


class TestAgainstTheRealScript(unittest.TestCase):
    """The parse must match what the shipped script actually prints."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix='fleetd-preamble-real-')
        self.lib = Path(self.tmp) / 'lib'
        self.lib.mkdir()
        for src in LIB_DIR.glob('*.sh'):
            shutil.copy(src, self.lib / src.name)
        (self.lib / 'branch-resolve.sh').write_text(BRANCH_STUB)
        (Path(self.tmp) / 'logs').mkdir()

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)
        for stale in Path('/tmp').glob('ticket-auto-PYPRE-*-env.sh'):
            stale.unlink(missing_ok=True)

    def test_round_trip_and_idempotent_re_entry(self):
        kwargs = dict(lib_dir=self.lib, project_dir=self.tmp,
                      logs_dir=str(Path(self.tmp) / 'logs'),
                      autonomy='auto', skip_preflight=True)
        first = preamble.run_preamble('PYPRE-1', **kwargs)
        self.assertTrue(first.ok, first.detail)
        self.assertEqual(first.fields['ENV_FILE'],
                         '/tmp/ticket-auto-PYPRE-1-env.sh')
        self.assertEqual(first.fields['BRANCH_ORIGIN'], 'resolved')
        self.assertEqual(first.fields['INTEGRATION_BRANCH'], 'epic/py')
        self.assertTrue(Path(first.fields['ENV_FILE']).is_file())

        second = preamble.run_preamble('PYPRE-1', **kwargs)
        self.assertEqual(second.fields['BRANCH_ORIGIN'], 'rehydrated')
        self.assertEqual(second.fields['BASE_BRANCH'],
                         first.fields['BASE_BRANCH'])
        log = Path(first.fields['LOG_FILE']).read_text()
        self.assertEqual(log.count('|META|branch-context|'), 1)

    def test_every_field_the_parser_knows_is_actually_emitted(self):
        # Guards the parse against the script renaming or dropping a field:
        # an unknown key is silently ignored by design, so without this a
        # rename would surface as a missing env file at spawn time.
        result = preamble.run_preamble(
            'PYPRE-2', lib_dir=self.lib, project_dir=self.tmp,
            logs_dir=str(Path(self.tmp) / 'logs'), skip_preflight=True)
        self.assertEqual(set(result.fields), set(preamble._RESULT_FIELDS))


if __name__ == '__main__':
    unittest.main()
