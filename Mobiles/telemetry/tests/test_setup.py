"""Local onboarding, activation, rollback, and teardown contracts."""
import base64
from contextlib import contextmanager
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import textwrap
from types import SimpleNamespace
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import setup
from configure import ROOT
from test_transport import ALLOY, NGINX, Recorder, eventually, post
from http.server import ThreadingHTTPServer
import threading


def destinations(base='http://127.0.0.1:9999'):
    return {s: {'flutter': base + '/collect/flutter', 'react-native': base + '/collect/react-native',
                **{app: {'endpoint': base + '/otlp/' + app, 'headers': {}} for app in ('ios', 'android', 'backend')},
                'cloud': {'stack': 'test', 'token': 'private-token', 'api_url': 'https://example.test/api/instances/'}}
            for s in ('primary', 'secondary')}


@contextmanager
def workspace():
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        here = root / 'Mobiles/telemetry'
        runtime = here / '.runtime'
        run = runtime / 'local'
        run.mkdir(parents=True)
        with patch.multiple(setup, ROOT=root, HERE=here, RUNTIME=runtime, RUN=run,
                            ACTIVE=runtime / 'active', STATE=run / 'setup.json'):
            yield root, here, run


class SetupTests(unittest.TestCase):
    def test_docker_check_is_bounded_and_reports_unavailable_engine(self):
        with patch.object(setup.shutil, 'which', return_value='/bin/docker'), \
             patch.object(setup.subprocess, 'run') as run:
            run.return_value.returncode = 0
            setup.require_docker()
            self.assertEqual(run.call_args.kwargs['timeout'], 5)
            run.return_value.returncode = 1
            with self.assertRaisesRegex(RuntimeError, 'Start or restart Docker'):
                setup.require_docker()
            run.side_effect = subprocess.TimeoutExpired('docker', 5)
            with self.assertRaisesRegex(RuntimeError, 'unresponsive'):
                setup.require_docker()
        with patch.object(setup.shutil, 'which', return_value=None), \
             patch.object(setup.subprocess, 'run') as run:
            with self.assertRaisesRegex(RuntimeError, 'Docker is unavailable'):
                setup.require_docker()
            run.assert_not_called()

    def test_default_requires_docker_before_onboarding_or_starting_services(self):
        with workspace(), patch.object(setup, 'require_docker', side_effect=RuntimeError('Docker unavailable')), \
             patch.object(setup, 'destinations') as configure, patch.object(setup, 'run_private') as runner, \
             patch.object(sys, 'argv', ['setup.py', '--non-interactive']):
            with self.assertRaisesRegex(RuntimeError, 'Docker unavailable'):
                setup.main()
            configure.assert_not_called()
            runner.assert_not_called()
            self.assertFalse(setup.ACTIVE.is_symlink())
            self.assertFalse(setup.STATE.exists())

    def test_local_build_is_default_and_explicit_image_skips_build(self):
        with workspace(), patch.dict(os.environ, {}, clear=True), \
             patch.object(setup, 'run_private') as runner:
            self.assertEqual(setup.prepare_backend_image(), setup.LOCAL_IMAGE)
            runner.assert_called_once_with(
                ['docker', 'build', '-t', setup.LOCAL_IMAGE, '.'], 'backend-build.log')
            runner.reset_mock()
            with patch.dict(os.environ, QUICKPIZZA_IMAGE='custom-mobile:test'):
                self.assertEqual(setup.prepare_backend_image(), 'custom-mobile:test')
            runner.assert_not_called()

    def test_teardown_compose_uses_saved_image_when_environment_changes(self):
        with workspace(), patch.object(setup, 'run_private') as runner, \
             patch.dict(os.environ, QUICKPIZZA_IMAGE='different-mobile:test'):
            setup.STATE.write_text(json.dumps({'docker_backend': True, 'backend_image': 'saved-mobile:test'}))
            setup.compose(['down'])
            self.assertEqual(runner.call_args.args[2]['QUICKPIZZA_IMAGE'], 'saved-mobile:test')

    def test_missing_cloud_names_required_fields_without_exposing_values(self):
        for side in ('primary', 'secondary'):
            with self.subTest(side=side), workspace() as (_, here, run):
                data = destinations()
                del data[side]['cloud']
                config = here / 'destinations.local.json'
                config.write_text(json.dumps(data))
                args = SimpleNamespace(destinations=config, non_interactive=True, backend='docker')
                with patch.object(setup, 'require_docker'), patch.object(setup, 'run_private') as runner:
                    with self.assertRaisesRegex(RuntimeError, side + r'\.cloud') as error:
                        setup.start(args)
                    runner.assert_not_called()
                self.assertIn('stack, token and api_url', str(error.exception))
                self.assertIn('--backend none', str(error.exception))
                self.assertNotIn('private-token', str(error.exception))
                self.assertFalse(setup.STATE.exists())
                self.assertFalse(setup.ACTIVE.is_symlink())

    def test_failed_build_does_not_start_forwarding_or_compose(self):
        with workspace() as (_, here, run):
            config = here / 'destinations.local.json'
            config.write_text(json.dumps(destinations()))
            args = SimpleNamespace(destinations=config, non_interactive=True, backend='docker',
                                   platform='ios', port_offset=0, skip_install=True)
            with patch.object(setup, 'require_docker'), \
                 patch.dict(os.environ, ALLOY_BIN=sys.executable, NGINX_BIN=sys.executable), \
                 patch.object(setup, 'prepare_backend_image', side_effect=RuntimeError('Build failed')), \
                 patch.object(setup, 'run_private') as runner, patch.object(setup, 'compose') as compose:
                with self.assertRaisesRegex(RuntimeError, 'Build failed'):
                    setup.start(args)
                runner.assert_not_called()
                compose.assert_not_called()
                self.assertFalse(setup.STATE.exists())
                self.assertFalse(setup.ACTIVE.is_symlink())

    def test_guided_setup_hides_app_keys_and_tokens(self):
        values = ['https://cloud.test/collect/private-key'] * 4 + [
            'https://gateway.test/otlp', '123', 'private-token', 'my-stack', 'production']
        with patch.object(setup, 'ask', side_effect=values * 2) as ask:
            result = setup.onboard()
        for offset in (0, 9):
            for i in (0, 1, 2, 3, 4, 6):
                self.assertTrue(ask.call_args_list[offset + i].kwargs['secret'])
        auth = result['primary']['backend']['headers']['Authorization']
        self.assertEqual(base64.b64decode(auth[6:]).decode(), '123:private-token')
        self.assertEqual(result['primary']['cloud']['token'], 'private-token')

    def test_invalid_input_keeps_saved_destinations_and_removes_staging(self):
        with workspace() as (_, here, run):
            saved = here / 'destinations.local.json'
            saved.write_text('existing-private-config')
            args = SimpleNamespace(destinations=Path('-'), non_interactive=True)
            with patch('sys.stdin') as stdin:
                stdin.read.return_value = 'private-not-json'
                with self.assertRaises(ValueError) as error:
                    setup.destinations(args)
            self.assertNotIn('private-not-json', str(error.exception))
            self.assertEqual(saved.read_text(), 'existing-private-config')
            self.assertFalse((run / 'destinations.pending.json').exists())

    def test_partial_docker_start_is_drained_and_stopped_on_failure(self):
        with workspace() as (_, here, run):
            config = here / 'destinations.local.json'
            config.write_text(json.dumps(destinations()))
            args = SimpleNamespace(destinations=config, non_interactive=True, backend='docker',
                                   platform='android', port_offset=0, skip_install=True)
            calls = []
            def compose(action):
                calls.append(action[0])
                if action[0] == 'up':
                    raise RuntimeError('Compose failed')
            with patch.object(setup, 'require_docker'), patch.object(setup, 'run_private') as runner, patch.object(setup, 'compose', side_effect=compose), \
                 patch.dict(os.environ, ALLOY_BIN=sys.executable, NGINX_BIN=sys.executable):
                with self.assertRaisesRegex(RuntimeError, 'Compose failed'):
                    setup.start(args)
            self.assertEqual(calls, ['up', 'drain', 'down'])
            self.assertIn('stop', runner.call_args.args[0])
            self.assertFalse(setup.STATE.exists())
            self.assertFalse(setup.ACTIVE.is_symlink())
            self.assertEqual(json.loads(config.read_text()), destinations())

    def test_existing_setup_is_not_stopped_or_overwritten(self):
        with workspace():
            setup.STATE.write_text('{"platform":"android"}')
            with patch.object(setup, 'shutdown') as stop, self.assertRaises(RuntimeError):
                setup.start(SimpleNamespace())
            stop.assert_not_called()
            self.assertEqual(setup.STATE.read_text(), '{"platform":"android"}')

    def test_sigterm_during_docker_start_cleans_up_and_restores_handlers(self):
        # A real signal in a subprocess catches a missing handler without killing
        # the test runner. Stub Docker and forwarding to leave local services alone.
        script = textwrap.dedent('''
            import os, signal, sys
            from unittest.mock import patch
            from test_setup import destinations, json, setup, workspace

            wrapped = sys.argv[1] == 'wrapped'
            with workspace() as (_, here, run):
                config = here / 'destinations.local.json'
                config.write_text(json.dumps(destinations()))
                sys.argv = ['setup.py', '--non-interactive', '--platform', 'android',
                            '--destinations', str(config), '--docker-backend', '--skip-install']
                if wrapped:
                    sys.argv += ['--', sys.executable, '-c', 'raise AssertionError("must not run")']
                calls = []
                previous = {sig: signal.getsignal(sig) for sig in (signal.SIGINT, signal.SIGTERM)}
                def compose(action):
                    calls.append(action[0])
                    if action[0] == 'up':
                        assert json.loads(setup.STATE.read_text())['docker_backend']
                        os.kill(os.getpid(), signal.SIGTERM)
                        raise AssertionError('SIGTERM did not interrupt startup')
                with patch.object(setup, 'require_docker'), patch.object(setup, 'compose', side_effect=compose), \
                     patch.object(setup, 'run_private') as runner:
                    try:
                        setup.main()
                    except KeyboardInterrupt:
                        pass
                    else:
                        raise AssertionError('Startup cancellation was swallowed')
                assert calls == ['up', 'drain', 'down'], calls
                assert 'stop' in runner.call_args.args[0]
                assert not setup.STATE.exists()
                assert not setup.ACTIVE.is_symlink()
                assert json.loads(config.read_text()) == destinations()
                assert all(signal.getsignal(sig) == handler for sig, handler in previous.items())
        ''')
        for mode in ('standalone', 'wrapped'):
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as tmp:
                env = {**os.environ, 'TMPDIR': tmp, 'PYTHONPATH': str(Path(__file__).parent),
                       'ALLOY_BIN': sys.executable, 'NGINX_BIN': sys.executable}
                result = subprocess.run([sys.executable, '-c', script, mode], env=env,
                                        capture_output=True, text=True, timeout=10)
                self.assertEqual(result.returncode, 0, result.stderr)

    def test_noninteractive_missing_destinations_fails_without_prompting(self):
        with workspace(), patch.dict(os.environ, {}, clear=True), patch.object(setup, 'start') as start:
            start.side_effect = RuntimeError('missing destinations')
            with patch.object(sys, 'argv', ['setup.py', '--non-interactive', '--backend', 'none']):
                with self.assertRaisesRegex(RuntimeError, 'missing destinations'):
                    setup.main()
            self.assertEqual(start.call_args.args[0].platform, 'ios')
            self.assertEqual(start.call_args.args[0].backend, 'none')

    @unittest.skipUnless(ALLOY and NGINX, 'Set ALLOY_BIN and NGINX_BIN')
    def test_real_setup_delivery_teardown_and_command_exit(self):
        # A disposable checkout prevents tests from changing the user's active profile.
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            here = root / 'Mobiles/telemetry'
            here.mkdir(parents=True)
            for name in ('setup.py', 'teardown.py', 'telemetry.py', 'configure.py'):
                shutil.copy(ROOT / 'Mobiles/telemetry' / name, here / name)
            for app in ('android', 'ios', 'react-native', 'flutter'):
                name = 'Config.xcconfig.example' if app == 'ios' else 'config.json.example'
                dest = root / 'Mobiles' / app / name
                dest.parent.mkdir(parents=True)
                shutil.copy(ROOT / 'Mobiles' / app / name, dest)
            server = ThreadingHTTPServer(('127.0.0.1', 0), Recorder)
            server.status = 200
            server.records = []
            threading.Thread(target=server.serve_forever, daemon=True).start()
            config = here / 'destinations.local.json'
            config.write_text(json.dumps(destinations(f'http://127.0.0.1:{server.server_port}')))
            command = [sys.executable, str(here / 'setup.py'), '--non-interactive', '--platform', 'android',
                       '--destinations', str(config), '--skip-install', '--backend', 'none', '--port-offset', '3000']
            stop = [sys.executable, str(here / 'teardown.py')]
            env = {**os.environ, 'ALLOY_BIN': ALLOY, 'NGINX_BIN': NGINX}
            def execute(cmd):
                return subprocess.run(cmd, env=env, capture_output=True, text=True, timeout=60)
            try:
                result = execute(command)
                self.assertEqual(result.returncode, 0, result.stderr)
                active = here / '.runtime/active'
                self.assertTrue(active.is_symlink())
                data = json.loads((active / 'android.json').read_text())
                self.assertEqual(data['OTLP_ENDPOINT'], 'http://10.0.2.2:20120')
                self.assertFalse((root / 'Mobiles/android/app/src/main/res/raw/config.json').exists())
                self.assertNotEqual(execute(command).returncode, 0)
                self.assertEqual(post('http://127.0.0.1:20134/collect/flutter', b'{"meta":{"session":{"id":"setup-test"}}}')[0], 200)
                eventually(lambda: len(server.records) == 2)
                self.assertEqual(execute(stop).returncode, 0)
                self.assertFalse(active.exists())
                self.assertFalse(active.is_symlink())
                self.assertTrue(config.exists())
                self.assertEqual(execute(stop).returncode, 0)
                result = execute([*command, '--', sys.executable, '-c',
                                  'import os,sys; assert os.path.isfile(os.environ["QUICKPIZZA_ANDROID_CONFIG_FILE"]); sys.exit(7)'])
                self.assertEqual(result.returncode, 7, result.stderr)
                self.assertFalse(active.is_symlink())
                wrapped = subprocess.Popen([*command, '--', sys.executable, '-c', 'import time; time.sleep(90)'],
                                           env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                try:
                    eventually(lambda: active.is_symlink())
                    # Wait for the command phase, not the short activation/launch handoff.
                    marker = here / '.runtime/local/ready'
                    self.assertTrue(marker.exists())
                    import time
                    time.sleep(.3)
                    wrapped.send_signal(signal.SIGTERM)
                    self.assertEqual(wrapped.wait(timeout=45), 130)
                    self.assertFalse(active.is_symlink())
                finally:
                    if wrapped.poll() is None:
                        wrapped.terminate()
                        wrapped.wait(timeout=45)
            finally:
                execute(stop)
                server.shutdown()
                server.server_close()
