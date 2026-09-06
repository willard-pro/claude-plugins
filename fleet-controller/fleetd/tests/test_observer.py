"""
Tests for fleetd's Agent Observer sidecar (fleetd/observer.py).

Run:
    python3 -m pytest fleet-controller/fleetd/tests/test_observer.py -v

Fixtures are real `claude -p --output-format stream-json --verbose` captures
(see fixtures/README.md), not hand-written — the traps they pin (`init` not
always line 0, `result` not always the last line, exit code as unstable text)
are exactly the shapes a synthetic fixture would quietly stop covering.
"""

import json
import os
import sys
import tempfile
import time
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent))

from fleetd import observer  # noqa: E402

FIXTURES_DIR = Path(__file__).resolve().parent / 'fixtures'


class FilenameParsingTest(unittest.TestCase):
    """`{tid}-{phase}-gen{N}.ndjson` -> (tid, PHASE, generation)."""

    def test_simple_phase_slug(self):
        self.assertEqual(
            observer._parse_ndjson_filename('/x/CRE-9-verify-gen1.ndjson'),
            ('CRE-9', 'VERIFY', 1))

    def test_hyphenated_phase_slug_is_not_split_wrong(self):
        self.assertEqual(
            observer._parse_ndjson_filename('/x/CRE-9-pr-review-gen3.ndjson'),
            ('CRE-9', 'PR-REVIEW', 3))

    def test_ticket_id_with_hyphens(self):
        self.assertEqual(
            observer._parse_ndjson_filename('/x/AB-CD-12-implement-gen1.ndjson'),
            ('AB-CD-12', 'IMPLEMENT', 1))

    def test_unrecognised_shape_returns_none(self):
        self.assertIsNone(observer._parse_ndjson_filename('/x/random.ndjson'))
        self.assertIsNone(observer._parse_ndjson_filename('/x/CRE-9-gen1.json'))
        self.assertIsNone(
            observer._parse_ndjson_filename('/x/CRE-9-notaphase-gen1.ndjson'))


class RedactionTest(unittest.TestCase):
    def test_known_secret_patterns_are_redacted(self):
        text = (
            'token=ghp_abcdefghijklmnopqrstuvwxyz12 '
            'linear=lin_api_abcdefghijklmnopqrstuvwx '
            'Authorization: Bearer sk-not-a-real-key-12345 '
            'url=https://user:hunter2@example.com/path'
        )
        redacted = observer._redact(text, [])
        self.assertNotIn('ghp_abcdefghijklmnopqrstuvwxyz12', redacted)
        self.assertNotIn('lin_api_abcdefghijklmnopqrstuvwx', redacted)
        self.assertNotIn('hunter2', redacted)
        self.assertIn('<redacted>', redacted)

    def test_env_secret_values_are_redacted(self):
        text = 'ran: curl -H "X-Api-Key: sekrit-value-123"'
        redacted = observer._redact(text, ['sekrit-value-123'])
        self.assertNotIn('sekrit-value-123', redacted)

    def test_collect_env_secret_values_matches_token_key_secret_suffixes(self):
        env = {
            'GITHUB_PERSONAL_ACCESS_TOKEN': 'ghp_realvalue',
            'LINEAR_API_KEY': 'lin_realvalue',
            'SOME_SECRET': 'shh',
            'UNRELATED_VAR': 'not-a-secret-name',
            'EMPTY_TOKEN': '',
        }
        values = observer._collect_env_secret_values(env)
        self.assertIn('ghp_realvalue', values)
        self.assertIn('lin_realvalue', values)
        self.assertIn('shh', values)
        self.assertNotIn('not-a-secret-name', values)
        self.assertNotIn('', values)


class TruncationTest(unittest.TestCase):
    def test_short_value_is_unchanged(self):
        self.assertEqual(observer._truncate('short', 512), 'short')

    def test_long_value_is_truncated_with_marker(self):
        text = 'x' * 1000
        out = observer._truncate(text, 100)
        self.assertEqual(len(out.split('...')[0]), 100)
        self.assertIn('truncated', out)

    def test_none_passes_through(self):
        self.assertIsNone(observer._truncate(None, 512))


class PhaseStreamTranslatorFixtureTest(unittest.TestCase):
    """End-to-end translation against the real captures."""

    def _events(self, fixture_name):
        translator = observer.PhaseStreamTranslator(
            'CRE-9', 'VERIFY', 1, lambda t: t, 512)
        events = []
        now = time.time()
        for line in (FIXTURES_DIR / fixture_name).read_text().splitlines():
            events.extend(translator.feed_line(line, now))
        return events, translator

    def test_exit3_fixture_yields_the_four_expected_event_kinds_in_order(self):
        events, translator = self._events('stream-json-bash-exit3.ndjson')
        kinds = [e['kind'] for e in events]
        self.assertEqual(kinds,
                         ['session_start', 'tool_call', 'tool_result', 'session_end'])
        self.assertIsNotNone(translator.finalized_at)

    def test_exit3_fixture_tool_result_exit_code_is_parsed_from_text(self):
        events, _ = self._events('stream-json-bash-exit3.ndjson')
        tool_result = next(e for e in events if e['kind'] == 'tool_result')
        self.assertTrue(tool_result['is_error'])
        self.assertEqual(tool_result['exit_code'], 3)
        self.assertEqual(tool_result['content'], 'Exit code 3')

    def test_hook_events_fixture_ignores_the_trailing_line_after_result(self):
        # This fixture's `result` frame (line 84 of 85) is followed by a
        # hook-shaped `system` line — README.md's central trap. A naive
        # "result is the last line" reader would never even reach it; this
        # asserts the *opposite* failure mode: reaching it and mis-handling
        # it, e.g. emitting a spurious stream_error or a second session_end.
        events, translator = self._events('stream-json-bash-ok-with-hook-events.ndjson')
        kinds = [e['kind'] for e in events]
        self.assertEqual(kinds,
                         ['session_start', 'tool_call', 'tool_result', 'session_end'])
        self.assertEqual(kinds.count('session_end'), 1)
        self.assertIsNotNone(translator.finalized_at)

    def test_session_start_carries_tools_and_mcp_servers_uncapped(self):
        # UNEXPECTED_TOOL/DEGRADED_SESSION (Inc 3) need these intact —
        # truncation must never touch this event's structural fields.
        events, _ = self._events('stream-json-bash-exit3.ndjson')
        start = next(e for e in events if e['kind'] == 'session_start')
        self.assertIn('Bash', start['tools'])
        self.assertTrue(len(start['mcp_servers']) > 5)

    def test_every_event_carries_tid_phase_gen_and_observed_at(self):
        events, _ = self._events('stream-json-bash-exit3.ndjson')
        for event in events:
            self.assertEqual(event['tid'], 'CRE-9')
            self.assertEqual(event['phase'], 'VERIFY')
            self.assertEqual(event['gen'], 1)
            self.assertIn('T', event['observed_at'])


class TranslatorEdgeCaseTest(unittest.TestCase):
    """Synthetic edge cases the real fixtures don't happen to exercise."""

    def _translator(self):
        return observer.PhaseStreamTranslator(
            'CRE-9', 'VERIFY', 1, lambda t: t, 512)

    def test_unparseable_line_yields_a_stream_error_and_does_not_raise(self):
        translator = self._translator()
        events = translator.feed_line('not json at all {{{', time.time())
        self.assertEqual(len(events), 1)
        self.assertEqual(events[0]['kind'], 'stream_error')
        self.assertIn('not json at all', events[0]['raw'])

    def test_processing_continues_after_an_unparseable_line(self):
        translator = self._translator()
        now = time.time()
        translator.feed_line('garbage', now)
        events = translator.feed_line(
            json.dumps({'type': 'system', 'subtype': 'init',
                       'session_id': 's1', 'tools': ['Bash']}), now)
        self.assertEqual(events[0]['kind'], 'session_start')

    def test_unknown_frame_type_is_silently_ignored(self):
        translator = self._translator()
        events = translator.feed_line(
            json.dumps({'type': 'rate_limit_event', 'foo': 'bar'}), time.time())
        self.assertEqual(events, [])

    def test_blank_line_is_ignored(self):
        translator = self._translator()
        self.assertEqual(translator.feed_line('', time.time()), [])
        self.assertEqual(translator.feed_line('   ', time.time()), [])

    def test_claim_event_extracts_verdict_from_phase_result_block(self):
        translator = self._translator()
        result_text = (
            'preamble text\n'
            '=== PHASE_RESULT ===\n'
            'VERDICT: PASS\n'
            'criteria_met: 3\n'
            '=== END PHASE_RESULT ===\n'
            'trailer text'
        )
        events = translator.feed_line(json.dumps({
            'type': 'result', 'result': result_text, 'session_id': 's1',
        }), time.time())
        claim = next(e for e in events if e['kind'] == 'claim')
        self.assertEqual(claim['claimed_verdict'], 'PASS')
        self.assertIn('criteria_met: 3', claim['raw_block'])
        self.assertNotIn('preamble text', claim['raw_block'])
        self.assertNotIn('trailer text', claim['raw_block'])

    def test_result_with_no_phase_result_block_yields_no_claim_event(self):
        translator = self._translator()
        events = translator.feed_line(json.dumps({
            'type': 'result', 'result': 'just a plain answer',
            'session_id': 's1',
        }), time.time())
        kinds = [e['kind'] for e in events]
        self.assertNotIn('claim', kinds)
        self.assertIn('session_end', kinds)

    def test_parallel_tool_calls_in_one_frame_each_yield_their_own_event(self):
        translator = self._translator()
        events = translator.feed_line(json.dumps({
            'type': 'assistant',
            'message': {'content': [
                {'type': 'tool_use', 'id': 't1', 'name': 'Bash', 'input': {}},
                {'type': 'tool_use', 'id': 't2', 'name': 'Read', 'input': {}},
            ]},
        }), time.time())
        self.assertEqual(len(events), 2)
        self.assertEqual({e['tool_use_id'] for e in events}, {'t1', 't2'})

    def test_secrets_in_tool_call_input_are_redacted(self):
        translator = observer.PhaseStreamTranslator(
            'CRE-9', 'VERIFY', 1,
            lambda t: observer._redact(t, ['sekrit123']), 512)
        events = translator.feed_line(json.dumps({
            'type': 'assistant',
            'message': {'content': [{
                'type': 'tool_use', 'id': 't1', 'name': 'Bash',
                'input': {'command': 'curl -H "X-Api-Key: sekrit123"'},
            }]},
        }), time.time())
        self.assertNotIn('sekrit123', events[0]['input'])

    def test_long_tool_result_content_is_truncated(self):
        translator = observer.PhaseStreamTranslator(
            'CRE-9', 'VERIFY', 1, lambda t: t, 50)
        events = translator.feed_line(json.dumps({
            'type': 'user',
            'message': {'content': [{
                'type': 'tool_result', 'tool_use_id': 't1', 'is_error': False,
                'content': 'x' * 500,
            }]},
        }), time.time())
        self.assertLess(len(events[0]['content']), 500)
        self.assertIn('truncated', events[0]['content'])


class ObserverPollTest(unittest.TestCase):
    """The sidecar loop: discover, tail, write events, release."""

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.log_dir = Path(self._tmp.name)

    def tearDown(self):
        self._tmp.cleanup()

    def _write_ndjson(self, name, lines):
        path = self.log_dir / name
        path.write_text('\n'.join(
            json.dumps(ln) if isinstance(ln, dict) else ln for ln in lines
        ) + '\n')
        return path

    def _events_for(self, tid, phase):
        path = self.log_dir / f'{tid}-{phase.lower()}-events.jsonl'
        if not path.is_file():
            return []
        return [json.loads(ln) for ln in path.read_text().splitlines() if ln.strip()]

    def test_fixture_copy_end_to_end_via_poll_once(self):
        import shutil
        shutil.copy(FIXTURES_DIR / 'stream-json-bash-exit3.ndjson',
                    self.log_dir / 'CRE-9-verify-gen1.ndjson')
        cfg = observer.ObserverConfig(log_dir=str(self.log_dir), grace_secs=0)
        obs = observer.Observer(cfg)
        obs.poll_once()
        events = self._events_for('CRE-9', 'VERIFY')
        self.assertEqual([e['kind'] for e in events],
                         ['session_start', 'tool_call', 'tool_result', 'session_end'])

    def test_a_released_stream_is_never_reprocessed_on_a_later_poll(self):
        """Regression: discover() must not re-track a finished file — its
        .ndjson stays on disk (fleetd's, not the observer's to delete), so
        without release-tracking every later poll would re-emit every event
        again, forever."""
        import shutil
        shutil.copy(FIXTURES_DIR / 'stream-json-bash-exit3.ndjson',
                    self.log_dir / 'CRE-9-verify-gen1.ndjson')
        cfg = observer.ObserverConfig(log_dir=str(self.log_dir), grace_secs=0)
        obs = observer.Observer(cfg)
        for _ in range(5):
            obs.poll_once()
        events = self._events_for('CRE-9', 'VERIFY')
        self.assertEqual(len(events), 4)

    def test_partial_line_at_eof_is_deferred_not_misread(self):
        """Fed one byte at a time: no line is consumed until its newline
        arrives, matching TailReader's existing contract (shared with
        otel.py) — a half-written line now would be recorded permanently
        wrong."""
        path = self.log_dir / 'CRE-9-verify-gen1.ndjson'
        full_line = json.dumps({
            'type': 'system', 'subtype': 'init', 'session_id': 's1',
            'tools': ['Bash'], 'mcp_servers': [],
        }) + '\n'
        path.write_text('')
        cfg = observer.ObserverConfig(log_dir=str(self.log_dir), grace_secs=999)
        obs = observer.Observer(cfg)
        with open(path, 'a') as fh:
            for i, ch in enumerate(full_line):
                fh.write(ch)
                fh.flush()
                obs.poll_once()
                events = self._events_for('CRE-9', 'VERIFY')
                if i < len(full_line) - 1:
                    self.assertEqual(events, [],
                                     f'consumed a partial line at byte {i}')
        events = self._events_for('CRE-9', 'VERIFY')
        self.assertEqual(len(events), 1)
        self.assertEqual(events[0]['kind'], 'session_start')

    def test_unparseable_line_fixture_yields_stream_error_and_keeps_going(self):
        self._write_ndjson('CRE-9-verify-gen1.ndjson', [
            {'type': 'system', 'subtype': 'init', 'session_id': 's1',
             'tools': [], 'mcp_servers': []},
            'not valid json {{{',
            {'type': 'result', 'result': 'DONE', 'session_id': 's1'},
        ])
        cfg = observer.ObserverConfig(log_dir=str(self.log_dir), grace_secs=0)
        obs = observer.Observer(cfg)
        obs.poll_once()
        kinds = [e['kind'] for e in self._events_for('CRE-9', 'VERIFY')]
        self.assertEqual(kinds, ['session_start', 'stream_error', 'session_end'])

    def test_secret_redaction_fixture_through_the_full_poll_loop(self):
        self._write_ndjson('CRE-9-verify-gen1.ndjson', [
            {'type': 'system', 'subtype': 'init', 'session_id': 's1',
             'tools': ['Bash'], 'mcp_servers': []},
            {'type': 'assistant', 'message': {'content': [{
                'type': 'tool_use', 'id': 't1', 'name': 'Bash',
                'input': {'command': 'curl -H "Authorization: Bearer sk-liveleak-123"'},
            }]}},
            {'type': 'result', 'result': 'DONE', 'session_id': 's1'},
        ])
        cfg = observer.ObserverConfig(log_dir=str(self.log_dir), grace_secs=0)
        obs = observer.Observer(cfg)
        obs.poll_once()
        events = self._events_for('CRE-9', 'VERIFY')
        tool_call = next(e for e in events if e['kind'] == 'tool_call')
        self.assertNotIn('sk-liveleak-123', tool_call['input'])
        self.assertIn('<redacted>', tool_call['input'])

    def test_exit_record_finalizes_a_stream_with_no_result_frame(self):
        """SIGKILL case (design.md): the worker's exit-record file, not a
        `result` frame, is what tells the observer this stream is done."""
        self._write_ndjson('CRE-9-verify-gen1.ndjson', [
            {'type': 'system', 'subtype': 'init', 'session_id': 's1',
             'tools': [], 'mcp_servers': []},
        ])
        (self.log_dir / 'CRE-9-gen1-exit.json').write_text(json.dumps({
            'exit_code': -9, 'exit_type': 'signal',
        }))
        cfg = observer.ObserverConfig(log_dir=str(self.log_dir), grace_secs=0)
        obs = observer.Observer(cfg)
        released = obs.poll_once()
        self.assertEqual(released, 1)
        kinds = [e['kind'] for e in self._events_for('CRE-9', 'VERIFY')]
        self.assertEqual(kinds, ['session_start'])

    def test_idle_timeout_with_no_terminal_frame_emits_observer_incomplete(self):
        self._write_ndjson('CRE-9-verify-gen1.ndjson', [
            {'type': 'system', 'subtype': 'init', 'session_id': 's1',
             'tools': [], 'mcp_servers': []},
        ])
        cfg = observer.ObserverConfig(log_dir=str(self.log_dir), grace_secs=0)
        obs = observer.Observer(cfg)
        obs.poll_once()
        # Force the idle clock without sleeping in the test.
        ts = next(iter(obs.streams.values()))
        ts.last_activity -= (cfg.idle_timeout_secs() + 1)
        released = obs.poll_once()
        self.assertEqual(released, 1)
        kinds = [e['kind'] for e in self._events_for('CRE-9', 'VERIFY')]
        self.assertEqual(kinds, ['session_start', 'observer_incomplete'])

    def test_grace_period_holds_a_finished_stream_open_briefly(self):
        self._write_ndjson('CRE-9-verify-gen1.ndjson', [
            {'type': 'result', 'result': 'DONE', 'session_id': 's1'},
        ])
        cfg = observer.ObserverConfig(log_dir=str(self.log_dir), grace_secs=100)
        obs = observer.Observer(cfg)
        released = obs.poll_once()
        self.assertEqual(released, 0)
        self.assertEqual(len(obs.streams), 1)

    def test_ticket_level_json_files_are_never_discovered(self):
        (self.log_dir / 'CRE-9-gen1.json').write_text(json.dumps({
            'type': 'result', 'result': 'DONE',
        }))
        cfg = observer.ObserverConfig(log_dir=str(self.log_dir), grace_secs=0)
        obs = observer.Observer(cfg)
        obs.poll_once()
        self.assertEqual(obs.streams, {})
        self.assertEqual(obs.events_written, 0)


class ObserverSupervisionTest(unittest.TestCase):
    """supervisor.py's spawn/backoff/reap/stop wiring for the sidecar
    (agent-observer Inc 2, task 3.6/3.9) — mirrors test_otel.py's
    TestSupervision exactly, per design.md D1's "architecturally the same
    object"."""

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.state_dir = Path(self._tmp.name)
        self._old_enable = os.environ.get('FLEET_OBSERVER_ENABLE')

    def tearDown(self):
        if self._old_enable is None:
            os.environ.pop('FLEET_OBSERVER_ENABLE', None)
        else:
            os.environ['FLEET_OBSERVER_ENABLE'] = self._old_enable
        self._tmp.cleanup()

    def _sup(self):
        from fleetd.supervisor import Supervisor
        return Supervisor(
            state_dir=str(self.state_dir),
            pidfile=str(self.state_dir / 'test.pid'),
        )

    def test_disabled_by_default_no_child_is_spawned(self):
        os.environ.pop('FLEET_OBSERVER_ENABLE', None)
        sup = self._sup()
        self.assertIsNone(sup.maybe_spawn_observer())
        self.assertIsNone(sup._observer_pid)
        self.assertEqual(len(sup._children), 0)

    def test_enabled_spawns_a_supervised_child_with_a_registry_entry(self):
        from fleetd import supervisor as sup_mod

        os.environ['FLEET_OBSERVER_ENABLE'] = 'true'
        sup = self._sup()
        pid = sup.maybe_spawn_observer()
        self.assertIsNotNone(pid)
        try:
            sid = sup_mod.observer_service_id()
            self.assertIn(sid, sup._children)
            entry = sup._children.get(sid)
            self.assertEqual(entry['pid'], pid)
            self.assertEqual(entry['reason'], 'agent-observer')
            self.assertTrue((self.state_dir / f'{sid}-run.json').exists())
        finally:
            sup.stop_observer(grace_secs=1)

    def test_the_spawned_child_actually_runs(self):
        """Same rationale as otel's equivalent test: a `-m fleetd.observer`
        invocation would die with ModuleNotFoundError from an unrelated
        cwd while every registry assertion above still passed. This runs
        the real argv and checks the exit status."""
        import subprocess

        from fleetd import supervisor as sup_mod

        cmd = sup_mod._observer_cmd(str(self.state_dir)) + ['--once']
        proc = subprocess.run(
            cmd, cwd='/', capture_output=True, text=True, timeout=60)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn('watching', proc.stderr)

    def test_the_observer_is_not_spawned_twice(self):
        os.environ['FLEET_OBSERVER_ENABLE'] = 'true'
        sup = self._sup()
        first = sup.maybe_spawn_observer()
        try:
            self.assertIsNone(sup.maybe_spawn_observer())
            self.assertEqual(sup._observer_pid, first)
        finally:
            sup.stop_observer(grace_secs=1)

    def test_an_observer_exit_never_enters_the_ticket_reap_path(self):
        from fleetd import supervisor as sup_mod

        sup = self._sup()
        sid = sup_mod.observer_service_id()
        sup._observer_pid = 424242
        sup._children.add(sid, 424242, reason='agent-observer')
        sup._handle_observer_exit(424242, 1, 'exit')
        self.assertIsNone(sup._observer_pid)
        self.assertNotIn(sid, sup._children)
        self.assertFalse((self.state_dir / f'{sid}-pipeline.log').exists())
        self.assertEqual(list(self.state_dir.glob('*-exit.json')), [])

    def test_a_crash_schedules_a_backoff_respawn(self):
        sup = self._sup()
        sup._observer_pid = 424243
        sup._handle_observer_exit(424243, 1, 'exit')
        self.assertEqual(sup._observer_failures, 1)
        self.assertGreater(sup._observer_next_attempt, 0)
        os.environ['FLEET_OBSERVER_ENABLE'] = 'true'
        self.assertIsNone(
            sup.maybe_spawn_observer(now=sup._observer_next_attempt - 1))

    def test_backoff_grows_and_a_clean_exit_resets_it(self):
        from fleetd.supervisor import _OBSERVER_RESPAWN_BACKOFF

        sup = self._sup()
        for _ in range(5):
            sup._observer_pid = 1
            sup._handle_observer_exit(1, 1, 'exit')
        self.assertEqual(sup._observer_backoff(), _OBSERVER_RESPAWN_BACKOFF[-1])
        sup._observer_pid = 1
        sup._handle_observer_exit(1, 0, 'exit')
        self.assertEqual(sup._observer_failures, 0)

    def test_stop_is_idempotent_when_nothing_is_running(self):
        sup = self._sup()
        sup.stop_observer()  # must not raise
        self.assertIsNone(sup._observer_pid)


class SweepFixTest(unittest.TestCase):
    """agent-observer D8/task 3.7/3.10: the phase-slugged sweep fix."""

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.state_dir = Path(self._tmp.name)

    def tearDown(self):
        self._tmp.cleanup()

    def _touch(self, name):
        (self.state_dir / name).write_text('x')

    def test_phase_slugged_files_of_both_suffixes_are_swept_past_retention(self):
        from fleetd.supervisor import _sweep_stale_generation_files

        for gen in (1, 2, 3):
            self._touch(f'CRE-9-verify-gen{gen}.json')
            self._touch(f'CRE-9-verify-gen{gen}.ndjson')
            self._touch(f'CRE-9-verify-gen{gen}.stderr')

        _sweep_stale_generation_files(
            str(self.state_dir), 'CRE-9', current_generation=5,
            phase='VERIFY', phase_retention=2)

        # gen1..3 are all >2 generations behind current_generation=5, so all
        # should be swept (cutoff = 5 - 2 = 3, sweeps gen 1..3 inclusive).
        remaining = sorted(p.name for p in self.state_dir.glob('CRE-9-verify-*'))
        self.assertEqual(remaining, [])

    def test_phase_slugged_sweep_keeps_recent_generations(self):
        from fleetd.supervisor import _sweep_stale_generation_files

        for gen in (1, 2, 3, 4, 5):
            self._touch(f'CRE-9-verify-gen{gen}.ndjson')

        _sweep_stale_generation_files(
            str(self.state_dir), 'CRE-9', current_generation=5,
            phase='VERIFY', phase_retention=2)

        remaining = sorted(p.name for p in self.state_dir.glob('CRE-9-verify-*'))
        self.assertEqual(remaining, ['CRE-9-verify-gen4.ndjson',
                                     'CRE-9-verify-gen5.ndjson'])

    def test_ticket_level_sweep_behavior_is_unchanged_when_phase_omitted(self):
        from fleetd.supervisor import _sweep_stale_generation_files

        for gen in (1, 2, 3):
            self._touch(f'CRE-9-gen{gen}.json')
            self._touch(f'CRE-9-gen{gen}.stderr')
            self._touch(f'CRE-9-gen{gen}-exit.json')

        # cutoff = current_generation(5) - retention(2) = 3, so gen 1..3 —
        # every file created above — are all past retention and swept, the
        # same ticket-level outcome as before this change (task 3.7 adds a
        # phase-slugged pass; it must not alter this one).
        _sweep_stale_generation_files(
            str(self.state_dir), 'CRE-9', current_generation=5, retention=2)

        remaining = sorted(p.name for p in self.state_dir.glob('CRE-9-gen*'))
        self.assertEqual(remaining, [])

    def test_no_phase_slugged_exit_json_variant_is_ever_created_or_swept(self):
        # _write_exit_record takes no phase argument — the exit record is
        # always ticket-scoped, never phase-slugged. Confirms the sweep
        # correctly never looks for one.
        from fleetd.supervisor import _sweep_stale_generation_files

        self._touch('CRE-9-verify-gen1.ndjson')
        _sweep_stale_generation_files(
            str(self.state_dir), 'CRE-9', current_generation=5,
            phase='VERIFY', phase_retention=0)
        self.assertFalse((self.state_dir / 'CRE-9-verify-gen1-exit.json').exists())


def _tool_pair(tool_use_id, name, is_error, input_json='{}', observed_at=None):
    call = {'kind': 'tool_call', 'tool_use_id': tool_use_id, 'name': name,
            'input': input_json}
    result = {'kind': 'tool_result', 'tool_use_id': tool_use_id,
             'is_error': is_error}
    if observed_at:
        call['observed_at'] = observed_at[0]
        result['observed_at'] = observed_at[1]
    return call, result


class RuleClaimContradictionTest(unittest.TestCase):
    CONTRACT = {
        'success_criteria': {'claimed_verdict_in': ['PASS']},
        'claim_predicates': {'command_substrings': ['pytest']},
    }
    LOG_PASS_CLAIM = [
        '2026-09-06T10:00:00Z|META|phase-result|info|' + json.dumps(
            {'phase': 'VERIFY', 'claimed_verdict': 'PASS', 'parse_status': 'ok'}),
    ]

    def test_fires_when_last_matching_run_failed(self):
        call, result = _tool_pair('t1', 'Bash', True, '{"command":"pytest"}')
        finding = observer.rule_claim_contradiction(
            [call, result], self.CONTRACT, self.LOG_PASS_CLAIM, 'CRE-9', 'VERIFY', 1)
        self.assertIsNotNone(finding)
        self.assertEqual(finding['type'], 'CLAIM_CONTRADICTION')
        self.assertEqual(finding['severity'], 'HIGH')

    def test_true_negative_when_a_later_run_passed(self):
        c1, r1 = _tool_pair('t1', 'Bash', True, '{"command":"pytest"}')
        c2, r2 = _tool_pair('t2', 'Bash', False, '{"command":"pytest"}')
        finding = observer.rule_claim_contradiction(
            [c1, r1, c2, r2], self.CONTRACT, self.LOG_PASS_CLAIM, 'CRE-9', 'VERIFY', 1)
        self.assertIsNone(finding)

    def test_true_negative_when_no_matching_run_at_all(self):
        finding = observer.rule_claim_contradiction(
            [], self.CONTRACT, self.LOG_PASS_CLAIM, 'CRE-9', 'VERIFY', 1)
        self.assertIsNone(finding)

    def test_disabled_when_contract_is_none(self):
        call, result = _tool_pair('t1', 'Bash', True, '{"command":"pytest"}')
        self.assertIsNone(observer.rule_claim_contradiction(
            [call, result], None, self.LOG_PASS_CLAIM, 'CRE-9', 'VERIFY', 1))

    def test_disabled_when_claimed_verdict_is_unknown(self):
        log = ['2026-09-06T10:00:00Z|META|phase-result|info|' + json.dumps(
            {'phase': 'VERIFY', 'claimed_verdict': 'UNKNOWN', 'parse_status': 'invalid'})]
        call, result = _tool_pair('t1', 'Bash', True, '{"command":"pytest"}')
        self.assertIsNone(observer.rule_claim_contradiction(
            [call, result], self.CONTRACT, log, 'CRE-9', 'VERIFY', 1))


class RuleRepeatedFailureTest(unittest.TestCase):
    def test_fires_at_the_threshold(self):
        events = []
        for i in range(3):
            call, result = _tool_pair(f't{i}', 'Bash', True, '{"command":"flaky"}')
            events.extend([call, result])
        findings = observer.rule_repeated_failure(events, [], 'CRE-9', 'IMPLEMENT', 1)
        self.assertEqual(len(findings), 1)
        self.assertEqual(findings[0]['evidence']['count'], 3)

    def test_true_negative_below_threshold(self):
        call, result = _tool_pair('t1', 'Bash', True, '{"command":"flaky"}')
        self.assertEqual(
            observer.rule_repeated_failure([call, result], [], 'CRE-9', 'IMPLEMENT', 1), [])

    def test_true_negative_when_not_failing(self):
        events = []
        for i in range(3):
            call, result = _tool_pair(f't{i}', 'Bash', False, '{"command":"flaky"}')
            events.extend([call, result])
        self.assertEqual(
            observer.rule_repeated_failure(events, [], 'CRE-9', 'IMPLEMENT', 1), [])


class RuleScopeViolationTest(unittest.TestCase):
    CONTRACT = {'allowed_paths': ['/repo/CRE-9--fix']}

    def test_fires_for_a_write_outside_allowed_paths(self):
        events = [{'kind': 'tool_call', 'tool_use_id': 't1', 'name': 'Write',
                  'path': '/etc/passwd'}]
        findings = observer.rule_scope_violation(events, self.CONTRACT, [], 'CRE-9', 'IMPLEMENT', 1)
        self.assertEqual(len(findings), 1)
        self.assertEqual(findings[0]['severity'], 'HIGH')

    def test_true_negative_for_a_write_inside_allowed_paths(self):
        events = [{'kind': 'tool_call', 'tool_use_id': 't1', 'name': 'Write',
                  'path': '/repo/CRE-9--fix/src/x.py'}]
        self.assertEqual(
            observer.rule_scope_violation(events, self.CONTRACT, [], 'CRE-9', 'IMPLEMENT', 1), [])

    def test_disabled_when_allowed_paths_unresolved(self):
        events = [{'kind': 'tool_call', 'tool_use_id': 't1', 'name': 'Write',
                  'path': '/etc/passwd'}]
        contract = {'allowed_paths': None}
        self.assertEqual(
            observer.rule_scope_violation(events, contract, [], 'CRE-9', 'IMPLEMENT', 1), [])

    def test_read_is_not_scope_checked(self):
        events = [{'kind': 'tool_call', 'tool_use_id': 't1', 'name': 'Read',
                  'path': '/etc/passwd'}]
        self.assertEqual(
            observer.rule_scope_violation(events, self.CONTRACT, [], 'CRE-9', 'IMPLEMENT', 1), [])


class RuleUnexpectedToolTest(unittest.TestCase):
    CONTRACT = {'allowed_tools': ['Bash', 'Read']}

    def test_fires_for_a_disallowed_tool(self):
        events = [{'kind': 'tool_call', 'tool_use_id': 't1', 'name': 'Write'}]
        findings = observer.rule_unexpected_tool(events, self.CONTRACT, [], 'CRE-9', 'APPRAISE', 1)
        self.assertEqual(len(findings), 1)

    def test_true_negative_for_an_allowed_tool(self):
        events = [{'kind': 'tool_call', 'tool_use_id': 't1', 'name': 'Bash'}]
        self.assertEqual(
            observer.rule_unexpected_tool(events, self.CONTRACT, [], 'CRE-9', 'APPRAISE', 1), [])

    def test_disabled_when_allowed_tools_is_none(self):
        events = [{'kind': 'tool_call', 'tool_use_id': 't1', 'name': 'Write'}]
        contract = {'allowed_tools': None}
        self.assertEqual(
            observer.rule_unexpected_tool(events, contract, [], 'CRE-9', 'APPRAISE', 1), [])

    def test_deduplicates_repeat_offenses_of_the_same_tool(self):
        events = [
            {'kind': 'tool_call', 'tool_use_id': 't1', 'name': 'Write'},
            {'kind': 'tool_call', 'tool_use_id': 't2', 'name': 'Write'},
        ]
        findings = observer.rule_unexpected_tool(events, self.CONTRACT, [], 'CRE-9', 'APPRAISE', 1)
        self.assertEqual(len(findings), 1)


class RuleRunawayCostTest(unittest.TestCase):
    def test_fires_over_threshold(self):
        finding = observer.rule_runaway_cost(3.5, [], 'CRE-9', 'IMPLEMENT', 1, 2.0)
        self.assertIsNotNone(finding)
        self.assertEqual(finding['type'], 'RUNAWAY_COST')

    def test_true_negative_under_threshold(self):
        self.assertIsNone(observer.rule_runaway_cost(0.5, [], 'CRE-9', 'IMPLEMENT', 1, 2.0))


class RuleLongToolCallTest(unittest.TestCase):
    def test_fires_over_threshold(self):
        call, result = _tool_pair('t1', 'Bash', False,
                                  observed_at=('2026-09-06T10:00:00Z', '2026-09-06T10:05:00Z'))
        findings = observer.rule_long_tool_call([call, result], [], 'CRE-9', 'VERIFY', 1, 120)
        self.assertEqual(len(findings), 1)
        self.assertEqual(findings[0]['evidence']['elapsed_secs'], 300.0)

    def test_true_negative_under_threshold(self):
        call, result = _tool_pair('t1', 'Bash', False,
                                  observed_at=('2026-09-06T10:00:00Z', '2026-09-06T10:00:05Z'))
        self.assertEqual(
            observer.rule_long_tool_call([call, result], [], 'CRE-9', 'VERIFY', 1, 120), [])


class RuleDegradedSessionTest(unittest.TestCase):
    def test_fires_for_a_relevant_degraded_server(self):
        events = [{'kind': 'session_start', 'mcp_servers': [
            {'name': 'linear-server', 'status': 'failed'},
        ]}]
        findings = observer.rule_degraded_session(events, [], 'CRE-9', 'APPRAISE', 1)
        self.assertEqual(len(findings), 1)

    def test_true_negative_for_an_unrelated_degraded_server(self):
        events = [{'kind': 'session_start', 'mcp_servers': [
            {'name': 'plugin:cloudflare:cloudflare-api', 'status': 'needs-auth'},
        ]}]
        self.assertEqual(
            observer.rule_degraded_session(events, [], 'CRE-9', 'APPRAISE', 1), [])

    def test_true_negative_for_a_connected_server(self):
        events = [{'kind': 'session_start', 'mcp_servers': [
            {'name': 'linear-server', 'status': 'connected'},
        ]}]
        self.assertEqual(
            observer.rule_degraded_session(events, [], 'CRE-9', 'APPRAISE', 1), [])

    def test_verify_phase_also_checks_playwright(self):
        events = [{'kind': 'session_start', 'mcp_servers': [
            {'name': 'plugin_playwright_playwright', 'status': 'failed'},
        ]}]
        findings = observer.rule_degraded_session(events, [], 'CRE-9', 'VERIFY', 1)
        self.assertEqual(len(findings), 1)


class RulePermissionDeniedTest(unittest.TestCase):
    def test_fires_when_denials_present(self):
        events = [{'kind': 'session_end', 'permission_denials': [{'tool_name': 'Bash'}]}]
        findings = observer.rule_permission_denied(events, [], 'CRE-9', 'IMPLEMENT', 1)
        self.assertEqual(len(findings), 1)

    def test_true_negative_when_empty(self):
        events = [{'kind': 'session_end', 'permission_denials': []}]
        self.assertEqual(
            observer.rule_permission_denied(events, [], 'CRE-9', 'IMPLEMENT', 1), [])

    def test_true_negative_with_no_session_end(self):
        self.assertEqual(
            observer.rule_permission_denied([], [], 'CRE-9', 'IMPLEMENT', 1), [])


class RecordFindingsTest(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.log_dir = Path(self._tmp.name)

    def tearDown(self):
        self._tmp.cleanup()

    def _finding(self, fingerprint='fp1'):
        return {'type': 'UNEXPECTED_TOOL', 'severity': 'HIGH', 'tid': 'CRE-9',
               'phase': 'APPRAISE', 'gen': 1, 'fingerprint': fingerprint,
               'evidence': {'tool': 'Write'}}

    def _findings_lines(self):
        path = self.log_dir / 'CRE-9-appraise-findings.jsonl'
        if not path.is_file():
            return []
        return [json.loads(ln) for ln in path.read_text().splitlines() if ln.strip()]

    def _pipeline_lines(self):
        path = self.log_dir / 'CRE-9-pipeline.log'
        if not path.is_file():
            return []
        return path.read_text().splitlines()

    def test_a_new_finding_is_written_once_to_both_files(self):
        created = observer.record_findings(
            str(self.log_dir), 'CRE-9', 'APPRAISE', [self._finding()], time.time())
        self.assertEqual(len(created), 1)
        self.assertEqual(len(self._findings_lines()), 1)
        self.assertEqual(len(self._pipeline_lines()), 1)

    def test_a_repeat_fingerprint_increments_count_without_duplicating(self):
        observer.record_findings(
            str(self.log_dir), 'CRE-9', 'APPRAISE', [self._finding()], time.time())
        created2 = observer.record_findings(
            str(self.log_dir), 'CRE-9', 'APPRAISE', [self._finding()], time.time())
        self.assertEqual(created2, [])
        lines = self._findings_lines()
        self.assertEqual(len(lines), 1)
        self.assertEqual(lines[0]['count'], 2)
        # No repeat pipeline-log spam (design.md D5 anti-spam precedent).
        self.assertEqual(len(self._pipeline_lines()), 1)

    def test_pipeline_log_line_is_withheld_once_the_ticket_is_terminal(self):
        # Regression: found during Inc 3 development — appending an
        # observer-finding line after META|outcome flips
        # _log_reached_terminal from True to False.
        log_lines = [
            '2026-09-06T10:00:00Z|IMPLEMENT|implement|done|ok',
            '2026-09-06T10:01:00Z|META|outcome|info|complete',
        ]
        created = observer.record_findings(
            str(self.log_dir), 'CRE-9', 'APPRAISE', [self._finding()], time.time(),
            log_lines=log_lines)
        self.assertEqual(len(created), 1)  # findings.jsonl still gets it
        self.assertEqual(len(self._findings_lines()), 1)
        self.assertEqual(self._pipeline_lines(), [])  # pipeline log untouched

    def test_no_findings_writes_nothing(self):
        created = observer.record_findings(
            str(self.log_dir), 'CRE-9', 'APPRAISE', [], time.time())
        self.assertEqual(created, [])
        self.assertEqual(self._findings_lines(), [])


class TerminalClassificationParityTest(unittest.TestCase):
    """task 4.10: _log_reached_terminal must be byte-identical with and
    without an injected META|observer-finding line, in every state that
    matters — not just the completed-ticket case RecordFindingsTest already
    covers from the writer side."""

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.state_dir = Path(self._tmp.name)

    def tearDown(self):
        self._tmp.cleanup()

    def _classify(self, tid):
        import sys as _sys
        _sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent))
        from fleetd.supervisor import _log_reached_terminal
        return _log_reached_terminal(str(self.state_dir), tid)

    def _write_log(self, tid, lines):
        (self.state_dir / f'{tid}-pipeline.log').write_text('\n'.join(lines) + '\n')

    def test_non_terminal_log_stays_non_terminal_with_a_mid_run_finding(self):
        self._write_log('CRE-1', [
            '2026-09-06T10:00:00Z|VERIFY|verify|waiting|Agent launched',
        ])
        before = self._classify('CRE-1')
        with open(self.state_dir / 'CRE-1-pipeline.log', 'a') as fh:
            fh.write('2026-09-06T10:00:30Z|META|observer-finding|done|'
                    'type=UNEXPECTED_TOOL sev=HIGH gen=1 fp=abc\n')
        after = self._classify('CRE-1')
        self.assertEqual(before, after)
        self.assertFalse(after)

    def test_terminal_log_stays_terminal_when_finding_precedes_outcome(self):
        self._write_log('CRE-2', [
            '2026-09-06T10:00:00Z|IMPLEMENT|implement|done|ok',
            '2026-09-06T10:00:30Z|META|observer-finding|done|'
            'type=UNEXPECTED_TOOL sev=HIGH gen=1 fp=abc',
            '2026-09-06T10:01:00Z|META|outcome|info|complete',
        ])
        self.assertTrue(self._classify('CRE-2'))


class ObserverIncompleteImmuneToRulesTest(unittest.TestCase):
    """task 4.11: no configuration of observer failure changes a ticket's
    phase progression. Exercised at the unit level here (the finding
    evaluator and writer never raise, and never touch anything but their
    own files); ObserverSupervisionTest already covers process-level
    crash isolation."""

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.log_dir = Path(self._tmp.name)

    def tearDown(self):
        self._tmp.cleanup()

    def test_evaluate_rules_never_raises_on_a_missing_contract(self):
        findings = observer.evaluate_rules(
            [{'kind': 'tool_call', 'tool_use_id': 't1', 'name': 'Write', 'path': '/x'}],
            None, [], 0.0, 'CRE-9', 'IMPLEMENT', 1, 2.0, 120)
        self.assertIsInstance(findings, list)

    def test_evaluate_rules_never_raises_on_malformed_events(self):
        findings = observer.evaluate_rules(
            [{'kind': 'tool_call'}, {'not_even_a_kind': True}, {}],
            {'allowed_tools': ['Bash']}, [], 0.0, 'CRE-9', 'IMPLEMENT', 1, 2.0, 120)
        self.assertIsInstance(findings, list)

    def test_a_crashing_rule_evaluation_never_touches_the_pipeline_log(self):
        from unittest import mock

        cfg = observer.ObserverConfig(log_dir=str(self.log_dir), grace_secs=0)
        obs_instance = observer.Observer(cfg)
        ts = observer.TrackedStream(
            path='/x', tid='CRE-9', phase='IMPLEMENT', generation=1,
            reader=observer.TailReader('/x'),
            translator=observer.PhaseStreamTranslator(
                'CRE-9', 'IMPLEMENT', 1, lambda t: t, 512),
            last_activity=time.time(),
        )
        with mock.patch.object(observer, 'evaluate_rules',
                              side_effect=RuntimeError('boom')):
            obs_instance._evaluate_and_record_findings(ts, time.time())
        # Must not raise, and must not have created a pipeline log.
        self.assertFalse((self.log_dir / 'CRE-9-pipeline.log').exists())


class ObserverEnabledTest(unittest.TestCase):
    def test_disabled_by_default(self):
        env = os.environ.pop('FLEET_OBSERVER_ENABLE', None)
        try:
            self.assertFalse(observer.observer_enabled())
        finally:
            if env is not None:
                os.environ['FLEET_OBSERVER_ENABLE'] = env

    def test_true_string_enables(self):
        os.environ['FLEET_OBSERVER_ENABLE'] = 'true'
        try:
            self.assertTrue(observer.observer_enabled())
        finally:
            del os.environ['FLEET_OBSERVER_ENABLE']


if __name__ == '__main__':
    unittest.main()
