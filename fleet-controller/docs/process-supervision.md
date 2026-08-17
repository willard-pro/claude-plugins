# fleetd Process Supervision

`fleetd` is a long-lived daemon. Every crash-recovery guarantee it provides —
worker adoption, generation fencing, startup orphan reconciliation — only
takes effect once fleetd's own process comes back up after a crash. Without
external supervision, a fleetd crash silently ends the fleet run with no
automatic recovery of any kind. This document covers how to keep fleetd
running.

## Primary path: systemd

A systemd unit ships at `fleet-controller/systemd/fleetd.service`.

### System unit (root)

```bash
sudo cp fleet-controller/systemd/fleetd.service /etc/systemd/system/
# Edit the unit: ExecStart, WorkingDirectory, FLEET_STATE_DIR, User, Group.
sudo systemctl daemon-reload
sudo systemctl enable --now fleetd
sudo systemctl status fleetd
```

### User unit (no root)

```bash
mkdir -p ~/.config/systemd/user
cp fleet-controller/systemd/fleetd.service ~/.config/systemd/user/
# Edit the unit: remove User=/Group= (user units cannot set them) and set
# ExecStart/WorkingDirectory/FLEET_STATE_DIR to your paths.
systemctl --user daemon-reload
systemctl --user enable --now fleetd
systemctl --user status fleetd
```

### Unit behavior

- `Type=simple` — fleetd stays in the foreground; systemd tracks it directly.
- `Restart=always` — restarts on any non-clean exit (crash, unhandled
  exception, OOM kill). A deliberate `systemctl stop` is NOT restarted.
- `RestartSec=5` — bounded restart delay.
- `StartLimitIntervalSec=600` / `StartLimitBurst=10` — a persistently
  crashing fleetd stops looping after 10 starts in 10 minutes and waits for
  operator intervention instead of restarting forever.
- The unit sets `FLEET_STATE_DIR` explicitly: fleetd's durable state (spawn
  queue, run registry, fence markers) lives under the workspace, never `/tmp`.
- **State-dir contract**: `FLEET_STATE_DIR` must be the directory that
  DIRECTLY CONTAINS the per-ticket pipeline logs (`{tid}-pipeline.log`).
  Workers write their logs to `$PWD/logs`, and `WorkingDirectory` is the
  workspace root — so the state dir is the workspace's `logs/` directory.
  Detection and startup reconciliation glob
  `{FLEET_STATE_DIR}/*-pipeline.log`; pointing the state dir anywhere that
  holds no pipeline logs makes both silent no-ops.

### Race safety with the single-instance lock

fleetd enforces single-instance semantics with an `fcntl.flock` on its
pidfile. If systemd's restart races an instance that is still shutting down
(still holding the lock), the new instance fails the lock and exits — it
never runs as a second concurrent supervisor against the same workspace.
The kernel releases the lock when the prior process exits, so the *next*
restart attempt proceeds normally. This is existing fleetd behavior —
systemd's restart mechanism composes with it without modification.

## Fallback path: cron watchdog (hosts without systemd)

A minimal cron watchdog achieves the same automatic-restart guarantee on
hosts without systemd. It checks whether a fleetd process is alive and
starts one if not:

```bash
# /etc/cron.d/fleetd-watchdog — every minute
* * * * * root pgrep -f 'fleet-controller.fleetd' >/dev/null || /usr/local/bin/start-fleetd.sh >> /var/log/fleetd-watchdog.log 2>&1
```

`start-fleetd.sh`:

```bash
#!/usr/bin/env bash
# Start fleetd in the background, detached from the terminal.
cd /path/to/tickets-workspace || exit 1
# State-dir contract: must be the directory that directly contains the
# per-ticket pipeline logs (workers write to $PWD/logs).
export FLEET_STATE_DIR=/path/to/tickets-workspace/logs
nohup /usr/bin/python3 -m fleet-controller.fleetd >> /var/log/fleetd.log 2>&1 &
```

Notes on the cron fallback:

- `pgrep -f` matches the fleetd command line; it does not verify the lock,
  which is fine — if a stale process lingers, the fresh fleetd fails its own
  single-instance lock and exits, exactly as with systemd.
- The watchdog itself is stateless cron, not a custom daemon: a watchdog
  daemon would need its own supervision, which does not converge.
- Startup is bounded to a one-minute granularity — acceptable for a
  recovery mechanism whose next steps (orphan reconciliation, detection)
  run on 30-second cycles anyway.

## Verifying supervision

1. Start fleetd under the chosen supervisor.
2. `kill -9 $(pgrep -f fleet-controller.fleetd)`.
3. Confirm the supervisor restarts it (systemd: `systemctl status fleetd`
   shows a restart; cron: wait up to a minute).
4. Confirm the health endpoint responds again:
   `curl -s http://127.0.0.1:21001/health`.
5. Confirm exactly one instance holds the lock (the health payload shows
   one supervisor; a second concurrent instance is impossible by design).
