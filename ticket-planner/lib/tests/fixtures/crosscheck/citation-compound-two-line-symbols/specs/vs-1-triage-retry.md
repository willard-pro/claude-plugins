# vs-1-triage-retry

## Description

Add a bounded retry around the triage worker's inner dispatch, reusing the
existing `_run_triage()/_run_triage_inner()` pair in `worker/main.py`.

## Labels

type:backend

## Signals

```json
{
  "services_identified": 1,
  "symbols_resolved": 2,
  "prior_art_found": true,
  "complexity": "simple",
  "exploration_depth": "standard",
  "TargetSymbols": "_run_triage()/_run_triage_inner():worker/main.py:12,30"
}
```
