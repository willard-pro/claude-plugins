"""
Tests for the OTel exporter (fleetd/otel.py) and its fleetd supervision.

Run:
    python3 -m pytest fleet-controller/fleetd/tests/test_otel.py -v

The SDK is deliberately not required to run these. Everything above
`OtlpEmitter` is pure stdlib, and the emitter itself is replaced by a recorder
in the derivation tests — asserting on a real TracerProvider's internals would
test the SDK, not the translation.

The properties under test are the ones D5 and D11 rest on:

- Spans are derived from log lines, so a phase that logs correctly is traced
  correctly with no instrumentation of its own.
- The exporter is downstream: an absent SDK, an unreachable collector, or a
  dead exporter process changes nothing about how fleetd supervises tickets.
- The exporter is a supervised child but *not* a ticket, so its exit never
  enters the ticket reap path.
"""

import os
import sys
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path

from fleetd import otel


# Relative to the real clock, not pinned: the grace window is evaluated against
# datetime.now(), so a fixture timestamped in the future never becomes ready.
NOW = datetime.now(timezone.utc).replace(microsecond=0)


def iso(secs_ago):
    return (NOW - timedelta(seconds=secs_ago)).strftime('%Y-%m-%dT%H:%M:%SZ')


class RecordingEmitter:
    """Stands in for OtlpEmitter. Records instead of exporting."""

    available = True

    def __init__(self):
        self.spans = []
        self.closed = []
        self.shutdowns = 0

    def emit(self, span):
        self.spans.append(span)

    def close_ticket(self, ticket, outcome, end_ts):
        self.closed.append((ticket, outcome))

    def shutdown(self):
        self.shutdowns += 1


class LogFixture:
    """A workspace of pipeline/activity logs."""

    def __init__(self, root):
        self.root = Path(root)

    def pipeline(self, tid, lines):
        path = self.root / f'{tid}-pipeline.log'
        with open(path, 'a') as fh:
            for ln in lines:
                fh.write(ln + '\n')
        return path

    def activity(self, tid, rows):
        path = self.root / f'{tid}-activity.log'
        with open(path, 'a') as fh:
            for ts, phase, tool in rows:
                fh.write(f'{ts}|{phase}|{tool}\n')
        return path

    def exporter(self, **cfg):
        config = otel.ExporterConfig(log_dir=str(self.root), span_grace_secs=0, **cfg)
        emitter = RecordingEmitter()
        return otel.Exporter(config, emitter), emitter


class TempWorkspace(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.ws = LogFixture(self._tmp.name)

    def tearDown(self):
        self._tmp.cleanup()


# ── Span derivation ─────────────────────────────────────────────────────────

class TestSpanDerivation(TempWorkspace):
    def test_a_bracket_becomes_one_span(self):
        self.ws.pipeline('AAA-1', [
            f'{iso(300)}|IMPLEMENT|implement|waiting|Agent launched',
            f'{iso(120)}|IMPLEMENT|implement|done|implemented',
        ])
        ex, rec = self.ws.exporter()
        self.assertEqual(ex.poll_once(), 1)
        span = rec.spans[0]
        self.assertEqual(span.ticket, 'AAA-1')
        self.assertEqual(span.phase, 'IMPLEMENT')
        self.assertTrue(span.ok)
        self.assertEqual(span.duration_secs(), 180)

    def test_a_failing_phase_produces_an_error_span(self):
        self.ws.pipeline('AAA-2', [
            f'{iso(300)}|VERIFY|verify|waiting|attempt 1',
            f'{iso(120)}|VERIFY|verify|fail|FAIL criterion 2',
        ])
        ex, rec = self.ws.exporter()
        ex.poll_once()
        self.assertFalse(rec.spans[0].ok)
        self.assertIn('criterion 2', rec.spans[0].msg)

    def test_a_skipped_phase_is_not_an_error(self):
        self.ws.pipeline('AAA-3', [
            f'{iso(300)}|MAINTENANCE|wiki|waiting|x',
            f'{iso(299)}|MAINTENANCE|wiki|skip|no wiki configured',
        ])
        ex, rec = self.ws.exporter()
        ex.poll_once()
        self.assertTrue(rec.spans[0].ok)
        self.assertEqual(rec.spans[0].attributes['pipeline.status'], 'skip')

    def test_an_open_bracket_produces_no_span_yet(self):
        self.ws.pipeline('AAA-4', [f'{iso(300)}|IMPLEMENT|implement|waiting|x'])
        ex, rec = self.ws.exporter()
        self.assertEqual(ex.poll_once(), 0)
        self.assertEqual(rec.spans, [])

    def test_retries_produce_one_span_each(self):
        self.ws.pipeline('AAA-5', [
            f'{iso(900)}|VERIFY|verify|waiting|attempt 1',
            f'{iso(800)}|VERIFY|verify|fail|FAIL',
            f'{iso(700)}|VERIFY|verify|waiting|attempt 2',
            f'{iso(600)}|VERIFY|verify|done|PASS',
        ])
        ex, rec = self.ws.exporter()
        self.assertEqual(ex.poll_once(), 2)
        self.assertEqual([s.ok for s in rec.spans], [False, True])

    def test_a_terminal_without_an_opening_bracket_is_marked_not_invented(self):
        # Happens when the exporter starts mid-run. Recording it as a
        # zero-length span with a flag beats silently pretending the phase
        # started when it ended.
        self.ws.pipeline('AAA-6', [f'{iso(120)}|IMPLEMENT|implement|done|ok'])
        ex, rec = self.ws.exporter()
        ex.poll_once()
        self.assertTrue(rec.spans[0].attributes['pipeline.bracket_incomplete'])

    def test_malformed_lines_are_ignored(self):
        self.ws.pipeline('AAA-7', [
            'garbage',
            'also|not|enough|fields',
            f'{iso(300)}|IMPLEMENT|implement|waiting|x',
            f'{iso(200)}|IMPLEMENT|implement|done|ok',
        ])
        ex, rec = self.ws.exporter()
        self.assertEqual(ex.poll_once(), 1)

    def test_an_unparseable_timestamp_does_not_create_a_span(self):
        self.ws.pipeline('AAA-8', [
            'not-a-date|IMPLEMENT|implement|waiting|x',
            'also-not|IMPLEMENT|implement|done|ok',
        ])
        ex, rec = self.ws.exporter()
        self.assertEqual(ex.poll_once(), 0)


class TestAttributes(TempWorkspace):
    def test_genai_convention_attributes_are_present(self):
        self.ws.pipeline('BBB-1', [
            f'{iso(300)}|IMPLEMENT|implement|waiting|x',
            f'{iso(200)}|IMPLEMENT|implement|done|ok',
        ])
        ex, rec = self.ws.exporter()
        ex.poll_once()
        attrs = rec.spans[0].attributes
        self.assertEqual(attrs['gen_ai.system'], 'anthropic')
        self.assertEqual(attrs['gen_ai.operation.name'], 'invoke_agent')
        self.assertEqual(attrs['gen_ai.agent.name'], 'implement.implement')
        self.assertEqual(attrs['ticket.id'], 'BBB-1')

    def test_model_from_a_meta_line_lands_on_the_span(self):
        self.ws.pipeline('BBB-2', [
            f'{iso(400)}|META|model|info|{{"phase":"IMPLEMENT","model":"claude-opus-5"}}',
            f'{iso(300)}|IMPLEMENT|implement|waiting|x',
            f'{iso(200)}|IMPLEMENT|implement|done|ok',
        ])
        ex, rec = self.ws.exporter()
        ex.poll_once()
        self.assertEqual(rec.spans[0].attributes['gen_ai.request.model'], 'claude-opus-5')

    def test_tokens_written_after_the_terminal_still_attach(self):
        # The reason the grace buffer exists: token-tracker.sh's SubagentStop
        # hook writes META|tokens *after* the router writes the terminal line,
        # so a span emitted the instant its bracket closes always loses them.
        self.ws.pipeline('BBB-3', [
            f'{iso(300)}|IMPLEMENT|implement|waiting|x',
            f'{iso(200)}|IMPLEMENT|implement|done|ok',
            f'{iso(199)}|META|tokens|info|IMPLEMENT:12000/3400/88000|elapsed_ms=98000',
        ])
        ex, rec = self.ws.exporter()
        ex.poll_once()
        attrs = rec.spans[0].attributes
        self.assertEqual(attrs['gen_ai.usage.input_tokens'], 12000)
        self.assertEqual(attrs['gen_ai.usage.output_tokens'], 3400)
        self.assertEqual(attrs['pipeline.tokens.cache'], 88000)
        self.assertEqual(attrs['pipeline.elapsed_ms'], 98000)

    def test_a_malformed_model_line_is_not_fatal(self):
        self.ws.pipeline('BBB-4', [
            f'{iso(400)}|META|model|info|{{not json',
            f'{iso(300)}|IMPLEMENT|implement|waiting|x',
            f'{iso(200)}|IMPLEMENT|implement|done|ok',
        ])
        ex, rec = self.ws.exporter()
        self.assertEqual(ex.poll_once(), 1)
        self.assertNotIn('gen_ai.request.model', rec.spans[0].attributes)


class TestGraceWindow(TempWorkspace):
    def test_a_span_waits_out_its_grace_window(self):
        self.ws.pipeline('CCC-1', [
            f'{iso(30)}|IMPLEMENT|implement|waiting|x',
            f'{iso(0)}|IMPLEMENT|implement|done|ok',
        ])
        config = otel.ExporterConfig(log_dir=str(self.ws.root), span_grace_secs=3600)
        rec = RecordingEmitter()
        ex = otel.Exporter(config, rec)
        self.assertEqual(ex.poll_once(), 0)
        self.assertEqual(len(ex.pending), 1)

    def test_the_ticket_outcome_flushes_immediately(self):
        # Nothing more can arrive to enrich a finished ticket, so its spans
        # must not sit out a grace window waiting for it.
        self.ws.pipeline('CCC-2', [
            f'{iso(30)}|IMPLEMENT|implement|waiting|x',
            f'{iso(1)}|IMPLEMENT|implement|done|ok',
            f'{iso(0)}|META|outcome|info|complete',
        ])
        config = otel.ExporterConfig(log_dir=str(self.ws.root), span_grace_secs=3600)
        rec = RecordingEmitter()
        ex = otel.Exporter(config, rec)
        self.assertEqual(ex.poll_once(), 1)
        self.assertEqual(rec.closed, [('CCC-2', 'complete')])
        self.assertEqual(ex.pending, [])

    def test_shutdown_flushes_buffered_spans(self):
        self.ws.pipeline('CCC-3', [
            f'{iso(30)}|IMPLEMENT|implement|waiting|x',
            f'{iso(0)}|IMPLEMENT|implement|done|ok',
        ])
        config = otel.ExporterConfig(
            log_dir=str(self.ws.root), span_grace_secs=3600, poll_secs=0)
        rec = RecordingEmitter()
        ex = otel.Exporter(config, rec)
        ex.run(max_cycles=1)
        self.assertEqual(len(rec.spans), 1)
        self.assertEqual(rec.shutdowns, 1)


class TestActivityDecoration(TempWorkspace):
    def test_tool_calls_inside_the_span_are_counted(self):
        self.ws.pipeline('DDD-1', [
            f'{iso(300)}|IMPLEMENT|implement|waiting|x',
            f'{iso(100)}|IMPLEMENT|implement|done|ok',
        ])
        self.ws.activity('DDD-1', [
            (iso(250), 'IMPLEMENT', 'Bash'),
            (iso(200), 'IMPLEMENT', 'Edit'),
            (iso(150), 'IMPLEMENT', 'Read'),
        ])
        ex, rec = self.ws.exporter()
        ex.poll_once()
        self.assertEqual(rec.spans[0].attributes['pipeline.tool_calls'], 3)
        self.assertEqual(len(rec.spans[0].events), 3)

    def test_tool_calls_outside_the_span_are_not_counted(self):
        self.ws.pipeline('DDD-2', [
            f'{iso(300)}|IMPLEMENT|implement|waiting|x',
            f'{iso(200)}|IMPLEMENT|implement|done|ok',
        ])
        self.ws.activity('DDD-2', [
            (iso(900), 'APPRAISE', 'Bash'),   # before the bracket
            (iso(250), 'IMPLEMENT', 'Edit'),  # inside
            (iso(10), 'VERIFY', 'Bash'),      # after
        ])
        ex, rec = self.ws.exporter()
        ex.poll_once()
        self.assertEqual(rec.spans[0].attributes['pipeline.tool_calls'], 1)

    def test_events_are_capped_and_the_truncation_is_declared(self):
        self.ws.pipeline('DDD-3', [
            f'{iso(300)}|IMPLEMENT|implement|waiting|x',
            f'{iso(100)}|IMPLEMENT|implement|done|ok',
        ])
        self.ws.activity('DDD-3', [(iso(200), 'IMPLEMENT', 'Bash')] * 25)
        ex, rec = self.ws.exporter(max_tool_events=10)
        ex.poll_once()
        attrs = rec.spans[0].attributes
        self.assertEqual(attrs['pipeline.tool_calls'], 25)
        self.assertEqual(len(rec.spans[0].events), 10)
        self.assertTrue(attrs['pipeline.tool_calls_truncated'])

    def test_an_absent_activity_log_is_not_an_error(self):
        self.ws.pipeline('DDD-4', [
            f'{iso(300)}|IMPLEMENT|implement|waiting|x',
            f'{iso(100)}|IMPLEMENT|implement|done|ok',
        ])
        ex, rec = self.ws.exporter()
        ex.poll_once()
        self.assertNotIn('pipeline.tool_calls', rec.spans[0].attributes)


class TestTailing(TempWorkspace):
    def test_lines_are_read_once_across_polls(self):
        self.ws.pipeline('EEE-1', [
            f'{iso(300)}|IMPLEMENT|implement|waiting|x',
            f'{iso(200)}|IMPLEMENT|implement|done|ok',
        ])
        ex, rec = self.ws.exporter()
        self.assertEqual(ex.poll_once(), 1)
        self.assertEqual(ex.poll_once(), 0)  # nothing new
        self.ws.pipeline('EEE-1', [
            f'{iso(150)}|VERIFY|verify|waiting|x',
            f'{iso(100)}|VERIFY|verify|done|PASS',
        ])
        self.assertEqual(ex.poll_once(), 1)
        self.assertEqual(len(rec.spans), 2)

    def test_a_partially_written_line_is_not_consumed(self):
        # The log is being appended to by a live agent. A half-written line
        # read now would be recorded permanently wrong, and an append-only
        # log never corrects it.
        path = self.ws.root / 'EEE-2-pipeline.log'
        with open(path, 'w') as fh:
            fh.write(f'{iso(300)}|IMPLEMENT|implement|waiting|x\n')
            fh.write(f'{iso(200)}|IMPLEMENT|implem')  # no newline yet
        ex, rec = self.ws.exporter()
        self.assertEqual(ex.poll_once(), 0)
        with open(path, 'a') as fh:
            fh.write('ent|done|ok\n')
        self.assertEqual(ex.poll_once(), 1)

    def test_a_new_pipeline_is_picked_up_without_a_restart(self):
        self.ws.pipeline('EEE-3', [
            f'{iso(300)}|IMPLEMENT|implement|waiting|x',
            f'{iso(200)}|IMPLEMENT|implement|done|ok',
        ])
        ex, rec = self.ws.exporter()
        ex.poll_once()
        self.ws.pipeline('EEE-4', [
            f'{iso(100)}|APPRAISE|appraise|waiting|x',
            f'{iso(50)}|APPRAISE|appraise|done|ok',
        ])
        self.assertEqual(ex.poll_once(), 1)
        self.assertEqual({s.ticket for s in rec.spans}, {'EEE-3', 'EEE-4'})

    def test_a_truncated_log_restarts_rather_than_reading_garbage(self):
        path = self.ws.pipeline('EEE-5', [
            f'{iso(300)}|IMPLEMENT|implement|waiting|x',
            f'{iso(200)}|IMPLEMENT|implement|done|ok',
        ])
        ex, rec = self.ws.exporter()
        ex.poll_once()
        with open(path, 'w') as fh:
            fh.write(f'{iso(100)}|VERIFY|verify|waiting|x\n')
            fh.write(f'{iso(50)}|VERIFY|verify|done|PASS\n')
        self.assertEqual(ex.poll_once(), 1)


class TestMultipleTickets(TempWorkspace):
    def test_spans_carry_their_own_ticket(self):
        for tid in ('FFF-1', 'FFF-2', 'FFF-3'):
            self.ws.pipeline(tid, [
                f'{iso(300)}|IMPLEMENT|implement|waiting|x',
                f'{iso(200)}|IMPLEMENT|implement|done|ok',
            ])
        ex, rec = self.ws.exporter()
        self.assertEqual(ex.poll_once(), 3)
        self.assertEqual(
            sorted(s.attributes['ticket.id'] for s in rec.spans),
            ['FFF-1', 'FFF-2', 'FFF-3'])

    def test_one_tickets_tokens_do_not_leak_into_another(self):
        self.ws.pipeline('FFF-4', [
            f'{iso(300)}|IMPLEMENT|implement|waiting|x',
            f'{iso(200)}|IMPLEMENT|implement|done|ok',
            f'{iso(199)}|META|tokens|info|IMPLEMENT:1/2/3',
        ])
        self.ws.pipeline('FFF-5', [
            f'{iso(300)}|IMPLEMENT|implement|waiting|x',
            f'{iso(200)}|IMPLEMENT|implement|done|ok',
        ])
        ex, rec = self.ws.exporter()
        ex.poll_once()
        by_tid = {s.ticket: s.attributes for s in rec.spans}
        self.assertEqual(by_tid['FFF-4']['gen_ai.usage.input_tokens'], 1)
        self.assertNotIn('gen_ai.usage.input_tokens', by_tid['FFF-5'])


# ── Fail-soft contract (D11, task 8.6) ──────────────────────────────────────

class TestFailSoft(unittest.TestCase):
    def test_the_exporter_is_opt_in(self):
        # A telemetry exporter that starts by default would have every fleetd
        # install opening OTLP connections to a collector nobody configured.
        old = os.environ.pop('FLEET_OTEL_ENABLE', None)
        try:
            self.assertFalse(otel.exporter_enabled())
        finally:
            if old is not None:
                os.environ['FLEET_OTEL_ENABLE'] = old

    def test_an_absent_sdk_is_reported_not_raised(self):
        import io

        cfg = otel.ExporterConfig()
        buf = io.StringIO()
        emitter = otel.OtlpEmitter(cfg, stderr=buf)
        # Force the import to fail regardless of whether the SDK is installed.
        real_import = __builtins__['__import__'] if isinstance(__builtins__, dict) \
            else __builtins__.__import__

        def blocked(name, *a, **kw):
            if name.startswith('opentelemetry'):
                raise ImportError('blocked for test')
            return real_import(name, *a, **kw)

        import builtins
        builtins.__import__ = blocked
        try:
            started = emitter.start()
        finally:
            builtins.__import__ = real_import
        self.assertFalse(started)
        self.assertFalse(emitter.available)
        self.assertIn('unavailable', buf.getvalue())

    def test_an_unavailable_emitter_makes_every_method_a_noop(self):
        cfg = otel.ExporterConfig()
        emitter = otel.OtlpEmitter(cfg)
        self.assertFalse(emitter.available)
        # None of these may raise.
        span = otel.DerivedSpan(
            ticket='X-1', phase='IMPLEMENT', step='implement',
            start=NOW, end=NOW, ok=True)
        emitter.emit(span)
        emitter.close_ticket('X-1', 'complete', NOW)
        emitter.shutdown()

    def test_derivation_still_runs_with_an_unavailable_emitter(self):
        # The pipeline must not care whether telemetry works. A real
        # OtlpEmitter that never started is the exact production shape when
        # the SDK is missing.
        with tempfile.TemporaryDirectory() as d:
            ws = LogFixture(d)
            ws.pipeline('X-2', [
                f'{iso(300)}|IMPLEMENT|implement|waiting|x',
                f'{iso(200)}|IMPLEMENT|implement|done|ok',
            ])
            cfg = otel.ExporterConfig(log_dir=d, span_grace_secs=0)
            ex = otel.Exporter(cfg, otel.OtlpEmitter(cfg))
            self.assertEqual(ex.poll_once(), 1)  # derived, silently discarded

    def test_a_missing_log_directory_exits_nonzero_without_raising(self):
        rc = otel.main(['--log-dir', '/nonexistent/definitely/not/here', '--once'])
        self.assertEqual(rc, 2)


# ── fleetd supervision (task 8.5) ───────────────────────────────────────────

class TestSupervision(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.state_dir = Path(self._tmp.name)
        self._old_enable = os.environ.get('FLEET_OTEL_ENABLE')

    def tearDown(self):
        if self._old_enable is None:
            os.environ.pop('FLEET_OTEL_ENABLE', None)
        else:
            os.environ['FLEET_OTEL_ENABLE'] = self._old_enable
        self._tmp.cleanup()

    def _sup(self):
        from fleetd.supervisor import Supervisor
        return Supervisor(
            state_dir=str(self.state_dir),
            pidfile=str(self.state_dir / 'test.pid'),
        )

    def test_disabled_by_default_no_child_is_spawned(self):
        os.environ.pop('FLEET_OTEL_ENABLE', None)
        sup = self._sup()
        self.assertIsNone(sup.maybe_spawn_otel())
        self.assertIsNone(sup._otel_pid)
        self.assertEqual(len(sup._children), 0)

    def test_enabled_spawns_a_supervised_child_with_a_registry_entry(self):
        from fleetd import supervisor as sup_mod

        os.environ['FLEET_OTEL_ENABLE'] = 'true'
        sup = self._sup()
        pid = sup.maybe_spawn_otel()
        self.assertIsNotNone(pid)
        try:
            sid = sup_mod.otel_service_id()
            self.assertIn(sid, sup._children)
            entry = sup._children.get(sid)
            self.assertEqual(entry['pid'], pid)
            self.assertEqual(entry['reason'], 'otel-exporter')
            # The spec's registry requirement: a run-registry file exists while
            # the process is active.
            self.assertTrue((self.state_dir / f'{sid}-run.json').exists())
        finally:
            sup.stop_otel(grace_secs=1)

    def test_the_spawned_child_actually_runs(self):
        """The spawn tests above prove a pid exists, not that it survived.

        A `-m fleetd.otel` invocation dies instantly with ModuleNotFoundError
        wherever fleetd was started from, and every assertion about the
        registry entry would still pass. This runs the real argv, from an
        unrelated working directory, and checks the exit status.
        """
        import subprocess

        from fleetd import supervisor as sup_mod

        cmd = sup_mod._otel_cmd(str(self.state_dir)) + ['--once']
        proc = subprocess.run(
            cmd, cwd='/', capture_output=True, text=True, timeout=60)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn('watching', proc.stderr)

    def test_the_exporter_is_not_spawned_twice(self):
        os.environ['FLEET_OTEL_ENABLE'] = 'true'
        sup = self._sup()
        first = sup.maybe_spawn_otel()
        try:
            self.assertIsNone(sup.maybe_spawn_otel())
            self.assertEqual(sup._otel_pid, first)
        finally:
            sup.stop_otel(grace_secs=1)

    def test_an_exporter_exit_never_enters_the_ticket_reap_path(self):
        # Sending it down the ticket path would write META|worker-exit into an
        # otel-exporter-pipeline.log, which fleet_detect_all would then glob
        # and report on — the monitor manufacturing findings about itself.
        from fleetd import supervisor as sup_mod

        sup = self._sup()
        sid = sup_mod.otel_service_id()
        sup._otel_pid = 424242
        sup._children.add(sid, 424242, reason='otel-exporter')
        sup._handle_otel_exit(424242, 1, 'exit')
        self.assertIsNone(sup._otel_pid)
        self.assertNotIn(sid, sup._children)
        self.assertFalse((self.state_dir / f'{sid}-pipeline.log').exists())
        self.assertEqual(list(self.state_dir.glob('*-exit.json')), [])

    def test_a_crash_schedules_a_backoff_respawn(self):
        sup = self._sup()
        sup._otel_pid = 424243
        sup._handle_otel_exit(424243, 1, 'exit')
        self.assertEqual(sup._otel_failures, 1)
        self.assertGreater(sup._otel_next_attempt, 0)
        # Inside the backoff window, no respawn even when enabled.
        os.environ['FLEET_OTEL_ENABLE'] = 'true'
        self.assertIsNone(sup.maybe_spawn_otel(now=sup._otel_next_attempt - 1))

    def test_backoff_grows_and_a_clean_exit_resets_it(self):
        sup = self._sup()
        for _ in range(5):
            sup._otel_pid = 1
            sup._handle_otel_exit(1, 1, 'exit')
        self.assertEqual(sup._otel_backoff(), sup_backoff_max())
        sup._otel_pid = 1
        sup._handle_otel_exit(1, 0, 'exit')
        self.assertEqual(sup._otel_failures, 0)

    def test_stop_is_idempotent_when_nothing_is_running(self):
        sup = self._sup()
        sup.stop_otel()  # must not raise
        self.assertIsNone(sup._otel_pid)


# ── Real SDK path ───────────────────────────────────────────────────────────
# Skipped wherever opentelemetry is not installed, which includes CI — CI
# deliberately does not install it, so that "fleetd works without the
# dependency" stays continuously verified rather than assumed. That leaves the
# real emitter otherwise untested, which is what this closes: run
# `pip install -r fleet-controller/fleetd/requirements-otel.txt` and it
# exercises a genuine TracerProvider with an in-memory span exporter.

try:
    import opentelemetry  # noqa: F401

    _HAVE_SDK = True
except ImportError:
    _HAVE_SDK = False


@unittest.skipUnless(_HAVE_SDK, 'opentelemetry SDK not installed')
class TestRealSdk(unittest.TestCase):
    def _emitter_with_memory_exporter(self):
        from opentelemetry.sdk.resources import Resource
        from opentelemetry.sdk.trace import TracerProvider
        from opentelemetry.sdk.trace.export import SimpleSpanProcessor
        from opentelemetry.sdk.trace.export.in_memory_span_exporter import (
            InMemorySpanExporter,
        )
        from opentelemetry import trace

        cfg = otel.ExporterConfig(span_grace_secs=0)
        emitter = otel.OtlpEmitter(cfg)
        exporter = InMemorySpanExporter()
        provider = TracerProvider(resource=Resource.create({'service.name': 'test'}))
        provider.add_span_processor(SimpleSpanProcessor(exporter))
        emitter._provider = provider
        emitter._trace = trace
        emitter._tracer = provider.get_tracer('test')
        emitter.available = True
        return emitter, exporter

    def test_a_derived_span_survives_the_sdk_round_trip(self):
        emitter, exporter = self._emitter_with_memory_exporter()
        span = otel.DerivedSpan(
            ticket='SDK-1', phase='IMPLEMENT', step='implement',
            start=NOW - timedelta(seconds=60), end=NOW, ok=True,
            attributes={'ticket.id': 'SDK-1', 'gen_ai.usage.input_tokens': 5},
            events=[('Bash', NOW - timedelta(seconds=30), {'gen_ai.tool.name': 'Bash'})],
        )
        emitter.emit(span)
        emitter.close_ticket('SDK-1', 'complete', NOW)
        finished = exporter.get_finished_spans()
        names = [s.name for s in finished]
        self.assertIn('invoke_agent implement.implement', names)
        self.assertIn('pipeline SDK-1', names)
        phase_span = next(s for s in finished if s.name.startswith('invoke_agent'))
        self.assertEqual(phase_span.attributes['gen_ai.usage.input_tokens'], 5)
        self.assertEqual(len(phase_span.events), 1)
        # The phase span must hang off the ticket's root span, not float alone.
        root = next(s for s in finished if s.name == 'pipeline SDK-1')
        self.assertEqual(phase_span.parent.span_id, root.context.span_id)

    def test_a_failed_phase_sets_an_error_status(self):
        from opentelemetry.trace import StatusCode

        emitter, exporter = self._emitter_with_memory_exporter()
        emitter.emit(otel.DerivedSpan(
            ticket='SDK-2', phase='VERIFY', step='verify',
            start=NOW - timedelta(seconds=10), end=NOW, ok=False,
            msg='FAIL criterion 2'))
        span = exporter.get_finished_spans()[0]
        self.assertEqual(span.status.status_code, StatusCode.ERROR)


def sup_backoff_max():
    from fleetd.supervisor import _OTEL_RESPAWN_BACKOFF
    return _OTEL_RESPAWN_BACKOFF[-1]


if __name__ == '__main__':
    unittest.main()
