"""
Tests for the fleet state store (fleetd/store.py, fleetd/schema.sql).

Run:
    python3 -m pytest fleet-controller/fleetd/tests/test_store.py -v

The properties under test are the ones the store's design rests on, not its
API surface for its own sake:

- Refusing an unrecognised schema version, because a supervisor that misreads
  which processes are alive is worse than one that will not start.
- Idempotent ingestion, because projection rebuild is only safe if re-reading
  a log is a no-op.
- Rebuildability, because that is what makes deleting the database a slow cold
  start rather than data loss — and what stops the store becoming a second
  authority that can silently diverge from the log.
- Fence parity with the file-based fence it replaces.
- A reader that cannot block or corrupt the writer.
"""

import json
import os
import sqlite3
import tempfile
import threading
import time
import unittest
from pathlib import Path

from fleetd import store


PHASE_RESULT = {
    'schema_version': 1,
    'phase': 'VERIFY',
    'verifier': 'playwright_uat',
    'claimed_verdict': 'PASS',
    'criteria_met': 3,
    'criteria_total': 3,
    'attempt': 2,
    'evidence': 'all steps green',
    'unaddressed': '',
    'extra': {},
    'parse_status': 'ok',
    'parse_error': '',
}


def _pipeline_lines():
    return [
        '2026-09-03T10:00:00Z|META|schema|info|1',
        '2026-09-03T10:00:01Z|APPRAISE|appraise|waiting|Agent launched',
        '2026-09-03T10:05:00Z|APPRAISE|appraise|done|PASS — appraised',
        '2026-09-03T10:06:00Z|META|phase-result|info|' + json.dumps(PHASE_RESULT),
        # A MSG containing the field separator — split must be bounded.
        '2026-09-03T10:07:00Z|IMPLEMENT|implement|fail|error: a|b|c',
    ]


class StoreTestCase(unittest.TestCase):

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.ws = Path(self._tmp.name)
        self.log = self.ws / 'CRE-1-pipeline.log'
        self.log.write_text('\n'.join(_pipeline_lines()) + '\n')
        self.activity = self.ws / 'CRE-1-activity.log'
        self.activity.write_text(
            '2026-09-03T10:00:02Z|APPRAISE|Bash\n'
            '2026-09-03T10:00:03Z|APPRAISE|Read\n')

    def tearDown(self):
        self._tmp.cleanup()

    def _open(self):
        return store.open_store(self.ws)


# ── Schema ───────────────────────────────────────────────────────────────────

class TestSchema(StoreTestCase):

    def test_schema_is_created_on_first_open(self):
        with self._open() as st:
            self.assertEqual(st.version(), store.SCHEMA_VERSION)
            tables = {r[0] for r in st.conn.execute(
                "SELECT name FROM sqlite_master WHERE type='table'")}
        for expected in ('tickets', 'workers', 'phase_runs', 'phase_results',
                         'log_events', 'activity_events', 'schema_version'):
            self.assertIn(expected, tables)

    def test_wal_mode_is_enabled(self):
        with self._open() as st:
            mode = st.conn.execute('PRAGMA journal_mode').fetchone()[0]
        self.assertEqual(mode.lower(), 'wal')

    def test_unknown_schema_version_is_refused(self):
        with self._open() as st:
            pass
        db = store.store_path(self.ws)
        conn = sqlite3.connect(str(db))
        conn.execute('UPDATE schema_version SET version = 99 WHERE id = 1')
        conn.commit()
        conn.close()

        with self.assertRaises(store.SchemaVersionError):
            store.open_store(self.ws)

    def test_unknown_schema_version_is_refused_read_only(self):
        with self._open():
            pass
        db = store.store_path(self.ws)
        conn = sqlite3.connect(str(db))
        conn.execute('UPDATE schema_version SET version = 99 WHERE id = 1')
        conn.commit()
        conn.close()

        with self.assertRaises(store.SchemaVersionError):
            store.FleetStore(db, read_only=True).open()

    def test_reopen_at_matching_version_succeeds(self):
        with self._open():
            pass
        with self._open() as st:
            self.assertEqual(st.version(), store.SCHEMA_VERSION)

    def test_newer_version_message_names_both_and_does_not_claim_rebuildable(self):
        with self._open():
            pass
        db = store.store_path(self.ws)
        conn = sqlite3.connect(str(db))
        conn.execute('UPDATE schema_version SET version = 99 WHERE id = 1')
        conn.commit()
        conn.close()

        with self.assertRaises(store.SchemaVersionError) as ctx:
            store.open_store(self.ws)
        message = str(ctx.exception)
        self.assertIn('99', message)
        self.assertIn(str(store.SCHEMA_VERSION), message)
        self.assertNotIn('rebuild', message.lower())

    def test_missing_schema_version_row_is_refused(self):
        with self._open():
            pass
        db = store.store_path(self.ws)
        conn = sqlite3.connect(str(db))
        conn.execute('DELETE FROM schema_version')
        conn.commit()
        conn.close()

        with self.assertRaises(store.SchemaVersionError):
            store.open_store(self.ws)

    def test_equal_version_open_writes_nothing(self):
        with self._open():
            pass
        db = store.store_path(self.ws)
        before = sqlite3.connect(str(db)).execute(
            'SELECT applied_at FROM schema_version WHERE id = 1').fetchone()[0]
        with self._open():
            pass
        after = sqlite3.connect(str(db)).execute(
            'SELECT applied_at FROM schema_version WHERE id = 1').fetchone()[0]
        self.assertEqual(before, after)


# ── Forward migration ────────────────────────────────────────────────────────

class TestMigration(StoreTestCase):
    """Exercises store.py's migration machinery with a fabricated future
    version, since the real v1->v2 step is declared non-additive and never
    migrates (see TestNonAdditiveGap below)."""

    def setUp(self):
        super().setUp()
        self._orig_version = store.SCHEMA_VERSION
        self._orig_migrations = dict(store._MIGRATIONS)

    def tearDown(self):
        store.SCHEMA_VERSION = self._orig_version
        store._MIGRATIONS = self._orig_migrations
        super().tearDown()

    def _bump_to_fake_additive_version(self, statements):
        store.SCHEMA_VERSION = self._orig_version + 1
        store._MIGRATIONS = dict(self._orig_migrations)
        store._MIGRATIONS[store.SCHEMA_VERSION] = {
            'additive': True, 'statements': statements}

    def test_additive_gap_migrates_and_preserves_rows(self):
        with self._open() as st:
            st.record_position('CRE-1', 'STEP_4')

        self._bump_to_fake_additive_version(
            ["ALTER TABLE tickets ADD COLUMN fake_probe TEXT NOT NULL DEFAULT ''"])

        with store.open_store(self.ws) as st:
            self.assertEqual(st.version(), store.SCHEMA_VERSION)
            ticket = st.get_ticket('CRE-1')
            columns = {r['name'] for r in
                      st.conn.execute('PRAGMA table_info(tickets)')}
        self.assertIn('fake_probe', columns)
        self.assertEqual(ticket['position'], 'STEP_4')

    def test_migration_is_atomic_on_a_failing_step(self):
        with self._open():
            pass

        self._bump_to_fake_additive_version([
            "ALTER TABLE tickets ADD COLUMN fake_probe TEXT NOT NULL DEFAULT ''",
            'THIS IS NOT VALID SQL',
        ])

        with self.assertRaises(store.SchemaVersionError):
            store.open_store(self.ws)

        db = store.store_path(self.ws)
        conn = sqlite3.connect(str(db))
        version = conn.execute(
            'SELECT version FROM schema_version WHERE id = 1').fetchone()[0]
        columns = {r[1] for r in conn.execute('PRAGMA table_info(tickets)')}
        conn.close()
        self.assertEqual(version, self._orig_version)
        self.assertNotIn('fake_probe', columns)

    def test_migration_declaration_is_data_not_inferred(self):
        """Each version carries its own steps and additive flag; nothing
        derives additivity by diffing the live schema against schema.sql."""
        for version, decl in store._MIGRATIONS.items():
            self.assertIn('additive', decl)
            self.assertIn('statements', decl)
            self.assertIsInstance(decl['statements'], list)


class TestNonAdditiveGap(StoreTestCase):

    def test_v1_store_is_refused_with_recreate_instruction(self):
        with self._open():
            pass
        db = store.store_path(self.ws)
        conn = sqlite3.connect(str(db))
        conn.execute('UPDATE schema_version SET version = 1 WHERE id = 1')
        conn.commit()
        conn.close()

        with self.assertRaises(store.SchemaVersionError) as ctx:
            store.open_store(self.ws)
        message = str(ctx.exception)
        self.assertIn('non-additive', message)
        self.assertIn('recreated', message)
        self.assertNotIn('rebuild', message.lower())


# ── Ingestion ────────────────────────────────────────────────────────────────

class TestIngestion(StoreTestCase):

    def test_pipeline_lines_are_ingested(self):
        with self._open() as st:
            n = st.ingest_pipeline_log(self.log)
            self.assertEqual(n, 5)
            rows = list(st.conn.execute(
                'SELECT line_no, phase, step, status, msg FROM log_events '
                'ORDER BY line_no'))
        self.assertEqual(rows[1]['phase'], 'APPRAISE')
        self.assertEqual(rows[1]['status'], 'waiting')
        # MSG keeps its own separators — the split is bounded at 4.
        self.assertEqual(rows[4]['msg'], 'error: a|b|c')

    def test_reingestion_is_idempotent(self):
        with self._open() as st:
            st.ingest_pipeline_log(self.log)
            again = st.ingest_pipeline_log(self.log)
            self.assertEqual(again, 0)
            count = st.conn.execute(
                'SELECT COUNT(*) FROM log_events').fetchone()[0]
        self.assertEqual(count, 5)

    def test_reingestion_after_offset_reset_still_does_not_duplicate(self):
        with self._open() as st:
            st.ingest_pipeline_log(self.log)
            st.conn.execute('DELETE FROM ingest_state')
            st.conn.commit()
            st.ingest_pipeline_log(self.log)
            count = st.conn.execute(
                'SELECT COUNT(*) FROM log_events').fetchone()[0]
        self.assertEqual(count, 5)

    def test_appended_lines_are_picked_up_incrementally(self):
        with self._open() as st:
            st.ingest_pipeline_log(self.log)
            with open(self.log, 'a') as fh:
                fh.write('2026-09-03T10:08:00Z|VERIFY|verify|done|PASS\n')
            self.assertEqual(st.ingest_pipeline_log(self.log), 1)
            last = st.conn.execute(
                'SELECT line_no, phase FROM log_events ORDER BY line_no DESC '
                'LIMIT 1').fetchone()
        self.assertEqual(last['line_no'], 6)
        self.assertEqual(last['phase'], 'VERIFY')

    def test_partial_trailing_line_is_not_ingested_until_complete(self):
        with self._open() as st:
            st.ingest_pipeline_log(self.log)
            with open(self.log, 'a') as fh:
                fh.write('2026-09-03T10:09:00Z|VERIFY|verify|wait')
            # A line still being appended must wait for its newline rather
            # than land half-written and be permanently wrong.
            self.assertEqual(st.ingest_pipeline_log(self.log), 0)
            with open(self.log, 'a') as fh:
                fh.write('ing|Agent launched\n')
            self.assertEqual(st.ingest_pipeline_log(self.log), 1)
            last = st.conn.execute(
                'SELECT status, msg FROM log_events ORDER BY line_no DESC '
                'LIMIT 1').fetchone()
        self.assertEqual(last['status'], 'waiting')
        self.assertEqual(last['msg'], 'Agent launched')

    def test_truncated_file_is_reingested_from_the_top(self):
        with self._open() as st:
            st.ingest_pipeline_log(self.log)
            self.log.write_text('2026-09-03T11:00:00Z|APPRAISE|appraise|start|new run\n')
            st.ingest_pipeline_log(self.log)
            row = st.conn.execute(
                'SELECT msg FROM log_events WHERE line_no = 1').fetchone()
            count = st.conn.execute(
                'SELECT COUNT(*) FROM log_events').fetchone()[0]
        # Line 1 keeps the row already recorded — the UNIQUE key makes
        # re-ingestion a no-op rather than a rewrite.
        self.assertEqual(count, 5)
        self.assertEqual(row['msg'], '1')

    def test_phase_result_is_projected(self):
        with self._open() as st:
            st.ingest_pipeline_log(self.log)
            row = st.conn.execute('SELECT * FROM phase_results').fetchone()
        self.assertEqual(row['phase'], 'VERIFY')
        self.assertEqual(row['claimed_verdict'], 'PASS')
        self.assertEqual(row['attempt'], 2)
        self.assertEqual(row['parse_status'], 'ok')
        self.assertEqual(json.loads(row['raw_json'])['verifier'], 'playwright_uat')

    def test_unparseable_phase_result_is_recorded_not_dropped(self):
        with open(self.log, 'a') as fh:
            fh.write('2026-09-03T10:10:00Z|META|phase-result|info|{not json\n')
        with self._open() as st:
            st.ingest_pipeline_log(self.log)
            row = st.conn.execute(
                "SELECT * FROM phase_results WHERE parse_status = 'unreadable'"
            ).fetchone()
        # The log line exists; a projection that silently drops it would hide it.
        self.assertIsNotNone(row)
        self.assertIn('not valid JSON', row['parse_error'])

    def test_activity_lines_are_ingested(self):
        with self._open() as st:
            self.assertEqual(st.ingest_activity_log(self.activity), 2)
            rows = list(st.conn.execute(
                'SELECT phase, tool FROM activity_events ORDER BY line_no'))
        self.assertEqual([r['tool'] for r in rows], ['Bash', 'Read'])
        self.assertEqual(rows[0]['phase'], 'APPRAISE')

    def test_workspace_sweep_covers_both_log_kinds(self):
        with self._open() as st:
            counts = st.ingest_workspace(self.ws)
        self.assertEqual(counts['pipeline'], 5)
        self.assertEqual(counts['activity'], 2)

    def test_unrelated_files_are_not_ingested(self):
        (self.ws / 'CRE-1-heartbeat.log').write_text('2026-09-03T10:00:00Z|x|y\n')
        (self.ws / 'notes.md').write_text('hello\n')
        with self._open() as st:
            counts = st.ingest_workspace(self.ws)
        self.assertEqual(counts['files'], 2)

    def test_malformed_timestamp_line_is_stored_without_an_epoch(self):
        with open(self.log, 'a') as fh:
            fh.write('not-a-timestamp|IMPLEMENT|implement|done|ok\n')
        with self._open() as st:
            st.ingest_pipeline_log(self.log)
            row = st.conn.execute(
                'SELECT iso, epoch FROM log_events ORDER BY line_no DESC '
                'LIMIT 1').fetchone()
        self.assertEqual(row['iso'], 'not-a-timestamp')
        self.assertIsNone(row['epoch'])


# ── Rebuild ──────────────────────────────────────────────────────────────────

class TestRebuild(StoreTestCase):

    def test_projections_rebuild_from_logs(self):
        with self._open() as st:
            st.ingest_workspace(self.ws)
            st.conn.execute('DELETE FROM log_events')
            st.conn.commit()
            counts = st.rebuild_projections(self.ws)
            events = st.conn.execute(
                'SELECT COUNT(*) FROM log_events').fetchone()[0]
        self.assertEqual(counts['pipeline'], 5)
        self.assertEqual(events, 5)

    def test_deleted_database_recovers_in_flight_tickets(self):
        with self._open() as st:
            st.ingest_workspace(self.ws)
        store.store_path(self.ws).unlink()

        with self._open() as st:
            counts = st.ingest_workspace(self.ws)
        # A deleted store costs a cold start, not the pipeline's history.
        self.assertEqual(counts['pipeline'], 5)

    def test_rebuild_leaves_fleetd_authored_rows_alone(self):
        with self._open() as st:
            st.ingest_workspace(self.ws)
            st.record_position('CRE-1', 'STEP_4')
            st.set_hold('CRE-1', 'gate', 'hold:CRE-1:g0:a1', 'complex')
            wid = st.record_worker_spawn('CRE-1', pid=os.getpid(), generation=3)

            st.rebuild_projections(self.ws)

            ticket = st.get_ticket('CRE-1')
            workers = st.running_workers('CRE-1')
        # These cannot be derived from the logs, which is exactly why fleetd
        # writes them first-hand — a rebuild must not touch them.
        self.assertEqual(ticket['position'], 'STEP_4')
        self.assertEqual(ticket['held'], 1)
        self.assertEqual(len(workers), 1)
        self.assertEqual(workers[0]['id'], wid)

    def test_log_wins_when_projection_disagrees(self):
        with self._open() as st:
            st.ingest_workspace(self.ws)
            st.conn.execute(
                "UPDATE log_events SET status = 'done' WHERE line_no = 5")
            st.conn.commit()
            st.rebuild_projections(self.ws)
            row = st.conn.execute(
                'SELECT status FROM log_events WHERE line_no = 5').fetchone()
        self.assertEqual(row['status'], 'fail')

    def test_pruning_removes_only_rows_past_the_retention_window(self):
        # Timestamps are generated relative to now, not hard-coded, so the
        # test does not start failing once the fixture dates age past the
        # retention window.
        recent = time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())
        stale = time.strftime('%Y-%m-%dT%H:%M:%SZ',
                              time.gmtime(time.time() - 10 * 86400))
        (self.ws / 'CRE-9-pipeline.log').write_text(
            f'{stale}|APPRAISE|appraise|done|old\n'
            f'{recent}|IMPLEMENT|implement|done|new\n')

        with self._open() as st:
            st.ingest_workspace(self.ws)
            st.record_position('CRE-9', 'STEP_4')
            removed = st.prune_log_events(older_than_days=5)
            ticket = st.get_ticket('CRE-9')
            remaining = [r['msg'] for r in st.conn.execute(
                "SELECT msg FROM log_events WHERE tid = 'CRE-9' ORDER BY line_no")]
        self.assertEqual(removed, 1)
        self.assertEqual(remaining, ['new'])
        # Retention is about query cost; fleetd-authored state is never pruned.
        self.assertEqual(ticket['position'], 'STEP_4')


# ── Position, hold and ownership ─────────────────────────────────────────────

class TestTicketState(StoreTestCase):

    def test_position_is_recorded_and_read_back(self):
        with self._open() as st:
            st.record_position('CRE-1', 'STEP_4')
            self.assertEqual(st.get_position('CRE-1'),
                             {'position': 'STEP_4', 'source': 'dispatch'})

    def test_adopted_position_is_marked_as_derived(self):
        with self._open() as st:
            st.record_position('CRE-1', 'STEP_2', source='adopted')
            self.assertEqual(st.get_position('CRE-1')['source'], 'adopted')

    def test_unknown_position_source_is_rejected(self):
        with self._open() as st:
            with self.assertRaises(ValueError):
                st.record_position('CRE-1', 'STEP_2', source='guessed')

    def test_hold_survives_reopen(self):
        with self._open() as st:
            st.set_hold('CRE-1', 'gate', 'hold:CRE-1:g0:a1',
                       'awaiting human approval')
        with self._open() as st:
            ticket = st.get_ticket('CRE-1')
        # An indefinite pause is a row, not a process that must stay alive.
        self.assertEqual(ticket['held'], 1)
        self.assertEqual(ticket['hold_kind'], 'gate')
        self.assertEqual(ticket['hold_id'], 'hold:CRE-1:g0:a1')
        self.assertEqual(ticket['hold_reason'], 'awaiting human approval')

    def test_release_clears_kind_and_hold_id_but_stamps_released_at(self):
        with self._open() as st:
            st.set_hold('CRE-1', 'gate', 'hold:CRE-1:g0:a1', 'awaiting approval')
            st.release_hold('CRE-1', 'hold:CRE-1:g0:a1')
            ticket = st.get_ticket('CRE-1')
        self.assertEqual(ticket['held'], 0)
        self.assertEqual(ticket['hold_kind'], '')
        self.assertEqual(ticket['hold_id'], '')
        self.assertTrue(ticket['released_at'])


# ── Hold transitions (compare-and-swap) ──────────────────────────────────────

class TestHoldTransitions(StoreTestCase):

    def test_mint_hold_id_format(self):
        with self._open() as st:
            self.assertEqual(
                st.mint_hold_id('CRE-9', generation=7, attempt=1),
                'hold:CRE-9:g7:a1')

    def test_holding_an_already_held_ticket_is_a_noop(self):
        with self._open() as st:
            first = st.set_hold('CRE-1', 'gate', 'hold:CRE-1:g0:a1', 'r1')
            before = st.get_ticket('CRE-1')
            second = st.set_hold('CRE-1', 'gate', 'hold:CRE-1:g0:a2', 'r2')
            after = st.get_ticket('CRE-1')
        self.assertEqual(first, 1)
        self.assertEqual(second, 0)
        # The second call changed nothing — same hold_id, reason, held_at.
        self.assertEqual(before, after)

    def test_release_with_the_wrong_hold_id_is_a_noop(self):
        with self._open() as st:
            st.set_hold('CRE-1', 'gate', 'hold:CRE-1:g0:a1', 'r')
            rowcount = st.release_hold('CRE-1', 'hold:CRE-1:g0:a2')
            ticket = st.get_ticket('CRE-1')
        self.assertEqual(rowcount, 0)
        self.assertEqual(ticket['held'], 1)

    def test_releasing_an_unheld_ticket_is_a_noop(self):
        with self._open() as st:
            rowcount = st.release_hold('CRE-1', 'hold:CRE-1:g0:a1')
        self.assertEqual(rowcount, 0)

    def test_two_identical_set_hold_calls_converge(self):
        """Exactly one caller sees rowcount 1; the resulting row is the same
        one a single call would have produced (design.md D2)."""
        with self._open() as st:
            a = st.set_hold('CRE-1', 'gate', 'hold:CRE-1:g0:a1', 'r')
            b = st.set_hold('CRE-1', 'gate', 'hold:CRE-1:g0:a1', 'r')
            ticket = st.get_ticket('CRE-1')
        self.assertEqual(sorted([a, b]), [0, 1])
        self.assertEqual(ticket['hold_id'], 'hold:CRE-1:g0:a1')
        self.assertEqual(ticket['hold_attempts'], 1)

    def test_hold_release_hold_leaves_attempts_at_two(self):
        with self._open() as st:
            st.set_hold('CRE-1', 'gate', 'hold:CRE-1:g0:a1', 'r1')
            st.release_hold('CRE-1', 'hold:CRE-1:g0:a1')
            st.set_hold('CRE-1', 'gate', 'hold:CRE-1:g0:a2', 'r2')
            ticket = st.get_ticket('CRE-1')
        self.assertEqual(ticket['hold_attempts'], 2)

    def test_held_tickets_are_oldest_first_and_carry_kind_and_id(self):
        with self._open() as st:
            st.set_hold('CRE-2', 'gate', 'hold:CRE-2:g0:a1', 'r')
            st.set_hold('CRE-1', 'gate', 'hold:CRE-1:g0:a1', 'r')
            # held_at has second resolution — both holds can land in the same
            # second, so pin distinct values to make the ordering assertion
            # unambiguous rather than racing the clock.
            st.conn.execute(
                "UPDATE tickets SET held_at = '2026-01-01T00:00:00Z' "
                "WHERE tid = 'CRE-2'")
            st.conn.execute(
                "UPDATE tickets SET held_at = '2026-01-01T00:00:05Z' "
                "WHERE tid = 'CRE-1'")
            st.conn.commit()
            rows = st.held_tickets()
        self.assertEqual([r['tid'] for r in rows], ['CRE-2', 'CRE-1'])
        for r in rows:
            self.assertEqual(r['hold_kind'], 'gate')
            self.assertTrue(r['hold_id'])

    def test_ties_on_held_at_break_by_tid_ascending(self):
        with self._open() as st:
            st.set_hold('CRE-2', 'gate', 'hold:CRE-2:g0:a1', 'r')
            st.set_hold('CRE-1', 'gate', 'hold:CRE-1:g0:a1', 'r')
            st.conn.execute(
                "UPDATE tickets SET held_at = '2026-01-01T00:00:00Z' "
                "WHERE tid IN ('CRE-1', 'CRE-2')")
            st.conn.commit()
            rows = st.held_tickets()
        self.assertEqual([r['tid'] for r in rows], ['CRE-1', 'CRE-2'])

    def test_hold_kind_is_constrained(self):
        with self._open() as st:
            st.update_ticket('CRE-1')
            with self.assertRaises(sqlite3.IntegrityError):
                st.conn.execute(
                    "UPDATE tickets SET hold_kind = 'bogus' WHERE tid = 'CRE-1'")

    def test_ingested_ticket_is_not_fleetd_owned(self):
        with self._open() as st:
            st.ingest_workspace(self.ws)
            st.update_ticket('CRE-1')
            self.assertFalse(st.is_fleetd_owned('CRE-1'))

    def test_spawning_a_worker_makes_the_ticket_fleetd_owned(self):
        with self._open() as st:
            st.record_worker_spawn('CRE-1', pid=os.getpid(), generation=1)
            self.assertTrue(st.is_fleetd_owned('CRE-1'))

    def test_unknown_column_is_rejected(self):
        with self._open() as st:
            with self.assertRaises(ValueError):
                st.update_ticket('CRE-1', not_a_column='x')

    def test_in_flight_lists_running_workers_only(self):
        with self._open() as st:
            wid = st.record_worker_spawn('CRE-1', pid=os.getpid(), generation=1,
                                         phase='IMPLEMENT')
            self.assertEqual(len(st.in_flight()), 1)
            st.record_worker_exit(wid, exit_code=0)
            self.assertEqual(st.in_flight(), [])

    def test_phase_workers_for_one_ticket_coexist(self):
        with self._open() as st:
            st.record_worker_spawn('CRE-1', pid=1001, generation=1, phase='APPRAISE')
            st.record_worker_spawn('CRE-1', pid=1002, generation=1, phase='IMPLEMENT')
            phases = sorted(w['phase'] for w in st.running_workers('CRE-1'))
        # The old one-registry-file-per-ticket assumption does not survive
        # phase-granularity supervision.
        self.assertEqual(phases, ['APPRAISE', 'IMPLEMENT'])

    def test_worker_resolves_by_session_id(self):
        with self._open() as st:
            st.record_worker_spawn('CRE-1', pid=1001, generation=1,
                                   session_id='sess-abc', phase='IMPLEMENT')
            row = st.worker_by_session('sess-abc')
        self.assertEqual(row['tid'], 'CRE-1')
        self.assertEqual(row['phase'], 'IMPLEMENT')

    def test_phase_run_records_and_closes(self):
        with self._open() as st:
            run_id = st.record_phase_run('CRE-1', 'VERIFY', step='verify', attempt=2)
            st.close_phase_run(run_id, verdict='FAIL', outcome='retry', exit_code=1)
            row = st.conn.execute(
                'SELECT * FROM phase_runs WHERE id = ?', (run_id,)).fetchone()
        self.assertEqual(row['attempt'], 2)
        self.assertEqual(row['verdict'], 'FAIL')


# ── Generation fence ─────────────────────────────────────────────────────────

class TestFence(StoreTestCase):

    def test_unfenced_ticket_allows_any_generation(self):
        with self._open() as st:
            self.assertTrue(st.fence_allows('CRE-1', 1))
            self.assertTrue(st.fence_allows('CRE-1', None))

    def test_superseded_generation_is_refused(self):
        with self._open() as st:
            st.set_fence('CRE-1', 2)
            self.assertFalse(st.fence_allows('CRE-1', 1))
            self.assertFalse(st.fence_allows('CRE-1', 2))
            self.assertTrue(st.fence_allows('CRE-1', 3))

    def test_fenced_ticket_without_a_generation_token_fails_closed(self):
        with self._open() as st:
            st.set_fence('CRE-1', 2)
            # Matching flow.sh: a fenced ticket with no caller generation is
            # refused rather than waved through.
            self.assertFalse(st.fence_allows('CRE-1', None))
            self.assertFalse(st.fence_allows('CRE-1', ''))
            self.assertFalse(st.fence_allows('CRE-1', 'not-a-number'))


# ── Legacy file import ───────────────────────────────────────────────────────

class TestLegacyImport(StoreTestCase):

    def _write_run(self, tid, pid, generation=1, session_id='sess-1'):
        (self.ws / f'{tid}-run.json').write_text(json.dumps({
            'tid': tid, 'pid': str(pid), 'generation': generation,
            'started_at': '2026-09-03T10:00:00Z', 'reason': 'dispatched',
            'session_id': session_id,
        }))

    def _write_fence(self, tid, generation):
        (self.ws / f'{tid}-fence').write_text(json.dumps({
            'tid': tid, 'fenced_generation': generation,
            'fenced_at': '2026-09-03T10:00:00Z',
        }))

    def test_run_registry_becomes_a_worker_row(self):
        self._write_run('CRE-1', os.getpid(), generation=2)
        with self._open() as st:
            imported = st.import_legacy_state(self.ws)
            workers = st.running_workers('CRE-1')
        self.assertEqual(imported['workers'], 1)
        self.assertEqual(workers[0]['generation'], 2)
        self.assertEqual(workers[0]['session_id'], 'sess-1')

    def test_import_is_idempotent(self):
        self._write_run('CRE-1', os.getpid())
        with self._open() as st:
            st.import_legacy_state(self.ws)
            second = st.import_legacy_state(self.ws)
            count = st.conn.execute(
                'SELECT COUNT(*) FROM workers').fetchone()[0]
        self.assertEqual(second['workers'], 0)
        self.assertEqual(count, 1)

    def test_zero_pid_sentinel_is_not_a_worker(self):
        self._write_run('CRE-2', 0)
        with self._open() as st:
            imported = st.import_legacy_state(self.ws)
        self.assertEqual(imported['workers'], 0)

    def test_fence_file_becomes_a_fence_row(self):
        self._write_fence('CRE-1', 4)
        with self._open() as st:
            imported = st.import_legacy_state(self.ws)
            self.assertEqual(imported['fences'], 1)
            self.assertFalse(st.fence_allows('CRE-1', 4))
            self.assertTrue(st.fence_allows('CRE-1', 5))

    def test_import_never_lowers_an_existing_fence(self):
        with self._open() as st:
            st.set_fence('CRE-1', 7)
            self._write_fence('CRE-1', 3)
            st.import_legacy_state(self.ws)
            # Un-fencing a generation the store already refuses would
            # resurrect a killed worker's authority.
            self.assertFalse(st.fence_allows('CRE-1', 7))
            self.assertEqual(st.get_fence('CRE-1'), 7)

    def test_corrupt_files_are_skipped(self):
        (self.ws / 'CRE-3-run.json').write_text('{not json')
        (self.ws / 'CRE-3-fence').write_text('also not json')
        with self._open() as st:
            imported = st.import_legacy_state(self.ws)
        self.assertEqual(imported, {'workers': 0, 'fences': 0})


# ── Concurrency ──────────────────────────────────────────────────────────────

class TestConcurrency(StoreTestCase):

    def test_reader_sees_committed_rows_during_active_writing(self):
        with self._open() as writer:
            writer.ingest_workspace(self.ws)
            db = store.store_path(self.ws)

            stop = threading.Event()
            errors = []

            def write_loop():
                # Its own connection: sqlite3 objects are thread-bound, and
                # fleetd's real writer is one process holding one connection.
                try:
                    with store.FleetStore(db) as w:
                        for i in range(50):
                            w.record_position('CRE-1', f'STEP_{i}')
                            if stop.is_set():
                                return
                except Exception as exc:  # pragma: no cover - failure path
                    errors.append(exc)

            t = threading.Thread(target=write_loop)
            t.start()
            try:
                reader = store.FleetStore(db, read_only=True).open()
                for _ in range(20):
                    count = reader.conn.execute(
                        'SELECT COUNT(*) FROM log_events').fetchone()[0]
                    self.assertEqual(count, 5)
                reader.close()
            finally:
                stop.set()
                t.join(timeout=10)

        self.assertEqual(errors, [])

    def test_read_only_connection_cannot_write(self):
        with self._open():
            pass
        reader = store.FleetStore(store.store_path(self.ws), read_only=True).open()
        try:
            with self.assertRaises(sqlite3.OperationalError):
                reader.conn.execute("INSERT INTO tickets (tid) VALUES ('X')")
        finally:
            reader.close()

    def test_read_only_open_of_a_missing_store_fails_clearly(self):
        with self.assertRaises(FileNotFoundError):
            store.FleetStore(self.ws / 'nope.db', read_only=True).open()


# ── Supervisor integration ───────────────────────────────────────────────────

class TestSupervisorIntegration(StoreTestCase):
    """The store's write path as the supervisor actually drives it.

    Exercised through supervisor.py's module-level helpers rather than a live
    daemon: these are the calls that decide whether the store is populated at
    all in production, and they are cheap to test directly.
    """

    def setUp(self):
        super().setUp()
        from fleetd import supervisor
        self.sup = supervisor

    def test_bootstrap_imports_registry_and_projects_logs(self):
        (self.ws / 'CRE-1-run.json').write_text(json.dumps({
            'tid': 'CRE-1', 'pid': str(os.getpid()), 'generation': 2,
            'started_at': '2026-09-03T10:00:00Z', 'reason': 'dispatched',
            'session_id': 'sess-1',
        }))
        result = self.sup._store_bootstrap(str(self.ws))
        self.assertIsNotNone(result)
        imported, counts = result
        self.assertEqual(imported['workers'], 1)
        self.assertEqual(counts['pipeline'], 5)

        with self._open() as st:
            self.assertTrue(st.is_fleetd_owned('CRE-1'))

    def test_sync_is_incremental(self):
        self.sup._store_bootstrap(str(self.ws))
        with open(self.log, 'a') as fh:
            fh.write('2026-09-03T10:20:00Z|VERIFY|verify|done|PASS\n')
        counts = self.sup._store_sync(str(self.ws))
        self.assertEqual(counts['pipeline'], 1)

    def test_spawn_and_exit_are_recorded(self):
        self.sup._store_record_spawn(
            str(self.ws), 'CRE-1', os.getpid(), 3, 'dispatched', 'sess-9')
        with self._open() as st:
            workers = st.running_workers('CRE-1')
            self.assertEqual(len(workers), 1)
            # The PID-reuse guard is captured at spawn, not looked up later.
            self.assertTrue(workers[0]['start_ticks'])

        self.sup._store_record_exit(
            str(self.ws), 'CRE-1', os.getpid(), 0, 'exit')
        with self._open() as st:
            self.assertEqual(st.running_workers('CRE-1'), [])
            row = st.conn.execute(
                'SELECT status, exit_code FROM workers').fetchone()
        self.assertEqual(row['status'], 'exited')
        self.assertEqual(row['exit_code'], 0)

    def test_killed_worker_is_distinguished_from_a_clean_exit(self):
        self.sup._store_record_spawn(
            str(self.ws), 'CRE-1', 4242, 1, 'dispatched', 'sess-9')
        self.sup._store_record_exit(
            str(self.ws), 'CRE-1', 4242, -9, 'signal', killed_by_fleet=True)
        with self._open() as st:
            row = st.conn.execute('SELECT status FROM workers').fetchone()
        self.assertEqual(row['status'], 'killed')

    def test_fence_is_written_to_both_store_and_marker_file(self):
        self.sup._write_fence_files('CRE-1', 4, str(self.ws))
        # The marker file stays until every consumer reads the store: flow.sh's
        # fence guard runs inside a worker and still reads the file, and
        # dropping it would let a superseded generation's mutations through.
        self.assertTrue((self.ws / 'CRE-1-fence').is_file())
        with self._open() as st:
            self.assertFalse(st.fence_allows('CRE-1', 4))
            self.assertTrue(st.fence_allows('CRE-1', 5))

    def test_store_failure_never_raises_into_the_supervisor(self):
        # An unusable state dir must degrade the store, not the fleet.
        broken = self.ws / 'not-a-dir'
        broken.write_text('this is a file, not a directory')
        self.assertIsNone(self.sup._store_bootstrap(str(broken)))
        self.assertIsNone(self.sup._store_sync(str(broken)))
        self.assertIsNone(
            self.sup._store_record_spawn(str(broken), 'CRE-1', 1, 1, 'r', 's'))
        self.assertIsNone(self.sup._store_record_fence(str(broken), 'CRE-1', 1))

    def test_store_can_be_disabled_by_env(self):
        from unittest.mock import patch
        with patch.object(self.sup, 'FLEET_STORE_ENABLE', False):
            self.assertIsNone(self.sup._store_bootstrap(str(self.ws)))
        self.assertFalse(store.store_path(self.ws).exists())


if __name__ == '__main__':
    unittest.main()
