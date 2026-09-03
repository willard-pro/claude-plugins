"""
fleet-controller state store — one SQLite database, fleetd the sole writer.

Replaces two things at once: the per-ticket JSON file conventions (run
registry, generation fence) and the habit of answering "what is happening
right now" by globbing `logs/*-pipeline.log` and re-parsing them on every
detection sweep.

Authorship decides authority, and the split is the whole design:

  fleetd-authored   tickets, workers, phase_runs
      Written only here, by the supervisor that performed the dispatch.
      Authoritative for fleet-managed tickets.

  projections       log_events, phase_results, activity_events
      Derived from the append-only logs, which stay the source of truth.
      On disagreement the log wins. All are rebuildable from the logs, so
      deleting the database costs a slow cold start, never data.

Sole writer is load-bearing. Every phase is an independent `claude -p`
process and every tool call fires a PostToolUse hook; letting either write
here would put dozens of uncoordinated short-lived writers on the write path.
They keep appending to their logs — no change required of them — and fleetd
ingests. WAL mode lets detectors and dashboards read while the writer works.

Stdlib only, matching supervisor.py's constraint: the store must open before
and survive independently of any workspace toolchain.
"""

import json
import os
import re
import sqlite3
import time
from datetime import datetime, timezone
from pathlib import Path

# Bumped when the schema changes shape. fleetd refuses to operate against a
# version it does not recognise rather than misreading tables that moved.
SCHEMA_VERSION = 1

DEFAULT_DB_NAME = 'fleet-state.db'
SCHEMA_FILE = Path(__file__).with_name('schema.sql')

# `TID-pipeline.log` / `TID-activity.log`. Anchored so a stray file in the
# workspace cannot produce a ticket id with a path separator in it.
_PIPELINE_RE = re.compile(r'^(?P<tid>[A-Za-z][A-Za-z0-9_-]*)-pipeline\.log$')
_ACTIVITY_RE = re.compile(r'^(?P<tid>[A-Za-z][A-Za-z0-9_-]*)-activity\.log$')

_ISO_FMT = '%Y-%m-%dT%H:%M:%SZ'


class SchemaVersionError(RuntimeError):
    """The store's schema version is not one this code understands."""


def _now_iso():
    return datetime.now(timezone.utc).strftime(_ISO_FMT)


def _iso_to_epoch(iso):
    """Parse a pipeline-log timestamp to epoch seconds, None when unparseable.

    Timestamps come from `date -u +%Y-%m-%dT%H:%M:%SZ` in bash. A line whose
    timestamp is malformed still gets stored — the log is the source of truth
    and dropping the line would lose it — it simply has no epoch to age.
    """
    if not iso:
        return None
    try:
        dt = datetime.strptime(iso.strip(), _ISO_FMT).replace(tzinfo=timezone.utc)
        return int(dt.timestamp())
    except (ValueError, TypeError):
        return None


def store_path(state_dir):
    """The database's location: alongside the rest of fleet's durable state.

    FLEET_STATE_DIR already survives reboot and is where the run registry,
    fence markers and stop files live, so the store inherits that lifecycle
    rather than inventing a second one.
    """
    return Path(state_dir) / DEFAULT_DB_NAME


def tid_from_log_name(name):
    """Ticket id for a pipeline-log filename, or None."""
    m = _PIPELINE_RE.match(name)
    return m.group('tid') if m else None


class FleetStore:
    """A connection to the fleet state store.

    Open read-write only in the fleetd supervisor. Everything else — detectors,
    dashboards, hooks, the bash query surface — opens read-only, so a crashed
    or hung reader can neither corrupt the database nor lock it against the
    writer.
    """

    def __init__(self, path, read_only=False, timeout=5.0):
        self.path = Path(path)
        self.read_only = read_only
        self.timeout = timeout
        self._conn = None

    # ── Lifecycle ────────────────────────────────────────────────────────────

    def open(self):
        if self._conn is not None:
            return self
        if self.read_only:
            if not self.path.exists():
                raise FileNotFoundError(f'state store not found: {self.path}')
            uri = f'file:{self.path}?mode=ro'
            self._conn = sqlite3.connect(uri, uri=True, timeout=self.timeout)
        else:
            self.path.parent.mkdir(parents=True, exist_ok=True)
            self._conn = sqlite3.connect(str(self.path), timeout=self.timeout)
        self._conn.row_factory = sqlite3.Row
        if not self.read_only:
            self._ensure_schema()
        else:
            self._check_version()
        return self

    def close(self):
        if self._conn is not None:
            try:
                self._conn.close()
            finally:
                self._conn = None

    def __enter__(self):
        return self.open()

    def __exit__(self, exc_type, exc, tb):
        self.close()

    @property
    def conn(self):
        if self._conn is None:
            raise RuntimeError('store is not open')
        return self._conn

    # ── Schema ───────────────────────────────────────────────────────────────

    def _ensure_schema(self):
        """Create the schema on first run; refuse an unrecognised version.

        Refusing is the point. A database written by a newer fleetd may have
        moved a column this code reads by name, and reading it anyway produces
        confidently wrong answers about which processes are alive — the one
        class of error a supervisor must not make.
        """
        cur = self.conn.execute(
            "SELECT name FROM sqlite_master WHERE type='table' AND name='schema_version'")
        fresh = cur.fetchone() is None

        self.conn.executescript(SCHEMA_FILE.read_text())

        if fresh:
            self.conn.execute(
                'INSERT OR REPLACE INTO schema_version (id, version, applied_at) '
                'VALUES (1, ?, ?)', (SCHEMA_VERSION, _now_iso()))
            self.conn.commit()
        else:
            self._check_version()

    def _check_version(self):
        try:
            row = self.conn.execute(
                'SELECT version FROM schema_version WHERE id = 1').fetchone()
        except sqlite3.Error as exc:
            raise SchemaVersionError(
                f'{self.path}: no readable schema_version table ({exc})') from exc
        if row is None:
            raise SchemaVersionError(f'{self.path}: schema_version table is empty')
        found = row['version']
        if found != SCHEMA_VERSION:
            raise SchemaVersionError(
                f'{self.path}: schema version {found} is not supported by this '
                f'fleetd (expects {SCHEMA_VERSION}). Refusing to read it. '
                f'Delete the store to rebuild from logs, or run a matching fleetd.')

    def version(self):
        row = self.conn.execute(
            'SELECT version FROM schema_version WHERE id = 1').fetchone()
        return row['version'] if row else None

    # ── tickets (fleetd-authored) ────────────────────────────────────────────

    def _ensure_ticket(self, tid):
        now = _now_iso()
        self.conn.execute(
            'INSERT INTO tickets (tid, created_at, updated_at) VALUES (?, ?, ?) '
            'ON CONFLICT(tid) DO NOTHING', (tid, now, now))

    def update_ticket(self, tid, **fields):
        """Set named columns on a ticket row, creating it if absent.

        Column names are validated against the table's own schema rather than
        interpolated blind — these values reach an SQL string, and a caller
        typo should fail loudly instead of becoming an injection surface.
        """
        allowed = {r['name'] for r in self.conn.execute('PRAGMA table_info(tickets)')}
        allowed.discard('tid')
        bad = set(fields) - allowed
        if bad:
            raise ValueError(f'unknown tickets column(s): {sorted(bad)}')
        self._ensure_ticket(tid)
        if not fields:
            self.conn.commit()
            return
        fields = dict(fields)
        fields['updated_at'] = _now_iso()
        assignments = ', '.join(f'{k} = ?' for k in fields)
        self.conn.execute(
            f'UPDATE tickets SET {assignments} WHERE tid = ?',
            (*fields.values(), tid))
        self.conn.commit()

    def get_ticket(self, tid):
        row = self.conn.execute(
            'SELECT * FROM tickets WHERE tid = ?', (tid,)).fetchone()
        return dict(row) if row else None

    def record_position(self, tid, position, source='dispatch'):
        """Record where dispatch has reached.

        Written as dispatch happens, not reconstructed afterwards: a supervisor
        that performed the dispatch does not need to infer where it got to.
        `source='adopted'` marks the one case where a position was derived from
        the log — a ticket a human started that fleetd has taken over.
        """
        if source not in ('dispatch', 'adopted'):
            raise ValueError(f"position_source must be 'dispatch' or 'adopted', got {source!r}")
        self.update_ticket(tid, position=position, position_source=source)

    def get_position(self, tid):
        row = self.conn.execute(
            'SELECT position, position_source FROM tickets WHERE tid = ?',
            (tid,)).fetchone()
        if row is None or not row['position']:
            return None
        return {'position': row['position'], 'source': row['position_source']}

    def set_gate_hold(self, tid, held, reason=''):
        """Park or release a ticket at its approval gate.

        A hold is a row, not a live process: this is what lets the automated
        path pause indefinitely for a human without keeping anything running,
        which is the property that ruled out engines that cannot survive
        process exit.
        """
        self.update_ticket(
            tid,
            gate_held=1 if held else 0,
            gate_hold_reason=reason if held else '',
            gate_held_at=_now_iso() if held else '')

    def set_owner(self, tid, owner):
        if owner not in ('fleetd', 'manual'):
            raise ValueError(f"owner must be 'fleetd' or 'manual', got {owner!r}")
        self.update_ticket(tid, owner=owner)

    def is_fleetd_owned(self, tid):
        """Whether the fleet may intervene on this ticket.

        Severity >= 2 drives real kills and respawns. A human running the
        pipeline by hand writes to the same logs the detectors read, so
        ownership — not log presence — is what scopes intervention.
        """
        row = self.conn.execute(
            'SELECT owner FROM tickets WHERE tid = ?', (tid,)).fetchone()
        if row is not None and row['owner'] == 'fleetd':
            return True
        # A live fleetd-spawned worker is ownership evidence in its own right,
        # covering the window between spawn and the ticket row being updated.
        row = self.conn.execute(
            "SELECT 1 FROM workers WHERE tid = ? AND status = 'running' LIMIT 1",
            (tid,)).fetchone()
        return row is not None

    def in_flight(self):
        """Tickets with a running worker: the answer to "what is running now"
        as one query, rather than a glob over the log directory."""
        rows = self.conn.execute(
            'SELECT t.tid AS tid, t.position AS position, t.owner AS owner, '
            '       w.phase AS phase, w.pid AS pid, w.generation AS generation '
            'FROM workers w LEFT JOIN tickets t ON t.tid = w.tid '
            "WHERE w.status = 'running' ORDER BY w.tid, w.id").fetchall()
        return [dict(r) for r in rows]

    # ── Generation fence (fleetd-authored) ───────────────────────────────────

    def set_fence(self, tid, generation):
        """Fence a generation: mutations from it and below are refused."""
        self.update_ticket(tid, fenced_generation=int(generation),
                           fenced_at=_now_iso())

    def get_fence(self, tid):
        row = self.conn.execute(
            'SELECT fenced_generation FROM tickets WHERE tid = ?', (tid,)).fetchone()
        if row is None:
            return None
        return row['fenced_generation']

    def fence_allows(self, tid, caller_generation):
        """Exact semantics of the file-based fence, preserved.

        Unfenced ticket: allowed. Fenced ticket with no generation token:
        refused (fail closed). Fenced ticket with generation <= the fenced
        generation: refused as superseded.
        """
        fenced = self.get_fence(tid)
        if fenced is None:
            return True
        if caller_generation is None or caller_generation == '':
            return False
        try:
            caller = int(caller_generation)
        except (TypeError, ValueError):
            return False
        return caller > int(fenced)

    # ── workers (fleetd-authored) ────────────────────────────────────────────

    def record_worker_spawn(self, tid, pid, generation=0, phase='', reason='',
                            session_id='', start_ticks='', started_at=None):
        """Record a spawned process and return its worker id.

        Rows are per spawn, not per ticket: phase-granularity supervision means
        several rows for one ticket coexist over its lifetime, which is the
        assumption every consumer of the old one-file-per-ticket registry has
        to be updated for.
        """
        self._ensure_ticket(tid)
        cur = self.conn.execute(
            'INSERT INTO workers (tid, phase, pid, start_ticks, generation, '
            'session_id, reason, status, started_at) '
            "VALUES (?, ?, ?, ?, ?, ?, ?, 'running', ?)",
            (tid, phase, int(pid), str(start_ticks or ''), int(generation),
             session_id or '', reason or '', started_at or _now_iso()))
        self.update_ticket(tid, owner='fleetd', generation=int(generation))
        self.conn.commit()
        return cur.lastrowid

    def record_worker_exit(self, worker_id, exit_code=None, exit_type='',
                           status='exited'):
        if status not in ('exited', 'killed', 'unknown'):
            raise ValueError(f'unexpected worker status {status!r}')
        self.conn.execute(
            'UPDATE workers SET status = ?, exit_code = ?, exit_type = ?, '
            'exited_at = ? WHERE id = ?',
            (status, exit_code, exit_type or '', _now_iso(), worker_id))
        self.conn.commit()

    def running_workers(self, tid=None):
        if tid is None:
            rows = self.conn.execute(
                "SELECT * FROM workers WHERE status = 'running' ORDER BY id").fetchall()
        else:
            rows = self.conn.execute(
                "SELECT * FROM workers WHERE status = 'running' AND tid = ? "
                'ORDER BY id', (tid,)).fetchall()
        return [dict(r) for r in rows]

    def worker_by_session(self, session_id):
        """Resolve a hook payload's session_id to its worker row.

        This is what `stop-capture.sh` does today by globbing `*-run.json` and
        reading each one — an assumption that breaks as soon as one ticket has
        several concurrent worker rows.
        """
        if not session_id:
            return None
        row = self.conn.execute(
            'SELECT * FROM workers WHERE session_id = ? ORDER BY id DESC LIMIT 1',
            (session_id,)).fetchone()
        return dict(row) if row else None

    # ── phase_runs (fleetd-authored) ─────────────────────────────────────────

    def record_phase_run(self, tid, phase, step='', attempt=1, worker_id=None,
                         started_at=None):
        """Open a phase-attempt row. Written by the phase-dispatch path."""
        self._ensure_ticket(tid)
        self.conn.execute(
            'INSERT INTO phase_runs (tid, phase, step, attempt, worker_id, started_at) '
            'VALUES (?, ?, ?, ?, ?, ?) '
            'ON CONFLICT(tid, phase, step, attempt) DO UPDATE SET '
            'worker_id = excluded.worker_id, started_at = excluded.started_at',
            (tid, phase, step, int(attempt), worker_id, started_at or _now_iso()))
        self.conn.commit()
        row = self.conn.execute(
            'SELECT id FROM phase_runs WHERE tid = ? AND phase = ? AND step = ? '
            'AND attempt = ?', (tid, phase, step, int(attempt))).fetchone()
        return row['id'] if row else None

    def close_phase_run(self, run_id, verdict='', outcome='', exit_code=None):
        self.conn.execute(
            'UPDATE phase_runs SET verdict = ?, outcome = ?, exit_code = ?, '
            'ended_at = ? WHERE id = ?',
            (verdict or '', outcome or '', exit_code, _now_iso(), run_id))
        self.conn.commit()

    # ── Ingestion (projections) ──────────────────────────────────────────────

    def _ingest_offset(self, path):
        row = self.conn.execute(
            'SELECT lines_read, bytes_read FROM ingest_state WHERE source_path = ?',
            (str(path),)).fetchone()
        if row is None:
            return 0, 0
        return row['lines_read'], row['bytes_read']

    def _save_offset(self, path, tid, kind, lines_read, bytes_read):
        self.conn.execute(
            'INSERT INTO ingest_state (source_path, tid, kind, lines_read, '
            'bytes_read, updated_at) VALUES (?, ?, ?, ?, ?, ?) '
            'ON CONFLICT(source_path) DO UPDATE SET tid = excluded.tid, '
            'kind = excluded.kind, lines_read = excluded.lines_read, '
            'bytes_read = excluded.bytes_read, updated_at = excluded.updated_at',
            (str(path), tid, kind, lines_read, bytes_read, _now_iso()))

    def _read_new_lines(self, path):
        """Return (start_line_no, [lines], new_byte_offset) for unread content.

        Reads from the stored byte offset and stops at the last complete line,
        so a line still being appended is picked up on the next sweep rather
        than ingested half-written. A file whose size went backwards was
        truncated or rotated, so ingestion restarts from the top — the UNIQUE
        (tid, line_no) keys make that a no-op for rows already present.
        """
        path = Path(path)
        try:
            size = path.stat().st_size
        except OSError:
            return 0, [], 0

        lines_read, bytes_read = self._ingest_offset(path)
        if size < bytes_read:
            lines_read, bytes_read = 0, 0

        if size == bytes_read:
            return lines_read, [], bytes_read

        try:
            with open(path, 'rb') as fh:
                fh.seek(bytes_read)
                chunk = fh.read()
        except OSError:
            return lines_read, [], bytes_read

        cut = chunk.rfind(b'\n')
        if cut < 0:
            return lines_read, [], bytes_read

        consumed = cut + 1
        text = chunk[:consumed].decode('utf-8', 'replace')
        return lines_read, text.splitlines(), bytes_read + consumed

    def ingest_pipeline_log(self, path, tid=None):
        """Ingest `ISO|PHASE|STEP|STATUS|MSG` lines into log_events.

        Idempotent by construction: (tid, line_no) is UNIQUE and inserts use
        OR IGNORE, so re-ingesting a log — after a rebuild, or because the
        offset was reset — never duplicates a row.
        """
        path = Path(path)
        tid = tid or tid_from_log_name(path.name) or ''
        if not tid:
            return 0

        start_line, lines, new_offset = self._read_new_lines(path)
        if not lines:
            self._save_offset(path, tid, 'pipeline', start_line, new_offset)
            self.conn.commit()
            return 0

        inserted = 0
        for idx, raw in enumerate(lines, start=start_line + 1):
            if not raw.strip():
                continue
            parts = raw.split('|', 4)
            while len(parts) < 5:
                parts.append('')
            iso, phase, step, status = (p.strip() for p in parts[:4])
            msg = parts[4]
            cur = self.conn.execute(
                'INSERT OR IGNORE INTO log_events '
                '(tid, line_no, iso, epoch, phase, step, status, msg) '
                'VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
                (tid, idx, iso, _iso_to_epoch(iso), phase, step, status, msg))
            inserted += cur.rowcount

            if phase == 'META' and step == 'phase-result':
                self._ingest_phase_result(tid, idx, iso, msg)

        self._save_offset(path, tid, 'pipeline', start_line + len(lines), new_offset)
        self.conn.commit()
        return inserted

    def _ingest_phase_result(self, tid, line_no, iso, payload):
        """Project one `META|phase-result|info|{json}` line.

        The payload is already canonical JSON — lib/phase-result-parse.sh
        validated the agent's block and serialised it with jq before it reached
        the log. Ingestion consumes that output; it never re-parses prose. A
        payload that will not parse is still recorded, with parse_status
        marking it, because the log line exists and dropping it would hide it.
        """
        try:
            data = json.loads(payload)
            if not isinstance(data, dict):
                raise ValueError('phase-result payload is not an object')
        except (ValueError, TypeError):
            self.conn.execute(
                'INSERT OR IGNORE INTO phase_results '
                '(tid, line_no, iso, parse_status, parse_error, raw_json) '
                'VALUES (?, ?, ?, ?, ?, ?)',
                (tid, line_no, iso, 'unreadable',
                 'payload is not valid JSON', payload))
            return

        def _int(key):
            val = data.get(key)
            try:
                return int(val)
            except (TypeError, ValueError):
                return None

        self.conn.execute(
            'INSERT OR IGNORE INTO phase_results '
            '(tid, line_no, iso, schema_version, phase, verifier, claimed_verdict, '
            ' criteria_met, criteria_total, attempt, evidence, unaddressed, '
            ' parse_status, parse_error, raw_json) '
            'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
            (tid, line_no, iso, _int('schema_version'),
             str(data.get('phase', '')), str(data.get('verifier', '')),
             str(data.get('claimed_verdict', '')),
             _int('criteria_met'), _int('criteria_total'), _int('attempt'),
             str(data.get('evidence', '')), str(data.get('unaddressed', '')),
             str(data.get('parse_status', '')), str(data.get('parse_error', '')),
             payload))

    def ingest_activity_log(self, path, tid=None):
        """Ingest `ISO|PHASE|TOOL_NAME` lines into activity_events.

        The hook ring-caps its file, so line numbers restart after a trim and
        the byte offset goes backwards — handled as a truncation, which
        re-ingests the retained tail. Rows already present are ignored by the
        UNIQUE key, so the effect is that the store keeps the full history
        while the file keeps only the tail.
        """
        path = Path(path)
        if tid is None:
            m = _ACTIVITY_RE.match(path.name)
            tid = m.group('tid') if m else ''
        if not tid:
            return 0

        start_line, lines, new_offset = self._read_new_lines(path)
        if not lines:
            self._save_offset(path, tid, 'activity', start_line, new_offset)
            self.conn.commit()
            return 0

        inserted = 0
        for idx, raw in enumerate(lines, start=start_line + 1):
            if not raw.strip():
                continue
            parts = raw.split('|', 2)
            while len(parts) < 3:
                parts.append('')
            iso, phase, tool = parts[0].strip(), parts[1].strip(), parts[2].strip()
            cur = self.conn.execute(
                'INSERT OR IGNORE INTO activity_events '
                '(tid, line_no, iso, epoch, phase, tool) VALUES (?, ?, ?, ?, ?, ?)',
                (tid, idx, iso, _iso_to_epoch(iso), phase, tool))
            inserted += cur.rowcount

        self._save_offset(path, tid, 'activity', start_line + len(lines), new_offset)
        self.conn.commit()
        return inserted

    def ingest_workspace(self, workspace):
        """Sweep every pipeline and activity log in a workspace."""
        workspace = Path(workspace)
        counts = {'pipeline': 0, 'activity': 0, 'files': 0}
        if not workspace.is_dir():
            return counts
        for entry in sorted(workspace.iterdir()):
            if not entry.is_file():
                continue
            if _PIPELINE_RE.match(entry.name):
                counts['pipeline'] += self.ingest_pipeline_log(entry)
                counts['files'] += 1
            elif _ACTIVITY_RE.match(entry.name):
                counts['activity'] += self.ingest_activity_log(entry)
                counts['files'] += 1
        return counts

    def rebuild_projections(self, workspace):
        """Drop and re-derive every projection from the logs.

        This is what makes deleting the database a slow cold start rather than
        data loss, and it is also the repair path when a projection row and its
        log line disagree: the log wins, so the projection is discarded and
        rebuilt from it.

        fleetd-authored tables (tickets, workers, phase_runs) are untouched —
        they cannot be derived from the logs, which is precisely why they are
        the ones fleetd must write first-hand.
        """
        self.conn.execute('DELETE FROM log_events')
        self.conn.execute('DELETE FROM phase_results')
        self.conn.execute('DELETE FROM activity_events')
        self.conn.execute('DELETE FROM ingest_state')
        self.conn.commit()
        return self.ingest_workspace(workspace)

    def prune_log_events(self, older_than_days=None):
        """Drop projection rows older than the retention window.

        Safe because they are projections: anything pruned is still in the
        pipeline log and comes back on a rebuild. Retention is about query
        cost, not durability.
        """
        days = older_than_days
        if days is None:
            try:
                days = int(os.environ.get('FLEET_STORE_EVENT_RETENTION_DAYS', '30'))
            except ValueError:
                days = 30
        if days <= 0:
            return 0
        cutoff = int(time.time()) - days * 86400
        removed = 0
        for table in ('log_events', 'activity_events'):
            cur = self.conn.execute(
                f'DELETE FROM {table} WHERE epoch IS NOT NULL AND epoch < ?',
                (cutoff,))
            removed += cur.rowcount
        self.conn.commit()
        return removed

    # ── Legacy file import ───────────────────────────────────────────────────

    def import_legacy_state(self, state_dir):
        """Adopt the JSON file conventions the store replaces.

        Run once at startup so a fleetd upgrading into the store does not
        orphan the workers and fences its predecessor recorded on disk. The
        files are read, never deleted: they stay readable by the bash consumers
        that have not yet moved to the store.
        """
        state = Path(state_dir)
        imported = {'workers': 0, 'fences': 0}
        if not state.is_dir():
            return imported

        for run_file in sorted(state.glob('*-run.json')):
            try:
                data = json.loads(run_file.read_text())
            except (OSError, ValueError):
                continue
            tid = str(data.get('tid', '') or '')
            if not tid:
                continue
            try:
                pid = int(data.get('pid', 0) or 0)
            except (TypeError, ValueError):
                pid = 0
            if pid == 0:
                # The sentinel for "never actually spawned" — not a worker.
                continue
            existing = self.conn.execute(
                'SELECT 1 FROM workers WHERE tid = ? AND pid = ? AND generation = ? '
                'LIMIT 1',
                (tid, pid, int(data.get('generation', 0) or 0))).fetchone()
            if existing:
                continue
            self._ensure_ticket(tid)
            self.conn.execute(
                'INSERT INTO workers (tid, phase, pid, generation, session_id, '
                "reason, status, started_at) VALUES (?, '', ?, ?, ?, ?, ?, ?)",
                (tid, pid, int(data.get('generation', 0) or 0),
                 str(data.get('session_id', '') or ''),
                 str(data.get('reason', '') or 'imported'),
                 'running' if _pid_alive(pid) else 'unknown',
                 str(data.get('started_at', '') or '')))
            self.update_ticket(tid, owner='fleetd')
            imported['workers'] += 1

        for fence_file in sorted(state.glob('*-fence')):
            try:
                data = json.loads(fence_file.read_text())
            except (OSError, ValueError):
                continue
            tid = str(data.get('tid', '') or '')
            if not tid:
                continue
            try:
                gen = int(data.get('fenced_generation', 0) or 0)
            except (TypeError, ValueError):
                continue
            current = self.get_fence(tid)
            # A fence only ever moves forward — importing must not un-fence a
            # generation the store already refuses.
            if current is None or gen > current:
                self.set_fence(tid, gen)
                imported['fences'] += 1

        self.conn.commit()
        return imported


def _pid_alive(pid):
    try:
        os.kill(int(pid), 0)
        return True
    except (OSError, ValueError, TypeError):
        return False


def open_store(state_dir, read_only=False):
    """Convenience opener used by the supervisor and the bash query surface."""
    return FleetStore(store_path(state_dir), read_only=read_only).open()
