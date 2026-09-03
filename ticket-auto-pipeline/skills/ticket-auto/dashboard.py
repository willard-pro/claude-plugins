#!/usr/bin/env python3
"""
ticket-auto pipeline dashboard

Usage:
    python3 dashboard.py <log-file> [--heartbeat]   # one ticket, step by step
    python3 dashboard.py --fleet [<log-dir>]        # every active pipeline, one row each

Log format: {ISO}|{PHASE}|{STEP}|{STATUS}|{MSG}
Heartbeat format: {ISO}|{CATEGORY}|{EVENT}|{STATUS}|{MSG}|{DETAIL}
"""

# Annotations are strings, never evaluated. That is what lets the rich import
# below be optional: several methods are annotated `-> Panel`, which Python would
# otherwise resolve at class-definition time and fail on when rich is absent.
from __future__ import annotations

import sys
import time
import argparse
import glob
import os
import re
from dataclasses import dataclass, field
from datetime import datetime, timezone
from typing import Optional
from collections import deque

# rich is required to *render*, not to *read*. The fleet data layer below is pure
# stdlib so its tests can import this module in an environment without rich —
# which is exactly the CI environment, where only pytest is installed.
try:
    from rich.live import Live
    from rich.text import Text
    from rich.panel import Panel
    from rich.layout import Layout
    from rich.table import Table
    from rich.console import Group

    _RICH_ERROR = None
except ImportError as exc:  # pragma: no cover - exercised only without rich
    _RICH_ERROR = exc

PHASE_ORDER = ["APPRAISE", "EXEC", "GATE", "IMPLEMENT", "VERIFY", "MAINTENANCE", "PR-REVIEW"]

PHASE_STEPS = {
    "APPRAISE":  ["setup-workspace", "complexity-sweep", "prior-art", "codebase-investigation", "handoff"],
    "EXEC":      ["load-workspace", "create-artifact", "post-linear", "handoff"],
    "GATE":      ["gate"],
    "IMPLEMENT": ["check-approval", "detect-path", "checkout-branch", "implement", "run-tests", "code-review", "commit-push"],
    "VERIFY":    ["load-requirements", "launch-browser", "execute-steps", "evaluate", "report"],
    "MAINTENANCE": ["maintenance"],
    "PR-REVIEW": ["fetch-ticket", "extract-requirements", "find-pr", "validate-diff", "post-findings", "merge-decision"],
}

SPINNERS = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]

HB_CATEGORY_COLORS = {
    "decision": "bold cyan",
    "fallback": "bold yellow",
    "heartbeat": "green",
    "api": "blue",
    "gate": "bold magenta",
    "retry": "yellow",
    "source": "dim white",
}


@dataclass
class StepState:
    name: str
    status: str = "pending"
    msg: str = ""
    start_ts: Optional[datetime] = None
    end_ts: Optional[datetime] = None

    def duration(self) -> str:
        if self.start_ts is None:
            return ""
        end = self.end_ts or datetime.now(timezone.utc)
        secs = int((end - self.start_ts).total_seconds())
        return f"{secs // 3600:02d}:{(secs % 3600) // 60:02d}:{secs % 60:02d}"


@dataclass
class PhaseState:
    name: str
    status: str = "pending"
    steps: list = field(default_factory=list)
    start_ts: Optional[datetime] = None
    end_ts: Optional[datetime] = None
    tokens: Optional[tuple] = None  # (input, output, cache)

    def duration(self) -> str:
        if self.start_ts is None:
            return ""
        end = self.end_ts or datetime.now(timezone.utc)
        secs = int((end - self.start_ts).total_seconds())
        return f"{secs // 3600:02d}:{(secs % 3600) // 60:02d}:{secs % 60:02d}"


@dataclass
class PipelineState:
    ticket_id: str = ""
    title: str = "Waiting for pipeline to start..."
    gate_result: str = ""
    start_ts: datetime = field(default_factory=lambda: datetime.now(timezone.utc))
    phases: dict = field(default_factory=dict)
    active_phase: Optional[str] = None
    outcome: Optional[str] = None
    artifacts: list = field(default_factory=list)  # list of (label, path)
    log_lines: deque = field(default_factory=lambda: deque(maxlen=5))
    hb_lines: deque = field(default_factory=lambda: deque(maxlen=5))
    tick: int = 0

    def elapsed(self) -> str:
        secs = int((datetime.now(timezone.utc) - self.start_ts).total_seconds())
        return f"{secs // 3600:02d}:{(secs % 3600) // 60:02d}:{secs % 60:02d}"


class LogReader:
    def __init__(self, path: str):
        self.path = path
        self._pos = 0

    def read_new_lines(self) -> list:
        try:
            with open(self.path, "r") as f:
                f.seek(self._pos)
                data = f.read()
                self._pos = f.tell()
            return [l for l in data.splitlines() if l.strip()] if data else []
        except FileNotFoundError:
            return []


class StateBuilder:
    def __init__(self):
        self.state = PipelineState()
        for name in PHASE_ORDER:
            ps = PhaseState(name=name)
            for step_name in PHASE_STEPS[name]:
                ps.steps.append(StepState(name=step_name))
            self.state.phases[name] = ps

    def _parse_ts(self, s: str) -> datetime:
        try:
            return datetime.fromisoformat(s.replace("Z", "+00:00"))
        except Exception:
            return datetime.now(timezone.utc)

    def _get_or_create_step(self, ps: PhaseState, name: str) -> StepState:
        for s in ps.steps:
            if s.name == name:
                return s
        ss = StepState(name=name)
        ps.steps.append(ss)
        return ss

    def apply(self, line: str):
        parts = line.split("|", 4)
        if len(parts) < 4:
            return
        ts_str, phase, step, status = parts[0], parts[1], parts[2], parts[3]
        msg = parts[4] if len(parts) > 4 else ""
        ts = self._parse_ts(ts_str)

        if phase == "META":
            if step == "title":
                self.state.title = msg
                self.state.ticket_id = msg.split()[0].rstrip(":") if " " in msg else msg
            elif step == "gate-result":
                self.state.gate_result = msg
            elif step == "outcome":
                self.state.outcome = msg
            elif step == "artifact":
                if ":" in msg:
                    label, path = msg.split(":", 1)
                    self.state.artifacts.append((label.strip(), path.strip()))
            elif step == "tokens":
                if ":" in msg:
                    phase_name, counts = msg.split(":", 1)
                    parts = counts.split("/")
                    if len(parts) == 3:
                        try:
                            inp, out, cache = int(parts[0]), int(parts[1]), int(parts[2])
                            if phase_name in self.state.phases:
                                self.state.phases[phase_name].tokens = (inp, out, cache)
                        except ValueError:
                            pass
            return

        # Append to log tail
        self.state.log_lines.append(
            f"{ts.strftime('%H:%M:%S')}  {phase[:7]:<7}  {step[:18]:<18}  {status:<5}  {msg[:35]}"
        )

        if phase not in self.state.phases:
            return

        ps = self.state.phases[phase]

        if status == "start":
            if ps.status == "pending":
                ps.status = "active"
                ps.start_ts = ps.start_ts or ts
                self.state.active_phase = phase
            ss = self._get_or_create_step(ps, step)
            ss.status = "active"
            ss.start_ts = ts
            ss.msg = msg

        elif status in ("done", "fail", "skip"):
            ss = self._get_or_create_step(ps, step)
            ss.status = status
            ss.end_ts = ts
            if msg:
                ss.msg = msg
            terminal = PHASE_STEPS.get(phase, [""])[- 1]
            if step in ("handoff", terminal):
                ps.status = "fail" if status == "fail" else ("skip" if status == "skip" else "done")
                ps.end_ts = ts
                if self.state.active_phase == phase:
                    self.state.active_phase = None

    def apply_heartbeat(self, line: str):
        """Parse a heartbeat log line into the hb_lines deque."""
        parts = line.split("|")
        if len(parts) < 5:
            return
        if parts[1] == "META":
            return  # skip schema header
        ts_str, category, event, status, msg = parts[0], parts[1], parts[2], parts[3], parts[4]
        try:
            ts = datetime.fromisoformat(ts_str.replace("Z", "+00:00"))
        except Exception:
            return
        self.state.hb_lines.append(
            f"{ts.strftime('%H:%M:%S')}  {category:<8}  {event:<18}  {status:<5}  {msg[:30]}"
        )


class Renderer:
    def __init__(self):
        self._tick = 0

    def _spinner(self) -> str:
        return SPINNERS[self._tick % len(SPINNERS)]

    def render_heartbeat_panel(self, state: PipelineState) -> Panel:
        t = Text()
        t.append("heartbeat — last 5 events\n", style="bold magenta")
        t.append("  " + "─" * 68 + "\n", style="dim magenta")

        if not state.hb_lines:
            t.append("  waiting for heartbeat data...\n", style="dim")
        else:
            for entry in list(state.hb_lines):
                # Color by category
                category = entry[9:17].strip()  # field at position 10-17 in formatted line
                color = HB_CATEGORY_COLORS.get(category, "dim")
                t.append(f"  {entry}\n", style=color)

        return Panel(t, border_style="magenta", padding=(0, 1))

    def render(self, state: PipelineState) -> Panel:
        self._tick += 1
        t = Text()

        # Header
        t.append("ticket-auto", style="bold blue")
        t.append("  ▸  ", style="dim blue")
        t.append(state.title + "\n", style="bold white")
        t.append("  Elapsed: ", style="dim")
        t.append(state.elapsed(), style="cyan")
        if state.gate_result:
            t.append("  ·  Gate: ", style="dim")
            style = "bold green" if "approved" in state.gate_result.lower() else "bold yellow"
            t.append(state.gate_result, style=style)
        t.append("\n\n")

        # Phase bar
        t.append("  Phases:  ")
        for i, name in enumerate(PHASE_ORDER):
            if i > 0:
                t.append("  ")
            ps = state.phases.get(name)
            if ps is None or ps.status == "pending":
                t.append("○ ", style="dim")
                t.append(name, style="dim")
            elif ps.status == "active":
                t.append(f"{self._spinner()} ", style="bold yellow")
                t.append(name, style="bold yellow underline")
            elif ps.status == "done":
                t.append("✓ ", style="bold green")
                t.append(name, style="green")
            elif ps.status == "fail":
                t.append("✗ ", style="bold red")
                t.append(name, style="red")
            elif ps.status == "skip":
                t.append("— ", style="dim")
                t.append(name, style="dim italic")
            if ps and ps.tokens:
                inp, out, cache = ps.tokens
                total = inp + out + cache
                if total >= 1000000:
                    t.append(f" · {total / 1000000:.1f}M", style="dim cyan")
                elif total >= 1000:
                    t.append(f" · {total / 1000:.0f}K", style="dim cyan")
                else:
                    t.append(f" · {total}", style="dim cyan")
        t.append("\n")

        # Artifacts
        if state.artifacts:
            t.append("\n  ")
            for i, (label, path) in enumerate(state.artifacts):
                if i > 0:
                    t.append("  ")
                t.append("📄 ", style="bold")
                t.append(f"{label}  ", style="bold cyan")
                t.append(path, style="dim underline", link=f"file://{path}")
                t.append("\n  ")
            t.append("\n")

        # Active phase detail
        active_name = state.active_phase
        if active_name is None and state.outcome:
            for name in reversed(PHASE_ORDER):
                ps = state.phases.get(name)
                if ps and ps.status in ("done", "fail"):
                    active_name = name
                    break

        if active_name:
            ps = state.phases[active_name]
            label_style = "bold yellow" if ps.status == "active" else "bold green"
            status_label = "in progress" if ps.status == "active" else ps.status
            t.append(f"\n  {active_name}", style=label_style)
            t.append(f" — {status_label}\n", style="dim")
            t.append("  " + "─" * 68 + "\n", style="dim")
            for ss in ps.steps:
                if ss.status == "active":
                    t.append(f"  {self._spinner()}  ", style="bold yellow")
                    t.append(f"{ss.name:<22}", style="bold yellow")
                    t.append(f"  {ss.duration():<10}", style="dim")
                    t.append(f"  {ss.msg[:38]}\n", style="white")
                elif ss.status == "done":
                    t.append("  ✓  ", style="bold green")
                    t.append(f"{ss.name:<22}", style="green")
                    t.append(f"  {ss.duration():<10}", style="dim")
                    t.append(f"  {ss.msg[:38]}\n", style="dim white")
                elif ss.status == "fail":
                    t.append("  ✗  ", style="bold red")
                    t.append(f"{ss.name:<22}", style="red")
                    t.append(f"  {ss.duration():<10}", style="dim")
                    t.append(f"  {ss.msg[:38]}\n", style="red")
                elif ss.status == "skip":
                    t.append("  —  ", style="dim")
                    t.append(f"{ss.name:<22}\n", style="dim italic")
                else:
                    t.append("  ○  ", style="dim")
                    t.append(f"{ss.name:<22}\n", style="dim")

        # Token summary
        phases_with_tokens = [(n, p) for n, p in state.phases.items() if p and p.tokens]
        if phases_with_tokens:
            total_in = sum(p.tokens[0] for _, p in phases_with_tokens)
            total_out = sum(p.tokens[1] for _, p in phases_with_tokens)
            total_cache = sum(p.tokens[2] for _, p in phases_with_tokens)
            grand = total_in + total_out + total_cache
            t.append("\n  Tokens:  ", style="bold")
            t.append(f"{grand / 1000:.0f}K total", style="cyan")
            t.append(f"  (in: {total_in / 1000:.0f}K", style="dim")
            t.append(f" / out: {total_out / 1000:.0f}K", style="dim")
            t.append(f" / cache: {total_cache / 1000:.0f}K)", style="dim")
            t.append("\n")

        # Log tail
        if state.log_lines:
            t.append("\n  " + "─" * 68 + "\n", style="dim")
            for entry in list(state.log_lines):
                t.append(f"  {entry}\n", style="dim cyan")

        # Outcome banner
        if state.outcome:
            t.append("\n  ● Pipeline: ", style="dim")
            if state.outcome == "complete":
                t.append("COMPLETE ✓\n", style="bold green")
            else:
                t.append(f"{state.outcome}\n", style="bold red")

        return Panel(t, border_style="blue", padding=(0, 1))



# ── Fleet view ───────────────────────────────────────────────────────────────
# One row per active pipeline instead of one screen per ticket. The per-ticket
# view answers "what is this ticket doing"; the fleet view answers "which of the
# dozen tickets in flight needs me". They read the same logs.
#
# Everything below the renderer is pure stdlib and does no I/O beyond reading the
# log files, so it is directly testable without a terminal or rich.

LINE_RE = re.compile(r"^([^|]*)\|([^|]*)\|([^|]*)\|([^|]*)\|(.*)$")


@dataclass
class FleetRow:
    tid: str
    phase: str = "-"
    step: str = "-"
    status: str = "-"
    bracket_age: Optional[int] = None
    activity_age: Optional[int] = None
    verify_attempts: int = 0
    pr_iterations: int = 0
    last_gate: str = ""


def _parse_iso(value: str) -> Optional[datetime]:
    """Parse the log's ISO-8601 UTC timestamp. Returns None on anything else."""
    try:
        return datetime.strptime(value.strip(), "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
    except (ValueError, AttributeError):
        return None


def _age_secs(ts: Optional[datetime], now: datetime) -> Optional[int]:
    if ts is None:
        return None
    return max(0, int((now - ts).total_seconds()))


def read_fleet_row(log_path: str, now: Optional[datetime] = None) -> Optional[FleetRow]:
    """Build one fleet row from a pipeline log. Returns None for a finished run.

    Completed pipelines are filtered out here rather than rendered greyed-out, to
    match `fleet_detect_all`'s definition of an active pipeline: a log carrying
    `META|outcome` is done, and a fleet view that keeps showing it competes for
    attention with the runs that still need it.
    """
    now = now or datetime.now(timezone.utc)
    tid = os.path.basename(log_path)[: -len("-pipeline.log")]
    if not tid:
        return None

    try:
        with open(log_path, "r", errors="replace") as fh:
            lines = [ln.rstrip("\n") for ln in fh if ln.strip()]
    except OSError:
        return None

    row = FleetRow(tid=tid)
    last_waiting = None  # (index, iso, phase, step)
    terminals = set()  # (phase, step) seen after each waiting, resolved below
    last_entry = None

    for idx, line in enumerate(lines):
        m = LINE_RE.match(line)
        if not m:
            continue
        iso, phase, step, status, msg = (g.strip() for g in m.groups())

        if phase == "META" and step == "outcome":
            return None  # finished run

        if phase == "META":
            if step.startswith("gate"):
                row.last_gate = f"{step}: {msg}"[:40]
            continue

        last_entry = (iso, phase, step, status)

        if status == "waiting":
            last_waiting = (idx, iso, phase, step)
            terminals = set()
        elif status in ("done", "fail", "skip"):
            terminals.add((phase, step))
            if phase == "VERIFY" and step == "verify":
                row.verify_attempts += 1
            elif phase == "PR-REVIEW" and step == "pr-review":
                row.pr_iterations += 1

    if last_entry:
        row.phase, row.step, row.status = last_entry[1], last_entry[2], last_entry[3]

    # An open bracket is a `waiting` with no terminal for the same phase/step
    # after it. Scoping to entries after the waiting line — rather than searching
    # the whole log — is what stops a previous cycle's terminal from masking a
    # live wait, the same bug fleet-detect.sh's position-scoped matching fixes.
    if last_waiting is not None:
        _, iso, phase, step = last_waiting
        if (phase, step) not in terminals:
            row.bracket_age = _age_secs(_parse_iso(iso), now)

    row.activity_age = _read_activity_age(os.path.dirname(log_path), tid, now)
    return row


def _read_activity_age(log_dir: str, tid: str, now: datetime) -> Optional[int]:
    """Age of the agent's own last tool call, from hooks/agent-activity.sh's log.

    Reads the last line's timestamp rather than the file's mtime: mtime also moves
    when the hook ring-caps the file, which would report activity that never
    happened.
    """
    path = os.path.join(log_dir or ".", f"{tid}-activity.log")
    try:
        with open(path, "r", errors="replace") as fh:
            last = ""
            for line in fh:
                if line.strip():
                    last = line
    except OSError:
        return None
    if not last:
        return None
    return _age_secs(_parse_iso(last.split("|", 1)[0]), now)


def collect_fleet_rows(log_dir: str, now: Optional[datetime] = None) -> list:
    """Every active pipeline in `log_dir`, ordered most-recently-active first.

    Re-globbed on every refresh rather than cached, so a pipeline that starts
    while the dashboard is open appears on the next tick.
    """
    now = now or datetime.now(timezone.utc)
    rows = []
    for path in sorted(glob.glob(os.path.join(log_dir, "*-pipeline.log"))):
        row = read_fleet_row(path, now)
        if row is not None:
            rows.append(row)
    # Oldest bracket first: the row most likely to need attention leads. Rows with
    # no open bracket sort last, since nothing is currently being waited on.
    rows.sort(key=lambda r: (r.bracket_age is None, -(r.bracket_age or 0)))
    return rows


def _fmt_age(secs: Optional[int]) -> str:
    if secs is None:
        return "-"
    if secs < 60:
        return f"{secs}s"
    if secs < 3600:
        return f"{secs // 60}m{secs % 60:02d}s"
    return f"{secs // 3600}h{(secs % 3600) // 60:02d}m"


def _age_style(secs: Optional[int], warn: int, bad: int) -> str:
    if secs is None:
        return "dim"
    if secs >= bad:
        return "bold red"
    if secs >= warn:
        return "yellow"
    return "green"


def render_fleet_table(rows, log_dir: str, tick: int = 0):
    """Render the fleet rows as a rich table."""
    table = Table(
        title=f"fleet — {len(rows)} active pipeline(s) in {log_dir}",
        title_style="bold blue",
        expand=True,
        border_style="blue",
    )
    table.add_column("ticket", style="bold")
    table.add_column("phase")
    table.add_column("step")
    table.add_column("bracket", justify="right")
    table.add_column("activity", justify="right")
    table.add_column("vfy", justify="right")
    table.add_column("pr", justify="right")
    table.add_column("last gate", overflow="ellipsis")

    if not rows:
        table.add_row("—", "no active pipelines", "", "", "", "", "", "")
        return Panel(table, border_style="blue", padding=(0, 1))

    spin = SPINNERS[tick % len(SPINNERS)]
    for r in rows:
        marker = spin if r.bracket_age is not None else " "
        # Thresholds mirror fleet-detect.sh's stall dimensions so the dashboard
        # and the detector agree about what "late" means.
        table.add_row(
            f"{marker} {r.tid}",
            r.phase,
            r.step,
            Text(_fmt_age(r.bracket_age), style=_age_style(r.bracket_age, 600, 900)),
            Text(_fmt_age(r.activity_age), style=_age_style(r.activity_age, 240, 900)),
            str(r.verify_attempts),
            str(r.pr_iterations),
            r.last_gate or "-",
        )
    return Panel(table, border_style="blue", padding=(0, 1))


def run_fleet(log_dir: str) -> None:
    """Live fleet view. Same cadence as the per-ticket dashboard (4 fps)."""
    tick = 0
    with Live(refresh_per_second=4, screen=True) as live:
        while True:
            rows = collect_fleet_rows(log_dir)
            live.update(render_fleet_table(rows, log_dir, tick))
            tick += 1
            time.sleep(0.25)


def main():
    parser = argparse.ArgumentParser(description="ticket-auto pipeline dashboard")
    parser.add_argument("log_file", nargs="?", help="Path to pipeline log file")
    parser.add_argument("--heartbeat", action="store_true", help="Also render heartbeat log panel")
    parser.add_argument(
        "--fleet",
        nargs="?",
        const="",
        metavar="LOG_DIR",
        help="Fleet mode: one row per active pipeline in LOG_DIR "
        "(default: $FLEET_PIPELINE_LOG_DIR, else ./logs)",
    )
    args = parser.parse_args()

    if _RICH_ERROR is not None:
        parser.error(f"the dashboard needs the 'rich' package to render: {_RICH_ERROR}")

    if args.fleet is not None:
        log_dir = args.fleet or os.environ.get("FLEET_PIPELINE_LOG_DIR") or "./logs"
        if not os.path.isdir(log_dir):
            parser.error(f"fleet log directory not found: {log_dir}")
        run_fleet(log_dir)
        return

    if not args.log_file:
        parser.error("a pipeline log file is required (or use --fleet)")

    reader = LogReader(args.log_file)
    builder = StateBuilder()
    renderer = Renderer()

    # Heartbeat log reader
    hb_reader = None
    if args.heartbeat:
        hb_path = args.log_file.replace("-pipeline.log", "-heartbeat.log")
        if os.path.exists(hb_path):
            hb_reader = LogReader(hb_path)

    with Live(refresh_per_second=4, screen=True) as live:
        while True:
            for line in reader.read_new_lines():
                builder.apply(line)
            if hb_reader:
                for line in hb_reader.read_new_lines():
                    builder.apply_heartbeat(line)
            builder.state.tick += 1

            if args.heartbeat:
                # Two-panel layout
                layout = Layout()
                layout.split_column(
                    Layout(renderer.render(builder.state), name="pipeline"),
                    Layout(renderer.render_heartbeat_panel(builder.state), name="heartbeat"),
                )
                live.update(layout)
            else:
                live.update(renderer.render(builder.state))

            if builder.state.outcome is not None:
                time.sleep(3)
                break
            time.sleep(0.25)


if __name__ == "__main__":
    main()
