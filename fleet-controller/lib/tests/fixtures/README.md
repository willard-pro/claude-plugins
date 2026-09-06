# fleet-controller `lib/` test fixtures

## `human-hold-160h-pipeline.log`

Synthetic, scrubbed regression corpus for the production incident that motivated
`human-hold-protocol`: a ticket asked a question (four AC-conflict questions, in this
fixture) and sat unanswered for 160 hours while nothing detected it, notified anyone,
or knew it could safely stop respawning — one real ticket reached generation 8 that
way. Ticket id, questions and artifact paths here are invented; no ticket id, customer
data, or real Linear content appears in this file (public repo).

The fixture's timestamps are fixed in the past (2026-01-01) rather than relative to
"now" — `detect_human_hold`'s age check only needs "old enough to be past
`FLEET_HOLD_WARN_HOURS`", and a fixed historical date satisfies that for as long as
this fixture exists, without the file needing to be regenerated.

**What this pins**: before `human-hold-protocol`, no detector recognised
`META|human-hold` at all — replaying this log against `detect_human_hold` is
meaningless on a pre-change checkout because the function does not exist. After the
change, `detect_human_hold` reports severity 1 for it (never higher — the detector's
own severity cap, see `fleet-controller/CLAUDE.md`). See
`test-fleet-detect.sh:test_human_hold_fixture_replay_reports_warn`.
