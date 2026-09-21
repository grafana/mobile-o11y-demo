#!/usr/bin/env python3
"""Adapt the shared launcher to multi-step GitHub Actions jobs."""
import json
import os
from pathlib import Path
import subprocess
import sys
from configure import HERE, PORTS

platform = sys.argv[1]
run = HERE / '.runtime' / 'ci'
subprocess.run([sys.executable, str(HERE / 'telemetry.py'), 'start', '--profile', 'dual-stack',
                '--platform', platform, '--run-dir', str(run),
                *(['--docker-backend'] if platform == 'android' else [])], check=True)
with Path(os.environ['GITHUB_ENV']).open('a') as output:
    env = json.loads((run / 'env.json').read_text())
    # Existing CI build steps use these endpoint variables. No Cloud credentials
    # are included in any generated app configuration.
    faro_host = '10.0.2.2' if platform == 'android' else '127.0.0.1'
    env.update(FARO_COLLECTOR_URL=f'http://{faro_host}:{PORTS["faro"]}/collect/flutter',
               FARO_COLLECTOR_URL_RN=f'http://{faro_host}:{PORTS["faro"]}/collect/react-native',
               FARO_OTLP_URL_ANDROID=f'http://10.0.2.2:{PORTS["android"]}',
               FARO_OTLP_URL_IOS=f'http://127.0.0.1:{PORTS["ios"]}')
    # CI creates its own normal app configs below, including demo version flags.
    # Alternate config selectors are for local builds only.
    for key, value in env.items():
        if key.startswith('QUICKPIZZA_') and key.endswith('_CONFIG_FILE'):
            continue
        output.write(f'{key}={value}\n')
