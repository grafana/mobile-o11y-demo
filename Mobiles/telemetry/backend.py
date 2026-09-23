"""Backend selection and native launch settings for the local setup."""
import os
import shutil
import socket
import subprocess


def select_backend(mode):
    if mode != 'auto':
        return mode
    try:
        if shutil.which('docker') and subprocess.run(
            ['docker', 'info', '--format', '{{.ServerVersion}}'],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=5,
        ).returncode == 0:
            return 'docker'
    except (OSError, subprocess.TimeoutExpired):
        pass
    print('Docker unavailable; using the native Go backend (OTLP telemetry only).', flush=True)
    return 'native'


def check_port(port):
    for family, host in ((socket.AF_INET, '0.0.0.0'), (socket.AF_INET6, '::')):
        with socket.socket(family) as sock:
            try:
                sock.bind((host, port))
            except OSError:
                raise RuntimeError(f'Backend port {port} is occupied; choose --backend-port or stop its owner.') from None


def build_native(root, run, build):
    if not shutil.which('go'):
        raise RuntimeError('Native backend requires Go. Install Go or start Docker and retry setup.')
    web = root / 'pkg/web/build/index.html'
    if not web.exists():
        web.parent.mkdir(parents=True, exist_ok=True)
        web.write_bytes((root / 'pkg/web/dev.html').read_bytes())
    binary = run / 'quickpizza'
    build(['go', 'build', '-o', str(binary), './cmd'], 'backend-build.log')
    return binary


def native_env(port, endpoint):
    # Opt in HTTP services only, keeping unrelated default gRPC ports untouched.
    env = {k: v for k, v in os.environ.items() if not k.startswith('QUICKPIZZA_ENABLE_')}
    env.update(QUICKPIZZA_ENABLE_ALL_SERVICES='0', QUICKPIZZA_HTTP_PORT=str(port),
               QUICKPIZZA_DB='', QUICKPIZZA_TIMEOUT='10s',
               QUICKPIZZA_TRUST_CLIENT_TRACEID='1', QUICKPIZZA_OTLP_ENDPOINT=endpoint,
               QUICKPIZZA_OTEL_SERVICE_NAME='quickpizza')
    for service in ('CATALOG', 'COPY', 'CONFIG', 'PUBLIC_API', 'RECOMMENDATIONS', 'WS', 'HTTP_TESTING'):
        env[f'QUICKPIZZA_ENABLE_{service}_SERVICE'] = '1'
    return env
