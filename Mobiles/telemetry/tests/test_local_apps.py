"""All-platform config selection and restoration, without saved credential writes."""
import importlib.util
import json
import os
from pathlib import Path
import shutil
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from configure import ROOT, PORTS, app_configs

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
            app_configs(run, 'ios', PORTS, root, backend_port=3333)
            active = here / '.runtime/active'
            active.symlink_to(run)
            with patch.dict(os.environ, {}, clear=True):
                selected = flutter_config.select(root, here)
                flutter = json.loads(selected.read_text())
                rn = json.loads((run / 'react-native.json').read_text())
                for app in (flutter, rn):
                    self.assertEqual(app['BASE_URL'], '')
                    self.assertEqual(app['PORT'], '3333')
                    self.assertIn('127.0.0.1:17134', app['FARO_COLLECTOR_URL_IOS'])
                    self.assertIn('10.0.2.2:17134', app['FARO_COLLECTOR_URL_ANDROID'])
                android = json.loads((run / 'android.json').read_text())
                self.assertEqual(android['BASE_URL'], 'http://10.0.2.2:3333')
                self.assertEqual(android['OTLP_ENDPOINT'], 'http://10.0.2.2:17120')
                ios = (run / 'ios.xcconfig').read_text()
                self.assertIn('BASE_URL = http:/$()/127.0.0.1:3333', ios)
                self.assertIn('OTLP_ENDPOINT = http:/$()/127.0.0.1:17118', ios)
                active.unlink()  # The build-selector part of teardown.
                restored = flutter_config.select(root, here)
                self.assertEqual(json.loads(restored.read_text()), json.loads(saved))
                self.assertEqual(original.read_bytes(), saved)
