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

# Fallback workspace — the fleet state dir when FLEET_STATE_DIR is unset.
# In the container this is the tickets directory.
DEFAULT_WORKSPACE = os.environ.get('FLEETD_WORKSPACE', '.')

# Path to the pidfile used for single-instance enforcement.
DEFAULT_PIDFILE = os.environ.get(
    'FLEETD_PIDFILE',
    '/tmp/fleetd.pid',
)


def _resolve_state_dir():
    """Resolve the fleet state directory using the same rule as config.sh."""
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
        # {tid: {pid, started_at, generation, reason, adopted, phase}}
        self._workers = {}

    def add(self, tid, pid, generation=0, reason='', adopted=False, phase=''):
        self._workers[tid] = {
            'tid': tid,
            'pid': pid,
            'generation': generation,
            'started_at': datetime.now(timezone.utc).isoformat(),
            'reason': reason,
            'adopted': adopted,
            'phase': phase,
        }

    def remove(self, tid):
        self._workers.pop(tid, None)

    def get(self, tid):
        return self._workers.get(tid)

    def update_phase(self, tid, phase):
        entry = self._workers.get(tid)
        if entry:
            entry['phase'] = phase

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
            }
            for w in self._workers.values()
        ]


# ── Registry scanner ───────────────────────────────────────────────────────

def scan_registry(state_dir, verify_ownership=False):
    """Read existing run-registry files and return parsed entries.

    Each *-run.json file contains {tid, pid, generation, started_at, reason}.
    When verify_ownership is True (crash recovery on startup), each entry's
    PID is checked not just for liveness but also for start-time consistency
    with the registry. Entries that fail ownership verification are excluded.

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
                # PID ownership cannot be confirmed — clear the stale entry
                # and do NOT adopt. Never signal an unverified PID.
                try:
                    run_file.unlink()
                except OSError:
                    pass
                continue

        # If the PID is dead, clear the stale registry entry.
        if not alive:
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


# ── Health HTTP server ─────────────────────────────────────────────────────

class HealthHandler(http.server.BaseHTTPRequestHandler):
    """HTTP request handler for the fleetd health endpoint.

    GET /health — returns JSON with live workers, queue depth, cycle info.
    All other paths → 404.
    """

    # Set by the Supervisor before starting the server.
    supervisor_state = None

    def log_message(self, format, *args):
        """Suppress default stderr logging — fleetd health is polled frequently."""
        pass

    def do_GET(self):
        if self.path == '/health':
            self._handle_health()
        else:
            self.send_error(404)

    def do_HEAD(self):
        if self.path == '/health':
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
        else:
            self.send_error(404)

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

        body = json.dumps(payload).encode('utf-8')
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)


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

    def start(self, supervisor_state_ref):
        """Start serving in a daemon thread."""
        HealthHandler.supervisor_state = supervisor_state_ref
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
        # (config.sh etc.) relative to its location on disk.
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
    Uses the same path conventions as config.sh's _fleet_stop_file().
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

# pylint: disable=invalid-name


# ── Spawn queue consumer ───────────────────────────────────────────────────

def _read_queue_entries(state_dir):
    """Yield parsed entries from the spawn queue JSONL file.

    Skips malformed entries (unparseable JSON, missing tid) so they do not
    halt queue consumption. Callers should remove consumed entries by
    rewriting the file.
    """
    queue_file = Path(state_dir) / f'fleet-{FLEET_INSTANCE_ID}-spawn-queue.jsonl'
    if not queue_file.is_file():
        return

    with open(queue_file) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                entry = json.loads(line)
            except json.JSONDecodeError:
                # Malformed entry — skip, don't halt consumption.
                print(f"fleetd: skipping malformed queue entry: {line[:80]}...",
                      file=sys.stderr)
                continue
            tid = entry.get('tid', '')
            if not tid:
                continue
            yield entry


def _remove_consumed_entries(state_dir, consumed_tids):
    """Rewrite the spawn queue without entries whose TIDs are in `consumed_tids`."""
    if not consumed_tids:
        return
    queue_file = Path(state_dir) / f'fleet-{FLEET_INSTANCE_ID}-spawn-queue.jsonl'
    if not queue_file.is_file():
        return
    kept = []
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


def _build_worker_cmd(tid, claude_bin=None):
    """Build the argument list for spawning a ticket-auto worker.

    Returns a list suitable for os.execvpe().
    """
    bin_path = claude_bin or CLAUDE_BIN
    return [bin_path, '-p', f'/ticket-auto {tid} --auto --from-planned']


class SpawnError(Exception):
    """Raised when a worker cannot be spawned."""


def spawn_worker(tid, generation, state_dir, reason='dispatched',
                 cmd_override=None):
    """Fork and exec a worker for `tid`. Returns the child PID.

    The child is placed in its own process group so that kill escalation
    (group 7) can signal the entire worker subtree.

    cmd_override: if provided, used as the argv list instead of the default
    claude invocation. This allows tests to spawn a simple Python process.
    """
    cmd = cmd_override if cmd_override is not None else _build_worker_cmd(tid)

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
                 spawn_enabled=None, max_concurrent=None, claude_bin=None):
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
        self._lock = InstanceLock(self._pidfile)
        self._children = ChildTable()
        self._reaper = ChildReaper()
        self._detection = DetectionCycle(fleet_lib_dir=fleet_lib_dir)
        self._cycle_cache = None  # created fresh per cycle
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

    def poll_adopted_workers(self):
        """Detect exits of adopted workers by liveness polling.

        Adopted workers were not forked by this daemon instance, so their
        exits cannot be reaped via waitpid. Instead we periodically check
        whether their PID is still alive and remove any that have exited.
        """
        removed = []
        for entry in list(self._children._workers.values()):
            if not entry.get('adopted'):
                continue
            if not _pid_is_alive(entry['pid']):
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

        Reads any existing fence marker and run registry to find the highest
        previously recorded generation, then increments. This ensures a
        restarted worker is never fenced by its predecessor — its generation
        is always strictly greater than the fenced generation.

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

    # ── spawn and reap (group 6) ──────────────────────────────────────────

    def _reap_children(self):
        """Reap any exited children and update the child table.

        Removes reaped workers from the child table and records their exit
        status. Called from the main loop each cycle.
        """
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
        """
        if not self._spawn_enabled:
            return set()

        active_count = len(self._children)
        slots = self._max_concurrent - active_count
        if slots <= 0:
            return set()

        consumed = set()
        for entry in _read_queue_entries(self._state_dir):
            if len(consumed) >= slots:
                break

            tid = entry['tid']
            # Don't double-spawn a ticket that's already running.
            if self._children.get(tid) is not None:
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

        Returns a KillResult.
        """
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

        health = HealthServer(self._bind, self._port)
        health.start(self._health_state)
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
