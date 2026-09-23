"""Real backend request, telemetry delivery and teardown against local recorders."""
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import threading
import unittest
from http.server import ThreadingHTTPServer
from urllib.request import Request, urlopen

from test_transport import ALLOY, NGINX, ROOT, Recorder, eventually


@unittest.skipUnless(ALLOY and NGINX and os.environ.get('NATIVE_BACKEND_BIN'),
                     'Set ALLOY_BIN, NGINX_BIN and NATIVE_BACKEND_BIN')
class NativeBackendTests(unittest.TestCase):
    def test_request_delivery_to_both_stacks_and_shutdown(self):
        servers = []
        for _ in range(2):
            server = ThreadingHTTPServer(('127.0.0.1', 0), Recorder)
            server.records = []
            server.status = 200
            threading.Thread(target=server.serve_forever, daemon=True).start()
            servers.append(server)
        with socket.socket() as sock:
            sock.bind(('127.0.0.1', 0))
            port = sock.getsockname()[1]
        with tempfile.TemporaryDirectory() as temp:
            run = Path(temp) / 'run'
            targets = Path(temp) / 'targets.json'
            data = {}
            for side, server in zip(('primary', 'secondary'), servers):
                base = f'http://127.0.0.1:{server.server_port}'
                data[side] = {app: base + '/collect/' + app for app in ('flutter', 'react-native')}
                data[side].update({app: {'endpoint': base + '/otlp/' + app, 'headers': {}}
                                  for app in ('ios', 'android', 'backend')})
            targets.write_text(json.dumps(data))
            cli = [sys.executable, str(ROOT / 'Mobiles/telemetry/telemetry.py')]
            args = ['--profile', 'dual-stack', '--destinations', str(targets), '--run-dir', str(run),
                    '--port-offset', '5000', '--drain-seconds', '5', '--native-backend',
                    os.environ['NATIVE_BACKEND_BIN'], '--backend-port', str(port)]
            try:
                result = subprocess.run([*cli, 'start', *args], capture_output=True, text=True, timeout=65)
                self.assertEqual(result.returncode, 0, result.stderr)
                base = f'http://127.0.0.1:{port}'
                with urlopen(Request(base + '/api/users/token/login',
                                     json.dumps({'username': 'default', 'password': '12345678'}).encode(),
                                     {'Content-Type': 'application/json'})) as response:
                    token = json.load(response)['token']
                with urlopen(Request(base + '/api/pizza',
                                     b'{"maxCaloriesPerSlice":1000,"minNumberOfToppings":2,"maxNumberOfToppings":5}',
                                     {'Content-Type': 'application/json', 'Authorization': 'Token ' + token})) as response:
                    self.assertEqual(response.status, 200)
                eventually(lambda: all(any(path == '/otlp/backend/v1/traces' for path, _, _ in server.records)
                                       for server in servers))
                result = subprocess.run([*cli, 'stop', '--run-dir', str(run), '--drain-seconds', '5'],
                                        capture_output=True, text=True, timeout=45)
                self.assertEqual(result.returncode, 0, result.stderr)
                with socket.socket() as sock:
                    self.assertNotEqual(sock.connect_ex(('127.0.0.1', port)), 0)
            finally:
                subprocess.run([*cli, 'stop', '--run-dir', str(run), '--drain-seconds', '1'],
                               capture_output=True, timeout=45)
                for server in servers:
                    server.shutdown()
                    server.server_close()
