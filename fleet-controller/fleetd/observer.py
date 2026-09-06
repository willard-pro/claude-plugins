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
import hashlib
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


def _env_float(name, default):
    try:
        return float(os.environ.get(name, '') or default)
    except (TypeError, ValueError):
        return default


DEFAULT_COST_WARN_USD = 2.00
DEFAULT_LONG_TOOL_SECS = 120


@dataclass
class ObserverConfig:
    log_dir: str = './logs'
    poll_secs: int = DEFAULT_POLL_SECS
    grace_secs: int = DEFAULT_GRACE_SECS
    max_field: int = DEFAULT_MAX_FIELD
    log_retention: int = DEFAULT_LOG_RETENTION
    cost_warn_usd: float = DEFAULT_COST_WARN_USD
    long_tool_secs: int = DEFAULT_LONG_TOOL_SECS

    @classmethod
    def from_env(cls, log_dir=None):
        return cls(
            log_dir=log_dir or os.environ.get('FLEET_PIPELINE_LOG_DIR') or './logs',
            poll_secs=_env_int('FLEET_OBSERVER_POLL_SECS', DEFAULT_POLL_SECS),
            grace_secs=_env_int('FLEET_OBSERVER_GRACE_SECS', DEFAULT_GRACE_SECS),
            max_field=_env_int('FLEET_OBSERVER_MAX_FIELD', DEFAULT_MAX_FIELD),
            log_retention=_env_int(
                'FLEET_OBSERVER_LOG_RETENTION', DEFAULT_LOG_RETENTION),
            cost_warn_usd=_env_float(
                'FLEET_OBSERVER_COST_WARN_USD', DEFAULT_COST_WARN_USD),
            long_tool_secs=_env_int(
                'FLEET_OBSERVER_LONG_TOOL_SECS', DEFAULT_LONG_TOOL_SECS),
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


#: Tools whose file-path argument SCOPE_VIOLATION (Inc 3) must read back
#: reliably. Extracted as its own untruncated field at translation time
#: rather than re-parsed out of `input` later — `input`'s JSON can be cut
#: mid-string by `_truncate` (a Write's `content` value routinely exceeds
#: `FLEET_OBSERVER_MAX_FIELD`), which would silently break a naive
#: `json.loads(event['input'])` the instant a call's payload got truncated.
#: Paths are short, so this field is never itself truncated.
_PATH_BEARING_TOOLS = frozenset({'Write', 'Edit', 'Read'})


def _tool_call_events(frame, redact, max_field):
    parent = frame.get('parent_tool_use_id')
    events = []
    for item in _content_items(frame, 'tool_use'):
        name = item.get('name')
        raw_input_obj = item.get('input') or {}
        raw_input = json.dumps(raw_input_obj, default=str)
        event = {
            'kind': 'tool_call',
            'tool_use_id': item.get('id'),
            'name': name,
            'input': _truncate(redact(raw_input), max_field),
            'parent_tool_use_id': parent,
        }
        if name in _PATH_BEARING_TOOLS and isinstance(raw_input_obj, dict):
            path = raw_input_obj.get('file_path') or raw_input_obj.get('path')
            if path:
                event['path'] = str(path)
        events.append(event)
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


#: Rough order-of-magnitude USD-per-token rates for RUNAWAY_COST's running
#: estimate (Inc 3) — NOT the same source as `total_cost_usd`, which the API
#: only reports on the terminal `result` frame, too late to catch a phase
#: still burning tokens mid-run. A blended, deliberately conservative rate
#: rather than a precise per-model table that would need updating every
#: pricing change: this rule's job is "is this phase burning much more than
#: usual", not "what will the invoice say".
_EST_INPUT_USD_PER_TOKEN = 3.0 / 1_000_000
_EST_OUTPUT_USD_PER_TOKEN = 15.0 / 1_000_000
_EST_CACHE_READ_USD_PER_TOKEN = 0.30 / 1_000_000


def _estimate_frame_cost(usage):
    if not isinstance(usage, dict):
        return 0.0
    return (
        (usage.get('input_tokens') or 0) * _EST_INPUT_USD_PER_TOKEN
        + (usage.get('cache_creation_input_tokens') or 0) * _EST_INPUT_USD_PER_TOKEN
        + (usage.get('output_tokens') or 0) * _EST_OUTPUT_USD_PER_TOKEN
        + (usage.get('cache_read_input_tokens') or 0) * _EST_CACHE_READ_USD_PER_TOKEN
    )


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
        # RUNAWAY_COST (Inc 3) running total — updated whenever an assistant
        # frame carries a `usage` dict, independent of whether that frame
        # also produces a tool_call event (a pure-text turn has no tool_use
        # content but still spends tokens).
        self.estimated_cost_usd = 0.0

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
            usage = (frame.get('message') or {}).get('usage')
            if usage:
                self.estimated_cost_usd += _estimate_frame_cost(usage)
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


# ── Deterministic rules (agent-observer Inc 3, design.md Non-Goals: zero LLM
# cost) ──────────────────────────────────────────────────────────────────────
# Every rule below is computed from structured evidence — tool names, exit
# codes, contract comparisons — never from matching prose. A rule returns a
# finding dict (or a list of them) with no `count`/`first_seen`/`last_seen`
# fields; `_merge_findings` (below) adds those when writing to disk.

_PIPELINE_LINE_RE = re.compile(r'^([^|]*)\|([^|]*)\|([^|]*)\|([^|]*)\|(.*)$')


def _read_contract(log_dir, tid, phase):
    path = Path(log_dir) / f'{tid}-{phase.lower()}-contract.json'
    try:
        return json.loads(path.read_text())
    except (OSError, ValueError, TypeError):
        return None


def _read_pipeline_log_tail(log_dir, tid):
    path = Path(log_dir) / f'{tid}-pipeline.log'
    try:
        return path.read_text().splitlines()
    except OSError:
        return []


def _last_run_id(log_lines):
    """The most recent `META|run-id|info|{json}` line's `run_id`, or None."""
    run_id = None
    for line in log_lines:
        match = _PIPELINE_LINE_RE.match(line.rstrip('\n'))
        if not match:
            continue
        _iso, phase, step, _status, msg = match.groups()
        if phase == 'META' and step == 'run-id':
            try:
                payload = json.loads(msg)
            except (ValueError, TypeError):
                continue
            run_id = payload.get('run_id') or run_id
    return run_id


def _last_phase_result_for(log_lines, phase):
    """The most recent `META|phase-result` payload whose own `phase` field
    matches `phase` — the authoritative `claimed_verdict` CLAIM_CONTRADICTION
    anchors on (design.md D3), a separate bash-written artifact from this
    observer's own best-effort `claim` event."""
    result = None
    for line in log_lines:
        match = _PIPELINE_LINE_RE.match(line.rstrip('\n'))
        if not match:
            continue
        _iso, log_phase, step, _status, msg = match.groups()
        if log_phase == 'META' and step == 'phase-result':
            try:
                payload = json.loads(msg)
            except (ValueError, TypeError):
                continue
            if payload.get('phase') == phase:
                result = payload
    return result


def _fingerprint(finding_type, run_id, phase, gen, evidence_key):
    raw = f'{finding_type}|{run_id or ""}|{phase}|{gen}|{evidence_key}'
    return hashlib.sha256(raw.encode('utf-8')).hexdigest()


def _pair_tool_events(events):
    """(tool_call, tool_result) pairs joined on `tool_use_id`, call order."""
    calls = {}
    pairs = []
    for event in events:
        kind = event.get('kind')
        tool_use_id = event.get('tool_use_id')
        if not tool_use_id:
            continue
        if kind == 'tool_call':
            calls[tool_use_id] = event
        elif kind == 'tool_result' and tool_use_id in calls:
            pairs.append((calls.pop(tool_use_id), event))
    return pairs


def _command_matches(text, predicates):
    if not text:
        return False
    for substring in predicates.get('command_substrings') or []:
        if substring and substring in text:
            return True
    return False


def _tool_matches_claim_predicate(call_event, predicates):
    name = call_event.get('name') or ''
    for prefix in predicates.get('tool_name_prefixes') or []:
        if name.startswith(prefix):
            return True
    return _command_matches(call_event.get('input') or '', predicates)


def rule_claim_contradiction(events, contract, log_lines, tid, phase, gen):
    """design.md D3: `claimed_verdict` (from `META|phase-result`, never
    prose) is in the phase's passing set, but the last observed
    claim-predicate-matching tool run failed and no later passing run of the
    same class follows. Disabled (returns None) whenever the phase has no
    verdict vocabulary, or the phase-result claim itself isn't a clean
    `parse_status: ok` pass — an UNKNOWN/invalid claim isn't a claim to
    contradict."""
    if contract is None:
        return None
    passing = set((contract.get('success_criteria') or {}).get('claimed_verdict_in') or [])
    if not passing:
        return None
    claim = _last_phase_result_for(log_lines, phase)
    if not claim or claim.get('parse_status') != 'ok':
        return None
    verdict = (claim.get('claimed_verdict') or '').upper()
    if verdict not in passing:
        return None

    predicates = contract.get('claim_predicates') or {}
    last_passed = None
    for call, result in _pair_tool_events(events):
        if _tool_matches_claim_predicate(call, predicates):
            last_passed = not result.get('is_error')
    if last_passed is False:
        run_id = _last_run_id(log_lines)
        return {
            'type': 'CLAIM_CONTRADICTION',
            'severity': 'HIGH',
            'tid': tid, 'phase': phase, 'gen': gen,
            'fingerprint': _fingerprint('CLAIM_CONTRADICTION', run_id, phase, gen,
                                        f'{verdict}:last-test-class-run-failed'),
            'evidence': {'claimed_verdict': verdict, 'last_test_class_run': 'failed'},
        }
    return None


def rule_repeated_failure(events, log_lines, tid, phase, gen, threshold=3):
    """The same (tool, normalized command) failing `threshold`+ times."""
    run_id = _last_run_id(log_lines)
    counts = {}
    for call, result in _pair_tool_events(events):
        if not result.get('is_error'):
            continue
        key = (call.get('name'), call.get('input'))
        counts[key] = counts.get(key, 0) + 1
    findings = []
    for (name, command), count in counts.items():
        if count < threshold:
            continue
        findings.append({
            'type': 'REPEATED_FAILURE',
            'severity': 'WARN',
            'tid': tid, 'phase': phase, 'gen': gen,
            'fingerprint': _fingerprint('REPEATED_FAILURE', run_id, phase, gen,
                                        f'{name}:{command}'),
            'evidence': {'tool': name, 'command': command, 'count': count},
        })
    return findings


def rule_scope_violation(events, contract, log_lines, tid, phase, gen):
    """A Write/Edit outside every resolved `allowed_paths` prefix. Disabled
    (returns []) whenever the contract couldn't resolve `allowed_paths` —
    design.md D4: a wrong default here produces confident false findings,
    the fastest way to get the whole subsystem ignored."""
    if contract is None:
        return []
    allowed = contract.get('allowed_paths')
    if not allowed:
        return []
    run_id = _last_run_id(log_lines)
    findings = []
    seen = set()
    for event in events:
        if event.get('kind') != 'tool_call' or event.get('name') not in ('Write', 'Edit'):
            continue
        path = event.get('path')
        if not path or path in seen:
            continue
        if any(path == root or path.startswith(root.rstrip('/') + '/') for root in allowed):
            continue
        seen.add(path)
        findings.append({
            'type': 'SCOPE_VIOLATION',
            'severity': 'HIGH',
            'tid': tid, 'phase': phase, 'gen': gen,
            'fingerprint': _fingerprint('SCOPE_VIOLATION', run_id, phase, gen, path),
            'evidence': {'tool': event.get('name'), 'path': path, 'allowed_paths': allowed},
        })
    return findings


def rule_unexpected_tool(events, contract, log_lines, tid, phase, gen):
    """A tool_call whose name is absent from the contract's `allowed_tools`.
    Disabled (returns []) when `allowed_tools` is None — no known allowlist
    means no known violation, never "allow nothing"."""
    if contract is None:
        return []
    allowed_tools = contract.get('allowed_tools')
    if allowed_tools is None:
        return []
    allowed_set = set(allowed_tools)
    run_id = _last_run_id(log_lines)
    findings = []
    seen = set()
    for event in events:
        if event.get('kind') != 'tool_call':
            continue
        name = event.get('name')
        if not name or name in allowed_set or name in seen:
            continue
        seen.add(name)
        findings.append({
            'type': 'UNEXPECTED_TOOL',
            'severity': 'HIGH',
            'tid': tid, 'phase': phase, 'gen': gen,
            'fingerprint': _fingerprint('UNEXPECTED_TOOL', run_id, phase, gen, name),
            'evidence': {'tool': name, 'allowed_tools': allowed_tools},
        })
    return findings


def rule_runaway_cost(estimated_cost_usd, log_lines, tid, phase, gen, threshold_usd):
    if estimated_cost_usd < threshold_usd:
        return None
    run_id = _last_run_id(log_lines)
    return {
        'type': 'RUNAWAY_COST',
        'severity': 'WARN',
        'tid': tid, 'phase': phase, 'gen': gen,
        'fingerprint': _fingerprint('RUNAWAY_COST', run_id, phase, gen,
                                    f'over-{threshold_usd}'),
        'evidence': {'estimated_cost_usd': round(estimated_cost_usd, 4),
                    'threshold_usd': threshold_usd},
    }


def rule_long_tool_call(events, log_lines, tid, phase, gen, threshold_secs):
    """`tool_call` -> `tool_result` wall-clock delta above threshold.

    Delta is measured between the observer's own `observed_at` timestamps
    (poll-interval resolution, not the tool's true start/end time) — a
    genuinely long-running tool spans multiple poll cycles and is caught
    with that coarse granularity; a fast one never approaches the threshold
    regardless of the imprecision.
    """
    run_id = _last_run_id(log_lines)
    findings = []
    for call, result in _pair_tool_events(events):
        try:
            start = datetime.strptime(call['observed_at'], '%Y-%m-%dT%H:%M:%SZ')
            end = datetime.strptime(result['observed_at'], '%Y-%m-%dT%H:%M:%SZ')
        except (KeyError, ValueError, TypeError):
            continue
        elapsed = (end - start).total_seconds()
        if elapsed < threshold_secs:
            continue
        tool_use_id = call.get('tool_use_id') or ''
        findings.append({
            'type': 'LONG_TOOL_CALL',
            'severity': 'WARN',
            'tid': tid, 'phase': phase, 'gen': gen,
            'fingerprint': _fingerprint('LONG_TOOL_CALL', run_id, phase, gen, tool_use_id),
            'evidence': {'tool': call.get('name'), 'tool_use_id': tool_use_id,
                        'elapsed_secs': elapsed},
        })
    return findings


#: MCP server name substrings this pipeline's phases genuinely depend on.
#: Not a full "contract-named server" mechanism (design.md's original
#: phrasing) — that would need a new contract field this late in the task
#: list for marginal precision, since MCP server naming is inconsistent
#: across installs (observed directly: "linear-server" alongside
#: "plugin:cloudflare:cloudflare-api"-shaped names for unrelated plugins).
#: Linear is a hard dependency of every phase (env-check.sh); Playwright is
#: VERIFY's own UAT driver.
_DEGRADED_SERVER_SUBSTRINGS = {
    None: ('linear',),
    'VERIFY': ('linear', 'playwright'),
}
_DEGRADED_MCP_STATUSES = frozenset({'failed', 'needs-auth', 'pending'})


def rule_degraded_session(events, log_lines, tid, phase, gen):
    session_start = next((e for e in events if e.get('kind') == 'session_start'), None)
    if not session_start:
        return []
    substrings = _DEGRADED_SERVER_SUBSTRINGS.get(phase, _DEGRADED_SERVER_SUBSTRINGS[None])
    run_id = _last_run_id(log_lines)
    findings = []
    for server in session_start.get('mcp_servers') or []:
        name = (server.get('name') or '')
        status = server.get('status')
        if status not in _DEGRADED_MCP_STATUSES:
            continue
        if not any(sub in name.lower() for sub in substrings):
            continue
        findings.append({
            'type': 'DEGRADED_SESSION',
            'severity': 'WARN',
            'tid': tid, 'phase': phase, 'gen': gen,
            'fingerprint': _fingerprint('DEGRADED_SESSION', run_id, phase, gen,
                                        f'{name}:{status}'),
            'evidence': {'server': name, 'status': status},
        })
    return findings


def rule_permission_denied(events, log_lines, tid, phase, gen):
    session_end = next((e for e in events if e.get('kind') == 'session_end'), None)
    if not session_end:
        return []
    denials = session_end.get('permission_denials') or []
    if not denials:
        return []
    run_id = _last_run_id(log_lines)
    key = json.dumps(denials, sort_keys=True, default=str)
    return [{
        'type': 'PERMISSION_DENIED',
        'severity': 'WARN',
        'tid': tid, 'phase': phase, 'gen': gen,
        'fingerprint': _fingerprint('PERMISSION_DENIED', run_id, phase, gen, key),
        'evidence': {'count': len(denials), 'denials': denials[:5]},
    }]


def evaluate_rules(events, contract, log_lines, estimated_cost_usd, tid, phase, gen,
                   cost_warn_usd, long_tool_secs):
    """Every rule against the full accumulated event history for one phase
    generation. Returns a flat list of findings (possibly empty) — never
    raises; a rule that cannot resolve its inputs returns nothing rather
    than guessing (design.md D4)."""
    findings = []
    claim = rule_claim_contradiction(events, contract, log_lines, tid, phase, gen)
    if claim:
        findings.append(claim)
    findings.extend(rule_repeated_failure(events, log_lines, tid, phase, gen))
    findings.extend(rule_scope_violation(events, contract, log_lines, tid, phase, gen))
    findings.extend(rule_unexpected_tool(events, contract, log_lines, tid, phase, gen))
    runaway = rule_runaway_cost(estimated_cost_usd, log_lines, tid, phase, gen, cost_warn_usd)
    if runaway:
        findings.append(runaway)
    findings.extend(rule_long_tool_call(events, log_lines, tid, phase, gen, long_tool_secs))
    findings.extend(rule_degraded_session(events, log_lines, tid, phase, gen))
    findings.extend(rule_permission_denied(events, log_lines, tid, phase, gen))
    return findings


# ── Findings persistence and the pipeline-log integration point (D5) ───────

def _findings_path(log_dir, tid, phase):
    return Path(log_dir) / f'{tid}-{phase.lower()}-findings.jsonl'


def _read_findings(path):
    """{fingerprint: entry} from an existing findings.jsonl, or {}."""
    try:
        lines = Path(path).read_text().splitlines()
    except OSError:
        return {}
    out = {}
    for line in lines:
        line = line.strip()
        if not line:
            continue
        try:
            entry = json.loads(line)
        except (ValueError, TypeError):
            continue
        fingerprint = entry.get('fingerprint')
        if fingerprint:
            out[fingerprint] = entry
    return out


def _write_findings(path, findings_by_fingerprint):
    lines = [json.dumps(entry) for entry in findings_by_fingerprint.values()]
    text = '\n'.join(lines) + ('\n' if lines else '')
    try:
        Path(path).write_text(text)
    except OSError:
        pass


def _strip_pipes(value):
    return str(value).replace('|', '_')


def _pipeline_log_already_terminal(log_lines):
    """True once ANY `META|outcome` or `META|dead-letter` line exists.

    Guards against a real race this rule engine can otherwise cause: the
    observer runs asynchronously and may still be draining its grace period
    after a phase's own terminal write, so a finding can legitimately be
    computed *after* `META|outcome` already landed. Appending anything after
    that line changes what "the last line" means to every consumer that
    classifies terminal state that way (`_log_reached_terminal`, its bash
    counterpart, `detect-resume.sh`) — confirmed empirically: an
    observer-finding line appended after a real outcome line flips
    `_log_reached_terminal` from True to False. Conservative on purpose:
    this does not replicate `_log_reached_terminal`'s held/gate-stop
    nuances (still-open holds, gate-stops that leave the log non-terminal)
    — it treats *any* outcome-or-dead-letter line as "stop appending",
    which only ever skips a late pipeline-log line for a finding, never
    causes one to wrongly appear. `findings.jsonl` is written regardless;
    only the pipeline-log integration point is held back.
    """
    for line in log_lines:
        match = _PIPELINE_LINE_RE.match(line.rstrip('\n'))
        if not match:
            continue
        _iso, phase, step, _status, _msg = match.groups()
        if phase == 'META' and step in ('outcome', 'dead-letter'):
            return True
    return False


def _append_observer_finding_log_line(log_dir, tid, finding):
    """The sole integration point (design.md D5): one
    `META|observer-finding|done|type=... sev=... gen=... fp=...` line per
    *newly created* fingerprint — never per repeat detection, matching the
    gate-hold precedent elsewhere in this codebase for the same anti-spam
    reason. `status` is always `done` (schema-valid; never invented) and
    every interpolated field has pipe characters stripped before it ever
    reaches a log fleetd's own classifiers read (existing `hb_write` rule,
    reused).
    """
    path = Path(log_dir) / f'{tid}-pipeline.log'
    ts = datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
    msg = (
        f"type={_strip_pipes(finding['type'])} "
        f"sev={_strip_pipes(finding['severity'])} "
        f"gen={_strip_pipes(finding['gen'])} "
        f"fp={_strip_pipes(finding['fingerprint'])}"
    )
    line = f'{ts}|META|observer-finding|done|{msg}\n'
    try:
        with open(path, 'a') as fh:
            fh.write(line)
    except OSError:
        pass


def record_findings(log_dir, tid, phase, findings, now, log_lines=()):
    """Merge `findings` into the on-disk store (findings.jsonl), appending a
    pipeline-log line only for fingerprints not already present — and only
    when the ticket's pipeline log hasn't already reached its terminal
    outcome (`_pipeline_log_already_terminal`). Returns the list of newly
    created entries (findings.jsonl is updated for all of them regardless of
    whether the pipeline-log line was held back).
    """
    if not findings:
        return []
    path = _findings_path(log_dir, tid, phase)
    existing = _read_findings(path)
    now_iso = _iso(now) if isinstance(now, (int, float)) else now
    created = []
    for finding in findings:
        fingerprint = finding['fingerprint']
        if fingerprint in existing:
            existing[fingerprint]['count'] += 1
            existing[fingerprint]['last_seen'] = now_iso
            continue
        entry = dict(finding)
        entry['count'] = 1
        entry['first_seen'] = now_iso
        entry['last_seen'] = now_iso
        existing[fingerprint] = entry
        created.append(entry)
    _write_findings(path, existing)
    if created and not _pipeline_log_already_terminal(log_lines):
        for entry in created:
            _append_observer_finding_log_line(log_dir, tid, entry)
    return created


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
    # All events translated so far this generation (Inc 3 rules need the full
    # history — REPEATED_FAILURE's count and UNEXPECTED_TOOL's allowlist scan
    # both look across everything a stream has done, not just this poll's
    # increment). Bounded by the same truncation/redaction every individual
    # event already went through; a phase's own event volume stays modest
    # relative to the raw NDJSON it was derived from.
    all_events: list = None

    def __post_init__(self):
        if self.all_events is None:
            self.all_events = []


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

    def _evaluate_and_record_findings(self, ts, now):
        """Inc 3: run every deterministic rule against `ts`'s full event
        history and persist any findings. Never raises — a rule-evaluation
        failure costs this poll's finding coverage, never the pipeline
        (design.md Goals): the observer's own bugs must not become a second
        way to hurt a ticket."""
        try:
            contract = _read_contract(self.config.log_dir, ts.tid, ts.phase)
            log_lines = _read_pipeline_log_tail(self.config.log_dir, ts.tid)
            findings = evaluate_rules(
                ts.all_events, contract, log_lines, ts.translator.estimated_cost_usd,
                ts.tid, ts.phase, ts.generation,
                self.config.cost_warn_usd, self.config.long_tool_secs,
            )
            record_findings(self.config.log_dir, ts.tid, ts.phase, findings, now,
                            log_lines=log_lines)
        except Exception as exc:
            print(f'agent-observer: finding evaluation failed for '
                  f'{ts.tid}/{ts.phase}: {exc}', file=sys.stderr)

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
            if events:
                ts.all_events.extend(events)
                self._evaluate_and_record_findings(ts, now)

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
