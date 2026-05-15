#!/usr/bin/env python3
"""
ticket-auto pipeline dashboard
Usage: python3 dashboard.py <log-file>
Log format: {ISO}|{PHASE}|{STEP}|{STATUS}|{MSG}
"""

import sys
import time
import argparse
from dataclasses import dataclass, field
from datetime import datetime, timezone
from typing import Optional
from collections import deque

from rich.live import Live
from rich.text import Text
from rich.panel import Panel

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
                # MSG format: label:path
                if ":" in msg:
                    label, path = msg.split(":", 1)
                    self.state.artifacts.append((label.strip(), path.strip()))
            elif step == "tokens":
                # MSG format: PHASE:input/output/cache
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
            # Mark phase done when its terminal step finishes
            terminal = PHASE_STEPS.get(phase, [""])[- 1]
            if step in ("handoff", terminal):
                ps.status = "fail" if status == "fail" else ("skip" if status == "skip" else "done")
                ps.end_ts = ts
                if self.state.active_phase == phase:
                    self.state.active_phase = None


class Renderer:
    def __init__(self):
        self._tick = 0

    def _spinner(self) -> str:
        return SPINNERS[self._tick % len(SPINNERS)]

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
            # Token count for completed/active phases
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

        # Token summary (after all phases, before log tail)
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


def main():
    parser = argparse.ArgumentParser(description="ticket-auto pipeline dashboard")
    parser.add_argument("log_file", help="Path to pipeline log file")
    args = parser.parse_args()

    reader = LogReader(args.log_file)
    builder = StateBuilder()
    renderer = Renderer()

    with Live(refresh_per_second=4, screen=True) as live:
        while True:
            for line in reader.read_new_lines():
                builder.apply(line)
            builder.state.tick += 1
            live.update(renderer.render(builder.state))
            if builder.state.outcome is not None:
                time.sleep(3)
                break
            time.sleep(0.25)


if __name__ == "__main__":
    main()
