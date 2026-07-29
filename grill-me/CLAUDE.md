# CLAUDE.md — grill-me

Plugin-level guidance for Claude Code when working inside this plugin directory. See also: [repo-level CLAUDE.md](../CLAUDE.md) for marketplace-wide conventions.

## Plugin purpose

Pre-work readiness gate. Any agent can invoke it before acting on an input — it assesses the input against a profile-driven dimension model, scores readiness deterministically in bash, produces a cryptographically sealed Validated Business Intent document, and (in interactive mode) asks ranked clarification questions to close gaps.

## Directory layout

```
grill-me/
  .claude-plugin/plugin.json      # Plugin manifest (name, version, hooks)
  skills/grill-me/SKILL.md        # Single skill: /grill-me
  lib/                            # Shared bash libraries (5 files)
  lib/tests/                      # Test suites (4 files)
  profiles/                       # Dimension profiles (JSON)
  docs/                           # Architecture and reference docs
  README.md                       # Marketplace entry point
```

## Skill

| Skill | Type | Purpose |
|-------|------|---------|
| [grill-me](skills/grill-me/SKILL.md) | Quality Gate | Assesses input readiness, asks ranked clarification questions, produces sealed Validated Business Intent document |

## Determinism boundary

- **Bash side (deterministic):** Profile validation, assessment JSON validation, readiness computation, recommendation resolution, question ranking, document rendering, seal generation, seal verification.
- **Agent side (LLM):** Dimension assessment (present/partial/missing judgements with evidence and gap text), question formulation, flag detection.

The agent emits judgement only — it never computes a score. The bash scorer computes the number. This is the same boundary used throughout the repo: bash orchestrates and decides; agents reason.

## Scoring contract

The agent produces an `assessment.json` with:
- `profile`, `subject`, `round`
- A `dimensions` array of `{id, status: present|partial|missing, evidence, gap}`
- A `flags` map of `{flag_id: true}`
- `assumptions`, `risks`, and `questions` arrays

`grill-score.sh` validates all of that, then computes:
- `readiness = sum(weight * status_factor) - flag_penalties`, clamped to 0–100
- `recommendation` from critical-missing → thresholds → flag caps
- `questions` ranked by `weight * (1 - status_factor)` descending, capped at `max_questions`

The agent SHALL NOT contain a computed score. Every scoring rule is a unit-testable assertion.

## Shared libraries (`lib/`)

| File | Exports |
|------|---------|
| `grill-input.sh` | `grill_sanitize_input` — input sanitization: length cap, whitespace normalization, zero-width and bidi stripping, injection-pattern screening |
| `grill-profile.sh` | `grill_profile_load`, `grill_profile_validate` — profile loading and structural validation |
| `grill-score.sh` | `grill_score` — assessment JSON validation, readiness computation, recommendation resolution, question ranking, `KEY=value` + `result.json` output |
| `grill-render.sh` | `grill_render` — document rendering with fixed section order, tabular gap and score reporting |
| `grill-seal.sh` | `grill_seal_generate`, `grill_seal_verify` — seal block generation and verification with exit-code contract |

## Seal canonicalization

The hash covers every byte from offset 0 up to and including the newline terminating the line immediately before the `**Content-Hash:**` line. All seal metadata (Readiness, Recommendation, Profile, etc.) falls inside the hashed region. Editing `**Readiness:** 22` to `**Readiness:** 95` breaks the hash exactly as editing the body does.

The `**Content-Hash:**` line must be the last non-empty line of the file. Trailing whitespace after it is ignored by verification.

## Known sharp edges

- **Ported sanitizer:** `grill-input.sh` reimplements `planner_sanitize_input` from `ticket-planner/lib/planner-phase-prompts.sh` rather than sourcing it, because grill-me must install standalone. The two copies can drift. The consequence of drift is low — sanitization is defense-in-depth, not a correctness contract between the plugins. Recorded as design decision D6.
- **Seal is tamper-evident, not tamper-proof:** An unkeyed SHA-256 hash can be recomputed by anyone. The threat model is accidental drift and casual hand-editing, not an adversarial operator who can simply re-run grill-me. `GRILL_SEAL_KEY` HMAC is noted as a future option and deliberately not built.
- **Interactive-only gating means unattended callers get no benefit from grilling:** `--non-interactive` still scores and seals, so a fleet-controller or cron caller can gate on `GRILL_RECOMMENDATION` without a human present.
- **Weights and thresholds are initially unvalidated guesses:** They live in one JSON file and are overridable per-run by environment variable, so tuning needs no code change. Calibration comes from the three worked examples and real use.
