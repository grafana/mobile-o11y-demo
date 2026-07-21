#!/usr/bin/env python3
"""Run a command with a hard timeout and forced process-group cleanup."""

import os
import signal
import subprocess
import sys


KILL_GRACE_SECONDS = 30


def main() -> int:
    if len(sys.argv) < 3:
        print(f"Usage: {sys.argv[0]} <timeout-seconds> <command> [args...]", file=sys.stderr)
        return 2

    try:
        timeout_seconds = int(sys.argv[1])
    except ValueError:
        print("timeout-seconds must be an integer", file=sys.stderr)
        return 2

    command = sys.argv[2:]
    process = subprocess.Popen(command, start_new_session=True)

    try:
        return process.wait(timeout=timeout_seconds)
    except subprocess.TimeoutExpired:
        print(
            f"Command timed out after {timeout_seconds} seconds: {' '.join(command)}",
            file=sys.stderr,
        )
        os.killpg(process.pid, signal.SIGTERM)

        try:
            process.wait(timeout=KILL_GRACE_SECONDS)
        except subprocess.TimeoutExpired:
            print(
                f"Command did not stop after {KILL_GRACE_SECONDS} seconds; forcing termination",
                file=sys.stderr,
            )
            os.killpg(process.pid, signal.SIGKILL)
            process.wait()

        return 124


if __name__ == "__main__":
    sys.exit(main())
