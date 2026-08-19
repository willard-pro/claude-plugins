"""
Tests for fleetd's worker-status API and dispatch/stop control surface.

Covers:
- Detection cycle wiring of phase/anomalies into worker records
- Token-sum and confidence readers
- dispatch_epic (stub and real-bash paths), incl. concurrent dispatch
- stop_epic (purge/kill/stop-file, idempotency)
- HTTP routes: GET /health, /workers, /workers/<tid>, /queue, /epics;
  POST /dispatch, /stop

Run:
    python -m pytest fleet-controller/fleetd/tests/test_worker_status_api.py -v
"""

import http.client
import http.server
import json
import os
import subprocess
import tempfile
import threading
import time
import unittest
import urllib.parse
from datetime import datetime, timezone
from pathlib import Path
from unittest.mock import patch

FLEETD_DIR = Path(__file__).resolve().parent.parent
FLEET_CONTROLLER_DIR = FLEETD_DIR.parent
REAL_LIB = FLEET_CONTROLLER_DIR / 'lib'


# ── helpers ────────────────────────────────────────────────────────────────

def _make_supervisor(state_dir, fleet_lib_dir=None, spawn_enabled=False):
    from fleetd.supervisor import Supervisor
    return Supervisor(
        state_dir=str(state_dir),
        pidfile=str(Path(state_dir) / 'test.pid'),
        port=0,
        fleet_lib_dir=str(fleet_lib_dir or REAL_LIB),
        spawn_enabled=spawn_enabled,
    )


class _FakeDetection:
    """Stands in for DetectionCycle — returns a canned result."""
    last_error = None

    def __init__(self, result):
        self._result = result

    def run(self, workspace, cache=None):
        return self._result


def _write_stub_dispatch(lib_dir):
    """A minimal fleet-dispatch.sh for fast unit tests (no Linear)."""
    (lib_dir / 'fleet-dispatch.sh').write_text('''fleet_dispatch_initiative() {
  echo "fleet_dispatch: validating initiative $1"
  if [ "${FLEET_DRY_RUN:-false}" = "true" ]; then
    echo '[DRY-RUN] would enqueue: {"tid":"CRE-101","reason":"planned-dispatch from '"$1"'"}'
    echo "[DRY-RUN] would enqueue 1 ticket(s) for $1"
    return 0
  fi
  local queue_file="${FLEET_STATE_DIR}/fleet-default-spawn-queue.jsonl"
  if [ -f "$queue_file" ] && grep -q CRE-101 "$queue_file" 2>/dev/null; then
    echo "  skip CRE-101 (already queued)"
  else
    echo '{"tid":"CRE-101","reason":"planned-dispatch from '"$1"'","timestamp":"2026-08-18T00:00:00Z","restarts":0,"dispatch_type":"initial","generation":1}' >>"$queue_file"
    echo "  enqueued CRE-101 (priority=1)"
  fi
  echo "fleet_dispatch: enqueued ticket(s) for $1"
}

fleet_stop_initiative() {
  local queue_file="${FLEET_STATE_DIR}/fleet-default-spawn-queue.jsonl"
  local purged="[]"
  if [ -f "$queue_file" ] && grep -q CRE-101 "$queue_file" 2>/dev/null; then
    rm -f "$queue_file"
    purged='["CRE-101"]'
  fi
  echo '{"initiative_id":"'"$1"'","stopped_at":"2026-08-18T00:00:00Z","reason":"'"$2"'","tickets":["CRE-101"]}' >"${FLEET_STATE_DIR}/stop-$1.json"
  echo "STOP_RESULT|purged=${purged}|killed=[]"
}
''')


def _write_stub_feedback(lib_dir, value='0.9'):
    (lib_dir / 'fleet-feedback.sh').write_text(
        '_fleet_confidence_predicted() { echo "%s"; }\n' % value)


class _LinearStubHandler(http.server.BaseHTTPRequestHandler):
    response = None

    def do_POST(self):
        length = int(self.headers.get('Content-Length', '0') or '0')
        self.rfile.read(length)
        body = json.dumps(self.response).encode('utf-8')
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


class _LinearStub:
    """Serves a canned Linear GraphQL response for real-bash dispatch tests."""

    def __init__(self, response):
        self.httpd = http.server.HTTPServer(('127.0.0.1', 0), _LinearStubHandler)
        _LinearStubHandler.response = response
        self.port = self.httpd.server_address[1]
        self.thread = threading.Thread(
            target=self.httpd.serve_forever, daemon=True)
        self.thread.start()

    def close(self):
        self.httpd.shutdown()
        self.httpd.server_close()


def _epic_response(epic_id, children):
    return {'data': {'issue': {
        'id': 'epic-uuid',
        'identifier': epic_id,
        'title': 'Initiative',
        'description': '',
        'state': {'name': 'Execution'},
        'labels': {'nodes': [{'name': 'state:execution'}]},
        'children': {'nodes': [{
            'id': 'child-%d' % i,
            'identifier': c['tid'],
            'title': 'child',
            'state': {'name': 'Backlog'},
            'labels': {'nodes': [{'name': 'planned'}]},
            'priority': c.get('priority', 3),
        } for i, c in enumerate(children)]},
    }}}


def _write_queue_entry(state, tid, epic_id):
    queue = state / 'fleet-default-spawn-queue.jsonl'
    entry = {
        'tid': tid,
        'reason': 'planned-dispatch from %s' % epic_id,
        'timestamp': '2026-08-18T00:00:00Z',
        'restarts': 0,
        'dispatch_type': 'initial',
        'generation': 1,
    }
    with open(queue, 'a') as f:
        f.write(json.dumps(entry) + '\n')
    return queue


# ── 2.4: detection-cycle wiring ────────────────────────────────────────────

class TestWorkerEnrichment(unittest.TestCase):

    def test_detection_cycle_wires_phase_and_anomalies(self):
        from fleetd.supervisor import Supervisor
        with tempfile.TemporaryDirectory() as tmp:
            state = Path(tmp)
            sup = _make_supervisor(state)
            sup._children.add('CRE-101', pid=99999,
                              reason='planned-dispatch from INIT-42')
            sup._detection = _FakeDetection({
                'summary': {'total': 1},
                'pipelines': [
                    {'tid': 'CRE-101', 'phase': 'ticket-implement',
                     'severity': 1, 'anomalies': 'stall(S1)', 'hb_age_secs': 30},
                    {'tid': 'CRE-999', 'phase': 'ticket-appraise',
                     'severity': 0, 'anomalies': 'none', 'hb_age_secs': 0},
                ],
            })
            sup.run_detection_cycle()

            child = sup._children.get('CRE-101')
            self.assertEqual(child['phase'], 'ticket-implement')
            self.assertEqual(child['anomalies'], 'stall(S1)')

            # Unknown tid is a no-op — not an error, not added to the table.
            self.assertIsNone(sup._children.get('CRE-999'))

            workers = sup._health_state['workers']
            self.assertEqual(workers[0]['tid'], 'CRE-101')
            self.assertEqual(workers[0]['anomalies'], 'stall(S1)')

    def test_none_anomalies_normalized_to_empty(self):
        from fleetd.supervisor import Supervisor
        with tempfile.TemporaryDirectory() as tmp:
            state = Path(tmp)
            sup = _make_supervisor(state)
            sup._children.add('CRE-101', pid=99999)
            sup._detection = _FakeDetection({
                'summary': {'total': 1},
                'pipelines': [
                    {'tid': 'CRE-101', 'phase': 'ticket-appraise',
                     'severity': 0, 'anomalies': 'none', 'hb_age_secs': 0},
                ],
            })
            sup.run_detection_cycle()
            self.assertEqual(sup._children.get('CRE-101')['anomalies'], '')

    def test_no_detection_cycle_yet_defaults(self):
        """A freshly spawned worker has empty phase/anomalies, no error."""
        from fleetd.supervisor import Supervisor
        with tempfile.TemporaryDirectory() as tmp:
            state = Path(tmp)
            sup = _make_supervisor(state)
            sup._children.add('CRE-101', pid=99999)
            child = sup._children.get('CRE-101')
            self.assertEqual(child['phase'], '')
            self.assertEqual(child['anomalies'], '')


# ── 3.x: token-sum and confidence readers ──────────────────────────────────

class TestTokenAndConfidenceReaders(unittest.TestCase):

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.state = Path(self._tmp.name)

    def tearDown(self):
        self._tmp.cleanup()

    def _write_log(self, tid, lines):
        log = self.state / f'{tid}-pipeline.log'
        log.write_text('\n'.join(lines) + '\n')
        return log

    def test_sum_tokens_across_phases(self):
        from fleetd.supervisor import _sum_tokens
        log = self._write_log('CRE-101', [
            '2026-08-18T00:00:00Z|META|tokens|info|APPRAISE:100/200/10',
            '2026-08-18T00:01:00Z|META|tokens|info|IMPLEMENT:50/60/5|elapsed_ms=1000',
            '2026-08-18T00:02:00Z|META|outcome-label|info|Smooth',
        ])
        self.assertEqual(_sum_tokens(log), 100 + 200 + 10 + 50 + 60 + 5)

    def test_sum_tokens_no_entries_zero(self):
        from fleetd.supervisor import _sum_tokens
        log = self._write_log('CRE-101', [
            '2026-08-18T00:00:00Z|META|outcome-label|info|Smooth',
        ])
        self.assertEqual(_sum_tokens(log), 0)

    def test_sum_tokens_missing_log_zero(self):
        from fleetd.supervisor import _sum_tokens
        self.assertEqual(_sum_tokens(self.state / 'NOPE-1-pipeline.log'), 0)

    def test_sum_tokens_malformed_payload_skipped(self):
        from fleetd.supervisor import _sum_tokens
        log = self._write_log('CRE-101', [
            '2026-08-18T00:00:00Z|META|tokens|info|APPRAISE:100/200/10',
            '2026-08-18T00:01:00Z|META|tokens|info|garbage-not-numeric',
        ])
        self.assertEqual(_sum_tokens(log), 310)

    def test_confidence_actual_absent_is_none(self):
        from fleetd.supervisor import _read_confidence_actual
        log = self._write_log('CRE-101', [
            '2026-08-18T00:00:00Z|META|tokens|info|APPRAISE:1/2/3',
        ])
        self.assertIsNone(_read_confidence_actual(log))

    def test_confidence_actual_present(self):
        from fleetd.supervisor import _read_confidence_actual
        log = self._write_log('CRE-101', [
            '2026-08-18T00:00:00Z|META|planner-feedback|info|'
            '{"initiative_id":"INIT-42","confidence_actual":0.85}',
        ])
        self.assertEqual(_read_confidence_actual(log), 0.85)

    def test_confidence_actual_malformed_payload_none(self):
        from fleetd.supervisor import _read_confidence_actual
        log = self._write_log('CRE-101', [
            '2026-08-18T00:00:00Z|META|planner-feedback|info|not json at all',
        ])
        self.assertIsNone(_read_confidence_actual(log))

    def test_confidence_predicted_via_stub_script(self):
        from fleetd.supervisor import _read_confidence_predicted
        with tempfile.TemporaryDirectory() as tmp:
            lib = Path(tmp)
            _write_stub_feedback(lib, '0.9')
            self.assertEqual(
                _read_confidence_predicted('CRE-101', lib), 0.9)

    def test_confidence_predicted_missing_script_none(self):
        from fleetd.supervisor import _read_confidence_predicted
        with tempfile.TemporaryDirectory() as tmp:
            self.assertIsNone(
                _read_confidence_predicted('CRE-101', Path(tmp)))

    def test_confidence_predicted_garbage_none(self):
        from fleetd.supervisor import _read_confidence_predicted
        with tempfile.TemporaryDirectory() as tmp:
            lib = Path(tmp)
            _write_stub_feedback(lib, 'not-a-number')
            self.assertIsNone(
                _read_confidence_predicted('CRE-101', lib))


# ── 4.x / 5.x: dispatch_epic — stub and real-bash paths ────────────────────

class TestDispatchEpic(unittest.TestCase):

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.state = Path(self._tmp.name) / 'state'
        self.state.mkdir()

    def tearDown(self):
        self._tmp.cleanup()

    def test_dispatch_epic_stub_script(self):
        from fleetd.supervisor import Supervisor
        with tempfile.TemporaryDirectory() as tmp:
            lib = Path(tmp)
            _write_stub_dispatch(lib)
            sup = _make_supervisor(self.state, fleet_lib_dir=lib)
            result = sup.dispatch_epic('INIT-42')
            self.assertEqual(result['queued'], ['CRE-101'])
            self.assertEqual(result['spawned'], [])  # spawn disabled
            self.assertIn('fleet_dispatch', result['message'])

            # Second dispatch — stub dedup: nothing new queued.
            result2 = sup.dispatch_epic('INIT-42')
            self.assertEqual(result2['queued'], [])

    def test_dispatch_epic_dry_run_stub(self):
        from fleetd.supervisor import Supervisor
        with tempfile.TemporaryDirectory() as tmp:
            lib = Path(tmp)
            _write_stub_dispatch(lib)
            sup = _make_supervisor(self.state, fleet_lib_dir=lib)
            result = sup.dispatch_epic('INIT-42', dry_run=True)
            self.assertEqual(result['queued'], ['CRE-101'])
            self.assertEqual(result['spawned'], [])
            # Stub only writes the queue file on non-dry paths.
            queue = self.state / 'fleet-default-spawn-queue.jsonl'
            self.assertFalse(queue.exists())

    def test_dispatch_epic_real_bash(self):
        """End-to-end: real fleet_dispatch_initiative against a stub Linear."""
        from fleetd.supervisor import Supervisor
        with tempfile.TemporaryDirectory() as repos:
            stub = _LinearStub(_epic_response('INIT-42', [
                {'tid': 'CRE-101'}, {'tid': 'CRE-102'}]))
            try:
                sup = _make_supervisor(self.state)
                with patch.dict(os.environ, {
                    'LINEAR_API_URL': 'http://127.0.0.1:%d/graphql' % stub.port,
                    'REPOS_ROOT': str(repos),
                    'FLEET_KILL_GRACE_SECS': '1',
                }):
                    result = sup.dispatch_epic('INIT-42')
                self.assertEqual(sorted(result['queued']),
                                 ['CRE-101', 'CRE-102'])
                self.assertEqual(result['spawned'], [])
                queue = self.state / 'fleet-default-spawn-queue.jsonl'
                lines = [json.loads(line) for line in
                         queue.read_text().splitlines() if line.strip()]
                self.assertEqual(len(lines), 2)
                for line in lines:
                    self.assertTrue(json.dumps(line))  # valid JSON
            finally:
                stub.close()

    def test_dispatch_respects_stop_file_real_bash(self):
        from fleetd.supervisor import Supervisor
        with tempfile.TemporaryDirectory() as repos:
            stub = _LinearStub(_epic_response('INIT-42', [
                {'tid': 'CRE-101'}]))
            try:
                sup = _make_supervisor(self.state)
                stop_file = self.state / 'stop-INIT-42.json'
                stop_file.write_text(json.dumps({
                    'initiative_id': 'INIT-42',
                    'stopped_at': '2026-08-18T00:00:00Z',
                    'reason': 'operator',
                    'tickets': ['CRE-101'],
                }))
                env = {
                    'LINEAR_API_URL': 'http://127.0.0.1:%d/graphql' % stub.port,
                    'REPOS_ROOT': str(repos),
                }
                with patch.dict(os.environ, env):
                    result = sup.dispatch_epic('INIT-42')
                self.assertEqual(result['queued'], [])
                self.assertIn('stopped', result['message'])
                self.assertTrue(stop_file.exists())

                # resume clears the stop-file and dispatches.
                with patch.dict(os.environ, env):
                    result = sup.dispatch_epic('INIT-42', resume=True)
                self.assertEqual(result['queued'], ['CRE-101'])
                self.assertFalse(stop_file.exists())
            finally:
                stub.close()

    def test_stop_file_inert_to_other_epics(self):
        """A stop-file for one epic never gates another epic's dispatch."""
        from fleetd.supervisor import Supervisor
        with tempfile.TemporaryDirectory() as tmp:
            lib = Path(tmp)
            _write_stub_dispatch(lib)
            sup = _make_supervisor(self.state, fleet_lib_dir=lib)
            (self.state / 'stop-INIT-43.json').write_text(json.dumps({
                'initiative_id': 'INIT-43', 'stopped_at': 'x',
                'reason': '', 'tickets': []}))
            result = sup.dispatch_epic('INIT-42')
            self.assertEqual(result['queued'], ['CRE-101'])

    def test_concurrent_dispatch_no_torn_queue(self):
        """Two concurrent dispatches of the same epic → one entry per ticket."""
        from fleetd.supervisor import Supervisor
        with tempfile.TemporaryDirectory() as repos:
            stub = _LinearStub(_epic_response('INIT-42', [
                {'tid': 'CRE-101'}, {'tid': 'CRE-102'}]))
            try:
                sup = _make_supervisor(self.state)
                env = {
                    'LINEAR_API_URL': 'http://127.0.0.1:%d/graphql' % stub.port,
                    'REPOS_ROOT': str(repos),
                }
                stop = threading.Event()
                results = []

                def _dispatch():
                    with patch.dict(os.environ, env):
                        results.append(sup.dispatch_epic('INIT-42'))
                    stop.set()

                def _detect():
                    while not stop.is_set():
                        sup.run_detection_cycle()
                        time.sleep(0.05)

                threads = [threading.Thread(target=_dispatch) for _ in range(2)]
                detector = threading.Thread(target=_detect)
                detector.start()
                for t in threads:
                    t.start()
                for t in threads:
                    t.join(timeout=30)
                stop.set()
                detector.join(timeout=10)

                queue = self.state / 'fleet-default-spawn-queue.jsonl'
                lines = [line for line in
                         queue.read_text().splitlines() if line.strip()]
                tids = [json.loads(line)['tid'] for line in lines]
                self.assertEqual(sorted(tids), ['CRE-101', 'CRE-102'])
                self.assertEqual(len(tids), len(set(tids)))  # no duplicates
            finally:
                stub.close()


# ── 8.x: stop_epic ─────────────────────────────────────────────────────────

class TestStopEpic(unittest.TestCase):

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.state = Path(self._tmp.name) / 'state'
        self.state.mkdir()

    def tearDown(self):
        self._tmp.cleanup()

    def test_stop_epic_purges_kills_and_writes_stop_file(self):
        from fleetd.supervisor import Supervisor
        # Queued ticket + live running worker, both from INIT-42.
        _write_queue_entry(self.state, 'CRE-101', 'INIT-42')
        proc = subprocess.Popen(['sleep', '300'])
        try:
            run_file = self.state / 'CRE-102-run.json'
            run_file.write_text(json.dumps({
                'tid': 'CRE-102',
                'pid': str(proc.pid),
                'generation': 1,
                # UTC, matching _write_run_registry — the kill escalation's
                # PID-reuse guard compares this against ps lstart.
                'started_at': datetime.now(timezone.utc).strftime(
                    '%Y-%m-%dT%H:%M:%SZ'),
                'reason': 'planned-dispatch from INIT-42',
            }))
            (self.state / 'CRE-102-pipeline.log').write_text(
                '2026-08-18T00:00:00Z|META|ticket-claimed|info|CRE-102\n')

            sup = _make_supervisor(self.state)
            sup._children.add('CRE-102', pid=proc.pid, generation=1,
                              reason='planned-dispatch from INIT-42')

            with patch.dict(os.environ, {'FLEET_KILL_GRACE_SECS': '1'}):
                result = sup.stop_epic('INIT-42', 'operator says stop')

            self.assertEqual(result['purged'], ['CRE-101'])
            # killed OR pinned carries CRE-102 — the escalation cannot always
            # verify death before returning (rc=3 "survived" race); exactly
            # one of the two lists reports it, and the stop-file union pins
            # it either way. `killed` must never lie about a live worker.
            self.assertEqual(
                set(result['killed']) ^ set(result['pinned']), {'CRE-102'})

            # Worker process escalated to termination.
            proc.wait(timeout=15)
            self.assertIsNotNone(proc.poll())

            # Stop-file written with the union.
            stop_file = self.state / 'stop-INIT-42.json'
            self.assertTrue(stop_file.exists())
            stop_data = json.loads(stop_file.read_text())
            self.assertEqual(stop_data['initiative_id'], 'INIT-42')
            self.assertEqual(stop_data['reason'], 'operator says stop')
            self.assertEqual(sorted(stop_data['tickets']),
                             ['CRE-101', 'CRE-102'])

            # Child-table drop only happens on a verified-dead pid — covered
            # deterministically in test_stop_epic_child_table_liveness_gate.

            # Queue entry purged.
            queue = self.state / 'fleet-default-spawn-queue.jsonl'
            self.assertFalse(queue.exists())

            # Idempotent second stop.
            with patch.dict(os.environ, {'FLEET_KILL_GRACE_SECS': '1'}):
                result2 = sup.stop_epic('INIT-42', 'again')
            self.assertEqual(result2['purged'], [])
            self.assertEqual(result2['killed'], [])
            # Dead worker is re-pinned (not re-killed) on re-stop.
            self.assertEqual(result2['pinned'], ['CRE-102'])
            # Existing pinned tickets are preserved across re-stop.
            stop_data2 = json.loads(stop_file.read_text())
            self.assertEqual(sorted(stop_data2['tickets']),
                             ['CRE-101', 'CRE-102'])
        finally:
            if proc.poll() is None:
                proc.kill()
            proc.wait(timeout=10)


# ── 9.x: reconciliation pin collection ─────────────────────────────────────

class TestStopPinnedTids(unittest.TestCase):

    def test_collect_stop_pinned_tids(self):
        from fleetd.supervisor import _collect_stop_pinned_tids
        with tempfile.TemporaryDirectory() as tmp:
            state = Path(tmp)
            (state / 'stop-INIT-42.json').write_text(json.dumps({
                'initiative_id': 'INIT-42',
                'tickets': ['CRE-101', 'CRE-102'],
            }))
            (state / 'stop-INIT-43.json').write_text(json.dumps({
                'initiative_id': 'INIT-43',
                'tickets': ['CRE-103', 'CRE-101'],
            }))
            (state / 'stop-BROKEN.json').write_text('not json')
            pinned = _collect_stop_pinned_tids(state)
            self.assertEqual(pinned, {'CRE-101', 'CRE-102', 'CRE-103'})

    def test_collect_no_stop_files_empty(self):
        from fleetd.supervisor import _collect_stop_pinned_tids
        with tempfile.TemporaryDirectory() as tmp:
            self.assertEqual(_collect_stop_pinned_tids(Path(tmp)), set())


# ── HTTP routes ────────────────────────────────────────────────────────────

class TestHttpRoutes(unittest.TestCase):

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.state = Path(self._tmp.name) / 'state'
        self.state.mkdir()
        self.lib = Path(self._tmp.name) / 'lib'
        self.lib.mkdir()
        _write_stub_dispatch(self.lib)
        _write_stub_feedback(self.lib)

        from fleetd.supervisor import Supervisor, HealthServer
        self.sup = Supervisor(
            state_dir=str(self.state),
            pidfile=str(self.state / 'test.pid'),
            port=0,
            fleet_lib_dir=str(self.lib),
            spawn_enabled=False,
        )
        self.server = HealthServer('127.0.0.1', 0)
        self.server.start(self.sup)
        self.port = self.server._httpd.server_address[1]

    def tearDown(self):
        self.server.shutdown()
        self._tmp.cleanup()

    def _get(self, path):
        conn = http.client.HTTPConnection('127.0.0.1', self.port, timeout=5)
        conn.request('GET', path)
        resp = conn.getresponse()
        body = resp.read()
        conn.close()
        try:
            return resp.status, json.loads(body)
        except json.JSONDecodeError:
            return resp.status, None

    def _post(self, path, payload=None):
        conn = http.client.HTTPConnection('127.0.0.1', self.port, timeout=5)
        body = json.dumps(payload or {}).encode('utf-8')
        conn.request('POST', path, body=body,
                     headers={'Content-Type': 'application/json'})
        resp = conn.getresponse()
        data = resp.read()
        conn.close()
        try:
            return resp.status, json.loads(data)
        except json.JSONDecodeError:
            return resp.status, None

    def _write_pipeline_log(self, tid, lines):
        log = self.state / f'{tid}-pipeline.log'
        log.write_text('\n'.join(lines) + '\n')
        return log

    def test_health_shape(self):
        status, payload = self._get('/health')
        self.assertEqual(status, 200)
        for field in ('workers', 'worker_count', 'queue_depth', 'last_cycle_at',
                      'last_cycle_success', 'last_cycle_error', 'cycle_count',
                      'last_summary', 'pipeline_count'):
            self.assertIn(field, payload)

    def test_worker_status_happy_path(self):
        self.sup._children.add('CRE-101', pid=99999,
                               reason='planned-dispatch from INIT-42')
        self._write_pipeline_log('CRE-101', [
            '2026-08-18T00:00:00Z|META|tokens|info|APPRAISE:100/200/10',
            '2026-08-18T00:01:00Z|META|planner-feedback|info|'
            '{"initiative_id":"INIT-42","confidence_actual":0.85}',
        ])
        status, payload = self._get('/workers/CRE-101')
        self.assertEqual(status, 200)
        self.assertEqual(payload['tid'], 'CRE-101')
        self.assertEqual(payload['pid'], 99999)
        self.assertEqual(payload['tokens_used_so_far'], 310)
        self.assertEqual(payload['confidence_predicted'], 0.9)
        self.assertEqual(payload['confidence_actual'], 0.85)

    def test_worker_status_confidence_actual_null(self):
        self.sup._children.add('CRE-101', pid=99999)
        self._write_pipeline_log('CRE-101', [
            '2026-08-18T00:00:00Z|META|tokens|info|APPRAISE:1/2/3',
        ])
        status, payload = self._get('/workers/CRE-101')
        self.assertEqual(status, 200)
        self.assertIsNone(payload['confidence_actual'])

    def test_worker_status_unknown_404(self):
        status, payload = self._get('/workers/CRE-999')
        self.assertEqual(status, 404)

    def test_worker_list_empty_and_populated(self):
        status, payload = self._get('/workers')
        self.assertEqual(status, 200)
        self.assertEqual(payload, [])

        self.sup._children.add('CRE-101', pid=99999,
                               reason='planned-dispatch from INIT-42')
        status, payload = self._get('/workers')
        self.assertEqual(status, 200)
        self.assertEqual([w['tid'] for w in payload], ['CRE-101'])
        single = self._get('/workers/CRE-101')[1]
        self.assertEqual(payload[0], single)  # same fields as per-worker

    def test_post_dispatch_happy(self):
        status, payload = self._post('/dispatch', {'epic_id': 'INIT-42'})
        self.assertEqual(status, 200)
        self.assertEqual(payload['queued'], ['CRE-101'])
        self.assertEqual(payload['spawned'], [])
        queue = self.state / 'fleet-default-spawn-queue.jsonl'
        self.assertTrue(queue.exists())

    def test_post_dispatch_missing_epic_id_400(self):
        status, payload = self._post('/dispatch', {})
        self.assertEqual(status, 400)
        self.assertIn('epic_id', payload['error'])
        queue = self.state / 'fleet-default-spawn-queue.jsonl'
        self.assertFalse(queue.exists())

    def test_post_dispatch_dry_run(self):
        status, payload = self._post(
            '/dispatch', {'epic_id': 'INIT-42', 'dry_run': True})
        self.assertEqual(status, 200)
        self.assertEqual(payload['queued'], ['CRE-101'])
        queue = self.state / 'fleet-default-spawn-queue.jsonl'
        self.assertFalse(queue.exists())

    def test_post_stop_happy_and_idempotent(self):
        _write_queue_entry(self.state, 'CRE-101', 'INIT-42')
        status, payload = self._post(
            '/stop', {'epic_id': 'INIT-42', 'reason': 'operator'})
        self.assertEqual(status, 200)
        self.assertEqual(payload['purged'], ['CRE-101'])
        self.assertEqual(payload['killed'], [])
        stop_file = self.state / 'stop-INIT-42.json'
        self.assertTrue(stop_file.exists())

        # Second stop — idempotent, empty lists.
        status, payload2 = self._post('/stop', {'epic_id': 'INIT-42'})
        self.assertEqual(status, 200)
        self.assertEqual(payload2['purged'], [])
        self.assertEqual(payload2['killed'], [])

    def test_post_stop_missing_epic_id_400(self):
        status, payload = self._post('/stop', {})
        self.assertEqual(status, 400)
        self.assertFalse((self.state / 'stop-.json').exists())

    # ── injection / validation guards (fix 1) ────────────────────────────

    def test_post_dispatch_invalid_epic_id_rejected(self):
        # Shell-injection-shaped epic_id must be rejected before it reaches
        # any bash subprocess or file path.
        marker = self.state / 'injection-marker'
        status, payload = self._post(
            '/dispatch',
            {'epic_id': 'INIT-42"; touch %s; echo "' % marker})
        self.assertEqual(status, 400)
        self.assertIn('invalid epic_id', payload['error'])
        self.assertFalse(marker.exists())
        self.assertFalse(
            (self.state / 'fleet-default-spawn-queue.jsonl').exists())

    def test_post_stop_invalid_epic_id_rejected(self):
        marker = self.state / 'injection-marker'
        status, payload = self._post(
            '/stop',
            {'epic_id': 'INIT-42"; touch %s; echo "' % marker})
        self.assertEqual(status, 400)
        self.assertIn('invalid epic_id', payload['error'])
        self.assertFalse(marker.exists())
        self.assertFalse((self.state / 'stop-INIT-42.json').exists())

    def test_post_stop_reason_none_normalized(self):
        # JSON null reason must not become the literal "None" string.
        _write_queue_entry(self.state, 'CRE-101', 'INIT-42')
        status, payload = self._post(
            '/stop', {'epic_id': 'INIT-42', 'reason': None})
        self.assertEqual(status, 200)
        stop_file = self.state / 'stop-INIT-42.json'
        self.assertTrue(stop_file.exists())
        stop_data = json.loads(stop_file.read_text())
        self.assertEqual(stop_data['reason'], '')

    def test_worker_status_invalid_tid_rejected(self):
        marker = self.state / 'injection-marker'
        path = '/workers/' + urllib.parse.quote(
            'CRE-101"; touch %s; echo "' % marker, safe='')
        status, _ = self._get(path)
        self.assertEqual(status, 400)
        self.assertFalse(marker.exists())

    def test_worker_status_query_string_stripped(self):
        self.sup._children.add('CRE-101', pid=99999,
                               reason='planned-dispatch from INIT-42')
        status, payload = self._get('/workers/CRE-101?x=1')
        self.assertEqual(status, 200)
        self.assertEqual(payload['tid'], 'CRE-101')

    def test_queue_endpoint_with_malformed_line(self):
        queue = self.state / 'fleet-default-spawn-queue.jsonl'
        queue.write_text(
            json.dumps({'tid': 'CRE-101', 'reason': 'x'}) + '\n'
            + '{"torn": "json" garbage\n'
            + json.dumps({'tid': 'CRE-102', 'reason': 'y'}) + '\n')
        status, payload = self._get('/queue')
        self.assertEqual(status, 200)
        self.assertEqual(len(payload['entries']), 2)
        self.assertEqual(len(payload['malformed']), 1)

    def test_queue_endpoint_missing_file(self):
        status, payload = self._get('/queue')
        self.assertEqual(status, 200)
        self.assertEqual(payload['entries'], [])
        self.assertEqual(payload['malformed'], [])

    def test_epics_endpoint(self):
        # Stopped epic + queued entry + running worker across two epics.
        (self.state / 'stop-INIT-42.json').write_text(json.dumps({
            'initiative_id': 'INIT-42', 'stopped_at': '2026-08-18T00:00:00Z',
            'reason': 'operator', 'tickets': ['CRE-101']}))
        _write_queue_entry(self.state, 'CRE-103', 'INIT-43')
        self.sup._children.add('CRE-104', pid=99999,
                               reason='planned-dispatch from INIT-43')
        status, payload = self._get('/epics')
        self.assertEqual(status, 200)
        by_id = {e['epic_id']: e for e in payload}
        self.assertEqual(sorted(by_id), ['INIT-42', 'INIT-43'])
        self.assertTrue(by_id['INIT-42']['stopped'])
        self.assertEqual(by_id['INIT-42']['tickets'], ['CRE-101'])
        self.assertEqual(by_id['INIT-43']['queued'], ['CRE-103'])
        self.assertEqual(by_id['INIT-43']['running'], ['CRE-104'])

    def test_epics_endpoint_empty(self):
        status, payload = self._get('/epics')
        self.assertEqual(status, 200)
        self.assertEqual(payload, [])

    def test_unknown_paths_404(self):
        self.assertEqual(self._get('/bogus')[0], 404)
        self.assertEqual(self._post('/bogus')[0], 404)


# ── regression tests for the review findings ────────────────────────────────

class TestStopEpicLivenessGate(unittest.TestCase):
    """F3: a `killed` report must never orphan a live worker."""

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.state = Path(self._tmp.name) / 'state'
        self.state.mkdir()

    def tearDown(self):
        self._tmp.cleanup()

    def _run_stop(self, pid_alive):
        sup = _make_supervisor(self.state)
        sup._children.add('CRE-102', pid=12345, generation=1,
                          reason='planned-dispatch from INIT-42')
        stdout = 'STOP_RESULT|purged=[]|killed=["CRE-102"]|pinned=[]\n'
        with patch('fleetd.supervisor._pid_is_alive',
                   return_value=pid_alive), \
             patch.object(sup, '_bash_dispatch',
                          return_value=(0, stdout, '')):
            result = sup.stop_epic('INIT-42', 'test')
        return sup, result

    def test_live_worker_kept_in_child_table(self):
        # Bash reported `killed` but the pid is still alive — the daemon
        # must keep supervising it rather than trusting the report.
        sup, result = self._run_stop(pid_alive=True)
        self.assertEqual(result['killed'], ['CRE-102'])
        self.assertIsNotNone(sup._children.get('CRE-102'))

    def test_dead_worker_dropped_from_child_table(self):
        sup, result = self._run_stop(pid_alive=False)
        self.assertEqual(result['killed'], ['CRE-102'])
        self.assertIsNone(sup._children.get('CRE-102'))


class TestDispatchLockRelease(unittest.TestCase):
    """F4: dispatch must not hold _state_lock across the bash subprocess."""

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.state = Path(self._tmp.name) / 'state'
        self.state.mkdir()

    def tearDown(self):
        self._tmp.cleanup()

    def test_dispatch_releases_state_lock_during_subprocess(self):
        sup = _make_supervisor(self.state)
        entered = threading.Event()
        release = threading.Event()

        def _slow_dispatch(cmd, timeout=300, extra_env=None):
            entered.set()
            release.wait(timeout=10)
            return 0, '', ''

        with patch.object(sup, '_bash_dispatch', side_effect=_slow_dispatch):
            t = threading.Thread(target=sup.dispatch_epic, args=('INIT-42',))
            t.start()
            self.assertTrue(entered.wait(timeout=5),
                            'dispatch subprocess never started')
            # Main-loop operations (reap, kill-requests, queue consume) all
            # need this lock — it must be free while the subprocess runs.
            self.assertTrue(sup._state_lock.acquire(timeout=2),
                            '_state_lock held during bash subprocess')
            sup._state_lock.release()
            release.set()
            t.join(timeout=10)
        self.assertFalse(t.is_alive())


class TestConsumeQueueStopPinned(unittest.TestCase):
    """F6: queue consumption must never spawn a stop-pinned ticket."""

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.state = Path(self._tmp.name) / 'state'
        self.state.mkdir()

    def tearDown(self):
        self._tmp.cleanup()

    def test_consume_queue_skips_stop_pinned_tids(self):
        (self.state / 'stop-INIT-42.json').write_text(json.dumps({
            'initiative_id': 'INIT-42', 'tickets': ['CRE-101'],
        }))
        _write_queue_entry(self.state, 'CRE-101', 'INIT-42')
        sup = _make_supervisor(self.state, spawn_enabled=True)
        spawned = []

        def _fake_spawn(**kwargs):
            spawned.append(kwargs['tid'])
            return 90000 + len(spawned)

        with patch('fleetd.supervisor.spawn_worker', side_effect=_fake_spawn):
            consumed = sup._consume_queue()
        self.assertEqual(consumed, set())
        self.assertEqual(spawned, [])
        # The entry stays queued — the pin blocks consumption, not the
        # entry itself (a later resume re-dispatches it).
        queue = self.state / 'fleet-default-spawn-queue.jsonl'
        self.assertTrue(queue.exists())

    def test_consume_queue_spawns_unpinned_tids(self):
        _write_queue_entry(self.state, 'CRE-101', 'INIT-42')
        sup = _make_supervisor(self.state, spawn_enabled=True)
        spawned = []

        def _fake_spawn(**kwargs):
            spawned.append(kwargs['tid'])
            return 90000 + len(spawned)

        with patch('fleetd.supervisor.spawn_worker', side_effect=_fake_spawn):
            consumed = sup._consume_queue()
        self.assertEqual(consumed, {'CRE-101'})
        self.assertEqual(spawned, ['CRE-101'])
        self.assertEqual(sup.child_tids(), ['CRE-101'])


class TestWorkerStatusConcurrentAccess(unittest.TestCase):
    """F5: GET-route reads must survive concurrent child-table mutation."""

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.state = Path(self._tmp.name) / 'state'
        self.state.mkdir()

    def tearDown(self):
        self._tmp.cleanup()

    def test_child_table_reads_survive_concurrent_mutation(self):
        sup = _make_supervisor(self.state)
        for i in range(30):
            sup._children.add(f'CRE-{i}', pid=90000 + i,
                              reason='planned-dispatch from INIT-42')
        stop = threading.Event()
        errors = []

        def _mutate():
            i = 0
            while not stop.is_set():
                tid = f'CRE-{i % 30}'
                if sup._children.get(tid) is not None:
                    sup._children.remove(tid)
                else:
                    sup._children.add(tid, pid=90000 + (i % 30),
                                      reason='planned-dispatch from INIT-42')
                i += 1

        def _read():
            try:
                for _ in range(300):
                    sup.child_tids()
                    sup.get_worker_status('CRE-0')
            except Exception as exc:  # RuntimeError: dict changed size
                errors.append(exc)

        mutator = threading.Thread(target=_mutate)
        reader = threading.Thread(target=_read)
        mutator.start()
        reader.start()
        reader.join(timeout=30)
        stop.set()
        mutator.join(timeout=10)
        self.assertFalse(reader.is_alive())
        self.assertEqual(errors, [])


if __name__ == '__main__':
    unittest.main()
