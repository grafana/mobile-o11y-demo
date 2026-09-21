import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from configure import PORTS, ROOT, app_configs, load_destinations, docker_config


class ConfigurationTests(unittest.TestCase):
    def test_build_inputs_preserve_local_settings(self):
        for platform in ('ios', 'android'):
            with self.subTest(platform=platform), tempfile.TemporaryDirectory() as temp:
                root = Path(temp)
                originals = {}
                for app in ('flutter', 'react-native', 'android'):
                    path = root / 'Mobiles' / app / ('app/src/main/res/raw/config.json' if app == 'android' else 'config.json')
                    path.parent.mkdir(parents=True)
                    original = {'BASE_URL': 'http://custom:3339', 'PORT': '3339', 'custom': False,
                                'OTLP_INSTANCE_ID': 'secret-id', 'OTLP_API_KEY': 'secret-key'}
                    path.write_text(json.dumps(original))
                    originals[path] = path.read_bytes()
                ios = root / 'Mobiles/ios/Config.xcconfig'
                ios.parent.mkdir(parents=True)
                ios.write_text('BASE_URL = http:/$()/custom:3339\nPORT = 3339\nOTLP_ENDPOINT = secret\nOTLP_API_KEY = secret\n')
                originals[ios] = ios.read_bytes()
                run = root / 'run'
                env = app_configs(run, platform, PORTS, root)
                for path, before in originals.items():
                    self.assertEqual(path.read_bytes(), before)
                for app in ('flutter', 'react-native', 'android'):
                    data = json.loads((run / f'{app}.json').read_text())
                    self.assertEqual(data['BASE_URL'], 'http://custom:3339')
                    self.assertFalse(data['custom'])
                native = json.loads((run / 'android.json').read_text())
                self.assertEqual(native['OTLP_API_KEY'], '')
                self.assertEqual(native['OTLP_INSTANCE_ID'], '')
                self.assertNotIn('secret', (run / 'ios.xcconfig').read_text())
                self.assertIn('10.0.2.2' if platform == 'android' else '127.0.0.1', native['OTLP_ENDPOINT'])
                self.assertNotIn('XCODE_XCCONFIG_FILE', env)  # Do not override RN's Xcode build.
                self.assertEqual((run / 'env.sh').stat().st_mode & 0o777, 0o600)

    def test_missing_settings_use_examples_without_creating_originals(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            for app in ('flutter', 'react-native', 'android', 'ios'):
                src = ROOT / 'Mobiles' / app / ('Config.xcconfig.example' if app == 'ios' else 'config.json.example')
                dest = root / src.relative_to(ROOT)
                dest.parent.mkdir(parents=True)
                dest.write_bytes(src.read_bytes())
            app_configs(root / 'run', 'ios', PORTS, root)
            self.assertFalse((root / 'Mobiles/ios/Config.xcconfig').exists())
            self.assertFalse((root / 'Mobiles/react-native/config.json').exists())

    def test_untrusted_configuration_fails_without_echoing_secrets(self):
        for raw in ('secret-not-json', '{}', '{"primary":"secret"}'):
            with patch.dict(os.environ, MOBILE_TELEMETRY_DESTINATIONS=raw):
                with self.assertRaisesRegex(ValueError, '^Invalid/missing destinations;'):
                    load_destinations()

    def test_destination_schema_rejects_missing_secondary_and_config_injection(self):
        data = {s: {
            'flutter': 'http://127.0.0.1/collect', 'react-native': 'http://127.0.0.1/collect',
            **{a: {'endpoint': 'http://127.0.0.1/otlp', 'headers': {}} for a in ('ios', 'android', 'backend')},
        } for s in ('primary', 'secondary')}
        with patch.dict(os.environ, MOBILE_TELEMETRY_DESTINATIONS=json.dumps(data)):
            self.assertEqual(load_destinations(), data)
        for bad in ('https://example.com/secret;error_log', 'https://example.com/$request_uri', 'https://user:secret@example.com/path'):
            data['secondary']['flutter'] = bad
            with patch.dict(os.environ, MOBILE_TELEMETRY_DESTINATIONS=json.dumps(data)):
                with self.assertRaises(ValueError) as error:
                    load_destinations()
                self.assertNotIn('secret', str(error.exception))
        del data['secondary']
        with patch.dict(os.environ, MOBILE_TELEMETRY_DESTINATIONS=json.dumps(data)):
            with self.assertRaises(ValueError):
                load_destinations()

    def test_default_executes_without_tools_or_configuration(self):
        with tempfile.TemporaryDirectory() as temp:
            marker = Path(temp) / 'untouched'
            result = subprocess.run([sys.executable, str(ROOT / 'Mobiles/telemetry/telemetry.py'),
                                     'run', '--run-dir', str(marker), '--', sys.executable, '-c',
                                     'import sys; assert sys.argv[1] == "a b"; sys.exit(7)', 'a b'])
            self.assertEqual(result.returncode, 7)
            self.assertFalse(marker.exists())



if __name__ == '__main__':
    unittest.main()
