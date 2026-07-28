# Intent Seal Schema

The `## Intent Seal` block is a cryptographic integrity marker terminating every `grill-me` Validated Business Intent document. It is tamper-evident but not tamper-proof — its threat model is accidental drift and casual hand-editing, not an adversarial operator.

## Format

The seal block is appended as the final section of the rendered document:

```markdown
## Intent Seal

**Grill-Version:** 0.1.0
**Profile:** product-idea
**Readiness:** 88
**Recommendation:** ready
**Rounds:** 1
**Generated:** 2026-07-26T00:00:00Z
**Content-Hash:** sha256:a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2
```

Fields:

| Field | Format | Description |
|-------|--------|-------------|
| **Grill-Version** | semver | grill-me plugin version that generated the seal |
| **Profile** | string | Profile id used for assessment |
| **Readiness** | integer 0–100 | Readiness score at sealing time |
| **Recommendation** | ready \| proceed-with-warnings \| do-not-proceed | Verdict at sealing time |
| **Rounds** | integer | Number of assessment rounds (1 = first-round ready, N = grilled) |
| **Generated** | ISO 8601 UTC | Timestamp of seal generation |
| **Content-Hash** | `sha256:` + 64 lowercase hex | SHA-256 hash over the canonicalized byte range |

## Canonicalization rule

The hash input is every byte of the file from offset 0 up to and including the newline (`\n`) terminating the line immediately preceding the `**Content-Hash:**` line.

Concretely:

```
Hash = SHA-256(bytes[0 .. end_of_previous_line])
```

Where `end_of_previous_line` is the byte offset of the last `\n` before the `**Content-Hash:**` line.

### Why seal metadata is inside the hashed region

All seal fields except `Content-Hash` fall inside the hashed region. This means editing `**Readiness:** 22` to `**Readiness:** 95` to slip past the planner's gate **breaks the hash** exactly as editing the document body does. If the hash covered only the body and not the seal metadata, an operator could edit the verdict, leave the body intact, and the invalid hash would still verify.

The only bytes outside the hashed region are:
- The `**Content-Hash:**` line itself (the hash cannot cover its own line)
- Any trailing whitespace/newlines after it (ignored by verification)

### Trailing whitespace independence

The canonicalization rule ignores trailing whitespace after the `**Content-Hash:**` line. A sealed file with or without trailing newlines after the hash line will verify as `VALID`. This makes the seal robust against editors that normalize final newlines.

## Verification contract

`grill_seal_verify <file>` exits with:

| Exit | Status | Meaning |
|------|--------|---------|
| 0 | `VALID` | Hash matches, seal intact |
| 2 | — | File missing or unreadable |
| 3 | `NO_SEAL` | No `## Intent Seal` block, or malformed `Content-Hash` value |
| 4 | `MISMATCH` | Recomputed hash does not match the recorded hash |

On success (exit 0), the verifier emits `KEY=value` lines:

```
GRILL_SEAL_STATUS=VALID
GRILL_READINESS=88
GRILL_RECOMMENDATION=ready
GRILL_PROFILE=product-idea
GRILL_GENERATED=2026-07-26T00:00:00Z
```

These allow callers to gate on the verdict without parsing the document body.

`NO_SEAL` (exit 3) and `MISMATCH` (exit 4) are deliberately distinct so downstream consumers can give specific operator messages:
- `NO_SEAL` → "This is not a grill-me intent file. Run `/grill-me` first."
- `MISMATCH` → "This file was edited since validation. Re-run `/grill-me`."

## Threat model

**This is an integrity check, not an authenticity check.** Anyone can re-run `grill_seal_generate` over edited content to produce a new valid seal. The seal detects:

1. **Accidental drift** — someone edited the body and forgot to re-seal
2. **Casual hand-editing** — someone changed the verdict to bypass the gate
3. **Copy-paste truncation** — the file was partially copied, losing content

It does NOT prevent:

1. **An adversarial operator** — who can just re-run `/grill-me`
2. **A modified grill-seal.sh** — who could change the verification logic

### Future: HMAC via `GRILL_SEAL_KEY`

A keyed HMAC (`GRILL_SEAL_KEY`) would make the seal tamper-proof against anyone without the key. This is deliberately **not built** in v1 — the operator model for this tool assumes honest but error-prone humans, not adversaries.
