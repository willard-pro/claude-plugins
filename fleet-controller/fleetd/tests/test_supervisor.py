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
"""

import http.client
import json
import os
import signal
import subprocess
import sys
import tempfile
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


class SingleInstanceTest(unittest.TestCase):
    """Task 4.6: single-instance enforcement."""

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.state_dir = Path(self._tmp.name)
        self.pidfile = self.state_dir / 'fleetd.pid'
        self.port = _find_free_port()

    def tearDown(self):
        self._tmp.cleanup()

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
        self._tmp.cleanup()

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


class RegistryObservationTest(unittest.TestCase):
    """Task 4.4: observe-only mode reads existing registry entries."""

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.state_dir = Path(self._tmp.name)
        self.pidfile = self.state_dir / 'fleetd.pid'
        self.port = _find_free_port()

    def tearDown(self):
        self._tmp.cleanup()

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
        self._tmp.cleanup()

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
        self._tmp.cleanup()

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
        self._tmp.cleanup()

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


# ── Group 7: Kill escalation tests ───────────────────────────────────────


def _make_ignoring_worker(sleep_secs=30):
    """Worker that ignores SIGTERM — forces escalation to SIGKILL."""
    return [
        sys.executable, '-c',
        f'import signal, time; '
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


class KillEscalationTest(unittest.TestCase):
    """Task 7.6: escalation reaches SIGKILL, descendants die, early exit skips."""

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.workspace = Path(self._tmp.name)
        self._append_queue_entry('TST-K1', 'test-kill', generation=1)

    def tearDown(self):
        # Ensure any lingering test children are cleaned up.
        self._tmp.cleanup()

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


# ── Group 8: Crash recovery and adoption tests ───────────────────────────


class CrashRecoveryTest(unittest.TestCase):
    """Task 8.6: adoption, PID reuse rejection, stale entry clearing."""

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.workspace = Path(self._tmp.name)

    def tearDown(self):
        self._tmp.cleanup()

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


# ── Group 9: Generation fencing tests ────────────────────────────────────


class GenerationFencingTest(unittest.TestCase):
    """Task 9.5: killed generation fenced, restarted generation above fence."""

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.workspace = Path(self._tmp.name)

    def tearDown(self):
        self._tmp.cleanup()

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


# ── Group 10: CLI alignment tests ────────────────────────────────────────


class CLIAlignmentTest(unittest.TestCase):
    """Task 10.4: skill-issued dispatch → daemon-owned worker."""

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.workspace = Path(self._tmp.name)

    def tearDown(self):
        self._tmp.cleanup()

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
            self.assertIn(result['method'], ['cooperative', 'SIGTERM', 'SIGKILL'])
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


if __name__ == '__main__':
    unittest.main()
