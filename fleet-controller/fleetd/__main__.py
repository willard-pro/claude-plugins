"""
fleetd entry point — invoke as `python -m fleetd`.

Usage:
    python -m fleet-controller.fleetd                        # defaults
    python -m fleet-controller.fleetd --port 21002           # custom health port
    python -m fleet-controller.fleetd --state-dir /path      # custom state dir
    python -m fleet-controller.fleetd --pidfile /tmp/f.pid   # custom pidfile
    python -m fleet-controller.fleetd --help                 # usage

Environment variables (all optional):
    FLEET_STATE_DIR    — durable state directory (fallback: FLEETD_WORKSPACE or .)
    FLEET_INSTANCE_ID  — instance namespace (default: "default")
    FLEETD_PORT        — health endpoint port (default: 21001)
    FLEETD_BIND        — health endpoint bind address (default: 127.0.0.1)
    FLEETD_PIDFILE     — single-instance lock file (default: /tmp/fleetd.pid)
    FLEETD_WORKSPACE   — fallback workspace when FLEET_STATE_DIR is unset
    CLAUDE_BIN         — worker binary name (default: "claude")
    CLAUDE_CMD         — full worker command line, overrides CLAUDE_BIN,
                          e.g. "claude-deepseek 2 --bypass"
    FLEET_STARTUP_ENV_CHECK — set "false" to skip the startup env-check gate
                              (default: enabled — see _run_startup_env_check)
"""

import os
import subprocess
import sys
from pathlib import Path

# Allow running from the fleet-controller directory directly:
#   python fleetd/__main__.py
_fleetd_dir = Path(__file__).resolve().parent
if str(_fleetd_dir) not in sys.path:
    sys.path.insert(0, str(_fleetd_dir.parent))

from fleetd.supervisor import Supervisor  # noqa: E402

_ENV_CHECK_SCRIPT = _fleetd_dir.parent / 'lib' / 'fleet-env-check.sh'


def _usage():
    print(__doc__)
    sys.exit(0)


def _run_startup_env_check():
    """Hard-gate fleetd startup on fleet-env-check.sh.

    ticket-auto-pipeline gates every /ticket-auto run on validate-env.sh via
    a Step-0 prose guard the LLM router executes before any pipeline phase.
    fleetd has no such turn to run a guard in — it is the process doing the
    work — so the equivalent gate has to live here, at process start,
    running the same deterministic pipe-delimited check and refusing to
    boot on a nonzero exit rather than spawning workers into a misconfigured
    environment.

    Opt out with FLEET_STARTUP_ENV_CHECK=false — used by fleetd's own
    subprocess-spawning tests, which exercise supervisor mechanics
    (health endpoint, single-instance lock, registry, reap/advance wiring)
    and have no reason to depend on a real LINEAR_API_KEY or CLAUDE_CMD.
    """
    if os.environ.get('FLEET_STARTUP_ENV_CHECK', 'true') == 'false':
        return
    if not _ENV_CHECK_SCRIPT.is_file():
        print(
            f'fleetd: env-check script not found at {_ENV_CHECK_SCRIPT} — skipping startup check',
            file=sys.stderr,
        )
        return
    result = subprocess.run(
        ['bash', str(_ENV_CHECK_SCRIPT)],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        print('fleetd: startup env check failed — refusing to start.', file=sys.stderr)
        print(f'Run `bash {_ENV_CHECK_SCRIPT} --show` for details.', file=sys.stderr)
        if result.stdout:
            print(result.stdout, file=sys.stderr)
        if result.stderr:
            print(result.stderr, file=sys.stderr)
        sys.exit(1)


def main():
    args = sys.argv[1:]
    port = None
    state_dir = None
    pidfile = None
    bind = None

    i = 0
    while i < len(args):
        arg = args[i]
        if arg in ('-h', '--help'):
            _usage()
        elif arg == '--port':
            i += 1
            port = int(args[i]) if i < len(args) else port
        elif arg == '--state-dir':
            i += 1
            state_dir = args[i] if i < len(args) else state_dir
        elif arg == '--pidfile':
            i += 1
            pidfile = args[i] if i < len(args) else pidfile
        elif arg == '--bind':
            i += 1
            bind = args[i] if i < len(args) else bind
        i += 1

    _run_startup_env_check()

    supervisor = Supervisor(
        state_dir=state_dir,
        pidfile=pidfile,
        port=port,
        bind=bind,
    )
    supervisor.run_observe()


if __name__ == '__main__':
    main()
