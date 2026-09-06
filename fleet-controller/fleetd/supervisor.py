"""
fleetd supervisor — owns worker process lifecycle.

Stdlib-only: must start before and survive independently of any workspace
toolchain. The dashboard (server.py) carries the same constraint for the
same reason: when the toolchain is broken is exactly when you need these.

Group 4 (observe-only): the daemon runs, acquires the single-instance lock,
scans existing registry entries into its child table, and serves the health
endpoint. It does not spawn or kill workers yet — that lands in groups 6-7.
"""

import fcntl
import http.server
import json
import os
import re
import shlex
import signal
import subprocess
import sys
import threading
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path

# The state store. Imported defensively: a supervisor that cannot open its
# store must still supervise processes, because the store is an accelerant
# for state queries, not the thing that keeps workers alive.
try:
    from fleetd import store as _store_mod
except ImportError:  # pragma: no cover - store unavailable
    _store_mod = None

# The OTel exporter module. otel.py is pure stdlib at import time — its
# opentelemetry dependency is imported lazily inside the exporter *process*,
# never here — so this only fails when the file itself is missing.
try:
    from fleetd import otel as _otel_mod
except ImportError:  # pragma: no cover - exporter unavailable
    _otel_mod = None

# The Agent Observer sidecar module. observer.py is pure stdlib, always —
# unlike otel.py there is no lazy third-party import to defer, so this only
# fails when the file itself is missing.
try:
    from fleetd import observer as _observer_mod
except ImportError:  # pragma: no cover - observer unavailable
    _observer_mod = None

# Phase-level dispatch. Unlike the two above, a missing phase_dispatch is not
# survivable for a phase spawn — there is no degraded mode in which fleetd
# dispatches a phase without knowing the dispatch table — so the failure is
# raised at the call, not swallowed at import.
try:
    from fleetd import phase_dispatch as _phase_mod
except ImportError:  # pragma: no cover - phase dispatch unavailable
    _phase_mod = None

# Hold reconciliation. Imported defensively like the store above: a held
# ticket that cannot be reconciled this cycle simply stays held and is
# retried next pass — not a reason to take the supervisor down.
try:
    from fleetd import gate_hold as _gate_hold_mod
except ImportError:  # pragma: no cover - gate hold unavailable
    _gate_hold_mod = None


# ── Configuration ──────────────────────────────────────────────────────────

def _env_int(name, default):
    val = os.environ.get(name, '')
    try:
        return int(val)
    except (TypeError, ValueError):
        return default


FLEET_STATE_DIR = os.environ.get('FLEET_STATE_DIR', '')
FLEET_INSTANCE_ID = os.environ.get('FLEET_INSTANCE_ID', 'default')
FLEETD_PORT = _env_int('FLEETD_PORT', 21001)
FLEETD_BIND = os.environ.get('FLEETD_BIND', '127.0.0.1')

# Linear identifier shape — epic ids (INIT-42) and ticket ids (CRE-101).
# Request-derived ids must match before reaching any file path or shell.
_ID_RE = re.compile(r'^[A-Z][A-Z0-9-]*-\d+$')

# Fallback workspace — the fleet state dir when FLEET_STATE_DIR is unset.
# In the container this is the tickets directory.
DEFAULT_WORKSPACE = os.environ.get('FLEETD_WORKSPACE', '.')

# Path to the pidfile used for single-instance enforcement.
DEFAULT_PIDFILE = os.environ.get(
    'FLEETD_PIDFILE',
    '/tmp/fleetd.pid',
)


def _resolve_state_dir():
    """Resolve the fleet state directory using the same rule as fleet-config.sh."""
    if FLEET_STATE_DIR:
        return Path(FLEET_STATE_DIR)
    return Path(DEFAULT_WORKSPACE)


# ── Single-instance lock ──────────────────────────────────────────────────

class InstanceLock:
    """Exclusive lock held for the daemon's lifetime.

    Uses fcntl.flock on a pidfile. The kernel releases the lock when the
    process exits (cleanly or otherwise), so a crashed daemon does not leave
    a stale lock requiring manual cleanup.

    The file is written with the current PID so that an operator or a second
    instance can report which process holds the lock.
    """

    def __init__(self, pidfile_path):
        self._path = Path(pidfile_path)
        self._fd = None

    def acquire(self):
        """Acquire the exclusive lock. Raises SystemExit if another instance holds it."""
        self._fd = os.open(self._path, os.O_CREAT | os.O_RDWR, 0o644)
        try:
            fcntl.flock(self._fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            # Another instance holds the lock — report who and exit.
            try:
                holder_pid = Path(self._path).read_text().strip()
            except Exception:
                holder_pid = 'unknown'
            print(
                f"fleetd: another instance is already running (pid {holder_pid}). "
                f"Refusing to start.",
                file=sys.stderr,
            )
            os.close(self._fd)
            self._fd = None
            sys.exit(1)

        # Truncate and write our PID so others can identify us.
        os.ftruncate(self._fd, 0)
        os.lseek(self._fd, 0, os.SEEK_SET)
        os.write(self._fd, str(os.getpid()).encode())
        os.fsync(self._fd)

    def release(self):
        """Release the lock and close the pidfile."""
        if self._fd is not None:
            try:
                fcntl.flock(self._fd, fcntl.LOCK_UN)
            except OSError:
                pass
            os.close(self._fd)
            self._fd = None

    @property
    def hold_fd(self):
        return self._fd


# ── Child-process table ────────────────────────────────────────────────────

class ChildTable:
    """The authoritative record of live workers.

    In observe-only mode (group 4), entries come from scanning existing
    run-registry files. When spawn lands (group 6), entries are added at
    fork time and the real PID is recorded directly.
    """

    def __init__(self):
        # {tid: {pid, started_at, generation, reason, adopted, phase,
        #        anomalies, start_ticks, hb_log_file}}
        self._workers = {}

    def add(self, tid, pid, generation=0, reason='', adopted=False, phase='',
            anomalies='', session_id=None, start_ticks=None, hb_log_file=''):
        self._workers[tid] = {
            'tid': tid,
            'pid': pid,
            'generation': generation,
            'started_at': datetime.now(timezone.utc).isoformat(),
            'reason': reason,
            'adopted': adopted,
            'phase': phase,
            'anomalies': anomalies,
            'session_id': session_id,
            # Phase-worker liveness heartbeat inputs (task 4.18). Empty/None
            # for a ticket-level spawn, which has no per-cycle heartbeat
            # writer of its own — the router's backgrounded watchdog already
            # covers it.
            'start_ticks': start_ticks,
            'hb_log_file': hb_log_file,
        }

    def remove(self, tid):
        self._workers.pop(tid, None)

    def get(self, tid):
        return self._workers.get(tid)

    def update_phase(self, tid, phase):
        entry = self._workers.get(tid)
        if entry:
            entry['phase'] = phase

    def update_anomalies(self, tid, anomalies):
        entry = self._workers.get(tid)
        if entry:
            entry['anomalies'] = anomalies

    def __iter__(self):
        return iter(self._workers.values())

    def __len__(self):
        return len(self._workers)

    def __contains__(self, tid):
        # Container semantics over ticket ids — iteration yields worker
        # dicts, so without this `tid in table` silently never matches.
        return tid in self._workers

    def list_workers(self):
        """Return worker list suitable for the health payload."""
        return [
            {
                'tid': w['tid'],
                'pid': w['pid'],
                'generation': w['generation'],
                'started_at': w['started_at'],
                'reason': w['reason'],
                'adopted': w['adopted'],
                'phase': w['phase'],
                'anomalies': w['anomalies'],
                'session_id': w.get('session_id'),
            }
            for w in self._workers.values()
        ]


# ── Registry scanner ───────────────────────────────────────────────────────

def _write_last_generation(state_dir, tid, generation):
    """Persist the last-known generation for `tid` before its registry entry
    is deleted as stale. One small JSON side record (`{tid}-last-generation`)
    in the same state dir — the only durable trace of how many generations a
    ticket has been through once the run-registry file is gone. Fail-soft:
    a lost side record degrades to pre-change behavior, never blocks startup.
    """
    try:
        last_file = Path(state_dir) / f'{tid}-last-generation'
        last_file.write_text(json.dumps({'generation': generation}))
    except OSError:
        pass


def scan_registry(state_dir, verify_ownership=False):
    """Read existing run-registry files and return parsed entries.

    Each *-run.json file contains {tid, pid, generation, started_at, reason}.
    When verify_ownership is True (crash recovery on startup), each entry's
    PID is checked not just for liveness but also for start-time consistency
    with the registry. Entries that fail ownership verification are excluded.

    Stale entries (dead PID, or unverifiable ownership) are deleted after
    their generation is preserved via `_write_last_generation`, so a later
    re-spawn of the same ticket continues the generation sequence instead of
    restarting at 1 — see `_resolve_generation`.

    Zero-PID entries (sentinel for "never actually spawned") are always skipped.
    """
    entries = []
    state = Path(state_dir)
    if not state.is_dir():
        return entries

    for run_file in sorted(state.glob('*-run.json')):
        try:
            data = json.loads(run_file.read_text())
        except (json.JSONDecodeError, OSError):
            continue

        tid = data.get('tid', '')
        generation = data.get('generation', 0)
        pid_str = data.get('pid', '0')
        try:
            pid = int(pid_str)
        except (TypeError, ValueError):
            pid = 0

        # Zero PID is the sentinel for "never actually spawned" — skip it.
        if pid == 0:
            continue

        alive = _pid_is_alive(pid)
        started_at = data.get('started_at', '')

        # On startup (crash recovery), verify PID ownership to avoid
        # adopting a reused PID that happens to be alive.
        ownership_verified = True
        if verify_ownership and alive:
            ownership_verified = _verify_pid_ownership(pid, started_at, tid)
            if not ownership_verified:
                # PID ownership cannot be confirmed — preserve the last-known
                # generation, clear the stale entry, and do NOT adopt.
                # Never signal an unverified PID.
                _write_last_generation(state_dir, tid, generation)
                try:
                    run_file.unlink()
                except OSError:
                    pass
                continue

        # If the PID is dead, preserve the last-known generation and clear
        # the stale registry entry.
        if not alive:
            _write_last_generation(state_dir, tid, generation)
            try:
                run_file.unlink()
            except OSError:
                pass
            continue

        entries.append({
            'tid': tid,
            'pid': pid,
            'generation': data.get('generation', 0),
            'started_at': started_at,
            'reason': data.get('reason', ''),
            'adopted': True,  # not our child — we didn't fork it
            'phase': '',
            '_alive': alive,
            '_ownership_verified': ownership_verified,
        })

    return entries


def _pid_is_alive(pid):
    """Check whether a PID exists in /proc. Best-effort, not authoritative."""
    try:
        os.kill(pid, 0)
        return True
    except (OSError, ProcessLookupError):
        return False


def _pid_start_time(pid):
    """Read the process start time from /proc/<pid>/stat.

    Returns the start time in clock ticks since boot (field 22 of stat),
    or None if the process doesn't exist or /proc isn't available.
    """
    try:
        stat = Path(f'/proc/{pid}/stat').read_text()
    except (OSError, FileNotFoundError):
        return None
    # Field 22 is starttime — number of clock ticks after system boot.
    # The format is: pid (comm) state ... — the comm field may contain
    # spaces and parens, so we find the closing ')' and parse from there.
    close_paren = stat.rfind(')')
    if close_paren == -1:
        return None
    fields = stat[close_paren + 2:].split()
    if len(fields) < 20:
        return None
    try:
        return int(fields[19])  # starttime is the 20th field after comm
    except (ValueError, IndexError):
        return None


def _boot_time_epoch():
    """Return the system boot time as a Unix epoch (seconds), or None."""
    try:
        raw = Path('/proc/stat').read_text()
    except OSError:
        return None
    for line in raw.splitlines():
        if line.startswith('btime '):
            try:
                return int(line.split()[1])
            except (ValueError, IndexError):
                pass
    return None


def _verify_pid_ownership(pid, registry_started_at_iso, tid=''):
    """Check whether `pid` plausibly belongs to the process described by the
    registry entry.

    Returns True if the process start time is consistent with the registry
    (the process started AFTER the registry was written), plus an optional
    cmdline check that the process's command line mentions the ticket ID.

    A process whose start time is BEFORE the registry was written cannot be
    our worker — it's a PID that was reused.
    """
    if pid == 0:
        return False

    start_ticks = _pid_start_time(pid)
    if start_ticks is None:
        return False  # can't read /proc — unsafe to claim ownership

    boot_epoch = _boot_time_epoch()
    clk_tck = os.sysconf(os.sysconf_names['SC_CLK_TCK'])
    if boot_epoch is None or clk_tck <= 0:
        # Can't compute absolute start time — fall back to cmdline check.
        return _cmdline_contains(pid, tid)

    # Process start epoch = boot_time + (starttime_ticks / clock_ticks_per_sec)
    proc_start_epoch = boot_epoch + (start_ticks / clk_tck)

    # Parse the registry started_at (ISO 8601).
    try:
        reg_dt = datetime.fromisoformat(registry_started_at_iso.replace('Z', '+00:00'))
        reg_epoch = reg_dt.timestamp()
    except (ValueError, OSError):
        return _cmdline_contains(pid, tid)

    # The process must have started AFTER the registry was written.
    # Allow a 5-second grace window for clock skew.
    if proc_start_epoch < (reg_epoch - 5):
        return False

    # Secondary check: cmdline should mention the ticket ID.
    if tid and not _cmdline_contains(pid, tid):
        return False

    return True


def _cmdline_contains(pid, fragment):
    """Check whether /proc/<pid>/cmdline contains `fragment`."""
    if not fragment:
        return True  # nothing to check — caller's choice
    try:
        cmdline = Path(f'/proc/{pid}/cmdline').read_bytes()
        # cmdline is null-separated; replace nulls with spaces for searching.
        return fragment.encode() in cmdline.replace(b'\x00', b' ')
    except OSError:
        return False


# ── Queue depth ────────────────────────────────────────────────────────────

def get_queue_depth(state_dir):
    """Count entries in the spawn queue JSONL file."""
    queue_file = Path(state_dir) / f'fleet-{FLEET_INSTANCE_ID}-spawn-queue.jsonl'
    try:
        if not queue_file.is_file():
            return 0
        # Count non-empty lines.
        with open(queue_file) as f:
            return sum(1 for line in f if line.strip())
    except OSError:
        return 0


# ── Per-worker enrichment readers (group: worker status API) ──────────────

def _sum_tokens(pipeline_log_path):
    """Sum token usage across all META|tokens entries in a pipeline log.

    Each entry's payload has the shape token-tracker.sh writes:
      {PHASE}:{input}/{output}/{cache_read+cache_create}{|elapsed_ms=...}
    All three numeric components of every entry are summed. Returns 0 for a
    missing/empty log or unparseable payloads — a fresh worker has legitimately
    used no tokens yet.
    """
    log_path = Path(pipeline_log_path)
    total = 0
    try:
        if not log_path.is_file():
            return 0
        with open(log_path) as f:
            for line in f:
                if '|META|tokens|' not in line:
                    continue
                parts = line.rstrip('\n').split('|')
                if len(parts) < 5:
                    continue
                msg = '|'.join(parts[4:])
                payload = msg.split('|elapsed_ms=', 1)[0]
                if ':' in payload:
                    payload = payload.split(':', 1)[1]
                for num in payload.split('/'):
                    try:
                        total += int(num)
                    except ValueError:
                        pass
    except OSError:
        return 0
    return total


def _read_confidence_actual(pipeline_log_path):
    """Read confidence_actual from the last META|planner-feedback entry.

    The entry is written once, near/at ticket completion, by
    planned-feedback-write.sh. Returns None (explicit null downstream) until
    that entry exists — never coerced to 0.
    """
    log_path = Path(pipeline_log_path)
    try:
        if not log_path.is_file():
            return None
        last_payload = None
        with open(log_path) as f:
            for line in f:
                if '|META|planner-feedback|' not in line:
                    continue
                parts = line.rstrip('\n').split('|')
                if len(parts) < 5:
                    continue
                last_payload = '|'.join(parts[4:])
        if last_payload is None:
            return None
        data = json.loads(last_payload)
        val = data.get('confidence_actual')
        if val is None:
            return None
        try:
            return float(val)
        except (TypeError, ValueError):
            return None
    except (json.JSONDecodeError, OSError):
        return None


def _read_confidence_predicted(tid, fleet_lib_dir):
    """Read the ticket's predicted confidence from its Planner Context block.

    Shells out to fleet-feedback.sh's _fleet_confidence_predicted — the single
    canonical parser for the Planner Context Confidence field (same extraction
    planned-feedback-write.sh uses when writing META|planner-feedback). One
    Linear API call per invocation; the caller is expected to cache the result.
    Returns a float, or None when the value is unavailable.
    """
    feedback_script = os.path.join(str(fleet_lib_dir), 'fleet-feedback.sh')
    if not os.path.isfile(feedback_script):
        return None
    # tid arrives from HTTP paths and state files — pass it via the
    # environment, never interpolated into shell source (same rule as
    # reconcile_orphaned_tickets).
    bash_cmd = (
        'source "$FLEET_FEEDBACK_SCRIPT" && '
        '_fleet_confidence_predicted "$FLEET_TID"'
    )
    try:
        proc = subprocess.run(
            ['bash', '-c', bash_cmd],
            capture_output=True,
            text=True,
            timeout=30,
            env={
                **os.environ,
                'FLEET_FEEDBACK_SCRIPT': feedback_script,
                'FLEET_TID': tid,
            },
        )
    except (subprocess.TimeoutExpired, OSError):
        return None
    out = (proc.stdout or '').strip()
    if not out or out == 'null':
        return None
    try:
        return float(out)
    except ValueError:
        return None


# ── Health HTTP server ─────────────────────────────────────────────────────

class HealthHandler(http.server.BaseHTTPRequestHandler):
    """HTTP request handler for fleetd's control/query surface.

    GET  /health        — daemon health (documented, unchanged shape)
    GET  /workers       — list of all workers with live status enrichment
    GET  /workers/<tid> — live status for one worker (404 when unknown)
    GET  /queue         — spawn queue contents (entries + malformed lines)
    GET  /epics         — epics fleetd's state dir knows about
    POST /dispatch      — on-demand scoped dispatch of one epic
    POST /stop          — epic-scoped stop (purge + kill + stop-file)

    All other paths → 404. The handler stays a thin delegator — business
    logic lives in the Supervisor, which the server attaches at start.
    """

    # Set by the Supervisor / HealthServer before serving.
    supervisor_state = None
    supervisor = None

    def log_message(self, format, *args):
        """Suppress default stderr logging — fleetd health is polled frequently."""
        pass

    def do_GET(self):
        if self.path == '/health':
            self._handle_health()
        elif self.path == '/workers':
            self._handle_workers()
        elif self.path.startswith('/workers/'):
            self._handle_worker_status(self.path[len('/workers/'):])
        elif self.path == '/queue':
            self._handle_queue()
        elif self.path == '/epics':
            self._handle_epics()
        else:
            self.send_error(404)

    def do_HEAD(self):
        if self.path == '/health':
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
        else:
            self.send_error(404)

    def do_POST(self):
        if self.path == '/dispatch':
            self._handle_dispatch()
        elif self.path == '/stop':
            self._handle_stop()
        else:
            self.send_error(404)

    # ── helpers ────────────────────────────────────────────────────────────

    def _send_json(self, status, payload):
        body = json.dumps(payload).encode('utf-8')
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _read_json_body(self):
        """Parse the request body as JSON. Returns None when absent/invalid."""
        try:
            length = int(self.headers.get('Content-Length', '0') or '0')
        except ValueError:
            return None
        if length <= 0:
            return None
        try:
            data = json.loads(self.rfile.read(length))
        except (json.JSONDecodeError, ValueError):
            return None
        return data if isinstance(data, dict) else None

    def _require_epic_id(self):
        data = self._read_json_body()
        if data is None or not data.get('epic_id'):
            self._send_json(400, {'error': 'epic_id is required'})
            return None
        epic_id = str(data.get('epic_id'))
        if not _ID_RE.match(epic_id):
            self._send_json(400, {'error': f'invalid epic_id: {epic_id!r}'})
            return None
        return data

    # ── GET handlers ───────────────────────────────────────────────────────

    def _handle_health(self):
        state = self.supervisor_state or {}
        workers = state.get('workers', [])
        payload = {
            'workers': workers,
            'worker_count': len(workers),
            'queue_depth': state.get('queue_depth', 0),
            'last_cycle_at': state.get('last_cycle_at'),
            'last_cycle_success': state.get('last_cycle_success'),
            'last_cycle_error': state.get('last_cycle_error'),
            'cycle_count': state.get('cycle_count', 0),
            'last_summary': state.get('last_summary'),
            'pipeline_count': state.get('pipeline_count', 0),
            'observer_findings': state.get('observer_findings', {}),
        }
        self._send_json(200, payload)

    def _handle_workers(self):
        if self.supervisor is None:
            self._send_json(503, {'error': 'supervisor not attached'})
            return
        tids = sorted(self.supervisor.child_tids())
        statuses = []
        for tid in tids:
            status = self.supervisor.get_worker_status(tid)
            if status is not None:
                statuses.append(status)
        self._send_json(200, statuses)

    def _handle_worker_status(self, tid):
        tid = tid.split('?', 1)[0]  # strip query string
        if not _ID_RE.match(tid):
            self._send_json(400, {'error': f'invalid ticket id: {tid!r}'})
            return
        if self.supervisor is None:
            self._send_json(503, {'error': 'supervisor not attached'})
            return
        status = self.supervisor.get_worker_status(tid)
        if status is None:
            self._send_json(
                404, {'error': f'no worker or pipeline log for {tid}'})
            return
        self._send_json(200, status)

    def _handle_queue(self):
        if self.supervisor is None:
            self._send_json(503, {'error': 'supervisor not attached'})
            return
        self._send_json(200, self.supervisor.list_queue())

    def _handle_epics(self):
        if self.supervisor is None:
            self._send_json(503, {'error': 'supervisor not attached'})
            return
        self._send_json(200, self.supervisor.list_epics())

    # ── POST handlers ──────────────────────────────────────────────────────

    def _handle_dispatch(self):
        data = self._require_epic_id()
        if data is None:
            return
        if self.supervisor is None:
            self._send_json(503, {'error': 'supervisor not attached'})
            return
        result = self.supervisor.dispatch_epic(
            str(data.get('epic_id')),
            dry_run=bool(data.get('dry_run', False)),
            resume=bool(data.get('resume', False)),
        )
        self._send_json(200, result)

    def _handle_stop(self):
        data = self._require_epic_id()
        if data is None:
            return
        if self.supervisor is None:
            self._send_json(503, {'error': 'supervisor not attached'})
            return
        result = self.supervisor.stop_epic(
            str(data.get('epic_id')),
            reason=str(data.get('reason') or '')[:500],
        )
        self._send_json(200, result)


class HealthServer:
    """Thin wrapper around http.server.HTTPServer, loopback-bound.

    The HTTP server runs in a daemon thread so the main thread can handle
    signals and call shutdown() from outside the serving thread — this is
    required because HTTPServer.shutdown() must be called from a different
    thread than the one running serve_forever().
    """

    def __init__(self, bind_address='127.0.0.1', port=21001):
        self._bind = bind_address
        self._port = port
        self._httpd = None
        self._thread = None

    def start(self, supervisor):
        """Start serving in a daemon thread.

        Attaches the Supervisor itself (not just its health-state dict) so
        the POST/DETAIL routes can delegate to Supervisor methods. The
        /health handler keeps reading supervisor_state exactly as before.
        """
        HealthHandler.supervisor_state = supervisor._health_state
        HealthHandler.supervisor = supervisor
        self._httpd = http.server.HTTPServer(
            (self._bind, self._port),
            HealthHandler,
        )
        self._thread = threading.Thread(
            target=self._httpd.serve_forever,
            name='fleetd-health',
            daemon=True,
        )
        self._thread.start()

    def shutdown(self):
        """Shut down the HTTP server from the calling (non-serving) thread."""
        if self._httpd:
            self._httpd.shutdown()
            self._httpd.server_close()
            self._httpd = None
        if self._thread and self._thread.is_alive():
            self._thread.join(timeout=2)


# ── Detection cycle ────────────────────────────────────────────────────────

# Default path to the fleet-controller lib directory, resolved relative to
# this file (fleetd/supervisor.py → fleet-controller/lib/).
_DEFAULT_FLEET_LIB = str(Path(__file__).resolve().parent.parent / 'lib')


class CycleCache:
    """Per-cycle cache for detection results and external lookups.

    Created fresh at the start of each detection cycle. Ensures that repeated
    requests for the same data within one cycle (e.g., multiple invocations of
    fleet_detect_all, or overlapping fleet-wide and per-ticket lookups) hit
    the cache rather than re-issuing external API calls.

    The cache is intentionally short-lived — cleared at the start of each
    cycle — so detection always sees fresh state. Caching across cycles
    (e.g., for Linear API rate-limit avoidance) would be a separate concern.
    """

    def __init__(self):
        self._detection_results = {}  # key: workspace → parsed JSON
        self._lookups = {}            # key: (method, url, body_hash) → response
        self._subprocess_count = 0    # for test assertions

    def get_detection(self, workspace):
        return self._detection_results.get(workspace)

    def put_detection(self, workspace, result):
        self._detection_results[workspace] = result

    def get_lookup(self, method, url, body_hash=''):
        return self._lookups.get((method, url, body_hash))

    def put_lookup(self, method, url, body_hash, response):
        self._lookups[(method, url, body_hash)] = response

    def record_subprocess_call(self):
        self._subprocess_count += 1

    @property
    def subprocess_count(self):
        return self._subprocess_count

    def clear(self):
        self._detection_results.clear()
        self._lookups.clear()
        self._subprocess_count = 0


class DetectionCycle:
    """Runs one fleet-detection pass over a workspace.

    Invokes the existing bash detection engines as a subprocess — the same
    code the CLI path runs — so daemon-driven and CLI-driven detection
    produce identical results against identical state.

    Individual detector failures are caught and reported without aborting
    the remaining detectors (fleet_detect_all already handles this — each
    detector's exit code is collected independently).
    """

    def __init__(self, fleet_lib_dir=None, cycle_timeout=120):
        self._lib_dir = fleet_lib_dir or _DEFAULT_FLEET_LIB
        self._timeout = cycle_timeout
        self._last_error = None

    @property
    def last_error(self):
        return self._last_error

    def run(self, workspace, cache=None):
        """Run fleet_detect_all against `workspace` and return parsed JSON.

        If `cache` is provided, checks for a cached result first (same
        workspace within the same cycle). On cache hit, skips the subprocess
        entirely — this is the mechanism that guarantees external lookups
        are not reissued within a cycle.
        """
        ws = str(workspace)
        if cache is not None:
            cached = cache.get_detection(ws)
            if cached is not None:
                return cached

        detect_script = os.path.join(self._lib_dir, 'fleet-detect.sh')
        if not os.path.isfile(detect_script):
            self._last_error = f"detection script not found: {detect_script}"
            return None

        # Build a bash invocation that sources the detection library then
        # calls fleet_detect_all. The script resolves its own dependencies
        # (fleet-config.sh etc.) relative to its location on disk.
        bash_cmd = (
            f'source "{detect_script}" && fleet_detect_all "{ws}"'
        )

        if cache is not None:
            cache.record_subprocess_call()

        try:
            proc = subprocess.run(
                ['bash', '-c', bash_cmd],
                capture_output=True,
                text=True,
                timeout=self._timeout,
                env={**os.environ, 'FLEET_PIPELINE_LOG_DIR': ws},
            )
        except subprocess.TimeoutExpired:
            self._last_error = f"detection cycle timed out after {self._timeout}s"
            return None
        except OSError as exc:
            self._last_error = f"failed to invoke detection: {exc}"
            return None

        if proc.returncode != 0:
            stderr_tail = proc.stderr.strip().split('\n')[-3:] if proc.stderr else []
            self._last_error = (
                f"detection exited {proc.returncode}: "
                + '; '.join(stderr_tail)
            )
            # Non-zero exit does not necessarily mean no data — some detectors
            # may still have produced valid output. Try to parse what we got.
            if not proc.stdout.strip():
                return None

        try:
            result = json.loads(proc.stdout)
        except json.JSONDecodeError as exc:
            self._last_error = f"invalid detection JSON: {exc}"
            return None

        self._last_error = None
        if cache is not None:
            cache.put_detection(ws, result)
        return result


def _write_stop_files(tid, state_dir):
    """Touch the cooperative-stop files the worker's spawn-helper.sh watches.

    Idempotent — touching files that already exist is harmless.
    Uses the same path conventions as fleet-config.sh's _fleet_stop_file().
    """
    state = Path(state_dir)
    for stop_type in ('pinger', 'watchdog'):
        stop_file = state / f'ticket-auto-{tid}-{stop_type}-stop'
        try:
            stop_file.touch()
        except OSError:
            pass


# ── State store (fail-soft) ────────────────────────────────────────────────
# fleetd is the store's sole writer, and every call below is wrapped so that a
# store failure degrades fleet-controller to its pre-store behaviour instead of
# taking the supervisor down with it. Losing the store costs a slower cold
# start; losing the supervisor loses the fleet.

FLEET_STORE_ENABLE = os.environ.get('FLEET_STORE_ENABLE', 'true') != 'false'

_STORE_WARNED = set()


def _store_warn(message):
    """Warn once per distinct message — a per-cycle failure must not become a
    per-cycle log flood."""
    if message in _STORE_WARNED:
        return
    _STORE_WARNED.add(message)
    print(f'fleetd[{os.getpid()}]: state store unavailable — {message}',
          file=sys.stderr)


def _store_do(state_dir, action, what):
    """Run `action(store)` against the state store, swallowing every failure.

    Short-lived connections rather than one long-held handle: these calls are
    rare (spawn, exit, kill, one ingest per detection cycle), fleetd is the
    only writer process, and not holding a connection across the daemon's
    lifetime removes a whole class of stale-handle bug.
    """
    if not FLEET_STORE_ENABLE or _store_mod is None:
        return None
    st = None
    try:
        st = _store_mod.open_store(state_dir)
        return action(st)
    except Exception as exc:  # noqa: BLE001 - deliberately total
        _store_warn(f'{what}: {exc}')
        return None
    finally:
        if st is not None:
            try:
                st.close()
            except Exception:  # noqa: BLE001
                pass


def _store_bootstrap(state_dir):
    """First-start adoption: take over the JSON file conventions the store
    replaces, then project the existing logs.

    Runs on every start, not just the first: it is idempotent, and it is also
    the recovery path for a deleted database — in-flight tickets are recovered
    from the registry files and the logs rather than orphaned.
    """
    def _run(st):
        imported = st.import_legacy_state(state_dir)
        counts = st.ingest_workspace(state_dir)
        return imported, counts
    return _store_do(state_dir, _run, 'bootstrap')


def _store_sync(state_dir):
    """Project any log lines written since the last cycle.

    Runs before detection so the engines read a store that is current. Only
    unread bytes are parsed, which is the cost the store removes: the old path
    re-parsed every log on every sweep.
    """
    return _store_do(state_dir, lambda st: st.ingest_workspace(state_dir), 'sync')


def _store_record_spawn(state_dir, tid, pid, generation, reason, session_id,
                        phase=''):
    return _store_do(
        state_dir,
        lambda st: st.record_worker_spawn(
            tid, pid, generation=generation, phase=phase, reason=reason,
            session_id=session_id or '',
            start_ticks=str(_pid_start_time(pid) or '')),
        'record spawn')


def _store_record_exit(state_dir, tid, pid, exit_code, exit_type,
                       killed_by_fleet=False):
    def _run(st):
        for worker in st.running_workers(tid):
            if worker['pid'] == pid:
                st.record_worker_exit(
                    worker['id'], exit_code=exit_code, exit_type=exit_type,
                    status='killed' if killed_by_fleet else 'exited')
                return worker['id']
        return None
    return _store_do(state_dir, _run, 'record exit')


def _store_record_fence(state_dir, tid, generation):
    return _store_do(state_dir, lambda st: st.set_fence(tid, generation),
                     'record fence')


def _store_finding_counts(state_dir):
    """{severity: count} across every ticket's findings (agent-observer Inc 4).

    Returns {} — not None — on any store failure, so `_health_state`'s
    default of {} is what `/health` serves rather than a stale prior value;
    a finding count going briefly blank on a store hiccup is honest, a
    frozen wrong number is not.
    """
    result = _store_do(
        state_dir,
        lambda st: {
            row['severity']: row['n']
            for row in st.conn.execute(
                'SELECT severity, COUNT(*) AS n FROM findings GROUP BY severity')
        },
        'finding counts')
    return result if result is not None else {}


def _store_record_position(state_dir, tid, step_id, source='dispatch'):
    """Record `tid`'s dispatch position (task 4.3, design.md D7).

    Called at the moment fleetd decides to spawn `step_id` — recording is
    strictly simpler than reconstructing, since the supervisor performing
    the dispatch already knows where it is. `source='dispatch'` here always;
    `'adopted'` is written only once, by `phase_dispatch.resolve_dispatch_position`
    for a ticket a human started manually.
    """
    return _store_do(
        state_dir,
        lambda st: st.record_position(tid, step_id, source=source),
        'record position')


def _store_get_position(state_dir, tid):
    return _store_do(state_dir, lambda st: st.get_position(tid),
                     'get position')


def _store_ticket_is_held(state_dir, tid):
    """Whether `tid`'s row currently has `held = 1`.

    Routed through `_store_do` like every other store call: a missing or
    disabled store degrades to "not held" rather than blocking dispatch —
    the guard's absence must never be the thing that stalls a ticket.
    """
    def _run(st):
        row = st.get_ticket(tid)
        return bool(row and row.get('held'))
    return bool(_store_do(state_dir, _run, 'held check'))


def _store_held_tickets(state_dir):
    return _store_do(state_dir, lambda st: st.held_tickets(), 'held tickets') or []


def _store_release_hold(state_dir, tid, hold_id):
    return _store_do(state_dir, lambda st: st.release_hold(tid, hold_id),
                     'release hold')


# ── OTel exporter lifecycle (D11, task 8.5) ────────────────────────────────
# The exporter is supervised with the same primitives as any other worker —
# fork/exec via spawn_worker, a run-registry entry, ChildReaper reaping, kill
# escalation — rather than bespoke process management for exactly one process.
#
# Everything here is fail-soft. A telemetry process that cannot start must not
# stop fleetd supervising tickets: that is the whole point of the exporter being
# downstream of the pipeline rather than in it.

#: Backoff after a crash, in seconds. Bounded and coarse — an exporter that
#: cannot start at all (no SDK, no collector, bad config) must not spin.
_OTEL_RESPAWN_BACKOFF = (5, 30, 120, 600)


def otel_service_id():
    """Fixed run-registry identifier. Not a ticket id, and the reap path
    branches on it so an exporter exit is never mistaken for a ticket dying."""
    return _otel_mod.SERVICE_ID if _otel_mod is not None else 'otel-exporter'


def otel_enabled():
    """True only when the operator opted in AND the module is importable."""
    if _otel_mod is None:
        return False
    try:
        return _otel_mod.exporter_enabled()
    except Exception:
        return False


def _otel_cmd(log_dir):
    """argv for the exporter child.

    Runs otel.py as a plain script, by absolute path, rather than as
    `-m fleetd.otel`. The child is exec'd with fleetd's *environment*, not its
    sys.path, so a `-m` invocation would need `fleet-controller/` on PYTHONPATH
    and would die with ModuleNotFoundError wherever fleetd happens to have been
    started from. otel.py imports nothing but the standard library precisely so
    this works from any working directory.
    """
    script = Path(__file__).resolve().parent / 'otel.py'
    return [sys.executable, str(script), '--log-dir', str(log_dir)]


#: Same shape as _OTEL_RESPAWN_BACKOFF — a sidecar that cannot start at all
#: (bad log dir, permissions) must not spin either.
_OBSERVER_RESPAWN_BACKOFF = (5, 30, 120, 600)


def observer_service_id():
    """Fixed run-registry identifier. Not a ticket id, and the reap path
    branches on it so an observer exit is never mistaken for a ticket dying."""
    return _observer_mod.SERVICE_ID if _observer_mod is not None else 'agent-observer'


def observer_enabled_for_sidecar():
    """True only when the operator opted in AND the module is importable.

    Named distinctly from the module-level `FLEET_OBSERVER_ENABLE` constant
    (which gates the phase-spawn `--output-format` switch, read once at
    import time) — this re-reads the env var on every call, the same
    always-current pattern `otel_enabled()` uses, so toggling the flag at
    runtime is reflected without a fleetd restart for the sidecar's own
    spawn/stop decisions.
    """
    if _observer_mod is None:
        return False
    try:
        return _observer_mod.observer_enabled()
    except Exception:
        return False


def _observer_cmd(log_dir):
    """argv for the observer child. Same rationale as `_otel_cmd`: a plain
    script by absolute path, never `-m fleetd.observer`, so it execs
    correctly regardless of fleetd's own working directory or sys.path."""
    script = Path(__file__).resolve().parent / 'observer.py'
    return [sys.executable, str(script), '--log-dir', str(log_dir)]


def _write_fence_files(tid, generation, state_dir):
    """Write a generation fence marker so the next spawn uses a higher generation.

    Written to both the store (authoritative for fleetd) and the marker file
    (which flow.sh's fence guard still reads from inside a worker). The file
    stays until every consumer reads the store — dropping it here would let a
    superseded worker's Linear mutations through, which is the one thing the
    fence exists to prevent.
    """
    _store_record_fence(state_dir, tid, generation)
    fence_file = Path(state_dir) / f'{tid}-fence'
    entry = {
        'tid': tid,
        'fenced_generation': generation,
        'fenced_at': datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
    }
    try:
        fence_file.write_text(json.dumps(entry))
    except OSError:
        pass


# ── Worker exit persistence (worker-reap-recovery) ─────────────────────────

FLEET_WORKER_LOG_RETENTION = _env_int('FLEET_WORKER_LOG_RETENTION', 3)

# Agent Observer (design.md D8): a separate retention count for the
# phase-slugged {tid}-{phase}-gen{N}.json/.ndjson/.stderr files, since a
# .ndjson capture can be far larger than the .json it replaces.
FLEET_OBSERVER_LOG_RETENTION = _env_int('FLEET_OBSERVER_LOG_RETENTION', 3)


def _append_pipeline_log_line(state_dir, tid, phase, step, status, msg):
    """Append one ISO|PHASE|STEP|STATUS|MSG line to {tid}-pipeline.log.

    Python mirror of the bash `_plog` writer (heartbeat.sh) — same schema,
    same timestamp format — so every existing consumer (detectors,
    detect-resume.sh, the dashboard, /ticket-overseer) reads this exactly
    like any other pipeline-log entry. Fail-soft: a logging failure must
    never interrupt reap-time recovery.
    """
    log_file = Path(state_dir) / f'{tid}-pipeline.log'
    iso = datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
    # MSG must not contain '|' — would corrupt the pipe-delimited format,
    # mirroring _plog's own guard.
    msg = msg.replace('|', '/')
    try:
        with open(log_file, 'a') as f:
            f.write(f'{iso}|{phase}|{step}|{status}|{msg}\n')
    except OSError:
        pass


def _write_exit_record(state_dir, tid, generation, pid, exit_code, exit_type,
                       killed_by_fleet, terminal, session_id=None,
                       last_assistant_message=None, action=None,
                       suppressed_retry_reason=None, cost_usd=None):
    """Write {tid}-gen{N}-exit.json — per-generation, no shared-write races.

    Follows the same per-ticket no-shared-write pattern as
    `_write_run_registry`. Fail-soft on OSError: a missing exit record
    degrades to today's behaviour of recording nothing (Migration Plan).
    Returns the entry dict regardless of whether the write succeeded, so
    callers (and later hook-driven merges) can still act on it in memory.

    `cost_usd` (float or `None`) is the worker's `total_cost_usd` as
    extracted by `worker_cost_usd` — the same lookup used for the
    `runs.jsonl` `cost` event (fleet-cost-events capability).
    """
    exit_file = Path(state_dir) / f'{tid}-gen{generation}-exit.json'
    entry = {
        'tid': tid,
        'generation': generation,
        'pid': pid,
        'exit_code': exit_code,
        'exit_type': exit_type,
        'exited_at': datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
        'killed_by_fleet': killed_by_fleet,
        'terminal': terminal,
        'session_id': session_id,
        'last_assistant_message': last_assistant_message,
        'action': action,
        'cost_usd': cost_usd,
    }
    if suppressed_retry_reason:
        entry['suppressed_retry_reason'] = suppressed_retry_reason
    try:
        exit_file.write_text(json.dumps(entry))
    except OSError:
        pass
    return entry


# ── Cost events (fleet-cost-events) ────────────────────────────────────────

def _worker_gen_file(state_dir, tid, phase, generation):
    """The stdout envelope path for a worker — mirrors spawn_worker's own slug.

    A phase-level worker's stdout is `.ndjson` instead of `.json` when it was
    spawned under `FLEET_OBSERVER_ENABLE=true` (see `spawn_worker`). The flag
    read now may not match the one in effect at that spawn (toggled mid-run,
    or fleetd restarted with a different value), so this checks which file
    actually exists rather than trusting the current flag value. A
    ticket-level worker (`phase` falsy) is never affected — always `.json`.
    """
    slug = f'{tid}-{phase.lower()}' if phase else tid
    base = Path(state_dir) / f'{slug}-gen{generation}'
    if phase:
        ndjson_path = base.with_suffix('.ndjson')
        if ndjson_path.is_file():
            return ndjson_path
    return base.with_suffix('.json')


def _last_run_id_for_generation(state_dir, tid, generation):
    """The last `META|run-id` line's run_id, iff its `gen` matches.

    A generation mismatch (a stale run-id line from a prior generation
    still sitting as "last" due to a race) yields `None` rather than
    mis-attributing a cost event to the wrong run (design.md Decision 3).
    """
    log_file = Path(state_dir) / f'{tid}-pipeline.log'
    try:
        lines = log_file.read_text().splitlines()
    except OSError:
        return None
    for line in reversed(lines):
        parts = line.split('|', 4)
        if len(parts) == 5 and parts[1] == 'META' and parts[2] == 'run-id':
            try:
                payload = json.loads(parts[4])
            except (ValueError, TypeError):
                return None
            if payload.get('gen') == generation:
                return payload.get('run_id')
            return None
    return None


def _append_runs_event(state_dir, event):
    """Append one JSON line to runs.jsonl, flock-guarded, fail-soft.

    Mirrors `run-summary.sh`'s bash `runs_append` — same lock-file naming,
    same append-only target — so bash and Python writers serialize against
    the same file. Bounded wait (5s) rather than a blocking flock, so a
    stuck writer elsewhere can never stall a reap or fleet-kill.
    """
    runs_file = Path(state_dir) / 'runs.jsonl'
    try:
        lock_fd = os.open(f'{runs_file}.lock', os.O_CREAT | os.O_WRONLY, 0o644)
    except OSError:
        return
    try:
        deadline = time.monotonic() + 5
        locked = False
        while time.monotonic() < deadline:
            try:
                fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                locked = True
                break
            except OSError:
                time.sleep(0.05)
        if not locked:
            return
        try:
            with open(runs_file, 'a') as f:
                f.write(json.dumps(event) + '\n')
        except OSError:
            pass
        finally:
            try:
                fcntl.flock(lock_fd, fcntl.LOCK_UN)
            except OSError:
                pass
    finally:
        os.close(lock_fd)


def _record_cost_event(state_dir, tid, generation, phase, cost_usd):
    """Append a `cost` event to runs.jsonl when a cost value was found.

    No-op when `cost_usd` is `None` — a missing cost is an honest gap, not
    an error, and produces no event at all (design.md).
    """
    if cost_usd is None:
        return
    _append_runs_event(state_dir, {
        'kind': 'cost',
        'tid': tid,
        'run_id': _last_run_id_for_generation(state_dir, tid, generation),
        'gen': generation,
        'phase': phase or None,
        'usd': cost_usd,
        'observed_at': datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
    })


def _read_hook_capture(state_dir, tid, generation):
    """Read {tid}-gen{N}-hook.json, written by the Stop hook (stop-capture.sh).

    Returns {} when absent — `Stop` fires on neither SIGINT nor SIGKILL, so
    a missing capture file is the expected case for those rungs, not an
    error (task 6.4). Best-effort: any parse failure degrades to {} rather
    than blocking exit-record persistence.
    """
    hook_file = Path(state_dir) / f'{tid}-gen{generation}-hook.json'
    try:
        return json.loads(hook_file.read_text())
    except (OSError, json.JSONDecodeError):
        return {}


def _update_exit_record_action(state_dir, tid, generation, action):
    """Best-effort update of an already-written exit record's `action` field.

    Used after reap-time recovery has actually attempted reconciliation for
    a tid, so the record reflects what fleetd did, not just what it decided
    to do at reap time. Never raises — a missing/unreadable record is a
    no-op, not an error.
    """
    exit_file = Path(state_dir) / f'{tid}-gen{generation}-exit.json'
    try:
        entry = json.loads(exit_file.read_text())
        entry['action'] = action
        exit_file.write_text(json.dumps(entry))
    except (OSError, json.JSONDecodeError):
        pass


def _notify_worker_event(fleet_lib_dir, state_dir, tid, event_type, detail=''):
    """Fire the deterministic Slack notifier for a non-terminal worker exit.

    Shells out to fleet-notify.sh (bash `curl`, per design.md Decision 7) so
    the transport is shared with the bash-side dead-letter call site in
    fleet-reconcile.sh. Fail-soft: an absent script, a missing SLACK_* env,
    or a transport failure must never affect reaping or reconciliation.
    """
    notify_script = Path(fleet_lib_dir) / 'fleet-notify.sh'
    if not notify_script.is_file():
        return
    try:
        subprocess.run(
            ['bash', '-c',
             f'source {shlex.quote(str(notify_script))} && '
             f'fleet_notify_worker_event {shlex.quote(tid)} '
             f'{shlex.quote(str(state_dir))} {shlex.quote(event_type)} '
             f'{shlex.quote(detail)}'],
            timeout=15, capture_output=True,
        )
    except (OSError, subprocess.SubprocessError):
        pass


def _sweep_stale_generation_files(state_dir, tid, current_generation,
                                  retention=None, phase='',
                                  phase_retention=None):
    """Delete gen/.stderr/-exit.json files older than the retention window.

    Per-generation worker output is otherwise unbounded — Increment A ships
    the sweep alongside capture rather than deferring it (tasks.md 3.12).
    Keeps the most recent `retention` generations (default
    FLEET_WORKER_LOG_RETENTION); best-effort, never raises.

    `phase` (agent-observer design.md D8): a pre-existing leak — this only
    ever matched `{tid}-gen{N}{suffix}`, never the phase-slugged
    `{tid}-{phase}-gen{N}.json`/`.ndjson`/`.stderr` a phase-level spawn_worker
    call writes (`spawn_worker`'s `slug`) — is fixed in the same increment
    that introduces `.ndjson` (Inc 2), not carried forward as new debt, since
    a `.ndjson` capture can be far larger than the `.json` it replaces.
    `phase_retention` defaults to `FLEET_OBSERVER_LOG_RETENTION` — a
    separate knob from the ticket-level `retention`, since an operator may
    want the larger phase-level captures aged out faster. The exit-record
    file has no phase-slugged form (`_write_exit_record` takes no `phase`
    argument), so only `.json`/`.ndjson`/`.stderr` are swept here, never
    `-exit.json`.
    """
    keep = retention if retention is not None else FLEET_WORKER_LOG_RETENTION
    cutoff = current_generation - keep
    state = Path(state_dir)
    if cutoff >= 1:
        for suffix in ('.json', '.stderr', '-exit.json'):
            for gen in range(1, cutoff + 1):
                stale = state / f'{tid}-gen{gen}{suffix}'
                try:
                    stale.unlink()
                except OSError:
                    pass

    if not phase:
        return
    p_keep = (phase_retention if phase_retention is not None
             else FLEET_OBSERVER_LOG_RETENTION)
    p_cutoff = current_generation - p_keep
    if p_cutoff < 1:
        return
    slug = f'{tid}-{phase.lower()}'
    for suffix in ('.json', '.ndjson', '.stderr'):
        for gen in range(1, p_cutoff + 1):
            stale = state / f'{slug}-gen{gen}{suffix}'
            try:
                stale.unlink()
            except OSError:
                pass


# ── Kill escalation ────────────────────────────────────────────────────────

KILL_ESCALATION_ORDER = ('cooperative', 'SIGINT', 'SIGTERM', 'SIGKILL')


def _try_reap(pid):
    """Reap a specific child if it has exited. Returns True if reaped.

    After sending SIGKILL, the process may be dead but still exist as a
    zombie until the parent calls waitpid. A zombie responds to kill(pid, 0)
    as "alive", so we must reap before checking liveness.
    """
    try:
        wpid, _status = os.waitpid(pid, os.WNOHANG)
        return wpid == pid
    except ChildProcessError:
        return True  # No such child — definitely dead


def kill_worker(tid, pid, generation, state_dir, reason='fleet-kill',
                grace_secs=None):
    """Escalate: cooperative stop → grace → SIGINT → grace → SIGTERM → grace → SIGKILL.

    Each step verifies the process is still alive before proceeding.
    - Cooperative stop: touch stop files, wait grace, check.
    - SIGINT: signal the process group, wait grace, check.
    - SIGTERM: signal the process group, wait grace, check.
    - SIGKILL: signal the process group, brief wait, check.

    Returns a KillResult: (success: bool, method: str, error: str|None).

    Signals target the process GROUP (not just the PID) because the worker
    spawns subprocesses (git, CLI tools, test runners) and those must
    terminate with the worker.

    What the SIGINT rung actually buys, per observation (worker-reap-recovery
    validation, not assumption): it ends the in-progress turn and produces a
    `result` line with a `session_id` over a finalized transcript, which
    SIGTERM does not — SIGTERM leaves the turn unfinished with no result
    recorded. It does NOT yield readable output: the observed subtype is
    `error_during_execution`, whose `result` field is documented as
    unavailable, `stop_reason` was `null`, and there was no text. It also
    does NOT fire the `Stop` hook, so Increment B's final-message capture
    yields nothing on this rung — do not build anything that reads output
    from a SIGINT-terminated worker. The rung is still worth having: a
    finalized transcript is strictly better than an abandoned turn for
    `--resume` and post-mortem.

    Empirically, SIGINT terminates a `-p` worker with exit 0 — this rung is
    only safe alongside kill-attribution sourced from fleetd's own call
    succeeding (never from an exit code): without it, every SIGINT-killed
    worker would look exactly like an exit-0 orphan and be re-enqueued by
    reap-time recovery. See Supervisor._record_fleet_kill_exit.
    """
    grace = grace_secs if grace_secs is not None else _env_int('FLEET_KILL_GRACE_SECS', 10)

    def _is_dead():
        """Check whether the worker is dead, reaping first to catch zombies."""
        if _try_reap(pid):
            return True
        return not _pid_is_alive(pid)

    # ── Step 1: cooperative stop ──────────────────────────────────────────
    _write_stop_files(tid, state_dir)
    time.sleep(grace)

    if _is_dead():
        _write_fence_files(tid, generation, state_dir)
        return KillResult(True, 'cooperative', None)

    # ── Step 2: SIGINT to process group ─────────────────────────────────────
    _signal_process_group(pid, signal.SIGINT)
    time.sleep(grace)

    if _is_dead():
        _write_fence_files(tid, generation, state_dir)
        return KillResult(True, 'SIGINT', None)

    # ── Step 3: SIGTERM to process group ──────────────────────────────────
    _signal_process_group(pid, signal.SIGTERM)
    time.sleep(grace)

    if _is_dead():
        _write_fence_files(tid, generation, state_dir)
        return KillResult(True, 'SIGTERM', None)

    # ── Step 4: SIGKILL to process group ──────────────────────────────────
    _signal_process_group(pid, signal.SIGKILL)
    time.sleep(1)  # Brief wait for kernel to reap

    if _is_dead():
        _write_fence_files(tid, generation, state_dir)
        return KillResult(True, 'SIGKILL', None)

    # ── Unkillable ────────────────────────────────────────────────────────
    return KillResult(False, 'SIGKILL',
                      f'PID {pid} survived full escalation for {tid}')


class KillResult:
    """Outcome of a kill escalation."""
    __slots__ = ('success', 'method', 'error')

    def __init__(self, success, method, error):
        self.success = success
        self.method = method
        self.error = error

    def __repr__(self):
        return f'KillResult(success={self.success}, method={self.method!r}, error={self.error!r})'


def _signal_process_group(pid, sig):
    """Send a signal to the process group whose leader is `pid`.

    Falls back to signalling the process directly if the process group
    doesn't exist (e.g., the worker already exited between the liveness
    check and this call).
    """
    try:
        os.killpg(pid, sig)
    except ProcessLookupError:
        pass  # Already dead — that's fine.
    except PermissionError:
        # Process group exists but we can't signal it — try direct signal.
        try:
            os.kill(pid, sig)
        except ProcessLookupError:
            pass


# ── Spawn configuration ────────────────────────────────────────────────────

FLEETD_SPAWN_ENABLED = os.environ.get('FLEETD_SPAWN_ENABLED', '') == '1'
FLEET_MAX_CONCURRENT = _env_int('FLEET_MAX_CONCURRENT', 3)
# Cycles between periodic merge-poll sweeps in run_observe (fleet-merge-poll-
# cadence) — the async complement to pipeline-finalize.sh's one-shot sweep,
# catching PRs that merge after the pipeline process has already exited.
FLEET_MERGE_POLL_CYCLES = _env_int('FLEET_MERGE_POLL_CYCLES', 10)
CLAUDE_BIN = os.environ.get('CLAUDE_BIN', 'claude')
# Full worker command line (binary + leading args), e.g. "claude-deepseek 2 --bypass".
# Takes precedence over CLAUDE_BIN when set. The ticket-auto invocation
# (`-p '/ticket-auto {tid} ...'`) is always appended after it.
CLAUDE_CMD = os.environ.get('CLAUDE_CMD', '')

# pylint: disable=invalid-name


# ── Spawn queue consumer ───────────────────────────────────────────────────

def _parse_queue_with_malformed(state_dir):
    """Parse the spawn queue JSONL into (entries, malformed_lines).

    The single canonical parse of the queue file — `_read_queue_entries`
    (consume time) and `GET /queue` (read time) both go through it, so the
    two views can never diverge. Malformed lines are reported, not silently
    dropped. A missing file parses as empty.
    """
    entries = []
    malformed = []
    queue_file = Path(state_dir) / f'fleet-{FLEET_INSTANCE_ID}-spawn-queue.jsonl'
    try:
        if not queue_file.is_file():
            return entries, malformed
        with open(queue_file) as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    entry = json.loads(line)
                except json.JSONDecodeError:
                    malformed.append(line)
                    continue
                if entry.get('tid', ''):
                    entries.append(entry)
    except OSError:
        pass
    return entries, malformed


def _read_queue_entries(state_dir):
    """Yield parsed entries from the spawn queue JSONL file.

    Skips malformed entries (unparseable JSON, missing tid) so they do not
    halt queue consumption. Callers should remove consumed entries by
    rewriting the file.
    """
    entries, malformed = _parse_queue_with_malformed(state_dir)
    for line in malformed:
        # Malformed entry — skip, don't halt consumption.
        print(f"fleetd: skipping malformed queue entry: {line[:80]}...",
              file=sys.stderr)
    yield from entries


def _remove_consumed_entries(state_dir, consumed_tids):
    """Rewrite the spawn queue without entries whose TIDs are in `consumed_tids`.

    The read-modify-rewrite is serialized against concurrent appends with the
    SAME sidecar lock file the bash append path uses
    (`{queue}.lock`, see _fleet_queue_append in fleet-dispatch.sh). Without the
    lock, a dispatch append landing between fleetd's read and its rename was
    silently lost — the ticket was never spawned and never dead-lettered.
    The file is re-read under the lock so entries appended since the initial
    (unlocked) scan are kept rather than clobbered.
    """
    if not consumed_tids:
        return
    queue_file = Path(state_dir) / f'fleet-{FLEET_INSTANCE_ID}-spawn-queue.jsonl'
    if not queue_file.is_file():
        return

    lock_file = Path(str(queue_file) + '.lock')
    kept = []
    with open(lock_file, 'a') as lock_fd:
        fcntl.flock(lock_fd.fileno(), fcntl.LOCK_EX)
        try:
            with open(queue_file) as f:
                for line in f:
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        entry = json.loads(line)
                    except json.JSONDecodeError:
                        kept.append(line)
                        continue
                    if entry.get('tid', '') not in consumed_tids:
                        kept.append(line)

            if kept:
                tmp = Path(str(queue_file) + '.tmp.' + str(os.getpid()))
                tmp.write_text('\n'.join(kept) + '\n')
                tmp.rename(queue_file)
            else:
                queue_file.unlink()
        finally:
            fcntl.flock(lock_fd.fileno(), fcntl.LOCK_UN)


# ── Worker spawning ────────────────────────────────────────────────────────

def _write_run_registry(state_dir, tid, pid, generation, reason='dispatched',
                        session_id=None, start_ticks=None, phase=''):
    """Write a run registry entry with the REAL pid (not a sentinel).

    `start_ticks` is field 22 of `/proc/<pid>/stat` — the process start time
    in clock ticks since boot. Readers pair it with the pid to defeat PID
    reuse: `kill -0` succeeds for whatever process now occupies a recycled
    pid, but its start ticks will not match the one recorded here. The guard
    in `_ticket_worker_alive` (detect-resume.sh) tolerates the field being
    absent, so omitting it does not break a reader — it silently disarms it,
    which is why this is written unconditionally on Linux rather than
    opportunistically.
    """
    # A phase worker gets its own `{tid}-{phase}-run.json` rather than
    # overwriting the ticket-level file: several phases run in sequence under
    # one ticket, and a reader asking "is anything working on this ticket"
    # must see the live phase, not the last one to finish. `_ticket_worker_alive`
    # (detect-resume.sh) already globs both shapes.
    suffix = f'-{phase.lower()}' if phase else ''
    run_file = Path(state_dir) / f'{tid}{suffix}-run.json'
    entry = {
        'tid': tid,
        'pid': str(pid),
        'generation': generation,
        'started_at': datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
        'reason': reason,
    }
    if session_id:
        entry['session_id'] = session_id
    if start_ticks:
        entry['start_ticks'] = str(start_ticks)
    if phase:
        entry['phase'] = phase
    run_file.write_text(json.dumps(entry))


# Non-interactive subprocess environment. A `-p` worker has no TTY and no
# human to answer a credential or hostkey prompt — without these, a git
# operation or a tool expecting a terminal can hang the worker indefinitely
# with no exit code for the reaper to ever see.
_NON_INTERACTIVE_ENV = {
    'GIT_TERMINAL_PROMPT': '0',
    'GIT_ASKPASS': '/bin/true',
    'SSH_ASKPASS': '/bin/true',
    'GIT_SSH_COMMAND': 'ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new',
    'DEBIAN_FRONTEND': 'noninteractive',
    'CI': 'true',
    'PAGER': 'cat',
    'GIT_PAGER': 'cat',
    'NO_COLOR': '1',
}

# `bypassPermissions` pairs with scoped `disallowedTools` deny rules — deny
# rules bind even under bypass, whereas `allowedTools` does not constrain
# bypass. `dontAsk` is deliberately not used (denies every tool requiring
# user interaction even when an allow rule matches); `auto` is deliberately
# not used (in a non-interactive session there is no turn boundary, so one
# classifier denial is reused for the rest of the run and the run does not
# stop — see design.md Decision 9).
FLEET_WORKER_PERMISSION_MODE = os.environ.get(
    'FLEET_WORKER_PERMISSION_MODE', 'bypassPermissions')
FLEET_WORKER_DISALLOWED_TOOLS = os.environ.get('FLEET_WORKER_DISALLOWED_TOOLS', '')

# Agent Observer (design.md D6, D9). False (the default) leaves fleetd
# byte-identical to today: phase workers spawn with --output-format json, the
# same as a ticket-level worker. True flips *phase-level* spawns only
# (never ticket-level /ticket-auto workers, see _build_worker_cmd's
# is_phase_worker parameter) to --output-format stream-json --verbose,
# writing NDJSON to a .ndjson stdout file instead of .json.
FLEET_OBSERVER_ENABLE = os.environ.get('FLEET_OBSERVER_ENABLE', 'false') == 'true'

# Markers indicating CLAUDE_CMD already supplies its own permission mode —
# fleetd must not double-specify (the CLI rejects conflicting/duplicate
# permission flags).
_PERMISSION_FLAG_MARKERS = (
    '--permission-mode', '--dangerously-skip-permissions', '--bypass',
)


def _cmd_already_sets_permission_mode(cmd_str):
    return any(marker in cmd_str for marker in _PERMISSION_FLAG_MARKERS)


def _cmd_already_sets_agent(cmd_str):
    return '--agent' in cmd_str


def _build_worker_cmd(tid, claude_bin=None, claude_cmd=None, session_id=None,
                      prompt=None, agent=None, is_phase_worker=False):
    """Build the argument list for spawning a worker.

    `prompt` replaces the default whole-ticket `/ticket-auto` invocation with
    a single-phase one built by `phase_dispatch.build_phase_spawn` (task 4.4).
    Only the `-p` payload differs: session id, output format and permission
    handling are identical, because a phase worker is the same kind of
    headless session as a ticket worker — it simply runs one step of the
    pipeline instead of all of them.

    `agent` is the dispatch table's per-step `spawn.agent` (a plugin-scoped
    subagent type, e.g. `ticket-auto-pipeline:ticket-implement-agent`),
    passed through as `--agent` so the phase worker's tool allowlist and
    system prompt (`ticket-auto-pipeline/agents/*.md`) actually bind — the
    mirror of the manual router passing `AGENT_TYPE` to the `Agent` tool's
    `subagent_type`. None for a whole-ticket worker (the router needs every
    tool to dispatch its own phases) and for any step with no dedicated
    agent type yet. Skipped when `claude_cmd`/CLAUDE_CMD already specifies
    `--agent` — same override precedence as permission mode.

    `claude_cmd` (or the CLAUDE_CMD env var) is a shell-style command line —
    e.g. "claude-deepseek 2 --bypass" — that replaces the bare binary name
    and takes precedence over `claude_bin`/CLAUDE_BIN. The ticket-auto
    invocation is always appended after it.

    `--output-format json` yields session_id, subtype, stop_reason,
    total_cost_usd and permission_denials on the final object — one `jq`
    call. `is_phase_worker` (set by `spawn_phase_worker`/`spawn_phase` only —
    never a whole-ticket `/ticket-auto` spawn) combined with
    `FLEET_OBSERVER_ENABLE=true` (Agent Observer, design.md D6/D9) switches
    this to `--output-format stream-json --verbose` instead, so `observer.py`
    has a per-tool-call NDJSON stream to tail; the caller (`spawn_worker`)
    is responsible for giving that stream a distinct `.ndjson` stdout file,
    since the reader (`worker_return_text`) and the sweep
    (`_sweep_stale_generation_files`) both key off the extension. `False`/
    disabled leaves every worker byte-identical to pre-Observer behavior.
    `--session-id` is generated by the caller before exec so the --resume
    handle exists even for a worker SIGKILLed before any hook could run. An
    explicit permission mode is added unless `claude_cmd`/CLAUDE_CMD already
    specifies one — `-p` starts in Manual mode on every plan otherwise, which
    fails silently (exits 0, writes nothing).

    Returns a list suitable for os.execvpe().
    """
    cmd_str = claude_cmd or CLAUDE_CMD
    prefix = shlex.split(cmd_str) if cmd_str else [claude_bin or CLAUDE_BIN]
    if is_phase_worker and FLEET_OBSERVER_ENABLE:
        output_format_args = ['--output-format', 'stream-json', '--verbose']
    else:
        output_format_args = ['--output-format', 'json']
    args = ['-p', prompt or f'/ticket-auto {tid} --auto --from-planned',
            *output_format_args]
    if session_id:
        args += ['--session-id', session_id]
    if agent and not _cmd_already_sets_agent(cmd_str):
        args += ['--agent', agent]
    if not _cmd_already_sets_permission_mode(cmd_str):
        args += ['--permission-mode', FLEET_WORKER_PERMISSION_MODE]
        if FLEET_WORKER_DISALLOWED_TOOLS:
            args += ['--disallowedTools', FLEET_WORKER_DISALLOWED_TOOLS]
    return prefix + args


def _read_own_start_ticks():
    """Read this process's own /proc/self/stat field-22 start ticks.

    Stamped into the worker's environment (as FLEET_WORKER_START_TICKS)
    alongside FLEET_WORKER_PID so the watchdog can detect PID reuse:
    `kill -0` succeeds for any live process occupying a recycled pid, but
    its start ticks will not match. Mirrors the existing
    `awk '{print $22}' /proc/$pid/stat` convention already used elsewhere
    in this codebase (fleet-dispatch.sh) rather than introducing a new one.
    Returns '' when /proc is unavailable (non-Linux) or unreadable.
    """
    try:
        with open('/proc/self/stat') as f:
            fields = f.read().split()
        return fields[21]
    except (OSError, IndexError):
        return ''


_FLEET_PLUGIN_VERSION = None


def _fleet_plugin_version():
    """The fleet-controller plugin's version string, read once from plugin.json.

    Stamped into worker env as FLEET_VERSION so Branch A's `run-identity.sh`
    carries a real value in `META|version`'s `fleet` field instead of `null`
    for fleetd-dispatched runs. Fail-soft to `''` on any read failure — a
    corrupt or missing plugin.json must not raise on the worker-spawn hot
    path (design.md Decision/Risk).
    """
    global _FLEET_PLUGIN_VERSION
    if _FLEET_PLUGIN_VERSION is not None:
        return _FLEET_PLUGIN_VERSION
    plugin_json = Path(__file__).parent.parent / '.claude-plugin' / 'plugin.json'
    try:
        data = json.loads(plugin_json.read_text())
        _FLEET_PLUGIN_VERSION = str(data.get('version') or '')
    except (OSError, ValueError, TypeError):
        _FLEET_PLUGIN_VERSION = ''
    return _FLEET_PLUGIN_VERSION


class SpawnError(Exception):
    """Raised when a worker cannot be spawned."""


def spawn_worker(tid, generation, state_dir, reason='dispatched',
                 cmd_override=None, claude_bin=None, claude_cmd=None,
                 prompt=None, phase='', extra_env=None, session_id=None,
                 agent=None):
    """Fork and exec a worker for `tid`. Returns the child PID.

    The child is placed in its own process group so that kill escalation
    (group 7) can signal the entire worker subtree.

    Worker stdout/stderr are redirected to per-generation files
    (`{tid}-gen{N}.json` / `.stderr`) — never merged. Hook execution
    failures are visible only on stderr, which makes the split a
    prerequisite for Increment B rather than a convenience. Redirection
    failure must not abort the spawn. The stdout file is `.ndjson` instead
    of `.json` when this is a phase-level spawn (`phase` truthy) and
    `FLEET_OBSERVER_ENABLE=true` — see `_build_worker_cmd`'s
    `is_phase_worker` for the matching `--output-format` switch; a
    ticket-level spawn (`phase=''`) always gets `.json`, regardless of the
    flag.

    cmd_override: if provided, used as the argv list instead of the default
    claude invocation. This allows tests to spawn a simple Python process.
    claude_bin/claude_cmd: forwarded to _build_worker_cmd when cmd_override
    is not given — see its docstring.

    prompt/phase/extra_env: phase dispatch (task 4.4). `prompt` replaces the
    whole-ticket invocation with one phase's; `phase` namespaces the stdio and
    run-registry files so a ticket's successive phases do not overwrite each
    other's records; `extra_env` carries what `spawn_agent_pre` would have
    exported in the agent prompt — see `phase_dispatch.build_phase_spawn`.

    agent: forwarded to `_build_worker_cmd` as `--agent` — see its docstring.
    None for a whole-ticket worker; a phase worker's dispatch-table
    `spawn.agent` otherwise.
    """
    # Generated here unless the caller already has one. A phase spawn does:
    # it must write the session id into spawn-meta *before* the fork, so no
    # hook can fire against a file that does not name its own session yet.
    session_id = session_id or str(uuid.uuid4())
    is_phase_worker = bool(phase)
    cmd = cmd_override if cmd_override is not None else _build_worker_cmd(
        tid, claude_bin=claude_bin, claude_cmd=claude_cmd,
        session_id=session_id, prompt=prompt, agent=agent,
        is_phase_worker=is_phase_worker)

    slug = f'{tid}-{phase.lower()}' if phase else tid
    stdout_ext = '.ndjson' if (is_phase_worker and FLEET_OBSERVER_ENABLE) else '.json'
    stdout_path = Path(state_dir) / f'{slug}-gen{generation}{stdout_ext}'
    stderr_path = Path(state_dir) / f'{slug}-gen{generation}.stderr'

    pid = os.fork()
    if pid == 0:
        # Child: create new process group, exec the worker.
        try:
            os.setpgid(0, 0)
        except OSError:
            pass  # best-effort — we may already be the group leader

        # Ensure stdin is detached so the worker does not compete for the
        # terminal with the daemon. This is also the documented remedy for
        # a 3-second per-worker startup stall waiting on stdin.
        try:
            fd = os.open(os.devnull, os.O_RDONLY)
            os.dup2(fd, 0)
            os.close(fd)
        except OSError:
            pass

        # Two separate files, never merged — see docstring. A redirection
        # failure here must not abort the spawn: the worker still runs,
        # just without captured output, which is strictly better than not
        # spawning at all.
        try:
            out_fd = os.open(str(stdout_path),
                             os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o644)
            os.dup2(out_fd, 1)
            os.close(out_fd)
            err_fd = os.open(str(stderr_path),
                             os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o644)
            os.dup2(err_fd, 2)
            os.close(err_fd)
        except OSError:
            pass

        worker_env = dict(os.environ)
        worker_env['FLEET_WORKER_PID'] = str(os.getpid())
        worker_env['FLEET_GENERATION'] = str(generation)
        worker_env['FLEET_VERSION'] = _fleet_plugin_version()
        # Explicit, not inherited: the hooks (stop-capture.sh, stop-failure.sh)
        # need to resolve their own tid/generation by scanning run-registry
        # files for their session_id, and must not depend on fleetd's own
        # process having FLEET_STATE_DIR set — it may have resolved state_dir
        # via the DEFAULT_WORKSPACE fallback instead.
        worker_env['FLEET_STATE_DIR'] = str(state_dir)
        start_ticks = _read_own_start_ticks()
        if start_ticks:
            worker_env['FLEET_WORKER_START_TICKS'] = start_ticks
        worker_env.update(_NON_INTERACTIVE_ENV)
        # Last, so a phase's own LOG_FILE/HB_LOG_FILE win over anything
        # inherited from the daemon's environment — fleetd may itself have
        # been started with a LOG_FILE set, and a phase writing its bracket
        # into the wrong log is silent and unrecoverable.
        if extra_env:
            worker_env.update({k: str(v) for k, v in extra_env.items()})

        try:
            os.execvpe(cmd[0], cmd, worker_env)
        except OSError:
            # exec failed — exit so the parent's SIGCHLD handler can record
            # the failure rather than having a forked Python interpreter
            # running supervisor code in the child.
            os._exit(127)

    # Parent: record the real PID (and session id) in the run registry.
    # Read the child's start ticks here rather than in the child before exec:
    # the child's own value is the pre-exec fork, and exec preserves the pid
    # and start time, so the parent's read of /proc/<pid>/stat is the same
    # number and needs no cooperation from the child.
    _write_run_registry(state_dir, tid, pid, generation, reason,
                        session_id=session_id,
                        start_ticks=_pid_start_time(pid), phase=phase)
    return pid, session_id


def _phase_write_identity(tid, spawn, session_id):
    """Write the phase's spawn-meta and start stamp. Never blocks a spawn.

    These files drive token accounting and activity attribution. Losing them
    costs telemetry; refusing to spawn over an unwritable `/tmp` would cost
    the ticket. The failure is warned about rather than raised for the same
    reason `_store_do` swallows store failures.
    """
    try:
        _phase_mod.write_spawn_meta(tid, spawn, session_id)
        _phase_mod.write_phase_start_marker(tid, spawn.phase)
    except OSError as exc:
        print(f'fleetd: spawn-meta write failed for {tid}/{spawn.phase}: '
              f'{exc}', file=sys.stderr)


def spawn_phase_worker(tid, step_id, generation, state_dir, log_file,
                       table=None, hb_log_file='', claude_log_file='',
                       from_step='', attempt=None, counters=None,
                       env_file='', extra_env=None, reason='phase-dispatch',
                       claude_bin=None, claude_cmd=None, cmd_override=None):
    """Fork one worker for a single dispatch-table phase (tasks 4.4, 4.5).

    Returns `(pid, session_id, spawn)` where `spawn` is the `PhaseSpawn` that
    produced the invocation — callers need its `phase`/`next_phase` to resolve
    the bracket later, and returning it saves them rebuilding it.

    Everything about the fork is `spawn_worker`'s: process group, stdio split,
    non-interactive env, run registry, reaping. This adds only the two things
    that are phase-specific — the `-p` payload and the phase's environment —
    plus the `workers` row that lets a reader ask which phase a live PID is
    running rather than only which ticket.
    """
    if _phase_mod is None:  # pragma: no cover - import guard
        raise SpawnError('fleetd.phase_dispatch is unavailable')
    table = table or _phase_mod.DispatchTable.load()
    spawn = _phase_mod.build_phase_spawn(
        table, step_id, tid, log_file, hb_log_file=hb_log_file,
        claude_log_file=claude_log_file, from_step=from_step, attempt=attempt,
        counters=counters, env_file=env_file, extra_env=extra_env,
    )
    # Identity before exec (D15). Both files are written by the router's
    # `spawn_agent_pre`/`SubagentStart` on the manual path; neither of those
    # runs here, and every hook that resolves "which ticket and phase am I"
    # reads them.
    session_id = str(uuid.uuid4())
    _phase_write_identity(tid, spawn, session_id)
    if FLEET_OBSERVER_ENABLE:
        # Only under the flag — byte-identical to today otherwise (design.md
        # Goals). Fail-soft: a contract write failure costs this
        # generation's observer rule coverage, never the spawn itself.
        try:
            _phase_mod.write_phase_contract(state_dir, table, step_id, tid,
                                            env_file=env_file)
        except Exception as exc:
            print(f"fleetd[{os.getpid()}]: phase contract write failed for "
                  f"{tid}/{spawn.phase}: {exc}", file=sys.stderr)

    pid, session_id = spawn_worker(
        tid, generation, state_dir, reason=reason, cmd_override=cmd_override,
        claude_bin=claude_bin, claude_cmd=claude_cmd,
        prompt=spawn.prompt, phase=spawn.phase, extra_env=spawn.env,
        session_id=session_id, agent=spawn.agent,
    )
    _store_record_spawn(state_dir, tid, pid, generation, reason, session_id,
                        phase=spawn.phase)
    # Position is recorded here, not inferred afterwards — this dispatch
    # call is the one place fleetd knows it for certain (design.md D7).
    _store_record_position(state_dir, tid, step_id, source='dispatch')
    return pid, session_id, spawn


# ── Child reaping (self-pipe trick) ────────────────────────────────────────

class ChildReaper:
    """Reaps exited children via SIGCHLD and a self-pipe.

    Signal handlers run in an extremely constrained context — only
    async-signal-safe operations are allowed. The self-pipe trick defers
    all non-trivial work (waitpid, bookkeeping, Python object mutation)
    to the main thread:

    1. SIGCHLD handler writes a single byte to a pipe.
    2. The main loop sees the pipe is readable and calls reap().
    3. reap() calls os.waitpid(-1, os.WNOHANG) until no more children.

    This is the standard pattern for integrating signal-driven events
    with an event loop without race conditions or unsafe signal-context
    operations.
    """

    def __init__(self):
        self._r_fd, self._w_fd = os.pipe()
        os.set_blocking(self._r_fd, False)
        # Prevent child processes from inheriting the write end of the pipe.
        # If a child holds it open, the reading end never sees EOF and the
        # main loop's drain-read never returns zero bytes, causing a spin.
        for fd in (self._r_fd, self._w_fd):
            flags = fcntl.fcntl(fd, fcntl.F_GETFD)
            fcntl.fcntl(fd, fcntl.F_SETFD, flags | fcntl.FD_CLOEXEC)
        self._exited = {}  # pid → {exit_code, exit_type, exited_at}
        signal.signal(signal.SIGCHLD, self._handle_sigchld)

    def _handle_sigchld(self, signum, frame):
        """Async-signal-safe: only write to the pipe."""
        try:
            os.write(self._w_fd, b'x')
        except (OSError, BlockingIOError):
            pass  # pipe full — main thread hasn't drained yet, will catch up

    @property
    def watch_fd(self):
        """File descriptor to watch for readability in the main loop."""
        return self._r_fd

    def reap(self):
        """Reap all exited children. Call from the main thread only.

        Returns a list of (pid, exit_status, exit_type) for newly reaped
        children, where exit_type is one of 'exit', 'signal', or 'unknown'.
        """
        newly_reaped = []
        # Drain the pipe so we don't spin on the next iteration.
        try:
            while os.read(self._r_fd, 64):
                pass
        except (OSError, BlockingIOError):
            pass

        while True:
            try:
                wpid, status = os.waitpid(-1, os.WNOHANG)
            except ChildProcessError:
                break
            if wpid == 0:
                break

            if os.WIFEXITED(status):
                exit_type = 'exit'
                exit_code = os.WEXITSTATUS(status)
            elif os.WIFSIGNALED(status):
                exit_type = 'signal'
                exit_code = -os.WTERMSIG(status)
            else:
                exit_type = 'unknown'
                exit_code = status

            self._exited[wpid] = {
                'exit_code': exit_code,
                'exit_type': exit_type,
                'exited_at': datetime.now(timezone.utc).isoformat(),
            }
            newly_reaped.append((wpid, exit_code, exit_type))

        return newly_reaped

    def close(self):
        for fd in (self._r_fd, self._w_fd):
            try:
                os.close(fd)
            except OSError:
                pass


# ── Kill-request files (group 10, CLI → daemon bridge) ──────────────────────


def _read_kill_requests(state_dir):
    """Yield (tid, request_data) tuples from the kill-requests directory.

    The CLI writes `{state_dir}/kill-requests/{tid}.json` to request a kill.
    The daemon picks these up and processes them in the main loop.
    """
    kr_dir = Path(state_dir) / 'kill-requests'
    if not kr_dir.is_dir():
        return
    for req_file in sorted(kr_dir.glob('*.json')):
        tid = req_file.stem
        # Skip result files from previous requests.
        if tid.endswith('-result'):
            continue
        try:
            data = json.loads(req_file.read_text())
        except (json.JSONDecodeError, OSError):
            # Malformed — remove so we don't re-read it forever.
            try:
                req_file.unlink()
            except OSError:
                pass
            continue
        yield tid, data, req_file


def _write_kill_result(state_dir, tid, success, method, error=None):
    """Write the result of processing a kill request."""
    kr_dir = Path(state_dir) / 'kill-requests'
    kr_dir.mkdir(parents=True, exist_ok=True)
    result_file = kr_dir / f'{tid}-result.json'
    result = {
        'tid': tid,
        'success': success,
        'method': method,
        'error': error,
        'completed_at': datetime.now(timezone.utc).isoformat(),
    }
    result_file.write_text(json.dumps(result))


# ── Stop-file pinned tickets ───────────────────────────────────────────────

def _collect_stop_pinned_tids(state_dir):
    """Collect the union of ticket ids pinned by any stop-*.json file.

    Used by startup reconciliation — it has no epic context of its own, so
    the pinned tid list is what makes a stop survive a fleetd restart.
    """
    pinned = set()
    state = Path(state_dir)
    try:
        for stop_file in sorted(state.glob('stop-*.json')):
            try:
                data = json.loads(stop_file.read_text())
            except (json.JSONDecodeError, OSError):
                continue
            for tid in data.get('tickets', []):
                if isinstance(tid, str) and tid:
                    pinned.add(tid)
    except OSError:
        pass
    return pinned


def _log_reached_terminal(state_dir, tid):
    """Whether the ticket's pipeline log shows a terminal state.

    Python mirror of the resume-relevant rules in
    fleet_ticket_terminal_state (fleet-controller/lib/fleet-reconcile.sh) —
    keep the two in sync; the bash classifier is the authority and this
    mirror exists so the consume loop does not shell out per queue entry.

    Terminal iff (mirrors fleet_ticket_terminal_state branch order —
    the bash classifier is the authority):
      - the last line's step is `outcome`: any `held: <kind>` message,
        `stopped: gate-stop` and `stopped: fleet-kill` are NOT terminal;
        any other outcome message IS terminal, or
      - the last line's step is `dead-letter` (terminal).
    A missing/empty log is NOT terminal, same as the bash classifier.

    The held check matches the `held: ` prefix, not the exact string
    `held: gate` — today the only hold kind pipeline-finalize.sh writes,
    but an exact match would silently misclassify any future hold kind
    (e.g. an external-wait hold) as terminal via the fallthrough below.

    NO gate-stop-derived verdict is terminal any more. Bash classifies all
    three of its gate-stop routes as `gate-stopped` — a distinct value from
    `done` — because the condition behind a gate-stop (missing acceptance
    criteria, a revoked approval, an absent template) lives outside the
    pipeline and may since have been fixed by a human. The three routes,
    all returning False here:
      1. a `stopped: gate-stop <CODE>` outcome message — pipeline-finalize.sh
         writes this on essentially every gate-stop exit, so it, not route 3,
         is what fires for real traffic;
      2. a `stopped: fleet-kill` outcome over a log that also carries a
         gate-stop marker (gate-stopped first, killed after);
      3. a bare `|META|gate-stop|fail|` marker with no outcome line at all —
         the process died before finalize could run.
    Treating any of them as terminal here would make the consume path drop
    the `campaign-resume` queue entry that a scoped reconcile just wrote,
    silently defeating campaign resume at the last step. Only a true `done`
    — genuine completion or a dead-letter — is terminal.
    """
    log_file = Path(state_dir) / f'{tid}-pipeline.log'
    try:
        lines = [ln for ln in log_file.read_text().splitlines() if ln]
    except OSError:
        return False
    if not lines:
        return False

    # Skip any trailing run of `META|worker-exit` entries — fleetd appends
    # one after a worker's own generation exits (fleet-controller/CLAUDE.md
    # "Worker exit records"), an annotation of the exit rather than a new
    # pipeline state. Without this, a genuinely completed pipeline reads as
    # `incomplete` the moment fleetd reaps it, because the raw last line is
    # no longer the outcome/dead-letter line (mirrors bash's
    # _last_effective_line).
    idx = len(lines) - 1
    while idx >= 0:
        fields = lines[idx].split('|')
        if len(fields) >= 3 and fields[2] == 'worker-exit':
            idx -= 1
            continue
        break
    if idx < 0:
        return False

    # Pipeline log schema is ISO|PHASE|STEP|STATUS|MSG — split() is
    # 0-indexed, so STEP is field 2 and STATUS is field 3. The outcome arm
    # must run before the gate-stop-anywhere grep: bash classifies a
    # gate-held outcome as gate-held even when a gate-stop line exists
    # earlier in the log.
    last = lines[idx].split('|')
    if len(last) >= 3 and last[2] == 'outcome':
        msg = '|'.join(last[4:]) if len(last) > 4 else ''
        if 'stopped: fleet-kill' in msg:
            # A verified kill is a pause — resumable. Bash classifies a
            # kill over a gate-stopped log as `gate-stopped` (not `done`),
            # which is likewise not terminal, so this arm returns False
            # either way and no marker grep is needed.
            return False
        if 'stopped: gate-stop' in msg:
            # bash: gate-stopped. The condition may since have been fixed;
            # a scoped campaign resume is entitled to retry it, so this
            # entry must not be dropped as stale. See the docstring.
            return False
        if msg.startswith('held: '):
            # Waiting on the human, not terminal — any hold kind, not just
            # "gate" (see docstring).
            return False
        return True

    # Crash between gate-held write and finalize: the held marker itself
    # is the last line. Still gate-held — the human gate stands.
    if len(last) >= 3 and last[2] == 'gate-held':
        return False

    if len(last) >= 3 and last[2] == 'dead-letter':
        return True
    return False


def _foreign_run_for_tid(state_dir, tid):
    """Read a ticket's log/activity state and ask `detect_foreign_run`.

    The pure decision lives in `phase_dispatch.detect_foreign_run` (task
    4.19) — this just supplies the two file reads it needs from the same
    `{tid}-pipeline.log` / `{tid}-activity.log` paths every other consumer of
    this state dir uses (`_log_reached_terminal`, `fleet-detect.sh`). Always
    called with `fleetd_owns_worker=False`: every caller has already checked
    `self._children.get(tid) is None` before reaching here.

    A missing/unreadable phase_dispatch import, or a missing pipeline log,
    both degrade to "no foreign run detected" — the same fail-open posture
    the rest of the interlock's own design commentary describes for a log
    that does not exist yet.
    """
    if _phase_mod is None:  # pragma: no cover - import guard
        return None
    log_file = Path(state_dir) / f'{tid}-pipeline.log'
    try:
        log_lines = [ln for ln in log_file.read_text().splitlines() if ln]
    except OSError:
        log_lines = []
    activity_log = Path(state_dir) / f'{tid}-activity.log'
    return _phase_mod.detect_foreign_run(
        tid, log_lines, str(activity_log), False)


# ── Epic view (pure state-dir derivation) ─────────────────────────────────

def _list_epics(state_dir, workers):
    """Derive the epic view for GET /epics from state-dir files only.

    Merges three sources into one object per epic: stop-files (`stopped`),
    spawn-queue entry reasons (`queued`), and worker record reasons
    (`running`). An epic appearing in none of them is not listed — fleetd's
    knowledge horizon is its own state dir. No Linear calls.
    """
    epics = {}
    state = Path(state_dir)

    def _epic(epic_id):
        if epic_id not in epics:
            epics[epic_id] = {
                'epic_id': epic_id,
                'stopped': False,
                'stopped_at': None,
                'stop_reason': None,
                'tickets': [],
                'queued': [],
                'running': [],
            }
        return epics[epic_id]

    # Stop-files: stop-{epic}.json → initiative_id/tickets/reason/stopped_at.
    try:
        for stop_file in sorted(state.glob('stop-*.json')):
            epic_id = stop_file.name[len('stop-'):-len('.json')]
            try:
                data = json.loads(stop_file.read_text())
            except (json.JSONDecodeError, OSError):
                continue
            entry = _epic(data.get('initiative_id') or epic_id)
            entry['stopped'] = True
            entry['stopped_at'] = data.get('stopped_at')
            entry['stop_reason'] = data.get('reason', '')
            for tid in data.get('tickets', []):
                if tid not in entry['tickets']:
                    entry['tickets'].append(tid)
    except OSError:
        pass

    # Queue entries: reason = "planned-dispatch from {epic}" or
    # "campaign-resume from {epic}".
    entries, _malformed = _parse_queue_with_malformed(state_dir)
    for entry in entries:
        match = re.search(r'(?:planned-dispatch|campaign-resume) from (\S+)',
                          entry.get('reason', ''))
        if not match:
            continue
        _epic(match.group(1))['queued'].append(entry.get('tid', ''))

    # Running workers: reason carries through spawn → registry → child table.
    for worker in workers:
        match = re.search(r'(?:planned-dispatch|campaign-resume) from (\S+)',
                          worker.get('reason', ''))
        if not match:
            continue
        _epic(match.group(1))['running'].append(worker.get('tid', ''))

    return [epics[key] for key in sorted(epics)]


# ── Supervisor ─────────────────────────────────────────────────────────────

class Supervisor:
    """fleetd supervisor — the top-level orchestrator.

    Lifecycle:
    1. Acquire single-instance lock
    2. Scan existing registry into child table
    3. Start health HTTP server
    4. (future groups) Run detection cycles, consume queue, spawn/reap workers
    """

    def __init__(self, state_dir=None, pidfile=None, port=None, bind=None,
                 fleet_lib_dir=None, cycle_interval=30,
                 spawn_enabled=None, max_concurrent=None, claude_bin=None,
                 claude_cmd=None):
        self._state_dir = Path(state_dir) if state_dir else _resolve_state_dir()
        self._pidfile = pidfile or DEFAULT_PIDFILE
        self._port = port or FLEETD_PORT
        self._bind = bind or FLEETD_BIND
        self._cycle_interval = cycle_interval
        self._spawn_enabled = (
            spawn_enabled if spawn_enabled is not None else FLEETD_SPAWN_ENABLED
        )
        self._max_concurrent = max_concurrent if max_concurrent is not None else FLEET_MAX_CONCURRENT
        self._claude_bin = claude_bin or CLAUDE_BIN
        self._claude_cmd = claude_cmd or CLAUDE_CMD
        self._fleet_lib_dir = (
            Path(fleet_lib_dir) if fleet_lib_dir else Path(_DEFAULT_FLEET_LIB)
        )
        self._lock = InstanceLock(self._pidfile)
        # RLock (not plain Lock): dispatch_epic/stop_epic hold the lock while
        # calling helpers (_consume_queue) that also acquire it.
        self._state_lock = threading.RLock()
        self._children = ChildTable()
        self._reaper = ChildReaper()
        self._detection = DetectionCycle(fleet_lib_dir=fleet_lib_dir)
        self._cycle_cache = None  # created fresh per cycle
        # Per-tid cache for predicted confidence — parsed once from the
        # ticket's Planner Context block (one Linear call), then served from
        # memory for the daemon's lifetime.
        self._confidence_cache = {}
        # OTel exporter (D11). One supervised child under a fixed identifier,
        # not a ticket. `_otel_failures` drives the respawn backoff; it resets
        # on any spawn that survives to the next reap.
        self._otel_pid = None
        self._otel_failures = 0
        self._otel_next_attempt = 0.0
        # Agent Observer sidecar (agent-observer D1). Same shape as the OTel
        # exporter above — one supervised child under a fixed identifier,
        # never a ticket, respawned with the same bounded backoff on crash.
        self._observer_pid = None
        self._observer_failures = 0
        self._observer_next_attempt = 0.0
        # Hold reconciliation's own cadence (design.md D5): `None` means
        # "never run", so the first cycle always probes any held ticket
        # rather than waiting a full interval after a restart.
        self._hold_reconcile_last_run = None
        # Deterministic-failure circuit breaker (worker-reap-recovery task
        # 3.8): a streak of fast, non-zero exits across the fleet — expired
        # auth, a bad CLAUDE_CMD — halts dispatch rather than burning
        # FLEET_MAX_RESTARTS per ticket. Reset to [] by any reap that is
        # NOT a fast failure.
        self._fast_failure_streak = []
        self._circuit_breaker_tripped = False
        self._circuit_breaker_reason = None
        # Generation of the last-reaped worker per tid — bridges
        # _reap_children_locked (which knows the generation) to
        # _reap_children's post-lock _update_exit_record_action call.
        self._last_reaped_generation = {}
        self._health_state = {
            'workers': [],
            'queue_depth': 0,
            'last_cycle_at': None,
            'last_cycle_success': None,
            'last_cycle_error': None,
            'cycle_count': 0,
            'spawn_enabled': self._spawn_enabled,
            'circuit_breaker_tripped': False,
            'circuit_breaker_reason': None,
            # agent-observer Inc 4: {severity: count} across every ticket's
            # findings, or {} when the store is disabled/unavailable — same
            # fail-soft posture as every other store-backed health field.
            'observer_findings': {},
        }

    # ── lock ────────────────────────────────────────────────────────────────

    def acquire_lock(self):
        self._lock.acquire()

    def release_lock(self):
        self._lock.release()

    # ── observe-only scan ───────────────────────────────────────────────────

    def scan_workers(self, verify_ownership=True):
        """Scan the run registry and populate the child table.

        On startup (verify_ownership=True): each registry entry's PID is
        verified via process start time + cmdline before adoption. Entries
        that fail verification are cleared — we never signal an unverified PID.
        Dead entries are also cleared.

        Surviving workers are adopted into degraded supervision: the daemon
        can stop and signal them, but exit detection relies on polling
        because we cannot waitpid a process we did not fork.
        """
        entries = scan_registry(self._state_dir, verify_ownership=verify_ownership)
        adopted_count = 0
        cleared_count = 0

        for entry in entries:
            if entry['_alive'] and entry.get('_ownership_verified', True):
                self._children.add(
                    tid=entry['tid'],
                    pid=entry['pid'],
                    generation=entry['generation'],
                    reason=entry['reason'],
                    adopted=entry['adopted'],
                )
                adopted_count += 1

        if adopted_count > 0:
            print(
                f"fleetd[{os.getpid()}]: adopted {adopted_count} surviving "
                f"worker(s) from previous instance"
            )

        # Bootstrap the state store after adoption, not before: scan_registry
        # has by now cleared the registry files of workers that did not
        # survive, so what the store imports is the set that is genuinely
        # still running. Idempotent, and also the recovery path when the
        # database has been deleted — projections rebuild from the logs
        # instead of the in-flight tickets being orphaned.
        result = _store_bootstrap(str(self._state_dir))
        if result is not None:
            imported, counts = result
            if imported['workers'] or imported['fences'] or counts['files']:
                print(
                    f"fleetd[{os.getpid()}]: state store — imported "
                    f"{imported['workers']} worker(s), {imported['fences']} "
                    f"fence(s); projected {counts['pipeline']} pipeline and "
                    f"{counts['activity']} activity line(s) from "
                    f"{counts['files']} log file(s)"
                )

        self._sync_health()

    def reconcile_orphaned_tickets(self, scope_tids=None):
        """Reconciliation via the bash fleet-reconcile.sh.

        Two callers:
        - Startup (scope_tids=None): one-shot, immediately after worker
          adoption. Classifies every known ticket by its own pipeline log
          (read-only, no Linear/gh calls) and re-enqueues `incomplete`
          tickets that have no adopted-live worker and no existing queue
          entry.
        - Reap-time (scope_tids=[tid, ...]): called by `_reap_children`
          after releasing `_state_lock`, once per tid whose worker just
          exited over a non-terminal log. `scope_tids` sets
          FLEET_RECONCILE_TIDS, which `fleet_reconcile_orphans` already
          supports natively — it limits the scan to exactly these tids
          instead of the startup path's global glob. All of the restart
          cap, stop-pin exclusion, queue-exclusion and dead-lettering
          logic is identical between the two callers; only the scope
          differs.

        The adopted-live TID set is passed in so the bash side can exclude
        workers this instance just adopted (irrelevant, but harmless, for
        the scoped reap-time case — a just-reaped tid was removed from the
        child table before this call and so can never appear there).

        A reconciliation failure logs and continues — it must never block
        daemon startup or the reap loop (matching the
        sync-failure-does-not-block-dispatch pattern).
        """
        reconcile_script = self._fleet_lib_dir / 'fleet-reconcile.sh'
        if not reconcile_script.is_file():
            print(
                f"fleetd[{os.getpid()}]: reconcile script not found: "
                f"{reconcile_script} — skipping orphan reconciliation"
            )
            return

        queue_file = (
            self._state_dir
            / f'fleet-{FLEET_INSTANCE_ID}-spawn-queue.jsonl'
        )
        live_tids = ' '.join(sorted(
            tid for tid, entry in self._children._workers.items()
            if entry.get('adopted')
        ))
        # Tickets pinned by any stop-*.json must not be resurrected by
        # reconciliation — a stop survives a fleetd restart through this pin.
        pinned_tids = ' '.join(sorted(_collect_stop_pinned_tids(self._state_dir)))
        scope = ' '.join(sorted(scope_tids)) if scope_tids else ''

        # Values that originate outside this process (state-dir file names,
        # adopted TIDs from run-registry entries, env-derived paths) are
        # passed via environment variables, never interpolated into the bash
        # source string — a malicious `{tid}-run.json` in a shared workspace
        # must not become shell syntax.
        bash_cmd = (
            'source "$FLEET_RECONCILE_SCRIPT" && '
            'fleet_reconcile_orphans "$FLEET_RECONCILE_STATE_DIR" '
            '"$FLEET_RECONCILE_QUEUE_FILE" "$FLEET_RECONCILE_LIVE_TIDS" '
            '"$FLEET_RECONCILE_PINNED_TIDS"'
        )
        try:
            proc = subprocess.run(
                ['bash', '-c', bash_cmd],
                capture_output=True,
                text=True,
                timeout=120,
                env={
                    **os.environ,
                    'FLEET_PIPELINE_LOG_DIR': str(self._state_dir),
                    'FLEET_RECONCILE_SCRIPT': str(reconcile_script),
                    'FLEET_RECONCILE_STATE_DIR': str(self._state_dir),
                    'FLEET_RECONCILE_QUEUE_FILE': str(queue_file),
                    'FLEET_RECONCILE_LIVE_TIDS': live_tids,
                    'FLEET_RECONCILE_PINNED_TIDS': pinned_tids,
                    'FLEET_RECONCILE_TIDS': scope,
                },
            )
        except (subprocess.TimeoutExpired, OSError) as exc:
            print(
                f"fleetd[{os.getpid()}]: orphan reconciliation failed "
                f"({exc}) — continuing"
            )
            return

        if proc.returncode != 0:
            stderr_tail = proc.stderr.strip().split('\n')[-3:] if proc.stderr else []
            print(
                f"fleetd[{os.getpid()}]: orphan reconciliation exited "
                f"{proc.returncode} — continuing: {stderr_tail}"
            )
            return

        for line in (proc.stdout or '').strip().splitlines():
            print(f"fleetd[{os.getpid()}]: {line}")

    def poll_adopted_workers(self):
        """Detect exits of adopted workers by liveness polling.

        Adopted workers were not forked by this daemon instance, so their
        exits cannot be reaped via waitpid. Instead we periodically check
        whether their PID is still alive and remove any that have exited.

        Acquires _state_lock — mutates the child table and run-registry files.
        """
        with self._state_lock:
            self._poll_adopted_workers_locked()

    def _poll_adopted_workers_locked(self):
        removed = []
        for entry in list(self._children._workers.values()):
            if not entry.get('adopted'):
                continue
            if not _pid_is_alive(entry['pid']):
                # Preserve the last-known generation before deleting the
                # registry entry — same continuity contract as scan_registry's
                # stale-deletion path (see _write_last_generation). Without
                # it, the generation sequence depends solely on the fence
                # marker surviving.
                _write_last_generation(self._state_dir, entry['tid'],
                                       entry.get('generation', 0))
                self._children.remove(entry['tid'])
                # Clear the stale registry file too.
                run_file = self._state_dir / f"{entry['tid']}-run.json"
                try:
                    run_file.unlink()
                except OSError:
                    pass
                removed.append(entry['tid'])

        if removed:
            self._sync_health()
            print(
                f"fleetd[{os.getpid()}]: polled {len(removed)} adopted "
                f"worker(s) now exited: {', '.join(removed)}"
            )

    # ── detection cycle ──────────────────────────────────────────────────

    def run_detection_cycle(self):
        """Run one detection pass and update health state.

        Creates a fresh CycleCache so that any repeated lookups within this
        cycle (e.g., overlapping fleet-wide scans) hit the cache rather than
        re-issuing external API calls.
        """
        self._cycle_cache = CycleCache()
        completed_at = datetime.now(timezone.utc).isoformat()

        # Phase-worker liveness heartbeats (task 4.18) are written before
        # detection runs, so a line emitted THIS cycle is visible to
        # `detect_stalls` THIS cycle rather than one cycle late.
        self.emit_phase_liveness_heartbeats()

        # Project new log lines before the engines read them, so store-backed
        # detection sees the same history a file-backed read would.
        _store_sync(str(self._state_dir))

        result = self._detection.run(str(self._state_dir), cache=self._cycle_cache)

        if result is None:
            self._health_state['last_cycle_success'] = False
            self._health_state['last_cycle_error'] = self._detection.last_error
            self._health_state['last_cycle_at'] = completed_at
        else:
            self._health_state['last_cycle_success'] = True
            self._health_state['last_cycle_error'] = None
            self._health_state['last_cycle_at'] = completed_at
            self._health_state['cycle_count'] += 1
            # Surface summary in health payload for fleet-dashboard consumption.
            summary = result.get('summary', {})
            self._health_state['last_summary'] = summary
            self._health_state['pipeline_count'] = summary.get('total', 0)

            # Merge per-ticket phase/anomalies into live worker records
            # instead of discarding everything but the summary. A tid the
            # detection knows but the child table doesn't (e.g. an adopted-
            # but-not-yet-registered ticket) is a no-op, not an error.
            with self._state_lock:
                for pipeline in result.get('pipelines', []):
                    tid = pipeline.get('tid', '')
                    if not tid or self._children.get(tid) is None:
                        continue
                    self._children.update_phase(tid, pipeline.get('phase', ''))
                    anomalies = pipeline.get('anomalies', '')
                    if anomalies in (None, 'none'):
                        anomalies = ''
                    self._children.update_anomalies(tid, anomalies)

        self._sync_health()

    # ── health state ────────────────────────────────────────────────────────

    def _sync_health(self):
        self._health_state['workers'] = self._children.list_workers()
        self._health_state['queue_depth'] = get_queue_depth(self._state_dir)
        self._health_state['spawn_enabled'] = self._spawn_enabled
        self._health_state['circuit_breaker_tripped'] = self._circuit_breaker_tripped
        self._health_state['circuit_breaker_reason'] = self._circuit_breaker_reason
        self._health_state['observer_findings'] = _store_finding_counts(
            str(self._state_dir))

    def update_cycle_result(self, success, completed_at=None):
        """Record the outcome of a detection cycle (for group 5+ consumers)."""
        self._health_state['last_cycle_at'] = (
            completed_at or datetime.now(timezone.utc).isoformat()
        )
        self._health_state['last_cycle_success'] = success
        self._sync_health()

    # ── generation fencing (group 9) ─────────────────────────────────────

    def _resolve_generation(self, tid):
        """Determine the generation for the next spawn of `tid`.

        Reads the fence marker, the run registry, and the preserved
        last-known generation record (written by `scan_registry` when it
        deleted a stale registry entry), taking the maximum, then increments.
        This ensures a restarted worker is never fenced by its predecessor —
        its generation is always strictly greater than any previously
        recorded one, including generations whose registry file was deleted
        as stale.

        Returns 1 if no prior record exists.
        """
        prior_gen = 0

        # Check the fence marker (written when a previous worker was killed).
        fence_file = self._state_dir / f'{tid}-fence'
        try:
            if fence_file.is_file():
                fence_data = json.loads(fence_file.read_text())
                fenced = fence_data.get('fenced_generation', 0)
                if fenced > prior_gen:
                    prior_gen = fenced
        except (json.JSONDecodeError, OSError):
            pass

        # Check the run registry (may survive a daemon restart).
        run_file = self._state_dir / f'{tid}-run.json'
        try:
            if run_file.is_file():
                run_data = json.loads(run_file.read_text())
                prev = run_data.get('generation', 0)
                if prev > prior_gen:
                    prior_gen = prev
        except (json.JSONDecodeError, OSError):
            pass

        # Check the preserved last-known generation (written by
        # scan_registry before deleting a stale registry entry — the record
        # that survives a full registry-file deletion).
        last_file = self._state_dir / f'{tid}-last-generation'
        try:
            if last_file.is_file():
                last_data = json.loads(last_file.read_text())
                last_gen = last_data.get('generation', 0)
                if last_gen > prior_gen:
                    prior_gen = last_gen
        except (json.JSONDecodeError, OSError):
            pass

        return prior_gen + 1

    # ── CLI alignment (group 10) ─────────────────────────────────────────

    def _process_kill_requests(self):
        """Process any pending kill-request files written by the CLI.

        The CLI writes `{state_dir}/kill-requests/{tid}.json` to request a
        kill. The daemon processes each request, removes the request file,
        and writes a result file the CLI can check.
        """
        for tid, data, req_file in _read_kill_requests(self._state_dir):
            reason = data.get('reason', 'cli-request')
            grace = data.get('grace_secs')  # optional override

            result = self.kill_worker(tid, reason=reason, grace_secs=grace)
            _write_kill_result(
                self._state_dir, tid,
                success=result.success,
                method=result.method,
                error=result.error,
            )
            # Remove the request file so we don't re-process it.
            try:
                req_file.unlink()
            except OSError:
                pass

    # ── on-demand dispatch / stop / status (HTTP control surface) ─────────

    def _bash_dispatch(self, bash_cmd, timeout=300, extra_env=None):
        """Run a fleet bash action subprocess and return (rc, stdout, stderr).

        Passes FLEET_PIPELINE_LOG_DIR / FLEET_STATE_DIR through the
        environment so sourced fleet libs resolve the same state dir the
        daemon uses, regardless of the caller's cwd. `extra_env` carries
        request-derived values (epic_id, reason) — never shell-interpolated.
        """
        try:
            env = {
                **os.environ,
                'FLEET_PIPELINE_LOG_DIR': str(self._state_dir),
                'FLEET_STATE_DIR': str(self._state_dir),
            }
            if extra_env:
                env.update(extra_env)
            proc = subprocess.run(
                ['bash', '-c', bash_cmd],
                capture_output=True,
                text=True,
                timeout=timeout,
                env=env,
            )
            return proc.returncode, proc.stdout or '', proc.stderr or ''
        except subprocess.TimeoutExpired:
            return -1, '', f'timed out after {timeout}s'
        except OSError as exc:
            return -1, '', f'failed to invoke: {exc}'

    def dispatch_epic(self, epic_id, dry_run=False, resume=False):
        """Dispatch one epic on demand via fleet_dispatch_initiative.

        Runs the same bash function the skill and the auto-sweep call —
        behavior (label validation, blocked-by resolution, queue idempotency,
        stop-file gate) is identical regardless of trigger path — then
        immediately consumes the resulting spawn-queue entries (unless
        dry_run) so tickets spawn without waiting for the next poll cycle.

        The bash subprocess runs OUTSIDE _state_lock: it can take minutes
        (Linear retries, epic-branch git ops across REPOS_ROOT), and holding
        the lock would freeze the main loop's reaping, kill-requests, and
        adopted-worker polling. Cross-process serialization is the
        epic-scoped flock's job; the lock is re-acquired only for the queue
        consume below.

        Returns {'queued': [...], 'resumed': [...], 'blocked': [...],
                 'spawned': [...], 'message': str}.
        """
        dispatch_script = self._fleet_lib_dir / 'fleet-dispatch.sh'
        if not dispatch_script.is_file():
            return {
                'queued': [], 'resumed': [], 'blocked': [], 'spawned': [],
                'message': f'dispatch script not found: {dispatch_script}',
            }

        # epic_id comes from the HTTP body — pass it via the environment,
        # never interpolated into shell source (see reconcile_orphaned_tickets).
        flags = ' --resume' if resume else ''
        bash_cmd = (
            f'source "{dispatch_script}" && '
            f'FLEET_DRY_RUN="{"true" if dry_run else "false"}" '
            f'fleet_dispatch_initiative "$FLEET_DISPATCH_EPIC" '
            f'"$FLEET_DISPATCH_STATE_DIR"{flags}'
        )
        rc, stdout, stderr = self._bash_dispatch(
            bash_cmd,
            extra_env={
                'FLEET_DISPATCH_EPIC': str(epic_id),
                'FLEET_DISPATCH_STATE_DIR': str(self._state_dir),
            },
        )

        # Ticket-id shape only — the summary line "enqueued N ticket(s)"
        # must not be captured as a tid.
        queued = re.findall(r'enqueued\s+([A-Z]+-\d+)', stdout)
        if dry_run:
            # Dry-run lines carry the would-be entry as JSON — parse tids.
            for match in re.finditer(r'would enqueue: (\{.*?\})', stdout):
                try:
                    entry = json.loads(match.group(1))
                    if entry.get('tid'):
                        queued.append(entry['tid'])
                except json.JSONDecodeError:
                    pass
        queued = list(dict.fromkeys(queued))  # dedupe, preserve order

        # Campaign-resume contract: per-tid `  resumed {tid}` (real mode) /
        # `[DRY-RUN] would resume {tid}` / `  blocked {tid}` lines plus a
        # summary last line. Additive — the `queued` regex above and the
        # last-line `message` contract are unchanged. The summary's
        # "resumed N"/"blocked N" counts do not match the tid shape.
        resumed = re.findall(r'(?:resumed|would resume)\s+([A-Z]+-\d+)',
                             stdout)
        blocked = re.findall(r'blocked\s+([A-Z]+-\d+)', stdout)
        resumed = list(dict.fromkeys(resumed))
        blocked = list(dict.fromkeys(blocked))

        lines = stdout.strip().splitlines()
        message = lines[-1] if lines else ''
        if rc != 0:
            err_lines = stderr.strip().splitlines()
            message = (err_lines or lines or ['dispatch failed'])[-1]

        spawned = []
        if not dry_run and rc == 0:
            with self._state_lock:
                spawned = sorted(self._consume_queue_locked())

        return {
            'queued': queued, 'resumed': resumed, 'blocked': blocked,
            'spawned': spawned, 'message': message,
        }

    def stop_epic(self, epic_id, reason=''):
        """Stop one epic per the fleet-epic-stop contract.

        Shells out to fleet_stop_initiative — the single bash stop
        implementation, also invoked by the skill's stop subcommand — which
        purges the epic's queue entries, escalate-kills its running workers,
        and writes the stop-file, all under the epic-scoped dispatch lock.
        The subprocess runs OUTSIDE _state_lock (kill escalations take
        grace periods and must not freeze the main loop); only the
        child-table update below is locked.

        Returns {'purged': [...], 'killed': [...], 'pinned': [...], 'message': str}.
        """
        dispatch_script = self._fleet_lib_dir / 'fleet-dispatch.sh'
        if not dispatch_script.is_file():
            return {
                'purged': [], 'killed': [], 'pinned': [],
                'message': f'dispatch script not found: {dispatch_script}',
            }

        # epic_id and reason come from the HTTP body — env-passed, never
        # shell-interpolated (see reconcile_orphaned_tickets).
        bash_cmd = (
            f'source "{dispatch_script}" && '
            f'fleet_stop_initiative "$FLEET_STOP_EPIC" "$FLEET_STOP_REASON" '
            f'"$FLEET_STOP_STATE_DIR"'
        )
        rc, stdout, stderr = self._bash_dispatch(
            bash_cmd,
            extra_env={
                'FLEET_STOP_EPIC': str(epic_id),
                'FLEET_STOP_REASON': str(reason),
                'FLEET_STOP_STATE_DIR': str(self._state_dir),
            },
        )

        purged, killed, pinned = [], [], []
        # End-anchored: with lazy groups an unanchored search would stop at
        # the shortest prefix and truncate the JSON payloads.
        match = re.search(
            r'STOP_RESULT\|purged=(.+?)\|killed=(.+?)'
            r'(?:\|pinned=(.+?))?\s*$',
            stdout, re.DOTALL)
        if match:
            for idx, field in enumerate((purged, killed, pinned)):
                try:
                    field.extend(json.loads(match.group(idx + 1)) or [])
                except (json.JSONDecodeError, TypeError):
                    pass

        # Drop killed workers from the child table ONLY when their PID is
        # confirmed dead. The bash side re-verifies liveness before adding
        # to `killed`, but a misreported kill must never orphan a live
        # process — the daemon keeps supervising until the pid is gone.
        # Pinned survivors/refusals stay in the table untouched. Registry
        # files are cleaned by the normal scan/poll paths on next sight.
        with self._state_lock:
            for tid in killed:
                child = self._children.get(tid)
                if child is None:
                    continue
                if _pid_is_alive(child['pid']):
                    continue
                self._children.remove(tid)
            self._sync_health()

        lines = stdout.strip().splitlines()
        message = lines[-1] if lines else ''
        if rc != 0:
            err_lines = stderr.strip().splitlines()
            message = (err_lines or lines or ['stop failed'])[-1]
        return {'purged': purged, 'killed': killed, 'pinned': pinned,
                'message': message}

    def child_tids(self):
        """TIDs of all workers in the child table.

        Snapshot under _state_lock — GET handlers run on the HTTP thread
        while the main loop mutates the table every cycle; iterating a live
        dict raises RuntimeError on a concurrent size change.
        """
        with self._state_lock:
            return list(self._children._workers.keys())

    def get_worker_status(self, tid):
        """Assemble live status for one worker (GET /workers/<tid>).

        Returns None when the ticket is entirely unknown — no worker record
        and no pipeline log. `phase`/`anomalies` come from the child table
        (latest detection cycle); `tokens_used_so_far` and
        `confidence_actual` are computed live from the pipeline log;
        `confidence_predicted` is parsed once from the ticket's Planner
        Context block and cached for the daemon's lifetime.
        """
        log_file = self._state_dir / f'{tid}-pipeline.log'
        # Child-table snapshot under _state_lock — the table is mutated by
        # the main loop every cycle; a lock-free read races those mutations.
        # File reads and the confidence subprocess run OUTSIDE the lock:
        # _read_confidence_predicted shells out (up to 30s) and must never
        # hold the state lock.
        with self._state_lock:
            child = self._children.get(tid)
            if child is None and not log_file.is_file():
                return None

            if child is not None:
                status = {
                    'tid': tid,
                    'pid': child['pid'],
                    'generation': child['generation'],
                    'started_at': child['started_at'],
                    'reason': child['reason'],
                    'adopted': child['adopted'],
                    'phase': child.get('phase', ''),
                    'anomalies': child.get('anomalies', ''),
                }
            else:
                # Known ticket (pipeline log exists) but no live worker record.
                status = {
                    'tid': tid,
                    'pid': None,
                    'generation': None,
                    'started_at': None,
                    'reason': '',
                    'adopted': False,
                    'phase': '',
                    'anomalies': '',
                }

        status['tokens_used_so_far'] = _sum_tokens(log_file)

        if tid not in self._confidence_cache:
            self._confidence_cache[tid] = _read_confidence_predicted(
                tid, self._fleet_lib_dir)
        status['confidence_predicted'] = self._confidence_cache[tid]
        status['confidence_actual'] = _read_confidence_actual(log_file)
        return status

    def list_queue(self):
        """Spawn queue contents for GET /queue."""
        entries, malformed = _parse_queue_with_malformed(self._state_dir)
        return {'entries': entries, 'malformed': malformed}

    def list_epics(self):
        """Epic view for GET /epics — pure state-dir derivation."""
        with self._state_lock:
            workers = self._children.list_workers()
        return _list_epics(self._state_dir, workers)

    # ── spawn and reap (group 6) ──────────────────────────────────────────

    def _reap_children(self):
        """Reap any exited children and re-enqueue non-terminal survivors.

        Removes reaped workers from the child table, persists an exit
        record, and — for a worker whose pipeline log is not terminal —
        triggers scoped reconciliation through the existing
        `fleet_reconcile_orphans` restart/dead-letter path.

        The reconcile calls happen AFTER releasing _state_lock (collected
        while locked, in _reap_children_locked). Reconcile is a
        `subprocess.run(timeout=120)`; holding the lock across it would
        stall reaping, kill-request processing and the health endpoint for
        up to two minutes per dead worker — the hazard already documented
        at the `reconcile_orphaned_tickets` call site.
        """
        with self._state_lock:
            non_terminal_tids = self._reap_children_locked()
        for tid in non_terminal_tids:
            _notify_worker_event(
                self._fleet_lib_dir, str(self._state_dir), tid, 'non-terminal-exit',
            )
            self.reconcile_orphaned_tickets(scope_tids=[tid])
            _update_exit_record_action(
                str(self._state_dir), tid,
                self._last_reaped_generation.get(tid, 0),
                'reconcile-attempted',
            )

    def _reap_children_locked(self):
        """Reap exited children, persist exit records, classify terminality.

        Returns the list of tids whose worker exited over a NON-terminal
        pipeline log and were not skipped (killed_by_fleet, exit 127, or
        the circuit breaker already open) — the set `_reap_children` must
        hand to scoped reconciliation once the lock is released.

        A worker fleetd itself killed never reaches this path: kill_worker's
        own liveness re-check (`_try_reap`) already consumes the exit
        status before the SIGCHLD-driven ChildReaper sees it, and the exit
        record for that case is written at the kill call site instead (see
        _kill_worker_locked) with killed_by_fleet=True. Everything that
        reaches here died on its own — crash, OOM, an unexplained signal —
        which is exactly why `killed_by_fleet=False` is safe to hard-code.
        """
        non_terminal_tids = []
        newly_reaped = self._reaper.reap()
        for pid, exit_code, exit_type in newly_reaped:
            # The OTel exporter is a supervised child but not a ticket worker.
            # Sending it down the ticket path would write a META|worker-exit
            # line into an `otel-exporter-pipeline.log`, which fleet_detect_all
            # would then glob and report on as a stuck pipeline — a monitoring
            # process manufacturing monitoring findings about itself.
            if pid == self._otel_pid:
                self._handle_otel_exit(pid, exit_code, exit_type)
                continue
            # Same reasoning as the OTel branch above: the observer is a
            # supervised child, not a ticket worker, and must never touch
            # the ticket reap path (no exit record, no circuit breaker, no
            # pipeline-log line, no reconciliation) — design.md Goals.
            if pid == self._observer_pid:
                self._handle_observer_exit(pid, exit_code, exit_type)
                continue
            # Find the child entry by PID and remove it.
            for tid, entry in list(self._children._workers.items()):
                if entry['pid'] == pid:
                    entry['exit_code'] = exit_code
                    entry['exit_type'] = exit_type
                    entry['exited_at'] = datetime.now(timezone.utc).isoformat()
                    generation = entry.get('generation', 0)
                    self._last_reaped_generation[tid] = generation

                    terminal = _log_reached_terminal(str(self._state_dir), tid)
                    skip_127 = (exit_type == 'exit' and exit_code == 127)
                    action = 'terminal' if terminal else None
                    suppressed = 'exec-failure (exit 127)' if skip_127 else None
                    if skip_127 and not terminal:
                        action = 'skipped: exec-failure'

                    self._update_circuit_breaker(tid, entry, exit_code, exit_type)
                    if not terminal and not skip_127 and self._circuit_breaker_tripped:
                        action = f'skipped: circuit-breaker ({self._circuit_breaker_reason})'

                    hook_capture = _read_hook_capture(str(self._state_dir), tid, generation)
                    phase = entry.get('phase', '')
                    cost_usd = None
                    if _phase_mod is not None:
                        cost_usd = _phase_mod.worker_cost_usd(
                            _worker_gen_file(str(self._state_dir), tid, phase, generation))
                    _write_exit_record(
                        str(self._state_dir), tid, generation, pid,
                        exit_code, exit_type,
                        killed_by_fleet=False,
                        terminal=terminal,
                        session_id=entry.get('session_id'),
                        last_assistant_message=hook_capture.get('last_assistant_message'),
                        action=action or 'reconcile-pending',
                        suppressed_retry_reason=suppressed,
                        cost_usd=cost_usd,
                    )
                    _record_cost_event(str(self._state_dir), tid, generation, phase, cost_usd)
                    _store_record_exit(
                        str(self._state_dir), tid, pid, exit_code, exit_type)
                    status = 'done' if (exit_type == 'exit' and exit_code == 0) else 'fail'
                    _append_pipeline_log_line(
                        str(self._state_dir), tid, 'META', 'worker-exit', status,
                        f'code={exit_code} type={exit_type} gen={generation} '
                        f'killed_by_fleet=false'
                    )
                    _sweep_stale_generation_files(str(self._state_dir), tid, generation, phase=phase)

                    self._children.remove(tid)
                    print(
                        f"fleetd[{os.getpid()}]: worker {tid} (pid {pid}) "
                        f"exited ({exit_type}, code={exit_code})"
                    )
                    if not terminal and not skip_127 and not self._circuit_breaker_tripped:
                        non_terminal_tids.append(tid)
                    break
        if newly_reaped:
            self._sync_health()
        return non_terminal_tids

    def _update_circuit_breaker(self, tid, entry, exit_code, exit_type):
        """Track the deterministic-failure streak; trip dispatch off at cap.

        A fast, non-zero exit (`exit`, not a signal — a signal death is a
        different failure mode, not the "generic exit 1 in ~2.3s" expired-
        auth scenario this guards) resets nothing and extends the streak.
        Anything else (success, a slow failure, a signal) resets the streak
        to empty — the breaker cares about a STREAK of fleet-wide faults,
        not an isolated bad ticket, which the per-tid restart cap already
        bounds.
        """
        if self._circuit_breaker_tripped:
            return
        threshold_secs = _env_int('FLEET_DETERMINISTIC_FAILURE_SECS', 5)
        threshold_count = _env_int('FLEET_DETERMINISTIC_FAILURE_COUNT', 3)
        elapsed = None
        try:
            started = datetime.fromisoformat(entry.get('started_at', ''))
            elapsed = (datetime.now(timezone.utc) - started).total_seconds()
        except (ValueError, TypeError):
            pass

        is_fast_failure = (
            exit_type == 'exit' and exit_code != 0
            and elapsed is not None and elapsed < threshold_secs
        )
        if not is_fast_failure:
            self._fast_failure_streak = []
            return

        self._fast_failure_streak.append(tid)
        if len(self._fast_failure_streak) >= threshold_count:
            self._circuit_breaker_tripped = True
            self._circuit_breaker_reason = (
                f'{len(self._fast_failure_streak)} consecutive fast failures '
                f'({", ".join(self._fast_failure_streak)}) — dispatch halted'
            )
            self._spawn_enabled = False
            print(
                f"fleetd[{os.getpid()}]: CIRCUIT BREAKER TRIPPED — "
                f"{self._circuit_breaker_reason}",
                file=sys.stderr,
            )

    def _consume_queue(self, cmd_override=None):
        """Consume spawn queue entries up to FLEET_MAX_CONCURRENT.

        Only acts when spawn_enabled is True. Skips malformed entries.
        Returns the set of TIDs that were consumed.

        Acquires _state_lock — HTTP-triggered dispatch and the main loop
        must never mutate the child table or spawn-queue file concurrently.
        """
        with self._state_lock:
            return self._consume_queue_locked(cmd_override)

    def _consume_queue_locked(self, cmd_override=None):
        if not self._spawn_enabled:
            return set()

        active_count = len(self._children)
        slots = self._max_concurrent - active_count
        if slots <= 0:
            return set()

        consumed = set()
        # A stop-pin survives a fleetd restart through stop-*.json — queue
        # entries for pinned tickets must never be consumed, or a stop would
        # be defeated by reconciliation re-enqueues after a daemon restart.
        pinned_tids = _collect_stop_pinned_tids(self._state_dir)
        for entry in _read_queue_entries(self._state_dir):
            if len(consumed) >= slots:
                break

            tid = entry['tid']
            if tid in pinned_tids:
                continue
            # Don't double-spawn a ticket that's already running.
            if self._children.get(tid) is not None:
                continue

            # Skip entries whose ticket already reached a terminal state.
            # The crash window between spawn_worker and queue removal leaves
            # a stale entry behind; without this check a restart would
            # re-spawn a finished pipeline. The raw `|META|outcome|` grep is
            # gone: it dropped the campaign-resume entries the classification
            # fix produces (a killed pipeline ends with a kill outcome but is
            # resumable — see _log_reached_terminal, the mirror of
            # fleet_ticket_terminal_state).
            if _log_reached_terminal(self._state_dir, tid):
                consumed.add(tid)
                print(
                    f"fleetd[{os.getpid()}]: skipping {tid} — pipeline log "
                    f"already terminal, removing stale queue entry"
                )
                continue

            # Dual-invocation interlock (design.md task 4.19): someone else
            # — typically a human running `/ticket-auto <ID>` by hand — may
            # already be mid-phase on this ticket. Leave the queue entry in
            # place (not consumed) so the next cycle re-checks rather than
            # dropping the dispatch on the floor.
            foreign = _foreign_run_for_tid(self._state_dir, tid)
            if foreign is not None and foreign.detected:
                print(
                    f"fleetd[{os.getpid()}]: deferring {tid} — {foreign.detail}"
                )
                continue

            # A held ticket is parked, not abandoned: leave its entry in
            # place so dispatch resumes the moment the hold clears, rather
            # than dropping it on the floor (design.md D8 — this is an
            # ordering guarantee, not a timing one, because the row is
            # always written before any release path can run).
            if _store_ticket_is_held(self._state_dir, tid):
                print(
                    f"fleetd[{os.getpid()}]: deferring {tid} — held"
                )
                continue

            # The supervisor assigns generations, not the queue entry.
            # This ensures a restarted worker always gets a generation
            # higher than any fenced predecessor.
            generation = self._resolve_generation(tid)
            reason = entry.get('reason', 'dispatched')

            try:
                pid, session_id = spawn_worker(
                    tid=tid,
                    generation=generation,
                    state_dir=str(self._state_dir),
                    reason=reason,
                    cmd_override=cmd_override,
                    claude_bin=self._claude_bin,
                    claude_cmd=self._claude_cmd,
                )
            except OSError as exc:
                print(
                    f"fleetd[{os.getpid()}]: failed to spawn {tid}: {exc}",
                    file=sys.stderr,
                )
                continue

            self._children.add(
                tid=tid,
                pid=pid,
                generation=generation,
                reason=reason,
                adopted=False,  # we forked it — not adopted
                session_id=session_id,
            )
            # Ownership is recorded at dispatch: this is what scopes severity
            # >= 2 intervention to fleet-managed work and keeps a human's
            # manual run out of the fleet's kill scope.
            _store_record_spawn(
                str(self._state_dir), tid, pid, generation, reason, session_id)
            consumed.add(tid)
            print(
                f"fleetd[{os.getpid()}]: spawned {tid} (pid {pid}, "
                f"gen={generation})"
            )

        if consumed:
            _remove_consumed_entries(self._state_dir, consumed)
            self._sync_health()

        return consumed

    # ── phase dispatch (task 4.17) ─────────────────────────────────────────

    def spawn_phase(self, tid, step_id, log_file, table=None, **kwargs):
        """Spawn one phase worker and register it as a killable child.

        The module-level `spawn_phase_worker` (task 4.4) does the fork; this
        adds the one thing that function cannot do on its own — record the
        pid in `self._children`, the table `self.kill_worker`/`kill_worker()`
        already reads. Without this a hung phase worker is invisible to the
        exact escalation path (cooperative-stop → SIGINT → SIGTERM →
        SIGKILL) a ticket-level worker already gets: `spawn_phase_worker`'s
        caller wiring the two together, rather than a second kill
        implementation, is the reuse task 4.1/4.17 ask for.

        `kwargs` passes through to `spawn_phase_worker` (`hb_log_file`,
        `from_step`, `attempt`, `counters`, `env_file`, `extra_env`, `reason`,
        `cmd_override`, ...); `generation` is resolved here, the same way
        `_consume_queue` resolves it for a ticket-level spawn, so a caller
        never has to fence-check by hand. `hb_log_file`, when given, is also
        kept on the child record — `emit_phase_liveness_heartbeats` (task
        4.18) needs it every cycle, not just at spawn time.
        """
        generation = self._resolve_generation(tid)
        reason = kwargs.pop('reason', 'phase-dispatch')
        hb_log_file = kwargs.get('hb_log_file', '')
        pid, session_id, spawn = spawn_phase_worker(
            tid, step_id, generation, str(self._state_dir), log_file,
            table=table, reason=reason,
            claude_bin=kwargs.pop('claude_bin', self._claude_bin),
            claude_cmd=kwargs.pop('claude_cmd', self._claude_cmd),
            **kwargs,
        )
        self._children.add(
            tid=tid, pid=pid, generation=generation, reason=reason,
            adopted=False, phase=spawn.phase, session_id=session_id,
            start_ticks=_pid_start_time(pid), hb_log_file=hb_log_file,
        )
        return pid, session_id, spawn

    def emit_phase_liveness_heartbeats(self):
        """Write one liveness heartbeat per live phase worker (task 4.18).

        The router's backgrounded watchdog wrote `|watchdog|alive|` on its
        own timer, which `fleet-detect.sh:411`'s heartbeat dimension reads as
        one half of stall detection (the other half, `_detect_activity_stall`,
        is independent and already applies unmodified to a phase-dispatched
        ticket — it reads `{tid}-activity.log`, written by the agent's own
        hook, regardless of what spawned the agent). A phase-dispatched
        ticket has no such watchdog, so without this call the heartbeat
        dimension is silent for it and every phase-dispatched ticket falls
        back to activity-only severity — losing the KILL+RESTART tier and the
        pinger-exhaustion escalation the heartbeat dimension alone carries.

        Called once per detection cycle, before detection runs, so a stale
        write from THIS cycle is what `detect_stalls` reads THIS cycle — not
        an emit-on-schedule liveness claim: `phase_liveness_heartbeat` itself
        still writes nothing unless the pid-plus-start-ticks check passes.
        Only children with a `phase` and `hb_log_file` recorded are
        candidates — a ticket-level spawn has neither, by design.
        """
        if _phase_mod is None:  # pragma: no cover - import guard
            return
        for child in list(self._children):
            if not child.get('phase') or not child.get('hb_log_file'):
                continue
            _phase_mod.phase_liveness_heartbeat(
                child['tid'], child['phase'], child['hb_log_file'],
                child['pid'], start_ticks=child.get('start_ticks'))

    # ── kill (group 7) ───────────────────────────────────────────────────

    def kill_worker(self, tid, reason='fleet-kill', grace_secs=None):
        """Escalate kill against a worker in the child table.

        Only workers the daemon spawned (adopted=False) are eligible for
        process-group signalling. Adopted workers get cooperative-stop-only
        because we didn't fork them and can't verify process-group ownership.

        Returns a KillResult. Acquires _state_lock — see _consume_queue.
        """
        with self._state_lock:
            return self._kill_worker_locked(tid, reason, grace_secs)

    def _kill_worker_locked(self, tid, reason='fleet-kill', grace_secs=None):
        child = self._children.get(tid)
        if child is None:
            return KillResult(False, 'none',
                              f'no worker for {tid} in child table')

        pid = child['pid']
        generation = child['generation']
        adopted = child['adopted']

        if adopted:
            # Adopted workers: re-verify PID ownership before signalling.
            # If ownership is confirmed, we can apply full escalation.
            # Otherwise, cooperative stop only.
            started_at = child.get('started_at', '')
            if _verify_pid_ownership(pid, started_at, tid):
                # Ownership confirmed — full escalation is safe.
                pass  # fall through to the normal kill_worker() path
            else:
                # Cannot verify ownership — cooperative stop only.
                _write_stop_files(tid, str(self._state_dir))
                time.sleep(grace_secs if grace_secs is not None
                           else _env_int('FLEET_KILL_GRACE_SECS', 10))
                alive = _pid_is_alive(pid)
                if not alive:
                    self._record_fleet_kill_exit(tid, child, 'cooperative')
                    self._children.remove(tid)
                    self._sync_health()
                    return KillResult(True, 'cooperative', None)
                return KillResult(False, 'cooperative',
                                  f'adopted PID {pid} survived cooperative stop '
                                  f'(ownership unverified, escalation withheld)')

        result = kill_worker(
            tid=tid,
            pid=pid,
            generation=generation,
            state_dir=str(self._state_dir),
            reason=reason,
            grace_secs=grace_secs,
        )

        if result.success:
            # killed_by_fleet is sourced from THIS call succeeding — never
            # from an exit code. SIGINT exits 0, so without this, every
            # deliberate kill would look exactly like a crash and be
            # re-enqueued by reap-time recovery (design.md Decision 2/4).
            # kill_worker()'s own _is_dead()/_try_reap already consumed the
            # exit status via waitpid before this returns, so the natural
            # SIGCHLD-driven ChildReaper path in _reap_children_locked will
            # never see this pid — this is the only place its exit record
            # gets written.
            self._record_fleet_kill_exit(tid, child, result.method)
            self._children.remove(tid)
            self._sync_health()
            print(
                f"fleetd[{os.getpid()}]: killed {tid} (pid {pid}, "
                f"{result.method}) — {reason}"
            )
        else:
            print(
                f"fleetd[{os.getpid()}]: kill-unverified — {result.error}",
                file=sys.stderr,
            )

        return result

    def _record_fleet_kill_exit(self, tid, child, method):
        """Write the exit record + META|worker-exit| line for a fleet-killed worker.

        The exit code itself is unknown here — kill_worker()'s liveness
        re-check consumes it via waitpid without propagating the status —
        but that is fine: killed_by_fleet=True comes from THIS call
        succeeding, never from a code, so the skip predicate (task 3.7)
        applies regardless. Reconciliation is never triggered for this
        path — a verified kill is a deliberate pause, not a crash.
        """
        state_dir = str(self._state_dir)
        generation = child.get('generation', 0)
        terminal = _log_reached_terminal(state_dir, tid)
        # A cooperative stop lets the worker exit on its own — the Stop hook
        # fires for that rung same as any normal end. SIGINT/SIGTERM/SIGKILL
        # do not fire it, so hook_capture is simply {} for those; harmless
        # to look up unconditionally.
        hook_capture = _read_hook_capture(state_dir, tid, generation)
        phase = child.get('phase', '')
        cost_usd = None
        if _phase_mod is not None:
            cost_usd = _phase_mod.worker_cost_usd(
                _worker_gen_file(state_dir, tid, phase, generation))
        _write_exit_record(
            state_dir, tid, generation, child.get('pid'),
            exit_code=None, exit_type=method,
            killed_by_fleet=True,
            terminal=terminal,
            session_id=child.get('session_id'),
            last_assistant_message=hook_capture.get('last_assistant_message'),
            action='killed-by-fleet',
            cost_usd=cost_usd,
        )
        _record_cost_event(state_dir, tid, generation, phase, cost_usd)
        _append_pipeline_log_line(
            state_dir, tid, 'META', 'worker-exit', 'fail',
            f'code=none type={method} gen={generation} killed_by_fleet=true'
        )
        _sweep_stale_generation_files(state_dir, tid, generation, phase=phase)

    def _merge_poll_sweep(self):
        """Periodic merge-truth sweep — the async complement to the
        pipeline's own one-shot sweep (fleet-merge-poll-cadence).

        Shells out to Branch B's `lib/merge-poll.sh`, the single merge-truth
        implementation, so fleetd owns only cadence, not polling logic
        (design.md). A missing script is a no-op, not an error — fleetd
        must keep running fine on a host that hasn't received Branch B yet.
        The outer `timeout=60` bounds worst-case sweep duration independent
        of the script's own internal `timeout 20` around each `gh` call.
        """
        if _phase_mod is None:
            return
        lib_dir = _phase_mod.ticket_auto_lib_dir()
        script = Path(lib_dir) / 'merge-poll.sh'
        if not script.is_file():
            return
        runs_file = self._state_dir / 'runs.jsonl'
        try:
            subprocess.run(
                ['bash', '-c',
                 'source "$MERGE_POLL_SCRIPT" && merge_poll_sweep "$RUNS_FILE"'],
                env={**os.environ, 'MERGE_POLL_SCRIPT': str(script),
                     'RUNS_FILE': str(runs_file)},
                timeout=60, capture_output=True,
            )
        except (OSError, subprocess.SubprocessError):
            pass

    def _hold_reconcile_pass(self):
        """Probe every held ticket's release predicate and apply the result.

        `held_tickets()` -> `reconcile_hold` per row -> `release_hold` on
        `RELEASE`, a gate-stop pipeline-log line on `GATE_STOP`, nothing on
        `HOLD`/`UNAVAILABLE`. Fail-soft throughout, like every other store
        interaction: a reconcile failure for one ticket must not stop the
        pass from reaching the rest, and a store outage just means every
        held ticket stays held until the next pass (design.md D5).

        Called from `run_observe`'s cycle body only — never from
        `phase_dispatch.py` or any Group-10-flagged path, where it would ship
        fully tested and never execute (design.md D5, task 7.3).
        """
        if _gate_hold_mod is None or _phase_mod is None:
            return
        rows = _store_held_tickets(self._state_dir)
        if not rows:
            return
        try:
            table = _phase_mod.DispatchTable.load()
        except Exception as exc:  # noqa: BLE001 - a bad table must not wedge the loop
            print(f"fleetd[{os.getpid()}]: hold reconcile: failed to load "
                  f"dispatch table: {exc}", file=sys.stderr)
            return
        for row in rows:
            tid = row.get('tid')
            if not tid:
                continue
            log_file = self._state_dir / f'{tid}-pipeline.log'
            try:
                decision = _gate_hold_mod.reconcile_hold(
                    table, tid, row, str(log_file),
                    lib_dir=str(self._fleet_lib_dir))
            except Exception as exc:  # noqa: BLE001 - one ticket must not sink the pass
                print(f"fleetd[{os.getpid()}]: hold reconcile failed for "
                      f"{tid}: {exc}", file=sys.stderr)
                continue

            if decision.action == _gate_hold_mod.RELEASE:
                _store_release_hold(self._state_dir, tid, decision.hold_id)
            elif decision.action == _gate_hold_mod.GATE_STOP:
                _append_pipeline_log_line(
                    self._state_dir, tid, 'META', 'gate-stop', 'fail',
                    decision.gate_stop_code or 'GATE_HOLD_RECONCILE_FAILED')
            # HOLD / UNAVAILABLE: the row is deliberately left untouched.

    # ── run ─────────────────────────────────────────────────────────────────

    # ── OTel exporter supervision ──────────────────────────────────────────

    def _otel_log_dir(self):
        return os.environ.get('FLEET_PIPELINE_LOG_DIR') or str(self._state_dir)

    def maybe_spawn_otel(self, now=None):
        """Start the exporter if enabled, not running, and past its backoff.

        Called on startup and on every cycle, so a crashed exporter comes back
        without fleetd restarting. Returns the pid, or None.
        """
        if not otel_enabled() or self._otel_pid is not None:
            return None
        now = time.time() if now is None else now
        if now < self._otel_next_attempt:
            return None

        sid = otel_service_id()
        try:
            pid, session_id = spawn_worker(
                sid, 0, str(self._state_dir), reason='otel-exporter',
                cmd_override=_otel_cmd(self._otel_log_dir()),
            )
        except Exception as exc:
            # Never fatal: telemetry failing to start must not stop fleetd
            # supervising tickets.
            print(f"fleetd[{os.getpid()}]: otel exporter spawn failed: {exc}",
                  file=sys.stderr)
            self._otel_failures += 1
            self._otel_next_attempt = now + self._otel_backoff()
            return None

        self._otel_pid = pid
        self._children.add(sid, pid, generation=0, reason='otel-exporter',
                           session_id=session_id)
        print(f"fleetd[{os.getpid()}]: otel exporter started (pid {pid}) "
              f"watching {self._otel_log_dir()}")
        return pid

    def _otel_backoff(self):
        idx = min(self._otel_failures, len(_OTEL_RESPAWN_BACKOFF)) - 1
        return _OTEL_RESPAWN_BACKOFF[max(idx, 0)]

    def _handle_otel_exit(self, pid, exit_code, exit_type):
        """Record an exporter exit and schedule a respawn.

        Deliberately not the ticket path: no exit record, no circuit breaker,
        no pipeline-log line, no reconciliation. The exporter has no ticket
        state to reconcile and no pipeline log of its own.
        """
        sid = otel_service_id()
        self._children.remove(sid)
        self._otel_pid = None
        clean = (exit_type == 'exit' and exit_code == 0)
        if clean:
            self._otel_failures = 0
        else:
            self._otel_failures += 1
        self._otel_next_attempt = time.time() + self._otel_backoff()
        print(
            f"fleetd[{os.getpid()}]: otel exporter (pid {pid}) exited "
            f"({exit_type}, code={exit_code}); "
            f"respawn in {self._otel_backoff()}s"
        )

    def stop_otel(self, grace_secs=5):
        """Stop the exporter through the same kill escalation as any worker."""
        if self._otel_pid is None:
            return
        pid, sid = self._otel_pid, otel_service_id()
        self._otel_pid = None
        try:
            kill_worker(sid, pid, 0, str(self._state_dir),
                        reason='fleetd-shutdown', grace_secs=grace_secs)
        except Exception as exc:
            print(f"fleetd[{os.getpid()}]: otel exporter stop failed: {exc}",
                  file=sys.stderr)

    # ── Agent Observer supervision (agent-observer Inc 2, D1) ───────────────
    # Copies the OTel exporter's spawn/backoff/reap/stop wiring exactly —
    # design.md D1 calls this "architecturally the same object", not a new
    # supervision pattern.

    def _observer_log_dir(self):
        return os.environ.get('FLEET_PIPELINE_LOG_DIR') or str(self._state_dir)

    def maybe_spawn_observer(self, now=None):
        """Start the sidecar if enabled, not running, and past its backoff.

        Called on startup and on every cycle, so a crashed observer comes
        back without fleetd restarting. Returns the pid, or None.
        """
        if not observer_enabled_for_sidecar() or self._observer_pid is not None:
            return None
        now = time.time() if now is None else now
        if now < self._observer_next_attempt:
            return None

        sid = observer_service_id()
        try:
            pid, session_id = spawn_worker(
                sid, 0, str(self._state_dir), reason='agent-observer',
                cmd_override=_observer_cmd(self._observer_log_dir()),
            )
        except Exception as exc:
            # Never fatal: the observer failing to start must not stop
            # fleetd supervising tickets — design.md Goals.
            print(f"fleetd[{os.getpid()}]: agent observer spawn failed: {exc}",
                  file=sys.stderr)
            self._observer_failures += 1
            self._observer_next_attempt = now + self._observer_backoff()
            return None

        self._observer_pid = pid
        self._children.add(sid, pid, generation=0, reason='agent-observer',
                           session_id=session_id)
        print(f"fleetd[{os.getpid()}]: agent observer started (pid {pid}) "
              f"watching {self._observer_log_dir()}")
        return pid

    def _observer_backoff(self):
        idx = min(self._observer_failures, len(_OBSERVER_RESPAWN_BACKOFF)) - 1
        return _OBSERVER_RESPAWN_BACKOFF[max(idx, 0)]

    def _handle_observer_exit(self, pid, exit_code, exit_type):
        """Record an observer exit and schedule a respawn.

        Deliberately not the ticket path: no exit record, no circuit
        breaker, no pipeline-log line, no reconciliation. The observer has
        no ticket state to reconcile and no pipeline log of its own.
        """
        sid = observer_service_id()
        self._children.remove(sid)
        self._observer_pid = None
        clean = (exit_type == 'exit' and exit_code == 0)
        if clean:
            self._observer_failures = 0
        else:
            self._observer_failures += 1
        self._observer_next_attempt = time.time() + self._observer_backoff()
        print(
            f"fleetd[{os.getpid()}]: agent observer (pid {pid}) exited "
            f"({exit_type}, code={exit_code}); "
            f"respawn in {self._observer_backoff()}s"
        )

    def stop_observer(self, grace_secs=5):
        """Stop the observer through the same kill escalation as any worker."""
        if self._observer_pid is None:
            return
        pid, sid = self._observer_pid, observer_service_id()
        self._observer_pid = None
        try:
            kill_worker(sid, pid, 0, str(self._state_dir),
                        reason='fleetd-shutdown', grace_secs=grace_secs)
        except Exception as exc:
            print(f"fleetd[{os.getpid()}]: agent observer stop failed: {exc}",
                  file=sys.stderr)
        self._children.remove(sid)

    def run_observe(self, cmd_override=None):
        """Daemon main loop: detect, reap, spawn (if enabled), repeat.

        Acquires the lock, scans existing registry entries, starts the health
        endpoint, then loops: reap children → consume queue → detect.
        Runs until SIGTERM/SIGINT.

        cmd_override: if provided, used as the worker argv for all spawns.
        This allows tests to substitute a simple Python process for claude.
        """
        self.acquire_lock()
        mode = 'spawn' if self._spawn_enabled else 'observe'
        print(
            f"fleetd[{os.getpid()}]: lock acquired, state_dir={self._state_dir}, "
            f"mode={mode}, max_concurrent={self._max_concurrent}"
        )
        self.scan_workers()
        print(f"fleetd[{os.getpid()}]: observed {len(self._children)} worker(s) from registry")
        # One-shot startup reconciliation: re-enqueue tickets orphaned by a
        # controller crash (worker died while fleetd itself was down).
        # Runs once, right after adoption, before the first detection cycle.
        self.reconcile_orphaned_tickets()

        health = HealthServer(self._bind, self._port)
        health.start(self)
        print(f"fleetd[{os.getpid()}]: health endpoint on {self._bind}:{self._port}")

        # Telemetry starts after the health endpoint and before the first
        # detection cycle, so a trace exists for work this run does.
        self.maybe_spawn_otel()
        self.maybe_spawn_observer()

        shutdown_event = threading.Event()

        def _on_signal(signum, frame):
            shutdown_event.set()

        signal.signal(signal.SIGTERM, _on_signal)
        signal.signal(signal.SIGINT, _on_signal)

        try:
            # Initial cycle: detect state immediately.
            self.run_detection_cycle()

            cycle_num = 0
            while not shutdown_event.is_set():
                # 1. Reap any exited children (always, even in observe mode).
                self._reap_children()

                # 2. Process CLI kill requests (every cycle — urgent).
                self._process_kill_requests()

                # 3. Poll adopted workers (every 3rd cycle).
                cycle_num += 1
                if cycle_num % 3 == 0:
                    self.poll_adopted_workers()

                # 3b. Periodic merge-poll sweep (fleet-merge-poll-cadence).
                if cycle_num % FLEET_MERGE_POLL_CYCLES == 0:
                    self._merge_poll_sweep()

                # 4. Consume spawn queue (no-op when spawn is disabled).
                self._consume_queue(cmd_override=cmd_override)

                # 4a. Hold-reconciliation pass, on its own cadence — a Linear
                # round trip per held ticket, not the 30s detection interval
                # (design.md D5). Must stay in this live loop, never the
                # Group-10-flagged phase-dispatch path (task 7.3).
                if _gate_hold_mod is not None and _gate_hold_mod.is_due(
                        self._hold_reconcile_last_run):
                    self._hold_reconcile_pass()
                    self._hold_reconcile_last_run = time.time()

                # 4b. Restart the exporter if it died (no-op when disabled,
                # already running, or still inside its backoff window).
                self.maybe_spawn_otel()
                self.maybe_spawn_observer()

                # 4. Wait for next interval or shutdown.
                if shutdown_event.wait(timeout=self._cycle_interval):
                    break

                # 5. Run detection.
                self.run_detection_cycle()
        finally:
            # Cooperative shutdown: stop health server, release lock.
            # In future groups we'll also attempt cooperative stop of all
            # workers before exiting.
            self.stop_otel()
            self.stop_observer()
            health.shutdown()
            self._reaper.close()
            self.release_lock()
            print(f"fleetd[{os.getpid()}]: stopped")
