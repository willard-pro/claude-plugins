-- fleet-controller state store — schema v2.
--
-- One SQLite database holding fleet-controller's operational state, replacing
-- the per-ticket JSON file conventions (run registry, generation fence) and the
-- re-parse-the-logs-on-every-read pattern in lib/fleet-detect.sh.
--
-- Two classes of table, and the distinction is load-bearing:
--
--   fleetd-authored (AUTHORITATIVE)  tickets, workers
--       fleetd knows these first-hand because it performed the dispatch. For
--       fleet-managed tickets the database is the authority; nothing else may
--       write them.
--
--   agent-authored (PROJECTION)      log_events, phase_results, activity_events
--       Derived from the append-only pipeline and activity logs, which remain
--       the source of truth. On disagreement the log wins. Every one of these
--       is rebuildable from the logs alone, so deleting the database costs a
--       slow cold start, never data.
--
-- Sole writer: the fleetd supervisor process. Phase agents, hooks and skills
-- keep appending to their logs exactly as they do today and never open this
-- database for writing — that is what keeps dozens of short-lived `claude -p`
-- processes and every PostToolUse hook invocation off the write path. Bash
-- consumers read through the sqlite3 CLI in read-only mode.

PRAGMA journal_mode = WAL;
PRAGMA foreign_keys = ON;

-- ── Version ──────────────────────────────────────────────────────────────────
-- Single row. fleetd refuses to operate against a version it does not
-- recognise rather than misreading tables that may have moved under it.
CREATE TABLE IF NOT EXISTS schema_version (
  id         INTEGER PRIMARY KEY CHECK (id = 1),
  version    INTEGER NOT NULL,
  applied_at TEXT    NOT NULL
);

-- ── tickets (fleetd-authored, AUTHORITATIVE) ─────────────────────────────────
-- One row per ticket fleetd has touched. `position` is recorded as dispatch
-- happens, which is what removes the need to infer it afterwards by parsing the
-- log; `position_source` distinguishes a position fleetd wrote from one derived
-- once when adopting a ticket a human started.
--
-- The hold columns are the answer to "where does an indefinite pause live
-- across a fleetd restart": a held ticket is a row, not a process that must
-- stay alive. The columns name no particular kind of hold — `hold_kind`
-- selects the release predicate that varies by kind; the row shape does not.
CREATE TABLE IF NOT EXISTS tickets (
  tid                TEXT PRIMARY KEY,

  -- Dispatch position
  position           TEXT    NOT NULL DEFAULT '',
  position_source    TEXT    NOT NULL DEFAULT 'dispatch'
                       CHECK (position_source IN ('dispatch', 'adopted')),

  -- Ownership. 'fleetd' gates severity >= 2 intervention; a ticket a human is
  -- running by hand is 'manual' and is reported on but never killed.
  owner              TEXT    NOT NULL DEFAULT 'manual'
                       CHECK (owner IN ('fleetd', 'manual')),

  -- Hold. Kind-agnostic: a hold is a row regardless of what put the ticket
  -- there, which is what lets an indefinite wait for a human survive a
  -- fleetd restart without keeping anything alive. hold_id is minted by
  -- fleetd (`hold:{tid}:g{generation}:a{attempt}`) and is the compare-and-
  -- swap guard both set_hold and release_hold key on — rowcount, not a
  -- lock, is the idempotency proof (design.md D2). notify_state/notified_at/
  -- escalated_at are created here and written by nothing yet — a column
  -- with no writer is cheaper than a second migration once a notifier
  -- lands.
  held               INTEGER NOT NULL DEFAULT 0,
  hold_kind          TEXT    NOT NULL DEFAULT '' CHECK (hold_kind IN ('', 'gate', 'human')),
  hold_id            TEXT    NOT NULL DEFAULT '',
  hold_reason        TEXT    NOT NULL DEFAULT '',
  held_at            TEXT    NOT NULL DEFAULT '',
  hold_generation    INTEGER NOT NULL DEFAULT 0,
  hold_attempts      INTEGER NOT NULL DEFAULT 0,
  notify_state       TEXT    NOT NULL DEFAULT '' CHECK (notify_state IN ('', 'pending', 'sent', 'failed')),
  notified_at        TEXT    NOT NULL DEFAULT '',
  escalated_at       TEXT    NOT NULL DEFAULT '',
  released_at        TEXT    NOT NULL DEFAULT '',

  -- Router-managed cycle counters. Caller-owned state: phase-result's ATTEMPT
  -- field is explicitly not the source of truth for these
  -- (docs/phase-result-schema.md).
  verify_attempts    INTEGER NOT NULL DEFAULT 0,
  iteration          INTEGER NOT NULL DEFAULT 0,
  reconcile_cycle    INTEGER NOT NULL DEFAULT 0,
  pr_feedback_cycle  INTEGER NOT NULL DEFAULT 0,

  -- Branch context, resolved once per ticket by the preamble
  base_branch        TEXT    NOT NULL DEFAULT '',
  integration_branch TEXT    NOT NULL DEFAULT '',
  ticket_branch      TEXT    NOT NULL DEFAULT '',
  uat_policy         TEXT    NOT NULL DEFAULT '',
  autonomy           TEXT    NOT NULL DEFAULT '',

  -- Generation and fence. fenced_generation preserves the file-based fence
  -- semantics exactly: a mutation from generation <= fenced_generation is
  -- refused, and a fenced ticket with no generation token fails closed.
  generation         INTEGER NOT NULL DEFAULT 0,
  fenced_generation  INTEGER,
  fenced_at          TEXT    NOT NULL DEFAULT '',

  created_at         TEXT    NOT NULL DEFAULT '',
  updated_at         TEXT    NOT NULL DEFAULT ''
);

CREATE INDEX IF NOT EXISTS idx_tickets_owner ON tickets (owner);
CREATE INDEX IF NOT EXISTS idx_tickets_held  ON tickets (held);

-- ── workers (fleetd-authored, AUTHORITATIVE) ─────────────────────────────────
-- One row per spawned process. `phase` is '' for a ticket-level worker (today's
-- `claude -p '/ticket-auto {tid} --auto'` spawn) and carries the phase name for
-- a phase-level worker, so several rows for one ticket coexist by design —
-- consumers that assumed one registry file per ticket must be updated to match.
--
-- start_ticks is field 22 of /proc/PID/stat, captured at spawn. `kill -0`
-- alone only proves *some* process holds the pid; comparing start ticks proves
-- it is the same process, which is what makes signalling safe.
CREATE TABLE IF NOT EXISTS workers (
  id           INTEGER PRIMARY KEY AUTOINCREMENT,
  tid          TEXT    NOT NULL,
  phase        TEXT    NOT NULL DEFAULT '',
  pid          INTEGER NOT NULL,
  start_ticks  TEXT    NOT NULL DEFAULT '',
  generation   INTEGER NOT NULL DEFAULT 0,
  session_id   TEXT    NOT NULL DEFAULT '',
  reason       TEXT    NOT NULL DEFAULT '',
  status       TEXT    NOT NULL DEFAULT 'running'
                 CHECK (status IN ('running', 'exited', 'killed', 'unknown')),
  started_at   TEXT    NOT NULL DEFAULT '',
  exited_at    TEXT    NOT NULL DEFAULT '',
  exit_code    INTEGER,
  exit_type    TEXT    NOT NULL DEFAULT ''
);

CREATE INDEX IF NOT EXISTS idx_workers_tid       ON workers (tid);
CREATE INDEX IF NOT EXISTS idx_workers_running   ON workers (tid, status);
CREATE INDEX IF NOT EXISTS idx_workers_session   ON workers (session_id);

-- ── phase_runs (fleetd-authored, AUTHORITATIVE) ──────────────────────────────
-- One row per phase attempt. Distinct from `workers`: a phase attempt is the
-- unit of pipeline progress, a worker is the unit of process supervision, and
-- on the ticket-level path one worker covers many phase attempts.
CREATE TABLE IF NOT EXISTS phase_runs (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  tid         TEXT    NOT NULL,
  phase       TEXT    NOT NULL,
  step        TEXT    NOT NULL DEFAULT '',
  attempt     INTEGER NOT NULL DEFAULT 1,
  worker_id   INTEGER,
  verdict     TEXT    NOT NULL DEFAULT '',
  outcome     TEXT    NOT NULL DEFAULT '',
  exit_code   INTEGER,
  started_at  TEXT    NOT NULL DEFAULT '',
  ended_at    TEXT    NOT NULL DEFAULT '',
  UNIQUE (tid, phase, step, attempt)
);

CREATE INDEX IF NOT EXISTS idx_phase_runs_tid ON phase_runs (tid, phase);

-- ── log_events (PROJECTION of the pipeline log) ──────────────────────────────
-- One row per `ISO|PHASE|STEP|STATUS|MSG` line. `line_no` is the 1-based line
-- number in the source file, which gives ingestion a natural key: re-ingesting
-- a log is an INSERT OR IGNORE no-op rather than a duplicate. It also preserves
-- log order, which every position-scoped detector depends on — a terminal from
-- an earlier cycle must not mask a later `waiting` for the same phase/step.
CREATE TABLE IF NOT EXISTS log_events (
  id        INTEGER PRIMARY KEY AUTOINCREMENT,
  tid       TEXT    NOT NULL,
  line_no   INTEGER NOT NULL,
  iso       TEXT    NOT NULL DEFAULT '',
  epoch     INTEGER,
  phase     TEXT    NOT NULL DEFAULT '',
  step      TEXT    NOT NULL DEFAULT '',
  status    TEXT    NOT NULL DEFAULT '',
  msg       TEXT    NOT NULL DEFAULT '',
  UNIQUE (tid, line_no)
);

CREATE INDEX IF NOT EXISTS idx_log_events_tid    ON log_events (tid, line_no);
CREATE INDEX IF NOT EXISTS idx_log_events_status ON log_events (tid, status);
CREATE INDEX IF NOT EXISTS idx_log_events_phase  ON log_events (tid, phase, step);

-- ── phase_results (PROJECTION of META|phase-result| lines) ───────────────────
-- The machine-readable envelope a loop-bearing phase agent emits, already
-- canonicalised into JSON by lib/phase-result-parse.sh before it reaches the
-- log. Ingestion parses that JSON; it never re-parses the agent's prose.
-- `raw_json` is kept so a consumer can read a field this schema does not
-- promote to a column without a migration.
CREATE TABLE IF NOT EXISTS phase_results (
  id              INTEGER PRIMARY KEY AUTOINCREMENT,
  tid             TEXT    NOT NULL,
  line_no         INTEGER NOT NULL,
  iso             TEXT    NOT NULL DEFAULT '',
  schema_version  INTEGER,
  phase           TEXT    NOT NULL DEFAULT '',
  verifier        TEXT    NOT NULL DEFAULT '',
  claimed_verdict TEXT    NOT NULL DEFAULT '',
  criteria_met    INTEGER,
  criteria_total  INTEGER,
  attempt         INTEGER,
  evidence        TEXT    NOT NULL DEFAULT '',
  unaddressed     TEXT    NOT NULL DEFAULT '',
  parse_status    TEXT    NOT NULL DEFAULT '',
  parse_error     TEXT    NOT NULL DEFAULT '',
  raw_json        TEXT    NOT NULL DEFAULT '',
  UNIQUE (tid, line_no)
);

CREATE INDEX IF NOT EXISTS idx_phase_results_tid ON phase_results (tid, phase);

-- ── activity_events (PROJECTION of the agent-activity log) ───────────────────
-- One row per `ISO|PHASE|TOOL_NAME` line written by
-- ticket-auto-pipeline/hooks/agent-activity.sh. Turns "how long since the agent
-- last did anything" and "how many tool calls in this bracket" into columns
-- instead of a file stat and a wc -l per detection sweep.
CREATE TABLE IF NOT EXISTS activity_events (
  id       INTEGER PRIMARY KEY AUTOINCREMENT,
  tid      TEXT    NOT NULL,
  line_no  INTEGER NOT NULL,
  iso      TEXT    NOT NULL DEFAULT '',
  epoch    INTEGER,
  phase    TEXT    NOT NULL DEFAULT '',
  tool     TEXT    NOT NULL DEFAULT '',
  UNIQUE (tid, line_no)
);

CREATE INDEX IF NOT EXISTS idx_activity_tid ON activity_events (tid, line_no);

-- ── ingest_state (bookkeeping) ───────────────────────────────────────────────
-- How far each source file has been ingested, so a sweep tails from where it
-- left off instead of re-reading the whole file. Truncated or rotated files are
-- detected by size going backwards and re-ingested from the start; the UNIQUE
-- keys above make that safe.
CREATE TABLE IF NOT EXISTS ingest_state (
  source_path  TEXT PRIMARY KEY,
  tid          TEXT    NOT NULL DEFAULT '',
  kind         TEXT    NOT NULL DEFAULT ''
                 CHECK (kind IN ('pipeline', 'activity', '')),
  lines_read   INTEGER NOT NULL DEFAULT 0,
  bytes_read   INTEGER NOT NULL DEFAULT 0,
  updated_at   TEXT    NOT NULL DEFAULT ''
);
