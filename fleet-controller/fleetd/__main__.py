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
"""

import sys
from pathlib import Path

# Allow running from the fleet-controller directory directly:
#   python fleetd/__main__.py
_fleetd_dir = Path(__file__).resolve().parent
if str(_fleetd_dir) not in sys.path:
    sys.path.insert(0, str(_fleetd_dir.parent))

from fleetd.supervisor import Supervisor  # noqa: E402


def _usage():
    print(__doc__)
    sys.exit(0)


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

    supervisor = Supervisor(
        state_dir=state_dir,
        pidfile=pidfile,
        port=port,
        bind=bind,
    )
    supervisor.run_observe()


if __name__ == '__main__':
    main()
