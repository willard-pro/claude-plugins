# grill-me — Pre-Work Readiness Gate

Ask your idea the hard questions before you build anything. `/grill-me` assesses a business idea against a profile-driven dimension model, interactively grills you on the gaps, and produces a cryptographically sealed Validated Business Intent document that downstream consumers (like `ticket-planner`) can gate on.

## Quick start

```
/grill-me "Add real-time collaboration to the document editor"
```

Or from a file:

```
/grill-me --file ./brief.md
```

## What it does

1. **Assesses** your idea against 10 quality dimensions (objective, users, success criteria, scope, acceptance criteria, constraints, dependencies, risks, edge cases, assumptions)
2. **Scores** readiness deterministically from 0–100 (bash, not an LLM guessing at arithmetic)
3. **Asks** ranked clarification questions for the highest-impact gaps — each question tells you *why* the information is required
4. **Produces** a sealed Validated Business Intent document with a SHA-256 content hash
5. **Refuses** to let downstream tools accept a tampered or under-specified intent

## Modes

| Mode | Flag | Use case |
|------|------|----------|
| Interactive | (default) | Human refining an idea — asks up to `--max-rounds` rounds of questions |
| Non-interactive | `--non-interactive` | Agent-to-agent — scores and seals without asking questions |

## Flags

| Flag | Default | Description |
|------|---------|-------------|
| `--profile <id>` | `product-idea` | Dimension profile to assess against |
| `--file <path>` | — | Read input from file |
| `--out <path>` | `.ticket-auto/intents/{slug}-{date}.md` | Output path for the sealed document |
| `--non-interactive` | off | Score, render, seal — never ask questions |
| `--max-rounds N` | 3 | Maximum grill question rounds |

## Environment overrides

| Variable | Overrides | Description |
|----------|-----------|-------------|
| `GRILL_THRESHOLD_READY` | profile `ready` threshold | Lower/raise the ready bar |
| `GRILL_THRESHOLD_WARN` | profile `warn` threshold | Lower/raise the warn bar |
| `GRILL_MAX_QUESTIONS` | profile `max_questions` | More/fewer questions per round |

## Recommendation tiers

| Recommendation | Meaning | Consumer behavior |
|----------------|---------|-------------------|
| `ready` | Well-specified, all critical dimensions present | Proceed |
| `proceed-with-warnings` | Has gaps but passable | Proceed with warning surfaced |
| `do-not-proceed` | Under-specified or critical dimensions missing | Hard stop — re-grill |

## How downstream agents consume this

1. **Verify the seal:** `grill_seal_verify <file>`
   - Exit 0 + `VALID` → proceed
   - Exit 3 `NO_SEAL` → "This is not a grill-me intent file"
   - Exit 4 `MISMATCH` → "This file was edited since validation"
2. **Read the verdict:** `GRILL_RECOMMENDATION` from verifier output
3. **Treat the document as authoritative:** The Objective, Scope, and Acceptance Criteria sections are the agreed-upon specification — never re-derive them from the raw idea

## Architecture

See [docs/grill-me.md](docs/grill-me.md) for the full architecture, determinism boundary, and worked examples. See [docs/intent-seal-schema.md](docs/intent-seal-schema.md) for the seal format and canonicalization rule.

## Dependencies

- `bash` (required)
- `jq` (required)
- `sha256sum` (required)
- No new runtime dependencies beyond what the existing plugins already require

## Version

0.1.0 — initial release with `product-idea` profile.

## License

UNLICENSED — proprietary. See repository root.
