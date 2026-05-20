# LinkedIn post — log traceability improvements

---

Spent the last few days wrestling with an invisible problem: when an autonomous agent pipeline fails somewhere across 20+ steps spanning six phases, how do you even know where to look?

The pipeline I've been building processes tickets end to end — appraisal, implementation, verification, PR review, merge. It spawns sub-agents for each phase. When something breaks midway through, the failure surface is enormous. Is it a bad complexity score? A state machine mismatch? An API timeout? A gate-stop? The agent is gone by the time you check — all you have is whatever output it left behind.

Until last week, that output was a single pipeline log tracking phase/step transitions. Useful, but it only told you *what* happened and *when*. Not *why*.

So I built a heartbeat log — a companion stream that runs alongside the pipeline log, recording every decision, every fallback, every retry, every API call timing, every gate evaluation, and periodic liveness signals during long operations. Pipe-delimited, flat JSON details, all writes through a shared bash library so format drift is structurally impossible.

The architecture is simple but the effect compounds:

```
Pipeline log:    ISO|PHASE|STEP|STATUS|MSG
Heartbeat log:   ISO|CATEGORY|EVENT|STATUS|MSG|DETAIL
```

Pipeline tracks the what. Heartbeat tracks the why.

The real breakthrough came when I realized the heartbeat log is machine-readable enough that the agent itself can use it for recovery. When a pipeline crashes, the resume detector reads both logs — the pipeline log gives it the last completed step, and the heartbeat entries around that timestamp give it context about what was being decided, what API calls were in flight, whether a fallback had activated. The agent tails the log and already has a rough map of where to go in the code.

It's not perfect. Schema versioning is v1. Some detail fields are still `{}`. The dashboard consumers are sketched but not built. But after days of adding write points across 16 files — the orchestrator, every agent skill, the bash libraries — the logs lit up and suddenly I could trace an entire pipeline run end to end, every decision legible, every failure point timestamped to the second.

That feeling when days of incremental plumbing finally cohere into something that works. You add one write point, then another, then forty more, and at some point it crosses from "scattered log lines" to "operational transparency."

The pipeline is still in testing. Still finding edge cases. But the difference between debugging blind and debugging with structured trace data is night and day. Small improvements, stacked patiently.

---

*Building an autonomous ticket pipeline that appraises, implements, verifies, and merges Linear tickets with zero user input. Currently in active testing. Writing about the log infrastructure because observability is what makes autonomy possible.*
