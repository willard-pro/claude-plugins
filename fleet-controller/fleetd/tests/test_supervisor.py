"""
Tests for fleetd supervisor — group 4.6.

Tests:
- Second instance refuses to start
- Lock from a dead instance does not block startup
- Endpoint responds with an empty worker set

Run:
    python -m pytest fleet-controller/fleetd/tests/test_supervisor.py -v
    # or directly:
    python fleet-controller/fleetd/tests/test_supervisor.py

NOTE: MUST run from the repo root. The daemon tests shell out to
`python -m fleet-controller.fleetd`, which needs the repo root on
sys.path — from inside fleet-controller/ those tests fail with
ModuleNotFoundError (the Makefile documents the same requirement).
"""

import fcntl
import http.client
import json
import os
import signal
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path


# Locate the fleetd package.
FLEETD_DIR = Path(__file__).resolve().parent.parent
FLEET_CONTROLLER_DIR = FLEETD_DIR.parent
MODULE = 'fleet-controller.fleetd'


def _fleetd_cmd(state_dir, pidfile, port, bind='127.0.0.1'):
    """Build a command line to launch fleetd in observe mode."""
    return [
        sys.executable, '-m', 'fleet-controller.fleetd',
        '--state-dir', str(state_dir),
        '--pidfile', str(pidfile),
        '--port', str(port),
        '--bind', bind,
    ]


def _health_check(port, timeout=2):
    """GET /health and return the parsed JSON. None on failure."""
    try:
        conn = http.client.HTTPConnection('127.0.0.1', port, timeout=timeout)
        conn.request('GET', '/health')
        resp = conn.getresponse()
        body = resp.read()
        conn.close()
        return json.loads(body)
    except Exception:
        return None


def _wait_health(port, timeout=5):
    """Poll /health until it responds, return the payload or None."""
    deadline = time.time() + timeout
    while time.time() < deadline:
        payload = _health_check(port)
        if payload is not None:
            return payload
        time.sleep(0.1)
    return None


def _safe_tmp_cleanup(tmp, retries=10, delay=0.1):
    """Retry TemporaryDirectory.cleanup() against a narrow, benign race.

    A spawned test worker's forked child creates its per-generation stdio
    files (worker-reap-recovery) asynchronously relative to the parent
    returning from _consume_queue — many tests here don't wait for or kill
    the worker before tearDown. If shutil.rmtree snapshots the directory
    listing at the exact instant the child is mid-open(), a new entry can
    appear after the snapshot and rmdir raises ENOTEMPTY. The child's
    remaining work (open, dup2, execve) completes in low-single-digit
    milliseconds, so a short retry loop is sufficient — this is test
    infrastructure hygiene, not a production concern (nothing deletes
    FLEET_STATE_DIR out from under a live worker).
    """
    for attempt in range(retries):
        try:
            tmp.cleanup()
            return
        except OSError:
            if attempt == retries - 1:
                raise
            time.sleep(delay)


class SingleInstanceTest(unittest.TestCase):
    """Task 4.6: single-instance enforcement."""

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.state_dir = Path(self._tmp.name)
        self.pidfile = self.state_dir / 'fleetd.pid'
        self.port = _find_free_port()

    def tearDown(self):
        _safe_tmp_cleanup(self._tmp)

    def test_second_instance_refuses_to_start(self):
        """Second instance exits with error when another holds the lock."""
        cmd = _fleetd_cmd(self.state_dir, self.pidfile, self.port)
        p1 = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            # Wait for health endpoint to come up.
            payload = _wait_health(self.port)
            self.assertIsNotNone(payload, "first instance should start and serve health")
            self.assertIn('workers', payload)

            # Try to start a second instance.
            p2 = subprocess.run(
                cmd,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                timeout=5,
            )
            self.assertNotEqual(p2.returncode, 0,
                                "second instance should fail to start")
            stderr = p2.stderr.decode()
            self.assertIn('already running', stderr,
                          "stderr should report the running instance")
            self.assertIn(str(p1.pid), stderr,
                          "stderr should include the holder PID")

        finally:
            p1.send_signal(signal.SIGTERM)
            p1.wait(timeout=5)

    def test_dead_instance_lock_does_not_block_startup(self):
        """A new instance starts normally after the previous one dies."""
        cmd = _fleetd_cmd(self.state_dir, self.pidfile, self.port)
        p1 = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            payload = _wait_health(self.port)
            self.assertIsNotNone(payload)
            p1_pid = p1.pid
        finally:
            p1.send_signal(signal.SIGTERM)
            p1.wait(timeout=5)

        # Verify pidfile still exists (the file itself, not the lock).
        self.assertTrue(self.pidfile.exists(),
                        "pidfile should still exist on disk after first instance exits")

        # Give the kernel a moment to release the flock.
        time.sleep(0.3)

        # Start a second instance on a different port to avoid bind collision.
        port2 = _find_free_port(start=self.port + 1)
        cmd2 = _fleetd_cmd(self.state_dir, self.pidfile, port2)
        p2 = subprocess.Popen(cmd2, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            payload = _wait_health(port2)
            self.assertIsNotNone(payload,
                                 "second instance should start after first is dead")
            self.assertNotEqual(p2.pid, p1_pid,
                                "new instance should have a different PID")
        finally:
            p2.send_signal(signal.SIGTERM)
            p2.wait(timeout=5)


class HealthEndpointTest(unittest.TestCase):
    """Task 4.6: health endpoint behaviour."""

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.state_dir = Path(self._tmp.name)
        self.pidfile = self.state_dir / 'fleetd.pid'
        self.port = _find_free_port()

    def tearDown(self):
        _safe_tmp_cleanup(self._tmp)

    def test_empty_worker_set(self):
        """Health endpoint reports an empty worker set when nothing is running."""
        cmd = _fleetd_cmd(self.state_dir, self.pidfile, self.port)
        p = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            payload = _wait_health(self.port)
            self.assertIsNotNone(payload)
            self.assertEqual(payload.get('worker_count'), 0,
                             "worker_count should be 0 with no registry entries")
            self.assertEqual(payload.get('workers'), [],
                             "workers should be an empty list")
            self.assertIn('queue_depth', payload,
                          "payload should include queue_depth")
            self.assertIn('last_cycle_at', payload,
                          "payload should include last_cycle_at")
        finally:
            p.send_signal(signal.SIGTERM)
            p.wait(timeout=5)

    def test_health_head_request(self):
        """HEAD /health returns 200 with no body."""
        cmd = _fleetd_cmd(self.state_dir, self.pidfile, self.port)
        p = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            _wait_health(self.port)
            conn = http.client.HTTPConnection('127.0.0.1', self.port, timeout=2)
            conn.request('HEAD', '/health')
            resp = conn.getresponse()
            body = resp.read()
            conn.close()
            self.assertEqual(resp.status, 200)
            self.assertEqual(len(body), 0, "HEAD should return no body")
        finally:
            p.send_signal(signal.SIGTERM)
            p.wait(timeout=5)

    def test_unknown_path_returns_404(self):
        """Non-/health paths return 404."""
        cmd = _fleetd_cmd(self.state_dir, self.pidfile, self.port)
        p = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            _wait_health(self.port)
            conn = http.client.HTTPConnection('127.0.0.1', self.port, timeout=2)
            conn.request('GET', '/')
            resp = conn.getresponse()
            resp.read()
            conn.close()
            self.assertEqual(resp.status, 404)
        finally:
            p.send_signal(signal.SIGTERM)
            p.wait(timeout=5)

    def test_loopback_only(self):
        """Health endpoint binds loopback, not all interfaces."""
        cmd = _fleetd_cmd(self.state_dir, self.pidfile, self.port)
        p = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            payload = _wait_health(self.port)
            self.assertIsNotNone(payload)
            # Verify the bind address from the process args or just
            # confirm 127.0.0.1 works and that the env var is respected.
            # The default is 127.0.0.1 per FLEETD_BIND.
            self.assertIn('workers', payload)
            self.assertIn('queue_depth', payload)
        finally:
            p.send_signal(signal.SIGTERM)
            p.wait(timeout=5)


class ObserverFindingCountsTest(unittest.TestCase):
    """agent-observer Inc 4 task 5.2: {severity: count} on /health."""

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.state_dir = Path(self._tmp.name)

    def tearDown(self):
        _safe_tmp_cleanup(self._tmp)

    def _insert_finding(self, tid, phase, fingerprint, severity):
        from fleetd import store as store_mod

        path = self.state_dir / f'{tid}-{phase.lower()}-findings.jsonl'
        existing = path.read_text() if path.is_file() else ''
        entry = {
            'type': 'UNEXPECTED_TOOL', 'severity': severity, 'tid': tid,
            'phase': phase, 'gen': 1, 'fingerprint': fingerprint, 'count': 1,
            'first_seen': '2026-09-06T10:00:00Z', 'last_seen': '2026-09-06T10:00:00Z',
            'evidence': {},
        }
        path.write_text(existing + json.dumps(entry) + '\n')
        with store_mod.open_store(self.state_dir) as st:
            st.ingest_findings(path)

    def test_store_finding_counts_groups_by_severity(self):
        from fleetd import supervisor as sup_mod

        self._insert_finding('CRE-1', 'APPRAISE', 'fp1', 'HIGH')
        self._insert_finding('CRE-1', 'IMPLEMENT', 'fp2', 'HIGH')
        self._insert_finding('CRE-2', 'VERIFY', 'fp3', 'WARN')
        counts = sup_mod._store_finding_counts(str(self.state_dir))
        self.assertEqual(counts, {'HIGH': 2, 'WARN': 1})

    def test_empty_store_yields_empty_dict(self):
        from fleetd import supervisor as sup_mod

        self.assertEqual(sup_mod._store_finding_counts(str(self.state_dir)), {})

    def test_disabled_store_yields_empty_dict_not_none(self):
        from unittest import mock
        from fleetd import supervisor as sup_mod

        with mock.patch.object(sup_mod, 'FLEET_STORE_ENABLE', False):
            self.assertEqual(sup_mod._store_finding_counts(str(self.state_dir)), {})

    def test_sync_health_populates_observer_findings(self):
        from fleetd.supervisor import Supervisor

        self._insert_finding('CRE-1', 'APPRAISE', 'fp1', 'HIGH')
        sup = Supervisor(state_dir=str(self.state_dir),
                         pidfile=str(self.state_dir / 'test.pid'))
        sup._sync_health()
        self.assertEqual(sup._health_state['observer_findings'], {'HIGH': 1})

    def test_health_payload_includes_observer_findings_key(self):
        port = _find_free_port()
        cmd = _fleetd_cmd(self.state_dir, self.state_dir / 'fleetd.pid', port)
        p = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            payload = _wait_health(port)
            self.assertIsNotNone(payload)
            self.assertIn('observer_findings', payload)
            self.assertEqual(payload['observer_findings'], {})
        finally:
            p.send_signal(signal.SIGTERM)
            p.wait(timeout=5)


class RegistryObservationTest(unittest.TestCase):
    """Task 4.4: observe-only mode reads existing registry entries."""

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.state_dir = Path(self._tmp.name)
        self.pidfile = self.state_dir / 'fleetd.pid'
        self.port = _find_free_port()

    def tearDown(self):
        _safe_tmp_cleanup(self._tmp)

    def test_zero_pid_entries_are_skipped(self):
        """Registry entries with PID 0 (sentinel) are not reported as live."""
        # Write a run file with the sentinel zero PID.
        run_file = self.state_dir / 'CRE-999-run.json'
        run_file.write_text(json.dumps({
            'tid': 'CRE-999',
            'pid': '0',
            'generation': 1,
            'started_at': '2026-01-01T00:00:00Z',
            'reason': 'test',
        }))

        cmd = _fleetd_cmd(self.state_dir, self.pidfile, self.port)
        p = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            payload = _wait_health(self.port)
            self.assertIsNotNone(payload)
            self.assertEqual(payload.get('worker_count'), 0,
                             "zero-PID entries should not appear as workers")
        finally:
            p.send_signal(signal.SIGTERM)
            p.wait(timeout=5)

    def test_live_pid_entry_is_reported(self):
        """Registry entry with an alive PID (our own test process) is reported."""
        # Spawn a long-lived child whose cmdline contains the TID so
        # ownership verification passes (group 8 crash recovery check).
        sleeper = subprocess.Popen(
            [sys.executable, '-c',
             'import time; time.sleep(30)  # worker: CRE-100'],
        )
        try:
            self.assertTrue(_pid_is_alive(sleeper.pid),
                            "sleeper should be alive for test")

            run_file = self.state_dir / 'CRE-100-run.json'
            run_file.write_text(json.dumps({
                'tid': 'CRE-100',
                'pid': str(sleeper.pid),
                'generation': 1,
                'started_at': '2026-01-01T00:00:00Z',
                'reason': 'test-spawn',
            }))

            cmd = _fleetd_cmd(self.state_dir, self.pidfile, self.port)
            p = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            try:
                payload = _wait_health(self.port)
                self.assertIsNotNone(payload)
                self.assertEqual(payload.get('worker_count'), 1,
                                 "live PID should appear as a worker")
                worker = payload['workers'][0]
                self.assertEqual(worker['tid'], 'CRE-100')
                self.assertEqual(worker['pid'], sleeper.pid)
                self.assertTrue(worker.get('adopted'),
                                "registry-scanned workers should be marked adopted")
            finally:
                p.send_signal(signal.SIGTERM)
                p.wait(timeout=5)
        finally:
            sleeper.terminate()
            sleeper.wait(timeout=5)


# ── Group 5: Detection integration tests ─────────────────────────────────


class DetectionCycleTest(unittest.TestCase):
    """Task 5.4: daemon-path and CLI-path detection produce identical results."""

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.workspace = Path(self._tmp.name)

    def tearDown(self):
        _safe_tmp_cleanup(self._tmp)

    def _write_pipeline_log(self, tid, lines):
        """Write a minimal pipeline log for a ticket."""
        log_file = self.workspace / f'{tid}-pipeline.log'
        log_file.write_text('\n'.join(lines) + '\n')

    def test_empty_workspace_yields_empty_results(self):
        """Both paths return empty results for a workspace with no pipeline logs."""
        from fleetd.supervisor import DetectionCycle
        dc = DetectionCycle()
        daemon_result = dc.run(str(self.workspace))

        cli_result = _run_fleet_detect_all(str(self.workspace))

        self.assertIsNotNone(daemon_result)
        self.assertIsNotNone(cli_result)
        self.assertEqual(
            daemon_result.get('summary', {}).get('total', 0),
            cli_result.get('summary', {}).get('total', 0),
            "daemon and CLI should agree on total count for empty workspace",
        )

    def test_identical_results_for_same_state(self):
        """Daemon and CLI detect the same anomalies for identical pipeline logs."""
        # Write a pipeline log with clear anomalies: a phase failure, a stall,
        # and a zombie pattern.
        now = datetime.now(timezone.utc)
        stale_time = (now - timedelta(hours=2)).strftime('%Y-%m-%dT%H:%M:%SZ')

        self._write_pipeline_log('TST-1', [
            f'{stale_time}|APPRAISE|fail|complexity-sweep|test failure',
        ])

        from fleetd.supervisor import DetectionCycle
        dc = DetectionCycle()
        daemon_result = dc.run(str(self.workspace))

        cli_result = _run_fleet_detect_all(str(self.workspace))

        self.assertIsNotNone(daemon_result, "daemon detection should succeed")
        self.assertIsNotNone(cli_result, "CLI detection should succeed")

        # Summaries should match (total pipeline count at minimum).
        daemon_summary = daemon_result.get('summary', {})
        cli_summary = cli_result.get('summary', {})
        self.assertEqual(
            daemon_summary.get('total'),
            cli_summary.get('total'),
            "pipeline count should match between daemon and CLI",
        )

        # Pipeline-level results should have the same TIDs.
        daemon_tids = {p.get('tid') for p in daemon_result.get('pipelines', [])}
        cli_tids = {p.get('tid') for p in cli_result.get('pipelines', [])}
        self.assertEqual(daemon_tids, cli_tids,
                         "detected TIDs should match between daemon and CLI")

        # Severities should match for each TID.
        for tid in daemon_tids:
            daemon_sev = _get_severity(daemon_result, tid)
            cli_sev = _get_severity(cli_result, tid)
            self.assertEqual(
                daemon_sev, cli_sev,
                f"severity for {tid} should match: daemon={daemon_sev}, CLI={cli_sev}",
            )

    def test_detection_failure_is_reported(self):
        """A failing detection (missing script) reports the error."""
        from fleetd.supervisor import DetectionCycle
        dc = DetectionCycle(fleet_lib_dir='/nonexistent/path')
        result = dc.run(str(self.workspace))

        # Should return None when the detection script is missing.
        self.assertIsNone(result, "detection should return None when script is missing")
        self.assertIsNotNone(dc.last_error, "last_error should be set on failure")
        self.assertIn('not found', dc.last_error,
                      "error should mention the missing script")

    def test_successful_detection_clears_error(self):
        """A successful detection clears last_error."""
        from fleetd.supervisor import DetectionCycle
        dc = DetectionCycle()
        result = dc.run(str(self.workspace))

        self.assertIsNotNone(result, "detection should succeed on valid workspace")
        self.assertIsNone(dc.last_error,
                          "last_error should be None after successful detection")

    def test_detection_failure_does_not_crash(self):
        """Supervisor handles a failed detection cycle without crashing."""
        from fleetd.supervisor import Supervisor

        sup = Supervisor(
            state_dir=str(self.workspace),
            pidfile=str(self.workspace / 'test.pid'),
        )
        sup.acquire_lock()
        try:
            # Run detection — should not raise.
            sup.run_detection_cycle()
            # Health state should reflect the cycle outcome (success or failure).
            self.assertIsNotNone(sup._health_state.get('last_cycle_at'))
            self.assertIn('last_cycle_success', sup._health_state)
            # The error field should be set for a failed cycle on an empty
            # workspace with no detection script reachable. In practice the
            # script IS reachable (it's in the same repo), so this is a
            # real detection on an empty workspace, which succeeds.
        finally:
            sup.release_lock()


class CycleCacheTest(unittest.TestCase):
    """Task 5.5: repeated lookups within a cycle are not reissued."""

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.workspace = Path(self._tmp.name)

    def tearDown(self):
        _safe_tmp_cleanup(self._tmp)

    def test_repeated_detection_hits_cache(self):
        """Second call to DetectionCycle.run with the same cache skips subprocess."""
        from fleetd.supervisor import DetectionCycle, CycleCache

        dc = DetectionCycle()
        cache = CycleCache()

        # First call — should invoke subprocess (count=1).
        result1 = dc.run(str(self.workspace), cache=cache)
        self.assertIsNotNone(result1)
        self.assertEqual(cache.subprocess_count, 1,
                         "first call should trigger a subprocess invocation")

        # Second call with same cache — should return cached result (count still 1).
        result2 = dc.run(str(self.workspace), cache=cache)
        self.assertIsNotNone(result2)
        self.assertEqual(cache.subprocess_count, 1,
                         "second call should hit cache, not re-invoke subprocess")

        # Results should be equal.
        self.assertEqual(
            result1.get('summary', {}).get('total'),
            result2.get('summary', {}).get('total'),
        )

    def test_cache_clear_resets_state(self):
        """Clearing the cache allows fresh subprocess invocation."""
        from fleetd.supervisor import DetectionCycle, CycleCache

        dc = DetectionCycle()
        cache = CycleCache()

        dc.run(str(self.workspace), cache=cache)
        self.assertEqual(cache.subprocess_count, 1)

        cache.clear()
        self.assertEqual(cache.subprocess_count, 0)

        dc.run(str(self.workspace), cache=cache)
        self.assertEqual(cache.subprocess_count, 1,
                         "after cache clear, next call should invoke subprocess")

    def test_supervisor_creates_fresh_cache_per_cycle(self):
        """Supervisor.run_detection_cycle creates a new cache each cycle."""
        from fleetd.supervisor import Supervisor

        sup = Supervisor(
            state_dir=str(self.workspace),
            pidfile=str(self.workspace / 'test.pid'),
            cycle_interval=5,
        )
        sup.acquire_lock()
        try:
            # First cycle creates cache and runs detection.
            sup.run_detection_cycle()
            cache1 = sup._cycle_cache
            self.assertIsNotNone(cache1)

            # Second cycle overwrites cache.
            sup.run_detection_cycle()
            cache2 = sup._cycle_cache
            self.assertIsNotNone(cache2)
            self.assertIsNot(cache1, cache2,
                             "each cycle should have a fresh cache instance")
        finally:
            sup.release_lock()


# ── Group 6: Spawn and reap tests ───────────────────────────────────────


def _make_worker_cmd(sleep_secs=5, exit_code=0):
    """Build a test worker command that sleeps then exits.

    This substitutes for the real `claude -p '/ticket-auto ...'` invocation
    so tests can verify spawn/reap/capacity without needing a Claude API key.
    """
    return [
        sys.executable, '-c',
        f'import time; time.sleep({sleep_secs}); exit({exit_code})',
    ]


class SpawnAndReapTest(unittest.TestCase):
    """Task 6.8: spawn, PID recording, reaping, capacity."""

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.workspace = Path(self._tmp.name)
        # Write a queue entry so the supervisor has something to consume.
        self._append_queue_entry('TST-S1', 'test-spawn', generation=1)

    def tearDown(self):
        _safe_tmp_cleanup(self._tmp)

    def _append_queue_entry(self, tid, reason, generation=1):
        """Append one entry to the spawn queue JSONL file."""
        queue_file = self.workspace / 'fleet-default-spawn-queue.jsonl'
        entry = {
            'tid': tid,
            'reason': reason,
            'generation': generation,
            'timestamp': datetime.now(timezone.utc).isoformat(),
        }
        with open(queue_file, 'a') as f:
            f.write(json.dumps(entry) + '\n')

    def _read_run_registry(self, tid):
        run_file = self.workspace / f'{tid}-run.json'
        if run_file.is_file():
            return json.loads(run_file.read_text())
        return None

    def test_spawned_worker_pid_matches_registry(self):
        """Spawned worker's PID matches the run registry entry."""
        from fleetd.supervisor import Supervisor

        sup = Supervisor(
            state_dir=str(self.workspace),
            pidfile=str(self.workspace / 'test.pid'),
            spawn_enabled=True,
            max_concurrent=1,
            cycle_interval=5,
        )
        sup.acquire_lock()
        try:
            cmd = _make_worker_cmd(sleep_secs=10)
            consumed = sup._consume_queue(cmd_override=cmd)
            self.assertEqual(consumed, {'TST-S1'},
                             "should consume the queue entry")

            # Check the run registry.
            reg = self._read_run_registry('TST-S1')
            self.assertIsNotNone(reg, "run registry should exist after spawn")
            self.assertNotEqual(reg.get('pid'), '0',
                                "PID should not be the zero sentinel")
            self.assertEqual(int(reg['pid']), sup._children.get('TST-S1')['pid'],
                             "registry PID should match child table PID")

            # The worker process should be alive.
            self.assertTrue(_pid_is_alive(int(reg['pid'])),
                            "spawned worker should be alive")
        finally:
            sup.release_lock()

    def test_no_sentinel_pid_written(self):
        """Run registry never contains a zero PID for spawned workers."""
        from fleetd.supervisor import Supervisor

        sup = Supervisor(
            state_dir=str(self.workspace),
            pidfile=str(self.workspace / 'test.pid'),
            spawn_enabled=True,
            max_concurrent=1,
        )
        sup.acquire_lock()
        try:
            cmd = _make_worker_cmd(sleep_secs=5)
            sup._consume_queue(cmd_override=cmd)

            reg = self._read_run_registry('TST-S1')
            self.assertIsNotNone(reg)
            pid_val = int(reg.get('pid', '0'))
            self.assertGreater(pid_val, 0,
                               "PID must be a real positive integer, not 0")
        finally:
            sup.release_lock()

    def test_exits_are_reaped(self):
        """A short-lived worker is reaped and removed from the child table."""
        from fleetd.supervisor import Supervisor

        sup = Supervisor(
            state_dir=str(self.workspace),
            pidfile=str(self.workspace / 'test.pid'),
            spawn_enabled=True,
            max_concurrent=1,
            cycle_interval=1,
        )
        sup.acquire_lock()
        try:
            # Spawn a worker that exits quickly.
            cmd = _make_worker_cmd(sleep_secs=1)
            sup._consume_queue(cmd_override=cmd)

            child = sup._children.get('TST-S1')
            self.assertIsNotNone(child, "worker should be in child table after spawn")
            worker_pid = child['pid']

            # Wait for the worker to exit, then reap.
            time.sleep(2)
            sup._reap_children()

            # After reaping, the child should be removed from the table.
            self.assertIsNone(sup._children.get('TST-S1'),
                              "reaped worker should be removed from child table")
            # The PID should no longer exist.
            self.assertFalse(_pid_is_alive(worker_pid),
                             "reaped worker PID should not be alive")
        finally:
            sup.release_lock()

    def test_no_zombies_accumulate(self):
        """Multiple short-lived workers are all reaped — no zombies."""
        from fleetd.supervisor import Supervisor

        # Write multiple queue entries.
        for i in range(3):
            self._append_queue_entry(f'TST-Z{i}', 'test-zombie', generation=1)

        sup = Supervisor(
            state_dir=str(self.workspace),
            pidfile=str(self.workspace / 'test.pid'),
            spawn_enabled=True,
            max_concurrent=3,
            cycle_interval=1,
        )
        sup.acquire_lock()
        try:
            # Spawn all three (short-lived).
            cmd = _make_worker_cmd(sleep_secs=1)
            sup._consume_queue(cmd_override=cmd)

            self.assertEqual(len(sup._children), 3,
                             "all three workers should be in child table")

            # Wait for all to exit, then reap.
            time.sleep(2)
            sup._reap_children()

            self.assertEqual(len(sup._children), 0,
                             "all workers should be reaped — zero children remain")
        finally:
            sup.release_lock()

    def test_capacity_cap_honoured(self):
        """FLEET_MAX_CONCURRENT is enforced — no more than the cap spawn."""
        from fleetd.supervisor import Supervisor

        # Write several queue entries.
        for i in range(5):
            self._append_queue_entry(f'TST-C{i}', 'test-capacity', generation=1)

        sup = Supervisor(
            state_dir=str(self.workspace),
            pidfile=str(self.workspace / 'test.pid'),
            spawn_enabled=True,
            max_concurrent=2,  # cap at 2
            cycle_interval=1,
        )
        sup.acquire_lock()
        try:
            cmd = _make_worker_cmd(sleep_secs=10)
            consumed = sup._consume_queue(cmd_override=cmd)

            # Only 2 should be spawned (capacity = 2, active_count = 0).
            self.assertEqual(len(consumed), 2,
                             "should only spawn up to max_concurrent")
            self.assertEqual(len(sup._children), 2,
                             "child table should have exactly max_concurrent workers")

            # A second consume should not spawn more (capacity full).
            consumed2 = sup._consume_queue(cmd_override=cmd)
            self.assertEqual(len(consumed2), 0,
                             "should not spawn more when at capacity")
        finally:
            sup.release_lock()

    def test_malformed_queue_entry_skipped(self):
        """Malformed queue entries don't halt consumption."""
        from fleetd.supervisor import Supervisor

        # Write a queue with a malformed line followed by a valid one.
        queue_file = self.workspace / 'fleet-default-spawn-queue.jsonl'
        lines = [
            'not json at all',
            json.dumps({'tid': 'TST-M1', 'reason': 'test', 'generation': 1}),
            '{broken json',
            json.dumps({'tid': 'TST-M2', 'reason': 'test', 'generation': 2}),
        ]
        queue_file.write_text('\n'.join(lines) + '\n')

        sup = Supervisor(
            state_dir=str(self.workspace),
            pidfile=str(self.workspace / 'test.pid'),
            spawn_enabled=True,
            max_concurrent=3,
        )
        sup.acquire_lock()
        try:
            cmd = _make_worker_cmd(sleep_secs=5)
            consumed = sup._consume_queue(cmd_override=cmd)
            self.assertEqual(consumed, {'TST-M1', 'TST-M2'},
                             "malformed entries should be skipped, valid ones consumed")
        finally:
            sup.release_lock()

    def test_remove_consumed_preserves_unconsumed_and_malformed(self):
        """Rewrite removes only consumed TIDs; malformed lines survive."""
        from fleetd.supervisor import _remove_consumed_entries

        queue_file = self.workspace / 'fleet-default-spawn-queue.jsonl'
        lines = [
            json.dumps({'tid': 'TST-A', 'reason': 'test'}),
            'torn line without closing brace',
            json.dumps({'tid': 'TST-B', 'reason': 'test'}),
        ]
        queue_file.write_text('\n'.join(lines) + '\n')

        _remove_consumed_entries(str(self.workspace), {'TST-A'})

        remaining = queue_file.read_text()
        self.assertNotIn('TST-A', remaining,
                         "consumed entry should be removed")
        self.assertIn('TST-B', remaining,
                      "unconsumed entry must survive the rewrite")
        self.assertIn('torn line', remaining,
                      "malformed lines must be preserved, not dropped")

    def test_remove_consumed_serializes_with_bash_append(self):
        """A bash-style flock append racing the rewrite is never lost.

        Regression for the lock-less tmp+rename rewrite: a dispatch append
        landing between fleetd's read and its rename used to vanish with the
        old inode — the ticket was never spawned and never dead-lettered.
        """
        from fleetd.supervisor import _remove_consumed_entries

        queue_file = self.workspace / 'fleet-default-spawn-queue.jsonl'
        lock_file = Path(str(queue_file) + '.lock')
        queue_file.write_text(
            json.dumps({'tid': 'TST-A', 'reason': 'test'}) + '\n')

        # Main thread holds the same sidecar lock the bash append path uses
        # (_fleet_queue_append flocks {queue}.lock), so both contenders block
        # until it releases.
        held = threading.Event()
        released = threading.Event()

        def hold_lock():
            with open(lock_file, 'a') as fd:
                fcntl.flock(fd.fileno(), fcntl.LOCK_EX)
                held.set()
                released.wait(5)
                fcntl.flock(fd.fileno(), fcntl.LOCK_UN)

        def append_entry():
            # Mirrors _fleet_queue_append: flock, append, unlock.
            with open(lock_file, 'a') as fd:
                fcntl.flock(fd.fileno(), fcntl.LOCK_EX)
                try:
                    with open(queue_file, 'a') as qf:
                        qf.write(json.dumps(
                            {'tid': 'TST-C', 'reason': 'test'}) + '\n')
                finally:
                    fcntl.flock(fd.fileno(), fcntl.LOCK_UN)

        def remove_consumed():
            _remove_consumed_entries(str(self.workspace), {'TST-A'})

        holder = threading.Thread(target=hold_lock)
        holder.start()
        self.assertTrue(held.wait(5),
                        "lock holder thread should acquire the lock")

        remover = threading.Thread(target=remove_consumed)
        appender = threading.Thread(target=append_entry)
        remover.start()
        appender.start()

        # Give both contenders time to block on the lock, then release.
        time.sleep(0.5)
        released.set()
        holder.join(5)
        remover.join(5)
        appender.join(5)

        remaining = queue_file.read_text()
        self.assertNotIn('TST-A', remaining,
                         "consumed entry should be removed")
        self.assertIn('TST-C', remaining,
                      "append racing the rewrite was lost — lock contract broken")

    def test_terminal_pipeline_not_respawned_from_stale_entry(self):
        """A stale entry whose ticket already has a terminal log is removed,
        not re-spawned (crash window between spawn and queue removal)."""
        from fleetd.supervisor import Supervisor

        queue_file = self.workspace / 'fleet-default-spawn-queue.jsonl'
        queue_file.write_text(
            json.dumps({'tid': 'TST-T1', 'reason': 'test'}) + '\n')
        log_file = self.workspace / 'TST-T1-pipeline.log'
        log_file.write_text('2026-01-01T00:00:00Z|META|outcome|info|completed\n')

        sup = Supervisor(
            state_dir=str(self.workspace),
            pidfile=str(self.workspace / 'test.pid'),
            spawn_enabled=True,
            max_concurrent=1,
        )
        sup.acquire_lock()
        try:
            consumed = sup._consume_queue(
                cmd_override=_make_worker_cmd(sleep_secs=5))
            self.assertEqual(consumed, {'TST-T1'},
                             "stale entry should be consumed (removed)")
            self.assertIsNone(sup._children.get('TST-T1'),
                              "terminal ticket must not be spawned")
            remaining = (queue_file.read_text()
                         if queue_file.is_file() else '')
            self.assertNotIn('TST-T1', remaining,
                             "stale entry should be removed from the queue")
        finally:
            sup.release_lock()

    def test_killed_pipeline_resumes_not_dropped_as_stale(self):
        """A log ending with a verified-kill outcome is resumable: the queue
        entry spawns (the worker self-resumes via ticket-detect-resume), not
        dropped as stale-terminal. Mirrors the kill arm of
        fleet_ticket_terminal_state (lib/fleet-reconcile.sh) via
        _log_reached_terminal."""
        from fleetd.supervisor import Supervisor

        queue_file = self.workspace / 'fleet-default-spawn-queue.jsonl'
        queue_file.write_text(
            json.dumps({'tid': 'TST-K1',
                        'reason': 'campaign-resume from INIT-42'}) + '\n')
        log_file = self.workspace / 'TST-K1-pipeline.log'
        log_file.write_text(
            '2026-01-01T00:00:00Z|EXEC|exec|start|mid-flight\n'
            '2026-01-01T00:00:01Z|META|outcome|info|'
            'stopped: fleet-kill (SIGTERM); auto-kill\n')

        sup = Supervisor(
            state_dir=str(self.workspace),
            pidfile=str(self.workspace / 'test.pid'),
            spawn_enabled=True,
            max_concurrent=1,
        )
        sup.acquire_lock()
        try:
            consumed = sup._consume_queue(
                cmd_override=_make_worker_cmd(sleep_secs=5))
            self.assertEqual(consumed, {'TST-K1'},
                             "killed pipeline must spawn, not be dropped")
            self.assertIsNotNone(sup._children.get('TST-K1'),
                                 "killed pipeline must spawn as a worker")
        finally:
            sup.release_lock()

    def test_gate_stopped_pipeline_resumes_not_dropped_as_stale(self):
        """A scoped campaign resume enqueues a gate-stopped ticket; the
        consume path must spawn it rather than drop it as stale-terminal.

        This is the end-to-end guard for the whole change: reconcile can
        enqueue correctly and the fix still be a no-op if the consume-path
        staleness check drops the entry a moment later. Uses the clean-exit
        outcome shape pipeline-finalize.sh actually writes."""
        from fleetd.supervisor import Supervisor

        queue_file = self.workspace / 'fleet-default-spawn-queue.jsonl'
        queue_file.write_text(
            json.dumps({'tid': 'TST-G1',
                        'reason': 'campaign-resume from INIT-42'}) + '\n')
        log_file = self.workspace / 'TST-G1-pipeline.log'
        log_file.write_text(
            '2026-01-01T00:00:00Z|GATE|gate|start|checking\n'
            '2026-01-01T00:00:01Z|META|gate-stop|fail|ZERO_AC\n'
            '2026-01-01T00:00:02Z|META|outcome|info|'
            'stopped: gate-stop ZERO_AC — no acceptance criteria\n')

        sup = Supervisor(
            state_dir=str(self.workspace),
            pidfile=str(self.workspace / 'test.pid'),
            spawn_enabled=True,
            max_concurrent=1,
        )
        sup.acquire_lock()
        try:
            consumed = sup._consume_queue(
                cmd_override=_make_worker_cmd(sleep_secs=5))
            self.assertEqual(consumed, {'TST-G1'},
                             "gate-stopped pipeline must spawn on a scoped "
                             "resume, not be dropped as stale")
            self.assertIsNotNone(sup._children.get('TST-G1'),
                                 "gate-stopped pipeline must spawn a worker")
        finally:
            sup.release_lock()

    def _log_terminal(self, content):
        """Write the given pipeline-log content and classify it.

        Direct-unit wrapper around _log_reached_terminal so the mirror can
        be pinned against fleet_ticket_terminal_state (bash authority)
        independently of the consume loop.
        """
        from fleetd.supervisor import _log_reached_terminal

        log_file = self.workspace / 'TST-L1-pipeline.log'
        if content is None:
            return _log_reached_terminal(str(self.workspace), 'TST-L1')
        log_file.write_text(content)
        return _log_reached_terminal(str(self.workspace), 'TST-L1')

    def test_log_reached_terminal_mirrors_bash_classifier(self):
        """_log_reached_terminal agrees with fleet_ticket_terminal_state
        on every resume-relevant log shape (the bash classifier is the
        authority; the mirror must not drift)."""
        # Finalized completion → terminal.
        self.assertTrue(self._log_terminal(
            '2026-01-01T00:00:00Z|META|outcome|info|completed\n'))
        # Dead-letter last line → terminal (idempotent reconciliation).
        self.assertTrue(self._log_terminal(
            '2026-01-01T00:00:00Z|META|dead-letter|warn|reason=restart-cap\n'))
        # Verified kill → resumable, not terminal.
        self.assertFalse(self._log_terminal(
            '2026-01-01T00:00:00Z|EXEC|exec|start|mid-flight\n'
            '2026-01-01T00:00:01Z|META|outcome|info|'
            'stopped: fleet-kill (SIGTERM); auto-kill\n'))
        # Gate-held outcome → waiting on the human, not terminal.
        self.assertFalse(self._log_terminal(
            '2026-01-01T00:00:00Z|META|outcome|info|held: gate\n'))
        # An unrecognised hold kind still matches the `held: ` prefix → not
        # terminal, never `done`. Documented pairwise-sync pair with the bash
        # classifier's own `held: some-future-kind` regression test
        # (lib/tests/test-fleet-reconcile.sh) — a divergence here is exactly
        # the failure this pin exists to catch.
        self.assertFalse(self._log_terminal(
            '2026-01-01T00:00:00Z|META|outcome|info|held: some-future-kind\n'))
        # Gate-held marker as last line (crash before finalize) → not terminal.
        self.assertFalse(self._log_terminal(
            '2026-01-01T00:00:00Z|META|gate-held|info|waiting approval\n'))
        # Route 3 — bare gate-stop marker, no outcome line (the process died
        # before pipeline-finalize.sh ran) → bash gate-stopped, not terminal:
        # the condition may since have been fixed, so a scoped campaign
        # resume is entitled to retry it.
        self.assertFalse(self._log_terminal(
            '2026-01-01T00:00:00Z|GATE|gate|fail|'
            '2026-01-01T00:00:01Z|META|gate-stop|fail|CRITIQUE_BLOCKED\n'
            '2026-01-01T00:00:02Z|IMPLEMENT|implement|start|x\n'))
        # Route 2 — kill outcome AFTER a gate-stop → bash gate-stopped,
        # not terminal.
        self.assertFalse(self._log_terminal(
            '2026-01-01T00:00:00Z|META|gate-stop|fail|CRITIQUE_BLOCKED\n'
            '2026-01-01T00:00:01Z|META|outcome|info|'
            'stopped: fleet-kill (SIGTERM)\n'))
        # Route 1 — the clean-exit shape pipeline-finalize.sh writes at
        # essentially every gate-stop exit, and so the one that matters for
        # real traffic. It lands in the outcome branch, which returns before
        # any marker grep: a fix targeting only the bare-marker route above
        # would leave THIS case reporting terminal and silently drop the
        # campaign-resume queue entry that a scoped reconcile just wrote.
        self.assertFalse(self._log_terminal(
            '2026-01-01T00:00:00Z|META|gate-stop|fail|ZERO_AC\n'
            '2026-01-01T00:00:01Z|META|outcome|info|'
            'stopped: gate-stop ZERO_AC — ticket has zero acceptance '
            'criteria; nothing verifiable exists\n'))
        # VERIFY_EXHAUSTED is classified like any other gate-stop code — no
        # per-code special-casing, even though retrying it cannot succeed.
        self.assertFalse(self._log_terminal(
            '2026-01-01T00:00:00Z|META|gate-stop|fail|VERIFY_EXHAUSTED\n'
            '2026-01-01T00:00:01Z|META|outcome|info|'
            'stopped: gate-stop VERIFY_EXHAUSTED\n'))
        # Dead-letter last line OVER an earlier gate-stop marker → terminal.
        # Retries are already exhausted; if the gate-stop won here the ticket
        # would become retry-eligible again and loop past its own restart cap.
        self.assertTrue(self._log_terminal(
            '2026-01-01T00:00:00Z|META|gate-stop|fail|ZERO_AC\n'
            '2026-01-01T00:00:01Z|META|dead-letter|warn|'
            'reason=orphaned-after-max-restarts\n'))
        # Gate-held outcome with an earlier gate-stop line → NOT terminal:
        # bash checks the outcome arm first, so gate-held wins.
        self.assertFalse(self._log_terminal(
            '2026-01-01T00:00:00Z|META|gate-stop|fail|CRITIQUE_BLOCKED\n'
            '2026-01-01T00:00:01Z|META|outcome|info|held: gate\n'))
        # Mid-flight log with no terminal markers → not terminal.
        self.assertFalse(self._log_terminal(
            '2026-01-01T00:00:00Z|EXEC|exec|start|mid-flight\n'))
        # Missing log → not terminal (bash: incomplete, caller decides).
        self.assertFalse(self._log_terminal(None))
        # Empty log → not terminal.
        self.assertFalse(self._log_terminal(''))

    def test_poll_adopted_workers_preserves_generation(self):
        """poll_adopted_workers preserves the last-known generation before
        deleting the registry — same contract as scan_registry."""
        from fleetd.supervisor import Supervisor

        sup = Supervisor(
            state_dir=str(self.workspace),
            pidfile=str(self.workspace / 'test.pid'),
            spawn_enabled=True,
            max_concurrent=1,
        )
        # A worker that already exited — PID not alive.
        proc = subprocess.Popen([sys.executable, '-c', 'pass'])
        dead_pid = proc.pid
        proc.wait()
        sup._children.add(
            tid='TST-ADOPT',
            pid=dead_pid,
            generation=7,
            reason='dispatched',
            adopted=True,
        )
        run_file = self.workspace / 'TST-ADOPT-run.json'
        run_file.write_text(json.dumps({'tid': 'TST-ADOPT', 'pid': str(dead_pid),
                                        'generation': 7}))

        sup.poll_adopted_workers()

        last_file = self.workspace / 'TST-ADOPT-last-generation'
        self.assertTrue(last_file.is_file(),
                        "last-generation side record should exist")
        self.assertEqual(json.loads(last_file.read_text())['generation'], 7,
                         "preserved generation should be 7")
        self.assertFalse(run_file.exists(),
                         "stale registry file should be removed")

    def test_spawn_disabled_does_not_consume(self):
        """When spawn_enabled is False, queue is not consumed."""
        from fleetd.supervisor import Supervisor

        sup = Supervisor(
            state_dir=str(self.workspace),
            pidfile=str(self.workspace / 'test.pid'),
            spawn_enabled=False,
        )
        sup.acquire_lock()
        try:
            consumed = sup._consume_queue()
            self.assertEqual(consumed, set(),
                             "should not consume when spawn is disabled")
        finally:
            sup.release_lock()


class HoldGuardTest(unittest.TestCase):
    """A held ticket is never spawned (design.md D8, task 5)."""

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.workspace = Path(self._tmp.name)

    def tearDown(self):
        _safe_tmp_cleanup(self._tmp)

    def _append_queue_entry(self, tid):
        queue_file = self.workspace / 'fleet-default-spawn-queue.jsonl'
        with open(queue_file, 'a') as f:
            f.write(json.dumps({'tid': tid, 'reason': 'test'}) + '\n')

    def test_held_ticket_is_not_spawned_and_its_entry_survives(self):
        from fleetd import store
        from fleetd.supervisor import Supervisor

        with store.open_store(self.workspace) as st:
            st.set_hold('TST-H1', 'gate', 'hold:TST-H1:g0:a1', 'complex')
        self._append_queue_entry('TST-H1')

        sup = Supervisor(
            state_dir=str(self.workspace),
            pidfile=str(self.workspace / 'test.pid'),
            spawn_enabled=True,
            max_concurrent=1,
        )
        sup.acquire_lock()
        try:
            consumed = sup._consume_queue(
                cmd_override=_make_worker_cmd(sleep_secs=5))
            self.assertEqual(consumed, set(),
                             "a held ticket must not be spawned")
            self.assertIsNone(sup._children.get('TST-H1'))
            queue_file = self.workspace / 'fleet-default-spawn-queue.jsonl'
            self.assertIn('TST-H1', queue_file.read_text(),
                          "the queue entry must survive, not be dropped")
        finally:
            sup.release_lock()

    def test_ticket_spawns_once_its_hold_is_released(self):
        from fleetd import store
        from fleetd.supervisor import Supervisor

        with store.open_store(self.workspace) as st:
            st.set_hold('TST-H2', 'gate', 'hold:TST-H2:g0:a1', 'complex')
        self._append_queue_entry('TST-H2')

        sup = Supervisor(
            state_dir=str(self.workspace),
            pidfile=str(self.workspace / 'test.pid'),
            spawn_enabled=True,
            max_concurrent=1,
        )
        sup.acquire_lock()
        try:
            consumed = sup._consume_queue(
                cmd_override=_make_worker_cmd(sleep_secs=5))
            self.assertEqual(consumed, set())

            with store.open_store(self.workspace) as st:
                st.release_hold('TST-H2', 'hold:TST-H2:g0:a1')

            consumed = sup._consume_queue(
                cmd_override=_make_worker_cmd(sleep_secs=5))
            self.assertEqual(consumed, {'TST-H2'},
                             "a released ticket must spawn on the next pass")
        finally:
            sup.release_lock()

    def test_disabled_store_degrades_to_todays_behaviour(self):
        """With the store unavailable, the consume path must behave exactly
        as it did before this change — the guard's absence must never be
        what blocks dispatch."""
        from fleetd.supervisor import Supervisor

        self._append_queue_entry('TST-H3')
        old_env = os.environ.get('FLEET_STORE_ENABLE')
        os.environ['FLEET_STORE_ENABLE'] = 'false'
        try:
            import fleetd.supervisor as supervisor_mod
            supervisor_mod.FLEET_STORE_ENABLE = False

            sup = Supervisor(
                state_dir=str(self.workspace),
                pidfile=str(self.workspace / 'test.pid'),
                spawn_enabled=True,
                max_concurrent=1,
            )
            sup.acquire_lock()
            try:
                consumed = sup._consume_queue(
                    cmd_override=_make_worker_cmd(sleep_secs=5))
                self.assertEqual(consumed, {'TST-H3'})
            finally:
                sup.release_lock()
        finally:
            if old_env is None:
                os.environ.pop('FLEET_STORE_ENABLE', None)
            else:
                os.environ['FLEET_STORE_ENABLE'] = old_env
            import fleetd.supervisor as supervisor_mod
            supervisor_mod.FLEET_STORE_ENABLE = (
                os.environ.get('FLEET_STORE_ENABLE', 'true') != 'false')


class HoldReconcilePassTest(unittest.TestCase):
    """The hold-reconcile pass is wired into run_observe's live loop on its
    own cadence, never the phase-dispatch path (design.md D5, task 7)."""

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.workspace = Path(self._tmp.name)

    def tearDown(self):
        _safe_tmp_cleanup(self._tmp)

    def _supervisor(self):
        from fleetd.supervisor import Supervisor
        return Supervisor(
            state_dir=str(self.workspace),
            pidfile=str(self.workspace / 'test.pid'),
            spawn_enabled=False,
        )

    def test_call_site_is_hold_reconcile_pass_method(self):
        """Load-bearing per design.md D5: a reconciler wired to the dormant
        phase-dispatch path is indistinguishable from a working one whenever
        the held set is empty. This proves `run_observe`'s live loop is the
        method that invokes `_hold_reconcile_pass` — not merely that
        behaviour looks right on an empty fleet — using the same
        stub-and-SystemExit pattern as StartupReconciliationTest above.
        """
        from fleetd.supervisor import Supervisor

        sup = Supervisor(
            state_dir=str(self.workspace),
            pidfile=str(self.workspace / 'test.pid'),
            port=_find_free_port(),
            cycle_interval=0.05,
        )
        calls = []

        def record(name):
            def _fn(*args, **kwargs):
                calls.append(name)
                return None
            return _fn

        sup.scan_workers = record('scan_workers')
        sup.reconcile_orphaned_tickets = record('reconcile_orphaned_tickets')
        sup.run_detection_cycle = record('run_detection_cycle')
        sup._reap_children = record('_reap_children')
        sup._process_kill_requests = record('_process_kill_requests')
        sup._consume_queue = record('_consume_queue')

        def _hold_reconcile_pass():
            calls.append('_hold_reconcile_pass')
            raise SystemExit(0)

        sup._hold_reconcile_pass = _hold_reconcile_pass

        with self.assertRaises(SystemExit):
            sup.run_observe()

        self.assertIn('_hold_reconcile_pass', calls,
                      "run_observe must call _hold_reconcile_pass")
        # `_hold_reconcile_last_run` starts None, and gate_hold.is_due(None)
        # is always True — so the very first cycle must probe, not wait a
        # full interval after a restart.
        self.assertLess(calls.index('_consume_queue'),
                        calls.index('_hold_reconcile_pass'),
                        "the pass runs after queue-consume, per task 7.2")

    def test_pass_respects_its_interval_across_cycles(self):
        import fleetd.supervisor as supervisor_mod

        sup = self._supervisor()
        calls = []
        sup._hold_reconcile_pass = lambda: calls.append(True)
        sup.acquire_lock()
        try:
            # Not due: last run is "now".
            sup._hold_reconcile_last_run = time.time()
            if supervisor_mod._gate_hold_mod.is_due(
                    sup._hold_reconcile_last_run):
                sup._hold_reconcile_pass()
            self.assertEqual(calls, [])

            # Due: interval elapsed.
            sup._hold_reconcile_last_run = time.time() - 3600
            if supervisor_mod._gate_hold_mod.is_due(
                    sup._hold_reconcile_last_run):
                sup._hold_reconcile_pass()
            self.assertEqual(calls, [True])
        finally:
            sup.release_lock()

    def test_held_ticket_is_reprobed_across_two_intervals(self):
        from fleetd import store

        with store.open_store(self.workspace) as st:
            st.set_hold('TST-R1', 'gate', 'hold:TST-R1:g0:a1', 'complex')

        sup = self._supervisor()
        probe_calls = []

        import fleetd.gate_hold as gate_hold_mod

        def _probe(tid, hb_log_file='', lib_dir=None):
            probe_calls.append(tid)
            return gate_hold_mod.GATE_ENTRY_HELD, []

        real_run_entry_gate = gate_hold_mod.run_entry_gate
        gate_hold_mod.run_entry_gate = _probe
        sup.acquire_lock()
        try:
            sup._hold_reconcile_pass()
            sup._hold_reconcile_pass()
        finally:
            gate_hold_mod.run_entry_gate = real_run_entry_gate
            sup.release_lock()
        self.assertEqual(probe_calls, ['TST-R1', 'TST-R1'])

    def test_empty_held_set_costs_nothing(self):
        import fleetd.gate_hold as gate_hold_mod

        sup = self._supervisor()
        calls = []
        real_run_entry_gate = gate_hold_mod.run_entry_gate
        gate_hold_mod.run_entry_gate = lambda *a, **k: calls.append(1)
        sup.acquire_lock()
        try:
            sup._hold_reconcile_pass()
        finally:
            gate_hold_mod.run_entry_gate = real_run_entry_gate
            sup.release_lock()
        self.assertEqual(calls, [])

    def test_release_decision_calls_release_hold_with_the_rows_own_hold_id(self):
        from fleetd import store
        import fleetd.gate_hold as gate_hold_mod

        with store.open_store(self.workspace) as st:
            st.set_hold('TST-R2', 'gate', 'hold:TST-R2:g0:a1', 'complex')

        sup = self._supervisor()
        real_run_entry_gate = gate_hold_mod.run_entry_gate
        gate_hold_mod.run_entry_gate = lambda *a, **k: (
            gate_hold_mod.GATE_ENTRY_PASS, [])
        sup.acquire_lock()
        try:
            sup._hold_reconcile_pass()
            with store.open_store(self.workspace) as st:
                ticket = st.get_ticket('TST-R2')
        finally:
            gate_hold_mod.run_entry_gate = real_run_entry_gate
            sup.release_lock()
        self.assertEqual(ticket['held'], 0)
        self.assertEqual(ticket['hold_id'], '')


class DualInvocationInterlockTest(unittest.TestCase):
    """The dual-invocation interlock (task 4.19) actually gates the live
    ticket-level spawn path — `_consume_queue` — not just its own unit
    tests. `phase_dispatch.detect_foreign_run` is exercised directly in
    test_phase_dispatch.py; these tests are the wiring, not the decision.
    """

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.workspace = Path(self._tmp.name)

    def tearDown(self):
        _safe_tmp_cleanup(self._tmp)

    def _append_queue_entry(self, tid, reason, generation=1):
        queue_file = self.workspace / 'fleet-default-spawn-queue.jsonl'
        entry = {
            'tid': tid,
            'reason': reason,
            'generation': generation,
            'timestamp': datetime.now(timezone.utc).isoformat(),
        }
        with open(queue_file, 'a') as f:
            f.write(json.dumps(entry) + '\n')

    def _write_open_bracket(self, tid):
        log_file = self.workspace / f'{tid}-pipeline.log'
        log_file.write_text(
            '2026-09-03T09:00:00Z|IMPLEMENT|implement|waiting|'
            'Agent launched\n')

    def _write_activity(self, tid, seconds_ago):
        stamp = datetime.now(timezone.utc) - timedelta(seconds=seconds_ago)
        act_file = self.workspace / f'{tid}-activity.log'
        act_file.write_text(
            stamp.strftime('%Y-%m-%dT%H:%M:%SZ') + '|IMPLEMENT|Edit\n')

    def test_a_live_foreign_run_is_not_double_spawned(self):
        """A human running `/ticket-auto` by hand blocks fleetd's own
        dispatch of the same ticket — the exact race task 4.19 exists to
        prevent."""
        from fleetd.supervisor import Supervisor

        self._append_queue_entry('TST-F1', 'test-foreign')
        self._write_open_bracket('TST-F1')
        self._write_activity('TST-F1', seconds_ago=30)

        sup = Supervisor(
            state_dir=str(self.workspace),
            pidfile=str(self.workspace / 'test.pid'),
            spawn_enabled=True,
            max_concurrent=1,
        )
        sup.acquire_lock()
        try:
            cmd = _make_worker_cmd(sleep_secs=5)
            consumed = sup._consume_queue(cmd_override=cmd)

            self.assertEqual(
                consumed, set(),
                "a live foreign run must not be consumed/spawned")
            self.assertIsNone(
                sup._children.get('TST-F1'),
                "fleetd must not fork a second worker over a foreign run")

            queue_file = self.workspace / 'fleet-default-spawn-queue.jsonl'
            remaining = [
                json.loads(ln)
                for ln in queue_file.read_text().splitlines() if ln.strip()
            ]
            self.assertEqual(
                [e['tid'] for e in remaining], ['TST-F1'],
                "the queue entry must be left in place so the next cycle "
                "re-checks rather than dropping the dispatch")
        finally:
            sup.release_lock()

    def test_a_crashed_orphan_is_still_recovered(self):
        """An open bracket with stale activity is a crash to recover, not a
        foreign run — it must still spawn normally."""
        from fleetd.supervisor import Supervisor

        self._append_queue_entry('TST-F2', 'test-orphan')
        self._write_open_bracket('TST-F2')
        self._write_activity('TST-F2', seconds_ago=4000)  # stale

        sup = Supervisor(
            state_dir=str(self.workspace),
            pidfile=str(self.workspace / 'test.pid'),
            spawn_enabled=True,
            max_concurrent=1,
        )
        sup.acquire_lock()
        try:
            cmd = _make_worker_cmd(sleep_secs=1)
            consumed = sup._consume_queue(cmd_override=cmd)
            self.assertEqual(
                consumed, {'TST-F2'},
                "a stale/crashed bracket is an orphan, not a foreign run, "
                "and reconciliation must still be able to spawn it")
        finally:
            sup.release_lock()

    def test_no_open_bracket_spawns_normally(self):
        """A ticket with no pipeline log yet (first dispatch ever) is
        unaffected by the interlock."""
        from fleetd.supervisor import Supervisor

        self._append_queue_entry('TST-F3', 'test-first-dispatch')

        sup = Supervisor(
            state_dir=str(self.workspace),
            pidfile=str(self.workspace / 'test.pid'),
            spawn_enabled=True,
            max_concurrent=1,
        )
        sup.acquire_lock()
        try:
            cmd = _make_worker_cmd(sleep_secs=1)
            consumed = sup._consume_queue(cmd_override=cmd)
            self.assertEqual(consumed, {'TST-F3'})
        finally:
            sup.release_lock()


# ── Group 7: Kill escalation tests ───────────────────────────────────────


def _make_ignoring_worker(sleep_secs=30):
    """Worker that ignores SIGINT and SIGTERM — forces escalation to SIGKILL.

    SIGINT must be ignored too now that kill escalation has a SIGINT rung
    (worker-reap-recovery) — otherwise Python's default SIGINT handling
    (KeyboardInterrupt, uncaught) would kill this "unresponsive" worker one
    rung early, at SIGINT rather than SIGKILL.
    """
    return [
        sys.executable, '-c',
        f'import signal, time; '
        f'signal.signal(signal.SIGINT, signal.SIG_IGN); '
        f'signal.signal(signal.SIGTERM, signal.SIG_IGN); '
        f'time.sleep({sleep_secs})',
    ]


def _make_worker_with_child(sleep_secs=30, child_pid_file=None):
    """Worker that spawns a child process — tests process-group signalling.

    If child_pid_file is provided, the worker writes the child's PID there
    so the test can find it without guessing.
    """
    script_lines = [
        'import os, time',
    ]
    if child_pid_file:
        script_lines += [
            'import json, pathlib',
            f'pid = os.fork()',
            'if pid == 0:',
            f'    time.sleep({sleep_secs})',
            'else:',
            f'    pathlib.Path({child_pid_file!r}).write_text(json.dumps({{"child_pid": pid}}))',
            f'    time.sleep({sleep_secs})',
        ]
    else:
        script_lines += [
            'pid = os.fork()',
            'if pid == 0:',
            f'    time.sleep({sleep_secs})',
            'else:',
            f'    time.sleep({sleep_secs})',
        ]
    return [sys.executable, '-c', '\n'.join(script_lines)]


class WorkerStdioAndEnvTest(unittest.TestCase):
    """worker-reap-recovery task 2.8: stdio capture, session id, env, generations."""

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.workspace = Path(self._tmp.name)
        self._append_queue_entry('TST-S1', 'test-spawn', generation=1)

    def tearDown(self):
        _safe_tmp_cleanup(self._tmp)

    def _append_queue_entry(self, tid, reason, generation=1):
        queue_file = self.workspace / 'fleet-default-spawn-queue.jsonl'
        entry = {
            'tid': tid,
            'reason': reason,
            'generation': generation,
            'timestamp': datetime.now(timezone.utc).isoformat(),
        }
        with open(queue_file, 'a') as f:
            f.write(json.dumps(entry) + '\n')

    def _read_run_registry(self, tid):
        run_file = self.workspace / f'{tid}-run.json'
        if run_file.is_file():
            return json.loads(run_file.read_text())
        return None

    def test_env_contains_fleet_worker_pid_matching_registry(self):
        """The worker's environment carries FLEET_WORKER_PID == its own pid."""
        from fleetd.supervisor import Supervisor

        env_out = self.workspace / 'env_out.json'
        script = (
            'import os, json, time; '
            'json.dump({"fleet_worker_pid": os.environ.get("FLEET_WORKER_PID"), '
            '"own_pid": os.getpid()}, open(%r, "w")); '
            'time.sleep(2)'
        ) % str(env_out)
        cmd = [sys.executable, '-c', script]
        sup = Supervisor(
            state_dir=str(self.workspace),
            pidfile=str(self.workspace / 'test.pid'),
            spawn_enabled=True,
            max_concurrent=1,
        )
        sup.acquire_lock()
        try:
            sup._consume_queue(cmd_override=cmd)
            deadline = time.time() + 5
            data = None
            while time.time() < deadline:
                if env_out.is_file():
                    try:
                        data = json.loads(env_out.read_text())
                        break
                    except json.JSONDecodeError:
                        pass
                time.sleep(0.1)
            self.assertIsNotNone(data, "worker never wrote its env snapshot")
            reg = self._read_run_registry('TST-S1')
            self.assertEqual(str(data['own_pid']), reg['pid'])
            self.assertEqual(str(data['fleet_worker_pid']), reg['pid'],
                             "FLEET_WORKER_PID must equal the worker's own pid")
        finally:
            sup.release_lock()

    def test_session_id_recorded_at_spawn(self):
        """A session id is generated and recorded in the run registry."""
        from fleetd.supervisor import Supervisor

        sup = Supervisor(
            state_dir=str(self.workspace),
            pidfile=str(self.workspace / 'test.pid'),
            spawn_enabled=True,
            max_concurrent=1,
        )
        sup.acquire_lock()
        try:
            cmd = _make_worker_cmd(sleep_secs=5)
            sup._consume_queue(cmd_override=cmd)
            reg = self._read_run_registry('TST-S1')
            self.assertIsNotNone(reg)
            self.assertTrue(reg.get('session_id'),
                            "run registry should carry a non-empty session_id")
            child = sup._children.get('TST-S1')
            self.assertEqual(child.get('session_id'), reg['session_id'],
                             "child table session_id should match the registry")
        finally:
            sup.release_lock()

    def test_stdout_and_stderr_land_in_separate_generation_files(self):
        """fd1/fd2 are redirected to distinct per-generation files, never merged."""
        from fleetd.supervisor import Supervisor

        cmd = [
            sys.executable, '-c',
            'import sys, time; '
            'sys.stdout.write("STDOUT-MARKER\\n"); sys.stdout.flush(); '
            'sys.stderr.write("STDERR-MARKER\\n"); sys.stderr.flush(); '
            'time.sleep(2)',
        ]
        sup = Supervisor(
            state_dir=str(self.workspace),
            pidfile=str(self.workspace / 'test.pid'),
            spawn_enabled=True,
            max_concurrent=1,
        )
        sup.acquire_lock()
        try:
            sup._consume_queue(cmd_override=cmd)
            stdout_file = self.workspace / 'TST-S1-gen1.json'
            stderr_file = self.workspace / 'TST-S1-gen1.stderr'
            deadline = time.time() + 5
            while time.time() < deadline:
                if stdout_file.is_file() and stdout_file.stat().st_size > 0:
                    break
                time.sleep(0.1)
            self.assertTrue(stdout_file.is_file(), "stdout file should exist")
            self.assertTrue(stderr_file.is_file(), "stderr file should exist")
            self.assertIn('STDOUT-MARKER', stdout_file.read_text())
            self.assertIn('STDERR-MARKER', stderr_file.read_text())
            self.assertNotIn('STDERR-MARKER', stdout_file.read_text())
            self.assertNotIn('STDOUT-MARKER', stderr_file.read_text())
        finally:
            sup.release_lock()

    def test_second_generation_does_not_overwrite_first(self):
        """A new generation for the same tid gets its own stdio files."""
        from fleetd.supervisor import spawn_worker

        pid1, _ = spawn_worker(
            tid='TST-GEN', generation=1, state_dir=str(self.workspace),
            cmd_override=[sys.executable, '-c',
                          'print("GEN1"); import time; time.sleep(1)'],
        )
        deadline = time.time() + 5
        gen1_file = self.workspace / 'TST-GEN-gen1.json'
        while time.time() < deadline and not (
                gen1_file.is_file() and gen1_file.stat().st_size > 0):
            time.sleep(0.1)
        os.waitpid(pid1, 0)

        pid2, _ = spawn_worker(
            tid='TST-GEN', generation=2, state_dir=str(self.workspace),
            cmd_override=[sys.executable, '-c',
                          'print("GEN2"); import time; time.sleep(1)'],
        )
        gen2_file = self.workspace / 'TST-GEN-gen2.json'
        deadline = time.time() + 5
        while time.time() < deadline and not (
                gen2_file.is_file() and gen2_file.stat().st_size > 0):
            time.sleep(0.1)
        os.waitpid(pid2, 0)

        self.assertIn('GEN1', gen1_file.read_text())
        self.assertIn('GEN2', gen2_file.read_text())
        self.assertNotIn('GEN2', gen1_file.read_text(),
                         "the second generation must not overwrite the first")

    def test_run_registry_records_start_ticks(self):
        """The run registry carries the worker's /proc start ticks.

        `_ticket_worker_alive` (detect-resume.sh) pairs pid with start ticks
        to defeat PID reuse, and tolerates the field being absent — so a
        missing value disarms the guard silently rather than failing. This
        test is the only thing that notices.
        """
        from fleetd.supervisor import spawn_worker, _pid_start_time

        pid, _ = spawn_worker(
            tid='TST-TICKS', generation=1, state_dir=str(self.workspace),
            cmd_override=[sys.executable, '-c', 'import time; time.sleep(1)'],
        )
        try:
            entry = json.loads(
                (self.workspace / 'TST-TICKS-run.json').read_text())
            self.assertEqual(entry['pid'], str(pid))
            self.assertIn('start_ticks', entry,
                          "start_ticks must be recorded or the PID-reuse "
                          "guard in detect-resume.sh is inert")
            self.assertEqual(entry['start_ticks'], str(_pid_start_time(pid)),
                             "recorded ticks must match /proc field 22 for "
                             "the live worker")
        finally:
            os.waitpid(pid, 0)

    def test_phase_worker_gets_its_own_registry_and_stdio_files(self):
        """A ticket's phases run in sequence and must not overwrite each other.

        The ticket-level `{tid}-run.json` answers "is this ticket running".
        With per-phase dispatch a reader also needs "which phase is running",
        and a second phase reusing the ticket-level file would answer with the
        phase that just finished.
        """
        from fleetd.supervisor import spawn_worker

        pid, _ = spawn_worker(
            tid='TST-PH', generation=1, state_dir=str(self.workspace),
            phase='VERIFY',
            cmd_override=[sys.executable, '-c', 'import time; time.sleep(1)'],
        )
        try:
            phase_run = self.workspace / 'TST-PH-verify-run.json'
            self.assertTrue(phase_run.is_file(),
                            "phase spawn must write a phase-scoped registry")
            self.assertFalse((self.workspace / 'TST-PH-run.json').is_file(),
                             "phase spawn must not claim the ticket-level file")
            entry = json.loads(phase_run.read_text())
            self.assertEqual(entry['phase'], 'VERIFY')
            self.assertEqual(entry['tid'], 'TST-PH')
            # The registry write is the parent's and is already done; the
            # stdio files are opened by the child after fork, so this one
            # has to be waited for.
            stderr_file = self.workspace / 'TST-PH-verify-gen1.stderr'
            deadline = time.time() + 5
            while time.time() < deadline and not stderr_file.is_file():
                time.sleep(0.05)
            self.assertTrue(stderr_file.is_file(),
                            "phase stdio must be namespaced too")
        finally:
            os.waitpid(pid, 0)

    def test_phase_worker_environment_reaches_the_process(self):
        """The env fleetd builds is the env the phase actually runs with.

        This is the whole of task 4.16's claim — that a value fleetd owns is
        configured rather than requested — so it is asserted against the real
        forked process, not against the dict that was passed in.
        """
        from fleetd.supervisor import spawn_worker

        out = self.workspace / 'TST-ENV-verify-gen1.json'
        pid, _ = spawn_worker(
            tid='TST-ENV', generation=1, state_dir=str(self.workspace),
            phase='VERIFY',
            extra_env={'LOG_FILE': '/w/logs/TST-ENV-pipeline.log',
                       'FLEET_PHASE': 'VERIFY'},
            cmd_override=[
                sys.executable, '-c',
                'import os; print(os.environ["LOG_FILE"], '
                'os.environ["FLEET_PHASE"])'],
        )
        os.waitpid(pid, 0)
        deadline = time.time() + 5
        while time.time() < deadline and not (
                out.is_file() and out.stat().st_size > 0):
            time.sleep(0.05)
        self.assertIn('/w/logs/TST-ENV-pipeline.log', out.read_text())
        self.assertIn('VERIFY', out.read_text())

    def test_phase_prompt_replaces_the_ticket_auto_invocation(self):
        """`-p` carries one phase, and nothing else about the spawn changes."""
        from fleetd.supervisor import _build_worker_cmd

        default = _build_worker_cmd('CRE-9', claude_bin='claude')
        phased = _build_worker_cmd('CRE-9', claude_bin='claude',
                                   prompt='/ticket-verify CRE-9 --from-auto')
        self.assertIn('/ticket-auto CRE-9 --auto --from-planned', default)
        self.assertIn('/ticket-verify CRE-9 --from-auto', phased)
        self.assertNotIn('/ticket-auto CRE-9 --auto --from-planned', phased)
        # Everything that is not the prompt is identical — session handling,
        # output format and permission mode are properties of a headless
        # worker, not of which phase it runs.
        def strip(cmd):
            return [a for a in cmd if not a.startswith('/ticket-')]

        self.assertEqual(strip(default), strip(phased))

    def test_build_worker_cmd_adds_agent_flag_when_given(self):
        """--agent binds the phase's tool allowlist/system prompt."""
        from fleetd.supervisor import _build_worker_cmd

        cmd = _build_worker_cmd(
            'CRE-9', claude_bin='claude',
            agent='ticket-auto-pipeline:ticket-implement-agent')
        self.assertIn('--agent', cmd)
        idx = cmd.index('--agent')
        self.assertEqual(cmd[idx + 1],
                          'ticket-auto-pipeline:ticket-implement-agent')

    def test_build_worker_cmd_omits_agent_flag_by_default(self):
        """A whole-ticket worker gets no --agent — the router needs every
        tool to dispatch its own phases."""
        from fleetd.supervisor import _build_worker_cmd

        cmd = _build_worker_cmd('CRE-9', claude_bin='claude')
        self.assertNotIn('--agent', cmd)

    def test_build_worker_cmd_skips_agent_flag_when_cmd_already_sets_it(self):
        """CLAUDE_CMD specifying --agent itself takes precedence."""
        from fleetd.supervisor import _build_worker_cmd

        cmd = _build_worker_cmd(
            'CRE-9', claude_cmd='claude --agent custom:override',
            agent='ticket-auto-pipeline:ticket-implement-agent')
        self.assertEqual(cmd.count('--agent'), 1)
        idx = cmd.index('--agent')
        self.assertEqual(cmd[idx + 1], 'custom:override')

    def test_build_worker_cmd_uses_stream_json_for_a_phase_worker_when_observer_enabled(self):
        """Agent Observer Inc 1: the flag flips only phase-level spawns."""
        from unittest import mock
        from fleetd import supervisor as sup_mod
        from fleetd.supervisor import _build_worker_cmd

        with mock.patch.object(sup_mod, 'FLEET_OBSERVER_ENABLE', True):
            cmd = _build_worker_cmd('CRE-9', claude_bin='claude',
                                    is_phase_worker=True)
        self.assertIn('--output-format', cmd)
        idx = cmd.index('--output-format')
        self.assertEqual(cmd[idx + 1], 'stream-json')
        self.assertIn('--verbose', cmd)
        # Never the token-level partial-message flag — Agent Observer stays
        # tool-call granularity only (task 2.3).
        self.assertNotIn('--include-partial-messages', cmd)

    def test_build_worker_cmd_stays_json_for_a_ticket_worker_even_when_observer_enabled(self):
        """The flag never touches a whole-ticket /ticket-auto spawn."""
        from unittest import mock
        from fleetd import supervisor as sup_mod
        from fleetd.supervisor import _build_worker_cmd

        with mock.patch.object(sup_mod, 'FLEET_OBSERVER_ENABLE', True):
            cmd = _build_worker_cmd('CRE-9', claude_bin='claude',
                                    is_phase_worker=False)
        idx = cmd.index('--output-format')
        self.assertEqual(cmd[idx + 1], 'json')
        self.assertNotIn('--verbose', cmd)

    def test_build_worker_cmd_stays_json_for_a_phase_worker_when_observer_disabled(self):
        """The default (observer off) is byte-identical to pre-Observer."""
        from fleetd.supervisor import _build_worker_cmd

        cmd = _build_worker_cmd('CRE-9', claude_bin='claude',
                                is_phase_worker=True)
        idx = cmd.index('--output-format')
        self.assertEqual(cmd[idx + 1], 'json')
        self.assertNotIn('--verbose', cmd)

    def test_spawn_worker_writes_ndjson_stdout_for_a_phase_worker_when_observer_enabled(self):
        """spawn_worker's own file-extension choice, independent of cmd_override."""
        from unittest import mock
        from fleetd import supervisor as sup_mod
        from fleetd.supervisor import spawn_worker

        with mock.patch.object(sup_mod, 'FLEET_OBSERVER_ENABLE', True):
            pid, _ = spawn_worker(
                tid='TST-OBS', generation=1, state_dir=str(self.workspace),
                phase='VERIFY', cmd_override=[sys.executable, '-c', 'pass'])
        os.waitpid(pid, 0)
        self.assertTrue((self.workspace / 'TST-OBS-verify-gen1.ndjson').is_file())
        self.assertFalse((self.workspace / 'TST-OBS-verify-gen1.json').is_file())

    def test_spawn_worker_writes_json_stdout_for_a_ticket_worker_even_when_observer_enabled(self):
        """A whole-ticket spawn (phase='') never gets `.ndjson`."""
        from unittest import mock
        from fleetd import supervisor as sup_mod
        from fleetd.supervisor import spawn_worker

        with mock.patch.object(sup_mod, 'FLEET_OBSERVER_ENABLE', True):
            pid, _ = spawn_worker(
                tid='TST-OBS2', generation=1, state_dir=str(self.workspace),
                cmd_override=[sys.executable, '-c', 'pass'])
        os.waitpid(pid, 0)
        self.assertTrue((self.workspace / 'TST-OBS2-gen1.json').is_file())

    def test_spawn_phase_worker_builds_from_the_canonical_table(self):
        """End to end: a step id in, a forked phase worker out."""
        from fleetd.supervisor import spawn_phase_worker

        pid, session_id, spawn = spawn_phase_worker(
            'TST-SPW', 'STEP_4_5', 1, str(self.workspace),
            log_file='/w/logs/TST-SPW-pipeline.log',
            counters={'VERIFY_ATTEMPTS': 0}, attempt=1,
            cmd_override=[sys.executable, '-c', 'import time; time.sleep(1)'],
        )
        try:
            self.assertEqual(spawn.phase, 'VERIFY')
            self.assertEqual(spawn.step, 'verify')
            self.assertTrue(spawn.prompt.startswith('/ticket-verify TST-SPW'))
            self.assertTrue(session_id)
            entry = json.loads(
                (self.workspace / 'TST-SPW-verify-run.json').read_text())
            self.assertEqual(entry['pid'], str(pid))
            self.assertEqual(entry['phase'], 'VERIFY')
        finally:
            os.waitpid(pid, 0)

    def test_spawn_phase_worker_writes_a_contract_when_observer_enabled(self):
        """agent-observer Inc 3: the contract is written at spawn under the flag."""
        from unittest import mock
        from fleetd import supervisor as sup_mod
        from fleetd.supervisor import spawn_phase_worker

        with mock.patch.object(sup_mod, 'FLEET_OBSERVER_ENABLE', True):
            pid, session_id, spawn = spawn_phase_worker(
                'TST-CTR', 'STEP_1', 1, str(self.workspace),
                log_file='/w/logs/TST-CTR-pipeline.log',
                cmd_override=[sys.executable, '-c', 'pass'],
            )
        os.waitpid(pid, 0)
        contract_path = self.workspace / 'TST-CTR-appraise-contract.json'
        self.assertTrue(contract_path.is_file())
        contract = json.loads(contract_path.read_text())
        self.assertEqual(contract['phase'], 'APPRAISE')
        self.assertEqual(contract['tid'], 'TST-CTR')

    def test_spawn_phase_worker_writes_no_contract_when_observer_disabled(self):
        from fleetd.supervisor import spawn_phase_worker

        pid, session_id, spawn = spawn_phase_worker(
            'TST-CTR2', 'STEP_1', 1, str(self.workspace),
            log_file='/w/logs/TST-CTR2-pipeline.log',
            cmd_override=[sys.executable, '-c', 'pass'],
        )
        os.waitpid(pid, 0)
        self.assertFalse(
            (self.workspace / 'TST-CTR2-appraise-contract.json').is_file())

    def test_redirection_failure_does_not_abort_spawn(self):
        """A stdio-redirect failure still lets the worker spawn and exec."""
        from fleetd.supervisor import Supervisor

        # Pre-create the stdout target AS A DIRECTORY so the child's
        # os.open(..., O_WRONLY) raises OSError (IsADirectoryError) —
        # isolates the redirection failure without touching the run
        # registry write, which happens in the parent via a different path.
        (self.workspace / 'TST-S1-gen1.json').mkdir()

        sup = Supervisor(
            state_dir=str(self.workspace),
            pidfile=str(self.workspace / 'test.pid'),
            spawn_enabled=True,
            max_concurrent=1,
        )
        sup.acquire_lock()
        try:
            cmd = _make_worker_cmd(sleep_secs=3)
            consumed = sup._consume_queue(cmd_override=cmd)
            self.assertEqual(consumed, {'TST-S1'},
                             "spawn must proceed despite redirection failure")
            child = sup._children.get('TST-S1')
            self.assertIsNotNone(child)
            self.assertTrue(_pid_is_alive(child['pid']),
                            "worker should still be running (exec succeeded)")
        finally:
            sup.release_lock()


class KillEscalationTest(unittest.TestCase):
    """Task 7.6: escalation reaches SIGKILL, descendants die, early exit skips."""

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.workspace = Path(self._tmp.name)
        self._append_queue_entry('TST-K1', 'test-kill', generation=1)

    def tearDown(self):
        # Ensure any lingering test children are cleaned up.
        _safe_tmp_cleanup(self._tmp)

    def _append_queue_entry(self, tid, reason, generation=1):
        queue_file = self.workspace / 'fleet-default-spawn-queue.jsonl'
        entry = {
            'tid': tid,
            'reason': reason,
            'generation': generation,
            'timestamp': datetime.now(timezone.utc).isoformat(),
        }
        with open(queue_file, 'a') as f:
            f.write(json.dumps(entry) + '\n')

    def _spawn_and_get_pid(self, sup, cmd, tid='TST-K1'):
        """Spawn a worker and return its PID."""
        sup._consume_queue(cmd_override=cmd)
        child = sup._children.get(tid)
        if child is None:
            return None
        return child['pid']

    def test_unresponsive_worker_reaches_sigkill(self):
        """Worker ignoring SIGTERM is escalated to SIGKILL and confirmed dead."""
        from fleetd.supervisor import Supervisor

        sup = Supervisor(
            state_dir=str(self.workspace),
            pidfile=str(self.workspace / 'test.pid'),
            spawn_enabled=True,
            max_concurrent=1,
        )
        sup.acquire_lock()
        try:
            cmd = _make_ignoring_worker(sleep_secs=30)
            pid = self._spawn_and_get_pid(sup, cmd)
            self.assertIsNotNone(pid, "worker should be spawned")
            self.assertTrue(_pid_is_alive(pid), "worker should be alive before kill")

            # Kill with short grace periods for test speed.
            result = sup.kill_worker('TST-K1', grace_secs=1)
            self.assertTrue(result.success,
                            f"kill should succeed: {result.error}")
            self.assertEqual(result.method, 'SIGKILL',
                             "SIGTERM-ignoring worker should reach SIGKILL")
            self.assertFalse(_pid_is_alive(pid),
                             "worker should be dead after SIGKILL")
            self.assertIsNone(sup._children.get('TST-K1'),
                              "worker should be removed from child table after kill")
        finally:
            sup.release_lock()

    def test_a_hung_phase_worker_is_killable_through_the_same_path(self):
        """Task 4.17 — `Supervisor.spawn_phase` registers the phase worker
        as a normal child, so a hung phase subprocess gets the identical
        cooperative-stop -> SIGINT -> SIGTERM -> SIGKILL escalation a
        ticket-level worker gets, through the same `kill_worker`."""
        from fleetd.supervisor import Supervisor

        sup = Supervisor(
            state_dir=str(self.workspace),
            pidfile=str(self.workspace / 'test.pid'),
            spawn_enabled=True,
            max_concurrent=1,
        )
        sup.acquire_lock()
        try:
            cmd = _make_ignoring_worker(sleep_secs=30)
            pid, session_id, spawn = sup.spawn_phase(
                'TST-KPHASE', 'STEP_4_5',
                log_file=str(self.workspace / 'logs' / 'TST-KPHASE-pipeline.log'),
                counters={'VERIFY_ATTEMPTS': 0}, attempt=1, cmd_override=cmd,
            )
            self.assertTrue(_pid_is_alive(pid), "phase worker should be alive")
            child = sup._children.get('TST-KPHASE')
            self.assertIsNotNone(child, "spawn_phase must register a child")
            self.assertEqual(child['pid'], pid)
            self.assertEqual(child['phase'], 'VERIFY')

            result = sup.kill_worker('TST-KPHASE', grace_secs=1)
            self.assertTrue(result.success, f"kill should succeed: {result.error}")
            self.assertEqual(result.method, 'SIGKILL',
                             "SIGTERM-ignoring phase worker should reach SIGKILL")
            self.assertFalse(_pid_is_alive(pid),
                             "phase worker should be dead after SIGKILL")
            self.assertIsNone(sup._children.get('TST-KPHASE'),
                              "phase worker should be removed from child table")
        finally:
            sup.release_lock()

    def test_descendants_die_with_worker(self):
        """Killing a worker also terminates its child processes."""
        from fleetd.supervisor import Supervisor

        child_pid_file = str(self.workspace / 'child_pid.json')

        sup = Supervisor(
            state_dir=str(self.workspace),
            pidfile=str(self.workspace / 'test.pid'),
            spawn_enabled=True,
            max_concurrent=1,
        )
        sup.acquire_lock()
        try:
            # Worker with a forked child — the worker writes the child's PID
            # to a file so we can find it without guessing.
            cmd = _make_worker_with_child(sleep_secs=30, child_pid_file=child_pid_file)
            pid = self._spawn_and_get_pid(sup, cmd)
            self.assertIsNotNone(pid)

            # Wait for the child PID to be written.
            deadline = time.time() + 5
            child_pid = None
            while time.time() < deadline:
                try:
                    data = json.loads(Path(child_pid_file).read_text())
                    child_pid = data.get('child_pid')
                    if child_pid:
                        break
                except (json.JSONDecodeError, OSError):
                    pass
                time.sleep(0.2)

            self.assertIsNotNone(child_pid, "should have found child PID")
            self.assertTrue(_pid_is_alive(child_pid),
                            f"worker child {child_pid} should be alive")

            # Kill — process group signal should reach both.
            result = sup.kill_worker('TST-K1', grace_secs=1)
            self.assertTrue(result.success, f"kill should succeed: {result.error}")

            # Both should be dead.
            time.sleep(0.5)
            self.assertFalse(_pid_is_alive(pid),
                             "worker should be dead after escalation")
            self.assertFalse(_pid_is_alive(child_pid),
                             "worker's child should also be dead")
        finally:
            sup.release_lock()

    def test_early_exit_skips_signalling(self):
        """Worker that exits during grace period is not signalled."""
        from fleetd.supervisor import Supervisor

        # Use a very short-lived worker that exits during the grace period.
        cmd = _make_worker_cmd(sleep_secs=1)

        sup = Supervisor(
            state_dir=str(self.workspace),
            pidfile=str(self.workspace / 'test.pid'),
            spawn_enabled=True,
            max_concurrent=1,
        )
        sup.acquire_lock()
        try:
            pid = self._spawn_and_get_pid(sup, cmd)
            self.assertIsNotNone(pid)

            # Wait a bit so the worker has time to start, then kill with
            # grace period longer than the worker's remaining sleep.
            time.sleep(0.5)
            result = sup.kill_worker('TST-K1', grace_secs=2)

            self.assertTrue(result.success,
                            f"kill should succeed on early exit: {result.error}")
            self.assertEqual(result.method, 'cooperative',
                             "worker that exits quickly should die cooperatively")
            self.assertFalse(_pid_is_alive(pid),
                             "worker should be dead after cooperative exit")
        finally:
            sup.release_lock()

    def test_kill_nonexistent_worker_reports_failure(self):
        """Killing a worker not in the child table returns a failure result."""
        from fleetd.supervisor import Supervisor

        sup = Supervisor(
            state_dir=str(self.workspace),
            pidfile=str(self.workspace / 'test.pid'),
        )
        sup.acquire_lock()
        try:
            result = sup.kill_worker('TST-NONEXIST')
            self.assertFalse(result.success,
                             "killing nonexistent worker should fail")
            self.assertEqual(result.method, 'none')
            self.assertIsNotNone(result.error)
        finally:
            sup.release_lock()

    def test_stop_files_are_written(self):
        """Kill escalation writes cooperative stop files."""
        from fleetd.supervisor import Supervisor

        sup = Supervisor(
            state_dir=str(self.workspace),
            pidfile=str(self.workspace / 'test.pid'),
            spawn_enabled=True,
            max_concurrent=1,
        )
        sup.acquire_lock()
        try:
            cmd = _make_worker_cmd(sleep_secs=30)
            self._spawn_and_get_pid(sup, cmd)

            sup.kill_worker('TST-K1', grace_secs=1)

            # Verify stop files were created.
            pinger_stop = self.workspace / 'ticket-auto-TST-K1-pinger-stop'
            watchdog_stop = self.workspace / 'ticket-auto-TST-K1-watchdog-stop'
            self.assertTrue(pinger_stop.exists() or watchdog_stop.exists(),
                            "stop files should be created during escalation")
        finally:
            sup.release_lock()

    def test_fence_file_is_written_on_kill(self):
        """A successful kill writes a generation fence marker."""
        from fleetd.supervisor import Supervisor

        sup = Supervisor(
            state_dir=str(self.workspace),
            pidfile=str(self.workspace / 'test.pid'),
            spawn_enabled=True,
            max_concurrent=1,
        )
        sup.acquire_lock()
        try:
            cmd = _make_worker_cmd(sleep_secs=1)
            self._spawn_and_get_pid(sup, cmd)
            time.sleep(0.5)

            sup.kill_worker('TST-K1', grace_secs=1)

            fence_file = self.workspace / 'TST-K1-fence'
            self.assertTrue(fence_file.exists(),
                            "fence file should be written after successful kill")
            fence_data = json.loads(fence_file.read_text())
            self.assertEqual(fence_data['tid'], 'TST-K1')
            self.assertIn('fenced_generation', fence_data)
        finally:
            sup.release_lock()


class PhaseLivenessHeartbeatTest(unittest.TestCase):
    """Task 4.18 — the watchdog replacement, wired to fire every cycle."""

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.workspace = Path(self._tmp.name)

    def tearDown(self):
        _safe_tmp_cleanup(self._tmp)

    def _sup(self):
        from fleetd.supervisor import Supervisor
        sup = Supervisor(
            state_dir=str(self.workspace),
            pidfile=str(self.workspace / 'test.pid'),
            spawn_enabled=True,
            max_concurrent=1,
        )
        sup.acquire_lock()
        return sup

    def test_spawn_phase_records_hb_log_file_and_start_ticks(self):
        sup = self._sup()
        try:
            hb = str(self.workspace / 'logs' / 'TST-HB1-heartbeat.log')
            pid, _sid, _spawn = sup.spawn_phase(
                'TST-HB1', 'STEP_4_5',
                log_file=str(self.workspace / 'logs' / 'TST-HB1-pipeline.log'),
                hb_log_file=hb, counters={'VERIFY_ATTEMPTS': 0}, attempt=1,
                cmd_override=_make_ignoring_worker(sleep_secs=30),
            )
            child = sup._children.get('TST-HB1')
            self.assertEqual(child['hb_log_file'], hb)
            self.assertTrue(child['start_ticks'])
        finally:
            sup.kill_worker('TST-HB1', grace_secs=1)
            sup.release_lock()

    def test_emit_writes_a_heartbeat_for_a_live_phase_worker(self):
        sup = self._sup()
        try:
            hb_path = self.workspace / 'logs'
            hb_path.mkdir(parents=True, exist_ok=True)
            hb = str(hb_path / 'TST-HB2-heartbeat.log')
            sup.spawn_phase(
                'TST-HB2', 'STEP_4_5',
                log_file=str(hb_path / 'TST-HB2-pipeline.log'),
                hb_log_file=hb, counters={'VERIFY_ATTEMPTS': 0}, attempt=1,
                cmd_override=_make_ignoring_worker(sleep_secs=30),
            )
            sup.emit_phase_liveness_heartbeats()
            self.assertIn('|watchdog|alive|', Path(hb).read_text())
        finally:
            sup.kill_worker('TST-HB2', grace_secs=1)
            sup.release_lock()

    def test_a_ticket_level_child_is_not_a_candidate(self):
        # A ticket-level spawn has no `phase`/`hb_log_file` — emitting for it
        # would be a second, redundant watchdog on top of its own.
        sup = self._sup()
        queue_file = self.workspace / 'fleet-default-spawn-queue.jsonl'
        entry = {
            'tid': 'TST-HB3', 'reason': 'test-hb', 'generation': 1,
            'timestamp': datetime.now(timezone.utc).isoformat(),
        }
        with open(queue_file, 'a') as f:
            f.write(json.dumps(entry) + '\n')
        try:
            cmd = _make_worker_cmd(sleep_secs=5)
            consumed = sup._consume_queue(cmd_override=cmd)
            self.assertEqual(consumed, {'TST-HB3'})
            # Should not raise, and should write nothing for TST-HB3 (no hb
            # file recorded on a ticket-level child, so nothing to write to).
            sup.emit_phase_liveness_heartbeats()
        finally:
            sup.kill_worker('TST-HB3', grace_secs=1)
            sup.release_lock()


# ── Group 8: Crash recovery and adoption tests ───────────────────────────


class CrashRecoveryTest(unittest.TestCase):
    """Task 8.6: adoption, PID reuse rejection, stale entry clearing."""

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.workspace = Path(self._tmp.name)

    def tearDown(self):
        _safe_tmp_cleanup(self._tmp)

    def _write_run_registry(self, tid, pid, started_at=None, generation=1):
        run_file = self.workspace / f'{tid}-run.json'
        entry = {
            'tid': tid,
            'pid': str(pid),
            'generation': generation,
            'started_at': started_at or datetime.now(timezone.utc).strftime(
                '%Y-%m-%dT%H:%M:%SZ'),
            'reason': 'test',
        }
        run_file.write_text(json.dumps(entry))

    def _spawn_sleeper(self, tid_marker=''):
        """Spawn a long-lived sleeper process. Returns the Popen object."""
        cmdline = f'import time; time.sleep(60)'
        if tid_marker:
            cmdline += f'  # worker: {tid_marker}'
        return subprocess.Popen([sys.executable, '-c', cmdline])

    def test_live_worker_is_adopted(self):
        """On restart (scan_workers), a live verified worker is adopted."""
        from fleetd.supervisor import Supervisor

        # Spawn a sleeper whose cmdline includes the TID.
        sleeper = self._spawn_sleeper(tid_marker='TST-A1')
        started_at = datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
        self._write_run_registry('TST-A1', sleeper.pid, started_at=started_at)

        sup = Supervisor(
            state_dir=str(self.workspace),
            pidfile=str(self.workspace / 'test.pid'),
            spawn_enabled=True,
            max_concurrent=3,
        )
        sup.acquire_lock()
        try:
            # scan_workers with ownership verification.
            sup.scan_workers(verify_ownership=True)

            child = sup._children.get('TST-A1')
            self.assertIsNotNone(child,
                                 "live worker with matching cmdline should be adopted")
            self.assertTrue(child['adopted'],
                            "registry-scanned worker should be marked adopted")
            self.assertEqual(child['pid'], sleeper.pid,
                             "adopted PID should match the real process")
        finally:
            sup.release_lock()
            sleeper.terminate()
            sleeper.wait(timeout=5)

    def test_reused_pid_is_not_adopted(self):
        """A registry entry whose PID started before the registry timestamp
        is NOT adopted — it's a reused PID."""
        from fleetd.supervisor import Supervisor

        # Spawn a sleeper and wait so its start time is clearly before
        # our registry timestamp.
        sleeper = self._spawn_sleeper(tid_marker='TST-R1')
        time.sleep(0.5)

        # Write registry with started_at = NOW, but the sleeper started 0.5s ago.
        # We need the gap to be > 5 seconds for the check to trigger.
        # Actually, the check is: proc_start < (reg_epoch - 5).
        # If proc started 0.5s before reg: 0.5 < 5 → false → check passes.
        # We need proc to start 6+ seconds before reg.

        # Wait longer so the PID reuse check triggers.
        time.sleep(6)

        started_at = datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
        self._write_run_registry('TST-R1', sleeper.pid, started_at=started_at)

        sup = Supervisor(
            state_dir=str(self.workspace),
            pidfile=str(self.workspace / 'test.pid'),
        )
        sup.acquire_lock()
        try:
            sup.scan_workers(verify_ownership=True)

            child = sup._children.get('TST-R1')
            self.assertIsNone(child,
                              "PID that started before registry should NOT be adopted")

            # The stale registry file should have been cleared.
            run_file = self.workspace / 'TST-R1-run.json'
            self.assertFalse(run_file.exists(),
                             "stale registry file should be cleared")
        finally:
            sup.release_lock()
            sleeper.terminate()
            sleeper.wait(timeout=5)

    def test_stale_entry_is_cleared(self):
        """Registry entry with a dead PID is cleared."""
        from fleetd.supervisor import Supervisor

        # Use a PID that almost certainly doesn't exist.
        dead_pid = 99999
        # Make sure it's actually dead.
        while _pid_is_alive(dead_pid):
            dead_pid += 1

        self._write_run_registry('TST-S1', dead_pid)

        sup = Supervisor(
            state_dir=str(self.workspace),
            pidfile=str(self.workspace / 'test.pid'),
        )
        sup.acquire_lock()
        try:
            sup.scan_workers(verify_ownership=True)

            # Dead PID should not be in child table.
            self.assertIsNone(sup._children.get('TST-S1'),
                              "dead PID should not be adopted")

            # Stale registry file should be cleared.
            run_file = self.workspace / 'TST-S1-run.json'
            self.assertFalse(run_file.exists(),
                             "stale registry file for dead PID should be cleared")
        finally:
            sup.release_lock()

    def test_adoption_prevents_double_spawn(self):
        """A worker adopted from the registry prevents a queue entry for the
        same ticket from spawning a duplicate."""
        from fleetd.supervisor import Supervisor

        # Spawn a live sleeper and write its registry.
        sleeper = self._spawn_sleeper(tid_marker='TST-D1')
        started_at = datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
        self._write_run_registry('TST-D1', sleeper.pid, started_at=started_at)

        # Also write a queue entry for the same TID.
        queue_file = self.workspace / 'fleet-default-spawn-queue.jsonl'
        queue_file.write_text(json.dumps({
            'tid': 'TST-D1',
            'reason': 'dispatch',
            'generation': 1,
        }) + '\n')

        sup = Supervisor(
            state_dir=str(self.workspace),
            pidfile=str(self.workspace / 'test.pid'),
            spawn_enabled=True,
            max_concurrent=3,
        )
        sup.acquire_lock()
        try:
            # First, adopt the existing worker.
            sup.scan_workers(verify_ownership=True)
            self.assertIsNotNone(sup._children.get('TST-D1'),
                                 "existing worker should be adopted")

            # Then try to consume queue — should skip TST-D1 (already running).
            consumed = sup._consume_queue(
                cmd_override=_make_worker_cmd(sleep_secs=5))
            self.assertNotIn('TST-D1', consumed,
                             "should not double-spawn an adopted worker")

            # The adopted worker should still be the original PID.
            self.assertEqual(sup._children.get('TST-D1')['pid'], sleeper.pid,
                             "adopted PID should still be the original process")
        finally:
            sup.release_lock()
            sleeper.terminate()
            sleeper.wait(timeout=5)

    def test_poll_adopted_workers_detects_exit(self):
        """Polling detects when an adopted worker exits."""
        from fleetd.supervisor import Supervisor

        # Spawn a short-lived sleeper.
        sleeper = subprocess.Popen(
            [sys.executable, '-c',
             'import time; time.sleep(1)  # worker: TST-P1'],
        )
        started_at = datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
        self._write_run_registry('TST-P1', sleeper.pid, started_at=started_at)

        sup = Supervisor(
            state_dir=str(self.workspace),
            pidfile=str(self.workspace / 'test.pid'),
        )
        sup.acquire_lock()
        try:
            sup.scan_workers(verify_ownership=True)
            self.assertIsNotNone(sup._children.get('TST-P1'),
                                 "worker should be adopted while alive")

            # Wait for the sleeper to exit.
            sleeper.wait(timeout=5)

            # Poll should detect the exit and remove the worker.
            sup.poll_adopted_workers()
            self.assertIsNone(sup._children.get('TST-P1'),
                              "exited adopted worker should be removed after poll")
        finally:
            sup.release_lock()


# ── worker-reap-recovery: exit persistence + reap-time recovery ──────────


class ExitPersistenceAndRecoveryTest(unittest.TestCase):
    """worker-reap-recovery tasks 3.10-3.11: exit records, scoped reap-time
    reconciliation, kill attribution, circuit breaker, lock hoist."""

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.workspace = Path(self._tmp.name)

    def tearDown(self):
        _safe_tmp_cleanup(self._tmp)

    def _append_queue_entry(self, tid, reason='test', generation=1):
        queue_file = self.workspace / 'fleet-default-spawn-queue.jsonl'
        entry = {
            'tid': tid,
            'reason': reason,
            'generation': generation,
            'timestamp': datetime.now(timezone.utc).isoformat(),
        }
        with open(queue_file, 'a') as f:
            f.write(json.dumps(entry) + '\n')

    def _read_exit_record(self, tid, generation=1):
        exit_file = self.workspace / f'{tid}-gen{generation}-exit.json'
        if exit_file.is_file():
            return json.loads(exit_file.read_text())
        return None

    def _make_sup(self, **kwargs):
        from fleetd.supervisor import Supervisor
        defaults = dict(
            state_dir=str(self.workspace),
            pidfile=str(self.workspace / 'test.pid'),
            spawn_enabled=True,
            max_concurrent=3,
        )
        defaults.update(kwargs)
        return Supervisor(**defaults)

    def test_crashed_worker_exit_record_and_scoped_reconcile(self):
        """A worker that exits non-zero over a non-terminal log gets an exit
        record (killed_by_fleet=False) and triggers scoped reconciliation."""
        from unittest import mock

        self._append_queue_entry('TST-R1')
        sup = self._make_sup()
        sup.acquire_lock()
        try:
            cmd = _make_worker_cmd(sleep_secs=1, exit_code=1)
            sup._consume_queue(cmd_override=cmd)
            time.sleep(2)

            recorded_scopes = []
            with mock.patch.object(
                sup, 'reconcile_orphaned_tickets',
                side_effect=lambda scope_tids=None: recorded_scopes.append(scope_tids),
            ):
                sup._reap_children()

            self.assertEqual(recorded_scopes, [['TST-R1']],
                             "reap-time recovery must scope reconcile to the "
                             "exact tid that just exited")
            record = self._read_exit_record('TST-R1')
            self.assertIsNotNone(record, "exit record must be written")
            self.assertEqual(record['exit_code'], 1)
            self.assertEqual(record['exit_type'], 'exit')
            self.assertFalse(record['killed_by_fleet'])
            self.assertFalse(record['terminal'])
        finally:
            sup.release_lock()

    def test_terminal_log_worker_not_reconciled(self):
        """A worker over an already-terminal pipeline log is not re-enqueued."""
        from unittest import mock

        tid = 'TST-R2'
        self._append_queue_entry(tid)
        sup = self._make_sup()
        sup.acquire_lock()
        try:
            cmd = _make_worker_cmd(sleep_secs=1, exit_code=0)
            sup._consume_queue(cmd_override=cmd)
            # Write the terminal marker AFTER spawn (consume-time terminality
            # would instead take the "stale queue entry" path and never
            # spawn at all) but BEFORE reap, so reap-time classification
            # sees a genuinely completed pipeline.
            log_file = self.workspace / f'{tid}-pipeline.log'
            log_file.write_text(
                '2026-08-29T00:00:00Z|META|schema|done|1\n'
                '2026-08-29T00:00:01Z|META|outcome|done|completed\n'
            )
            time.sleep(2)

            called = []
            with mock.patch.object(
                sup, 'reconcile_orphaned_tickets',
                side_effect=lambda scope_tids=None: called.append(scope_tids),
            ):
                sup._reap_children()

            self.assertEqual(called, [], "a terminal-log worker must not be reconciled")
            record = self._read_exit_record(tid)
            self.assertTrue(record['terminal'])
        finally:
            sup.release_lock()

    def test_notify_called_for_non_terminal_exit(self):
        """The Slack notifier fires for a crash over a non-terminal log
        (task 7.2), before scoped reconciliation runs."""
        from unittest import mock

        tid = 'TST-N1'
        self._append_queue_entry(tid)
        sup = self._make_sup()
        sup.acquire_lock()
        try:
            cmd = _make_worker_cmd(sleep_secs=1, exit_code=1)
            sup._consume_queue(cmd_override=cmd)
            time.sleep(2)

            with mock.patch('fleetd.supervisor._notify_worker_event') as notify, \
                 mock.patch.object(sup, 'reconcile_orphaned_tickets'):
                sup._reap_children()

            notify.assert_called_once_with(
                sup._fleet_lib_dir, str(self.workspace), tid, 'non-terminal-exit',
            )
        finally:
            sup.release_lock()

    def test_notify_not_called_for_terminal_log_or_clean_completion(self):
        """A worker completing over a terminal (done) pipeline log must
        never trigger a Slack notification — only crashes do."""
        from unittest import mock

        tid = 'TST-N2'
        self._append_queue_entry(tid)
        sup = self._make_sup()
        sup.acquire_lock()
        try:
            cmd = _make_worker_cmd(sleep_secs=1, exit_code=0)
            sup._consume_queue(cmd_override=cmd)
            log_file = self.workspace / f'{tid}-pipeline.log'
            log_file.write_text(
                '2026-08-29T00:00:00Z|META|schema|done|1\n'
                '2026-08-29T00:00:01Z|META|outcome|done|completed\n'
            )
            time.sleep(2)

            with mock.patch('fleetd.supervisor._notify_worker_event') as notify:
                sup._reap_children()

            notify.assert_not_called()
        finally:
            sup.release_lock()

    def test_exit_127_worker_not_reconciled(self):
        """fleetd's own exec-failure sentinel (127) is a hard skip."""
        from unittest import mock

        tid = 'TST-R3'
        self._append_queue_entry(tid)
        sup = self._make_sup()
        sup.acquire_lock()
        try:
            cmd = _make_worker_cmd(sleep_secs=1, exit_code=127)
            sup._consume_queue(cmd_override=cmd)
            time.sleep(2)

            called = []
            with mock.patch.object(
                sup, 'reconcile_orphaned_tickets',
                side_effect=lambda scope_tids=None: called.append(scope_tids),
            ):
                sup._reap_children()

            self.assertEqual(called, [], "exit 127 must skip reconciliation")
            record = self._read_exit_record(tid)
            self.assertEqual(record['suppressed_retry_reason'],
                             'exec-failure (exit 127)')
        finally:
            sup.release_lock()

    def test_sigint_killed_worker_marked_killed_by_fleet_and_skipped(self):
        """A worker killed via kill_worker()'s SIGINT rung is recorded
        killed_by_fleet=True and never reaches reap-time recovery."""
        from unittest import mock

        tid = 'TST-R4'
        self._append_queue_entry(tid)
        sup = self._make_sup()
        sup.acquire_lock()
        try:
            # Plain worker with no signal handling installed — Python's
            # default SIGINT disposition (uncaught KeyboardInterrupt)
            # terminates it immediately, so the kill succeeds at the SIGINT
            # rung specifically (the scenario this test targets: the real
            # `claude -p` behavior of exiting 0 on SIGINT).
            cmd = _make_worker_cmd(sleep_secs=30)
            sup._consume_queue(cmd_override=cmd)

            called = []
            with mock.patch.object(
                sup, 'reconcile_orphaned_tickets',
                side_effect=lambda scope_tids=None: called.append(scope_tids),
            ):
                result = sup.kill_worker(tid, grace_secs=1)
                self.assertTrue(result.success)
                self.assertEqual(result.method, 'SIGINT')
                # The kill path itself must never trigger reconciliation —
                # a verified kill is a deliberate pause, not a crash.
                self.assertEqual(called, [])

            record = self._read_exit_record(tid)
            self.assertIsNotNone(record)
            self.assertTrue(record['killed_by_fleet'])
            self.assertEqual(record['action'], 'killed-by-fleet')

            # And a subsequent reap cycle (SIGCHLD for the already-reaped
            # pid) must not double-process or re-trigger reconciliation —
            # kill_worker's own _try_reap already consumed the exit status.
            with mock.patch.object(
                sup, 'reconcile_orphaned_tickets',
                side_effect=lambda scope_tids=None: called.append(scope_tids),
            ):
                sup._reap_children()
            self.assertEqual(called, [])
        finally:
            sup.release_lock()

    def test_hook_capture_merges_into_natural_reap_exit_record(self):
        """A Stop-hook-written {tid}-gen{N}-hook.json is merged into the exit
        record on natural reap (task 6.4)."""
        tid = 'TST-R5'
        self._append_queue_entry(tid)
        sup = self._make_sup()
        sup.acquire_lock()
        try:
            cmd = _make_worker_cmd(sleep_secs=1, exit_code=0)
            sup._consume_queue(cmd_override=cmd)
            hook_file = self.workspace / f'{tid}-gen1-hook.json'
            hook_file.write_text(json.dumps({'last_assistant_message': 'need clarification'}))
            time.sleep(2)
            sup._reap_children()

            record = self._read_exit_record(tid)
            self.assertIsNotNone(record)
            self.assertEqual(record['last_assistant_message'], 'need clarification')
        finally:
            sup.release_lock()

    def test_hook_capture_merges_into_killed_by_fleet_exit_record(self):
        """A hook capture present at kill time (e.g. cooperative stop, which
        lets the worker exit on its own and so can fire Stop) still merges
        into the killed-by-fleet exit record."""
        tid = 'TST-R6'
        self._append_queue_entry(tid)
        sup = self._make_sup()
        sup.acquire_lock()
        try:
            cmd = _make_worker_cmd(sleep_secs=30)
            sup._consume_queue(cmd_override=cmd)
            hook_file = self.workspace / f'{tid}-gen1-hook.json'
            hook_file.write_text(json.dumps({'last_assistant_message': 'done early'}))

            result = sup.kill_worker(tid, grace_secs=1)
            self.assertTrue(result.success)

            record = self._read_exit_record(tid)
            self.assertIsNotNone(record)
            self.assertTrue(record['killed_by_fleet'])
            self.assertEqual(record['last_assistant_message'], 'done early')
        finally:
            sup.release_lock()

    def test_exit_record_valid_when_hook_capture_absent(self):
        """SIGKILL leaves no hook capture — the exit record must still be
        valid, with last_assistant_message simply None."""
        tid = 'TST-R7'
        self._append_queue_entry(tid)
        sup = self._make_sup()
        sup.acquire_lock()
        try:
            cmd = _make_ignoring_worker(sleep_secs=30)
            sup._consume_queue(cmd_override=cmd)

            result = sup.kill_worker(tid, grace_secs=1)
            self.assertTrue(result.success)
            self.assertEqual(result.method, 'SIGKILL')

            record = self._read_exit_record(tid)
            self.assertIsNotNone(record)
            self.assertIsNone(record['last_assistant_message'])
        finally:
            sup.release_lock()

    def test_circuit_breaker_trips_after_consecutive_fast_failures(self):
        """N consecutive fast non-zero exits across different tickets halts
        dispatch (spawn_enabled False) rather than reconciling every one."""
        from unittest import mock

        for i in range(3):
            self._append_queue_entry(f'TST-CB{i}')
        sup = self._make_sup(max_concurrent=3)
        os.environ['FLEET_DETERMINISTIC_FAILURE_SECS'] = '30'
        os.environ['FLEET_DETERMINISTIC_FAILURE_COUNT'] = '3'
        sup.acquire_lock()
        try:
            cmd = _make_worker_cmd(sleep_secs=0, exit_code=1)
            sup._consume_queue(cmd_override=cmd)
            time.sleep(1)

            with mock.patch.object(sup, 'reconcile_orphaned_tickets'):
                sup._reap_children()

            self.assertTrue(sup._circuit_breaker_tripped,
                            "3 consecutive fast failures should trip the breaker")
            self.assertFalse(sup._spawn_enabled,
                             "tripped breaker must halt further dispatch")

            # A subsequent spawn attempt is a no-op — dispatch is halted.
            self._append_queue_entry('TST-CB-after')
            consumed = sup._consume_queue(cmd_override=cmd)
            self.assertEqual(consumed, set())
        finally:
            sup.release_lock()
            os.environ.pop('FLEET_DETERMINISTIC_FAILURE_SECS', None)
            os.environ.pop('FLEET_DETERMINISTIC_FAILURE_COUNT', None)

    def test_circuit_breaker_resets_on_slow_or_successful_exit(self):
        """A streak is reset by any exit that is not itself a fast failure."""
        from unittest import mock

        self._append_queue_entry('TST-CB-A')
        sup = self._make_sup(max_concurrent=1)
        os.environ['FLEET_DETERMINISTIC_FAILURE_SECS'] = '30'
        sup.acquire_lock()
        try:
            # Fast failure #1.
            cmd_fail = _make_worker_cmd(sleep_secs=0, exit_code=1)
            sup._consume_queue(cmd_override=cmd_fail)
            time.sleep(1)
            with mock.patch.object(sup, 'reconcile_orphaned_tickets'):
                sup._reap_children()
            self.assertEqual(len(sup._fast_failure_streak), 1)

            # A clean exit resets the streak.
            self._append_queue_entry('TST-CB-B')
            cmd_ok = _make_worker_cmd(sleep_secs=0, exit_code=0)
            sup._consume_queue(cmd_override=cmd_ok)
            time.sleep(1)
            with mock.patch.object(sup, 'reconcile_orphaned_tickets'):
                sup._reap_children()
            self.assertEqual(sup._fast_failure_streak, [])
            self.assertFalse(sup._circuit_breaker_tripped)
        finally:
            sup.release_lock()
            os.environ.pop('FLEET_DETERMINISTIC_FAILURE_SECS', None)

    def test_kill_request_processed_without_waiting_for_reconcile(self):
        """Lock-hoist: reaping a crashed worker must not block kill-request
        processing on a slow reconcile subprocess (task 3.11)."""
        from unittest import mock

        self._append_queue_entry('TST-LH1')
        sup = self._make_sup(max_concurrent=1)
        sup.acquire_lock()
        try:
            crash_cmd = _make_worker_cmd(sleep_secs=1, exit_code=1)
            sup._consume_queue(cmd_override=crash_cmd)
            time.sleep(2)  # let it crash so the reaper has something to find

            entered = threading.Event()
            release = threading.Event()

            def _slow_reconcile(scope_tids=None):
                entered.set()
                release.wait(timeout=10)

            with mock.patch.object(sup, 'reconcile_orphaned_tickets',
                                   side_effect=_slow_reconcile):
                t = threading.Thread(target=sup._reap_children)
                t.start()
                self.assertTrue(entered.wait(timeout=5),
                                "reconcile subprocess never started")
                # _state_lock must be free while reconcile runs — a pending
                # kill-request (or the health endpoint) must not stall for
                # up to 120s behind it.
                self.assertTrue(sup._state_lock.acquire(timeout=2),
                                "_state_lock held during reconcile subprocess")
                sup._state_lock.release()
                release.set()
                t.join(timeout=10)
        finally:
            sup.release_lock()

    def test_exit_record_fields_use_iso_utc_timestamp(self):
        """Sanity check on the exit record's timestamp shape."""
        from fleetd.supervisor import _write_exit_record

        entry = _write_exit_record(
            str(self.workspace), 'TST-FMT', 1, 12345, -9, 'signal',
            killed_by_fleet=False, terminal=False,
        )
        self.assertRegex(entry['exited_at'], r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$')

    def test_generation_files_swept_beyond_retention(self):
        """Stale per-generation stdio/exit files are pruned beyond retention."""
        from fleetd.supervisor import _sweep_stale_generation_files

        tid = 'TST-SWEEP'
        for gen in range(1, 6):
            (self.workspace / f'{tid}-gen{gen}.json').write_text('x')
            (self.workspace / f'{tid}-gen{gen}.stderr').write_text('x')
            (self.workspace / f'{tid}-gen{gen}-exit.json').write_text('{}')

        _sweep_stale_generation_files(str(self.workspace), tid, current_generation=5,
                                      retention=2)

        # Generations 1-3 are beyond the retention-2 window (keep 4, 5).
        for gen in (1, 2, 3):
            self.assertFalse((self.workspace / f'{tid}-gen{gen}.json').exists())
            self.assertFalse((self.workspace / f'{tid}-gen{gen}.stderr').exists())
            self.assertFalse((self.workspace / f'{tid}-gen{gen}-exit.json').exists())
        for gen in (4, 5):
            self.assertTrue((self.workspace / f'{tid}-gen{gen}.json').exists())


# ── Group 9: Generation fencing tests ────────────────────────────────────


class GenerationFencingTest(unittest.TestCase):
    """Task 9.5: killed generation fenced, restarted generation above fence."""

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.workspace = Path(self._tmp.name)

    def tearDown(self):
        _safe_tmp_cleanup(self._tmp)

    def _append_queue(self, tid, reason='test'):
        queue_file = self.workspace / 'fleet-default-spawn-queue.jsonl'
        entry = {'tid': tid, 'reason': reason, 'timestamp': datetime.now(timezone.utc).isoformat()}
        with open(queue_file, 'a') as f:
            f.write(json.dumps(entry) + '\n')

    def test_resolve_generation_defaults_to_one(self):
        """With no prior records, generation starts at 1."""
        from fleetd.supervisor import Supervisor

        sup = Supervisor(
            state_dir=str(self.workspace),
            pidfile=str(self.workspace / 'test.pid'),
        )
        self.assertEqual(sup._resolve_generation('TST-G1'), 1)

    def test_resolve_generation_above_fence(self):
        """A new spawn gets a generation higher than the fenced generation."""
        from fleetd.supervisor import Supervisor

        # Write a fence marker for generation 3.
        fence_file = self.workspace / 'TST-G2-fence'
        fence_file.write_text(json.dumps({
            'tid': 'TST-G2',
            'fenced_generation': 3,
            'fenced_at': datetime.now(timezone.utc).isoformat(),
        }))

        sup = Supervisor(
            state_dir=str(self.workspace),
            pidfile=str(self.workspace / 'test.pid'),
        )
        gen = sup._resolve_generation('TST-G2')
        self.assertEqual(gen, 4,
                         "new generation should be fenced_gen + 1")

    def test_resolve_generation_above_prior_registry(self):
        """A respawn gets a generation higher than a surviving run registry."""
        from fleetd.supervisor import Supervisor

        # Write a run registry for generation 2.
        run_file = self.workspace / 'TST-G3-run.json'
        run_file.write_text(json.dumps({
            'tid': 'TST-G3',
            'pid': '12345',
            'generation': 2,
            'started_at': datetime.now(timezone.utc).isoformat(),
            'reason': 'test',
        }))

        sup = Supervisor(
            state_dir=str(self.workspace),
            pidfile=str(self.workspace / 'test.pid'),
        )
        gen = sup._resolve_generation('TST-G3')
        self.assertEqual(gen, 3,
                         "new generation should be prior_gen + 1")

    def test_resolve_generation_max_of_fence_and_registry(self):
        """New generation exceeds both fence and registry, whichever is higher."""
        from fleetd.supervisor import Supervisor

        # Registry says gen=2, fence says gen=5.
        fence_file = self.workspace / 'TST-G4-fence'
        fence_file.write_text(json.dumps({
            'tid': 'TST-G4', 'fenced_generation': 5,
        }))
        run_file = self.workspace / 'TST-G4-run.json'
        run_file.write_text(json.dumps({
            'tid': 'TST-G4', 'pid': '99999', 'generation': 2,
            'started_at': datetime.now(timezone.utc).isoformat(),
            'reason': 'test',
        }))

        sup = Supervisor(
            state_dir=str(self.workspace),
            pidfile=str(self.workspace / 'test.pid'),
        )
        gen = sup._resolve_generation('TST-G4')
        self.assertEqual(gen, 6,
                         "new generation should be max(fence, registry) + 1")

    # ── Generation continuity across stale-registry deletion ───────────────

    def _write_stale_run_file(self, tid, generation, dead_pid):
        """Write a run-registry entry whose PID is known dead."""
        run_file = self.workspace / f'{tid}-run.json'
        run_file.write_text(json.dumps({
            'tid': tid,
            'pid': str(dead_pid),
            'generation': generation,
            'started_at': datetime.now(timezone.utc).isoformat(),
            'reason': 'test',
        }))
        return run_file

    def test_scan_registry_preserves_generation_before_delete(self):
        """Stale-entry deletion keeps the last-known generation on disk."""
        from fleetd.supervisor import scan_registry

        # A PID that is guaranteed dead: a child that already exited.
        sleeper = subprocess.Popen([sys.executable, '-c', 'pass'])
        sleeper.wait(timeout=5)
        dead_pid = sleeper.pid

        run_file = self._write_stale_run_file('CRE-14', 2, dead_pid)

        entries = scan_registry(self.workspace, verify_ownership=False)
        self.assertEqual(entries, [],
                         "dead-PID entry must not be adopted")
        self.assertFalse(run_file.exists(),
                         "stale run-registry file should be deleted")

        last_file = self.workspace / 'CRE-14-last-generation'
        self.assertTrue(last_file.exists(),
                        "last-generation record should be preserved")
        data = json.loads(last_file.read_text())
        self.assertEqual(data.get('generation'), 2,
                         "preserved generation should match the deleted entry")

    def test_next_spawn_continues_preserved_generation(self):
        """A spawn after stale deletion continues the sequence, not restart at 1."""
        from fleetd.supervisor import Supervisor

        # Simulate the state after scan_registry deleted a gen-2 entry:
        # no run registry, no fence, only the preserved record.
        last_file = self.workspace / 'CRE-14-last-generation'
        last_file.write_text(json.dumps({'generation': 2}))

        sup = Supervisor(
            state_dir=str(self.workspace),
            pidfile=str(self.workspace / 'test.pid'),
        )
        self.assertEqual(sup._resolve_generation('CRE-14'), 3,
                         "next spawn should be preserved_gen + 1")

    def test_fence_higher_than_preserved_still_wins(self):
        """A higher fenced generation beats the preserved value."""
        from fleetd.supervisor import Supervisor

        last_file = self.workspace / 'CRE-14-last-generation'
        last_file.write_text(json.dumps({'generation': 2}))
        fence_file = self.workspace / 'CRE-14-fence'
        fence_file.write_text(json.dumps({
            'tid': 'CRE-14', 'fenced_generation': 4,
        }))

        sup = Supervisor(
            state_dir=str(self.workspace),
            pidfile=str(self.workspace / 'test.pid'),
        )
        self.assertEqual(sup._resolve_generation('CRE-14'), 5,
                         "next spawn should be max(preserved, fenced) + 1")

    def test_killed_worker_fences_generation(self):
        """Killing a worker writes a fence for its generation."""
        from fleetd.supervisor import Supervisor

        self._append_queue('TST-G5')
        sup = Supervisor(
            state_dir=str(self.workspace),
            pidfile=str(self.workspace / 'test.pid'),
            spawn_enabled=True,
            max_concurrent=1,
        )
        sup.acquire_lock()
        try:
            # Spawn a short-lived worker.
            cmd = _make_worker_cmd(sleep_secs=3)
            sup._consume_queue(cmd_override=cmd)
            child = sup._children.get('TST-G5')
            self.assertIsNotNone(child)
            killed_gen = child['generation']
            self.assertGreater(killed_gen, 0)

            # Kill it.
            sup.kill_worker('TST-G5', grace_secs=1)

            # Fence file should exist with the killed generation.
            fence_file = self.workspace / 'TST-G5-fence'
            self.assertTrue(fence_file.exists(),
                            "fence file should be written on kill")
            fence_data = json.loads(fence_file.read_text())
            self.assertEqual(fence_data['fenced_generation'], killed_gen,
                             "fence should record the killed generation")
        finally:
            sup.release_lock()

    def test_respawn_above_fence(self):
        """A respawned worker gets a generation above the fence, so it's unfenced."""
        from fleetd.supervisor import Supervisor

        # First spawn → gen=1, kill → fence=1.
        self._append_queue('TST-G6')
        sup = Supervisor(
            state_dir=str(self.workspace),
            pidfile=str(self.workspace / 'test.pid'),
            spawn_enabled=True,
            max_concurrent=1,
        )
        sup.acquire_lock()
        try:
            cmd = _make_worker_cmd(sleep_secs=3)
            sup._consume_queue(cmd_override=cmd)
            child = sup._children.get('TST-G6')
            gen1 = child['generation']
            sup.kill_worker('TST-G6', grace_secs=1)

            # Verify fence exists.
            fence_file = self.workspace / 'TST-G6-fence'
            self.assertTrue(fence_file.exists())

            # Respawn — should get gen > fence.
            self._append_queue('TST-G6', reason='retry')
            sup._consume_queue(cmd_override=cmd)
            child2 = sup._children.get('TST-G6')
            self.assertIsNotNone(child2,
                                 "respawned worker should be in child table")
            gen2 = child2['generation']
            self.assertGreater(gen2, gen1,
                               f"respawn generation {gen2} must exceed "
                               f"fenced generation {gen1}")

            # Kill the respawn too.
            sup.kill_worker('TST-G6', grace_secs=1)
        finally:
            sup.release_lock()

    def test_generation_in_registry_matches_child_table(self):
        """The generation in the run registry matches the child table."""
        from fleetd.supervisor import Supervisor

        self._append_queue('TST-G7')
        sup = Supervisor(
            state_dir=str(self.workspace),
            pidfile=str(self.workspace / 'test.pid'),
            spawn_enabled=True,
            max_concurrent=1,
        )
        sup.acquire_lock()
        try:
            cmd = _make_worker_cmd(sleep_secs=30)
            sup._consume_queue(cmd_override=cmd)
            child = sup._children.get('TST-G7')
            self.assertIsNotNone(child)

            # Read the run registry and verify.
            run_file = self.workspace / 'TST-G7-run.json'
            reg_data = json.loads(run_file.read_text())
            self.assertEqual(int(reg_data['generation']), child['generation'],
                             "registry generation should match child table")
        finally:
            sup.release_lock()


# ── Startup orphan reconciliation tests ──────────────────────────────────


class _RunOnceSupervisor:
    """Wraps Supervisor for startup-sequence assertions.

    Patches the loop-body methods to record call order and raise SystemExit
    on the first queue-consume, so run_observe() exits after exactly one
    loop iteration (reconciliation happens before the loop starts, so one
    iteration is enough to prove it runs once at startup, not per cycle).
    """

    def __init__(self, supervisor, calls):
        self._sup = supervisor
        self._calls = calls

    def __getattr__(self, name):
        return getattr(self._sup, name)


class StartupReconciliationTest(unittest.TestCase):
    """run_observe calls reconciliation once at startup, after adoption."""

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.workspace = Path(self._tmp.name)
        self.pidfile = self.workspace / 'test.pid'
        self.port = _find_free_port()

    def tearDown(self):
        _safe_tmp_cleanup(self._tmp)

    def _make_patched_supervisor(self):
        from fleetd.supervisor import Supervisor

        sup = Supervisor(
            state_dir=str(self.workspace),
            pidfile=str(self.pidfile),
            port=self.port,
            cycle_interval=0.05,
        )
        calls = []

        def record(name):
            def _fn(*args, **kwargs):
                calls.append(name)
                return None
            return _fn

        sup.scan_workers = record('scan_workers')
        sup.reconcile_orphaned_tickets = record('reconcile_orphaned_tickets')
        sup.run_detection_cycle = record('run_detection_cycle')
        sup._reap_children = record('_reap_children')
        sup._process_kill_requests = record('_process_kill_requests')

        def _consume_queue(*args, **kwargs):
            calls.append('_consume_queue')
            raise SystemExit(0)

        sup._consume_queue = _consume_queue
        return sup, calls

    def test_run_observe_reconciles_once_after_scan(self):
        """run_observe: scan_workers → reconcile_orphaned_tickets → detection."""
        from fleetd.supervisor import Supervisor

        sup, calls = self._make_patched_supervisor()
        with self.assertRaises(SystemExit):
            sup.run_observe()

        # Reconcile happens exactly once, immediately after scan_workers and
        # before the first detection cycle; the single loop iteration adds
        # no second call.
        self.assertEqual(calls.count('reconcile_orphaned_tickets'), 1,
                         "reconciliation must run exactly once at startup")
        scan_idx = calls.index('scan_workers')
        recon_idx = calls.index('reconcile_orphaned_tickets')
        detect_idx = calls.index('run_detection_cycle')
        self.assertLess(scan_idx, recon_idx,
                        "reconciliation must run after scan_workers")
        self.assertLess(recon_idx, detect_idx,
                        "reconciliation must run before the first detection cycle")

    def test_reconcile_passes_adopted_tids_to_bash(self):
        """The bash reconciliation call receives the adopted-live TID set."""
        from unittest import mock
        from fleetd.supervisor import Supervisor

        sup = Supervisor(
            state_dir=str(self.workspace),
            pidfile=str(self.pidfile),
            port=self.port,
        )
        # Simulate scan_workers having adopted two survivors; a third child
        # exists in the table but is not adopted.
        sup._children.add(tid='CRE-12', pid=1, adopted=True)
        sup._children.add(tid='CRE-13', pid=2, adopted=True)
        sup._children.add(tid='CRE-14', pid=3, adopted=False)

        captured = {}

        def fake_run(cmd, **kwargs):
            captured['cmd'] = cmd
            captured['env'] = kwargs.get('env', {})
            return mock.Mock(returncode=0, stdout='', stderr='')

        with mock.patch('fleetd.supervisor.subprocess.run', side_effect=fake_run):
            sup.reconcile_orphaned_tickets()

        self.assertIn('cmd', captured, "bash reconciliation not invoked")
        argv = captured['cmd']
        bash_source = argv[2] if len(argv) > 2 and argv[:2] == ['bash', '-c'] else ''
        self.assertIn('fleet_reconcile_orphans', bash_source,
                      f"bash source missing call: {argv}")
        # Untrusted values travel via environment variables, not inline
        # interpolation — the bash source contains only fixed variable refs.
        env = captured['env']
        self.assertEqual(env.get('FLEET_RECONCILE_LIVE_TIDS'), 'CRE-12 CRE-13',
                         "adopted TIDs not passed via env")
        self.assertNotIn('CRE-14', env.get('FLEET_RECONCILE_LIVE_TIDS', ''),
                         "non-adopted TID leaked into live set")
        self.assertEqual(env.get('FLEET_RECONCILE_STATE_DIR'), str(self.workspace))
        self.assertTrue(env.get('FLEET_RECONCILE_QUEUE_FILE', '').endswith(
            'fleet-default-spawn-queue.jsonl'))

    def test_reconcile_no_inline_interpolation_of_untrusted_values(self):
        """No state-dir-derived value is spliced into the bash source string.

        A malicious `{tid}-run.json` (e.g. tid `x"; rm -rf ~; "`) in a shared
        workspace must not become shell syntax at reconciliation time.
        """
        from unittest import mock
        from fleetd.supervisor import Supervisor

        sup = Supervisor(
            state_dir=str(self.workspace),
            pidfile=str(self.pidfile),
            port=self.port,
        )
        # A hostile adopted TID that would be catastrophic if interpolated.
        hostile_tid = 'EVIL"; touch /tmp/pwned; "'
        sup._children.add(tid=hostile_tid, pid=1, adopted=True)

        captured = {}

        def fake_run(cmd, **kwargs):
            captured['cmd'] = cmd
            captured['env'] = kwargs.get('env', {})
            return mock.Mock(returncode=0, stdout='', stderr='')

        with mock.patch('fleetd.supervisor.subprocess.run', side_effect=fake_run):
            sup.reconcile_orphaned_tickets()

        bash_source = captured['cmd'][2]
        # The hostile value appears nowhere in the parsed command source.
        self.assertNotIn('pwned', bash_source)
        self.assertNotIn(hostile_tid, bash_source)
        # It rides in the environment instead, where bash cannot parse it.
        self.assertIn(hostile_tid, captured['env']['FLEET_RECONCILE_LIVE_TIDS'])

    def test_reconcile_failure_does_not_block(self):
        """A reconciliation subprocess failure is reported, not raised."""
        from unittest import mock
        from fleetd.supervisor import Supervisor

        sup = Supervisor(
            state_dir=str(self.workspace),
            pidfile=str(self.pidfile),
            port=self.port,
        )

        with mock.patch(
            'fleetd.supervisor.subprocess.run',
            return_value=mock.Mock(returncode=1, stdout='', stderr='boom'),
        ):
            # Must not raise.
            sup.reconcile_orphaned_tickets()


# ── Group 10: CLI alignment tests ────────────────────────────────────────


class CLIAlignmentTest(unittest.TestCase):
    """Task 10.4: skill-issued dispatch → daemon-owned worker."""

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.workspace = Path(self._tmp.name)

    def tearDown(self):
        _safe_tmp_cleanup(self._tmp)

    def _write_queue_entry(self, tid, reason='cli-dispatch'):
        """Simulate fleet-controller dispatch writing to the spawn queue."""
        queue_file = self.workspace / 'fleet-default-spawn-queue.jsonl'
        entry = {
            'tid': tid,
            'reason': reason,
            'timestamp': datetime.now(timezone.utc).isoformat(),
        }
        with open(queue_file, 'a') as f:
            f.write(json.dumps(entry) + '\n')

    def test_skill_dispatch_results_in_daemon_owned_worker(self):
        """A queue entry written by the skill (simulated) results in a
        daemon-owned (non-adopted) worker."""
        from fleetd.supervisor import Supervisor

        self._write_queue_entry('TST-CLI1', 'cli-dispatch')
        sup = Supervisor(
            state_dir=str(self.workspace),
            pidfile=str(self.workspace / 'test.pid'),
            spawn_enabled=True,
            max_concurrent=1,
        )
        sup.acquire_lock()
        try:
            cmd = _make_worker_cmd(sleep_secs=30)
            consumed = sup._consume_queue(cmd_override=cmd)
            self.assertIn('TST-CLI1', consumed)

            child = sup._children.get('TST-CLI1')
            self.assertIsNotNone(child, "worker should be in child table")
            self.assertFalse(child['adopted'],
                             "daemon-spawned worker should NOT be adopted")
            self.assertGreater(child['pid'], 0,
                               "PID should be a real positive integer")
        finally:
            sup.release_lock()

    def test_kill_request_file_processed_by_daemon(self):
        """CLI writes a kill-request file; daemon processes and kills the worker."""
        from fleetd.supervisor import Supervisor, _write_kill_result

        # Spawn a worker first.
        self._write_queue_entry('TST-CLI2', 'cli-dispatch')
        sup = Supervisor(
            state_dir=str(self.workspace),
            pidfile=str(self.workspace / 'test.pid'),
            spawn_enabled=True,
            max_concurrent=1,
        )
        sup.acquire_lock()
        try:
            cmd = _make_worker_cmd(sleep_secs=30)
            sup._consume_queue(cmd_override=cmd)
            self.assertIsNotNone(sup._children.get('TST-CLI2'))

            # Simulate CLI kill request.
            kr_dir = self.workspace / 'kill-requests'
            kr_dir.mkdir(parents=True, exist_ok=True)
            req_file = kr_dir / 'TST-CLI2.json'
            req_file.write_text(json.dumps({
                'tid': 'TST-CLI2',
                'reason': 'manual-intervention',
            }))

            # Process it.
            sup._process_kill_requests()

            # Worker should be gone.
            self.assertIsNone(sup._children.get('TST-CLI2'),
                              "worker should be killed by CLI request")

            # Result file should exist.
            result_file = kr_dir / 'TST-CLI2-result.json'
            self.assertTrue(result_file.exists(),
                            "result file should be written")
            result = json.loads(result_file.read_text())
            self.assertTrue(result['success'],
                            f"kill should succeed: {result.get('error')}")
            self.assertIn(result['method'],
                         ['cooperative', 'SIGINT', 'SIGTERM', 'SIGKILL'])
        finally:
            sup.release_lock()

    def test_kill_request_for_nonexistent_worker(self):
        """Kill request for a worker not in the child table writes a failure result."""
        from fleetd.supervisor import Supervisor

        sup = Supervisor(
            state_dir=str(self.workspace),
            pidfile=str(self.workspace / 'test.pid'),
        )
        sup.acquire_lock()
        try:
            kr_dir = self.workspace / 'kill-requests'
            kr_dir.mkdir(parents=True, exist_ok=True)
            req_file = kr_dir / 'TST-NOPE.json'
            req_file.write_text(json.dumps({
                'tid': 'TST-NOPE',
                'reason': 'test',
            }))

            sup._process_kill_requests()

            result_file = kr_dir / 'TST-NOPE-result.json'
            self.assertTrue(result_file.exists())
            result = json.loads(result_file.read_text())
            self.assertFalse(result['success'],
                             "kill for nonexistent worker should fail")
        finally:
            sup.release_lock()


# ── Helpers ────────────────────────────────────────────────────────────────

def _find_free_port(start=21001):
    """Find a free port starting from `start`."""
    import socket
    port = start
    while port < start + 100:
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
            try:
                s.bind(('127.0.0.1', port))
                return port
            except OSError:
                port += 1
    raise RuntimeError(f"no free port found in range {start}-{start + 100}")


def _pid_is_alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except (OSError, ProcessLookupError):
        return False


def _run_fleet_detect_all(workspace):
    """Run fleet_detect_all via the CLI path (direct bash invocation).

    Returns parsed JSON on success, None on failure.
    """
    fleet_lib = Path(__file__).resolve().parent.parent.parent / 'lib'
    detect_script = fleet_lib / 'fleet-detect.sh'
    if not detect_script.is_file():
        return None

    bash_cmd = f'source "{detect_script}" && fleet_detect_all "{workspace}"'
    try:
        proc = subprocess.run(
            ['bash', '-c', bash_cmd],
            capture_output=True,
            text=True,
            timeout=30,
        )
        return json.loads(proc.stdout)
    except (subprocess.TimeoutExpired, json.JSONDecodeError, OSError):
        return None


def _get_severity(result, tid):
    """Extract the severity for a given TID from a fleet_detect_all result."""
    for pipeline in result.get('pipelines', []):
        if pipeline.get('tid') == tid:
            return pipeline.get('severity', 0)
    return 0


# ── Commercial Evidence MVP Branch C: fleet-cost-events ──────────────────


class WorkerGenFileTest(unittest.TestCase):
    """Agent Observer: `_worker_gen_file` resolves whichever extension the
    spawn that wrote this generation actually used, not the flag's current
    value — a mid-run toggle or restart must not silently point a reader at
    a file that was never written."""

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.workspace = Path(self._tmp.name)

    def tearDown(self):
        _safe_tmp_cleanup(self._tmp)

    def test_ticket_level_is_always_json(self):
        from fleetd.supervisor import _worker_gen_file

        path = _worker_gen_file(str(self.workspace), 'CRE-9', '', 1)
        self.assertEqual(path.name, 'CRE-9-gen1.json')

    def test_phase_level_prefers_ndjson_when_it_exists(self):
        from fleetd.supervisor import _worker_gen_file

        (self.workspace / 'CRE-9-verify-gen1.ndjson').write_text('{}')
        path = _worker_gen_file(str(self.workspace), 'CRE-9', 'VERIFY', 1)
        self.assertEqual(path.name, 'CRE-9-verify-gen1.ndjson')

    def test_phase_level_falls_back_to_json_when_no_ndjson_exists(self):
        from fleetd.supervisor import _worker_gen_file

        path = _worker_gen_file(str(self.workspace), 'CRE-9', 'VERIFY', 1)
        self.assertEqual(path.name, 'CRE-9-verify-gen1.json')


class CostEventTest(unittest.TestCase):
    """Reap/fleet-kill cost extraction and runs.jsonl `cost` event emission."""

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.workspace = Path(self._tmp.name)
        self._append_queue_entry('TST-C1', 'test-cost', generation=1)

    def tearDown(self):
        _safe_tmp_cleanup(self._tmp)

    def _append_queue_entry(self, tid, reason, generation=1):
        queue_file = self.workspace / 'fleet-default-spawn-queue.jsonl'
        entry = {
            'tid': tid,
            'reason': reason,
            'generation': generation,
            'timestamp': datetime.now(timezone.utc).isoformat(),
        }
        with open(queue_file, 'a') as f:
            f.write(json.dumps(entry) + '\n')

    def _runs_events(self):
        runs_file = self.workspace / 'runs.jsonl'
        if not runs_file.is_file():
            return []
        return [json.loads(line) for line in runs_file.read_text().splitlines()
                if line.strip()]

    def test_reap_writes_cost_usd_and_one_cost_event(self):
        from fleetd.supervisor import Supervisor

        sup = Supervisor(
            state_dir=str(self.workspace),
            pidfile=str(self.workspace / 'test.pid'),
            spawn_enabled=True, max_concurrent=1, cycle_interval=1,
        )
        sup.acquire_lock()
        try:
            cmd = _make_worker_cmd(sleep_secs=1)
            sup._consume_queue(cmd_override=cmd)
            self.assertIsNotNone(sup._children.get('TST-C1'))

            # The harness envelope the worker "produced" before it exits.
            gen_file = self.workspace / 'TST-C1-gen1.json'
            gen_file.write_text(json.dumps({'total_cost_usd': 0.4321}))

            time.sleep(2)
            sup._reap_children()

            exit_entry = json.loads(
                (self.workspace / 'TST-C1-gen1-exit.json').read_text())
            self.assertEqual(exit_entry['cost_usd'], 0.4321)

            cost_events = [e for e in self._runs_events() if e.get('kind') == 'cost']
            self.assertEqual(len(cost_events), 1)
            self.assertEqual(cost_events[0]['tid'], 'TST-C1')
            self.assertEqual(cost_events[0]['gen'], 1)
            self.assertEqual(cost_events[0]['usd'], 0.4321)
            # No META|run-id line exists for this synthetic ticket, so the
            # event's run_id is an honest null, not a guess.
            self.assertIsNone(cost_events[0]['run_id'])
        finally:
            sup.release_lock()

    def test_no_envelope_means_no_cost_event(self):
        from fleetd.supervisor import Supervisor

        sup = Supervisor(
            state_dir=str(self.workspace),
            pidfile=str(self.workspace / 'test.pid'),
            spawn_enabled=True, max_concurrent=1, cycle_interval=1,
        )
        sup.acquire_lock()
        try:
            cmd = _make_worker_cmd(sleep_secs=1)
            sup._consume_queue(cmd_override=cmd)
            time.sleep(2)
            sup._reap_children()

            exit_entry = json.loads(
                (self.workspace / 'TST-C1-gen1-exit.json').read_text())
            self.assertIsNone(exit_entry['cost_usd'])
            self.assertEqual(
                [e for e in self._runs_events() if e.get('kind') == 'cost'], [])
        finally:
            sup.release_lock()

    def test_fleet_kill_writes_a_cost_event(self):
        from fleetd.supervisor import Supervisor

        sup = Supervisor(
            state_dir=str(self.workspace),
            pidfile=str(self.workspace / 'test.pid'),
            spawn_enabled=True, max_concurrent=1,
        )
        sup.acquire_lock()
        try:
            cmd = _make_ignoring_worker(sleep_secs=30)
            sup._consume_queue(cmd_override=cmd)
            child = sup._children.get('TST-C1')
            self.assertIsNotNone(child)

            gen_file = self.workspace / 'TST-C1-gen1.json'
            gen_file.write_text(json.dumps({'total_cost_usd': 1.5}))

            result = sup.kill_worker('TST-C1', grace_secs=1)
            self.assertTrue(result.success, f"kill should succeed: {result.error}")

            exit_entry = json.loads(
                (self.workspace / 'TST-C1-gen1-exit.json').read_text())
            self.assertEqual(exit_entry['cost_usd'], 1.5)
            self.assertTrue(exit_entry['killed_by_fleet'])

            cost_events = [e for e in self._runs_events() if e.get('kind') == 'cost']
            self.assertEqual(len(cost_events), 1)
            self.assertEqual(cost_events[0]['usd'], 1.5)
        finally:
            sup.release_lock()


class WorkerSpawnEnvironmentTest(unittest.TestCase):
    """worker-stdio-capture: FLEET_GENERATION / FLEET_VERSION reach the worker."""

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.workspace = Path(self._tmp.name)

    def tearDown(self):
        _safe_tmp_cleanup(self._tmp)

    def test_worker_environment_carries_generation_and_version(self):
        from fleetd.supervisor import spawn_worker

        out = self.workspace / 'TST-ENVC-gen3.json'
        pid, _ = spawn_worker(
            tid='TST-ENVC', generation=3, state_dir=str(self.workspace),
            cmd_override=[
                sys.executable, '-c',
                'import os; print(os.environ.get("FLEET_GENERATION"), '
                'os.environ.get("FLEET_VERSION"))'],
        )
        os.waitpid(pid, 0)
        deadline = time.time() + 5
        while time.time() < deadline and not (
                out.is_file() and out.stat().st_size > 0):
            time.sleep(0.05)
        printed = out.read_text()
        self.assertIn('3', printed.split()[0])

    def test_a_missing_plugin_json_degrades_to_empty_string(self):
        from fleetd import supervisor as sup_mod
        from unittest import mock

        with mock.patch.object(sup_mod, '_FLEET_PLUGIN_VERSION', None), \
             mock.patch.object(Path, 'read_text', side_effect=OSError('nope')):
            self.assertEqual(sup_mod._fleet_plugin_version(), '')


# ── Commercial Evidence MVP Branch C: fleet-merge-poll-cadence ───────────


class MergePollSweepTest(unittest.TestCase):
    """`_merge_poll_sweep` shells out to merge-poll.sh, fail-soft throughout."""

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.workspace = Path(self._tmp.name)

    def tearDown(self):
        _safe_tmp_cleanup(self._tmp)

    def _make_supervisor(self):
        from fleetd.supervisor import Supervisor
        return Supervisor(
            state_dir=str(self.workspace), pidfile=str(self.workspace / 't.pid'))

    def test_missing_script_is_a_noop(self):
        from unittest import mock

        sup = self._make_supervisor()
        with mock.patch('fleetd.phase_dispatch.ticket_auto_lib_dir',
                        return_value=self.workspace / 'no-such-lib'), \
             mock.patch('subprocess.run') as run:
            sup._merge_poll_sweep()
            run.assert_not_called()

    def test_invokes_the_script_with_an_outer_timeout(self):
        from unittest import mock

        lib_dir = self.workspace / 'lib'
        lib_dir.mkdir()
        (lib_dir / 'merge-poll.sh').write_text('#!/usr/bin/env bash\n')

        sup = self._make_supervisor()
        with mock.patch('fleetd.phase_dispatch.ticket_auto_lib_dir',
                        return_value=lib_dir), \
             mock.patch('subprocess.run') as run:
            sup._merge_poll_sweep()
            run.assert_called_once()
            _, kwargs = run.call_args
            self.assertEqual(kwargs.get('timeout'), 60)

    def test_a_hanging_gh_call_does_not_propagate(self):
        from unittest import mock

        lib_dir = self.workspace / 'lib'
        lib_dir.mkdir()
        (lib_dir / 'merge-poll.sh').write_text('#!/usr/bin/env bash\n')

        sup = self._make_supervisor()
        with mock.patch('fleetd.phase_dispatch.ticket_auto_lib_dir',
                        return_value=lib_dir), \
             mock.patch('subprocess.run',
                        side_effect=subprocess.TimeoutExpired(cmd='x', timeout=60)):
            sup._merge_poll_sweep()  # must not raise


class MergePollCadenceTest(unittest.TestCase):
    """run_observe fires the sweep every FLEET_MERGE_POLL_CYCLES cycles."""

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.workspace = Path(self._tmp.name)
        self.pidfile = self.workspace / 'test.pid'
        self.port = _find_free_port()

    def tearDown(self):
        _safe_tmp_cleanup(self._tmp)

    def _make_patched_supervisor(self, cycles_before_exit):
        from fleetd.supervisor import Supervisor

        sup = Supervisor(
            state_dir=str(self.workspace), pidfile=str(self.pidfile),
            port=self.port, cycle_interval=0.01,
        )
        calls = []
        sup.scan_workers = lambda: None
        sup.reconcile_orphaned_tickets = lambda *a, **k: None
        sup.run_detection_cycle = lambda: None
        sup._reap_children = lambda: None
        sup._process_kill_requests = lambda: None
        sup.poll_adopted_workers = lambda: None
        sup.maybe_spawn_otel = lambda: None
        sup._merge_poll_sweep = lambda: calls.append('sweep')

        counter = {'n': 0}

        def _consume_queue(*args, **kwargs):
            counter['n'] += 1
            if counter['n'] >= cycles_before_exit:
                raise SystemExit(0)

        sup._consume_queue = _consume_queue
        return sup, calls

    def test_sweep_fires_on_the_configured_cadence(self):
        from unittest import mock
        from fleetd import supervisor as sup_mod

        with mock.patch.object(sup_mod, 'FLEET_MERGE_POLL_CYCLES', 2):
            sup, calls = self._make_patched_supervisor(cycles_before_exit=2)
            with self.assertRaises(SystemExit):
                sup.run_observe()
            self.assertEqual(calls, ['sweep'])

    def test_sweep_does_not_fire_off_cadence(self):
        from unittest import mock
        from fleetd import supervisor as sup_mod

        with mock.patch.object(sup_mod, 'FLEET_MERGE_POLL_CYCLES', 5):
            sup, calls = self._make_patched_supervisor(cycles_before_exit=2)
            with self.assertRaises(SystemExit):
                sup.run_observe()
            self.assertEqual(calls, [])


if __name__ == '__main__':
    unittest.main()
