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
from datetime import datetime, timezone
from pathlib import Path


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
        # {tid: {pid, started_at, generation, reason, adopted, phase, anomalies}}
        self._workers = {}

    def add(self, tid, pid, generation=0, reason='', adopted=False, phase='',
            anomalies=''):
        self._workers[tid] = {
            'tid': tid,
            'pid': pid,
            'generation': generation,
            'started_at': datetime.now(timezone.utc).isoformat(),
            'reason': reason,
            'adopted': adopted,
            'phase': phase,
            'anomalies': anomalies,
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


def _write_fence_files(tid, generation, state_dir):
    """Write a generation fence marker so the next spawn uses a higher generation."""
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


# ── Kill escalation ────────────────────────────────────────────────────────

KILL_ESCALATION_ORDER = ('cooperative', 'SIGTERM', 'SIGKILL')


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
    """Escalate: cooperative stop → grace → SIGTERM → grace → SIGKILL.

    Each step verifies the process is still alive before proceeding.
    - Cooperative stop: touch stop files, wait grace, check.
    - SIGTERM: signal the process group, wait grace, check.
    - SIGKILL: signal the process group, brief wait, check.

    Returns a KillResult: (success: bool, method: str, error: str|None).

    Signals target the process GROUP (not just the PID) because the worker
    spawns subprocesses (git, CLI tools, test runners) and those must
    terminate with the worker.
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

    # ── Step 2: SIGTERM to process group ──────────────────────────────────
    _signal_process_group(pid, signal.SIGTERM)
    time.sleep(grace)

    if _is_dead():
        _write_fence_files(tid, generation, state_dir)
        return KillResult(True, 'SIGTERM', None)

    # ── Step 3: SIGKILL to process group ──────────────────────────────────
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

def _write_run_registry(state_dir, tid, pid, generation, reason='dispatched'):
    """Write a run registry entry with the REAL pid (not a sentinel)."""
    run_file = Path(state_dir) / f'{tid}-run.json'
    entry = {
        'tid': tid,
        'pid': str(pid),
        'generation': generation,
        'started_at': datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
        'reason': reason,
    }
    run_file.write_text(json.dumps(entry))


def _build_worker_cmd(tid, claude_bin=None, claude_cmd=None):
    """Build the argument list for spawning a ticket-auto worker.

    `claude_cmd` (or the CLAUDE_CMD env var) is a shell-style command line —
    e.g. "claude-deepseek 2 --bypass" — that replaces the bare binary name
    and takes precedence over `claude_bin`/CLAUDE_BIN. The ticket-auto
    invocation is always appended after it.

    Returns a list suitable for os.execvpe().
    """
    cmd_str = claude_cmd or CLAUDE_CMD
    prefix = shlex.split(cmd_str) if cmd_str else [claude_bin or CLAUDE_BIN]
    return prefix + ['-p', f'/ticket-auto {tid} --auto --from-planned']


class SpawnError(Exception):
    """Raised when a worker cannot be spawned."""


def spawn_worker(tid, generation, state_dir, reason='dispatched',
                 cmd_override=None, claude_bin=None, claude_cmd=None):
    """Fork and exec a worker for `tid`. Returns the child PID.

    The child is placed in its own process group so that kill escalation
    (group 7) can signal the entire worker subtree.

    cmd_override: if provided, used as the argv list instead of the default
    claude invocation. This allows tests to spawn a simple Python process.
    claude_bin/claude_cmd: forwarded to _build_worker_cmd when cmd_override
    is not given — see its docstring.
    """
    cmd = cmd_override if cmd_override is not None else _build_worker_cmd(
        tid, claude_bin=claude_bin, claude_cmd=claude_cmd)

    pid = os.fork()
    if pid == 0:
        # Child: create new process group, exec the worker.
        try:
            os.setpgid(0, 0)
        except OSError:
            pass  # best-effort — we may already be the group leader

        # Ensure stdin is detached so the worker does not compete for the
        # terminal with the daemon.
        try:
            fd = os.open(os.devnull, os.O_RDONLY)
            os.dup2(fd, 0)
            os.close(fd)
        except OSError:
            pass

        try:
            os.execvpe(cmd[0], cmd, os.environ)
        except OSError:
            # exec failed — exit so the parent's SIGCHLD handler can record
            # the failure rather than having a forked Python interpreter
            # running supervisor code in the child.
            os._exit(127)

    # Parent: record the real PID in the run registry.
    _write_run_registry(state_dir, tid, pid, generation, reason)
    return pid


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

    Terminal iff:
      - the last line's step is `dead-letter`, or
      - the last line's step is `outcome` and its message contains neither
        `stopped: fleet-kill` (a verified kill is a pause — resumable) nor
        `held: gate` (waiting on the human, not terminal), or
      - any `|META|gate-stop|fail|` line exists (structural stop — must
        never resume).
    A missing/empty log is NOT terminal, same as the bash classifier.
    """
    log_file = Path(state_dir) / f'{tid}-pipeline.log'
    try:
        lines = [ln for ln in log_file.read_text().splitlines() if ln]
    except OSError:
        return False
    if not lines:
        return False

    if any('|META|gate-stop|fail|' in ln for ln in lines):
        return True

    last = lines[-1].split('|')
    if len(last) >= 4 and last[3] == 'dead-letter':
        return True
    if len(last) >= 5 and last[3] == 'outcome':
        msg = '|'.join(last[4:])
        if 'stopped: fleet-kill' in msg or 'held: gate' in msg:
            return False
        return True
    return False


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
        self._health_state = {
            'workers': [],
            'queue_depth': 0,
            'last_cycle_at': None,
            'last_cycle_success': None,
            'last_cycle_error': None,
            'cycle_count': 0,
            'spawn_enabled': self._spawn_enabled,
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
        self._sync_health()

    def reconcile_orphaned_tickets(self):
        """One-shot startup reconciliation of tickets orphaned by a restart.

        Runs the bash fleet-reconcile.sh once, immediately after worker
        adoption: classifies every known ticket by its own pipeline log
        (read-only, no Linear/gh calls) and re-enqueues `incomplete`
        tickets that have no adopted-live worker and no existing queue
        entry. The adopted-live TID set is passed in so the bash side can
        exclude workers this instance just adopted.

        A reconciliation failure logs and continues — it must never block
        daemon startup (matching the sync-failure-does-not-block-dispatch
        pattern).
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
        """Reap any exited children and update the child table.

        Removes reaped workers from the child table and records their exit
        status. Called from the main loop each cycle. Acquires _state_lock.
        """
        with self._state_lock:
            self._reap_children_locked()

    def _reap_children_locked(self):
        newly_reaped = self._reaper.reap()
        for pid, exit_code, exit_type in newly_reaped:
            # Find the child entry by PID and remove it.
            for tid, entry in list(self._children._workers.items()):
                if entry['pid'] == pid:
                    entry['exit_code'] = exit_code
                    entry['exit_type'] = exit_type
                    entry['exited_at'] = datetime.now(timezone.utc).isoformat()
                    self._children.remove(tid)
                    print(
                        f"fleetd[{os.getpid()}]: worker {tid} (pid {pid}) "
                        f"exited ({exit_type}, code={exit_code})"
                    )
                    break
        if newly_reaped:
            self._sync_health()

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

            # The supervisor assigns generations, not the queue entry.
            # This ensures a restarted worker always gets a generation
            # higher than any fenced predecessor.
            generation = self._resolve_generation(tid)
            reason = entry.get('reason', 'dispatched')

            try:
                pid = spawn_worker(
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
            )
            consumed.add(tid)
            print(
                f"fleetd[{os.getpid()}]: spawned {tid} (pid {pid}, "
                f"gen={generation})"
            )

        if consumed:
            _remove_consumed_entries(self._state_dir, consumed)
            self._sync_health()

        return consumed

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

    # ── run ─────────────────────────────────────────────────────────────────

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

                # 4. Consume spawn queue (no-op when spawn is disabled).
                self._consume_queue(cmd_override=cmd_override)

                # 4. Wait for next interval or shutdown.
                if shutdown_event.wait(timeout=self._cycle_interval):
                    break

                # 5. Run detection.
                self.run_detection_cycle()
        finally:
            # Cooperative shutdown: stop health server, release lock.
            # In future groups we'll also attempt cooperative stop of all
            # workers before exiting.
            health.shutdown()
            self._reaper.close()
            self.release_lock()
            print(f"fleetd[{os.getpid()}]: stopped")
