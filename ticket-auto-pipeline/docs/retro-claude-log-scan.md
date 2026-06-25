# Plan: ticket-retro Claude Log Scan

**Goal**: Extend `ticket-retro` to scan `$CLAUDE_LOG_FILE` alongside the pipeline log, giving retro full diagnostic context (unrestricted msg length, agent reasoning, stack traces) to propose more precise skill diffs.

---

## Problem

Pipeline log msgs are capped at ~60 chars. When an agent fails, retro sees:

```
EXEC|fail|execution error
```

The claude log has the full trace. Retro misses it.

---

## Phase 1 — Failure Signal Scan

Retro greps claude log for high-signal failure keywords, grabs ±5 lines of context, surfaces in retro output as `## Claude Log Failures`.

### Keywords

| Keyword | Why |
|---|---|
| `permission denied` | Filesystem/auth gaps in skills |
| `command not found` | Missing deps, wrong PATH in container |
| `no such file` | Artifact expectation mismatches |
| `exit code` / `exited with` | Non-zero subprocess exits |
| `timeout` | Hung operations |
| `rate limit` / `429` | API throttling patterns |
| `STATE_ASSERTION_FAILED` | Gate-stop with full context |
| `EXEC_NO_ARTIFACT` | Gate-stop with full context |
| `fatal:` | Git failures |
| `could not` / `unable to` / `failed to` | Soft failures that degrade but don't exit |

### Implementation

```bash
if [[ -f "$CLAUDE_LOG_FILE" ]]; then
  grep -n -i \
    -e "permission denied" \
    -e "command not found" \
    -e "no such file" \
    -e "exit code" \
    -e "exited with" \
    -e "timeout" \
    -e "rate limit" \
    -e "429" \
    -e "STATE_ASSERTION_FAILED" \
    -e "EXEC_NO_ARTIFACT" \
    -e "fatal:" \
    -e "could not" \
    -e "unable to" \
    -e "failed to" \
    "$CLAUDE_LOG_FILE" \
  | head -200 > /tmp/claude-log-failures.txt
fi
```

Retro reads `/tmp/claude-log-failures.txt` and includes it in the skill-diff prompt context.

---

## Phase 2 — Improvement Hint Scan

### Existing hints

`★ Insight` blocks written by learning mode — agents already self-annotate improvements. Retro greps these verbatim:

```bash
grep -A5 "★ Insight" "$CLAUDE_LOG_FILE"
```

### New convention: `RETRO|hint`

Add a `cl_write` call convention agents can use to surface improvement hints explicitly:

```bash
cl_write "RETRO|hint|<improvement observation>"
```

Retro grabs all `RETRO|hint` lines verbatim and lists them as `## Agent Improvement Hints` in the retro report. Zero noise — only written when agent observes something worth fixing.

Example use in a skill:
```
cl_write "RETRO|hint|EXEC artifact path hardcoded — breaks if WORKSPACE_ROOT changes"
```

---

## Phase 3 — Phase-Windowed Context

Use `cl_write` phase boundary entries as anchors (e.g. `APPRAISE|handoff`) to window the surrounding lines. Retro correlates failure lines with the phase they occurred in, giving:

```
EXEC phase — 3 failures found:
  line 142: permission denied /home/user/artifacts/
  line 201: exited with code 1
  line 209: no such file: notes.md
```

---

## Implementation Order

1. **Phase 1** — grep scan + surface in retro output (no skill changes needed beyond retro)
2. **Phase 2a** — grep `★ Insight` blocks (read-only, zero risk)
3. **Phase 2b** — add `RETRO|hint` convention to `cl_write` and wire into 2-3 skills as examples
4. **Phase 3** — phase-windowed correlation (more complex, do last)

---

## Files to Change

| File | Change |
|---|---|
| `skills/ticket-retro.md` | Add claude log scan section, surface failures + hints in prompt context |
| `lib/heartbeat.sh` | Document `RETRO|hint` as valid `cl_write` usage pattern |
| 2-3 pipeline skills | Add example `cl_write "RETRO|hint|..."` calls at known pain points |

---

## Non-Goals

- Do not read the entire claude log (too large)
- Do not replace pipeline log as primary retro source
- Do not add external tooling — bash grep only
