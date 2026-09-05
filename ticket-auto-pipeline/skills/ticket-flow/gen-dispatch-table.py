#!/usr/bin/env python3
"""Render the ticket-auto dispatch table from dispatch-table.json into SKILL.md.

Deterministic and stdlib-only: the same JSON always produces byte-identical
output, which is what makes ``--check`` usable as a CI drift gate.

Usage:
    gen-dispatch-table.py              # print the generated block to stdout
    gen-dispatch-table.py --check      # exit 1 if SKILL.md is out of date
    gen-dispatch-table.py --write      # rewrite the generated block in SKILL.md

Exit codes:
    0  in sync (or wrote successfully)
    1  drift detected (--check)
    2  structural problem (missing file, missing markers, malformed JSON)
"""

import argparse
import difflib
import json
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
DEFAULT_TABLE = HERE / "dispatch-table.json"
DEFAULT_SKILL = HERE.parent / "ticket-auto" / "SKILL.md"

START_MARKER = "<!-- GENERATED:dispatch-table START -->"
END_MARKER = "<!-- GENERATED:dispatch-table END -->"

PREAMBLE = (
    "<!-- Generated from skills/ticket-flow/dispatch-table.json by "
    "skills/ticket-flow/gen-dispatch-table.py. Do not hand-edit: edit the JSON "
    "and regenerate. CI fails the build when this block drifts. -->"
)


def load_steps(table_path):
    try:
        data = json.loads(table_path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        die(f"dispatch table not found: {table_path}")
    except json.JSONDecodeError as exc:
        die(f"dispatch table is not valid JSON: {exc}")

    steps = data.get("steps")
    if not isinstance(steps, list) or not steps:
        die("dispatch table has no 'steps' array")

    for i, step in enumerate(steps):
        for field in ("step_id", "table_label", "table_action", "table_type"):
            if field not in step:
                die(f"steps[{i}] is missing required field '{field}'")
    return steps


def _step_agents(step):
    """Yield (skill, agent) pairs for every agent spawn a step declares.

    A step has either a single `spawn` block or a `sequence` of them
    (STEP_5's document + wiki-maintenance); never both. `agent` is `None`
    for a spawn with no dedicated subagent type yet (falls back to
    `general-purpose` at dispatch time — see SKILL.md's Agent spawn
    template).
    """
    spawn = step.get("spawn")
    if spawn and spawn.get("skill"):
        yield spawn["skill"], spawn.get("agent")
        return
    for entry in step.get("sequence") or []:
        if entry.get("skill"):
            yield entry["skill"], entry.get("agent")


def render(steps):
    """Render the generated block. Entry order in the JSON is the render order."""
    lines = [START_MARKER, PREAMBLE, "", "| RESUME_STEP | Action | Type |", "|-------------|--------|------|"]
    for step in steps:
        lines.append(
            "| {} | {} | {} |".format(
                step["table_label"], step["table_action"], step["table_type"]
            )
        )
    lines.append("")
    lines.append(
        "**Agent types** — the `subagent_type` each phase's `Agent` tool "
        "spawn MUST use (see \"Agent spawn template\" below). A skill with "
        "no dedicated agent type falls back to `general-purpose`."
    )
    lines.append("")
    lines.append("| Skill | subagent_type |")
    lines.append("|-------|---------------|")
    for step in steps:
        for skill, agent in _step_agents(step):
            lines.append("| `{}` | `{}` |".format(skill, agent or "general-purpose"))
    lines.append(END_MARKER)
    return "\n".join(lines) + "\n"


def split_skill(skill_path):
    """Return (before, current_block, after) around the generated markers."""
    try:
        text = skill_path.read_text(encoding="utf-8")
    except FileNotFoundError:
        die(f"SKILL.md not found: {skill_path}")

    start = text.find(START_MARKER)
    end = text.find(END_MARKER)
    if start == -1 or end == -1:
        die(
            f"{skill_path} has no generated dispatch-table block.\n"
            f"Insert these markers around the table:\n  {START_MARKER}\n  ...\n  {END_MARKER}"
        )
    if end < start:
        die(f"{skill_path}: END marker precedes START marker")

    block_end = end + len(END_MARKER)
    # Absorb the newline that terminates the END marker line so the rendered
    # block (which ends in "\n") round-trips without gaining or losing one.
    if text[block_end:block_end + 1] == "\n":
        block_end += 1
    return text[:start], text[start:block_end], text[block_end:]


def die(msg):
    print(f"gen-dispatch-table: {msg}", file=sys.stderr)
    sys.exit(2)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="exit 1 if SKILL.md is out of date")
    parser.add_argument("--write", action="store_true", help="rewrite the block in SKILL.md")
    parser.add_argument("--table", type=Path, default=DEFAULT_TABLE)
    parser.add_argument("--skill", type=Path, default=DEFAULT_SKILL)
    args = parser.parse_args()

    if args.check and args.write:
        die("--check and --write are mutually exclusive")

    expected = render(load_steps(args.table))

    if not args.check and not args.write:
        sys.stdout.write(expected)
        return 0

    before, current, after = split_skill(args.skill)

    if current == expected:
        if args.check:
            print(f"gen-dispatch-table: {args.skill.name} dispatch table is in sync")
        return 0

    if args.check:
        diff = difflib.unified_diff(
            current.splitlines(keepends=True),
            expected.splitlines(keepends=True),
            fromfile=f"{args.skill} (current)",
            tofile=f"{args.table} (generated)",
        )
        sys.stderr.write(
            "gen-dispatch-table: SKILL.md dispatch table has drifted from "
            "dispatch-table.json.\nRegenerate with:\n"
            f"  python3 {Path(__file__).name} --write\n\n"
        )
        sys.stderr.writelines(diff)
        return 1

    args.skill.write_text(before + expected + after, encoding="utf-8")
    print(f"gen-dispatch-table: rewrote dispatch table in {args.skill}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
