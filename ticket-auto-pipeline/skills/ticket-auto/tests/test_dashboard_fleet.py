"""
Tests for dashboard.py's fleet view (--fleet).

Run:
    python3 -m pytest ticket-auto-pipeline/skills/ticket-auto/tests/test_dashboard_fleet.py -v

The data layer is tested, not the rendering: `collect_fleet_rows` and
`read_fleet_row` are pure stdlib and do nothing but read log files, which is why
dashboard.py's rich import is optional. Asserting on a rich Table's internals
would test rich, not the dashboard.

The properties that matter:

- One row per *active* pipeline, so a directory of a dozen tickets is a dozen
  rows and a finished ticket is none.
- Rows are re-derived from a fresh glob on every refresh, so a pipeline that
  starts while the dashboard is open appears without a restart.
- The activity-age column reads the activity log's last entry, since that is the
  agent's own liveness pulse and the only column here the orchestrator cannot
  fake.
"""

import os
import sys
from datetime import datetime, timedelta, timezone

import pytest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
import dashboard  # noqa: E402


NOW = datetime(2026, 9, 3, 12, 0, 0, tzinfo=timezone.utc)


def iso(secs_ago):
    return (NOW - timedelta(seconds=secs_ago)).strftime("%Y-%m-%dT%H:%M:%SZ")


def write_log(d, tid, lines):
    path = os.path.join(d, f"{tid}-pipeline.log")
    with open(path, "a") as fh:
        for ln in lines:
            fh.write(ln + "\n")
    return path


def write_activity(d, tid, secs_ago, n=1):
    path = os.path.join(d, f"{tid}-activity.log")
    with open(path, "a") as fh:
        for _ in range(n):
            fh.write(f"{iso(secs_ago)}|IMPLEMENT|Bash\n")
    return path


@pytest.fixture
def logs(tmp_path):
    return str(tmp_path)


class TestRowExtraction:
    def test_open_bracket_reports_its_age(self, logs):
        write_log(logs, "AAA-1", [f"{iso(300)}|IMPLEMENT|implement|waiting|Agent launched"])
        row = dashboard.read_fleet_row(os.path.join(logs, "AAA-1-pipeline.log"), NOW)
        assert row.tid == "AAA-1"
        assert row.phase == "IMPLEMENT"
        assert row.step == "implement"
        assert row.bracket_age == 300

    def test_closed_bracket_reports_no_age(self, logs):
        write_log(
            logs,
            "AAA-2",
            [
                f"{iso(300)}|IMPLEMENT|implement|waiting|Agent launched",
                f"{iso(60)}|IMPLEMENT|implement|done|implemented",
            ],
        )
        row = dashboard.read_fleet_row(os.path.join(logs, "AAA-2-pipeline.log"), NOW)
        assert row.bracket_age is None
        assert row.status == "done"

    def test_a_prior_cycles_terminal_does_not_mask_a_live_wait(self, logs):
        # The same bug fleet-detect.sh's position-scoped matching fixes: a
        # terminal from an earlier cycle must not close a later bracket.
        write_log(
            logs,
            "AAA-3",
            [
                f"{iso(900)}|VERIFY|verify|waiting|attempt 1",
                f"{iso(800)}|VERIFY|verify|fail|FAIL",
                f"{iso(200)}|VERIFY|verify|waiting|attempt 2",
            ],
        )
        row = dashboard.read_fleet_row(os.path.join(logs, "AAA-3-pipeline.log"), NOW)
        assert row.bracket_age == 200

    def test_loop_counters_are_counted(self, logs):
        write_log(
            logs,
            "AAA-4",
            [
                f"{iso(900)}|VERIFY|verify|waiting|attempt 1",
                f"{iso(880)}|VERIFY|verify|fail|FAIL",
                f"{iso(700)}|VERIFY|verify|waiting|attempt 2",
                f"{iso(680)}|VERIFY|verify|done|PASS",
                f"{iso(600)}|PR-REVIEW|pr-review|waiting|reviewing",
                f"{iso(500)}|PR-REVIEW|pr-review|done|WARN",
            ],
        )
        row = dashboard.read_fleet_row(os.path.join(logs, "AAA-4-pipeline.log"), NOW)
        assert row.verify_attempts == 2
        assert row.pr_iterations == 1

    def test_last_gate_event_is_surfaced(self, logs):
        write_log(
            logs,
            "AAA-5",
            [
                f"{iso(900)}|META|gate-result|info|auto-approved",
                f"{iso(300)}|META|gate-held|info|held",
                f"{iso(200)}|IMPLEMENT|implement|waiting|Agent launched",
            ],
        )
        row = dashboard.read_fleet_row(os.path.join(logs, "AAA-5-pipeline.log"), NOW)
        assert "gate-held" in row.last_gate

    def test_meta_lines_do_not_become_the_current_step(self, logs):
        # META is a pseudo-phase. Showing "META / tokens" as the current step
        # would hide the phase the ticket is actually in.
        write_log(
            logs,
            "AAA-6",
            [
                f"{iso(300)}|IMPLEMENT|implement|waiting|Agent launched",
                f"{iso(10)}|META|tokens|info|in=100 out=50",
            ],
        )
        row = dashboard.read_fleet_row(os.path.join(logs, "AAA-6-pipeline.log"), NOW)
        assert row.phase == "IMPLEMENT"
        assert row.bracket_age == 300

    def test_malformed_lines_are_skipped_not_fatal(self, logs):
        write_log(
            logs,
            "AAA-7",
            [
                "not a pipeline line at all",
                "",
                f"{iso(120)}|IMPLEMENT|implement|waiting|Agent launched",
            ],
        )
        row = dashboard.read_fleet_row(os.path.join(logs, "AAA-7-pipeline.log"), NOW)
        assert row.bracket_age == 120

    def test_unreadable_log_yields_no_row(self, logs):
        assert dashboard.read_fleet_row(os.path.join(logs, "GONE-1-pipeline.log"), NOW) is None


class TestActivityAge:
    def test_activity_age_comes_from_the_last_entry(self, logs):
        write_log(logs, "BBB-1", [f"{iso(300)}|IMPLEMENT|implement|waiting|Agent launched"])
        write_activity(logs, "BBB-1", 500)
        write_activity(logs, "BBB-1", 45)
        row = dashboard.read_fleet_row(os.path.join(logs, "BBB-1-pipeline.log"), NOW)
        assert row.activity_age == 45

    def test_absent_activity_log_is_not_an_error(self, logs):
        write_log(logs, "BBB-2", [f"{iso(300)}|IMPLEMENT|implement|waiting|Agent launched"])
        row = dashboard.read_fleet_row(os.path.join(logs, "BBB-2-pipeline.log"), NOW)
        assert row.activity_age is None

    def test_a_hung_agent_under_a_fresh_bracket_is_visible(self, logs):
        # The column exists for exactly this: a young bracket says nothing about
        # whether the agent inside it is doing anything.
        write_log(logs, "BBB-3", [f"{iso(120)}|VERIFY|verify|waiting|Agent launched"])
        write_activity(logs, "BBB-3", 1100)
        row = dashboard.read_fleet_row(os.path.join(logs, "BBB-3-pipeline.log"), NOW)
        assert row.bracket_age == 120
        assert row.activity_age == 1100


class TestCollection:
    def test_multiple_pipelines_render_as_multiple_rows(self, logs):
        for tid in ("CCC-1", "CCC-2", "CCC-3"):
            write_log(logs, tid, [f"{iso(100)}|IMPLEMENT|implement|waiting|Agent launched"])
        rows = dashboard.collect_fleet_rows(logs, NOW)
        assert sorted(r.tid for r in rows) == ["CCC-1", "CCC-2", "CCC-3"]

    def test_completed_pipelines_are_excluded(self, logs):
        write_log(logs, "CCC-4", [f"{iso(100)}|IMPLEMENT|implement|waiting|Agent launched"])
        write_log(
            logs,
            "CCC-5",
            [
                f"{iso(400)}|IMPLEMENT|implement|done|ok",
                f"{iso(100)}|META|outcome|info|complete",
            ],
        )
        rows = dashboard.collect_fleet_rows(logs, NOW)
        assert [r.tid for r in rows] == ["CCC-4"]

    def test_a_pipeline_starting_mid_session_appears_on_the_next_refresh(self, logs):
        write_log(logs, "DDD-1", [f"{iso(100)}|IMPLEMENT|implement|waiting|Agent launched"])
        first = dashboard.collect_fleet_rows(logs, NOW)
        assert [r.tid for r in first] == ["DDD-1"]

        # A second pipeline starts while the dashboard is running.
        write_log(logs, "DDD-2", [f"{iso(10)}|APPRAISE|appraise|waiting|Agent launched"])
        second = dashboard.collect_fleet_rows(logs, NOW)
        assert sorted(r.tid for r in second) == ["DDD-1", "DDD-2"]

    def test_a_pipeline_completing_mid_session_drops_off(self, logs):
        write_log(logs, "DDD-3", [f"{iso(100)}|IMPLEMENT|implement|waiting|Agent launched"])
        assert len(dashboard.collect_fleet_rows(logs, NOW)) == 1
        write_log(logs, "DDD-3", [f"{iso(5)}|META|outcome|info|complete"])
        assert dashboard.collect_fleet_rows(logs, NOW) == []

    def test_oldest_open_bracket_sorts_first(self, logs):
        write_log(logs, "EEE-1", [f"{iso(60)}|IMPLEMENT|implement|waiting|x"])
        write_log(logs, "EEE-2", [f"{iso(900)}|VERIFY|verify|waiting|x"])
        write_log(logs, "EEE-3", [f"{iso(300)}|EXEC|exec|waiting|x"])
        rows = dashboard.collect_fleet_rows(logs, NOW)
        assert [r.tid for r in rows] == ["EEE-2", "EEE-3", "EEE-1"]

    def test_rows_without_an_open_bracket_sort_last(self, logs):
        write_log(
            logs,
            "EEE-4",
            [
                f"{iso(900)}|IMPLEMENT|implement|waiting|x",
                f"{iso(800)}|IMPLEMENT|implement|done|ok",
            ],
        )
        write_log(logs, "EEE-5", [f"{iso(60)}|VERIFY|verify|waiting|x"])
        rows = dashboard.collect_fleet_rows(logs, NOW)
        assert [r.tid for r in rows] == ["EEE-5", "EEE-4"]

    def test_empty_directory_yields_no_rows(self, logs):
        assert dashboard.collect_fleet_rows(logs, NOW) == []


class TestFormatting:
    @pytest.mark.parametrize(
        "secs,expected",
        [(None, "-"), (0, "0s"), (59, "59s"), (60, "1m00s"), (3599, "59m59s"), (3600, "1h00m")],
    )
    def test_age_formatting(self, secs, expected):
        assert dashboard._fmt_age(secs) == expected

    def test_age_styling_tracks_the_detector_thresholds(self):
        assert dashboard._age_style(30, 240, 900) == "green"
        assert dashboard._age_style(300, 240, 900) == "yellow"
        assert dashboard._age_style(1000, 240, 900) == "bold red"
        assert dashboard._age_style(None, 240, 900) == "dim"
