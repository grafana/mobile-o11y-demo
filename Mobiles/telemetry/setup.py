#!/usr/bin/env python3
"""Enable local dual-stack forwarding, interactively or from a private JSON file."""
import argparse
import base64
from contextlib import contextmanager
import fcntl
import getpass
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys

from backend import select_backend, check_port, build_native
from configure import HERE, ROOT, load_destinations, write
from telemetry import active, stop_child

RUNTIME = HERE / '.runtime'
RUN = RUNTIME / 'local'
ACTIVE = RUNTIME / 'active'
STATE = RUN / 'setup.json'


@contextmanager
def setup_lock():
    RUNTIME.mkdir(parents=True, exist_ok=True, mode=0o700)
    with (RUNTIME / 'setup.lock').open('w') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise RuntimeError('Setup or teardown is already running.') from None
        yield


def ask(label, default='', secret=False):
    suffix = ' [saved; Enter to keep]' if secret and default else f' [{default}]' if default else ''
    while True:
        value = (getpass.getpass if secret else input)(label + suffix + ': ').strip()
        if value or default:
            return value or default
        print('A value is required.')


def onboard():
    print('Enter destinations for both stacks. URLs containing app keys and tokens are hidden.')
    data = {}
    for side in ('primary', 'secondary'):
        print(f'\n{side.capitalize()} stack ({"controls SDK responses" if side == "primary" else "receives copies"})')
        target = {}
        for app in ('flutter', 'react-native', 'ios', 'android'):
            url = ask(f'{app} {"Faro collector URL" if app in ("flutter", "react-native") else "app OTLP base URL"}', secret=True)
            target[app] = {'endpoint': url, 'headers': {}} if app in ('ios', 'android') else url
        endpoint = ask('Backend OTLP base URL (ends in /otlp)', secret=True)
        instance = ask('Backend OTLP username / Grafana instance ID')
        token = ask('Cloud Access Policy token', secret=True)
        target['backend'] = {'endpoint': endpoint, 'headers': {
            'Authorization': 'Basic ' + base64.b64encode(f'{instance}:{token}'.encode()).decode()}}
        stack = ask('Cloud stack slug')
        environment = ask('Stack environment: production or development', 'production').lower()
        while environment not in ('production', 'development'):
            environment = ask('Choose production or development').lower()
        target['cloud'] = {'stack': stack, 'token': token,
                           'api_url': 'https://' + ('grafana.com' if environment == 'production' else 'grafana-dev.com') + '/api/instances/'}
        data[side] = target
    return data


def destinations(args):
    if args.destinations:
        if str(args.destinations) != '-':
            path = args.destinations.expanduser().resolve()
            load_destinations(path)
            return path
        raw = sys.stdin.read()
    elif os.environ.get('MOBILE_TELEMETRY_DESTINATIONS'):
        load_destinations()
        return None
    elif (HERE / 'destinations.local.json').exists():
        path = HERE / 'destinations.local.json'
        load_destinations(path)
        return path
    elif args.non_interactive:
        raise RuntimeError('Provide --destinations FILE (or - for stdin), or MOBILE_TELEMETRY_DESTINATIONS.')
    else:
        raw = json.dumps(onboard(), indent=2) + '\n'
    # Validate before saving. Invalid input never replaces saved configuration.
    staging = RUN / 'destinations.pending.json'
    try:
        write(staging, raw)
        load_destinations(staging)
        path = RUN / 'destinations.json' if args.non_interactive or args.destinations else HERE / 'destinations.local.json'
        write(path, raw)
        return path
    finally:
        staging.unlink(missing_ok=True)


def run_private(command, name, env=None):
    with (RUN / name).open('a') as log:
        log_path = RUN / name
        log_path.chmod(0o600)
        result = subprocess.run(command, cwd=ROOT, env=env, stdout=log, stderr=subprocess.STDOUT)
    if result.returncode:
        raise RuntimeError(f'Command failed. Details are in the private log: {log_path}')


def compose(action):
    run_private(['bash', str(HERE / 'backend-compose.sh'), *action], 'backend.log',
                {**os.environ, 'TELEMETRY_PROFILE': 'dual-stack',
                 'MOBILE_TELEMETRY_RUN_DIR': str(RUN), 'ALLOY_FILE_NAME': 'cloud-dev.alloy',
                 'QUICKPIZZA_IMAGE': os.environ.get('QUICKPIZZA_IMAGE', 'ghcr.io/grafana/quickpizza-mobile-local:latest')})


def deactivate():
    if ACTIVE.is_symlink() and ACTIVE.resolve() == RUN.resolve():
        ACTIVE.unlink()


def shutdown():
    """Called with the setup lock held; retain failed state so teardown can retry."""
    errors = []
    state = json.loads(STATE.read_text()) if STATE.exists() else {}
    if state.get('docker_backend'):
        for action in (['drain'], ['down']):
            try:
                compose(action)
            except (OSError, RuntimeError) as error:
                errors.append(str(error))
    deactivate()
    try:
        run_private([sys.executable, str(HERE / 'telemetry.py'), 'stop', '--run-dir', str(RUN)], 'lifecycle.log')
    except (OSError, RuntimeError) as error:
        errors.append(str(error))
    if errors:
        raise RuntimeError('Teardown incomplete; retry teardown after checking private logs.')
    STATE.unlink(missing_ok=True)


def start(args):
    if STATE.exists() or ACTIVE.exists() or ACTIVE.is_symlink() or active(RUN):
        raise RuntimeError('A local setup already exists. Run teardown.py before switching configuration.')
    RUN.mkdir(parents=True, exist_ok=True, mode=0o700)
    RUN.chmod(0o700)
    path = destinations(args)
    mode = select_backend(args.backend)
    args.docker_backend = mode == 'docker'
    backend_port = (args.backend_port or 29333) if mode == 'native' else (3333 if mode == 'docker' else None)
    if mode != 'native' and args.backend_port is not None:
        raise RuntimeError('--backend-port is only supported with the native backend.')
    if args.docker_backend:
        from configure import docker_config
        docker_config(load_destinations(path))  # Fail before installing/starting anything.
    for env, name in (('ALLOY_BIN', 'alloy'), ('NGINX_BIN', 'nginx')):
        binary = os.environ.get(env, str(RUNTIME / 'tools' / name))
        if not shutil.which(binary):
            if args.skip_install or os.environ.get(env):
                raise RuntimeError(f'{name} is missing; install tools or correct {env}.')
            print('Installing forwarding tools. See the private install.log for progress.', flush=True)
            run_private(['bash', str(HERE / 'install-tools.sh')], 'install.log')
            break
    binary = None
    if mode == 'native':
        check_port(backend_port)
        binary = build_native(ROOT, RUN, run_private)
    command = [sys.executable, str(HERE / 'telemetry.py'), 'start', '--profile', 'dual-stack',
               '--platform', args.platform, '--run-dir', str(RUN), '--port-offset', str(args.port_offset)]
    if path:
        command += ['--destinations', str(path)]
    if args.docker_backend:
        command += ['--docker-backend']
    if backend_port is not None:
        command += ['--backend-port', str(backend_port)]
    if binary:
        command += ['--native-backend', str(binary)]
    try:
        run_private(command, 'lifecycle.log')
        write(STATE, json.dumps({'docker_backend': False, 'backend': mode, 'backend_port': backend_port}))
        if args.docker_backend:
            # Record intent before Compose so a partial startup is recoverable.
            write(STATE, json.dumps({'docker_backend': True, 'backend': mode, 'backend_port': backend_port}))
            compose(['up', '-d', '--wait', '--wait-timeout', '120'])
        if (ROOT / 'Mobiles/ios/Scripts/generate-config.sh').is_file():
            run_private(['bash', str(ROOT / 'Mobiles/ios/Scripts/generate-config.sh')], 'ios-config.log',
                        {**os.environ, 'SRCROOT': str(ROOT / 'Mobiles/ios'),
                         'QUICKPIZZA_IOS_CONFIG_FILE': str(RUN / 'ios.xcconfig')})
        ACTIVE.symlink_to(RUN, target_is_directory=True)
    except BaseException:
        shutdown()
        raise
    if backend_port:
        print(f'QuickPizza ready: http://localhost:{backend_port} ({mode} backend)', flush=True)
    return json.loads((RUN / 'env.json').read_text())


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--non-interactive', action='store_true', help='Never prompt; require saved destinations, a file or environment.')
    parser.add_argument('--platform', choices=('android', 'ios'), default='ios',
                        help='Legacy default field for external consumers; all apps support both platforms.')
    parser.add_argument('--destinations', type=Path, help='Private destination JSON; - reads stdin. Defaults to saved file or environment.')
    group = parser.add_mutually_exclusive_group()
    group.add_argument('--backend', choices=('auto', 'docker', 'native', 'none'), default='auto',
                       help='Default: Docker when available, otherwise native Go. none starts forwarding only.')
    group.add_argument('--docker-backend', dest='backend', action='store_const', const='docker',
                       help='Alias for --backend docker.')
    parser.add_argument('--backend-port', type=int, help='Native HTTP port (default: 29333).')
    parser.add_argument('--skip-install', action='store_true', help='Fail if forwarding binaries are missing.')
    parser.add_argument('--port-offset', type=int, default=0, help='Offset local forwarding ports.')
    argv = sys.argv[1:]
    split = argv.index('--') if '--' in argv else len(argv)
    args = parser.parse_args(argv[:split])
    command = argv[split + 1:]
    if not sys.stdin.isatty():
        args.non_interactive = True
    if args.backend_port is not None and not 0 < args.backend_port < 65536:
        parser.error('Invalid backend port.')
    if not 0 <= args.port_offset < 48000:
        parser.error('Invalid port offset.')
    def interrupt(*_):
        raise KeyboardInterrupt
    # Startup owns partial-state cleanup, so cancellation must raise there too.
    previous = {sig: signal.signal(sig, interrupt) for sig in (signal.SIGINT, signal.SIGTERM)}
    try:
        with setup_lock():
            env = start(args)
        print('All mobile apps are configured for both iOS and Android. Saved app settings are unchanged.')
        if not command:
            print('Android Studio: sync Gradle, then rebuild/run. Xcode: rebuild/run.')
            print('React Native: restart Metro with --reset-cache, then rebuild/run.')
            print('Flutter: launch from Cursor, or use Mobiles/flutter/scripts/run-ios.sh / run-android.sh.')
            print('Stop apps before running: python3 Mobiles/telemetry/teardown.py')
            return 0
        child = None
        try:
            child = subprocess.Popen(command, env={**os.environ, **env}, start_new_session=True)
            return child.wait()
        finally:
            stop_child(child)
            with setup_lock():
                shutdown()
    finally:
        for sig, handler in previous.items():
            signal.signal(sig, handler)


if __name__ == '__main__':
    os.umask(0o077)
    try:
        sys.exit(main())
    except RuntimeError as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
    except (OSError, ValueError):
        # Neither JSON parsing nor subprocess errors should expose destinations.
        print('Setup failed. Check arguments, destinations and private .runtime/local logs. Run teardown.py before retrying a partial setup.', file=sys.stderr)
        sys.exit(1)
    except (KeyboardInterrupt, EOFError):
        print('Setup cancelled.', file=sys.stderr)
        sys.exit(130)
