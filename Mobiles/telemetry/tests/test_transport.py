"""Real Alloy/nginx integration. Requires binaries and opentelemetry-proto for decoding."""
import gzip
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from urllib.error import HTTPError
from urllib.request import Request, urlopen

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from configure import ROOT

ALLOY = os.environ.get('ALLOY_BIN')
NGINX = os.environ.get('NGINX_BIN')
try:
    from opentelemetry.proto.collector.trace.v1.trace_service_pb2 import ExportTraceServiceRequest
except ImportError:
    ExportTraceServiceRequest = None


class Recorder(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_POST(self):
        body = self.rfile.read(int(self.headers['Content-Length']))
        status = self.server.status
        if status == 200:
            self.server.records.append((self.path, dict(self.headers), body))
        self.send_response(status)
        self.send_header('Content-Type', 'application/x-protobuf')
        self.send_header('Retry-After', '1')
        self.end_headers()


def post(url, body, encoding=None):
    headers = {'Content-Type': 'application/json', 'X-Faro-Session-Id': 'session-kept'}
    if encoding:
        headers['Content-Encoding'] = encoding
    try:
        with urlopen(Request(url, body, headers), timeout=15) as response:
            return response.status, response.headers
    except HTTPError as error:
        result = error.code, error.headers
        error.close()
        return result


def eventually(predicate, seconds=20):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(.1)
    raise AssertionError('Timed out waiting for telemetry')


@unittest.skipUnless(ALLOY and NGINX and ExportTraceServiceRequest, 'Set ALLOY_BIN/NGINX_BIN and install test requirements')
class TransportTests(unittest.TestCase):
    def test_roundtrip_routing_outage_and_lifecycle(self):
        servers = []
        for _ in range(2):
            server = ThreadingHTTPServer(('127.0.0.1', 0), Recorder)
            server.records = []
            server.status = 200
            threading.Thread(target=server.serve_forever, daemon=True).start()
            servers.append(server)
        with tempfile.TemporaryDirectory() as temp:
            run = Path(temp) / 'run'
            destinations = Path(temp) / 'destinations.json'
            data = {}
            for stack, server in zip(('primary', 'secondary'), servers):
                base = f'http://127.0.0.1:{server.server_port}'
                data[stack] = {app: base + '/collect/' + app + '/' + stack for app in ('flutter', 'react-native')}
                data[stack].update({app: {'endpoint': base + '/otlp/' + app, 'headers': {'X-Target': stack}} for app in ('ios', 'android', 'backend')})
            destinations.write_text(json.dumps(data))
            cli = [sys.executable, str(ROOT / 'Mobiles/telemetry/telemetry.py')]
            args = ['--profile', 'dual-stack', '--destinations', str(destinations), '--run-dir', str(run), '--port-offset', '1000', '--drain-seconds', '5']
            def invoke(action):
                return subprocess.run([*cli, action, *args], capture_output=True, text=True)
            foreground = None
            try:
                started = invoke('start')
                self.assertEqual(started.returncode, 0, started.stderr + (run / 'supervisor.log').read_text())
                self.assertNotEqual(invoke('start').returncode, 0)
                self.assertEqual(invoke('status').returncode, 0)
                payload = json.dumps({'meta': {'session': {'id': 'session-kept'}, 'device': {'is_physical': False}, 'view': {'name': 'pizza'}}, 'traces': {'resourceSpans': []}, 'unknown_future': 123}).encode()
                for app in ('flutter', 'react-native'):
                    for body, encoding in ((payload, None), (gzip.compress(payload), 'gzip')):
                        status, _ = post(f'http://127.0.0.1:18134/collect/{app}', body, encoding)
                        self.assertEqual(status, 200)
                eventually(lambda: all(len(s.records) == 4 for s in servers))
                for server, stack in zip(servers, ('primary', 'secondary')):
                    for path, headers, body in server.records:
                        self.assertTrue(path.endswith('/' + stack))
                        self.assertEqual(headers['X-Faro-Session-Id'], 'session-kept')
                        self.assertEqual(gzip.decompress(body) if headers.get('Content-Encoding') == 'gzip' else body, payload)
                servers[1].status = 503
                self.assertEqual(post('http://127.0.0.1:18134/collect/flutter', payload)[0], 200)
                servers[0].status = 429
                status, headers = post('http://127.0.0.1:18134/collect/flutter', payload)
                self.assertEqual(status, 429)
                self.assertEqual(headers['Retry-After'], '1')
                servers[0].status = 200
                # Native spans and a backend child must retain IDs, parents and metadata.
                trace_id = '11223344556677881122334455667788'
                for app, port, span_id, parent in [('ios', 18118, '1122334455667788', ''), ('android', 18120, '2233445566778899', ''), ('backend', 18119, '33445566778899aa', '1122334455667788')]:
                    span = {'traceId': trace_id, 'spanId': span_id, 'name': app, 'startTimeUnixNano': '1720000000000000000', 'endTimeUnixNano': '1720000001000000000', 'attributes': [{'key': 'session.id', 'value': {'stringValue': 'session-kept'}}]}
                    if parent:
                        span['parentSpanId'] = parent
                    body = json.dumps({'resourceSpans': [{'resource': {'attributes': [{'key': 'device.model.name', 'value': {'stringValue': 'test-device'}}]}, 'scopeSpans': [{'spans': [span]}]}]}).encode()
                    self.assertEqual(post(f'http://127.0.0.1:{port}/v1/traces', body)[0], 200)
                def trace_records(server):
                    return [r for r in server.records if '/otlp/' in r[0]]
                eventually(lambda: len(trace_records(servers[0])) == 3)
                self.assertEqual(len(trace_records(servers[1])), 0)
                servers[1].status = 200
                eventually(lambda: len(trace_records(servers[1])) == 3)
                decoded = []
                for server in servers:
                    records = {}
                    for path, headers, body in trace_records(server):
                        request = ExportTraceServiceRequest()
                        request.ParseFromString(gzip.decompress(body) if headers.get('Content-Encoding') == 'gzip' else body)
                        records[path] = request
                    decoded.append(records)
                self.assertEqual(decoded[0], decoded[1])
                mobile = decoded[0]['/otlp/ios/v1/traces'].resource_spans[0]
                backend = decoded[0]['/otlp/backend/v1/traces'].resource_spans[0]
                a, b = mobile.scope_spans[0].spans[0], backend.scope_spans[0].spans[0]
                self.assertEqual(a.trace_id, b.trace_id)
                self.assertEqual(a.span_id, b.parent_span_id)
                self.assertEqual(a.attributes[0].value.string_value, 'session-kept')
                self.assertEqual(mobile.resource.attributes[0].value.string_value, 'test-device')
                # Backend OTLP logs and metrics have their own gateway routes.
                for signal_name, body in (
                    ('logs', {'resourceLogs': [{'scopeLogs': [{'logRecords': [{'timeUnixNano': '1720000000000000000', 'body': {'stringValue': 'backend-log'}}]}]}]}),
                    ('metrics', {'resourceMetrics': [{'scopeMetrics': [{'metrics': [{'name': 'backend-test', 'gauge': {'dataPoints': [{'timeUnixNano': '1720000000000000000', 'asInt': '1'}]}}]}]}]}),
                ):
                    self.assertEqual(post(f'http://127.0.0.1:18119/v1/{signal_name}', json.dumps(body).encode())[0], 200)
                    eventually(lambda: all(any(r[0] == '/otlp/backend/v1/' + signal_name for r in server.records) for server in servers))
                self.assertEqual(invoke('stop').returncode, 0)
                self.assertNotEqual(invoke('status').returncode, 0)
                # Immediate restart proves child listeners were released.
                self.assertEqual(invoke('start').returncode, 0)
                self.assertEqual(invoke('stop').returncode, 0)
                foreground = subprocess.Popen([*cli, 'run', *args], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                eventually(lambda: invoke('status').returncode == 0)
                foreground.send_signal(signal.SIGTERM)
                self.assertEqual(foreground.wait(timeout=40), 130)
                self.assertNotEqual(invoke('status').returncode, 0)
            finally:
                invoke('stop')
                if foreground and foreground.poll() is None:
                    foreground.terminate()
                    foreground.wait(timeout=40)
                for server in servers:
                    server.shutdown()
                    server.server_close()


if __name__ == '__main__':
    unittest.main()
