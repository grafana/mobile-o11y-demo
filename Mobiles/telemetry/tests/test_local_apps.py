"""All-platform config selection and restoration, without saved credential writes."""
import importlib.util
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from configure import ROOT, PORTS, app_configs
from backend import select_backend, check_port, native_env

spec = importlib.util.spec_from_file_location('flutter_config', ROOT / 'Mobiles/telemetry/flutter-config.py')
flutter_config = importlib.util.module_from_spec(spec)
spec.loader.exec_module(flutter_config)


class LocalAppsTests(unittest.TestCase):
    def test_managed_backend_applies_to_every_app_and_flutter_restores_after_teardown(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            for app in ('flutter', 'react-native', 'android', 'ios'):
                name = 'Config.xcconfig.example' if app == 'ios' else 'config.json.example'
                target = root / 'Mobiles' / app / name
                target.parent.mkdir(parents=True)
                shutil.copy(ROOT / 'Mobiles' / app / name, target)
            original = root / 'Mobiles/flutter/config.json'
            original.write_text(json.dumps({'BASE_URL': 'https://original.test', 'FARO_COLLECTOR_URL': 'https://original.test/collect'}))
            saved = original.read_bytes()
            here = root / 'Mobiles/telemetry'
            run = here / '.runtime/local'
            app_configs(run, 'ios', PORTS, root, backend_port=29333)
            active = here / '.runtime/active'
            active.symlink_to(run)
            with patch.dict(os.environ, {}, clear=True):
                selected = flutter_config.select(root, here)
                flutter = json.loads(selected.read_text())
                rn = json.loads((run / 'react-native.json').read_text())
                for app in (flutter, rn):
                    self.assertEqual(app['BASE_URL'], '')
                    self.assertEqual(app['PORT'], '29333')
                    self.assertIn('127.0.0.1:17134', app['FARO_COLLECTOR_URL_IOS'])
                    self.assertIn('10.0.2.2:17134', app['FARO_COLLECTOR_URL_ANDROID'])
                android = json.loads((run / 'android.json').read_text())
                self.assertEqual(android['BASE_URL'], 'http://10.0.2.2:29333')
                self.assertEqual(android['OTLP_ENDPOINT'], 'http://10.0.2.2:17120')
                ios = (run / 'ios.xcconfig').read_text()
                self.assertIn('BASE_URL = http:/$()/127.0.0.1:29333', ios)
                self.assertIn('OTLP_ENDPOINT = http:/$()/127.0.0.1:17118', ios)
                active.unlink()  # The build-selector part of teardown.
                restored = flutter_config.select(root, here)
                self.assertEqual(json.loads(restored.read_text()), json.loads(saved))
                self.assertEqual(original.read_bytes(), saved)

    def test_auto_backend_is_bounded_and_explicit_modes_do_not_probe_docker(self):
        with patch('backend.shutil.which', return_value='/bin/docker'), patch('backend.subprocess.run') as run:
            run.return_value.returncode = 0
            self.assertEqual(select_backend('auto'), 'docker')
            run.side_effect = subprocess.TimeoutExpired('docker', 5)
            self.assertEqual(select_backend('auto'), 'native')
            self.assertEqual(run.call_args.kwargs['timeout'], 5)
            run.reset_mock()
            for mode in ('native', 'docker', 'none'):
                self.assertEqual(select_backend(mode), mode)
            run.assert_not_called()

    def test_native_backend_does_not_enable_inherited_grpc_and_preserves_occupied_ports(self):
        with patch.dict(os.environ, {'QUICKPIZZA_ENABLE_GRPC_SERVICE': '1'}):
            env = native_env(29333, 'http://127.0.0.1:17119')
            self.assertNotIn('QUICKPIZZA_ENABLE_GRPC_SERVICE', env)
            self.assertEqual(env['QUICKPIZZA_HTTP_PORT'], '29333')
        with socket.socket() as listener:
            listener.bind(('127.0.0.1', 0))
            listener.listen()
            with self.assertRaisesRegex(RuntimeError, 'occupied'):
                check_port(listener.getsockname()[1])
            self.assertGreater(listener.fileno(), 0)
