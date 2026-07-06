---
name: ticket-verify
description: Verifies a Linear ticket fix by loading its requirements, navigating the live app via Playwright, reproducing the original issue steps, and confirming the fix works. Produces a structured pass/fail report. On failure, emits a REMEDIATION_BRIEF that can be fed directly to ticket-implement or a fix skill. Use when the user says "/ticket-verify <ID>", "verify ticket <ID>", "test ticket <ID>", or "check if <ID> is fixed". Accepts optional --user, --password, and --env flags.
---

# Ticket Verify

You have been given a ticket ID as the argument (e.g. `CRE-39`), with optional flags:
- `--user <email>` — login email override. If omitted, derived from the ticket description.
- `--password <password>` — login password override. If omitted, uses `admin` on UAT (the standard test password). On local, the login gate is typically bypassed.
- `--env local|uat` — which environment to test against (default: `local`)
- `--from-auto` — called by ticket-auto or batch. Suppresses all user prompts.
  Missing credentials or nav failures produce a diagnostic FAIL instead
  of asking the user.
- `--no-env-start` — skip Step 1.6 (don't start/check backend services).
  Use when managing the environment manually.

Parse the arguments before proceeding.

**Environment URLs:**
- `local` → Read `LOCAL_URL` from `./CLAUDE.md`. If absent, abort: "No LOCAL_URL configured for this project."
- `uat` → Read `UAT_URL` from `./CLAUDE.md`. If absent, abort: "No UAT_URL configured for this project."

**Credential derivation (UAT only):** If `--user` is not explicitly provided, extract it from the ticket description after Step 1b. If `--password` is not provided, use `admin` on UAT. On local, credentials are typically not needed.

## Pipeline Preamble

Follow the pipeline preamble in `~/.claude/skills/lib/skill-preamble.md` with parameters: TICKET_ID=<from args>, PHASE=VERIFY, FROM_FLAG=none, HAS_LINEAR_ACCESS=true, LINEAR_OPS=get_issue,save_comment, HAS_GUARD=true, HAS_PROJECT_CONTEXT=false, HAS_LOGGING=true, HAS_HEARTBEAT=true, HAS_STEP_DISPATCH=true, HAS_TASK_TRACKER=false

### Heartbeat points
- **Browser session**: after starting Playwright, write `hb-wrap.sh api "browser-session" "ok" "browser session established"`; if session fails, write `hb-wrap.sh api "browser-session" "fail" "browser session failed"`
- **Navigation**: after each page navigation, write `hb-wrap.sh api "browser-navigate" "ok" "navigated to <url>" '{"url":"...","title":"..."}'`
- **Session resume**: if browser session was lost and resumed, write `hb-wrap.sh fallback "browser-resume" "fired" "session lost, rebuilding plan" '{"reason":"Playwright session lost"}'`
- **Verdict**: after the final pass/fail determination, write `hb-wrap.sh decision "verification-verdict" "fired" "PASS|FAIL" '{"verdict":"PASS|FAIL","criteria_met":"N","criteria_total":"M"}'`

### Step dispatch
**Important:** Steps `browser-session`, `navigate`, and `execute-steps` depend on a live Playwright session that is lost when the server crashes. If `--from-step` is one of these values, fall back to `build-plan` instead — always re-run browser steps from scratch.

| `--from-step` value | Effective skip to | Restore from |
|---------------------|-------------------|--------------|
| `load-context` | Step 2 (build plan) | ticket already loaded; re-use from notes.md/context.md |
| `build-plan` | Step 3 (browser session) | re-run Steps 3+ in full |
| `browser-session` | **falls back to `build-plan`** | browser state lost on crash |
| `navigate` | **falls back to `build-plan`** | browser state lost on crash |
| `execute-steps` | **falls back to `build-plan`** | browser state lost on crash |

---

## Step 1 — Load ticket context

### 1a — Load app knowledge and navigation hints

Read both knowledge sources before fetching the ticket:

```bash
cat "$HOME/.claude/skills/app-knowledge/SKILL.md"
```

Then load the project nav hints:

```
/nav-hints list
```

`app-knowledge/SKILL.md` contains business rules, role-based UI behaviour, state mappings, and navigation patterns confirmed across sessions. Use it to interpret what you see in Playwright snapshots and to derive correct navigation without guessing.

`/nav-hints` returns area → click-path mappings learned during previous ticket verification and reproduction sessions. **Never use direct URLs for in-app navigation** — always click through the UI because Angular loses session state on full page reload.

### 1b — Fetch from Linear

Call the Linear access strategy to fetch the ticket (bash `get_issue` when `LINEAR_API_KEY` is set, MCP `get_issue` fallback otherwise).

Capture:
- `title`, `description`, `status`, `labels`, `url`

Parse the description for the following sections (they may use any heading style):
- **Steps to Reproduce** — numbered list of user actions
- **Expected Behaviour / Acceptance Criteria** — what "working" looks like
- **Actual Behaviour / Bug** — what was broken

If these sections are not explicitly labelled, infer them from context.

### 1b5 — Derive credentials (UAT only)

Skip this step if `--env local` is set.

If `--user` was provided, use it. If `--password` was provided, use it. Otherwise:

1. Scan the ticket `description` for an email address matching typical test users (e.g. `user@example.com`). The ticket description often contains a `**User:**` field or an inline mention like "Log in as X (email)".
2. If found → `derived_user = email`, `derived_password = "admin"`.
3. If an email is found but `--user` was also passed → `--user` takes precedence.
4. If an email is found but `--password` was also passed → `--password` takes precedence.
5. If no email found in the description:
   - **If `--from-auto`** → post a comment to the Linear ticket:
     ```
     ⚠️ Cannot verify: no user found in ticket description. Please add the test user email to the ticket (e.g. "**User:** user@example.com").
     ```
     Then abort with a FAIL verdict (skip to Step 7 with WHAT_FAILED = "No test user email in ticket description").
   - **Otherwise** → ask the user: "No user email found in the ticket. Which user should I log in as? (provide --user <email>)"
6. Record the derived credentials for Step 3.

### 1c — Load local workspace

```bash
find "$TICKETS_ROOT" -type d -name "{TICKET-ID}*"
```

If found, read:
- `context.md` — for any additional reproduction detail
- `notes.md` — for the fix summary and any UAT notes left by the implement session
- `artifacts/` — check for any playwright scripts, test plans, or snapshots left by the implementer

If not found, continue — the Linear description alone is sufficient.

### 1d — Load openspec change (if present)

```bash
ls "$TICKETS_ROOT/openspec/changes/" | grep -i "{ticket-id-lowercase}"
```

If found, read `tasks.md` to understand what was implemented and any "Manually verify" tasks — these become your verification checklist.

[ -n "$LOG_FILE" ] && echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|VERIFY|load-context|done|Context loaded" >> "$LOG_FILE"

---

## Step 1.5 — Create task tracker

Create a TaskCreate for every remaining step (Steps 2 through 7). Each task subject = the step heading. After each step is fully done, mark it completed with TaskUpdate. At session end, write a trace file to the ticket directory:

```bash
cat > {ticket-dir}/verify-session.md << 'TRACE'
# verify session — {ISSUE-ID}
**Date:** {today}
**Environment:** {env}
**User:** {--user}
**Verdict:** {PASS|FAIL}

## Step trace
- [x] Step 1.6: Env readiness — {env start status}
- [x] Step 1.7: Verify pre-flight — user:{test_user} nav:{nav_target}
- [x] Step 2: Build verification plan — {N} criteria
- [x] Step 3: Establish browser session — {logged in|already authenticated}
- [x] Step 4: Navigate to feature — {path}, {attempts} attempts
- [x] Step 4b: Execute verification — {N} steps
- [x] Step 5: Evaluate — {PASS|FAIL}
- [x] Step 6/7: Report — {pass report|failure report + REMEDIATION_BRIEF}
TRACE
```

---

## Step 1.6 — Ensure local environment is ready (local only)

Skip entirely if `--env=uat` or `--no-env-start` is set.

### 1.6a — Detect affected backend services

Extract service names from the ticket's notes.md and context.md:

```bash
grep -oP '(?<=microservices/)[a-z][a-z-]+' {ticket-dir}/notes.md {ticket-dir}/context.md 2>/dev/null \
  | grep -v '^gateway-fe$' | sort -u
```

If the ticket dir is not found (no local workspace), affected services = empty (env-start.sh will start all).

### 1.6b — Run env-start.sh (BE + FE)

Always start all services including the gateway FE. `env-start.sh` skips anything already running.

If no specific affected services were detected in 1.6a (or ticket dir missing):

```bash
bash {TICKETS_ROOT}/env-start.sh
```

If specific affected services were detected and the ticket dir exists, restart only those plus the FE:

```bash
bash {TICKETS_ROOT}/env-start.sh --restart {affected-services} gateway-fe
```

Block until the script exits. If it exits non-zero, abort ticket-verify with the script's error — do not proceed to browser.

---

## Step 1.7 — Verify pre-flight (prerequisite resolution)

Before building the verification plan, resolve the test user, navigation target, and expected behavior. This ensures the verify agent has everything needed before launching the browser.

[ -n "$LOG_FILE" ] && echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|VERIFY|pre-flight|start|Resolving verification prerequisites" >> "$LOG_FILE"

### 1.7a — Resolve test user

Use this priority chain (stop at first match):

1. **`--user` flag** — if explicitly passed on the command line, use it verbatim
2. **notes.md `## Verification Readiness` section** — if present, extract the test user from the prerequisite table
3. **context.md `**User:**` field** — if present in the ticket context
4. **Linear ticket description** — scan for `**User:**`, email addresses, or role mentions ("as an attorney", "log in as admin")
5. **`test-users.json` catalog** — resolve the catalog, find a user matching any role mentioned in the ticket. If no specific role is mentioned in the ticket, catalog lookup SHALL return empty (do NOT default to admin — a ticket with zero role mentions is underspecified and should have been blocked earlier in the pipeline)

**If no test user is found:**

- **If `--from-auto`**: abort with FAIL. Do not launch the browser. Post a Linear comment:
  ```
  ⚠️ Cannot verify: no test user found. Resolution chain exhausted — no user in --user flag, notes.md, context.md, ticket description, or test-users.json catalog. Add a test user to the ticket (e.g. "**User:** user@example.com") or provide --user.
  ```
  Write to log:
  ```bash
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|VERIFY|pre-flight|fail|No test user found" >> "$LOG_FILE"
  ```
  Exit with SKIP (no failure — the ticket needs human input).

- **If interactive** (no `--from-auto`): prompt the user: "No test user found. Which user should I log in as? (provide --user <email>)"

**If a test user is found**, record it for use in Step 2 and Step 3b.

### 1.7b — Resolve navigation target

Use this priority chain (stop at first match):

1. **notes.md `## Verification Readiness`** — if present, extract the navigation target
2. **nav-hints.md** — match the ticket's feature area against known nav-hints entries
3. **context.md** — scan for URL patterns (`/handover/`, `/admin/`, etc.)
4. **Linear ticket description** — scan for URL patterns or navigation instructions

**If no navigation target is found:**

- **If `--from-auto`**: log a warning but continue. The verifier has a 3-attempt nav budget and can often discover the page from context.
  ```bash
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|VERIFY|pre-flight|warning|No navigation target found, will use 3-attempt nav budget" >> "$LOG_FILE"
  ```
- **If interactive**: note the gap in the verification plan but continue (the user can guide navigation in Step 4).

### 1.7c — Pre-populate expected behavior

Check if the plan artifact already has expected behavior (from the `## Verification Readiness` section in notes.md):

1. **notes.md `## Verification Readiness`** — if present, extract expected behavior
2. **Linear ticket description** — extract from acceptance criteria, "Expected Behaviour", or "What should be true" sections

If found in notes.md, use it as the basis for verification criteria in Step 2. If not, extract from the Linear ticket description as normal.

[ -n "$LOG_FILE" ] && echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|VERIFY|pre-flight|done|User:{test_user} Nav:{nav_target}" >> "$LOG_FILE"

---

## Step 2 — Build the verification plan

### 2a — Derive the navigation path

Using the ticket title, labels, description, and context.md, determine where in the app to navigate. Use this priority order:

1. **Explicit URL** — if the ticket description or notes.md contains a path (e.g. `/handover/123`, `/admin/users`), use it. **Only** use it to identify the URL pattern — the actual navigation must still be done via UI clicks (Step 4), never `page.goto()`.
2. **Nav hints** — read `{TICKETS_ROOT}/nav-hints.md` and match the ticket's feature area (e.g. "Handover Payments", "Handover Progress") against known area headings. The hint provides the exact click-by-click path. **Do not use the URL from the hint for `page.goto()`** — use it only to verify you landed in the right place. Always execute the click-by-click steps.
3. **Inference from labels and title** — derive the likely feature area from keywords:
   - "Handover" / "correspondent" → Handover Correspondents
   - "Attorney" / "Legal" → Handover List (Active filter = LEGAL state)
   - "Payment" → Handover Payments (receipt icon on handover row)
   - "Progress" → Handover Progress
   - "Administration" / "User" / "Organisation" → Administration
   - "Credit report" → Credit Report
   - If uncertain, start from the handover list and explore via the action icons

Record the **derived area** and its **source** (explicit / nav-hints / inferred). Include this in the plan.

### 2b — Expand acceptance criteria into atomic items

Before writing the plan, extract every requirement from the ticket description and **expand compound requirements into individual atomic items**. A criterion is atomic if it describes exactly one observable fact that can be independently confirmed in the UI.

Rules for expansion:
- A list with N items → N separate criteria (e.g. "dropdown offers Plaintiff, Defendant, and Attorney" → three criteria, one per type)
- "A and B" in a single sentence → two criteria
- "Only X may be added" → one criterion confirming X is present AND one confirming non-permitted types are absent (if testable)
- Vague phrases like "works correctly" or "is enabled" → replace with the specific observable: element label, disabled/enabled state, visible/absent element

Write out the expanded criteria as a numbered list before proceeding to the plan template. This list becomes the pass criteria verbatim.

### 2c — Write the plan

Construct and print the **Verification Plan**:

```
## Verification Plan — {TICKET-ID}: {title}

**Environment:** {env} ({base URL})
**Test user:** {--user value}
**Navigation path:** {derived path} (source: {explicit|nav-hints|inferred})

**What was broken:** {one sentence from Actual Behaviour}
**What should be true now:** {one sentence from Expected Behaviour / AC}

### Acceptance criteria (expanded — each item verified independently)
1. {atomic criterion — one observable fact}
2. {atomic criterion}
3. {atomic criterion}
...

### Steps
1. Navigate to {derived path}
2. {action derived from Steps to Reproduce}
3. {action}
...

### Pass criteria
- [ ] {criterion 1 from expanded list above}
- [ ] {criterion 2}
- [ ] {criterion 3}
...
```

**Each pass criterion maps 1:1 to an expanded acceptance criterion. Never collapse multiple requirements into one criterion line.**

If `--from-auto` is NOT set:
  Pause here and ask the user: **"Does this plan look right? (yes / adjust: ...)"**
  If the user adjusts, update the plan accordingly. If yes, proceed to Step 3.

If `--from-auto` IS set:
  Print the plan and proceed directly to Step 3 (no user prompt).

[ -n "$LOG_FILE" ] && echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|VERIFY|build-plan|done|{N} criteria" >> "$LOG_FILE"

---

## Step 3 — Establish browser session

### 3a — Navigate to the app

```playwright
mcp__plugin_playwright_playwright__browser_navigate: {base URL from --env}
```

Take a snapshot. If the nav already shows an authenticated user name, skip 3b.

### 3b — Log in

Use the credentials from Step 1b5 (derived or explicit).

Open the login dialog:
- Click **Account** in the nav to expand the dropdown
- Click **Sign in**

Fill the login form with `{derived_user}` and `{derived_password}`.

Click **Sign in**. Take a snapshot. Confirm the nav shows the authenticated user name.

If login fails:

- **On UAT** (password is always `admin`): post a comment to the Linear ticket:
  ```
  ⚠️ Login failed for {derived_user} with default password "admin". The account may use a different password or be locked. Please verify credentials and re-run with --user and --password flags.
  ```
  Then abort with a FAIL verdict (skip to Step 7 with WHAT_FAILED = "Login failed for {derived_user}").
- **On local**: report and stop as above (local env may have different requirements).

[ -n "$LOG_FILE" ] && echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|VERIFY|browser-session|done|Logged in as {--user}" >> "$LOG_FILE"

---

## Step 4 — Navigate to the feature under test

This step uses a **3-attempt** budget to reach the correct location before escalating to the user.

### Attempt tracking

Maintain a counter `nav_attempts = 0`. Each time you try a click path and it does not show the expected content, increment the counter.

### Attempt loop

**For each attempt (up to 3):**

1. Execute the click-by-click steps from the nav-hints entry (or the inferred path from Step 2a). **Never use `page.goto()` for in-app navigation** — Angular loses session state on full reload.
2. Take a snapshot.
3. Evaluate the snapshot:
   - **Success** — the page shows content related to the ticket's feature area (relevant headings, buttons, forms, or list items mentioned in the ticket). Proceed to Step 4b.
   - **Wrong page** — the page looks unrelated, shows a 404, redirects to `/accessdenied`, or the expected component is absent. Increment `nav_attempts`. Try the next candidate path.

**Candidate click paths to try in order (if the first fails):**
1. The exact click path from the matched nav-hints entry.
2. A parent/sibling click path (e.g. if "Handover Progress" fails, go to "Handover Payments" first using its nav-hints entry, then look for tabs/links to Progress).
3. Explore the nav: start from the root page (click Home), then click through nav bar items that match the feature area until reaching the target.

**Important:** If any attempt results in an `/accessdenied` redirect, do NOT try that URL or click path again. The nav bar will likely be broken after `/accessdenied` — navigate to the root URL (`/`) to restore session, then continue with the next attempt.

### After 3 failed attempts

If `nav_attempts == 3` and the correct page has not been reached:

- **If `--from-auto`** → record the 3 attempted paths and proceed directly to Step 7 (failure report). Include nav diagnostics in WHAT_FAILED:
  ```
  Navigation failed after 3 attempts. Tried: {path1}, {path2}, {path3}. Target area: {feature area}.
  ```
- **Otherwise** → stop and ask:

  > "I tried {list the 3 paths attempted} but couldn't find the {feature area} section. Where should I navigate to test this? (e.g. `/handover/456` or click path through the UI)"

  Wait for the user's answer. Use the provided path as attempt 4 and proceed.

### Save new navigation knowledge (Step 4a)

Once the correct page is reached — whether via the plan, retry, or user input — **if the area was not already in `{TICKETS_ROOT}/nav-hints.md`**, save it now.

Append to `{TICKETS_ROOT}/nav-hints.md` (create the file if it doesn't exist):

```markdown
## {feature area label}
- **Path:** {exact URL pattern, e.g. `/handover-payment/{id}`}
- **How to reach:** {numbered click-by-click steps — no `page.goto()` references}
- **Learned from:** {TICKET-ID}
- **Date:** {today's date}
```

Tell the user: `"Saved navigation hint for '{feature area}' to nav-hints.md for future tickets."`

[ -n "$LOG_FILE" ] && echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|VERIFY|navigate|done|Reached {feature area}" >> "$LOG_FILE"

---

## Step 4b — Execute verification steps

With the browser now on the correct page, work through each remaining step in the Verification Plan sequentially. For **every step**:

1. Perform the Playwright action (navigate, click, fill, select, etc.)
2. Take a snapshot with `mcp__plugin_playwright_playwright__browser_snapshot`
3. Record the **observed result** — what you see in the snapshot

Capture after each step:
- The snapshot YAML (accessibility tree)
- The current URL
- Any new console errors: `mcp__plugin_playwright_playwright__browser_console_messages`

At any point, if the observed result contradicts a pass criterion, mark that criterion **FAIL** and record:
- The step number
- What was expected
- What was observed (quote element labels, button states, error messages verbatim from the snapshot)

Continue executing remaining steps unless the page is in a broken state (crash, blank page, unexpected auth redirect).

[ -n "$LOG_FILE" ] && echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|VERIFY|execute-steps|done|{N} steps executed" >> "$LOG_FILE"

---

## Step 5 — Evaluate pass/fail

### Pass

All pass criteria are met → proceed to Step 6.

### Fail

One or more pass criteria are not met → proceed to Step 7.

---

## Step 6 — Pass report

Print to the user:

```
## ✅ {TICKET-ID} — VERIFIED PASS

**Ticket:** {Linear URL}
**Environment:** {env} ({base URL})
**Tested as:** {--user}

### Criteria
| Criterion | Result |
|---|---|
| {criterion} | ✅ Pass |

### Evidence
- Step {N}: {brief description of what was observed confirming the fix}

**Recommendation:** Ready to merge / promote.
```

Append to `{ticket-dir}/notes.md`:
```markdown
### {today's date} — Verification PASS ({env})
- **User:** {--user}
- **Criteria:** {N}/{N} passed
- **Evidence:** {brief summary}
```

### If `--env local`: Open PR and close out

Verification passed on localhost — the implementation is confirmed working. Now open the PR:

1. Read `notes.md` for the branch name and repo from the `committed` entry.
2. For each affected repo, check if a PR already exists for this branch, then open one against `develop` if needed:
   ```bash
   existing_pr=$(cd {repo-path} && gh pr list --head {branch-name} --json url --jq '.[0].url' 2>/dev/null)
   if [ -n "$existing_pr" ]; then
     echo "PR already exists: $existing_pr"
   else
     cd {repo-path} && gh pr create --base develop --head {branch-name} \
       --title "{type}({TICKET-ID}): {description}" \
       --body "$(cat <<'EOF'
   ## Summary
   {bullets from the plan}
   
   ## Test plan
   - [x] ticket-verify --env local PASS ({N}/{N} criteria)
   EOF
     )"
   fi
   ```
3. Capture the PR URL(s).
4. Delegate to the flow executor:
   ```
   /ticket-flow {TICKET-ID} implement-complete
   _rc=$?
   if [ "$_rc" -ne 0 ]; then
     hb-wrap.sh retry "flow-sh" "fail" "flow.sh implement-complete failed (exit ${_rc})" \
       "{\"trigger\":\"implement-complete\",\"exit_code\":\"${_rc}\",\"ticket\":\"{TICKET-ID}\"}"
     echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|META|flow-error|fail|exit ${_rc}: implement-complete" >> {LOG_FILE}
   fi
   ```
   This moves state → `Review` and removes `approved`.

5. Append to `notes.md`:
   ```markdown
   - PRs: {repo}: {URL}
   - Status → Review
   ```

### Post findings to Linear (all environments, pass)

Post via the Linear access strategy (bash `save_comment` when `LINEAR_API_KEY` is set, MCP `save_comment` fallback otherwise):

```
✅ ticket-verify PASS — {env}

**Tested as:** {--user}
**Date:** {today}

| Criterion | Result |
|---|---|
| {criterion} | ✅ Pass |

All acceptance criteria confirmed. {For local: PR {URL} opened against develop. | For uat: Ticket moved to Done.}
```

### If `--env uat`: Move to Done

No PR creation. Delegate the state transition:

```
/ticket-flow {TICKET-ID} uat-pass
_rc=$?
if [ "$_rc" -ne 0 ]; then
  hb-wrap.sh retry "flow-sh" "fail" "flow.sh uat-pass failed (exit ${_rc})" \
    "{\"trigger\":\"uat-pass\",\"exit_code\":\"${_rc}\",\"ticket\":\"{TICKET-ID}\"}"
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|META|flow-error|fail|exit ${_rc}: uat-pass" >> {LOG_FILE}
fi
```

This moves state → `Done` and removes `claimed` + `reviewed`.

---

## Step 7 — Failure report

### 7a — Collect diagnostics

1. **Console errors** — `mcp__plugin_playwright_playwright__browser_console_messages` (errors only, not warnings)
2. **Current URL** — from the last snapshot
3. **Last snapshot YAML** — accessibility tree at the point of failure
4. **Failed step** — step number, expected vs. observed

### 7b — Write the failure report

Print to the user:

```
## ❌ {TICKET-ID} — VERIFICATION FAILED

**Ticket:** {Linear URL}
**Environment:** {env} ({base URL})
**Tested as:** {--user}
**Failed at step:** {N} — {step description}

### Criteria result
| Criterion | Result |
|---|---|
| {passing criterion} | ✅ Pass |
| {failing criterion} | ❌ FAIL |

### What happened
**Expected:** {expected behaviour from pass criterion}
**Observed:** {what was actually seen — quote element labels and states verbatim}

### Diagnostics
**URL at failure:** {url}
**Console errors:**
{list, or "none"}

**Snapshot at failure (relevant excerpt):**
{10–20 most relevant lines of the accessibility tree YAML, focused on the component under test}
```

### 7c — Emit the REMEDIATION_BRIEF

After the failure report, emit this block verbatim (preserving delimiter lines and key names — downstream skills parse them):

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
REMEDIATION_BRIEF — paste into /ticket-implement or a fix skill
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

TICKET_ID: {TICKET-ID}
TICKET_TITLE: {title}
TICKET_URL: {Linear URL}
ENV: {env}
TEST_USER: {--user}

WHAT_WAS_EXPECTED:
{1–3 sentences describing the expected behaviour from the acceptance criteria}

WHAT_FAILED:
{1–3 sentences describing exactly what was observed — be specific: UI element names,
button states (disabled/enabled), error messages, missing elements}

FAILED_AT_STEP: {N} — {step description}

CONSOLE_ERRORS:
{list, or "none"}

SNAPSHOT_EXCERPT:
{10–20 most relevant lines of the accessibility tree YAML at the failure point,
focused on the component under test}

CURRENT_URL: {url}

CONTEXT_FILES:
- {ticket-dir}/context.md  (or "not found locally")
- {ticket-dir}/notes.md    (or "not found locally")
- {openspec change tasks.md path, or "none"}

SUGGESTED_FIX:
{2–4 sentence hypothesis about what is likely still broken in the code. Reference
specific file names, component names, Angular template bindings, or Java service
methods if known from notes.md or openspec tasks. If unknown, say so explicitly
rather than guessing.}
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

### 7c5 — Write REMEDIATION_BRIEF to plan artifact

After emitting the brief in chat, persist it to the plan artifact so `ticket-implement` can read the structured remediation data (SUGGESTED_FIX, SNAPSHOT_EXCERPT, diagnostics, context files).

**Detect plan artifact** (same detection as `ticket-implement` Step 2):

```bash
find . -name "simple-fix.md" -path "*{TICKET-ID}*"
```

- Found → `PLAN = {output-path}`, mode = `simple-fix`
- Not found:
  ```bash
  ls openspec/changes/ | grep -i "{ticket-id-lowercase}"
  ```
  If found → `PLAN = openspec/changes/{change-name}/tasks.md`, mode = `openspec`
- Neither found → skip write. Report: "No plan artifact found for REMEDIATION_BRIEF — brief emitted to chat and notes.md only."

**Count existing sections and write atomically:**

Count `^## Verification #` lines in the plan to determine `N` (0 if none).

Write to a temporary file first, then atomically rename:
```bash
PLAN_TMP="${PLAN}.tmp"
# Write: original content + new section + closing marker
cat "$PLAN" > "$PLAN_TMP"
cat >> "$PLAN_TMP" << 'SECTION'

## Verification #{N+1}

**Date:** {today's date}
**Environment:** {env}
**Failed at step:** {N} — {step description}
**Test user:** {--user}

### Expected
{WHAT_WAS_EXPECTED — 1–3 sentences}

### Observed
{WHAT_FAILED — 1–3 sentences}

### Suggested Fix
{SUGGESTED_FIX — 2–4 sentence hypothesis from the brief}

### Diagnostics
**URL at failure:** {CURRENT_URL}
**Console errors:** {CONSOLE_ERRORS content}
**Snapshot excerpt:**
{SNAPSHOT_EXCERPT content}

### Context Files
{CONTEXT_FILES list items}

<!-- /REMEDIATION_BRIEF -->
SECTION

# Atomic rename — partial writes never visible at the destination
mv "$PLAN_TMP" "$PLAN" || {
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|META|gate-stop|fail|REMEDIATION_BRIEF_TRUNCATED — rename failed: $PLAN" >> "$LOG_FILE"
  cl_write RETRO hint info "REMEDIATION_BRIEF atomic rename failed — plan path: $PLAN, TMP: $PLAN_TMP. Check filesystem permissions and cross-device rename restrictions"
  rm -f "$PLAN_TMP"
  exit 1
}
```

If the write or rename fails for any reason, emit `|META|gate-stop|fail|REMEDIATION_BRIEF_TRUNCATED` and abort. The `.tmp` file is removed on the way out.

### 7d — Record in notes.md

Append to `{ticket-dir}/notes.md`:
```markdown
### {today's date} — Verification FAIL ({env})
- **User:** {--user}
- **Failed at step:** {N} — {step description}
- **Expected:** {expected}
- **Observed:** {observed}
- **Console errors:** {count or "none"}
- **Plan updated:** {PLAN path or "not found"} — `## Verification #{N+1}` appended
```

### 7e — Post findings to Linear

Post via the Linear access strategy (bash `save_comment` when `LINEAR_API_KEY` is set, MCP `save_comment` fallback otherwise):

```
❌ ticket-verify FAIL — {env}

**Tested as:** {--user}
**Date:** {today}
**Failed at step:** {N} — {step description}

| Criterion | Result |
|---|---|
| {passing criterion} | ✅ Pass |
| {failing criterion} | ❌ FAIL |

**Expected:** {expected behaviour}
**Observed:** {observed behaviour — verbatim element labels/states}

**Console errors:** {list or "none"}
```

### 7f — Update Linear state (UAT only)

If `--env uat`:

```
/ticket-flow {TICKET-ID} uat-fail
_rc=$?
if [ "$_rc" -ne 0 ]; then
  hb-wrap.sh retry "flow-sh" "fail" "flow.sh uat-fail failed (exit ${_rc})" \
    "{\"trigger\":\"uat-fail\",\"exit_code\":\"${_rc}\",\"ticket\":\"{TICKET-ID}\"}"
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|META|flow-error|fail|exit ${_rc}: uat-fail" >> {LOG_FILE}
fi
```

This moves state → `Ready`, adds `rejected`, removes `reviewed`. A human must run `/ticket-flow {TICKET-ID} human-approve` before the next implementation cycle can start.

If `--env local`: no state change — the ticket is still in `Ready`, code just needs more work.

The REMEDIATION_BRIEF above feeds `ticket-implement` for the fix round.

---

## Notes

- **Session reuse:** If the browser is already open and logged in at the correct environment, skip Step 3b. Detect this from the snapshot — if the nav shows a user name, proceed directly to Step 4.
- **Snapshot verbosity:** Trim snapshots to the relevant component subtree in all reports. Full snapshots can be hundreds of lines — include only what is needed to understand the failure.
- **Multiple failing criteria:** If more than one criterion fails, report all of them in 7b and 7c. The WHAT_FAILED and SNAPSHOT_EXCERPT should cover the first failure point; list subsequent failures under a `ADDITIONAL_FAILURES:` key in the brief.
- **Scope:** This skill does not modify source code. It posts a verification comment to Linear on both pass and fail. On UAT fail it also triggers `uat-fail` (state → `Ready`, label `rejected`). Local pass triggers `implement-complete` (state → `Review`). The business partner handles the final UAT → Done transition manually.
- **REMEDIATION_BRIEF format is canonical** — do not reformat the delimiter lines or key names.
