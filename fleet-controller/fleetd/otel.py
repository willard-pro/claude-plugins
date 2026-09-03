"""OpenTelemetry exporter for the ticket-auto pipeline.

Derives OTel GenAI-convention spans by tailing the pipeline log
(`ISO|PHASE|STEP|STATUS|MSG`) and the agent-activity log
(`ISO|PHASE|TOOL_NAME`), and ships them to an OTLP collector.

Two properties are load-bearing, and both are structural rather than tested-in:

**Derived, never hand-instrumented (D5).** No phase skill, hook, or fleetd
module emits a span at the point of action. A log `printf` and an OTel SDK call
placed side by side will eventually disagree — a new phase gets one and not the
other — and then there are two authorities about what happened. There is one
writer of truth (the log) and one reader that translates it.

**Downstream, never authoritative (D5).** `detect-resume.sh`, the gate scripts,
`fleet-detect.sh` and `dashboard.py --fleet` all read the pipeline log directly.
Nothing in the pipeline waits on this process, reads its output, or notices its
absence. Stopping the exporter or unplugging the collector costs traces and
nothing else.

**The SDK dependency is quarantined here (D11).** `opentelemetry-sdk` is the
repository's first third-party Python dependency. `supervisor.py` and `store.py`
remain pure-stdlib and must stay that way. The import below is lazy and inside
the exporter process, so fleetd starts, supervises, dispatches and detects
normally when the SDK is absent — it says so once and carries on. Everything
above the emitter in this file is pure stdlib, which is also what makes it
testable in an environment (like CI) that has no SDK installed.

Run standalone (a plain script — it imports nothing but the standard library
at module level, so it needs no package on sys.path):
    python3 fleet-controller/fleetd/otel.py --log-dir ./logs

Normally fleetd spawns and supervises it; see supervisor.py's exporter
lifecycle.
"""

from __future__ import annotations

import argparse
import glob
import json
import os
import re
import sys
import time
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path

# ── Configuration ───────────────────────────────────────────────────────────
# Same FLEET_* convention as every other knob in fleet-config.sh.

DEFAULT_ENDPOINT = 'http://localhost:4318'
DEFAULT_SERVICE_NAME = 'ticket-auto-pipeline'
DEFAULT_POLL_SECS = 5
DEFAULT_MAX_TOOL_EVENTS = 100
#: How long a completed span waits before it is emitted, so enrichment written
#: *after* the phase terminal can still attach to it. `META|tokens` is the
#: reason this exists: the SubagentStop hook writes it a moment after the
#: router writes the terminal line, so a span emitted the instant its bracket
#: closes always loses its token counts. 30s is generous against a hook that
#: normally lands within one poll interval.
DEFAULT_SPAN_GRACE_SECS = 30

#: Fixed run-registry identifier fleetd supervises this process under. Not a
#: ticket id — the reap path branches on it precisely so exporter exits are not
#: mistaken for a ticket worker dying.
SERVICE_ID = 'otel-exporter'


def _env_int(name, default):
    try:
        return int(os.environ.get(name, '') or default)
    except (TypeError, ValueError):
        return default


@dataclass
class ExporterConfig:
    log_dir: str = './logs'
    endpoint: str = DEFAULT_ENDPOINT
    service_name: str = DEFAULT_SERVICE_NAME
    poll_secs: int = DEFAULT_POLL_SECS
    max_tool_events: int = DEFAULT_MAX_TOOL_EVENTS
    span_grace_secs: int = DEFAULT_SPAN_GRACE_SECS

    @classmethod
    def from_env(cls, log_dir=None):
        return cls(
            log_dir=log_dir or os.environ.get('FLEET_PIPELINE_LOG_DIR') or './logs',
            endpoint=os.environ.get('FLEET_OTEL_ENDPOINT') or DEFAULT_ENDPOINT,
            service_name=os.environ.get('FLEET_OTEL_SERVICE_NAME') or DEFAULT_SERVICE_NAME,
            poll_secs=_env_int('FLEET_OTEL_POLL_SECS', DEFAULT_POLL_SECS),
            max_tool_events=_env_int('FLEET_OTEL_MAX_TOOL_EVENTS', DEFAULT_MAX_TOOL_EVENTS),
            span_grace_secs=_env_int('FLEET_OTEL_SPAN_GRACE_SECS', DEFAULT_SPAN_GRACE_SECS),
        )


def exporter_enabled():
    """Opt-in, not opt-out.

    A telemetry exporter that starts by default would have every fleetd install
    attempting OTLP connections to a collector nobody configured.
    """
    return os.environ.get('FLEET_OTEL_ENABLE', 'false').lower() == 'true'


# ── Log parsing (pure stdlib) ───────────────────────────────────────────────

LINE_RE = re.compile(r'^([^|]*)\|([^|]*)\|([^|]*)\|([^|]*)\|(.*)$')
ACTIVITY_RE = re.compile(r'^([^|]*)\|([^|]*)\|(.*)$')
#: `META|tokens|info|IMPLEMENT:1234/567/890|elapsed_ms=12345`
TOKENS_RE = re.compile(r'^([A-Z-]+):(\d+)/(\d+)/(\d+)(?:\|elapsed_ms=(\d+))?')

TERMINAL_STATUSES = ('done', 'fail', 'skip')


def parse_iso(value):
    try:
        return datetime.strptime(value.strip(), '%Y-%m-%dT%H:%M:%SZ').replace(
            tzinfo=timezone.utc)
    except (ValueError, AttributeError):
        return None


def _nanos(ts):
    return int(ts.timestamp() * 1_000_000_000)


@dataclass
class DerivedSpan:
    """One completed phase/step bracket, ready to become an OTel span."""

    ticket: str
    phase: str
    step: str
    start: datetime
    end: datetime
    ok: bool
    msg: str = ''
    attributes: dict = field(default_factory=dict)
    events: list = field(default_factory=list)

    @property
    def name(self):
        # GenAI convention: `<operation> <target>`. The step is the agent-ish
        # unit of work here, so it is the target.
        return f'invoke_agent {self.phase.lower()}.{self.step}'

    def duration_secs(self):
        return (self.end - self.start).total_seconds()


class TicketTranslator:
    """Turns one ticket's pipeline-log lines into completed spans.

    Deliberately stateful and incremental: the exporter tails a live log, so
    lines arrive one at a time and a span is only complete once its terminal
    line shows up. Feeding the same lines in order to a fresh translator
    reproduces the same spans, which is what makes a restart harmless.
    """

    def __init__(self, ticket):
        self.ticket = ticket
        self.open_brackets = {}  # (phase, step) -> (start_ts, msg)
        self.phase_models = {}   # phase -> model name
        self.pending_tokens = {}  # phase -> dict of usage attributes
        self.first_ts = None
        self.outcome = None
        self.outcome_ts = None
        self.gate_stops = []

    def feed(self, line):
        """Consume one raw log line. Returns a list of newly completed spans."""
        m = LINE_RE.match(line.rstrip('\n'))
        if not m:
            return []
        iso, phase, step, status, msg = (g.strip() for g in m.groups())
        ts = parse_iso(iso)
        if ts is None:
            return []
        if self.first_ts is None:
            self.first_ts = ts

        if phase == 'META':
            return self._feed_meta(step, status, msg, ts)

        key = (phase, step)
        if status in ('waiting', 'start'):
            # A second open for the same key replaces the first. The log's own
            # bracket-uniqueness guarantee says this should not happen; when it
            # does, the newer bracket is the live one — the same rule
            # fleet-detect.sh's position-scoped matching applies.
            self.open_brackets[key] = (ts, msg)
            return []

        if status in TERMINAL_STATUSES:
            opened = self.open_brackets.pop(key, None)
            start_ts = opened[0] if opened else ts
            span = DerivedSpan(
                ticket=self.ticket,
                phase=phase,
                step=step,
                start=start_ts,
                end=ts,
                ok=(status != 'fail'),
                msg=msg,
                attributes=self._span_attributes(phase, step, status, opened is None),
            )
            return [span]

        return []

    def _feed_meta(self, step, status, msg, ts):
        if step == 'model':
            try:
                payload = json.loads(msg)
                if payload.get('phase') and payload.get('model'):
                    self.phase_models[payload['phase']] = payload['model']
            except (ValueError, TypeError):
                pass
        elif step == 'tokens':
            m = TOKENS_RE.match(msg)
            if m:
                phase, inp, out, cache, elapsed = m.groups()
                usage = {
                    'gen_ai.usage.input_tokens': int(inp),
                    'gen_ai.usage.output_tokens': int(out),
                    'pipeline.tokens.cache': int(cache),
                }
                if elapsed:
                    usage['pipeline.elapsed_ms'] = int(elapsed)
                self.pending_tokens[phase] = usage
        elif step == 'gate-stop':
            self.gate_stops.append(msg)
        elif step == 'outcome':
            self.outcome = msg
            self.outcome_ts = ts
        return []

    def take_tokens(self, phase):
        """Consume token usage recorded for `phase` since its span closed.

        Called at flush time rather than at span-completion time, because
        `META|tokens|info|` is written by the SubagentStop hook *after* the
        router writes the phase's terminal line.
        """
        return self.pending_tokens.pop(phase, None)

    def _span_attributes(self, phase, step, status, orphaned):
        attrs = {
            'gen_ai.system': 'anthropic',
            'gen_ai.operation.name': 'invoke_agent',
            'gen_ai.agent.name': f'{phase.lower()}.{step}',
            'ticket.id': self.ticket,
            'pipeline.phase': phase,
            'pipeline.step': step,
            'pipeline.status': status,
        }
        model = self.phase_models.get(phase)
        if model:
            attrs['gen_ai.request.model'] = model
        usage = self.pending_tokens.pop(phase, None)
        if usage:
            attrs.update(usage)
        # No token line yet is the normal case, not an error — the hook writes
        # it just after the terminal. take_tokens() picks it up at flush time.
        if orphaned:
            # A terminal with no opening bracket in this translator's view:
            # either the exporter started mid-run, or the log genuinely lost
            # its `waiting` line. Recorded rather than silently back-dated to
            # the terminal's own timestamp with no explanation.
            attrs['pipeline.bracket_incomplete'] = True
        return attrs


# ── Activity log (second derivation input, task 8.3) ────────────────────────

class ActivityIndex:
    """The agent's own tool calls, queryable by time window.

    Not emitted as spans of their own: one span per tool call would swamp a
    trace whose useful unit is the phase. They attach to the phase span that
    contains them — a count attribute always, and the first N as span events,
    bounded by FLEET_OTEL_MAX_TOOL_EVENTS. The count is the part that answers
    "was the agent doing anything in there", which is exactly what a phase
    span's duration alone cannot say.
    """

    def __init__(self, max_events=DEFAULT_MAX_TOOL_EVENTS):
        self.max_events = max_events
        self.entries = {}  # ticket -> list of (ts, phase, tool)

    def feed(self, ticket, line):
        m = ACTIVITY_RE.match(line.rstrip('\n'))
        if not m:
            return
        iso, phase, tool = (g.strip() for g in m.groups())
        ts = parse_iso(iso)
        if ts is None:
            return
        self.entries.setdefault(ticket, []).append((ts, phase, tool))

    def decorate(self, span):
        """Attach tool-call count and bounded events to a completed span."""
        rows = self.entries.get(span.ticket)
        if not rows:
            return span
        window = [r for r in rows if span.start <= r[0] <= span.end]
        if not window:
            return span
        span.attributes['pipeline.tool_calls'] = len(window)
        for ts, _phase, tool in window[: self.max_events]:
            span.events.append((tool or 'unknown', ts, {'gen_ai.tool.name': tool}))
        if len(window) > self.max_events:
            span.attributes['pipeline.tool_calls_truncated'] = True
        return span

    def prune(self, ticket, before):
        """Drop entries older than a completed span so memory stays bounded."""
        rows = self.entries.get(ticket)
        if rows:
            self.entries[ticket] = [r for r in rows if r[0] >= before]


# ── Incremental file reading ────────────────────────────────────────────────

class TailReader:
    """Byte-offset tail of an append-only log.

    Stops at the last complete line. An agent is appending while this reads;
    a half-written line consumed now would be recorded permanently wrong,
    and an append-only log never corrects it. Same rule as the state store's
    ingester, for the same reason.
    """

    def __init__(self, path):
        self.path = path
        self.offset = 0

    def read_new_lines(self):
        try:
            size = os.path.getsize(self.path)
        except OSError:
            return []
        if size < self.offset:
            # Truncated or rotated underneath us — start over rather than
            # reading from a meaningless offset into different content.
            self.offset = 0
        if size == self.offset:
            return []
        try:
            with open(self.path, 'rb') as fh:
                fh.seek(self.offset)
                chunk = fh.read(size - self.offset)
        except OSError:
            return []
        cut = chunk.rfind(b'\n')
        if cut == -1:
            return []
        self.offset += cut + 1
        text = chunk[:cut].decode('utf-8', errors='replace')
        return [ln for ln in text.split('\n') if ln.strip()]


# ── OTLP emission (the only part that needs the SDK) ────────────────────────

class OtlpEmitter:
    """Wraps the OTel SDK. Import is lazy; absence is not an error.

    `available` is False when the SDK is not installed, and every method is a
    no-op. That is what keeps D11's promise: fleetd runs identically without
    the dependency, and this file is importable and testable without it.
    """

    def __init__(self, config, stderr=sys.stderr):
        self.config = config
        self.stderr = stderr
        self.available = False
        self._tracer = None
        self._provider = None
        self._roots = {}  # ticket -> (span, context)
        self._trace = None

    def start(self):
        try:
            from opentelemetry import trace
            from opentelemetry.sdk.resources import Resource
            from opentelemetry.sdk.trace import TracerProvider
            from opentelemetry.sdk.trace.export import BatchSpanProcessor
            from opentelemetry.exporter.otlp.proto.http.trace_exporter import (
                OTLPSpanExporter,
            )
        except ImportError as exc:
            print(
                f'otel-exporter: opentelemetry SDK unavailable ({exc}) — '
                f'no spans will be emitted. Install opentelemetry-sdk and '
                f'opentelemetry-exporter-otlp-proto-http to enable.',
                file=self.stderr,
            )
            return False

        resource = Resource.create({'service.name': self.config.service_name})
        provider = TracerProvider(resource=resource)
        provider.add_span_processor(
            BatchSpanProcessor(
                OTLPSpanExporter(endpoint=f'{self.config.endpoint}/v1/traces')
            )
        )
        self._provider = provider
        self._trace = trace
        self._tracer = provider.get_tracer('fleetd.otel')
        self.available = True
        return True

    def _root_context(self, ticket, start_ts):
        """One root span per ticket, parenting every phase span under it.

        Created on first sight and left open until the ticket's `META|outcome`.
        A trace per ticket is the unit an operator actually asks about — "what
        happened to CRE-123" — rather than a trace per phase, which would
        scatter one ticket across a dozen unrelated traces.
        """
        if ticket in self._roots:
            return self._roots[ticket][1]
        root = self._tracer.start_span(
            name=f'pipeline {ticket}',
            start_time=_nanos(start_ts),
            attributes={
                'ticket.id': ticket,
                'gen_ai.system': 'anthropic',
                'gen_ai.operation.name': 'invoke_agent',
            },
        )
        ctx = self._trace.set_span_in_context(root)
        self._roots[ticket] = (root, ctx)
        return ctx

    def emit(self, span):
        if not self.available:
            return
        ctx = self._root_context(span.ticket, span.start)
        otel_span = self._tracer.start_span(
            name=span.name,
            context=ctx,
            start_time=_nanos(span.start),
            attributes=span.attributes,
        )
        for name, ts, attrs in span.events:
            otel_span.add_event(name, attributes=attrs, timestamp=_nanos(ts))
        if not span.ok:
            from opentelemetry.trace import Status, StatusCode

            otel_span.set_status(Status(StatusCode.ERROR, span.msg[:200]))
        otel_span.end(end_time=_nanos(span.end))

    def close_ticket(self, ticket, outcome, end_ts):
        if not self.available:
            return
        entry = self._roots.pop(ticket, None)
        if entry is None:
            return
        root, _ctx = entry
        root.set_attribute('pipeline.outcome', outcome)
        if outcome and outcome != 'complete':
            from opentelemetry.trace import Status, StatusCode

            root.set_status(Status(StatusCode.ERROR, outcome[:200]))
        root.end(end_time=_nanos(end_ts))

    def shutdown(self):
        # End any still-open root spans so a clean stop does not strand
        # traces mid-flight, then flush the batch processor.
        for ticket, (root, _ctx) in list(self._roots.items()):
            try:
                root.set_attribute('pipeline.outcome', 'exporter-stopped')
                root.end()
            except Exception:
                pass
        self._roots.clear()
        if self._provider is not None:
            try:
                self._provider.shutdown()
            except Exception:
                pass


# ── The exporter loop ───────────────────────────────────────────────────────

class Exporter:
    def __init__(self, config, emitter=None):
        self.config = config
        self.emitter = emitter if emitter is not None else OtlpEmitter(config)
        self.translators = {}
        self.pipeline_readers = {}
        self.activity_readers = {}
        self.activity = ActivityIndex(config.max_tool_events)
        self.pending = []  # [(span, translator)] awaiting the grace window
        self.spans_emitted = 0

    def _ticket_of(self, path, suffix):
        return os.path.basename(path)[: -len(suffix)]

    def poll_once(self):
        """One pass over every log in the directory. Returns spans emitted."""
        emitted = 0

        # Activity first: a span is decorated with the tool calls inside it, so
        # those calls must already be indexed when the span completes.
        for path in sorted(glob.glob(os.path.join(self.config.log_dir, '*-activity.log'))):
            ticket = self._ticket_of(path, '-activity.log')
            reader = self.activity_readers.setdefault(path, TailReader(path))
            for line in reader.read_new_lines():
                self.activity.feed(ticket, line)

        for path in sorted(glob.glob(os.path.join(self.config.log_dir, '*-pipeline.log'))):
            ticket = self._ticket_of(path, '-pipeline.log')
            if not ticket:
                continue
            reader = self.pipeline_readers.setdefault(path, TailReader(path))
            translator = self.translators.setdefault(ticket, TicketTranslator(ticket))
            for line in reader.read_new_lines():
                for span in translator.feed(line):
                    self.pending.append((span, translator))

            if translator.outcome is not None:
                # The ticket is finished, so nothing more can arrive to enrich
                # its spans: flush them immediately rather than making the root
                # span wait out a grace window for enrichment that will never
                # come.
                emitted += self._flush(force_ticket=ticket)
                self.emitter.close_ticket(
                    ticket, translator.outcome, translator.outcome_ts)
                # Keep the reader (the log may still gain trailing lines) but
                # drop the translator so a re-run of the same ticket id starts
                # from a clean bracket state.
                self.translators.pop(ticket, None)

        emitted += self._flush()
        self.spans_emitted += emitted
        return emitted

    def _flush(self, force_ticket=None, now=None):
        """Emit pending spans whose grace window has elapsed.

        `force_ticket` flushes one ticket's spans regardless of age, used when
        the ticket reaches its outcome.
        """
        now = now or datetime.now(timezone.utc)
        grace = self.config.span_grace_secs
        still_pending = []
        emitted = 0
        for span, translator in self.pending:
            ready = (
                force_ticket is not None and span.ticket == force_ticket
            ) or (now - span.end).total_seconds() >= grace
            if not ready:
                still_pending.append((span, translator))
                continue
            usage = translator.take_tokens(span.phase)
            if usage:
                span.attributes.update(usage)
            self.activity.decorate(span)
            self.emitter.emit(span)
            self.activity.prune(span.ticket, span.end)
            emitted += 1
        self.pending = still_pending
        return emitted

    def run(self, max_cycles=None):
        cycles = 0
        try:
            while max_cycles is None or cycles < max_cycles:
                self.poll_once()
                cycles += 1
                if max_cycles is None or cycles < max_cycles:
                    time.sleep(self.config.poll_secs)
        except KeyboardInterrupt:
            pass
        finally:
            # Buffered spans are real completed work — emit them rather than
            # dropping them because the process is stopping.
            self._flush(now=datetime.max.replace(tzinfo=timezone.utc))
            self.emitter.shutdown()


def main(argv=None):
    parser = argparse.ArgumentParser(
        description='OTel exporter for the ticket-auto pipeline')
    parser.add_argument('--log-dir', default=None,
                        help='Pipeline log directory (default: $FLEET_PIPELINE_LOG_DIR, else ./logs)')
    parser.add_argument('--once', action='store_true',
                        help='Run a single poll and exit (for testing)')
    args = parser.parse_args(argv)

    config = ExporterConfig.from_env(args.log_dir)
    if not os.path.isdir(config.log_dir):
        print(f'otel-exporter: log directory not found: {config.log_dir}',
              file=sys.stderr)
        return 2

    emitter = OtlpEmitter(config)
    emitter.start()  # absence of the SDK is reported, not fatal
    exporter = Exporter(config, emitter)
    print(
        f'otel-exporter: watching {config.log_dir} → {config.endpoint} '
        f'(sdk={"up" if emitter.available else "absent"})',
        file=sys.stderr,
    )
    exporter.run(max_cycles=1 if args.once else None)
    return 0


if __name__ == '__main__':
    sys.exit(main())
