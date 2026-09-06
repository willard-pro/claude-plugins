"""Agent Observer sidecar for the ticket-auto pipeline (openspec change agent-observer).

Tails the NDJSON (`--output-format stream-json`) stdout of phase-level workers
spawned under `FLEET_OBSERVER_ENABLE=true` and derives a normalized,
independent execution record from it — what a worker actually did, not what
it claimed to have done. Modeled directly on `otel.py`'s spawn/backoff/reap/
stop lifecycle (design.md D1): fleetd already supervises one optional,
non-authoritative sidecar, and this is architecturally the same object.

Three properties are load-bearing, and both are structural rather than
tested-in:

**Non-authoritative, under any configuration (design.md Goals).** No output
of this process can gate, fail, delay, or otherwise change a ticket's phase
progression. It can be crashed, killed, or fed malformed input at any time
and the pipeline it is watching is unaffected — the one place it could hurt
a ticket is a malformed `META|observer-finding` pipeline-log line, which is
why that writer (Inc 3) strips pipe characters and restricts `status` to
schema-valid values before ever touching the log fleetd's own classifiers
read.

**One fleet-wide process, one logical observer per live phase (D1).** Not one
process per spawned worker — this process discovers live phase workers by
globbing `{log_dir}/*-gen*.ndjson`, the same way `otel.py` discovers live
tickets by globbing `*-pipeline.log`. `spawn_worker` needs no new code path
for this; the only thing that changed is `_build_worker_cmd`'s output-format
value (Inc 1).

**Deterministic funnel, zero LLM cost (design.md Non-Goals).** Nothing in
this module calls a model. Findings (Inc 3, a later increment) are computed
from structured evidence — tool names, exit codes, contract comparisons —
never from matching prose.

Run standalone (a plain script — stdlib only at module level, so it needs no
package on sys.path):
    python3 fleet-controller/fleetd/observer.py --log-dir ./logs

Normally fleetd spawns and supervises it; see supervisor.py's observer
lifecycle (`maybe_spawn_observer` / `_handle_observer_exit` / `stop_observer`).
"""

from __future__ import annotations

import argparse
import glob
import json
import os
import re
import sys
import time
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path

# ── Configuration ───────────────────────────────────────────────────────────
# Same FLEET_* convention as every other knob in fleet-config.sh.

DEFAULT_POLL_SECS = 5
DEFAULT_GRACE_SECS = 30
DEFAULT_MAX_FIELD = 512
DEFAULT_LOG_RETENTION = 3

#: Fixed run-registry identifier fleetd supervises this process under. Not a
#: ticket id — the reap path branches on it precisely so observer exits are
#: never mistaken for a ticket worker dying (mirrors otel.py's SERVICE_ID).
SERVICE_ID = 'agent-observer'


def _env_int(name, default):
    try:
        return int(os.environ.get(name, '') or default)
    except (TypeError, ValueError):
        return default


@dataclass
class ObserverConfig:
    log_dir: str = './logs'
    poll_secs: int = DEFAULT_POLL_SECS
    grace_secs: int = DEFAULT_GRACE_SECS
    max_field: int = DEFAULT_MAX_FIELD
    log_retention: int = DEFAULT_LOG_RETENTION

    @classmethod
    def from_env(cls, log_dir=None):
        return cls(
            log_dir=log_dir or os.environ.get('FLEET_PIPELINE_LOG_DIR') or './logs',
            poll_secs=_env_int('FLEET_OBSERVER_POLL_SECS', DEFAULT_POLL_SECS),
            grace_secs=_env_int('FLEET_OBSERVER_GRACE_SECS', DEFAULT_GRACE_SECS),
            max_field=_env_int('FLEET_OBSERVER_MAX_FIELD', DEFAULT_MAX_FIELD),
            log_retention=_env_int(
                'FLEET_OBSERVER_LOG_RETENTION', DEFAULT_LOG_RETENTION),
        )

    def idle_timeout_secs(self):
        """How long a file may go silent, with no terminal frame ever seen,
        before the observer gives up on it (`observer_incomplete`).

        Not a separate env var — design.md's task 2.1 enumerates exactly four
        new `FLEET_OBSERVER_*` vars, and a mid-run crash is already rare
        enough that deriving this from `grace_secs` (which operators already
        tune) avoids growing the config surface for a case with no live
        caller demanding its own knob.
        """
        return max(self.grace_secs * 4, 60)


def observer_enabled():
    """Opt-in, not opt-out — see FLEET_OBSERVER_ENABLE's docstring in
    fleet-config.sh. A sidecar that started unasked would tail NDJSON nobody
    asked it to."""
    return os.environ.get('FLEET_OBSERVER_ENABLE', 'false').lower() == 'true'


# ── Filename discovery (design.md D1, D6) ───────────────────────────────────
# Phase-level spawns only ever get `.ndjson` (Inc 1); the slug the observer
# must split off `{tid}-{phase}` is the same finite set `dispatch-table.json`
# declares as `spawn.phase` values — enumerated here rather than derived
# dynamically, the same choice phase_dispatch.py's own LOOP_BEARING_PHASES
# already makes (design.md D12) for the same reason: this file must stay
# stdlib-only and importing the table loader is unnecessary complexity for a
# set that changes only when a new phase is added to the pipeline itself.
# Sorted longest-first so 'pr-review' (the one slug with its own hyphen) is
# tried before a shorter false match could split it wrong.
_KNOWN_PHASE_SLUGS = tuple(sorted(
    ('appraise', 'reproduce', 'exec', 'gate', 'implement', 'verify',
     'pr-review', 'maintenance'),
    key=len, reverse=True,
))

_GEN_SUFFIX_RE = re.compile(r'^(.+)-gen(\d+)\.ndjson$')


def _parse_ndjson_filename(path):
    """`{tid}-{phase}-gen{N}.ndjson` -> `(tid, PHASE, generation)`, or None.

    A ticket id may itself contain hyphens, so this cannot split on the first
    or last `-` — it matches against the known, finite phase-slug set instead.
    Any file this cannot parse (an unrelated `.ndjson`, or a naming scheme
    this observer predates) is silently skipped by the caller, not raised.
    """
    m = _GEN_SUFFIX_RE.match(os.path.basename(path))
    if not m:
        return None
    stem, generation = m.group(1), int(m.group(2))
    for slug in _KNOWN_PHASE_SLUGS:
        suffix = '-' + slug
        if stem.endswith(suffix) and len(stem) > len(suffix):
            return stem[: -len(suffix)], slug.upper(), generation
    return None


# ── Secret redaction (design.md Risk: secrets in tool_call/tool_result) ─────
# Applied at normalization time, not as a later pass — unfixable after the
# fact once written to events.jsonl.

_SECRET_PATTERNS = (
    re.compile(r'ghp_[A-Za-z0-9]{20,}'),
    re.compile(r'lin_api_[A-Za-z0-9]{20,}'),
    re.compile(r'Bearer\s+[A-Za-z0-9._-]+', re.IGNORECASE),
    re.compile(r'://[^/\s:@]+:[^/\s@]+@'),
)

_SECRET_ENV_RE = re.compile(r'(TOKEN|KEY|SECRET)$')


def _collect_env_secret_values(env=None):
    """Literal values of every `*_TOKEN`/`*_KEY`/`*_SECRET` env var.

    Longest-first so one secret value that happens to be a substring of
    another is not left partially redacted by an earlier, shorter match.
    """
    env = env if env is not None else os.environ
    values = {v for k, v in env.items() if v and _SECRET_ENV_RE.search(k)}
    return sorted(values, key=len, reverse=True)


def _redact(text, env_secret_values):
    if not text:
        return text
    for pattern in _SECRET_PATTERNS:
        text = pattern.sub('<redacted>', text)
    for value in env_secret_values:
        if value in text:
            text = text.replace(value, '<redacted>')
    return text


def _truncate(value, max_len):
    """Byte-cap any field before it reaches events.jsonl (FLEET_OBSERVER_MAX_FIELD).

    Structured, bounded metadata (a tool allowlist, an mcp_servers status
    list) is deliberately NOT run through this — Inc 3's UNEXPECTED_TOOL and
    DEGRADED_SESSION findings need those fields intact, and truncating an
    enumerable list is a false economy when the risk this guards against
    (a Read result embedding a whole file, a long shell command) lives in
    tool_call.input / tool_result.content / claim.raw_block, not there.
    """
    if value is None:
        return value
    text = value if isinstance(value, str) else json.dumps(value, default=str)
    if len(text) <= max_len:
        return text
    return text[:max_len] + f'...(+{len(text) - max_len}B truncated)'


def _iso(ts):
    return datetime.fromtimestamp(ts, tz=timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')


# ── Incremental file reading ─────────────────────────────────────────────────

class TailReader:
    """Byte-offset tail of an append-only file. Identical contract to
    `otel.py`'s reader of the same name: stops at the last complete line, so a
    partial line mid-write (fed one byte at a time, or interrupted by a
    SIGKILL) is simply deferred to the next poll rather than misread."""

    def __init__(self, path):
        self.path = path
        self.offset = 0

    def read_new_lines(self):
        try:
            size = os.path.getsize(self.path)
        except OSError:
            return []
        if size < self.offset:
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


# ── Frame -> event translation (design.md "six event kinds") ────────────────

_EXIT_CODE_RE = re.compile(r'^Exit code (\d+)$')

#: Matches lib/phase-result-parse.sh's _PR_OPEN_MARKER / _PR_CLOSE_MARKER
#: verbatim. This is a best-effort, independent capture for events.jsonl —
#: the authoritative `claimed_verdict` Inc 3's CLAIM_CONTRADICTION rule
#: anchors on (design.md D3) is the pipeline log's `META|phase-result|` line,
#: written separately by that bash script from the same captured text.
_PR_OPEN = '=== PHASE_RESULT ==='
_PR_CLOSE = '=== END PHASE_RESULT ==='
_VERDICT_RE = re.compile(r'^\s*VERDICT:\s*(\S+)', re.MULTILINE)


def _session_start_event(frame):
    return {
        'kind': 'session_start',
        'session_id': frame.get('session_id'),
        'model': frame.get('model'),
        'permission_mode': frame.get('permissionMode'),
        'cwd': frame.get('cwd'),
        'tools': frame.get('tools') or [],
        'mcp_servers': frame.get('mcp_servers') or [],
    }


def _content_items(frame, item_type):
    content = ((frame.get('message') or {}).get('content')) or []
    if not isinstance(content, list):
        return []
    return [c for c in content if isinstance(c, dict) and c.get('type') == item_type]


def _tool_call_events(frame, redact, max_field):
    parent = frame.get('parent_tool_use_id')
    events = []
    for item in _content_items(frame, 'tool_use'):
        raw_input = json.dumps(item.get('input') or {}, default=str)
        events.append({
            'kind': 'tool_call',
            'tool_use_id': item.get('id'),
            'name': item.get('name'),
            'input': _truncate(redact(raw_input), max_field),
            'parent_tool_use_id': parent,
        })
    return events


def _tool_result_text(raw_content):
    if isinstance(raw_content, list):
        return ''.join(
            block.get('text', '') for block in raw_content
            if isinstance(block, dict) and block.get('type') == 'text'
        )
    if isinstance(raw_content, str):
        return raw_content
    if raw_content is None:
        return ''
    return json.dumps(raw_content, default=str)


def _tool_result_events(frame, redact, max_field):
    parent = frame.get('parent_tool_use_id')
    events = []
    for item in _content_items(frame, 'tool_result'):
        text = _tool_result_text(item.get('content'))
        exit_match = _EXIT_CODE_RE.match(text.strip()) if text else None
        events.append({
            'kind': 'tool_result',
            'tool_use_id': item.get('tool_use_id'),
            'is_error': bool(item.get('is_error')),
            'content': _truncate(redact(text), max_field),
            # Nullable and text-parsed on purpose (design.md Risk): the CLI
            # exposes a tool's exit code only as the literal string
            # "Exit code N", undocumented and unstable — never a numeric
            # field. A fixture test pins this format so a CLI change that
            # breaks it fails loudly here rather than silently zeroing the
            # signal REPEATED_FAILURE (Inc 3) depends on.
            'exit_code': int(exit_match.group(1)) if exit_match else None,
            'parent_tool_use_id': parent,
        })
    return events


def _claim_event(frame, redact, max_field):
    text = frame.get('result')
    if not isinstance(text, str) or _PR_OPEN not in text:
        return None
    body = text.split(_PR_OPEN, 1)[1]
    if _PR_CLOSE in body:
        body = body.split(_PR_CLOSE, 1)[0]
    verdict_match = _VERDICT_RE.search(body)
    return {
        'kind': 'claim',
        'claimed_verdict': verdict_match.group(1) if verdict_match else None,
        'raw_block': _truncate(redact(body.strip()), max_field),
    }


def _session_end_event(frame):
    return {
        'kind': 'session_end',
        'session_id': frame.get('session_id'),
        'is_error': bool(frame.get('is_error')),
        'subtype': frame.get('subtype'),
        'stop_reason': frame.get('stop_reason'),
        'num_turns': frame.get('num_turns'),
        'total_cost_usd': frame.get('total_cost_usd'),
        'duration_ms': frame.get('duration_ms'),
        'permission_denials': frame.get('permission_denials') or [],
    }


class PhaseStreamTranslator:
    """Turns one phase worker's NDJSON lines into normalized event dicts.

    Stateful only in `finalized_at` (set the moment the terminal `result`
    frame is seen) — everything else is a pure per-line translation, so
    re-feeding the same lines to a fresh translator reproduces the same
    events, the same restart-safety property `otel.py`'s TicketTranslator
    documents for the same reason.

    Frame types with no case here (`rate_limit_event`, a `hook_response`
    trailing the terminal frame, an unrecognised future type) are silently
    ignored, never treated as `stream_error` — only a line that fails to
    parse as JSON at all is a stream error (fixtures/README.md's traps).
    """

    def __init__(self, tid, phase, generation, redact, max_field):
        self.tid = tid
        self.phase = phase
        self.generation = generation
        self._redact = redact
        self._max_field = max_field
        self.finalized_at = None

    def feed_line(self, line, now):
        line = line.strip()
        if not line:
            return []
        try:
            frame = json.loads(line)
        except (ValueError, TypeError):
            return [self._envelope(
                {'kind': 'stream_error',
                 'raw': _truncate(self._redact(line), self._max_field)}, now)]
        if not isinstance(frame, dict):
            return []

        ftype = frame.get('type')
        raw_events = []
        if ftype == 'system' and frame.get('subtype') == 'init':
            raw_events.append(_session_start_event(frame))
        elif ftype == 'assistant':
            raw_events.extend(
                _tool_call_events(frame, self._redact, self._max_field))
        elif ftype == 'user':
            raw_events.extend(
                _tool_result_events(frame, self._redact, self._max_field))
        elif ftype == 'result':
            claim = _claim_event(frame, self._redact, self._max_field)
            if claim:
                raw_events.append(claim)
            raw_events.append(_session_end_event(frame))
            self.finalized_at = now

        return [self._envelope(e, now) for e in raw_events]

    def _envelope(self, event, now):
        event['tid'] = self.tid
        event['phase'] = self.phase
        event['gen'] = self.generation
        event['observed_at'] = _iso(now)
        return event


# ── Per-file tracking and the observer loop ─────────────────────────────────

@dataclass
class TrackedStream:
    path: str
    tid: str
    phase: str
    generation: int
    reader: TailReader
    translator: PhaseStreamTranslator
    last_activity: float
    grace_start: float = None


class Observer:
    """The sidecar's main loop: discover live phase streams, tail each,
    translate, write `{tid}-{phase}-events.jsonl`, and release a stream once
    it has finished (grace-drained) or gone stale with no terminal frame."""

    def __init__(self, config):
        self.config = config
        self.streams = {}  # path -> TrackedStream
        # Paths already finished (released or timed out). The underlying
        # .ndjson file is fleetd's, not this process's to delete, so it stays
        # on disk (until the retention sweep ages it out) — without this set,
        # the very next discover() would re-glob a finished file, start a
        # fresh TailReader at offset 0, and re-emit every event a second time,
        # forever, once per poll cycle.
        self._released_paths = set()
        self._env_secret_values = _collect_env_secret_values()
        self.events_written = 0

    def _redact(self, text):
        return _redact(text, self._env_secret_values)

    def discover(self):
        # Prune released paths whose file is finally gone (the retention
        # sweep caught up), so this set does not grow for the life of the
        # daemon.
        self._released_paths = {p for p in self._released_paths
                                if os.path.exists(p)}
        pattern = os.path.join(self.config.log_dir, '*-gen*.ndjson')
        for path in sorted(glob.glob(pattern)):
            if path in self.streams or path in self._released_paths:
                continue
            parsed = _parse_ndjson_filename(path)
            if parsed is None:
                continue
            tid, phase, generation = parsed
            self.streams[path] = TrackedStream(
                path=path, tid=tid, phase=phase, generation=generation,
                reader=TailReader(path),
                translator=PhaseStreamTranslator(
                    tid, phase, generation, self._redact,
                    self.config.max_field),
                last_activity=time.time(),
            )

    def _events_path(self, ts):
        return Path(self.config.log_dir) / f'{ts.tid}-{ts.phase.lower()}-events.jsonl'

    def _exit_record_path(self, ts):
        # Ticket-scoped, never phase-slugged — _write_exit_record (supervisor.py)
        # has no phase parameter, so this is the one file name both a
        # ticket-level and a phase-level worker's exit record share.
        return Path(self.config.log_dir) / f'{ts.tid}-gen{ts.generation}-exit.json'

    def _write_events(self, ts, events):
        if not events:
            return
        try:
            with open(self._events_path(ts), 'a') as fh:
                for event in events:
                    fh.write(json.dumps(event) + '\n')
        except OSError:
            return
        self.events_written += len(events)

    def poll_once(self):
        """One pass: discover new streams, tail each, release finished ones.

        Returns the number of released (finished or timed-out) stream paths.
        """
        self.discover()
        now = time.time()
        released = []

        for path, ts in self.streams.items():
            lines = ts.reader.read_new_lines()
            if lines:
                ts.last_activity = now
            events = []
            for line in lines:
                events.extend(ts.translator.feed_line(line, now))
            self._write_events(ts, events)

            terminal_seen = (
                ts.translator.finalized_at is not None
                or self._exit_record_path(ts).is_file()
            )
            if terminal_seen:
                if ts.grace_start is None:
                    ts.grace_start = ts.translator.finalized_at or now
                if now >= ts.grace_start + self.config.grace_secs:
                    released.append(path)
            elif now - ts.last_activity > self.config.idle_timeout_secs():
                self._write_events(ts, [ts.translator._envelope(
                    {'kind': 'observer_incomplete',
                     'reason': 'idle timeout with no terminal frame'}, now)])
                released.append(path)

        for path in released:
            del self.streams[path]
            self._released_paths.add(path)
        return len(released)

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


def main(argv=None):
    parser = argparse.ArgumentParser(
        description='Agent Observer sidecar for the ticket-auto pipeline')
    parser.add_argument('--log-dir', default=None,
                        help='Pipeline log / worker-stdio directory '
                             '(default: $FLEET_PIPELINE_LOG_DIR, else ./logs)')
    parser.add_argument('--once', action='store_true',
                        help='Run a single poll and exit (for testing)')
    args = parser.parse_args(argv)

    config = ObserverConfig.from_env(args.log_dir)
    if not os.path.isdir(config.log_dir):
        print(f'agent-observer: log directory not found: {config.log_dir}',
              file=sys.stderr)
        return 2

    observer = Observer(config)
    print(f'agent-observer: watching {config.log_dir} for *-gen*.ndjson',
          file=sys.stderr)
    observer.run(max_cycles=1 if args.once else None)
    return 0


if __name__ == '__main__':
    sys.exit(main())
