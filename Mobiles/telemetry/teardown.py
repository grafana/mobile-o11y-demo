#!/usr/bin/env python3
"""Stop local dual-stack forwarding and restore normal build inputs."""
import os
import sys
from setup import RUN, setup_lock, shutdown


def main():
    if len(sys.argv) > 1:
        print(__doc__ + '\nUsage: python3 Mobiles/telemetry/teardown.py')
        return 0 if sys.argv[1:] in (['--help'], ['-h']) else 2
    with setup_lock():
        if RUN.exists():
            shutdown()
    print('Dual-stack setup stopped. Saved destinations and Docker volumes are kept.')
    print('Sync/rebuild/reinstall apps to use original endpoints. Restart Metro if used.')
    return 0


if __name__ == '__main__':
    os.umask(0o077)
    try:
        sys.exit(main())
    except (OSError, ValueError, RuntimeError):
        print('Teardown incomplete. Check private .runtime/local logs and retry.', file=sys.stderr)
        sys.exit(1)
