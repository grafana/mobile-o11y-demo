#!/usr/bin/env python3
"""Local/CI forwarding supervisor. Python standard library only."""
import argparse
import fcntl
import json
import os
from pathlib import Path
import shutil
import signal
import socket
import ssl
import subprocess
import sys
import time
from urllib.request import urlopen

from configure import (HERE, ROOT, PORTS, write, load_destinations, alloy_config,
                       nginx_config, docker_config, app_configs)


def get(url):
    with urlopen(url, timeout=2) as response:
        return response.read().decode()


def healthy(run):
    try:
        ports = json.loads((run / 'ports.json').read_text())
        get(f'http://127.0.0.1:{ports["alloy"]}/-/ready')
        get(f'http://127.0.0.1:{ports["faro"]}/ready')
        return True
    except (OSError, ValueError):
        return False


def queues_empty(port):
    text = get(f'http://127.0.0.1:{port}/metrics')
    samples = [line for line in text.splitlines() if line.startswith('otelcol_exporter_queue_size{')]
    return bool(samples) and all(float(line.rsplit(' ', 1)[1]) == 0 for line in samples)


def stop_child(child, sig=signal.SIGTERM, timeout=20):
    if child is None:
        return
    try:
        os.killpg(child.pid, sig)
    except ProcessLookupError:
        pass
    try:
        child.wait(timeout=timeout)
    except subprocess.TimeoutExpired:
        os.killpg(child.pid, signal.SIGKILL)
        child.wait()


def serve(args):
    run = args.run_dir
    run.mkdir(parents=True, exist_ok=True, mode=0o700)
    run.chmod(0o700)
    # Lock covers preparation and lifetime. Never signal PIDs recovered from stale files.
    lock = (run / 'lock').open('w')
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        raise RuntimeError('This run directory is already active') from None
    children = []
    command = None
    logs = []
    stopping = False
    def request_stop(*_):
        nonlocal stopping
        stopping = True
    old_signals = {sig: signal.signal(sig, request_stop) for sig in (signal.SIGINT, signal.SIGTERM)}
    for name in ('ready', 'stop', 'result.json'):
        (run / name).unlink(missing_ok=True)
    result = 0
    try:
        ports = {k: v + args.port_offset for k, v in PORTS.items()}
        for port in ports.values():
            with socket.socket() as sock:
                sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
                sock.bind(('127.0.0.1', port))
        targets = load_destinations(args.destinations)
        ca_file = args.ca_file or next((p for p in (ssl.get_default_verify_paths().cafile, '/etc/ssl/cert.pem', '/etc/ssl/certs/ca-certificates.crt') if p and Path(p).is_file()), None)
        if not ca_file or not Path(ca_file).is_file():
            raise RuntimeError('No TLS CA bundle found; set --ca-file')
        write(run / 'ports.json', json.dumps(ports))
        write(run / 'forward.alloy', alloy_config(targets, ports))
        write(run / 'nginx.conf', nginx_config(targets, ports['faro'], ca_file))
        env = app_configs(run, args.platform, ports, backend_port=3333 if args.docker_backend else None)
        if args.docker_backend:
            write(run / 'backend.alloy', docker_config(targets))
            # Existing Compose files still own discovery, services and their lifecycle.
            override = {'services': {'alloy': {'volumes': [f'{run}/backend.alloy:/config.alloy:ro'],
                'stop_grace_period': '30s'}}}
            write(run / 'compose.json', json.dumps(override))
        for tool in (args.alloy, args.nginx):
            if not shutil.which(tool):
                raise RuntimeError('Forwarding binary missing; run install-tools.sh or set ALLOY_BIN/NGINX_BIN')
        for tool, argv in (
            ('alloy', [args.alloy, 'run', str(run / 'forward.alloy'), f'--server.http.listen-addr=127.0.0.1:{ports["alloy"]}', '--storage.path=' + str(run / 'alloy-data')]),
            ('nginx', [args.nginx, '-p', str(run) + '/', '-c', str(run / 'nginx.conf'), '-g', 'daemon off;']),
        ):
            log = (run / f'{tool}.log').open('w')
            logs.append(log)
            children.append(subprocess.Popen(argv, stdout=log, stderr=subprocess.STDOUT, start_new_session=True))
        deadline = time.monotonic() + 30
        while not healthy(run):
            if stopping or any(p.poll() is not None for p in children) or time.monotonic() > deadline:
                raise RuntimeError('Forwarding startup failed; inspect private run logs')
            time.sleep(.2)
        write(run / 'ready', 'ready\n')
        print(f'Forwarding ready. Build configuration: {run / "env.sh"}', flush=True)
        if args.command:
            command = subprocess.Popen(args.command, env={**os.environ, **env}, start_new_session=True)
        while not stopping and not (run / 'stop').exists():
            if any(p.poll() is not None for p in children):
                raise RuntimeError('A forwarding process exited; inspect private run logs')
            if command and command.poll() is not None:
                result = command.returncode
                break
            time.sleep(.2)
        if stopping:
            result = 130
    except BaseException:
        result = 1
        raise
    finally:
        (run / 'ready').unlink(missing_ok=True)
        stop_child(command)
        # SDKs need their own export window before apps are terminated. Here we finish
        # in-flight Faro mirrors, then give OTLP queues bounded time to empty.
        if len(children) == 2:
            stop_child(children.pop(), signal.SIGQUIT)
            deadline = time.monotonic() + args.drain_seconds
            empty_since = None
            while time.monotonic() < deadline and children[0].poll() is None:
                try:
                    empty = queues_empty(ports['alloy'])
                except OSError:
                    empty = False
                empty_since = (empty_since or time.monotonic()) if empty else None
                if empty_since and time.monotonic() - empty_since >= 2:
                    break
                time.sleep(.5)
            else:
                if args.drain_seconds:
                    print('OTLP drain deadline reached; delivery may be incomplete.', file=sys.stderr)
        for child in reversed(children):
            stop_child(child)
        for log in logs:
            log.close()
        write(run / 'result.json', json.dumps({'exit_code': result}))
        for sig, handler in old_signals.items():
            signal.signal(sig, handler)
        lock.close()
    return result


def active(run):
    try:
        with (run / 'lock').open('r') as lock:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                return False
            except BlockingIOError:
                return True
    except FileNotFoundError:
        return False


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=('run', 'start', 'stop', 'status'))
    parser.add_argument('--profile', choices=('default', 'dual-stack'), default='default')
    parser.add_argument('--destinations', type=Path)
    parser.add_argument('--platform', choices=('ios', 'android'), default='ios')
    parser.add_argument('--run-dir', type=Path, default=HERE / '.runtime/run')
    parser.add_argument('--port-offset', type=int, default=0)
    parser.add_argument('--drain-seconds', type=float, default=30)
    parser.add_argument('--ca-file')
    parser.add_argument('--alloy', default=os.environ.get('ALLOY_BIN', str(HERE / '.runtime/tools/alloy')))
    parser.add_argument('--nginx', default=os.environ.get('NGINX_BIN', str(HERE / '.runtime/tools/nginx')))
    parser.add_argument('--docker-backend', action='store_true')
    argv = sys.argv[1:]
    command = argv[argv.index('--') + 1:] if '--' in argv else []
    args = parser.parse_args(argv[:argv.index('--')] if '--' in argv else argv)
    args.command = command
    args.run_dir = args.run_dir.resolve()
    if args.destinations:
        args.destinations = args.destinations.resolve()
    if args.drain_seconds < 0 or not 0 <= args.port_offset < 48000:
        parser.error('Invalid drain time or port offset')
    if args.action == 'status':
        ok = active(args.run_dir) and (args.run_dir / 'ready').exists() and healthy(args.run_dir)
        print('ready' if ok else 'not ready')
        return 0 if ok else 1
    if args.action == 'stop':
        if not active(args.run_dir):
            return 0
        write(args.run_dir / 'stop', 'stop\n')
        deadline = time.monotonic() + args.drain_seconds + 65
        while active(args.run_dir):
            if time.monotonic() > deadline:
                raise RuntimeError('Shutdown timed out; inspect private run logs')
            time.sleep(.2)
        return 0
    if args.profile == 'default':
        return subprocess.call(command) if command else 0
    if args.action == 'start':
        if command:
            parser.error('Use run to wrap a command')
        if active(args.run_dir):
            raise RuntimeError('This run directory is already active')
        args.run_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
        (args.run_dir / 'ready').unlink(missing_ok=True)
        with (args.run_dir / 'supervisor.log').open('w') as log:
            child = subprocess.Popen([sys.executable, str(Path(__file__).resolve()), 'run', *sys.argv[2:]],
                                     stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
        deadline = time.monotonic() + 40
        while not (args.run_dir / 'ready').exists():
            if child.poll() is not None or time.monotonic() > deadline:
                stop_child(child, timeout=args.drain_seconds + 65)
                raise RuntimeError('Startup failed; inspect private run logs')
            time.sleep(.2)
        print(f'Forwarding ready. Build configuration: {args.run_dir / "env.sh"}')
        return 0
    return serve(args)


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (ValueError, RuntimeError) as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
    except OSError:
        # Third-party errors may include destination URLs; detailed child logs stay private.
        print('Telemetry setup failed. Check destinations, tools, ports and private run logs.', file=sys.stderr)
        sys.exit(1)
