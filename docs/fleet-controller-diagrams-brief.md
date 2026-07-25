# Fleet Controller Diagrams — Design Brief

> For Claude Design and ChatGPT image generation. Two audiences: C-suite (business value, safety, scale) and technical evaluators (architecture, data flow).

---

## What exists already

Two diagrams in this repo:

1. **`docs/ticket-auto-pipeline-diagram.html`** — Interactive SVG of a SINGLE ticket pipeline. Shows 7 Linear states (Backlog → Todo → Approve → Ready → Review → UAT → Done) with 8 phase chips below (APPRAISE, REPRODUCE, EXEC, GATE, IMPLEMENT, PR-REVIEW, VERIFY, MAINTENANCE). Drills into each phase's steps, gates, labels, and stop codes.

2. **`docs/ticket-pipeline-animation.html`** — Animated version of the same single-pipeline flow.

**What's missing:** The fleet controller — the meta-layer that oversees ALL running pipelines simultaneously. This is the product's "control tower."

---

## 1. Fleet Controller Diagram — for Claude Design

### What to build

An interactive diagram showing the fleet controller as the overseer of multiple concurrent pipeline instances. Three layers:

```
┌─────────────────────────────────────────────────┐
│                  FLEET CONTROLLER                │
│  ┌───────────────────────────────────────────┐  │
│  │         DETECTION ENGINES (8)              │  │
│  │  phase-failures | stalls | zombies        │  │
│  │  loops | abandonment | flow-failures      │  │
│  │  auto-blocks | tool-errors                │  │
│  └───────────────────────────────────────────┘  │
│              ↓                                   │
│  ┌───────────────────────────────────────────┐  │
│  │    ESCALATION LADDER                       │  │
│  │    OBSERVE → WARN → KILL → KILL+RESTART   │  │
│  └───────────────────────────────────────────┘  │
│              ↓                                   │
│  ┌───────────────────────────────────────────┐  │
│  │    INTERVENTION                            │  │
│  │    kill (stop files) | restart (respawn)   │  │
│  └───────────────────────────────────────────┘  │
│              ↓                                   │
│  ┌───────────────────────────────────────────┐  │
│  │    DASHBOARD + REPORT                      │  │
│  │    terminal health table | markdown report │  │
│  └───────────────────────────────────────────┘  │
└─────────────────────────────────────────────────┘
         │ monitors 3-10 concurrent pipelines
         ↓
┌──────────┐  ┌──────────┐  ┌──────────┐
│ Pipeline │  │ Pipeline │  │ Pipeline │  ...
│ Ticket A │  │ Ticket B │  │ Ticket C │
│ Backlog  │  │ Approve  │  │ Review   │
│ → Todo   │  │ → Ready  │  │ → Done   │
└──────────┘  └──────────┘  └──────────┘
```

### Design specs

**Layout:** Top-down. Fleet controller as a horizontal bar across the top (or a central hub). Pipeline instances as cards/boxes below, each showing current state and phase. Anomaly indicators (color-coded dots) on each pipeline. Escalation ladder as a vertical flow on the right side.

**Colors (match existing diagrams):**
- `#5cc7d1` (teal) — autonomous transitions
- `#f2a23c` (amber) — human actions / warnings
- `#ef5d6c` (red) — failures / kill
- `#8ecf6c` (green) — healthy / pass
- `#8aa6ff` (periwinkle) — informational
- Background: `#0b0d10`, panels: `#11151a`

**Interactivity:**
- Click a pipeline → drill into its state diagram (link to ticket-auto-pipeline-diagram.html)
- Hover a detection engine → show its thresholds and current counts
- Click an escalation level → show the intervention that fires
- Real-time-ish: severity dots pulse/change color based on detection data
- "Show Steps" toggle to reveal the 8 detection engine names below each engine block

**Key data to surface per pipeline:**
- Ticket ID and title
- Current Linear state + phase
- Heartbeat age (how long since last activity)
- Severity level (0-3) with icon
- Active anomaly types
- Restart count (if any)

**Edge cases to show:**
- 0 active pipelines → "No active pipelines" empty state
- All healthy → green across the board
- Mixed severity → some green, some amber, one or two red
- KILL+RESTART in progress → pulsing indicator on that pipeline
- flow.sh mutex held → "deferred" indicator (fleet controller waits, doesn't stomp)

### Phase detail view (like existing diagram's View 2)

When clicking into the fleet controller itself, show:
- **Detection engines card:** 8 engines with their thresholds (e.g., stalls: WARN at 300s, KILL at 900s, RESTART at 1800s)
- **Escalation ladder card:** 4 levels with criteria
- **Intervention card:** kill flow (stop files → finalize log → audit entry) and restart flow (kill + eligibility check + spawn queue)
- **Configuration card:** env vars that control behavior (FLEET_POLL_INTERVAL, FLEET_AUTO_RESTART, FLEET_DRY_RUN, FLEET_MAX_RESTARTS, etc.)

---

## 2. C-Suite Diagram Recommendations

These tell the business story. Order from most to least important.

### Diagram A: Value Delivery Pipeline (⭐ show first)

**What it shows:** A ticket enters on the left, flows through stages, and working code emerges on the right. Time metrics overlay.

**Structure:**
```
Ticket    ┌──────────┐    ┌──────────┐    ┌──────────┐    ┌──────────┐
created   │ APPRAISE │ →  │IMPLEMENT │ →  │ VERIFY   │ →  │  MERGE   │   Deployed
──→       │ 5-15 min │    │ 10-60 min│    │ 5-20 min │    │ auto     │   ──→
          └──────────┘    └──────────┘    └──────────┘    └──────────┘
               ↑              ↑               ↑               ↑
          AI reads       AI writes       AI tests         PR merged
          ticket +       code against    in browser       automatically
          plans work     spec            on real app

Traditional manual process: 2-5 days
Automated pipeline: 20-90 minutes
```

**C-suite message:** "This turns days into minutes. One engineer's oversight → 10x throughput."

### Diagram B: Safety & Governance Architecture

**What it shows:** The layers of protection that prevent bad code from shipping.

**Structure:**
```
                    ┌─────────────────────────────┐
                    │   HUMAN APPROVAL GATE        │
                    │   Complex / high-risk work   │
                    │   must be signed off         │
                    └──────────────┬──────────────┘
                                   ↑
┌──────────┐    ┌──────────┐    ┌──────────┐    ┌──────────┐
│ 7 BASH   │    │ CONTENT  │    │ PR REVIEW │    │  UAT     │
│ GATES    │    │ QUALITY  │    │ (AI)      │    │ VERIFY   │
│          │    │ SCORING  │    │           │    │ (AI +    │
│ No AI    │    │ <40 =    │    │ Diff vs   │    │ browser) │
│ involved │    │ halt     │    │ reqs      │    │          │
└──────────┘    └──────────┘    └──────────┘    └──────────┘
    ↓                ↓               ↓               ↓
Structural      Quality          Correctness      Behavior
integrity       threshold        validation       confirmed
```

**C-suite message:** "AI does the work. Deterministic code checks the work. Humans approve the hard stuff. Three layers of safety."

### Diagram C: Scale & Throughput

**What it shows:** One fleet controller managing many concurrent pipelines.

**Structure:**
```
                    ┌──────────────────────┐
                    │   FLEET CONTROLLER    │
                    │   (1 instance)        │
                    │                       │
                    │   Watches all         │
                    │   Self-heals failures │
                    │   Auto-restarts       │
                    └──────┬───────────────┘
                           │
            ┌──────────────┼──────────────┐
            ↓              ↓              ↓
       ┌─────────┐   ┌─────────┐   ┌─────────┐
       │ Pipeline│   │ Pipeline│   │ Pipeline│  ... up to N
       │ TIX-123 │   │ TIX-456 │   │ TIX-789 │
       │ Backlog │   │ Approve │   │ Review  │
       └─────────┘   └─────────┘   └─────────┘
            ↓              ↓              ↓
       ┌─────────┐   ┌─────────┐   ┌─────────┐
       │   PR    │   │  In QA  │   │  Done   │
       └─────────┘   └─────────┘   └─────────┘

Scale: 1 operator → N concurrent pipelines → N× throughput
Bottleneck: human approval gates only (simple tickets never need them)
```

**C-suite message:** "One person can oversee 10+ concurrent workstreams. The fleet controller keeps everything healthy."

### Diagram D: Decision Automation Funnel

**What it shows:** How decisions flow through the system — what's automated vs. what needs humans.

**Structure:**
```
100 tickets enter
    │
    ↓
┌──────────────────────┐
│ AI APPRAISAL          │  ← 100% automated
│ Classifies complexity │
│ Simple: 60%           │
│ Medium: 25%           │
│ Complex: 15%          │
└──────────┬───────────┘
           ↓
     ┌─────┴─────┐
     ↓           ↓
  SIMPLE       COMPLEX
  (60%)        (40%)
     ↓           ↓
  Auto-        Human
  approve      approval
     ↓         gate
     ↓           ↓
     └─────┬─────┘
           ↓
┌──────────────────────┐
│ AI IMPLEMENTATION     │  ← 100% automated
│ Writes code + tests   │
└──────────┬───────────┘
           ↓
┌──────────────────────┐
│ AI VERIFICATION       │  ← 100% automated
│ Browser testing       │
└──────────┬───────────┘
           ↓
       MERGED
```

**C-suite message:** "60% of tickets never touch a human. The other 40% get human sign-off at one decision point. Everything else is automated."

### Diagram E: Fleet Controller Self-Healing

**What it shows:** The detection → escalation → intervention loop.

**Structure:**
```
                    ┌──────────────────────────────┐
                    │     CONTINUOUS MONITORING      │
                    │     (every 30s by default)     │
                    └──────────────┬───────────────┘
                                   ↓
                    ┌──────────────────────────────┐
                    │     8 DETECTION ENGINES        │
                    │                               │
                    │  🔍 Phase failures             │
                    │  ⏱  Stalls (stale heartbeats)  │
                    │  🧟 Zombies (unresolved steps) │
                    │  🔄 Loops (excessive retries)  │
                    │  🏚  Abandonment (no outcome)  │
                    │  🔧 Flow failures               │
                    │  🚫 Auto-mode blocks             │
                    │  ⚠  Tool errors                 │
                    └──────────────┬───────────────┘
                                   ↓
                    ┌──────────────────────────────┐
                    │     ESCALATION LADDER          │
                    │                               │
                    │  🟢 OBSERVE — log only         │
                    │  🟡 WARN    — alert + report   │
                    │  🔴 KILL    — stop pipeline    │
                    │  💀 RESTART — kill + respawn   │
                    └──────────────┬───────────────┘
                                   ↓
                    ┌──────────────────────────────┐
                    │     INTERVENTION               │
                    │                               │
                    │  Kill: touch stop files        │
                    │  → pingers exit                │
                    │  → watchdogs exit              │
                    │  → pipeline log finalized      │
                    │                               │
                    │  Restart: kill +               │
                    │  → eligibility check           │
                    │  → spawn queue (cron)          │
                    │  OR agent spawn (interactive)  │
                    │  → fresh pipeline begins       │
                    └──────────────────────────────┘
```

**C-suite message:** "If anything goes wrong, the system detects it, escalates appropriately, and heals itself. No ops person staring at dashboards at 3am."

---

## 3. ChatGPT Image Generation Prompts

Give these to ChatGPT (GPT-4o with image generation) or any image-gen tool. Each prompt is self-contained.

### Prompt 1: Fleet Controller Architecture (technical audience)

> Create a technical architecture diagram showing a "Fleet Controller" system that oversees multiple AI-powered software development pipelines. Use a dark theme (background #0b0d10).
>
> **Layout:** Top section labeled "FLEET CONTROLLER" containing four columns: "8 DETECTION ENGINES" (with small icons for phase-failures, stalls, zombies, loops, abandonment, flow-failures, auto-blocks, tool-errors), "ESCALATION LADDER" (showing OBSERVE → WARN → KILL → KILL+RESTART as a vertical sequence), "INTERVENTION" (showing kill and restart actions), and "DASHBOARD" (showing a health table and report icon).
>
> **Bottom section:** 3-5 horizontal bars representing concurrent "Pipeline" instances, each showing a ticket ID, current state (Backlog/Todo/Approve/Ready/Review/UAT/Done), and a colored severity dot (green 🟢 = healthy, yellow 🟡 = warning, red 🔴 = critical). Arrows from the Fleet Controller point down to all pipelines.
>
> **Style:** Clean, modern, professional. Use teal (#5cc7d1) for autonomous elements, amber (#f2a23c) for warnings, red (#ef5d6c) for critical states, green (#8ecf6c) for healthy. Sans-serif font. No code snippets. This is for a software engineering audience — technical but not cluttered.

### Prompt 2: Value Proposition — C-Suite One-Pager

> Create a clean, executive-friendly infographic showing how an "AI-Powered Software Delivery Pipeline" transforms ticket-to-deployment speed.
>
> **Left side — "Traditional":** Manual steps (read ticket → plan → code → review → test → deploy) with "2-5 days" labeled prominently. Use gray/muted tones.
>
> **Right side — "Automated":** Three phases — "AI Appraises" (5-15 min), "AI Implements" (10-60 min), "AI Verifies + Merges" (5-20 min). Total: "20-90 minutes end-to-end." Use teal (#5cc7d1) and green (#8ecf6c).
>
> **Center:** A "Fleet Controller" hub showing "10+ concurrent pipelines" with "1 operator oversees all."
>
> **Key callout boxes:**
> - "60% of tickets: zero human touch"
> - "7 deterministic safety gates prevent bad code"
> - "Self-healing: detects and recovers from failures automatically"
>
> **Style:** Modern SaaS infographic. White or light background. Rounded rectangles with subtle shadows. Professional but approachable. No code or terminal windows. This is for C-suite and VP-level audience.

### Prompt 3: Safety & Governance Architecture

> Create a diagram showing the three-layer safety architecture of an AI code automation system.
>
> **Layer 1 (bottom) — "Structural Gates":** 7 bash-script checkpoints labeled "No AI involved — deterministic code." Show checks like: artifact exists, complexity matches plan, acceptance criteria present, bug has repro steps, verification readiness.
> Color: teal (#5cc7d1).
>
> **Layer 2 (middle) — "Content Quality":** AI-powered review with a score threshold. Show "Score ≥40 → proceed" and "Score <40 → halt for human." Plus PR diff validation and browser-based UAT verification.
> Color: amber (#f2a23c).
>
> **Layer 3 (top) — "Human Approval Gate":** Shown as a checkpoint that only activates for complex/high-risk work. Label: "Simple tickets auto-approve. Complex tickets require human sign-off."
> Color: red (#ef5d6c) to indicate this is the final safety barrier.
>
> **Bottom annotation:** "Idempotent operations — nothing breaks if retried. Post-mutation state assertions — system verifies every change took effect correctly."
>
> **Style:** Clean, vertical stack. Dark background (#0b0d10). Professional. For a technical leadership audience (CTO, VP Engineering).

### Prompt 4: Fleet Controller Self-Healing Loop

> Create a circular/loop diagram showing the self-healing mechanism of a "Fleet Controller" for AI software pipelines.
>
> **Cycle:**
> 1. "Continuous Monitoring" — every 30 seconds, scans all active pipelines
> 2. "8 Detection Engines" — phase failures, stalls, zombies, loops, abandonment, flow failures, auto-mode blocks, tool errors
> 3. "Severity Assessment" — assigns level 0 (healthy), 1 (warn), 2 (kill), 3 (kill+restart) based on time/count thresholds
> 4. "Automated Intervention" — WARN: write alert to dashboard report. KILL: touch stop files, finalize pipeline log, write audit entry. RESTART: kill + check eligibility + spawn fresh pipeline agent.
> 5. "Dashboard Update" — terminal health table and markdown report refreshed
>
> **Arrows** connect 1→2→3→4→5→1 forming a continuous loop.
>
> **Style:** Circular flow diagram. Dark background (#0b0d10). Each step as a rounded card with icon. Use severity color coding (green for monitoring, amber for detection, red for intervention). Professional DevOps aesthetic. For a platform engineering audience.

### Prompt 5: System Overview — Mixed Audience

> Create a high-level system architecture diagram for an "Autonomous Software Delivery Platform." Keep it simple enough for business stakeholders but accurate enough for technical evaluators.
>
> **Three columns, left to right:**
>
> **Column 1 — "Work Source":** Linear ticket tracker icon + GitHub icon. Arrows point right.
>
> **Column 2 — "AI Pipeline Engine":** Central hub showing the 8-phase pipeline as a horizontal flow: Appraise → Reproduce → Execute → Gate → Implement → PR Review → Verify → Maintenance. Below it, three label badges: "AI Agents" (each phase spawns a fresh isolated agent), "Bash Gates" (deterministic checkpoints, no AI), "Safety Checks" (7 structural invariants).
>
> **Column 3 — "Outcomes":** Three outputs — "Merged PR" (code deployed), "Documentation" (auto-generated context docs), "Wiki Updates" (knowledge base maintained).
>
> **Top bar spanning all columns:** "Fleet Controller — Oversees all pipelines, detects anomalies, self-heals failures."
>
> **Bottom annotation:** "Built on Claude Code plugin architecture. Open-source. Zero user input required for simple tickets."
>
> **Style:** Clean architecture diagram. Light background. Professional but not intimidating. Boxes with subtle borders and rounded corners. Use teal (#5cc7d1) as the primary accent color. Sans-serif font throughout. No terminal windows or code.

---

## Summary: What to build first

| Priority | Diagram | Audience | Format |
|----------|---------|----------|--------|
| 1 | Fleet Controller interactive | Technical evaluators | HTML (Claude Design) |
| 2 | Value Delivery Pipeline | C-suite | Image (ChatGPT) |
| 3 | Safety & Governance | CTO/VP Eng | Image (ChatGPT) |
| 4 | Scale & Throughput | VP/ Director | Image (ChatGPT) |
| 5 | Self-Healing Loop | Platform/DevOps | Image (ChatGPT) |

The fleet controller diagram is the missing piece that elevates this from "a pipeline" to "a platform." Everything else tells the business story around it.
