#!/usr/bin/env python3
"""
ticket-auto overseer — standup & status report generator.

Usage:
  python3 report.py standup [--date YYYY-MM-DD] [--workspace PATH]
  python3 report.py status  [--workspace PATH] [--stale-minutes N]

Data sources (all relative to workspace root):
  ./logs/*.log           — pipeline event streams (ISO|PHASE|STEP|STATUS|MSG)
  ./**／auto-session.md   — completed session traces per ticket
  ./**／notes.md          — complexity scores, REMEDIATION_BRIEFs

Standup:  yesterdayʼs completions + todayʼs queue + blockers.
Status:   active tickets + recent completions + stall alerts.
"""

import argparse
import json
import os
import re
import sys
from collections import defaultdict
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Optional

# ── data model ──────────────────────────────────────────────────────────────

STATUS_ICONS = {
    "done": "✓", "fail": "✗", "skip": "—", "start": "▶",
    "waiting": "⏳", "active": "◎", "pending": "○",
}


@dataclass
class LogEvent:
    ts: datetime
    phase: str       # APPRAISE | EXEC | GATE | IMPLEMENT | VERIFY | PR-REVIEW | META
    step: str        # sub-step or phase name
    status: str      # start | waiting | done | fail | skip | info
    msg: str


@dataclass
class SessionTrace:
    ticket_id: str
    date: str                          # YYYY-MM-DD
    outcome: str                       # complete | stopped: {reason}
    steps: list = field(default_factory=list)  # [(step_name, status, detail)]


@dataclass
class TicketSummary:
    ticket_id: str
    title: str = ""
    complexity: str = ""               # simple | complex
    outcome: str = ""                  # complete | stopped: {reason}
    implement_outcome: str = ""        # Smooth | Rough | Hard
    phases: dict = field(default_factory=dict)  # phase → status
    active_phase: str = ""
    elapsed: str = ""
    merged: str = ""                   # yes | no | skipped
    pr_urls: list = field(default_factory=list)
    gate_result: str = ""
    started_at: Optional[datetime] = None
    ended_at: Optional[datetime] = None


# ── parsers ─────────────────────────────────────────────────────────────────

def parse_ts(s: str) -> datetime:
    try:
        return datetime.fromisoformat(s.replace("Z", "+00:00"))
    except (ValueError, TypeError):
        return datetime.now(timezone.utc)


def parse_log_line(line: str) -> Optional[LogEvent]:
    parts = line.strip().split("|", 4)
    if len(parts) < 4:
        return None
    return LogEvent(
        ts=parse_ts(parts[0]),
        phase=parts[1],
        step=parts[2],
        status=parts[3],
        msg=parts[4] if len(parts) > 4 else "",
    )


def parse_pipeline_log(path: str) -> list[LogEvent]:
    events = []
    try:
        with open(path) as f:
            for line in f:
                ev = parse_log_line(line)
                if ev:
                    events.append(ev)
    except OSError:
        pass
    return events


def parse_auto_session(path: str) -> Optional[SessionTrace]:
    """Parse an auto-session.md file into a SessionTrace."""
    try:
        with open(path) as f:
            content = f.read()
    except OSError:
        return None

    # Extract ticket ID from heading: "# auto session — CRE-47"
    m = re.search(r"#\s*auto\s+session\s*[—\-]\s*(\S+)", content)
    ticket_id = m.group(1) if m else "???"

    # Extract date
    m = re.search(r"\*\*Date:\*\*\s*(\S+)", content)
    date = m.group(1) if m else ""

    # Extract outcome
    m = re.search(r"\*\*Outcome:\*\*\s*(.+)", content)
    outcome = m.group(1).strip() if m else ""

    # Extract step trace: "- [x] Step 1: Appraise — complex, 5 files traced"
    steps = []
    for line in content.splitlines():
        sm = re.match(r"-\s*\[([ x])\]\s*(Step\s+\d[^:]*):\s*(.+)", line)
        if sm:
            checked = "done" if sm.group(1).lower() == "x" else "skip"
            steps.append((sm.group(2).strip(), checked, sm.group(3).strip()))

    return SessionTrace(ticket_id=ticket_id, date=date, outcome=outcome, steps=steps)


def parse_notes_complexity(path: str) -> str:
    """Extract complexity from notes.md."""
    try:
        with open(path) as f:
            content = f.read()
        m = re.search(r"##\s*Complexity\s*\n+\**[^*]+\*?\*?\s*(simple|complex)", content, re.I)
        return m.group(1).lower() if m else ""
    except OSError:
        return ""


# ── aggregators ─────────────────────────────────────────────────────────────

def find_ticket_dirs(workspace: str) -> dict[str, str]:
    """Map ticket_id → ticket_dir path."""
    mapping = {}
    for root, dirs, files in os.walk(workspace):
        # Match directories named like "CRE-47--slug"
        for d in dirs:
            m = re.match(r"^((?:[A-Z]+-)?\d+)--", d)
            if m:
                tid = m.group(1)
                mapping[tid] = os.path.join(root, d)
    return mapping


def build_summaries(workspace: str) -> dict[str, TicketSummary]:
    """Aggregate all data sources into TicketSummary objects keyed by ticket ID."""
    summaries: dict[str, TicketSummary] = {}

    # 1. Pipeline logs
    logs_dir = os.path.join(workspace, "logs")
    if os.path.isdir(logs_dir):
        for fname in os.listdir(logs_dir):
            if not fname.endswith("-pipeline.log"):
                continue
            tid = fname.split("-")[0]  # "CRE-47-pipeline.log" → "CRE" (first segment)
            # Fix: extract full prefix like "CRE-47"
            m = re.match(r"^((?:[A-Z]+-)?\d+)", fname)
            if not m:
                continue
            tid = m.group(1)
            path = os.path.join(logs_dir, fname)
            events = parse_pipeline_log(path)
            if not events:
                continue

            ts = TicketSummary(ticket_id=tid)
            ts.started_at = events[0].ts

            for ev in events:
                if ev.phase == "META":
                    if ev.step == "title":
                        ts.title = ev.msg
                    elif ev.step == "gate-result":
                        ts.gate_result = ev.msg
                    elif ev.step == "outcome":
                        ts.outcome = ev.msg
                    continue

                # Track phase status
                if ev.status == "start" and ev.phase not in ts.phases:
                    ts.phases[ev.phase] = "active"
                    ts.active_phase = ev.phase
                elif ev.status == "done":
                    ts.phases[ev.phase] = "done"
                    if ts.active_phase == ev.phase:
                        ts.active_phase = ""
                elif ev.status == "fail":
                    ts.phases[ev.phase] = "fail"
                    if ts.active_phase == ev.phase:
                        ts.active_phase = ""
                elif ev.status == "waiting":
                    if ev.phase not in ts.phases:
                        ts.phases[ev.phase] = "waiting"

                # Extract outcome details
                if ev.phase == "IMPLEMENT" and ev.step == "implement" and ev.status == "done":
                    for word in ["Smooth", "Rough", "Hard"]:
                        if word in ev.msg:
                            ts.implement_outcome = word
                if ev.phase == "PR-REVIEW" and ev.step == "pr-review" and ev.status == "done":
                    if "merged: yes" in ev.msg.lower():
                        ts.merged = "yes"
                    elif "merged: no" in ev.msg.lower():
                        ts.merged = "no"

            # Elapsed time
            if ts.started_at:
                end = events[-1].ts if events else datetime.now(timezone.utc)
                secs = int((end - ts.started_at).total_seconds())
                ts.elapsed = f"{secs // 3600}h {(secs % 3600) // 60}m"

            summaries[tid] = ts

    # 2. Auto-session.md files — enrich with step traces and outcomes
    ticket_dirs = find_ticket_dirs(workspace)
    for tid, tdir in ticket_dirs.items():
        session_path = os.path.join(tdir, "auto-session.md")
        if not os.path.isfile(session_path):
            continue
        trace = parse_auto_session(session_path)
        if not trace:
            continue

        if tid not in summaries:
            summaries[tid] = TicketSummary(ticket_id=tid)

        ts = summaries[tid]
        # Session trace outcome overrides log-derived outcome if more specific
        if trace.outcome and not ts.outcome:
            ts.outcome = trace.outcome
        # Fill title from session if missing
        if not ts.title:
            ts.title = trace.date  # fallback

        # Complexity from notes.md
        notes_path = os.path.join(tdir, "notes.md")
        if os.path.isfile(notes_path):
            ts.complexity = parse_notes_complexity(notes_path)

    # 3. Detect active sessions — pipeline logs without META|outcome
    for tid, ts in summaries.items():
        if not ts.outcome and ts.active_phase:
            pass  # already marked as active

    return summaries


# ── report generators ───────────────────────────────────────────────────────

def is_active(ts: TicketSummary) -> bool:
    """A ticket is active if it has phases tracked but no terminal outcome."""
    return bool(ts.phases) and not ts.outcome


def is_completed(ts: TicketSummary) -> bool:
    return ts.outcome == "complete"


def is_stopped(ts: TicketSummary) -> bool:
    return ts.outcome.startswith("stopped") if ts.outcome else False


def was_yesterday(ts: TicketSummary, ref_date: datetime) -> bool:
    """Check if ticket activity was on the day before ref_date."""
    if not ts.started_at:
        return False
    yesterday = ref_date - timedelta(days=1)
    return ts.started_at.date() == yesterday.date()


def was_today(ts: TicketSummary, ref_date: datetime) -> bool:
    if not ts.started_at:
        return False
    return ts.started_at.date() == ref_date.date()


def generate_standup(workspace: str, ref_date: datetime) -> str:
    summaries = build_summaries(workspace)
    yesterday = ref_date - timedelta(days=1)
    today = ref_date

    yesterday_str = yesterday.strftime("%A, %Y-%m-%d")
    today_str = today.strftime("%A, %Y-%m-%d")

    yesterday_tickets = [ts for ts in summaries.values() if was_yesterday(ts, ref_date)]
    today_active = [ts for ts in summaries.values() if is_active(ts) or was_today(ts, ref_date)]
    carried_over = [ts for ts in summaries.values()
                    if was_yesterday(ts, ref_date) and is_active(ts)]

    lines = []
    lines.append(f"# Bot Standup — {today_str}")
    lines.append("")

    # ── Yesterday ────────────────────────────────────────────────────────
    lines.append(f"## Yesterday ({yesterday_str})")
    lines.append("")

    # Completions
    completed = [ts for ts in yesterday_tickets if is_completed(ts)]
    stopped = [ts for ts in yesterday_tickets if is_stopped(ts)]

    if completed:
        lines.append("### Completed")
        for ts in completed:
            lines.append(f"- **{ts.ticket_id}** — {ts.title or '(no title)'}")
            if ts.complexity:
                lines.append(f"  - Complexity: {ts.complexity}")
            if ts.implement_outcome:
                lines.append(f"  - Implementation: {ts.implement_outcome}")
            if ts.merged:
                lines.append(f"  - Merged: {ts.merged}")
            lines.append(f"  - Phases: {_fmt_phases(ts)}")
            lines.append("")
    else:
        lines.append("### Completed")
        lines.append("_No tickets completed yesterday._")
        lines.append("")

    if stopped:
        lines.append("### Stopped / Held")
        for ts in stopped:
            lines.append(f"- **{ts.ticket_id}** — {ts.title or '(no title)'}")
            lines.append(f"  - Reason: {ts.outcome}")
            if ts.gate_result:
                lines.append(f"  - Gate: {ts.gate_result}")
            lines.append(f"  - Phases: {_fmt_phases(ts)}")
            lines.append("")
    else:
        lines.append("### Stopped / Held")
        lines.append("_No tickets stopped yesterday._")
        lines.append("")

    if not yesterday_tickets:
        lines.append("_No ticket activity yesterday._")
        lines.append("")

    # ── Today ────────────────────────────────────────────────────────────
    lines.append(f"## Today ({today_str})")
    lines.append("")

    if today_active:
        lines.append("### Active / Queued")
        for ts in sorted(today_active, key=lambda t: t.started_at or datetime.max):
            status = "◎ Active" if is_active(ts) else ("✓ Done" if is_completed(ts) else "⏸ Stopped")
            lines.append(f"- **{ts.ticket_id}** [{status}] — {ts.title or '(no title)'}")
            if ts.active_phase:
                lines.append(f"  - Current phase: {ts.active_phase}")
            if ts.complexity:
                lines.append(f"  - Complexity: {ts.complexity}")
            if ts.elapsed:
                lines.append(f"  - Elapsed: {ts.elapsed}")
            lines.append("")
    else:
        lines.append("### Active / Queued")
        lines.append("_No tickets active or queued._")
        lines.append("")

    # ── Blockers ─────────────────────────────────────────────────────────
    lines.append("## Blockers")
    blocked = [ts for ts in summaries.values()
               if is_stopped(ts) or ts.outcome == "fail"
               or (is_active(ts) and "fail" in ts.phases.values())]
    # Also check for max-retry tickets
    blocked += [ts for ts in summaries.values()
                if "max" in ts.outcome.lower() or "held" in ts.gate_result.lower()]

    if blocked:
        # Deduplicate
        seen = set()
        for ts in blocked:
            if ts.ticket_id in seen:
                continue
            seen.add(ts.ticket_id)
            lines.append(f"- **{ts.ticket_id}** — {ts.title or '(no title)'}")
            lines.append(f"  - Status: {ts.outcome or ts.gate_result or 'blocked'}")
            if ts.active_phase:
                lines.append(f"  - Stuck at: {ts.active_phase}")
            lines.append("")
    else:
        lines.append("_No blockers._")
        lines.append("")

    lines.append("---")
    lines.append(f"_Generated {datetime.now(timezone.utc).strftime('%Y-%m-%d %H:%M UTC')}_")

    return "\n".join(lines)


def generate_status(workspace: str, stale_minutes: int = 30) -> str:
    summaries = build_summaries(workspace)
    now = datetime.now(timezone.utc)

    active = [ts for ts in summaries.values() if is_active(ts)]
    recent = [ts for ts in summaries.values()
              if ts.ended_at and (now - ts.ended_at) < timedelta(hours=24)]
    # Also include completed/stopped from today
    recent_ids = {ts.ticket_id for ts in recent}
    for ts in summaries.values():
        if ts.ticket_id not in recent_ids:
            if was_today(ts, now) and (is_completed(ts) or is_stopped(ts)):
                recent.append(ts)

    # Check for stalled tickets — active but no recent events
    stalled_threshold = now - timedelta(minutes=stale_minutes)
    stalled = [ts for ts in active
               if ts.started_at and ts.started_at < stalled_threshold]

    lines = []
    lines.append(f"# Bot Status — {now.strftime('%Y-%m-%d %H:%M UTC')}")
    lines.append("")

    # ── Active ───────────────────────────────────────────────────────────
    lines.append("## Active")
    if active:
        for ts in active:
            phase_bar = _fmt_progress_bar(ts)
            lines.append(f"### {ts.ticket_id} — {ts.title or '(no title)'}")
            lines.append(f"- Phase: {ts.active_phase or 'unknown'} {phase_bar}")
            if ts.complexity:
                lines.append(f"- Complexity: {ts.complexity}")
            if ts.elapsed:
                lines.append(f"- Elapsed: {ts.elapsed}")
            lines.append(f"- Phases: {_fmt_phases(ts)}")
            # Stale warning
            if ts in stalled:
                stale_mins = int((now - ts.started_at).total_seconds() // 60)
                lines.append(f"- ⚠️ **No progress in {stale_mins} minutes — may be stalled**")
            lines.append("")
    else:
        lines.append("_No active tickets._")
        lines.append("")

    # ── Recent Completions ───────────────────────────────────────────────
    lines.append("## Recent (last 24h)")
    if recent:
        for ts in sorted(recent, key=lambda t: t.ended_at or datetime.min, reverse=True):
            icon = "✓" if is_completed(ts) else "⏸"
            lines.append(f"- {icon} **{ts.ticket_id}** — {ts.title or '(no title)'}")
            if ts.implement_outcome:
                lines.append(f"  - Outcome: {ts.implement_outcome}")
            if ts.outcome:
                lines.append(f"  - Result: {ts.outcome}")
            lines.append("")
    else:
        lines.append("_No recent completions._")
        lines.append("")

    # ── Alerts ───────────────────────────────────────────────────────────
    alerts = []
    if stalled:
        for ts in stalled:
            alerts.append(f"- ⚠️ **{ts.ticket_id}** stalled at `{ts.active_phase}` — {ts.elapsed} elapsed")

    held_tickets = [ts for ts in summaries.values()
                    if "held" in ts.gate_result.lower() and not is_completed(ts)]
    for ts in held_tickets:
        if ts.ticket_id not in {s.ticket_id for s in stalled}:
            alerts.append(f"- ⏸ **{ts.ticket_id}** held at gate — needs human approval")

    failed_tickets = [ts for ts in summaries.values()
                      if ts.outcome and ("fail" in ts.outcome.lower() or "max" in ts.outcome.lower())]
    for ts in failed_tickets:
        alerts.append(f"- ✗ **{ts.ticket_id}** failed — {ts.outcome}")

    if alerts:
        lines.append("## Alerts")
        lines.extend(alerts)
        lines.append("")
    else:
        lines.append("## Alerts")
        lines.append("_No alerts._")
        lines.append("")

    lines.append("---")
    lines.append(f"_Generated {now.strftime('%Y-%m-%d %H:%M UTC')}_")

    return "\n".join(lines)


# ── formatting helpers ──────────────────────────────────────────────────────

PHASE_ORDER = ["APPRAISE", "EXEC", "GATE", "IMPLEMENT", "VERIFY", "PR-REVIEW"]


def _fmt_phases(ts: TicketSummary) -> str:
    parts = []
    for p in PHASE_ORDER:
        status = ts.phases.get(p, "")
        icon = STATUS_ICONS.get(status, "○")
        parts.append(f"{icon} {p}")
    return "  ".join(parts)


def _fmt_progress_bar(ts: TicketSummary) -> str:
    """Render a compact progress bar like [███░░░] 3/6."""
    total = len(PHASE_ORDER)
    done = sum(1 for p in PHASE_ORDER if ts.phases.get(p) == "done")
    active_count = sum(1 for p in PHASE_ORDER if ts.phases.get(p) in ("active", "waiting"))
    bar_width = 10
    filled = int((done / total) * bar_width) if total else 0
    bar = "█" * filled + "░" * (bar_width - filled)
    return f"[{bar}] {done}/{total}"


# ── cli ─────────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(
        description="ticket-auto overseer — standup & status reports",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    sub = parser.add_subparsers(dest="mode", required=True)

    sp = sub.add_parser("standup", help="Generate daily standup report")
    sp.add_argument("--date", default=None,
                    help="Reference date YYYY-MM-DD (default: today)")
    sp.add_argument("--workspace", default=None,
                    help="Path to tickets workspace (default: cwd)")

    st = sub.add_parser("status", help="Generate current status report")
    st.add_argument("--workspace", default=None,
                    help="Path to tickets workspace (default: cwd)")
    st.add_argument("--stale-minutes", type=int, default=30,
                    help="Minutes without progress before flagging stalled (default: 30)")

    args = parser.parse_args()
    workspace = args.workspace or os.getcwd()

    reports_dir = os.path.join(workspace, "logs", "reports")
    os.makedirs(reports_dir, exist_ok=True)

    if args.mode == "standup":
        if args.date:
            ref_date = datetime.fromisoformat(args.date)
            if ref_date.tzinfo is None:
                ref_date = ref_date.replace(tzinfo=timezone.utc)
        else:
            ref_date = datetime.now(timezone.utc)
        report = generate_standup(workspace, ref_date)
        print(report)
        out_path = os.path.join(reports_dir, f"standup-{ref_date.strftime('%Y-%m-%d')}.md")
        with open(out_path, "w") as f:
            f.write(report)

    elif args.mode == "status":
        report = generate_status(workspace, stale_minutes=args.stale_minutes)
        print(report)
        ts = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H%MZ")
        out_path = os.path.join(reports_dir, f"status-{ts}.md")
        with open(out_path, "w") as f:
            f.write(report)


if __name__ == "__main__":
    main()
