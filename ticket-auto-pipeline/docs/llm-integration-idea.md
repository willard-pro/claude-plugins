# Local LLM Integration for ticket-auto Pipeline

**Date:** 2026-05-16
**Status:** Planned

## Hardware

- AMD Ryzen AI 7 350 (8c/16t, Zen 5)
- 30GB RAM
- NVIDIA RTX 5050 Laptop GPU (8GB VRAM)

## Stack

| Layer | Choice | Why |
|-------|--------|-----|
| Runtime | **ollama** | Single Go binary, auto-detects CUDA, REST API on `localhost:11434` |
| Primary model | **qwen2.5:7b** (4-bit, ~4.5GB VRAM) | Strong at classification, instruction-following, structured output. Fits in 8GB with headroom |
| Fast-path model | **llama3.2:3b** (~2GB) | Sub-second inference for simple classification |

Why qwen2.5:7b over llama3.1:8b? qwen2.5 is consistently better at structured extraction (parsing logs into labeled fields, extracting verdicts from unstructured text). For the pipeline's needs — complexity scoring, verdict extraction, log recovery — structured output matters more than creative writing.

## Setup

```bash
curl -fsSL https://ollama.com/install.sh | sh
ollama pull qwen2.5:7b
ollama pull llama3.2:3b
```

## Bash wrapper (`~/.claude/skills/lib/llm.sh`)

Skills are bash-heavy — a thin curl wrapper beats adding Python dependencies.

```bash
llm_classify() {
  # $1 = model, $2 = system prompt, stdin = text
  # Returns: single token. temperature=0 for deterministic output.
  local model="${1:-qwen2.5:7b}" system="$2"
  curl -sf --max-time 30 http://localhost:11434/api/generate \
    -d "$(jq -n --arg m "$model" --arg s "$system" --arg p "$(cat)" \
          --argjson stream false \
          '{model: $m, system: $s, prompt: $p, stream: $stream,
            options: {temperature: 0, num_predict: 10}}')" \
    | jq -r '.response' | xargs
}

llm_summarize() {
  # $1 = model, $2 = system prompt, stdin = text
  # Returns: markdown. temperature=0.3 for slight flexibility.
  local model="${1:-qwen2.5:7b}" system="$2"
  curl -sf --max-time 60 http://localhost:11434/api/generate \
    -d "$(jq -n --arg m "$model" --arg s "$system" --arg p "$(cat)" \
          --argjson stream false \
          '{model: $m, system: $s, prompt: $p, stream: $stream,
            options: {temperature: 0.3, num_predict: 512}}')" \
    | jq -r '.response'
}
```

Key design: `temperature: 0` for classification, `0.3` for summarization. `num_predict` caps prevent runaway generation. `--max-time 30` means if ollama is down, the skill falls through to its existing Claude path.

## Prompt templates (`~/.claude/skills/lib/prompts/`)

```
prompts/
  complexity-score.txt       # ticket text → simple/complex + axes fired
  verdict-parse.txt           # PR output → verdict extraction
  log-recovery.txt            # damaged log → resume point
  prior-art-triage.txt        # mem-search hit → High/Medium/Low confidence
  wiki-routing.txt            # ticket labels → wiki file paths
```

## Integration points (priority order)

### 1. Complexity scoring (HIGHEST ROI)
- **Where:** `ticket-appraise` Step 2.5
- **What:** Ticket title + description + labels → simple/complex + fired axes
- **Current:** Claude classifies inline in the appraise agent
- **Why local:** Pure text classification, zero tool use, runs on every ticket
- **Model:** `llama3.2:3b` (sub-second)
- **Integration:** Inline call before the agent spawn, result feeds into the agent's prompt

### 2. Pipeline log recovery (HIGH RELIABILITY IMPACT)
- **Where:** `ticket-detect-resume/detect-resume.sh`
- **What:** Malformed or ambiguous pipeline log → resume point
- **Current:** `cut -d'|' -f5` — fragile positional parsing
- **Why local:** Low volume (only on crash recovery), high impact. LLM reads semantically, not positionally.
- **Model:** `qwen2.5:7b`
- **Integration:** Fallback path: if structured parsing fails, pass full log with schema prompt

### 3. Verdict parsing fallback (SELF-HEALING)
- **Where:** `ticket-auto` Step 5b verdict-line integrity gate
- **What:** Unstructured PR review output → verdict (&#10004; or &#9888;)
- **Current:** `grep -cP '^\*\*Verdict:\*\* [&#10004;&#9888;]'` — exact match, one formatting drift halts pipeline
- **Model:** `qwen2.5:7b`
- **Integration:** When `VERDICT_COUNT != 1`, try local LLM extraction before halting

### 4. Prior art triage
- **Where:** `ticket-appraise` Step 2.6
- **What:** claude-mem search hits → High/Medium/Low confidence
- **Model:** `llama3.2:3b`
- **Integration:** Per-hit classification, batchable

### 5. Wiki index matching
- **Where:** `ticket-appraise` Step 3a
- **What:** Ticket labels + title → wiki file paths from index.md
- **Model:** `llama3.2:3b`

### 6. Regression guard cross-referencing
- **Where:** `ticket-appraise-exec` Step 3.5
- **What:** Plan files vs prior art files → CONFLICT/ADJACENT/SUPERSEDES
- **Model:** `qwen2.5:7b`

### 7. Retro template drafting
- **Where:** `ticket-retro`
- **What:** Pipeline log + gate-stop events → post-mortem
- **Model:** `qwen2.5:7b`

## Model-to-task mapping

| Task | Model | Why |
|------|-------|-----|
| Complexity scoring | `llama3.2:3b` | Binary classification, sub-second latency |
| Prior art triage | `llama3.2:3b` | Per-hit classification, many calls, speed matters |
| Wiki routing | `llama3.2:3b` | Label → file mapping, simple classification |
| Verdict parsing | `qwen2.5:7b` | Unstructured input, needs robustness to formatting drift |
| Log recovery | `qwen2.5:7b` | Damaged structured data, needs semantic understanding |
| Regression guard | `qwen2.5:7b` | File list comparison with reasoning |
| Retro template | `qwen2.5:7b` | Summarization with structure |

## What stays with Claude

- **Codebase tracing** (needs LSP/Serena, file reads, find_references)
- **Code writing** (multi-file edits, git operations, test writing)
- **Playwright UAT** (browser automation, visual verification)
- **PR diff review** (reading diffs, cross-referencing requirements)

## Architectural boundary

If a task requires **only text → text/text → label** (no filesystem, no API calls, no multi-step reasoning that depends on prior tool outputs), it's local-LLM-eligible. The moment it needs to read a file, call an MCP tool, or make a decision that depends on the result of a previous tool call — it stays with Claude.
